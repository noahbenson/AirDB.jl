# Build forms inside functions so their locals are released when the function
# returns; a local in a test scope can otherwise keep a form alive through the
# test machinery and defeat the weak cache.

function _make_parent_child(db)
    child = VolatileForm(db, "child", v = 1)
    parent = VolatileForm(db, "parent", kid = child)
    AirDB.sync(db)
    return (parent.id, child.id)
end

function _write_actor(db; history = true)
    af = ActorForm(db, form(n = 0); history = history)
    send(af) do v
        form(n = value(v[:n]) + 1)
    end
    _waitfor(() -> value(af[][:n]) == 1)
    AirDB.sync(db)
    return af.id
end

function _write_promise(db)
    pf = PromiseForm(db)
    vf = VolatileForm(db, p = pf)     # serialized while undelivered: a row exists
    AirDB.sync(db)
    put!(pf, form(x = 1))
    AirDB.sync(db)
    return pf.id
end

# A form holding a stored extern, returned by id so the live handle can be
# collected and the extern reloaded (unloaded) from its JSON.
function _extern_form(db, id::Symbol)
    ex = construct(get_extern_API(:counter), Form(Symbol(":new")), Form(4); id = id)
    vf = VolatileForm(db, e = ex)
    AirDB.sync(db)
    return vf.id
end

function _make_cycle(db)
    a = VolatileForm(db, "a")
    b = VolatileForm(db, "b")
    AirDB.sync(db)
    tx(() -> (a[:peer] = b))
    tx(() -> (b[:peer] = a))
    AirDB.sync(db)
    return a.id
end

# A graph with live objects reachable from the name "gc-root" and dead ones held
# only by a form that is itself dropped. Returns ids only, so the objects can be
# collected.
function _gc_postgres_graph(db)
    root = named_form(db, "gc-root"; create = true, value = form(a = 1))
    kid = VolatileForm(db, n = 2)
    @tx root[:kid] = kid
    af = ActorForm(db, form(n = 0))
    pf = PromiseForm(db)
    ex = construct(get_extern_API(:counter), Form(Symbol(":new")), Form(1);
                   id = Symbol(":gc-live-extern"))
    @tx begin
        root[:af] = af
        root[:pf] = pf
        root[:ex] = ex
    end
    dead_af = ActorForm(db, form(n = 0))
    dead_pf = PromiseForm(db)
    dead_ex = construct(get_extern_API(:counter), Form(Symbol(":new")), Form(2);
                        id = Symbol(":gc-dead-extern"))
    tmp = VolatileForm(db, af = dead_af, pf = dead_pf, ex = dead_ex)
    AirDB.sync(db)
    @tx root[:a] = 2
    @tx kid[:n] = 3
    AirDB.sync(db)
    return (root.id, kid.id, tmp.id, af.id, pf.id, dead_af.id, dead_pf.id)
end

function _gc_unreachable_named(db)
    vf = named_form(db, "gc-temp"; create = true, value = form(z = 1))
    AirDB.sync(db)
    return vf.id
end

# Owner metadata on every kind, created in one helper so no local survives.
function _metadata_objects(db)
    m = form(owner = "alice")
    vf = VolatileForm(db, a = 1; metadata = m)
    af = ActorForm(db, form(n = 0); metadata = m)
    pf = PromiseForm(db; metadata = m)
    c = construct(get_extern_API(:counter), Form(Symbol(":new")), Form(1);
                  id = Symbol(":pg-meta-ext"), metadata = m)
    holder = VolatileForm(db, e = c, p = pf)     # gives the extern and promise rows
    AirDB.sync(db)
    return (vf.id, af.id, pf.id, holder.id)
end

# Deliver a promise that is never stored anywhere.
function _deliver_only_durable(db)
    pf = PromiseForm(db)
    put!(pf, form(v = 9))
    AirDB.sync(db)
    return pf.id
end

function _fail_only_durable(db)
    pf = PromiseForm(db)
    fail!(pf, form(err = "boom"))
    AirDB.sync(db)
    return pf.id
end

