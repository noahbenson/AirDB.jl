@testset "retry policy (:retry)" begin
    cfg = _TEST_CFG

    @testset "retry recovers a broken writer connection" begin
        rcfg = _reconfig(cfg; failure = :retry, retries = 5, retry_delay = 0.01,
                         retry_delay_max = 0.05)
        db = create_database(rcfg; overwrite = true)
        conn = _connect(rcfg)
        try
            vf = VolatileForm(db, n = 1)
            AirDB.sync(db)
            @test _current_version(conn, vf.id) == 1

            close(db.writeactor[].conn)      # break the writer connection
            @tx vf[:n] = 2
            AirDB.sync(db)                   # reconnects and retries, then succeeds
            @test _current_version(conn, vf.id) == 2
            @test db.failure === nothing
        finally
            close(conn)
            close(db)
        end
    end

    @testset "on_error hook can force abort" begin
        seen = Ref(0)
        rcfg = _reconfig(cfg; failure = :retry, retries = 5,
                         on_error = (db, err) -> (seen[] += 1; :abort))
        db = create_database(rcfg; overwrite = true)
        try
            vf = VolatileForm(db, n = 1)
            AirDB.sync(db)
            close(db.writeactor[].conn)
            @tx vf[:n] = 2
            @test_throws Exception AirDB.sync(db)
            @test seen[] >= 1
            @test db.failure isa DatabaseError
        finally
            close(db)
        end
    end

    @testset "on_error hook sees the pending writes" begin
        seen = Ref(0)
        rcfg = _reconfig(cfg; failure = :retry, retries = 5, retry_delay = 0.01,
                         on_error = (db, err) -> (seen[] = length(pending_writes(db)); :retry))
        db = create_database(rcfg; overwrite = true)
        try
            vf = VolatileForm(db, n = 1)
            AirDB.sync(db)
            close(db.writeactor[].conn)
            @tx vf[:n] = 2
            AirDB.sync(db)
            @test seen[] >= 1                # the hook saw the queued update
        finally
            close(db)
        end
    end

    @testset "retry gives up when the budget is spent" begin
        rcfg = _reconfig(cfg; failure = :retry, retries = 0, retry_delay = 0.01)
        db = create_database(rcfg; overwrite = true)
        try
            vf = VolatileForm(db, n = 1)
            AirDB.sync(db)
            close(db.writeactor[].conn)
            @tx vf[:n] = 2
            @test_throws Exception AirDB.sync(db)
            @test db.failure isa DatabaseError
            @test_throws ActorException tx(() -> (vf[:n] = 3))
        finally
            close(db)
        end
    end

    @testset "reads retry a broken read connection" begin
        rcfg = _reconfig(cfg; failure = :retry, retries = 5, retry_delay = 0.01,
                         retry_delay_max = 0.05)
        db = create_database(rcfg; overwrite = true)
        try
            id = _create_and_forget(db, n = 7)
            GC.gc(); GC.gc()
            # break every pooled read connection
            for _ in 1:rcfg.readpoolsize
                c = take!(db.readpool)
                close(c)
                put!(db.readpool, c)
            end
            # the read reconnects and retries, then succeeds
            @test value(get_form(db, id)[:n]) == 7
            @test db.failure === nothing
        finally
            close(db)
        end
    end
end
