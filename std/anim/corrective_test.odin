package mirai_anim

import "base:runtime"
import cmath "core:math"
import "core:math/linalg"
import "core:testing"
import math "mirai:std/math"

@(test)
corrective_twist_swing_and_cone_weights_ramp_and_clamp :: proc(t:^testing.T) {
    rest:=math.quat_axis_angle({0,0,1},0.35)
    half_pi:=f32(math.PI*0.5)
    Case :: struct {
        name:string,
        driver:Corrective_Driver,
        delta:math.Quat,
        want:f32,
        negate:bool,
    }
    cases:=[]Case{
        {"twist at rest is zero",
            {mode=.Twist,axis={1,0,0},cone_axis={0,0,-1},min_angle=0,max_angle=half_pi},
            1,0,false},
        {"twist midpoint is half",
            {mode=.Twist,axis={1,0,0},cone_axis={0,0,-1},min_angle=0,max_angle=half_pi},
            math.quat_axis_angle({1,0,0},half_pi*0.5),0.5,false},
        {"twist ignores perpendicular swing",
            {mode=.Twist,axis={0,1,0},cone_axis={0,0,-1},min_angle=0,max_angle=half_pi},
            math.quat_axis_angle({1,0,0},0.8)*math.quat_axis_angle({0,1,0},half_pi*0.5),0.5,true},
        {"twist clamps above max_angle",
            {mode=.Twist,axis={1,0,0},cone_axis={0,0,-1},min_angle=0,max_angle=half_pi},
            math.quat_axis_angle({1,0,0},math.PI*0.75),1,false},
        {"twist clamps negative below min_angle",
            {mode=.Twist,axis={1,0,0},cone_axis={0,0,-1},min_angle=0,max_angle=half_pi},
            math.quat_axis_angle({1,0,0},-0.6),0,false},
        {"twist smoothstep at quarter is 0.15625",
            {mode=.Twist,axis={1,0,0},cone_axis={0,0,-1},min_angle=0,max_angle=half_pi,smooth=true},
            math.quat_axis_angle({1,0,0},half_pi*0.25),0.15625,false},
        {"swing pure twist is zero",
            {mode=.Swing,axis={0,1,0},cone_axis={0,0,-1},min_angle=0,max_angle=half_pi},
            math.quat_axis_angle({0,1,0},1.2),0,false},
        {"swing midpoint is half",
            {mode=.Swing,axis={0,1,0},cone_axis={0,0,-1},min_angle=0,max_angle=half_pi},
            math.quat_axis_angle({1,0,0},half_pi*0.5),0.5,false},
        {"swing below min_angle clamps to zero",
            {mode=.Swing,axis={0,1,0},cone_axis={0,0,-1},min_angle=0.3,max_angle=half_pi},
            math.quat_axis_angle({0,0,1},0.2),0,false},
        {"swing past max_angle clamps to one",
            {mode=.Swing,axis={0,1,0},cone_axis={0,0,-1},min_angle=0,max_angle=half_pi},
            math.quat_axis_angle({0,0,1},math.PI*0.75),1,true},
        {"cone at rest outside 90 deg cone is zero",
            {mode=.Cone,axis={0,-1,0},cone_axis={0,0,-1},min_angle=0,max_angle=half_pi},
            1,0,false},
        {"cone 45 deg toward -Z is half",
            {mode=.Cone,axis={0,-1,0},cone_axis={0,0,-1},min_angle=0,max_angle=half_pi},
            math.quat_axis_angle({1,0,0},half_pi*0.5),0.5,false},
        {"cone 90 deg aligned with -Z is one",
            {mode=.Cone,axis={0,-1,0},cone_axis={0,0,-1},min_angle=0,max_angle=half_pi},
            math.quat_axis_angle({1,0,0},half_pi),1,false},
        {"cone backward toward +Z stays zero",
            {mode=.Cone,axis={0,-1,0},cone_axis={0,0,-1},min_angle=0,max_angle=half_pi},
            math.quat_axis_angle({1,0,0},-half_pi*0.5),0,false},
        {"cone inner radius clamps to one",
            {mode=.Cone,axis={0,-1,0},cone_axis={0,0,-1},min_angle=0.25,max_angle=half_pi},
            math.quat_axis_angle({1,0,0},half_pi-0.2),1,false},
    }
    for c in cases {
        rot:=linalg.normalize0(rest*c.delta)
        if c.negate {rot=-rot}
        got,ok:=corrective_weight(rot,rest,c.driver)
        testing.expectf(t,ok && abs(got-c.want)<1e-4,"%s: got %v (ok=%v), want %v",c.name,got,ok,c.want)
    }

    // Additive application & clamping.
    delta:=math.Transform{
        position={0.1,-0.2,0.3},
        rotation=math.quat_axis_angle({0,1,0},half_pi),
        scale={1.2,0.8,1.5},
    }
    base_local:=math.Transform{position={1,2,3},rotation=math.quat_axis_angle({1,0,0},0.4),scale={2,2,2}}
    zero:=base_local
    testing.expect(t,corrective_apply(&zero,delta,0) && zero==base_local)
    half:=base_local
    testing.expect(t,corrective_apply(&half,delta,0.5))
    testing.expect(t,linalg.length(half.position-(base_local.position+delta.position*0.5))<1e-5)
    testing.expect(t,linalg.length(half.scale-math.Vec3{2.2,1.8,2.5})<1e-5)
    testing.expect(t,math.quat_angle(half.rotation,linalg.normalize0(base_local.rotation*math.quat_axis_angle({0,1,0},half_pi*0.5)))<1e-5)
    over:=base_local
    testing.expect(t,corrective_apply(&over,delta,3))
    testing.expect(t,linalg.length(over.position-(base_local.position+delta.position))<1e-5)
    testing.expect(t,linalg.length(over.scale-base_local.scale*delta.scale)<1e-5)

    // Whole-skeleton corrective runs allocation-free and updates world pose of helper & its child.
    parents:=[4]i32{-1,0,0,2}
    names:=[4]u64{1,2,3,4}
    rest_pose:=[4]math.Transform{
        math.TRANSFORM_IDENTITY,
        {{0,-0.1,0},rest,{1,1,1}},
        {{0.15,0,0},1,{1,1,1}},
        {{0,0.05,0},1,{1,1,1}},
    }
    skeleton:=Skeleton{parents[:],names[:],rest_pose[:]}
    local:=rest_pose;world:[4]math.Transform
    cfg:=CORRECTIVE_DEFAULT
    cfg.driver={mode=.Cone,axis={0,-1,0},cone_axis={0,0,-1},min_angle=0,max_angle=half_pi}
    cfg.delta={position={0,0.04,-0.02},rotation=math.quat_axis_angle({1,0,0},0.5),scale={1.1,1,1}}
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    stable:=true
    for i in 0..<100 {
        local=rest_pose
        local[1].rotation=linalg.normalize0(rest*math.quat_axis_angle({1,0,0},f32(i%10)*0.1))
        applied,ok:=skeleton_corrective(skeleton,local[:],world[:],1,2,cfg,1)
        stable &&=ok && applied>=0 && applied<=1
        expected_pos:=rest_pose[2].position+cfg.delta.position*applied
        stable &&=linalg.length(world[2].position-expected_pos)<1e-5
    }
    context=saved
    testing.expect(t,stable)
}

