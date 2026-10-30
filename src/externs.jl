################################################################################
# externs.jl
#
# Host-level extern types: user-defined objects (sockets, promises, handles)
# whose operations are declared in Julia and whose data may be stored in the
# database. A form holds one in a `FormExtern`, which wraps an `ExternHandle` —
# the live state: the object's data, an optional keyword `id`, a reader/writer
# lock, and an Air `Volatile{Int}` version cell.
#
# Registration supplies, per type, a PDict of read-only operations, a PDict of
# read-edit operations, a PDict of constructors, an `immutable` flag, and (both
# or neither) serialization functions that read and write the data through an
# `IO`. Operation and constructor names are keywords (`Symbol(":read-bytes")`),
# matching the argument passed to `call`/`construct`.
#
# Concurrency. An immutable type's API is available to any thread at any time.
# A mutable type's API is never handed out directly: `reserve_read` takes the
# resources' read locks in sorted `(type, id)` order and runs the function on the
# caller's task, while `reserve` takes their write locks on a spawned task and
# returns a promise. Both orders avoid deadlock. Every read-edit operation
# increments a counter; when a reservation ends the count is published to the
# resource's `Volatile{Int}` version cell. A transaction that read a resource has
# registered that cell with Air, so Air's ordinary commit validation retries it
# if a read-edit intervened — no change to Air is needed.
#
# MIT License
# Copyright (c) 2020-2026 Noah C. Benson

# ---- registration ------------------------------------------------------------

"""
    ExternType

The registered interface of one extern data type: its name, its read-only and
read-edit operation tables, its constructor table, whether it is immutable, its
optional serialization functions, and — for an immutable type that opts in —
its equivalence functions. Built by [`register_extern`](@ref).
"""
struct ExternType{T<:AbstractAirExtern}
    name::Symbol
    read_only::PDict{Symbol,Function}     # (data, Form) -> Form
    read_edit::PDict{Symbol,Function}     # (data, Form) -> Form
    constructors::PDict{Symbol,Function}  # (Form) -> data
    immutable::Bool
    serialize::Union{Nothing,Function}    # (data, IO) -> nothing
    deserialize::Union{Nothing,Function}  # (IO) -> data
    equal::Union{Nothing,Function}        # (data, data) -> Bool
    hashfn::Union{Nothing,Function}       # (data, seed::UInt) -> UInt
end
_typeparam(::ExternType{T}) where {T} = T

# Coerce a user-supplied `PDict` to `PDict{Symbol,Function}`, so the interface
# tables are stored uniformly whatever concrete function types they hold.
function _functiondict(p, what::String)
    out = PDict{Symbol,Function}()
    for (k, v) in p
        (k isa Symbol) || throw(ExternError("an extern $what name must be a symbol, not $k"))
        (v isa Function) || throw(ExternError("an extern $what must be a function, not $(typeof(v))"))
        out = push(out, k => v)
    end
    return out
end

const _EXTERN_BY_NAME = Dict{Symbol,ExternType}()
const _EXTERN_BY_TYPE = Dict{Type,Symbol}()

