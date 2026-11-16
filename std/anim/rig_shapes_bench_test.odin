package mirai_anim

@(require) import "core:log"
@(require) import "core:testing"
@(require) import "core:time"
@(require) import math "mirai:std/math"

when #config(MIRAI_BENCH,false) {
@(test)
bench_spline_and_angular_pose_samples :: proc(t:^testing.T) {
    REPEATS :: 20000
    settings:=Spline_Chain{controls={{},{0,1,0},{1,2,0},{0,3,0}},up={0,0,1}}
    points:[32]math.Vec3;lengths:[31]f32;for &length in lengths {length=.1}
    rotations:[16]math.Quat;weights:[16]f32
    for &rotation,i in rotations {rotation=math.quat_axis_angle({0,0,1},f32(i)*.15)}
    testing.expect(t,spline_chain(settings,lengths[:],points[:]) && pose_sample_weights(1,rotations[:],weights[:]))
    best:=max(time.Duration);sink:f32
    for _ in 0..<5 {
        start:=time.tick_now()
        for i in 0..<REPEATS {settings.controls[1].x=f32(i%100)*.01;spline_chain(settings,lengths[:],points[:]);sink+=points[31].x}
        best=min(best,time.tick_since(start))
    }
    log.infof("spline 32 points / 64 curve segments: %.2f ns/evaluation (check %v)",f64(time.duration_nanoseconds(best))/REPEATS,sink)
    parents:[32]i32;names:[32]u64;rest,local,world:[32]math.Transform;bones:[32]i32
    for &pose,i in rest {pose=math.TRANSFORM_IDENTITY;if i>0 {pose.position.y=.1};parents[i]=i32(i-1);names[i]=u64(i+1);bones[i]=i32(i)}
    skeleton:=Skeleton{parents[:],names[:],rest[:]};best=max(time.Duration)
    for _ in 0..<5 {
        start:=time.tick_now()
        for i in 0..<REPEATS {local=rest;settings.controls[1].x=f32(i%100)*.01;skeleton_spline_ik(skeleton,local[:],world[:],bones[:],settings,points[:],lengths[:]);sink+=world[31].position.x}
        best=min(best,time.tick_since(start))
    }
    log.infof("skeleton spline IK 32 bones including validation and world recomposition: %.2f ns/evaluation (check %v)",f64(time.duration_nanoseconds(best))/REPEATS,sink)
    best=max(time.Duration)
    for _ in 0..<5 {
        start:=time.tick_now()
        for i in 0..<REPEATS {pose_sample_weights(math.quat_axis_angle({0,0,1},(f32(i%16)+.5)*.15),rotations[:],weights[:]);sink+=weights[i%16]}
        best=min(best,time.tick_since(start))
    }
    log.infof("16 angular corrective samples: %.2f ns/evaluation (check %v)",f64(time.duration_nanoseconds(best))/REPEATS,sink)
}
}
