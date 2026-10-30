################################################################################
# pipeline.jl
#
# The write pipeline. An Air `Actor` receives one committed `WriteBatch` per
# transaction and only enqueues it; a pool of encoder tasks turns batches into
# `PreparedBatch`es (all the expensive `to_JSON`, `serialize`, and snapshot work),
# and one ordered writer task owns the PostgreSQL connection and writes prepared
# batches in commit order. Encoding and database I/O therefore never share a
# task, and a slow form or extern no longer stalls the writer's intake.
#
# The ordering invariant: a batch may be encoded any time after it is enqueued
# and before it is written. For any mutable value carried by a later-ordered
# write, the mutation happens before its batch is enqueued, so an earlier batch's
# encoder sees it; a later batch's write follows and wins.
#
# MIT License
# Copyright (c) 2020-2026 Noah C. Benson

# One committed transaction waiting to be encoded and written. The queues are
# moved out of the committing task's `WriteBatch` so that task does not pin them.
mutable struct BatchEntry
    seq::Int
    txid::Int64
    pending::Vector{PendingWrite}
    nameops::Vector{NameOp}
    resources::Dict{Tuple{Symbol,Symbol},PendingResource}
    streams::Dict{UUID,PendingStream}
    actors::Vector{PendingActor}
    promise_ensure::Dict{UUID,Union{Nothing,Form}}
    promise_settlements::Dict{UUID,PendingPromise}
    metadata::Vector{PendingMetadata}
    state::Symbol                  # :queued | :encoding | :encoded | :failed
    prepared::Union{Nothing,PreparedBatch}
    error::Union{Nothing,Exception}
end

# Ordered jobs that must be processed by the writer between batches.
struct BarrierEntry
    done::Channel{Any}
end

struct GCEntry
    dry_run::Bool
    batchsize::Int
    t0::Float64
    done::Channel{Any}
end

struct CloseEntry
    done::Channel{Any}
end

mutable struct WritePipeline <: AbstractWritePipeline
    lock::ReentrantLock
    cond::Threads.Condition
    entries::Dict{Int,Any}
    claims::Vector{Int}
    head::Int
    nextseq::Int
    unwritten::Int                 # committed-but-unwritten batches
    pendingitems::Int              # forms + name operations not yet written
    flush_due::Bool
    stop::Bool
    conn::LibPQ.Connection
    db::Database
    last_error::Union{Nothing,Exception}
    encoders::Vector{Task}
    writer::Union{Nothing,Task}
end

function _start_pipeline!(db::Database, conn, txseq::Integer)
    lk = ReentrantLock()
    pipe = WritePipeline(lk, Threads.Condition(lk), Dict{Int,Any}(), Int[],
                         1, 1, 0, 0, false, false, conn, db, nothing, Task[], nothing)
    n = max(1, db.config.encoder_tasks)
    pipe.encoders = Task[Threads.@spawn _encode_loop!(pipe) for _ in 1:n]
    pipe.writer = Threads.@spawn _write_loop!(pipe)
    return pipe
end

# The writer connection, for tests and diagnostics.
function _writer_conn(db::Database)
    pipe = db.pipeline
    pipe === nothing && throw(ArgumentError("the database has no write pipeline"))
    return (pipe::WritePipeline).conn
end

# The signal a stopped pipeline gives to a waiting barrier/GC/close job.
struct PipelineStop
    ex::Exception
end

# ---- backpressure ------------------------------------------------------------

# A committing thread waits before starting a new batch when the writer's backlog
# is at the configured bound. Waiting reserves nothing, so an aborted transaction
# leaks no capacity; overshoot is bounded by the number of concurrent writers.
_await_capacity(::AbstractDatabase) = nothing

function _await_capacity(db::Database)
    pipe = db.pipeline
    pipe === nothing && return nothing
    lock(pipe.lock)
    try
        while !pipe.stop && pipe.unwritten >= db.config.max_pending
            wait(pipe.cond)
        end
    finally
        unlock(pipe.lock)
    end
    db.failure === nothing || throw(db.failure)
    return nothing
end

# Some staging paths run under an extern read/write lock or in Air's finalize
# phase; waiting there would deadlock or block a committing transaction, so they
# suppress the capacity wait. `_run_reserve` checks capacity before taking locks
# instead.
const _SUPPRESS_CAPACITY_KEY = :AirDBSuppressCapacity
_suppress_capacity() =
    get(task_local_storage(), _SUPPRESS_CAPACITY_KEY, false) === true
