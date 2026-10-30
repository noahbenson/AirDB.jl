# AirDB quickstart
# ===============
#
# Paste these blocks into a Julia notebook (IJulia or Pluto), one block per cell,
# or run the whole file:
#
#     docker compose up -d                        # start the test Postgres
#     JULIA_NUM_THREADS=4 julia --project=. examples/quickstart.jl
#
# It walks the whole surface: configure, create a database, build forms, write
# them inside transactions, read and update them along paths, link forms
# together, and see lazy loading, concurrency, batching, and failure handling.

# %% 1. Setup -----------------------------------------------------------------
using AirDB
using Air            # for the @tx / tx transaction macros
using UUIDs          # for uuid4(), used to look up a missing form

# Connection details for YOUR PostgreSQL server. These defaults match this repo's
# docker-compose.yml.
cfg = DatabaseConfig(; host = "localhost", port = 5432,
                       dbname = "airdb_test", user = "airdb", password = "airdb")

# create_database initializes a NEW AirDB database (it creates the tables).
# Use open_database(cfg) for one that already exists. `overwrite = true` drops
# and recreates the AirDB tables first — handy while experimenting.
db = create_database(cfg; overwrite = true)

# %% 2. Forms -----------------------------------------------------------------
# Every node in a form tree is a form. `form(...)` builds a container — its
# positional arguments are the sequence, its keyword arguments the map — and
# `Form(x)` builds a scalar form from a single leaf.
f = form("widget", n = 1, tags = ["a", "b"])
f[]                       # a container; a nested collection is a nested container
f[:n]                     # Form(1) — indexing yields a form ...
value(f[:n])              # ... and `value` unwraps a scalar form to its leaf: 1
value(f[:tags][1])        # "a" — a nested container's first element

Form("abc")               # a scalar form: just a leaf, no sequence or map
value(Form("abc"))        # "abc"
to_form(5)                # Form(5)
to_form([1, 2, 3])        # Form(1, 2, 3)
form(:a, :b)[1]           # Form(:a) — a leaf read out of a container

# %% 3. Create a volatile form ------------------------------------------------
# A VolatileForm is a form that persists itself. Its arguments are `form`'s.
widget = VolatileForm(db, "widget", n = 1, tags = ["a", "b"])

widget[]                  # the whole form (read from the database on first use)
value(widget[:n])         # 1

# %% 4. Update it -------------------------------------------------------------
# A form may only be changed inside an Air transaction; the change is staged and
# sent to the database when the transaction commits.
@tx widget[:n] = 42
AirDB.sync(db)            # block until the writer has saved everything sent so far
value(widget[:n])         # 42

# %% 5. A commit is atomic and ordered ----------------------------------------
a = VolatileForm(db, kind = "A")
b = VolatileForm(db, kind = "B")
AirDB.sync(db)

@tx begin                 # both updates land in ONE database transaction
    a[:v] = 1
    b[:v] = 2
end
AirDB.sync(db)
(value(a[:v]), value(b[:v]))

# %% 6. Forms can link to other forms -----------------------------------------
parent = VolatileForm(db, name = "parent", child = widget)
AirDB.sync(db)

parent[:child]            # a VolatileForm, not an expanded copy
AirDB.to_JSON(parent[])   # a link is written as "@<uuid>"

# %% 7. Path indexing ---------------------------------------------------------
# Index with a path of keys. A VolatileForm met along the way is transparent
# (its value is used in its place); a final one is returned as-is.
value(parent[:name])      # "parent"
value(parent[:child, :n]) # 42 — the intermediate volatile is transparent
parent[:child]            # the VolatileForm itself (a final volatile is not expanded)

# A vector key (or `:`) fans out into a new form, with volatiles eliminated:
form(a = form(x = 1), b = form(x = 2))[[:a, :b], :x]     # Form(a=1, b=2)
get(parent, :child, :missing, :none)                     # :none (a default for a missing key)

# %% 8. Functional update — setindex ------------------------------------------
# setindex builds a new form and never writes a volatile, so a volatile on the
# path is replaced by its plain, updated value; off-path volatiles are kept.
setindex(parent, 1, :child, :n)   # a plain container; the :child volatile is eliminated
setindex(form(1, 2, 3), 9, 4)     # index length+1 appends: Form(1, 2, 3, 9)

# %% 9. Transactional update — setindex! --------------------------------------
# setindex! walks the path and writes the deepest VolatileForm on it.
@tx parent[:child, :n] = 7        # writes the volatile at :child (reads parent)
AirDB.sync(db)
value(parent[:child, :n])         # 7

# an integer one past the end of a sequence appends
seq = VolatileForm(db, 1, 2)
AirDB.sync(db)
@tx seq[3] = 3
AirDB.sync(db)
seq[]                             # Form(1, 2, 3)

# %% 10. map ------------------------------------------------------------------
# map applies a function to every value, keeping the keys. A volatile *value* is
# handed to the function as the VolatileForm object.
map(v -> v, parent)                                      # same keys; the :child volatile is passed through
map(v -> v isa Int64 ? v + 1 : v, form(1, 2, a = 3))     # Form(2, 3, a=4)

