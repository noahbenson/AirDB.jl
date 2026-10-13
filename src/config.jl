################################################################################
# config.jl
#
# How a `Database` finds and configures its PostgreSQL server. AirDB never
# manages the server — the user owns it — so a config is just connection
# parameters plus a few AirDB policies.
#
# MIT License
# Copyright (c) 2020-2026 Noah C. Benson

"""
    DatabaseConfig(; dbname, user, host="localhost", port=5432, password=nothing,
                     sslmode="prefer", connect_timeout=10, readpoolsize=8,
                     max_batch=1, failure=:abort, retries=nothing, retry_time=nothing,
                     retry_delay=0.1, retry_delay_max=5.0, on_error=nothing,
                     conninfo=nothing)
    DatabaseConfig(url::AbstractString; kwargs...)

The parameters AirDB uses to reach a PostgreSQL database and to decide how it
behaves. The server is the user's to configure and manage; AirDB only connects.

`dbname` and `user` are required unless `conninfo` is given. `conninfo`, when
set, is a libpq connection string or URI used verbatim (as built by the
`url` method), and the structured fields are ignored.

* `readpoolsize` — how many read connections to keep in the pool.
* `max_batch` — how many committed updates the writer actor accumulates before
  flushing. `1` (the default) writes every commit as soon as it arrives.
* `failure` — what to do when a database operation fails:
  * `:abort` (the default) — the writer actor is poisoned and every database
    operation raises.
  * `:retry` — the failing operation is retried, reconnecting first, while the
    retry budget lasts. Reads block until a retry succeeds or the budget is
    exhausted; writes accumulate in the writer's queue meanwhile.
* `retries` / `retry_time` — the retry budget: at most this many attempts, or at
  most this many seconds. If both are given, whichever runs out first wins; if
  neither is given under `:retry`, a small default is used.
* `retry_delay` / `retry_delay_max` — the delay before the first retry and its
  ceiling; the delay doubles after each failed attempt up to the ceiling.
* `on_error` — a hook `on_error(db, err)` called on every database error, before
  the policy is applied. It may return `:retry` or `:abort` to override the
  policy, an `Integer` to retry at most that many more times, a `Real` to retry
  for that many seconds, or `nothing` to use the configured policy. It can read
  [`pending_writes`](@ref) on `db` to see the unsaved updates.

"""
Base.@kwdef struct DatabaseConfig
    dbname::String
    user::String
    host::String = "localhost"
    port::Int = 5432
    password::Union{Nothing,String} = nothing
    sslmode::String = "prefer"
    connect_timeout::Int = 10
    readpoolsize::Int = 8
    max_batch::Int = 1
    failure::Symbol = :abort
    retries::Union{Nothing,Int} = nothing
    retry_time::Union{Nothing,Float64} = nothing
    retry_delay::Float64 = 0.1
    retry_delay_max::Float64 = 5.0
    on_error::Union{Nothing,Function} = nothing
    conninfo::Union{Nothing,String} = nothing
end

# A URL or libpq connection string is stored verbatim; the structured fields are
# placeholders that `_conninfo` never reads when `conninfo` is set.
DatabaseConfig(url::AbstractString; dbname::AbstractString = "", user::AbstractString = "", kwargs...) =
    DatabaseConfig(; conninfo = String(url), dbname = String(dbname), user = String(user), kwargs...)

# libpq's conninfo syntax quotes a value with single quotes, escaping a
# backslash or a single quote inside it.
function _conninfo_value(io::IO, v::AbstractString)
    print(io, '\'')
    for c in v
        (c == '\\' || c == '\'') && print(io, '\\')
        print(io, c)
    end
    return print(io, '\'')
end

function _build_conninfo(cfg::DatabaseConfig)
    io = IOBuffer()
    sep = ""
    for (k, v) in (("host", cfg.host), ("port", string(cfg.port)),
                   ("dbname", cfg.dbname), ("user", cfg.user))
        print(io, sep, k, "=")
        _conninfo_value(io, v)
        sep = " "
    end
    if cfg.password !== nothing
        print(io, sep, "password=")
        _conninfo_value(io, cfg.password)
        sep = " "
    end
    for (k, v) in (("sslmode", cfg.sslmode), ("connect_timeout", string(cfg.connect_timeout)))
        print(io, sep, k, "=")
        _conninfo_value(io, v)
        sep = " "
    end
    return String(take!(io))
end

"""
    _conninfo(cfg::DatabaseConfig) -> String

The libpq connection string for the config: `conninfo` verbatim when it was set,
otherwise built from the structured fields.

This is part of AirDB's internal implementation.
"""
_conninfo(cfg::DatabaseConfig) = cfg.conninfo === nothing ? _build_conninfo(cfg) : cfg.conninfo

function _validate(cfg::DatabaseConfig)
    (cfg.failure === :abort || cfg.failure === :retry) ||
        throw(ArgumentError("failure must be :abort or :retry, not :$(cfg.failure)"))
    (cfg.readpoolsize >= 1) ||
        throw(ArgumentError("readpoolsize must be at least 1"))
    (cfg.max_batch >= 1) ||
        throw(ArgumentError("max_batch must be at least 1"))
    (cfg.retries === nothing || cfg.retries >= 0) ||
        throw(ArgumentError("retries must be non-negative"))
    (cfg.retry_time === nothing || cfg.retry_time >= 0) ||
        throw(ArgumentError("retry_time must be non-negative"))
    (cfg.retry_delay >= 0) || throw(ArgumentError("retry_delay must be non-negative"))
    (cfg.retry_delay_max >= cfg.retry_delay) ||
        throw(ArgumentError("retry_delay_max must be at least retry_delay"))
    return cfg
end

export DatabaseConfig
