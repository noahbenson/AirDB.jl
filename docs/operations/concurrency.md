# Concurrency

<!-- review-status: unreviewed -->
:::{warning} Unreviewed content
This page was written with AI assistance and has not been reviewed by a human.
It may contain errors, omissions, or outdated information.
:::

AirDB is built for many threads sharing data. The model is simple: **many readers
and writers, one ordered writer**.

## Many threads, one ordered writer

Reads go through a pool of connections and never wait on the writer. A commit
hands its batch to an intake actor and returns; a pool of **encoder tasks** turns
committed batches into their JSON payloads, extern bytes, and stream snapshots;
one **writer task** owns the PostgreSQL connection and writes prepared batches in
commit order. So the database sees transactions in exactly the order they were
enqueued — no deadlocks, no row-level lock contention, no two writers racing —
while a slow form or extern serialization no longer holds up the commit path or
the writer's intake.

```julia
counter = VolatileForm(db, n = 0)
AirDB.sync(db)

@sync for _ in 1:50
    Threads.@spawn tx(() -> (counter[:n] = value(counter[:n]) + 1))
end
AirDB.sync(db)

value(counter[:n])                 # 50 — every increment committed exactly once
```

`max_pending` bounds how far the writer may lag: a committing thread waits only
when that many committed batches are still unwritten. `encoder_tasks` controls
the encoding pool (the default is `max(1, min(4, nthreads()-1))`).

Under contention Air re-runs transactions that lose a race, so the *final* value
is correct even though the bodies run more than once. The history reflects only
the commits that succeeded, one row each.

Run Julia with more than one thread to see real contention:

```bash
JULIA_NUM_THREADS=4 julia --project=. examples/quickstart.jl
```

## What each kind of object makes atomic

The general rule is the same for everything: **inside a transaction, a read is
validated and a staged write commits with it — or the whole attempt is discarded
and retried. Outside a transaction, operations happen immediately.** What differs
between kinds is only which operations are staged.

| object | inside a transaction | outside a transaction | when the database write is sent |
| --- | --- | --- | --- |
| `VolatileForm` | reads and writes are transactional; a write is staged | a write raises | on commit (subject to batching) |
| metadata (any kind) | `set_metadata!` is staged and visible to the transaction; reads are validated too | `set_metadata!` raises; reads are immediate | on commit |
| `ActorForm` | `send` is deferred until commit | `send` runs on the actor at once | when the actor applies the update |
| `PromiseForm` | `put!`/`fail!` are staged and visible to the transaction; reading an unsettled promise raises | settle and read at once (a read waits) | on commit (or immediately outside) |
| `StreamForm` | `put!`/`take`/`close` are staged by Air; a stream first loaded in the transaction raises `StreamDeadlock` if an operation would block | operations happen at once (they may block) | on commit (or immediately outside) |
| named extern | `reserve`/`reserve_read` work; a read-edit's version is validated at commit | operations happen at once | after each read-edit |

A form written while it holds a promise or stream that lives in the database is
queued behind that object's own write, so a form never names a row that does not
exist.

### Streams and transactions

A stream *created* in a transaction cannot be reached by another thread until
that transaction commits — a second loader would be a different in-memory stream
— so an operation there that would block raises `Air.StreamDeadlock` rather than
waiting forever. A stream merely *loaded* inside a transaction is treated the
same way for this purpose. This is Air's deliberate choice; see
[`TODO.md`](https://github.com/noahbenson/AirDB.jl/blob/main/TODO.md) for the
open question of whether a loaded stream should be allowed to block.

## One object per id

`get_form` returns the same object for a given id as long as it is alive, no
matter which thread asks, so two threads that hold a form share its value and its
transactional identity.

```julia
id = ...
results = Vector{VolatileForm}(undef, 16)
@sync for i in 1:16
    Threads.@spawn (results[i] = get_form(db, id))
end
all(r -> r === results[1], results)   # true
```

## Garbage-collection safety

A form queued for a write is held by the pipeline's queues until the write succeeds,
so it cannot be collected — and reloaded from the database — while a write that
updates it is pending. This is why read-your-writes holds even under batching and
concurrency: a form with an unsaved change is always still in memory.

## What to avoid

- **Do not** read a form and then write it *outside* a transaction: reads are
  always safe, but a write must be inside `@tx`, and a read-modify-write must be
  inside a single transaction to be atomic.
- **Do not** put side effects in a transaction body: it may run more than once.

```julia
# Atomic read-modify-write: correct.
@tx counter[:n] = value(counter[:n]) + 1

# Not atomic: another thread may interleave between the read and the write.
n = value(counter[:n])
@tx counter[:n] = n + 1
```

## Next

[Failure policies](failures-policies.md) decide what happens when a database
write cannot be saved.