function _without_capacity(f::Function)
    task_local_storage(_SUPPRESS_CAPACITY_KEY, true)
    try
        return f()
    finally
        task_local_storage(_SUPPRESS_CAPACITY_KEY, false)
    end
end

# ---- intake ------------------------------------------------------------------

# Move a committed batch into a pipeline entry and reset the batch's containers
# so the committing task's task-local holder does not pin them.
function _enqueue_batch!(pipe::WritePipeline, b::WriteBatch, txid::Int64)
    pending = PendingWrite[PendingWrite(u.vf, u.form, u.metadata, u.history, txid)
                           for u in values(b.forms)]
    actors = PendingActor[PendingActor(a.af, a.value, a.history, a.metadata, txid)
                          for a in b.actors]
    lock(pipe.lock)
    try
        pipe.stop && return nothing
        seq = pipe.nextseq
        pipe.nextseq += 1
        entry = BatchEntry(seq, txid, pending, b.nameops, b.resources, b.streams,
                           actors, b.promise_ensure, b.promise_settlements,
                           b.metadata, :queued, nothing, nothing)
        pipe.entries[seq] = entry
        push!(pipe.claims, seq)
        pipe.unwritten += 1
        pipe.pendingitems += length(pending) + length(b.nameops)
        if pipe.pendingitems >= pipe.db.config.max_batch
            pipe.flush_due = true
        end
        notify(pipe.cond; all = true)
        # Detach the moved containers from the committing task's batch.
        b.forms = Dict{UUID,AccumulatedUpdate}()
        b.nameops = NameOp[]
        b.resources = Dict{Tuple{Symbol,Symbol},PendingResource}()
        b.streams = Dict{UUID,PendingStream}()
        b.actors = AccumulatedActor[]
        b.promise_ensure = Dict{UUID,Union{Nothing,Form}}()
        b.promise_settlements = Dict{UUID,PendingPromise}()
        b.metadata = PendingMetadata[]
        return nothing
    finally
        unlock(pipe.lock)
    end
end

# Enqueue an ordered job (barrier, GC, close). If the pipeline has stopped, the
# job's channel is completed immediately with the stop reason.
function _enqueue_entry!(pipe::WritePipeline, entry)
    lock(pipe.lock)
    try
        if pipe.stop
            put!(entry.done, _stop_reason(pipe))
            return nothing
        end
        seq = pipe.nextseq
        pipe.nextseq += 1
        pipe.entries[seq] = entry
        notify(pipe.cond; all = true)
        return nothing
    finally
        unlock(pipe.lock)
    end
end

_stop_reason(pipe::WritePipeline) =
    PipelineStop(pipe.db.failure !== nothing ? pipe.db.failure :
                 ArgumentError("the database is closed"))

# ---- encoding ----------------------------------------------------------------

function _claim_batch!(pipe::WritePipeline)
    lock(pipe.lock)
    try
        while true
            if !isempty(pipe.claims)
                seq = pop!(pipe.claims)
                entry = pipe.entries[seq]::BatchEntry
                entry.state = :encoding
                return entry
            end
            pipe.stop && return nothing
            wait(pipe.cond)
        end
    finally
        unlock(pipe.lock)
    end
end

function _encode_loop!(pipe::WritePipeline)
    entry = nothing
    prep = nothing
    while true
        entry = _claim_batch!(pipe)
        entry === nothing && return nothing
        try
            prep = _prepare_batch!(pipe.db, entry.pending, entry.resources,
                                   entry.streams, entry.actors,
                                   entry.promise_ensure, entry.promise_settlements,
                                   entry.metadata)
            lock(pipe.lock)
            try
                entry.prepared = prep
                entry.state = :encoded
                notify(pipe.cond; all = true)
            finally
                unlock(pipe.lock)
            end
        catch err
            lock(pipe.lock)
            try
                entry.error = err
                entry.state = :failed
                notify(pipe.cond; all = true)
            finally
                unlock(pipe.lock)
            end
        end
        # Drop this task's strong references before waiting for the next batch.
        entry = nothing
        prep = nothing
    end
end

# ---- writer ------------------------------------------------------------------

function _has_job_at_or_after(pipe::WritePipeline)
    for k in keys(pipe.entries)
        (k >= pipe.head && !(pipe.entries[k] isa BatchEntry)) && return true
    end
    return false
