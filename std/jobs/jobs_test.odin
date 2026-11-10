package jobs

import "base:intrinsics"
import "base:runtime"
import "core:mem"
import "core:testing"
import "core:time"
import "mirai:std/base"

@(private="file")
TEST_THREADS :: 3

@(private="file")
Tally :: struct {
    js:^Job_System,
    sum:i64,
    hits:[]i32,
    busy:[8]i32,
    overlaps:i32,
    bad_worker:i32,
    depth:int,
}

@(private="file")
tally_enter :: proc(tally:^Tally,worker:int) {
    if worker<0 || worker>=worker_count(tally.js) {intrinsics.atomic_add(&tally.bad_worker,1);return}
    if intrinsics.atomic_add(&tally.busy[worker],1)!=0 {intrinsics.atomic_add(&tally.overlaps,1)}
}
@(private="file")
tally_leave :: proc(tally:^Tally,worker:int) {
    if worker>=0 && worker<worker_count(tally.js) {intrinsics.atomic_sub(&tally.busy[worker],1)}
}

@(private="file")
add_one :: proc(tally:^Tally,worker:int) {
    tally_enter(tally,worker)
    intrinsics.atomic_add(&tally.sum,1)
    tally_leave(tally,worker)
}

@(private="file")
mark_range :: proc(tally:^Tally,first,last:int,worker:int) {
    for i in first..<last {intrinsics.atomic_add(&tally.hits[i],1)}
}

@(test)
jobs_run_on_the_workers_and_the_counter_waits_for_them :: proc(t:^testing.T) {
    testing.set_fail_timeout(t,60*time.Second)
    js:Job_System
    testing.expect(t,system_init(&js,{threads=TEST_THREADS}))
    defer system_destroy(&js)
    testing.expect_value(t,worker_count(&js),TEST_THREADS+1)
    tally:=Tally{js=&js}
    counter:Counter
    for _ in 0..<5000 {run(&js,OWNER,add_one,&tally,&counter)}
    wait(&js,OWNER,&counter)
    testing.expect_value(t,tally.sum,i64(5000))
    testing.expect_value(t,counter.pending,i32(0))
    testing.expect_value(t,tally.bad_worker,i32(0))
    testing.expect_value(t,tally.overlaps,i32(0))
    testing.expect(t,system_stats(&js).executed>=5000)
}

@(test)
system_without_threads_runs_everything_on_the_owner :: proc(t:^testing.T) {
    js:Job_System
    testing.expect(t,system_init(&js,{}))
    defer system_destroy(&js)
    testing.expect_value(t,worker_count(&js),1)
    tally:=Tally{js=&js}
    run(&js,OWNER,add_one,&tally)
    testing.expect_value(t,tally.sum,i64(1))
    counter:Counter
    for _ in 0..<100 {run(&js,OWNER,add_one,&tally,&counter)}
    testing.expect_value(t,tally.sum,i64(1))
    wait(&js,OWNER,&counter)
    testing.expect_value(t,tally.sum,i64(101))
    stats:=system_stats(&js)
    testing.expect_value(t,stats.stolen,u64(0))
    testing.expect_value(t,stats.sleeps,u64(0))
}

@(test)
parallel_for_visits_every_index_exactly_once :: proc(t:^testing.T) {
    testing.set_fail_timeout(t,60*time.Second)
    js:Job_System
    testing.expect(t,system_init(&js,{threads=TEST_THREADS}))
    defer system_destroy(&js)
    tally:=Tally{js=&js,hits=make([]i32,100_003)}
    defer delete(tally.hits)
    for grain in ([]int{1,7,64,4096,1_000_000}) {
        mem.zero_slice(tally.hits)
        parallel_for(&js,OWNER,len(tally.hits),grain,mark_range,&tally)
        wrong:=0
        for hit in tally.hits {if hit!=1 {wrong+=1}}
        testing.expectf(t,wrong==0,"grain %d: %d indices not visited exactly once",grain,wrong)
    }
    parallel_for(&js,OWNER,0,16,mark_range,&tally)
    parallel_for(&js,OWNER,-5,16,mark_range,&tally)
    testing.expect_value(t,tally.hits[0],i32(1))
}

