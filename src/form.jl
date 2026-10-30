################################################################################
# form.jl
#
# Operations on forms: conversion, construction, reading, updating, and the
# collection protocol. The types themselves are in types.jl.
#
# MIT License
# Copyright (c) 2020-2026 Noah C. Benson

# ---- converting a value into the closed set ----------------------------------

# The error message names the type, because the usual cause is a value the caller
# assumed was acceptable — a `Set` where a leaf is wanted, or a dictionary with
# non-symbol keys.
_formerror(x, why) =
    throw(ArgumentError("a Form cannot hold $(typeof(x)): $why; " *
                        "see FormLeaf for what it can hold"))

# A form (a scalar, a container, or a volatile) is already a member of the closed
# set and passes through unchanged.
@inline _formvalue(x::Form) = x
# An exact leaf type is preserved as it is; the methods below only canonicalize
# the wider Julia numeric types into a leaf type.
@inline _formvalue(x::FormLeaf) = x
# `Bool` before `Integer`, since `Bool <: Integer` and `true` must stay `true`.
@inline _formvalue(x::Bool) = x
# The numeric tower's exact leaves (also members of `FormLeaf`; named here so
# they are more specific than `Integer`/`Real`/`Complex` and cannot be ambiguous).
@inline _formvalue(x::BigInt) = x
@inline _formvalue(x::BigFloat) = x
@inline _formvalue(x::Rational{Int64}) = x
@inline _formvalue(x::Rational{BigInt}) = x
@inline _formvalue(x::Complex{BigFloat}) = x
@inline _formvalue(x::ComplexF64) = x

# An integer becomes an `Int64` when it fits, and a `BigInt` otherwise.
@inline _formvalue(x::Integer) = _canonical_int(x)
function _canonical_int(x::Integer)
    x isa BigInt && return x
    typemin(Int64) <= x <= typemax(Int64) ? Int64(x) : BigInt(x)
end

# A float becomes a `Float64` where that is exact (every `Float16`/`Float32`),
# and otherwise a `BigFloat` at the current precision where that is exact.
@inline _formvalue(x::Float16) = Float64(x)
@inline _formvalue(x::Float32) = Float64(x)
@inline _formvalue(x::Float64) = x
function _formvalue(x::AbstractFloat)
    y = BigFloat(x)
    y == x || _formerror(x, "it is not exactly representable as a BigFloat")
    return y
end

# A rational's components pick the leaf type: `Int64`-backed when they fit,
# `BigInt`-backed otherwise. (`Rational{Int64}`/`Rational{BigInt}` are exact
# leaves and keep their type; this handles every other integer component type.)
function _formvalue(x::Rational)
    n = _canonical_int(numerator(x))
    d = _canonical_int(denominator(x))
    return (n isa BigInt || d isa BigInt) ? BigInt(n) // BigInt(d) : Int64(n) // Int64(d)
end

# A complex becomes `ComplexF64` when both parts are exactly `Float64`, else
# `Complex{BigFloat}` when both are exactly `BigFloat`, and is otherwise
# rejected: rounding a part would silently change the value.
function _formvalue(x::Complex)
    re, im = real(x), imag(x)
    r64 = _exact_float64(re)
    i64 = _exact_float64(im)
    (r64 !== nothing && i64 !== nothing) && return ComplexF64(r64, i64)
    rb = _exact_bigfloat(re)
    ib = _exact_bigfloat(im)
    (rb !== nothing && ib !== nothing) && return Complex{BigFloat}(rb, ib)
    return _formerror(x, "its parts are not exactly representable as Float64 or BigFloat")
end

# The exact `Float64` value of `x`, or `nothing` when there is none.
function _exact_float64(x)
    y = try
        Float64(x)
    catch
        return nothing
    end
    return y == x ? y : nothing
end

# The exact `BigFloat` value of `x` at the current precision, or `nothing`.
function _exact_bigfloat(x)
    x isa BigFloat && return x
    y = try
        BigFloat(x)
    catch
        return nothing
    end
    return y == x ? y : nothing
end

