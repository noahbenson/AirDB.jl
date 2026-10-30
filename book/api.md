# API reference

A quick reference to the exported names. Every function below has a docstring you
can reach with `?name` at the REPL.

## Configuration and lifecycle

```julia
DatabaseConfig(; dbname, user, host = "localhost", port = 5432, password = nothing,
                 sslmode = "prefer", connect_timeout = 10, readpoolsize = 8,
                 max_batch = 1, failure = :isolate, retries = nothing, retry_time = nothing,
                 retry_delay = 0.1, retry_delay_max = 5.0, on_error = nothing,
                 conninfo = nothing, encoder_tasks = max(1, min(4, nthreads()-1)),
                 max_pending = 256)
DatabaseConfig(url::AbstractString; kwargs...)

create_database(config; overwrite = false) -> Database
open_database(config)                      -> Database
MemoryDatabase()                           -> MemoryDatabase   # fake, in-memory, for tests
Base.close(db::Database)

AirDB.sync(db::Database)                   # wait until queued writes are saved
AirDB.status(db::Database)                 # (npending, last_error)
pending_writes(db::Database)               # unsaved and quarantined updates
```

| `DatabaseConfig` field | meaning |
| --- | --- |
| `readpoolsize` | read connections to keep |
| `max_batch` | commits accumulated before one database write |
| `failure` | `:isolate` (default), `:abort`, or `:retry` |
| `retries`, `retry_time` | retry budget: attempts and/or seconds |
| `retry_delay`, `retry_delay_max` | backoff between retries |
| `on_error` | `on_error(db, err)` hook called on every database error |
| `encoder_tasks` | tasks that encode committed batches |
| `max_pending` | committed-but-unwritten batches allowed before a commit waits |

## Failure inspection

```julia
write_failures(db)                     # Vector{FailureRecord}, oldest first
write_failures(db, id)                 # records touching a form/actor/promise/
                                       # stream id, extern (type, id), or name
failed(db, id)                         # is the object's write quarantined?
clear_write_failure!(db, id; retry = false)  # acknowledge; retry=true re-stages
clear_write_failures!(db)

read_failures(db); read_failures(db, id); clear_read_failures!(db)

FailureRecord                          # sequence, error, time, items
FailedItem                             # kind, id, object, write
ReadFailure                            # error, time, operation, id
FailedObjectError                      # raised when loading a quarantined object
```

## Forms

```julia
Form(x::FormLeaf)           # a scalar form from one leaf
Form(seq, map)              # a container from prepared collections
form(seq...; keys...)       # the general builder
form()                      # an empty container
to_form(x)                  # convert any value to a form
is_form_representable(x)    # would to_form(x) succeed? (a pre-check)
value(fs)                   # the leaf a scalar form wraps

# FormLeaf: String, Symbol, Bool, Nothing, Int64, BigInt, Float64, BigFloat,
#           Rational{Int64}, Rational{BigInt}, ComplexF64, Complex{BigFloat}

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

iskeyword(f); iswildcard(f) # a symbol leaf with a leading : or ?

isequiv(a, b)               # equivalence: same leaf type + value, structural
                            # containers, object identity for mutable forms
equivhash(f, h = zero(UInt))# a hash consistent with isequiv
```

`==` compares values (so `Form(5) == Form(5.0)`); `isequiv` additionally
requires the same leaf type, treats `NaN` as equivalent to itself, and gives
mutable forms identity semantics. See [Forms](forms.md).

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
VolatileForm(db, seq...; keys...)       -> VolatileForm
VolatileForm(db, form::Form;            -> VolatileForm
             metadata = nothing,
             history = true)
get_form(db, id::UUID)                  -> VolatileForm
isloaded(vf)                            -> Bool
AirDB.load!(vf)                         -> VolatileForm

vf[]                                    # read the whole form (loads if needed)
vf[idxs...]                             # read along a path

