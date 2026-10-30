# Actors

<!-- review-status: unreviewed -->
:::{warning} Unreviewed content
This page was written with AI assistance and has not been reviewed by a human.
It may contain errors, omissions, or outdated information.
:::

An `ActorForm` is a sequential worker whose value is a form. Sending it a
function updates the value; every update is persisted. It behaves like any other
form — it nests in containers, has a stable identity, and round-trips through
the database — while keeping its live semantics.

```julia
using AirDB, Air

af = ActorForm(db, form(n = 0))
af[]                          # Form(n=0)

send(af) do v
    form(n = value(v[:n]) + 1)
end
af[]                          # Form(n=1) — once the actor has processed it
```

Inside a transaction, `send` is deferred until the transaction commits, exactly
as with Air's actors; `af[]` is a transactional read. See
[Transactions](../transactions/stm.md).

`history` is fixed when the actor is created, like a `VolatileForm`'s:

```julia
ActorForm(db, form(n = 0); history = false)   # keep only the current value
```

An actor carries the same optional owner/ACL metadata as every database-backed
kind:

```julia
af = ActorForm(db, form(n = 0); metadata = form(owner = "alice"))
metadata(af)
@tx set_metadata!(af, form(owner = "bob"))
```

See [Metadata](../transactions/metadata.md).

## The actor table

An actor's current value is stored in `form_actor_current`; with history on,
each update also appends to `form_actor_history`:

```sql
CREATE TABLE form_actor_current (
    actor_id    UUID        PRIMARY KEY,
    version     BIGINT      NOT NULL,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    value       JSONB       NOT NULL,
    history     BOOLEAN     NOT NULL DEFAULT TRUE,
    metadata    JSONB
);
CREATE TABLE form_actor_history (
    actor_id    UUID        NOT NULL,
    version     BIGINT      NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    tx_id       BIGINT      NOT NULL,
    value       JSONB       NOT NULL,
    PRIMARY KEY (actor_id, version)
);
```

An actor loads lazily by id with `get_actor`, like any other database-backed
object (see [Lazy loading and the cache](../transactions/lazy-loading-and-cache.md)).
An actor row survives while a name, a live handle, or another reachable object
references it; [`gc!`](../operations/garbage-collection.md) sweeps it once
nothing does.

## Next

[Promises](promises.md) are the single-assignment counterpart.
