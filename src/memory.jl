################################################################################
# memory.jl
#
# An in-memory `Database` for testing. It presents the same surface as the
# PostgreSQL-backed one — `VolatileForm`, `named_form`, `get_form`, `sync`, one
# writer actor, commit ordering — but keeps everything in dictionaries and
# vectors, saves nothing, and keeps no history: only the current value of each
# form and the name table. Nothing in it is ever garbage collected, so a test can
# hold ids and reload forms freely.
#
# MIT License
# Copyright (c) 2020-2026 Noah C. Benson

# The state of one promise in a `MemoryDatabase`: pending, delivered, or failed.
mutable struct _MemoryPromise
    state::Symbol                          # :pending | :delivered | :failed
    value::Union{Nothing,Form}
    error::Union{Nothing,Form}
    metadata::Union{Nothing,Form}
end

mutable struct MemoryDatabase <: AbstractDatabase
    cache::Dict{UUID,WeakRef}        # VolatileForm
    actorcache::Dict{UUID,WeakRef}   # ActorForm
    promisecache::Dict{UUID,WeakRef} # PromiseForm
    streamcache::Dict{UUID,WeakRef}  # StreamForm
    cachelock::ReentrantLock
    gclock::ReentrantLock              # held exclusively by gc!; shared by loads
    names::Volatile{PDict{String,VolatileForm}}
    writeactor::Actor
    store::Dict{UUID,NTuple{3,Any}}          # (form, metadata, history)
    actorvals::Dict{UUID,NTuple{3,Any}}      # (value, history, metadata)
    promisevals::Dict{UUID,_MemoryPromise}   # promise state, value/error, metadata
    streamvals::Dict{UUID,NTuple{4,Any}}     # (items, maxsize, closed, metadata)
    resources::Dict{Tuple{Symbol,Symbol},NTuple{2,Any}}  # (bytes, metadata)
    nameids::Dict{String,UUID}      # the alias table
    storelock::ReentrantLock
    failure::Union{Nothing,DatabaseError}
    closed::Bool
end

# The writer actor's value: a reference back to the database, whose store it
# applies committed batches to.
mutable struct MemoryActorState
    db::Union{Nothing,MemoryDatabase}
end

"""
    MemoryDatabase() -> MemoryDatabase

A fake, in-memory [`Database`](@ref) for testing without PostgreSQL. It behaves
like a real database — forms persist across commits, named forms work, `sync`
blocks — but keeps everything in memory, saves nothing, and keeps no history.
"""
function MemoryDatabase()
    st = MemoryActorState(nothing)
    actor = Actor{MemoryActorState}(st)
    db = MemoryDatabase(Dict{UUID,WeakRef}(), Dict{UUID,WeakRef}(), Dict{UUID,WeakRef}(),
                        Dict{UUID,WeakRef}(),
                        ReentrantLock(), ReentrantLock(),
                        Volatile{PDict{String,VolatileForm}}(PDict{String,VolatileForm}()),
                        actor, Dict{UUID,NTuple{3,Any}}(),
                        Dict{UUID,NTuple{3,Any}}(),
                        Dict{UUID,_MemoryPromise}(),
                        Dict{UUID,NTuple{4,Any}}(),
                        Dict{Tuple{Symbol,Symbol},NTuple{2,Any}}(),
                        Dict{String,UUID}(), ReentrantLock(), nothing, false)
    st.db = db
    return db
end

