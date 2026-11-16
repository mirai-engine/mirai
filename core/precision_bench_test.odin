package core

@(require) import "core:fmt"
@(require) import "core:math/linalg"
@(require) import "core:slice"
@(require) import "core:testing"
@(require) import "core:time"
@(require) import mm "mirai:std/math"

// ./mirai test core --release -define:PRECISION_BENCH=true -define:ODIN_TEST_THREADS=1 bench_positions_in_f64
@(private="file") PRECISION_BENCH :: #config(PRECISION_BENCH,false)

when PRECISION_BENCH {

// A transform whose position is f64, the alternative measured for large worlds:
// rotation and scale stay f32.
@(private="file")
Transform64 :: struct {
    position:[3]f64,
    rotation:mm.Quat,
    scale:[3]f32,
}

@(private="file")
compose64 :: #force_inline proc "contextless" (parent:Transform64,local:mm.Transform) -> Transform64 {
    offset:=mm.quat_rotate(parent.rotation,parent.scale*local.position)
    return {parent.position+linalg.array_cast(offset,f64),parent.rotation*local.rotation,parent.scale*local.scale}
}

@(private="file")
Body32 :: struct {position:[3]f32,velocity:[3]f32,low,high:[3]f32,half:[3]f32}
@(private="file")
Body64 :: struct {position:[3]f64,velocity:[3]f32,low,high:[3]f32,half:[3]f32}

// The median of runs of a kernel, in nanoseconds per element.
@(private="file")
median_ns :: proc(runs:[]f64) -> f64 {
    slice.sort(runs)
    return runs[len(runs)/2]
}

// What the kernels of the hot paths cost with the position of the world in
// f64 against f32, on the same data: the composition of the hierarchy
// (transforms_propagate), taking a world position to the render origin and
// writing the instance (render_sync), and a body integrating its position
// and rounding its broadphase box out (the solver and the broadphase).
@(test)
bench_positions_in_f64 :: proc(t:^testing.T) {
    N :: 200_000
    RUNS :: 31
    far:=[3]f64{12_000,250,-9_000}
    // Hierarchy: chains of 4, parents before children.
    locals:=make([]mm.Transform,N);defer delete(locals)
    parents:=make([]i32,N);defer delete(parents)
    for i in 0..<N {
        locals[i]={{f32(i%13)*0.5,f32(i%7)*0.25,f32(i%5)},linalg.quaternion_angle_axis_f32(f32(i)*0.001,{0,1,0}),{1,1,1}}
        parents[i]=i%4==0?-1:i32(i-1)
    }
    worlds32:=make([]mm.Transform,N);defer delete(worlds32)
    worlds64:=make([]Transform64,N);defer delete(worlds64)
    runs:[RUNS]f64
    root32:=mm.Transform{linalg.array_cast(far,f32),1,{1,1,1}}
    root64:=Transform64{far,1,{1,1,1}}
    for &run in runs {
        start:=time.tick_now()
        for i in 0..<N {
            p:=parents[i]
            worlds32[i]=mm.transform_compose(p<0?root32:worlds32[p],locals[i])
        }
        run=f64(time.tick_since(start))/N
    }
    compose_32:=median_ns(runs[:])
    for &run in runs {
        start:=time.tick_now()
        for i in 0..<N {
            p:=parents[i]
            worlds64[i]=compose64(p<0?root64:worlds64[p],locals[i])
        }
        run=f64(time.tick_since(start))/N
    }
    compose_64:=median_ns(runs[:])

    // The instances of the render: a world pose to a 3x4 matrix, relative to the render origin with f64.
    instances:=make([][3][4]f32,N);defer delete(instances)
    origin:=[3]f64{12_000,0,-9_000}
    write :: #force_inline proc "contextless" (out:^[3][4]f32,position:[3]f32,rotation:mm.Quat,scale:[3]f32) {
        m:=linalg.matrix3_from_quaternion_f32(rotation)
        for r in 0..<3 {out[r]={m[r][0]*scale.x,m[r][1]*scale.y,m[r][2]*scale.z,position[r]}}
    }
    for &run in runs {
        start:=time.tick_now()
        for i in 0..<N {write(&instances[i],worlds32[i].position,worlds32[i].rotation,worlds32[i].scale)}
        run=f64(time.tick_since(start))/N
    }
    render_32:=median_ns(runs[:])
    for &run in runs {
        start:=time.tick_now()
        for i in 0..<N {write(&instances[i],linalg.array_cast(worlds64[i].position-origin,f32),worlds64[i].rotation,worlds64[i].scale)}
        run=f64(time.tick_since(start))/N
    }
    render_64:=median_ns(runs[:])

    // Bodies: integrate the position and round the box of the broadphase out.
    B :: 50_000
    bodies32:=make([]Body32,B);defer delete(bodies32)
    bodies64:=make([]Body64,B);defer delete(bodies64)
    for i in 0..<B {
        p:=far+{f64(i%100)*2,f64(i/100)*2,0}
        bodies32[i]={position=linalg.array_cast(p,f32),velocity={0,-1,0.5},half={0.5,0.5,0.5}}
        bodies64[i]={position=p,velocity={0,-1,0.5},half={0.5,0.5,0.5}}
    }
    dt:=f32(1.0/60)
    for &run in runs {
        start:=time.tick_now()
        for &b in bodies32 {
            b.position+=b.velocity*dt
            b.low,b.high=b.position-b.half,b.position+b.half
        }
        run=f64(time.tick_since(start))/B
    }
    bodies_32:=median_ns(runs[:])
    for &run in runs {
        start:=time.tick_now()
        for &b in bodies64 {
            b.position+=linalg.array_cast(b.velocity*dt,f64)
            // The broadphase stays in f32: its box is fattened by more than a step of f32 there.
            at:=linalg.array_cast(b.position,f32)
            b.low,b.high=at-b.half,at+b.half
        }
        run=f64(time.tick_since(start))/B
    }
    bodies_64:=median_ns(runs[:])

    fmt.printfln("| Kernel | f32 (ns) | f64 (ns) | Difference |")
    fmt.printfln("| --- | --- | --- | --- |")
    row :: proc(name:string,a,b:f64) {fmt.printfln("| %s | %.2f | %.2f | %+.0f%% |",name,a,b,(b/a-1)*100)}
    row("Compose the hierarchy",compose_32,compose_64)
    row("Instance relative to the render origin",render_32,render_64)
    row("Integrate a body and its box",bodies_32,bodies_64)
    fmt.printfln("Sizes: Transform %d → %d bytes; World_Transform %d → %d bytes",size_of(mm.Transform),size_of(Transform64),2*size_of(mm.Transform),2*size_of(Transform64))
    testing.expect(t,worlds64[N-1].position.x!=0 && bodies64[0].low.x!=0)
}

}
