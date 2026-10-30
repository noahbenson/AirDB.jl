# The write pipeline: encoding happens off the committing thread and off the
# writer task, and the lag is bounded by `max_pending`.

# An extern whose serialization blocks until the test releases it.
mutable struct SlowExtern <: AbstractAirExtern
    n::Int
end
const _SLOW_GATE = Ref{Union{Nothing,Channel{Nothing}}}(nothing)
AirDB.register_extern(:slow, SlowExtern;
    read_only = PDict(Symbol(":get") => (d, a) -> Form(d.n)),
    constructors = PDict(Symbol(":new") => a -> SlowExtern(Int(value(a)))),
    serialize = (d, io) -> begin
        g = _SLOW_GATE[]
        g === nothing || take!(g)
        print(io, d.n)
    end,
    deserialize = io -> SlowExtern(parse(Int, read(io, String))))

@testset "write pipeline" begin
    @testset "encoding is off the committing thread" begin
        cfg = _reconfig(_TEST_CFG; encoder_tasks = 2, max_pending = 16)
        db = create_database(cfg; overwrite = true)
        gate = Channel{Nothing}(1)
        _SLOW_GATE[] = gate
        try
            slow = construct(get_extern_API(:slow), Form(Symbol(":new")), Form(1);
                             id = Symbol(":slow-encode"))
            t0 = time()
            vf1 = VolatileForm(db, e = slow)     # its encoding blocks
            @test time() - t0 < 2.0              # the commit did not encode
            vf2 = VolatileForm(db, n = 2)        # later commits are accepted
            # the intake actor is asynchronous; wait for it to take the batches
            @test timedwait(() -> AirDB.status(db)[1] > 0, 5.0) === :ok
            put!(gate, nothing)                  # release the serializer
            AirDB.sync(db)
            @test value(get_form(db, vf1.id)[][:e]).n == 1
            @test value(get_form(db, vf2.id)[][:n]) == 2
        finally
            try
                put!(gate, nothing)              # never leave the encoder blocked
            catch
            end
            _SLOW_GATE[] = nothing
            close(db)
        end
    end

    @testset "max_pending bounds the writer lag" begin
        cfg = _reconfig(_TEST_CFG; encoder_tasks = 1, max_pending = 1, max_batch = 1)
        db = create_database(cfg; overwrite = true)
        gate = Channel{Nothing}(1)
        _SLOW_GATE[] = gate
        done = Channel{Nothing}(1)
        try
            slow = construct(get_extern_API(:slow), Form(Symbol(":new")), Form(5);
                             id = Symbol(":slow-capacity"))
            vf1 = VolatileForm(db, e = slow)     # fills the only pending slot
            # wait for intake to take it before the second commit checks capacity
            @test timedwait(() -> AirDB.status(db)[1] > 0, 5.0) === :ok
            Threads.@spawn begin
                VolatileForm(db, n = 6)          # must wait for capacity
                put!(done, nothing)
            end
            @test timedwait(() -> isready(done), 0.3) === :timed_out
            put!(gate, nothing)                  # release the slow batch
            @test timedwait(() -> isready(done), 10.0) === :ok
            take!(done)
            AirDB.sync(db)
            @test value(get_form(db, vf1.id)[][:e]).n == 5
        finally
            try
                put!(gate, nothing)
            catch
            end
            _SLOW_GATE[] = nothing
            close(db)
        end
    end

    @testset "concurrent commits keep their order" begin
        cfg = _reconfig(_TEST_CFG; encoder_tasks = 3, max_batch = 1)
        db = create_database(cfg; overwrite = true)
        conn = _connect(cfg)
        try
            vf = VolatileForm(db, n = 0)
            AirDB.sync(db)
            @sync for _ in 1:8
                Threads.@spawn for _ in 1:10
                    tx(() -> (vf[:n] = value(vf[:n]) + 1))
                end
            end
            AirDB.sync(db)
            @test value(vf[:n]) == 80
            @test _current_version(conn, vf.id) == 81   # the initial row + 80
        finally
            close(conn)
            close(db)
        end
    end

    @testset "close drains a queued pipeline" begin
        cfg = _reconfig(_TEST_CFG; encoder_tasks = 2, max_pending = 16)
        db = create_database(cfg; overwrite = true)
        _SLOW_GATE[] = nothing
        vf = VolatileForm(db, n = 7)
        close(db)                                # flushes the queued update
        @test db.closed
        conn = _connect(cfg)
        try
            @test _current_version(conn, vf.id) == 1
        finally
            close(conn)
        end
    end
end
