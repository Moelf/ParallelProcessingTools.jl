# This file is a part of ParallelProcessingTools.jl, licensed under the MIT License (MIT).

"""
    FlexWorkerPool{WP<:AbstractWorkerPool}(
        worker_pids::AbstractVector{Int} = [Distributed.myid()];
        oversubscription::Int = 1, init_workers::Bool = true
    )::AbstractWorkerPool

    FlexWorkerPool(args...; kwargs...)

An flexible worker pool, intended to work with cluster managers that may
add and remove Julia processes dynamically.

If the current process (`Distributed.myid()`) is part of the pool, it will
only be used as a fallback while no other processes are members of the pool
(e.g. because no other processes have been added yet or because all other
processes in the pool have terminated and been removed from it). The
current process will *not* be used as a fallback because all other workers
are currently in use.

Values greater than zero for `oversubscription` will the same workers in
be used `oversubscription` times in parallel. So `take!(pool)` may return
the same process ID `pid` multiple times without a `put!(pool, pid)` in
between. A moderate oversubscription can be useful to reduce idle times on
workers, e.g. when functions running on the workers are blocked waiting for
I/O. Note: Workers still need to be put back the same number of times they
were taken from the pool, in total.

If `init_workers` is `true`, workers taken from the pool will be guaranteed
to be initialized to the current global initialization level
(see [`@always_everywhere`](@ref)).

`WP` is the type of the underlying worker pool used, e.g.
`Distributed.WorkerPool` (default) or `Distributed.CachingPool`.

Example:

```julia
using ParallelProcessingTools, Distributed

pool = FlexWorkerPool(oversubscription = 2)

pids = [take!(pool) for _ in 1:3]
pids == repeat([myid()], 3)
foreach(pid -> put!(pool, pid), pids)

addprocs(4)
worker_procs = workers()

pids = [take!(pool) for _ in 1:4*3]
pids == repeat(worker_procs, 3)
foreach(pid -> put(pool, pid), pids)
rmprocs(worker_procs)

pids = [take!(pool) for _ in 1:3]
pids == repeat(myid(), 3)
foreach(pid -> put!(pool, pid), pids)
```
"""
struct FlexWorkerPool{WP<:AbstractWorkerPool} <: AbstractWorkerPool
    _pool::WP
    _mypid_pool::WorkerPool
    _label::String
    _oversubscription::Int
    _init_workers::Bool
    _spares::Channel{Tuple{Int,Int}}
    _worker_mgmt::Threads.Condition
    _worker_history::Set{Int}
end
export FlexWorkerPool


function FlexWorkerPool{WP}(
    worker_pids::AbstractVector{Int} = [Distributed.myid()];
    label::AbstractString = "",
    oversubscription::Int = 1, init_workers::Bool = true
) where {WP <: AbstractWorkerPool}
    @argcheck oversubscription >= 1

    pool = WP(Int[])
    mypid_pool = WorkerPool(Int[])
    spares = Channel{Tuple{Int,Int}}(typemax(Int))
    worker_mgmt = Threads.Condition()
    worker_history = Set{Int}()

    mypid = myid()
    for _ in 1:oversubscription
        for pid in worker_pids
            if isvalid_pid(pid)
                if pid != mypid
                    push!(pool, pid)
                else
                    push!(mypid_pool, pid)
                end
                push!(worker_history, pid)
            end
        end
    end

    FlexWorkerPool{WP}(pool, mypid_pool, label, oversubscription, init_workers, spares, worker_mgmt, worker_history)
end

function FlexWorkerPool(worker_pids::AbstractVector{Int} = [Distributed.myid()]; kwargs...)
    return FlexWorkerPool{WorkerPool}(worker_pids; kwargs...)
end

function Base.show(io::IO, @nospecialize(fwp::FlexWorkerPool))
    print(io, "FlexWorkerPool{$(nameof(typeof(fwp._pool)))}(...")
    if !isempty(fwp._label)
        print(io, ", label=\"", fwp._label, "\"")
    end
    print(io, ")")
end

function Base.length(fwp::FlexWorkerPool)
    l = length(fwp._pool)
    l > 0 ? l : length(fwp._mypid_pool)
end


function Base.isready(fwp::FlexWorkerPool)
    _use_main_pool(fwp) ? isready(fwp._pool) : isready(fwp._mypid_pool)
end

function _use_main_pool(fwp::FlexWorkerPool)
    length(fwp._pool) > 0 || length(fwp._mypid_pool) == 0
end

function Distributed.workers(fwp::FlexWorkerPool)
    _use_main_pool(fwp) ? workers(fwp._pool) : workers(fwp._mypid_pool)
end


function Base.push!(fwp::FlexWorkerPool, pid::Int)
    try lock(fwp._worker_mgmt)
        if isvalid_pid(pid)
            # Adding workers that are already in the pool must not increase oversubscription:
            if !in(pid, fwp._worker_history)
                mypid = myid()
                if pid == mypid
                    @assert length(fwp._mypid_pool) == 0
                    for _ in 1:fwp._oversubscription
                        push!(fwp._mypid_pool, mypid)
                    end
                    return fwp
                else
                    ## ToDo: Re-enable greedy/background worker init?
                    #if fwp._init_workers
                    #    Threads.@spawn ensure_procinit_or_kill(pid)
                    #end

                    # Add worker to pool only once, hold oversubscription in reserve. We
                    # want to spread it out over the worker queue:
                    push!(fwp._pool, pid)
                    if fwp._oversubscription > 1
                        push!(fwp._spares, (pid, fwp._oversubscription - 1))
                    end
                    notify(fwp._worker_mgmt)
                end
            end
        else
            @warn "Not adding invalid process ID $pid to $(getlabel(fwp))."
        end

        return fwp
    finally
        unlock(fwp._worker_mgmt)
    end
