################################################################################
# database.jl
#
# The `Database` object: a configured connection to a PostgreSQL server, a pool
# of read connections, a weak cache of live forms, and a single writer actor that
# persists committed updates in commit order.
#
# MIT License
# Copyright (c) 2020-2026 Noah C. Benson

# Bumped to 7 for stream forms. A database written by an earlier version cannot
# be read and is refused at open time rather than failing per row.
const _SCHEMA_VERSION = "7"

const _DDL_STATEMENTS = [
    """
    CREATE TABLE IF NOT EXISTS form_history (
        form_id     UUID        NOT NULL,
        version     BIGINT      NOT NULL,
        created_at  TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
        tx_id       BIGINT      NOT NULL,
        payload     JSONB       NOT NULL,
        metadata    JSONB,
        PRIMARY KEY (form_id, version)
    )
    """,
    "CREATE INDEX IF NOT EXISTS form_history_tx_id_idx ON form_history (tx_id)",
    """
    CREATE TABLE IF NOT EXISTS form_current (
        form_id     UUID        PRIMARY KEY,
        version     BIGINT      NOT NULL,
        updated_at  TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
        payload     JSONB       NOT NULL,
        metadata    JSONB,
        history     BOOLEAN     NOT NULL DEFAULT TRUE
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS form_name (
        name        TEXT        PRIMARY KEY,
        form_id     UUID        NOT NULL REFERENCES form_current(form_id)
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS resources (
        type        TEXT        NOT NULL,
        id          TEXT        NOT NULL,
        data        BYTEA       NOT NULL,
        metadata    JSONB,
        PRIMARY KEY (type, id)
    )
    """,
    "CREATE INDEX IF NOT EXISTS resources_type_idx ON resources (type)",
    "CREATE INDEX IF NOT EXISTS resources_id_idx   ON resources (id)",
    """
    CREATE TABLE IF NOT EXISTS form_actor_current (
        actor_id    UUID        PRIMARY KEY,
        version     BIGINT      NOT NULL,
        updated_at  TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
        value       JSONB       NOT NULL,
        history     BOOLEAN     NOT NULL DEFAULT TRUE,
        metadata    JSONB
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS form_actor_history (
        actor_id    UUID        NOT NULL,
        version     BIGINT      NOT NULL,
        created_at  TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
        tx_id       BIGINT      NOT NULL,
        value       JSONB       NOT NULL,
        PRIMARY KEY (actor_id, version)
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS form_promise (
        promise_id   UUID        PRIMARY KEY,
        state        TEXT        NOT NULL DEFAULT 'pending'
                                 CHECK (state IN ('pending','delivered','failed')),
        value        JSONB,
        error        JSONB,
        metadata     JSONB,
        settled_at   TIMESTAMPTZ
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS form_stream (
        stream_id  UUID        PRIMARY KEY,
        items      JSONB       NOT NULL DEFAULT '[]',
        maxsize    INTEGER,
        closed     BOOLEAN     NOT NULL DEFAULT FALSE,
        metadata   JSONB,
        updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
    )
    """,
    "CREATE TABLE IF NOT EXISTS airdb_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
    "INSERT INTO airdb_meta (key, value) VALUES ('schema_version', '$_SCHEMA_VERSION') " *
    "ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value",
]

const _DROP_STATEMENTS = [
    "DROP TABLE IF EXISTS form_name",      # before form_current: it references it
    "DROP TABLE IF EXISTS form_history",
    "DROP TABLE IF EXISTS form_current",
    "DROP TABLE IF EXISTS resources",
    "DROP TABLE IF EXISTS form_actor_history",
    "DROP TABLE IF EXISTS form_actor_current",
    "DROP TABLE IF EXISTS form_promise",
    "DROP TABLE IF EXISTS form_stream",
    "DROP TABLE IF EXISTS airdb_meta",
]