"""
    register_extern(name, ::Type{T}; read_only, read_edit, constructors,
                    immutable = false, serialize = nothing, deserialize = nothing)

Register an extern data type `T` under `name`. `read_only` and `read_edit` are
`PDict`s of keyword operators to `(data, args) -> Form` functions; `constructors`
is a `PDict` of keyword operators to `(args) -> data` functions. A read-edit
operation may mutate the data and therefore requires a [`reserve`](@ref); an
`immutable` type must declare none, and its API is available to any thread.

`serialize(data, io)` writes the data and `deserialize(io)` reads it back. A type
with both is database-storable: a form may hold a named extern of that type, and
the bytes live in the `resources` table. A type with neither is never stored — a
form that holds one is written as a dead-extern marker.

An **immutable** type may also declare `equal(a, b) -> Bool` and
`hash(data, seed::UInt) -> UInt` (both, or neither). They give the type value
semantics in [`isequiv`](@ref)/[`equivhash`](@ref); without them, two externs
are equivalent only when they wrap the same live handle. A mutable type is
always identity-equivalent and may not declare them.

```julia
register_extern(:config, ConfigData;
    read_only = PDict(Symbol(":version") => (d, args) -> Form(d.version)),
    read_edit = PDict(Symbol(":bump") => (d, args) -> (d.version += 1; Form(d.version))),
    constructors = PDict(Symbol(":new") => args -> ConfigData(1)),
    immutable = false,
    serialize = (d, io) -> print(io, d.version),
    deserialize = io -> ConfigData(parse(Int, read(io, String))))
```
"""
function register_extern(name::Symbol, ::Type{T};
                         read_only = PDict{Symbol,Function}(),
                         read_edit = PDict{Symbol,Function}(),
                         constructors = PDict{Symbol,Function}(),
                         immutable::Bool = false,
                         serialize::Union{Nothing,Function} = nothing,
                         deserialize::Union{Nothing,Function} = nothing,
                         equal::Union{Nothing,Function} = nothing,
                         hash::Union{Nothing,Function} = nothing) where {T<:AbstractAirExtern}
    immutable && !isempty(read_edit) &&
        throw(ExternError("the extern type $T is immutable but declares read-edit operations"))
    ((serialize === nothing) == (deserialize === nothing)) ||
        throw(ExternError("the extern type $T must declare both serialize and deserialize, or neither"))
    ((equal === nothing) == (hash === nothing)) ||
        throw(ExternError("the extern type $T must declare both equal and hash, or neither"))
    (equal !== nothing && !immutable) &&
        throw(ExternError("the extern type $T is mutable; its equivalence is always identity"))
    haskey(_EXTERN_BY_NAME, name) && begin
        reg = _EXTERN_BY_NAME[name]
        reg.type === T ||
            throw(ExternError("the extern name :$name is already registered for $(reg.type), not $T"))
        return reg
    end
    haskey(_EXTERN_BY_TYPE, T) &&
        throw(ExternError("the extern type $T is already registered as :$(_EXTERN_BY_TYPE[T])"))
    et = ExternType{T}(name, _functiondict(read_only, "operation"),
                       _functiondict(read_edit, "operation"),
                       _functiondict(constructors, "constructor"),
                       immutable, serialize, deserialize, equal, hash)
    _EXTERN_BY_NAME[name] = et
    _EXTERN_BY_TYPE[T] = name
    return et
end

# `ExternType.type` is the type parameter; expose it as a property for
# convenience without shadowing the constructor.
Base.getproperty(et::ExternType, k::Symbol) =
    k === :type ? _typeparam(et) : getfield(et, k)

# The registration for a name, or for a value type (walking supertypes so an
# abstract extern type covers its concrete subtypes).
function _extern_type(name::Symbol)
    et = get(_EXTERN_BY_NAME, name, nothing)
    et === nothing && throw(ExternError("no extern type is registered under :$name"))
    return et::ExternType
end
function _extern_type(::Type{T}) where {T}
    S = T
    while S !== Any
        if haskey(_EXTERN_BY_TYPE, S)
            return _extern_type(_EXTERN_BY_TYPE[S])
        end
        S = supertype(S)
    end
    throw(ExternError("the extern type $T is not registered"))
end

# Whether a concrete extern data type has a registration (directly or through a
# supertype), without throwing.
function _extern_registered(::Type{T}) where {T}
    S = T
    while S !== Any
        haskey(_EXTERN_BY_TYPE, S) && return true
        S = supertype(S)
    end
    return false
end

# `to_form` wraps a registered extern's data in a `FormExtern`; an unregistered
# type cannot be represented.
is_form_representable(x::AbstractAirExtern) = _extern_registered(typeof(x))

# ---- errors ------------------------------------------------------------------

"""
    ExternError

Raised when an extern is used incorrectly: an unregistered type or operation, an
API requested for a mutable extern without a reservation, a dead extern touched,
or a resource that cannot be loaded.
"""
struct ExternError <: Exception
    msg::String
end
Base.showerror(io::IO, e::ExternError) = print(io, "ExternError: ", e.msg)

# ---- APIs --------------------------------------------------------------------

"""
    ExternAPI

A handle to an extern's interface. A *type-level* API (from
`get_extern_API(name)`) carries no data and is used with [`construct`](@ref). A
*value-level* API (from `get_extern_API(fe)` for immutable types, or handed to a
[`reserve`](@ref)/[`reserve_read`](@ref) function) carries the data and is used with
`call`.
"""
struct ExternAPI{T<:AbstractAirExtern}
    handle::Union{Nothing,ExternHandle{T}}
    editable::Bool
    # Suppress the generated outer constructor: it would infer `T` from `handle`,
    # which is ambiguous (and leaves `T` unbound) when the handle is `nothing` for
    # a type-level API. Callers always name `T` explicitly.
    ExternAPI{T}(handle::Union{Nothing,ExternHandle{T}}, editable::Bool) where {T} =
        new{T}(handle, editable)
