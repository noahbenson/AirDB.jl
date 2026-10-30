# Actor, promise, and delay forms

Three more kinds of form are backed by live Air objects. Each behaves like any
other form — it nests in containers, has a stable identity, and round-trips
through the database — while keeping its live semantics.

| form | backed by | JSON |
| --- | --- | --- |
| `ActorForm` | an Air `Actor{Form}` | `"!<uuid>"` |
| `PromiseForm` | an Air `Promise{Form}` | `"~<uuid>"` |
| `DelayForm` | a run-once computation | `{"delay": ":<type>", "form": <form>}` |

## Actors

An `ActorForm` is a sequential worker whose value is a form. Sending it a
function updates the value; every update is persisted.

```julia
af = ActorForm(db, form(n = 0))
af[]                          # Form(n=0)

send(af) do v
    form(n = value(v[:n]) + 1)
end
af[]                          # Form(n=1) — once the actor has processed it
```

Inside a transaction, `send` is deferred until the transaction commits, exactly
as with Air's actors. `af[]` is a transactional read.

`history` is fixed when the actor is created, like a `VolatileForm`'s:

```julia
ActorForm(db, form(n = 0); history = false)   # keep only the current value
```

An actor's value is stored in `form_actor_current` (plus `form_actor_history`
when history is on), and it loads lazily by id with
[`get_actor`](@ref).

## Promises

A `PromiseForm` is delivered once, with a form:

```julia
pf = PromiseForm(db)
isready(pf)                   # false
put!(pf, form(x = 1))
isready(pf)                   # true
pf[]                          # Form(x=1)
put!(pf, form(x = 2))         # ERROR: already fulfilled
```

Delivery inside a transaction is staged and takes effect only if the transaction
commits. Reading an *undelivered* promise inside a transaction raises — waiting
there can deadlock — so test with `isready` first; outside a transaction `pf[]`
waits for delivery.

**A promise is always a link.** Every form that names a promise writes
`"~<uuid>"`, whether the promise is pending, delivered, or failed, and the promise
always has a row in `form_promise` to hold its state:

```julia
pf = PromiseForm(db)
to_JSON(form(p = pf))         # "[[], {\":p\": \"~<uuid>\"}]"       — a link
put!(pf, form(a = 1))
to_JSON(form(p = pf))         # "[[], {\":p\": \"~<uuid>\"}]"       — still a link
```

Writing the value inline would lose the handle: a reader of the stored form could
no longer tell who else was waiting on the promise, and a failure would have no
place to live. So the identity and the settled value both survive a round trip —
a reloaded form's promise is the same `PromiseForm` with the same value — and
[`get_promise`](@ref) reaches a promise by id at any time.

A promise row is reachable exactly like any other object: it survives while a
named form, a live handle, or another reachable object references it, and
[`gc!`](@ref) sweeps it once nothing does.

### States: pending, delivered, failed

Every promise row carries a state. A promise is **pending** until settled, then
**delivered** with a value or **failed** with an error form:

```julia
pf = PromiseForm(db)
fail!(pf, form(err = :boom))     # settle as failed
isready(pf)                      # true — a settled promise is ready
isfailed(pf)                     # true
pf[]                             # ERROR: Air.PromiseFailed(err = :boom)
put!(pf, form(x = 1))            # ERROR: already settled
```

The error is stored as a form, so another process can reload the promise and
receive the same failure. A promise settles exactly once; the database update is
a compare-and-set, and a settlement creates the promise's row if it does not
exist yet.

### Uncommitted promises

A promise created inside a transaction can be marked as not yet committed:

```julia
pf = PromiseForm(db; pending_commit = true)   # :pending
isready(pf)                                   # ERROR: UncommittedPromise
put!(pf, form(x = 1))                         # settling is allowed
mark_committed!(pf)                            # :live — now readable
```

`mark_aborted!` makes every read and settlement raise `AbortedPromise`. A
promise reloaded by id is always `:live`.

## Owner and ACL metadata

Every database-backed kind carries an optional metadata form: a
`VolatileForm`, `ActorForm`, `PromiseForm`, and a stored extern. It is set at
creation or edited later:

```julia
vf = VolatileForm(db, a = 1; metadata = form(owner = "alice"))
af = ActorForm(db, form(n = 0); metadata = form(owner = "alice"))
pf = PromiseForm(db; metadata = form(owner = "alice"))
c  = construct(get_extern_API(:counter), Form(Symbol(":new")), Form(1);
               id = :my-counter, metadata = form(owner = "alice"))

metadata(vf)                  # form(owner="alice")
@tx set_metadata!(vf, form(owner = "bob"))   # transactional, metadata only
```

`metadata` reads only the metadata columns — it never fetches or decodes the
payload, so a permission check can precede the read. `set_metadata!` likewise
rewrites only the metadata; it adds no version or history row. An object with no
row (an unpersisted extern, a dead extern) has no metadata: `metadata` returns
`nothing`. Only database-backed externs are permissioned.

A metadata edit is transactional like any other write. The editing transaction
reads its own value back through `metadata`, the next reader sees it as soon as
the transaction commits, another transaction's edit is validated at commit (so
the loser retries), and an aborted transaction leaves both memory and the row
unchanged.

AirDB carries the metadata; it does not interpret it. Checks are the caller's
job.

## Delays

A `DelayForm` is a run-once, thread-safe lazy value computed from a form. Its
type is registered with a loader that computes the value:

```julia
register_delay(:double, f -> Form(2 * value(f)))

d = DelayForm(:double, Form(3))
d[]                           # Form(6) — the loader runs once
isready(d)                    # true, and it never runs again
```

The serialization — the type name and the form — never changes, and writing the
delay out does not force it:

```julia
to_JSON(DelayForm(:double, Form(3)))
# "{\"delay\": \":double\", \"form\": 3}"
```

A delay is immutable: `d[] = x` raises. It has no table and no id; it is stored
inline wherever it appears, and a delay of an unregistered type cannot be built
or read.

## In the API index

```julia
ActorForm(db, args...; history = true, metadata = nothing)
ActorForm(db, form::Form; history = true, metadata = nothing)
af[]; send(f, af)
get_actor(db, id)

PromiseForm(db; pending_commit = false, metadata = nothing)
isready(pf); isfailed(pf); pf[]; put!(pf, value); fail!(pf, error)
take(pf; timeout = nothing, token = nothing)
mark_pending_commit!(pf); mark_committed!(pf); mark_aborted!(pf)
get_promise(db, id)
UncommittedPromise; AbortedPromise

metadata(x); set_metadata!(x, m)     # every database-backed kind
register_delay(:type, load_fn)      # load_fn(::Form) -> Form
DelayForm(:type, form)
d[]; isready(d)
```
