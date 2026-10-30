################################################################################
# actor.jl
#
# The write path. Every database has one Air `Actor` that owns the writer
# connection; committed updates are sent to it and written in commit order.
#
# One message is sent per committed Air transaction, carrying every form it
# changed and every name it registered, so a commit lands in the database as a
# single atomic write. The trick is that the message's function captures a
# mutable batch that later writes in the same transaction append to; the actor
# only ever sees it after the transaction commits, by which point it holds the
# final contents.
#
# Retry safety: Air's `tx_clear!` empties the transaction's actor table at the
# start of every attempt (Air `src/TX.jl:616-622`), so `actor in currtx().actors`
# is false on the first write of each attempt and a fresh batch is built. The
# previous attempt's staged message was discarded with its actor data and never
# runs.
#
# MIT License
# Copyright (c) 2020-2026 Noah C. Benson

# One form changed within a commit, and the committed snapshot of it.
struct AccumulatedUpdate
    vf::VolatileForm
    form::Form
    metadata::Union{Nothing,Form}
    history::Bool
end

# A resource's bytes, queued by a read-edit operation. `handle` is the live
# extern handle when one is known, so the writer can mark its row present.
struct PendingResource
    type::Symbol
    id::Symbol
    data::Vector{UInt8}
    metadata::Union{Nothing,Form}
    handle::Union{Nothing,ExternHandle}
end

# One actor value, queued by the actor's post-processor.
struct AccumulatedActor
    af::ActorForm
    value::Form
    history::Bool
    metadata::Union{Nothing,Form}
end

# A promise settlement (delivery or failure), queued by the promise's callback.
struct PendingPromise
    id::UUID
    state::Symbol                 # :delivered | :failed
    payload::Form                 # the value or the error form
    metadata::Union{Nothing,Form}
end

# A stream snapshot, queued by an operation or a reference.
struct PendingStream
    sf::StreamForm
    items::Vector{Form}
    maxsize::Union{Nothing,Int}
    closed::Bool
    metadata::Union{Nothing,Form}
end

# A metadata-only edit, queued by `set_metadata!`. The edit itself is already in
# the object's metadata volatile (Air applies it at commit); this only makes the
# database row follow.
struct PendingMetadata
    kind::Symbol                  # :form | :actor | :promise | :stream | :extern
    id::Any                       # a UUID, or a `(type, id)` pair for externs
    metadata::Union{Nothing,Form}
end

# A name-table operation. Order matters: the last operation for a name wins, so
# `delete_name!` followed by `name_form!` leaves the name registered.
struct NameOp
    op::Symbol                  # :set | :delete
    name::String
    id::Union{Nothing,UUID}     # the form id for :set
end

# The mutable batch a transaction's message carries: the forms it changed, the
# names it registered, the resource bytes it produced, the actor values it
# updated, the promises it referenced or settled, and the metadata-only edits it
# made. Later writes in the same transaction append to it, so the actor sees the
# final contents once the transaction commits.
mutable struct WriteBatch
    forms::Dict{UUID,AccumulatedUpdate}
    nameops::Vector{NameOp}
    resources::Dict{Tuple{Symbol,Symbol},PendingResource}
    streams::Dict{UUID,PendingStream}
    actors::Vector{AccumulatedActor}
    promise_ensure::Dict{UUID,Union{Nothing,Form}}  # create a pending row if absent
    promise_settlements::Dict{UUID,PendingPromise}  # deliver or fail, if pending
    metadata::Vector{PendingMetadata}              # metadata-only edits
end
WriteBatch() = WriteBatch(Dict{UUID,AccumulatedUpdate}(), NameOp[],
                          Dict{Tuple{Symbol,Symbol},PendingResource}(),
                          Dict{UUID,PendingStream}(),
                          AccumulatedActor[],
                          Dict{UUID,Union{Nothing,Form}}(),
                          Dict{UUID,PendingPromise}(), PendingMetadata[])
_batch_empty(b::WriteBatch) =
    isempty(b.forms) && isempty(b.nameops) &&
    isempty(b.resources) && isempty(b.streams) && isempty(b.actors) &&
    isempty(b.promise_ensure) && isempty(b.promise_settlements) && isempty(b.metadata)
_batch_empty!(b::WriteBatch) = (empty!(b.forms); empty!(b.nameops);
                                empty!(b.resources); empty!(b.streams);
                                empty!(b.actors);
                                empty!(b.promise_ensure); empty!(b.promise_settlements);
                                empty!(b.metadata))

