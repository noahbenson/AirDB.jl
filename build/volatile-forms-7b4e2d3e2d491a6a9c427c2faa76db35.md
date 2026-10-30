# Volatile forms

<!-- review-status: unreviewed -->
:::{warning} Unreviewed content
This page was written with AI assistance and has not been reviewed by a human.
It may contain errors, omissions, or outdated information.
:::

A `VolatileForm` is the form that is attached to a database. It wraps an Air
`Volatile{Form}`, has a stable UUID, and is cached per database by that id.

```julia
using AirDB, Air

widget = VolatileForm(db, "widget", n = 1)
widget.id                     # a UUID
widget[]                      # Form("widget", n=1)
value(widget[:n])             # 1
```

Its positional arguments become the sequence and its keyword arguments the map,
exactly as for [`form`](values.md). Forms can hold other volatile forms, which
gives a tree of independently versioned pieces:

```julia
child  = VolatileForm(db, n = 0)
parent = VolatileForm(db, name = "parent", child = child)
parent[:child]                # the child VolatileForm
value(parent[:child, :n])     # 0
```

## Writing

The value in memory is always readable, but it may only be **written inside an
Air transaction**. The change is staged during the transaction and sent to the
database when it commits:

```julia
@tx widget[:n] = 42
value(widget[:n])             # 42
```

Outside a transaction a write is an error:

```julia
widget[:n] = 5
# ERROR: cannot set volatile outside of transaction
```

The transaction model — why the body may run more than once, how reads are
validated, and how the commit is made durable — is the subject of
[Transactions](../transactions/stm.md) and
[Commits and durability](../transactions/commits-and-durability.md). For now,
treat `@tx` as the only place a write may happen.

A `VolatileForm` carries two optional pieces of persistence policy, fixed or
settable as noted:

```julia
VolatileForm(db, a = 1; metadata = form(owner = "alice"))
VolatileForm(db, a = 1; history = false)   # keep only the current row
```

`metadata` is the owner/ACL blob; `history` records an append-only history row
per update. See [Metadata](../transactions/metadata.md) and
[Schema and history](../transactions/schema-and-history.md).

## Reading and lazy loading

A `VolatileForm` loaded from the database records only its id until its value is
first needed; the body is then read from the database. `get_form(db, id)`
returns the live object if it is still in memory, and otherwise an unloaded
handle:

```julia
id = widget.id
r = get_form(db, id)
isloaded(r)                  # true — the same live object
```

If nothing references the form any more, the weak cache releases it; a later
lookup creates a fresh handle that loads on first use:

```julia
r = nothing
GC.gc(); GC.gc()
r = get_form(db, id)
isloaded(r)                  # false
value(r[:n])                 # the body is read from PostgreSQL here
```

The cache and identity rules are covered in
[Lazy loading and the cache](../transactions/lazy-loading-and-cache.md), and
links between forms in [Links between forms](../transactions/links-between-forms.md).

## Next

[Reading and paths](reading-and-paths.md) shows how indexing walks a form,
including through volatile forms.