end

# `api.call(op, args)` is the interface the user sees; expose `call` as a bound
# property rather than requiring `call(api, op, args)`.
Base.getproperty(api::ExternAPI, k::Symbol) =
    k === :call ? ((op, args) -> call(api, op, args)) : getfield(api, k)

"""
    get_extern_API(name::Symbol) -> ExternAPI

The type-level API for the extern type registered under `name`, used with
[`construct`](@ref).
"""
get_extern_API(name::Symbol) = get_extern_API(_extern_type(name))
get_extern_API(et::ExternType{T}) where {T} = ExternAPI{T}(nothing, false)

"""
    get_extern_API(fe::FormExtern) -> ExternAPI

The API for an immutable extern, usable from any thread. A mutable extern raises:
it must be [`reserve`](@ref)d (or [`reserve_read`](@ref)) first.
"""
function get_extern_API(fe::FormExtern{T}) where {T}
    h = fe.handle
    h.data isa DeadExtern &&
        throw(ExternError("the extern :$(h.type) is dead and has no API"))
    _extern_type(T).immutable ||
        throw(ExternError("the extern :$(h.type) is mutable; reserve it to get an API"))
    return ExternAPI{T}(h, false)
end
get_extern_API(fe::FormExtern{DeadExtern}) =
    throw(ExternError("a dead extern has no API"))

# The operation name a `call`/`construct` argument carries. It is a keyword, as
# in `Form(Symbol(":read-bytes"))`.
function _opname(f::Form)
    fs = to_form(f)
    fs isa FormScalar{Symbol} ||
        throw(ExternError("an extern operation or constructor name must be a keyword"))
    s = value(fs)
    startswith(string(s), ":") ||
        throw(ExternError("an extern operation or constructor name must be a keyword, not $(repr(s))"))
    return s
end

# The result of an operation must be a form.
_result(x) = (x isa Form && return x; return to_form(x))

"""
    construct(api::ExternAPI, ctor::Form, args::Form; id = nothing) -> FormExtern

Run the constructor named by `ctor` (a keyword form) with `args`, and wrap the
returned data in a [`FormExtern`](@ref). `id`, if given, is the keyword under
which the extern is stored; it must be unique among live externs.
"""
function construct(api::ExternAPI{T}, ctor::Form, args::Form;
                   id::Union{Nothing,Symbol} = nothing,
                   metadata = nothing) where {T}
    api.handle === nothing ||
        throw(ExternError("construct must be called on a type-level API"))
    api.editable && throw(ExternError("a type-level API cannot be editable"))
    et = _extern_type(T)
    key = _opname(ctor)
    fn = get(et.constructors, key, nothing)
    fn === nothing &&
        throw(ExternError("the extern type :$(et.name) has no constructor $key"))
    data = fn(args)
    data isa T ||
        throw(ExternError("the constructor $key for :$(et.name) returned " *
                          "$(typeof(data)), not $T"))
    m = metadata === nothing ? nothing : to_form(metadata)
    h = _extern_handle(T, et.name, id, data, true, nothing;
                       metadata = m, metaloaded = true)
    id === nothing || _register_handle!(h)
    return FormExtern(h)
end

"""
    call(api::ExternAPI, op::Form, args::Form) -> Form

Run the operation named by `op` (a keyword form) on the extern's data with
`args`. Through a read-only API only read-only operations are available; through
an API handed out by [`reserve`](@ref) the read-edit operations are too.
"""
function call(api::ExternAPI{T}, op::Form, args::Form) where {T}
    h = api.handle
    h === nothing &&
        throw(ExternError("a type-level API has no data; use construct"))
    _ensure_loaded(h)
    h.data isa DeadExtern &&
        throw(ExternError("the extern :$(h.type) is dead"))
    et = _extern_type(T)
    key = _opname(op)
    data = h.data::T
    if api.editable
        fn = get(et.read_edit, key, nothing)
        if fn !== nothing
            h.edits += 1
            h.dirty = true
            return _result(fn(data, args))
        end
    end
    fn = get(et.read_only, key, nothing)
    fn !== nothing && return _result(fn(data, args))
    if get(et.read_edit, key, nothing) !== nothing
        throw(ExternError("the operation $key on :$(h.type) edits the extern; " *
                          "it is only available inside reserve"))
    end
    throw(ExternError("the extern type :$(et.name) has no operation $key"))