# An actor update waiting to reach the database.
struct PendingActor
    af::ActorForm
    value::Form
    history::Bool
    metadata::Union{Nothing,Form}
    txid::Int64
end

# A write waiting to reach the database. The `vf` field is a strong reference, so
# a queued form cannot be collected (and reloaded) while its write is pending.
struct PendingWrite
    vf::VolatileForm
    form::Form
    metadata::Union{Nothing,Form}
    history::Bool
    txid::Int64
end

"""
    FormActorState

The value held by a database's intake `Actor`: the transaction sequence number
and a reference to the database's write pipeline. The actor only enqueues
committed batches; encoding and database writes happen on the pipeline's tasks.
"""
mutable struct FormActorState
    config::DatabaseConfig
    txseq::Int64
    db::Union{Nothing,Database}
end

# The per-task map from writer actor to the batch for the current attempt. It
# lives in task-local storage rather than an Air `Var`, whose `setindex!` is
# disabled and whose mutable default would be shared across tasks.
const _ACC_KEY = :AirDBAccumulators
function _accdict()
    d = task_local_storage()
    a = get(d, _ACC_KEY, nothing)
    (a isa IdDict{Actor,Any}) && return a
    a = IdDict{Actor,Any}()
    task_local_storage(_ACC_KEY, a)
    return a
end

# Add `entry(batch)` to the current transaction's batch for `actor`, or, with no
# transaction, to a fresh batch sent immediately. Inside a transaction the send is
# deferred until commit, so the batch is always complete when the actor sees it;
# with no transaction the entry is added before the send.
#
# `db` is checked first: a poisoned `:abort` database and a closed database must
# reject new writes here, since the intake actor itself stays alive.
function _stage!(add::Function, actor::Actor, db::Union{Nothing,AbstractDatabase} = nothing)
    db === nothing || _check_open(db)
    db === nothing || _check_health(db)
    t = currtx()
    if t === nothing
        (db === nothing || _suppress_capacity()) || _await_capacity(db)
        b = WriteBatch()
        add(b)
        send(a -> _receive!(a, b), actor)
        return nothing
    end
    holder = _accdict()
    # `getfield(t, :actors)` is the transaction's own actor map; the property
    # `t.actors` builds an `IdSet` of its keys on every access.
    if !haskey(getfield(t, :actors), actor)  # first write of this attempt
        (db === nothing || _suppress_capacity()) || _await_capacity(db)
        b = WriteBatch()
        holder[actor] = b
        send(a -> _receive!(a, b), actor)    # dispatched only on commit
    end
    add(holder[actor]::WriteBatch)
    return nothing
end

# Arrange for `form` — the value `vf` was just set to — to reach the database when
# the current transaction commits (or immediately, if there is no transaction).
function _register!(vf::VolatileForm, form::Form)
    u = AccumulatedUpdate(vf, form, _metavalue(vf), vf.history)
    _stage!(b -> (b.forms[vf.id] = u), vf.db.writeactor, vf.db)
    return form
end

# Arrange for the name `name` to point at the form `id` once the current
# transaction commits (or immediately).
function _register_name!(db::AbstractDatabase, name::AbstractString, id::UUID)
    key = String(name)
    _stage!(b -> push!(b.nameops, NameOp(:set, key, id)), db.writeactor, db)
    return nothing
end

# Arrange for the name `name` to be removed once the current transaction commits
# (or immediately).
function _unregister_name!(db::AbstractDatabase, name::AbstractString)
    key = String(name)
    _stage!(b -> push!(b.nameops, NameOp(:delete, key, nothing)), db.writeactor, db)
    return nothing
end

# Queue a read-edited resource's bytes. The bytes are captured by the caller
# while it holds the resource's write lock.
function _stage_resource!(db::AbstractDatabase, type::Symbol, id::Symbol,
                          data::Vector{UInt8}; metadata = nothing, handle = nothing)
    pr = PendingResource(type, id, data, metadata, handle)
    _stage!(b -> (b.resources[(type, id)] = pr), db.writeactor, db)
    return nothing
end

# A metadata-only edit: no payload rewrite, no version bump, no history row. The
# in-memory edit is already in the metadata volatile; this queues the row update.
function _stage_metadata!(kind::Symbol, id, metadata, db::AbstractDatabase)
    pm = PendingMetadata(kind, id, metadata)
    _stage!(b -> push!(b.metadata, pm), db.writeactor, db)
    return nothing
end

