# The JSON format

<!-- review-status: unreviewed -->
:::{warning} Unreviewed content
This page was written with AI assistance and has not been reviewed by a human.
It may contain errors, omissions, or outdated information.
:::

Forms are stored as PostgreSQL `JSONB`, and `to_JSON`/`from_JSON` convert between
a form and the text. This page is the reference for that text: how each leaf and
each link is written. You rarely need it — writing and reading a form does this
for you — but it is useful when inspecting a row or producing JSON by hand.

```julia
using AirDB: to_JSON, from_JSON
```

## Leaves and containers

A container is the two-element list `[seq, map]`, and a scalar form is its bare
leaf. A bare object is accepted on input as a map-only form, and a bare scalar as
a scalar form, so hand-written JSON can omit the wrapper.

```julia
to_JSON(form("widget", 1, 2.5))   # "[[\"'widget\", 1, 2.5], {}]"
to_JSON(form(a = 1))              # "[[], {\":a\": 1}]"
to_JSON(Form(5))                  # "5"
to_JSON(Form("abc"))              # "\"'abc\""

from_JSON("[[\"'widget\", 1, 2.5], {}]") == form("widget", 1, 2.5)   # true
from_JSON("5") == Form(5)         # a bare scalar is a scalar form
from_JSON("{\":a\": 1}")          # Form(a=1) — a bare object is a map-only form
```

Strings and symbols are both JSON strings, told apart by the first character
inside the quotes: `'` for a string, `:` for a symbol. A float always carries a
point or an exponent.

## Numbers beyond JSON

JSON's number model is narrower than the [form leaves](../forms/values.md). A
value outside it is written as a marked string:

| leaf | JSON |
| --- | --- |
| `Inf`, `-Inf`, `NaN` | `"#inf"`, `"#-inf"`, `"#nan"` |
| `BigInt` | `"#big:<digits>"` |
| `Rational{Int64}` | `"#rat:<num>/<den>"` |
| `Rational{BigInt}` | `"#bigrat:<num>/<den>"` |
| `BigFloat` | `"#bigfloat:<precision-bits>:<digits>"` |

A `Complex` is an object `{"re": …, "im": …}`, always, even when the imaginary
part is zero. The parts are both `Float64` or both `BigFloat`.

```julia
to_JSON(Form(Inf))                 # "\"#inf\""
to_JSON(Form(ComplexF64(NaN, 0)))  # "{\"re\": \"#nan\", \"im\": 0.0}"
to_JSON(Form(big(5)))              # "\"#big:5\""
to_JSON(Form(1 // 3))              # "\"#rat:1/3\""
to_JSON(Form(big"1.5"))            # "\"#bigfloat:256:1.5\""

from_JSON("\"#big:5\"")            # Form(big(5))
from_JSON("12345678901234567890")  # Form(big(12345678901234567890))
```

A `BigFloat` keeps its precision across the round trip.

## Links

A database-backed object is never expanded into the form that holds it; the form
stores a **link**. This keeps a cyclic form encodable and lets one object be
shared by many forms. Each kind has its own marker:

| object | JSON |
| --- | --- |
| [`VolatileForm`](../forms/volatile-forms.md) | `"@<uuid>"` |
| [`ActorForm`](../live/actors.md) | `"!<uuid>"` |
| [`PromiseForm`](../live/promises.md) | `"~<uuid>"` |
| [`StreamForm`](../live/streams.md) | `"&<uuid>"` |
| stored [`FormExtern`](../live/externs-registration.md) | `{"extern": "'<type>", "id": ":<id>"}` |
| dead extern | `{"extern": "'<type>"}` |
| [`DelayForm`](../live/delays.md) | `{"delay": ":<type>", "form": …}` |

```julia
to_JSON(form(p = pf))     # "[[], {\":p\": \"~<uuid>\"}]" — a promise is a link
```

The link markers are what makes the format self-describing: user strings begin
with `'` and symbols with `:`, so a structural scan can never mistake data for a
link. Garbage collection relies on that property; see
[Garbage collection](../operations/garbage-collection.md).

## Reading a form with links

Resolving a link needs the database that owns it. `from_JSON` accepts the
database, a resolver function, or neither:

```julia
from_JSON(db, s)              # resolve links through this database
from_JSON(uuid -> get_form(db, uuid), s)   # or with your own function
from_JSON(s)                  # only for forms with no links
```

Reading a form that contains a link without a resolver is an error:

```julia
from_JSON("[[\"@11111111-1111-1111-1111-111111111111\"], {}]")
# ERROR: a form link (@...) needs a Database to be resolved
```

An extern object is resolved through the registry, so its type must have been
registered with [`register_extern`](../live/externs-registration.md); its stored
bytes are read from the `resources` table lazily.

## Next

[Concurrency](../operations/concurrency.md) turns to running many threads against
one database.
