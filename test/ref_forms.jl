# Actor, promise, and delay forms: the in-memory and codec behaviour.

function _waitfor(f; timeout = 5.0)
    t0 = time()
    while !f()
        time() - t0 > timeout && error("timed out waiting for a condition")
        sleep(0.005)
    end
    return nothing
end

function _actor_to_forget(db)
    af = ActorForm(db, form(n = 5))
    AirDB.sync(db)
    return af.id
end

function _make_failed_promise(db)
    pf = PromiseForm(db)
    fail!(pf, form(err = :boom))
    AirDB.sync(db)
    return pf.id
end

function _metadata_form(db)
    vf = VolatileForm(db, a = 1; metadata = form(owner = "carol"))
    AirDB.sync(db)
    return vf.id
end

function _deliver_only(db)
    pf = PromiseForm(db)
    put!(pf, form(v = 9))
    AirDB.sync(db)
    return pf.id
end

@testset "actor, promise, and delay forms" begin
    @testset "actors" begin
        db = MemoryDatabase()
        af = ActorForm(db, form(n = 0))
        @test af isa Form
        @test af isa AirDB.FormNode
        @test af[] == form(n = 0)
        @test af == af
        @test AirDB.to_JSON(af) == "\"!$(af.id)\""
        send(af) do v
            form(n = value(v[:n]) + 1)
        end
        _waitfor(() -> value(af[][:n]) == 1)
        @test value(af[][:n]) == 1
        AirDB.sync(db)
        @test db.actorvals[af.id] == (form(n = 1), true, nothing)
        # a send staged in a transaction runs when it commits
        @tx send(af) do v
            form(n = value(v[:n]) + 10)
        end
        _waitfor(() -> value(af[][:n]) == 11)
        AirDB.sync(db)
        @test db.actorvals[af.id][1] == form(n = 11)
        # JSON resolves to the same cached actor
        g = AirDB.from_JSON(db, AirDB.to_JSON(af))
        @test g isa ActorForm && g === af
        # history = false is recorded with the actor
        ah = ActorForm(db, form(n = 0); history = false)
        send(ah) do v
            form(n = 1)
        end
        _waitfor(() -> value(ah[][:n]) == 1)
        AirDB.sync(db)
        @test db.actorvals[ah.id] == (form(n = 1), false, nothing)
        # the constructor's initial value is persisted too
        @test db.actorvals[af.id] == (form(n = 11), true, nothing)
        close(db)
    end

    @testset "actor lazy load" begin
        db = MemoryDatabase()
        id = _actor_to_forget(db)
        GC.gc(); GC.gc()
        r = get_actor(db, id)
        @test r isa ActorForm
        @test !isloaded(r)
        @test r[] == form(n = 5)
        @test isloaded(r)
        # concurrent lookups of one id yield the same object
        @test get_actor(db, id) === r
        close(db)
    end

    @testset "promises" begin
        db = MemoryDatabase()
        # undelivered: a link and an empty row
        pf = PromiseForm(db)
        @test !isready(pf)
        @test AirDB.to_JSON(pf) == "\"~$(pf.id)\""
        vf = VolatileForm(db, p = pf)
        AirDB.sync(db)
        @test haskey(db.promisevals, pf.id)
        @test db.promisevals[pf.id].state === :pending
        @test db.promisevals[pf.id].value === nothing
        # delivery updates the row
        put!(pf, form(x = 1))
        @test isready(pf)
        @test pf[] == form(x = 1)
        AirDB.sync(db)
        @test db.promisevals[pf.id].state === :delivered
        @test db.promisevals[pf.id].value == form(x = 1)
        # a delivered promise is still a link: its identity survives the round
        # trip, so the row (and its value) can be read back
        @test AirDB.to_JSON(pf) == "\"~$(pf.id)\""
        g = AirDB.from_JSON(db, AirDB.to_JSON(pf))
        @test g isa PromiseForm && g === pf
        @test g[] == form(x = 1)
        # a second delivery errors
        @test_throws ArgumentError put!(pf, form(x = 2))
        # a settlement creates its own row even if the promise is never stored
        pf2 = PromiseForm(db)
        put!(pf2, form(y = 2))
        AirDB.sync(db)
        @test haskey(db.promisevals, pf2.id)
        @test db.promisevals[pf2.id].state === :delivered
        @test db.promisevals[pf2.id].value == form(y = 2)
        # delivered before serialization: a link, with a row for the value
        pf3 = PromiseForm(db)
        put!(pf3, form(z = 3))
        vf3 = VolatileForm(db, p = pf3)
        AirDB.sync(db)
        @test haskey(db.promisevals, pf3.id)
        @test AirDB.to_JSON(vf3[]) == "[[], {\":p\": \"~$(pf3.id)\"}]"
        g3 = AirDB.from_JSON(db, AirDB.to_JSON(vf3[]))
        @test g3[:p] isa PromiseForm && g3[:p] === pf3
        @test g3[:p][] == form(z = 3)
        # an undelivered one round-trips as a promise (same handle)
        pf4 = PromiseForm(db)
        vf4 = VolatileForm(db, p = pf4)
        AirDB.sync(db)
        g = AirDB.from_JSON(db, AirDB.to_JSON(vf4[]))
        @test g[:p] isa PromiseForm && g[:p] === pf4
        @test !isready(g[:p])
        # reading an undelivered promise inside a transaction raises
        @test_throws ArgumentError (@tx pf4[])
        # a delivery staged in a transaction lands
        @tx put!(pf4, form(w = 4))
        AirDB.sync(db)
        @test db.promisevals[pf4.id].state === :delivered
        @test db.promisevals[pf4.id].value == form(w = 4)
        close(db)
    end

    @testset "delays" begin
        AirDB.register_delay(:double, f -> Form(2 * value(f)))
        df = DelayForm(:double, Form(3))
        @test df isa Form
        @test !isready(df)
        @test AirDB.to_JSON(df) == "{\"delay\": \":double\", \"form\": 3}"
        @test df[] == Form(6)
        @test isready(df)
        @test_throws ArgumentError (df[] = Form(1))
        @test_throws ArgumentError DelayForm(:nope, Form(1))
        @test_throws ArgumentError AirDB.register_delay(:double, f -> Form(1))
        # equality is by type and serialization form
        @test DelayForm(:double, Form(3)) == DelayForm(:double, Form(3))
        @test DelayForm(:double, Form(3)) != DelayForm(:double, Form(4))
        @test hash(DelayForm(:double, Form(3))) == hash(DelayForm(:double, Form(3)))
        # writing a delay never forces it
        df2 = DelayForm(:double, Form(4))
        AirDB.to_JSON(df2)
        @test !isready(df2)
        # a delay round-trips, inside a container too
        db = MemoryDatabase()
        f = form(d = DelayForm(:double, Form(5)), n = 1)
        g = AirDB.from_JSON(db, AirDB.to_JSON(f))
        @test g[:d] isa DelayForm
        @test g[:d][] == Form(10)
        close(db)
    end

    @testset "concurrent sends" begin
        db = MemoryDatabase()
        af = ActorForm(db, form(n = 0))
        @sync for _ in 1:4
            Threads.@spawn for _ in 1:50
                send(af) do v
                    form(n = value(v[:n]) + 1)
                end
            end
        end
        _waitfor(() -> value(af[][:n]) == 200)
        AirDB.sync(db)
        @test value(af[][:n]) == 200
        @test db.actorvals[af.id][1] == form(n = 200)
        close(db)
    end

    @testset "promise settlement states" begin
        db = MemoryDatabase()
        # a failure is durable and replayable
        id = _make_failed_promise(db)
        GC.gc(); GC.gc()
        r = get_promise(db, id)
        @test isready(r)                    # ready is true for a failure
        @test isfailed(r)
        e = try
            r[]
            nothing
        catch err
            err
        end
        @test e isa Air.PromiseFailed
        @test e.err == form(err = :boom)
        @test db.promisevals[id].state === :failed
        @test db.promisevals[id].error == form(err = :boom)
        # a settlement creates its own row even when never stored
        pid = _deliver_only(db)
        GC.gc(); GC.gc()
        @test get_promise(db, pid)[] == form(v = 9)
        # the first settlement wins
        p = PromiseForm(db)
        put!(p, form(a = 1))
        @test_throws ArgumentError fail!(p, form(a = 2))
        @test_throws ArgumentError put!(p, form(a = 2))
        close(db)
    end

    @testset "uncommitted and aborted promises" begin
        db = MemoryDatabase()
        pf = PromiseForm(db; pending_commit = true)
        @test_throws UncommittedPromise isready(pf)
        @test_throws UncommittedPromise pf[]
        put!(pf, form(x = 1))              # settling a pending promise is allowed
        mark_committed!(pf)
        @test isready(pf)
        @test pf[] == form(x = 1)
        pe = PromiseForm(db; pending_commit = true)
        mark_aborted!(pe)
        @test_throws AbortedPromise isready(pe)
        @test_throws AbortedPromise pe[]
        @test_throws AbortedPromise put!(pe, form(x = 1))
        @test_throws AbortedPromise fail!(pe, form(x = 1))
        close(db)
    end

    @testset "owner metadata" begin
        db = MemoryDatabase()
        m = form(owner = "alice")
        vf = VolatileForm(db, a = 1; metadata = m)
        af = ActorForm(db, form(n = 0); metadata = m)
        pf = PromiseForm(db; metadata = m)
        c = construct(get_extern_API(:counter), Form(Symbol(":new")), Form(1);
                      id = Symbol(":meta-ext"), metadata = m)
        VolatileForm(db, e = c)            # gives the extern a row
        AirDB.sync(db)
        @test metadata(vf) == m
        @test metadata(af) == m
        @test metadata(pf) == m
        @test metadata(c) == m
        # an extern with no row is unmanaged
        u = construct(get_extern_API(:counter), Form(Symbol(":new")), Form(2))
        @test metadata(u) === nothing
        @test_throws ArgumentError set_metadata!(u, m)
        # metadata-only edits, on every kind
        m2 = form(owner = "bob")
        @tx set_metadata!(vf, m2)
        @tx set_metadata!(af, m2)
        @tx set_metadata!(pf, m2)
        @tx set_metadata!(c, m2)
        AirDB.sync(db)
        @test metadata(vf) == m2
        @test metadata(af) == m2
        @test metadata(pf) == m2
        @test metadata(c) == m2
        close(db)
    end

    @testset "metadata-only reads do not load the payload" begin
        db = MemoryDatabase()
        id = _metadata_form(db)
        GC.gc(); GC.gc()
        r = get_form(db, id)
        @test !isloaded(r)
        @test metadata(r) == form(owner = "carol")
        @test !isloaded(r)                 # the payload was never fetched
        @test history(r)                   # the same metadata query carries the flag
        @test !isloaded(r)
        close(db)
    end

    @testset "GC keeps metadata and error links" begin
        db = MemoryDatabase()
        # a volatile referenced only by another object's metadata survives
        target = VolatileForm(db, n = 1)
        holder = VolatileForm(db, a = 2; metadata = form(acl = target))
        AirDB.sync(db)
        GC.gc(); GC.gc()
        @test gc!(db).swept_forms == 0
        @test haskey(db.store, target.id)
        @test haskey(db.store, holder.id)
        # a volatile referenced only by a failed promise's error survives
        db2 = MemoryDatabase()
        other = VolatileForm(db2, n = 3)
        failed = PromiseForm(db2)
        fail!(failed, form(why = other))
        AirDB.sync(db2)
        GC.gc(); GC.gc()
        @test gc!(db2).swept_forms == 0
        @test haskey(db2.store, other.id)
        close(db); close(db2)
    end

    @testset "JSON links need a database" begin
        af = ActorForm(MemoryDatabase(), form(n = 0))
        @test_throws ArgumentError AirDB.from_JSON("\"!$(af.id)\"")
        pf = PromiseForm(MemoryDatabase())
        @test_throws ArgumentError AirDB.from_JSON("\"~$(pf.id)\"")
    end
end
