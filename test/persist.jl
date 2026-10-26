# Build forms inside functions so their locals are released when the function
# returns; a local in a test scope can otherwise keep a form alive through the
# test machinery and defeat the weak cache.

function _make_parent_child(db)
    child = VolatileForm(db, "child", v = 1)
    parent = VolatileForm(db, "parent", kid = child)
    AirDB.sync(db)
    return (parent.id, child.id)
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
    finally
        close(conn)
        close(db)
    end
end
