# AirDB.jl

**A PostgreSQL-backed persistence layer built on
[Air.jl](https://github.com/noahbenson/Air.jl)'s software transactional memory.**

AirDB lets you keep shared application state in memory as ordinary Julia objects
and have every committed change written to PostgreSQL automatically, in
transaction order, without locks in your own code. It is aimed at asynchronous,
multithreaded servers whose threads share data and whose write order matters.

## The idea

Air provides three building blocks:

- a **`Volatile`**, a `Ref`-like cell that may only be written inside a
  transaction and is guaranteed constant for the duration of one;
- an **`Actor`**, a worker with its own thread and message queue, which runs sent
  functions one at a time; and
- **transactions** (`@tx` / `tx`), which make a group of reads, writes, and sends
  take effect all at once or not at all, re-running the body if another thread
  interferes.

AirDB builds three objects on top of those:

- **`Form`** — an immutable, JSON-able nested map/sequence structure, the value
  type that gets stored;
- **`VolatileForm`** — a `Form` with a stable UUID that writes itself to the
  database when the transaction that changed it commits; and
- **`Database`** — the connection, the single writer actor, the read pool, and a
  cache of live forms.

```{admonition} One writer, many readers
:class: tip
Every `Database` owns **one** writer actor. Committed updates are sent to it in
Air's global commit order and written by it in that order, so the database never
sees two writers race. Reads go through a separate pool of connections and never
wait on the writer.
```

## A first taste

```julia
using AirDB
using Air            # for the @tx / tx transaction macros

cfg = DatabaseConfig(; host = "localhost", dbname = "airdb", user = "airdb")
db = create_database(cfg; overwrite = true)   # initialize a new AirDB database

widget = VolatileForm(db, "widget", n = 1)    # a new form, persisted on commit

@tx widget[:n] = 42                           # change it inside a transaction
AirDB.sync(db)                                # wait until the writer has saved it
value(widget[:n])                              # 42
```

The value lives in memory and in PostgreSQL. Another process (or another
connection) can read it back by its UUID:

```julia
id = widget.id
close(db)
db = open_database(cfg)
r = get_form(db, id)      # a fresh handle; the body is read lazily
value(r[:n])               # 42
```

## How to read this book

- **[Getting started](getting-started.md)** — configuring a connection and
  creating or opening a database.
- **[Named forms](named-forms.md)** — giving a form a name like `"root"` so it can
  be found without a UUID.
- **[Forms](forms.md)** — building, reading, updating, and encoding forms.
- **[Transactions and volatile forms](transactions.md)** — how writes commit.
- **[Indexing and updating](indexing.md)** — the path-based access paradigm.
- **[Persistence](persistence.md)** — the schema, lazy loading, the cache, and
  batching.
- **[Concurrency](concurrency.md)** — many threads, one writer.
- **[Failures and retries](failures.md)** — what happens when PostgreSQL is
  unreachable.
- **[API reference](api.md)** — the exported names at a glance.

## Requirements

AirDB requires Julia 1.10 or later, [Air.jl](https://github.com/noahbenson/Air.jl)
0.2, and a PostgreSQL server you provide (the library never manages the server
itself). The repository ships a `docker-compose.yml` that starts a throwaway
PostgreSQL 16 for the tests and the examples in this book.
