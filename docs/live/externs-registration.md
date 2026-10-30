# Extern types: registration

<!-- review-status: unreviewed -->
:::{warning} Unreviewed content
This page was written with AI assistance and has not been reviewed by a human.
It may contain errors, omissions, or outdated information.
:::

A form holds leaves and other forms — everything JSON can say. A running program
also holds things JSON cannot: a socket, a promise, a configuration handle.
These are **extern types**. A provider defines the type, its operations in
Julia, and how (and whether) it is stored; AirDB supplies the form wrapper, the
concurrency, and the database storage.

This page covers declaring and constructing an extern type. Calling its
operations and reserving it are in
[Calling and reservations](externs-calling-and-reservations.md); storing it is in
[Storage and dead externs](externs-storage-and-dead-externs.md).

## Registering a type

An extern's data is any type that subclasses `AbstractAirExtern`. Its interface
is registered once, at startup:

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
- `equal = (a, b) -> Bool` and `hash = (data, seed) -> UInt` (both, or neither)
  are optional for an **immutable** type. They give the extern value semantics
  in [`isequiv`/`equivhash`](../semantics/equivalence.md). Without them — and for
  every mutable extern — two externs are equivalent only when they wrap the same
  live handle.

Operation and constructor names are keywords, as in `Form(Symbol(":get"))`.

## Constructing

`get_extern_API(:counter)` is the type-level API; `construct` runs a
constructor and returns a `FormExtern`:

```julia
c = construct(get_extern_API(:counter), Form(Symbol(":new")), Form(3))
value(c)                # Counter(3) — the data
```

`construct(api, ctor, args; id = :c1)` names the extern for storage; see
[Storage and dead externs](externs-storage-and-dead-externs.md). Without an id,
the extern is usable in memory but is not stored.

## Registration and startup

The registry is in-memory, so a package that provides an extern type should
register it from its `__init__`:

```julia
function __init__()
    register_extern(:socket, SocketData; ...)
end
```

Registering the same name and type twice is harmless; registering a name for a
different type, or a type under a second name, raises `ExternError`.

## Next

[Calling and reservations](externs-calling-and-reservations.md) runs the
operations.
