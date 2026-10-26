# Persistence

## The schema

AirDB keeps an append-only history and an up-to-date snapshot of forms, plus the
bytes of stored externs.

```sql
CREATE TABLE form_history (
    form_id     UUID        NOT NULL,
    version     BIGINT      NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    tx_id       BIGINT      NOT NULL,
    payload     JSONB       NOT NULL,
    metadata    JSONB,
    PRIMARY KEY (form_id, version)
);

CREATE TABLE form_current (
    form_id     UUID        PRIMARY KEY,
    version     BIGINT      NOT NULL,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    payload     JSONB       NOT NULL,
    metadata    JSONB,
    history     BOOLEAN     NOT NULL DEFAULT TRUE
);

-- An alias table for well-known forms (see Named forms).
CREATE TABLE form_name (
    name        TEXT        PRIMARY KEY,
    form_id     UUID        NOT NULL REFERENCES form_current(form_id)
);

-- The bytes of named, serializable externs (see Extern types).
CREATE TABLE resources (
    type        TEXT        NOT NULL,
    id          TEXT        NOT NULL,
    data        BYTEA       NOT NULL,
    PRIMARY KEY (type, id)
);
```

Every committed update appends a new row to `form_history` and upserts
`form_current`, in one database transaction. Reads fetch exclusively from
`form_current`, so a lookup is an indexed point read by `form_id`. The version is
assigned by the database (1 on the first insert, one more each time), and `tx_id`
groups the rows written by a single commit.

A form created with `history = false` skips the history row: its current row is
overwritten in place, while still carrying its `metadata` and `payload`. The
`history` choice is fixed when the form is created.

```julia
db = create_database(cfg; overwrite = true)
vf = VolatileForm(db, "widget", n = 1)
AirDB.sync(db)

@tx vf[:n] = 2
AirDB.sync(db)
# form_current:  version = 2
# form_history:  (version 1, tx_id 1), (version 2, tx_id 2)
```

## Lazy loading and the cache

A form is identified by its UUID. `get_form(db, id)` returns the live form if it
is still in memory, and otherwise a **fresh handle** whose body is read from the
database the first time it is needed.

```julia
id = vf.id
get_form(db, id) === vf          # true — the same object while it is alive
AirDB.isloaded(get_form(db, id)) # true

# drop every reference and collect: the cache releases it
vf = nothing
GC.gc(); GC.gc()

r = get_form(db, id)
AirDB.isloaded(r)                # false — only the id is known so far
value(r[:n])                      # 2     — the body is loaded from PostgreSQL here
```

The cache holds each form through a `WeakRef`, so it never keeps a form alive on
its own: a form stays cached exactly as long as something else references it, and
is released back to the database once nothing does. The same id always yields the
same object within one `Database`, which is what keeps Air's transactional reads
on a form coherent across threads.

## Links between forms

A form may hold another `VolatileForm`. It is stored as the string `"@<uuid>"`,
never expanded, so a form that links to itself — or in a cycle — still encodes.

```julia
child  = VolatileForm(db, v = 1)
parent = VolatileForm(db, name = "parent", kid = child)
AirDB.sync(db)

AirDB.to_JSON(parent[])
# "[[], {\":kid\": \"@<uuid-of-child>\", \":name\": \"'parent\"}]"
```

Reading the parent loads only the parent; the child is loaded when it is touched.

```julia
parent[:kid]            # the child VolatileForm — not expanded
value(parent[:kid][:v])  # 1 — now the child is loaded
```

Because loading a form never expands the forms it links to, loading a parent does
not pull in the whole database, and cyclic references are handled without
recursion.

## Cross-commit batching

By default each commit is written as soon as the writer receives it. Setting
`max_batch` lets the writer accumulate several commits and write them in one
database transaction — useful under heavy load.

```julia
bcfg = DatabaseConfig(; dbname = "airdb_test", user = "airdb", max_batch = 3)
bdb = create_database(bcfg; overwrite = true)

bf = VolatileForm(bdb, n = 0)
AirDB.sync(bdb)

@tx bf[:n] = 1
@tx bf[:n] = 2                  # fewer than max_batch: not written yet ...
value(bf[:n])                    # 2 — ... but the in-memory value is current
@tx bf[:n] = 3                  # the third fills the batch; it is written at once
AirDB.sync(bdb)                 # sync flushes a partial batch too
```

```{admonition} Read-your-writes still holds
:class: note
While a batch is waiting, the forms in it are pinned by the writer's queue, so a
lookup is a cache hit rather than a database read. You always see the latest
committed value in-process, even before it reaches the database.
```