# The actor's side: take a committed batch and hand it to the write pipeline.
# Nothing is encoded here, so the intake stays fast and never blocks on a slow
# form, extern, or stream.
function _receive!(st::FormActorState, b::WriteBatch)
    _batch_empty(b) && return st
    txid = (st.txseq += 1)
    pipe = st.db === nothing ? nothing : st.db.pipeline
    pipe === nothing || _enqueue_batch!(pipe, b, txid)
    return st
end

# A promise row that was referenced but not settled; kept so a quarantined batch
# can be inspected and retried.
struct PendingPromiseEnsure
    id::UUID
    metadata::Union{Nothing,Form}
end

# The live object behind a queued key, if it is still cached.
function _live_object(db, kind::Symbol, id)
    db === nothing && return nothing
    if kind === :extern
        (id isa Tuple && length(id) == 2) || return nothing
        lock(_EXTERN_HANDLES_LOCK)
        try
            wr = get(_EXTERN_HANDLES, id, nothing)
            return wr === nothing ? nothing : wr.value
        finally
            unlock(_EXTERN_HANDLES_LOCK)
        end
    end
    id isa UUID || return nothing
    cache = kind === :form ? db.cache :
            kind === :actor ? db.actorcache :
            kind === :promise ? db.promisecache :
            kind === :stream ? db.streamcache : nothing
    cache === nothing && return nothing
    lock(db.cachelock)
    try
        wr = get(cache, id, nothing)
        return wr === nothing ? nothing : wr.value
    finally
        unlock(db.cachelock)
    end
end

# Everything a batch needs, encoded and ready to write. Produced by
# `_prepare_batch!` on an encoder task and consumed by `_write_prepared!` on the
# writer task, so encoding and database I/O never share a task.
struct PreparedBatch
    payloads::Vector{String}
    form_metas::Vector{Union{Missing,String}}
    actor_payloads::Vector{String}
    actor_metas::Vector{Union{Missing,String}}
    metadata_params::Vector{Union{Missing,String}}
    settlement_payloads::Dict{UUID,String}
    stream_rows::Dict{UUID,NTuple{4,Any}}
    resource_rows::Dict{Tuple{Symbol,Symbol},NTuple{2,Any}}
    resource_handles::Dict{Tuple{Symbol,Symbol},ExternHandle}
    ensure_metas::Dict{UUID,Union{Missing,String}}
end

