################################################################################
# ref_forms.jl
#
# The behaviour of the three database-backed form kinds besides `VolatileForm`:
# `ActorForm` (an Air `Actor{Form}`), `PromiseForm` (a single-assignment
# `Air.Promise{Form}`), and `DelayForm` (a run-once value computed from a form by
# a registered loader). The types themselves live in types.jl.
#
# `ActorForm` persists through the actor's post-processing hook, which runs on the
# actor's task after each update. `PromiseForm` persists through the promise's
# delivery callback; inside a transaction that callback runs in the finalize
# phase, where a staged `send` joins the transaction and is discarded with a
# failed attempt, so the write is commit-gated.
#
# MIT License
# Copyright (c) 2020-2026 Noah C. Benson

# ---- actors ------------------------------------------------------------------

"""
    ActorForm(db, form::Form; history = true, metadata = nothing) -> ActorForm
    ActorForm(db, args...; history = true, metadata = nothing, kwargs...) -> ActorForm

Create an actor form and register its initial value for writing. Send functions
to it with `send(af) do value ... end`; each new value is persisted. `history`
is fixed for the actor's life: `true` appends a history row per update, `false`
overwrites the current row. `metadata` is the owner/ACL metadata blob.
"""
function ActorForm(db::AbstractDatabase, form::Form; history::Bool = true,
                   metadata = nothing)
    _check_open(db)
    m = metadata === nothing ? nothing : to_form(metadata)
    af = ActorForm(uuid4(), nothing, false, false, ReentrantLock(), db, history,
                   Volatile{FormMetadata}(m))
    af.actor = _make_actor(af, form)
    af.loaded = true
    _cache_put!(db, af)
    _register_actor!(af, form)
    return af
end
function ActorForm(db::AbstractDatabase, args...; history::Bool = true,
                   metadata = nothing, kwargs...)
    return ActorForm(db, form(args...; kwargs...); history = history, metadata = metadata)
end

# The Air actor's post-processor stores the function's result unchanged, after
# arranging for it to reach the database. It runs on the actor's task.
function _make_actor(af::ActorForm, value::Form)
    return Actor{Form}(value; postprocess = (old, new) -> (_register_actor!(af, new); new))
end

isloaded(af::ActorForm) = af.loaded

function load!(af::ActorForm)
    af.loaded && return af
    lock(af.db.gclock)
    try
        lock(af.lock)
        try
            af.loaded && return af
            _check_health(af.db)
            _check_failed(af.db, af.id)
            value, hist, meta = _read_actor(af.db, af.id)
            af.actor = _make_actor(af, value)
            af.history = hist
            # A committed metadata edit is already in the volatile; the row may
            # still be stale until the writer lands it.
            af.metavolatile === nothing &&
                (af.metavolatile = Volatile{FormMetadata}(meta))
            af.loaded = true
            af.persisted = true
            return af
        finally
            unlock(af.lock)
        end
    finally
        unlock(af.db.gclock)
    end
end

"""
    af[]

The actor form's current value. Inside a transaction this is an Air transactional
read, so the transaction sees a consistent value.
"""
Base.getindex(af::ActorForm) = (load!(af); (af.actor::Actor{Form})[])

"""
    send(f, af::ActorForm)

Send `f` to the actor form's underlying actor. Like any Air send, inside a
transaction this is deferred until the transaction commits.
"""
send(f::Function, af::ActorForm) = (load!(af); send(f, af.actor::Actor{Form}))

function _register_actor!(af::ActorForm, value)
    _stage!(b -> push!(b.actors,
                       AccumulatedActor(af, value, af.history, _metavalue(af))),
            af.db.writeactor, af.db)
    return value
end

function metadata(af::ActorForm)
    af.metavolatile === nothing || return _metavalue(af)
    # Metadata-only read: never fetch or decode the payload.
    lock(af.db.gclock)
    try
        af.metavolatile === nothing || return _metavalue(af)
        lock(af.lock)
        try
            af.loaded && return _metavalue(af)
            _check_failed(af.db, af.id)
            meta, hist = _read_actor_metadata(af.db, af.id)
            af.history = hist
            af.metavolatile = Volatile{FormMetadata}(meta)
            return _metavalue(af)
        finally
            unlock(af.lock)
        end
    finally
        unlock(af.db.gclock)
    end
end

