# Garbage collection

<!-- review-status: unreviewed -->
:::{warning} Unreviewed content
This page was written with AI assistance and has not been reviewed by a human.
It may contain errors, omissions, or outdated information.
:::


The sweep that reclaims rows nothing references any more, and its
statistics.

(api-gc)=
## gc!

```julia
gc!(db; dry_run = false, batch = 1000) -> GCStats
```

Sweeps unreachable database objects. The roots are the named forms (`form_name`)
and every live in-memory object (`VolatileForm`, `ActorForm`, `PromiseForm`, and
extern handle), so an object referenced only from a live handle survives. The
sweep removes unreachable rows from `form_current`, `form_actor_current`,
`form_promise`, and `resources`, and deletes the history rows of the swept
objects; live objects keep their full history.

The sweep runs as one job on the database's writer task, so it sees a
consistent snapshot and blocks only writes (reads continue). Object loading is
serialized with it, so a row cannot be swept while it is being loaded. Names are
never removed here; use [`delete_name!`](named-forms.md#api-delete-name) to release one.

`dry_run = true` reports what would be swept without deleting anything.

`MemoryDatabase` implements the same sweep over its in-memory stores.


(api-gcstats)=
## GCStats

```julia
GCStats
```

What a [`gc!`](#api-gc) sweep scanned and removed, per object kind, and how long it
took.


