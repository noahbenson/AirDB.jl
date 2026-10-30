using Test
using AirDB
using Air
using UUIDs
using LibPQ

include("helpers.jl")
include("form.jl")
include("externs.jl")
include("ref_forms.jl")
include("streams.jl")
include("json.jl")
include("indexing.jl")
include("verbs.jl")
include("memory.jl")        # no PostgreSQL needed
include("gc.jl")            # the in-memory sweep; the PostgreSQL one is in persist.jl
include("regressions.jl")   # the pre-0.1.0 review's confirmed defects
include("equivalence.jl")   # form equivalence and its hash

const _TEST_CFG = _test_config()

if _db_available(_TEST_CFG)
    include("database.jl")
    include("persist.jl")
    include("named.jl")
    include("batching.jl")
    include("failure.jl")
    include("isolation.jl")
    include("retry.jl")
    include("encoding.jl")
    include("pipeline.jl")
else
    @warn "PostgreSQL is not reachable; skipping the database tests. " *
          "Start a test server with `docker compose up -d`."
end

if Base.find_package("Aqua") === nothing
    @warn "Aqua is not available; skipping the Aqua tests."
else
    include("aqua.jl")
end
