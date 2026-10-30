# Transactions and volatile forms

A `VolatileForm` is a thin wrapper around an Air `Volatile{Form}`. It can be read
at any time, but it may only be **written inside a transaction**, and when that
transaction commits, the new value is sent to the database's writer.

## Writing inside a transaction

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

## How a write reaches the database

AirDB intercepts the write, and — once, per transaction — arranges for the
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

## Reading inside a transaction

Reading a form inside a transaction registers an Air read, so the transaction
sees a consistent value and will be re-run if it changes. A form that has not yet
been loaded from the database is loaded on first access — that is ordinary lazy
loading (see [Persistence](persistence.md)), and it is safe to do inside a
transaction.

```julia
@tx begin
    current = value(widget[:n])   # read (and register)
    widget[:n] = current + 1 # write
end
```

## Volatile forms link to one another

Because a form may hold a `VolatileForm`, forms compose into a tree of
independently-versioned pieces. A transaction that reaches through a child form
reads it and (if it writes) writes only the part it actually changes; see
[Indexing and updating](indexing.md) for the details.

```julia
child  = VolatileForm(db, n = 0)
parent = VolatileForm(db, name = "parent", child = child)

@tx parent[:child, :n] = 1     # writes `child`, reads `parent`
```
