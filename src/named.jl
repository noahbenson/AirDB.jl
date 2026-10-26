################################################################################
# named.jl
#
# Named forms. A `Database` keeps the whole name table in memory, held in an Air
# `Volatile`, so a change to it is transactional: it commits with the surrounding
# transaction (or in one of its own), and is retried or discarded with it, just
# like the form data. A name is only an alias for a form id; the table is small
# enough to hold outright, and the database write is scheduled through the writer
# in the same commit.
#
# A name may be given as a `Symbol` or a `String`; both refer to the same form,
# because a name is compared by its string value.
#
# MIT License
# Copyright (c) 2020-2026 Noah C. Benson

_namekey(name) = string(name)

# The default `value`, kept distinct from `nothing` — which is itself a leaf a form
# can hold, and so would otherwise mean `FormScalar(nothing)`.
struct _NoValue end
const _NOVALUE = _NoValue()

# Turn an initial value into the form a new named form should hold: no value gives
# an empty container; anything else is converted with `to_form`.
_as_form(::_NoValue) = form()
_as_form(x) = to_form(x)

# The current name table. Inside a transaction this registers a read, so the
# transaction is retried if the table changes; outside, it is the committed value.
_name_table(db::AbstractDatabase) = db.names[]

"""
    named_form(db::Database, name; create = false, value = nothing)

Look up the form registered under `name`, which may be a `Symbol` or a `String`.
`create` controls what happens when the name is not found:

* `create = false` (the default) — raise if no form is registered under `name`;
* `create = true` — create a new named form and return it, raising if the name is
  already in use;
* `create = nothing` — never raise; return `nothing` when the name is not found.

`value` is the new form's initial value, used only when a form is created. It is
converted with [`to_form`](@ref), so a [`Form`](@ref) is used as-is, a number
becomes a [`FormScalar`](@ref), a collection becomes a container, and leaving it
out gives an empty container; or it may be an existing [`VolatileForm`](@ref), in
which case no new form is made and the name is pointed at the given one.

Creating is transactional: it joins the caller's transaction if there is one, and
otherwise runs in a transaction of its own.

# Examples
```julia
root = named_form(db, "root"; create = true, value = form(version = 1))
named_form(db, "root")                 # the same form
named_form(db, :root)                  # Symbol and String agree
named_form(db, "root"; create = true)  # ERROR: already in use
named_form(db, "other"; create = nothing)   # nothing
```
"""
function named_form(db::AbstractDatabase, name; create::Union{Nothing,Bool} = false,
                    value = _NOVALUE, metadata = nothing, history::Bool = true)
    _check_open(db)
    key = _namekey(name)
    existing = get(_name_table(db), key, nothing)
    if existing !== nothing
        (create === true) && throw(ArgumentError("the name \"$key\" is already in use"))
        return existing
    end
    (create === false) && throw(ArgumentError("no form is named \"$key\""))
    (create === nothing) && return nothing
    return _create_name!(db, key, value, metadata, history)
end

# Register a brand-new name. Runs in a transaction — the caller's, or a fresh one
# — so the check-and-set is atomic and the change is retried or discarded with the
# transaction. `tx` folds into an enclosing transaction, so this is correct
# whether or not the caller is already inside one.
function _create_name!(db::AbstractDatabase, key::AbstractString, value,
                       metadata = nothing, history::Bool = true)
    return tx() do
        table = _name_table(db)
        haskey(table, key) && throw(ArgumentError("the name \"$key\" is already in use"))
        vf = value isa VolatileForm ? value :
             VolatileForm(db, _as_form(value); metadata = metadata, history = history)
        db.names[] = push(table, key => vf)
        _register_name!(db, key, vf.id)
        vf
    end
end

"""
    name_form!(db::Database, name, vf::VolatileForm) -> VolatileForm

Registers `vf` under `name`, overwriting any form already registered under it.
Transactional, like [`named_form`](@ref).
"""
function name_form!(db::AbstractDatabase, name, vf::VolatileForm)
    _check_open(db)
    key = _namekey(name)
    return tx() do
        db.names[] = push(_name_table(db), key => vf)
        _register_name!(db, key, vf.id)
        vf
    end
end

"""
    named_forms(db::Database) -> PDict{String,VolatileForm}

The whole name table as it currently stands. The `PDict` is immutable, so it is
safe to share and to keep; each value is a (possibly not-yet-loaded)
[`VolatileForm`](@ref). Inside a transaction this registers a read of the table.
"""
function named_forms(db::AbstractDatabase)
    _check_open(db)
    return _name_table(db)
end

export named_form, name_form!, named_forms