# Every other real — an `Irrational` constant, for example — is not a value type
# a form can hold exactly; it is converted to `Float64`.
@inline _formvalue(x::Real) = Float64(x)
@inline _formvalue(x::Char) = string(x)
@inline _formvalue(x::AbstractString) = String(x)

"""
    is_form_representable(x) -> Bool

Whether [`to_form(x)`](@ref to_form) can represent `x` without raising. It
mirrors the conversion rules exactly:

- any [`Form`](@ref), `FormLeaf`, `Bool`, `Symbol`, `String`, `Char`, `Integer`,
  `Rational`, `Float16`/`Float32`/`Float64`/`BigFloat`, or `Irrational`;
- a `Complex` whose parts are exactly `Float64` or exactly `BigFloat` (so
  `complex(1//2, 3//2)` is representable, but `complex(1//3, 0)` is not);
- an [`AbstractAirExtern`](@ref) whose type is registered;
- recursively, an `AbstractVector` of representable values, or an
  `AbstractDict` whose keys are symbols/strings/chars and whose values are
  representable.

It is a pre-check only: `to_form` itself is unchanged and still raises an
`ArgumentError` for a value it cannot represent.
"""
is_form_representable(::Form) = true
is_form_representable(::FormLeaf) = true
is_form_representable(::Bool) = true
is_form_representable(::BigInt) = true
is_form_representable(::BigFloat) = true
is_form_representable(::Rational{Int64}) = true
is_form_representable(::Rational{BigInt}) = true
is_form_representable(::Complex{BigFloat}) = true
is_form_representable(::ComplexF64) = true
is_form_representable(::Integer) = true
is_form_representable(::Float16) = true
is_form_representable(::Float32) = true
is_form_representable(::Float64) = true
function is_form_representable(x::AbstractFloat)
    y = try
        BigFloat(x)
    catch
        return false
    end
    return y == x
end
is_form_representable(::Rational) = true
function is_form_representable(x::Complex)
    re, im = real(x), imag(x)
    r64 = _exact_float64(re)
    i64 = _exact_float64(im)
    (r64 !== nothing && i64 !== nothing) && return true
    rb = _exact_bigfloat(re)
    ib = _exact_bigfloat(im)
    return rb !== nothing && ib !== nothing
end
function is_form_representable(x::Real)
    try
        Float64(x)
    catch
        return false
    end
    return true
end
is_form_representable(::Char) = true
is_form_representable(::AbstractString) = true
is_form_representable(x::AbstractVector) = all(is_form_representable, x)
function is_form_representable(x::AbstractDict)
    for (k, v) in x
        (k isa Symbol || k isa AbstractString || k isa Char) || return false
        is_form_representable(v) || return false
    end
    return true
end
is_form_representable(x) = false
function _formvalue(x::AbstractVector)
    return FormContainer(FormSeq(FormValue[_store(v) for v in x]), FormMap())
end
function _formvalue(x::AbstractDict)
    pairs = Pair{Symbol,FormValue}[_formkey(k) => _store(v) for (k, v) in x]
    return FormContainer(FormSeq(), FormMap(pairs))
end
# A bare extern data object is wrapped in an unnamed extern; its type must be
# registered, since that is what supplies its operations.
@inline function _formvalue(x::AbstractAirExtern)
    T = typeof(x)
    return FormExtern(_extern_handle(T, _extern_type(T).name, nothing, x, true, nothing))
end
_formvalue(x) = _formerror(x, "it is not a value type this can represent")

# A dictionary key must become a symbol for the map. Only the conversions that
# cannot lose information are made.
@inline _formkey(k::Symbol) = k
@inline _formkey(k::AbstractString) = Symbol(k)
@inline _formkey(k::Char) = Symbol(string(k))
_formkey(k) = _formerror(k, "a map key must be a Symbol, a String or a Char")

# A container stores raw leaves: a scalar form is stored as the leaf it wraps, so
# `form(:a)` and a value read back out of a container agree.
@inline _stored(fs::FormScalar) = value(fs)
@inline _stored(x) = x
@inline _store(x) = _stored(_formvalue(x))

# ---- converting a value into a form ------------------------------------------

