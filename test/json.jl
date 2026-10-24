@testset "JSON" begin
    @testset "round trips" begin
        for f in (form(), form(1, 2, 3), form("widget", 1, 2.5, meta = form(name = "abc")),
                  form([1, 2, 3], d = Dict(:x => 1)), form(true, false, nothing),
                  form(1 + 2im, 3.0, :sym), form(form(form(1))),
                  Form("abc"), Form(5), Form(2.5), Form(nothing), Form(true))
            @test from_JSON(to_JSON(f)) == f
        end
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
