# Extern data types for the representability predicate (one registered, one not).
mutable struct FormTestExtern <: AbstractAirExtern
    n::Int
end
AirDB.register_extern(:form_test_extern, FormTestExtern)
struct UnregisteredFormExtern <: AbstractAirExtern end

@testset "Form" begin
    @testset "is_form_representable" begin
        @test is_form_representable(5)
        @test is_form_representable(Int8(3))
        @test is_form_representable(big(5))
        @test is_form_representable(1 // 3)
        @test is_form_representable(big(1) // big(3))
        @test is_form_representable(2.5)
        @test is_form_representable(1.0f0)
        @test is_form_representable(big"1.5")
        @test is_form_representable(1 + 2im)
        @test is_form_representable(complex(big"1.5", big"2.5"))
        @test is_form_representable(complex(1 // 2, 3 // 2))  # exact Float64 parts
        @test !is_form_representable(complex(1 // 3, 0))
        @test is_form_representable('x')
        @test is_form_representable("abc")
        @test is_form_representable(:a)
        @test is_form_representable(nothing)
        @test is_form_representable(true)
        @test is_form_representable(π)                       # -> Float64
        @test is_form_representable(Form(5))
        @test is_form_representable(form(a = 1))
        @test is_form_representable([1, 2, [3]])
        @test is_form_representable(Dict(:a => 1, "b" => 2))
        @test !is_form_representable(Set([1, 2]))
        @test !is_form_representable(Dict(1 => 2))
        @test !is_form_representable([1, Set([2])])
        @test !is_form_representable(missing)
        @test is_form_representable(FormTestExtern(1))
        @test !is_form_representable(UnregisteredFormExtern())
    end

    @testset "scalar forms" begin
        @test Form("abc") isa FormScalar
        @test Form("abc") isa Form
        @test Form("abc") isa FormValue
        @test value(Form("abc")) == "abc"
        @test value(Form(:a)) === :a
        @test value(Form(5)) === Int64(5)
        @test value(Form(2.5)) === 2.5
        @test value(Form(true)) === true
        @test value(Form(nothing)) === nothing
        @test value(Form(1 + 2im)) === ComplexF64(1, 2)
        @test Form(5) == Form(5)
        @test Form(5) != Form(6)
        @test Form(5) == Form(5.0)          # Julia's numeric equality
        @test Form(1 + 2im) == Form(ComplexF64(1, 2))   # a narrower scalar converts
        @test hash(Form(5)) == hash(Form(5))
        @test sprint(show, Form(5)) == "Form(5)"
        @test sprint(show, Form("a")) == "Form(\"a\")"
    end

    @testset "container construction" begin
        @test form() isa FormContainer
        @test form() isa Form
        @test length(form(1, 2, 3)) == 3
        @test length(form(a = 1, b = 2)) == 2
        @test length(Form(5)) == 0          # a scalar form has no elements
        c = Form(PVector(FormValue[1, 2]), PDict{Symbol,FormValue}(:a => 3))
        @test c isa FormContainer
        @test value(c[1]) == 1
        @test value(c[:a]) == 3
    end

    @testset "reading wraps leaves into forms" begin
        f = form(10, 20, a = 30)
        @test f[1] == Form(10)
        @test f[1] isa FormScalar
        @test value(f[1]) === Int64(10)
        @test f[:a] == Form(30)
        @test value(f[:a]) === Int64(30)
        @test haskey(f, 2)
        @test !haskey(f, 3)
        @test haskey(f, :a)
        @test get(f, :a, :none) == Form(30)
        @test get(f, :z, :none) === :none
    end

    @testset "leaf conversions" begin
        @test value(form(Int8(3))[1]) === Int64(3)
        @test value(form(1.0f0)[1]) === Float64(1.0)
        @test value(form('x')[1]) == "x"
        @test value(form(1 + 2im)[1]) === ComplexF64(1, 2)
        @test value(form(true)[1]) === true
        @test value(form(nothing)[1]) === nothing
        @test value(form(:a)[1]) === :a
        @test value(form(SubString("abc", 1, 2))[1]) == "ab"
    end

    @testset "container isequal recurses with isequal" begin
        # a NaN compares equal to itself under isequal, so a container holding
        # one must too (and its hash already agrees)
        @test isequal(Form(NaN), Form(NaN))
        @test isequal(form(NaN), form(NaN))
        @test isequal(form(NaN, 1), form(NaN, 1))
        @test isequal(form(a = NaN), form(a = NaN))
        @test hash(form(NaN, 1)) == hash(form(NaN, 1))
        @test hash(form(a = NaN)) == hash(form(a = NaN))
        d = Dict{Any,Int}()
        d[form(NaN)] = 1
        @test get(d, form(NaN), :missing) == 1
        # signed zero: `==` compares numerically, but `isequal` and `hash`
        # agree that 0.0 and -0.0 are distinct keys
        z, nz = form(0.0), form(-0.0)
        @test z == nz
        @test !isequal(z, nz)
        @test hash(z) != hash(nz)
        @test !isequal(form(a = 0.0), form(a = -0.0))
        d2 = Dict{Any,Int}()
        d2[z] = 1
        @test get(d2, nz, :missing) == :missing
    end

    @testset "numeric tower leaves" begin
        # arbitrary-precision integers: a leaf type, and the fallback for an
        # integer that does not fit in an Int64
        @test Form(big(5)) isa FormScalar{BigInt}
        @test value(Form(big(5))) isa BigInt && value(Form(big(5))) == big(5)
        @test Form(Int128(2)^70) isa FormScalar{BigInt}
        @test value(Form(Int128(2)^70)) == big(2)^70
        @test value(Form(typemax(UInt64))) == BigInt(typemax(UInt64))
        @test value(Form(Int8(3))) === Int64(3)
        # floats widen only where exact
        @test value(Form(Float16(1.5))) === 1.5
        @test value(Form(1.0f0)) === 1.0
        @test Form(big"1.5") isa FormScalar{BigFloat}
        @test value(Form(big"1.5")) == big"1.5"
        # rationals keep their two exact leaf types; other component types are
        # canonicalized by fit
        @test Form(1 // 3) isa FormScalar{Rational{Int64}}
        @test value(Form(1 // 3)) === 1 // 3
        @test Form(Rational{BigInt}(1, 2)) isa FormScalar{Rational{BigInt}}
        @test Form(Rational{Int32}(1, 2)) isa FormScalar{Rational{Int64}}
        @test value(Form(Rational{Int32}(1, 2))) === 1 // 2
        bigrat = Rational{BigInt}(big(2)^100, 3)
        @test value(Form(bigrat)) isa Rational{BigInt}
        @test value(Form(bigrat)) == bigrat
        # complex: exact Float64 parts use ComplexF64, exact BigFloat parts use
        # Complex{BigFloat}, and a part that is exact in neither is rejected
        @test value(Form(1 + 2im)) === ComplexF64(1, 2)
        @test Form(Complex{BigFloat}(big(1), big(2))) isa FormScalar{Complex{BigFloat}}
        @test value(Form(Complex{BigFloat}(big(1), big(2)))) ==
              Complex{BigFloat}(big(1), big(2))
        @test value(Form(Complex{Rational{Int64}}(1 // 2, 3 // 2))) === ComplexF64(0.5, 1.5)
        @test_throws ArgumentError Form(Complex{Rational{Int64}}(1 // 3, 0 // 1))
        # equality stays numeric across leaf types
        @test Form(big(5)) == Form(5)
        @test Form(1 // 2) == Form(0.5)
        @test Form(Complex{BigFloat}(big(1), big(2))) == Form(1 + 2im)
    end

    @testset "collections become nested containers" begin
        v = form([1, 2, 3])
        @test v isa FormContainer
        @test v[1] isa FormContainer          # the vector argument became a container
        @test value(v[1][1]) == 1
        @test isempty(v.map)
        d = form(Dict(:a => 1, "b" => 2))
        @test d[1] isa FormContainer
        @test value(d[1][:a]) == 1
    end

    @testset "to_form" begin
        @test to_form(5) == Form(5)
        @test to_form("abc") == Form("abc")
        @test to_form(nothing) == Form(nothing)
        @test to_form(Form(5)) == Form(5)
        @test to_form([1, 2, 3]) == form(1, 2, 3)     # a vector becomes a sequence
        @test to_form(Dict(:a => 1)) == form(a = 1)
        @test to_form(form(a = 1)) == form(a = 1)
        @test_throws ArgumentError to_form(Set([1, 2]))
    end

    @testset "rejected values" begin
        @test_throws ArgumentError form(Set([1, 2]))
        @test_throws ArgumentError form(Dict(1 => 2))
        @test value(form(Int128(2)^70)[1]) == big(2)^70  # an integer too big for Int64
        @test_throws MethodError Form(1, 2)           # use form(1, 2)
    end

    @testset "updating" begin
        f = form(1, 2, 3)
        @test setindex(f, 9, 1) == form(9, 2, 3)
        @test setindex(f, 9, 2) == form(1, 9, 3)
        @test push(f, 4) == form(1, 2, 3, 4)
        @test pop(f) == form(1, 2)
        @test delete(f, 2) == form(1, 3)
        @test delete(form(a = 1, b = 2), :a) == form(b = 2)
        @test setindex(form(a = 1), 2, :b) == form(a = 1, b = 2)
        @test_throws ArgumentError pop(form(a = 1))
        @test f == form(1, 2, 3)      # the original is unchanged
    end

    @testset "equality and printing" begin
        @test form(1, 2) == form(1, 2)
        @test form(1, 2) != form(2, 1)
        @test hash(form(1, 2)) == hash(form(1, 2))
        @test form(a = 1) != form(a = 2)
        @test sprint(show, form("a", b = 1)) == "Form(\"a\", b=1)"
        @test sprint(show, form(form(1), 2)) == "Form((1), 2)"
        # keys print in sorted order, not insertion order
        @test sprint(show, form(b = 1, a = 2)) == "Form(a=2, b=1)"
    end

    @testset "collection protocol" begin
        f = form(10, 20, a = 30)
        @test length(f) == 3
        @test !isempty(f)
        @test isempty(form())
        @test length(Form(5)) == 0
        @test isempty(Form(5))
        # the canonical order: sequence positions, then sorted map keys
        @test collect(keys(f)) == Any[1, 2, :a]
        @test collect(values(f)) == [Form(10), Form(20), Form(30)]
        @test collect(pairs(f)) == [1 => Form(10), 2 => Form(20), :a => Form(30)]
        @test collect(f) == [1 => Form(10), 2 => Form(20), :a => Form(30)]
        @test first(f) == (1 => Form(10))
        @test last(f) == (:a => Form(30))
        @test Dict(collect(f)) == Dict(1 => Form(10), 2 => Form(20), :a => Form(30))
        # a scalar form has no elements
        @test isempty(keys(Form(5)))
        @test iterate(Form(5)) === nothing
        # copy is identity (forms are immutable); empty is the empty container
        @test copy(f) === f
        @test empty(f) == form()
        @test empty(Form(5)) == form()
    end

    @testset "keywords and wildcards" begin
        # iskeyword / iswildcard classify the symbol leaves
        @test iskeyword(Form(Symbol(":abc")))
        @test !iskeyword(Form(:abc))
        @test !iskeyword(Form(Symbol("?abc")))
        @test !iskeyword(Form(5))
        @test !iskeyword(form(a = 1))
        @test iswildcard(Form(Symbol("?abc")))
        @test !iswildcard(Form(:abc))
        @test !iswildcard(Form(Symbol(":abc")))
        @test !iswildcard(Form(5))
        @test !iswildcard(form(a = 1))
        # only a leading marker counts
        @test !iskeyword(Form(Symbol("a:b")))
        @test !iswildcard(Form(Symbol("a?b")))
        # a keyword and a wildcard are distinct leaves
        @test Form(Symbol(":abc")) != Form(Symbol("?abc"))
        @test Form(Symbol(":abc")) != Form(:abc)
        @test Form(Symbol("?abc")) != Form(:abc)
        # and they carry through a container and its equality
        @test iskeyword(form(a = Form(Symbol(":k")))[:a])
        @test form(a = Form(Symbol("?k"))) == form(a = Form(Symbol("?k")))
        @test form(a = Form(Symbol("?k"))) != form(a = Form(Symbol(":k")))
    end

    @testset "sequence ranges" begin
        f = form(10, 20, 30, 40)
        @test f[2:3] == form(20, 30)          # a form over the subsequence
        @test f[:] == f
        @test collect(f.seq[2:3]) == Any[20, 30]
        @test f.seq[2:3] isa AirDB.FormSeq    # the subsequence is a FormSeq, not a Vector
        @test collect(f.seq[[1, 3]]) == Any[10, 30]
        # a range past the flat threshold still promotes
        big = form((1:40)...)
        @test length(big.seq[10:30]) == 21
    end

    @testset "small-to-large promotion" begin
        # a sequence grown past the flat threshold promotes and keeps working
        f = form(1, 2, 3)
        for i in 4:40
            f = push(f, i)
        end
        @test length(f) == 40
        @test value(f[1]) == 1 && value(f[40]) == 40
        @test length(delete(f, 1)) == 39
        @test length(pop(f)) == 39
        # a map grown past the threshold promotes and keeps working
        m = form(a = 1)
        for i in 1:40
            m = setindex(m, i, Symbol("k", i))
        end
        @test length(m) == 41
        @test value(m[:a]) == 1 && value(m[Symbol("k", 40)]) == 40
        @test !haskey(m, :nope)
        # a flat and a promoted form with the same content are equal and hash equal
        p = setindex(form(1, 2, 3), 4, 4)
        @test p == form(1, 2, 3, 4)
        @test hash(p) == hash(form(1, 2, 3, 4))
        # construction from a large collection promotes
        big = form((1:40)...)
        @test length(big) == 40 && value(big[40]) == 40
    end
end
