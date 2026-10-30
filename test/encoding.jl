# Encoding-time reference collection, extern serialization reuse, and stream
# snapshot ordering. These are the pre-existing correctness bugs fixed with the
# writer-pipeline work.

# A serializable extern that counts how often it is serialized.
mutable struct CountedExtern <: AbstractAirExtern
    n::Int
end
const _COUNTED_SERIALIZATIONS = Ref(0)
AirDB.register_extern(:counted, CountedExtern;
    read_only = PDict(Symbol(":get") => (d, a) -> Form(d.n)),
    read_edit = PDict(Symbol(":bump") => (d, a) -> (d.n += 1; Form(d.n))),
    constructors = PDict(Symbol(":new") => a -> CountedExtern(Int(value(a)))),
    serialize = (d, io) -> (_COUNTED_SERIALIZATIONS[] += 1; print(io, d.n)),
    deserialize = io -> CountedExtern(parse(Int, read(io, String))))

@testset "encoding correctness" begin
    @testset "metadata and payload references get rows" begin
        cfg = _reconfig(_TEST_CFG; failure = :isolate)
        db = create_database(cfg; overwrite = true)
        conn = _connect(cfg)
        try
            ex = construct(get_extern_API(:counter), Form(Symbol(":new")), Form(5);
                           id = Symbol(":meta-ref-ex"))
            sf = StreamForm(db)
            pf = PromiseForm(db)
            # referenced only from a form's metadata
            vf = VolatileForm(db, a = 1;
                              metadata = form(e = ex, s = sf, p = pf))
            # referenced only from an actor's value
            aex = construct(get_extern_API(:counter), Form(Symbol(":new")), Form(6);
                            id = Symbol(":actor-ref-ex"))
            af = ActorForm(db, form(e = aex))
            # referenced only from a promise settlement payload
            pex = construct(get_extern_API(:counter), Form(Symbol(":new")), Form(7);
                            id = Symbol(":promise-ref-ex"))
            psf = StreamForm(db)
            p = PromiseForm(db)
            put!(p, form(e = pex, s = psf))
            AirDB.sync(db)

            # the referenced resources and streams/rows exist
            q = LibPQ.execute(conn,
                "SELECT count(*) FROM resources WHERE type = 'counter' AND id = \$1",
                (string(Symbol(":meta-ref-ex")),))
            @test q[1, 1] == 1
            q = LibPQ.execute(conn,
                "SELECT count(*) FROM resources WHERE type = 'counter' AND id = \$1",
                (string(Symbol(":actor-ref-ex")),))
            @test q[1, 1] == 1
            q = LibPQ.execute(conn,
                "SELECT count(*) FROM resources WHERE type = 'counter' AND id = \$1",
                (string(Symbol(":promise-ref-ex")),))
            @test q[1, 1] == 1
            for stream in (sf, psf)
                q = LibPQ.execute(conn,
                    "SELECT count(*) FROM form_stream WHERE stream_id = \$1::uuid",
                    (string(stream.id),))
                @test q[1, 1] == 1
            end
            # and the references load back
            m = metadata(get_form(db, vf.id))
            @test value(m[:e]) isa CounterData
            @test m[:e].handle.present
            @test m[:s] isa StreamForm
            @test m[:p] isa PromiseForm
        finally
            close(conn)
            close(db)
        end
    end

    @testset "stored externs are serialized once" begin
        cfg = _reconfig(_TEST_CFG; failure = :isolate)
        db = create_database(cfg; overwrite = true)
        try
            _COUNTED_SERIALIZATIONS[] = 0
            c = construct(get_extern_API(:counted), Form(Symbol(":new")), Form(1);
                          id = Symbol(":counted-once"))
            @test !c.handle.present
            vf1 = VolatileForm(db, e = c)
            AirDB.sync(db)
            @test c.handle.present
            ser1 = _COUNTED_SERIALIZATIONS[]
            @test ser1 == 1
            # a second form naming the same stored extern does not re-serialize
            vf2 = VolatileForm(db, e = c)
            AirDB.sync(db)
            @test _COUNTED_SERIALIZATIONS[] == ser1
            # a read-edit serializes once when its bytes are staged; references
            # still do not re-serialize
            p = reserve(c) do api
                api.call(Form(Symbol(":bump")), form())
            end
            p[]                               # wait for the read-edit to stage
            AirDB.sync(db)
            ser2 = _COUNTED_SERIALIZATIONS[]
            @test ser2 > ser1
            vf3 = VolatileForm(db, e = c)
            AirDB.sync(db)
            @test _COUNTED_SERIALIZATIONS[] == ser2
            # the row holds the bumped value
            r = get_form(db, vf3.id)[]
            @test value(r[:e]).n == 2
        finally
            close(db)
        end
    end

    @testset "a failed resource write stays retryable" begin
        cfg = _reconfig(_TEST_CFG; failure = :isolate, retries = 0)
        db = create_database(cfg; overwrite = true)
        try
            c = construct(get_extern_API(:counted), Form(Symbol(":new")), Form(9);
                          id = Symbol(":counted-retry"))
            close(AirDB._writer_conn(db))
            vf = VolatileForm(db, e = c)        # the batch is quarantined
            AirDB.sync(db)
            @test failed(db, vf.id)
            @test !c.handle.present              # the row was never written
            # clearing with retry writes the current value and marks it present
            @test clear_write_failure!(db, vf.id; retry = true)
            AirDB.sync(db)
            @test c.handle.present
            @test value(get_form(db, vf.id)[][:e]).n == 9
        finally
            close(db)
        end
    end

    @testset "concurrent non-transactional stream ops keep their order" begin
        cfg = _reconfig(_TEST_CFG; failure = :isolate)
        db = create_database(cfg; overwrite = true)
        conn = _connect(cfg)
        try
            sf = StreamForm(db)
            AirDB.sync(db)
            @sync for t in 1:8
                Threads.@spawn for i in 1:25
                    put!(sf, t * 1000 + i)
                end
            end
            AirDB.sync(db)
            q = LibPQ.execute(conn,
                "SELECT items::text FROM form_stream WHERE stream_id = \$1::uuid",
                (string(sf.id),))
            stored = AirDB.from_JSON(db, String(q[1, 1]))
            @test length(stored) == 200
            @test stored == form(snapshot(sf)...)
        finally
            close(conn)
            close(db)
        end
    end
end