# One statement per form: append the new version to the history and project it
# into the current snapshot, atomically. The version is assigned by the database
# (1 on first insert, otherwise one more than the current), so the client never
# needs to read it back. A current-only form uses `_UPSERT_CURRENT_SQL`, which
# skips the history insert.
const _UPSERT_SQL = """
WITH upserted AS (
    INSERT INTO form_current (form_id, version, updated_at, payload, metadata, history)
    VALUES (\$1::uuid, 1, clock_timestamp(), \$2::jsonb, \$3::jsonb, \$4::boolean)
    ON CONFLICT (form_id) DO UPDATE
        SET version    = form_current.version + 1,
            updated_at = clock_timestamp(),
            payload    = EXCLUDED.payload,
            metadata   = EXCLUDED.metadata,
            history    = EXCLUDED.history
    RETURNING form_id, version, payload, metadata
)
INSERT INTO form_history (form_id, version, created_at, tx_id, payload, metadata)
SELECT form_id, version, clock_timestamp(), \$5::bigint, payload, metadata FROM upserted
"""

const _UPSERT_CURRENT_SQL = """
INSERT INTO form_current (form_id, version, updated_at, payload, metadata, history)
VALUES (\$1::uuid, 1, clock_timestamp(), \$2::jsonb, \$3::jsonb, \$4::boolean)
ON CONFLICT (form_id) DO UPDATE
    SET version    = form_current.version + 1,
        updated_at = clock_timestamp(),
        payload    = EXCLUDED.payload,
        metadata   = EXCLUDED.metadata,
        history    = EXCLUDED.history
"""

const _SELECT_CURRENT_SQL =
    "SELECT payload, metadata, history FROM form_current WHERE form_id = \$1::uuid"

const _UPSERT_RESOURCE_SQL =
    "INSERT INTO resources (type, id, data, metadata) " *
    "VALUES (\$1, \$2, \$3::bytea, \$4::jsonb) " *
    "ON CONFLICT (type, id) DO UPDATE " *
    "SET data = EXCLUDED.data, metadata = EXCLUDED.metadata"

const _SELECT_RESOURCE_SQL = "SELECT data FROM resources WHERE type = \$1 AND id = \$2"
const _SELECT_RESOURCE_METADATA_SQL =
    "SELECT metadata FROM resources WHERE type = \$1 AND id = \$2"
const _UPDATE_RESOURCE_METADATA_SQL =
    "UPDATE resources SET metadata = \$3::jsonb WHERE type = \$1 AND id = \$2"

# An actor update: like a form, optionally appending a history row, and carrying
# the owner/ACL metadata.
const _UPSERT_ACTOR_SQL = """
WITH upserted AS (
    INSERT INTO form_actor_current (actor_id, version, updated_at, value, history, metadata)
    VALUES (\$1::uuid, 1, clock_timestamp(), \$2::jsonb, \$3::boolean, \$4::jsonb)
    ON CONFLICT (actor_id) DO UPDATE
        SET version    = form_actor_current.version + 1,
            updated_at = clock_timestamp(),
            value      = EXCLUDED.value,
            history    = EXCLUDED.history,
            metadata   = EXCLUDED.metadata
    RETURNING actor_id, version, value
)
INSERT INTO form_actor_history (actor_id, version, created_at, tx_id, value)
SELECT actor_id, version, clock_timestamp(), \$5::bigint, value FROM upserted
"""
const _UPSERT_ACTOR_CURRENT_SQL = """
INSERT INTO form_actor_current (actor_id, version, updated_at, value, history, metadata)
VALUES (\$1::uuid, 1, clock_timestamp(), \$2::jsonb, \$3::boolean, \$4::jsonb)
ON CONFLICT (actor_id) DO UPDATE
    SET version    = form_actor_current.version + 1,
        updated_at = clock_timestamp(),
        value      = EXCLUDED.value,
        history    = EXCLUDED.history,
        metadata   = EXCLUDED.metadata
"""

# Every referenced promise gets a row (created 'pending' if absent, in the same
# commit that first names or settles it), and is settled by a compare-and-set
# that only matches a pending row. A delivered promise keeps its row: the link
# in the form is what preserves its identity.
const _INSERT_PROMISE_SQL =
    "INSERT INTO form_promise (promise_id, metadata) VALUES (\$1::uuid, \$2::jsonb) " *
    "ON CONFLICT (promise_id) DO NOTHING"
