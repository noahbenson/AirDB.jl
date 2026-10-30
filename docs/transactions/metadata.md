# Metadata and access control

<!-- review-status: unreviewed -->
:::{warning} Unreviewed content
This page was written with AI assistance and has not been reviewed by a human.
It may contain errors, omissions, or outdated information.
:::

Every database-backed kind carries an optional **metadata** form: a
`VolatileForm`, and — introduced later — an `ActorForm`, a `PromiseForm`, a
`StreamForm`, and a stored extern. It is set at creation or edited later:

```julia
vf = VolatileForm(db, a = 1; metadata = form(owner = "alice"))

metadata(vf)                                  # Form(owner="alice")
@tx set_metadata!(vf, form(owner = "bob"))    # transactional, metadata only
metadata(vf)                                  # Form(owner="bob")
```

`metadata` reads only the metadata columns — it never fetches or decodes the
payload, so a permission check can precede the read. `set_metadata!` likewise
rewrites only the metadata; it adds no version or history row.

```{admonition} A metadata-only read
:class: note
Because `metadata(vf)` does not load the form body, an unloaded form can be
permission-checked without reading its value. `isloaded(vf)` remains false
afterwards.
```

An object with no row (an unpersisted extern, a dead extern) has no metadata:
`metadata` returns `nothing`. Only database-backed externs are permissioned.

## Transactional edits

A metadata edit is transactional like any other write. The editing transaction
reads its own value back through `metadata`, the next reader sees it as soon as
the transaction commits, another transaction's edit is validated at commit (so
the loser retries), and an aborted transaction leaves both memory and the row
unchanged.

```julia
try
    @tx begin
        set_metadata!(vf, form(owner = "mallory"))
        error("abort")
    end
catch
end
metadata(vf)                                  # still Form(owner="bob")
```

AirDB carries the metadata; it does not interpret it. Checks are the caller's
job.

## The other kinds

The same `metadata` keyword, `metadata(x)`, and `set_metadata!(x, m)` work on
the kinds introduced later; each page shows the call:

- [Actors](../live/actors.md)
- [Promises](../live/promises.md)
- [Streams](../live/streams.md)
- [Extern types](../live/externs-registration.md) (for a stored, named extern)

The metadata columns are described in
[Schema and history](schema-and-history.md).

## Next

[Live objects](../live/actors.md) begins the forms backed by live Air objects.
