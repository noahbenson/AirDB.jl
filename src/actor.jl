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
end

# The mutable batch a transaction's message carries: the forms it changed and the
# names it registered. Later writes in the same transaction append to it, so the
# actor sees the final contents once the transaction commits.
mutable struct WriteBatch
    forms::Dict{UUID,AccumulatedUpdate}
    names::Dict{String,UUID}
end
WriteBatch() = WriteBatch(Dict{UUID,AccumulatedUpdate}(), Dict{String,UUID}())
_batch_empty(b::WriteBatch) = isempty(b.forms) && isempty(b.names)
_batch_empty!(b::WriteBatch) = (empty!(b.forms); empty!(b.names))

# A write waiting to reach the database. The `vf` field is a strong reference, so
# a queued form cannot be collected (and reloaded) while its write is pending.
struct PendingWrite
    vf::VolatileForm
    form::Form
    txid::Int64
end

# A name registration waiting to reach the database.
struct PendingName
    name::String
    id::UUID
end

"""
    FormActorState

The value held by a database's writer `Actor`. It owns the writer connection, the
queues of updates and name registrations not yet written, and the running
transaction id. Holding the queues here (rather than writing immediately) is what
lets a later policy batch several commits into one database transaction; the
strong references in `pending` keep those forms alive until they are written.
"""
mutable struct FormActorState
    config::DatabaseConfig
    conn::LibPQ.Connection
    pending::Vector{PendingWrite}
    names::Vector{PendingName}
    txseq::Int64
    db::Union{Nothing,Database}
    last_error::Union{Nothing,Exception}
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
function _stage!(add::Function, actor::Actor)
    t = currtx()
    if t === nothing
        b = WriteBatch()
        add(b)
        send(a -> _receive!(a, b), actor)
        return nothing
    end
    holder = _accdict()
    if !(actor in t.actors)                 # first write of this attempt
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
    u = AccumulatedUpdate(vf, form)
    _stage!(b -> (b.forms[vf.id] = u), vf.db.writeactor)
    return form
end

# Arrange for the name `name` to point at the form `id` once the current
# transaction commits (or immediately).
function _register_name!(db::AbstractDatabase, name::AbstractString, id::UUID)
    key = String(name)
    _stage!(b -> (b.names[key] = id), db.writeactor)
    return nothing
end

# The actor's side: take a committed batch, queue it, and flush when the queue is
# large enough. Under the default `max_batch == 1` this writes each commit at once.
function _receive!(st::FormActorState, b::WriteBatch)
    _batch_empty(b) && return st
    txid = (st.txseq += 1)
    for u in values(b.forms)
        push!(st.pending, PendingWrite(u.vf, u.form, txid))
    end
    for (name, id) in b.names
        push!(st.names, PendingName(name, id))
    end
    # The updates now live in `pending` (which holds the strong references that
    # keep the forms alive until they are written). Clearing the batch releases
    # the writing task's references, so the weak cache can let a form go once
    # nothing else needs it. The transaction is already committed by the time this
    # runs, so the batch is final.
    _batch_empty!(b)
    (length(st.pending) + length(st.names)) >= st.config.max_batch && _flush!(st)
    return st
end

# Write every queued update and name in one database transaction, retrying per the
# configured policy. If the policy gives up, the queues are kept, the error is
# recorded on the database, and the error is rethrown — which poisons the actor,
# so every later write and read raises.
function _flush!(st::FormActorState)
    (isempty(st.pending) && isempty(st.names)) && return st
    db = st.db
    attempt = 0
    t0 = time()
    delay = st.config.retry_delay
    while true
        try
            _write_batch!(st.conn, st.pending, st.names)
            break
        catch e
            st.last_error = e
            attempt += 1
            if !_decide_retry(db, e, attempt, time() - t0)
                db === nothing ||
                    (db.failure = DatabaseError(e, Any[pw for pw in st.pending]))
                rethrow()
            end
            _reconnect_writer!(st)
            sleep(delay)
            delay = _next_delay(delay, st.config)
        end
    end
    for pw in st.pending
        pw.vf.persisted = true
    end
    empty!(st.pending)
    empty!(st.names)
    return st
end

function _reconnect_writer!(st::FormActorState)
    try
        close(st.conn)
    catch
    end
    try
        st.conn = LibPQ.Connection(_conninfo(st.config))
    catch
    end
    return nothing
end

# Append every queued update to the history and project it into the current
# snapshot, then record every name, all inside one transaction so the commit is
# all-or-nothing. Forms are written before names so the name's foreign key is
# satisfied.
function _write_batch!(conn, pending::Vector{PendingWrite}, names::Vector{PendingName})
    LibPQ.execute(conn, "BEGIN")
    try
        for pw in pending
            LibPQ.execute(conn, _UPSERT_SQL, (string(pw.vf.id), to_JSON(pw.form), pw.txid))
        end
        for pn in names
            LibPQ.execute(conn, _UPSERT_NAME_SQL, (pn.name, string(pn.id)))
        end
        LibPQ.execute(conn, "COMMIT")
    catch
        try
            LibPQ.execute(conn, "ROLLBACK")
        catch
        end
        rethrow()
    end
    return nothing
end
