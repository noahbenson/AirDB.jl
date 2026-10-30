# Volatile forms and metadata

<!-- review-status: unreviewed -->
:::{warning} Unreviewed content
This page was written with AI assistance and has not been reviewed by a human.
It may contain errors, omissions, or outdated information.
:::


The database-backed form, the lookup and loading API, and the optional
owner/ACL metadata and history policy every database-backed kind shares.

(api-volatileform)=
## VolatileForm

```julia
VolatileForm
```

A [`Form`](forms.md#api-form) that is stored in a PostgreSQL database and kept in sync with
it. A `VolatileForm` is a thin wrapper around an Air `Volatile{Form}`: it can be
read at any time, but it may only be *written* inside an Air transaction
(`@tx`/`tx`), and when that transaction commits the new value is sent to the
database's write pipeline.

Every `VolatileForm` has a stable `UUID`, and forms may embed other
volatile forms (written `"@<uuid>"` in JSON). Volatile forms are cached per
`Database` by id, so the same form is always the same object within one process.

Create one with `VolatileForm(db, args...; kwargs...)` or
`VolatileForm(db, form::Form)`; retrieve an existing one with
[`get_form`](#api-get-form).


```julia
VolatileForm(db::AbstractDatabase, form::Form; metadata = nothing,
             history = true) -> VolatileForm
VolatileForm(db::AbstractDatabase, args...; metadata = nothing,
             history = true, kwargs...) -> VolatileForm
```

Creates a new volatile form with a fresh UUID and registers it with `db` so it
will be written to the database. The arguments of the second form are the same as
[`Form`](forms.md#api-form)'s.

`metadata` is an optional [form](forms.md#api-form) stored alongside the form in its
`metadata` JSONB column; it may be changed later with [`set_metadata!`](#api-set-metadata).
`history` is fixed for the life of the form: `true` appends a row to
`form_history` on every update, while `false` keeps only the current row and
overwrites it.


(api-get-form)=
## get_form

```julia
get_form(db::AbstractDatabase, id::UUID) -> VolatileForm
```

The volatile form with the given id. If it is already cached it is returned
immediately; otherwise an unloaded form is created (its body is read from the
database on first access). The same id always yields the same object within a
`Database`.


(api-isloaded)=
## isloaded

```julia
isloaded(vf::VolatileForm) -> Bool
```

Whether `vf`'s form body has been read into memory. An unloaded form still knows
its id and will load on first access.


(api-load)=
## load!

```julia
load!(vf::VolatileForm) -> VolatileForm
```

Reads `vf`'s form body from the database if it is not already loaded, and yields
`vf`. Loading only fetches `vf` itself; the forms it links to stay unloaded until
they are touched in turn.


(api-history)=
## history

```julia
history(vf::VolatileForm) -> Bool
```

Whether `vf` records its history or keeps only its current row. Fixed at
construction.


(api-metadata)=
## metadata

```julia
metadata(fe::FormExtern)
```

The extern's owner/ACL metadata blob, or `nothing` when it has no row (an
unpersisted or dead extern). Read without touching the resource bytes.


```julia
metadata(vf::VolatileForm) -> Union{Form,Nothing}
```

The form's optional metadata. Like the body, it lives in an Air `Volatile`, so
an edit made by [`set_metadata!`](#api-set-metadata) is visible to the editing transaction and
to the next reader as soon as the transaction commits.


(api-set-metadata)=
## set_metadata!

```julia
set_metadata!(fe::FormExtern, m) -> FormExtern
```

Set the extern's owner/ACL metadata (a [`Form`](forms.md#api-form), or `nothing`). Like a
metadata edit on any other kind, this must happen inside a transaction and does
not rewrite the resource bytes; an aborted transaction leaves the value as it
was. An extern with no id has no row to carry metadata and raises.


```julia
set_metadata!(vf::VolatileForm, m) -> VolatileForm
```

Sets the form's metadata (a [`Form`](forms.md#api-form), or `nothing` to clear it). Like any
write, this must happen inside a transaction. The edit is transactional: the same
transaction reads it back through [`metadata`](#api-metadata), the next reader sees it as
soon as the transaction commits, another transaction's edit is validated at
commit, and an aborted transaction leaves the form — in memory and in the
database — untouched. It is a metadata-only edit: it neither rewrites the
payload nor adds a version or history row.


