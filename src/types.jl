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

The scalar values a form can hold: `String`, `Symbol`, `Bool`, `Nothing`, and
the numeric tower wherever it is a value type —
`Int64`, `BigInt`, `Float64`, `BigFloat`, `Rational{Int64}`,
`Rational{BigInt}`, `ComplexF64` and `Complex{BigFloat}`. A [`FormScalar`](@ref)
wraps one; a [`FormContainer`](@ref) holds forms and leaves. Narrower scalar
types are converted to one of these where the conversion is exact; see
[`to_form`](@ref).
"""
const FormLeaf = Union{String,Symbol,Bool,Nothing,Int64,BigInt,Float64,BigFloat,
                       Rational{Int64},Rational{BigInt},ComplexF64,Complex{BigFloat}}

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

# The metadata a database-backed object carries: a form, or `nothing` for none.
# It lives in an Air `Volatile` on every kind, so a metadata edit is
# transactional like any other write: Air rolls it back on abort, applies it at
# commit so the next reader sees it at once, and validates it at commit.
const FormMetadata = Union{Nothing,Form}

# The metadata volatile itself, or `nothing` until it has been read. A
# constructed object starts with it; a loaded one fills it from its row.
const MetadataVolatile = Volatile{FormMetadata}

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

A form holding just a leaf (see [`FormLeaf`](@ref)): a string, symbol, `Bool`,
`Nothing`, or one of the numeric tower's value types. `Form(x)` for a leaf `x`
builds one, and indexing a container wraps a leaf into one, so every value read
out of a form is a form. Use [`value`](@ref) to get the leaf back.
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
    present::Bool                    # a `resources` row exists for this handle
    lock::ReadWriteLock
    loadlock::ReentrantLock          # guards the lazy `resources` read
    version::Volatile{Int}           # Air version cell, read inside transactions
    edits::Int                       # read-edit ops since the last publish
    dirty::Bool                      # read-edited since the last resource write
    metavolatile::Union{Nothing,MetadataVolatile}  # owner/ACL metadata, transactional
    db::Union{Nothing,AbstractDatabase}
    ExternHandle{T}(type, id, data, loaded, present, lock, loadlock, version, edits,
                    dirty, metavolatile, db) where {T} =
        new(type, id, data, loaded, present, lock, loadlock, version, edits, dirty,
            metavolatile, db)
end
_extern_handle(::Type{T}, type, id, data, loaded, db;
               metadata = nothing, metaloaded::Bool = false,
               present::Bool = false) where {T<:AbstractAirExtern} =
    ExternHandle{T}(type, id, data, loaded, present, ReadWriteLock(), ReentrantLock(),
                    Volatile{Int}(0), 0, false,
                    metaloaded ? Volatile{FormMetadata}(metadata) : nothing, db)

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
    metavolatile::Union{Nothing,MetadataVolatile}  # owner/ACL metadata
    history::Bool                              # record history? fixed at creation
    # The inner constructor is typed so that it does not collide with the
    # `VolatileForm(db, args...)` convenience constructor below.
    VolatileForm(id::UUID, volatile::Union{Nothing,Volatile{Form}}, loaded::Bool,
                 persisted::Bool, lock::ReentrantLock, db::AbstractDatabase,
                 metavolatile::Union{Nothing,MetadataVolatile}, history::Bool) =
        new(id, volatile, loaded, persisted, lock, db, metavolatile, history)
end

"""
    ActorForm

A [`Form`](@ref) backed by an Air `Actor{Form}`: its value is updated by sending
functions to it, and every update is written to the database. Most actors are
orderly workers, and this one persists each value it takes.

Create one with `ActorForm(db, args...; kwargs...)` or
`ActorForm(db, form::Form; history = true)`; retrieve an existing one with
[`get_actor`](@ref). In JSON an actor is written `"!<uuid>"`.
"""
mutable struct ActorForm <: Form
    id::UUID
    actor::Union{Nothing,Actor{Form}}   # nothing until loaded
    loaded::Bool
    persisted::Bool
    lock::ReentrantLock
    db::AbstractDatabase
    history::Bool                       # record history? fixed at creation
    metavolatile::Union{Nothing,MetadataVolatile}   # owner/ACL metadata
    ActorForm(id::UUID, actor::Union{Nothing,Actor{Form}}, loaded::Bool,
              persisted::Bool, lock::ReentrantLock, db::AbstractDatabase,
              history::Bool,
              metavolatile::Union{Nothing,MetadataVolatile}) =
        new(id, actor, loaded, persisted, lock, db, history, metavolatile)
end

"""
    UncommittedPromise

