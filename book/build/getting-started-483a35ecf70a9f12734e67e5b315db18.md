# Getting started

## Installation

AirDB depends on [Air.jl](https://github.com/noahbenson/Air.jl) 0.2 and
[LibPQ.jl](https://github.com/JuliaDatabases/LibPQ.jl). Add it to a project with:

```julia
using Pkg
Pkg.add("AirDB")            # once AirDB is registered
```

## A PostgreSQL server

AirDB never creates or manages a PostgreSQL server — it connects to one you
provide. For experimenting, the repository ships a `docker-compose.yml` that
starts a throwaway server:

```bash
docker compose up -d        # postgres:16 on localhost:5432, user/db "airdb"
```

## Configuring a connection

Everything AirDB needs to reach the server goes in a `DatabaseConfig`. The
structured fields cover the common case; you can also hand it a libpq URI or
connection string, which is used verbatim.

```julia
using AirDB

cfg = DatabaseConfig(;
    host     = "localhost",
    port     = 5432,
    dbname   = "airdb_test",
    user     = "airdb",
    password = "airdb",
)
```

```julia
# ... or a libpq URL / connection string:
cfg = DatabaseConfig("postgresql://airdb:airdb@localhost:5432/airdb_test")
cfg = DatabaseConfig("host=localhost port=5432 dbname=airdb_test user=airdb")
```

Other fields tune behaviour — pool size, write batching, and what to do on
failure. See [Failures and retries](failures.md) and [Persistence](persistence.md).

```julia
cfg = DatabaseConfig(;
    dbname       = "airdb_test",
    user         = "airdb",
    readpoolsize = 16,      # connections kept for reads
    max_batch    = 1,       # commits accumulated before one database write
    failure      = :abort,  # or :retry
)
```

## Creating or opening a database

There are two constructors. `create_database` initializes a **new** AirDB
database — it creates the tables — and returns a `Database`. `open_database`
connects to one that already exists.

```julia
db = create_database(cfg)            # create the tables and connect
# ... work with db ...
close(db)

db = open_database(cfg)              # connect to an existing AirDB database
```

Pass `overwrite = true` to `create_database` to drop and recreate the AirDB
tables first — convenient while experimenting, never what you want in
production.

```julia
db = create_database(cfg; overwrite = true)
```

Opening a database that has no AirDB schema raises an `ArgumentError` telling you
to create one.

## Your first form

A `VolatileForm` holds a `Form` and has a stable UUID. Its positional arguments
become the form's sequence and its keyword arguments its map, exactly as for
`Form`.

```julia
widget = VolatileForm(db, "widget", n = 1, tags = ["a", "b"])
```

Reading a form is ordinary indexing. The body is read from the database the first
time it is needed.

```julia
widget[]        # Form("widget", n=1, tags=("a", "b"))
value(widget[:n]) # 1
widget[:tags]   # Form("a", "b") — a nested collection is a nested form
```

Writing must happen inside an Air transaction; the change is staged during the
transaction and sent to the writer when it commits.

```julia
@tx widget[:n] = 42
AirDB.sync(db)  # block until the writer has saved everything sent so far
value(widget[:n]) # 42
```

`AirDB.sync` is the way to wait for durability: because the writer is sequential,
once it has processed the sync message every earlier write is on disk. In a
server you usually do **not** call `sync` after every write — the write is queued
and saved asynchronously.

## Testing without a database

For tests that should not depend on PostgreSQL, `MemoryDatabase()` builds a fake,
in-memory database with the same surface — `VolatileForm`, `named_form`,
`get_form`, `sync` — that saves nothing and keeps no history.

```julia
db = MemoryDatabase()
vf = VolatileForm(db, n = 1)
@tx vf[:n] = 2
AirDB.sync(db)
value(vf[:n])          # 2
```

## Closing

`close(db)` flushes any queued writes and closes every connection. Further
operations on a closed database raise.

```julia
close(db)
```

```{admonition} Read-your-writes
:class: note
Within one `Database`, a read always sees the latest committed value, even if the
writer has not yet reached the database: the form is cached in memory and the
pending write keeps it alive. `sync` is only needed when another process — or a
later session — must see the write.
```
