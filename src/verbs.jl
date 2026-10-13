################################################################################
# verbs.jl
#
# The verbs a form is operated on with: read-modify-write, merging, selecting,
# filtering, walking, and converting out. These build on the indexing in
# indexing.jl; `setindex` and `filter` and friends are functional (they never
# write a volatile), while the `!` forms write the deepest volatile on a path,
# exactly as `setindex!` does.
#
# MIT License
# Copyright (c) 2020-2026 Noah C. Benson

# ---- read-modify-write -------------------------------------------------------

"""
    update(f, fn, path...) -> FormContainer

`setindex(f, fn(f[path...]), path...)`: read the value at `path...`, apply `fn`,
and write the result back. Purely functional.
"""
function update(f::FormNode, fn, path...)
    return setindex(f, fn(f[path...]), path...)
end

"""
    update!(f, fn, path...) -> FormContainer

Like [`update`](@ref), but transactional: it writes the *deepest* `VolatileForm`
on the path, exactly as [`setindex!`](@ref) does, and raises if there is none.
Must run inside a transaction.
"""
function update!(f::FormNode, fn, path...)
    return setindex!(f, fn(f[path...]), path...)
end

# ---- merging -----------------------------------------------------------------

"""
    merge(f, g, ...) -> FormContainer

Combines forms: the sequences are concatenated and the maps are merged, a later
form winning on a shared key.
"""
function Base.merge(a::FormContainer, b::FormContainer)
    seq = a.seq
    for x in b.seq
        seq = push(seq, x)
    end
    map = a.map
    for (k, v) in b.map
        map = push(map, k => v)
    end
    return FormContainer(seq, map)
end
Base.merge(a::FormContainer, b::FormContainer, c::FormContainer, rest::FormContainer...) =
    reduce(merge, rest; init = merge(a, b))

"""
    merge_with(fn, f, g) -> FormContainer

Like `merge`, but a key present in both forms is combined with
`fn(f[key], g[key])` (each value passed as a form).
"""
function merge_with(fn, a::FormContainer, b::FormContainer)
    seq = a.seq
    for x in b.seq
        seq = push(seq, x)
    end
    map = a.map
    for (k, v) in b.map
        map = haskey(map, k) ? push(map, k => _store(fn(to_form(map[k]), to_form(v)))) :
              push(map, k => v)
    end
    return FormContainer(seq, map)
end

# ---- selecting and querying --------------------------------------------------

"""
    haskey(f, path...) -> Bool

Whether the whole path resolves. A missing intermediate or final key gives
`false` (rather than raising), and a `VolatileForm` on the path is transparent.
"""
function Base.haskey(f::FormNode, k1, k2, ks...)
    cur = f
    for k in (k1, k2, ks...)
        v = _deref(cur)
        v isa FormContainer || return false
        ok, raw = _try_index(v, k)
        ok || return false
        cur = to_form(raw)
    end
    return true
end

"""
    select_keys(f, ks) -> FormContainer

A form with only the given keys, in the order given; keys that are not present
are skipped.
"""
function select_keys(f::FormContainer, ks)
    return f[[k for k in ks if haskey(f, k)]]
end

# ---- mapping and filtering ---------------------------------------------------

"""
    filter(pred, f) -> FormNode

The form with only the entries whose value satisfies `pred` (each value passed as
a form). A scalar form is kept or dropped as a whole.
"""
function Base.filter(pred, f::FormContainer)
    seq = FormSeq(FormValue[x for x in f.seq if pred(to_form(x))])
    map = FormMap(Pair{Symbol,FormValue}[k => v for (k, v) in f.map if pred(to_form(v))])
    return FormContainer(seq, map)
end
Base.filter(pred, fs::FormScalar) = pred(fs) ? fs : form()

"""
    map_values(fn, f) -> FormContainer

Like `map`, but `fn` receives each value as a form.
"""
map_values(fn, f::FormContainer) = map(v -> fn(to_form(v)), f)
map_values(fn, fs::FormScalar) = to_form(fn(fs))

"""
    map_keys(fn, f) -> FormContainer

A form with every map key replaced by `fn(key)`; the sequence is unchanged.
"""
function map_keys(fn, f::FormContainer)
    map = FormMap(Pair{Symbol,FormValue}[_formkey(fn(k)) => v for (k, v) in f.map])
    return FormContainer(f.seq, map)
end
map_keys(fn, fs::FormScalar) = fs

# ---- walking -----------------------------------------------------------------

"""
    deep_map(fn, f) -> FormNode

`fn` applied to every node of the tree, bottom-up (a post-order walk): each child
is transformed first, then `fn` is applied to the rebuilt parent. A
`VolatileForm` is passed to `fn` as the object.
"""
function deep_map(fn, f::FormContainer)
    seq = FormSeq(FormValue[_store(deep_map(fn, to_form(x))) for x in f.seq])
    map = FormMap(Pair{Symbol,FormValue}[k => _store(deep_map(fn, to_form(v))) for (k, v) in f.map])
    return _store(fn(FormContainer(seq, map)))
end
deep_map(fn, fs::FormScalar) = _store(fn(fs))
deep_map(fn, vf::VolatileForm) = _store(fn(vf))

# ---- converting out ----------------------------------------------------------

# A form as ordinary Julia data: a scalar form as its leaf, a seq-only container
# as a `Vector`, a map-only container as a `Dict`, and one with both as a
# `NamedTuple` of the two.
_to_native(fs::FormScalar) = value(fs)
_to_native(vf::VolatileForm) = vf
_to_native(x) = x                          # a raw leaf, as stored in a container
function _to_native(fc::FormContainer)
    if isempty(fc.map)
        return [_to_native(x) for x in fc.seq]
    elseif isempty(fc.seq)
        return Dict(k => _to_native(v) for (k, v) in fc.map)
    else
        return (seq = [_to_native(x) for x in fc.seq],
                map = Dict(k => _to_native(v) for (k, v) in fc.map))
    end
end

"""
    to_vector(f) -> Vector

The sequence of `f` as a `Vector` of ordinary Julia values.
"""
to_vector(f::FormContainer) = [_to_native(x) for x in f.seq]
to_vector(fs::FormScalar) = [value(fs)]

"""
    to_dict(f) -> Dict{Symbol,Any}

The map of `f` as a `Dict` of ordinary Julia values.
"""
to_dict(f::FormContainer) = Dict{Symbol,Any}(k => _to_native(v) for (k, v) in f.map)
to_dict(fs::FormScalar) = Dict{Symbol,Any}()

export update, update!, merge_with, select_keys, map_values, map_keys,
    deep_map, to_vector, to_dict
