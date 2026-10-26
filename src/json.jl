################################################################################
# json.jl
#
# The JSON codec for `Form`. A container is written as the two-element list
# `[seq, map]`, with the symbol keys of the map as JSON strings, and a scalar form
# as its bare leaf; that is what makes the format self-describing. Three encodings
# are worth stating because they are not forced by JSON itself:
#
#  * A `String` and a `Symbol` are both JSON strings, so the first character
#    inside the quotes says which: `'` for a string and `:` for a symbol.
#  * A `Float64` is written as a plain number but always with a decimal point or
#    an exponent, since a bare integer would read back as an `Int64`.
#  * A complex number has no JSON equivalent, so it is written as the object
#    `{"re": …, "im": …}` — always, even when the imaginary part is zero.
#
# A `VolatileForm` has no JSON body of its own: it is written as the string
# `"@<uuid>"` and read back through a resolver.
#
# The reader works on the UTF-8 *bytes* rather than on `Char`s, since every
# character JSON gives meaning to is ASCII — decoding a `Char` per byte was the
# bulk of the cost of loading a form — and a string with no escapes is taken as a
# byte slice rather than rebuilt character by character.
#
# MIT License
# Copyright (c) 2020-2026 Noah C. Benson

const _JSON_ESCAPE = Dict{UInt8,String}(
    UInt8('"') => "\\\"", UInt8('\\') => "\\\\", UInt8('\b') => "\\b",
    UInt8('\f') => "\\f", UInt8('\n') => "\\n", UInt8('\r') => "\\r",
    UInt8('\t') => "\\t",
)

# `marker` is the first character inside the quotes, and is what says whether the
# value is a string or a symbol: JSON has only one string type, and a form holds
# both.
function _jsonstring(io::IO, s::AbstractString, marker::Char)
    print(io, '"', marker)
    for c in s
        u = UInt32(c)
        if u < 0x20
            haskey(_JSON_ESCAPE, UInt8(u)) ? print(io, _JSON_ESCAPE[UInt8(u)]) :
                print(io, "\\u", string(u, base = 16, pad = 4))
        elseif c == '"' || c == '\\'
            print(io, '\\', c)
        else
            print(io, c)
        end
    end
    return print(io, '"')
end

_jsonvalue(io::IO, x::Nothing) = print(io, "null")
_jsonvalue(io::IO, x::Bool) = print(io, x ? "true" : "false")
_jsonvalue(io::IO, x::Int64) = print(io, x)
_jsonvalue(io::IO, x::AbstractString) = _jsonstring(io, x, '\'')
_jsonvalue(io::IO, x::Symbol) = _jsonstring(io, string(x), ':')
# `print`, not `show`: `show(1.5)` writes `1.5` but `show(1.5f0)` would write
# `1.5f0`, which is not JSON. A float is always written with a point or an
# exponent, so it never reads back as an integer.
_jsonvalue(io::IO, x::Float64) = print(io, x)
# Always the object, even when the imaginary part is zero: `ComplexF64(1, 0)` and
# `Float64(1)` are different values, and a plain number would read back as the
# latter.
function _jsonvalue(io::IO, x::ComplexF64)
    print(io, "{\"re\": ", real(x), ", \"im\": ", imag(x), "}")
    return nothing
end

function _jsonvalue(io::IO, fc::FormContainer)
    # Two brackets: the form's own, then the seq array's.
    print(io, "[[")
    sep = ""
    for x in fc.seq
        print(io, sep)
        sep = ", "
        _jsonvalue(io, x)
    end
    print(io, "], {")
    sep = ""
    for k in sort!(collect(keys(fc.map)))
        print(io, sep)
        sep = ", "
        _jsonvalue(io, k)
        print(io, ": ")
        _jsonvalue(io, fc.map[k])
    end
    return print(io, "}]")
end

# A scalar form is just its leaf.
_jsonvalue(io::IO, fs::FormScalar) = _jsonvalue(io, value(fs))

