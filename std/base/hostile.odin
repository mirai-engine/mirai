package base

import "base:runtime"
import "core:mem"

// Seeded inputs for the tests that hand a package what it has to refuse (the
// hostile_test.odin of each package): a seed gives the same inputs on every
// platform, so a failure repeats.
Hostile :: struct {state:u64}

hostile_next :: proc "contextless" (h:^Hostile) -> u64 {
    h.state+=0x9e3779b97f4a7c15
    return hash_u64(h.state)
}
// A number below `below`; 0 when there is none.
hostile_int :: proc "contextless" (h:^Hostile,below:int) -> int {return below<=0?0:int(hostile_next(h)%u64(below))}
// NaN, an infinity or an extreme most of the time; otherwise hundredths between -10 and 10.
hostile_f32 :: proc "contextless" (h:^Hostile) -> f32 {
    switch hostile_int(h,14) {
    case 0: return f32(0h7fc00000)
    case 1: return f32(0h7f800000)
    case 2: return f32(0hff800000)
    case 3: return 1e30
    case 4: return -1e30
    case 5: return 1e-30
    case 6: return 0
    case 7: return 1
    case 8: return -1
    case 9: return f32(0h7f7fffff)
    }
    return f32(hostile_int(h,2001)-1000)/100
}

// The allocator a hostile test works with: it counts what stays allocated and
// what is freed without having been allocated, which the test requires to be nothing.
Hostile_Memory :: struct {track:mem.Tracking_Allocator}

hostile_memory_begin :: proc(m:^Hostile_Memory,backing:=context.allocator) -> runtime.Allocator {
    mem.tracking_allocator_init(&m.track,backing)
    m.track.bad_free_callback=mem.tracking_allocator_bad_free_callback_add_to_array
    return mem.tracking_allocator(&m.track)
}
hostile_memory_end :: proc(m:^Hostile_Memory) -> (leaked,bad_frees:int) {
    leaked,bad_frees=len(m.track.allocation_map),len(m.track.bad_free_array)
    mem.tracking_allocator_destroy(&m.track)
    return
}
