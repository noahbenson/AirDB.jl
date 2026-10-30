# Form equivalence: a relation distinct from `==`, with its own hash.

# An already-registered immutable extern type with value semantics.
struct EqExtern <: AbstractAirExtern
    v::Int
end
AirDB.register_extern(:eqext, EqExtern;
    constructors = PDict(Symbol(":new") => a -> EqExtern(Int(value(a)))),
    immutable = true,
    equal = (a, b) -> a.v == b.v,
    hash = (x, h) -> hash(x.v, h))

@testset "form equivalence" begin
    @testset "leaves and containers" begin
        # leaf type is part of equivalence, unlike `==`
        @test isequiv(Form(5), Form(5))
        @test Form(5) == Form(5.0)          # equality is numeric
        @test !isequiv(Form(5), Form(5.0))
        @test isequiv(Form(big(5)), Form(big(5)))
        @test !isequiv(Form(big(5)), Form(5))
        @test isequiv(Form(1 // 2), Form(1 // 2))
        @test !isequiv(Form(1 // 2), Form(Rational{BigInt}(1, 2)))
        @test isequiv(Form("a"), Form("a"))
        @test !isequiv(Form("a"), Form(:a))
        @test isequiv(Form(true), Form(true))
        @test !isequiv(Form(true), Form(1))
        @test isequiv(Form(nothing), Form(nothing))
        # NaN is equivalent to itself; signed zero is equivalent to zero
        @test isequiv(Form(NaN), Form(NaN))
        @test isequiv(Form(-0.0), Form(0.0))
        @test isequiv(Form(big(NaN)), Form(big(NaN)))
        @test isequiv(Form(complex(NaN, 1.0)), Form(complex(NaN, 1.0)))
        @test !isequiv(Form(complex(NaN, 1.0)), Form(complex(NaN, 2.0)))
        # containers are structural; map order does not matter
        @test isequiv(form(a = 1, b = 2), form(b = 2, a = 1))
        @test !isequiv(form(a = 1), form(a = 2))
        @test !isequiv(form(a = 1), form(b = 1))
        @test isequiv(form(1, 2), form(1, 2))
        @test !isequiv(form(1, 2), form(2, 1))
        @test isequiv(form(NaN), form(NaN))
        @test !isequiv(form(5), form(5.0))
        @test !isequiv(Form(5), form(5))
    end

    @testset "mutable forms" begin
        db = MemoryDatabase()
        vf = VolatileForm(db, a = 1)
        af = ActorForm(db, form(n = 0))
        pf = PromiseForm(db)
        sf = StreamForm(db)
        @test isequiv(vf, vf) && isequiv(af, af) && isequiv(pf, pf) && isequiv(sf, sf)
        # distinct live objects are never equivalent, even with equal contents
        @test !isequiv(vf, VolatileForm(db, a = 1))
        @test !isequiv(ActorForm(db, form(n = 0)), ActorForm(db, form(n = 0)))
        # a reloaded form with the same id is the same object while it is alive
        @test isequiv(vf, get_form(db, vf.id))
        @test equivhash(vf) == equivhash(vf)
        close(db)
    end

    @testset "delays" begin
        AirDB.register_delay(:equiv_double, f -> Form(2 * value(f)))
        @test isequiv(DelayForm(:equiv_double, Form(3)),
                      DelayForm(:equiv_double, Form(3)))
        @test !isequiv(DelayForm(:equiv_double, Form(3)),
                       DelayForm(:equiv_double, Form(4)))
        @test equivhash(DelayForm(:equiv_double, Form(3))) ==
              equivhash(DelayForm(:equiv_double, Form(3)))
    end

    @testset "externs" begin
        # mutable externs are identity only
        c1 = construct(get_extern_API(:counter), Form(Symbol(":new")), Form(3))
        c2 = construct(get_extern_API(:counter), Form(Symbol(":new")), Form(3))
        @test isequiv(c1, c1)
        @test !isequiv(c1, c2)
        # immutable externs without equal/hash are identity only
        k1 = construct(get_extern_API(:config), Form(Symbol(":new")), Form(3))
        k2 = construct(get_extern_API(:config), Form(Symbol(":new")), Form(3))
        @test isequiv(k1, k1)
        @test !isequiv(k1, k2)
        # an immutable type with equal/hash gets value semantics
        e1 = construct(get_extern_API(:eqext), Form(Symbol(":new")), Form(7))
        e2 = construct(get_extern_API(:eqext), Form(Symbol(":new")), Form(7))
        e3 = construct(get_extern_API(:eqext), Form(Symbol(":new")), Form(8))
        @test isequiv(e1, e2)
        @test !isequiv(e1, e3)
        @test equivhash(e1) == equivhash(e2)
        # different extern types never compare
        @test !isequiv(e1, k1)
        @test !isequiv(e1, c1)
    end

    @testset "hash consistency" begin
        forms = Any[Form(5), Form(5.0), Form(big(5)), Form(1 // 2), Form(0.5),
                    Form(NaN), Form(-0.0), Form(0.0), Form("a"), Form(:a),
                    form(a = 1, b = NaN), form(b = NaN, a = 1), form(1, 2),
                    Form(complex(NaN, 1.0)), form(a = form(b = 1))]
        for a in forms, b in forms
            isequiv(a, b) && @test equivhash(a) == equivhash(b)
        end
        @test isequiv(form(a = NaN), form(a = NaN))
        # BigFloat precision does not affect equivalence or the hash
        x256 = setprecision(256) do
            BigFloat(1.5)
        end
        x1024 = setprecision(1024) do
            BigFloat(1.5)
        end
        @test precision(x256) != precision(x1024)
        @test isequiv(Form(x256), Form(x1024))
        @test equivhash(Form(x256)) == equivhash(Form(x1024))
    end
end