end

# Block until the writer has work it can act on. Returns `(:batch, group)` for a
# contiguous run of batch entries, or `(:barrier, entry)`, `(:gc, entry)`,
# `(:close, entry)`, or `:stop`.
function _next_job!(pipe::WritePipeline)
    lock(pipe.lock)
    try
        while true
            pipe.stop && return :stop
            if !haskey(pipe.entries, pipe.head)
                wait(pipe.cond)
                continue
            end
            entry = pipe.entries[pipe.head]
            if entry isa BarrierEntry
                delete!(pipe.entries, pipe.head)
                pipe.head += 1
                return (:barrier, entry)
            elseif entry isa GCEntry
                delete!(pipe.entries, pipe.head)
                pipe.head += 1
                return (:gc, entry)
            elseif entry isa CloseEntry
                delete!(pipe.entries, pipe.head)
                pipe.head += 1
                return (:close, entry)
            end
            # A batch. With batching enabled, wait for the threshold or for an
            # ordered job that must not pass it.
            if !pipe.flush_due && !_has_job_at_or_after(pipe)
                wait(pipe.cond)
                continue
            end
            group = BatchEntry[]
            s = pipe.head
            while true
                haskey(pipe.entries, s) || break
                e = pipe.entries[s]
                e isa BatchEntry || break
                while e.state !== :encoded && e.state !== :failed
                    pipe.stop && return :stop
                    wait(pipe.cond)
                end
                push!(group, e)
                s += 1
            end
            pipe.flush_due = false
            return (:batch, group)
        end
    finally
        unlock(pipe.lock)
    end
end

function _retire_group!(pipe::WritePipeline, group::Vector{BatchEntry})
    isempty(group) && return nothing
    lock(pipe.lock)
    try
        for e in group
            haskey(pipe.entries, e.seq) && delete!(pipe.entries, e.seq)
            pipe.unwritten -= 1
            pipe.pendingitems -= length(e.pending) + length(e.nameops)
            # Release the strong references the entry carried. A task's stack can
            # retain a stale pointer to the entry or to a group vector, so the
            # entry's containers are emptied rather than only dropped.
            empty!(e.pending)
            empty!(e.nameops)
            empty!(e.resources)
            empty!(e.streams)
            empty!(e.actors)
            empty!(e.promise_ensure)
            empty!(e.promise_settlements)
            empty!(e.metadata)
            # A precondition for this: `PreparedBatch.resource_handles` keeps the
            # live handles alive, so drop them too.
            e.prepared === nothing || empty!((e.prepared::PreparedBatch).resource_handles)
            e.prepared = nothing
            e.error = nothing
        end
        pipe.head = maximum(e.seq for e in group) + 1
        notify(pipe.cond; all = true)
    finally
        unlock(pipe.lock)
    end
    return nothing
end

function _failed_items_from_entry(entry::BatchEntry, db)
    out = FailedItem[]
    for pw in entry.pending
        push!(out, FailedItem(:form, pw.vf.id, pw.vf, pw))
    end
    for pa in entry.actors
        push!(out, FailedItem(:actor, pa.af.id, pa.af, pa))
    end
    for ps in values(entry.streams)
        push!(out, FailedItem(:stream, ps.sf.id, ps.sf, ps))
    end
    for (k, pr) in entry.resources
        push!(out, FailedItem(:extern, k, _live_object(db, :extern, k), pr))
    end
    for (id, meta) in entry.promise_ensure
        push!(out, FailedItem(:promise, id, _live_object(db, :promise, id),
                              PendingPromiseEnsure(id, meta)))
    end
    for (id, pp) in entry.promise_settlements
        push!(out, FailedItem(:promise, id, _live_object(db, :promise, id), pp))
    end
    for pm in entry.metadata
        push!(out, FailedItem(pm.kind, pm.id, _live_object(db, pm.kind, pm.id), pm))
    end
    for no in entry.nameops
        push!(out, FailedItem(:name, no.name, nothing, no))
    end
    return out
end

function _entry_keys(entry::BatchEntry)
    out = Any[]
    for pw in entry.pending
        push!(out, (:form, pw.vf.id))
    end
    for pa in entry.actors
        push!(out, (:actor, pa.af.id))
    end
    for ps in values(entry.streams)
        push!(out, (:stream, ps.sf.id))
    end
    for k in keys(entry.resources)
        push!(out, (:extern, k))
    end
    for id in keys(entry.promise_ensure)
        push!(out, (:promise, id))
    end
    for id in keys(entry.promise_settlements)
        push!(out, (:promise, id))
    end
    for pm in entry.metadata
        push!(out, pm.kind === :extern ? (:extern, pm.id) : (pm.kind, pm.id))
    end
    for no in entry.nameops
        push!(out, (:name, no.name))
    end
    return out
