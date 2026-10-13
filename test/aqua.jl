using Aqua

@testset "Aqua" begin
    Aqua.test_all(AirDB;
        # AirDB is a package under active development and depends on a local
        # checkout of Air, so the dependency checks are not meaningful here.
        deps_compat = false,
        stale_deps = false,
        project_extras = false,
    )
end
