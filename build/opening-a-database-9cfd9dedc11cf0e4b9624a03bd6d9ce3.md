# Opening a database

<!-- review-status: unreviewed -->
:::{warning} Unreviewed content
This page was written with AI assistance and has not been reviewed by a human.
It may contain errors, omissions, or outdated information.
:::

This page assumes the connection setup from
[Installation and connection](installation.md).

## Creating or opening

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

Opening a database that has no AirDB schema raises an `ArgumentError` telling
you to create one.

```{admonition} The `Database` object
:class: note
A `Database` holds the connection, one ordered writer, a pool of read
connections, and a cache of the forms you have loaded. You create it once per
program and pass it to the constructors in this book.
```

## Closing

`close(db)` flushes any queued writes and closes every connection. Further
operations on a closed database raise.

```julia
close(db)
```

## Testing without PostgreSQL

For tests that should not depend on a server, `MemoryDatabase()` builds a fake,
in-memory database with the same surface — forms,
[named forms](../transactions/named-forms.md), `sync` — that saves nothing and
keeps no history.

```julia
db = MemoryDatabase()
```

It is useful for unit tests and for trying examples when no server is running.

## Next

[Your first form](first-example.md) puts a database to work.
