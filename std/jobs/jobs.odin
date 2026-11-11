package jobs

import "base:intrinsics"
import "base:runtime"
import "core:os"
import "core:sync"
import "core:thread"
import "mirai:std/base"

// Work-stealing job system. The thread that calls system_init is worker 0
// (OWNER); every other worker is a thread of the system. A procedure that
// queues or waits takes the index of the worker calling it: the owner passes
// OWNER, a job passes the index it received. Any other thread must not call in.
//
// A job is of a Class. A thread that waits outside a background job runs only
// frame jobs, so a long job never lands inside a frame, and background jobs
// take all threads but one at once (at least one), so frames keep a helper.
// With threads the owner runs a background job only while it waits for that
// job's counter and the job is the last it queued.
//
// Inside a job context.temp_allocator is Odin's temporary allocator of the
// thread that runs it, so DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD scopes it there
// too; what the job asked for is released when it returns.

CACHE_LINE :: 128
OWNER :: 0
THREADS_AUTO :: -1

Class :: enum u8 {
    Frame,      // a frame waits for it: physics, animation, render, what a frame reads back the next one
    Background, // outlives frames: loads, bakes, builds, disk writes
}

Job_Proc :: #type proc(data:rawptr,worker:int)
Range_Proc :: #type proc(data:rawptr,first,last:int,worker:int)

Job_System_Desc :: struct {
    threads:int,        // besides the owner. 0: everything runs on the owner. THREADS_AUTO: one per remaining core
    queue_capacity:int, // jobs waiting per worker, rounded up to a power of two. 0: 1024
    temp_bytes:int,     // first block of the temporary memory of each thread; a job that needs more grows it until it returns. 0: 1 MiB
    allocator:runtime.Allocator, // the threads take their temporary memory from it: it must be safe to call from several at once
}

// Jobs still running. A zero Counter is ready; it must outlive its jobs.
Counter :: struct {pending:i32}

Stats :: struct {
    workers:int,
    executed:u64,     // jobs and parallel_for ranges
    stolen:u64,
    queue_full:u64,   // jobs run by their caller because its queue was full
    sleeps:u64,
    temp_peak:int,    // bytes, the most temporary memory one job or range asked for
}

@(private)
Job :: struct {
    procedure:Job_Proc,data:rawptr,counter:^Counter,
    class:Class,   // of the queue it came from; slots do not keep it
    reserved:bool, // holds one of the background places of the system
}

@(private)
Slot :: struct {procedure,data,counter:uintptr}

// Chase-Lev deque of fixed capacity: the owner pushes and pops at the bottom,
// thieves take from the top.
@(private)
Deque :: struct {
    top:i64,
    _:[CACHE_LINE-size_of(i64)]u8,
    bottom:i64,
    _:[CACHE_LINE-size_of(i64)]u8,
    slots:[]Slot,
    mask:i64,
}

@(private)
Worker :: struct #align(CACHE_LINE) {
    deques:[Class]Deque,
    system:^Job_System,
    index:int,
    thread:^thread.Thread,
    background:bool, // inside a background job: a wait there runs background jobs too
    temp_peak:int,
    random:u32,
    executed,stolen,queue_full,sleeps:u64,
}

// Must stay at the address it was initialized at.
Job_System :: struct {
    workers:[]Worker,
    slots:[]Slot,
    temp_bytes:int,
    allocator:runtime.Allocator,
    wake_epoch:sync.Futex,
    _:[CACHE_LINE-size_of(sync.Futex)]u8,
    started:i32,  // threads with their temporary memory ready
    sleepers:i32, // threads blocked or about to block on wake_epoch
    waiters:i32,  // the ones among them that wait for a counter
    background_running:i32, // threads that took a background job while idle, or are about to
    background_places:i32,  // the most of them at once: all threads but one, at least one
    quit:bool,
    profile:^base.Profile, // optional: a zone per job and per range of parallel_for on the ring of the worker (ring = worker index); nil records nothing
}

@(private) SPIN_LIMIT :: 64
@(private) YIELD_LIMIT :: 16

