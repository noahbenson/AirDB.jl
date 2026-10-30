################################################################################
# equivalence.jl
#
# Form equivalence and its hash. `==` is Julia's value equality — numeric leaves
# compare as numbers, so `Form(5) == Form(5.0)`. Equivalence is stricter and is
# the relation suitable for using forms as dictionary keys:
#
#   * an immutable leaf is equivalent only to a leaf of the *same type* with an
#     equal value, except that NaN is equivalent to itself (so -0.0 and 0.0 are
#     equivalent, as `==` says);
#   * an immutable container is equivalent when it has the same sequence and the
#     same map keys with equivalent values;
#   * a mutable form (a volatile, actor, promise, stream, or mutable extern) is
#     equivalent only to itself (`===`);
#   * an immutable extern is equivalent only to itself unless its type registered
#     `equal`/`hash` functions;
#   * a delay is equivalent when its type and serialization form are equivalent.
#
# `equivhash` is the hash consistent with that relation: equivalent forms hash
# equally. Floats are hashed with signed zero normalized and NaN as one value,
# and a complex's parts are hashed individually — Julia's own `hash` would
# distinguish -0.0 from 0.0 and would mix a complex's parts in a way that does
# not respect the NaN rule.
#
# MIT License
# Copyright (c) 2020-2026 Noah C. Benson

# ---- the leaf rule -----------------------------------------------------------

_equiv_leaf(a, b) = a == b || _both_nan(a, b)
_both_nan(::Any, ::Any) = false
_both_nan(a::AbstractFloat, b::AbstractFloat) = isnan(a) && isnan(b)
# A complex is equivalent when each part is; whole-value `==` would reject two
# complex numbers that share a NaN part.
_equiv_leaf(a::Complex, b::Complex) =
    _equiv_leaf(real(a), real(b)) && _equiv_leaf(imag(a), imag(b))

# ---- the forms ---------------------------------------------------------------

"""
    isequiv(a::Form, b::Form) -> Bool

Whether two forms are **equivalent**: equal in both value and type, with object
identity for anything mutable.

A `FormScalar` is equivalent to another only when the leaves have the same type
and an equal value (`NaN` is equivalent to itself, and `-0.0` to `0.0`). Thus
`Form(5) == Form(5.0)` but `!isequiv(Form(5), Form(5.0))`, and a `BigInt(5)` is
not equivalent to an `Int64(5)`. A `FormContainer` is equivalent when its
sequences match position by position and its maps have the same keys with
equivalent values.

A `VolatileForm`, `ActorForm`, `PromiseForm`, `StreamForm`, or mutable extern is
equivalent only to the same object. An immutable extern is equivalent only to
itself unless its type registered `equal`/`hash` functions with
[`register_extern`](@ref); a `DelayForm` is equivalent when its type and
serialization form are equivalent.

Use [`equivhash`](@ref) for a hash that agrees with this relation.
"""
function isequiv end

function isequiv(a::FormScalar{T}, b::FormScalar{S}) where {T,S}
    T === S || return false
    return _equiv_leaf(a.value, b.value)
end

# Container values are stored as raw leaves, so normalize through `to_form`.
_equiv_value(a, b) = isequiv(to_form(a), to_form(b))

function isequiv(a::FormContainer, b::FormContainer)
    length(a.seq) == length(b.seq) || return false
    for i in 1:length(a.seq)
        _equiv_value(a.seq[i], b.seq[i]) || return false
    end
    length(a.map) == length(b.map) || return false
    for (k, v) in a.map
        haskey(b.map, k) || return false
        _equiv_value(v, b.map[k]) || return false
    end
    return true
end

# Anything mutable is equivalent only to itself.
isequiv(a::VolatileForm, b::VolatileForm) = a === b
isequiv(a::ActorForm, b::ActorForm) = a === b
isequiv(a::PromiseForm, b::PromiseForm) = a === b
isequiv(a::StreamForm, b::StreamForm) = a === b

# A delay's identity is its type and serialization form; forcing it must not
# change what it is equivalent to.
isequiv(a::DelayForm, b::DelayForm) = a.type === b.type && isequiv(a.form, b.form)