const _DELIVER_PROMISE_SQL =
    "UPDATE form_promise " *
    "SET value = \$2::jsonb, state = 'delivered', settled_at = clock_timestamp() " *
    "WHERE promise_id = \$1::uuid AND state = 'pending' RETURNING promise_id"
const _FAIL_PROMISE_SQL =
    "UPDATE form_promise " *
    "SET error = \$2::jsonb, state = 'failed', settled_at = clock_timestamp() " *
    "WHERE promise_id = \$1::uuid AND state = 'pending' RETURNING promise_id"
const _UPSERT_STREAM_SQL =
    "INSERT INTO form_stream (stream_id, items, maxsize, closed, metadata, updated_at) " *
    "VALUES (\$1::uuid, \$2::jsonb, \$3::integer, \$4::boolean, \$5::jsonb, " *
    "        clock_timestamp()) " *
    "ON CONFLICT (stream_id) DO UPDATE " *
    "SET items = EXCLUDED.items, maxsize = EXCLUDED.maxsize, closed = EXCLUDED.closed, " *
    "    metadata = EXCLUDED.metadata, updated_at = clock_timestamp()"
const _SELECT_STREAM_SQL =
    "SELECT items::text, maxsize, closed, metadata::text FROM form_stream " *
    "WHERE stream_id = \$1::uuid"
const _SELECT_STREAM_METADATA_SQL =
    "SELECT metadata::text FROM form_stream WHERE stream_id = \$1::uuid"
const _UPDATE_STREAM_METADATA_SQL =
    "UPDATE form_stream SET metadata = \$2::jsonb WHERE stream_id = \$1::uuid"
const _SELECT_ACTOR_SQL =
    "SELECT value::text, history, metadata::text " *
    "FROM form_actor_current WHERE actor_id = \$1::uuid"
const _SELECT_PROMISE_SQL =
    "SELECT state, value::text, error::text, metadata::text " *
    "FROM form_promise WHERE promise_id = \$1::uuid"

# Metadata-only reads and updates.
const _SELECT_CURRENT_METADATA_SQL =
    "SELECT metadata::text, history FROM form_current WHERE form_id = \$1::uuid"
const _SELECT_ACTOR_METADATA_SQL =
    "SELECT metadata::text, history FROM form_actor_current WHERE actor_id = \$1::uuid"
const _SELECT_PROMISE_METADATA_SQL =
    "SELECT metadata::text, state FROM form_promise WHERE promise_id = \$1::uuid"
const _UPDATE_FORM_METADATA_SQL =
    "UPDATE form_current SET metadata = \$2::jsonb WHERE form_id = \$1::uuid"
const _UPDATE_ACTOR_METADATA_SQL =
    "UPDATE form_actor_current SET metadata = \$2::jsonb WHERE actor_id = \$1::uuid"
const _UPDATE_PROMISE_METADATA_SQL =
    "UPDATE form_promise SET metadata = \$2::jsonb WHERE promise_id = \$1::uuid"

# A name is an alias for a form id. The writer's upsert overwrites, so a later
# `name_form!` wins; the in-memory table (the authority for reads) is updated in
# the same order.
const _UPSERT_NAME_SQL =
    "INSERT INTO form_name (name, form_id) VALUES (\$1, \$2::uuid) " *
    "ON CONFLICT (name) DO UPDATE SET form_id = EXCLUDED.form_id"

const _SELECT_ALL_NAMES_SQL = "SELECT name, form_id::text FROM form_name"
const _DELETE_NAME_SQL = "DELETE FROM form_name WHERE name = \$1"

"""
    FormNotFound(id)

Raised when a form's id is not present in the database.
"""
struct FormNotFound <: Exception
    id::UUID
end
Base.showerror(io::IO, e::FormNotFound) =
    print(io, "no form with id ", e.id, " is stored in the database")

