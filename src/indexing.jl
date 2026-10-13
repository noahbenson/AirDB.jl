################################################################################
# indexing.jl
#
# Rich indexing and updating for forms.
#
# A form is a navigable tree. Indexing walks it: a scalar key descends one level,
# a `VolatileForm` met along the way is transparent (its value is used in its
# place), and a vector key (or `:`) fans out, building a new form with one entry
# per key. A value read out of a container is wrapped into a form (a leaf becomes
# a `FormScalar`), so indexing always yields a form; the value at the final key is
# returned as it is, so a final `VolatileForm` is returned rather than expanded.
# Because indexing extracts data, volatiles are eliminated from any structure it
# builds.
#
# `setindex!` walks the same path and writes the *deepest* `VolatileForm` on it
# (the last volatile among the values along the path, including the final one),
# rebuilding that volatile's value along the keys below it; a path with no
# volatile cannot be mutated and raises.
#
# `setindex` (and `map`, `push`, ...) are purely functional: they build a new
# form and never write a volatile. A volatile that lies on the update path is
# therefore eliminated (replaced by its plain, updated value); volatiles off the
# path are kept as links.
#
# MIT License
# Copyright (c) 2020-2026 Noah C. Benson

# A sentinel for the value at a final key that does not exist yet (a new key, or
# one past the end of a sequence, which `setindex!` will add or append).
const _MISSING = :__airdb_missing__

_islist(k) = k isa AbstractVector || k isa Colon

# A volatile met during a walk is transparent: its form is used in its place.
@inline _deref(x::VolatileForm)::FormNode = x[]
@inline _deref(x::Form) = x

# The keys a fan-out covers: every sequence position then every (sorted) map key.
function _allkeys(f::FormContainer)
    ks = Any[]
    for i in 1:length(f.seq)
        push!(ks, i)
    end
    for k in sort!(collect(keys(f.map)))
        push!(ks, k)
    end
    return ks
end
_keys_for(f::FormContainer, ::Colon) = _allkeys(f)
_keys_for(f::FormContainer, ks::AbstractVector) = collect(ks)

# A lookup that reports whether the key was found instead of raising. It yields
# the raw stored value; callers wrap it with `to_form`.
function _try_index(f::FormContainer, k::Integer)
    (1 <= k <= length(f.seq)) && return (true, f.seq[k])
    return (false, nothing)
end
function _try_index(f::FormContainer, k::Symbol)
    haskey(f.map, k) && return (true, f.map[k])
    return (false, nothing)
end
_try_index(::Any, ::Any) = (false, nothing)

_missing(f, k::Integer) = throw(BoundsError(f, k))
_missing(f, k::Symbol) = throw(KeyError(k))
_missing(f, k) = throw(ArgumentError("a form key must be an Integer or a Symbol, not a $(typeof(k))"))

# One key, as a form, raising if it is missing or the value cannot be indexed.
@inline function _index_one(x::Form, k)::FormNode
    v = _deref(x)
    v isa FormContainer ||
        throw(ArgumentError("cannot index into a $(typeof(v)); only a FormContainer has keys"))
    ok, val = _try_index(v, k)
    ok || _missing(v, k)
    return to_form(val)
end

# Build a form from a list of keys and their values: integer keys become the
# sequence, symbol keys the map.
function _build(keys, vals)
    seq = FormValue[]
    map = Pair{Symbol,FormValue}[]
    for (k, v) in zip(keys, vals)
        if k isa Integer
            push!(seq, _store(v))
        elseif k isa Symbol
            push!(map, k => _store(v))
        else
            throw(ArgumentError("a form key must be an Integer or a Symbol, not a $(typeof(k))"))
        end
    end
    return FormContainer(FormSeq(seq), FormMap(map))
end

# The low-level persistent updates, used to rebuild a container along a path.
# These do not recurse (unlike the public `setindex`), so a rebuild terminates.
_setone(f::FormContainer, v, k::Integer) = FormContainer(setindex(f.seq, _store(v), k), f.map)
_setone(f::FormContainer, v, k::Symbol) = FormContainer(f.seq, push(f.map, k => _store(v)))
_appendone(f::FormContainer, v) = FormContainer(push(f.seq, _store(v)), f.map)

