# Shared helpers for the database tests. The test Postgres is the one started by
# `docker compose up -d`; point the tests elsewhere with the AIRDB_TEST_* vars or
# AIRDB_TEST_URL.

function _test_config()
    url = get(ENV, "AIRDB_TEST_URL", nothing)
    url === nothing || return DatabaseConfig(url; readpoolsize = 4)
    return DatabaseConfig(;
        host = get(ENV, "AIRDB_TEST_HOST", "localhost"),
        port = parse(Int, get(ENV, "AIRDB_TEST_PORT", "5432")),
        dbname = get(ENV, "AIRDB_TEST_DBNAME", "airdb_test"),
        user = get(ENV, "AIRDB_TEST_USER", "airdb"),
        password = get(ENV, "AIRDB_TEST_PASSWORD", "airdb"),
        readpoolsize = 4)
end

_connect(cfg::DatabaseConfig) = LibPQ.Connection(AirDB._conninfo(cfg))

# Create a form, wait until it is persisted, and return its id with no reference
# left in the caller's scope, so the weak cache can release it (used to test lazy
# loading). Creating inside a function matters: a local in a test scope can keep
# the form alive through the test machinery.
function _create_and_forget(db::Database, args...; kwargs...)
    vf = VolatileForm(db, args...; kwargs...)
    AirDB.sync(db)
    return vf.id
end

_db_available(cfg::DatabaseConfig) =
    try
        close(_connect(cfg))
        true
    catch
        false
    end

# A config just like `cfg` but pointing at another database on the same server
# (used to reach a database that has no AirDB schema).
function _with_dbname(cfg::DatabaseConfig, name::AbstractString)
    if cfg.conninfo !== nothing
        return DatabaseConfig(cfg.conninfo * " dbname='" * name * "'";
                              readpoolsize = cfg.readpoolsize)
    end
    return DatabaseConfig(; dbname = String(name), user = cfg.user, password = cfg.password,
                          host = cfg.host, port = cfg.port, sslmode = cfg.sslmode,
                          readpoolsize = cfg.readpoolsize)
end

# The (version, tx_id) pairs in the history for a form, oldest first.
function _history(conn, id::UUID)
    r = LibPQ.execute(conn,
        "SELECT version, tx_id FROM form_history WHERE form_id = \$1::uuid ORDER BY version",
        (string(id),))
    return [(Int64(row[1]), Int64(row[2])) for row in r]
end

# The version in the current snapshot for a form, or nothing if it has no row.
function _current_version(conn, id::UUID)
    r = LibPQ.execute(conn, "SELECT version FROM form_current WHERE form_id = \$1::uuid",
                      (string(id),))
    return isempty(r) ? nothing : Int64(r[1, 1])
end

# The payload stored in the current snapshot for a form, as a String.
function _current_payload(conn, id::UUID)
    r = LibPQ.execute(conn, "SELECT payload FROM form_current WHERE form_id = \$1::uuid",
                      (string(id),))
    return isempty(r) ? nothing : String(r[1, 1])
end

# A copy of `cfg` with any fields overridden.
function _reconfig(cfg::DatabaseConfig; kwargs...)
    base = (; host = cfg.host, port = cfg.port, dbname = cfg.dbname, user = cfg.user,
              password = cfg.password, sslmode = cfg.sslmode,
              connect_timeout = cfg.connect_timeout, readpoolsize = cfg.readpoolsize,
              max_batch = cfg.max_batch, failure = cfg.failure, retries = cfg.retries,
              retry_time = cfg.retry_time, retry_delay = cfg.retry_delay,
              retry_delay_max = cfg.retry_delay_max, on_error = cfg.on_error,
              conninfo = cfg.conninfo, encoder_tasks = cfg.encoder_tasks,
              max_pending = cfg.max_pending)
    return DatabaseConfig(; merge(base, (; kwargs...))...)
end

# A copy of `cfg` with a different batch size (and optionally pool size).
_with_max_batch(cfg::DatabaseConfig, n::Integer; readpoolsize = cfg.readpoolsize) =
    _reconfig(cfg; max_batch = n, readpoolsize = readpoolsize)

# Wait until a form's current version equals `v` (or give up), yielding the last
# version seen.
function _wait_version(conn, id::UUID, v; timeout = 5.0)
    t0 = time()
    while _current_version(conn, id) != v
        time() - t0 > timeout && break
        sleep(0.005)
    end
    return _current_version(conn, id)
end