function set_metadata!(af::ActorForm, m)
    currtx() === nothing &&
        throw(ArgumentError("metadata can only be set inside a transaction"))
    af.metavolatile === nothing && load!(af)
    meta = m === nothing ? nothing : to_form(m)
    _setmetavalue!(af, meta)          # transactional; Air rolls it back on abort
    _stage_metadata!(:actor, af.id, meta, af.db)
    return af
end

# ---- promises ----------------------------------------------------------------

"""
    PromiseForm(db; pending_commit = false, metadata = nothing) -> PromiseForm

Create an undelivered promise form. Settle it with `put!(pf, value)` or
`fail!(pf, error)`; the outcome is persisted when the settling transaction
commits (or immediately, outside a transaction). `metadata` is the owner/ACL
metadata blob.

`pending_commit = true` marks a promise created inside a transaction that has not
committed: reading it raises `UncommittedPromise` until
[`mark_committed!`](@ref), and [`mark_aborted!`](@ref) makes every read raise
`AbortedPromise`. Settling a pending promise is allowed.
"""
function PromiseForm(db::AbstractDatabase; pending_commit::Bool = false,
                     metadata = nothing)
    _check_open(db)
    m = metadata === nothing ? nothing : to_form(metadata)
    pf = PromiseForm(uuid4(), nothing, false, false, ReentrantLock(), db,
                     Volatile{FormMetadata}(m), pending_commit ? :pending : :live)
    pf.promise = _make_promise(pf)
    pf.loaded = true
    _cache_put!(db, pf)
    return pf
end

# A fresh Air promise with AirDB's settlement callbacks installed.
function _make_promise(pf::PromiseForm)
    return Air.Promise{Form}(ondelivery = v -> _register_promise!(pf, v),
                             onfailure = e -> _register_promise_failure!(pf, e))
end

"""
    mark_pending_commit!(pf::PromiseForm) -> PromiseForm

Marks the promise as created by a transaction that has not committed yet, so
reading it raises [`UncommittedPromise`](@ref).
"""
mark_pending_commit!(pf::PromiseForm) = _set_commit_state!(pf, :pending)

"""
    mark_committed!(pf::PromiseForm) -> PromiseForm

Marks the promise's creating transaction as committed: the promise becomes
`:live` and readable.
"""
mark_committed!(pf::PromiseForm) = _set_commit_state!(pf, :live)

"""
    mark_aborted!(pf::PromiseForm) -> PromiseForm

Marks the promise's creating transaction as aborted: every read or settlement
raises [`AbortedPromise`](@ref).
"""
mark_aborted!(pf::PromiseForm) = _set_commit_state!(pf, :aborted)

function _check_readable(pf::PromiseForm)
    state = _commit_state(pf)
    state === :aborted && throw(AbortedPromise(pf.id))
    state === :pending && throw(UncommittedPromise(pf.id))
    return nothing
end
function _check_settleable(pf::PromiseForm)
    _commit_state(pf) === :aborted && throw(AbortedPromise(pf.id))
    return nothing
end

isloaded(pf::PromiseForm) = pf.loaded

function load!(pf::PromiseForm)
    pf.loaded && return pf
    lock(pf.db.gclock)
    try
        lock(pf.lock)
        try
            pf.loaded && return pf
            _check_health(pf.db)
            _check_failed(pf.db, pf.id)
            row = _read_promise(pf.db, pf.id)
            if row === nothing
                # A promise with no row may only be one whose creating
                # transaction has not committed; otherwise the handle is stale.
                _commit_state(pf) === :pending || throw(FormNotFound(pf.id))
                pf.promise = _make_promise(pf)
                pf.persisted = false
            else
                state, value, error, meta = row
                pf.metavolatile === nothing &&
                    (pf.metavolatile = Volatile{FormMetadata}(meta))
                if state === :delivered
                    p = Air.Promise{Form}()     # no callbacks: loading is not delivering
                    put!(p, value)
                    pf.promise = p
                elseif state === :failed
                    p = Air.Promise{Form}()
                    fail!(p, error)
                    pf.promise = p
                else
                    pf.promise = _make_promise(pf)
                end
                pf.persisted = true
            end
            pf.loaded = true
            return pf
        finally
            unlock(pf.lock)
        end
    finally
        unlock(pf.db.gclock)
    end
end

