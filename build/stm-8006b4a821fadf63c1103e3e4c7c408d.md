# Transactions

<!-- review-status: unreviewed -->
:::{warning} Unreviewed content
This page was written with AI assistance and has not been reviewed by a human.
It may contain errors, omissions, or outdated information.
:::

AirDB's writes go through Air's software transactional memory. This page explains
the transaction model from scratch; the database side — how a commit becomes a
durable write — is the next page,
[Commits and durability](commits-and-durability.md).

## Writing inside a transaction

A `VolatileForm` is a thin wrapper around an Air `Volatile{Form}`. It can be read
at any time, but it may only be **written inside a transaction**:

```julia
using AirDB, Air

widget = VolatileForm(db, "widget", n = 1)

@tx widget[:n] = 42       # stage the change ...
# ... it commits here, and the writer is told to save the new form
value(widget[:n])          # 42
```

Outside a transaction a write is an error, inherited from Air:

```julia
widget[:n] = 5
# ERROR: cannot set volatile outside of transaction
```

The `tx` function is the non-macro form, handy when you already have a closure:

```julia
tx(() -> (widget[:n] = value(widget[:n]) + 1))
```

## A commit is atomic

All the writes in one transaction become visible together, and all the sends are
dispatched together, in commit order. A commit that changes several forms writes
them to the database in a single database transaction, so a reader never sees
half of a commit.

```julia
a = VolatileForm(db, kind = "A")
b = VolatileForm(db, kind = "B")

@tx begin
    a[:v] = 1
    b[:v] = 2
end
AirDB.sync(db)
(value(a[:v]), value(b[:v]))   # (1, 2) — both landed together
```

## The body may run more than once

Air is optimistic: a transaction records what it reads, and if any of those
values change before it commits, the transaction is discarded and re-run. So the
body of a transaction must be free of side effects other than the transactional
ones.

```julia
# Good: the only side effect is the transactional write.
@tx widget[:n] = value(widget[:n]) + 1

# Bad: this prints a different number of times depending on contention.
@tx begin
    println("attempt")          # do not do this
    widget[:n] = value(widget[:n]) + 1
end
```

If the body throws, nothing is written:

```julia
try
    @tx begin
        widget[:n] = 99
        error("abort")
    end
catch
end
value(widget[:n])                 # still 42 — the write never happened
```

## Reading inside a transaction

Reading a form inside a transaction registers an Air read, so the transaction
sees a consistent value and will be re-run if it changes. A form that has not
yet been loaded from the database is loaded on first access; that is ordinary
lazy loading (see
[Lazy loading and the cache](lazy-loading-and-cache.md)), and it is safe inside
a transaction.

```julia
@tx begin
    current = value(widget[:n])   # read (and register)
    widget[:n] = current + 1      # write
end
```

## Read-your-writes and durability

Within one process, a read always sees the latest committed value even if the
database writer has not caught up: the live form is cached in memory. Making a
write durable — waiting until PostgreSQL has it — is the subject of
[Commits and durability](commits-and-durability.md).

## Next

[Commits and durability](commits-and-durability.md) follows a commit to the
database.