system_init :: proc(js:^Job_System,desc:Job_System_Desc) -> bool {
    js^={}
    js.allocator=desc.allocator.procedure!=nil?desc.allocator:context.allocator
    threads:=desc.threads
    if threads<0 {threads=max(os.get_processor_core_count()-1,0)}
    capacity:=1
    for capacity<(desc.queue_capacity>0?desc.queue_capacity:1024) {capacity<<=1}
    js.temp_bytes=desc.temp_bytes>0?desc.temp_bytes:1<<20
    count:=threads+1
    js.background_places=i32(max(threads-1,1))

    error:runtime.Allocator_Error
    if js.workers,error=make([]Worker,count,js.allocator);error!=nil {system_destroy(js);return false}
    if js.slots,error=make([]Slot,count*len(Class)*capacity,js.allocator);error!=nil {system_destroy(js);return false}
    for &w,i in js.workers {
        w.system=js;w.index=i
        for &d,class in w.deques {
            d.slots=js.slots[(i*len(Class)+int(class))*capacity:][:capacity];d.mask=i64(capacity-1)
        }
        w.random=u32(i)*0x9e3779b9+0x7f4a7c15
    }
    thread_context:=context
    context.allocator=js.allocator
    for &w in js.workers[1:] {
        w.thread=thread.create(worker_main)
        if w.thread==nil {system_destroy(js);return false}
        w.thread.data=&w
        w.thread.init_context=thread_context
        thread.start(w.thread)
    }
    for intrinsics.atomic_load(&js.started)<i32(threads) {thread.yield()}
    return true
}

// Runs what is still queued, stops the threads and frees the memory.
system_destroy :: proc(js:^Job_System) {
    if len(js.workers)>0 {
        owner:=&js.workers[OWNER]
        for class in Class {
            for job in own_pop(owner,class) {job_execute(js,owner,job)}
        }
    }
    intrinsics.atomic_store(&js.quit,true)
    intrinsics.atomic_add(&js.wake_epoch,1)
    sync.futex_broadcast(&js.wake_epoch)
    for &w in js.workers {
        if w.thread!=nil {thread.destroy(w.thread)}
    }
    delete(js.workers,js.allocator);delete(js.slots,js.allocator)
    js^={}
}

worker_count :: #force_inline proc(js:^Job_System) -> int {return len(js.workers)}

// Records the jobs into p from now on, which must have a ring per worker and
// outlive the system; nil stops it. Whether p records is p's own switch.
system_profile_set :: proc "contextless" (js:^Job_System,p:^base.Profile) {
    intrinsics.atomic_store_explicit(&js.profile,p,.Relaxed)
}

system_stats :: proc(js:^Job_System) -> (stats:Stats) {
    stats.workers=len(js.workers)
    for &w in js.workers {
        stats.executed+=intrinsics.atomic_load_explicit(&w.executed,.Relaxed)
        stats.stolen+=intrinsics.atomic_load_explicit(&w.stolen,.Relaxed)
        stats.queue_full+=intrinsics.atomic_load_explicit(&w.queue_full,.Relaxed)
        stats.sleeps+=intrinsics.atomic_load_explicit(&w.sleeps,.Relaxed)
        stats.temp_peak=max(stats.temp_peak,intrinsics.atomic_load_explicit(&w.temp_peak,.Relaxed))
    }
    return
}

// The worker that runs code which takes no job system of its own: worker of
// system (a nil system: the calling thread alone), and the profile that
// records its zones on the ring of that worker. The zero value is the caller
// alone, recording nothing.
Worker_Ref :: struct {
    system:^Job_System,
    worker:int,
    profile:^base.Profile,
}

// The same worker inside a job of its system, which runs on worker.
worker_ref_at :: #force_inline proc "contextless" (ref:Worker_Ref,worker:int) -> Worker_Ref {
    return {ref.system,worker,ref.profile}
}

// A zone of ref until the end of the enclosing block.
@(deferred_out=base.profile_end)
worker_zone :: #force_inline proc "contextless" (ref:Worker_Ref,name:string) -> base.Profile_Scope {
    return base.profile_begin(ref.profile,ref.worker,name)
}

// A zone of ref that base.profile_end ends.
worker_zone_begin :: #force_inline proc "contextless" (ref:Worker_Ref,name:string) -> base.Profile_Scope {
    return base.profile_begin(ref.profile,ref.worker,name)
}

// Queues a job of class. With a counter, wait(counter) returns after the job
// ran. Without threads a job without counter runs before run returns. A job
// whose worker has no room in its queue runs inside run.
run :: proc{run_raw,run_typed}

run_raw :: proc(js:^Job_System,worker:int,class:Class,procedure:Job_Proc,data:rawptr,counter:^Counter=nil) {
    w:=&js.workers[worker]
    job:=Job{procedure=procedure,data=data,counter=counter,class=class}
    if counter==nil && len(js.workers)==1 {job_execute(js,w,job);return}
    if counter!=nil {intrinsics.atomic_add(&counter.pending,1)}
    job_push(js,w,job)
    wake(js,class,1)
}

