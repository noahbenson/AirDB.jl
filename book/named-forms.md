# Named forms

A project usually has a few **well-known** forms — a `"root"` holding shared
data, a `"settings"` form, a per-user entry point. Rather than pass UUIDs around,
give a form a name.

A name is just an **alias**: it lives in a `form_name` table, and the form it
points to still has its own UUID and its own rows in `form_history` and
`form_current`. The table is small, so a `Database` keeps it **in memory** as a
`PDict{String,VolatileForm}` — and, because names are almost always changed inside
a transaction, that `PDict` lives in an Air **`Volatile`**. A change to it is
therefore transactional: it commits with the surrounding transaction (or in one of
its own) and is retried or discarded with it, just like the form data, while the
database write is scheduled through the writer in the same commit.

## Looking a form up by name

`named_form` looks a name up. A name may be a `Symbol` or a `String` — both refer
to the same form, because a name is compared by its string value.

`create` decides what happens when the name is *not* found:

| `create` | name found | name not found |
| --- | --- | --- |
| `false` (the default) | return the form | raise |
| `true` | raise | create a new named form and return it |
| `nothing` | return the form | return `nothing` |

```julia
using AirDB

named_form(db, "root")                    # ERROR if "root" is not registered
named_form(db, "root"; create = nothing)  # nothing if it is not registered
named_form(db, :root; create = nothing)   # Symbol and String agree
```

## Creating a named form

With `create = true`, a new form is created and registered when the name is free:

```julia
root = named_form(db, "root"; create = true, value = form(version = 1))
named_form(db, "root") === root         # true
named_form(db, "root"; create = true)   # ERROR: the name "root" is already in use
```

The `value` argument is the new form's initial value, used only when a form is
created. It may be:

- a `Form` — used as-is;
- anything a form can be made from, such as a number — converted, so `5` becomes
  `Form(5)`;
- no value (the default) — an empty container;
- an existing `VolatileForm` — in which case **no new form is made**, and the name
  is simply pointed at the given form.

```julia
named_form(db, "a"; create = true, value = form(x = 1))  # holds Form(x=1)
named_form(db, "b"; create = true, value = 5)            # holds Form(5)
named_form(db, "c"; create = true)                       # holds an empty container

shared = VolatileForm(db, n = 1)
named_form(db, "d"; create = true, value = shared)       # aliases `shared`
named_form(db, "d") === shared                           # true — the same object
```

## Renaming

`name_form!` registers a form under a name, overwriting whatever was there:

```julia
name_form!(db, "current", some_form)
name_form!(db, "current", another_form)   # now points at another_form
```

## The whole table

`named_forms` returns the whole table as a `PDict{String,VolatileForm}`. A `PDict`
is immutable, so the result is safe to share and to keep; each value is a
(possibly not-yet-loaded) `VolatileForm`.

```julia
names = named_forms(db)
names["root"]           # the form named "root"
haskey(names, "settings")
```

## Across connections

The table is loaded when a database is opened, so another process — or a later
session — finds the same names.

```julia
close(db)
db = open_database(cfg)
value(named_form(db, "root")[:version])   # 1
```

## Transactions

The name table is a `Volatile`, so registering or renaming a form is
transactional. `named_form` with `create = true` and `name_form!` join the
caller's transaction if there is one, and otherwise run in a transaction of their
own — so you can call them anywhere.

Inside a transaction, the registration commits with everything else:

```julia
@tx begin
    root = named_form(db, "root"; create = true, value = form(version = 1))
    root[:version] = 2                  # both commit together
end
```

and, just as importantly, it is **discarded if the transaction does not commit**:

```julia
try
    @tx begin
        named_form(db, "temp"; create = true)
        error("abort")
    end
catch
end
named_form(db, "temp"; create = nothing)   # nothing — the registration never happened
```

Reading the table inside a transaction registers a read of it, so a transaction
that looks a name up is retried if another transaction changes the table — the
same optimistic rule that governs everything else in Air.

Two transactions that register names at once are serialized by Air's conflict
detection, so the table stays consistent without any lock of our own.

## The alias table

```sql
CREATE TABLE form_name (
    name        TEXT        PRIMARY KEY,
    form_id     UUID        NOT NULL REFERENCES form_current(form_id)
);
```

The primary key keeps names unique, and the foreign key keeps every name pointing
at a real form.
