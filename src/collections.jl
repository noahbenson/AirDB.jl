################################################################################
# collections.jl
#
# The small, flat, copy-on-write sequence and map a `FormContainer` is built from
# (the structs are in types.jl). Each holds either a flat `Vector` — the common
# case — or Air's persistent `PVector`/`PDict` once it grows past `_SMALL`.
#
# Every operation returns a new collection; nothing is mutated in place, so a
# value shared between two forms is never changed under either of them. Equality
# and hashing are by content, so a flat and a promoted collection that hold the
# same entries compare and hash the same.
#
# MIT License
# Copyright (c) 2020-2026 Noah C. Benson

# ---- FormSeq -----------------------------------------------------------------

FormSeq() = FormSeq(FormValue[], Val(:raw))
FormSeq(v::PVector{FormValue}) = FormSeq(v, Val(:raw))
FormSeq(v::Vector{FormValue}) =
    length(v) <= _SMALL ? FormSeq(v, Val(:raw)) : FormSeq(PVector(v), Val(:raw))
FormSeq(v::AbstractVector) = FormSeq(FormValue[x for x in v])

Base.length(s::FormSeq) = length(s.v)
Base.isempty(s::FormSeq) = isempty(s.v)
Base.eachindex(s::FormSeq) = eachindex(s.v)
Base.getindex(s::FormSeq, i::Integer) = s.v[i]
# A range (or a vector of positions) yields the subsequence, as a `FormSeq` — not
# a plain `Vector`, so the container it is assigned to stays a `FormSeq`.
Base.getindex(s::FormSeq, r::AbstractRange{<:Integer}) =
    FormSeq(FormValue[s.v[i] for i in r])
Base.getindex(s::FormSeq, r::AbstractVector{<:Integer}) =
    FormSeq(FormValue[s.v[i] for i in r])
Base.iterate(s::FormSeq, st...) = iterate(s.v, st...)

# Content equality, so a flat `Vector` and a promoted `PVector` agree. `==`
# compares values (so `1 == 1.0`); `isequal` compares with `isequal`, matching
# the element hash's treatment of NaN and signed zero.
_seq_equal(a, b) = length(a) == length(b) && all(a[i] == b[i] for i in eachindex(a))
_seq_isequal(a, b) =
    length(a) == length(b) && all(isequal(a[i], b[i]) for i in eachindex(a))
Base.:(==)(a::FormSeq, b::FormSeq) = _seq_equal(a.v, b.v)
Base.isequal(a::FormSeq, b::FormSeq) = _seq_isequal(a.v, b.v)
function Base.hash(s::FormSeq, h::UInt)
    h = hash(:FormSeq, h)
    for x in s.v
        h = hash(x, h)
    end
    return h
end

function push(s::FormSeq, x::FormValue)
    v = s.v
    if v isa Vector{FormValue}
        length(v) < _SMALL && return FormSeq(push!(copy(v), x))
        return FormSeq(push(PVector(v), x))            # promote
    end
    return FormSeq(push(v, x))
end

function pop(s::FormSeq)
    v = s.v
    v isa Vector{FormValue} && return FormSeq(v[1:(end - 1)])
    return FormSeq(pop(v))
end

function deleteat(s::FormSeq, i::Integer)
    v = s.v
    if v isa Vector{FormValue}
        w = copy(v)
        deleteat!(w, i)
        return FormSeq(w)
    end
    return FormSeq(deleteat(v, i))
end

function setindex(s::FormSeq, x::FormValue, i::Integer)
    v = s.v
    if v isa Vector{FormValue}
        w = copy(v)
        w[i] = x
        return FormSeq(w)
    end
    return FormSeq(setindex(v, x, i))
end

# ---- FormMap -----------------------------------------------------------------

FormMap() = FormMap(Pair{Symbol,FormValue}[], Val(:raw))
FormMap(v::PDict{Symbol,FormValue}) = FormMap(v, Val(:raw))
FormMap(v::Vector{Pair{Symbol,FormValue}}) =
    length(v) <= _SMALL ? FormMap(v, Val(:raw)) : FormMap(PDict{Symbol,FormValue}(v), Val(:raw))

Base.length(m::FormMap) = length(m.v)
Base.isempty(m::FormMap) = isempty(m.v)
Base.iterate(m::FormMap, st...) = iterate(m.v, st...)

function Base.haskey(m::FormMap, k::Symbol)
    v = m.v
    v isa Vector{Pair{Symbol,FormValue}} && return any(p -> first(p) === k, v)
    return haskey(v, k)
end

function Base.getindex(m::FormMap, k::Symbol)
    v = m.v
    if v isa Vector{Pair{Symbol,FormValue}}
        for p in v
            first(p) === k && return last(p)
        end
        throw(KeyError(k))
    end
    return v[k]
end

Base.keys(m::FormMap) =
    m.v isa Vector{Pair{Symbol,FormValue}} ? Symbol[first(p) for p in m.v] : keys(m.v)

function Base.:(==)(a::FormMap, b::FormMap)
    length(a) == length(b) || return false
    for (k, v) in a
        (haskey(b, k) && b[k] == v) || return false
    end
    return true
end
# `isequal` recurses with `isequal`, matching the element hash (NaN equals
# itself; -0.0 does not equal 0.0).
function Base.isequal(a::FormMap, b::FormMap)
    length(a) == length(b) || return false
    for (k, v) in a
        (haskey(b, k) && isequal(b[k], v)) || return false
    end
    return true
end

# Order-independent, so a flat and a promoted map that hold the same entries hash
# the same.
function Base.hash(m::FormMap, h::UInt)
    acc = zero(UInt)
    for (k, v) in m
        acc ⊻= hash(k, hash(v))
    end
    return hash(acc, hash(:FormMap, h))
end

function push(m::FormMap, kv::Pair{Symbol,S}) where {S}
    k = first(kv)
    x = _store(last(kv))
    v = m.v
    if v isa Vector{Pair{Symbol,FormValue}}
        i = findfirst(p -> first(p) === k, v)
        if i !== nothing
            w = copy(v)
            w[i] = k => x
            return FormMap(w)
        end
        length(v) < _SMALL && return FormMap(push!(copy(v), k => x))
        return FormMap(push(PDict{Symbol,FormValue}(v), k => x))    # promote
    end
    return FormMap(push(v, k => x))
end

function delete(m::FormMap, k::Symbol)
    v = m.v
    if v isa Vector{Pair{Symbol,FormValue}}
        i = findfirst(p -> first(p) === k, v)
        i === nothing && return m
        w = copy(v)
        deleteat!(w, i)
        return FormMap(w)
    end
    return FormMap(delete(v, k))
end
