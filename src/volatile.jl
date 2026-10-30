################################################################################
# volatile.jl
#
# `VolatileForm`: a form that persists itself. It wraps an Air `Volatile{Form}`,
# carries a stable UUID, and belongs to a `Database`. A write to it must happen
# inside an Air transaction; when that transaction commits, the new form is sent
# to the write pipeline and saved.
#
# A `VolatileForm` is loaded lazily: constructing one from the database records
# only its id, and the form body is read the first time the value is requested.
#
# MIT License
# Copyright (c) 2020-2026 Noah C. Benson

# The `VolatileForm` type itself lives in types.jl, with the rest of the form
# hierarchy; this file holds its behaviour.

function Base.show(io::IO, vf::VolatileForm)
    print(io, "VolatileForm(@", vf.id)
    if vf.loaded
        print(io, ": ")
        show(io, (vf.volatile::Volatile{Form})[])
    end
    return print(io, ")")
end

"""
    isloaded(vf::VolatileForm) -> Bool

Whether `vf`'s form body has been read into memory. An unloaded form still knows
its id and will load on first access.
"""
isloaded(vf::VolatileForm) = vf.loaded

"""
    load!(vf::VolatileForm) -> VolatileForm

Reads `vf`'s form body from the database if it is not already loaded, and yields
`vf`. Loading only fetches `vf` itself; the forms it links to stay unloaded until
they are touched in turn.
"""
function load!(vf::VolatileForm)
    vf.loaded && return vf
    # Serialize loading with `gc!`, so the row cannot be swept mid-load.
    lock(vf.db.gclock)
    try
        lock(vf.lock)
        try
            vf.loaded && return vf
            _check_health(vf.db)
            _check_failed(vf.db, vf.id)
            form, metadata, history = _read_current(vf.db, vf.id)
            vf.volatile = Volatile{Form}(form)
            # A metadata edit commits to the volatile before the row update
            # lands; never replace an already-known in-memory value with the
            # (possibly stale) row.
            vf.metavolatile === nothing &&
                (vf.metavolatile = Volatile{FormMetadata}(metadata))
            vf.history = history
            vf.loaded = true
            vf.persisted = true
            return vf
        finally
            unlock(vf.lock)
        end
    finally
        unlock(vf.db.gclock)
    end
end

# ---- construction ------------------------------------------------------------

"""
    VolatileForm(db::AbstractDatabase, form::Form; metadata = nothing,
                 history = true) -> VolatileForm
    VolatileForm(db::AbstractDatabase, args...; metadata = nothing,
                 history = true, kwargs...) -> VolatileForm

Creates a new volatile form with a fresh UUID and registers it with `db` so it
will be written to the database. The arguments of the second form are the same as
[`Form`](@ref)'s.

`metadata` is an optional [form](@ref Form) stored alongside the form in its
`metadata` JSONB column; it may be changed later with [`set_metadata!`](@ref).
`history` is fixed for the life of the form: `true` appends a row to
`form_history` on every update, while `false` keeps only the current row and
overwrites it.
"""
function VolatileForm(db::AbstractDatabase, form::Form;
                      metadata = nothing, history::Bool = true)
    _check_open(db)
    m = metadata === nothing ? nothing : to_form(metadata)
    vf = VolatileForm(uuid4(), Volatile{Form}(form), true, false, ReentrantLock(), db,
                      Volatile{FormMetadata}(m), history)
    _cache_put!(db, vf)
    _register!(vf, form)
    return vf
end
function VolatileForm(db::AbstractDatabase, args...;
                      metadata = nothing, history::Bool = true, kwargs...)
    return VolatileForm(db, form(args...; kwargs...); metadata = metadata, history = history)
end

