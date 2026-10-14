# Failures and retries

A connection to PostgreSQL can fail at any time — a dropped socket, a restart, a
network blip. AirDB gives you two policies, chosen with `failure` on the
`DatabaseConfig`.

## `:abort` (the default)

As soon as a database operation fails, the database is **failed**: the writer
actor is poisoned, every later write raises, and every later read raises. Nothing
is silently lost, but the database is unusable until it is replaced.

```julia
db = create_database(DatabaseConfig(; dbname = "airdb_test", user = "airdb");
                     overwrite = true)
vf = VolatileForm(db, n = 1)
AirDB.sync(db)

close(db.writeactor[].conn)      # break the writer connection
@tx vf[:n] = 2
AirDB.sync(db)
# ERROR: AirDB database error: ... (1 unsaved write(s))

db.failure isa DatabaseError     # true
get_form(db, uuid4())[]          # ERROR: AirDB database error: ...
```

## `:retry`

With `failure = :retry`, a failed operation is retried instead, reconnecting
first, while a **budget** lasts. Reads block until a retry succeeds (or the budget
is spent); writes accumulate in the writer's queue meanwhile.

```julia
cfg = DatabaseConfig(;
    dbname     = "airdb_test",
    user       = "airdb",
    failure    = :retry,
    retries    = 5,          # retry at most 5 times ...
    retry_time = 30.0,       # ... or for at most 30 seconds (whichever first)
    retry_delay = 0.1,       # wait 0.1 s before the first retry ...
    retry_delay_max = 5.0,   # ... doubling up to 5 s between attempts
)
db = create_database(cfg; overwrite = true)

vf = VolatileForm(db, n = 1)
AirDB.sync(db)
close(db.writeactor[].conn)      # break the writer connection
@tx vf[:n] = 2
AirDB.sync(db)                   # the writer reconnects, retries, and succeeds
vf[:n]                           # 2
db.failure === nothing           # true — the database is healthy
```

You give a budget as a **number of retries** (`retries`), an **amount of time**
(`retry_time`), or both — whichever runs out first wins. If you set neither, a
small default is used.

If the budget is spent, the database fails exactly as under `:abort`: the error
is recorded on `db.failure` and every later operation raises. The failed writes
are kept on the error.

## The `on_error` hook

Set `on_error` to a function `on_error(db, err)` and it is called on **every**
database error — writer or reader — before the policy is applied. Its return
value decides what happens:

| return | meaning |
| --- | --- |
| `:retry` or `true` | retry, within the configured budget |
| `:abort` or `false` | do not retry; fail the database |
| an `Integer` | retry at most that many attempts |
| a `Real` | retry for at most that many seconds |
| `nothing` | use the configured `failure` policy |

The hook receives the `Database`, so it can inspect the unsaved work with
[`pending_writes`](api.md), log the error, alert, or change its mind as an outage
drags on.

```julia
attempts = Ref(0)
cfg = DatabaseConfig(;
    dbname = "airdb_test", user = "airdb",
    failure = :retry, retry_delay = 0.05,
    on_error = (db, err) -> begin
        attempts[] += 1
        n = length(pending_writes(db))          # the updates a retry would save
        @warn "database error; $n write(s) pending" exception = err
        n > 1000 ? :abort : :retry              # give up if too far behind
    end,
)
```

A hook can also force a retry even when the configured policy is `:abort`:

```julia
cfg = DatabaseConfig(;
    dbname = "airdb_test", user = "airdb",
    failure = :abort,                            # otherwise fail immediately
    on_error = (db, err) -> :retry,              # ... but this hook says retry
)
```

```{admonition} The budget is per operation
:class: note
Each flush and each read has its own attempt count and clock. During a long
outage, every read independently retries for up to `retry_time` before failing,
and the writer's queue keeps growing until it recovers or gives up.
```
