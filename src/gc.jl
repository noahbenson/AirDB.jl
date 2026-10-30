################################################################################
# gc.jl
#
# Garbage collection for database-backed objects. The persistent graph is:
#
#   form_current      --@--> volatile,  --!--> actor,  --~--> promise, extern refs
#   form_actor_current -- same links
#   form_promise      -- same links (in the delivered value)
#   resources         -- no links (raw bytes)
#
# The only persistent roots are the names in `form_name`; the other roots are the
# live in-memory objects (the weak caches and the extern registry). Everything
# else is reachable only through links.
#
# The sweep runs as one job on the writer task. That task is sequential, so
# every earlier write is already applied and every later write queues behind the
# sweep: the marking pass sees a consistent snapshot without any extra locking,
# and reads continue on the read pool. A per-database `gclock` closes the one
# remaining race — a row being loaded (made live) by another thread between root
# collection and sweeping — by making loads and `gc!` mutually exclusive.
#
# Link extraction is exact rather than heuristic: in the stored JSON every link
# string begins with `@`, `!`, or `~`, while user strings begin with `'` and
# symbols with `:`, so a structural scan cannot mistake one for the other.
#
# MIT License
# Copyright (c) 2020-2026 Noah C. Benson

"""
    GCStats

What a [`gc!`](@ref) sweep scanned and removed, per object kind, and how long it
took.
"""
struct GCStats
    scanned_forms::Int
    scanned_actors::Int
    scanned_promises::Int
    scanned_streams::Int
    scanned_resources::Int
    swept_forms::Int
    swept_actors::Int
    swept_promises::Int
    swept_streams::Int
    swept_resources::Int
    seconds::Float64
end

function Base.show(io::IO, s::GCStats)
    print(io, "GCStats(scanned: ", s.scanned_forms, " forms, ", s.scanned_actors,
          " actors, ", s.scanned_promises, " promises, ", s.scanned_streams,
          " streams, ", s.scanned_resources, " resources; swept: ", s.swept_forms,
          " forms, ", s.swept_actors, " actors, ", s.swept_promises,
          " promises, ", s.swept_streams, " streams, ", s.swept_resources,
          " resources; ", s.seconds, "s)")
end

# A link is `(kind, id)`, where `kind` is `:volatile`, `:actor`, `:promise`, or
# `:extern` and the id is a UUID or a `(type, id)` pair of Symbols.
const _Link = Tuple{Symbol,Any}

# ---- link extraction ---------------------------------------------------------

# Collect the links in a stored payload, without resolving anything. This mirrors
# `_parsevalue!`, but records marker-tagged strings instead of resolving them, and
# recognizes `{"extern", "id"}` objects by their keys (whose order PostgreSQL may
# have changed).
function _collect_links!(out::Vector{_Link}, s::AbstractString)
    r = _JSONReader(s)
    _scanvalue!(out, r)
    _skipws!(r)
    _atend(r) || _jsonfail(r, "trailing data in a payload")
    return out
end

function _scanvalue!(out::Vector{_Link}, r::_JSONReader)
    _skipws!(r)
    _atend(r) && _jsonfail(r, "unexpected end of a payload")
    c = r.b[r.i]
    if c == _BYTE_QUOTE
        _scanmarker!(out, _parsestring!(r))
    elseif c == _BYTE_LBRACKET
        _scanarray!(out, r)
    elseif c == _BYTE_LBRACE
        _scanobject!(out, r)
    elseif c == UInt8('n')
        _literal!(r, "null", nothing)
    elseif c == UInt8('t')
        _literal!(r, "true", true)
    elseif c == UInt8('f')
        _literal!(r, "false", false)
    else
        _skipnumber!(r)
    end
    return nothing
end