Raised when a promise created inside a transaction is read before that
transaction commits. See [`PromiseForm`](@ref).
"""
struct UncommittedPromise <: Exception
    id::UUID
end
Base.showerror(io::IO, e::UncommittedPromise) =
    print(io, "promise ", e.id, " was created in a transaction that has not committed")

"""
    AbortedPromise

Raised when a promise whose creating transaction aborted is read or delivered.
"""
struct AbortedPromise <: Exception
    id::UUID
end
Base.showerror(io::IO, e::AbortedPromise) =
    print(io, "promise ", e.id, " was created in a transaction that aborted")

"""
    PromiseForm

A [`Form`](@ref) backed by an Air `Promise{Form}`. A promise is delivered once;
a form that holds one stores the link `"~<uuid>"`, whether the promise is
pending, delivered, or failed, and the promise always has a row to hold its
state, so its identity and outcome survive a round trip.

Create one with `PromiseForm(db)`; deliver it with `put!(pf, value)`; retrieve an
existing one with [`get_promise`](@ref).
"""
mutable struct PromiseForm <: Form
    id::UUID
    promise::Union{Nothing,Air.Promise{Form}}   # nothing until loaded
    loaded::Bool
    persisted::Bool
    lock::ReentrantLock
    db::AbstractDatabase
    metavolatile::Union{Nothing,MetadataVolatile}   # owner/ACL metadata
    commit_state::Symbol                # :live | :pending | :aborted
    PromiseForm(id::UUID, promise::Union{Nothing,Air.Promise{Form}}, loaded::Bool,
                persisted::Bool, lock::ReentrantLock, db::AbstractDatabase,
                metavolatile::Union{Nothing,MetadataVolatile},
                commit_state::Symbol) =
        new(id, promise, loaded, persisted, lock, db, metavolatile, commit_state)
end

"""
    UncommittedStream

Raised when a stream created inside a transaction is used before that
transaction commits. See [`StreamForm`](@ref).
"""
struct UncommittedStream <: Exception
    id::UUID
end
Base.showerror(io::IO, e::UncommittedStream) =
    print(io, "stream ", e.id, " was created in a transaction that has not committed")

"""
    AbortedStream

Raised when a stream whose creating transaction aborted is used.
"""
struct AbortedStream <: Exception
    id::UUID
end
Base.showerror(io::IO, e::AbortedStream) =
    print(io, "stream ", e.id, " was created in a transaction that aborted")

"""
    StreamForm

A [`Form`](@ref) backed by an Air `Stream{Form}`: a FIFO of forms that supports
blocking `put!`/`take`, an optional bound, timeouts, and `close`. Its contents
are persisted, and it loads lazily by id.

Create one with `StreamForm(db; maxsize, metadata)`; retrieve an existing one
with [`get_stream`](@ref). In JSON a stream is written `"&<uuid>"`.
"""
mutable struct StreamForm <: Form
    id::UUID
    stream::Union{Nothing,Air.Stream{Form}}     # nothing until loaded
    loaded::Bool
    persisted::Bool
    lock::ReentrantLock
    oplock::ReentrantLock                        # serializes snapshot + staging
    db::AbstractDatabase
    metavolatile::Union{Nothing,MetadataVolatile}   # owner/ACL metadata
    commit_state::Symbol                         # :live | :pending | :aborted
    StreamForm(id::UUID, stream::Union{Nothing,Air.Stream{Form}}, loaded::Bool,
               persisted::Bool, lock::ReentrantLock, oplock::ReentrantLock,
               db::AbstractDatabase,
               metavolatile::Union{Nothing,MetadataVolatile},
               commit_state::Symbol) =
        new(id, stream, loaded, persisted, lock, oplock, db, metavolatile,
            commit_state)
end

"""
    DelayForm(type, form)

