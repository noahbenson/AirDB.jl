# Inspecting failures

<!-- review-status: unreviewed -->
:::{warning} Unreviewed content
This page was written with AI assistance and has not been reviewed by a human.
It may contain errors, omissions, or outdated information.
:::

Under the default `failure = :isolate` policy a batch that cannot be saved is
**quarantined**: its committed in-memory values remain readable, the failure is
recorded with the objects and pending writes it contained, and unrelated reads
and writes continue. This page covers the recording and inspection API; the
policies themselves are in [Failure policies](failures-policies.md).

## Write failures

```julia
write_failures(db)               # Vector{FailureRecord}, oldest first
write_failures(db, id)           # the records touching one object
failed(db, id)                   # is this object currently unsaved?
```

The `id` may be a `UUID`, an extern `(type, id)` pair, a name, or an explicit
`(kind, id)` key.

A `FailureRecord` is one quarantined batch:

| field | meaning |
| --- | --- |
| `sequence` | the batch's sequence number |
| `error` | the database error |
| `time` | when it happened |
| `items` | the `FailedItem`s it contained |

A `FailedItem` is one object:

| field | meaning |
| --- | --- |
| `kind` | `:form`, `:actor`, `:promise`, `:stream`, `:extern`, or `:name` |
| `id` | a `UUID`, an extern `(type, id)` pair, or a name |
| `object` | the live object, when one is known |
| `write` | the pending write that failed (value, metadata, history, txid) |

```julia
r = first(write_failures(db))
r.error                          # the database error
r.items[1].kind                  # :form
r.items[1].object                # the live VolatileForm
r.items[1].write                 # the pending write
```

## Clearing and retrying

```julia
clear_write_failure!(db, id)             # acknowledge the loss
clear_write_failure!(db, id; retry = true)   # re-stage the current value
clear_write_failures!(db)                # clear every record
```

With the default `retry = false`, clearing only acknowledges the loss and
unblocks loading again: a later reload reads the older row. With `retry = true`
the object's **current** value is re-staged, so a retry cannot regress a newer
write. Call `AirDB.sync(db)` afterwards to wait for the new attempt.

```julia
clear_write_failure!(db, vf.id; retry = true)
AirDB.sync(db)
```

## Loading a quarantined object

A live in-memory object is still readable while its write is quarantined.
Reloading it would silently return the older database row, so loading raises
`FailedObjectError` until the failure is cleared:

```julia
failed(db, vf.id)                # true
get_form(db, vf.id)              # ERROR: FailedObjectError
```

## Read failures

Read errors are recorded separately, since they are not durability gaps:

```julia
read_failures(db)                # Vector{ReadFailure}, oldest first
read_failures(db, id)            # those for one object
clear_read_failures!(db)         # forget them
```

A `ReadFailure` records the `error`, the `time`, the `operation` (`:load`,
`:metadata`, `:name`, `:read`, …), and the object `id` when there was one. The
history is bounded (the most recent 1024 failures are kept), so a long outage
cannot grow it without limit. Under `:isolate` a failed read raises to its
caller but does not poison later reads; under `:abort` a read failure fails the
whole database, as described in [Failure policies](failures-policies.md).

## Next

[Garbage collection](garbage-collection.md) reclaims rows nothing refers to.
