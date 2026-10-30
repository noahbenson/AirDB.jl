# Streams

<!-- review-status: unreviewed -->
:::{warning} Unreviewed content
This page was written with AI assistance and has not been reviewed by a human.
It may contain errors, omissions, or outdated information.
:::

A `StreamForm` is a FIFO of forms backed by an Air `Stream{Form}`. It is like a
promise that can be written and read repeatedly: `put!` appends, `take` removes
the oldest value, and both block when they cannot proceed. The stream can be
bounded, can time out, and can be closed, and its queued contents are persisted.

```julia
using AirDB

sf = StreamForm(db; maxsize = 3)
put!(sf, form(id = 1))
put!(sf, form(id = 2))

length(sf)        # 2
snapshot(sf)      # Form[Form(id=1), Form(id=2)] — a copy; nothing is removed
take(sf)          # Form(id=1)
take(sf)          # Form(id=2)
```

## Bounds, timeouts, and closing

`maxsize` bounds how many forms may wait: `nothing` (the default) leaves the
stream unbounded, so `put!` never waits. A write to a full stream waits for a
read to make room. Both reads and writes accept `timeout` (in seconds) and a
cancellation `token`, as Air's `take` and `put!` do:

```julia
sf = StreamForm(db; maxsize = 1)
put!(sf, 1)
put!(sf, 2; timeout = 0.05)   # ERROR: Air.ReaderTimeout

take(sf)                       # 1 — the timeout freed nothing
take(sf; timeout = 0.05)       # ERROR: Air.ReaderTimeout (now empty)
```

`close(sf)` ends the stream: a later `put!` raises `Air.StreamClosed`, while a
`take` drains the values that remain and then raises it too.

```julia
put!(sf, 7); close(sf)
take(sf)      # 7
take(sf)      # ERROR: Air.StreamClosed
```

`isopen`, `length`, `isempty`, `isready`, and `maxsize` inspect a stream without
blocking.

## Transactions

Air stages stream operations inside `@tx`: a `put!`, `take`, or `close` inside a
transaction happens only if the transaction commits, the transaction that staged
it sees its own writes and reads, and a concurrent change makes the attempt
retry. A blocking operation on a stream created in the current transaction
raises `Air.StreamDeadlock` — no other task can reach it until the commit — and
a stream first *loaded* in the transaction is treated the same way. AirDB sends
the stream's updated contents to the database writer only if the transaction
commits. See [Transactions](../transactions/stm.md).

## Commit state

A stream created inside a transaction can be marked as not yet committed, just
like a promise:

```julia
sf = StreamForm(db; pending_commit = true)
isready(sf)          # ERROR: UncommittedStream
put!(sf, form(x = 1))  # writing a pending stream is allowed
mark_committed!(sf)    # :live — reads work now
```

`mark_aborted!` makes every operation raise `AbortedStream`. A stream reloaded
by id is always `:live`.

## Persistence

A stream's queued forms, its `maxsize`, whether it is closed, and its metadata
are stored in `form_stream`, one row per stream:

```sql
CREATE TABLE form_stream (
    stream_id  UUID        PRIMARY KEY,
    items      JSONB       NOT NULL DEFAULT '[]',  -- the queued forms
    maxsize    INTEGER,                            -- NULL = unbounded
    closed     BOOLEAN     NOT NULL DEFAULT FALSE,
    metadata   JSONB,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);
```

Every successful `put!`, `take`, or `close` sends an updated snapshot to the
writer, so the row follows the queue with the usual delayed-write lag; a reload
restores the contents and the stream's state.

```julia
sf = StreamForm(db; maxsize = 3)
put!(sf, form(a = 1)); close(sf)
AirDB.sync(db)

r = get_stream(db, sf.id)     # the same object while it is alive
snapshot(r)                   # the queued forms
```

In JSON a stream is always a link, written `"&<uuid>"`; reading one needs a
database. See [The JSON format](../semantics/json.md). A stream carries optional
owner metadata: `metadata(sf)` and `set_metadata!(sf, m)`; see
[Metadata](../transactions/metadata.md). Its row is swept by
[`gc!`](../operations/garbage-collection.md) when nothing references it.

## Next

[Extern types](externs-registration.md) turn to host-level values.
