# Forms

A `Form` is an immutable, nested, JSON-able value. Every node in a form tree is a
form: a **`FormScalar`** holds a single leaf, a **`FormContainer`** holds a
sequence of positional values and a map of symbol-keyed ones, a
**`VolatileForm`** (see [Transactions](transactions.md)) holds a form that
persists itself, a **`FormExtern`** (see [Extern types](externs.md)) holds a
host-level value that is not JSON itself, **`ActorForm`**, **`PromiseForm`**,
and **`DelayForm`** (see
[Actor, promise, and delay forms](actor-promise-delay-forms.md)) hold live Air
objects, and a **`StreamForm`** (see [Stream forms](stream-forms.md)) holds a
persisted FIFO of forms.

## Scalar forms

A leaf on its own is a form:

```julia
using AirDB

Form("abc")             # Form("abc")
Form(5)                 # Form(5)
Form(nothing)           # Form(nothing)
value(Form("abc"))      # "abc" — unwrap a scalar form to its leaf
```

The leaves a form can hold are `String`, `Symbol`, `Bool`, `Nothing`, and the
numeric tower's value types: `Int64`, `BigInt`, `Float64`, `BigFloat`,
`Rational{Int64}`, `Rational{BigInt}`, `ComplexF64` and `Complex{BigFloat}`. A
wider or narrower scalar is converted where the conversion cannot lose
information:

```julia
Form(Int32(7))          # Form(7) — an Int64
Form(Int128(2)^70)      # a BigInt: it does not fit in an Int64
Form('x')               # Form("x")
Form(1 + 2im)           # Form(1.0 + 2.0im)
Form(true)              # Form(true) — Bool stays Bool
Form(1 // 3)            # Form(1//3) — a Rational{Int64}
Form(big"1.5")          # a BigFloat, at its own precision
```

Each of these leaf types survives a JSON round trip as the same Julia type and
value; a `BigFloat` keeps its precision. A value that fits no exact leaf —
`Complex(1//3, 0)`, say — raises rather than rounding. The one lossy conversion
is an `Irrational` constant (`π`, `ℯ`), which becomes a `Float64`.
`is_form_representable(x)` answers whether `to_form(x)` will succeed, without
raising, so a caller can check first:

```julia
is_form_representable(1 // 3)             # true
is_form_representable(complex(1 // 3, 0)) # false
is_form_representable([1, 2])             # true, recursively
```

## Containers

`form(...)` builds a container: its positional arguments become the sequence and
its keyword arguments the map.

```julia
f = form("widget", 1, 2.5, meta = form(name = "abc"))
f                       # Form("widget", 1, 2.5, meta=(name="abc"))
```

Every value must be a leaf or another form. A `Vector` or `Dict` **argument**
becomes a nested container, so ordinary Julia collections nest naturally:

```julia
form([1, 2, 3])         # Form((1, 2, 3))
form(Dict(:a => 1))     # Form((a=1))
```

```{admonition} Form vs. form
:class: note
`Form(x)` builds a *scalar* form from one leaf, and `Form(seq, map)` builds a
container from prepared collections. `form(...)` is the general builder, and
[`to_form`](#to_form) converts any value to a form.
```

```{admonition} How a container is stored
:class: note
A container's sequence and map are held in a small, flat, copy-on-write form
while they are small — which is the common case — and promoted to Air's
persistent structure above a threshold. Every update copies, so a form shared
between two values is never changed under either of them; you never need to know
which representation is in use.
```

## Reading

Indexing walks the tree, and a leaf read out of a container is wrapped back into a
scalar form — so **every value you read is a form**:

```julia
f = form(10, 20, a = form(x = 1))

f[1]              # Form(10)
value(f[1])       # 10
f[:a]             # Form(x=1)
value(f[:a, :x])  # 1
```

Use `value` to get the leaf out of a scalar form.

## The collection protocol

A form is a collection, so it iterates in one canonical order — every sequence
position, then every map key sorted — and supports the usual tools.

```julia
f = form(10, 20, a = 30)

length(f)          # 3
isempty(f)         # false
keys(f)            # 1, 2, :a
values(f)          # Form(10), Form(20), Form(30)
pairs(f)           # 1 => Form(10), 2 => Form(20), :a => Form(30)

for (k, v) in f
    # iterates the pairs, in the canonical order
end

Dict(collect(f))   # 1 => Form(10), 2 => Form(20), :a => Form(30)
first(f)           # 1 => Form(10)
last(f)            # :a => Form(30)

copy(f) === f      # true — forms are immutable
empty(f)           # Form() — the empty container
```

## Keywords and wildcards

A symbol that begins with a colon is a **keyword**, and one that begins with a
question mark is a **wildcard**. They are ordinary leaves with distinct text, so a
keyword and a wildcard are never equal to each other or to a plain symbol.
`iskeyword` and `iswildcard` test for them.

```julia
iskeyword(Form(Symbol(":abc")))  # true
iswildcard(Form(Symbol("?abc"))) # true
iskeyword(Form(:abc))            # false — a plain symbol
iswildcard(Form(Symbol(":abc"))) # false

Form(Symbol(":abc"))             # not equal to Form(Symbol("?abc")) or Form(:abc)
```

## Updating