"""
    isready(pf::PromiseForm) -> Bool

Whether the promise has been settled (delivered or failed), including a
settlement staged by the current transaction. Raises `UncommittedPromise` /
`AbortedPromise` for a promise in one of those states.
"""
function Base.isready(pf::PromiseForm; token = nothing)
    _check_readable(pf)
    load!(pf)
    # A non-blocking predicate stays independent of cancellation; Air's own
    # `isready` takes no token.
    return isready(pf.promise::Air.Promise{Form})
end

"""
    isfailed(pf::PromiseForm) -> Bool

Whether the promise failed (as opposed to being delivered).
"""
function isfailed(pf::PromiseForm)
    _check_readable(pf)
    load!(pf)
    return isfailed(pf.promise::Air.Promise{Form})
end

"""
    take(pf::PromiseForm; timeout = nothing, token = nothing)
    pf[]

The settled value. Outside a transaction this blocks until settlement; inside a
transaction, reading an unsettled promise raises, since waiting there can
deadlock — use `isready` first. With timeouts and cancellation (once Air
provides them) `timeout` raises `PromiseTimeout` and a cancelled `token` raises
`Cancelled`.
"""
function take(pf::PromiseForm; timeout = nothing, token = nothing)
    _check_readable(pf)
    load!(pf)
    p = pf.promise::Air.Promise{Form}
    currtx() === nothing || _settled(p) ||
        throw(ArgumentError("an unsettled promise cannot be read inside a transaction; " *
                            "use isready"))
    return take(p; timeout = timeout, token = token)
end
Base.getindex(pf::PromiseForm; timeout = nothing, token = nothing) =
    take(pf; timeout = timeout, token = token)

_settled(p::Air.Promise) = isready(p) || isfailed(p)

# A promise is always written as a link and always has a row, delivered or not.
# Serializing it as its value would lose the handle: a reader of the stored form
# could no longer tell who else was waiting on it, and a failure would have no
# place to live. Every delivery or failure is therefore a row, and a form that
# references the promise resolves to the same `PromiseForm` after a round trip.
# The row survives while something references it and is swept by `gc!` otherwise.

"""
    put!(pf::PromiseForm, value)

Deliver `value` to the promise (as a [`Form`](@ref)). A promise may be settled
only once. Inside a transaction the settlement is staged and takes effect only if
the transaction commits.
"""
function Base.put!(pf::PromiseForm, value)
    _check_settleable(pf)
    load!(pf)
    return put!(pf.promise::Air.Promise{Form}, to_form(value))
end

"""
    fail!(pf::PromiseForm, error)

Fail the promise with `error` (as a [`Form`](@ref)), exactly once. Readers then
throw `Air.PromiseFailed` carrying the stored error.
"""
function fail!(pf::PromiseForm, error)
    _check_settleable(pf)
    load!(pf)
    return fail!(pf.promise::Air.Promise{Form}, to_form(error))
end

# These callbacks run in Air's finalize phase (with `currtx() === nothing`), but
# their send is commit-gated; waiting for writer capacity there would block the
# committing transaction, so the wait is suppressed.
function _register_promise!(pf::PromiseForm, value)
    v = value isa Form ? value : to_form(value)
    _without_capacity() do
        _stage!(b -> (b.promise_settlements[pf.id] =
                          PendingPromise(pf.id, :delivered, v, _metavalue(pf))),
                pf.db.writeactor, pf.db)
    end
    return v
end

function _register_promise_failure!(pf::PromiseForm, error)
    e = error isa Form ? error : to_form(error)
    _without_capacity() do
        _stage!(b -> (b.promise_settlements[pf.id] =
                          PendingPromise(pf.id, :failed, e, _metavalue(pf))),
                pf.db.writeactor, pf.db)
    end
    return e
end

function metadata(pf::PromiseForm)
    pf.metavolatile === nothing || return _metavalue(pf)
    lock(pf.db.gclock)
    try
        pf.metavolatile === nothing || return _metavalue(pf)
        _check_failed(pf.db, pf.id)
        row = _read_promise_metadata(pf.db, pf.id)
        pf.metavolatile = Volatile{FormMetadata}(row === nothing ? nothing : row[1])
        return _metavalue(pf)
    finally
        unlock(pf.db.gclock)
    end
end

function set_metadata!(pf::PromiseForm, m)
    currtx() === nothing &&
        throw(ArgumentError("metadata can only be set inside a transaction"))
    pf.metavolatile === nothing && load!(pf)
    meta = m === nothing ? nothing : to_form(m)
    _setmetavalue!(pf, meta)          # transactional; Air rolls it back on abort
    _stage_metadata!(:promise, pf.id, meta, pf.db)
    return pf
