# Extern types: calling and reservations

<!-- review-status: unreviewed -->
:::{warning} Unreviewed content
This page was written with AI assistance and has not been reviewed by a human.
It may contain errors, omissions, or outdated information.
:::

This page assumes a type registered as in
[Extern types: registration](externs-registration.md). Its stored form is covered
in [Extern types: storage](externs-storage-and-dead-externs.md).

## Calling operations

An operation is called through `api.call`:

```julia
reserve_read(c) do api
    api.call(Form(Symbol(":get")), form())      # Form(3)
end
```

For an **immutable** type the API is available directly, from any thread:

```julia
api = get_extern_API(config_extern)
api.call(Form(Symbol(":version")), form())
```

For a **mutable** type, asking for the API directly raises. Its data is shared
memory that can be edited, so access is always through a reservation.

## Reservations

`reserve_read` takes the read locks of every resource, in sorted `(type, id)`
order (which prevents deadlock), runs the function on the caller's task, and
returns its value. Read-only operations run concurrently with one another, and
never during a read-edit.

`reserve` takes the **write** locks, runs the function on a spawned task, and
returns an `ExternPromise`; wait on it with `p[]`:

```julia
p = reserve(a, b) do api_a, api_b
    api_a.call(Form(Symbol(":bump")), form())
    api_b.call(Form(Symbol(":bump")), form())
end
p[]                     # (Form(2), Form(3))
```

Resources are always passed to the function in sorted order, so the arguments'
positions depend on their names, not the order you named them. A read-edit of a
stored extern also queues an update of its bytes to the database writer, so the
stored copy follows the live one.

## Transactions

Every resource carries a version. A read made inside an `@tx` registers that
version with Air, and every read-edit increments it. If a read-edit happens
between a transaction's first read and its commit, Air's ordinary commit
validation fails and the transaction retries — so a transaction always sees a
consistent resource state, without holding a lock for its duration. See
[Transactions](../transactions/stm.md).

A `reserve` called inside a transaction behaves specially:

- its function does **not** run until the transaction commits, and is discarded
  if the transaction retries;
- the reservation counts as a read, so its resources' versions must be unchanged
  at commit;
- reading the returned promise before the transaction completes raises, since
  waiting there could deadlock.

```julia
@tx begin
    p = reserve(c) do api
        api.call(Form(Symbol(":bump")), form())
    end
    # p[] here would raise; use it after the transaction
end
```

The lock and version rules are per resource, so a transaction that touches two
externs validates both. Externs take part in the same failure handling as the
other kinds: a failed write is quarantined or aborts the database according to
the [failure policy](../operations/failures-policies.md).

## Next

[Extern types: storage](externs-storage-and-dead-externs.md) covers the
`resources` table and dead externs.
