# Links between forms

<!-- review-status: unreviewed -->
:::{warning} Unreviewed content
This page was written with AI assistance and has not been reviewed by a human.
It may contain errors, omissions, or outdated information.
:::

A form may hold another `VolatileForm`. It is stored as the string `"@<uuid>"`,
never expanded, so a form that links to itself — or in a cycle — still encodes.

```julia
child  = VolatileForm(db, v = 1)
parent = VolatileForm(db, name = "parent", kid = child)
AirDB.sync(db)

AirDB.to_JSON(parent[])
# "[[], {\":kid\": \"@<uuid-of-child>\", \":name\": \"'parent\"}]"
```

Reading the parent loads only the parent; the child is loaded when it is
touched.

```julia
parent[:kid]             # the child VolatileForm — not expanded
value(parent[:kid][:v])  # 1 — now the child is loaded
```

Because loading a form never expands the forms it links to, loading a parent
does not pull in the whole database, and cyclic references are handled without
recursion.

The other live kinds use their own markers in the same way: `"!<uuid>"` for an
[actor](../live/actors.md), `"~<uuid>"` for a [promise](../live/promises.md),
`"&<uuid>"` for a [stream](../live/streams.md), and an object for an
[extern](../live/externs-registration.md) or a [delay](../live/delays.md). The
[JSON format](../semantics/json.md) page has the complete table.

## Next

[Named forms](named-forms.md) gives forms stable names.
