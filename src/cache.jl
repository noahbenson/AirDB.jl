################################################################################
# cache.jl
#
# The per-database cache of live `VolatileForm`s. Each form is keyed by its UUID
# and held through a `WeakRef`, so the cache never keeps a form alive on its own:
# a form stays cached exactly as long as something else references it, and once
# nothing does it is released back to the database. The cache guarantees object
# identity — the same id always yields the same object within a process — which
# is what makes Air's transactional reads on a form coherent across threads.
#
# MIT License
# Copyright (c) 2020-2026 Noah C. Benson

function _cache_put!(db::AbstractDatabase, vf::VolatileForm)
    lock(db.cachelock)
    try
        db.cache[vf.id] = WeakRef(vf)
    finally
        unlock(db.cachelock)
    end
    return vf
end

# The cached form for `id`, or a fresh unloaded one. The whole get-or-create runs
# under the cache lock, so two threads asking for the same id at once get the
# same object; holding `vf` in a local across the unlock keeps it from being
# collected before it is returned.
function _cached_form(db::AbstractDatabase, id::UUID)
    lock(db.cachelock)
    try
        wr = get(db.cache, id, nothing)
        if wr !== nothing
            v = wr.value
            v === nothing || return v::VolatileForm
        end
        vf = VolatileForm(id, nothing, false, true, ReentrantLock(), db)
        db.cache[id] = WeakRef(vf)
        return vf
    finally
        unlock(db.cachelock)
    end
end

"""
    get_form(db::AbstractDatabase, id::UUID) -> VolatileForm

The volatile form with the given id. If it is already cached it is returned
immediately; otherwise an unloaded form is created (its body is read from the
database on first access). The same id always yields the same object within a
`Database`.
"""
get_form(db::AbstractDatabase, id::UUID) = _cached_form(db, id)
