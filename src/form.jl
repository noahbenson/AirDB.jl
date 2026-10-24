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
@inline _formvalue(x::FormLeaf) = x
# `Bool` before `Integer`, since `Bool <: Integer` and `true` must stay `true`.
@inline _formvalue(x::Bool) = x
function _formvalue(x::Integer)
    return try
        Int64(x)
    catch
        _formerror(x, "it does not fit in an Int64, which is the only integer a Form holds")
    end
end
@inline _formvalue(x::Real) = Float64(x)
@inline _formvalue(x::Complex) = ComplexF64(x)
@inline _formvalue(x::Char) = string(x)
@inline _formvalue(x::AbstractString) = String(x)
function _formvalue(x::AbstractVector)
    return FormContainer(FormSeq(FormValue[_store(v) for v in x]), FormMap())
end
function _formvalue(x::AbstractDict)
    pairs = Pair{Symbol,FormValue}[_formkey(k) => _store(v) for (k, v) in x]
    return FormContainer(FormSeq(), FormMap(pairs))
end
# A host-level extern is held as it is, wrapped so the tree stays closed: the
# provider's `serialize_extern` runs only when the form is written.
@inline _formvalue(x::AbstractAirExtern) = FormExtern(x)
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
    iskeyword, iswildcard
