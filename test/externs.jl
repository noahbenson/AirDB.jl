# Host-level extern types: user-defined interfaces, reservations, and resources.

# A mutable counter: read-only and read-edit operations, a constructor, and
# serialization.
mutable struct CounterData <: AbstractAirExtern
    n::Int
end
AirDB.register_extern(:counter, CounterData;
    read_only = PDict(
        Symbol(":get") => (d, a) -> Form(d.n),
        Symbol(":sum") => (d, a) -> Form(d.n + Int(value(a)))),
    read_edit = PDict(
        Symbol(":bump") => (d, a) -> (d.n += 1; Form(d.n)),
        Symbol(":add") => (d, a) -> (d.n += Int(value(a)); Form(d.n))),
    constructors = PDict(Symbol(":new") => a -> CounterData(Int(value(a)))),
    serialize = (d, io) -> print(io, d.n),
    deserialize = io -> CounterData(parse(Int, read(io, String))))

# An immutable handle: no locking, API available to any thread.
struct ConfigData <: AbstractAirExtern
    v::Int
end
AirDB.register_extern(:config, ConfigData;
    read_only = PDict(Symbol(":version") => (d, a) -> Form(d.v)),
    constructors = PDict(Symbol(":new") => a -> ConfigData(Int(value(a)))),
    immutable = true,
    serialize = (d, io) -> print(io, d.v),
    deserialize = io -> ConfigData(parse(Int, read(io, String))))

# A type with no serialization: it can never be stored.
struct EphemeralData <: AbstractAirExtern
    v::Int
end
AirDB.register_extern(:ephemeral, EphemeralData;
    read_only = PDict(Symbol(":get") => (d, a) -> Form(d.v)),
    constructors = PDict(Symbol(":new") => a -> EphemeralData(Int(value(a)))))

# A type whose constructor returns the wrong data type.
struct BadData <: AbstractAirExtern
    v::Int
end
AirDB.register_extern(:bad, BadData;
    constructors = PDict(Symbol(":new") => a -> "not bad data"))

# Registration is tested with types of their own, so the name/type rules can be
# exercised without disturbing the types above.
struct TmpExternA <: AbstractAirExtern end
struct TmpExternB <: AbstractAirExtern end
struct TmpExternC <: AbstractAirExtern end
struct EqTmpA <: AbstractAirExtern end
struct EqTmpB <: AbstractAirExtern end

_call(api, op::Symbol, args = form()) = api.call(Form(op), args)
_ctor(name::Symbol) = Form(name)

