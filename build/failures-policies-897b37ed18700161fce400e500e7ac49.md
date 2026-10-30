# Failures and retries

<!-- review-status: unreviewed -->
:::{warning} Unreviewed content
This page was written with AI assistance and has not been reviewed by a human.
It may contain errors, omissions, or outdated information.
:::

A connection to PostgreSQL can fail at any time — a dropped socket, a restart, a
network blip — and a particular row can be impossible to write. AirDB lets you
choose what a permanent failure does with `failure` on the `DatabaseConfig`:
`:isolate` (the default), `:abort`, or `:retry`.

Retries are separate from the terminal action. `:isolate` and `:retry` both retry
a failing operation while a **budget** lasts (reconnecting first); when the
budget is spent, they **quarantine** the batch. `:abort` gives up immediately (or
when the `on_error` hook says to stop) and fails the whole database.

## `:isolate` (the default)

A batch that cannot be saved is **quarantined**: its committed in-memory values
remain readable, the failure is recorded with the objects and pending writes it
contained, and unrelated reads and writes continue.

```julia
db = create_database(DatabaseConfig(; dbname = "airdb_test", user = "airdb",
                                    password = "airdb", retries = 0);  # no retries here
                     overwrite = true)
vf = VolatileForm(db, n = 1)
AirDB.sync(db)

close(AirDB._writer_conn(db))    # test-only: force an outage (internal helper)
@tx vf[:n] = 2
AirDB.sync(db)                   # does not throw
vf[]                             # Form(n=2) — the committed value is kept
failed(db, vf.id)                # true — its row was not written
```

A quarantined batch is recorded, not lost: `write_failures(db)` lists the
records, `failed(db, id)` says whether one object is affected, and
`clear_write_failure!` acknowledges or retries it. Read errors are recorded
separately with `read_failures`. The whole inspection and retry API is in
[Inspecting failures](failures-inspection.md).

## `:abort`

With `failure = :abort`, the first permanent failure fails the **whole
database**: `db.failure` is set, every later write raises, and every later read
raises. Nothing is silently lost, but the database is unusable until it is
replaced.

```julia
cfg = DatabaseConfig(; dbname = "airdb_test", user = "airdb",
                      password = "airdb", failure = :abort)
db = create_database(cfg; overwrite = true)
vf = VolatileForm(db, n = 1)
AirDB.sync(db)

close(AirDB._writer_conn(db))    # test-only: force an outage (internal helper)
@tx vf[:n] = 2
AirDB.sync(db)
# ERROR: AirDB database error: ... (1 unsaved write(s))

db.failure isa DatabaseError     # true
get_form(db, uuid4())[]          # ERROR: AirDB database error: ...
```

## `:retry`

`:retry` is a compatibility alias for the isolated retry path: a failed
operation is retried, reconnecting first, while a **budget** lasts. Reads block
until a retry succeeds (or the budget is spent); writes accumulate in the
pipeline meanwhile. When the budget is spent the batch is quarantined, as under
`:isolate`.

```julia
cfg = DatabaseConfig(;
    dbname     = "airdb_test",
    user       = "airdb",
    password   = "airdb",
    failure    = :retry,
    retries    = 5,          # retry at most 5 times ...
    retry_time = 30.0,       # ... or for at most 30 seconds (whichever first)
    retry_delay = 0.1,       # wait 0.1 s before the first retry ...
    retry_delay_max = 5.0,   # ... doubling up to 5 s between attempts
)
db = create_database(cfg; overwrite = true)

vf = VolatileForm(db, n = 1)
AirDB.sync(db)
close(AirDB._writer_conn(db))    # test-only: force an outage (internal helper)
@tx vf[:n] = 2
AirDB.sync(db)                   # the writer reconnects, retries, and succeeds
vf[:n]                           # 2
db.failure === nothing           # true — the database is healthy
```

You give a budget as a **number of retries** (`retries`), an **amount of time**
(`retry_time`), or both — whichever runs out first wins. If you set neither, a
small default is used.

## The `on_error` hook

Set `on_error` to a function `on_error(db, err)` and it is called on **every**
database error — writer or reader — before the policy is applied. Its return
value decides whether to retry:

| return | meaning |
| --- | --- |
| `:retry` or `true` | retry, within the configured budget |
| `:abort` or `false` | do not retry |
| an `Integer` | retry at most that many attempts |
| a `Real` | retry for at most that many seconds |
| `nothing` | use the configured `failure` policy |

What happens after retries are exhausted is still the configured `failure`:
`:isolate`/`:retry` quarantine the batch; `:abort` fails the database.

The hook receives the `Database`, so it can inspect the unsaved work with
[`pending_writes`](../api/index.md), log the error, alert, or change its mind as an outage
drags on.

```julia
attempts = Ref(0)
cfg = DatabaseConfig(;
    dbname = "airdb_test", user = "airdb", password = "airdb",
    failure = :retry, retry_delay = 0.05,
    on_error = (db, err) -> begin
        attempts[] += 1
        n = length(pending_writes(db))          # the updates a retry would save
        @warn "database error; $n write(s) pending" exception = err
        n > 1000 ? :abort : :retry              # stop retrying if too far behind
    end,
)
```

A hook can also force a retry even when the configured policy is `:abort`:

```julia
cfg = DatabaseConfig(;
    dbname = "airdb_test", user = "airdb", password = "airdb",
    failure = :abort,                            # otherwise fail immediately
    on_error = (db, err) -> :retry,              # ... but this hook says retry
)
```

```{admonition} The budget is per operation
:class: note
Each flush and each read has its own attempt count and clock. During a long
outage, every read independently retries for up to `retry_time` before failing,
and the pipeline's queue keeps growing until it recovers or gives up.
```

## Next

[Inspecting failures](failures-inspection.md) covers the records a quarantine
leaves behind and how to clear or retry them.