# An extern is an object with plain keys, like the `{"re","im"}` a complex number
# uses, so it never collides with a form map (whose keys carry the `:` marker):
# `{"extern": "'socket", "id": ":my-socket"}` for a stored extern, and
# `{"extern": "'socket"}` for a dead one. A stored extern's bytes live in the
# `resources` table; the form only names them.
function _jsonvalue(io::IO, fe::FormExtern)
    h = fe.handle
    print(io, "{\"extern\": ")
    _jsonstring(io, string(h.type), '\'')
    if _storable(h)
        _note_referenced!(h)
        print(io, ", \"id\": ")
        _jsonstring(io, string(h.id), ':')
    end
    return print(io, "}")
end

"""
    to_JSON(f::Form) -> String

The form as a JSON string. A container is written as the two-element list
`[seq, map]`, so the format is self-describing: `from_JSON` reads a list as a
container (or an extern — see below). A scalar form is written as its bare leaf.

A `String` and a `Symbol` are both written as JSON strings, with the first
character inside the quotes saying which: `'` for a string and `:` for a symbol.
A `Float64` is a plain number, always with a decimal point or an exponent so that
it reads back as a float rather than as an integer. A complex number has no JSON
equivalent and is written as `{"re": …, "im": …}`, always, even when its
imaginary part is zero. A [`VolatileForm`](@ref) is written as the string
`"@<uuid>"`; it is never expanded, so cyclic links are safe to write. A
[`FormExtern`](@ref) is written as the object `{"extern": "<type>", "id":
"<id>"}` — or `{"extern": "<type>"}` when it is dead — and its bytes live in the
`resources` table.

"""
function to_JSON(f::Form)
    io = IOBuffer()
    _jsonvalue(io, f)
    return String(take!(io))
end

# ==============================================================================
# parsing

const _BYTE_QUOTE = UInt8('"')
const _BYTE_BACKSLASH = UInt8('\\')
const _BYTE_COMMA = UInt8(',')
const _BYTE_COLON = UInt8(':')
const _BYTE_LBRACKET = UInt8('[')
const _BYTE_RBRACKET = UInt8(']')
const _BYTE_LBRACE = UInt8('{')
const _BYTE_RBRACE = UInt8('}')

_isws(c::UInt8) = c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d

# A byte-oriented reader over the UTF-8 bytes of the input. `resolve` turns a
# `"@<uuid>"` link into a value (normally a `VolatileForm` from the owning
# `Database`); it is `nothing` when the caller has no database and links are
# therefore an error.
mutable struct _JSONReader
    b::Base.CodeUnits{UInt8,String}
    i::Int
    resolve::Union{Nothing,Function}
    db::Union{Nothing,AbstractDatabase}
end
_JSONReader(s::AbstractString) = _JSONReader(codeunits(String(s)), 1, nothing, nothing)
_JSONReader(s::AbstractString, resolve::Union{Nothing,Function}) =
    _JSONReader(codeunits(String(s)), 1, resolve, nothing)
_JSONReader(s::AbstractString, resolve::Union{Nothing,Function},
            db::Union{Nothing,AbstractDatabase}) =
    _JSONReader(codeunits(String(s)), 1, resolve, db)

_jsonfail(r::_JSONReader, msg) =
    throw(ArgumentError("invalid JSON at byte $(r.i): $msg"))
_atend(r::_JSONReader) = r.i > length(r.b)

@inline function _skipws!(r::_JSONReader)
    b = r.b
    i = r.i
    n = length(b)
    while i <= n && _isws(b[i])
        i += 1
    end
    r.i = i
    return nothing
end

@inline function _expect!(r::_JSONReader, c::UInt8)
    _skipws!(r)
    (_atend(r) || r.b[r.i] != c) && _jsonfail(r, "expected '$(Char(c))'")
    r.i += 1
    return nothing
end

function _literal!(r::_JSONReader, word::String, value)
    _skipws!(r)
    wb = codeunits(word)
    (r.i + length(wb) - 1 <= length(r.b)) || _jsonfail(r, "expected $word")
    for k in 1:length(wb)
        r.b[r.i + k - 1] == wb[k] || _jsonfail(r, "expected $word")
    end
    r.i += length(wb)
    return value
end

