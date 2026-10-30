# AirDB.jl

<!-- review-status: unreviewed -->
:::{warning} Unreviewed content
This page was written with AI assistance and has not been reviewed by a human.
It may contain errors, omissions, or outdated information.
:::

**A PostgreSQL-backed persistence layer built on
[Air.jl](https://github.com/noahbenson/Air.jl)'s software transactional memory.**

AirDB keeps shared application state in memory as ordinary Julia values and
writes every committed change to PostgreSQL automatically, in transaction order,
without locks in your own code. It is aimed at asynchronous, multithreaded
servers whose threads share data and whose write order matters.

## The idea

Air provides three building blocks:

- a **`Volatile`**, a `Ref`-like cell that may only be written inside a
  transaction and is guaranteed constant for the duration of one;
- an **`Actor`**, a worker with its own task and message queue, which runs sent
  functions one at a time; and
- **transactions** (`@tx` / `tx`), which make a group of reads, writes, and sends
  take effect all at once or not at all, re-running the body if another thread
  interferes.

AirDB builds on those:

- **`Form`** — an immutable, JSON-able nested value: the type that gets stored.
  Forms are introduced in [Form values](forms/values.md).
- **`VolatileForm`** — a form with a stable UUID that writes itself to the
  database when the transaction that changed it commits. See
  [Volatile forms](forms/volatile-forms.md).
- **`Database`** — the connection, the write pipeline, the read pool, and a
  cache of live forms. See [Opening a database](getting-started/opening-a-database.md).
- **Live forms and externs** — forms backed by an Air actor, promise, delay, or
  stream, and forms holding host-level values such as sockets or configuration
  handles. These are introduced later, in [Live objects](live/actors.md) and
  [Extern types](live/externs-registration.md).

```{admonition} One ordered writer, many readers
:class: tip
Every `Database` owns one ordered writer: committed updates are written in
Air's commit order, so the database never sees two writers race. Reads go
through a separate pool of connections and never wait on the writer. The
[Concurrency](operations/concurrency.md) page covers the details.
```

## A first taste

The rest of this book explains each piece; here is the whole shape of a small
program:

```julia
using AirDB
using Air            # for @tx and the Air types

cfg = DatabaseConfig(; host = "localhost", dbname = "airdb_test",
                       user = "airdb", password = "airdb")
db = create_database(cfg; overwrite = true)   # create the tables and connect

widget = VolatileForm(db, "widget", n = 1)    # a form, persisted on commit
value(widget[:n])                             # 1

@tx widget[:n] = 42                           # a transaction: stage the change
AirDB.sync(db)                                # wait until the writer has saved it
value(widget[:n])                             # 42
```

The value now lives both in memory and in PostgreSQL. Another process, or a
later session, can read it by its UUID:

```julia
id = widget.id
close(db)
db = open_database(cfg)
r = get_form(db, id)      # a fresh handle; the body is read lazily
value(r[:n])              # 42
```

The write rule (`@tx`), `sync`, and lazy loading are explained in
[Transactions](transactions/stm.md),
[Commits and durability](transactions/commits-and-durability.md), and
[Lazy loading and the cache](transactions/lazy-loading-and-cache.md). The
next pages build this example up from the beginning.

## Terms you will see

A few names recur; a short working description is enough for now:

- **`UUID`** — the unique identifier every database-backed form carries.
- **`PDict`** — Air's persistent (immutable) dictionary; updating one copies it.
- **`Volatile`** — Air's transactional `Ref`-like cell: readable at any time,
  writable only inside a transaction.
- **`WeakRef`** — a reference that does not keep its value alive; the form cache
  uses these.
- **`@tx` / `tx`** — Air's transaction macro and function. Writes are made inside
  them; see [Transactions](transactions/stm.md).

## How to read this book

The book follows the order in which the ideas build on one another:

1. **[Getting started](getting-started/installation.md)** — install AirDB,
   connect to PostgreSQL, and open a database.
2. **[Your first form](getting-started/first-example.md)** — a complete, runnable
   example.
3. **[Forms](forms/values.md)** — what a form is, how to read it, and how to
   update it.
4. **[Transactions and persistence](transactions/stm.md)** — how changes are
   made atomic and durable, and how forms are stored and loaded.
5. **[Live objects and externs](live/actors.md)** — actors, promises, delays,
   streams, and host-level extern values.
6. **[Semantics and operations](semantics/equivalence.md)** — the JSON format,
   form equivalence, concurrency, failures, and garbage collection.
7. **[API reference](api/index.md)** — every public name with its docstring.

Every page currently carries an "unreviewed content" warning; see
[Use of AI](#use-of-ai) below.

## Requirements

AirDB requires Julia 1.10 or later, [Air.jl](https://github.com/noahbenson/Air.jl)
0.3, and a PostgreSQL server you provide (the library never manages the server
itself). The repository ships a `docker-compose.yml` that starts a throwaway
PostgreSQL 16 for the tests and the examples in this book.

## Use of AI

This package was written with AI assistance. The human author directed all
design goals and decisions and has reviewed and tested the code.
Documentation pages were largely AI-written; each page that has not yet been
reviewed by a human carries the warning shown above, and the marker
`review-status: unreviewed` is in its source. As pages are reviewed, the marker
becomes `reviewed` and the warning is removed. See
[Building the documentation](README.md) for the review commands.