function _setleaf(f::FormContainer, k::Integer, v)
    n = length(f.seq)
    if k == n + 1
        return _appendone(f, v)
    elseif 1 <= k <= n
        return _setone(f, v, k)
    else
        throw(BoundsError(f, k))
    end
end
_setleaf(f::FormContainer, k::Symbol, v) = _setone(f, v, k)
_setleaf(f::FormContainer, k, v) = _missing(f, k)

# ==============================================================================
# reading

"""
    f[idxs...] -> Form

Index into a form along a path of keys. An `Integer` is a sequence position, a
`Symbol` a map key, and a `VolatileForm` met along the way is transparent (its
value is used). The value at the final key is returned as a form — a leaf comes
back as a `FormScalar` (use [`value`](@ref) to get the leaf), and a final
`VolatileForm` is returned rather than expanded.

A vector key (or `:`, meaning every sequence position and map key) fans out: the
result is a new `FormContainer` with one entry per key, built by the outer product
of the vector keys, with volatiles eliminated. Missing keys raise.

# Examples
```julia
f = form(10, meta = form(n = 1))
f[1]              # Form(10)
value(f[1])       # 10
f[:meta, :n]      # Form(1)
```
"""
Base.getindex(x::FormNode, idx, idxs...)::FormNode = _getindex(x, (idx, idxs...))
# `f[]` is the form itself (a `VolatileForm` overrides this to read its value).
Base.getindex(f::FormNode)::FormNode = f

function _getindex(cur::FormNode, path::Tuple)::FormNode
    isempty(path) && return cur
    v = _deref(cur)
    v isa FormContainer ||
        throw(ArgumentError("cannot index into a $(typeof(v)); only a FormContainer has keys"))
    k = first(path)
    rest = Base.tail(path)
    if _islist(k)
        keys = _keys_for(v, k)
        return _build(keys, FormValue[_getindex(_index_one(v, kk), rest) for kk in keys])
    else
        return _getindex(_index_one(v, k), rest)
    end
end

"""
    get(f, idxs..., default) -> Form or default

Like [`getindex`](@ref), but a missing *final* key yields `default` instead of
raising. A missing intermediate key still raises.
"""
function Base.get(x::Form, args...)
    length(args) >= 2 ||
        throw(ArgumentError("get requires at least one key and a default value"))
    return _get(x, args[1:(end - 1)], args[end])
end

function _get(cur, path::Tuple, default)
    isempty(path) && return cur
    v = _deref(cur)
    v isa FormContainer || return default
    k = first(path)
    rest = Base.tail(path)
    if _islist(k)
        keys = _keys_for(v, k)
        vals = FormValue[]
        for kk in keys
            ok, child = _try_index(v, kk)
            push!(vals, _get(ok ? to_form(child) : default, rest, default))
        end
        return _build(keys, vals)
    else
        ok, child = _try_index(v, k)
        if !ok
            isempty(rest) && return default
            _missing(v, k)
        end
        return _get(to_form(child), rest, default)
    end
end

# ==============================================================================
# functional update

"""
    setindex(f, v, idxs...) -> FormContainer

A copy of `f` with the value at the path `idxs...` replaced by `v`. Purely
functional: no `VolatileForm` is written. A volatile on the update path is
eliminated (replaced by its plain value), so the result never contains a volatile
whose content the update would have changed; volatiles off the path are kept as
links.

A vector key (or `:`) fans out and builds a new form over the selection.

An integer index equal to one past the end of a sequence appends.
"""
function setindex(x::Form, v, idx, idxs...)
    return _setindex_func(x, (idx, idxs...), v)
end

