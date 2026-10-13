@testset "Database lifecycle" begin
    cfg = _TEST_CFG

    @testset "create and open" begin
        db = create_database(cfg; overwrite = true)
        @test db isa Database
        @test AirDB.status(db) == (0, nothing)
        conn = _connect(cfg)
        try
            r = LibPQ.execute(conn, "SELECT to_regclass('public.form_current') IS NOT NULL")
            @test first(r)[1] === true
            r = LibPQ.execute(conn, "SELECT value FROM airdb_meta WHERE key = 'schema_version'")
            @test first(r)[1] == AirDB._SCHEMA_VERSION
        finally
            close(conn)
        end
        close(db)

        # opening the same database again works
        db = open_database(cfg)
        @test db isa Database
        close(db)
    end

    @testset "overwrite resets" begin
        db = create_database(cfg; overwrite = true)
        vf = VolatileForm(db, "keepme")
        AirDB.sync(db)
        id = vf.id
        close(db)

        db = create_database(cfg; overwrite = true)
        conn = _connect(cfg)
        try
            @test _current_version(conn, id) === nothing
        finally
            close(conn)
        end
        close(db)
    end

    @testset "missing schema raises" begin
        # the default `postgres` database exists on every server but has no AirDB
        # schema, so opening it must fail cleanly
        @test_throws ArgumentError open_database(_with_dbname(cfg, "postgres"))
    end

    @testset "closed database raises" begin
        db = create_database(cfg; overwrite = true)
        close(db)
        @test_throws ArgumentError AirDB.sync(db)
        @test_throws ArgumentError VolatileForm(db, "nope")
    end
end
