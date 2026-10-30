# Equality and hashing

<!-- review-status: unreviewed -->
:::{warning} Unreviewed content
This page was written with AI assistance and has not been reviewed by a human.
It may contain errors, omissions, or outdated information.
:::

Two forms are equal when they are the same kind of form with equal contents.
Numeric leaves compare as numbers, so `Form(5) == Form(5.0)`, and a
`BigInt(5)` equals an `Int64(5)`.

```julia
form(1, 2) == form(1, 2)               # true
form(1, 2) == form(1, 2.0)             # true — numeric equality
Form(big(5)) == Form(5)                # true
form(a = 1, b = 2) == form(b = 2, a = 1)   # true — map order does not matter
```

`isequal` and `hash` use Julia's element relations. Containers recurse with
`isequal`, so a container holding `NaN` is `isequal` to itself, a container
holding `-0.0` is not `isequal` to one holding `0.0`, and the hash agrees. This
is what makes a form usable as a `Dict` key:

```julia
isequal(form(NaN), form(NaN))          # true
isequal(form(-0.0), form(0.0))         # false
hash(form(NaN)) == hash(form(NaN))     # true

d = Dict{Any,Int}()
d[form(NaN)] = 1
d[form(NaN)]                           # 1
```

This is *value* equality with Julia's hashing rules. It is not the same as
**equivalence**, which additionally requires the same leaf type and treats
mutable handles by identity. Equivalence — and when you want it for a
dictionary — is covered in [Equivalence](../semantics/equivalence.md); it is
defined there because it uses every form kind.

## Next

[Transactions](../transactions/stm.md) starts the persistence story: how a
`VolatileForm`'s writes become atomic and durable.