# Numbers carry no links. Skip one without building its value: the form decoder
# is what must parse it, and a hand-written payload with a huge integer should
# not make the link scan allocate a huge `BigInt`.
function _skipnumber!(r::_JSONReader)
    _skipws!(r)
    b = r.b
    n = length(b)
    start = r.i
    i = r.i
    while i <= n && (UInt8('0') <= b[i] <= UInt8('9') ||
                     b[i] == UInt8('-') || b[i] == UInt8('+') ||
                     b[i] == UInt8('.') || b[i] == UInt8('e') || b[i] == UInt8('E'))
        i += 1
    end
    (i == start) && _jsonfail(r, "expected a number")
    r.i = i
    return nothing
end

function _scanmarker!(out::Vector{_Link}, text::AbstractString)
    isempty(text) && return nothing
    m = text[1]
    (m == '@' || m == '!' || m == '~' || m == '&') || return nothing
    id = try
        UUID(SubString(text, nextind(text, 1)))
    catch
        return nothing                     # not a link the writer produces
    end
    kind = m == '@' ? :volatile : m == '!' ? :actor : m == '~' ? :promise : :stream
    push!(out, (kind, id))
    return nothing
end

function _scanarray!(out::Vector{_Link}, r::_JSONReader)
    _expect!(r, _BYTE_LBRACKET)
    _skipws!(r)
    if !_atend(r) && r.b[r.i] == _BYTE_RBRACKET
        r.i += 1
        return nothing
    end
    while true
        _scanvalue!(out, r)
        _skipws!(r)
        _atend(r) && _jsonfail(r, "unterminated array in a payload")
        c = r.b[r.i]
        r.i += 1
        (c == _BYTE_RBRACKET) && return nothing
        (c == _BYTE_COMMA) || _jsonfail(r, "expected ',' or ']' in a payload")
    end
end

function _scanobject!(out::Vector{_Link}, r::_JSONReader)
    _expect!(r, _BYTE_LBRACE)
    exttype = nothing
    extid = nothing
    _skipws!(r)
    if !_atend(r) && r.b[r.i] == _BYTE_RBRACE
        r.i += 1
        return nothing
    end
    while true
        _skipws!(r)
        key = _parsestring!(r)
        _expect!(r, _BYTE_COLON)
        _skipws!(r)
        if !_atend(r) && r.b[r.i] == _BYTE_QUOTE
            raw = _parsestring!(r)
            if key == "extern"
                exttype = startswith(raw, "'") ?
                    Symbol(SubString(raw, nextind(raw, 1))) : nothing
            elseif key == "id"
                extid = startswith(raw, ":") ?
                    Symbol(SubString(raw, nextind(raw, 1))) : nothing
            else
                _scanmarker!(out, raw)     # an ordinary string-valued map entry
            end
        else
            _scanvalue!(out, r)            # a nested array/object/number
        end
        _skipws!(r)
        _atend(r) && _jsonfail(r, "unterminated object in a payload")
        c = r.b[r.i]
        r.i += 1
        if c == _BYTE_RBRACE
            break
        end
        (c == _BYTE_COMMA) || _jsonfail(r, "expected ',' or '}' in a payload")
    end
    if exttype !== nothing && extid !== nothing
        push!(out, (:extern, (exttype, extid)))
    end
    return nothing
end

# The in-memory equivalent, used by `MemoryDatabase`, which stores form trees
# rather than payloads.
_collect_form_links!(out::Vector{_Link}, ::Any) = out
function _collect_form_links!(out::Vector{_Link}, fc::FormContainer)
    for x in fc.seq
        _collect_form_links!(out, x)
    end
    for (_, v) in fc.map
        _collect_form_links!(out, v)
    end
    return out
end
_collect_form_links!(out::Vector{_Link}, vf::VolatileForm) =
    (push!(out, (:volatile, vf.id)); out)
_collect_form_links!(out::Vector{_Link}, af::ActorForm) =
    (push!(out, (:actor, af.id)); out)
_collect_form_links!(out::Vector{_Link}, pf::PromiseForm) =
    (push!(out, (:promise, pf.id)); out)
_collect_form_links!(out::Vector{_Link}, sf::StreamForm) =
    (push!(out, (:stream, sf.id)); out)