@(test)
corrective_rejects_hostile_inputs_and_cycles :: proc(t:^testing.T) {
    nan:=cmath.nan_f32()
    inf:=cmath.inf_f32(1)
    bad_drivers:=[]Corrective_Driver{
        {mode=Corrective_Mode(99),axis={0,1,0},cone_axis={0,0,-1},min_angle=0,max_angle=1},
        {mode=.Twist,axis={0,0,0},cone_axis={0,0,-1},min_angle=0,max_angle=1},
        {mode=.Swing,axis={nan,1,0},cone_axis={0,0,-1},min_angle=0,max_angle=1},
        {mode=.Cone,axis={0,1,0},cone_axis={0,0,0},min_angle=0,max_angle=1},
        {mode=.Cone,axis={0,1,0},cone_axis={0,inf,-1},min_angle=0,max_angle=1},
        {mode=.Swing,axis={0,1,0},cone_axis={0,0,-1},min_angle=1,max_angle=1},
        {mode=.Swing,axis={0,1,0},cone_axis={0,0,-1},min_angle=1.2,max_angle=0.5},
        {mode=.Swing,axis={0,1,0},cone_axis={0,0,-1},min_angle=-0.1,max_angle=1},
        {mode=.Swing,axis={0,1,0},cone_axis={0,0,-1},min_angle=0,max_angle=math.PI+0.1},
        {mode=.Cone,axis={0,1,0},cone_axis={0,0,-1},min_angle=-0.1,max_angle=1},
        {mode=.Twist,axis={0,1,0},cone_axis={0,0,-1},min_angle=-math.PI-0.1,max_angle=1},
        {mode=.Twist,axis={0,1,0},cone_axis={0,0,-1},min_angle=0,max_angle=math.PI+0.1},
        {mode=.Twist,axis={0,1,0},cone_axis={0,0,-1},min_angle=nan,max_angle=1},
        {mode=.Twist,axis={0,1,0},cone_axis={0,0,-1},min_angle=0,max_angle=inf},
    }
    for d,i in bad_drivers {
        _,ok:=corrective_weight(1,1,d)
        testing.expectf(t,!ok && !corrective_driver_valid(d),"hostile driver %d must fail",i)
    }
    _,bad_rot:=corrective_weight(0,1,CORRECTIVE_DRIVER_DEFAULT)
    _,bad_ref:=corrective_weight(1,0,CORRECTIVE_DRIVER_DEFAULT)
    testing.expect(t,!bad_rot && !bad_ref)

    bad_deltas:=[]math.Transform{
        {position={nan,0,0},rotation=1,scale={1,1,1}},
        {position={},rotation=0,scale={1,1,1}},
        {position={},rotation=1,scale={0,1,1}},
        {position={},rotation=1,scale={1,-0.5,1}},
        {position={},rotation=1,scale={1,inf,1}},
    }
    for d,i in bad_deltas {
        local:=math.TRANSFORM_IDENTITY
        testing.expectf(t,!corrective_apply(&local,d,1) && local==math.TRANSFORM_IDENTITY,"hostile delta %d must fail without mutating",i)
    }
    local:=math.TRANSFORM_IDENTITY
    testing.expect(t,!corrective_apply(nil,math.TRANSFORM_IDENTITY,1))
    testing.expect(t,!corrective_apply(&local,math.TRANSFORM_IDENTITY,nan))

    // Self-drive and out-of-range indices rejected in skeleton_corrective.
    parents:=[2]i32{-1,0};names:=[2]u64{1,2}
    rest:=[2]math.Transform{math.TRANSFORM_IDENTITY,math.TRANSFORM_IDENTITY}
    skeleton:=Skeleton{parents[:],names[:],rest[:]}
    pose:=rest;world:[2]math.Transform
    _,self_ok:=skeleton_corrective(skeleton,pose[:],world[:],1,1,CORRECTIVE_DEFAULT)
    _,oob_ok:=skeleton_corrective(skeleton,pose[:],world[:],-1,1,CORRECTIVE_DEFAULT)
    _,oob2_ok:=skeleton_corrective(skeleton,pose[:],world[:],0,2,CORRECTIVE_DEFAULT)
    testing.expect(t,!self_ok && !oob_ok && !oob2_ok)

    // Table-driven cycle detection (DAGs accepted, self-loops and cycles rejected).
    Graph_Case :: struct {name:string,drivers,drivens:[]i32,want:bool}
    graphs:=[]Graph_Case{
        {"empty",nil,nil,true},
        {"single edge",{1},{2},true},
        {"chain",{1,2},{2,3},true},
        {"diamond DAG",{1,1,2,3},{2,3,4,4},true},
        {"fan-in",{1,2},{3,3},true},
        {"multi-edge same pair",{1,1},{2,2},true},
        {"self-drive",{1},{1},false},
        {"two-cycle",{1,2},{2,1},false},
        {"three-cycle",{1,2,3},{2,3,1},false},
        {"stem into cycle",{0,1,2},{1,2,1},false},
    }
    for g in graphs {
        testing.expectf(t,corrective_acyclic(g.drivers,g.drivens)==g.want,"%s",g.name)
    }
    peeled:[3]bool
    testing.expect(t,!corrective_acyclic([]i32{0,1,2},[]i32{1,2,1},peeled[:]))
    testing.expect(t,peeled[0] && !peeled[1] && !peeled[2],"stem edge peeled, cycle edges unpeeled")

    // Reverse-listed chain 2->3 before 1->2 orders upstream edge first.
    order:[2]u16
    count,acyclic:=corrective_order([]i32{2,1},[]i32{3,2},order[:])
    testing.expect(t,acyclic && count==2 && order[0]==1 && order[1]==0,"topological order puts upstream edge first")
}
