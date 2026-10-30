@testset "JSON" begin
    @testset "round trips" begin
        for f in (form(), form(1, 2, 3), form("widget", 1, 2.5, meta = form(name = "abc")),
                  form([1, 2, 3], d = Dict(:x => 1)), form(true, false, nothing),
                  form(1 + 2im, 3.0, :sym), form(form(form(1))),
                  Form("abc"), Form(5), Form(2.5), Form(nothing), Form(true))
            @test from_JSON(to_JSON(f)) == f
        end
    end

    @testset "non-finite floats" begin
        # JSON has no infinity or NaN, so a non-finite float is a marked string
        @test to_JSON(Form(Inf)) == "\"#inf\""
        @test to_JSON(Form(-Inf)) == "\"#-inf\""
        @test to_JSON(Form(NaN)) == "\"#nan\""
        @test value(from_JSON(to_JSON(Form(Inf)))) === Inf
        @test value(from_JSON(to_JSON(Form(-Inf)))) === -Inf
        @test isnan(value(from_JSON(to_JSON(Form(NaN)))))
        # ... also inside a container and as a complex component
        f = from_JSON(to_JSON(form(Inf, -Inf, NaN)))
        @test value(f[1]) === Inf
        @test value(f[2]) === -Inf
        @test isnan(value(f[3]))
        z = value(from_JSON(to_JSON(Form(ComplexF64(Inf, NaN)))))
        @test z isa ComplexF64 && z.re === Inf && isnan(z.im)
        z = value(from_JSON(to_JSON(Form(ComplexF64(-Inf, 1.5)))))
        @test z isa ComplexF64 && z.re === -Inf && z.im === 1.5
        # a user string that looks like the encoding is still a string
        @test to_JSON(Form("#inf")) == "\"'#inf\""
        @test value(from_JSON(to_JSON(Form("#inf")))) == "#inf"
        # a finite float keeps its ordinary encoding, including negative zero,
        # and a narrower non-finite float is converted to Float64 first
        @test to_JSON(Form(-0.0)) == "-0.0"
        @test value(from_JSON("-0.0")) === -0.0
        @test to_JSON(Form(Inf32)) == "\"#inf\""
        # an unknown or malformed special float is an error
        @test_throws ArgumentError from_JSON("\"#Inf\"")
        @test_throws ArgumentError from_JSON("\"#\"")
        @test_throws ArgumentError from_JSON("\"#infinity\"")
    end

    @testset "encodings" begin
        # a string is marked with ', a symbol with :
        @test to_JSON(form(:a, "b")) == "[[\":a\", \"'b\"], {}]"
        # a scalar form is just its leaf
        @test to_JSON(Form(5)) == "5"
        @test to_JSON(Form("abc")) == "\"'abc\""
        @test to_JSON(Form(nothing)) == "null"
        # a float always carries a point or exponent so it reads back as a float
        @test to_JSON(form(3.0)) == "[[3.0], {}]"
        @test value(from_JSON(to_JSON(form(3.0)))[1]) === 3.0
        @test value(from_JSON("[[3], {}]")[1]) === Int64(3)
        # a complex number is always an object, even with a zero imaginary part
        @test to_JSON(form(1 + 0im)) == "[[{\"re\": 1.0, \"im\": 0.0}], {}]"
        @test value(from_JSON(to_JSON(form(1 + 0im)))[1]) === ComplexF64(1, 0)
        # a form is a two-element list; a bare object is a map-only form
        @test from_JSON("{\":a\": 1}") == form(a = 1)
        @test from_JSON("[[\"'x\"], {\":a\": 1}]") == form("x", a = 1)
        # a bare scalar is a scalar form
        @test from_JSON("5") == Form(5)
        @test from_JSON("5") isa FormScalar
        @test from_JSON("\"'abc\"") == Form("abc")
        # escapes and unicode
        @test from_JSON(to_JSON(form("a\nb\"c")))[1] == Form("a\nb\"c")
        @test from_JSON("[[\"'\\u0041\"], {}]")[1] == Form("A")
        # a keyword and a wildcard are distinct leaves whose prefixes are part of
        # the symbol's text (the marker is the first character inside the quotes)
        @test to_JSON(Form(:abc)) == "\":abc\""
        @test to_JSON(Form(Symbol(":abc"))) == "\"::abc\""
        @test to_JSON(Form(Symbol("?abc"))) == "\":?abc\""
        @test from_JSON(to_JSON(Form(Symbol(":abc")))) == Form(Symbol(":abc"))
        @test from_JSON(to_JSON(Form(Symbol("?abc")))) == Form(Symbol("?abc"))
        @test iskeyword(from_JSON(to_JSON(Form(Symbol(":abc")))))
        @test iswildcard(from_JSON(to_JSON(Form(Symbol("?abc")))))
    end

    @testset "numeric tower" begin
        # the marked encodings, and their exact types on the way back
        @test to_JSON(Form(big(5))) == "\"#big:5\""
        @test to_JSON(Form(big(-10)^40)) == "\"#big:$(big(-10)^40)\""
        @test value(from_JSON(to_JSON(Form(big(5))))) isa BigInt
        @test value(from_JSON(to_JSON(Form(big(5))))) == big(5)
        @test value(from_JSON("\"#big:5\"")) isa BigInt
        @test value(from_JSON("\"#big:5\"")) == big(5)
        @test value(from_JSON("123456789012345678901234567890")) ==
              big"123456789012345678901234567890"      # a bare integer too big for Int64
        @test value(from_JSON(to_JSON(Form(1 // 3)))) === 1 // 3
        @test to_JSON(Form(1 // 3)) == "\"#rat:1/3\""
        @test to_JSON(Form(-2 // 3)) == "\"#rat:-2/3\""
        @test to_JSON(Form(Rational{BigInt}(big(2)^100, 3))) ==
              "\"#bigrat:$(big(2)^100)/3\""
        @test value(from_JSON("\"#bigrat:$(big(2)^100)/3\"")) isa Rational{BigInt}
        @test value(from_JSON("\"#bigrat:$(big(2)^100)/3\"")) ==
              Rational{BigInt}(big(2)^100, 3)
        # a BigFloat keeps its value and its precision
        for p in (24, 64, 256, 1024)
            setprecision(BigFloat, p) do
                for x in (parse(BigFloat, "0.1"), prevfloat(parse(BigFloat, "1.0")),
                          nextfloat(parse(BigFloat, "1.0")), BigFloat(1e300),
                          BigFloat(1e-300), BigFloat(-0.0), BigFloat(Inf),
                          BigFloat(-Inf), BigFloat(NaN))
                    s = to_JSON(Form(x))
                    @test startswith(s, "\"#bigfloat:$p:")
                    y = value(from_JSON(s))
                    @test y isa BigFloat
                    @test precision(y) == p
                    @test isnan(x) ? isnan(y) : y == x
                end
            end
        end
        # a Complex{BigFloat} is the usual object with marked parts
        z = Complex{BigFloat}(parse(BigFloat, "1.5"), parse(BigFloat, "-2.5"))
        @test to_JSON(Form(z)) ==
              "{\"re\": \"#bigfloat:256:1.5\", \"im\": \"#bigfloat:256:-2.5\"}"
        g = value(from_JSON(to_JSON(Form(z))))
        @test g isa Complex{BigFloat} && g == z
        # malformed marked numbers are errors
        @test_throws ArgumentError from_JSON("\"#big:abc\"")
        @test_throws ArgumentError from_JSON("\"#rat:1/0\"")
        @test_throws ArgumentError from_JSON("\"#rat:1\"")
        @test_throws ArgumentError from_JSON("\"#bigrat:1/x\"")
        @test_throws ArgumentError from_JSON("\"#bigfloat:0:1.0\"")
        @test_throws ArgumentError from_JSON("\"#bigfloat:256\"")
        @test_throws ArgumentError from_JSON("\"#bigfloat:256:abc\"")
        # a mixed complex is an error (the writer never produces one)
        @test_throws ArgumentError from_JSON("{\"re\": 1.0, \"im\": \"#bigfloat:256:2.0\"}")
        @test_throws ArgumentError from_JSON("{\"re\": 1, \"im\": 2}")
    end

    @testset "form links" begin
        u = uuid4()
        # a resolver turns "@<uuid>" into a value
        g = from_JSON(id -> Symbol("link-", id), "[[\"@$u\"], {}]")
        @test value(g[1]) == Symbol("link-", u)
        # without a resolver, a link is an error
        @test_throws ArgumentError from_JSON("[[\"@$u\"], {}]")
        # a malformed link is an error even with a resolver
        @test_throws ArgumentError from_JSON(id -> id, "[[\"@not-a-uuid\"], {}]")
    end

    @testset "errors" begin
        @test_throws ArgumentError from_JSON("[[1], {}] trailing")
        @test_throws ArgumentError from_JSON("[[1]")
        @test_throws ArgumentError from_JSON("{\"a\": 1}")          # key lacks the : marker
        @test_throws ArgumentError from_JSON("[[\"x\"], {}]")        # string lacks a marker
        @test_throws ArgumentError from_JSON("")
    end
end
