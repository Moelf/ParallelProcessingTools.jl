# This file is a part of ParallelProcessingTools.jl, licensed under the MIT License (MIT).

using Test
using ParallelProcessingTools

using Distributed

if length(workers()) < 2
    addprocs(2, exename = ParallelProcessingTools.mtjulia_exe())
end


@testset "distexec" begin
    @testset "worker-init" begin
        @test length(workers()) >= 2
    end

    @testset "onprocs" begin
        @everywhere using ParallelProcessingTools, Base.Threads

        @test (@onprocs workers() myid()) == workers()

        threadinfo = [collect(1:n) for n in [fetch(@spawnat w nthreads()) for w in workers()]]
        ref_result = ((w,t) -> (proc = w, threads = t)).(workers(), threadinfo)

        @test (@onprocs workers() begin
            tl = ThreadLocal(0)
            @onthreads allthreads() tl[] = threadid()
            (proc = myid(), threads = getallvalues(tl))
        end) == ref_result
    end

    @testset "mtjulia_exe" begin
        if Sys.islinux()
            @test fetch(@spawnat first(workers()) nthreads()) > 1
        end
    end

    @testset "Examples" begin
        @test begin
            workers() == (@onprocs workers() myid())
        end
    end
end