run_typed :: proc(js:^Job_System,worker:int,class:Class,procedure:proc(data:^$T,worker:int),data:^T,counter:^Counter=nil) {
    run_raw(js,worker,class,cast(Job_Proc)procedure,data,counter)
}

// Whether some job of the counter has not finished, without waiting for it.
pending :: proc "contextless" (counter:^Counter) -> bool {return intrinsics.atomic_load(&counter.pending)>0}

// Returns when every job of the counter has finished. Meanwhile the caller
// runs queued frame jobs, its own first; background ones only inside a
// background job, or the last one it queued when it is of this counter (a
// thread that waits for its own job does not leave it queued behind others).
wait :: proc(js:^Job_System,worker:int,counter:^Counter) {
    w:=&js.workers[worker]
    spins:=0
    for intrinsics.atomic_load(&counter.pending)>0 {
        if job,found:=work_find(js,w,counter);found {job_execute(js,w,job);spins=0;continue}
        assert(len(js.workers)>1,"jobs.wait: the counter has pending jobs that were never queued")
        spins+=1
        if spins<=SPIN_LIMIT {intrinsics.cpu_relax();continue}
        if spins<=SPIN_LIMIT+YIELD_LIMIT {thread.yield();continue}
        epoch:=intrinsics.atomic_load(&js.wake_epoch)
        intrinsics.atomic_add(&js.sleepers,1)
        intrinsics.atomic_add(&js.waiters,1)
        if intrinsics.atomic_load(&counter.pending)>0 && !work_available(js,w.background) {
            stat_add(&w.sleeps)
            sync.futex_wait(&js.wake_epoch,u32(epoch))
        }
        intrinsics.atomic_sub(&js.waiters,1)
        intrinsics.atomic_sub(&js.sleepers,1)
        spins=0
    }
}

// Calls procedure over [0,count) split in ranges of grain elements: range k is
// [k*grain,min((k+1)*grain,count)) whatever the number of workers. Returns
// when every range has run. Ranges must not depend on each other. Its helpers
// are of the class of the caller: background inside a background job.
parallel_for :: proc{parallel_for_raw,parallel_for_typed}

parallel_for_raw :: proc(js:^Job_System,worker:int,count,grain:int,procedure:Range_Proc,data:rawptr) {
    if count<=0 {return}
    state:=Range_State{js=js,procedure=procedure,data=data,count=count,grain=max(grain,1)}
    w:=&js.workers[worker]
    class:=Class.Background if w.background else .Frame
    ranges:=(count+state.grain-1)/state.grain
    helpers:=min(ranges,len(js.workers))-1
    queued:=0
    for _ in 0..<helpers {
        intrinsics.atomic_add(&state.counter.pending,1)
        if deque_push(&w.deques[class],{procedure=range_help,data=&state,counter=&state.counter}) {queued+=1} else {intrinsics.atomic_sub(&state.counter.pending,1);break}
    }
    if queued>0 {wake(js,class,queued)}
    range_work(&state,w)
    if queued>0 {wait(js,worker,&state.counter)}
}

parallel_for_typed :: proc(js:^Job_System,worker:int,count,grain:int,procedure:proc(data:^$T,first,last:int,worker:int),data:^T) {
    parallel_for_raw(js,worker,count,grain,cast(Range_Proc)procedure,data)
}

@(private)
Range_State :: struct {
    js:^Job_System,
    procedure:Range_Proc,
    data:rawptr,
    count,grain:int,
    counter:Counter,
    _:[CACHE_LINE]u8,
    next:int,
}

@(private)
range_help :: proc(data:rawptr,worker:int) {
    state:=cast(^Range_State)data
    range_work(state,&state.js.workers[worker])
}

@(private)
range_work :: proc(state:^Range_State,w:^Worker) {
    context.temp_allocator=runtime.default_temp_allocator(&runtime.global_default_temp_allocator_data)
    arena:=&runtime.global_default_temp_allocator_data.arena
    for {
        first:=intrinsics.atomic_add(&state.next,state.grain)
        if first>=state.count {break}
        scope:=runtime.arena_temp_begin(arena)
        used:=arena.total_used
        zone:=base.profile_begin(intrinsics.atomic_load_explicit(&state.js.profile,.Relaxed),w.index,"range")
        state.procedure(state.data,first,min(first+state.grain,state.count),w.index)
        base.profile_end(zone)
        temp_note(w,arena,used)
        runtime.arena_temp_end(scope)
        stat_add(&w.executed)
    }
}

