package physics

import "core:fmt"
import "core:testing"
import "core:time"

// A section that brings 8,192 static boxes in one settle: what physics_step
// costs in each tick while they come, BODIES_PER_TICK at a time, and once
// they all came.
@(test)
bench_arrival :: proc(t:^testing.T) {
    if !PHYSICS_BENCH {return}
    COUNT :: 8192
    f:Physics_Test
    if !physics_test_init(t,&f) {return}
    defer physics_test_destroy(&f)
    f.settings.bodies,f.settings.shapes=COUNT+8,COUNT+8
    for i in 0..<COUNT {_=physics_test_box(&f,{f32(i%64)*3,0,f32(i/64)*3},{1,0.1,1})}
    for tick in 0..<COUNT/BODIES_PER_TICK+4 {
        mark:=time.tick_now()
        physics_test_step(&f)
        fmt.printfln("BENCH arrival, %v bodies per tick, tick %v: %.3f ms, %v made",BODIES_PER_TICK,tick,time.duration_milliseconds(time.tick_since(mark)),f.state.stats.bodies_created)
    }
}
