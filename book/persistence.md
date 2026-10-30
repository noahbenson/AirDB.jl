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
    metadata    JSONB,
    PRIMARY KEY (type, id)
);

-- Actor and promise forms (see Actor, promise, and delay forms).
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
CREATE TABLE form_promise (
    promise_id   UUID        PRIMARY KEY,
    state        TEXT        NOT NULL DEFAULT 'pending'
                             CHECK (state IN ('pending','delivered','failed')),
    value        JSONB,                 -- the delivered value
    error        JSONB,                 -- the failure form
    metadata     JSONB,
    settled_at   TIMESTAMPTZ
);
CREATE TABLE form_stream (
    stream_id  UUID        PRIMARY KEY,
    items      JSONB       NOT NULL DEFAULT '[]',  -- the queued forms
    maxsize    INTEGER,                            -- NULL = unbounded
    closed     BOOLEAN     NOT NULL DEFAULT FALSE,
    metadata   JSONB,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
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

Every database-backed kind carries an optional `metadata` JSONB blob (owner/ACL
information for the caller to interpret). `metadata(x)` reads it with a
metadata-only query and never fetches or decodes the payload; `set_metadata!`
rewrites only the metadata. A promise's `state` is settled by a compare-and-set
that only matches a `pending` row, so a promise settles exactly once.

```julia
db = create_database(cfg; overwrite = true)
vf = VolatileForm(db, "widget", n = 1)
AirDB.sync(db)

@tx vf[:n] = 2
AirDB.sync(db)
# form_current:  version = 2
# form_history:  (version 1, tx_id 1), (version 2, tx_id 2)
```

## Garbage collection

Rows accumulate for objects nothing refers to any more: an unnamed form, an
actor that finished, a promise whose referrer is gone — delivered or not, since
every promise has a row. `gc!(db)` sweeps them:

```julia
stats = gc!(db)        # or gc!(db; dry_run = true) to see what would go
stats.swept_forms      # how many form rows were removed
```

The roots are every name in `form_name` and every **live in-memory object** — a
`VolatileForm`, `ActorForm`, `PromiseForm`, or extern handle that is still
reachable in the process. Everything else is reachable only through links inside
stored forms, so the sweep crawls the payloads, marks what the roots reach, and
deletes the rest (with `form_history`/`form_actor_history` rows for the deleted
objects; live objects keep their full history).

The sweep runs as one job on the writer task, so it sees a consistent
snapshot and only writes wait behind it; reads continue on the read pool. Object
loading is serialized with it, so a row cannot be swept while it is being loaded.

Two things to know:

- A name is a root forever unless you release it with `delete_name!(db, name)`.
- Because live in-memory objects are roots, collection is *conservative*: an
  object still referenced anywhere in the process is kept. That is always safe —
  `gc!` never removes something in use — but a just-released object may survive
  one sweep.

Links are found by a structural scan of the stored JSON: every link string begins
with a marker (`@`, `!`, `~`, `&`, or an `{"extern": …}` object), while user
strings begin with `'` and symbols with `:`, so the scan cannot mistake data for
a link. A payload the reader itself would reject (a malformed marker) is not a
link the sweep can resolve, either; such a row is left alone rather than being
read as reachable.

`MemoryDatabase` implements the same sweep over its in-memory stores.

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
While a batch is waiting, the forms in it are pinned by the pipeline's queues, so a
lookup is a cache hit rather than a database read. You always see the latest
committed value in-process, even before it reaches the database.
```
