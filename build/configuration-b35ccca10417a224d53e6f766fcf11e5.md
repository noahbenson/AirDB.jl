# Configuration and lifecycle

<!-- review-status: unreviewed -->
:::{warning} Unreviewed content
This page was written with AI assistance and has not been reviewed by a human.
It may contain errors, omissions, or outdated information.
:::


The configuration a `Database` is built from, the database object itself,
and the operations that apply to the whole database: waiting for a write
to become durable, inspecting the writer, and closing it.

(api-databaseconfig)=
## DatabaseConfig

```julia
DatabaseConfig(; dbname, user, host="localhost", port=5432, password=nothing,
                 sslmode="prefer", connect_timeout=10, readpoolsize=8,
                 max_batch=1, failure=:isolate, retries=nothing, retry_time=nothing,
                 retry_delay=0.1, retry_delay_max=5.0, on_error=nothing,
                 conninfo=nothing)
DatabaseConfig(url::AbstractString; kwargs...)
```

The parameters AirDB uses to reach a PostgreSQL database and to decide how it
behaves. The server is the user's to configure and manage; AirDB only connects.

`dbname` and `user` are required unless `conninfo` is given. `conninfo`, when
set, is a libpq connection string or URI used verbatim (as built by the
`url` method), and the structured fields are ignored.

* `readpoolsize` — how many read connections to keep in the pool.
* `max_batch` — how many committed updates the pipeline accumulates before
  flushing. `1` (the default) writes every commit as soon as it arrives.
* `failure` — what to do when an operation fails permanently:
  * `:isolate` (the default) — quarantine the failing batch, record it (see
    [`write_failures`](failures.md#api-write-failures)), and keep serving unrelated reads and writes.
  * `:abort` — the write pipeline stops and every database operation raises.
  * `:retry` — a compatibility alias for the isolated retry path.
  `:isolate` and `:retry` retry within the budget before quarantining; `:abort`
  gives up immediately.
* `retries` / `retry_time` — the retry budget: at most this many attempts, or at
  most this many seconds. If both are given, whichever runs out first wins; if
  neither is given under `:isolate`/`:retry`, a small default is used.
* `retry_delay` / `retry_delay_max` — the delay before the first retry and its
  ceiling; the delay doubles after each failed attempt up to the ceiling.
* `on_error` — a hook `on_error(db, err)` called on every database error, before
  the policy is applied. It may return `:retry` or `:abort` to override the
  policy, an `Integer` to retry at most that many more times, a `Real` to retry
  for that many seconds, or `nothing` to use the configured policy. It can read
  [`pending_writes`](failures.md#api-pending-writes) on `db` to see the unsaved updates.
* `encoder_tasks` — how many tasks encode committed batches (the form JSON,
  extern serialization, stream snapshots). Encoding happens after commit and in
  parallel with database writes; the default is `max(1, min(4, nthreads()-1))`.
* `max_pending` — the most committed-but-unwritten batches allowed before a
  committing thread waits. This bounds the writer's lag; the default is `256`.


(api-database)=
## Database

```julia
Database
```

A configured connection to a PostgreSQL database, plus the machinery AirDB keeps
around it: a pool of read connections, a weak cache of live `VolatileForm`s, an
intake actor, an encoder pool, and a single ordered writer task that persists
committed updates in global commit order.

Create one with [`create_database`](#api-create-database) (to initialize a new database) or
[`open_database`](#api-open-database) (to open an existing one).


(api-create-database)=
## create_database

```julia
create_database(config::DatabaseConfig; overwrite::Bool=false) -> Database
```

Initializes a new AirDB database in the PostgreSQL instance described by
`config` — creating the `form_history`, `form_current`, and `airdb_meta` tables
and starting a `Database` for it. The server itself is the user's to provide and
manage.

With `overwrite=true` the three AirDB tables are dropped and recreated first.


(api-open-database)=
## open_database

```julia
open_database(config::DatabaseConfig) -> Database
```

Opens an AirDB database that already exists in the PostgreSQL instance described
by `config`. Raises if the AirDB schema is missing (use [`create_database`](#api-create-database)
to make one).


(api-memorydatabase)=
## MemoryDatabase

```julia
MemoryDatabase() -> MemoryDatabase
```

A fake, in-memory [`Database`](#api-database) for testing without PostgreSQL. It behaves
like a real database — forms persist across commits, named forms work, `sync`
blocks — but keeps everything in memory, saves nothing, and keeps no history.


(api-sync)=
## sync

```julia
sync(db::Database)
```

Blocks until every update sent to `db` before this call has been written to the
database. The pipeline's writer is sequential, so once it has passed the sync
barrier every earlier write is durable.

Under `:isolate`, a quarantined batch does not make `sync` raise (see
[`write_failures`](failures.md#api-write-failures)); under `:abort`, the recorded `DatabaseError` is
raised.


(api-status)=
## status

```julia
status(db::Database) -> (npending, error)
```

The number of updates queued for the writer but not yet written, and the last
error the writer saw (or `nothing`). The intake is asynchronous, so a commit
that has just returned may not be counted yet; [`sync`](#api-sync) waits for it.


(api-close)=
## close

```julia
close(sf::StreamForm)
```

Closes the stream: a later `put!` raises `Air.StreamClosed`, and a `take`
drains what remains and then raises it too. Idempotent; staged inside a
transaction.


```julia
close(db::Database)
```

Flushes any queued writes and closes every connection the database holds. Further
operations raise.


(api-databaseerror)=
## DatabaseError

```julia
DatabaseError(cause, failed_writes)
```

Raised, or recorded on a `Database`, when a database operation fails under the
`:abort` policy. `cause` is the underlying exception and `failed_writes` holds the
updates that could not be saved.


(api-formnotfound)=
## FormNotFound

```julia
FormNotFound(id)
```

Raised when a form's id is not present in the database.


