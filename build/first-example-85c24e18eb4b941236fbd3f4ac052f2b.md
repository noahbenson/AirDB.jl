# Your first form

<!-- review-status: unreviewed -->
:::{warning} Unreviewed content
This page was written with AI assistance and has not been reviewed by a human.
It may contain errors, omissions, or outdated information.
:::

This page assumes a `cfg` and a database created as in
[Opening a database](opening-a-database.md):

```julia
using AirDB
using Air

db = create_database(cfg; overwrite = true)
```

## Creating a form

A `VolatileForm` holds a `Form` and has a stable UUID. Its positional arguments
become the form's sequence and its keyword arguments its map, exactly as for
`Form`:

```julia
widget = VolatileForm(db, "widget", n = 1, tags = ["a", "b"])
```

You can read it with ordinary indexing. (A form fetched later by id reads its
body from the database the first time it is needed.)

```julia
widget[]        # Form("widget", n=1, tags=("a", "b"))
value(widget[:n]) # 1
widget[:tags]   # Form("a", "b") — a nested collection is a nested form
```

`value` unwraps a scalar form. Forms, indexing, and their container structure are
the subject of [Form values](../forms/values.md) and
[Reading and paths](../forms/reading-and-paths.md); for now it is enough that a
form holds nested maps and sequences and that indexing walks them.

## Writing it

A write must happen inside an Air transaction. The change is staged during the
transaction and sent to the database writer when it commits:

```julia
@tx widget[:n] = 42
AirDB.sync(db)  # block until the writer has saved everything sent so far
value(widget[:n]) # 42
```

The transaction rule is explained in [Transactions](../transactions/stm.md). A
brief first version: `@tx` groups reads and writes so that they take effect all
at once, or not at all if the body throws or the transaction has to retry.

`AirDB.sync` waits for durability: because the writer is sequential, once it has
processed the sync message every earlier write is on disk. In a server you
usually do **not** call `sync` after every write — the write is queued and saved
asynchronously.
[Commits and durability](../transactions/commits-and-durability.md) covers the
details.

## Reading it back

The form's value lives both in memory and in PostgreSQL. Another process, or a
later session, can reach it by its UUID:

```julia
id = widget.id
close(db)
db = open_database(cfg)
r = get_form(db, id)      # a fresh handle; the body is read lazily
value(r[:n])              # 42
```

The same id yields the same live object within one `Database`; when nothing
references it any more, the cache lets it go. See
[Lazy loading and the cache](../transactions/lazy-loading-and-cache.md).

```{admonition} Read-your-writes
:class: note
Within one `Database`, a read always sees the latest committed value, even if
the writer has not yet reached PostgreSQL: the form is cached in memory and the
pending write keeps it alive. `sync` is needed only when another process — or a
later session — must see the write.
```

## Next

[Form values](../forms/values.md) starts from the value type itself.