@(private="file")
Ranges :: struct {grain:int,firsts,lasts:[]int,values:[]u64}

@(private="file")
record_range :: proc(ranges:^Ranges,first,last:int,worker:int) {
    k:=first/ranges.grain
    ranges.firsts[k]=first;ranges.lasts[k]=last
    value:=u64(0xcbf29ce484222325)
    for i in first..<last {value=(value~u64(i))*0x100000001b3}
    ranges.values[k]=value
}

@(test)
parallel_for_gives_the_same_ranges_and_results_with_and_without_threads :: proc(t:^testing.T) {
    testing.set_fail_timeout(t,60*time.Second)
    COUNT :: 10_000
    GRAIN :: 37
    RANGES :: (COUNT+GRAIN-1)/GRAIN
    results:[2]Ranges
    for &ranges,pass in results {
        ranges={GRAIN,make([]int,RANGES),make([]int,RANGES),make([]u64,RANGES)}
        js:Job_System
        testing.expect(t,system_init(&js,{threads=pass==0?0:TEST_THREADS}))
        parallel_for(&js,OWNER,COUNT,GRAIN,record_range,&ranges)
        system_destroy(&js)
    }
    defer for ranges in results {delete(ranges.firsts);delete(ranges.lasts);delete(ranges.values)}
    for k in 0..<RANGES {
        testing.expect_value(t,results[0].firsts[k],k*GRAIN)
        testing.expect_value(t,results[0].lasts[k],min((k+1)*GRAIN,COUNT))
        testing.expect_value(t,results[1].firsts[k],results[0].firsts[k])
        testing.expect_value(t,results[1].lasts[k],results[0].lasts[k])
        testing.expect_value(t,results[1].values[k],results[0].values[k])
    }
}

@(private="file")
nested_outer :: proc(tally:^Tally,first,last:int,worker:int) {
    tally_enter(tally,worker)
    for _ in first..<last {
        tally_leave(tally,worker)
        if tally.depth>0 {
            inner:=Tally{js=tally.js,depth=tally.depth-1}
            parallel_for(tally.js,worker,8,1,nested_outer,&inner)
            intrinsics.atomic_add(&tally.sum,inner.sum)
        } else {
            intrinsics.atomic_add(&tally.sum,1)
        }
        tally_enter(tally,worker)
    }
    tally_leave(tally,worker)
}

@(test)
nested_parallel_for_completes_under_stress :: proc(t:^testing.T) {
    testing.set_fail_timeout(t,120*time.Second)
    js:Job_System
    testing.expect(t,system_init(&js,{threads=TEST_THREADS,queue_capacity=64}))
    defer system_destroy(&js)
    for round in 0..<20 {
        tally:=Tally{js=&js,depth=3}
        parallel_for(&js,OWNER,8,1,nested_outer,&tally)
        testing.expectf(t,tally.sum==8*8*8*8,"round %d: %d",round,tally.sum)
        testing.expect_value(t,tally.overlaps,i32(0))
        testing.expect_value(t,tally.bad_worker,i32(0))
    }
}

@(private="file")
Tree :: struct {tally:^Tally,depth:int}

@(private="file")
tree_job :: proc(tree:^Tree,worker:int) {
    tally:=tree.tally
    tally_enter(tally,worker)
    defer tally_leave(tally,worker)
    intrinsics.atomic_add(&tally.sum,1)
    if tree.depth==0 {return}
    children:=[3]Tree{{tally,tree.depth-1},{tally,tree.depth-1},{tally,tree.depth-1}}
    counter:Counter
    for &child in children {run(tally.js,worker,tree_job,&child,&counter)}
    tally_leave(tally,worker)
    wait(tally.js,worker,&counter)
    tally_enter(tally,worker)
}

