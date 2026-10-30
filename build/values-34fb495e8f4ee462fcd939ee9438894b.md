# Form values

<!-- review-status: unreviewed -->
:::{warning} Unreviewed content
This page was written with AI assistance and has not been reviewed by a human.
It may contain errors, omissions, or outdated information.
:::

A `Form` is an immutable, nested, JSON-able value. Every node in a form tree is
a form:

- a **`FormScalar`** holds a single leaf;
- a **`FormContainer`** holds a sequence of positional values and a map of
  symbol-keyed ones;
- a **`VolatileForm`** (see [Volatile forms](volatile-forms.md)) holds a form
  that persists itself in a database;
- a **`FormExtern`** (see [Extern types](../live/externs-registration.md)) holds
  a host-level value that is not JSON itself; and
- **`ActorForm`**, **`PromiseForm`**, **`StreamForm`**, and **`DelayForm`**
  (see [Actors](../live/actors.md), [Promises](../live/promises.md),
  [Streams](../live/streams.md), and [Delays](../live/delays.md)) hold live Air
  objects.

This page is about the plain values: scalars and containers.

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
`to_form` converts any value to a form.
```

```{admonition} How a container is stored
:class: note
A container's sequence and map are held in a small, flat, copy-on-write form
while they are small — which is the common case — and promoted to Air's
persistent structure above a threshold. Every update copies, so a form shared
between two values is never changed under either of them; you never need to know
which representation is in use. (`PDict` and `PVector` are Air's persistent map
and vector types.)
```

## The collection protocol

A form is a collection, so it iterates in one canonical order — every sequence
position, then every map key sorted — and supports the usual tools.

```julia
f = form(10, 20, a = 30)

length(f)          # 3
isempty(f)         # false
keys(f)            # 1, 2, :a
values(f)          # iterates Form(10), Form(20), Form(30)
pairs(f)           # iterates 1 => Form(10), 2 => Form(20), :a => Form(30)

for (k, v) in f
    # iterates the pairs, in the canonical order
end

collect(f)         # Any[1 => Form(10), 2 => Form(20), :a => Form(30)]
Dict(collect(f))   # a Dict of the same pairs
first(f)           # 1 => Form(10)
last(f)            # :a => Form(30)

copy(f) === f      # true — forms are immutable
empty(f)           # Form() — the empty container
```

A scalar form has no elements: `length(Form(5)) == 0`.

## Keywords and wildcards

A symbol that begins with a colon is a **keyword**, and one that begins with a
question mark is a **wildcard**. They are ordinary leaves with distinct text, so
a keyword and a wildcard are never equal to each other or to a plain symbol.
`iskeyword` and `iswildcard` test for them.

```julia
iskeyword(Form(Symbol(":abc")))  # true
iswildcard(Form(Symbol("?abc"))) # true
iskeyword(Form(:abc))            # false — a plain symbol
iswildcard(Form(Symbol(":abc"))) # false

Form(Symbol(":abc"))             # not equal to Form(Symbol("?abc")) or Form(:abc)
```

They become important when an operation names a key: the
[extern API](../live/externs-registration.md) and the indexing paths use keyword
forms for names that are not map keys.

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

## Printing

A nested container prints without the `Form` prefix, so a form reads like a
function call with its arguments, and the map keys are printed sorted:

```julia
form(1, 2) == form(1, 2)               # true
form(b = 1, a = 2)                     # Form(a=2, b=1)
sprint(show, form("a", b = 1))         # "Form(\"a\", b=1)"
sprint(show, Form(5))                  # "Form(5)"
```

## Next

[Volatile forms](volatile-forms.md) attaches a form to a database.