"""
    metadata(vf::VolatileForm) -> Union{Form,Nothing}

The form's optional metadata. Like the body, it lives in an Air `Volatile`, so
an edit made by [`set_metadata!`](@ref) is visible to the editing transaction and
to the next reader as soon as the transaction commits.
"""
function metadata(vf::VolatileForm)
    vf.metavolatile === nothing || return _metavalue(vf)
    # Read only the metadata columns: a permission check must not fetch or
    # decode the payload.
    lock(vf.db.gclock)
    try
        vf.metavolatile === nothing || return _metavalue(vf)
        lock(vf.lock)
        try
            vf.loaded && return _metavalue(vf)
            _check_failed(vf.db, vf.id)
            meta, hist = _read_form_metadata(vf.db, vf.id)
            vf.history = hist
            vf.metavolatile = Volatile{FormMetadata}(meta)
            return _metavalue(vf)
        finally
            unlock(vf.lock)
        end
    finally
        unlock(vf.db.gclock)
    end
end

"""
    history(vf::VolatileForm) -> Bool

Whether `vf` records its history or keeps only its current row. Fixed at
construction.
"""
function history(vf::VolatileForm)
    (vf.loaded || vf.metavolatile !== nothing) || metadata(vf)  # the same query carries history
    return vf.history
end

"""
    set_metadata!(vf::VolatileForm, m) -> VolatileForm

Sets the form's metadata (a [`Form`](@ref), or `nothing` to clear it). Like any
write, this must happen inside a transaction. The edit is transactional: the same
transaction reads it back through [`metadata`](@ref), the next reader sees it as
soon as the transaction commits, another transaction's edit is validated at
commit, and an aborted transaction leaves the form — in memory and in the
database — untouched. It is a metadata-only edit: it neither rewrites the
payload nor adds a version or history row.
"""
function set_metadata!(vf::VolatileForm, m)
    currtx() === nothing &&
        throw(ArgumentError("metadata can only be set inside a transaction"))
    # Read the current metadata (without fetching the payload) so the edit is a
    # write of a volatile that already exists, and so `history` is known.
    vf.metavolatile === nothing && metadata(vf)
    meta = m === nothing ? nothing : to_form(m)
    _setmetavalue!(vf, meta)          # transactional; Air rolls it back on abort
    _stage_metadata!(:form, vf.id, meta, vf.db)
    return vf
end

# ---- reading -----------------------------------------------------------------

"""
    vf[]

The volatile form's current [`Form`](@ref). Reads the body from the database on
first use. Inside a transaction this registers an Air read, so the transaction
sees a consistent value.
"""
Base.getindex(vf::VolatileForm) = (load!(vf); (vf.volatile::Volatile{Form})[])

# ---- writing -----------------------------------------------------------------

# The write itself goes through Air's `Volatile`, which stages it in the current
# transaction and refuses outside one; `_register!` arranges for the committed
# value to reach the database.
function _setform!(vf::VolatileForm, form::Form)
    vf.loaded || load!(vf)
    Base.setindex!(vf.volatile::Volatile{Form}, form)
    _register!(vf, form)
    return form
end

function Base.setindex!(vf::VolatileForm, x)
    form = _formvalue(x)
    (form isa Form) ||
        throw(ArgumentError("a VolatileForm holds a Form, but got a $(typeof(form)); " *
                            "a volatile form cannot be a form's own value, only one of its values"))
    return _setform!(vf, form)
end

# Setting a whole volatile (`vf[] = x`) is here; setting a value *inside* one
# (`vf[:a] = x`, `vf[:a, 1] = x`) goes through the path-aware `setindex!` in
# indexing.jl, which routes to this method for the target volatile.

# The functional verbs operate on a volatile's value; they never write it.
push(vf::VolatileForm, v) = push(vf[], v)
pop(vf::VolatileForm) = pop(vf[])
delete(vf::VolatileForm, k) = delete(vf[], k)

# ---- JSON --------------------------------------------------------------------

# A volatile form is written as the JSON string "@<uuid>"; it is never expanded,
# so a form that links to itself still encodes.
_jsonvalue(io::IO, vf::VolatileForm) = _jsonstring(io, string(vf.id), '@')

"""
    to_JSON(vf::VolatileForm) -> String

The volatile form's link text, `"@<uuid>"` (without the surrounding JSON quotes).
"""
to_JSON(vf::VolatileForm) = string('@', vf.id)

export VolatileForm, get_form, isloaded, metadata, history, set_metadata!
