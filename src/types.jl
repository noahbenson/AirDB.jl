################################################################################
# types.jl
#
# The form type hierarchy, gathered in one place so that every concrete type is
# known before the `FormNode` union below. The operations return `FormNode` (the
# concrete union) rather than the abstract `Form`, so a scalar form — which may be
# an isbits value — is kept inline instead of being boxed on every read.
#
# MIT License
# Copyright (c) 2020-2026 Noah C. Benson

"""
    FormLeaf

The scalar values a form can hold: `String`, `Symbol`, `Bool`, `Int64`,
`Float64`, `ComplexF64` and `Nothing`. A [`FormScalar`](@ref) wraps one; a
[`FormContainer`](@ref) holds forms and leaves.
"""
const FormLeaf = Union{String,Symbol,Bool,Int64,Float64,ComplexF64,Nothing}

"""
    Form

The abstract supertype of every form: [`FormScalar`](@ref) (a bare leaf),
[`FormContainer`](@ref) (a sequence and a map), and [`VolatileForm`](@ref) (a form
that persists itself). The concrete kinds are gathered in [`FormNode`](@ref).
"""
abstract type Form end

"""
    FormValue

What a [`FormContainer`](@ref) holds directly: a [`Form`](@ref) or a
[`FormLeaf`](@ref).
"""
const FormValue = Union{Form,FormLeaf}

# ---- small collections -------------------------------------------------------
#
# A container's sequence and map are usually small, and for small sizes a flat,
# copy-on-write `Vector` is both far cheaper to build (Air's HAMT allocates
# hundreds of bytes and costs hundreds of nanoseconds for a handful of entries)
# and no slower to look up. `FormSeq`/`FormMap` hold either a flat `Vector` (up to
# `_SMALL` entries) or Air's persistent `PVector`/`PDict` above it, promoting on
# growth. Every update copies — nothing is ever mutated in place — so the
# immutable sharing semantics are unchanged.

const _SMALL = 16

struct FormSeq
    v::Union{Vector{FormValue},PVector{FormValue}}
    FormSeq(v::Union{Vector{FormValue},PVector{FormValue}}, ::Val{:raw}) = new(v)
end

struct FormMap
    v::Union{Vector{Pair{Symbol,FormValue}},PDict{Symbol,FormValue}}
    FormMap(v::Union{Vector{Pair{Symbol,FormValue}},PDict{Symbol,FormValue}}, ::Val{:raw}) = new(v)
end

"""
    FormScalar(value)

A form holding just a leaf: a `String`, `Symbol`, `Bool`, `Int64`, `Float64`,
`ComplexF64` or `Nothing`. `Form(x)` for a leaf `x` builds one, and indexing a
container wraps a leaf into one, so every value read out of a form is a form.
Use [`value`](@ref) to get the leaf back.
"""
struct FormScalar{T<:FormLeaf} <: Form
    value::T
end

"""
    FormContainer(seq, map)

A form holding a sequence of positional values (`seq`) and a map of symbol-keyed
values (`map`), each a [`FormValue`](@ref). Build one with [`form`](@ref),
[`to_form`](@ref), or from prepared collections.
"""
struct FormContainer <: Form
    seq::FormSeq
    map::FormMap
    held::Bool
    # Suppress the generated constructor, as in the original: `FormContainer(a, b)`
    # must not capture two positional values. `held` is part of the container's
    # value — a held form is not equal to an unheld one — but not of its JSON
    # encoding.
    FormContainer(seq::FormSeq, map::FormMap, held::Bool = false) = new(seq, map, held)
end

# `Database` (database.jl) and a `VolatileForm` refer to one another — a form
# belongs to a database, and a database holds the name table of forms — so the
# form is written against this abstract type, which `Database` subtypes.
abstract type AbstractDatabase end

"""
    VolatileForm

A [`Form`](@ref) that is stored in a PostgreSQL database and kept in sync with
it. A `VolatileForm` is a thin wrapper around an Air `Volatile{Form}`: it can be
read at any time, but it may only be *written* inside an Air transaction
(`@tx`/`tx`), and when that transaction commits the new value is sent to the
database's writer actor.

Every `VolatileForm` has a stable `UUID`, and forms may embed other
volatile forms (written `"@<uuid>"` in JSON). Volatile forms are cached per
`Database` by id, so the same form is always the same object within one process.

Create one with `VolatileForm(db, args...; kwargs...)` or
`VolatileForm(db, form::Form)`; retrieve an existing one with
[`get_form`](@ref).
"""
mutable struct VolatileForm <: Form
    id::UUID
    volatile::Union{Nothing,Volatile{Form}}   # nothing until loaded
    loaded::Bool
    persisted::Bool                            # a row exists / has been written
    lock::ReentrantLock                        # guards the load
    db::AbstractDatabase
    # The inner constructor is typed so that it does not collide with the
    # `VolatileForm(db, args...)` convenience constructor below.
    VolatileForm(id::UUID, volatile::Union{Nothing,Volatile{Form}}, loaded::Bool,
                 persisted::Bool, lock::ReentrantLock, db::AbstractDatabase) =
        new(id, volatile, loaded, persisted, lock, db)
end

"""
    FormNode

The concrete kinds of form, as a `Union`. The operations that produce a form are
typed to return this union rather than the abstract [`Form`](@ref), so the
compiler keeps a scalar form inline instead of boxing it on every read.
"""
const FormNode = Union{FormScalar,FormContainer,VolatileForm}

# ---- shared operations -------------------------------------------------------

"""
    value(fs::FormScalar)

The leaf a scalar form wraps.
"""
value(fs::FormScalar) = fs.value

Base.isequal(a::VolatileForm, b::VolatileForm) = a.id == b.id
Base.:(==)(a::VolatileForm, b::VolatileForm) = a.id == b.id
Base.hash(vf::VolatileForm, h::UInt) = hash(vf.id, hash(:VolatileForm, h))
