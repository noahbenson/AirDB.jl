# Reading and paths

<!-- review-status: unreviewed -->
:::{warning} Unreviewed content
This page was written with AI assistance and has not been reviewed by a human.
It may contain errors, omissions, or outdated information.
:::

Forms are navigated with a **path** of keys. The same indexing works on any form,
and a `VolatileForm` met along the way is transparent — its value is used in its
place — which makes a tree of forms read like a single nested value.

- An `Integer` is a sequence position; a `Symbol` is a map key.
- A **vector** key (or `:`, meaning every key) **fans out**, building a new form
  over the selection.
- A value read out of a container is wrapped back into a form, so indexing always
  yields a form: a leaf comes back as a `FormScalar`, which `value` unwraps. The
  value at the **final** key is returned as it is, so a final `VolatileForm`
  comes back whole rather than expanded.

## Reading

```julia
f = form(10, 20, 30, a = form(x = 1, y = 2), b = form(x = 3))

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
f[[:a, :b], [:x]]      # Form(a=(x=1), b=(x=3)) — a nested level per vector
f[2:3]                 # Form(20, 30) — a range is a vector key, so it fans out
```

A range over the sequence's own collection gives the subsequence, as a sequence
rather than a plain `Vector`, so it can be used as a container's sequence:

```julia
f.seq[2:3]             # the subsequence holding 20 and 30
```

With volatiles in the tree:

```julia
g = form(a = VolatileForm(db, x = 0), b = VolatileForm(db, x = 1))

g[[:a, :b], :x]        # Form(a=0, b=1)          — the volatiles are eliminated
g[[:a, :b], [:x]]      # Form(a=(x=0), b=(x=1))
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

`haskey(f, path...)` tests whether a whole path resolves.

## Next

[Updating and verbs](updating-and-verbs.md) covers changing a form.
