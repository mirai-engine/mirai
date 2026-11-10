package cinematics

import "core:testing"
import "mirai:core"
import render "mirai:engine/render"
import mm "mirai:std/math"

@(private="file")
Cinematic_World :: struct {
    using world:core.Test_World,
    shots:core.Table(Cinematic_Shot),
    tracks:core.Table(Cinematic_Track),
}

@(test)
the_shot_in_force_blends_in_from_the_one_before_it :: proc(t:^testing.T) {
    w:Cinematic_World
    if !core.test_world_init(t,&w) {return}
    defer core.test_world_destroy(&w)
    es,shots:=&w.entities,&w.shots
    timeline,first,second:=core.create(es),core.create(es),core.create(es)
    core.add(shots,core.create(es),Cinematic_Shot{timeline=timeline,camera=second,tick=30,blend_ticks=10})
    core.add(shots,core.create(es),Cinematic_Shot{timeline=timeline,camera=first,tick=0})
    core.add(shots,core.create(es),Cinematic_Shot{timeline=core.create(es),camera=first,tick=20})
    core.test_world_settle(&w)
    _,_,found:=cinematic_shots_at(core.read(shots),timeline,-1)
    testing.expect(t,!found)
    current,previous,_:=cinematic_shots_at(core.read(shots),timeline,29.5)
    testing.expect_value(t,current.camera,first)
    testing.expect_value(t,previous.camera,core.NONE)
    current,previous,_=cinematic_shots_at(core.read(shots),timeline,35)
    testing.expect_value(t,current.camera,second)
    testing.expect_value(t,previous.camera,first)
    from:=Camera_Sample{pose=mm.TRANSFORM_IDENTITY,fov=1,near=0.1}
    to:=from;to.pose.position={10,0,0};to.fov=2
    halfway:=cinematic_shot_blend(current,from,to,35)
    testing.expect_value(t,halfway.pose.position.x,f32(5))
    testing.expect_value(t,halfway.fov,f32(1.5))
    testing.expect_value(t,cinematic_shot_blend(current,from,to,40),to)
    testing.expect_value(t,cinematic_shot_blend(current,from,to,29),to)
}

@(test)
a_camera_sample_takes_the_tracks_that_target_it_and_a_track_out_of_order_is_skipped :: proc(t:^testing.T) {
    w:Cinematic_World
    if !core.test_world_init(t,&w) {return}
    defer core.test_world_destroy(&w)
    es,tracks:=&w.entities,&w.tracks
    timeline,camera:=core.create(es),core.create(es)
    moving:=Cinematic_Track{timeline=timeline,target=camera,property=.Position,key_count=2}
    moving.keys[0]={time=0,value={0,0,0,0}};moving.keys[1]={time=10,value={4,0,0,0}}
    lens:=Cinematic_Track{timeline=timeline,target=camera,property=.Fov,key_count=1}
    lens.keys[0]={time=0,value={0.5,0,0,0}}
    unordered:=Cinematic_Track{timeline=timeline,target=camera,property=.Near,key_count=2}
    unordered.keys[0]={time=10,value={3,0,0,0}};unordered.keys[1]={time=0,value={5,0,0,0}}
    core.add(tracks,core.create(es),moving);core.add(tracks,core.create(es),lens);core.add(tracks,core.create(es),unordered)
    core.test_world_settle(&w)
    _,valid:=cinematic_track_value(&unordered,5)
    testing.expect(t,!valid)
    sample:=cinematic_camera_sample(core.read(tracks),timeline,camera,mm.TRANSFORM_IDENTITY,render.CAMERA_DEFAULT,5)
    testing.expect_value(t,sample.pose.position.x,f32(2))
    testing.expect_value(t,sample.fov,f32(0.5))
    testing.expect_value(t,sample.near,render.CAMERA_DEFAULT.near)
}
