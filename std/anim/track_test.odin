package mirai_anim

import "core:testing"
import "mirai:std/base"
import math "mirai:std/math"

key :: proc(time:f32,x:f32,interpolation:Interpolation=.Linear,ease:math.Ease=.Linear) -> Keyframe {
    return {time=time,value={x,0,0,0},ease=ease,interpolation=interpolation}
}
rot_key :: proc(time:f32,q:math.Quat,interpolation:Interpolation=.Linear) -> Keyframe {
    return {time=time,value=quat_vec4(q),interpolation=interpolation}
}

near :: proc(a,b:f32,eps:f32=1e-4) -> bool {return abs(a-b)<=eps}
near_vec :: proc(a,b:$V/[$N]f32,eps:f32=1e-4) -> bool {
    for i in 0..<N {if abs(a[i]-b[i])>eps {return false}}
    return true
}

// The one way a keyed value is read at a time: what a clip, a cinematic and an interface play.
@(test)
a_keyed_value_is_evaluated_one_way :: proc(t:^testing.T) {
    quarter:=math.quat_axis_angle({0,1,0},math.PI/2)
    half:=math.quat_axis_angle({0,1,0},math.PI)
    nan:=f32(0h7fc00000)
    Case :: struct {name:string,keys:[]Keyframe,property:Property,loop:Loop,time:f32,want:math.Vec4,unit:bool}
    cases:=[]Case{
        {name="no keys give zero",time=1},
        {name="one key holds everywhere",keys={key(1,10)},time=5,want={10,0,0,0}},
        {name="before the first key",keys={key(1,10),key(3,20)},time=0,want={10,0,0,0}},
        {name="after the last key",keys={key(1,10),key(3,20)},time=9,want={20,0,0,0}},
        {name="a NaN time gives the first value",keys={key(1,10),key(3,20)},time=nan,want={10,0,0,0}},
        {name="Linear",keys={key(1,10),key(3,20),key(4,0)},time=2,want={15,0,0,0}},
        {name="Linear, every component",keys={{time=0,value={0,2,4,6}},{time=2,value={2,4,6,8}}},property=.Vector,time=1,want={1,3,5,7}},
        {name="Step holds until its key",keys={key(0,1),key(1,5,.Step),key(2,9,.Step)},time=.99,want={1,0,0,0}},
        {name="Step arrives at its key",keys={key(0,1),key(1,5,.Step),key(2,9,.Step)},time=1,want={5,0,0,0}},
        {name="Cubic passes through a key",keys={key(0,0),key(1,1,.Cubic),key(2,0,.Cubic)},time=1,want={1,0,0,0}},
        {name="Cubic takes its slopes from the neighbors",keys={key(0,0),key(1,1,.Cubic),key(2,0,.Cubic)},time=.5,want={.625,0,0,0}},
        {name="Cubic along a line is the line",keys={key(0,0),key(1,1,.Cubic),key(2,2,.Cubic),key(3,3,.Cubic)},time=1.5,want={1.5,0,0,0}},
        {name="Cubic with its own slopes",keys={{time=10,out_slope={3,0,0,0},tangents=true},{time=14,value={12,0,0,0},in_slope={3,0,0,0},tangents=true,interpolation=.Cubic}},time=12,want={6,0,0,0}},
        {name="Cubic_Spline with its own slopes",keys={{time=0,tangents=true},{time=2,value={8,0,0,0},tangents=true,interpolation=.Cubic_Spline}},time=1,want={4,0,0,0}},
        {name="a rotation takes the short arc",keys={rot_key(0,1),rot_key(1,-quarter)},property=.Rotation,time=.5,want=quat_vec4(math.quat_axis_angle({0,1,0},math.PI/4)),unit=true},
        {name="a Cubic rotation passes through a key",keys={rot_key(0,1,.Cubic),rot_key(1,quarter,.Cubic),rot_key(2,half,.Cubic)},property=.Rotation,time=1,want=quat_vec4(quarter),unit=true},
        {name="keys at one time do not divide by zero",keys={key(0,0),key(1,1,.Cubic),key(1,5,.Cubic),key(2,6,.Cubic)},time=1,want={5,0,0,0}},
        {name="Once holds the end",keys={key(0,0),key(2,8)},loop=.Once,time=5,want={8,0,0,0}},
        {name="Loop starts over",keys={key(0,0),key(2,8)},loop=.Loop,time=5,want={4,0,0,0}},
        {name="Ping_Pong comes back",keys={key(0,0),key(2,8)},loop=.Ping_Pong,time=3,want={4,0,0,0}},
        {name="a loop of no length is its start",keys={key(0,3)},loop=.Loop,time=5,want={3,0,0,0}},
    }
    for c in cases {
        duration:=c.keys[len(c.keys)-1].time if len(c.keys)>0 else 0
        time:=c.time
        if c.loop!=.Once || time>duration {time,_=loop_time(c.loop,duration,c.time)}
        if c.time!=c.time {time=c.time}
        got:=track_evaluate(c.keys,c.property,time)
        if c.unit {
            testing.expectf(t,near(abs(vec4_quat(got)),1) && near(math.quat_angle(vec4_quat(got),vec4_quat(c.want)),0,1e-3),"%s: %v, not %v",c.name,got,c.want)
            continue
        }
        testing.expectf(t,near_vec(got,c.want),"%s: %v, not %v",c.name,got,c.want)
    }
    // Every ease shapes the segment that arrives at its key, and leaves its ends where they are.
    for ease in math.Ease {
        keys:=[]Keyframe{key(0,2),key(4,10,.Linear,ease)}
        testing.expectf(t,near(track_evaluate(keys,.Float,1).x,2+8*math.ease_apply(ease,.25)),"%v at a quarter",ease)
        testing.expectf(t,near(track_evaluate(keys,.Float,0).x,2) && near(track_evaluate(keys,.Float,4).x,10),"%v at its ends",ease)
    }
    // Keys out of order, of times that are not numbers or of an interpolation that does not exist give a value without failing.
    hostile:=[]Keyframe{key(3,1),key(nan,2,.Cubic),key(-1,3,Interpolation(200),math.Ease(200)),key(max(f32),4,.Cubic_Spline),key(0,5)}
    for time in ([]f32{-max(f32),-1,0,1,3,nan,max(f32)}) {_=track_evaluate(hostile,.Rotation,time);_=track_evaluate(hostile,.Float,time)}
}

