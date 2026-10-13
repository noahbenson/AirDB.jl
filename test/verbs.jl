@testset "verbs" begin
    f = form(10, 20, a = form(x = 1), b = 3)

    @testset "update" begin
        @test update(f, v -> value(v) + 1, :a, :x) == form(10, 20, a = form(x = 2), b = 3)
        @test update(f, v -> value(v) * 2, :b) == form(10, 20, a = form(x = 1), b = 6)
        @test f == form(10, 20, a = form(x = 1), b = 3)   # unchanged
    end

    @testset "merge" begin
        @test merge(form(a = 1), form(b = 2)) == form(a = 1, b = 2)
        @test merge(form(a = 1), form(a = 9, b = 2)) == form(a = 9, b = 2)   # later wins
        @test merge(form(1), form(2)) == form(1, 2)                          # sequences concat
        @test merge_with((x, y) -> value(x) + value(y), form(a = 1), form(a = 2, b = 3)) ==
              form(a = 3, b = 3)
    end

    @testset "haskey along a path" begin
        @test haskey(f, :a, :x)
        @test !haskey(f, :a, :z)
        @test !haskey(f, :z, :x)     # a missing intermediate is false, not an error
        @test haskey(f, :b)
        @test !haskey(f, :zzz)
    end

    @testset "select_keys" begin
        @test select_keys(f, [:b, :a]) == form(b = 3, a = form(x = 1))
        @test select_keys(f, [:a, :nope]) == form(a = form(x = 1))   # missing keys skipped
    end

    @testset "filter" begin
        g = form(1, "s", a = 2, b = "t")
        @test filter(v -> v isa FormScalar && value(v) isa Int64, g) == form(1, a = 2)
        @test filter(_ -> true, g) == g
        @test filter(_ -> false, g) == form()
        @test filter(_ -> false, Form(5)) == form()
        @test filter(_ -> true, Form(5)) == Form(5)
    end

    @testset "map_values and map_keys" begin
        @test map_values(v -> v isa FormScalar ? value(v) : v, form(1, a = 2)) == form(1, a = 2)
        @test map_values(v -> value(v) + 1, form(1, a = 2)) == form(2, a = 3)
        @test map_keys(k -> Symbol("k_", k), form(a = 1, b = 2)) == form(k_a = 1, k_b = 2)
        @test map_keys(k -> Symbol("k_", k), Form(5)) == Form(5)
    end

    @testset "deep_map" begin
        g = form(1, 2, a = form(x = 3))
        @test deep_map(v -> v isa FormScalar && value(v) isa Int64 ? Form(value(v) * 10) : v, g) ==
              form(10, 20, a = form(x = 30))
    end

    @testset "converting out" begin
        @test to_vector(form(1, 2, 3)) == [1, 2, 3]
        @test to_vector(form(a = 1)) == []
        @test to_vector(form(form(1, 2))) == [[1, 2]]
        @test to_dict(form(a = 1, b = form(x = 2))) ==
              Dict{Symbol,Any}(:a => 1, :b => Dict(:x => 2))
        @test to_dict(form(1, 2)) == Dict{Symbol,Any}()
    end
end
