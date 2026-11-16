package mirai_anim

@(require) import "core:log"
@(require) import "core:testing"
@(require) import "core:time"
@(require) import mm "mirai:std/math"

when #config(MIRAI_BENCH,false) {
@(test)
bench_blend_space_sampling :: proc(t:^testing.T) {
    REPEATS :: 100000
    points:[25]mm.Vec2
    for &point,i in points {point={f32(i%5),f32(i/5)}}
    space,ok:=blend_space_prepare(points[:],.Two)
    if !testing.expect(t,ok) {return};defer blend_space_destroy(&space)
    probes:=[8]mm.Vec2{{0,0},{0.2,0.7},{0.5,0.5},{1.7,2.3},{3.5,1.5},{4,4},{-2,2},{5,5}}
    sink:f32;best:=max(time.Duration)
    for _ in 0..<5 {
        start:=time.tick_now()
        for i in 0..<REPEATS {
            weights,_:=blend_space_sample(space,probes[i%len(probes)])
            sink+=weights.weights[0]
        }
        best=min(best,time.tick_since(start))
    }
    log.infof("blend space 2D, 25 samples/32 triangles, inside + outside: %.2f ns/sample (check %v)",f64(time.duration_nanoseconds(best))/REPEATS,sink)
}
}