A [`Form`](@ref) that computes its value lazily from a serialized form. `type` is
the keyword under which a loader was registered with [`register_delay`](@ref);
`form` is the serialization, fixed for the delay's life. `d[]` runs the loader
once and memoizes the result, and writing the delay back out never forces it.
"""
struct DelayForm <: Form
    type::Symbol
    form::Form
    delay::Air.Delay{Form}
    DelayForm(type::Symbol, form::Form, delay::Air.Delay{Form}) = new(type, form, delay)
end

"""
    FormNode

The concrete kinds of form, as a `Union`. The operations that produce a form are
typed to return this union rather than the abstract [`Form`](@ref), so the
compiler keeps a scalar form inline instead of boxing it on every read.
"""
const FormNode = Union{FormScalar,FormContainer,VolatileForm,FormExtern,
                       ActorForm,PromiseForm,StreamForm,DelayForm}

# ---- reference collection ----------------------------------------------------
#
# Encoding a form records the externs, promises, and streams it names in
# task-local sets, so the writer can create their rows before the forms that name
# them. Encoding for any other reason (`to_JSON`, a caller's own use) must not
# leave those strong references behind on a long-lived task, so a note is
# recorded only while the writer is encoding.
const _COLLECT_REFS_KEY = :AirDBCollectRefs
_collecting_refs() = get(task_local_storage(), _COLLECT_REFS_KEY, false) === true

function _collecting!(f::Function)
    task_local_storage(_COLLECT_REFS_KEY, true)
    try
        return f()
    finally
        task_local_storage(_COLLECT_REFS_KEY, false)
    end
end

# ---- metadata and commit state -----------------------------------------------
#
# The four kinds whose body is not already a volatile carry their metadata in an
# Air `Volatile`, so a metadata edit is transactional. Reading the volatile
# inside a transaction registers an Air read (the edit is visible to its own
# transaction and validated at commit); outside one it is a plain read. These
# helpers assume the metadata is known; `metadata(x)` loads it when it is not.

function _metavalue(x)::FormMetadata
    v = getfield(x, :metavolatile)
    v === nothing && return nothing
    return (v::MetadataVolatile)[]
end

function _setmetavalue!(x, m::FormMetadata)
    v = getfield(x, :metavolatile)
    (v::MetadataVolatile)[] = m
    return m
end

# The commit state (`:live`/`:pending`/`:aborted`) is handed between threads
# (the creating transaction and whoever later reads or aborts the object), so it
# is read and written under the object's lock.
function _commit_state(x)
    lock(x.lock)
    try
        return x.commit_state
    finally
        unlock(x.lock)
    end
end

function _set_commit_state!(x, s::Symbol)
    lock(x.lock)
    try
        x.commit_state = s
    finally
        unlock(x.lock)
    end
    return x
end

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

Base.isequal(a::ActorForm, b::ActorForm) = a.id == b.id
Base.:(==)(a::ActorForm, b::ActorForm) = a.id == b.id
Base.hash(af::ActorForm, h::UInt) = hash(af.id, hash(:ActorForm, h))

Base.isequal(a::PromiseForm, b::PromiseForm) = a.id == b.id
Base.:(==)(a::PromiseForm, b::PromiseForm) = a.id == b.id
Base.hash(pf::PromiseForm, h::UInt) = hash(pf.id, hash(:PromiseForm, h))

Base.isequal(a::StreamForm, b::StreamForm) = a.id == b.id
Base.:(==)(a::StreamForm, b::StreamForm) = a.id == b.id
Base.hash(sf::StreamForm, h::UInt) = hash(sf.id, hash(:StreamForm, h))

Base.isequal(a::DelayForm, b::DelayForm) = a.type == b.type && isequal(a.form, b.form)
Base.:(==)(a::DelayForm, b::DelayForm) = a.type == b.type && a.form == b.form
Base.hash(df::DelayForm, h::UInt) = hash(df.form, hash(df.type, hash(:DelayForm, h)))
