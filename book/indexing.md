# Indexing and updating

Forms are navigated with a **path** of keys. The same indexing works on any form,
and a `VolatileForm` met along the way is transparent — its value is used in its
place — which makes a tree of forms read like a single nested value.

- An `Integer` is a sequence position; a `Symbol` is a map key.
- A **vector** key (or `:`, meaning every key) **fans out**, building a new form
  over the selection.
- A value read out of a container is wrapped back into a form, so indexing always
  yields a form: a leaf comes back as a `FormScalar`, which [`value`](@ref)
  unwraps. The value at the **final** key is returned as it is, so a final
  `VolatileForm` comes back whole rather than expanded.

## Reading

```julia
f = form(10, 20, a = form(x = 1, y = 2), b = form(x = 3))

f[1]              # Form(10)
value(f[1])       # 10
f[:a]             # Form(x=1, y=2)
value(f[:a, :x])  # 1   — same as value(f[:a][:x])
```

A `VolatileForm` is transparent when you index *through* it, but returned whole
when it is the final value:

```julia
a = VolatileForm(db, x = 0)
b = VolatileForm(db, x = 1)
fv = form(a = a, b = b)

fv[:a]            # the VolatileForm itself
value(fv[:a, :x]) # 0    — fv[:a] was dereferenced to reach :x
value(fv[:a][:x]) # 0
```

## Fanning out

A vector key builds a form over the selection. Because reading **extracts data**,
volatiles are eliminated from whatever it builds — a `VolatileForm` in the result
is replaced by its value.

```julia
f[[:a, :b], :x]        # Form(a=1, b=3)
f[[:a, :b], [:x]]      # Form(a=Form(x=1), b=Form(x=3)) — a nested level per vector
f[2:3]                 # Form(20, 30) — a range is a vector key, so it fans out
```

A range over the sequence's own collection gives the subsequence, as a sequence
rather than a plain `Vector`, so it can be used as a container's sequence:

```julia
f.seq[2:3]             # the FormSeq holding 20 and 30
```

With volatiles in the tree:

```julia
g = form(a = VolatileForm(db, x = 0), b = VolatileForm(db, x = 1))

g[[:a, :b], :x]        # Form(a=0, b=1)          — the volatiles are eliminated
g[[:a, :b], [:x]]      # Form(a=Form(x=0), b=Form(x=1))
```

`:` selects every sequence position and every map key:

```julia
h = form(form(x = 10), form(x = 20), a = form(x = 30))
h[:, :x]               # Form(10, 20, a=30)
```

A missing key raises. `get` supplies a default for a missing **final** key; a
missing intermediate key still raises.

```julia
f[:z]                          # ERROR: KeyError: key :z not found
get(f, :z, :none)              # :none
get(f, :a, :z, :none)          # :none   — :a exists, :z does not
get(f, :z, :x, :none)          # ERROR: KeyError — the intermediate :z is missing
```

## Functional update — `setindex`

`setindex` builds a new form and never writes a volatile. A volatile on the
update path is therefore **eliminated** (replaced by its plain, updated value);
volatiles off the path are kept as links.

```julia
setindex(f, 99, :a, :x)        # Form(10, 20, a=Form(x=99, y=2), b=Form(x=3))
setindex(f, 5, 1)              # Form(5, 20, a=..., b=...)
setindex(f, 42, :c)            # adds a new key
setindex(f, 4, 4)              # appends: Form(10, 20, ..., 4)
```

```julia
r = setindex(g, 99, :a, :x)
r[:a]                          # Form(x=99) — a plain container; the volatile is gone
r[:b] === g[:b]                # true       — the off-path volatile is kept
```

A fan-out `setindex` returns a form over the selection:

```julia
setindex(f, 99, [:a, :b], :x)  # Form(a=Form(x=99, y=2), b=Form(x=99))
```

## Transactional update — `setindex!`

`setindex!` walks the path and writes the **deepest `VolatileForm`** on it — the
last volatile among the values along the path, including the final one. It
rebuilds that volatile along the keys below it. If no value on the path is a
volatile, it raises, because a persistent form cannot be mutated.

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

## Applying a function — `map`

`map` returns a form with the same keys, every immediate value replaced by
`fn(value)`. A `VolatileForm` **value** is handed to `fn` as the `VolatileForm`
object, so the function decides whether to keep or drop it. If the form itself is
a `VolatileForm`, the function is applied to its value; if it is a `FormScalar`,
it is applied to the leaf.

```julia
map(x -> x * 2, form(1, 2, a = 3))     # Form(2, 4, a=6)
map(x -> x + 1, Form(5))               # Form(6)
map(identity, fv)                      # same keys; the volatiles are passed through
map(v -> v isa VolatileForm ? v[] : v, fv)   # ... or expanded, if you prefer
```

The functional verbs `push`, `pop`, and `delete` likewise operate on a
`VolatileForm`'s value and return a new form; they never write the volatile.

```julia
push(seq, 9)       # a new form
delete(seq, 1)     # a new form with items shifted down
```

## Verbs

Beyond `get`/`setindex`, a form is operated on with the usual functional verbs.
Each value handed to a function is passed as a form.

```julia
f = form(10, 20, a = form(x = 1), b = 3)

update(f, v -> value(v) + 1, :a, :x)   # read-modify-write: Form(10, 20, a=(x=2), b=3)
update!(vf, v -> value(v) + 1, :n)     # ... transactional: deepest volatile, like setindex!

merge(form(a = 1), form(b = 2))        # Form(a=1, b=2)
merge(form(a = 1), form(a = 9))        # Form(a=9) — the later form wins
merge_with((x, y) -> value(x) + value(y), form(a = 1), form(a = 2))   # Form(a=3)

haskey(f, :a, :x)                      # true — haskey takes a path
select_keys(f, [:b, :a])               # Form(b=3, a=(x=1)); missing keys are skipped

filter(v -> v isa FormScalar && value(v) isa Int64, form(1, "s", a = 2))  # Form(1, a=2)
map_values(v -> value(v) + 1, form(1, a = 2))   # Form(2, a=3)
map_keys(k -> Symbol("k_", k), form(a = 1))     # Form(k_a=1)
deep_map(v -> ..., f)                            # transform every node, bottom-up

to_vector(form(1, 2, 3))   # [1, 2, 3]
to_dict(form(a = 1))       # Dict(:a => 1)
```

`update` and the other verbs without a `!` are purely functional; `update!` writes
the deepest `VolatileForm` on the path and raises if there is none — the same
rule as `setindex!` — so it must run inside a transaction.