end

# Write a group of prepared entries in one database transaction.
function _write_group!(conn, entries::Vector{BatchEntry})
    LibPQ.execute(conn, "BEGIN")
    try
        for e in entries
            prep = e.prepared::PreparedBatch
            for (id, row) in prep.stream_rows
                LibPQ.execute(conn, _UPSERT_STREAM_SQL,
                              (string(id), row[1],
                               row[2] === nothing ? missing : row[2], row[3], row[4]))
            end
            for (key, row) in prep.resource_rows
                LibPQ.execute(conn, _UPSERT_RESOURCE_SQL,
                              (string(key[1]), string(key[2]),
                               "\\x" * bytes2hex(row[1]), row[2]))
            end
            for (id, meta) in prep.ensure_metas
                LibPQ.execute(conn, _INSERT_PROMISE_SQL, (string(id), meta))
            end
            for (i, pa) in enumerate(e.actors)
                params = pa.history ?
                    (string(pa.af.id), prep.actor_payloads[i], pa.history,
                     prep.actor_metas[i], pa.txid) :
                    (string(pa.af.id), prep.actor_payloads[i], pa.history,
                     prep.actor_metas[i])
                LibPQ.execute(conn,
                              pa.history ? _UPSERT_ACTOR_SQL : _UPSERT_ACTOR_CURRENT_SQL,
                              params)
            end
            for i in eachindex(e.pending)
                pw = e.pending[i]
                params = pw.history ?
                    (string(pw.vf.id), prep.payloads[i], prep.form_metas[i],
                     pw.history, pw.txid) :
                    (string(pw.vf.id), prep.payloads[i], prep.form_metas[i],
                     pw.history)
                LibPQ.execute(conn, pw.history ? _UPSERT_SQL : _UPSERT_CURRENT_SQL,
                              params)
            end
            for (id, pp) in e.promise_settlements
                sql = pp.state === :delivered ? _DELIVER_PROMISE_SQL : _FAIL_PROMISE_SQL
                r = LibPQ.execute(conn, sql, (string(id), prep.settlement_payloads[id]))
                isempty(r) &&
                    @debug "promise settlement matched no pending row" id pp.state
            end
            for (i, pm) in enumerate(e.metadata)
                _apply_metadata!(conn, pm, prep.metadata_params[i])
            end
        end
        # Name operations across the whole group: the last operation per name wins.
        resolved = Dict{String,NameOp}()
        for e in entries, no in e.nameops
            resolved[no.name] = no
        end
        for no in values(resolved)
            if no.op === :set
                LibPQ.execute(conn, _UPSERT_NAME_SQL, (no.name, string(no.id::UUID)))
            else
                LibPQ.execute(conn, _DELETE_NAME_SQL, (no.name,))
            end
        end
        LibPQ.execute(conn, "COMMIT")
        for e in entries, h in values((e.prepared::PreparedBatch).resource_handles)
            h.present = true
        end
    catch
        try
            LibPQ.execute(conn, "ROLLBACK")
        catch
        end
        rethrow()
    end
    return nothing
end

function _reconnect_pipeline!(pipe::WritePipeline)
    try
        close(pipe.conn)
    catch
    end
    try
        pipe.conn = LibPQ.Connection(_conninfo(pipe.db.config))
    catch
    end
    return nothing
end

# Mark a group's writes as quarantined (or poison the database under :abort).
function _quarantine_or_poison!(pipe::WritePipeline, group::Vector{BatchEntry},
                                err::Exception)
    db = pipe.db
    pipe.last_error = err
    items = FailedItem[]
    for e in group
        append!(items, _failed_items_from_entry(e, db))
    end
    seq = isempty(group) ? 0 : maximum(e.txid for e in group)
    _record_write_failure!(db, seq, err, items)
    if db.config.failure === :abort
        db.failure = DatabaseError(err, _pending_items(pipe))
        lock(pipe.lock)
        try
            pipe.stop = true
            for ent in values(pipe.entries)
                (ent isa BarrierEntry || ent isa GCEntry || ent isa CloseEntry) &&
                    put!(ent.done, PipelineStop(db.failure))
            end
            notify(pipe.cond; all = true)
        finally
            unlock(pipe.lock)
        end
        return :poison
    end
    _reconnect_pipeline!(pipe)
    return :quarantine