function _pg_stream(db)
    sf = StreamForm(db; maxsize = 3, metadata = form(owner = "alice"))
    put!(sf, form(a = 1))
    put!(sf, form(b = 2))
    close(sf)
    AirDB.sync(db)
    return sf.id
end

function _pg_stream_edited(db)
    sf = StreamForm(db)
    put!(sf, form(x = 1))
    put!(sf, form(x = 2))
    AirDB.sync(db)
    return sf.id
end

_row_count(conn, table, col, id) =
    Int(LibPQ.execute(conn, "SELECT count(*) FROM $table WHERE $col = \$1::uuid",
                      (string(id),))[1, 1])

@testset "VolatileForm persistence" begin
    cfg = _TEST_CFG
    db = create_database(cfg; overwrite = true)
    conn = _connect(cfg)
    try
        @testset "creation and update" begin
            vf = VolatileForm(db, "widget", n = 1)
            AirDB.sync(db)
            @test _current_version(conn, vf.id) == 1
            @test value(vf[:n]) == 1
            @test AirDB.from_JSON(db, _current_payload(conn, vf.id)) == vf[]

            @tx vf[:n] = 5
            AirDB.sync(db)
            @test value(vf[:n]) == 5
            @test _current_version(conn, vf.id) == 2
            @test _history(conn, vf.id) == [(1, 1), (2, 2)]
            @test AirDB.status(db) == (0, nothing)
        end

        @testset "one commit is one database write" begin
            a = VolatileForm(db, "a")
            b = VolatileForm(db, "b")
            AirDB.sync(db)
            @tx begin
                a[:x] = 1
                b[:y] = 2
            end
            AirDB.sync(db)
            ha, hb = _history(conn, a.id), _history(conn, b.id)
            @test length(ha) == 2 && length(hb) == 2
            # both rows of the commit carry the same transaction id
            @test ha[end][2] == hb[end][2]

            # writing one form twice in a commit is a single version bump
            n0 = length(_history(conn, a.id))
            @tx begin
                a[:x] = 10
                a[:x] = 11
            end
            AirDB.sync(db)
            @test length(_history(conn, a.id)) == n0 + 1
            @test value(a[:x]) == 11
        end

        @testset "lazy load and cache identity" begin
            # while a form is alive, its id yields the same object
            vf = VolatileForm(db, "lazy", n = 7)
            AirDB.sync(db)
            @test get_form(db, vf.id) === vf
            @test isloaded(get_form(db, vf.id))

            # with no reference left, the cache releases it and the next lookup
            # creates a fresh, unloaded form that reads its body on first use
            id = _create_and_forget(db, "lazy2", n = 8)
            GC.gc(); GC.gc()
            v2 = get_form(db, id)
            @test !isloaded(v2)
            @test value(v2[:n]) == 8
            @test isloaded(v2)
        end

        @testset "embedded links load lazily" begin
            pid, cid = _make_parent_child(db)
            GC.gc(); GC.gc()

            p = get_form(db, pid)
            @test !isloaded(p)
            f = p[]
            kid = f[:kid]
            @test kid isa VolatileForm && kid.id == cid
            @test !isloaded(kid)          # the link is not expanded until touched
            @test value(kid[:v]) == 1
            @test isloaded(kid)
        end

        @testset "cyclic links" begin
            aid = _make_cycle(db)
            # encoding never expands a link, so a cycle is safe to write
            @test occursin("@", AirDB.to_JSON(get_form(db, aid)[]))
            GC.gc(); GC.gc()
            ra = get_form(db, aid)
            rb = ra[:peer]
            @test rb isa VolatileForm
            @test rb[:peer] === ra        # the cycle is reconstructed through the cache
        end

        @testset "missing form" begin
            @test_throws FormNotFound get_form(db, uuid4())[]
        end

        @testset "extern resources survive JSONB" begin
            # The types are registered in test/externs.jl. The form stores only
            # the type/id reference; the bytes live in the `resources` table.
            c = construct(get_extern_API(:counter), Form(Symbol(":new")), Form(7),
                          id = Symbol(":db-test"))
            vf = VolatileForm(db, cfg = c, n = 1)
            AirDB.sync(db)
            payload = _current_payload(conn, vf.id)
            @test occursin("\"extern\"", payload) && occursin("'counter", payload)
            res = LibPQ.execute(conn, AirDB._SELECT_RESOURCE_SQL, ("counter", ":db-test"))
            @test length(res) == 1
            @test res[1, 1] == UInt8['7']
            # drop the in-memory copy and read it back from the database
            id = vf.id
            vf = nothing; c = nothing
            GC.gc(); GC.gc()
            r = get_form(db, id)[]
            @test r[:cfg] isa FormExtern
            @test value(r[:cfg]) isa CounterData
            @test value(r[:cfg]).n == 7
            # a read-edit updates the resource bytes on the next write
            p = reserve(r[:cfg]) do a; a.call(Form(Symbol(":bump")), form()); end
            @test p[] == Form(8)
            AirDB.sync(db)
            res2 = LibPQ.execute(conn, AirDB._SELECT_RESOURCE_SQL, ("counter", ":db-test"))
            @test res2[1, 1] == UInt8['8']
        end

        @testset "non-finite floats survive JSONB" begin
            # JSONB (like JSON) has no Inf/NaN, so these are stored as marked
            # strings; a bare `Inf` would be rejected by PostgreSQL.
            vf = VolatileForm(db, a = Inf, b = -Inf, c = NaN, z = ComplexF64(Inf, -Inf))
            AirDB.sync(db)
            payload = _current_payload(conn, vf.id)
            @test occursin("\"#inf\"", payload)
            @test occursin("\"#-inf\"", payload)
            @test occursin("\"#nan\"", payload)
            id = vf.id
            vf = nothing
            GC.gc(); GC.gc()
            r = get_form(db, id)[]
            @test value(r[:a]) === Inf
            @test value(r[:b]) === -Inf
            @test isnan(value(r[:c]))
            @test value(r[:z]) == ComplexF64(Inf, -Inf)
        end

        @testset "metadata and history" begin
            # a current-only form stores metadata but never appends history
            m = VolatileForm(db, form(a = 1); metadata = form(v = 1), history = false)
            AirDB.sync(db)
            @test _history(conn, m.id) == []
            @test metadata(m) == form(v = 1)
            @test !history(m)
            @tx m[:a] = 2
            AirDB.sync(db)
            @test _history(conn, m.id) == []
            @tx set_metadata!(m, form(v = 2))
            AirDB.sync(db)
            @test _history(conn, m.id) == []
            @test metadata(m) == form(v = 2)
            # the metadata is persisted and read back
            id = m.id
            m = nothing
            GC.gc(); GC.gc()
            r = get_form(db, id)
            @test metadata(r) == form(v = 2)     # reading metadata loads the row
            @test !history(r)
            @test value(r[][:a]) == 2
            # a normal form still records history
            h = VolatileForm(db, a = 1)
            AirDB.sync(db)
            @tx h[:a] = 2
            AirDB.sync(db)
            @test length(_history(conn, h.id)) == 2
            @test metadata(h) === nothing
            @test history(h)
        end

        @testset "actor and promise forms survive JSONB" begin
            # an actor persists its initial value and every update
            aid = _write_actor(db)
            r = LibPQ.execute(conn,
                "SELECT value, history FROM form_actor_current WHERE actor_id = \$1::uuid",
                (string(aid),))
            @test length(r) == 1
            @test r[1, 1] == "[[], {\":n\": 1}]"
            @test r[1, 2] == true
            h = LibPQ.execute(conn,
                "SELECT count(*) FROM form_actor_history WHERE actor_id = \$1::uuid",
                (string(aid),))
            @test h[1, 1] == 2                  # the initial value and one update
            # a current-only actor keeps no history
            ahid = _write_actor(db; history = false)
            h = LibPQ.execute(conn,
                "SELECT count(*) FROM form_actor_history WHERE actor_id = \$1::uuid",
                (string(ahid),))
            @test h[1, 1] == 0
            # reload the actor in a fresh cache
            GC.gc(); GC.gc()
            ar = get_actor(db, aid)
            @test !isloaded(ar)
            @test ar[] == form(n = 1)
            # an undelivered promise keeps an empty row until delivery
            pf = PromiseForm(db)
            vf = VolatileForm(db, p = pf)
            AirDB.sync(db)
            pid = pf.id
            q = LibPQ.execute(conn,
                "SELECT value FROM form_promise WHERE promise_id = \$1::uuid", (string(pid),))
            @test length(q) == 1
            @test ismissing(q[1, 1])
            put!(pf, form(x = 1))
            AirDB.sync(db)
            q = LibPQ.execute(conn,
                "SELECT value FROM form_promise WHERE promise_id = \$1::uuid", (string(pid),))
            @test q[1, 1] == "[[], {\":x\": 1}]"
            # reload the delivered promise in a fresh cache
            pid2 = _write_promise(db)
            GC.gc(); GC.gc()
            pr = get_promise(db, pid2)
            @test !isloaded(pr)
            @test isready(pr)
            @test pr[] == form(x = 1)
            # a promise delivered before serialization is a link, and its
            # settlement still creates a durable row
            pf2 = PromiseForm(db)
            put!(pf2, form(z = 3))
            vf2 = VolatileForm(db, p = pf2)
            AirDB.sync(db)
            q = LibPQ.execute(conn,
                "SELECT state, value FROM form_promise WHERE promise_id = \$1::uuid",
                (string(pf2.id),))
            @test length(q) == 1
            @test q[1, 1] == "delivered"
            @test q[1, 2] == "[[], {\":z\": 3}]"
            @test AirDB.to_JSON(get_form(db, vf2.id)[]) ==
                  "[[], {\":p\": \"~$(pf2.id)\"}]"
            GC.gc(); GC.gc()
            r2 = get_form(db, vf2.id)[]
            @test r2[:p] isa PromiseForm
            @test r2[:p][] == form(z = 3)
            # a delay serializes as its type and form and loads the same way
            df = DelayForm(:double, Form(3))
            vf3 = VolatileForm(db, d = df)
            AirDB.sync(db)
            dr = get_form(db, vf3.id)[]
            @test dr[:d] isa DelayForm
            @test dr[:d][] == Form(6)
        end

        @testset "promise states, metadata, and metadata-only reads" begin
            # a failure is durable
            fid = _fail_only_durable(db)
            q = LibPQ.execute(conn,
                "SELECT state, error FROM form_promise WHERE promise_id = \$1::uuid",
                (string(fid),))
            @test length(q) == 1
            @test q[1, 1] == "failed"
            @test q[1, 2] == "[[], {\":err\": \"'boom\"}]"
            GC.gc(); GC.gc()
            fr = get_promise(db, fid)
            @test isfailed(fr)
            e = try
                fr[]
                nothing
            catch err
                err
            end
            @test e isa Air.PromiseFailed
            @test e.err == form(err = "boom")
            # a delivery to a never-stored promise is durable (the ensure fix)
            pid = _deliver_only_durable(db)
            q = LibPQ.execute(conn,
                "SELECT state, value FROM form_promise WHERE promise_id = \$1::uuid",
                (string(pid),))
            @test length(q) == 1
            @test q[1, 1] == "delivered"
            @test q[1, 2] == "[[], {\":v\": 9}]"
            GC.gc(); GC.gc()
            @test get_promise(db, pid)[] == form(v = 9)
            # owner metadata survives a reload for every kind
            vid, aid, pfid, hid = _metadata_objects(db)
            m = form(owner = "alice")
            GC.gc(); GC.gc()
            @test metadata(get_form(db, vid)) == m
            @test metadata(get_actor(db, aid)) == m
            @test metadata(get_promise(db, pfid)) == m
            holder = get_form(db, hid)[]
            @test metadata(holder[:e]) == m
            @test metadata(holder[:p]) == m
            # an extern with no row is unmanaged
            u = construct(get_extern_API(:counter), Form(Symbol(":new")), Form(2))
            @test metadata(u) === nothing
            # metadata-only edits reach the database without rewriting payloads
            m2 = form(owner = "bob")
            vf2 = get_form(db, vid)
            af2 = get_actor(db, aid)
            pf2 = get_promise(db, pfid)
            ex2 = get_form(db, hid)[][:e]
            v1 = _current_version(conn, vid)
            @tx set_metadata!(vf2, m2)
            @tx set_metadata!(af2, m2)
            @tx set_metadata!(pf2, m2)
            @tx set_metadata!(ex2, m2)
            AirDB.sync(db)
            @test _current_version(conn, vid) == v1             # no version bump
            @test metadata(get_form(db, vid)) == m2
            @test metadata(get_actor(db, aid)) == m2
            @test metadata(get_promise(db, pfid)) == m2
            @test metadata(get_form(db, hid)[][:e]) == m2
            # a metadata read does not decode the payload
            badid = uuid4()
            LibPQ.execute(conn,
                "INSERT INTO form_current (form_id, version, payload, metadata, history) " *
                "VALUES (\$1::uuid, 1, '\"bogus\"'::jsonb, \$2::jsonb, true)",
                (string(badid), AirDB.to_JSON(form(owner = "dave"))))
            bad = get_form(db, badid)
            @test metadata(bad) == form(owner = "dave")
            @test !isloaded(bad)
            @test_throws ArgumentError bad[]
        end

        @testset "stream forms survive JSONB" begin
            sid = _pg_stream(db)
            q = LibPQ.execute(conn,
                "SELECT maxsize, closed, metadata::text FROM form_stream " *
                "WHERE stream_id = \$1::uuid", (string(sid),))
            @test length(q) == 1
            @test q[1, 1] == 3
            @test q[1, 2] == true
            @test q[1, 3] !== missing
            GC.gc(); GC.gc()
            r = get_stream(db, sid)
            @test !isloaded(r)
            @test snapshot(r) == Form[form(a = 1), form(b = 2)]
            @test maxsize(r) == 3
            @test !isopen(r)
            @test metadata(r) == form(owner = "alice")
            @test take(r) == form(a = 1)
            @test take(r) == form(b = 2)
            @test_throws Air.StreamClosed take(r)
            # a stream edited but never referenced by a stored form persists
            oid = _pg_stream_edited(db)
            GC.gc(); GC.gc()
            @test snapshot(get_stream(db, oid)) == Form[form(x = 1), form(x = 2)]
            # a staged put inside a committing transaction reaches the database
            sf2 = StreamForm(db)
            @tx put!(sf2, form(w = 9))
            AirDB.sync(db)
            q = LibPQ.execute(conn,
                "SELECT items::text FROM form_stream WHERE stream_id = \$1::uuid",
                (string(sf2.id),))
            @test length(q) == 1
            @test occursin(":w", string(q[1, 1]))
            # an aborted transaction discards its staged put
            sf3 = StreamForm(db)
            AirDB.sync(db)
            @test_throws ErrorException @tx begin
                put!(sf3, form(z = 1))
                error("abort")
            end
            AirDB.sync(db)
            q = LibPQ.execute(conn,
                "SELECT items::text FROM form_stream WHERE stream_id = \$1::uuid",
                (string(sf3.id),))
            @test length(q) == 1
            @test String(q[1, 1]) == "[[], {}]"
        end

        @testset "garbage collection" begin
            rid, kid, tid, afid, pfid, dafid, dpfid = _gc_postgres_graph(db)
            GC.gc(); GC.gc()
            # earlier testsets left their own unreachable rows in this database,
            # so the totals are lower bounds; the per-object checks below are exact
            dry = gc!(db; dry_run = true)
            @test dry.swept_forms >= 1
            @test dry.swept_actors >= 1
            @test dry.swept_promises >= 1
            @test dry.swept_resources >= 1
            @test _row_count(conn, "form_current", "form_id", tid) == 1  # nothing deleted
            st = gc!(db)
            @test st.swept_forms >= 1
            # dead rows are gone, with their history
            @test _row_count(conn, "form_current", "form_id", tid) == 0
            @test _row_count(conn, "form_history", "form_id", tid) == 0
            @test _row_count(conn, "form_actor_current", "actor_id", dafid) == 0
            @test _row_count(conn, "form_actor_history", "actor_id", dafid) == 0
            @test _row_count(conn, "form_promise", "promise_id", dpfid) == 0
            @test Int(LibPQ.execute(conn,
                "SELECT count(*) FROM resources WHERE id = ':gc-dead-extern'")[1, 1]) == 0
            # live rows and their history survive
            @test _row_count(conn, "form_current", "form_id", rid) == 1
            @test _row_count(conn, "form_history", "form_id", rid) >= 2
            @test _row_count(conn, "form_current", "form_id", kid) == 1
            @test _row_count(conn, "form_actor_current", "actor_id", afid) == 1
            @test _row_count(conn, "form_promise", "promise_id", pfid) == 1
            @test Int(LibPQ.execute(conn,
                "SELECT count(*) FROM resources WHERE id = ':gc-live-extern'")[1, 1]) == 1
            # the live objects still load and read
            r = get_form(db, rid)[]
            @test r isa FormContainer
            @test value(r[:kid][:n]) == 3
            @test get_actor(db, afid)[] == form(n = 0)
            @test !isready(get_promise(db, pfid))
            @test r[:ex] isa FormExtern
            @test value(r[:ex]) isa CounterData
            # deleting a name releases its form
            id2 = _gc_unreachable_named(db)
            GC.gc(); GC.gc()
            @test _row_count(conn, "form_current", "form_id", id2) == 1
            delete_name!(db, "gc-temp")
            AirDB.sync(db)
            GC.gc(); GC.gc()
            @test gc!(db).swept_forms >= 1
            @test _row_count(conn, "form_current", "form_id", id2) == 0
            delete_name!(db, "gc-root")
            AirDB.sync(db)
        end

        @testset "concurrent writers" begin
            vf = VolatileForm(db, n = 0)
            AirDB.sync(db)
            v0 = _current_version(conn, vf.id)
            n = 20
            @sync for _ in 1:n
                Threads.@spawn tx(() -> (vf[:n] = value(vf[:n]) + 1))
            end
            AirDB.sync(db)
            @test value(vf[:n]) == n
            # every successful commit added exactly one version, and the versions
            # are appended in commit order
            @test _current_version(conn, vf.id) == v0 + n
            h = _history(conn, vf.id)
            @test issorted([v for (v, _) in h])
            @test issorted([t for (_, t) in h])
        end

        @testset "cache identity under concurrency" begin
            id = _create_and_forget(db, "shared", v = 1)
            results = Vector{VolatileForm}(undef, 16)
            @sync for i in 1:16
                Threads.@spawn (results[i] = get_form(db, id))
            end
            @test all(r -> r === results[1], results)
        end

        @testset "path indexing across volatiles" begin
            a = VolatileForm(db, x = 0)
            b = VolatileForm(db, x = 1)
            f = form(a = a, b = b)

            # a final volatile is returned as-is; an intermediate one is transparent
            @test f[:a] === a
            @test value(f[:a, :x]) == 0
            @test f[[:a, :b], :x] == form(a = 0, b = 1)
            @test f[[:a, :b], [:x]] == form(a = form(x = 0), b = form(x = 1))

            # functional setindex eliminates a volatile on the path, keeps off-path links
            r = setindex(f, 99, :a, :x)
            @test r[:a] isa FormContainer && value(r[:a][:x]) == 99
            @test r[:b] === b                     # untouched, still a link

            # setindex! writes the deepest volatile and only reads the others
            @tx f[:a, :x] = 5
            AirDB.sync(db)
            @test value(a[:x]) == 5
            @test value(b[:x]) == 1

            # update! is setindex! with a function, same target rules
            @tx update!(f, v -> value(v) + 10, :a, :x)
            AirDB.sync(db)
            @test value(a[:x]) == 15
            @test_throws ArgumentError update!(form(a = form(x = 1)), v -> v, :a, :x)

            # setting the final key replaces the final volatile's value
            @tx f[:a] = form(x = 42)
            AirDB.sync(db)
            @test a[] == form(x = 42)

            # a path with no volatile cannot be mutated
            @test_throws ArgumentError setindex!(form(a = form(x = 1)), 5, :a, :x)

            # map hands volatile values to the function
            seen = Ref(0)
            map(v -> (v isa VolatileForm && (seen[] += 1); v), f)
            @test seen[] == 2

            # append through a volatile
            c = VolatileForm(db, 1, 2)
            AirDB.sync(db)
            @tx c[3] = 3
            AirDB.sync(db)
            @test c[] == form(1, 2, 3)

            # setindex! fans out across a list, writing each branch's target
            g1 = VolatileForm(db, x = 0)
            g2 = VolatileForm(db, x = 0)
            h = form(a = g1, b = g2)
            AirDB.sync(db)
            @tx h[[:a, :b], :x] = 9
            AirDB.sync(db)
            @test value(g1[:x]) == 9
            @test value(g2[:x]) == 9
        end

        @testset "a rehydrated extern can be written back" begin
            # a helper so the locals are gone before the reload
            vid = _extern_form(db, Symbol(":rehydrate-ext"))
            GC.gc(); GC.gc()
            r = get_form(db, vid)[]
            @test r[:e] isa FormExtern
            # rehydrated from the stored JSON, so its data is not in memory
            @test !r[:e].handle.loaded
            # copying it into a new form used to crash the writer, which tried to
            # re-serialize a handle with no data
            vf2 = VolatileForm(db, e = r[:e])
            AirDB.sync(db)
            v = value(get_form(db, vf2.id)[][:e])
            @test v isa CounterData
            @test v.n == 4
        end

        @testset "metadata edits are transactional" begin
            m1 = form(owner = "kim")
            m2 = form(owner = "lee")
            vf = VolatileForm(db, a = 1; metadata = m1)
            sf = StreamForm(db; metadata = m1)
            AirDB.sync(db)
            # a committed edit reaches the row — including a stream's
            @tx set_metadata!(sf, m2)
            AirDB.sync(db)
            q = LibPQ.execute(conn,
                "SELECT metadata::text FROM form_stream WHERE stream_id = \$1::uuid",
                (string(sf.id),))
            @test AirDB.from_JSON(String(q[1, 1])) == m2
            # read-your-writes
            @test (@tx begin
                set_metadata!(vf, m2)
                metadata(vf)
            end) == m2
            AirDB.sync(db)
            # an aborted edit changes neither memory nor the row
            try
                @tx begin
                    set_metadata!(vf, m1)
                    error("abort")
                end
            catch
            end
            @test metadata(vf) == m2
            AirDB.sync(db)
            q = LibPQ.execute(conn,
                "SELECT metadata::text FROM form_current WHERE form_id = \$1::uuid",
                (string(vf.id),))
            @test AirDB.from_JSON(String(q[1, 1])) == m2
        end

        @testset "numeric tower leaves survive JSONB" begin
            x = setprecision(256) do
                parse(BigFloat, "1.1")
            end
            z = Complex{BigFloat}(parse(BigFloat, "1.5"), parse(BigFloat, "-2.5"))
            vf = VolatileForm(db, b = big(2)^100, br = Rational{BigInt}(big(2)^100, 3),
                              r = 1 // 3, f = x, z = z)
            AirDB.sync(db)
            payload = _current_payload(conn, vf.id)
            @test occursin("\"#big:", payload)
            @test occursin("\"#bigrat:", payload)
            @test occursin("\"#rat:1/3\"", payload)
            @test occursin("\"#bigfloat:256:", payload)
            r = get_form(db, vf.id)[]
            @test value(r[:b]) isa BigInt && value(r[:b]) == big(2)^100
            @test value(r[:br]) isa Rational{BigInt}
            @test value(r[:br]) == Rational{BigInt}(big(2)^100, 3)
            @test value(r[:r]) === 1 // 3
            @test value(r[:f]) isa BigFloat
            @test precision(value(r[:f])) == 256
            @test value(r[:f]) == x
            @test value(r[:z]) isa Complex{BigFloat}
            @test value(r[:z]) == z
        end
    finally
        close(conn)
        close(db)
    end
end
