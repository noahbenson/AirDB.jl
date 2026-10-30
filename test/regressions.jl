# Regressions from the pre-0.1.0 review: writing back a rehydrated extern,
# transactional metadata, delay forms that hide their references from the
# in-memory collector, and the reachability of promise rows.

# A delay type used only here: its serialization form names other objects.
AirDB.register_delay(:regression_identity, f -> f)

# Built in functions so no test-scope local keeps a form alive past its test.
# The in-memory store keeps a form tree alive, and the tree holds the objects it
# names, so a full collection can take two sweeps.
function _gc_promise_form(db)
    vf = VolatileForm(db, p = PromiseForm(db))
    pf = vf[][:p]
    put!(pf, form(v = 1))
    AirDB.sync(db)
    return (vf.id, pf.id, pf)
end
function _gc_promise_id(db)
    _, pid, _ = _gc_promise_form(db)
    return pid
end

@testset "regressions" begin
    @testset "a rehydrated extern can be written back" begin
        db = MemoryDatabase()
        c = construct(get_extern_API(:counter), Form(Symbol(":new")), Form(6);
                      id = Symbol(":copy-ext"))
        vf = VolatileForm(db, e = c)
        AirDB.sync(db)
        vid = vf.id
        vf = nothing
        c = nothing
        GC.gc(); GC.gc()
        # the in-memory store keeps the form tree, so the handle stays live; a
        # form that names it writes back cleanly (the unloaded case is the
        # PostgreSQL one, tested in `persist.jl`)
        r = get_form(db, vid)[]
        @test r[:e] isa FormExtern
        vf2 = VolatileForm(db, e = r[:e])
        AirDB.sync(db)
        @test haskey(db.resources, (:counter, Symbol(":copy-ext")))
        # and the bytes still load
        @test value(get_form(db, vf2.id)[][:e]) isa CounterData
        close(db)
    end

    @testset "metadata edits are transactional" begin
        db = MemoryDatabase()
        m1 = form(owner = "alice")
        m2 = form(owner = "bob")
        vf = VolatileForm(db, a = 1; metadata = m1)
        af = ActorForm(db, form(n = 0); metadata = m1)
        pf = PromiseForm(db; metadata = m1)
        sf = StreamForm(db; metadata = m1)
        c = construct(get_extern_API(:counter), Form(Symbol(":new")), Form(1);
                      id = Symbol(":meta-tx-ext"), metadata = m1)
        VolatileForm(db, e = c)                 # gives the extern a row
        AirDB.sync(db)
        kinds = Any[vf, af, pf, sf, c]
        # the writing transaction reads its own edit, and the next reader sees a
        # committed edit at once — for every kind, with no `sync` in between
        for x in kinds
            seen = @tx begin
                set_metadata!(x, m2)
                metadata(x)
            end
            @test seen == m2
            @test metadata(x) == m2
        end
        for x in kinds
            @test metadata(x) == m2
        end
        AirDB.sync(db)
        for x in kinds
            @test metadata(x) == m2
        end
        # an aborted transaction changes neither memory nor the database
        for x in kinds
            @test_throws ErrorException @tx begin
                set_metadata!(x, m1)
                error("abort")
            end
            @test metadata(x) == m2
        end
        AirDB.sync(db)
        for x in kinds
            @test metadata(x) == m2
        end
        close(db)
    end

    @testset "delay forms keep their references" begin
        db = MemoryDatabase()
        pf = PromiseForm(db)
        sf = StreamForm(db)
        c = construct(get_extern_API(:counter), Form(Symbol(":new")), Form(7);
                      id = Symbol(":delay-ext"))
        df = DelayForm(:regression_identity, form(p = pf, s = sf, e = c))
        VolatileForm(db, d = df)
        AirDB.sync(db)
        # the in-memory database never encodes a form, so it walks the tree; a
        # delay's serialization form is part of that tree
        @test haskey(db.promisevals, pf.id)
        @test haskey(db.streamvals, sf.id)
        @test haskey(db.resources, (:counter, Symbol(":delay-ext")))
        close(db)
    end

    @testset "promise rows follow reachability" begin
        # a live handle keeps the row
        db = MemoryDatabase()
        _, pid, pf = _gc_promise_form(db)
        GC.gc(); GC.gc()
        @test gc!(db).swept_promises == 0
        @test haskey(db.promisevals, pid)
        @test isready(pf)
        close(db)
        # once nothing references it, the row is swept. The in-memory form tree
        # itself keeps the promise alive until the form's row is swept, so this
        # takes two passes: the first drops the form, the second the promise.
        db2 = MemoryDatabase()
        pid2 = _gc_promise_id(db2)
        GC.gc(); GC.gc()
        gc!(db2)
        GC.gc(); GC.gc()
        @test gc!(db2).swept_promises >= 1
        @test !haskey(db2.promisevals, pid2)
        close(db2)
    end
end
