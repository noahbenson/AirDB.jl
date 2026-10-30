################################################################################
# retry.jl
#
# The retry policy. Under `:retry`, a database error does not fail the database
# outright: the failing operation reconnects and tries again, while the budget
# lasts. The budget is a number of attempts, an amount of time, or whatever the
# user's `on_error` hook decides.
#
# The same decision is used by the writer (flushing its queue) and by reads (so a
# read blocks until a retry succeeds or the budget runs out), which is what makes
# a database outage freeze rather than fail.
#
# MIT License
# Copyright (c) 2020-2026 Noah C. Benson

"""
    pending_writes(db::Database)

The updates the writer has not yet saved — form writes, actor values, queued
stream snapshots, resource bytes, promise rows and settlements, names, and
metadata-only edits — plus any writes that were quarantined by the failure
policy. This is meant for use inside an `on_error` hook, where the writer is
between attempts and its queue is the work that a successful retry would save.
If the writer has already been poisoned (`:abort`), the writes from the failed
batch are returned instead.
"""
function pending_writes(db::AbstractDatabase)
    db isa Database || return Any[]
    e = geterror(db.writeactor)
    if e !== nothing
        return db.failure === nothing ? Any[] : db.failure.failed_writes
    end
    pipe = db.pipeline
    pipe === nothing && return _failed_write_items(db)
    items = lock(pipe.lock) do
        _pending_items(pipe)
    end
    append!(items, _failed_write_items(db))
    return items
end

# Decide whether a failed operation should be retried. `attempt` is the number of
# failures so far (1 for the first) and `elapsed` the seconds since the first.
#
# The `on_error` hook, when set, runs first and may override everything:
#   * `:abort` / `false`   — do not retry;
#   * `:retry` / `true`    — retry within the configured budget;
#   * an `Integer`         — retry at most that many attempts;
#   * a `Real`             — retry for at most that many seconds;
#   * `nothing`            — fall back to the configured `failure` policy.
function _decide_retry(db, err, attempt::Int, elapsed::Float64)
    db === nothing && return false
    cfg = db.config
    d = cfg.on_error === nothing ? nothing : cfg.on_error(db, err)

    (d === false || d === :abort) && return false

    maxn = cfg.retries
    maxt = cfg.retry_time
    if d === true || d === :retry
        # keep the configured budget
    elseif d isa Integer
        maxn = Int(d)
    elseif d isa Real
        maxt = Float64(d)
    else
        # no hook decision: obey the configured policy. `:isolate` and `:retry`
        # retry within the budget; only `:abort` gives up immediately.
        (cfg.failure === :retry || cfg.failure === :isolate) || return false
    end
    if maxn === nothing && maxt === nothing
        maxn = 5                      # no budget configured: a small default
    end
    (maxn !== nothing && attempt >= maxn) && return false
    (maxt !== nothing && elapsed >= maxt) && return false
    return true
end

# The delay before the next attempt, doubling from `retry_delay` up to
# `retry_delay_max`.
_next_delay(delay::Float64, cfg::DatabaseConfig) = min(delay * 2, cfg.retry_delay_max)

export pending_writes
