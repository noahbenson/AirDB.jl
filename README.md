# AirDB.jl

A PostgreSQL-backed persistence layer built on
[Air.jl](https://github.com/noahbenson/Air.jl)'s software transactional memory
(STM).

AirDB lets you keep shared application state in memory as ordinary Julia objects
and have every committed change written to PostgreSQL automatically, in
transaction order, without locks in your own code. It is aimed at asynchronous,
multithreaded servers whose threads share data and whose write order matters.

```julia
using AirDB
using Air                        # for @tx / tx

cfg = DatabaseConfig(; host = "localhost", dbname = "airdb", user = "airdb")
db = create_database(cfg; overwrite = true)

widget = VolatileForm(db, "widget", n = 1)   # a form, persisted on commit
@tx widget[:n] = 42                          # change it inside a transaction
AirDB.sync(db)                               # wait until the writer has saved it
value(widget[:n])                            # 42
```

## Installation

AirDB requires Julia 1.10 or later and a PostgreSQL server. It is registered in
the General registry:

```julia
using Pkg
Pkg.add("AirDB")
```

The test suite starts its own server with `docker compose up -d`; see
`docker-compose.yml`.

## What you get

- **`Form`** — an immutable, JSON-able nested value: a `FormScalar`, a
  `FormContainer`, a `VolatileForm`, or a `FormExtern`. Rich path indexing,
  functional updates, and a collection protocol.
- **`VolatileForm`** — a form with a stable UUID that persists itself when the
  transaction that changed it commits, loaded lazily and cached by id, with
  optional metadata and an optional append-only history.
- **`ActorForm`, `PromiseForm`, `StreamForm`, `DelayForm`** — forms backed by a
  live Air actor, a single-assignment promise, a FIFO stream, and a run-once lazy
  value. A promise is pending, delivered, or failed durably; a stream is a
  persisted, optionally bounded queue; all load lazily by id.
- **Extern types** — host-level values a form can hold (a socket, a config
  handle) with a declared interface of read-only and read-edit operations,
  `reserve`/`reserve_read` concurrency, and serialized state in a `resources`
  table.
- **Named forms, metadata, and garbage collection** — stable names as roots, an
  owner/ACL metadata blob on every database-backed kind (readable without
  loading the payload), and `gc!` to sweep what nothing reaches.
- **One writer, many readers** — committed updates reach a single ordered writer in
  global commit order; reads use a connection pool and never wait on the writer.

## Documentation

- [The written guide](https://noahbenson.github.io/AirDB.jl/book/) — getting
  started, forms, extern types, transactions, indexing, persistence,
  concurrency, and failures, with worked examples.
- [API reference](https://noahbenson.github.io/AirDB.jl/book/api.html), or
  `?name` at the REPL.
- [CHANGELOG.md](CHANGELOG.md) for the release history, and
  [TODO.md](TODO.md) for known limitations and future work.

## License

MIT. Copyright (c) 2020-2026 Noah C. Benson.