function _setindex_func(cur, path::Tuple, v)
    isempty(path) && return _formvalue(v)
    form = _deref(cur)
    form isa FormContainer ||
        throw(ArgumentError("cannot index into a $(typeof(form)); only a FormContainer has keys"))
    k = first(path)
    rest = Base.tail(path)
    if _islist(k)
        keys = _keys_for(form, k)
        vals = FormValue[]
        for kk in keys
            ok, child = _try_index(form, kk)
            ok || _missing(form, kk)
            push!(vals, _setindex_func(to_form(child), rest, v))
        end
        return _build(keys, vals)
    elseif isempty(rest)
        return _setleaf(form, k, v)
    else
        return _setleaf(form, k, _setindex_func(_index_one(form, k), rest, v))
    end
end

# ==============================================================================
# transactional update

# One step down the path for `setindex!`: a volatile is dereferenced to continue
# (but is recorded by the caller as a candidate target). The final key may be new
# — a key being added, or the append position — so a missing final value is the
# `_MISSING` sentinel rather than an error; only intermediate keys must exist.
function _step(cur, k, is_last)
    v = _deref(cur)
    v isa FormContainer ||
        throw(ArgumentError("cannot index into a $(typeof(v)); only a FormContainer has keys"))
    if is_last
        ok, val = _try_index(v, k)
        return ok ? to_form(val) : _MISSING
    end
    return _index_one(v, k)
end

"""
    setindex!(f, v, idxs...) -> v

Walks the path `idxs...` and sets the value of the *deepest* `VolatileForm` on
it — the last volatile among the values along the path, including the final one.
The volatile is rebuilt along the keys below it. If no value on the path is a
volatile, the call raises, because a persistent `Form` cannot be mutated.

Because it writes a volatile, this must run inside an Air transaction
(`@tx`/`tx`); the outer volatiles are read (and registered with the transaction),
and only the target is written.

An integer index equal to one past the end of a sequence appends.

# Examples
```julia
a = VolatileForm(db, n = 0)
@tx a[:n] = 5            # writes the volatile a
@tx a[:deep, :n] = 1     # writes the deepest volatile on the path
```
"""
function Base.setindex!(x::Form, v, idx, idxs...)
    _setindex_bang(x, (idx, idxs...), v)
    return v
end

function _setindex_bang(cur, path::Tuple, v)
    # A list key fans out: each key of the list contributes its own update, and
    # the container is the value the walk has reached so far (possibly a volatile
    # that is itself the target of each branch).
    p = findfirst(_islist, path)
    if p !== nothing
        c = cur
        for k in path[1:(p - 1)]
            c = _index_one(c, k)
        end
        form = _deref(c)
        form isa FormContainer ||
            throw(ArgumentError("cannot index into a $(typeof(form)); only a FormContainer has keys"))
        rest = path[(p + 1):end]
        for kk in _keys_for(form, path[p])
            _setindex_bang(c, (kk, rest...), v)
        end
        return nothing
    end
    vals = Any[cur]
    c = cur
    m = length(path)
    for (i, k) in enumerate(path)
        c = _step(c, k, i == m)
        push!(vals, c)
    end
    j = findlast(y -> y isa VolatileForm, vals)
    j === nothing &&
        throw(ArgumentError("cannot setindex! a persistent Form: no VolatileForm on the path"))
    target = vals[j]::VolatileForm
    Base.setindex!(target, to_form(_setindex_func(target[], path[j:end], v)))
    return nothing
end

# ==============================================================================
# elementwise apply

"""
    map(fn, f) -> Form

A form with the same keys as `f` (both its sequence and its map), every immediate
value replaced by `fn(value)`. `fn` receives a `VolatileForm` value as the
`VolatileForm` object, so it decides whether to keep or drop it. The results are
converted the way any form value is.

If `f` is a `VolatileForm`, the function is applied to its value; if `f` is a
`FormScalar`, it is applied to the leaf.
"""
function Base.map(fn, f::FormContainer)
    seq = FormSeq(FormValue[_store(fn(x)) for x in f.seq])
    map = FormMap(Pair{Symbol,FormValue}[k => _store(fn(v)) for (k, v) in f.map])
    return FormContainer(seq, map)
end
Base.map(fn, fs::FormScalar) = to_form(fn(value(fs)))
Base.map(fn, vf::VolatileForm) = map(fn, vf[])