# %% 11. Named forms ----------------------------------------------------------
# A form can be registered under a name, so a project has well-known entry points
# without passing UUIDs around. A name may be a Symbol or a String. The whole name
# table is held in memory as an immutable PDict, in a Volatile — so registering is
# transactional.
root = named_form(db, "root"; create = true, value = form(version = 1))
named_form(db, "root") === root             # true — the same object
named_form(db, :root) === root              # true — Symbol and String agree
named_form(db, "missing"; create = nothing) # nothing — never raises
try
    named_form(db, "missing")               # create = false raises ...
catch e
    e                                       # ... ArgumentError
end

named_forms(db)["root"] === root            # the whole table, as a PDict
name_form!(db, "current", root)             # register a form, overwriting any current one
@tx named_form(db, "settings"; create = true, value = form(theme = "dark"))

# %% 12. Reads are lazy and cached --------------------------------------------
id = widget.id
get_form(db, id) === widget       # the same object while it is in memory
AirDB.isloaded(get_form(db, id))  # true

# %% 13. Persistence across connections ---------------------------------------
close(db)
db = open_database(cfg)           # reopen the existing database
r = get_form(db, id)
AirDB.isloaded(r)                 # false: only the id is known so far
value(r[:n])                      # 7 — the body is loaded from PostgreSQL here
                                  #     (:child *is* widget, so cell 9 changed it)

# %% 14. Concurrent writers ---------------------------------------------------
# (Run with JULIA_NUM_THREADS > 1 to see real contention.)
counter = VolatileForm(db, n = 0)
AirDB.sync(db)
@sync for _ in 1:50
    Threads.@spawn tx(() -> (counter[:n] = value(counter[:n]) + 1))
end
AirDB.sync(db)
value(counter[:n])                # 50 — every increment committed exactly once

# %% 15. A missing form raises ------------------------------------------------
try
    get_form(db, uuid4())[]
catch e
    e                             # FormNotFound
end

# %% 16. Cross-commit batching ------------------------------------------------
# `max_batch > 1` lets the writer accumulate several commits before writing them
# in one database transaction; `sync` (or filling the batch) flushes it. This
# uses its own database so it can start clean.
bdb = create_database(DatabaseConfig(; host = cfg.host, port = cfg.port,
                                       dbname = cfg.dbname, user = cfg.user,
                                       password = cfg.password, max_batch = 3);
                      overwrite = true)
bf = VolatileForm(bdb, n = 0)
AirDB.sync(bdb)
@tx bf[:n] = 1
@tx bf[:n] = 2                    # fewer than max_batch: not written yet ...
value(bf[:n])                     # ... but the in-memory value is already 2
@tx bf[:n] = 3                    # the third fills the batch; it is written at once
AirDB.sync(bdb)
value(bf[:n])                     # 3
close(bdb)

# %% 17. Failure isolation (:isolate) -----------------------------------------
# The default :isolate policy quarantines a batch that cannot be saved: the
# failure is recorded, the committed in-memory value is kept, and unrelated
# reads and writes continue. This cell deliberately breaks a throwaway database.
fdb = create_database(DatabaseConfig(; host = cfg.host, port = cfg.port,
                                       dbname = cfg.dbname, user = cfg.user,
                                       password = cfg.password, retries = 0);
                      overwrite = true)
fv = VolatileForm(fdb, n = 1)
AirDB.sync(fdb)
close(AirDB._writer_conn(fdb))    # break the writer connection
@tx fv[:n] = 2
AirDB.sync(fdb)                   # does not throw
fv[]                              # Form(n=2) — the committed value is kept
failed(fdb, fv.id)                # true — the write is quarantined
first(write_failures(fdb))        # the record: the error and the pending write
clear_write_failure!(fdb, fv.id; retry = true)   # acknowledge and retry
AirDB.sync(fdb)
close(fdb)

# With `failure = :abort`, a database error fails the whole database instead:
# reads and writes raise until it is replaced.
adb = create_database(DatabaseConfig(; host = cfg.host, port = cfg.port,
                                       dbname = cfg.dbname, user = cfg.user,
                                       password = cfg.password,
                                       failure = :abort); overwrite = true)
av = VolatileForm(adb, n = 1)
AirDB.sync(adb)
close(AirDB._writer_conn(adb))
try
    @tx av[:n] = 2
    AirDB.sync(adb)
catch e
    e                             # the write fails
end
adb.failure isa DatabaseError     # true — the database is now failed
close(adb)

# %% 18. Retry policy (:retry) and the on_error hook --------------------------
# With `failure = :retry`, a database error is retried — reconnecting first —
# until a budget (a number of attempts, or an amount of time) is spent. Reads
# block until a retry succeeds. The `on_error` hook runs on each error and can
# decide the policy; it can read the unsaved updates with `pending_writes`.
attempts = Ref(0)
rdb = create_database(DatabaseConfig(; host = cfg.host, port = cfg.port,
                                       dbname = cfg.dbname, user = cfg.user,
                                       password = cfg.password, failure = :retry,
                                       retry_delay = 0.05,
                                       on_error = (db, err) -> (attempts[] += 1; :retry));
                      overwrite = true)
rv = VolatileForm(rdb, n = 1)
AirDB.sync(rdb)
close(AirDB._writer_conn(rdb))    # break the writer connection
@tx rv[:n] = 2                    # the writer reconnects and retries ...
AirDB.sync(rdb)
value(rv[:n])                     # 2 — the write succeeded
attempts[]                        # 1 — the hook was called once
rdb.failure === nothing           # true — the database is healthy
close(rdb)

# %% 19. Clean up -------------------------------------------------------------
close(db)
