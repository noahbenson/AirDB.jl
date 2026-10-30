# TODO

Known limitations and planned work, in rough priority order. Items here are
deliberate for 0.1.0, not oversights.

## Write pipeline

- **Per-form encoding inside a batch.** The encoder pool parallelizes across
  committed batches, but a single batch is still encoded on one task (a huge form
  occupies one encoder). Splitting a batch per form would need the stream
  fixed-point and reference collection per form with a merge step.
- **Byte-based backpressure.** `max_pending` bounds the number of pending
  batches, not their size; one enormous form can still exceed a memory budget. A
  byte budget alongside the batch count would bound memory directly.
- **Per-object write ordering.** Database transactions are written in commit
  order, so a slow batch delays every later write. Relaxing this for independent
  objects would let a slow extern `serialize` be overtaken, at the cost of a
  per-object ordering/dependency design.
- **Extern serialization on reference** is skipped once a handle's row exists;
  a first reference still serializes. A pre-commit or background serialization
  for newly constructed handles could remove that last stall.

## Streams

- **Blocking on a stream loaded in a transaction.** Air treats a stream first
  loaded inside a transaction as created there for the purpose of blocking, so an
  operation that would block raises `StreamDeadlock` rather than waiting. Air's
  reasoning is sound — another thread cannot see the transaction's staged state,
  and a second loader would be a different in-memory stream — but a narrower rule
  may be possible. Revisit alongside Air.

## Garbage collection

- **A link table for scale.** `gc!` re-scans every payload on each sweep. A
  maintained `(object, link)` table would make marking incremental; the current
  scan is exact and simple, and fine at moderate sizes.
- **History retention.** `gc!` keeps the full history of every live object. A
  retention policy (keep the last *n* versions, or versions younger than *t*) is
  not implemented.
- **Malformed payloads.** A stored payload the reader would reject (e.g. a
  malformed link marker) is skipped by the link scan rather than treated as
  reachable. This is deliberate — the GC cannot resolve what the reader cannot
  parse — but a corrupt row is thus never swept.

## Forms and codecs

- **More scalar types.** Leaves cover the numeric tower (`Int64`, `BigInt`,
  `Float64`, `BigFloat`, `Rational`, and complex numbers), strings, symbols,
  `Bool`, and `Nothing`. Dates/times and `UUID`s are not forms; convert them or
  hold them in an extern.
- **Key sorting on write.** A container's map is sorted when it is encoded, so a
  large map pays `O(n log n)` per write. Caching a sorted key order is a possible
  micro-optimization.
- **Dead-`WeakRef` sweeping.** The form caches and the extern registry drop dead
  entries opportunistically on insertion; a dedicated sweep could make their
  memory use tighter under churn.
