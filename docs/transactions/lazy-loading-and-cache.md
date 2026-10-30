# Lazy loading and the cache

<!-- review-status: unreviewed -->
:::{warning} Unreviewed content
This page was written with AI assistance and has not been reviewed by a human.
It may contain errors, omissions, or outdated information.
:::

A database-backed form is identified by its UUID. `get_form(db, id)` returns the
live form if it is still in memory, and otherwise a **fresh handle** whose body
is read from the database the first time it is needed.

```julia
vf = VolatileForm(db, n = 1)
id = vf.id
get_form(db, id) === vf          # true — the same object while it is alive
AirDB.isloaded(get_form(db, id)) # true

# drop every reference and collect: the cache releases it
vf = nothing
GC.gc(); GC.gc()

r = get_form(db, id)
AirDB.isloaded(r)                # false — only the id is known so far
value(r[:n])                     # the body is loaded from PostgreSQL here
```

## One object per id

The cache holds each form through a `WeakRef`, so it never keeps a form alive on
its own: a form stays cached exactly as long as something else references it, and
is released back to the database once nothing does. The same id always yields the
same object within one `Database`, which is what keeps Air's transactional reads
on a form coherent across threads:

```julia
id = ...
results = Vector{VolatileForm}(undef, 16)
@sync for i in 1:16
    Threads.@spawn (results[i] = get_form(db, id))
end
all(r -> r === results[1], results)   # true
```

The same identity rule applies to actors, promises, and streams through
`get_actor`, `get_promise`, and `get_stream`, introduced in
[Live objects](../live/actors.md).

## Lazy loading is safe

Loading happens on first use and only for the object touched; the forms it links
to stay unloaded until they are touched in turn. That is why loading a parent
does not pull in the whole database.

Inside a transaction, loading a form is also a transactional read: the form is
registered with the transaction, so a concurrent change makes the attempt retry.
See [Transactions](stm.md) and [Links between forms](links-between-forms.md).

## Reopening a database

Closing and reopening a `Database` leaves the ids valid; a later session loads
the forms on demand:

```julia
close(db)
db = open_database(cfg)
r = get_form(db, id)
value(r[:n])
```

## Next

[Links between forms](links-between-forms.md) describes how a stored form
points at another.
