# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Under `0.x`, SemVer puts breaking changes in the minor position and compatible
fixes in the patch position, which is how the versions below are chosen.

## [Unreleased]

### Removed

- **The `held` flag.** Forms no longer carry a held/unheld distinction: the
  `FormContainer` field, `hold`/`unhold`/`isheld`, and the trailing JSON element
  are all gone. A container is now written as the two-element list `[seq, map]`.

  This invalidates the stored format — a payload written by an earlier version is
  a three-element list and will not parse — so the schema version is bumped to
  `3`, and opening an older database fails with a clear error rather than
  per-row failures.

### Added

- **`iskeyword(f)` and `iswildcard(f)`**, which test whether a symbol scalar form
  is a keyword (a leading `:`) or a wildcard (a leading `?`).

- **Extern types**: a form can hold a host-level value that is not JSON itself — a
  socket, a promise, a configuration handle — wrapped in a **`FormExtern`**. A
  provider subclasses `AbstractAirExtern` and declares its interface with
  `register_extern(:name, T; read_only, read_edit, constructors, immutable,
  serialize, deserialize)`: `PDict`s of keyword operations, each taking the data
  and an argument form and returning a form. Constructors are run with
  `construct(get_extern_API(:name), ctor, args; id)`; operations with
  `api.call(op, args)`.
- **Concurrency**: a mutable extern is never handed out directly. `reserve_read`
  takes shared read locks (in sorted `(type, id)` order) and runs on the caller's
  task; `reserve` takes exclusive write locks on a spawned task and returns an
  `ExternPromise`. `immutable` types need neither. Each resource carries an Air
  `Volatile{Int}` version, so a transaction that read a resource retries if a
  read-edit intervened — no change to Air was needed.
- **Stored externs**: a named, serializable extern is written as
  `{"extern": "<type>", "id": "<id>"}`, with its bytes in the new `resources`
  table keyed by `(type, id)`; read-edit operations keep those bytes up to date.
  An unnamed or non-serializable extern is written as `{"extern": "<type>"}` and
  loads as a **`DeadExtern`**, which raises `ExternError` when used.
- **Volatile-form metadata and history**: `VolatileForm(...; metadata, history)`,
  with `metadata`, `history`, and the transactional `set_metadata!`. A form with
  `history = false` overwrites its current row instead of appending history.
  `form_current` and `form_history` gained a `metadata` column and
  `form_current` a `history` flag; the schema version is now `4`.

## [0.1.0] - 2026-10-12

The first release. AirDB builds a PostgreSQL-backed persistence layer on top of
[Air.jl](https://github.com/noahbenson/Air.jl)'s software transactional memory.

### Added

- **`Form`**, an immutable, JSON-able nested value. A form is a `FormScalar` (a
  bare leaf), a `FormContainer` (a sequence and a map), or a `VolatileForm`.
  Constructed with `Form(x)` for a leaf, `Form(seq, map)`, or `form(args...;
  kwargs...)`, and converted with `to_form`; `value(fs)` unwraps a scalar form.
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
- **The `held` flag** on containers (and a leading colon on symbol scalar forms):
  `hold`, `unhold`, `isheld`. It is part of a form's equality and hashing — a
  held form is not equal to an unheld one — and it is written in the form's JSON.
- **`VolatileForm`**, a `Form` with a stable UUID that persists itself on commit,
  loaded lazily and cached by id.
- **`Database`**, configured with `DatabaseConfig` and created with
  `create_database` (new) or `open_database` (existing). A single writer actor
  persists committed updates in global commit order; reads go through a
  connection pool. The schema is an append-only `form_history` plus an
  up-to-date `form_current` snapshot.
- **Named forms**: `named_form`, `name_form!`, `named_forms`, over a `form_name`
  alias table held in memory and written transactionally.
- **Failure policies**: `:abort` (the default) and `:retry`, with an `on_error`
  hook and `pending_writes`.
- **Cross-commit batching** via `max_batch`.
- **`MemoryDatabase`**, a fake in-memory database for tests that need no
  PostgreSQL.

### Performance

- Small sequences and maps are held in a flat, copy-on-write form and promoted to
  Air's persistent HAMT above a threshold — roughly 5× faster to build and 6×
  less allocation for the small forms that dominate.
- The JSON reader works on UTF-8 bytes rather than decoding a `Char` per byte.

[0.1.0]: https://github.com/noahbenson/AirDB.jl/releases/tag/v0.1.0