"""
    DatabaseError(cause, failed_writes)

Raised, or recorded on a `Database`, when a database operation fails under the
`:abort` policy. `cause` is the underlying exception and `failed_writes` holds the
updates that could not be saved.
"""
struct DatabaseError <: Exception
    cause::Exception
    failed_writes::Vector{Any}
end
Base.showerror(io::IO, e::DatabaseError) =
    print(io, "AirDB database error: ", sprint(showerror, e.cause),
          " (", length(e.failed_writes), " unsaved write(s))")

"""
    Database

A configured connection to a PostgreSQL database, plus the machinery AirDB keeps
around it: a pool of read connections, a weak cache of live `VolatileForm`s, and
a single writer actor that persists committed updates in global commit order.

Create one with [`create_database`](@ref) (to initialize a new database) or
[`open_database`](@ref) (to open an existing one).
"""
mutable struct Database <: AbstractDatabase
    config::DatabaseConfig
    writeactor::Actor
    readpool::Channel{LibPQ.Connection}
    cache::Dict{UUID,WeakRef}          # VolatileForm
    actorcache::Dict{UUID,WeakRef}     # ActorForm
    promisecache::Dict{UUID,WeakRef}   # PromiseForm
    streamcache::Dict{UUID,WeakRef}    # StreamForm
    cachelock::ReentrantLock
    gclock::ReentrantLock              # held exclusively by gc!; shared by loads
    names::Volatile{PDict{String,VolatileForm}}   # the name table, transactional
    failure::Union{Nothing,DatabaseError}         # the :abort poison marker
    writefailures::Vector{FailureRecord}          # quarantined write batches
    failedkeys::Dict{Any,Int}                     # key -> newest failure record
    lastsuccess::Dict{Any,Int}                    # key -> last successful sequence
    readfailures::Vector{ReadFailure}
    faillock::ReentrantLock
    closed::Bool
    pipeline::Any                                 # the WritePipeline (pipeline.jl)
end

_check_open(db::AbstractDatabase) = db.closed && throw(ArgumentError("the database is closed"))
_check_health(db::AbstractDatabase) = db.failure === nothing || throw(db.failure)

# Run `f` with a read connection from the pool. The connection is returned to the
# pool when `f` returns or throws; a connection left broken by an error is
# replaced so a single bad query does not poison the pool. `op`/`id` label a
# failure for `read_failures` and for `load!`'s per-object check.
function _withread(f::Function, db::Database; op::Symbol = :read, id = nothing)
    _check_open(db)
    _check_health(db)
    conn = take!(db.readpool)
    attempt = 0
    t0 = time()
    delay = db.config.retry_delay
    while true
        try
            out = f(conn)
            put!(db.readpool, conn)
            return out
        catch e
            attempt += 1
            if !_decide_retry(db, e, attempt, time() - t0)
                _record_read_failure!(db, e, op, id)
                # Under :abort the error fails the whole database; under
                # :isolate it fails only this read.
                if db.config.failure === :abort
                    db.failure === nothing && (db.failure = DatabaseError(e, Any[]))
                end
                _discard_read_conn!(db, conn)
                rethrow()
            end
            conn = _fresh_read_conn!(db, conn)
            sleep(delay)
            delay = _next_delay(delay, db.config)
        end
    end
end

# Replace a broken read connection with a fresh one (returning the old one if the
# reconnect itself fails, so the next attempt simply tries again).
function _fresh_read_conn!(db::Database, conn)
    try
        close(conn)
    catch
    end
    try
        return LibPQ.Connection(_conninfo(db.config))
    catch
        return conn
    end
end

function _discard_read_conn!(db::Database, conn)
    try
        close(conn)
    catch
    end
    try
        put!(db.readpool, LibPQ.Connection(_conninfo(db.config)))
    catch
    end
    return nothing
end

function _read_max_txid(conn)
    r = LibPQ.execute(conn, "SELECT COALESCE(MAX(tx_id), 0) FROM form_history")
    return Int64(first(r)[1])
end