# An extern is identity by default. An immutable type that declared `equal` gets
# value semantics; the function is only consulted for the same extern type.
function isequiv(a::FormExtern{T}, b::FormExtern{S}) where {T,S}
    ah, bh = a.handle, b.handle
    ah === bh && return true
    (T === S && ah.type === bh.type) || return false
    reg = try
        _extern_type(T)
    catch
        return false                    # an unregistered or dead extern
    end
    (reg.immutable && reg.equal !== nothing) || return false
    (_extern_data_mode(ah) && _extern_data_mode(bh)) || return false
    v = (reg.equal::Function)(ah.data, bh.data)
    v isa Bool ||
        throw(ExternError("the extern equality for :$(reg.name) returned " *
                          "$(typeof(v)), not Bool"))
    return v
end

isequiv(::Form, ::Form) = false         # different concrete kinds of form

# ---- the hash ----------------------------------------------------------------

"""
    equivhash(x::Form, h::UInt = zero(UInt)) -> UInt

A hash consistent with [`isequiv`](@ref): equivalent forms hash equally. It is
not `Base.hash` — numeric leaves hash by type and value, so `Form(5)` and
`Form(5.0)` differ; a signed zero hashes as `0.0`; every NaN hashes to one value;
and a mutable form hashes by object identity.

`h` is a seed, so `equivhash` composes like `Base.hash`.
"""
equivhash(x::Form, h::UInt = zero(UInt)) = _equivhash(x, h)

function _equivhash(fs::FormScalar, h::UInt)
    v = value(fs)
    return hash(typeof(v), _equivhash_leaf(v, h))
end

_equivhash_leaf(v, h::UInt) = hash(v, h)
function _equivhash_leaf(v::AbstractFloat, h::UInt)
    isnan(v) && return hash(NaN, h)
    iszero(v) && return hash(0.0, h)    # -0.0 and 0.0 are equivalent
    return hash(v, h)
end
function _equivhash_leaf(v::Complex, h::UInt)
    return _equivhash_leaf(imag(v), _equivhash_leaf(real(v), h))
end

function _equivhash(fc::FormContainer, h::UInt)
    h = hash(:FormContainer, h)
    h = hash(length(fc.seq), h)
    for x in fc.seq
        h = _equivhash(to_form(x), h)
    end
    acc = zero(UInt)
    for (k, v) in fc.map
        acc ⊻= hash(k, _equivhash(to_form(v), zero(UInt)))
    end
    return hash(acc, hash(length(fc.map), h))
end

_equivhash(x::VolatileForm, h::UInt) = hash(objectid(x), hash(:VolatileForm, h))
_equivhash(x::ActorForm, h::UInt) = hash(objectid(x), hash(:ActorForm, h))
_equivhash(x::PromiseForm, h::UInt) = hash(objectid(x), hash(:PromiseForm, h))
_equivhash(x::StreamForm, h::UInt) = hash(objectid(x), hash(:StreamForm, h))

function _equivhash(df::DelayForm, h::UInt)
    return hash(df.type, _equivhash(df.form, hash(:DelayForm, h)))
end

# The hash mode must follow the registration, not the particular pair, so two
# equivalent externs of a value-semantics type always hash the same way.
function _equivhash(fe::FormExtern{T}, h::UInt) where {T}
    hd = fe.handle
    tag = hash(T, hash(:FormExtern, h))
    reg = try
        _extern_type(T)
    catch
        nothing
    end
    if reg !== nothing && reg.immutable && reg.equal !== nothing &&
       _extern_data_mode(hd)
        v = (reg.hashfn::Function)(hd.data, tag)
        v isa UInt ||
            throw(ExternError("the extern hash for :$(reg.name) returned " *
                              "$(typeof(v)), not UInt"))
        return v
    end
    return hash(objectid(hd), tag)
end

# Whether an immutable extern's data can be used for equivalence: it must be
# loadable (which may read the database) and present.
function _extern_data_mode(h::ExternHandle)
    h.data isa DeadExtern && return false
    if !h.loaded
        try
            _ensure_loaded(h)
        catch
            return false
        end
    end
    return h.data !== nothing
end

export isequiv, equivhash
