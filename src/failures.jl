################################################################################
# failures.jl
#
# Failure records for the `:isolate` policy. A batch that cannot be written is
# quarantined: its objects stay in memory, are marked failed (so they cannot be
# reloaded from the older database row), and are recorded here for inspection,
# clearing, or a manual retry. Read failures are recorded separately, since they
# are not durability gaps.
#
# MIT License
# Copyright (c) 2020-2026 Noah C. Benson

"""
    FailedItem

One object that a quarantined batch could not save: its `kind`
(`:form`, `:actor`, `:promise`, `:stream`, `:extern`, or `:name`), its `id`
(a `UUID`, a `(type, id)` pair, or a name), the live object when one is known,
and the pending write that failed.
"""
struct FailedItem
    kind::Symbol
    id::Any
    object::Any
    write::Any
end

"""
    FailureRecord

One quarantined batch: the batch's sequence number, the database error, when it
happened, and the [`FailedItem`](@ref)s it contained.
"""
struct FailureRecord
    sequence::Int
    error::Exception
    time::Float64
    items::Vector{FailedItem}
end

"""
    ReadFailure

A read that failed and was not retried successfully: the error, when it
happened, the operation (`:load`, `:metadata`, `:name`, `:read`, ...), and the
object id when the read was for one.
"""
struct ReadFailure
    error::Exception
    time::Float64
    operation::Symbol
    id::Any
end

"""
    FailedObjectError(id, record)

Raised when an object whose database write was quarantined is loaded. The live
in-memory object remains readable; reloading it would silently return the older
row, so it raises instead. See [`write_failures`](@ref) and
[`clear_write_failure!`](@ref).
"""
struct FailedObjectError <: Exception
    id::Any
    record::Union{Nothing,FailureRecord}
end

function Base.showerror(io::IO, e::FailedObjectError)
    print(io, "the database write for ", e.id,
          " was quarantined and not saved")
    if e.record !== nothing
        print(io, ": ", sprint(showerror, e.record.error))
    end
    return print(io, "; see write_failures(db)")
end

Base.show(io::IO, r::FailureRecord) =
    print(io, "FailureRecord(#", r.sequence, ", ", length(r.items),
          " item(s): ", sprint(showerror, r.error), ")")

# The read-failure history is bounded so a long outage cannot grow without limit.
const _MAX_READ_FAILURES = 1024

# ---- keys --------------------------------------------------------------------

# The key for an item: `(:form, uuid)`, `(:extern, (type, id))`, `(:name, name)`.
_item_key(it::FailedItem) =
    it.kind === :extern ? (:extern, it.id) :
    it.kind === :name ? (:name, String(it.id)) :
    (it.kind, it.id)

# The keys an id may refer to, so `failed`/`write_failures(db, id)` accept a
# UUID, an extern `(type, id)` pair, a name, or an explicit key.
function _candidate_keys(id)
    id isa UUID && return Any[(:form, id), (:actor, id), (:promise, id), (:stream, id)]
    if id isa Tuple && length(id) == 2 && id[1] isa Symbol
        (id[2] isa UUID) && return Any[id]            # an explicit key
        return Any[(:extern, id)]                     # an extern (type, id)
    end
    (id isa AbstractString || id isa Symbol) && return Any[(:name, String(id))]
    return Any[]
end

_id_matches(it::FailedItem, id) = any(k -> _item_key(it) == k, _candidate_keys(id))

function _metadata_target_kind(kind::Symbol)
    # A metadata edit's `PendingMetadata.kind` already names the target kind;
    # `:extern` stays `:extern`.
    return kind
end

# ---- queries -----------------------------------------------------------------

"""
    write_failures(db) -> Vector{FailureRecord}
    write_failures(db, id) -> Vector{FailureRecord}

The quarantined write batches, oldest first, or those touching `id` (a `UUID`,
an extern `(type, id)` pair, a name, or an explicit `(kind, id)` key).
"""
function write_failures(db::AbstractDatabase)
    lock(db.faillock)
    try
        return copy(db.writefailures)
    finally
        unlock(db.faillock)
    end