# The form, its metadata (or `nothing`), and its history flag.
function _read_current(db::Database, id::UUID)
    # The not-found case is reported by returning `nothing`, not by throwing
    # inside `_withread` — a `FormNotFound` is not a database error and must not
    # poison the database.
    row = _withread(db; op = :load, id = id) do conn
        r = LibPQ.execute(conn, _SELECT_CURRENT_SQL, (string(id),))
        return isempty(r) ? nothing : (r[1, 1], r[1, 2], r[1, 3])
    end
    row === nothing && throw(FormNotFound(id))
    payload, meta, hist = row
    form = from_JSON(db, String(payload))
    metadata = (meta === nothing || ismissing(meta)) ? nothing : from_JSON(db, String(meta))
    return (form, metadata, Bool(hist))
end

# Read a resource's bytes and let its type deserialize them.
function _read_resource(db::Database, type::Symbol, id::Symbol)
    bytes = _withread(db; op = :load, id = (type, id)) do conn
        r = LibPQ.execute(conn, _SELECT_RESOURCE_SQL, (string(type), string(id)))
        return isempty(r) ? nothing : r[1, 1]
    end
    bytes === nothing &&
        throw(ExternError("no resource :$type/$(id) is stored in the database"))
    return _deserialize_resource(type, Vector{UInt8}(bytes))
end

# An actor's current value, its history flag, and its metadata.
function _read_actor(db::Database, id::UUID)
    row = _withread(db; op = :load, id = id) do conn
        r = LibPQ.execute(conn, _SELECT_ACTOR_SQL, (string(id),))
        isempty(r) ? nothing : (r[1, 1], r[1, 2], r[1, 3])
    end
    row === nothing && throw(FormNotFound(id))
    payload, hist, meta = row
    metadata = (meta === nothing || ismissing(meta)) ? nothing : from_JSON(db, String(meta))
    return (from_JSON(db, String(payload)), Bool(hist), metadata)
end

# A promise row as `(state, value, error, metadata)`, with the three payloads
# `nothing` when NULL; or `nothing` when there is no row at all.
function _read_promise(db::Database, id::UUID)
    row = _withread(db; op = :load, id = id) do conn
        r = LibPQ.execute(conn, _SELECT_PROMISE_SQL, (string(id),))
        isempty(r) ? nothing : (String(r[1, 1]), r[1, 2], r[1, 3], r[1, 4])
    end
    row === nothing && return nothing
    state, val, err, meta = row
    value = (val === nothing || ismissing(val)) ? nothing : from_JSON(db, String(val))
    error = (err === nothing || ismissing(err)) ? nothing : from_JSON(db, String(err))
    metadata = (meta === nothing || ismissing(meta)) ? nothing : from_JSON(db, String(meta))
    return (Symbol(state), value, error, metadata)
end

# Metadata-only reads: they never fetch or decode the payload.
function _read_form_metadata(db::Database, id::UUID)
    row = _withread(db; op = :metadata, id = id) do conn
        r = LibPQ.execute(conn, _SELECT_CURRENT_METADATA_SQL, (string(id),))
        isempty(r) ? nothing : (r[1, 1], r[1, 2])
    end
    row === nothing && throw(FormNotFound(id))
    meta, hist = row
    metadata = (meta === nothing || ismissing(meta)) ? nothing : from_JSON(db, String(meta))
    return (metadata, Bool(hist))
end

function _read_actor_metadata(db::Database, id::UUID)
    row = _withread(db; op = :metadata, id = id) do conn
        r = LibPQ.execute(conn, _SELECT_ACTOR_METADATA_SQL, (string(id),))
        isempty(r) ? nothing : (r[1, 1], r[1, 2])
    end
    row === nothing && throw(FormNotFound(id))
    meta, hist = row
    metadata = (meta === nothing || ismissing(meta)) ? nothing : from_JSON(db, String(meta))
    return (metadata, Bool(hist))
end

