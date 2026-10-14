using Test
using AirDB
using Air
using UUIDs
using LibPQ

include("helpers.jl")
include("form.jl")
include("externs.jl")
include("json.jl")
include("indexing.jl")
include("verbs.jl")
include("memory.jl")        # no PostgreSQL needed

const _TEST_CFG = _test_config()

if _db_available(_TEST_CFG)
    include("database.jl")
    include("persist.jl")
    include("named.jl")
    include("batching.jl")
    include("failure.jl")
    include("retry.jl")
else
    @warn "PostgreSQL is not reachable; skipping the database tests. " *
          "Start a test server with `docker compose up -d`."
end

if Base.find_package("Aqua") === nothing
    @warn "Aqua is not available; skipping the Aqua tests."
else
    include("aqua.jl")
end
