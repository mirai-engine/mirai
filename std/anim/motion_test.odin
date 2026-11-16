package mirai_anim

import cmath "core:math"
import "core:math/linalg"
import "core:testing"
import math "mirai:std/math"

@(test)
a_cubic_key_with_tangents_leaves_and_arrives_with_their_slopes :: proc(t:^testing.T) {
    flat:=[]Keyframe{
        {time=0,value={0,0,0,0},interpolation=.Cubic,tangents=true},
        {time=2,value={4,0,0,0},interpolation=.Cubic,tangents=true},
    }
    testing.expect(t,near(track_evaluate(flat,.Float,1).x,2),"zero slopes at both ends: the middle is half way")
    slope :: proc(keys:[]Keyframe,time:f32) -> f32 {
        h:=f32(1e-3)
        return (track_evaluate(keys,.Float,time+h).x-track_evaluate(keys,.Float,time-h).x)/(2*h)
    }
    testing.expect(t,abs(slope(flat,0.01))<0.1 && abs(slope(flat,1.99))<0.1)
    steep:=[]Keyframe{
        {time=0,value={0,0,0,0},interpolation=.Cubic,tangents=true,out_slope={6,0,0,0}},
        {time=2,value={4,0,0,0},interpolation=.Cubic,tangents=true,in_slope={-1,0,0,0}},
    }
    testing.expect(t,abs(slope(steep,0.002)-6)<0.1 && abs(slope(steep,1.998)+1)<0.1)
    testing.expect(t,near(track_evaluate(steep,.Float,0).x,0) && near(track_evaluate(steep,.Float,2).x,4))
    // Without tangents the slope still comes from the neighbors.
    auto:=[]Keyframe{key(0,0,.Cubic),key(1,1,.Cubic),key(2,2,.Cubic)}
    testing.expect(t,abs(slope(auto,1)-1)<0.05)
}

@(test)
a_cubic_rotation_follows_a_spherical_spline_through_its_keys :: proc(t:^testing.T) {
    turn :: proc(degrees:f32) -> math.Quat {return math.quat_axis_angle({0,1,0},degrees*math.RAD_PER_DEG)}
    keys:=[]Keyframe{rot_key(0,turn(0),.Cubic),rot_key(1,turn(30),.Cubic),rot_key(2,turn(120),.Cubic),rot_key(3,turn(150),.Cubic)}
    angle :: proc(keys:[]Keyframe,time:f32) -> f32 {
        q:=vec4_quat(track_evaluate(keys,.Rotation,time))
        return 2*cmath.atan2(linalg.length(math.Vec3{imag(q),jmag(q),kmag(q)}),real(q))*math.DEG_PER_RAD
    }
    for key,i in keys {
        q:=vec4_quat(track_evaluate(keys,.Rotation,key.time))
        testing.expectf(t,abs(linalg.dot(quat_vec4(q),key.value))>0.9999,"key %d is reached",i)
    }
    for time:=f32(0);time<=3;time+=0.125 {
        testing.expect(t,abs(linalg.length(track_evaluate(keys,.Rotation,time))-1)<1e-4)
    }
    // The speed of the turn does not jump at a key the curve passes through.
    h:=f32(0.01)
    before:=(angle(keys,1)-angle(keys,1-h))/h
    after:=(angle(keys,1+h)-angle(keys,1))/h
    testing.expectf(t,abs(before-after)<0.05*max(abs(before),1),"%v degrees per second before, %v after",before,after)
    linear:=[]Keyframe{rot_key(0,turn(0)),rot_key(1,turn(30)),rot_key(2,turn(120))}
    jump:=abs((angle(linear,1+h)-angle(linear,1))/h-(angle(linear,1)-angle(linear,1-h))/h)
    testing.expect(t,jump>30,"a linear rotation does jump there")
}

