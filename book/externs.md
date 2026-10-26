# Extern types

A form holds leaves and other forms — everything JSON can say. A running program
also holds things JSON cannot: a socket, a promise, a configuration handle. These
are **extern types**. A provider defines the type, its operations in Julia, and
how (and whether) it is stored; AirDB supplies the form wrapper, the concurrency,
and the database storage.

## Registering a type

An extern's data is any type that subclasses `AbstractAirExtern`. Its interface is
registered once, at startup:

```julia
using AirDB, Air

mutable struct Counter <: AbstractAirExtern
    n::Int
end

register_extern(:counter, Counter;
    read_only = PDict(
        Symbol(":get") => (d, args) -> Form(d.n)),
    read_edit = PDict(
        Symbol(":bump") => (d, args) -> (d.n += 1; Form(d.n))),
    constructors = PDict(
        Symbol(":new") => args -> Counter(Int(value(args)))),
    serialize = (d, io) -> print(io, d.n),
    deserialize = io -> Counter(parse(Int, read(io, String))))
```

- `read_only` and `read_edit` are `PDict`s from keyword operation names to
  `(data, args) -> Form` functions. **Every operation is classified when it is
  defined**: a read-edit operation mutates the data and therefore needs a write
  lock, while read-only operations may run concurrently.
- `constructors` are keyword-named `(args) -> data` functions; they produce the
  object's data from an argument form.
- `immutable = true` declares that the data never changes: no read-edit
  operations are allowed, and the API is available to every thread at any time.
- `serialize`/`deserialize` are both present or both absent. With them, a *named*
  extern can be stored in the database; without them it is never stored.

Operation and constructor names are keywords, as in `Form(Symbol(":get"))`.

## Constructing

`get_extern_API(:counter)` is the type-level API; `construct` runs a constructor
and returns a [`FormExtern`](@ref):

```julia
c = construct(get_extern_API(:counter), Form(Symbol(":new")), Form(3))
value(c)                # Counter(3) — the data
```

`construct(api, ctor, args; id = :c1)` names the extern for storage (see below).

## Calling operations

An operation is called through `api.call`:

```julia
reserve_read(c) do api
    api.call(Form(Symbol(":get")), form())      # Form(3)
end
```

For an **immutable** type the API is available directly, from any thread:

```julia
api = get_extern_API(config_extern)
api.call(Form(Symbol(":version")), form())
```

For a **mutable** type, asking for the API directly raises. Its data is shared
memory that can be edited, so access is always through a reservation.

## Reservations

`reserve_read` takes the read locks of every resource, in sorted `(type, id)`
order (which prevents deadlock), runs the function on the caller's task, and
returns its value. Read-only operations run concurrently with one another, and
never during a read-edit.

`reserve` takes the **write** locks, runs the function on a spawned task, and
returns an `ExternPromise`; wait on it with `p[]`:

```julia
p = reserve(a, b) do api_a, api_b
    api_a.call(Form(Symbol(":bump")), form())
    api_b.call(Form(Symbol(":bump")), form())
end
p[]                     # (Form(2), Form(3))
```

Resources are always passed to the function in sorted order, so the arguments'
positions depend on their names, not the order you named them.

## Transactions

Every resource carries a version. A read made inside an `@tx` registers that
version with Air, and every read-edit increments it. If a read-edit happens
between a transaction's first read and its commit, Air's ordinary commit
validation fails and the transaction retries — so a transaction always sees a
consistent resource state, without holding a lock for its duration.

A `reserve` called inside a transaction behaves specially:

- its function does **not** run until the transaction commits, and is discarded
  if the transaction retries;
- the reservation counts as a read, so its resources' versions must be unchanged
  at commit;
- reading the returned promise before the transaction completes raises, since
  waiting there could deadlock.

```julia
@tx begin
    p = reserve(c) do api; api.call(Form(Symbol(":bump")), form()); end
    # p[] here would raise; use it after the transaction
end
```

## Storage

A named extern (`id = :something`) whose type has serialization is stored in the
`resources` table, keyed by `(type, id)`, as raw bytes produced by `serialize`.
The form itself stores only the reference:

```json
{"extern": "'counter", "id": "::c1"}
```

Reading the form back resolves the reference through the database's handle
registry; the bytes are read and deserialized the first time the data is used.
Two forms that name the same `(type, id)` share one handle — and therefore one
lock and one version.

Every read-edit of a stored extern queues an update of its bytes to the
database's writer actor, so the stored copy follows the live one.

A `MemoryDatabase` keeps extern data for the session and never writes it
anywhere, but otherwise behaves the same.

## Dead externs

An extern that is **unnamed**, or whose type has **no serialization**, cannot be
stored. It is written as a marker with the type name only:

```json
{"extern": "'counter"}
```

Reading that back yields a `FormExtern` whose data is a `DeadExtern`. Using it —
`get_extern_API`, `call`, `reserve`, `reserve_read` — raises `ExternError`.

## Registration and startup

The registry is in-memory, so a package that provides an extern type should
register it from its `__init__`:

```julia
function __init__()
    register_extern(:socket, SocketData; ...)
end
```

## Reference

| | |
| --- | --- |
| `AbstractAirExtern` | the supertype of an extern's data |
| `FormExtern` | the form wrapping an extern handle |
| `DeadExtern` | the data of an extern that could not be stored |
| `register_extern(:name, T; ...)` | declare a type's interface |
| `get_extern_API(name::Symbol)` | the type-level API, for `construct` |
| `construct(api, ctor, args; id)` | run a constructor, producing a `FormExtern` |
| `api.call(op, args)` | run an operation |
| `reserve_read(f, resources...)` | read-only access, on the caller's task |
| `reserve(f, resources...)` | read-edit access, on a spawned task; returns a promise |
| `ExternPromise` | the reservation's promise; `p[]` waits for the result |
| `ExternError` | raised for a dead, unregistered, or misused extern |
