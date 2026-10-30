# Failure isolation: the default :isolate policy quarantines a failing batch,
# records it, and keeps the database serving unrelated work.

@testset "failure isolation" begin
    @testset "write failures are quarantined" begin
        cfg = _reconfig(_TEST_CFG; failure = :isolate, retries = 0)
        db = create_database(cfg; overwrite = true)
        conn = _connect(cfg)
        try
            vf = VolatileForm(db, n = 1)
            other = VolatileForm(db, m = 10)
            AirDB.sync(db)

            close(AirDB._writer_conn(db))    # break the writer connection
            @tx vf[:n] = 2
            AirDB.sync(db)                   # does not throw

            @test db.failure === nothing
            @test failed(db, vf.id)
            @test !failed(db, other.id)
            recs = write_failures(db)
            @test length(recs) == 1
            @test length(write_failures(db, vf.id)) == 1
            @test isempty(write_failures(db, other.id))
            item = recs[1].items[1]
            @test item.kind === :form && item.object === vf
            @test item.write isa AirDB.PendingWrite
            @test value(vf[:n]) == 2         # the committed in-memory value is kept
            # the writer reconnects, so unrelated writes continue
            @tx other[:m] = 11
            AirDB.sync(db)
            @test value(get_form(db, other.id)[:m]) == 11
            @test length(write_failures(db)) == 1
            # pending_writes reports the quarantined update
            @test any(pw -> pw isa AirDB.PendingWrite && pw.vf === vf,
                      pending_writes(db))
            # clear with retry re-stages the current value
            @test clear_write_failure!(db, vf.id; retry = true)
            AirDB.sync(db)
            @test isempty(write_failures(db))
            @test !failed(db, vf.id)
        finally
            close(conn)
            close(db)
        end
    end

    @testset "read failures are recorded separately" begin
        cfg = _reconfig(_TEST_CFG; failure = :isolate, retries = 0)
        db = create_database(cfg; overwrite = true)
        try
            id = _create_and_forget(db, n = 1)
            GC.gc(); GC.gc()
            conn = _connect(cfg)
            try
                LibPQ.execute(conn, "DROP TABLE form_current CASCADE")
            finally
                close(conn)
            end
            @test_throws Exception get_form(db, id)[]
            @test db.failure === nothing          # :isolate does not poison
            @test !isempty(read_failures(db))
            @test !isempty(read_failures(db, id))
            @test isempty(read_failures(db, uuid4()))
            @test isempty(write_failures(db))
            clear_read_failures!(db)
            @test isempty(read_failures(db))
        finally
            close(db)
        end
    end

    @testset "name operations keep their order" begin
        cfg = _reconfig(_TEST_CFG; failure = :isolate)
        db = create_database(cfg; overwrite = true)
        try
            vf = VolatileForm(db, a = 1)
            AirDB.sync(db)
            @tx name_form!(db, "n", vf)
            AirDB.sync(db)
            @test named_form(db, "n") === vf
            # delete followed by set in one transaction ends registered
            @tx begin
                delete_name!(db, "n")
                name_form!(db, "n", vf)
            end
            AirDB.sync(db)
            @test named_form(db, "n") === vf
            # set followed by delete in one transaction ends deleted
            @tx begin
                name_form!(db, "n", vf)
                delete_name!(db, "n")
            end
            AirDB.sync(db)
            @test named_form(db, "n"; create = nothing) === nothing
        finally
            close(db)
        end
    end

    @testset "the on_error hook can stop retrying" begin
        seen = Ref(0)
        cfg = _reconfig(_TEST_CFG; failure = :isolate, retries = 5,
                        retry_delay = 0.01,
                        on_error = (db, err) -> (seen[] += 1; :abort))
        db = create_database(cfg; overwrite = true)
        try
            vf = VolatileForm(db, n = 1)
            AirDB.sync(db)
            close(AirDB._writer_conn(db))
            @tx vf[:n] = 2
            AirDB.sync(db)
            @test seen[] == 1                    # the hook said no retry
            @test failed(db, vf.id)              # and the batch was quarantined
            @test db.failure === nothing
        finally
            close(db)
        end
    end

    @testset "a metadata edit survives a body load" begin
        cfg = _reconfig(_TEST_CFG; failure = :isolate, max_batch = 100)
        db = create_database(cfg; overwrite = true)
        conn = _connect(cfg)
        try
            id = _create_and_forget(db, n = 1; metadata = form(owner = "old"))
            GC.gc(); GC.gc()
            r = get_form(db, id)
            @test !isloaded(r)
            m = form(owner = "new")
            # A metadata-only batch does not reach the max_batch threshold, so
            # the row still has the old metadata while the volatile has the new
            # value.
            @tx set_metadata!(r, m)
            @test metadata(r) == m
            @test value(r[:n]) == 1         # loads the body from the old row
            @test metadata(r) == m          # the load must not clobber the edit
            AirDB.sync(db)
            q = LibPQ.execute(conn,
                "SELECT metadata::text FROM form_current WHERE form_id = \$1::uuid",
                (string(id),))
            @test AirDB.from_JSON(String(q[1, 1])) == m
            @test db.failure === nothing
        finally
            close(conn)
            close(db)
        end
    end

    @testset "MemoryDatabase parity" begin
        db = MemoryDatabase()
        vf = VolatileForm(db, a = 1)
        @tx set_metadata!(vf, form(x = 1))
        @test isempty(write_failures(db))
        @test isempty(write_failures(db, vf.id))
        @test isempty(read_failures(db))
        @test !failed(db, vf.id)
        @test !clear_write_failure!(db, vf.id)
        @test clear_write_failures!(db) === nothing
        @test clear_read_failures!(db) === nothing
        close(db)
    end
end