"""
    to_form(x) -> Form

`x` as a form: a form is returned as it is, a leaf becomes a
[`FormScalar`](@ref), and a `Vector`/`PVector` or `Dict`/`PDict` becomes a
[`FormContainer`](@ref). Anything else raises.
"""
@inline function to_form(x)::FormNode
    v = _formvalue(x)
    return v isa Form ? v : FormScalar(v)
end

# ---- construction ------------------------------------------------------------

"""
    Form(x::FormLeaf) -> FormScalar
    Form(seq, map) -> FormContainer
    form(seqargs...; mapargs...) -> FormContainer

`Form(x)` for a leaf builds a scalar form, and `Form(seq, map)` builds a container
from collections. `form(...)` is the general builder: its positional arguments
become the sequence and its keyword arguments the map, each converted the way
[`to_form`](@ref) does.
"""
Form(x::FormLeaf)::FormNode = FormScalar(x)
# A narrower scalar (an `Int32`, a `Complex{Int64}`, a `Float32`) is converted to
# the leaf it becomes, so `Form(1 + 2im)` works. Anything that is not a single
# leaf — a vector, a dictionary — must go through `to_form` or `form`.
function Form(x)::FormNode
    v = _formvalue(x)
    v isa FormLeaf ||
        _formerror(x, "it is not a single leaf; use to_form or form to build a container")
    return FormScalar(v)
end
Form(seq::PVector, map::PDict) = FormContainer(
    FormSeq(FormValue[_store(x) for x in seq]),
    FormMap(Pair{Symbol,FormValue}[_formkey(k) => _store(v) for (k, v) in map]),
)

"""
    form(seqargs...; mapargs...) -> FormContainer

Build a container from its arguments: the positional arguments become the
sequence and the keyword arguments the map, each converted the way
[`to_form`](@ref) does.

# Examples
```julia
form("widget", 1, meta = form(name = "abc"))
```
"""
function form(args...; kwargs...)
    seq = FormSeq(FormValue[_store(a) for a in args])
    map = FormMap(Pair{Symbol,FormValue}[k => _store(v) for (k, v) in kwargs])
    return FormContainer(seq, map)
end

# ---- keywords and wildcards --------------------------------------------------

"""
    iskeyword(f) -> Bool

Whether `f` is a keyword — a symbol scalar form whose name begins with `:`, such
as `Form(Symbol(":abc"))`. Any other form is not a keyword. See
[`iswildcard`](@ref).
"""
iskeyword(fs::FormScalar{Symbol}) = startswith(string(value(fs)), ":")
iskeyword(::Form) = false

"""
    iswildcard(f) -> Bool

Whether `f` is a wildcard — a symbol scalar form whose name begins with `?`, such
as `Form(Symbol("?abc"))`. Any other form is not a wildcard. See
[`iskeyword`](@ref).
"""
iswildcard(fs::FormScalar{Symbol}) = startswith(string(value(fs)), "?")
iswildcard(::Form) = false

# ---- the canonical order -----------------------------------------------------

# The keys of a form in the one order everything uses: every sequence position,
# then every map key in sorted order. `:`, iteration, `keys` and `pairs` all agree
# on it.
function _ordered_keys(f::FormContainer)
    ks = Vector{Any}(undef, length(f.seq) + length(f.map))
    i = 0
    for k in 1:length(f.seq)
        ks[i += 1] = k
    end
    for k in sort!(collect(keys(f.map)))
        ks[i += 1] = k
    end
    return ks
end

# The value at a key, as a form (a leaf is wrapped).
@inline _keyget(f::FormContainer, k::Integer)::FormNode = to_form(f.seq[k])
@inline _keyget(f::FormContainer, k::Symbol)::FormNode = to_form(f.map[k])

# ---- the collection protocol -------------------------------------------------

Base.length(f::FormContainer) = length(f.seq) + length(f.map)
Base.length(::FormScalar) = 0
Base.isempty(f::FormContainer) = isempty(f.seq) && isempty(f.map)
Base.isempty(::FormScalar) = true

Base.haskey(f::FormContainer, i::Integer) = i in eachindex(f.seq)
Base.haskey(f::FormContainer, k::Symbol) = haskey(f.map, k)