# Read a `\uXXXX` escape (four hex digits) at the current position.
function _hex4!(r::_JSONReader)
    (r.i + 3 <= length(r.b)) || _jsonfail(r, "truncated \\u escape")
    v = UInt32(0)
    for _ in 1:4
        c = r.b[r.i]
        d = UInt32('0') <= UInt32(c) <= UInt32('9') ? UInt32(c) - UInt32('0') :
            UInt32('a') <= UInt32(c) <= UInt32('f') ? UInt32(c) - UInt32('a') + 0x0a :
            UInt32('A') <= UInt32(c) <= UInt32('F') ? UInt32(c) - UInt32('A') + 0x0a :
            _jsonfail(r, "bad \\u escape")
        v = (v << 4) | d
        r.i += 1
    end
    return v
end

# Read a JSON string's content (the quotes are consumed). The fast path takes the
# byte slice verbatim when there are no escapes; the slow path rebuilds the
# string, decoding the escapes.
function _parsestring!(r::_JSONReader)
    _expect!(r, _BYTE_QUOTE)
    start = r.i
    b = r.b
    n = length(b)
    i = r.i
    while i <= n
        c = b[i]
        if c == _BYTE_QUOTE
            r.i = i + 1
            return String(b[start:(i - 1)])
        elseif c == _BYTE_BACKSLASH
            break                      # an escape: fall back to the slow path
        else
            i += 1
        end
    end
    r.i = start
    return _parsestring_slow!(r)
end

function _parsestring_slow!(r::_JSONReader)
    io = IOBuffer()
    b = r.b
    n = length(b)
    while true
        (r.i > n) && _jsonfail(r, "unterminated string")
        c = b[r.i]
        if c == _BYTE_QUOTE
            r.i += 1
            return String(take!(io))
        elseif c != _BYTE_BACKSLASH
            (c < 0x20) && _jsonfail(r, "unescaped control character")
            write(io, c)
            r.i += 1
        else
            r.i += 1
            (r.i > n) && _jsonfail(r, "unterminated escape")
            e = b[r.i]
            r.i += 1
            if e == UInt8('u')
                u = _hex4!(r)
                # A surrogate pair is one character, encoded as two escapes.
                if 0xd800 <= u <= 0xdbff
                    (r.i + 1 <= n && b[r.i] == _BYTE_BACKSLASH && b[r.i + 1] == UInt8('u')) ||
                        _jsonfail(r, "unpaired surrogate")
                    r.i += 2
                    v = _hex4!(r)
                    (0xdc00 <= v <= 0xdfff) || _jsonfail(r, "unpaired surrogate")
                    u = 0x10000 + ((u - 0xd800) << 10) + (v - 0xdc00)
                end
                print(io, Char(u))
            elseif e == UInt8('n')
                write(io, UInt8('\n'))
            elseif e == UInt8('t')
                write(io, UInt8('\t'))
            elseif e == UInt8('r')
                write(io, UInt8('\r'))
            elseif e == UInt8('b')
                write(io, UInt8('\b'))
            elseif e == UInt8('f')
                write(io, UInt8('\f'))
            elseif e == _BYTE_QUOTE || e == _BYTE_BACKSLASH || e == UInt8('/')
                write(io, e)
            else
                _jsonfail(r, "unknown escape \\$(Char(e))")
            end
        end
    end
end

# An integer literal reads back as an `Int64`; anything with a point or an
# exponent reads back as the `Float64` the writer would have produced for one.
# That is what makes the encoding round-trip.
function _parsenumber!(r::_JSONReader)
    _skipws!(r)
    b = r.b
    n = length(b)
    start = r.i
    i = r.i
    while i <= n && (UInt8('0') <= b[i] <= UInt8('9') ||
                     b[i] == UInt8('-') || b[i] == UInt8('+') ||
                     b[i] == UInt8('.') || b[i] == UInt8('e') || b[i] == UInt8('E'))
        i += 1
    end
    (i == start) && _jsonfail(r, "expected a number")
    text = String(b[start:(i - 1)])
    r.i = i
    if !occursin('.', text) && !occursin('e', text) && !occursin('E', text)
        v = tryparse(Int64, text)
        (v === nothing) && _jsonfail(r, "integer out of range: $text")
        return v
    end
    v = tryparse(Float64, text)
    (v === nothing) && _jsonfail(r, "bad number: $text")
    return v