end

function write_failures(db::AbstractDatabase, id)
    lock(db.faillock)
    try
        return [r for r in db.writefailures
                if any(it -> _id_matches(it, id), r.items)]
    finally
        unlock(db.faillock)
    end
end

"""
    failed(db, id) -> Bool

Whether `id` currently has an unsaved (quarantined) write. A live in-memory
object is still readable; loading it raises [`FailedObjectError`](@ref).
"""
function failed(db::AbstractDatabase, id)
    lock(db.faillock)
    try
        for k in _candidate_keys(id)
            idx = get(db.failedkeys, k, 0)
            idx == 0 && continue
            ls = get(db.lastsuccess, k, 0)
            (idx <= length(db.writefailures)) || continue
            (db.writefailures[idx].sequence > ls) && return true
        end
        return false
    finally
        unlock(db.faillock)
    end
end

"""
    read_failures(db) -> Vector{ReadFailure}
    read_failures(db, id) -> Vector{ReadFailure}

Reads that failed, oldest first. They do not block later reads; clear them with
[`clear_read_failures!`](@ref).
"""
function read_failures(db::AbstractDatabase)
    lock(db.faillock)
    try
        return copy(db.readfailures)
    finally
        unlock(db.faillock)
    end
end

function read_failures(db::AbstractDatabase, id)
    lock(db.faillock)
    try
        return [r for r in db.readfailures if r.id == id]
    finally
        unlock(db.faillock)
    end
end

# ---- recording ---------------------------------------------------------------

function _failed_write_items(db::AbstractDatabase)
    lock(db.faillock)
    try
        out = Any[]
        for rec in db.writefailures, it in rec.items
            push!(out, it.write)
        end
        return out
    finally
        unlock(db.faillock)
    end
end

function _record_write_failure!(db::AbstractDatabase, sequence::Int,
                                err::Exception, items::Vector{FailedItem})
    lock(db.faillock)
    try
        push!(db.writefailures, FailureRecord(sequence, err, time(), items))
        idx = length(db.writefailures)
        for it in items
            db.failedkeys[_item_key(it)] = idx
        end
    finally
        unlock(db.faillock)
    end
    return nothing
end

function _mark_write_success!(db::AbstractDatabase, keys, sequence::Int)
    lock(db.faillock)
    try
        for k in keys
            db.lastsuccess[k] = max(get(db.lastsuccess, k, 0), sequence)
            idx = get(db.failedkeys, k, 0)
            if idx != 0 && idx <= length(db.writefailures) &&
               db.writefailures[idx].sequence <= sequence
                delete!(db.failedkeys, k)
            end
        end
    finally
        unlock(db.faillock)
    end
    return nothing
end

function _record_read_failure!(db::AbstractDatabase, err::Exception,
                               operation::Symbol, id)
    lock(db.faillock)
    try
        push!(db.readfailures, ReadFailure(err, time(), operation, id))
        length(db.readfailures) > _MAX_READ_FAILURES && popfirst!(db.readfailures)
    finally
        unlock(db.faillock)
    end
    return nothing
end

function _check_failed(db::AbstractDatabase, id)
    failed(db, id) || return nothing
    rec = nothing
    for r in write_failures(db, id)
        rec = r
    end
    throw(FailedObjectError(id, rec))
end

# ---- clearing and manual retry ----------------------------------------------

"""
    clear_write_failure!(db, id; retry = false) -> Bool

Acknowledge and remove the quarantined writes for `id`. With `retry = true`,
also re-stage the object's **current** in-memory value for another write (a
form's value and metadata, an actor's value, a stream's snapshot, an extern's
bytes, the current name mapping, or a promise's outcome). Returns whether
anything was cleared.
"""
function clear_write_failure!(db::AbstractDatabase, id; retry::Bool = false)
    lock(db.faillock)
    items = FailedItem[]
    try
        for rec in db.writefailures, it in rec.items
            _id_matches(it, id) && push!(items, it)
        end
        isempty(items) && return false
        _remove_failures!(db, it -> _id_matches(it, id))
    finally
        unlock(db.faillock)
    end
    retry && _retry_failed_items(db, items)
    return true
