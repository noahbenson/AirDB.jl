# Host-level extern types: values a form holds without being JSON themselves.

# A provider that serializes to a small map and compares by its contents.
struct ConfigHandle <: AbstractAirExtern
    version::Int
    label::String
end
AirDB.serialize_extern(c::ConfigHandle) = Dict("version" => c.version, "label" => c.label)
AirDB.deserialize_extern(::Val{:config}, p::AbstractDict) =
    ConfigHandle(Int(p[:version]), String(p[:label]))
AirDB.register_extern(:config, ConfigHandle;
                      isequal = (a, b) -> a.version == b.version && a.label == b.label,
                      hash = (x, h) -> hash(x.version, hash(x.label, h)))

# A provider that opts out of custom equality: the default is identity. It is
# mutable, so two handles with the same number are still two objects.
mutable struct OpaqueHandle <: AbstractAirExtern
    n::Int
end
AirDB.serialize_extern(o::OpaqueHandle) = o.n
AirDB.deserialize_extern(::Val{:opaque}, p) = OpaqueHandle(Int(p))
AirDB.register_extern(:opaque, OpaqueHandle)

# A type that is never registered.
struct UnregisteredHandle <: AbstractAirExtern
    n::Int
end
AirDB.serialize_extern(o::UnregisteredHandle) = o.n

@testset "externs" begin
    @testset "the type" begin
        x = ConfigHandle(1, "a")
        fe = FormExtern(x)
        @test fe isa Form
        @test fe isa FormValue
        @test fe isa AirDB.FormNode
        @test fe isa FormExtern{ConfigHandle}
        @test value(fe) === x
        @test to_form(x) == fe
        @test to_form(x) isa FormExtern{ConfigHandle}
        @test FormExtern(x) isa FormExtern{ConfigHandle}
        @test sprint(show, fe) == "FormExtern(ConfigHandle(1, \"a\"))"
        # an extern nests in a container, both as an argument and as a stored value
        @test form(x)[1] == fe
        @test form(1, x)[2] == fe
        @test form(a = x)[:a] == fe
        @test value(form(x)[1]) === x
    end

    @testset "JSON" begin
        # a map payload goes through the ordinary form encoding
        x = ConfigHandle(2, "b")
        s = AirDB.to_JSON(FormExtern(x))
        @test s == "[\"'extern\", \":config\", [[], {\":label\": \"'b\", \":version\": 2}]]"
        @test AirDB.from_JSON(s) == FormExtern(x)
        # a scalar payload is written as the bare leaf
        @test AirDB.to_JSON(FormExtern(OpaqueHandle(7))) == "[\"'extern\", \":opaque\", 7]"
        o = AirDB.from_JSON("[\"'extern\", \":opaque\", 7]")
        @test o isa FormExtern{OpaqueHandle}
        @test value(o).n == 7
        # an extern round-trips nested inside a container
        c = form(1, ConfigHandle(3, "c"), k = ConfigHandle(4, "d"))
        @test AirDB.from_JSON(AirDB.to_JSON(c)) == c
    end

    @testset "equality and hashing" begin
        # a registered `isequal` compares by value
        @test FormExtern(ConfigHandle(1, "a")) == FormExtern(ConfigHandle(1, "a"))
        @test FormExtern(ConfigHandle(1, "a")) != FormExtern(ConfigHandle(2, "a"))
        @test isequal(FormExtern(ConfigHandle(1, "a")), FormExtern(ConfigHandle(1, "a")))
        @test hash(FormExtern(ConfigHandle(1, "a"))) == hash(FormExtern(ConfigHandle(1, "a")))
        # the default is identity
        o = OpaqueHandle(1)
        @test FormExtern(o) == FormExtern(o)
        @test FormExtern(o) != FormExtern(OpaqueHandle(1))
        @test hash(FormExtern(o)) == hash(FormExtern(o))
        # different concrete types are never equal
        @test FormExtern(ConfigHandle(1, "a")) != FormExtern(OpaqueHandle(1))
        # and an extern is never equal to a plain form
        @test FormExtern(ConfigHandle(1, "a")) != Form(1)
        # a container holding equal externs is equal and hashes equal
        @test form(ConfigHandle(1, "a")) == form(ConfigHandle(1, "a"))
        @test hash(form(ConfigHandle(1, "a"))) == hash(form(ConfigHandle(1, "a")))
        @test form(ConfigHandle(1, "a")) != form(ConfigHandle(2, "a"))
    end

    @testset "tombstones" begin
        @test_throws ExternTombstone AirDB.from_JSON("[\"'extern\", \":config\", \":abandoned\"]")
        @test_throws ExternTombstone AirDB.from_JSON("[\"'extern\", \":opaque\", \":expired\"]")
        e = try
            AirDB.from_JSON("[\"'extern\", \":config\", \":abandoned\"]")
        catch err
            err
        end
        @test e isa ExternTombstone
        @test e.name === :config
        @test e.kind === :abandoned
    end

    @testset "errors" begin
        # reading a form whose extern type is not registered
        @test_throws ExternError AirDB.from_JSON("[\"'extern\", \":nope\", 1]")
        msg = sprint(showerror, try
            AirDB.from_JSON("[\"'extern\", \":nope\", 1]")
        catch err
            err
        end)
        @test occursin(":nope", msg)
        # writing a form whose extern type is not registered
        @test_throws ExternError AirDB.to_JSON(FormExtern(UnregisteredHandle(1)))
        # a name cannot be re-used for another type, but re-registering is a no-op
        @test_throws ExternError register_extern(:config, OpaqueHandle)
        @test register_extern(:config, ConfigHandle).name === :config
    end

    @testset "through a database" begin
        db = MemoryDatabase()
        vf = VolatileForm(db, form(a = 1))
        @tx setindex!(vf, form(cfg = ConfigHandle(5, "e"), 1, 2))
        AirDB.sync(db)
        f = get_form(db, vf.id)[]
        @test f == form(cfg = ConfigHandle(5, "e"), 1, 2)
        @test f[:cfg] isa FormExtern{ConfigHandle}
        @test value(f[:cfg]) == ConfigHandle(5, "e")
        close(db)
    end
end
