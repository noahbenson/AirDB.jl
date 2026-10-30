# Installation and connection

<!-- review-status: unreviewed -->
:::{warning} Unreviewed content
This page was written with AI assistance and has not been reviewed by a human.
It may contain errors, omissions, or outdated information.
:::

## Installation

AirDB depends on [Air.jl](https://github.com/noahbenson/Air.jl) 0.3 and
[LibPQ.jl](https://github.com/JuliaDatabases/LibPQ.jl). Add it to a project with:

```julia
using Pkg
Pkg.add("AirDB")
```

If `AirDB` is not in your registry yet, add it from its repository instead:

```julia
Pkg.add(url = "https://github.com/noahbenson/AirDB.jl")
```

You will also use Air directly for the transaction macros and types:

```julia
using AirDB
using Air
```

## A PostgreSQL server

AirDB never creates or manages a PostgreSQL server — it connects to one you
provide. For experimenting, the repository ships a `docker-compose.yml` that
starts a throwaway server:

```bash
docker compose up -d        # postgres:16 on localhost:5432, user/db "airdb"
```

The examples in this book use the database name `airdb_test`, the user `airdb`,
and the password `airdb`; adjust them for your server.

## Configuring a connection

Everything AirDB needs to reach the server goes in a `DatabaseConfig`. The
structured fields cover the common case; you can also hand it a libpq URI or
connection string, which is used verbatim.

```julia
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

The remaining fields tune the read pool, write batching, encoder tasks, and
failure behavior. They are explained where they matter:

```julia
cfg = DatabaseConfig(;
    dbname        = "airdb_test",
    user          = "airdb",
    readpoolsize  = 16,     # connections kept for reads
    max_batch     = 1,      # commits accumulated before one database write
    failure       = :isolate, # :abort or :retry; see Failures
    encoder_tasks = 4,      # tasks that encode committed batches
    max_pending   = 256,    # committed-but-unwritten batches allowed
)
```

See [Commits and durability](../transactions/commits-and-durability.md) for
batching, [Concurrency](../operations/concurrency.md) for the encoder tasks
and the pending bound, and [Failure policies](../operations/failures-policies.md)
for the failure setting.

## Next

[Opening a database](opening-a-database.md) creates or opens the tables.