end

"""
    clear_write_failures!(db) -> Nothing

Acknowledge and remove every quarantined write.
"""
function clear_write_failures!(db::AbstractDatabase)
    lock(db.faillock)
    try
        empty!(db.writefailures)
        empty!(db.failedkeys)
    finally
        unlock(db.faillock)
    end
    return nothing
end

"""
    clear_read_failures!(db) -> Nothing

Clear the read-failure history.
"""
function clear_read_failures!(db::AbstractDatabase)
    lock(db.faillock)
    try
        empty!(db.readfailures)
    finally
        unlock(db.faillock)
    end
    return nothing
end

# Remove the matching items from every record (dropping empty records) and
# rebuild the key index. The caller holds `faillock`.
function _remove_failures!(db::AbstractDatabase, pred::Function)
    kept = FailureRecord[]
    for rec in db.writefailures
        items = FailedItem[it for it in rec.items if !pred(it)]
        isempty(items) || push!(kept, FailureRecord(rec.sequence, rec.error,
                                                     rec.time, items))
    end
    empty!(db.writefailures)
    append!(db.writefailures, kept)
    empty!(db.failedkeys)
    for (i, rec) in enumerate(db.writefailures), it in rec.items
        db.failedkeys[_item_key(it)] = i
    end
    return nothing
end

# Re-stage the current in-memory value of each failed item. This runs outside
# the failure lock; each call goes through the normal writer staging path.
function _retry_failed_items(db::AbstractDatabase, items::Vector{FailedItem})
    for it in items
        obj = it.object
        if it.kind === :form && obj isa VolatileForm
            _register!(obj, obj[])
        elseif it.kind === :actor && obj isa ActorForm
            _register_actor!(obj, obj[])
        elseif it.kind === :stream && obj isa StreamForm
            _register_stream!(obj)
        elseif it.kind === :extern && obj isa ExternHandle && obj.id !== nothing
            (obj.db === nothing) && (obj.db = db)
            if obj.loaded
                _await_capacity(db)       # before taking the extern lock
                _without_capacity() do
                    _rw_read(obj.lock) do
                        _stage_resource!(obj.db, obj.type, obj.id::Symbol,
                                         _serialize_resource(obj);
                                         metadata = _metavalue(obj), handle = obj)
                    end
                end
            end
        elseif it.kind === :promise && obj isa PromiseForm
            if isfailed(obj)
                try
                    obj[]
                catch e
                    (e isa Air.PromiseFailed) &&
                        _register_promise_failure!(obj, e.err)
                end
            elseif isready(obj)
                _register_promise!(obj, obj[])
            else
                meta = _metavalue(obj)
                _stage!(b -> (b.promise_ensure[obj.id] = meta), db.writeactor, db)
            end
        elseif it.kind === :name
            name = String(it.id)
            names = db.names[]
            if haskey(names, name)
                _register_name!(db, name, names[name].id)
            else
                _unregister_name!(db, name)
            end
        elseif it.write isa PendingMetadata
            pm = it.write
            cur = obj === nothing ? pm.metadata : metadata(obj)
            _stage_metadata!(pm.kind, pm.id, cur, db)
        elseif it.write isa PendingPromise
            pp = it.write
            _stage!(b -> (b.promise_settlements[pp.id] = pp), db.writeactor, db)
        elseif it.write isa PendingResource
            pr = it.write
            _stage_resource!(db, pr.type, pr.id, pr.data; metadata = pr.metadata)
        else
            throw(ArgumentError("no in-memory value is available to retry $it"))
        end
    end
    return nothing
end

export FailedItem, FailureRecord, ReadFailure, FailedObjectError,
    write_failures, failed, clear_write_failure!, clear_write_failures!,
    read_failures, clear_read_failures!
