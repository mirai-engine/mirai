package jobs

@(require) import "core:log"
@(require) import "core:testing"
@(require) import "core:time"

// ./mirai test std/jobs --release -define:MIRAI_BENCH=true -define:ODIN_TEST_THREADS=1
BENCH :: #config(MIRAI_BENCH,false)

when BENCH {

@(private="file")
Scale :: struct {values:[]f32,factor:f32}

@(private="file")
scale_range :: proc(scale:^Scale,first,last:int,worker:int) {
    for &value in scale.values[first:last] {value=value*scale.factor+1}
}

@(private="file")
nothing :: proc(data:rawptr,worker:int) {}

@(private="file")
best_of :: proc(rounds:int,body:proc(data:rawptr),data:rawptr) -> time.Duration {
    best:=time.Duration(max(i64))
    for _ in 0..<rounds {
        start:=time.tick_now()
        body(data)
        best=min(best,time.tick_since(start))
    }
    return best
}

@(test)
bench_parallel_for_over_a_million_floats :: proc(t:^testing.T) {
    testing.set_fail_timeout(t,120*time.Second)
    Run :: struct {js:^Job_System,scale:Scale,grain:int}
    values:=make([]f32,1_000_000)
    defer delete(values)
    for threads in ([]int{0,1,3}) {
        js:Job_System
        testing.expect(t,system_init(&js,{threads=threads}))
        for grain in ([]int{1024,16384}) {
            run:=Run{&js,{values,1.0001},grain}
            elapsed:=best_of(50,proc(data:rawptr) {
                run:=cast(^Run)data
                parallel_for(run.js,OWNER,len(run.scale.values),run.grain,scale_range,&run.scale)
            },&run)
            log.infof("parallel_for 1,000,000 f32, %d workers, grain %d: %v",threads+1,grain,elapsed)
        }
        system_destroy(&js)
    }
}

@(test)
bench_job_overhead :: proc(t:^testing.T) {
    testing.set_fail_timeout(t,120*time.Second)
    JOBS :: 100_000
    for threads in ([]int{0,3}) {
        js:Job_System
        testing.expect(t,system_init(&js,{threads=threads,queue_capacity=JOBS}))
        elapsed:=best_of(20,proc(data:rawptr) {
            js:=cast(^Job_System)data
            counter:Counter
            for _ in 0..<JOBS {run(js,OWNER,.Frame,nothing,nil,&counter)}
            wait(js,OWNER,&counter)
        },&js)
        log.infof("run+wait %d empty jobs, %d workers: %v (%.1f ns per job)",JOBS,threads+1,elapsed,f64(time.duration_nanoseconds(elapsed))/JOBS)
        system_destroy(&js)
    }
}

}