@(test)
jobs_that_queue_and_wait_for_jobs_complete_under_stress :: proc(t:^testing.T) {
    testing.set_fail_timeout(t,120*time.Second)
    for threads in ([]int{0,1,TEST_THREADS}) {
        js:Job_System
        testing.expect(t,system_init(&js,{threads=threads,queue_capacity=16}))
        for round in 0..<10 {
            tally:=Tally{js=&js}
            root:=Tree{&tally,7}
            counter:Counter
            run(&js,OWNER,tree_job,&root,&counter)
            wait(&js,OWNER,&counter)
            testing.expectf(t,tally.sum==(2187*3-1)/2,"threads %d round %d: %d",threads,round,tally.sum)
            testing.expect_value(t,tally.overlaps,i32(0))
        }
        system_destroy(&js)
    }
}

@(test)
job_whose_queue_is_full_runs_in_its_caller :: proc(t:^testing.T) {
    js:Job_System
    testing.expect(t,system_init(&js,{queue_capacity=4}))
    defer system_destroy(&js)
    tally:=Tally{js=&js}
    counter:Counter
    for _ in 0..<10 {run(&js,OWNER,add_one,&tally,&counter)}
    testing.expect_value(t,tally.sum,i64(6))
    testing.expect_value(t,system_stats(&js).queue_full,u64(6))
    wait(&js,OWNER,&counter)
    testing.expect_value(t,tally.sum,i64(10))
}

@(private="file")
Temp_Probe :: struct {failed,succeeded:i32}

// A job grows past the first block when it needs to, and the guard of Odin
// gives back what was asked inside it.
@(private="file")
temp_job :: proc(probe:^Temp_Probe,first,last:int,worker:int) {
    small,small_error:=make([]u8,600,context.temp_allocator)
    big,big_error:=make([]u8,4096,context.temp_allocator)
    arena:=&runtime.global_default_temp_allocator_data.arena
    block,used:=arena.curr_block,arena.curr_block.used
    {
        runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
        _,_=make([]u8,8192,context.temp_allocator)
    }
    scoped:=arena.curr_block==block && block.used==used
    if small_error!=nil || big_error!=nil || len(small)!=600 || len(big)!=4096 || !scoped {intrinsics.atomic_add(&probe.failed,1)} else {
        small[599],big[4095]=1,1
        intrinsics.atomic_add(&probe.succeeded,1)
    }
}

@(test)
temporary_memory_of_a_job_grows_when_needed_and_is_released_after_it :: proc(t:^testing.T) {
    testing.set_fail_timeout(t,60*time.Second)
    js:Job_System
    testing.expect(t,system_init(&js,{threads=TEST_THREADS,temp_bytes=1024}))
    defer system_destroy(&js)
    probe:Temp_Probe
    parallel_for(&js,OWNER,500,1,temp_job,&probe)
    testing.expect_value(t,probe.succeeded,i32(500))
    testing.expect_value(t,probe.failed,i32(0))
    stats:=system_stats(&js)
    testing.expect(t,stats.temp_peak>=600+4096)
}

@(test)
destroying_the_system_runs_what_is_still_queued :: proc(t:^testing.T) {
    testing.set_fail_timeout(t,60*time.Second)
    js:Job_System
    testing.expect(t,system_init(&js,{threads=TEST_THREADS}))
    tally:=Tally{js=&js}
    for _ in 0..<1000 {run(&js,OWNER,add_one,&tally)}
    system_destroy(&js)
    testing.expect_value(t,tally.sum,i64(1000))
}

@(private="file")
Meeting :: struct {arrived,met:i32}

// Finishes only when two threads are inside it at the same time.
@(private="file")
meet :: proc(meeting:^Meeting,worker:int) {
    intrinsics.atomic_add(&meeting.arrived,1)
    start:=time.tick_now()
    for intrinsics.atomic_load(&meeting.arrived)<2 {
        if time.tick_since(start)>20*time.Second {return}
        intrinsics.cpu_relax()
    }
    intrinsics.atomic_add(&meeting.met,1)
}

