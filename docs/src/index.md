# AirDB.jl

A PostgreSQL-backed persistence layer built on
[Air.jl](https://github.com/noahbenson/Air.jl)'s software transactional memory.

AirDB lets you keep shared application state in memory as ordinary Julia objects
and have every committed change written to PostgreSQL automatically, in
transaction order, without locks in your own code. It is aimed at asynchronous,
multithreaded servers whose threads share data and whose write order matters.

```julia
using AirDB
using Air                  # for @tx / tx

cfg = DatabaseConfig(; host = "localhost", dbname = "airdb", user = "airdb")
db = create_database(cfg; overwrite = true)

widget = VolatileForm(db, "widget", n = 1)   # a form, persisted on commit
@tx widget[:n] = 42                          # change it inside a transaction
AirDB.sync(db)                               # wait until the writer has saved it
value(widget[:n])                            # 42
```

The pieces:

- **`Form`** — an immutable, JSON-able nested value. A form is a `FormScalar` (a
  bare leaf), a `FormContainer` (a sequence and a map), or a `VolatileForm`.
- **`VolatileForm`** — a `Form` with a stable UUID that persists itself when the
  transaction that changed it commits, loaded lazily and cached by id.
- **`Database`** — the connection, the single writer actor, the read pool, and
  the cache. `create_database` makes a new one; `open_database` opens an existing
  one; `MemoryDatabase` is a fake, in-memory one for tests.

## The written guide

A narrative guide — getting started, forms, transactions, indexing, persistence,
concurrency, and failures, with worked examples — is in the
[book](https://noahbenson.github.io/AirDB.jl/book/).

## API reference

See the [API Reference](@ref) for the exported names, or `?name` at the REPL for
any docstring.
