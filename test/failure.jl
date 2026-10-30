# Wait until the database records a poisoning failure (or give up).
function _wait_failure(db; timeout = 10.0)
    t0 = time()
    while db.failure === nothing
        time() - t0 > timeout && return false
        sleep(0.002)
    end
    return true
end

@testset "failure policy (:abort)" begin
    cfg = _reconfig(_TEST_CFG; failure = :abort)
    db = create_database(cfg; overwrite = true)
    conn = _connect(cfg)
    try
        vf = VolatileForm(db, "victim", n = 1)
        AirDB.sync(db)
        v0 = _current_version(conn, vf.id)
        @test v0 == 1

        # break the writer connection, then commit an update: the write fails
        close(AirDB._writer_conn(db))
        tx(() -> (vf[:n] = 2))
        @test _wait_failure(db)

        # the failure is recorded, the database is poisoned, and nothing landed
        @test db.failure isa DatabaseError
        @test _current_version(conn, vf.id) == v0

        # reads of a not-yet-loaded form raise
        @test_throws DatabaseError get_form(db, uuid4())[]
        # writes raise too: `_stage!` checks the recorded failure (and the actor
        # is poisoned as well)
        @test_throws DatabaseError tx(() -> (vf[:n] = 3))
        # and so does an explicit sync
        @test_throws Exception AirDB.sync(db)
    finally
        close(conn)
        close(db)
    end
end

@testset "read failure poisons the database" begin
    cfg = _reconfig(_TEST_CFG; failure = :abort)
    db = create_database(cfg; overwrite = true)
    try
        id = _create_and_forget(db, n = 1)
        GC.gc(); GC.gc()   # let the cache release the form so the read hits the database

        # Break the schema so the next read fails with a database error (rather
        # than a missing row). Closing the pool's connections is the obvious way
        # to provoke one, but whether LibPQ raises on a closed connection — and
        # when — differs between versions, so it is not reliable.
        conn = _connect(cfg)
        try
            LibPQ.execute(conn, "DROP TABLE form_current CASCADE")
        finally
            close(conn)
        end

        # the read fails and, under :abort, fails the whole database
        @test_throws Exception get_form(db, id)[]
        @test db.failure isa DatabaseError
        # further database operations raise rather than retry
        @test_throws DatabaseError get_form(db, uuid4())[]
    finally
        close(db)
    end
end