end


function Base.put!(fwp::FlexWorkerPool, pid::Int)
    pid != myid() ? put!(fwp._pool, pid) : put!(fwp._mypid_pool, pid)
    return pid
end


function Base.take!(fwp::FlexWorkerPool)
    while true
        pid::Int = _take_worker_noinit!(fwp)
        if fwp._init_workers
            try
                wait_for_all(ensure_procinit(pid))
                return pid
            catch err
                orig_err = inner_exception(err)
                @warn "Error while initializig process $pid, removing it." orig_err
                rmprocs(pid)
            end
        else
            return pid
        end
    end
end

function _take_worker_noinit!(fwp::FlexWorkerPool)
    while true
        if (!isready(fwp._pool) || length(fwp._pool) == 0) && isready(fwp._spares)
            _add_spare_to_pool!(fwp._spares, fwp._pool)
        end

        try
            if _use_main_pool(fwp)
                if length(fwp._pool) > 0
                    return take!(fwp._pool)
                else
                    yield()
                    lock(fwp._worker_mgmt) do
                        if length(fwp._pool) == 0
                            wait(fwp._worker_mgmt)
                        end
                    end
                end
            else
                return take!(fwp._mypid_pool)
            end
        catch err
            if err isa ErrorException && length(fwp._pool) == 0
                # err probably is `ErrorException("No active worker available in pool")`,
                # we can deal with that, so ignore it.
            else
                rethrow()
            end
        end
    end
end

const _invalid_pid_counter = Threads.Atomic{UInt}()

function _add_spare_to_pool!(spares::Channel{Tuple{Int,Int}}, @nospecialize(pool::AbstractWorkerPool))
    # `spares` may not be ready, even if checked before (due to a race condition).
    # So we put in an invalid dummy entry to ensure we can take from it
    # immediately. No one but us may take it out without putting it back in.

    invalid_pid_counterval = Threads.atomic_add!(_invalid_pid_counter, UInt(1))
    invalid_pid = -Int((invalid_pid_counterval << 2 >> 2) + UInt(1))

    put!(spares, (invalid_pid, 0))
    while isready(spares)
        pid, remaining_oversubscription = take!(spares)
        if pid == invalid_pid
            # Ensure loop terminates, we added dummy_id to the end of spares:
            break
        elseif pid < 0
            # Invalid dummy id put into spares by someone else, need to put it back:
            put!(spares, (pid, remaining_oversubscription))
        else
            @assert pid > 0 && remaining_oversubscription > 0
            push!(pool, pid)
            if remaining_oversubscription > 1
                put!(spares, (pid, remaining_oversubscription - 1))
            end
        end
    end
    return nothing
end


"""
    clear_worker_caches!(pool::AbstractWorkerPool)

Clear the worker caches (cached function closures, etc.) on the workers In
`pool`.

Does nothing if the pool doesn't perform any on-worker caching.
"""
function clear_worker_caches! end
export clear_worker_caches!

clear_worker_caches!(::AbstractWorkerPool) = nothing

clear_worker_caches!(fwp::FlexWorkerPool{<:CachingPool}) = clear_worker_caches!(fwp._pool)

function clear_worker_caches!(wp::CachingPool)
    clear!(wp._pool)
    return nothing
end


# ToDo: Use atomic reference on recent Julia versions:
const _g_default_wp = Ref{Union{AbstractWorkerPool,Nothing}}(nothing)
const _g_default_wp_lock = ReentrantLock()

"""
    default_flex_worker_pool()

Returns the default flexible worker pool, an instance of
[`FlexWorkerPool`](@ref).

If the default instance doesn't exist yet, then a `FlexWorkerPool` will be
created that initially contains `Distributed.myid()` as the only worker.
"""
function default_flex_worker_pool()
    lock(_g_default_wp_lock)
    wp = _g_default_wp[]
    unlock(_g_default_wp_lock)
    if isnothing(wp)
        lock(_g_default_wp_lock) do
            wp = _g_default_wp[]
            if isnothing(wp)
                return default_flex_worker_pool!(FlexWorkerPool(label = "auto_default_flex_worker_pool"))
            else
                return wp
            end
        end
    else
        return wp
    end
end
export default_flex_worker_pool


"""
    default_flex_worker_pool!(wp::FlexWorkerPool)

Sets the default flexible worker pool to `wp` and returns it.

See [`default_flex_worker_pool()`](@ref).
"""
function default_flex_worker_pool!(fwp::FlexWorkerPool)
    lock(_g_default_wp_lock) do
        lock(allprocs_management_lock()) do
            _g_default_wp[] = fwp
            return _g_default_wp[]
        end
    end
end
export default_flex_worker_pool!
