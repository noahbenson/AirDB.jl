# Extern types: storage and dead externs

<!-- review-status: unreviewed -->
:::{warning} Unreviewed content
This page was written with AI assistance and has not been reviewed by a human.
It may contain errors, omissions, or outdated information.
:::

This page assumes a type registered as in
[Extern types: registration](externs-registration.md) and covers what happens
when a form that holds one is stored.

## Storage

A named extern (`id = :something`) whose type has `serialize`/`deserialize` is
stored in the `resources` table, keyed by `(type, id)`, as the raw bytes those
functions produce:

```sql
CREATE TABLE resources (
    type      TEXT        NOT NULL,
    id        TEXT        NOT NULL,
    data      BYTEA       NOT NULL,
    metadata  JSONB,
    PRIMARY KEY (type, id)
);
```

The form itself stores only the reference:

```json
{"extern": "'counter", "id": ":c1"}
```

Reading the form back resolves the reference through the database's handle
registry; the bytes are read and deserialized the first time the data is used,
not when the form is loaded. Two forms that name the same `(type, id)` share one
handle — and therefore one lock and one version.

Every read-edit of a stored extern queues an update of its bytes to the
database's write pipeline, so the stored copy follows the live one. A
`MemoryDatabase` keeps extern data for the session and never writes it anywhere,
but otherwise behaves the same.

A stored extern is database-backed, so it carries optional owner metadata:
`metadata(c)` and `@tx set_metadata!(c, m)`; see
[Metadata](../transactions/metadata.md). Its row is swept by
[`gc!`](../operations/garbage-collection.md) when nothing references it.

## Dead externs

An extern that is **unnamed**, or whose type has **no serialization**, cannot be
stored. It is written as a marker with the type name only:

```json
{"extern": "'counter"}
```

Reading that back yields a `FormExtern` whose data is a `DeadExtern`. Using it —
`get_extern_API`, `call`, `reserve`, `reserve_read` — raises `ExternError`.

```julia
d = construct(get_extern_API(:counter), Form(Symbol(":new")), Form(3))
to_JSON(form(x = d))          # "[[], {\":x\": {\"extern\": \"'counter\"}}]"

r = from_JSON("[[], {\":x\": {\"extern\": \"'counter\"}}]")
value(r[:x])                  # a DeadExtern
get_extern_API(r[:x])         # ERROR: ExternError
```

A dead extern is still a form: it nests, compares, and round-trips. It simply
has no live data to call. Give the extern an `id` and its type a
`serialize`/`deserialize` pair to make it storable.

## Next

[Equivalence](../semantics/equivalence.md) compares two forms by value and type.