Base.keys(f::FormContainer) = _ordered_keys(f)
Base.keys(::FormScalar) = ()
Base.values(f::FormContainer) = FormNode[_keyget(f, k) for k in _ordered_keys(f)]
Base.values(::FormScalar) = ()
Base.pairs(f::FormContainer) = (k => _keyget(f, k) for k in _ordered_keys(f))
Base.pairs(::FormScalar) = ()

# Iterating a form yields `key => value` pairs, in the canonical order, so
# `for (k, v) in f` works and `collect(f)` gives the pairs.
function Base.iterate(f::FormContainer, st = (1, _ordered_keys(f)))
    i, ks = st
    i > length(ks) && return nothing
    k = ks[i]
    return (k => _keyget(f, k), (i + 1, ks))
end
Base.iterate(::FormScalar, ::Any = nothing) = nothing

Base.first(f::FormContainer) = (k = _ordered_keys(f)[1]; k => _keyget(f, k))
Base.last(f::FormContainer) = (ks = _ordered_keys(f); k = ks[end]; k => _keyget(f, k))

# A form is immutable, so a copy is itself, and the empty form of any form is the
# empty container.
Base.copy(f::Form) = f
Base.empty(::Form) = form()

# ---- updating ----------------------------------------------------------------

push(f::FormContainer, v) = FormContainer(push(f.seq, _formvalue(v)), f.map)

function pop(f::FormContainer)
    isempty(f.seq) && throw(ArgumentError("a FormContainer with an empty seq has nothing to pop"))
    return FormContainer(pop(f.seq), f.map)
end

# `deleteat`, not `delete`: the latter removes a *value* from a vector, and here
# the argument is a position.
delete(f::FormContainer, i::Integer) = FormContainer(deleteat(f.seq, i), f.map)
delete(f::FormContainer, k::Symbol) = FormContainer(f.seq, delete(f.map, k))

# ---- equality ----------------------------------------------------------------

Base.:(==)(a::FormScalar, b::FormScalar) = a.value == b.value
Base.:(==)(a::FormContainer, b::FormContainer) = a.seq == b.seq && a.map == b.map
Base.:(==)(::Form, ::Form) = false          # different concrete kinds of form

Base.isequal(a::FormScalar, b::FormScalar) = isequal(a.value, b.value)
Base.isequal(a::FormContainer, b::FormContainer) =
    isequal(a.seq, b.seq) && isequal(a.map, b.map)
Base.isequal(::Form, ::Form) = false

Base.hash(fs::FormScalar, h::UInt) = hash(fs.value, hash(:FormScalar, h))
Base.hash(fc::FormContainer, h::UInt) =
    hash(fc.map, hash(fc.seq, hash(:FormContainer, h)))

# ---- printing ----------------------------------------------------------------

# A nested container prints without the `Form` prefix, so a form reads like a
# function call with its arguments: `Form("widget", meta=(name="abc"))`. A scalar
# form prints as the leaf it wraps.
function _showvalue(io::IO, fc::FormContainer)
    print(io, "(")
    _showcontents(io, fc)
    return print(io, ")")
end
_showvalue(io::IO, fs::FormScalar) = show(io, value(fs))
_showvalue(io::IO, x) = show(io, x)

function _showcontents(io::IO, fc::FormContainer)
    sep = ""
    for x in fc.seq
        print(io, sep)
        sep = ", "
        _showvalue(io, x)
    end
    # The keys are sorted so that what is printed is a property of the form and
    # not of the map's iteration order, which is an implementation detail of the
    # HAMT. Note that this means keyword values do not print in the order they
    # were given: the map is a `PDict`, so it does not record one.
    for k in sort!(collect(keys(fc.map)))
        print(io, sep, k, "=")
        sep = ", "
        _showvalue(io, fc.map[k])
    end
    return nothing
end

Base.show(io::IO, fs::FormScalar) = (print(io, "Form("); _showvalue(io, fs); print(io, ")"))
Base.show(io::IO, fc::FormContainer) = (print(io, "Form("); _showcontents(io, fc); print(io, ")"))

export Form, FormScalar, FormContainer, FormLeaf, FormValue, form, to_form, value,
    iskeyword, iswildcard, is_form_representable
