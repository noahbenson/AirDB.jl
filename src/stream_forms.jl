################################################################################
# stream_forms.jl
#
# `StreamForm`: a form backed by an Air `Stream{Form}`. Air owns the queue — the
# FIFO, the bound, blocking, timeouts, cancellation, closing, and transactional
# staging — so this file is the form wrapper: construction, lazy loading,
# persistence, commit state, and metadata.
#
# Persistence follows the promise pattern. Every successful `put!`, `take` or
# `close` stages a snapshot of the queue to the database writer; inside a
# transaction the send is dispatched only if the transaction commits and is
# discarded with a failed attempt. The snapshot is the transaction's staged view
# (`snapshot` includes its staged puts and excludes its takes), which is exactly
# the committed contents when the transaction commits.
 #
# MIT License
# Copyright (c) 2020-2026 Noah C. Benson

# ---- construction and loading ------------------------------------------------

"""
    StreamForm(db; maxsize = nothing, pending_commit = false,
               metadata = nothing) -> StreamForm

Create a stream form and register its (empty) row for writing. `maxsize` bounds
the number of queued forms (`nothing` leaves it unbounded). Send and receive with
`put!(sf, value)` and `take(sf)`; both accept `timeout` and `token` keywords, and
`close(sf)` ends the stream. `metadata` is the owner/ACL metadata blob.

`pending_commit = true` marks a stream created inside a transaction that has not
committed: read-like operations raise [`UncommittedStream`](@ref) until
[`mark_committed!`](@ref), and [`mark_aborted!`](@ref) makes every operation
raise [`AbortedStream`](@ref). Writing to a pending stream is allowed.
"""
function StreamForm(db::AbstractDatabase; maxsize = nothing,
                    pending_commit::Bool = false, metadata = nothing)
    _check_open(db)
    m = metadata === nothing ? nothing : to_form(metadata)
    sf = StreamForm(uuid4(), nothing, false, false, ReentrantLock(),
                    ReentrantLock(), db, Volatile{FormMetadata}(m),
                    pending_commit ? :pending : :live)
    sf.stream = Air.Stream{Form}(; maxsize = maxsize)
    sf.loaded = true
    _cache_put!(db, sf)
    _register_stream!(sf)
    return sf
end

isloaded(sf::StreamForm) = sf.loaded

function load!(sf::StreamForm)
    sf.loaded && return sf
    lock(sf.db.gclock)
    try
        lock(sf.lock)
        try
            sf.loaded && return sf
            _check_health(sf.db)
            _check_failed(sf.db, sf.id)
            row = _read_stream(sf.db, sf.id)
            row === nothing && throw(FormNotFound(sf.id))
            items, maxsize, closed, meta = row
            s = Air.Stream{Form}(items; maxsize = maxsize)
            closed && close(s)
            sf.stream = s
            sf.metavolatile === nothing &&
                (sf.metavolatile = Volatile{FormMetadata}(meta))
            sf.loaded = true
            sf.persisted = true
            return sf
        finally
            unlock(sf.lock)
        end
    finally
        unlock(sf.db.gclock)
    end
end

# ---- commit state ------------------------------------------------------------

"""
    mark_pending_commit!(sf::StreamForm) -> StreamForm

Marks the stream as created by a transaction that has not committed yet, so
read-like operations raise [`UncommittedStream`](@ref).
"""
mark_pending_commit!(sf::StreamForm) = _set_commit_state!(sf, :pending)

"""
    mark_committed!(sf::StreamForm) -> StreamForm

Marks the stream's creating transaction as committed: the stream becomes
`:live`.
"""
mark_committed!(sf::StreamForm) = _set_commit_state!(sf, :live)

"""
    mark_aborted!(sf::StreamForm) -> StreamForm

Marks the stream's creating transaction as aborted: every operation raises
[`AbortedStream`](@ref).
"""
mark_aborted!(sf::StreamForm) = _set_commit_state!(sf, :aborted)

function _check_stream_readable(sf::StreamForm)
    state = _commit_state(sf)
    state === :aborted && throw(AbortedStream(sf.id))
    state === :pending && throw(UncommittedStream(sf.id))
    return nothing
end
function _check_stream_writable(sf::StreamForm)
    _commit_state(sf) === :aborted && throw(AbortedStream(sf.id))
    return nothing
end

# ---- operations --------------------------------------------------------------

_inner(sf::StreamForm) = sf.stream::Air.Stream{Form}

"""
    take(sf::StreamForm; timeout = nothing, token = canceltoken())

Remove and return the oldest queued form, blocking when the stream is empty.
`timeout` raises `Air.ReaderTimeout`; `token` observes cancellation. Inside a
transaction the take is staged by Air and happens only if the transaction
commits.
"""
function take(sf::StreamForm; timeout = nothing,
              token::Union{Nothing,Air.CancelToken} = Air.canceltoken())
    _check_stream_readable(sf)
    load!(sf)
    r = take(_inner(sf); timeout = timeout, token = token)
    _register_stream!(sf)
    return r
end

"""
    put!(sf::StreamForm, value; timeout = nothing, token = canceltoken())

Append a form to the stream, blocking when a bounded stream is full. `value` is
converted with [`to_form`](@ref). `timeout` raises `Air.ReaderTimeout`; `token`
observes cancellation. Inside a transaction the append is staged by Air and
happens only if the transaction commits.
"""
function Base.put!(sf::StreamForm, value; timeout = nothing,
                   token::Union{Nothing,Air.CancelToken} = Air.canceltoken())
    _check_stream_writable(sf)
    load!(sf)
    r = put!(_inner(sf), to_form(value); timeout = timeout, token = token)
    _register_stream!(sf)
    return r