make_library :: proc(t:^testing.T,keys:=64,tracks:=16,clips:=8,markers:=16) -> Library {
    lib:Library
    testing.expect(t,library_init(&lib,{max_keys=keys,max_tracks=tracks,max_clips=clips,max_markers=markers}))
    return lib
}

@(test)
library_stores_clips_with_their_duration_tracks_and_sorted_markers :: proc(t:^testing.T) {
    lib:=make_library(t)
    defer library_destroy(&lib)
    move:=base.name_hash("move")
    clip,_:=clip_add(&lib,{name=base.name_hash("walk"),loop=.Loop,
        tracks={{target=move,property=.Position,keys={{time=0,value={0,0,0,0}},{time=2,value={4,0,0,0}}}},{target=move,property=.Float,slot=3,keys={key(0,1),key(1.5,2)}}},
        markers={{time=1.5,id=7},{time=0.5,id=3}}})
    testing.expect(t,clip==1)
    testing.expect(t,near(clip_duration(&lib,clip),2))
    testing.expect_value(t,clip_find(&lib,base.name_hash("walk")),clip)
    testing.expect_value(t,clip_find(&lib,base.name_hash("run")),Clip(0))
    tracks:=clip_tracks(&lib,clip)
    testing.expect_value(t,len(tracks),2)
    testing.expect_value(t,tracks[1].slot,u8(3))
    testing.expect_value(t,len(track_keys(&lib,tracks[0])),2)
    markers:=clip_markers(&lib,clip)
    testing.expect(t,len(markers)==2 && markers[0].id==3 && markers[1].id==7)
    testing.expect(t,near(clip_evaluate(&lib,tracks[0],1).x,2))
    testing.expect_value(t,clip_data(&lib,clip).loop,Loop.Loop)
}

@(test)
library_refuses_unsorted_keys_and_exhausted_capacity :: proc(t:^testing.T) {
    lib:=make_library(t,keys=4,tracks=2,clips=2,markers=1)
    defer library_destroy(&lib)
    unsorted:=Track_Desc{target=1,keys={key(1,0),key(0,1)}}
    added :: proc(t:^testing.T,lib:^Library,desc:Clip_Desc,clip:Clip,error:Clip_Error,loc:=#caller_location) {
        got,why:=clip_add(lib,desc)
        testing.expect_value(t,got,clip,loc=loc)
        testing.expect_value(t,why,error,loc=loc)
    }
    added(t,&lib,{tracks={unsorted}},0,.Unsorted)
    three:=[]Keyframe{key(0,0),key(1,1),key(2,2)}
    added(t,&lib,{tracks={{target=1,keys=three}}},1,.None)
    added(t,&lib,{tracks={{target=1,keys=three}}},0,.Full) // keys: 3+3 > 4
    added(t,&lib,{markers={{time=1,id=1},{time=2,id=2}}},0,.Full) // markers: 2 > 1
    added(t,&lib,{tracks={{target=1,keys={key(0,0)}},{target=2},{target=3}}},0,.Full) // tracks: 1+3 > 2
    added(t,&lib,{markers={{time=1,id=1}}},2,.None)
    added(t,&lib,{},0,.Full) // clips: 2 of 2
    testing.expect_value(t,lib.clip_count,2)
}

@(test)
library_in_zero_state_and_with_invalid_handles_is_safe :: proc(t:^testing.T) {
    lib:Library
    zero,_:=clip_add(&lib,{})
    testing.expect_value(t,zero,Clip(0))
    testing.expect_value(t,clip_duration(&lib,1),f32(0))
    testing.expect(t,clip_tracks(&lib,5)==nil && clip_markers(&lib,0)==nil)
    library_destroy(&lib)
    testing.expect(t,!library_init(&lib,{}))
    testing.expect(t,!library_init(&lib,{max_keys=1,max_tracks=1,max_clips=0}))
    full:=make_library(t)
    defer library_destroy(&full)
    testing.expect_value(t,clip_data(&full,3),Clip_Data{})
}
