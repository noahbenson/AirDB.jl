# Commits and durability

<!-- review-status: unreviewed -->
:::{warning} Unreviewed content
This page was written with AI assistance and has not been reviewed by a human.
It may contain errors, omissions, or outdated information.
:::

This page follows a committed transaction to PostgreSQL. It assumes the
transaction model from [Transactions](stm.md).

## How a write reaches the database

AirDB intercepts the write, and — once per transaction — arranges for the
committed values to reach the write pipeline. Air guarantees that a message sent
during a transaction is dispatched only if the transaction commits, and in
commit order. So the database sees exactly the transactions that succeeded, in
the order they committed, and a retried transaction never leaves a trace.

```{admonition} What this means for you
:class: tip
You never call the writer directly, and you never write to the database by hand.
Write forms inside `@tx`, and AirDB does the rest. Use `AirDB.sync(db)` only when
something outside the process needs to observe the write.
```

## `sync`: waiting for durability

`AirDB.sync(db)` blocks until every update sent to the database before the call
has been written. Because the writer is sequential, once it has processed the
sync message every earlier write is on disk.

```julia
@tx widget[:n] = 42
AirDB.sync(db)              # the write is durable here
```

In a server you usually do **not** call `sync` after every write: writes are
queued and saved asynchronously. `sync` is for tests, shutdown, and the moments
when another process — or a later session — must see the write.

## Read-your-writes

Within one `Database`, a read always sees the latest committed value, even if
the writer has not yet reached PostgreSQL: the form is cached in memory and the
pending write keeps it alive.

```julia
@tx widget[:n] = 43
value(widget[:n])           # 43 — immediately, before the writer runs
AirDB.sync(db)              # now PostgreSQL also has 43
```

The cache and identity rules are in
[Lazy loading and the cache](lazy-loading-and-cache.md).

## Batching

By default each commit is written as soon as it reaches the writer. A larger
`max_batch` accumulates commits and writes several in one database transaction:

```julia
cfg = DatabaseConfig(; dbname = "airdb_test", user = "airdb",
                      password = "airdb", max_batch = 100)
```

A partial batch is flushed by `AirDB.sync`, by `close`, or when the threshold is
reached. Read-your-writes still holds while a batch is waiting: the forms in it
are pinned in memory.

## Status and closing

`AirDB.status(db)` reports the number of updates queued for the writer and the
last error it saw:

```julia
AirDB.status(db)            # (npending, last_error)
```

`close(db)` flushes queued writes and closes every connection; later operations
raise.

## Next

[Schema and history](schema-and-history.md) describes what the writer stores.
