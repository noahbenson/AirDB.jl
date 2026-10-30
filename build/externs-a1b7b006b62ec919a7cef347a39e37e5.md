# Extern types

<!-- review-status: unreviewed -->
:::{warning} Unreviewed content
This page was written with AI assistance and has not been reviewed by a human.
It may contain errors, omissions, or outdated information.
:::


Host-level values: registration, construction, calls, reservations, and
the form that wraps them. See
[Extern types](../live/externs-registration.md).

(api-abstractairextern)=
## AbstractAirExtern

```julia
AbstractAirExtern
```

The supertype of a host-level value a form can hold *without* being JSON itself —
a socket, a promise, a configuration handle, a cached value. A form stores one
inside a [`FormExtern`](#api-formextern); its operations, constructors, and optional
serialization are declared with [`register_extern`](#api-register-extern).


(api-formextern)=
## FormExtern

```julia
FormExtern(handle)
```

A form holding a host-level [`AbstractAirExtern`](#api-abstractairextern): an object whose
operations are defined by its registered type and whose data lives in an
`ExternHandle`. Build one with `construct`; use [`value`](forms.md#api-value) to get the
data back.


(api-deadextern)=
## DeadExtern

```julia
DeadExtern(type)
```

The data of a [`FormExtern`](#api-formextern) whose object could not be stored: it was
unnamed, or its type declared no serialization. A dead extern carries only the
registered type name and raises whenever it is used.


(api-externapi)=
## ExternAPI

```julia
ExternAPI
```

A handle to an extern's interface. A *type-level* API (from
`get_extern_API(name)`) carries no data and is used with [`construct`](#api-construct). A
*value-level* API (from `get_extern_API(fe)` for immutable types, or handed to a
[`reserve`](#api-reserve)/[`reserve_read`](#api-reserve-read) function) carries the data and is used with
`call`.


(api-externerror)=
## ExternError

```julia
ExternError
```

Raised when an extern is used incorrectly: an unregistered type or operation, an
API requested for a mutable extern without a reservation, a dead extern touched,
or a resource that cannot be loaded.


(api-externpromise)=
## ExternPromise

```julia
ExternPromise
```

The promise returned by [`reserve`](#api-reserve). `p[]` waits for the reservation and
yields its result, re-raising any error the function raised.


(api-register-extern)=
## register_extern

```julia
register_extern(name, ::Type{T}; read_only, read_edit, constructors,
                immutable = false, serialize = nothing, deserialize = nothing)
```

Register an extern data type `T` under `name`. `read_only` and `read_edit` are
`PDict`s of keyword operators to `(data, args) -> Form` functions; `constructors`
is a `PDict` of keyword operators to `(args) -> data` functions. A read-edit
operation may mutate the data and therefore requires a [`reserve`](#api-reserve); an
`immutable` type must declare none, and its API is available to any thread.

`serialize(data, io)` writes the data and `deserialize(io)` reads it back. A type
with both is database-storable: a form may hold a named extern of that type, and
the bytes live in the `resources` table. A type with neither is never stored — a
form that holds one is written as a dead-extern marker.

An **immutable** type may also declare `equal(a, b) -> Bool` and
`hash(data, seed::UInt) -> UInt` (both, or neither). They give the type value
semantics in [`isequiv`](equivalence.md#api-isequiv)/[`equivhash`](equivalence.md#api-equivhash); without them, two externs
are equivalent only when they wrap the same live handle. A mutable type is
always identity-equivalent and may not declare them.

```julia
register_extern(:config, ConfigData;
    read_only = PDict(Symbol(":version") => (d, args) -> Form(d.version)),
    read_edit = PDict(Symbol(":bump") => (d, args) -> (d.version += 1; Form(d.version))),
    constructors = PDict(Symbol(":new") => args -> ConfigData(1)),
    immutable = false,
    serialize = (d, io) -> print(io, d.version),
    deserialize = io -> ConfigData(parse(Int, read(io, String))))
```


(api-get-extern-api)=
## get_extern_API

```julia
get_extern_API(name::Symbol) -> ExternAPI
```

The type-level API for the extern type registered under `name`, used with
[`construct`](#api-construct).


```julia
get_extern_API(fe::FormExtern) -> ExternAPI
```

The API for an immutable extern, usable from any thread. A mutable extern raises:
it must be [`reserve`](#api-reserve)d (or [`reserve_read`](#api-reserve-read)) first.


(api-construct)=
## construct

```julia
construct(api::ExternAPI, ctor::Form, args::Form; id = nothing) -> FormExtern
```

Run the constructor named by `ctor` (a keyword form) with `args`, and wrap the
returned data in a [`FormExtern`](#api-formextern). `id`, if given, is the keyword under
which the extern is stored; it must be unique among live externs.


(api-call)=
## call

```julia
call(api::ExternAPI, op::Form, args::Form) -> Form
```

Run the operation named by `op` (a keyword form) on the extern's data with
`args`. Through a read-only API only read-only operations are available; through
an API handed out by [`reserve`](#api-reserve) the read-edit operations are too.


(api-reserve)=
## reserve

```julia
reserve(f, resources...) -> ExternPromise
```

Run `f` with editable APIs for each resource on a spawned task, which first takes
their write locks in sorted `(type, id)` order. Returns a promise; wait on it
with `p[]` for `f`'s value.

Inside a transaction the function is not run until the transaction commits (and
is discarded if it retries), and the reservation counts as a read: `f`'s
resources' versions must be unchanged at commit. Reading the promise inside that
same transaction before it completes raises.

```julia
p = reserve(r1) do api
    api.call(Form(Symbol(":bump")), form())
end
p[]          # the result
```


(api-reserve-read)=
## reserve_read

```julia
reserve_read(f, resources...) -> value
```

Run `f` with read-only APIs for each resource, taking their read locks in sorted
`(type, id)` order first. Runs on the caller's task and returns `f`'s value.
Inside a transaction the versions are read, so a concurrent read-edit forces the
transaction to retry. This is the ordinary way to call read-only operations.

```julia
reserve_read(r1, r2) do api1, api2
    api1.call(Form(Symbol(":version")), form())
end
```