function _collect_form_links!(out::Vector{_Link}, fe::FormExtern)
    _storable(fe.handle) &&
        push!(out, (:extern, (fe.handle.type, fe.handle.id::Symbol)))
    return out
end
function _collect_form_links!(out::Vector{_Link}, df::DelayForm)
    _collect_form_links!(out, df.form)
    return out
end

# ---- marking -----------------------------------------------------------------

function _gc_mark(roots::Vector{_Link}, links::Dict{Tuple{Symbol,Any},Vector{_Link}})
    marked = Set{_Link}()
    stack = copy(roots)
    while !isempty(stack)
        key = pop!(stack)
        (key in marked) && continue
        push!(marked, key)
        for l in get(links, key, ())
            (l in marked) || push!(stack, l)
        end
    end
    return marked
end

# ---- the public sweep --------------------------------------------------------

"""
    gc!(db; dry_run = false, batch = 1000) -> GCStats

Sweeps unreachable database objects. The roots are the named forms (`form_name`)
and every live in-memory object (`VolatileForm`, `ActorForm`, `PromiseForm`, and
extern handle), so an object referenced only from a live handle survives. The
sweep removes unreachable rows from `form_current`, `form_actor_current`,
`form_promise`, and `resources`, and deletes the history rows of the swept
objects; live objects keep their full history.

The sweep runs as one job on the database's writer task, so it sees a
consistent snapshot and blocks only writes (reads continue). Object loading is
serialized with it, so a row cannot be swept while it is being loaded. Names are
never removed here; use [`delete_name!`](@ref) to release one.

`dry_run = true` reports what would be swept without deleting anything.

`MemoryDatabase` implements the same sweep over its in-memory stores.
"""
function gc!(db::AbstractDatabase; dry_run::Bool = false, batch::Int = 1000)
    _check_open(db)
    batch > 0 || throw(ArgumentError("batch must be positive"))
    return _gc!(db, dry_run, batch)
end

function _gc!(db::Database, dry_run::Bool, batch::Int)
    _check_health(db)
    t0 = time()
    return _queue_gc!(db, dry_run, batch, t0)
end

function _gc_database!(db::Database, conn, dry_run::Bool, batch::Int, t0)
    lock(db.gclock)
    try
        roots = _gc_roots(db, conn)
        links = Dict{Tuple{Symbol,Any},Vector{_Link}}()
        ids = _gc_scan!(links, conn, batch)
        marked = _gc_mark(roots, links)
        swept = _gc_sweep!(conn, ids, marked, dry_run, batch)
        return GCStats(length(ids[:volatile]), length(ids[:actor]),
                       length(ids[:promise]), length(ids[:stream]),
                       length(ids[:extern]),
                       swept[:volatile], swept[:actor], swept[:promise],
                       swept[:stream], swept[:extern],
                       round(time() - t0, digits = 3))
    finally
        unlock(db.gclock)
    end
end

function _gc_roots(db::Database, conn)
    roots = _Link[]
    for row in LibPQ.execute(conn, "SELECT form_id::text FROM form_name")
        push!(roots, (:volatile, UUID(row[1])))
    end
    lock(db.cachelock)
    try
        for (cache, kind) in ((db.cache, :volatile), (db.actorcache, :actor),
                              (db.promisecache, :promise), (db.streamcache, :stream))
            for (id, wr) in cache
                wr.value === nothing || push!(roots, (kind, id))
            end
        end
    finally
        unlock(db.cachelock)
    end
    lock(_EXTERN_HANDLES_LOCK)
    try
        for ((t, i), wr) in _EXTERN_HANDLES
            wr.value === nothing || push!(roots, (:extern, (t, i)))
        end
    finally
        unlock(_EXTERN_HANDLES_LOCK)
    end
    return roots
end

