@testset "cross-commit batching" begin
    cfg = _TEST_CFG

    @testset "max_batch > 1 defers writes" begin
        bcfg = _with_max_batch(cfg, 3)
        bdb = create_database(bcfg; overwrite = true)
        bconn = _connect(bcfg)
        try
            vf = VolatileForm(bdb, n = 0)
            AirDB.sync(bdb)
            @test _current_version(bconn, vf.id) == 1

            # two commits are fewer than max_batch, so nothing reaches the database
            @tx vf[:n] = 1
            @tx vf[:n] = 2
            sleep(0.2)
            @test _current_version(bconn, vf.id) == 1
            # ... but the in-memory value is already up to date
            @test value(vf[:n]) == 2

            # the third commit fills the batch and it is written at once
            @tx vf[:n] = 3
            @test _wait_version(bconn, vf.id, 4) == 4
            @test value(vf[:n]) == 3
        finally
            close(bconn)
            close(bdb)
        end
    end

    @testset "sync flushes a partial batch" begin
        bcfg = _with_max_batch(cfg, 100)
        bdb = create_database(bcfg; overwrite = true)
        bconn = _connect(bcfg)
        try
            vf = VolatileForm(bdb, n = 0)
            AirDB.sync(bdb)
            @tx vf[:n] = 1
            @tx vf[:n] = 2
            # far below max_batch, but sync forces the batch out
            AirDB.sync(bdb)
            @test _current_version(bconn, vf.id) == 3
        finally
            close(bconn)
            close(bdb)
        end
    end
end
