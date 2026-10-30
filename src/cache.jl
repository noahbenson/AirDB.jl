################################################################################
# cache.jl
#
# The per-database caches of live database-backed forms: `VolatileForm`,
# `ActorForm`, and `PromiseForm`. Each is keyed by its UUID and held through a
# `WeakRef`, so a cache never keeps an object alive on its own: an object stays
# cached exactly as long as something else references it, and once nothing does it
# is released back to the database. The cache guarantees object identity — the
# same id always yields the same object within a process — which is what makes
# Air's transactional reads on a form coherent across threads.
#
# MIT License
# Copyright (c) 2020-2026 Noah C. Benson

# Which cache an object belongs to.
_cache_for(db::AbstractDatabase, ::VolatileForm) = db.cache
_cache_for(db::AbstractDatabase, ::ActorForm) = db.actorcache
_cache_for(db::AbstractDatabase, ::PromiseForm) = db.promisecache
_cache_for(db::AbstractDatabase, ::StreamForm) = db.streamcache

# Drop the entries whose object has been collected. A dead `WeakRef` is
# otherwise never removed, so a long-lived database would accumulate one entry
# per form it has ever loaded. This runs on insertion, now and then, rather than
# on every insert.
function _sweep_dead!(cache::Dict{UUID,WeakRef})
    for (k, wr) in collect(cache)
        wr.value === nothing && delete!(cache, k)
    end
    return nothing
end
_sweep_due(cache) = length(cache) >= 256 && (length(cache) & 255) == 0

function _cache_put!(cache::Dict{UUID,WeakRef}, l::ReentrantLock, obj, id::UUID)
    lock(l)
    try
        _sweep_due(cache) && _sweep_dead!(cache)
        cache[id] = WeakRef(obj)
    finally
        unlock(l)
    end
    return obj
end
_cache_put!(db::AbstractDatabase, obj) =
    _cache_put!(_cache_for(db, obj), db.cachelock, obj, obj.id)

# The cached object for `id`, or one made by `make`. The whole get-or-create runs
# under the cache lock, so two threads asking for the same id at once get the
# same object; holding the result in a local across the unlock keeps it from
# being collected before it is returned.
function _cached_ref(cache::Dict{UUID,WeakRef}, l::ReentrantLock, id::UUID, make::Function,
                     gclock::ReentrantLock)
    lock(l)
    try
        wr = get(cache, id, nothing)
        if wr !== nothing
            v = wr.value
            v === nothing || return v
        end
    finally
        unlock(l)
    end
    # A miss makes a row live. Serialize that with `gc!`, so a row cannot be
    # swept between being made live and being read.
    lock(gclock)
    try
        lock(l)
        try
            wr = get(cache, id, nothing)
            if wr !== nothing
                v = wr.value
                v === nothing || return v
            end
            obj = make()
            _sweep_due(cache) && _sweep_dead!(cache)
            cache[id] = WeakRef(obj)
            return obj
        finally
            unlock(l)
        end
    finally
        unlock(gclock)
    end
end

_cached_form(db::AbstractDatabase, id::UUID) =
    _cached_ref(db.cache, db.cachelock, id,
                () -> VolatileForm(id, nothing, false, true, ReentrantLock(), db,
                                   nothing, true), db.gclock)::VolatileForm
_cached_actor(db::AbstractDatabase, id::UUID) =
    _cached_ref(db.actorcache, db.cachelock, id,
                () -> ActorForm(id, nothing, false, true, ReentrantLock(), db,
                                true, nothing), db.gclock)::ActorForm
_cached_promise(db::AbstractDatabase, id::UUID) =
    _cached_ref(db.promisecache, db.cachelock, id,
                () -> PromiseForm(id, nothing, false, true, ReentrantLock(),
                                  db, nothing, :live), db.gclock)::PromiseForm
_cached_stream(db::AbstractDatabase, id::UUID) =
    _cached_ref(db.streamcache, db.cachelock, id,
                () -> StreamForm(id, nothing, false, true, ReentrantLock(),
                                 ReentrantLock(), db, nothing, :live),
                db.gclock)::StreamForm

"""
    get_form(db::AbstractDatabase, id::UUID) -> VolatileForm

The volatile form with the given id. If it is already cached it is returned
immediately; otherwise an unloaded form is created (its body is read from the
database on first access). The same id always yields the same object within a
`Database`.
"""
get_form(db::AbstractDatabase, id::UUID) = _cached_form(db, id)

"""
    get_actor(db::AbstractDatabase, id::UUID) -> ActorForm

The actor form with the given id, cached like [`get_form`](@ref).
"""
get_actor(db::AbstractDatabase, id::UUID) = _cached_actor(db, id)

"""
    get_promise(db::AbstractDatabase, id::UUID) -> PromiseForm

The promise form with the given id, cached like [`get_form`](@ref).
"""
get_promise(db::AbstractDatabase, id::UUID) = _cached_promise(db, id)

"""
    get_stream(db::AbstractDatabase, id::UUID) -> StreamForm

The stream form with the given id, cached like [`get_form`](@ref).
"""
get_stream(db::AbstractDatabase, id::UUID) = _cached_stream(db, id)
