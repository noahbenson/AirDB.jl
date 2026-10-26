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
    AbstractAirExtern

The supertype of a host-level value a form can hold *without* being JSON itself —
a socket, a promise, a configuration handle, a cached value. A form stores one
inside a [`FormExtern`](@ref); its operations, constructors, and optional
serialization are declared with [`register_extern`](@ref).
"""
abstract type AbstractAirExtern end

# `Database` (database.jl) and the form types refer to one another — a form
# belongs to a database, and a database holds caches of forms and extern
# resources — so the form types are written against this abstract type, which
# `Database` and `MemoryDatabase` subtype.
abstract type AbstractDatabase end

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
    DeadExtern(type)

The data of a [`FormExtern`](@ref) whose object could not be stored: it was
unnamed, or its type declared no serialization. A dead extern carries only the
registered type name and raises whenever it is used.
"""
struct DeadExtern <: AbstractAirExtern
    type::Symbol
end

# A reader/writer lock over a resource: any number of readers may hold it at
# once; a writer excludes both readers and other writers. Writers are preferred
# so a stream of readers cannot starve one. Nested use on one task is not
# supported beyond a plain reader re-entry.
mutable struct ReadWriteLock
    mtx::ReentrantLock
    cond::Threads.Condition
    readers::Int
    writer::Bool
    waiting_writers::Int
    ReadWriteLock() = (m = ReentrantLock(); new(m, Threads.Condition(m), 0, false, 0))
end

"""
    ExternHandle

The live state behind a [`FormExtern`](@ref): the registered type name, the
optional keyword `id` under which it is stored, the object's `data`, the lock and
the Air `Volatile{Int}` version cell that give it its concurrency semantics, and
the database it belongs to. A handle is created either by `construct` or by
loading a form that references it; its data is read from the `resources` table on
first use when it was loaded.
"""
mutable struct ExternHandle{T<:AbstractAirExtern}
    type::Symbol
    id::Union{Nothing,Symbol}
    data::Union{Nothing,T}
    loaded::Bool
    lock::ReadWriteLock
    loadlock::ReentrantLock          # guards the lazy `resources` read
    version::Volatile{Int}           # Air version cell, read inside transactions
    edits::Int                       # read-edit ops since the last publish
    dirty::Bool                      # read-edited since the last resource write
    db::Union{Nothing,AbstractDatabase}
    ExternHandle{T}(type, id, data, loaded, lock, loadlock, version, edits, dirty, db) where {T} =
        new(type, id, data, loaded, lock, loadlock, version, edits, dirty, db)
end
_extern_handle(::Type{T}, type, id, data, loaded, db) where {T<:AbstractAirExtern} =
    ExternHandle{T}(type, id, data, loaded, ReadWriteLock(), ReentrantLock(),
                    Volatile{Int}(0), 0, false, db)

"""
    FormExtern(handle)

A form holding a host-level [`AbstractAirExtern`](@ref): an object whose
operations are defined by its registered type and whose data lives in an
[`ExternHandle`](@ref). Build one with `construct`; use [`value`](@ref) to get the
data back.
"""
struct FormExtern{T<:AbstractAirExtern} <: Form
    handle::ExternHandle{T}
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
    # Suppress the generated constructor, as in the original: `FormContainer(a, b)`
    # must not capture two positional values.
    FormContainer(seq::FormSeq, map::FormMap) = new(seq, map)
end

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
    metadata::Union{Nothing,Form}              # optional JSONB metadata (mutable)
    history::Bool                              # record history? fixed at creation
    # The inner constructor is typed so that it does not collide with the
    # `VolatileForm(db, args...)` convenience constructor below.
    VolatileForm(id::UUID, volatile::Union{Nothing,Volatile{Form}}, loaded::Bool,
                 persisted::Bool, lock::ReentrantLock, db::AbstractDatabase,
                 metadata::Union{Nothing,Form}, history::Bool) =
        new(id, volatile, loaded, persisted, lock, db, metadata, history)
end

"""
    FormNode

The concrete kinds of form, as a `Union`. The operations that produce a form are
typed to return this union rather than the abstract [`Form`](@ref), so the
compiler keeps a scalar form inline instead of boxing it on every read.
"""
const FormNode = Union{FormScalar,FormContainer,VolatileForm,FormExtern}

# ---- shared operations -------------------------------------------------------

"""
    value(fs::FormScalar)
    value(fe::FormExtern)

The leaf a scalar form wraps, or the data an extern form wraps (loading it from
the database first if it was loaded rather than constructed).
"""
value(fs::FormScalar) = fs.value
value(fe::FormExtern) = (_ensure_loaded(fe.handle); fe.handle.data)

Base.isequal(a::VolatileForm, b::VolatileForm) = a.id == b.id
Base.:(==)(a::VolatileForm, b::VolatileForm) = a.id == b.id
Base.hash(vf::VolatileForm, h::UInt) = hash(vf.id, hash(:VolatileForm, h))
