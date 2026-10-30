# Schema and history

<!-- review-status: unreviewed -->
:::{warning} Unreviewed content
This page was written with AI assistance and has not been reviewed by a human.
It may contain errors, omissions, or outdated information.
:::

AirDB keeps an append-only history and an up-to-date snapshot of forms, plus the
tables for named forms and the live-object kinds introduced later. This page
covers the core form tables; each live kind's table is described on its page.

## The core tables

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

-- The alias table for named forms (see Named forms).
CREATE TABLE form_name (
    name        TEXT        PRIMARY KEY,
    form_id     UUID        NOT NULL REFERENCES form_current(form_id)
);
```

Every committed update appends a new row to `form_history` and upserts
`form_current`, in one database transaction. Reads fetch exclusively from
`form_current`, so a lookup is an indexed point read by `form_id`. The version
is assigned by the database (1 on the first insert, one more each time), and
`tx_id` groups the rows written by a single commit.

```julia
db = create_database(cfg; overwrite = true)
vf = VolatileForm(db, "widget", n = 1)
AirDB.sync(db)

@tx vf[:n] = 2
AirDB.sync(db)
# form_current:  version = 2
# form_history:  (version 1, tx_id 1), (version 2, tx_id 2)
```

## History

A form created with `history = false` skips the history row: its current row is
overwritten in place. The choice is fixed when the form is created:

```julia
vf = VolatileForm(db, n = 1; history = false)
```

A [promise](../live/promises.md), [actor](../live/actors.md), and
[stream](../live/streams.md) have the same option on their own tables; their
pages give the details.

## Metadata

Every database-backed kind has an optional `metadata` JSONB blob (owner/ACL
information for the caller to interpret), stored alongside the payload. It is
readable with a metadata-only query and edited transactionally; see
[Metadata](metadata.md).

## Next

[Lazy loading and the cache](lazy-loading-and-cache.md) explains how a form is
identified and loaded.
