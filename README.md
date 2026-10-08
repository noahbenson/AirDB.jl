# AirDB.jl

A fluid JSON database representation built using Air.jl.


## Background and Motivation

Asynchronous multithreaded server applications require a strategy for managing
data across many threads whose workloads and timings cannot be easily
predicted. A common operation mode for many kinds of server applications is one
in which many users may be simultaneously connected to the system, sending
requests at arbitrary intervals. Many threads are typically used to
simultaneously read these requests and delegate them for parallel processing.

When multiple simultaneous workloads need to read from and/or write to memory
that is shared across threads, some mechanism of synchronization must be
adopted, and it must handle the problem of deadlocks. One strategy, which is
exemplified by the STM and immutable data philosophies of the clojure
programming language, is to (1) force as much data as possible to be
represented using persistent (immutable) data structures; (2) allow only a few
specific mutable structures and require them to be edited only within finite
transaction blocks; and (3) require the side-effects of transaction blocks to
be managed by the transaction. With some clever engineering, this allows the
developer to effectively treat a transaction block as an arbitrary atomic
operation.

The library `Air.jl` implements the above STM system and immutable data
structures in julia. This library, `AirDB.jl`, extends the STM types of Air to
create a (database) persistence layer on top of Air that supports multithreaded
transactional journaling of all updates to relevant program state in a
configurable way.


## Architecture

The library embraces Air's transaction system and builds on it, primarily by
implementing types that wrap Air's types and extend their functionality to
journal updates to a PostgreSQL database. The database connection is
configured during the construction of a `Database` object and maintained by
it. The `Database` is then used to create `FormActor` and `VolatileForm`
objects that automatically syncronize their contents to the database. Both
types explicitly work with the `Form` type, which is also built on Air
concepts. Forms are explicitly persistent nested map-/sequence-like data
structures that can be easily converted to/from JSON. They can contain only
persistent data or `VolatileForm` objects. `VolatileForm` objects are in turn a
thin wrapper around `Volatile{Form}` objects. `VolatileForm` objects are
associated with `FormActor` objects and send them instructions to write updates
to the SQL database whenever the volatile is updated. These instructions are
sent using the `Actor` pattern's `send` when (and only when) a transactional
update of the `VolatileForm` commits. The `FormActor` then writes the new value
to the database in its own thread.

Critically, because `VolatileForm` objects can only hold `Form` objects, and
because `Form` objects can only point to JSON-able data plus other
`VolatileForm` objects, the system is fairly self-contained. All `Form` objects
referenced by `VolatileForm`s can be saved in `jsonb` fields of a simple
PostgreSQL table that is indexed by the `VolatileForm`'s ID. `VolatileForm`
objects are saved in JSON as strings that start with the `@` character; each
volatile is given a unique ID that is saved in the database (and created in the
database when the object is created), and this ID is saved after the `@`. When
a `VolatileForm` is loaded from the database, its `Form` contents are loaded,
and any `VolatileForm` it points to is loaded in a lazy fashion---the ID alone
is loaded eagerly, and the first time the user requests its value its `Form` is
loaded from the database (again with any `VolatileForm`s it references
deferred). `VolatileForm` objects are cached by their `Database` object
using a `WeakRef` system such that a `VolatileForm` object is always cached for
as long as it is held in memory (and can be returned in its correct,
up-to-date, cached state when loaded from the database by another form) but
released back to the database alone as soon as nothing but the cache itself
references the object. Importantly, `FormActor`s are always given a reference
to the `VolatileForm` that they are updating in the database, and this
reference is only discarded after the database has been updated, so that it is
impossible for a `VolatileForm` to be garbage collected and reloaded while a
database write that updates the form is pending.


## Database Specification

The database persistence layer is backed by PostgreSQL and managed through
`LibPQ.jl` for high-throughput, low-latency execution using native binary
protocols and prepared statements. To achieve optimal concurrency and linear
performance under heavy multithreaded workloads, `AirDB.jl` isolates read and
write paths while using an append-only event-sourcing model combined with an
up-to-date state projection.

### Schema Architecture

The database schema splits concerns between an immutable audit history and a
state snapshot lookup:

```sql
-- Full, append-only historical audit trail of all transactions
CREATE TABLE form_history (
    form_id      UUID NOT NULL,
    version      BIGINT NOT NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    tx_id        BIGINT NOT NULL,
    payload      JSONB NOT NULL,
    PRIMARY KEY (form_id, version)
);

-- Up-to-date snapshot projection table for point lookups
CREATE TABLE form_current (
    form_id      UUID PRIMARY KEY,
    version      BIGINT NOT NULL,
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    payload      JSONB NOT NULL
);
```

Every update dispatched upon the commit of an `Air.jl` transaction appends a
new record to `form_history` and updates `form_current`. Reads fetch
exclusively from `form_current`, enabling $O(1)$ B-Tree point lookups indexed
directly by `form_id`.

### Concurrency and Thread Model

To preserve the global transactional ordering guaranteed by `Air.jl`'s STM
runtime without introducing lock contention in PostgreSQL, writes and reads are
decoupled into separate channels:

* **Single Writer Actor (Global Write Queue):** All database write operations
  generated by committed `Air.jl` transactions are dispatched via an `Actor`
  pattern to a single, dedicated database writer thread owning a primary
  connection. The writer thread drains its inbox channel in micro-batches,
  executing bulk `INSERT` and `UPSERT` statements within single PostgreSQL
  transactions. Because `Air.jl` serializes transaction commit side-effects
  deterministically, a single writer guarantees that database updates arrive in
  exact global commit order without encountering deadlocks or row-level lock
  contention.
* **Multithreaded Read Pool:** Lazy reads generated when dereferencing
  `VolatileForm` instances bypass the writer actor entirely. Read queries
  execute across worker threads using a thread-safe connection pool (`LibPQ.jl`
  connections managed via Julia `Channel`s). Under PostgreSQL's Multi-Version
  Concurrency Control (MVCC), concurrent point reads never block or wait on the
  background write queue.

### Memory Caching and Lazy Traversal

Memory management leverages Julia's `WeakRef` capabilities paired with
`LibPQ.jl` binary JSON deserialization to bound memory footprint while
maintaining object identity:

* **Weak-Reference Cache:** Every `Database` object maintains a cache of active
  `VolatileForm` instances mapped by `UUID` using `WeakRef`s. If an application
  thread requests a form already present in memory, the cached reference is
  returned immediately without touching the network.
* **Garbage Collection Safety:** A `VolatileForm` queued for persistence
  retains an active reference inside its `FormActor` until the writer thread
  confirms the database write has succeeded, preventing premature garbage
  collection and reload races during pending updates.
* **Lazy Link Resolution:** Embedded child forms referenced in JSON payloads as
  `"@<UUID>"` are loaded lazily upon first access. This avoids eager transitive
  expansion, keeps query execution times $O(1)$, and naturally handles cyclic
  form references without infinite recursion.