# A promise's metadata and state, or `nothing` when it has no row (an
# uncommitted or never-stored promise).
function _read_promise_metadata(db::Database, id::UUID)
    row = _withread(db; op = :metadata, id = id) do conn
        r = LibPQ.execute(conn, _SELECT_PROMISE_METADATA_SQL, (string(id),))
        isempty(r) ? nothing : (r[1, 1], String(r[1, 2]))
    end
    row === nothing && return nothing
    meta, state = row
    metadata = (meta === nothing || ismissing(meta)) ? nothing : from_JSON(db, String(meta))
    return (metadata, Symbol(state))
end

# A stream row as `(items::Vector{Form}, maxsize, closed, metadata)`, or
# `nothing` when it has no row.
function _read_stream(db::Database, id::UUID)
    row = _withread(db; op = :load, id = id) do conn
        r = LibPQ.execute(conn, _SELECT_STREAM_SQL, (string(id),))
        isempty(r) ? nothing : (r[1, 1], r[1, 2], r[1, 3], r[1, 4])
    end
    row === nothing && return nothing
    itemsjson, mxs, closed, metajson = row
    items = Form[]
    if itemsjson !== nothing && !ismissing(itemsjson)
        container = from_JSON(db, String(itemsjson))
        container isa FormContainer ||
            throw(ArgumentError("stored stream items are not a form list"))
        for x in container.seq
            push!(items, to_form(x))
        end
    end
    m = (mxs === nothing || ismissing(mxs)) ? nothing : Int(mxs)
    metadata = (metajson === nothing || ismissing(metajson)) ? nothing :
               from_JSON(db, String(metajson))
    return (items, m, Bool(closed), metadata)
end

function _read_stream_metadata(db::Database, id::UUID)
    meta = _withread(db; op = :metadata, id = id) do conn
        r = LibPQ.execute(conn, _SELECT_STREAM_METADATA_SQL, (string(id),))
        isempty(r) ? nothing : r[1, 1]
    end
    (meta === nothing || ismissing(meta)) && return nothing
    return from_JSON(db, String(meta))
end

function _read_resource_metadata(db::Database, type::Symbol, id::Symbol)
    meta = _withread(db; op = :metadata, id = (type, id)) do conn
        r = LibPQ.execute(conn, _SELECT_RESOURCE_METADATA_SQL,
                          (string(type), string(id)))
        isempty(r) ? nothing : r[1, 1]
    end
    (meta === nothing || ismissing(meta)) && return nothing
    return from_JSON(db, String(meta))
end

"""
    from_JSON(db::AbstractDatabase, s::AbstractString) -> Form

Reads a form from JSON, resolving any `"@<uuid>"` links to the (possibly not yet
loaded) `VolatileForm`s cached by `db`, and any extern references through `db`'s
resource registry.
"""
from_JSON(db::AbstractDatabase, s::AbstractString) =
    _from_JSON(id -> get_form(db, id), s, db)

# Build a Database from a config whose schema already exists: open the writer
# connection, start the writer actor, and fill the read pool.
function _make_database(config::DatabaseConfig)
    wconn = LibPQ.Connection(_conninfo(config))
    txseq = _read_max_txid(wconn)
    st = FormActorState(config, txseq, nothing)
    actor = Actor{FormActorState}(st)
    db = Database(config, actor, Channel{LibPQ.Connection}(config.readpoolsize),
                  Dict{UUID,WeakRef}(), Dict{UUID,WeakRef}(), Dict{UUID,WeakRef}(),
                  Dict{UUID,WeakRef}(),
                  ReentrantLock(), ReentrantLock(),
                  Volatile{PDict{String,VolatileForm}}(PDict{String,VolatileForm}()),
                  nothing, FailureRecord[], Dict{Any,Int}(), Dict{Any,Int}(),
                  ReadFailure[], ReentrantLock(), false, nothing)
    st.db = db
    for _ in 1:config.readpoolsize
        put!(db.readpool, LibPQ.Connection(_conninfo(config)))
    end
    # Build the table (resolving each id through the cache) and hand it to the
    # volatile. Constructing a volatile with a value needs no transaction, and no
    # other thread has the database yet, so replacing the field is safe.
    db.names = Volatile{PDict{String,VolatileForm}}(_load_names(db, wconn))
    # The pipeline takes ownership of the writer connection from here on.
    db.pipeline = _start_pipeline!(db, wconn, txseq)
    return db