# Scan every payload, metadata blob, and error form, recording each object's
# links and every id that exists. Links inside metadata or an error form keep
# their targets alive.
function _gc_scan!(links, conn, batch)
    ids = Dict{Symbol,Vector{Any}}(:volatile => Any[], :actor => Any[],
                                   :promise => Any[], :stream => Any[],
                                   :extern => Any[])
    _gc_scan_table!(links, ids, conn, "form_current", "form_id",
                    (:payload, :metadata), :volatile, batch)
    _gc_scan_table!(links, ids, conn, "form_actor_current", "actor_id",
                    (:value, :metadata), :actor, batch)
    _gc_scan_table!(links, ids, conn, "form_promise", "promise_id",
                    (:value, :error, :metadata), :promise, batch)
    _gc_scan_table!(links, ids, conn, "form_stream", "stream_id",
                    (:items, :metadata), :stream, batch)
    for row in LibPQ.execute(conn, "SELECT type, id, metadata::text FROM resources")
        pair = (Symbol(row[1]), Symbol(row[2]))
        push!(ids[:extern], pair)
        meta = row[3]
        if meta !== nothing && !ismissing(meta)
            out = get!(() -> _Link[], links, (:extern, pair))
            _collect_links!(out, String(meta))
        end
    end
    return ids
end

function _gc_scan_table!(links, ids, conn, table, idcol, valcols::Tuple, kind, batch)
    cols = join(("$(c)::text" for c in valcols), ", ")
    lastid = ""
    while true
        r = LibPQ.execute(conn,
            "SELECT $idcol::text, $cols FROM $table " *
            "WHERE $idcol::text > \$1 ORDER BY $idcol::text LIMIT \$2",
            (lastid, batch))
        isempty(r) && break
        for i in 1:length(r)
            idtext = r[i, 1]
            id = UUID(idtext)
            push!(ids[kind], id)
            out = get!(() -> _Link[], links, (kind, id))
            for j in 2:(length(valcols) + 1)
                payload = r[i, j]
                (payload === nothing || ismissing(payload)) && continue
                _collect_links!(out, String(payload))
            end
            lastid = idtext
        end
    end
    return nothing
end

function _gc_sweep!(conn, ids, marked, dry_run::Bool, batch)
    dead = Dict{Symbol,Vector{Any}}()
    for kind in (:volatile, :actor, :promise, :stream)
        dead[kind] = Any[id for id in ids[kind] if !((kind, id) in marked)]
    end
    dead[:extern] = Any[p for p in ids[:extern] if !((:extern, p) in marked)]
    if !dry_run
        _delete_uuids!(conn, "form_current", "form_id", dead[:volatile], batch)
        _delete_uuids!(conn, "form_history", "form_id", dead[:volatile], batch)
        _delete_uuids!(conn, "form_actor_current", "actor_id", dead[:actor], batch)
        _delete_uuids!(conn, "form_actor_history", "actor_id", dead[:actor], batch)
        _delete_uuids!(conn, "form_promise", "promise_id", dead[:promise], batch)
        _delete_uuids!(conn, "form_stream", "stream_id", dead[:stream], batch)
        _delete_resources!(conn, dead[:extern], batch)
    end
    return Dict{Symbol,Int}(kind => length(v) for (kind, v) in dead)
end

function _delete_uuids!(conn, table, col, ids, batch)
    isempty(ids) && return nothing
    for chunk in Iterators.partition(ids, batch)
        ph = join(("\$" * string(i) * "::uuid" for i in 1:length(chunk)), ", ")
        LibPQ.execute(conn, "DELETE FROM $table WHERE $col IN ($ph)",
                      Tuple(string(x) for x in chunk))
    end
    return nothing
end

function _delete_resources!(conn, pairs, batch)
    isempty(pairs) && return nothing
    for chunk in Iterators.partition(pairs, batch)
        ph = String[]
        params = Any[]
        for (t, i) in chunk
            n = length(params)
            push!(ph, "(\$" * string(n + 1) * ", \$" * string(n + 2) * ")")
            push!(params, string(t))
            push!(params, string(i))
        end
        LibPQ.execute(conn,
            "DELETE FROM resources WHERE (type, id) IN (" * join(ph, ", ") * ")",
            Tuple(params))
    end
    return nothing