@(test)
root_motion_adds_the_motion_of_every_pass_a_loop_crosses :: proc(t:^testing.T) {
    lib:=make_library(t)
    defer library_destroy(&lib)
    ROOT :: u64(5)
    walk,_:=clip_add(&lib,{loop=.Loop,tracks={
        {target=ROOT,property=.Position,keys={key(0,0),key(2,4)}},
        {target=ROOT,property=.Rotation,keys={rot_key(0,1),rot_key(2,math.quat_axis_angle({0,1,0},cmath.PI/2))}},
    }})
    moved,turned:=clip_root_motion(&lib,walk,ROOT,0.5,1.5)
    testing.expect(t,near(moved.x,2) && near(moved.y,0))
    // From 1.5 across the end to 0.5 of the next pass, and across three passes.
    moved,_=clip_root_motion(&lib,walk,ROOT,1.5,2.5)
    testing.expect(t,near(moved.x,2))
    moved,turned=clip_root_motion(&lib,walk,ROOT,0,6)
    testing.expect(t,near(moved.x,12))
    expected:=math.quat_axis_angle({0,1,0},3*cmath.PI/2)
    testing.expect(t,abs(linalg.dot(quat_vec4(turned),quat_vec4(expected)))>0.9999)
    // Backwards, the same motion the other way.
    moved,turned=clip_root_motion(&lib,walk,ROOT,2.5,1.5)
    testing.expect(t,near(moved.x,-2))
    testing.expect(t,abs(linalg.dot(quat_vec4(turned),quat_vec4(math.quat_axis_angle({0,1,0},-cmath.PI/4))))>0.9999)
    // A player: the motion of its next advance; a Once clip stops at its end.
    p:=player_make(walk)
    moved,_=player_root_motion(&lib,p,ROOT,0.5)
    testing.expect(t,near(moved.x,1))
    once,_:=clip_add(&lib,{loop=.Once,tracks={{target=ROOT,property=.Position,keys={key(0,0),key(1,3)}}}})
    moved,_=clip_root_motion(&lib,once,ROOT,0.5,4)
    testing.expect(t,near(moved.x,1.5))
    moved,turned=clip_root_motion(&lib,once,u64(99),0,1)
    testing.expect(t,moved=={} && turned==1,"a target the clip does not move")
}

@(test)
an_additive_clip_adds_what_it_changes_from_its_rest_on_top_of_the_others :: proc(t:^testing.T) {
    lib:=make_library(t)
    defer library_destroy(&lib)
    base_clip:=pose_clip(&lib,2)
    nod,_:=clip_add(&lib,{loop=.Loop,tracks={
        {target=HIP,property=.Position,keys={key(0,0),key(1,1)}},
        {target=HIP,property=.Rotation,keys={rot_key(0,1),rot_key(1,math.quat_axis_angle({1,0,0},cmath.PI/2))}},
    }})
    track_bones:[16]i32
    testing.expect(t,library_track_bones(&lib,{HIP},track_bones[:]))
    references:[3]i32
    // The pose of HIP: what base_clip blends, with what the additive player puts on top.
    posed :: proc(lib:^Library,track_bones:[]i32,references:[]i32,under:Clip,over:Player,scale:f32=1,from:Clip=0) -> (position:math.Vec3,rotation:math.Quat) {
        blended,added:[1]Bone_Blend
        bones_blend(blended[:],track_bones,lib,player_make(under))
        bones_blend_additive(added[:],track_bones,lib,over,0,scale,from,references)
        position,_,_=bone_position(blended[0])
        rotation=1
        if change,ok:=bone_added_position(added[0]);ok {position+=change}
        if change,ok:=bone_added_rotation(added[0]);ok {rotation*=change}
        return
    }
    playing:=player_make(nod)
    player_advance(&lib,&playing,0.5,nil)
    position,rotation:=posed(&lib,track_bones[:],references[:],base_clip,playing)
    testing.expect(t,near(position.x,2.5))
    testing.expect(t,abs(linalg.dot(quat_vec4(rotation),quat_vec4(math.quat_axis_angle({1,0,0},cmath.PI/4))))>0.9999)
    // Half its weight, half its change; its rest pose changes nothing.
    position,_=posed(&lib,track_bones[:],references[:],base_clip,playing,0.5)
    testing.expect(t,near(position.x,2.25))
    position,_=posed(&lib,track_bones[:],references[:],base_clip,player_make(nod))
    testing.expect(t,near(position.x,2))
    // Over a reference clip it adds what it changes from that clip's pose (an emote over a
    // stand): nod at .5 over base_clip at 0 adds .5-2; the rotation base_clip lacks is measured
    // from nod's own.
    position,rotation=posed(&lib,track_bones[:],references[:],base_clip,playing,1,base_clip)
    testing.expect(t,near(position.x,.5) && abs(linalg.dot(quat_vec4(rotation),quat_vec4(math.quat_axis_angle({1,0,0},cmath.PI/4))))>0.9999)
}