Every update returns a new form; the original is untouched. (`setindex` here is
Air's persistent verb, not `Base.setindex!`.)

```julia
g = form(1, 2, 3)

setindex(g, 9, 1)      # Form(9, 2, 3)
push(g, 4)             # Form(1, 2, 3, 4)
pop(g)                 # Form(1, 2)
delete(g, 2)           # Form(1, 3)   — items shift down; no blanks
setindex(form(a = 1), 2, :b)   # Form(a=1, b=2)

g                      # Form(1, 2, 3) — unchanged
```

An integer index equal to one past the end of the sequence appends:

```julia
setindex(g, 4, 4)      # Form(1, 2, 3, 4)
setindex(g, 9, 5)      # ERROR: BoundsError
```

## `to_form`

`to_form` converts any value to a form: a form is returned as it is, a leaf
becomes a `FormScalar`, and a collection becomes a container.

```julia
to_form(5)             # Form(5)
to_form("abc")         # Form("abc")
to_form(nothing)       # Form(nothing)
to_form([1, 2, 3])     # Form(1, 2, 3)
to_form(Dict(:a => 1)) # Form(a=1)
```

## Equality and printing

Two forms are equal when they are the same kind of form with equal contents
(numeric leaves compare as numbers, so `Form(5) == Form(5.0)`). A nested
container prints without the `Form` prefix, so a form reads like a call:

```julia
form(1, 2) == form(1, 2)               # true
form(b = 1, a = 2)                     # Form(a=2, b=1) — keys print sorted
sprint(show, form("a", b = 1))         # "Form(\"a\", b=1)"
sprint(show, Form(5))                  # "Form(5)"
```

### Equivalence

`==` compares values, so `Form(5) == Form(5.0)` and `Form(big(5)) == Form(5)`.
`isequal` and `hash` use Julia's element relations, so a container holding `NaN`
is `isequal` to itself and a container holding `-0.0` is not `isequal` to one
holding `0.0` — which keeps a form usable as a `Dict` key.

That value-based `==` is not the relation you want for a dictionary key in every
case: a `BigInt` and an `Int64` are different values even when they are
numerically equal. `isequiv` is the stricter, hashable relation:

- an immutable leaf is equivalent only to a leaf of the **same type** with an
  equal value, except that `NaN` is equivalent to itself (so `-0.0` and `0.0`
  are equivalent, as `==` says);
- an immutable container is equivalent when its sequence matches position by
  position and its map has the same keys with equivalent values;
- a mutable form — a `VolatileForm`, `ActorForm`, `PromiseForm`, `StreamForm`,
  or mutable extern — is equivalent only to the same object;
- an immutable extern is equivalent only to itself unless its type registered
  `equal`/`hash` functions;
- a `DelayForm` is equivalent when its type and serialization form are
  equivalent (forcing it changes nothing).

`equivhash` is a hash consistent with `isequiv`; use the pair together.

```julia
isequiv(Form(5), Form(5))          # true
isequiv(Form(5), Form(5.0))        # false — different leaf types
isequiv(Form(NaN), Form(NaN))      # true
isequiv(Form(-0.0), Form(0.0))     # true
isequiv(form(a = 1, b = 2), form(b = 2, a = 1))   # true

d = Dict{UInt,Any}()
d[equivhash(Form(5))] = Form(5)
```

## JSON

A container is written as the two-element list `[seq, map]`, and a scalar form as
its bare leaf, which makes the format self-describing. Strings and symbols are
both JSON strings, told apart by the first character inside the quotes (`'` for a
string, `:` for a symbol); a float always carries a point or exponent; and a
complex number is written as `{"re": …, "im": …}`. Values outside JSON's number
model are marked strings: a non-finite float is `"#inf"`, `"#-inf"`, or
`"#nan"`, and the arbitrary-precision leaves have their own markers:

| leaf | JSON |
| --- | --- |
| `BigInt` | `"#big:<digits>"` |
| `Rational{Int64}` | `"#rat:<num>/<den>"` |
| `Rational{BigInt}` | `"#bigrat:<num>/<den>"` |
| `BigFloat` | `"#bigfloat:<precision-bits>:<digits>"` |

A `Complex{BigFloat}` is the usual `{"re", …}` object with each part written as
a `BigFloat`.

```julia
using AirDB: to_JSON, from_JSON

to_JSON(form("widget", 1, 2.5))   # "[[\"'widget\", 1, 2.5], {}]"
to_JSON(form(a = 1))              # "[[], {\":a\": 1}]"
to_JSON(Form(5))                  # "5"
to_JSON(Form("abc"))              # "\"'abc\""
to_JSON(Form(Inf))                # "\"#inf\""
to_JSON(Form(ComplexF64(NaN, 0))) # "{\"re\": \"#nan\", \"im\": 0.0}"
to_JSON(Form(big(5)))             # "\"#big:5\""
to_JSON(Form(1 // 3))             # "\"#rat:1/3\""
to_JSON(Form(big"1.5"))           # "\"#bigfloat:256:1.5\""

from_JSON("[[\"'widget\", 1, 2.5], {}]") == form("widget", 1, 2.5)   # true
from_JSON("5") == Form(5)         # true — a bare scalar is a scalar form
from_JSON("{\":a\": 1}")          # Form(a=1) — a bare object is a map-only form
from_JSON("\"#big:5\"")           # Form(big(5)) — a BigInt
from_JSON("12345678901234567890") # a BigInt too, from a bare large integer
```

A form may link to a `VolatileForm`, written `"@<uuid>"`. Reading such a link
needs the database that owns it (see [Persistence](persistence.md)); without one
it is an error.

A form may also hold a `FormExtern`, written as `{"extern": "<type>", "id":
"<id>"}` — or `{"extern": "<type>"}` when it is dead. See
[Extern types](externs.md). An actor, promise, or stream link is written
`"!<uuid>"`, `"~<uuid>"`, or `"&<uuid>"`; a delay is the object
`{"delay": ":<type>", "form": …}`.

```julia
from_JSON("[[\"@11111111-1111-1111-1111-111111111111\"], {}]")
# ERROR: a form link (@...) needs a Database to be resolved
```