end

# ---- the in-memory sweep -----------------------------------------------------

function _gc!(db::MemoryDatabase, dry_run::Bool, batch::Int)
    t0 = time()
    lock(db.gclock)
    try
        lock(db.storelock)
        try
            roots = _Link[]
            for id in values(db.nameids)
                push!(roots, (:volatile, id))
            end
            lock(db.cachelock)
            try
                for (cache, kind) in ((db.cache, :volatile), (db.actorcache, :actor),
                                      (db.promisecache, :promise),
                                      (db.streamcache, :stream))
                    for (id, wr) in cache
                        wr.value === nothing || push!(roots, (kind, id))
                    end
                end
            finally
                unlock(db.cachelock)
            end
            lock(_EXTERN_HANDLES_LOCK)
            try
                for ((t, i), wr) in _EXTERN_HANDLES
                    wr.value === nothing || push!(roots, (:extern, (t, i)))
                end
            finally
                unlock(_EXTERN_HANDLES_LOCK)
            end
            links = Dict{Tuple{Symbol,Any},Vector{_Link}}()
            for (id, v) in db.store
                out = _Link[]
                _collect_form_links!(out, v[1])
                v[2] === nothing || _collect_form_links!(out, v[2])
                links[(:volatile, id)] = out
            end
            for (id, v) in db.actorvals
                out = _Link[]
                _collect_form_links!(out, v[1])
                v[3] === nothing || _collect_form_links!(out, v[3])
                links[(:actor, id)] = out
            end
            for (id, rec) in db.promisevals
                out = _Link[]
                rec.value === nothing || _collect_form_links!(out, rec.value)
                rec.error === nothing || _collect_form_links!(out, rec.error)
                rec.metadata === nothing || _collect_form_links!(out, rec.metadata)
                links[(:promise, id)] = out
            end
            for (id, v) in db.streamvals
                out = _Link[]
                for x in v[1]
                    _collect_form_links!(out, x)
                end
                v[4] === nothing || _collect_form_links!(out, v[4])
                links[(:stream, id)] = out
            end
            for (key, v) in db.resources
                v[2] === nothing && continue
                out = _Link[]
                _collect_form_links!(out, v[2])
                links[(:extern, key)] = out
            end
            marked = _gc_mark(roots, links)
            ids = Dict(:volatile => Any[keys(db.store)...],
                       :actor => Any[keys(db.actorvals)...],
                       :promise => Any[keys(db.promisevals)...],
                       :stream => Any[keys(db.streamvals)...],
                       :extern => Any[keys(db.resources)...])
            dead = Dict{Symbol,Vector{Any}}()
            for kind in (:volatile, :actor, :promise, :stream)
                dead[kind] = Any[id for id in ids[kind] if !((kind, id) in marked)]
            end
            dead[:extern] = Any[p for p in ids[:extern] if !((:extern, p) in marked)]
            if !dry_run
                for id in dead[:volatile]
                    delete!(db.store, id)
                end
                for id in dead[:actor]
                    delete!(db.actorvals, id)
                end
                for id in dead[:promise]
                    delete!(db.promisevals, id)
                end
                for id in dead[:stream]
                    delete!(db.streamvals, id)
                end
                for p in dead[:extern]
                    delete!(db.resources, p)
                end
            end
            return GCStats(length(ids[:volatile]), length(ids[:actor]),
                           length(ids[:promise]), length(ids[:stream]),
                           length(ids[:extern]),
                           length(dead[:volatile]), length(dead[:actor]),
                           length(dead[:promise]), length(dead[:stream]),
                           length(dead[:extern]),
                           round(time() - t0, digits = 3))
        finally
            unlock(db.storelock)
        end
    finally
        unlock(db.gclock)
    end
end

export gc!, GCStats