end

"""
    close(sf::StreamForm)

Closes the stream: a later `put!` raises `Air.StreamClosed`, and a `take`
drains what remains and then raises it too. Idempotent; staged inside a
transaction.
"""
function Base.close(sf::StreamForm)
    _check_stream_writable(sf)
    load!(sf)
    close(_inner(sf))
    _register_stream!(sf)
    return sf
end

# ---- inspection --------------------------------------------------------------

"""
    isopen(sf::StreamForm) -> Bool

Whether the stream is open.
"""
function Base.isopen(sf::StreamForm)
    _check_stream_readable(sf)
    load!(sf)
    return isopen(_inner(sf))
end

"""
    length(sf::StreamForm) -> Int
    isempty(sf::StreamForm) -> Bool
    isready(sf::StreamForm) -> Bool

The number of queued forms, whether there are none, and whether a `take` would
return immediately. Inside a transaction these are Air's read-your-writes view.
"""
function Base.length(sf::StreamForm)
    _check_stream_readable(sf)
    load!(sf)
    return length(_inner(sf))
end
Base.isempty(sf::StreamForm) = length(sf) == 0
function Base.isready(sf::StreamForm)
    _check_stream_readable(sf)
    load!(sf)
    return isready(_inner(sf))
end

"""
    maxsize(sf::StreamForm) -> Union{Nothing,Int}

The stream's bound, or `nothing` when it is unbounded.
"""
maxsize(sf::StreamForm) = (load!(sf); maxsize(_inner(sf)))

"""
    snapshot(sf::StreamForm) -> Vector{Form}

A copy of the queued forms, oldest first, without removing them.
"""
function snapshot(sf::StreamForm)
    _check_stream_readable(sf)
    load!(sf)
    return snapshot(_inner(sf))
end

Base.eltype(::Type{StreamForm}) = Form

# ---- persistence -------------------------------------------------------------

# Stage a snapshot of the stream's queue. Inside a transaction the snapshot is
# the staged view, and the staged send is discarded if the attempt fails. The
# snapshot and the staging are serialized per stream: two tasks that operate on
# the stream outside a transaction would otherwise be able to enqueue their
# snapshots in the opposite order from the operations, so a stale snapshot could
# overwrite a newer one.
function _register_stream!(sf::StreamForm)
    sf.loaded || return sf
    lock(sf.oplock)
    try
        s = _inner(sf)
        ps = PendingStream(sf, snapshot(s), maxsize(s), !isopen(s), _metavalue(sf))
        _stage!(b -> (b.streams[sf.id] = ps), sf.db.writeactor, sf.db)
    finally
        unlock(sf.oplock)
    end
    return sf
end

# Streams referenced by the form currently being encoded, so their rows exist
# before any form or queue that names them. A task-local set, like the extern and
# promise references.
const _STREAM_REF_KEY = :AirDBReferencedStreams
function _stream_refs()
    d = task_local_storage()
    s = get(d, _STREAM_REF_KEY, nothing)
    (s isa IdDict{Any,Nothing}) && return s
    s = IdDict{Any,Nothing}()
    task_local_storage(_STREAM_REF_KEY, s)
    return s
end
function _note_referenced_stream!(sf::StreamForm)
    _collecting_refs() && (_stream_refs()[sf] = nothing)
    return nothing
end

# The streams a form tree names. `MemoryDatabase` uses this to ensure their rows
# exist, since it never encodes a form.
_collect_streams!(out, ::Any) = out
_collect_streams!(out, sf::StreamForm) = (out[sf] = nothing; out)
function _collect_streams!(out, fc::FormContainer)
    for x in fc.seq
        _collect_streams!(out, x)
    end
    for (_, v) in fc.map
        _collect_streams!(out, v)
    end
    return out
end
_collect_streams!(out, df::DelayForm) = _collect_streams!(out, df.form)

# Encode a stream's queued forms as the form-container encoding `[items, {}]`,
# so reading it back is an ordinary `from_JSON` that resolves links.
function _encode_stream_items(items::Vector{Form})
    io = IOBuffer()
    print(io, "[[")
    sep = ""
    for x in items
        print(io, sep)
        sep = ", "
        _jsonvalue(io, x)
    end
    print(io, "], {}]")
    return String(take!(io))
end

# ---- metadata ----------------------------------------------------------------

function metadata(sf::StreamForm)
    sf.metavolatile === nothing || return _metavalue(sf)
    lock(sf.db.gclock)
    try
        sf.metavolatile === nothing || return _metavalue(sf)
        _check_failed(sf.db, sf.id)
        sf.metavolatile =
            Volatile{FormMetadata}(_read_stream_metadata(sf.db, sf.id))
        return _metavalue(sf)
    finally
        unlock(sf.db.gclock)
    end
end

function set_metadata!(sf::StreamForm, m)
    currtx() === nothing &&
        throw(ArgumentError("metadata can only be set inside a transaction"))
    sf.metavolatile === nothing && load!(sf)
    meta = m === nothing ? nothing : to_form(m)
    _setmetavalue!(sf, meta)          # transactional; Air rolls it back on abort
    _stage_metadata!(:stream, sf.id, meta, sf.db)
    return sf
end

# ---- printing ----------------------------------------------------------------

function Base.show(io::IO, sf::StreamForm)
    print(io, "StreamForm(@", sf.id, ")")
    return nothing
end
_showvalue(io::IO, sf::StreamForm) = print(io, "StreamForm(@", sf.id, ")")

export StreamForm, get_stream, UncommittedStream, AbortedStream