end

# ---- handle registry and loading ---------------------------------------------

# Live extern handles, keyed by `(type, id)` and held weakly: a handle stays
# alive exactly as long as a form (or caller) references it, so a resource has a
# single lock and version within the process.
const _EXTERN_HANDLES = Dict{Tuple{Symbol,Symbol},WeakRef}()
const _EXTERN_HANDLES_LOCK = ReentrantLock()

# Drop the handles whose objects have been collected, as the form caches do: a
# dead entry is otherwise never removed, so a long-lived process would keep one
# per extern it has ever loaded. Runs on insertion, now and then.
function _sweep_dead_handles!()
    for (k, wr) in collect(_EXTERN_HANDLES)
        wr.value === nothing && delete!(_EXTERN_HANDLES, k)
    end
    return nothing
end
_handles_sweep_due() =
    length(_EXTERN_HANDLES) >= 256 && (length(_EXTERN_HANDLES) & 255) == 0

function _register_handle!(h::ExternHandle)
    h.id === nothing && return h
    lock(_EXTERN_HANDLES_LOCK)
    try
        _handles_sweep_due() && _sweep_dead_handles!()
        key = (h.type, h.id::Symbol)
        wr = get(_EXTERN_HANDLES, key, nothing)
        if wr !== nothing && wr.value !== nothing && wr.value !== h
            throw(ExternError("the extern id $(repr(h.id)) is already in use for :$(h.type)"))
        end
        _EXTERN_HANDLES[key] = WeakRef(h)
        return h
    finally
        unlock(_EXTERN_HANDLES_LOCK)
    end
end

# The handle for `name`/`id`, created unloaded if it is not already live.
function _get_handle(db::Union{Nothing,AbstractDatabase}, name::Symbol, id::Symbol)
    et = _extern_type(name)
    T = _typeparam(et)
    lock(_EXTERN_HANDLES_LOCK)
    try
        wr = get(_EXTERN_HANDLES, (name, id), nothing)
        if wr !== nothing
            h = wr.value
            if h !== nothing
                (h.db === nothing && db !== nothing) && setfield!(h, :db, db)
                return h::ExternHandle
            end
        end
        _handles_sweep_due() && _sweep_dead_handles!()
        # A rehydrated handle names a resource row that already exists.
        h = _extern_handle(T, name, id, nothing, false, db; present = true)
        _EXTERN_HANDLES[(name, id)] = WeakRef(h)
        return h
    finally
        unlock(_EXTERN_HANDLES_LOCK)
    end
end

# Read a handle's data from the database on first use.
function _ensure_loaded(h::ExternHandle)
    h.loaded && return h
    h.db === nothing && h.id !== nothing &&
        throw(ExternError("the extern :$(h.type)/$(h.id) is not attached to a database"))
    db = h.db
    if db === nothing
        h.loaded = true
        return h
    end
    # Serialize loading with `gc!`, so a resource row cannot be swept mid-load.
    lock(db.gclock)
    try
        lock(h.loadlock)
        try
            h.loaded && return h
            _check_health(db)
            h.id === nothing || _check_failed(db, (h.type, h.id::Symbol))
            h.data = _read_resource(db, h.type, h.id::Symbol)
            h.loaded = true
            return h
        finally
            unlock(h.loadlock)
        end
    finally
        unlock(db.gclock)
    end
end

# ---- serialization -----------------------------------------------------------

# Whether a handle's bytes belong in the `resources` table.
function _storable(h::ExternHandle)
    h.id === nothing && return false
    (h.data isa DeadExtern) && return false
    return _extern_type(h.type).serialize !== nothing
end

function _serialize_resource(h::ExternHandle)
    et = _extern_type(h.type)
    et.serialize === nothing &&
        throw(ExternError("the extern type :$(h.type) has no serialization"))
    io = IOBuffer()
    (et.serialize::Function)(h.data, io)
    return take!(io)
end