end

function _write_group_step!(pipe::WritePipeline, group::Vector{BatchEntry})
    db = pipe.db
    poisoned = false
    # Encoding failures are quarantined (or poison under :abort).
    for e in group
        if e.state === :failed
            (_quarantine_or_poison!(pipe, [e], e.error) === :poison) && (poisoned = true)
        end
    end
    ok = BatchEntry[e for e in group if e.state === :encoded]
    if !poisoned && !isempty(ok)
        attempt = 0
        t0 = time()
        delay = db.config.retry_delay
        while true
            try
                _write_group!(pipe.conn, ok)
                txid = Int(maximum(e.txid for e in ok))
                keys = Any[]
                for e in ok
                    append!(keys, _entry_keys(e))
                    for pw in e.pending
                        pw.vf.persisted = true
                    end
                end
                _mark_write_success!(db, keys, txid)
                break
            catch e
                pipe.last_error = e
                attempt += 1
                if !_decide_retry(db, e, attempt, time() - t0)
                    (_quarantine_or_poison!(pipe, ok, e) === :poison) && (poisoned = true)
                    break
                end
                _reconnect_pipeline!(pipe)
                sleep(delay)
                delay = _next_delay(delay, db.config)
            end
        end
    end
    poisoned || _retire_group!(pipe, group)
    return nothing
end

function _write_loop!(pipe::WritePipeline)
    job = nothing
    while true
        job = _next_job!(pipe)
        job === :stop && return nothing
        kind, entry = job
        if kind === :barrier
            put!(entry.done, nothing)
        elseif kind === :gc
            db = pipe.db
            res = try
                _gc_database!(db, pipe.conn, entry.dry_run, entry.batchsize, entry.t0)
            catch e
                CapturedException(e, catch_backtrace())
            end
            put!(entry.done, res)
        elseif kind === :close
            lock(pipe.lock)
            try
                pipe.stop = true
                notify(pipe.cond; all = true)
            finally
                unlock(pipe.lock)
            end
            try
                close(pipe.conn)
            catch
            end
            put!(entry.done, nothing)
            return nothing
        else
            _write_group_step!(pipe, entry)
        end
        # Drop this task's strong references before waiting for the next job.
        job = nothing
        kind = nothing
        entry = nothing
    end
end

# ---- public plumbing ---------------------------------------------------------

_pipeline_pending_items(pipe::WritePipeline) = pipe.pendingitems

function _pending_items(pipe::WritePipeline)
    out = Any[]
    for e in values(pipe.entries)
        e isa BatchEntry || continue
        append!(out, e.pending)
        append!(out, e.actors)
        append!(out, e.nameops)
        append!(out, collect(values(e.resources)))
        append!(out, collect(values(e.streams)))
        append!(out, collect(values(e.promise_ensure)))
        append!(out, collect(values(e.promise_settlements)))
        append!(out, e.metadata)
    end
    return out
end

function _queue_barrier!(db)
    pipe = db.pipeline
    ch = Channel{Any}(1)
    send(db.writeactor) do st
        _enqueue_entry!(pipe, BarrierEntry(ch))
        return st
    end
    res = take!(ch)
    res isa PipelineStop && throw(res.ex)
    return nothing
end

function _queue_gc!(db, dry_run, batchsize, t0)
    pipe = db.pipeline
    ch = Channel{Any}(1)
    send(db.writeactor) do st
        _enqueue_entry!(pipe, GCEntry(dry_run, batchsize, t0, ch))
        return st
    end
    res = take!(ch)
    res isa PipelineStop && throw(res.ex)
    res isa CapturedException && throw(res.ex)
    return res::GCStats
end

function _queue_close!(db)
    pipe = db.pipeline
    ch = Channel{Any}(1)
    try
        send(db.writeactor) do st
            _enqueue_entry!(pipe, CloseEntry(ch))
            return st
        end
        take!(ch)
    catch
    end
    for e in pipe.encoders
        try
            wait(e)
        catch
        end
    end
    try
        wait(pipe.writer)
    catch
    end
    try
        close(pipe.conn)
    catch
    end
    return nothing
end
