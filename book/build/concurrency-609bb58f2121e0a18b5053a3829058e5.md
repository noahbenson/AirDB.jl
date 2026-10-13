# Concurrency

AirDB is built for many threads sharing data. The model is simple: **many readers
and writers, one writer actor**.

## Many threads, one writer

Reads go through a pool of connections and never wait on the writer. Writes are
dispatched to a single writer actor in Air's global commit order, so the database
sees transactions in exactly the order they committed — no deadlocks, no
row-level lock contention, no two writers racing.

```julia
counter = VolatileForm(db, n = 0)
AirDB.sync(db)

@sync for _ in 1:50
    Threads.@spawn tx(() -> (counter[:n] = value(counter[:n]) + 1))
end
AirDB.sync(db)

value(counter[:n])                 # 50 — every increment committed exactly once
```

Under contention Air re-runs transactions that lose a race, so the *final* value
is correct even though the bodies run more than once. The history reflects only
the commits that succeeded, one row each.

```julia
# form_history has one new row per successful commit, versions in order
```

Run Julia with more than one thread to see real contention:

```bash
JULIA_NUM_THREADS=4 julia --project=. examples/quickstart.jl
```

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

A form queued for a write is held by the writer's queue until the write succeeds,
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