@(private)
temp_note :: proc "contextless" (w:^Worker,arena:^runtime.Arena,used:uint) {
    asked:=int(arena.total_used-min(used,arena.total_used))
    if asked>intrinsics.atomic_load_explicit(&w.temp_peak,.Relaxed) {intrinsics.atomic_store_explicit(&w.temp_peak,asked,.Relaxed)}
}

@(private)
worker_main :: proc(t:^thread.Thread) {
    w:=cast(^Worker)t.data
    js:=w.system
    runtime.init_global_temporary_allocator(js.temp_bytes,js.allocator)
    defer runtime.default_temp_allocator_destroy(&runtime.global_default_temp_allocator_data)
    intrinsics.atomic_add(&js.started,1)
    spins:=0
    for {
        if job,found:=work_find(js,w,nil);found {job_execute(js,w,job);spins=0;continue}
        if intrinsics.atomic_load(&js.quit) {break}
        spins+=1
        if spins<=SPIN_LIMIT {intrinsics.cpu_relax();continue}
        if spins<=SPIN_LIMIT+YIELD_LIMIT {thread.yield();continue}
        epoch:=intrinsics.atomic_load(&js.wake_epoch)
        intrinsics.atomic_add(&js.sleepers,1)
        if !intrinsics.atomic_load(&js.quit) && !work_available(js,intrinsics.atomic_load(&js.background_running)<js.background_places) {
            stat_add(&w.sleeps)
            sync.futex_wait(&js.wake_epoch,u32(epoch))
        }
        intrinsics.atomic_sub(&js.sleepers,1)
        spins=0
    }
}

@(private)
job_execute :: proc(js:^Job_System,w:^Worker,job:Job) {
    context.temp_allocator=runtime.default_temp_allocator(&runtime.global_default_temp_allocator_data)
    arena:=&runtime.global_default_temp_allocator_data.arena
    scope:=runtime.arena_temp_begin(arena)
    used:=arena.total_used
    outer:=w.background
    w.background=outer || job.class==.Background
    zone:=base.profile_begin(intrinsics.atomic_load_explicit(&js.profile,.Relaxed),w.index,"job")
    job.procedure(job.data,w.index)
    base.profile_end(zone)
    w.background=outer
    if job.reserved {intrinsics.atomic_sub(&js.background_running,1)}
    temp_note(w,arena,used)
    runtime.arena_temp_end(scope)
    stat_add(&w.executed)
    // The counter may be gone as soon as it reaches zero.
    if job.counter!=nil && intrinsics.atomic_sub(&job.counter.pending,1)==1 && intrinsics.atomic_load(&js.waiters)>0 {
        intrinsics.atomic_add(&js.wake_epoch,1)
        sync.futex_broadcast(&js.wake_epoch)
    }
}

@(private)
job_push :: proc(js:^Job_System,w:^Worker,job:Job) {
    if deque_push(&w.deques[job.class],job) {return}
    stat_add(&w.queue_full)
    job_execute(js,w,job)
}

// A background job wakes every sleeper: one signal could reach a thread that
// may not take it.
@(private)
wake :: proc(js:^Job_System,class:Class,count:int) {
    if intrinsics.atomic_load(&js.sleepers)==0 {return}
    intrinsics.atomic_add(&js.wake_epoch,1)
    if count==1 && class==.Frame {sync.futex_signal(&js.wake_epoch)} else {sync.futex_broadcast(&js.wake_epoch)}
}

// A job w may take. An idle thread (awaited nil) takes a background job first
// while it gets one of the background places, so frames that never stop do
// not starve them; then frame jobs. A waiter takes background jobs only inside
// a background job, when it is the only worker, or the last one it queued
// when that one is of awaited.
@(private)
work_find :: proc(js:^Job_System,w:^Worker,awaited:^Counter) -> (job:Job,ok:bool) {
    alone:=len(js.workers)==1
    if awaited==nil && !alone {
        if intrinsics.atomic_add(&js.background_running,1)<js.background_places {
            if job,ok=class_find(js,w,.Background);ok {job.reserved=true;return}
        }
        intrinsics.atomic_sub(&js.background_running,1)
    }
    if job,ok=class_find(js,w,.Frame);ok {return}
    if w.background || alone {return class_find(js,w,.Background)}
    if awaited==nil {return}
    if job,ok=own_pop(w,.Background);ok && job.counter!=awaited {
        deque_push(&w.deques[.Background],job)
        return {},false
    }
    return
}

