################################################################################
# externs.jl
#
# Host-level extern types: values a form can hold that are not JSON themselves —
# a promise, a socket, a configuration handle. A form stores one in a
# `FormExtern`, which the JSON codec writes as the tagged list
# `["extern", "<type>", <payload>]`, so an extern survives a round trip through
# the database.
#
# The split between what is a *method* and what is a *registration argument* is
# deliberate. `serialize_extern`/`deserialize_extern` dispatch on the extern's own
# type, so a provider defines them as ordinary methods (and may add a method for a
# type it does not own only if it owns the extern). Equality and hashing are
# *values* stored at registration, because a provider cannot extend `==` for our
# `FormExtern` wrapper without committing type piracy — it owns neither the
# wrapper nor `Base.:(==)`. Registering the function instead keeps that clean, and
# lets one Julia type be registered under several names with different notions of
# equality.
#
# MIT License
# Copyright (c) 2020-2026 Noah C. Benson

"""
    serialize_extern(obj::AbstractAirExtern) -> payload

The JSON-able payload that stands for `obj` in the database: a leaf, a `Vector`, a
`Dict`, or a [`Form`](@ref). A provider defines a method for each extern type it
owns — `import`ing the function first, since it is AirDB's:

```julia
import AirDB: serialize_extern
serialize_extern(x::MyExtern) = …
```

The default raises, so an extern type that never implemented serialization fails
loudly rather than being stored as a hole.

`serialize_extern` runs on the database's writer thread, while the committed form
is encoded, so it must not block. An extern that stands for something that may not
be ready should return a tombstone (see [`ExternTombstone`](@ref)) rather than
wait for it:

```julia
serialize_extern(p::Promise) = isready(p) ? fetch(p) : :abandoned
```
"""
serialize_extern(obj::AbstractAirExtern) =
    error("unimplemented serialization for the extern type $(typeof(obj))")

"""
    deserialize_extern(::Val{name}, payload) -> AbstractAirExtern

Rebuild the extern registered under `name` from the `payload` the reader parsed.
A provider defines a method for each name it registers, dispatching on the `Val`
that carries the name:

```julia
deserialize_extern(::Val{:promise}, payload) = Promise(payload)
```

The `payload` is ordinary Julia data — a leaf, a `Vector`, a `Dict` — because an
extern is not required to serialize as a form. The default raises.
"""
deserialize_extern(::Val{name}, payload) where {name} =
    error("unimplemented deserialization for the extern type :$name")

"""
    ExternError

Raised when an extern cannot be written or read: its type is not registered, or a
form names an extern type the process has not registered.
"""
struct ExternError <: Exception
    msg::String
end
Base.showerror(io::IO, e::ExternError) = print(io, "ExternError: ", e.msg)

"""
    ExternTombstone

Raised when a form is read back and its extern was written as a tombstone — the
symbol `:abandoned` (an active primitive, like an unresolved promise, that could
not be persisted) or `:expired`. The `name` is the extern's registered type and
`kind` is the tombstone symbol.
"""
struct ExternTombstone <: Exception
    name::Symbol
    kind::Symbol
end
Base.showerror(io::IO, e::ExternTombstone) =
    print(io, "the extern :", e.name, " was written as a tombstone (:", e.kind,
          ") and cannot be rehydrated")

# The tombstone payloads. A bare symbol equal to one of these is intercepted by
# the reader and raised, rather than being handed to a provider — the provider
# never has to deal with a value that stands for "this was not saved".
const _EXTERN_TOMBSTONES = (:abandoned, :expired)

# The equality and hash a provider supplies at registration. Both default to
# identity of the object, so an extern that never says otherwise is equal only to
# itself.
const _extern_default_isequal = ===
_extern_default_hash(x, h::UInt) = hash(objectid(x), h)

struct ExternRegistration
    name::Symbol
    type::Type
    isequal::Function
    hash::Function
end

