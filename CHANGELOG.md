# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Under `0.x`, SemVer puts breaking changes in the minor position and compatible
fixes in the patch position, which is how later versions will be chosen.

## [0.1.0] - 2026-10-29

The first release. AirDB builds a PostgreSQL-backed persistence layer on top of
[Air.jl](https://github.com/noahbenson/Air.jl)'s software transactional memory.
It requires Air 0.3 and Julia 1.10; the schema version is `7`.

### Added

- **`Form`**, an immutable, JSON-able nested value. A form is a `FormScalar` (a
  bare leaf), a `FormContainer` (a sequence and a map), a `VolatileForm`, a
  `FormExtern`, or one of the live-object forms below. Constructed with
  `Form(x)` for a leaf, `Form(seq, map)`, or `form(args...; kwargs...)`, and
  converted with `to_form`; `value(fs)` unwraps a scalar form.
- **The numeric tower as leaves.** A form can hold `BigInt`, `BigFloat`,
  `Rational{Int64}`, `Rational{BigInt}`, and `Complex{BigFloat}` alongside the
  existing `Int64`/`Float64`/`ComplexF64`. Only exact conversions are made: an
  integer too large for `Int64` becomes a `BigInt`, another `Rational` width
  becomes `Rational{Int64}` or `Rational{BigInt}` by fit, and a `Complex` whose
  parts are exact in neither `Float64` nor
  `BigFloat` is rejected. Each type survives a JSON/JSONB round trip exactly — a
  `BigFloat` keeps its precision — as the marked strings `"#big:"`,
  `"#rat:"`, `"#bigrat:"`, and `"#bigfloat:<precision>:<digits>"`.
- **`isequiv` and `equivhash`**, a form equivalence relation distinct from `==`
  and its consistent hash. `==` stays value-based (`Form(5) == Form(5.0)`);
  equivalence additionally requires the same leaf type, treats `NaN` as
  equivalent to itself, compares containers structurally, and gives mutable
  forms (volatiles, actors, promises, streams, mutable externs) identity
  semantics. An immutable extern type may register `equal`/`hash` functions to
  opt into value semantics.
- **Rich indexing** along a path (`f[:a, :b]`), with vector keys fanning out into
  a new form; a range is a vector key, so `f[2:3]` yields the subsequence, and
  `f.seq[2:3]` yields it as a sequence. `setindex` (functional) and `setindex!`
  (transactional, writing the deepest `VolatileForm` on the path).
- **The collection protocol**: `length`, `isempty`, `keys`, `values`, `pairs`,
  `iterate`, `first`, `last`, `copy`, `empty`, in one canonical order (sequence
  positions, then sorted map keys).
- **Verbs**: `update`/`update!`, `merge`/`merge_with`, `haskey` along a path,
  `select_keys`, `filter`, `map_values`, `map_keys`, `deep_map`, `to_vector`,
  `to_dict`.
- **`iskeyword(f)` and `iswildcard(f)`**, which test whether a symbol scalar form
  is a keyword (a leading `:`) or a wildcard (a leading `?`).
- **`is_form_representable(x)`**, a non-throwing pre-check for [`to_form`](@ref):
  it answers whether `to_form(x)` will succeed for a value, a nested collection,
  or a registered extern, without changing `to_form`'s behavior.
- **`VolatileForm`**, a `Form` with a stable UUID that persists itself on commit,
  loaded lazily and cached by id, with optional metadata and an optional
  append-only history (`history = false` keeps only the current row).
- **`ActorForm`**, backed by an Air `Actor{Form}`: `send` updates it and every
  value is persisted, with the same optional history and metadata as a volatile.
- **`PromiseForm`**, backed by an Air `Promise{Form}`: delivered once with
  `put!` or failed durably with `fail!`, with commit-state markers
  (`pending_commit`, `mark_committed!`, `mark_aborted!`) and the
  `UncommittedPromise`/`AbortedPromise` errors. A promise is always written as
  the link `"~<uuid>"` and always has a row, so its identity, value, and failure
  survive a round trip.
- **`StreamForm`**, a database-backed FIFO of forms wrapping Air's
  `Stream{Form}`: `put!`/`take` with optional bounds, timeouts, and cancellation;
  `close`; `isopen`/`length`/`isempty`/`isready`/`maxsize`/`snapshot`.
- **`DelayForm`**, a run-once lazy value computed from its serialization form by
  a loader registered with `register_delay`.
- **Extern types**: a form can hold a host-level value that is not JSON itself —
  a socket, a promise, a configuration handle — wrapped in a **`FormExtern`**. A
  provider subclasses `AbstractAirExtern` and declares its interface with
  `register_extern(:name, T; read_only, read_edit, constructors, immutable,
  serialize, deserialize)`: `PDict`s of keyword operations, each taking the data
  and an argument form and returning a form. Constructors are run with
  `construct(get_extern_API(:name), ctor, args; id)`; operations with
  `api.call(op, args)`.
- **Extern concurrency**: a mutable extern is never handed out directly.
  `reserve_read` takes shared read locks (in sorted `(type, id)` order) and runs
  on the caller's task; `reserve` takes exclusive write locks on a spawned task
  and returns an `ExternPromise`. `immutable` types need neither. Each resource
  carries an Air `Volatile{Int}` version, so a transaction that read a resource
  retries if a read-edit intervened.
- **Stored externs**: a named, serializable extern is written as
  `{"extern": "<type>", "id": "<id>"}`, with its bytes in the `resources` table
  keyed by `(type, id)`; read-edit operations keep those bytes up to date. An
  unnamed or non-serializable extern is written as `{"extern": "<type>"}` and
  loads as a **`DeadExtern`**, which raises `ExternError` when used.
- **Owner/ACL metadata on every database-backed kind**, settable at creation and
  with a transactional, metadata-only `set_metadata!`. `metadata(x)` uses a
  metadata-only query for every kind: it never fetches or decodes the payload, so
  a permission check can precede the read. An edit is visible to its own
  transaction, validated at commit, and rolled back with an aborted transaction.
- **Garbage collection**: `gc!(db; dry_run, batch)` sweeps database objects that
  are reachable neither from a named form nor from a live in-memory object,
  deleting their current rows and their history. It runs as one job on the
  writer task, so it sees a consistent snapshot and blocks only writes; object
  loading is serialized with it. `delete_name!(db, name)` releases a root.
  `GCStats` reports what was scanned and swept. `MemoryDatabase` implements the
  same sweep over its in-memory stores.
- **`Database`**, configured with `DatabaseConfig` and created with
  `create_database` (new) or `open_database` (existing). A single writer actor
  persists committed updates in global commit order; reads go through a
  connection pool. The schema is an append-only `form_history` plus an
  up-to-date `form_current` snapshot, with dedicated tables for actors, promises,
  streams, extern resources, and names.
- **Named forms**: `named_form`, `name_form!`, `delete_name!`, `named_forms`, over
  a `form_name` alias table held in memory and written transactionally.
- **A write pipeline.** Commits hand their batch to an intake actor and return;
  a configurable pool of `encoder_tasks` encodes forms, extern bytes, and stream
  snapshots after commit; one ordered writer task owns the PostgreSQL connection
  and writes prepared batches in commit order. Encoding and database I/O no
  longer share a task, and `max_pending` bounds how far the writer may lag
  (commits wait only past that bound). See `book/concurrency.md`.
- **Failure isolation.** The default `failure = :isolate` quarantines a batch
  that cannot be saved: committed in-memory values stay readable, unrelated work
  continues, and the failure is recorded for inspection —
  `write_failures(db[, id])`, `failed(db, id)`, `clear_write_failure!(db, id;
  retry = false)` (with `retry = true` re-staging the current value), and
  `clear_write_failures!`. Read errors are recorded separately (`read_failures`,
  `clear_read_failures!`). `failure = :abort` keeps the old poison behavior, and
  `:retry` retries within its budget and then quarantines. `on_error`,
  `pending_writes`, and `max_batch` remain.
- **Correctness fixes**: name operations now preserve their order (a delete
  followed by a registration in one flush ends registered); concurrent
  non-transactional stream operations can no longer enqueue a stale snapshot
  after a newer one; objects referenced only from metadata, actor values, or
  promise payloads now get their rows ensured; a stored extern is serialized
  only once, not on every reference; container `isequal` recurses with
  `isequal`, so it agrees with `hash` for `NaN` and signed zero; and `load!` no
  longer replaces a committed in-memory metadata edit with a stale row.
- **`MemoryDatabase`**, a fake in-memory database for tests that need no
  PostgreSQL.

### Performance

- Small sequences and maps are held in a flat, copy-on-write form and promoted to
  Air's persistent HAMT above a threshold — roughly 5× faster to build and 6×
  less allocation for the small forms that dominate.
- The JSON reader works on UTF-8 bytes rather than decoding a `Char` per byte.
- Form writes are batched per commit into one database transaction, and a single
  writer keeps commits in global order without row-level contention.

[0.1.0]: https://github.com/noahbenson/AirDB.jl/releases/tag/v0.1.0
