# Garbage collection

<!-- review-status: unreviewed -->
:::{warning} Unreviewed content
This page was written with AI assistance and has not been reviewed by a human.
It may contain errors, omissions, or outdated information.
:::

Rows accumulate for objects that nothing refers to any more: an unnamed form,
an actor that finished, a promise whose referrer is gone — delivered or not,
since every promise has a row. `gc!(db)` sweeps them:

```julia
stats = gc!(db)                    # sweep
stats = gc!(db; dry_run = true)    # or only report what would go
```

```julia
stats.swept_forms        # form rows removed
stats.swept_actors       # actor rows removed
stats.swept_promises     # promise rows removed
stats.swept_streams      # stream rows removed
stats.swept_resources    # extern resource rows removed
stats.seconds            # how long the sweep took
```

Each kind also has a `scanned_*` count in the same struct. `GCStats(scanned: …,
swept: …, …s)` prints a one-line summary.

## Roots

The roots are:

- every name in `form_name` (see [Named forms](../transactions/named-forms.md)),
  and
- every **live in-memory object** — a [`VolatileForm`](../forms/volatile-forms.md),
  [`ActorForm`](../live/actors.md), [`PromiseForm`](../live/promises.md),
  [`StreamForm`](../live/streams.md), or extern handle — that is still reachable
  in the process.

Everything else is reachable only through links inside stored forms, so the sweep
crawls the payloads, marks what the roots reach, and deletes the rest. A deleted
object's history rows go with it.

Two consequences:

- A name is a root forever unless you release it with
  `delete_name!(db, name)`.
- Collection is **conservative**: an object still referenced anywhere in the
  process is kept. That is always safe — `gc!` never removes something in use —
  but a just-released object may survive one sweep.

## Links and malformed rows

Links are found by a structural scan of the stored JSON. Every link string begins
with a marker (`@`, `!`, `~`, `&`, or an `{"extern": …}` object), while user
strings begin with `'` and symbols with `:`, so the scan cannot mistake data for
a link (see [The JSON format](../semantics/json.md)). A payload the reader itself
would reject — a malformed marker — is not a link the sweep can resolve, so such
a row is left alone rather than being read as reachable.

## Running while the database is live

The sweep runs as one job on the writer task, so it sees a consistent snapshot
and only writes wait behind it; reads continue on the read pool. Object loading
is serialized with it, so a row cannot be swept while it is being loaded. The
sweep is bounded per batch (the `batch` keyword) so it does not hold the writer
for an unbounded time.

`MemoryDatabase` implements the same sweep over its in-memory stores.

## Next

[Back to the beginning](../index.md) is a good place to go next if you
have read the whole book, or jump to the [API reference](../api/index.md) for
every public name.