metadata(vf)                            # the optional metadata Form, or nothing
history(vf)                             # whether this form records history
set_metadata!(vf, m)                    # transactional; metadata only
```

`metadata` and `set_metadata!` exist for every database-backed kind
(`VolatileForm`, `ActorForm`, `PromiseForm`, `StreamForm`, `FormExtern`).
`metadata` uses a metadata-only query; it never fetches or decodes the payload.
An edit is transactional: its own transaction reads it back, the next reader
sees it as soon as the transaction commits, an abort leaves the value unchanged,
and concurrent edits are validated at commit.

`metadata` is stored in its own JSONB column alongside the payload.
`history` is fixed at construction: `true` (the default) appends a row to
`form_history` on every update; `false` keeps only the current row and overwrites
it.

## Actor, promise, and delay forms

```julia
ActorForm(db, args...; history = true, metadata = nothing)
ActorForm(db, form::Form; history = true, metadata = nothing)
af[]                                     # current value (transactional read)
send(f, af)                              # update it (deferred in a transaction)
get_actor(db, id)                        # cached / lazily loaded by id

PromiseForm(db; pending_commit = false, metadata = nothing)
isready(pf)                              # settled? (delivered or failed)
isfailed(pf)                             # failed?
pf[]                                     # value; raises PromiseFailed if failed
put!(pf, value)                          # deliver once
fail!(pf, error)                         # fail once, durably
take(pf; timeout = nothing, token = nothing)
mark_pending_commit!(pf)                 # inside a transaction that has not committed
mark_committed!(pf); mark_aborted!(pf)
get_promise(db, id)
UncommittedPromise; AbortedPromise

register_delay(:type, load_fn)           # load_fn(::Form) -> Form
DelayForm(:type, form)                   # a run-once lazy form
d[]; isready(d)                          # force it (memoized)
```

See [Actor, promise, and delay forms](actor-promise-delay-forms.md).

## Stream forms

```julia
StreamForm(db; maxsize = nothing, pending_commit = false, metadata = nothing)
get_stream(db, id)

put!(sf, value; timeout = nothing, token = ...)
take(sf; timeout = nothing, token = ...)
close(sf)

isopen(sf); length(sf); isempty(sf); isready(sf); maxsize(sf); snapshot(sf)
mark_pending_commit!(sf); mark_committed!(sf); mark_aborted!(sf)
UncommittedStream; AbortedStream
metadata(sf); set_metadata!(sf, m)
```

See [Stream forms](stream-forms.md).

## Named forms

```julia
named_form(db, name; create = false, value = nothing)  # look up, or create, by name
name_form!(db, name, vf::VolatileForm)                 # register vf under name (overwrites)
delete_name!(db, name)                                 # release an alias
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
AbstractAirExtern                     # supertype of an extern's data
FormExtern                            # the form wrapping an extern handle
DeadExtern                            # the data of a stored-away (dead) extern
value(fe)                             # the data back out

register_extern(:name, T;             # declare a type's interface
                read_only  = PDict(), #   (data, args) -> Form
                read_edit  = PDict(), #   (data, args) -> Form, needs a reserve
                constructors = PDict(), # (args) -> data
                immutable = false,
                serialize = nothing,  # (data, io) -> nothing
                deserialize = nothing)# (io) -> data

get_extern_API(name::Symbol)          # the type-level API
get_extern_API(fe::FormExtern)        # the value API (immutable types only)
construct(api, ctor, args; id = nothing)  -> FormExtern
api.call(op::Form, args::Form)        -> Form

reserve_read(f, resources...)         # read-only; runs on the caller's task
reserve(f, resources...)              -> ExternPromise
p[]                                   # wait for a reservation's result
ExternError
```

See [Extern types](externs.md).

## Garbage collection

```julia
gc!(db; dry_run = false, batch = 1000)  -> GCStats
```

Sweeps database objects that are reachable neither from a named form nor from a
live in-memory object, removing their rows and their history. Runs as one
operation on the writer task (writes wait; reads continue). See
[Persistence](persistence.md).

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
