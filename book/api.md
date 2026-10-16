# API reference

A quick reference to the exported names. Every function below has a docstring you
can reach with `?name` at the REPL.

## Configuration and lifecycle

```julia
DatabaseConfig(; dbname, user, host = "localhost", port = 5432, password = nothing,
                 sslmode = "prefer", connect_timeout = 10, readpoolsize = 8,
                 max_batch = 1, failure = :abort, retries = nothing, retry_time = nothing,
                 retry_delay = 0.1, retry_delay_max = 5.0, on_error = nothing,
                 conninfo = nothing)
DatabaseConfig(url::AbstractString; kwargs...)

create_database(config; overwrite = false) -> Database
open_database(config)                      -> Database
MemoryDatabase()                           -> MemoryDatabase   # fake, in-memory, for tests
Base.close(db::Database)

AirDB.sync(db::Database)                   # wait until queued writes are saved
AirDB.status(db::Database)                 # (npending, last_error)
pending_writes(db::Database)               # the writer's unsaved updates
```

| `DatabaseConfig` field | meaning |
| --- | --- |
| `readpoolsize` | read connections to keep |
| `max_batch` | commits accumulated before one database write |
| `failure` | `:abort` or `:retry` |
| `retries`, `retry_time` | retry budget: attempts and/or seconds |
| `retry_delay`, `retry_delay_max` | backoff between retries |
| `on_error` | `on_error(db, err)` hook called on every database error |

## Forms

```julia
Form(x::FormLeaf)           # a scalar form from one leaf
Form(seq, map)              # a container from prepared collections
form(seq...; keys...)       # the general builder
form()                      # an empty container
to_form(x)                  # convert any value to a form
value(fs)                   # the leaf a scalar form wraps

length(f); isempty(f)       # collection protocol, in the canonical order
keys(f); values(f); pairs(f)
first(f); last(f); copy(f); empty(f)

update(f, fn, idxs...)      # read-modify-write
update!(f, fn, idxs...)     # ... transactional (deepest volatile, like setindex!)
merge(f, g, ...)            # combine: sequences concat, maps merge (later wins)
merge_with(fn, f, g)        # ... combining shared keys with fn
haskey(f, idxs...)          # does the path resolve?
select_keys(f, ks)          # a form with only these keys
filter(pred, f); map_values(fn, f); map_keys(fn, f); deep_map(fn, f)
to_vector(f); to_dict(f)    # convert out to ordinary Julia data

hold(f); unhold(f)          # the `held` flag (containers, symbol scalars)
isheld(f)                   # ... held: a container flag, or a leading ' on a symbol
iskeyword(f); iswildcard(f) # ... a leading : or ? on a symbol (both inert)
```

Reading and updating use ordinary indexing; see
[Indexing and updating](indexing.md).

```julia
f[idxs...]                  # getindex / get along a path
get(f, idxs..., default)
setindex(f, v, idxs...)     # functional update (returns a new form)
setindex!(f, v, idxs...)    # transactional update (writes a volatile; needs @tx)
map(fn, f)                  # elementwise, keys preserved

push(f, v); pop(f); delete(f, k)
length(f); haskey(f, k)
```

## Volatile forms

```julia
VolatileForm(db, seq...; keys...) -> VolatileForm
VolatileForm(db, form::Form)      -> VolatileForm
get_form(db, id::UUID)            -> VolatileForm
isloaded(vf)                      -> Bool
AirDB.load!(vf)                   -> VolatileForm

vf[]                              # read the whole form (loads if needed)
vf[idxs...]                       # read along a path
```

## Named forms

```julia
named_form(db, name; create = false, value = nothing)  # look up, or create, by name
name_form!(db, name, vf::VolatileForm)                 # register vf under name (overwrites)
named_forms(db)                                        # the whole table, as a PDict
```

`name` may be a `Symbol` or a `String`; both refer to the same form. For
`named_form`, `create` is `false` (raise if absent), `true` (create; raise if
present), or `nothing` (return `nothing` if absent). `value` is the new form's
initial value, used only when creating; it may be a `Form`, something a `Form` can
be made from, `nothing` (an empty form), or an existing `VolatileForm` (which is
aliased rather than copied). Registering or renaming is transactional: it joins
the caller's transaction, or runs in one of its own.

## JSON

```julia
AirDB.to_JSON(f::Form)              -> String
AirDB.from_JSON(s)                  -> Form            # no volatile links
AirDB.from_JSON(resolve, s)         -> Form            # resolve "@<uuid>" links
AirDB.from_JSON(db, s)              -> Form            # resolve links via the database
```

## Extern types

```julia
AbstractAirExtern                   # supertype of a host-level value a form can hold
FormExtern(x)                       # the form wrapping one
value(fe)                           # the extern back out

serialize_extern(obj)               # provider: obj -> JSON-able payload (a method)
deserialize_extern(::Val{name}, p)  # provider: payload -> obj (a method)
register_extern(:name, T;           # register T under a symbol, with its equality
                isequal = ===,      #   (a function, not a method: no piracy)
                hash = ...)
```

See [Extern types](externs.md).

## Air re-exports

AirDB builds on Air's transaction system, which you use directly:

```julia
using Air                  # @tx, tx, Volatile, Actor, send, ...
```

## Errors

| error | raised when |
| --- | --- |
| `ArgumentError` | a bad config, a non-key index, no volatile on a `setindex!` path, indexing a leaf |
| `KeyError` | a missing map key |
| `BoundsError` | a missing sequence position, or an out-of-range append |
| `FormNotFound` | loading a form whose id is not in the database |
| `DatabaseError` | a database operation failed and the policy gave up |
| `ExternError` | a form holds an extern type that is not registered |
| `ExternTombstone` | an extern was written as a tombstone (`:abandoned`/`:expired`) |
