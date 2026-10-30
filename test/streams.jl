# Stream forms: FIFO semantics, bounding, timeouts, closing, persistence,
# transaction staging, commit state, JSON, and GC.

function _stream_graph(db)
    sf = StreamForm(db; maxsize = 3, metadata = form(owner = "alice"))
    put!(sf, form(a = 1))
    put!(sf, form(b = 2))
    close(sf)
    AirDB.sync(db)
    return sf.id
end

function _stream_to_forget(db)
    sf = StreamForm(db)
    put!(sf, form(v = 1))
    AirDB.sync(db)
    return sf.id
end

@testset "stream forms" begin
    @testset "FIFO and inspection" begin
        db = MemoryDatabase()
        sf = StreamForm(db; maxsize = 3)
        @test sf isa Form
        @test sf isa AirDB.FormNode
        @test isopen(sf)
        @test isempty(sf)
        @test length(sf) == 0
        @test maxsize(sf) == 3
        @test !isready(sf)
        put!(sf, form(a = 1))
        put!(sf, 2)
        @test length(sf) == 2 && !isempty(sf) && isready(sf)
        @test snapshot(sf) == Form[form(a = 1), Form(2)]
        @test take(sf) == form(a = 1)
        @test take(sf) == Form(2)
        @test isempty(sf)
        @test AirDB.to_JSON(sf) == "\"&$(sf.id)\""
        # unbounded: puts never wait
        ub = StreamForm(db)
        @test maxsize(ub) === nothing
        for i in 1:50
            put!(ub, i)
        end
        @test length(ub) == 50
        close(db)
    end

    @testset "bound and timeouts" begin
        db = MemoryDatabase()
        sf = StreamForm(db; maxsize = 1)
        put!(sf, form(a = 1))
        @test_throws Air.ReaderTimeout put!(sf, form(b = 2); timeout = 0.02)
        @test length(sf) == 1
        @test take(sf) == form(a = 1)
        put!(sf, form(b = 2))               # room again
        @test take(sf) == form(b = 2)
        @test_throws Air.ReaderTimeout take(sf; timeout = 0.02)
        close(db)
    end

    @testset "closing" begin
        db = MemoryDatabase()
        sf = StreamForm(db)
        put!(sf, form(a = 1))
        close(sf)
        @test !isopen(sf)
        @test isready(sf)                   # a take returns immediately
        @test take(sf) == form(a = 1)
        @test_throws Air.StreamClosed take(sf)
        @test_throws Air.StreamClosed put!(sf, form(b = 2))
        close(sf)                           # idempotent
        close(db)
    end

    @testset "persistence and reload" begin
        db = MemoryDatabase()
        sid = _stream_graph(db)
        GC.gc(); GC.gc()
        r = get_stream(db, sid)
        @test r isa StreamForm
        @test !isloaded(r)
        @test snapshot(r) == Form[form(a = 1), form(b = 2)]
        @test maxsize(r) == 3
        @test !isopen(r)
        @test metadata(r) == form(owner = "alice")
        @test take(r) == form(a = 1)
        @test take(r) == form(b = 2)
        @test_throws Air.StreamClosed take(r)
        # a stream edited but never stored in a form still persists
        oid = _stream_to_forget(db)
        GC.gc(); GC.gc()
        @test snapshot(get_stream(db, oid)) == Form[form(v = 1)]
        close(db)
    end

    @testset "transaction staging" begin
        db = MemoryDatabase()
        sf = StreamForm(db)
        @tx put!(sf, form(a = 1))
        AirDB.sync(db)
        @test length(sf) == 1
        # an aborted transaction discards its staged put
        @test_throws ErrorException @tx begin
            put!(sf, form(b = 2))
            error("abort")
        end
        AirDB.sync(db)
        @test length(sf) == 1
        @test snapshot(sf) == Form[form(a = 1)]
        # a take inside a committing transaction
        @tx take(sf)
        @test isempty(sf)
        close(db)
    end

    @testset "commit state" begin
        db = MemoryDatabase()
        sf = StreamForm(db; pending_commit = true)
        @test_throws UncommittedStream isready(sf)
        @test_throws UncommittedStream snapshot(sf)
        @test_throws UncommittedStream take(sf)
        put!(sf, form(a = 1))               # writing a pending stream is allowed
        mark_committed!(sf)
        @test length(sf) == 1
        @test take(sf) == form(a = 1)
        ab = StreamForm(db; pending_commit = true)
        mark_aborted!(ab)
        @test_throws AbortedStream isready(ab)
        @test_throws AbortedStream length(ab)
        @test_throws AbortedStream take(ab)
        @test_throws AbortedStream put!(ab, 1)
        @test_throws AbortedStream close(ab)
        close(db)
    end

    @testset "JSON" begin
        db = MemoryDatabase()
        sf = StreamForm(db)
        put!(sf, form(a = 1))
        @test AirDB.to_JSON(sf) == "\"&$(sf.id)\""
        g = AirDB.from_JSON(db, AirDB.to_JSON(form(s = sf)))
        @test g[:s] isa StreamForm
        @test g[:s] === sf
        @test_throws ArgumentError AirDB.from_JSON("\"&$(sf.id)\"")
        close(db)
    end

    @testset "GC keeps stream links" begin
        db = MemoryDatabase()
        target = VolatileForm(db, n = 1)
        sf = StreamForm(db)
        put!(sf, form(ref = target))
        AirDB.sync(db)
        GC.gc(); GC.gc()
        @test gc!(db).swept_forms == 0
        @test haskey(db.store, target.id)
        # a stream's metadata is link-bearing too
        db2 = MemoryDatabase()
        t2 = VolatileForm(db2, n = 2)
        StreamForm(db2; metadata = form(acl = t2))
        AirDB.sync(db2)
        GC.gc(); GC.gc()
        @test gc!(db2).swept_forms == 0
        @test haskey(db2.store, t2.id)
        # an unreachable stream row is swept
        db3 = MemoryDatabase()
        oid = _stream_to_forget(db3)
        GC.gc(); GC.gc()
        @test gc!(db3).swept_streams >= 1
        @test !haskey(db3.streamvals, oid)
        close(db); close(db2); close(db3)
    end
end
