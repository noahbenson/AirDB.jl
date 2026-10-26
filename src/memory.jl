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

mutable struct MemoryDatabase <: AbstractDatabase
    cache::Dict{UUID,WeakRef}
    cachelock::ReentrantLock
    names::Volatile{PDict{String,VolatileForm}}
    writeactor::Actor
    store::Dict{UUID,NTuple{3,Any}}  # (form, metadata, history) for each form
    resources::Dict{Tuple{Symbol,Symbol},Vector{UInt8}}  # extern bytes (session only)
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
    db = MemoryDatabase(Dict{UUID,WeakRef}(), ReentrantLock(),
                        Volatile{PDict{String,VolatileForm}}(PDict{String,VolatileForm}()),
                        actor, Dict{UUID,NTuple{3,Any}}(),
                        Dict{Tuple{Symbol,Symbol},Vector{UInt8}}(),
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
        lock(db.storelock)
        try
            for u in values(b.forms)
                db.store[u.vf.id] = (u.form, u.metadata, u.history)
                u.vf.persisted = true
            end
            # The in-memory database never encodes a form, so it collects the
            # externs it references by walking the committed form tree.
            found = IdDict{Any,Nothing}()
            for u in values(b.forms)
                _collect_externs!(found, u.form)
            end
            for h in keys(found)
                h.db === nothing && setfield!(h, :db, db)
                _rw_read(h.lock) do
                    db.resources[(h.type, h.id::Symbol)] = _serialize_resource(h)
                end
            end
            for (k, pr) in b.resources
                db.resources[k] = pr.data
            end
            for (name, id) in b.names
                db.nameids[name] = id
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

function _read_resource(db::MemoryDatabase, type::Symbol, id::Symbol)
    bytes = lock(db.storelock) do
        get(db.resources, (type, id), nothing)
    end
    bytes === nothing &&
        throw(ExternError("no resource :$type/$(id) is stored in the database"))
    return _deserialize_resource(type, bytes)
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

function Base.close(db::MemoryDatabase)
    db.closed = true
    return db
end

function Base.show(io::IO, db::MemoryDatabase)
    return print(io, "MemoryDatabase(", db.closed ? "closed" : "open", ")")
end

export MemoryDatabase