function _deserialize_resource(name::Symbol, bytes)
    et = _extern_type(name)
    et.deserialize === nothing &&
        throw(ExternError("the extern type :$name has no deserialization"))
    return (et.deserialize::Function)(IOBuffer(bytes))
end

# The handles referenced by the form currently being encoded, so the writer can
# store their bytes before it writes any form that names them. The set lives in
# task-local storage because encoding always runs on one task (the writer actor
# or a caller of `to_JSON`).
const _REF_KEY = :AirDBReferencedExterns
function _refset()
    d = task_local_storage()
    s = get(d, _REF_KEY, nothing)
    (s isa IdDict{Any,Nothing}) && return s
    s = IdDict{Any,Nothing}()
    task_local_storage(_REF_KEY, s)
    return s
end
function _note_referenced!(h::ExternHandle)
    _collecting_refs() && (_refset()[h] = nothing)
    return nothing
end

# ---- reader/writer locks -----------------------------------------------------

function _rw_read(f::Function, l::ReadWriteLock)
    lock(l.mtx)
    try
        while l.writer || l.waiting_writers > 0
            wait(l.cond)
        end
        l.readers += 1
    finally
        unlock(l.mtx)
    end
    try
        return f()
    finally
        lock(l.mtx)
        try
            l.readers -= 1
            l.readers == 0 && notify(l.cond)
        finally
            unlock(l.mtx)
        end
    end
end

function _rw_write(f::Function, l::ReadWriteLock)
    lock(l.mtx)
    try
        l.waiting_writers += 1
        try
            while l.writer || l.readers > 0
                wait(l.cond)
            end
            l.writer = true
        finally
            l.waiting_writers -= 1
        end
    finally
        unlock(l.mtx)
    end
    try
        return f()
    finally
        lock(l.mtx)
        try
            l.writer = false
            notify(l.cond)
        finally
            unlock(l.mtx)
        end
    end
end

# Acquire the locks of `hs` in order, then call `f()`.
function _nested_locks(f::Function, hs::Vector, i::Int, acquire::Function)
    i > length(hs) && return f()
    return acquire(() -> _nested_locks(f, hs, i + 1, acquire), hs[i].lock)
end

# The handles behind a list of externs, deduplicated and sorted by `(type, id)`
# (ties among unnamed handles are broken by object identity, so the order is
# still total).
function _sorted_handles(resources)
    out = ExternHandle[]
    for r in resources
        r isa FormExtern ||
            throw(ExternError("reserve expects externs, but got a $(typeof(r))"))
        h = r.handle
        (h.loaded && h.data isa DeadExtern) &&
            throw(ExternError("the extern :$(h.type) is dead"))
        push!(out, h)
    end
    sort!(out; by = h -> (h.type, h.id === nothing ? Symbol("") : h.id,
                          h.id === nothing ? objectid(h) : 0))
    unique!(out)
    return out
end

# Walk a form and collect its storable extern handles. The PostgreSQL writer
# learns references while encoding the form; this is for `MemoryDatabase`, which
# never encodes.
_collect_externs!(out, ::FormScalar) = out
_collect_externs!(out, ::VolatileForm) = out
_collect_externs!(out, ::Any) = out
function _collect_externs!(out, fe::FormExtern)
    _storable(fe.handle) && (out[fe.handle] = nothing)
    return out
end
function _collect_externs!(out, fc::FormContainer)
    for x in fc.seq
        _collect_externs!(out, x)
    end
    for (_, v) in fc.map
        _collect_externs!(out, v)
    end
    return out
end
# A delay is written as its serialization form, so the externs that form names
# belong to the delay's references.
_collect_externs!(out, df::DelayForm) = _collect_externs!(out, df.form)

# Inside a transaction, reading each version registers an Air read, so the
# transaction retries if a read-edit intervenes.
function _read_versions(hs::Vector)
    for h in hs
        h.version[]
    end
    return nothing
end

"""
    ExternPromise

The promise returned by [`reserve`](@ref). `p[]` waits for the reservation and
yields its result, re-raising any error the function raised.
"""
mutable struct ExternPromise{T}
    inner::Air.Promise{Any}
    origin::Union{Nothing,Transaction}
    ExternPromise{T}() where {T} = new{T}(Air.Promise{Any}(), currtx())
