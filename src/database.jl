################################################################################
# database.jl
#
# The `Database` object: a configured connection to a PostgreSQL server, a pool
# of read connections, a weak cache of live forms, and a single writer actor that
# persists committed updates in commit order.
#
# MIT License
# Copyright (c) 2020-2026 Noah C. Benson

const _SCHEMA_VERSION = "2"

const _DDL_STATEMENTS = [
    """
    CREATE TABLE IF NOT EXISTS form_history (
        form_id     UUID        NOT NULL,
        version     BIGINT      NOT NULL,
        created_at  TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
        tx_id       BIGINT      NOT NULL,
        payload     JSONB       NOT NULL,
        PRIMARY KEY (form_id, version)
    )
    """,
    "CREATE INDEX IF NOT EXISTS form_history_tx_id_idx ON form_history (tx_id)",
    """
    CREATE TABLE IF NOT EXISTS form_current (
        form_id     UUID        PRIMARY KEY,
        version     BIGINT      NOT NULL,
        updated_at  TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
        payload     JSONB       NOT NULL
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS form_name (
        name        TEXT        PRIMARY KEY,
        form_id     UUID        NOT NULL REFERENCES form_current(form_id)
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
    "DROP TABLE IF EXISTS airdb_meta",
]

# One statement per form: append the new version to the history and project it
# into the current snapshot, atomically. The version is assigned by the database
# (1 on first insert, otherwise one more than the current), so the client never
# needs to read it back.
const _UPSERT_SQL = """
WITH upserted AS (
    INSERT INTO form_current (form_id, version, updated_at, payload)
    VALUES (\$1::uuid, 1, clock_timestamp(), \$2::jsonb)
    ON CONFLICT (form_id) DO UPDATE
        SET version    = form_current.version + 1,
            updated_at = clock_timestamp(),
            payload    = EXCLUDED.payload
    RETURNING form_id, version, payload
)
INSERT INTO form_history (form_id, version, created_at, tx_id, payload)
SELECT form_id, version, clock_timestamp(), \$3::bigint, payload FROM upserted
"""

const _SELECT_CURRENT_SQL = "SELECT payload FROM form_current WHERE form_id = \$1::uuid"

# A name is an alias for a form id. The writer's upsert overwrites, so a later
# `name_form!` wins; the in-memory table (the authority for reads) is updated in
# the same order.
const _UPSERT_NAME_SQL =
    "INSERT INTO form_name (name, form_id) VALUES (\$1, \$2::uuid) " *
    "ON CONFLICT (name) DO UPDATE SET form_id = EXCLUDED.form_id"

const _SELECT_ALL_NAMES_SQL = "SELECT name, form_id::text FROM form_name"

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
    cache::Dict{UUID,WeakRef}
    cachelock::ReentrantLock
    names::Volatile{PDict{String,VolatileForm}}   # the name table, transactional
    failure::Union{Nothing,DatabaseError}
    closed::Bool
end

_check_open(db::AbstractDatabase) = db.closed && throw(ArgumentError("the database is closed"))
_check_health(db::AbstractDatabase) = db.failure === nothing || throw(db.failure)

# Run `f` with a read connection from the pool. The connection is returned to the
# pool when `f` returns or throws; a connection left broken by an error is
# replaced so a single bad query does not poison the pool.
function _withread(f::Function, db::Database)
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
                # Under :abort (or a spent retry budget) the error fails the whole
                # database, not just this read.
                db.failure === nothing && (db.failure = DatabaseError(e, Any[]))
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

function _read_current(db::Database, id::UUID)
    # The not-found case is reported by returning `nothing`, not by throwing
    # inside `_withread` — a `FormNotFound` is not a database error and must not
    # poison the database.
    payload = _withread(db) do conn
        r = LibPQ.execute(conn, _SELECT_CURRENT_SQL, (string(id),))
        return isempty(r) ? nothing : r[1, 1]
    end
    payload === nothing && throw(FormNotFound(id))
    return from_JSON(db, String(payload))
end

"""
    from_JSON(db::AbstractDatabase, s::AbstractString) -> Form

Reads a form from JSON, resolving any `"@<uuid>"` links to the (possibly not yet
loaded) `VolatileForm`s cached by `db`.
"""
from_JSON(db::AbstractDatabase, s::AbstractString) = _from_JSON(id -> get_form(db, id), s)

# Build a Database from a config whose schema already exists: open the writer
# connection, start the writer actor, and fill the read pool.
function _make_database(config::DatabaseConfig)
    wconn = LibPQ.Connection(_conninfo(config))
    txseq = _read_max_txid(wconn)
    st = FormActorState(config, wconn, PendingWrite[], PendingName[], txseq, nothing, nothing)
    actor = Actor{FormActorState}(st)
    db = Database(config, actor, Channel{LibPQ.Connection}(config.readpoolsize),
                  Dict{UUID,WeakRef}(), ReentrantLock(),
                  Volatile{PDict{String,VolatileForm}}(PDict{String,VolatileForm}()),
                  nothing, false)
    st.db = db
    for _ in 1:config.readpoolsize
        put!(db.readpool, LibPQ.Connection(_conninfo(config)))
    end
    # Build the table (resolving each id through the cache) and hand it to the
    # volatile. Constructing a volatile with a value needs no transaction, and no
    # other thread has the database yet, so replacing the field is safe.
    db.names = Volatile{PDict{String,VolatileForm}}(_load_names(db, wconn))
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
database. The writer actor is sequential, so once it has processed the sync
message every earlier write is durable.

Raises the recorded `DatabaseError` if the flush failed.
"""
function sync(db::Database)
    _check_open(db)
    _check_health(db)
    actor = db.writeactor
    err0 = geterror(actor)
    err0 === nothing || throw(err0)
    sig = Channel{Nothing}(1)
    err = Ref{Any}(nothing)
    send(actor) do st
        try
            _flush!(st)
        catch e
            err[] = e
        finally
            put!(sig, nothing)
        end
        return st
    end
    # A message that throws makes the actor drop everything still queued and stop
    # (Air `src/TX.jl:218-225`), so a sync sent behind a failing write is never
    # processed. Wait for the signal, but give up and raise if the actor fails
    # instead — otherwise this would hang.
    while !isready(sig)
        e = geterror(actor)
        e === nothing || throw(e)
        sleep(0.001)
    end
    take!(sig)
    err[] === nothing || throw(err[])
    return nothing
end

"""
    status(db::Database) -> (npending, error)

The number of updates queued for the writer but not yet written, and the last
error the writer saw (or `nothing`). If the writer actor is poisoned, the error
is returned as the second element.
"""
function status(db::Database)
    e = geterror(db.writeactor)
    e === nothing || return (0, e)
    st = db.writeactor[]
    return (length(st.pending), st.last_error)
end

"""
    close(db::Database)

Flushes any queued writes and closes every connection the database holds. Further
operations raise.
"""
function Base.close(db::Database)
    db.closed && return db
    db.closed = true
    try
        send(db.writeactor) do st
            try
                _flush!(st)
            catch
            end
            try
                close(st.conn)
            catch
            end
            return st
        end
    catch
    end
    while isready(db.readpool)
        try
            close(take!(db.readpool))
        catch
        end
    end
    return db
end

export Database, create_database, open_database, DatabaseError, FormNotFound