# The writer: apply the committed batch to the in-memory store, keeping only the
# current value (no history).
function _receive!(st::MemoryActorState, b::WriteBatch)
    _batch_empty(b) && return st
    db = st.db
    if db !== nothing
        # The in-memory database never encodes a form, so it collects the
        # objects the committed trees name by walking them. Reading the
        # referenced objects — an extern's bytes, a stream's snapshot, a
        # promise's metadata — is done before taking the store lock: a loader
        # holds a form's or a handle's lock and then takes the store lock, so
        # doing this under the store lock would invert that order.
        found = IdDict{Any,Nothing}()
        foundp = IdDict{Any,Nothing}()
        founds = IdDict{Any,Nothing}()
        for u in values(b.forms)
            _collect_externs!(found, u.form)
            _collect_promises!(foundp, u.form)
            _collect_streams!(founds, u.form)
        end
        promises = Tuple{UUID,Union{Nothing,Form}}[]
        for pf in keys(foundp)
            # An unloaded promise was rehydrated from a stored payload, so its
            # row exists; do not load it here.
            pf.loaded || continue
            push!(promises, (pf.id, _metavalue(pf)))
        end
        snaps = Tuple{UUID,Any}[]
        for sf in keys(founds)
            snap = _stream_snapshot(sf)     # `nothing` for an unloaded stream
            snap === nothing || push!(snaps, (sf.id, snap))
        end
        externs = Tuple{Tuple{Symbol,Symbol},Any,Any,Any}[]
        for h in keys(found)
            (h.db === nothing) && setfield!(h, :db, db)
            h.loaded || continue            # its row is where it came from
            h.present && continue           # the resource row already exists
            _rw_read(h.lock) do
                push!(externs, ((h.type, h.id::Symbol), _serialize_resource(h),
                                _metavalue(h), h))
            end
        end
        lock(db.storelock)
        try
            for u in values(b.forms)
                db.store[u.vf.id] = (u.form, u.metadata, u.history)
                u.vf.persisted = true
            end
            for (id, meta) in promises
                haskey(db.promisevals, id) ||
                    (db.promisevals[id] = _MemoryPromise(:pending, nothing, nothing, meta))
            end
            for (id, snap) in snaps
                haskey(db.streamvals, id) || (db.streamvals[id] = snap)
            end
            for (key, bytes, meta, h) in externs
                db.resources[key] = (bytes, meta)
                h.present = true
            end
            for (k, pr) in b.resources
                db.resources[k] = (pr.data, pr.metadata)
                pr.handle === nothing || (pr.handle.present = true)
            end
            for pa in b.actors
                db.actorvals[pa.af.id] = (pa.value, pa.history, pa.metadata)
            end
            # A promise row exists once something references it while unsettled
            # or it is settled; a settlement is a compare-and-set.
            for (id, meta) in b.promise_ensure
                haskey(db.promisevals, id) ||
                    (db.promisevals[id] = _MemoryPromise(:pending, nothing, nothing, meta))
            end
            for (id, ps) in b.streams
                db.streamvals[id] = (ps.items, ps.maxsize, ps.closed, ps.metadata)
            end
            for (id, pp) in b.promise_settlements
                rec = get!(db.promisevals, id,
                           _MemoryPromise(:pending, nothing, nothing, pp.metadata))
                rec.state === :pending || continue
                rec.state = pp.state
                if pp.state === :delivered
                    rec.value = pp.payload
                else
                    rec.error = pp.payload
                end
            end
            for pm in b.metadata
                _apply_memory_metadata!(db, pm)
            end
            for no in b.nameops
                if no.op === :set
                    db.nameids[no.name] = no.id::UUID
                else
                    delete!(db.nameids, no.name)
                end
            end
        finally
            unlock(db.storelock)
        end
    end
    _batch_empty!(b)
    return st
end

_flush!(st::MemoryActorState) = st              # nothing is ever queued
_reconnect_writer!(::MemoryActorState) = nothing

function _read_current(db::MemoryDatabase, id::UUID)
    lock(db.storelock)
    try
        haskey(db.store, id) || throw(FormNotFound(id))
        return db.store[id]
    finally
        unlock(db.storelock)
    end
end

function _read_actor(db::MemoryDatabase, id::UUID)
    lock(db.storelock)
    try
        haskey(db.actorvals, id) || throw(FormNotFound(id))
        return db.actorvals[id]
    finally
        unlock(db.storelock)
    end
end

# A promise row as `(state, value, error, metadata)`, or `nothing` when absent.
function _read_promise(db::MemoryDatabase, id::UUID)
    lock(db.storelock)
    try
        rec = get(db.promisevals, id, nothing)
        rec === nothing && return nothing
        return (rec.state, rec.value, rec.error, rec.metadata)
    finally
        unlock(db.storelock)
    end
end

function _read_form_metadata(db::MemoryDatabase, id::UUID)
    lock(db.storelock)
    try
        haskey(db.store, id) || throw(FormNotFound(id))
        v = db.store[id]
        return (v[2], v[3])
    finally
        unlock(db.storelock)
    end
end

function _read_actor_metadata(db::MemoryDatabase, id::UUID)
    lock(db.storelock)
    try
        haskey(db.actorvals, id) || throw(FormNotFound(id))
        v = db.actorvals[id]
        return (v[3], v[2])
    finally
        unlock(db.storelock)
    end