end
Base.isready(p::ExternPromise) = isready(p.inner)
function Base.getindex(p::ExternPromise{T}) where {T}
    t = currtx()
    if !isready(p.inner) && t !== nothing && t === p.origin
        throw(ExternError("reserved extern promise read before the transaction completed; " *
                          "wait for it after the transaction"))
    end
    v = p.inner[]
    v isa CapturedException && throw(v.ex)
    v isa Some || throw(ExternError("the reserved extern function returned no value"))
    return v.value
end
Base.wait(p::ExternPromise) = (p[]; nothing)

# ---- reserve / reserve_read --------------------------------------------------

"""
    reserve_read(f, resources...) -> value

Run `f` with read-only APIs for each resource, taking their read locks in sorted
`(type, id)` order first. Runs on the caller's task and returns `f`'s value.
Inside a transaction the versions are read, so a concurrent read-edit forces the
transaction to retry. This is the ordinary way to call read-only operations.

```julia
reserve_read(r1, r2) do api1, api2
    api1.call(Form(Symbol(":version")), form())
end
```
"""
function reserve_read(f::Function, resources...)
    hs = _sorted_handles(resources)
    return _nested_locks(hs, 1, _rw_read) do
        _read_versions(hs)
        apis = ExternAPI[_readonly_api(h) for h in hs]
        f(apis...)
    end
end

function _readonly_api(h::ExternHandle{T}) where {T}
    h.data isa DeadExtern &&
        throw(ExternError("the extern :$(h.type) is dead"))
    return ExternAPI{T}(h, false)
end

"""
    reserve(f, resources...) -> ExternPromise

Run `f` with editable APIs for each resource on a spawned task, which first takes
their write locks in sorted `(type, id)` order. Returns a promise; wait on it
with `p[]` for `f`'s value.

Inside a transaction the function is not run until the transaction commits (and
is discarded if it retries), and the reservation counts as a read: `f`'s
resources' versions must be unchanged at commit. Reading the promise inside that
same transaction before it completes raises.

```julia
p = reserve(r1) do api
    api.call(Form(Symbol(":bump")), form())
end
p[]          # the result
```
"""
function reserve(f::Function, resources...)
    hs = _sorted_handles(resources)
    p = ExternPromise{Any}()
    if currtx() === nothing
        Threads.@spawn _run_reserve(f, hs, p)
    else
        _read_versions(hs)                    # the reservation counts as a read
        send(_gate()) do val
            Threads.@spawn _run_reserve(f, hs, p)
            return val
        end
    end
    return p
end

function _run_reserve(f::Function, hs::Vector, p::ExternPromise)
    # Backpressure is checked before any extern lock is taken; the staging in
    # `_queue_resource_writes` runs under the locks and suppresses it.
    for h in hs
        if h.db !== nothing
            _await_capacity(h.db)
            break
        end
    end
    try
        result = _nested_locks(hs, 1, _rw_write) do
            try
                apis = ExternAPI[_editable_api(h) for h in hs]
                f(apis...)
            finally
                _publish_versions!(hs)
                _queue_resource_writes(hs)
            end
        end
        put!(p.inner, Some(result))
    catch e
        put!(p.inner, CapturedException(e, catch_backtrace()))
    end
    return nothing
end

function _editable_api(h::ExternHandle{T}) where {T}
    h.data isa DeadExtern &&
        throw(ExternError("the extern :$(h.type) is dead"))
    return ExternAPI{T}(h, true)
end

# Publish each handle's read-edit count into its Air version cell. Called while
# the write locks are held, so no reader can observe an intermediate version.
function _publish_versions!(hs::Vector)
    pending = Tuple{ExternHandle,Int}[]
    for h in hs
        h.edits == 0 && continue
        push!(pending, (h, h.edits))
        h.edits = 0
    end
    isempty(pending) && return nothing
    tx() do
        for (h, n) in pending
            h.version[] = h.version[] + n
        end
    end
    return nothing
end

# Send the bytes of every dirty, storable handle to the writer. The write locks
# are still held, so the snapshot is consistent.
function _queue_resource_writes(hs::Vector)
    # The caller holds the extern write locks; never wait for writer capacity
    # here (see `_run_reserve`, which checks before taking the locks).
    _without_capacity() do
        for h in hs
            h.dirty || continue
            h.dirty = false
            _storable(h) || continue
            h.db === nothing && continue      # never stored: nothing to sync
            bytes = _serialize_resource(h)
            _stage_resource!(h.db::AbstractDatabase, h.type, h.id::Symbol, bytes;
                             metadata = _metavalue(h), handle = h)
        end
    end
    return nothing
