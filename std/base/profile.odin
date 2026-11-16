package base

import "base:intrinsics"
import "base:runtime"
import "core:time"

// Timed zones recorded into one ring per thread. A zone costs two clock reads
// and one write to its thread's ring when the Profile is enabled, two
// branches when it is disabled, and nothing when the build sets
// -define:MIRAI_PROFILE=false. On x86-64 the clock is the cycle counter of
// the processor when it runs at a constant rate, and the system's monotonic
// clock otherwise and on other architectures.
PROFILE_COMPILED :: #config(MIRAI_PROFILE,true)

// A finished zone. Times are nanoseconds since profile_init.
Profile_Zone :: struct {
    name:string, // not copied: it must outlive the Profile, as a literal does
    start:i64,
    duration:i64,
    frame:u32,   // profile_frame calls before the zone ended
    depth:u16,   // zones open on its thread when it began
    thread:u16,
}

Profile_Thread :: struct #align(64) {
    zones:[]Profile_Zone, // zone number n is at n&mask; the newest overwrite the oldest. Times are in clock units until profile_read converts them
    written:u64,          // zones finished since init or the last clear
    depth:u16,
}

Profile_Desc :: struct {
    threads:int,          // rings: each thread that records zones needs its own index
    zones_per_thread:int, // rounded up to a power of two
    allocator:runtime.Allocator,
}

Profile :: struct {
    enabled:bool,
    cycles:bool,       // the clock is the cycle counter, whose rate is measured against epoch_tick
    frame:u32,
    epoch:i64,         // clock reading at init
    epoch_tick:time.Tick,
    threads:[]Profile_Thread,
    zones:[]Profile_Zone,
    mask:u64,
    allocator:runtime.Allocator,
}

// An open zone: what profile_begin hands to profile_end.
Profile_Scope :: struct {
    profile:^Profile,
    name:string,
    start:i64, // clock units
    thread:u16,
    depth:u16,
}

profile_init :: proc(p:^Profile,desc:Profile_Desc) -> bool {
    p^={}
    if desc.threads<=0 || desc.threads>int(max(u16)) || desc.zones_per_thread<=0 || desc.zones_per_thread>max(int)/2 {return false}
    allocator:=desc.allocator if desc.allocator.procedure!=nil else context.allocator
    ring:=1
    for ring<desc.zones_per_thread {ring<<=1}
    if ring>max(int)/desc.threads {return false}
    threads,first:=slice_make([]Profile_Thread,desc.threads,allocator)
    zones,second:=slice_make([]Profile_Zone,desc.threads*ring,allocator)
    if !first || !second {delete(threads,allocator);delete(zones,allocator);return false}
    for &thread,i in threads {thread.zones=zones[i*ring:][:ring]}
    p.threads=threads;p.zones=zones;p.mask=u64(ring-1);p.allocator=allocator
    when ODIN_ARCH==.amd64 {p.cycles=time.has_invariant_tsc()}
    p.epoch_tick=time.tick_now()
    p.epoch=profile_clock(p)
    p.enabled=true
    return true
}
profile_destroy :: proc(p:^Profile) {
    if p.allocator.procedure!=nil {delete(p.threads,p.allocator);delete(p.zones,p.allocator)}
    p^={}
}
profile_set_enabled :: proc "contextless" (p:^Profile,enabled:bool) {
    intrinsics.atomic_store_explicit(&p.enabled,enabled,.Relaxed)
}
// Marks the start of a new frame: zones that end from now on carry its number.
profile_frame :: proc "contextless" (p:^Profile) {
    intrinsics.atomic_add_explicit(&p.frame,1,.Relaxed)
}
// Forgets the recorded zones. No zone may be open.
profile_clear :: proc "contextless" (p:^Profile) {
    for &thread in p.threads {thread.written=0;thread.depth=0}
}