@testset "externs" begin
    @testset "registration checks" begin
        @test_throws ExternError AirDB.register_extern(:tmp, TmpExternA; immutable = true,
            read_edit = PDict(Symbol(":x") => (d, a) -> form()))
        @test_throws ExternError AirDB.register_extern(:tmp, TmpExternA;
            serialize = (d, io) -> nothing)
        AirDB.register_extern(:tmp, TmpExternA)
        @test_throws ExternError AirDB.register_extern(:tmp, TmpExternB)
        @test_throws ExternError AirDB.register_extern(:tmp2, TmpExternA)
        # equivalence functions must come in a pair, and only for immutable types
        @test_throws ExternError AirDB.register_extern(:tmp3, EqTmpA;
            immutable = true, equal = (a, b) -> true)
        @test_throws ExternError AirDB.register_extern(:tmp4, EqTmpB;
            immutable = true, hash = (x, h) -> h)
        @test_throws ExternError AirDB.register_extern(:tmp5, TmpExternC;
            equal = (a, b) -> true, hash = (x, h) -> h)
    end

    @testset "construct" begin
        c = construct(get_extern_API(:counter), _ctor(Symbol(":new")), Form(3))
        @test c isa FormExtern{CounterData}
        @test value(c) isa CounterData
        @test value(c).n == 3
        @test_throws ExternError construct(get_extern_API(:counter), _ctor(Symbol(":nope")), form())
        @test_throws ExternError construct(get_extern_API(:counter), Form(3), form())
        @test_throws ExternError construct(get_extern_API(:bad), _ctor(Symbol(":new")), form())
        # a type-level API has no data
        @test_throws ExternError call(get_extern_API(:counter), _ctor(Symbol(":get")), form())
    end

    @testset "read-only calls" begin
        c = construct(get_extern_API(:counter), _ctor(Symbol(":new")), Form(3))
        @test reserve_read(c) do a; _call(a, Symbol(":get")); end == Form(3)
        @test reserve_read(c) do a; _call(a, Symbol(":sum"), Form(4)); end == Form(7)
        @test value(c).n == 3
        @test_throws ExternError reserve_read(c) do a; _call(a, Symbol(":nope")); end
        # a read-edit operation is not available through a read-only API
        @test_throws ExternError reserve_read(c) do a; _call(a, Symbol(":bump")); end
        @test value(c).n == 3
    end

    @testset "reserve" begin
        c = construct(get_extern_API(:counter), _ctor(Symbol(":new")), Form(1))
        p = reserve(c) do a
            a.call(Form(Symbol(":bump")), form())
            _call(a, Symbol(":add"), Form(10))
        end
        @test p isa ExternPromise
        @test p[] == Form(12)
        @test value(c).n == 12
        # read-only operations are available through an editable API too
        @test (reserve(c) do a; _call(a, Symbol(":get")); end)[] == Form(12)
        # an error in the function is re-raised by the promise
        p2 = reserve(c) do a; error("boom"); end
        @test_throws ErrorException p2[]
        @test value(c).n == 12
    end

    @testset "multiple resources" begin
        a = construct(get_extern_API(:counter), _ctor(Symbol(":new")), Form(1),
                      id = Symbol(":multi-a"))
        b = construct(get_extern_API(:counter), _ctor(Symbol(":new")), Form(2),
                      id = Symbol(":multi-b"))
        # requested out of order; the reservation sorts by (type, id), so the
        # do-block receives :multi-a first
        r = reserve(b, a) do first, second
            (first.call(Form(Symbol(":bump")), form()),
             second.call(Form(Symbol(":bump")), form()))
        end
        @test r[] == (Form(2), Form(3))
        @test (value(a).n, value(b).n) == (2, 3)
        s = reserve_read(b, a) do first, second
            (first.call(Form(Symbol(":get")), form()),
             second.call(Form(Symbol(":get")), form()))
        end
        @test s == (Form(2), Form(3))
    end

    @testset "immutable externs" begin
        c = construct(get_extern_API(:config), _ctor(Symbol(":new")), Form(9),
                      id = Symbol(":cfg-test"))
        api = get_extern_API(c)                 # no reservation needed
        @test _call(api, Symbol(":version")) == Form(9)
        @test reserve_read(c) do a; _call(a, Symbol(":version")); end == Form(9)
    end

    @testset "JSON" begin
        c = construct(get_extern_API(:counter), _ctor(Symbol(":new")), Form(3),
                      id = Symbol(":json-test"))
        @test AirDB.to_JSON(c) == "{\"extern\": \"'counter\", \"id\": \"::json-test\"}"
        r = AirDB.from_JSON(AirDB.to_JSON(c))
        @test r isa FormExtern
        @test r.handle === c.handle            # the registry returns the same handle
        @test value(r) === value(c)
        # inside a form
        f = form(1, cfg = c)
        g = AirDB.from_JSON(AirDB.to_JSON(f))
        @test g[:cfg].handle === c.handle
        # unnamed externs are written as dead markers
        u = construct(get_extern_API(:counter), _ctor(Symbol(":new")), Form(3))
        @test AirDB.to_JSON(u) == "{\"extern\": \"'counter\"}"
        @test AirDB.from_JSON(AirDB.to_JSON(u)) isa FormExtern
        @test value(AirDB.from_JSON(AirDB.to_JSON(u))) isa DeadExtern
        # so are externs whose type has no serialization, even when named
        e = construct(get_extern_API(:ephemeral), _ctor(Symbol(":new")), Form(1),
                      id = Symbol(":eph-test"))
        @test AirDB.to_JSON(e) == "{\"extern\": \"'ephemeral\"}"
    end

    @testset "dead externs" begin
        dead = AirDB.from_JSON("{\"extern\": \"'counter\"}")
        @test value(dead) isa DeadExtern
        @test_throws ExternError get_extern_API(dead)
        @test_throws ExternError reserve_read(dead) do a; nothing; end
        @test_throws ExternError reserve(dead) do a; nothing; end
        # an unregistered type cannot be read back
        @test_throws ExternError AirDB.from_JSON("{\"extern\": \"'nope\", \"id\": \"::x\"}")
    end

    @testset "transactional version check" begin
        c = construct(get_extern_API(:counter), _ctor(Symbol(":new")), Form(0),
                      id = Symbol(":tx-test"))
        read_ch = Channel{Nothing}(1)
        go_ch = Channel{Nothing}(1)
        attempts = Ref(0)
        seen = Ref{Any}(nothing)
        t = Threads.@spawn begin
            @tx begin
                attempts[] += 1
                v = reserve_read(c) do a
                    _call(a, Symbol(":get"))
                end
                if attempts[] == 1
                    seen[] = v
                    put!(read_ch, nothing)     # the read has happened
                    take!(go_ch)               # let the bump finish
                else
                    seen[] = v
                end
            end
        end
        take!(read_ch)
        # a read-edit while the transaction is open must invalidate it
        p = reserve(c) do a; _call(a, Symbol(":bump")); end
        p[]
        put!(go_ch, nothing)
        wait(t)
        @test attempts[] == 2
        @test value(seen[]) == 1
        @test value(c).n == 1
    end

    @testset "promise before commit" begin
        c = construct(get_extern_API(:counter), _ctor(Symbol(":new")), Form(0),
                      id = Symbol(":promise-test"))
        err = Ref{Any}(nothing)
        p_ref = Ref{Any}(nothing)
        t = Threads.@spawn begin
            @tx begin
                p_ref[] = reserve(c) do a; _call(a, Symbol(":bump")); end
                err[] = try
                    p_ref[][]
                    nothing
                catch e
                    e
                end
            end
        end
        wait(t)
        @test err[] isa ExternError
        @test p_ref[][] == Form(1)           # after the commit it yields the result
    end

    @testset "a database" begin
        db = MemoryDatabase()
        c = construct(get_extern_API(:counter), _ctor(Symbol(":new")), Form(5),
                      id = Symbol(":mem-test"))
        vf = VolatileForm(db, cfg = c)
        AirDB.sync(db)
        (reserve(c) do a; _call(a, Symbol(":bump")); end)[]
        AirDB.sync(db)
        @test db.resources[(:counter, Symbol(":mem-test"))][1] == UInt8['6']
        close(db)
    end
end