end

# A gate actor exists only to turn Air's commit-gated `send` into a spawn; the
# reservation's function itself always runs on a spawned task.
const _GATE_LOCK = ReentrantLock()
const _GATE = Ref{Union{Nothing,Actor{Nothing}}}(nothing)
function _gate()
    lock(_GATE_LOCK)
    try
        g = _GATE[]
        g === nothing || return g
        g = Actor{Nothing}(nothing)
        _GATE[] = g
        return g
    finally
        unlock(_GATE_LOCK)
    end
end

# ---- metadata ----------------------------------------------------------------

"""
    metadata(fe::FormExtern)

The extern's owner/ACL metadata blob, or `nothing` when it has no row (an
unpersisted or dead extern). Read without touching the resource bytes.
"""
function metadata(h::ExternHandle)
    h.metavolatile === nothing || return _metavalue(h)
    db = h.db
    if db === nothing || h.id === nothing
        lock(h.loadlock)
        try
            h.metavolatile === nothing || return _metavalue(h)
            h.metavolatile = Volatile{FormMetadata}(nothing)
            return _metavalue(h)
        finally
            unlock(h.loadlock)
        end
    end
    lock(db.gclock)
    try
        h.metavolatile === nothing || return _metavalue(h)
        lock(h.loadlock)
        try
            h.metavolatile === nothing || return _metavalue(h)
            _check_failed(db, (h.type, h.id::Symbol))
            h.metavolatile =
                Volatile{FormMetadata}(_read_resource_metadata(db, h.type,
                                                                h.id::Symbol))
            return _metavalue(h)
        finally
            unlock(h.loadlock)
        end
    finally
        unlock(db.gclock)
    end
end
metadata(fe::FormExtern) = metadata(fe.handle)

"""
    set_metadata!(fe::FormExtern, m) -> FormExtern

Set the extern's owner/ACL metadata (a [`Form`](@ref), or `nothing`). Like a
metadata edit on any other kind, this must happen inside a transaction and does
not rewrite the resource bytes; an aborted transaction leaves the value as it
was. An extern with no id has no row to carry metadata and raises.
"""
function set_metadata!(fe::FormExtern, m)
    h = fe.handle
    currtx() === nothing &&
        throw(ArgumentError("metadata can only be set inside a transaction"))
    h.id === nothing &&
        throw(ArgumentError("an extern with no id has no persisted metadata to set"))
    h.metavolatile === nothing && metadata(h)
    meta = m === nothing ? nothing : to_form(m)
    _setmetavalue!(h, meta)           # transactional; Air rolls it back on abort
    if h.db !== nothing
        _stage_metadata!(:extern, (h.type, h.id::Symbol), meta, h.db)
    end
    return fe
end

# ---- printing and equality ---------------------------------------------------

Base.:(==)(a::FormExtern, b::FormExtern) = _extern_equal(a.handle, b.handle)
Base.isequal(a::FormExtern, b::FormExtern) = _extern_equal(a.handle, b.handle)
function _extern_equal(a::ExternHandle, b::ExternHandle)
    a === b && return true
    (a.type === b.type && a.id !== nothing && a.id === b.id) && return true
    return false
end
Base.hash(fe::FormExtern, h::UInt) =
    fe.handle.id === nothing ?
        hash(objectid(fe.handle), hash(:FormExtern, h)) :
        hash(fe.handle.id, hash(fe.handle.type, hash(:FormExtern, h)))

Base.show(io::IO, fe::FormExtern) = begin
    print(io, "FormExtern(:", fe.handle.type)
    fe.handle.id === nothing || print(io, " ", fe.handle.id)
    print(io, ": ")
    h = fe.handle
    (h.loaded && h.data !== nothing) ? show(io, h.data) : print(io, "<unloaded>")
    print(io, ")")
end
_showvalue(io::IO, fe::FormExtern) = (fe.handle.loaded && fe.handle.data !== nothing) ?
    show(io, fe.handle.data) : print(io, "FormExtern(:", fe.handle.type, ")")

export AbstractAirExtern, FormExtern, DeadExtern, ExternAPI, ExternError,
    ExternPromise, register_extern, get_extern_API, construct, call,
    reserve, reserve_read