# Two indexes over the same registrations: by name, which the reader needs, and by
# type, which the writer needs to find the name for a value it is handed.
const _EXTERN_BY_NAME = Dict{Symbol,ExternRegistration}()
const _EXTERN_BY_TYPE = Dict{Type,Symbol}()

"""
    register_extern(name::Symbol, ::Type{T}; isequal, hash) -> ExternRegistration

Register the extern type `T` under `name`, so that forms holding it can be written
and read. `name` is what appears in the stored JSON — `register_extern(:promise,
Promise)` writes `["extern", ":promise", …]` — and is looked up again on read.

`isequal` and `hash` are the equality and hash used for `FormExtern`s wrapping a
`T`, and they must agree with one another (equal externs hash equal). Both default
to identity of the object, which is the safe choice for a live handle; supply them
to compare by value instead:

```julia
register_extern(:config, Config;
                isequal = (a, b) -> a.version == b.version,
                hash = (x, h) -> hash(x.version, h))
```

Registering the same name and type twice is a no-op; registering a name already
taken by a different type is an error.

The registry lives in memory, so a *package* that provides an extern type should
register it from its `__init__`, which runs when the package is loaded — a
top-level call would run at precompilation and be lost.
"""
function register_extern(name::Symbol, ::Type{T};
                         isequal::Function = _extern_default_isequal,
                         hash::Function = _extern_default_hash) where {T<:AbstractAirExtern}
    if haskey(_EXTERN_BY_NAME, name)
        reg = _EXTERN_BY_NAME[name]
        reg.type === T ||
            throw(ExternError("the extern name :$name is already registered for " *
                              "$(reg.type), not $T"))
        return reg
    end
    reg = ExternRegistration(name, T, isequal, hash)
    _EXTERN_BY_NAME[name] = reg
    _EXTERN_BY_TYPE[T] = name
    return reg
end

# The registration for a value's type, walking up the supertypes so that
# registering an abstract extern type covers its concrete subtypes.
function _extern_registration(::Type{T}) where {T}
    S = T
    while S !== Any
        if haskey(_EXTERN_BY_TYPE, S)
            return _EXTERN_BY_NAME[_EXTERN_BY_TYPE[S]]
        end
        S = supertype(S)
    end
    return nothing
end

# The name to write for a value of this type. Raises rather than writing a form
# the database could never read back.
function _extern_name(::Type{T}) where {T}
    reg = _extern_registration(T)
    reg === nothing &&
        throw(ExternError("the extern type $T is not registered; call " *
                          "register_extern(:name, $T) before storing a form that holds one"))
    return reg.name
end

# ---- equality and hashing ----------------------------------------------------
#
# Identity unless the provider registered something else. Two externs of different
# concrete types are never equal, so the same-type method is the one that consults
# the registry.

function _extern_equal(a::T, b::T) where {T<:AbstractAirExtern}
    reg = _extern_registration(T)
    return reg === nothing ? (a === b) : reg.isequal(a, b)
end
_extern_equal(::AbstractAirExtern, ::AbstractAirExtern) = false

function _extern_hash(x::AbstractAirExtern, h::UInt)
    reg = _extern_registration(typeof(x))
    return reg === nothing ? _extern_default_hash(x, h) : reg.hash(x, h)
end

Base.:(==)(a::FormExtern, b::FormExtern) = _extern_equal(a.value, b.value)
Base.isequal(a::FormExtern, b::FormExtern) = _extern_equal(a.value, b.value)
Base.hash(fe::FormExtern, h::UInt) = _extern_hash(fe.value, hash(:FormExtern, h))

# ---- printing ----------------------------------------------------------------

Base.show(io::IO, fe::FormExtern) = (print(io, "FormExtern("); show(io, fe.value); print(io, ")"))
# Inside a container an extern reads like the object it wraps, since the wrapper
# is an implementation detail.
_showvalue(io::IO, fe::FormExtern) = show(io, fe.value)

export AbstractAirExtern, FormExtern, serialize_extern, deserialize_extern,
    register_extern, ExternError, ExternTombstone