end

# A JSON string carries its own kind in its first character: `'` for a string,
# `:` for a symbol, and `@` for a volatile-form link. Anything else is a mistake
# rather than a value, since the writer never produces one.
function _parseleafstring!(r::_JSONReader)
    text = _parsestring!(r)
    isempty(text) &&
        _jsonfail(r, "a JSON string must begin with ' (a string), : (a symbol) or @ (a form link)")
    marker = text[1]
    rest = SubString(text, nextind(text, 1))
    (marker == '\'') && return String(rest)
    (marker == ':') && return Symbol(rest)
    if marker == '@'
        (r.resolve === nothing) &&
            _jsonfail(r, "a form link (@$rest) needs a Database to be resolved")
        id = try
            UUID(rest)
        catch
            _jsonfail(r, "a form link must carry a UUID, not \"$rest\"")
        end
        return r.resolve(id)
    end
    _jsonfail(r, "a JSON string must begin with ' (a string), : (a symbol) or @ (a form link), " *
                 "not '$marker'")
end

# A map key is always a symbol, so it is written with the `:` marker. The marker
# is required rather than assumed, since a key without one is a mistake the writer
# never makes — but it is checked here rather than while reading the object, so
# that the `{"re", "im"}` object a complex number is written as can carry plain
# keys without them meaning symbols.
function _parsekey(r::_JSONReader, k::AbstractString)
    isempty(k) && _jsonfail(r, "a map key cannot be empty")
    (k[1] == ':') || _jsonfail(r, "a map key must be a symbol, written \":name\"")
    return Symbol(SubString(k, nextind(k, 1)))
end

function _parsearray!(r::_JSONReader)
    _expect!(r, _BYTE_LBRACKET)
    out = FormValue[]
    _skipws!(r)
    if !_atend(r) && r.b[r.i] == _BYTE_RBRACKET
        r.i += 1
        return out
    end
    while true
        push!(out, _parsevalue!(r))
        _skipws!(r)
        _atend(r) && _jsonfail(r, "unterminated array")
        c = r.b[r.i]
        r.i += 1
        (c == _BYTE_RBRACKET) && return out
        (c == _BYTE_COMMA) || _jsonfail(r, "expected ',' or ']'")
    end
end

function _parseobject!(r::_JSONReader)
    _expect!(r, _BYTE_LBRACE)
    out = Pair{String,FormValue}[]
    _skipws!(r)
    if !_atend(r) && r.b[r.i] == _BYTE_RBRACE
        r.i += 1
        return out
    end
    while true
        _skipws!(r)
        k = _parsestring!(r)
        _expect!(r, _BYTE_COLON)
        push!(out, k => _parsevalue!(r))
        _skipws!(r)
        _atend(r) && _jsonfail(r, "unterminated object")
        c = r.b[r.i]
        r.i += 1
        (c == _BYTE_RBRACE) && return out
        (c == _BYTE_COMMA) || _jsonfail(r, "expected ',' or '}'")
    end
end

# A list is a container: its first element is the sequence.
function _parseform!(r::_JSONReader)
    _expect!(r, _BYTE_LBRACKET)
    seq = _parsearray!(r)
    _expect!(r, _BYTE_COMMA)
    pairs = _parseobject!(r)
    _expect!(r, _BYTE_RBRACKET)
    kv = Pair{Symbol,FormValue}[_parsekey(r, first(p)) => last(p) for p in pairs]
    return FormContainer(FormSeq(seq), FormMap(kv))
end

# Whether a parsed object is an extern: plain keys `extern` and optionally `id`,
# which a form map cannot have (its keys carry the `:` marker).
function _isexternkeys(p::Vector{Pair{String,FormValue}})
    if length(p) == 1
        return first(p[1]) == "extern"
    elseif length(p) == 2
        return (first(p[1]) == "extern" && first(p[2]) == "id") ||
               (first(p[1]) == "id" && first(p[2]) == "extern")
    end
    return false
end

_externfield(p::Vector{Pair{String,FormValue}}, k::String) =
    (q = findfirst(x -> first(x) == k, p); q === nothing ? nothing : last(p[q]))

