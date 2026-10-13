################################################################################
# AirDB.jl
#
# A PostgreSQL-backed persistence layer built on Air.jl's software transactional
# memory.
#
# MIT License
# Copyright (c) 2020-2026 Noah C. Benson

module AirDB

using Air
# Air defines its own persistent verbs (distinct from Base's), so the methods in
# form.jl must extend Air's functions rather than shadow them.
import Air: setindex, push, pop, delete, deleteat
using UUIDs
using LibPQ

include("types.jl")
include("collections.jl")
include("config.jl")
include("form.jl")
include("json.jl")
include("volatile.jl")
include("database.jl")
include("retry.jl")
include("indexing.jl")
include("verbs.jl")
include("actor.jl")
include("cache.jl")
include("named.jl")
include("memory.jl")

end