end

# Promises referenced by the form currently being encoded, so the writer can
# create their (pending) rows before any form that names them. A task-local set,
# like the extern references.
const _PROMISE_REF_KEY = :AirDBReferencedPromises
function _promise_refs()
    d = task_local_storage()
    s = get(d, _PROMISE_REF_KEY, nothing)
    (s isa IdDict{Any,Nothing}) && return s
    s = IdDict{Any,Nothing}()
    task_local_storage(_PROMISE_REF_KEY, s)
    return s
end
function _note_referenced_promise!(pf::PromiseForm)
    _collecting_refs() && (_promise_refs()[pf] = nothing)
    return nothing
end

# Collect the promises in a form tree. The PostgreSQL writer learns this while
# encoding; `MemoryDatabase` never encodes, so it walks the tree. Every promise
# needs a row — a delivered one included — so the link survives a round trip.
_collect_promises!(out, ::FormScalar) = out
_collect_promises!(out, ::VolatileForm) = out
_collect_promises!(out, ::Any) = out
function _collect_promises!(out, pf::PromiseForm)
    out[pf] = nothing
    return out
end
function _collect_promises!(out, fc::FormContainer)
    for x in fc.seq
        _collect_promises!(out, x)
    end
    for (_, v) in fc.map
        _collect_promises!(out, v)
    end
    return out
end
# A delay is written as its serialization form, so the objects that form names
# are part of the delay's references even though the delay itself is not loaded.
_collect_promises!(out, df::DelayForm) = _collect_promises!(out, df.form)

# ---- delays ------------------------------------------------------------------

const _DELAY_LOADERS = Dict{Symbol,Function}()

"""
    register_delay(name::Symbol, load_fn)

Register a delay type under `name`. `load_fn(form)` computes the delay's value
from its serialization form. Create a delay with `DelayForm(name, form)`.
"""
function register_delay(name::Symbol, load_fn::Function)
    haskey(_DELAY_LOADERS, name) &&
        throw(ArgumentError("a delay type is already registered under :$name"))
    _DELAY_LOADERS[name] = load_fn
    return load_fn
end

function _delay_loader(name::Symbol)
    fn = get(_DELAY_LOADERS, name, nothing)
    fn === nothing && throw(ArgumentError("no delay type is registered under :$name"))
    return fn
end

"""
    DelayForm(type::Symbol, form::Form) -> DelayForm

Create a delay form of the registered type `type`, serialized as `form`. The
loader is run the first time `d[]` is read, and the result is memoized; writing
the delay out never forces it.
"""
function DelayForm(type::Symbol, form::Form)
    fn = _delay_loader(type)
    return DelayForm(type, form, Delay{Form}(() -> fn(form)))
end

Base.getindex(df::DelayForm) = df.delay[]
Base.isready(df::DelayForm) = isready(df.delay)
Base.setindex!(df::DelayForm, x, ::CartesianIndex{0}) =
    throw(ArgumentError("setindex!: delays are immutable"))
function Base.setindex!(df::DelayForm, x...)
    return throw(ArgumentError("setindex!: delays are immutable"))
end

# ---- printing ----------------------------------------------------------------

Base.show(io::IO, af::ActorForm) = begin
    print(io, "ActorForm(@", af.id)
    if af.loaded && af.actor !== nothing
        print(io, ": ")
        show(io, (af.actor::Actor{Form})[])
    end
    print(io, ")")
end
Base.show(io::IO, pf::PromiseForm) = begin
    print(io, "PromiseForm(@", pf.id)
    if pf.loaded && isready(pf.promise::Air.Promise{Form})
        print(io, ": ")
        show(io, (pf.promise::Air.Promise{Form})[])
    end
    print(io, ")")
end
Base.show(io::IO, df::DelayForm) = print(io, "DelayForm(:", df.type, ")")

_showvalue(io::IO, af::ActorForm) = print(io, "ActorForm(@", af.id, ")")
_showvalue(io::IO, pf::PromiseForm) = print(io, "PromiseForm(@", pf.id, ")")
_showvalue(io::IO, df::DelayForm) = print(io, "DelayForm(:", df.type, ")")

export ActorForm, PromiseForm, DelayForm, get_actor, get_promise, register_delay,
    UncommittedPromise, AbortedPromise, mark_pending_commit!, mark_committed!,
    mark_aborted!
