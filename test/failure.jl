# Wait until an actor enters its error state (or give up).
function _wait_error(actor; timeout = 10.0)
    t0 = time()
    while geterror(actor) === nothing
        time() - t0 > timeout && return false
        sleep(0.002)
    end
    return true
end

@testset "failure policy (:abort)" begin
    cfg = _TEST_CFG
    db = create_database(cfg; overwrite = true)
    conn = _connect(cfg)
    try
        vf = VolatileForm(db, "victim", n = 1)
        AirDB.sync(db)
        v0 = _current_version(conn, vf.id)
        @test v0 == 1

        # break the writer connection, then commit an update: the write fails
        st = db.writeactor[]
        close(st.conn)
        tx(() -> (vf[:n] = 2))
        @test _wait_error(db.writeactor)

        # the failure is recorded, the actor is poisoned, and nothing landed
        @test db.failure isa DatabaseError
        @test geterror(db.writeactor) isa ActorException
        @test _current_version(conn, vf.id) == v0

        # reads of a not-yet-loaded form raise
        @test_throws DatabaseError get_form(db, uuid4())[]
        # writes raise too, because the actor is poisoned
        @test_throws ActorException tx(() -> (vf[:n] = 3))
        # and so does an explicit sync
        @test_throws Exception AirDB.sync(db)
    finally
        close(conn)
        close(db)
    end
end

@testset "read failure poisons the database" begin
    cfg = _TEST_CFG
    db = create_database(cfg; overwrite = true)
    try
        id = _create_and_forget(db, n = 1)
        GC.gc(); GC.gc()   # let the cache release the form so the read hits the database

        # close every pooled read connection so the next read fails
        for _ in 1:cfg.readpoolsize
            c = take!(db.readpool)
            close(c)
            put!(db.readpool, c)
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
