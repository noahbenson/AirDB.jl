@testset "Form indexing" begin
    f = form(10, 20, a = form(x = 1, y = 2), b = form(x = 3))

    @testset "scalar paths" begin
        @test value(f[1]) == 10
        @test value(f[2]) == 20
        @test f[:a] == form(x = 1, y = 2)
        @test value(f[:a, :x]) == 1
        @test f[:a, :x] == f[:a][:x]
        @test value(f[:a, :y]) == 2
        # a leaf comes back as a scalar form
        @test f[1] == Form(10)
        @test f[1] isa FormScalar
    end

    @testset "fan-out" begin
        # a vector key builds a form over the selection
        @test f[[:a, :b], :x] == form(a = 1, b = 3)
        # a deeper vector key adds a nesting level (outer product)
        @test f[[:a, :b], [:x]] == form(a = form(x = 1), b = form(x = 3))
        @test f[[:a], [:x, :y]] == form(a = form(x = 1, y = 2))
        # every branch must resolve
        @test_throws KeyError f[[:a, :b], [:x, :y]]
        # `:` selects every sequence position and map key
        g = form(form(x = 10), form(x = 20), a = form(x = 30))
        @test g[:, :x] == form(10, 20, a = 30)
    end

    @testset "get" begin
        @test get(f, :a, :x, :none) == Form(1)
        @test get(f, :a, :z, :none) === :none
        @test get(f, :z, :none) === :none
        @test get(f, [:a, :b], :x, :none) == form(a = 1, b = 3)
        # a missing intermediate still raises
        @test_throws KeyError get(f, :z, :x, :none)
    end

    @testset "functional setindex" begin
        @test setindex(f, 99, :a, :x) == form(10, 20, a = form(x = 99, y = 2), b = form(x = 3))
        @test setindex(f, 5, 1) == form(5, 20, a = form(x = 1, y = 2), b = form(x = 3))
        @test setindex(f, 42, :c) == form(10, 20, a = form(x = 1, y = 2), b = form(x = 3), c = 42)
        # fan-out builds a form over the selection
        @test setindex(f, 99, [:a, :b], :x) == form(a = form(x = 99, y = 2), b = form(x = 99))
        # the original is unchanged
        @test f == form(10, 20, a = form(x = 1, y = 2), b = form(x = 3))
    end

    @testset "append and shifting delete" begin
        v = form(1, 2, 3)
        @test setindex(v, 4, 4) == form(1, 2, 3, 4)   # index length+1 appends
        @test push(v, 4) == form(1, 2, 3, 4)
        @test delete(v, 2) == form(1, 3)              # items shift down, no blanks
        @test_throws BoundsError setindex(v, 9, 5)    # beyond the append position
        @test_throws BoundsError v[4]
    end

    @testset "map" begin
        @test map(x -> x * 2, form(1, 2, a = 3)) == form(2, 4, a = 6)
        @test map(identity, f) == f
        @test map(x -> x + 1, Form(5)) == Form(6)     # a scalar form
    end

    @testset "errors" begin
        @test_throws KeyError f[:z]
        @test_throws BoundsError f[3]
        @test_throws Exception f[1, 1]        # 10 is a leaf, not indexable
        @test_throws ArgumentError f[1.5]
    end
end