end

function _read_promise_metadata(db::MemoryDatabase, id::UUID)
    lock(db.storelock)
    try
        rec = get(db.promisevals, id, nothing)
        rec === nothing && return nothing
        return (rec.metadata, rec.state)
    finally
        unlock(db.storelock)
    end
end

function _read_stream(db::MemoryDatabase, id::UUID)
    lock(db.storelock)
    try
        return get(db.streamvals, id, nothing)
    finally
        unlock(db.storelock)
    end
end

function _read_stream_metadata(db::MemoryDatabase, id::UUID)
    lock(db.storelock)
    try
        v = get(db.streamvals, id, nothing)
        v === nothing ? nothing : v[4]
    finally
        unlock(db.storelock)
    end
end

# The snapshot a `MemoryDatabase` stores for a stream, or `nothing` when the
# stream is unloaded (it then came from a stored snapshot, and loading it would
# take `gclock` under the store lock).
function _stream_snapshot(sf::StreamForm)
    sf.loaded || return nothing
    inner = sf.stream::Air.Stream{Form}
    return (snapshot(inner), maxsize(inner), !isopen(inner), _metavalue(sf))
end

function _read_resource(db::MemoryDatabase, type::Symbol, id::Symbol)
    entry = lock(db.storelock) do
        get(db.resources, (type, id), nothing)
    end
    entry === nothing &&
        throw(ExternError("no resource :$type/$(id) is stored in the database"))
    return _deserialize_resource(type, entry[1])
end

function _read_resource_metadata(db::MemoryDatabase, type::Symbol, id::Symbol)
    lock(db.storelock) do
        entry = get(db.resources, (type, id), nothing)
        entry === nothing ? nothing : entry[2]
    end
end

# Apply a metadata-only edit to the in-memory rows.
function _apply_memory_metadata!(db::MemoryDatabase, pm::PendingMetadata)
    if pm.kind === :form
        haskey(db.store, pm.id) || return nothing
        v = db.store[pm.id]
        db.store[pm.id] = (v[1], pm.metadata, v[3])
    elseif pm.kind === :actor
        haskey(db.actorvals, pm.id) || return nothing
        v = db.actorvals[pm.id]
        db.actorvals[pm.id] = (v[1], v[2], pm.metadata)
    elseif pm.kind === :promise
        rec = get(db.promisevals, pm.id, nothing)
        rec === nothing || (rec.metadata = pm.metadata)
    elseif pm.kind === :stream
        v = get(db.streamvals, pm.id, nothing)
        v === nothing || (db.streamvals[pm.id] = (v[1], v[2], v[3], pm.metadata))
    elseif pm.kind === :extern
        haskey(db.resources, pm.id) || return nothing
        v = db.resources[pm.id]
        db.resources[pm.id] = (v[1], pm.metadata)
    end
    return nothing
end

function _load_names(db::MemoryDatabase)
    names = PDict{String,VolatileForm}()
    for (name, id) in db.nameids
        names = push(names, name => get_form(db, id))
    end
    return names
end

function sync(db::MemoryDatabase)
    _check_open(db)
    sig = Channel{Nothing}(1)
    send(db.writeactor) do st
        put!(sig, nothing)
        return st
    end
    take!(sig)
    return nothing
end

status(db::MemoryDatabase) = (0, nothing)
pending_writes(db::MemoryDatabase) = Any[]

# The in-memory database never fails a write, so its failure lists are empty.
write_failures(::MemoryDatabase) = FailureRecord[]
write_failures(::MemoryDatabase, id) = FailureRecord[]
failed(::MemoryDatabase, id) = false
clear_write_failure!(::MemoryDatabase, id; retry::Bool = false) = false
clear_write_failures!(::MemoryDatabase) = nothing
read_failures(::MemoryDatabase) = ReadFailure[]
read_failures(::MemoryDatabase, id) = ReadFailure[]
clear_read_failures!(::MemoryDatabase) = nothing
_failed_write_items(::MemoryDatabase) = Any[]
_check_failed(::MemoryDatabase, id) = nothing

function Base.close(db::MemoryDatabase)
    db.closed = true
    return db
end

function Base.show(io::IO, db::MemoryDatabase)
    return print(io, "MemoryDatabase(", db.closed ? "closed" : "open", ")")
end

export MemoryDatabase
