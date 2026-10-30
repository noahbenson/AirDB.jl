# Equivalence

<!-- review-status: unreviewed -->
:::{warning} Unreviewed content
This page was written with AI assistance and has not been reviewed by a human.
It may contain errors, omissions, or outdated information.
:::

[Equality](../forms/equality.md) compared forms by value. **Equivalence** is the
stricter relation you want when a form is a dictionary key: it compares both
value and type, and it treats every mutable form by identity. It is defined here,
after the live object kinds, because it names all of them.

```julia
isequiv(a, b)          # are two forms equivalent?
equivhash(a, h)        # a hash consistent with `isequiv`
```

## The rules

- An immutable leaf is equivalent only to a leaf of the **same type** with an
  equal value, except that `NaN` is equivalent to itself (and `-0.0` to `0.0`).
  So `Form(5) == Form(5.0)` but `!isequiv(Form(5), Form(5.0))`, and a
  `BigInt(5)` is not equivalent to an `Int64(5)`.
- An immutable container is equivalent when its sequence matches position by
  position and its map has the same keys with equivalent values.
- A mutable form — a [`VolatileForm`](../forms/volatile-forms.md),
  [`ActorForm`](../live/actors.md), [`PromiseForm`](../live/promises.md),
  [`StreamForm`](../live/streams.md), or a mutable extern — is equivalent only
  to the same object.
- An immutable extern is equivalent only to itself unless its type registered
  `equal`/`hash` functions; see
  [Extern types](../live/externs-registration.md#registering-a-type).
- A [`DelayForm`](../live/delays.md) is equivalent when its type and
  serialization form are equivalent. Forcing it changes nothing.

```julia
isequiv(Form(5), Form(5))                          # true
isequiv(Form(5), Form(5.0))                        # false — different leaf types
isequiv(Form(NaN), Form(NaN))                      # true
isequiv(Form(-0.0), Form(0.0))                     # true
isequiv(form(a = 1, b = 2), form(b = 2, a = 1))    # true
```

## Its hash

`equivhash` agrees with `isequiv`: equivalent forms hash equally. It is not
`Base.hash` — a signed zero hashes as `0.0`, every `NaN` hashes to one value, a
numeric leaf hashes with its type, and a mutable form hashes by object identity.

```julia
d = Dict{UInt,Any}()
d[equivhash(Form(5))] = Form(5)
d[equivhash(Form(5.0))] = Form(5.0)     # a different key
length(d)                               # 2
```

The seed argument composes like `Base.hash`:

```julia
equivhash(Form(5), zero(UInt))
```

## Next

[The JSON format](json.md) writes every kind of form — and every link — as text.
