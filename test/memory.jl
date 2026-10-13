# Create a form and return its id with no reference left in the caller's scope,
# so the weak cache can release it (used to test lazy loading).
function _mem_forget(db, args...; kwargs...)
    vf = VolatileForm(db, args...; kwargs...)
    AirDB.sync(db)
    return vf.id
end

@testset "MemoryDatabase" begin
    db = MemoryDatabase()
    @test db isa AirDB.AbstractDatabase

    @testset "forms persist across commits" begin
        vf = VolatileForm(db, n = 1)
        AirDB.sync(db)
        @test value(vf[:n]) == 1
        @tx vf[:n] = 2
        AirDB.sync(db)
        @test value(vf[:n]) == 2
        # reloading by id reads the stored value, lazily
        id = _mem_forget(db, n = 7)
        GC.gc(); GC.gc()
        r = get_form(db, id)
        @test !AirDB.isloaded(r)
        @test value(r[:n]) == 7
    end

    @testset "a missing form raises" begin
        @test_throws FormNotFound get_form(db, uuid4())[]
    end

    @testset "named forms" begin
        root = named_form(db, "root"; create = true, value = form(version = 1))
        AirDB.sync(db)
        @test named_form(db, "root") === root
        @test named_form(db, :root) === root
        @test value(named_form(db, "root")[:version]) == 1
        @test named_form(db, "nope"; create = nothing) === nothing
        @test_throws ArgumentError named_form(db, "root"; create = true)
    end

    @testset "atomicity and ordering" begin
        a = VolatileForm(db, x = 0)
        b = VolatileForm(db, x = 0)
        AirDB.sync(db)
        @tx begin
            a[:x] = 1
            b[:x] = 2
        end
        AirDB.sync(db)
        @test value(a[:x]) == 1 && value(b[:x]) == 2
        # an aborted transaction writes nothing
        try
            @tx begin
                a[:x] = 99
                error("abort")
            end
        catch
        end
        @test value(a[:x]) == 1
    end

    @testset "concurrent writers" begin
        c = VolatileForm(db, n = 0)
        AirDB.sync(db)
        @sync for _ in 1:20
            Threads.@spawn tx(() -> (c[:n] = value(c[:n]) + 1))
        end
        AirDB.sync(db)
        @test value(c[:n]) == 20
    end

    @testset "close" begin
        close(db)
        @test_throws ArgumentError VolatileForm(db, "x")
    end
end