# Encode a batch's forms, metadata, actor values, promise payloads, streams, and
# extern bytes. All encoding happens inside one `_collecting!` region, so every
# object referenced from any of them is recorded before the rows are written.
function _prepare_batch!(db, pending::Vector{PendingWrite},
                         queued::Dict{Tuple{Symbol,Symbol},PendingResource},
                         queued_streams::Dict{UUID,PendingStream},
                         actors::Vector{PendingActor},
                         promise_ensure::Dict{UUID,Union{Nothing,Form}},
                         promise_settlements::Dict{UUID,PendingPromise},
                         metadata_updates::Vector{PendingMetadata})
    # All encoding happens inside one `_collecting!` region: form payloads,
    # metadata (of every kind), actor values, promise payloads, stream items, and
    # the metadata of resources and streams. Encoding records every extern,
    # promise, and stream referenced from any of them, so their rows are written
    # before the rows that name them. The notes live only inside this region, so
    # an unrelated `to_JSON` on a long-lived task leaves no strong references
    # behind.
    refs = _refset()
    empty!(refs)
    prefs = _promise_refs()
    empty!(prefs)
    srefs = _stream_refs()
    empty!(srefs)
    payloads = String[]
    form_metas = Union{Missing,String}[]
    actor_payloads = String[]
    actor_metas = Union{Missing,String}[]
    metadata_params = Union{Missing,String}[]
    settlement_payloads = Dict{UUID,String}()
    # LibPQ sends `missing` as SQL NULL; `nothing` would be encoded as a string.
    # Each stream entry is `(items-json, maxsize, closed, metadata-param)`;
    # each resource entry is `(bytes, metadata-param)`; each ensure entry is its
    # metadata parameter.
    stream_rows = Dict{UUID,NTuple{4,Any}}()
    resource_rows = Dict{Tuple{Symbol,Symbol},NTuple{2,Any}}()
    resource_handles = Dict{Tuple{Symbol,Symbol},ExternHandle}()
    ensure_metas = Dict{UUID,Union{Missing,String}}()
    # Stream snapshots: the queued ones, plus every stream named by any encoded
    # value or by another stream's queued items. Encoding the items can name more
    # streams, so this runs to a fixed point.
    streams = Dict{UUID,PendingStream}(queued_streams)
    try
        _collecting!() do
            for pw in pending
                push!(payloads, to_JSON(pw.form))
                push!(form_metas, _metadata_param(pw.metadata))
            end
            for pa in actors
                push!(actor_payloads, to_JSON(pa.value))
                push!(actor_metas, _metadata_param(pa.metadata))
            end
            for pm in metadata_updates
                push!(metadata_params, _metadata_param(pm.metadata))
            end
            for (id, pp) in promise_settlements
                settlement_payloads[id] = to_JSON(pp.payload)
            end
            for (id, ps) in streams
                stream_rows[id] = (_encode_stream_items(ps.items), ps.maxsize,
                                   ps.closed, _metadata_param(ps.metadata))
            end
            while true
                todo = Any[sf for sf in keys(srefs)
                           if sf isa StreamForm && !haskey(stream_rows, sf.id)]
                isempty(todo) && break
                for sf in todo
                    sf.loaded || load!(sf)
                    inner = sf.stream::Air.Stream{Form}
                    ps = PendingStream(sf, snapshot(inner), maxsize(inner),
                                       !isopen(inner), _metavalue(sf))
                    streams[sf.id] = ps
                    stream_rows[sf.id] = (_encode_stream_items(ps.items), ps.maxsize,
                                          ps.closed, _metadata_param(ps.metadata))
                end
            end
            # A resource's bytes are captured under its lock. A handle whose row
            # already exists needs no serialization: the form only names it, and
            # any later edit writes its own ordered resource batch.
            for (k, pr) in queued
                resource_rows[k] = (pr.data, _metadata_param(pr.metadata))
                pr.handle === nothing || (resource_handles[k] = pr.handle)
            end
            for h in keys(refs)
                h isa ExternHandle || continue
                # A constructed handle learns its database the first time a form
                # that names it is written, so later read-edits know where to
                # sync.
                (h.db === nothing && db !== nothing) && setfield!(h, :db, db)
                # A rehydrated handle's bytes are the row it came from; a stored
                # handle's row already exists. Only a never-stored, loaded handle
                # has bytes to queue.
                h.loaded || continue
                h.present && continue
                key = (h.type, h.id::Symbol)
                haskey(resource_rows, key) && continue
                _rw_read(h.lock) do
                    resource_rows[key] = (_serialize_resource(h),
                                          _metadata_param(_metavalue(h)))
                end
                resource_handles[key] = h
            end
            # Every settlement ensures its own row, so a delivery to a promise
            # that was never stored is not lost (and carries its owner metadata).
            for (id, meta) in promise_ensure
                ensure_metas[id] = _metadata_param(meta)
            end
            for pf in keys(prefs)
                pf isa PromiseForm &&
                    (ensure_metas[pf.id] = _metadata_param(_metavalue(pf)))
            end
            for (id, pp) in promise_settlements
                ensure_metas[id] = _metadata_param(pp.metadata)
            end
            return nothing
        end
    finally
        empty!(refs)
        empty!(prefs)
        empty!(srefs)
    end
    return PreparedBatch(payloads, form_metas, actor_payloads, actor_metas,
                         metadata_params, settlement_payloads, stream_rows,
                         resource_rows, resource_handles, ensure_metas)
end

_metadata_param(m::Nothing) = missing
_metadata_param(m::Form) = to_JSON(m)

# Apply a metadata-only edit to the row of the object it belongs to. A row that
# does not exist is simply untouched (an unpersisted extern, a dead extern). The
# metadata parameter is precomputed inside the batch's collection region.
function _apply_metadata!(conn, pm::PendingMetadata, meta)
    if pm.kind === :form
        LibPQ.execute(conn, _UPDATE_FORM_METADATA_SQL, (string(pm.id), meta))
    elseif pm.kind === :actor
        LibPQ.execute(conn, _UPDATE_ACTOR_METADATA_SQL, (string(pm.id), meta))
    elseif pm.kind === :promise
        LibPQ.execute(conn, _UPDATE_PROMISE_METADATA_SQL, (string(pm.id), meta))
    elseif pm.kind === :stream
        LibPQ.execute(conn, _UPDATE_STREAM_METADATA_SQL, (string(pm.id), meta))
    elseif pm.kind === :extern
        (t, i) = pm.id
        LibPQ.execute(conn, _UPDATE_RESOURCE_METADATA_SQL,
                      (string(t), string(i), meta))
    else
        error("unknown metadata kind $(pm.kind)")
    end
    return nothing
end
