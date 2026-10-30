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
import Air: setindex, push, pop, delete, deleteat, send, take, fail!, isfailed,
    maxsize, snapshot
using UUIDs
using LibPQ

include("types.jl")
include("collections.jl")
include("config.jl")
include("form.jl")
include("externs.jl")
include("ref_forms.jl")
include("stream_forms.jl")
include("equivalence.jl")
include("json.jl")
include("volatile.jl")
include("failures.jl")
include("database.jl")
include("retry.jl")
include("indexing.jl")
include("verbs.jl")
include("actor.jl")
include("pipeline.jl")
include("cache.jl")
include("named.jl")
include("memory.jl")
include("gc.jl")

end