@(private)
class_find :: proc(js:^Job_System,w:^Worker,class:Class) -> (job:Job,ok:bool) {
    if job,ok=own_pop(w,class);ok {return}
    others:=len(js.workers)-1
    if others==0 {return}
    w.random~=w.random<<13;w.random~=w.random>>17;w.random~=w.random<<5
    start:=int(w.random%u32(others))
    for i in 0..<others {
        victim:=(w.index+1+(start+i)%others)%len(js.workers)
        if job,ok=deque_steal(&js.workers[victim].deques[class]);ok {job.class=class;stat_add(&w.stolen);return}
    }
    return
}

@(private)
own_pop :: proc "contextless" (w:^Worker,class:Class) -> (job:Job,ok:bool) {
    job,ok=deque_pop(&w.deques[class])
    job.class=class
    return
}

@(private)
work_available :: proc(js:^Job_System,background:bool) -> bool {
    for &w in js.workers {
        for &d,class in w.deques {
            if (class==.Frame || background) && intrinsics.atomic_load(&d.top)<intrinsics.atomic_load(&d.bottom) {return true}
        }
    }
    return false
}

// Counters are written by their worker only; the relaxed store keeps readers of the stats well defined.
@(private)
stat_add :: #force_inline proc "contextless" (value:^u64) {
    intrinsics.atomic_store_explicit(value,value^+1,.Relaxed)
}

@(private)
slot_store :: #force_inline proc "contextless" (slot:^Slot,job:Job) {
    intrinsics.atomic_store_explicit(&slot.procedure,transmute(uintptr)job.procedure,.Relaxed)
    intrinsics.atomic_store_explicit(&slot.data,uintptr(job.data),.Relaxed)
    intrinsics.atomic_store_explicit(&slot.counter,uintptr(job.counter),.Relaxed)
}

@(private)
slot_load :: #force_inline proc "contextless" (slot:^Slot) -> Job {
    return {
        procedure=transmute(Job_Proc)intrinsics.atomic_load_explicit(&slot.procedure,.Relaxed),
        data=rawptr(intrinsics.atomic_load_explicit(&slot.data,.Relaxed)),
        counter=cast(^Counter)rawptr(intrinsics.atomic_load_explicit(&slot.counter,.Relaxed)),
    }
}

@(private)
deque_push :: proc "contextless" (d:^Deque,job:Job) -> bool {
    bottom:=intrinsics.atomic_load_explicit(&d.bottom,.Relaxed)
    top:=intrinsics.atomic_load(&d.top)
    if bottom-top>d.mask {return false}
    #no_bounds_check {slot_store(&d.slots[bottom&d.mask],job)}
    // Sequentially consistent, so a thread about to sleep either sees the job or is seen by wake.
    intrinsics.atomic_store(&d.bottom,bottom+1)
    return true
}

@(private)
deque_pop :: proc "contextless" (d:^Deque) -> (job:Job,ok:bool) {
    bottom:=intrinsics.atomic_load_explicit(&d.bottom,.Relaxed)
    if bottom<=intrinsics.atomic_load(&d.top) {return}
    bottom-=1
    intrinsics.atomic_store(&d.bottom,bottom)
    top:=intrinsics.atomic_load(&d.top)
    if top>bottom {
        intrinsics.atomic_store(&d.bottom,bottom+1)
        return
    }
    #no_bounds_check job=slot_load(&d.slots[bottom&d.mask])
    if top<bottom {return job,true}
    // Last job: a thief may be taking it.
    _,ok=intrinsics.atomic_compare_exchange_strong(&d.top,top,top+1)
    intrinsics.atomic_store(&d.bottom,bottom+1)
    return
}

// A slot read while its owner rewrites it is discarded: the owner only reuses
// a slot after top moved past it, which makes the exchange fail.
@(private)
deque_steal :: proc "contextless" (d:^Deque) -> (job:Job,ok:bool) {
    top:=intrinsics.atomic_load(&d.top)
    bottom:=intrinsics.atomic_load(&d.bottom)
    if top>=bottom {return}
    #no_bounds_check job=slot_load(&d.slots[top&d.mask])
    _,ok=intrinsics.atomic_compare_exchange_strong(&d.top,top,top+1)
    return
}