@(private)
profile_clock :: #force_inline proc "contextless" (p:^Profile) -> i64 {
    when ODIN_ARCH==.amd64 {
        if p.cycles {return intrinsics.read_cycle_counter()}
    }
    return i64(time.tick_diff({},time.tick_now()))
}
// Nanoseconds per clock unit. The rate of the cycle counter is what it has
// advanced since init over the time that passed: the longer ago, the more exact.
@(private)
profile_scale :: proc "contextless" (p:^Profile) -> f64 {
    if !p.cycles {return 1}
    elapsed:=profile_clock(p)-p.epoch
    if elapsed<=0 {return 0}
    return f64(time.tick_diff(p.epoch_tick,time.tick_now()))/f64(elapsed)
}

// Opens a zone on the ring of `thread`, which only that thread may use.
profile_begin :: #force_inline proc "contextless" (p:^Profile,thread:int,name:string) -> Profile_Scope {
    when PROFILE_COMPILED {
        if p==nil || !intrinsics.atomic_load_explicit(&p.enabled,.Relaxed) || thread<0 || thread>=len(p.threads) {return {}}
        state:=&p.threads[thread]
        scope:=Profile_Scope{p,name,profile_clock(p),u16(thread),state.depth}
        state.depth+=1
        return scope
    } else {
        return {}
    }
}
profile_end :: #force_inline proc "contextless" (scope:Profile_Scope) {
    when PROFILE_COMPILED {
        p:=scope.profile
        if p==nil || int(scope.thread)>=len(p.threads) {return}
        state:=&p.threads[scope.thread]
        state.depth=scope.depth
        frame:=intrinsics.atomic_load_explicit(&p.frame,.Relaxed)
        #no_bounds_check state.zones[state.written&p.mask]={scope.name,scope.start,profile_clock(p)-scope.start,frame,scope.depth,scope.thread}
        state.written+=1
    }
}
// A zone that lasts until the end of the enclosing block:
//     profile_zone(&profile,worker,"physics.step")
@(deferred_out=profile_end)
profile_zone :: #force_inline proc "contextless" (p:^Profile,thread:int,name:string) -> Profile_Scope {
    return profile_begin(p,thread,name)
}

// Copies the newest zones of a thread, in the order they ended, and returns
// how many. Call it while that thread records nothing, as between frames.
profile_read :: proc "contextless" (p:^Profile,thread:int,out:[]Profile_Zone) -> int {
    if thread<0 || thread>=len(p.threads) {return 0}
    state:=&p.threads[thread]
    count:=min(state.written,u64(len(state.zones)),u64(len(out)))
    first:=state.written-count
    scale:=profile_scale(p)
    for i in 0..<count {
        zone:=state.zones[(first+i)&p.mask]
        zone.start=i64(f64(zone.start-p.epoch)*scale)
        zone.duration=i64(f64(zone.duration)*scale)
        out[i]=zone
    }
    return int(count)
}
// Copies the zones a thread finished from zone number `since` on, oldest
// first, and returns how many, the number to pass next time, and how many of
// them were lost: overwritten in the ring or beyond len(out). It writes
// nothing of the thread, so a thread that keeps recording can be drained from
// another; a zone written while it is read can come out torn.
profile_read_since :: proc "contextless" (p:^Profile,thread:int,since:u64,out:[]Profile_Zone) -> (count:int,next:u64,lost:u64) {
    if thread<0 || thread>=len(p.threads) {return 0,since,0}
    state:=&p.threads[thread]
    written:=intrinsics.atomic_load_explicit(&state.written,.Relaxed)
    if written<=since {return 0,written,0}
    first:=since
    if oldest:=written-min(written,u64(len(state.zones)));first<oldest {lost=oldest-first;first=oldest}
    if written-first>u64(len(out)) {lost+=written-first-u64(len(out));first=written-u64(len(out))}
    scale:=profile_scale(p)
    for i in 0..<written-first {
        zone:=state.zones[(first+i)&p.mask]
        zone.start=i64(f64(zone.start-p.epoch)*scale)
        zone.duration=i64(f64(zone.duration)*scale)
        out[i]=zone
    }
    return int(written-first),written,lost
}
// Zones a thread finished that are no longer in its ring.
profile_lost :: proc "contextless" (p:^Profile,thread:int) -> u64 {
    if thread<0 || thread>=len(p.threads) {return 0}
    state:=&p.threads[thread]
    return state.written-min(state.written,u64(len(state.zones)))
}
