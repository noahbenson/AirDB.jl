# Extern types

A form holds leaves and other forms — everything JSON can say. But a running
program also holds things JSON cannot: a promise, an open socket, a handle to a
configuration cache, a resolved future. These are **externs**, and a form holds
one inside a `FormExtern`.

An extern type subclasses `AbstractAirExtern`, and its provider teaches AirDB how
to store it: `serialize_extern` turns one into JSON-able data, and
`deserialize_extern` turns that data back. The type is registered under a symbol,
which is what appears in the database.

```julia
using AirDB
# `serialize_extern` and `deserialize_extern` are methods of AirDB's functions, so
# a provider `import`s them and defines methods unqualified.
import AirDB: serialize_extern, deserialize_extern

struct ConfigHandle <: AbstractAirExtern
    version::Int
    label::String
end

serialize_extern(c::ConfigHandle) = Dict("version" => c.version, "label" => c.label)
deserialize_extern(::Val{:config}, p::AbstractDict) =
    ConfigHandle(Int(p[:version]), String(p[:label]))

register_extern(:config, ConfigHandle;
                isequal = (a, b) -> a.version == b.version && a.label == b.label,
                hash = (x, h) -> hash(x.version, hash(x.label, h)))
```

Now a `ConfigHandle` is a value a form can hold, alongside any leaf or nested
form:

```julia
f = form(1, cfg = ConfigHandle(2, "abc"))
f[:cfg]                # FormExtern(ConfigHandle(2, "abc"))
value(f[:cfg])         # ConfigHandle(2, "abc")
```

`to_form(x)` wraps any `AbstractAirExtern` in a `FormExtern`, and `value` unwraps
it — the same pair that works for a scalar form.

## The JSON

An extern is written as a tagged list, `["extern", "<type>", <payload>]`, where the
tag is the string `extern`, the type is the name it was registered under, and the
payload is what `serialize_extern` returned. A list whose first element is the tag
*string* is an extern; a list whose first element is a *list* is a container, so
the two never collide.

```julia
using AirDB: to_JSON, from_JSON

to_JSON(FormExtern(ConfigHandle(2, "abc")))
# "[\"'extern\", \":config\", [[], {\":label\": \"'abc\", \":version\": 2}]]"

from_JSON("[\"'extern\", \":config\", [[], {\":label\": \"'abc\", \":version\": 2}]]")
# FormExtern(ConfigHandle(2, "abc"))
```

A scalar payload is written as its bare leaf, so an extern that serializes to one
value is compact:

```julia
to_JSON(FormExtern(OpaqueHandle(7)))     # "[\"'extern\", \":opaque\", 7]"
```

Reading an extern dispatches on the name in the registry: the reader looks it up
and calls `deserialize_extern(Val(name), payload)`. The payload is ordinary Julia
data — a leaf, a `Vector`, a `Dict` — because an extern is not required to
serialize as a form.

## Tombstones

An extern that stands for something active — an unresolved promise, an open
socket — cannot be persisted, and should say so rather than fail. The convention
is a **tombstone**: return the symbol `:abandoned` (or `:expired`).

```julia
serialize_extern(p::Promise) = isready(p) ? fetch(p) : :abandoned
```

A tombstone is written like any other payload, but reading it back raises
`ExternTombstone` instead of calling the provider — the value is gone, and the
caller is told so plainly:

```julia
from_JSON("[\"'extern\", \":promise\", \":abandoned\"]")
# ERROR: the extern :promise was written as a tombstone (:abandoned) and cannot be rehydrated
```

`serialize_extern` runs on the database's writer thread while the committed form
is encoded, so it **must not block**: an extern that is not ready should return a
tombstone, not wait for a value.

## Equality

Two `FormExtern`s are equal only if they wrap the *same object* — identity — unless
the provider registered something else. Because a provider cannot extend `==` for
AirDB's `FormExtern` wrapper without committing type piracy, the comparison is a
function supplied at registration, as in the example above. `isequal` and `hash`
must agree — equal externs must hash equal — so give both or neither. With
neither, an extern compares by identity, which is the right default for a live
handle.

## Errors

| error | raised when |
| --- | --- |
| `ExternError` | a form holds an extern type that is not registered, on write or on read |
| `ExternTombstone` | a form is read back and its extern was written as a tombstone |
