################################################################################
# volatile.jl
#
# `VolatileForm`: a form that persists itself. It wraps an Air `Volatile{Form}`,
# carries a stable UUID, and belongs to a `Database`. A write to it must happen
# inside an Air transaction; when that transaction commits, the writer actor is
# sent the new form and saves it.
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
    lock(vf.lock)
    try
        vf.loaded && return vf
        _check_health(vf.db)
        form = _read_current(vf.db, vf.id)
        vf.volatile = Volatile{Form}(form)
        vf.loaded = true
        vf.persisted = true
        return vf
    finally
        unlock(vf.lock)
    end
end

# ---- construction ------------------------------------------------------------

"""
    VolatileForm(db::AbstractDatabase, form::Form) -> VolatileForm
    VolatileForm(db::AbstractDatabase, args...; kwargs...) -> VolatileForm

Creates a new volatile form with a fresh UUID and registers it with `db` so it
will be written to the database. The arguments of the second form are the same as
[`Form`](@ref)'s.
"""
function VolatileForm(db::AbstractDatabase, form::Form)
    _check_open(db)
    vf = VolatileForm(uuid4(), Volatile{Form}(form), true, false, ReentrantLock(), db)
    _cache_put!(db, vf)
    _register!(vf, form)
    return vf
end
VolatileForm(db::AbstractDatabase, args...; kwargs...) = VolatileForm(db, form(args...; kwargs...))

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

export VolatileForm, get_form, isloaded
