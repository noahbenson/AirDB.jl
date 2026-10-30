# Updating and verbs

<!-- review-status: unreviewed -->
:::{warning} Unreviewed content
This page was written with AI assistance and has not been reviewed by a human.
It may contain errors, omissions, or outdated information.
:::

There are two ways to update. A **functional** update builds a new form and
leaves the original untouched. A **transactional** update writes through the
`VolatileForm`s on the path, changing their values in place; it must run inside
a transaction. The transaction rule itself is covered in
[Transactions](../transactions/stm.md); this page is about the update
operations.

## Functional update: `setindex`

`setindex` builds a new form and never writes a volatile. A volatile on the
update path is therefore **eliminated** (replaced by its plain, updated value);
volatiles off the path are kept as links.

```julia
f = form(10, 20, a = form(x = 1, y = 2), b = form(x = 3))

setindex(f, 99, :a, :x)        # Form(10, 20, a=(x=99, y=2), b=(x=3))
setindex(f, 5, 1)              # Form(5, 20, a=..., b=...)
setindex(f, 42, :c)            # adds a new key
setindex(f, 4, 3)              # appends: Form(10, 20, 4, a=..., b=...)
```

```julia
g = form(a = VolatileForm(db, x = 0), b = VolatileForm(db, x = 1))
r = setindex(g, 99, :a, :x)
r[:a]                          # Form(x=99) — a plain container; the volatile is gone
r[:b] === g[:b]                # true       — the off-path volatile is kept
```

A fan-out `setindex` returns a form over the selection:

```julia
setindex(f, 99, [:a, :b], :x)  # Form(a=(x=99, y=2), b=(x=99))
```

An integer index equal to one past the end of the sequence appends:

```julia
setindex(form(1, 2, 3), 4, 4)  # Form(1, 2, 3, 4)
setindex(form(1, 2, 3), 9, 5)  # ERROR: BoundsError
```

## Transactional update: `setindex!`

`setindex!` walks the path and writes the **deepest `VolatileForm`** on it — the
last volatile among the values along the path, including the final one. It
rebuilds that volatile along the keys below it. If no value on the path is a
volatile, it raises, because an ordinary form cannot be mutated.

```julia
@tx g[:a, :x] = 5              # writes the volatile g[:a]; reads g
```

Because it writes a volatile, `setindex!` must run inside a transaction. Setting
the final key sets the final volatile's value:

```julia
@tx g[:a] = form(x = 42)       # sets the value of the volatile at :a
```

A fan-out writes each branch's target:

```julia
@tx g[[:a, :b], :x] = 9        # writes both volatiles
```

An integer one past the end of a sequence appends:

```julia
seq = VolatileForm(db, 1, 2)
@tx seq[3] = 3                 # seq[] == Form(1, 2, 3)
```

```{admonition} Writes are not local
:class: warning
`setindex!` writes the deepest volatile, which may be shared with other
structures, so the change is visible everywhere that volatile is reachable. This
is the intended model — volatiles are identity objects — but it means the effect
of `g[:a, 1] = x` is not always obvious from the call site.
```

## Applying a function: `map`

`map` returns a form with the same keys, every immediate value replaced by
`fn(value)`. A `VolatileForm` **value** is handed to `fn` as the `VolatileForm`
object, so the function decides whether to keep or drop it. If the form itself is
a `VolatileForm`, the function is applied to its value; if it is a `FormScalar`,
it is applied to the leaf.

```julia
f = form(10, 20, a = form(x = 1), b = 3)

map(x -> x * 2, form(1, 2, a = 3))     # Form(2, 4, a=6)
map(x -> x + 1, Form(5))               # Form(6)
map(identity, g)                       # same keys; the volatiles are passed through
map(v -> v isa VolatileForm ? v[] : v, g)    # ... or expanded, if you prefer
```

The functional verbs `push`, `pop`, and `delete` likewise operate on a
`VolatileForm`'s value and return a new form; they never write the volatile.

```julia
g = form(1, 2, 3)
push(g, 4)          # Form(1, 2, 3, 4)
pop(g)              # Form(1, 2)
delete(g, 2)        # Form(1, 3) — items shift down; no blanks
```

## Verbs

Beyond `get`/`setindex`, a form is operated on with the usual functional verbs.
Each value handed to a function is passed as a form.

```julia
f = form(10, 20, a = form(x = 1), b = 3)
vf = VolatileForm(db, n = 0)

update(f, v -> value(v) + 1, :a, :x)   # read-modify-write: Form(10, 20, a=(x=2), b=3)
update!(vf, v -> value(v) + 1, :n)     # ... transactional: deepest volatile, like setindex!

merge(form(a = 1), form(b = 2))        # Form(a=1, b=2)
merge(form(a = 1), form(a = 9))        # Form(a=9) — the later form wins
merge_with((x, y) -> value(x) + value(y), form(a = 1), form(a = 2))   # Form(a=3)

haskey(f, :a, :x)                      # true — haskey takes a path
select_keys(f, [:b, :a])               # Form(a=(x=1), b=3); missing keys are skipped

filter(v -> v isa FormScalar && value(v) isa Int64, form(1, "s", a = 2))  # Form(1, a=2)
map_values(v -> value(v) + 1, form(1, a = 2))   # Form(2, a=3)
map_keys(k -> Symbol("k_", k), form(a = 1))     # Form(k_a=1)
deep_map(v -> v isa FormScalar && value(v) isa Int64 ? Form(value(v) + 1) : v,
         form(1, a = 2))                       # Form(2, a=3): every leaf, bottom-up

to_vector(form(1, 2, 3))   # [1, 2, 3]
to_dict(form(a = 1))       # Dict(:a => 1)
```

`update` and the other verbs without a `!` are purely functional; `update!`
writes the deepest `VolatileForm` on the path and raises if there is none — the
same rule as `setindex!` — so it must run inside a transaction.

## Next

[Equality](equality.md) covers comparing forms.
