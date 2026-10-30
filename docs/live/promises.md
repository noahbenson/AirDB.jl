# Promises

<!-- review-status: unreviewed -->
:::{warning} Unreviewed content
This page was written with AI assistance and has not been reviewed by a human.
It may contain errors, omissions, or outdated information.
:::

A `PromiseForm` is delivered once, with a form:

```julia
using AirDB, Air

pf = PromiseForm(db)
isready(pf)                   # false
put!(pf, form(x = 1))
isready(pf)                   # true
pf[]                          # Form(x=1)
put!(pf, form(x = 2))         # ERROR: already fulfilled
```

Delivery inside a transaction is staged and takes effect only if the transaction
commits. Reading an *undelivered* promise inside a transaction raises — waiting
there can deadlock — so test with `isready` first; outside a transaction `pf[]`
waits for delivery. See [Transactions](../transactions/stm.md).

## A promise is always a link

Every form that names a promise writes `"~<uuid>"`, whether the promise is
pending, delivered, or failed, and the promise always has a row in
`form_promise` to hold its state:

```julia
pf = PromiseForm(db)
to_JSON(form(p = pf))         # "[[], {\":p\": \"~<uuid>\"}]"       — a link
put!(pf, form(a = 1))
to_JSON(form(p = pf))         # "[[], {\":p\": \"~<uuid>\"}]"       — still a link
```

Writing the value inline would lose the handle: a reader of the stored form
could no longer tell who else was waiting on the promise, and a failure would
have no place to live. So the identity and the settled value both survive a
round trip — a reloaded form's promise is the same `PromiseForm` with the same
value — and `get_promise` reaches a promise by id at any time. The complete JSON
table is in [The JSON format](../semantics/json.md).

## States: pending, delivered, failed

Every promise row carries a state. A promise is **pending** until settled, then
**delivered** with a value or **failed** with an error form:

```julia
pf = PromiseForm(db)
fail!(pf, form(err = :boom))     # settle as failed
isready(pf)                      # true — a settled promise is ready
isfailed(pf)                     # true
pf[]                             # ERROR: Air.PromiseFailed(err = :boom)
put!(pf, form(x = 1))            # ERROR: already settled
```

The error is stored as a form, so another process can reload the promise and
receive the same failure. A promise settles exactly once; the database update is
a compare-and-set, and a settlement creates the promise's row if it does not
exist yet.

## Uncommitted promises

A promise created inside a transaction can be marked as not yet committed:

```julia
pf = PromiseForm(db; pending_commit = true)   # :pending
isready(pf)                                   # ERROR: UncommittedPromise
put!(pf, form(x = 1))                         # settling is allowed
mark_committed!(pf)                            # :live — now readable
```

`mark_aborted!` makes every read and settlement raise `AbortedPromise`. A
promise reloaded by id is always `:live`.

## The promise table

```sql
CREATE TABLE form_promise (
    promise_id   UUID        PRIMARY KEY,
    state        TEXT        NOT NULL DEFAULT 'pending'
                             CHECK (state IN ('pending','delivered','failed')),
    value        JSONB,                 -- the delivered value
    error        JSONB,                 -- the failure form
    metadata     JSONB,
    settled_at   TIMESTAMPTZ
);
```

Like every database-backed kind, a promise carries optional owner metadata:
`metadata(pf)` and `set_metadata!(pf, m)`; see
[Metadata](../transactions/metadata.md). A promise row is reachable like any
other object and is swept by [`gc!`](../operations/garbage-collection.md) when
nothing references it.

## Next

[Delays](delays.md) are the run-once lazy counterpart.
