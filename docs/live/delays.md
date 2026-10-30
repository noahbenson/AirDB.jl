# Delays

<!-- review-status: unreviewed -->
:::{warning} Unreviewed content
This page was written with AI assistance and has not been reviewed by a human.
It may contain errors, omissions, or outdated information.
:::

A `DelayForm` is a run-once, thread-safe lazy value computed from a form. Its
type is registered with a loader that computes the value:

```julia
using AirDB

register_delay(:double, f -> Form(2 * value(f)))

d = DelayForm(:double, Form(3))
d[]                           # Form(6) — the loader runs once
isready(d)                    # true, and it never runs again
```

The serialization — the type name and the form — never changes, and writing the
delay out does not force it:

```julia
to_JSON(DelayForm(:double, Form(3)))
# "{\"delay\": \":double\", \"form\": 3}"
```

A delay is immutable: `d[] = x` raises. It has no table and no id; it is stored
inline wherever it appears, and a delay of an unregistered type cannot be built
or read. The loader should be deterministic: it is the delay's definition, and
a reloaded delay runs it again in the new process.

## Next

[Streams](streams.md) are the FIFO form.