# Turn a parsed extern object back into a `FormExtern`. A missing `id` is a dead
# extern; an id resolves through the database's handle registry, though the bytes
# themselves are read lazily.
function _extern_rehydrate(r::_JSONReader, name::FormValue, id::FormValue)
    (name isa String) || _jsonfail(r, "an extern's type name must be a string")
    sym = Symbol(name)
    if id === nothing
        return FormExtern(_extern_handle(DeadExtern, sym, nothing, DeadExtern(sym), true, r.db))
    end
    (id isa Symbol) || _jsonfail(r, "an extern's id must be a keyword")
    _extern_type(sym)                       # raise if the type is not registered
    return FormExtern(_get_handle(r.db, sym, id))
end

# Whether a two-key object is the `{"re": …, "im": …}` a complex number is
# written as. Checked without building any sets, since this runs on every object.
_iscomplexkeys(p::Vector{Pair{String,FormValue}}) =
    length(p) == 2 &&
    ((first(p[1]) == "re" && first(p[2]) == "im") ||
     (first(p[1]) == "im" && first(p[2]) == "re"))

function _parsevalue!(r::_JSONReader)
    _skipws!(r)
    _atend(r) && _jsonfail(r, "unexpected end of input")
    c = r.b[r.i]
    (c == UInt8('n')) && return _literal!(r, "null", nothing)
    (c == UInt8('t')) && return _literal!(r, "true", true)
    (c == UInt8('f')) && return _literal!(r, "false", false)
    (c == _BYTE_QUOTE) && return _parseleafstring!(r)
    (c == _BYTE_LBRACKET) && return _parseform!(r)
    if c == _BYTE_LBRACE
        pairs = _parseobject!(r)
        # An extern object names a resource; `{"re","im"}` is how a complex
        # number is written; any other object is a form with only a map.
        if _isexternkeys(pairs)
            return _extern_rehydrate(r, _externfield(pairs, "extern"),
                                     _externfield(pairs, "id"))
        end
        if _iscomplexkeys(pairs)
            re = (first(pairs[1]) == "re" ? pairs[1] : pairs[2]).second
            im = (first(pairs[1]) == "im" ? pairs[1] : pairs[2]).second
            (re isa Float64 && im isa Float64) ||
                _jsonfail(r, "re and im must be numbers")
            return ComplexF64(re, im)
        end
        kv = Pair{Symbol,FormValue}[_parsekey(r, first(p)) => last(p) for p in pairs]
        return FormContainer(FormSeq(), FormMap(kv))
    end
    return _parsenumber!(r)
end

"""
    from_JSON(s::AbstractString) -> Form
    from_JSON(resolve::Function, s::AbstractString) -> Form
    from_JSON(db::Database, s::AbstractString) -> Form

Reads a [`Form`](@ref) from the JSON that [`to_JSON`](@ref) writes. A container is
a list `[seq, map]`; a bare object is accepted as a form with only a map, and a
bare scalar as a scalar form, since both are convenient ways to write one by hand.

A form may link to a [`VolatileForm`](@ref), written `"@<uuid>"`. Resolving such
a link requires a database, so either pass one, or pass a function that turns a
`UUID` into the value the link should yield. Reading a form that contains a link
without a resolver is an error.

An object with the plain key `extern` is a [`FormExtern`](@ref): its type is
looked up in the registry (see [`register_extern`](@ref)) and its bytes are read
from the `resources` table lazily. An object with no `id` is a dead extern; an
unregistered type is an [`ExternError`](@ref).

"""
from_JSON(s::AbstractString) = _from_JSON(nothing, s, nothing)
from_JSON(resolve::Function, s::AbstractString) = _from_JSON(resolve, s, nothing)

function _from_JSON(resolve::Union{Nothing,Function}, s::AbstractString,
                    db::Union{Nothing,AbstractDatabase})
    r = _JSONReader(s, resolve, db)
    v = _parsevalue!(r)
    _skipws!(r)
    _atend(r) || _jsonfail(r, "trailing data after the form")
    v isa FormValue || _jsonfail(r, "the JSON must describe a Form, not a $(typeof(v))")
    return to_form(v)          # a bare leaf becomes a scalar form
end

export to_JSON, from_JSON