@(test)
sleeping_workers_wake_for_new_jobs :: proc(t:^testing.T) {
    testing.set_fail_timeout(t,120*time.Second)
    js:Job_System
    testing.expect(t,system_init(&js,{threads=TEST_THREADS}))
    defer system_destroy(&js)
    for round in 0..<8 {
        start:=time.tick_now()
        for intrinsics.atomic_load(&js.sleepers)<TEST_THREADS && time.tick_since(start)<20*time.Second {time.sleep(time.Millisecond)}
        testing.expectf(t,intrinsics.atomic_load(&js.sleepers)==TEST_THREADS,"round %d: the workers did not go to sleep",round)
        // The owner runs one of the two jobs; the other needs a worker that was asleep.
        meeting:Meeting
        counter:Counter
        run(&js,OWNER,meet,&meeting,&counter)
        run(&js,OWNER,meet,&meeting,&counter)
        wait(&js,OWNER,&counter)
        testing.expectf(t,meeting.met==2,"round %d: no worker woke up",round)
    }
    testing.expect(t,system_stats(&js).sleeps>=TEST_THREADS)
}

@(test)
jobs_and_ranges_allocate_nothing_once_the_system_exists :: proc(t:^testing.T) {
    testing.set_fail_timeout(t,60*time.Second)
    track:mem.Tracking_Allocator
    mem.tracking_allocator_init(&track,context.allocator)
    defer mem.tracking_allocator_destroy(&track)
    context.allocator=mem.tracking_allocator(&track)
    js:Job_System
    testing.expect(t,system_init(&js,{threads=TEST_THREADS}))
    tally:=Tally{js=&js,hits=make([]i32,10_000)}
    allocations:=track.total_allocation_count
    for _ in 0..<50 {
        counter:Counter
        for _ in 0..<200 {run(&js,OWNER,add_one,&tally,&counter)}
        wait(&js,OWNER,&counter)
        parallel_for(&js,OWNER,len(tally.hits),64,mark_range,&tally)
    }
    testing.expect_value(t,track.total_allocation_count,allocations)
    testing.expect_value(t,tally.sum,i64(10_000))
    delete(tally.hits)
    system_destroy(&js)
    testing.expect_value(t,len(track.allocation_map),0)
}

@(test)
jobs_and_ranges_record_a_zone_on_the_ring_of_their_worker_while_a_profile_is_set :: proc(t:^testing.T) {
    testing.set_fail_timeout(t,60*time.Second)
    js:Job_System
    testing.expect(t,system_init(&js,{threads=TEST_THREADS}))
    defer system_destroy(&js)
    p:base.Profile
    testing.expect(t,base.profile_init(&p,{threads=worker_count(&js),zones_per_thread=4096}))
    defer base.profile_destroy(&p)
    hits:=make([]i32,1000)
    defer delete(hits)
    tally:=Tally{js=&js,hits=hits}
    counter:Counter

    system_profile_set(&js,&p)
    for _ in 0..<200 {run(&js,OWNER,add_one,&tally,&counter)}
    wait(&js,OWNER,&counter)
    parallel_for(&js,OWNER,1000,10,mark_range,&tally)
    system_profile_set(&js,nil)
    for _ in 0..<50 {run(&js,OWNER,add_one,&tally,&counter)}
    wait(&js,OWNER,&counter)

    out:=make([]base.Profile_Zone,4096)
    defer delete(out)
    jobs,ranges:=0,0
    for thread in 0..<worker_count(&js) {
        count,_,lost:=base.profile_read_since(&p,thread,0,out)
        testing.expect_value(t,lost,u64(0))
        for zone in out[:count] {
            testing.expect_value(t,int(zone.thread),thread)
            switch zone.name {
            case "job": jobs+=1
            case "range": ranges+=1
            }
        }
    }
    // The helpers of parallel_for are jobs too; the 50 after the profile was taken away are not recorded.
    testing.expect(t,jobs>=200 && jobs<=200+TEST_THREADS,"every job of the profile, and only those")
    testing.expect_value(t,ranges,100)
    testing.expect_value(t,tally.sum,i64(250))
}
