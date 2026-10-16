# Forms

A `Form` is an immutable, nested, JSON-able value. Every node in a form tree is a
form: a **`FormScalar`** holds a single leaf, a **`FormContainer`** holds a
sequence of positional values and a map of symbol-keyed ones, a
**`VolatileForm`** (see [Transactions](transactions.md)) holds a form that
persists itself, and a **`FormExtern`** (see [Extern types](externs.md)) holds a
host-level value that is not JSON itself.

## Scalar forms

A leaf on its own is a form:

```julia
using AirDB

Form("abc")             # Form("abc")
Form(5)                 # Form(5)
Form(nothing)           # Form(nothing)
value(Form("abc"))      # "abc" — unwrap a scalar form to its leaf
```

The leaves a form can hold are `String`, `Symbol`, `Bool`, `Int64`, `Float64`,
`ComplexF64` and `Nothing`. A narrower scalar is converted where the conversion
cannot lose information:

```julia
Form(Int32(7))          # Form(7)
Form('x')               # Form("x")
Form(1 + 2im)           # Form(1.0 + 2.0im)
Form(true)              # Form(true) — Bool stays Bool
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

## The `held` flag

A container carries a `held` flag, and a symbol scalar form carries the same idea
as a leading quote on its name. `hold` sets it, `unhold` clears it, and `isheld`
tests it. It is part of a form's value — a held form is not equal to an unheld one
— and it is written in the form's JSON, so a held form round-trips through the
database.

```julia
h = hold(form(a = 1))        # the same form, now held
isheld(h)                    # true
hold(h) === h                # idempotent

hold(Form(:abc))             # Form(Symbol("'abc")) — a leading quote
hold(Form(Symbol("'abc")))   # unchanged — quotes do not stack
unhold(Form(Symbol("'abc"))) # Form(:abc)

hold(Form(5))                # Form(5) — other forms are returned unchanged
```

A symbol that begins with a colon is a **keyword**, and a keyword is a different,
inert leaf: holding one is the keyword, so `hold` and `unhold` leave it exactly as
it is, and `isheld` does not count it as held.

```julia
hold(Form(Symbol(":abc")))     # unchanged — a keyword is inert
unhold(Form(Symbol(":abc")))   # unchanged — a keyword never unholds
isheld(Form(Symbol(":abc")))   # false — a keyword is not a held symbol
Form(Symbol(":abc"))           # not equal to Form(Symbol("'abc"))
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

## JSON

A container is written as the three-element list `[seq, map, held]`, and a scalar
form as its bare leaf, which makes the format self-describing. Strings and symbols are
both JSON strings, told apart by the first character inside the quotes (`'` for a
string, `:` for a symbol); a float always carries a point or exponent; and a
complex number is written as `{"re": …, "im": …}`.

```julia
using AirDB: to_JSON, from_JSON

to_JSON(form("widget", 1, 2.5))   # "[[\"'widget\", 1, 2.5], {}, false]"
to_JSON(hold(form(a = 1)))        # "[[], {\":a\": 1}, true]" — the flag is last
to_JSON(Form(5))                  # "5"
to_JSON(Form("abc"))              # "\"'abc\""

from_JSON("[[\"'widget\", 1, 2.5], {}]") == form("widget", 1, 2.5)   # true
from_JSON("5") == Form(5)         # true — a bare scalar is a scalar form
from_JSON("{\":a\": 1}")          # Form(a=1) — a bare object is a map-only form
```

A form may link to a `VolatileForm`, written `"@<uuid>"`. Reading such a link
needs the database that owns it (see [Persistence](persistence.md)); without one
it is an error.

A form may also hold a `FormExtern`, written as the tagged list `["extern",
"<type>", <payload>]`. See [Extern types](externs.md).

```julia
from_JSON("[[\"@11111111-1111-1111-1111-111111111111\"], {}]")
# ERROR: a form link (@...) needs a Database to be resolved
```
