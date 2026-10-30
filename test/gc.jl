# Garbage collection: the in-memory sweep and `delete_name!`. The PostgreSQL
# sweep is tested in persist.jl.

function _gc_memory_graph(db)
    root = named_form(db, "root"; create = true, value = form(a = 1))
    kid = VolatileForm(db, n = 2)
    @tx root[:kid] = kid
    orphan = VolatileForm(db, n = 3)
    AirDB.sync(db)
    return (root.id, kid.id, orphan.id)
end

@testset "garbage collection" begin
    @testset "the in-memory sweep" begin
        db = MemoryDatabase()
        rid, kid, oid = _gc_memory_graph(db)
        GC.gc(); GC.gc()
        dry = gc!(db; dry_run = true)
        @test dry.scanned_forms == 3
        @test dry.swept_forms == 1
        @test length(db.store) == 3            # dry run deletes nothing
        st = gc!(db)
        @test st.swept_forms == 1
        @test haskey(db.store, rid)
        @test haskey(db.store, kid)
        @test !haskey(db.store, oid)
        # releasing the name makes the chain collectable; the memory database
        # needs one pass per layer, since a swept row can still hold an object
        delete_name!(db, "root")
        AirDB.sync(db)
        GC.gc(); GC.gc()
        @test gc!(db).swept_forms == 1
        GC.gc(); GC.gc()
        @test gc!(db).swept_forms == 1
        @test isempty(db.store)
        close(db)
    end

    @testset "a live unnamed object is a root" begin
        db = MemoryDatabase()
        vf = VolatileForm(db, n = 1)
        AirDB.sync(db)
        @test gc!(db).swept_forms == 0
        @test haskey(db.store, vf.id)
        close(db)
    end

    @testset "delete_name!" begin
        db = MemoryDatabase()
        named_form(db, "x"; create = true, value = form(a = 1))
        AirDB.sync(db)
        @test !isempty(named_forms(db))
        delete_name!(db, "x")
        AirDB.sync(db)
        @test isempty(named_forms(db))
        @test_throws ArgumentError delete_name!(db, "x")
        close(db)
    end
end