end

# Read the whole name table into memory. Each name maps to a (lazily loaded)
# VolatileForm, cached like any other.
function _load_names(db::Database, conn)
    names = PDict{String,VolatileForm}()
    for row in LibPQ.execute(conn, _SELECT_ALL_NAMES_SQL)
        names = push(names, String(row[1]) => get_form(db, UUID(String(row[2]))))
    end
    return names
end

"""
    create_database(config::DatabaseConfig; overwrite::Bool=false) -> Database

Initializes a new AirDB database in the PostgreSQL instance described by
`config` — creating the `form_history`, `form_current`, and `airdb_meta` tables
and starting a `Database` for it. The server itself is the user's to provide and
manage.

With `overwrite=true` the three AirDB tables are dropped and recreated first.
"""
function create_database(config::DatabaseConfig; overwrite::Bool=false)
    _validate(config)
    conn = LibPQ.Connection(_conninfo(config))
    try
        if overwrite
            for stmt in _DROP_STATEMENTS
                LibPQ.execute(conn, stmt)
            end
        end
        for stmt in _DDL_STATEMENTS
            LibPQ.execute(conn, stmt)
        end
    finally
        close(conn)
    end
    return _make_database(config)
end

"""
    open_database(config::DatabaseConfig) -> Database

Opens an AirDB database that already exists in the PostgreSQL instance described
by `config`. Raises if the AirDB schema is missing (use [`create_database`](@ref)
to make one).
"""
function open_database(config::DatabaseConfig)
    _validate(config)
    conn = LibPQ.Connection(_conninfo(config))
    try
        _verify_schema(conn)
    finally
        close(conn)
    end
    return _make_database(config)
end

function _verify_schema(conn)
    r = LibPQ.execute(conn, "SELECT to_regclass('public.form_current') IS NOT NULL")
    (isempty(r) || first(r)[1] !== true) &&
        throw(ArgumentError("no AirDB schema found in this database; " *
                            "use create_database to initialize one"))
    r = LibPQ.execute(conn, "SELECT value FROM airdb_meta WHERE key = 'schema_version'")
    if isempty(r) || string(first(r)[1]) != _SCHEMA_VERSION
        found = isempty(r) ? "none" : string(first(r)[1])
        throw(ArgumentError("this database has AirDB schema version $found, " *
                            "but this version of AirDB expects $_SCHEMA_VERSION"))
    end
    return nothing
end

"""
    sync(db::Database)

Blocks until every update sent to `db` before this call has been written to the
database. The pipeline's writer is sequential, so once it has passed the sync
barrier every earlier write is durable.

Under `:isolate`, a quarantined batch does not make `sync` raise (see
[`write_failures`](@ref)); under `:abort`, the recorded `DatabaseError` is
raised.
"""
function sync(db::Database)
    _check_open(db)
    currtx() === nothing ||
        throw(ArgumentError("sync cannot be called inside a transaction"))
    _check_health(db)
    _queue_barrier!(db)
    return nothing
end

"""
    status(db::Database) -> (npending, error)

The number of updates queued for the writer but not yet written, and the last
error the writer saw (or `nothing`).
"""
function status(db::Database)
    pipe = db.pipeline
    pipe === nothing && return (0, nothing)
    lock(pipe.lock)
    try
        return (pipe.pendingitems, pipe.last_error)
    finally
        unlock(pipe.lock)
    end
end

"""
    close(db::Database)

Flushes any queued writes and closes every connection the database holds. Further
operations raise.
"""
function Base.close(db::Database)
    db.closed && return db
    db.closed = true
    _queue_close!(db)
    while isready(db.readpool)
        try
            close(take!(db.readpool))
        catch
        end
    end
    return db
end

export Database, create_database, open_database, DatabaseError, FormNotFound
