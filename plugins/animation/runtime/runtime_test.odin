package anim

import "base:runtime"
import "core:math/linalg"
import "core:strings"
import "core:testing"
import "mirai:core"
import "mirai:host"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"

@(test)
curve_queries_mix_missing_tracks_with_the_callers_default_and_retire_stale_outputs :: proc(t:^testing.T) {
    content:=host.Content_Animation{clip_count=2}
    testing.expect(t,lib.library_init(&content.lib,{max_clips=2,max_tracks=1,max_keys=2}))
    defer lib.library_destroy(&content.lib)
    target:=base.name_hash("pulse")
    keys:=[2]lib.Keyframe{{time=0,value={2,0,0,0}},{time=1,value={4,0,0,0}}}
    clip,_:=lib.clip_add(&content.lib,{name=1,tracks={{target=target,property=.Float,keys=keys[:]}}})
    empty,_:=lib.clip_add(&content.lib,{name=2})
    playback:Playback;defer playback_free(&playback)
    state:=state_get(&playback,core.Entity(1));state.seen=1;playback.frame=1
    lib.fader_play(&state.fader,clip,1,0);state.fader.current.time=.5
    sample_curves(state,&content,.5)
    testing.expect_value(t,animation_curve(&playback,state.entity,"pulse",default_value=5),f32(4))
    lib.fader_play(&state.fader,empty,1,1)
    state.fader.current.time=.5
    state.fader.outgoing[0].elapsed=.5;state.fader.elapsed=.5
    sample_curves(state,&content,1)
    testing.expect_value(t,animation_curve(&playback,state.entity,"pulse",default_value=5),f32(4))
    playback.frame+=1
    testing.expect_value(t,animation_curve(&playback,state.entity,"pulse",default_value=5),f32(5))
    _,present:=animation_root_delta(&playback,state.entity);testing.expect(t,!present)
}

// The curves of an additive layer change by what its clip differs from its reference clip, as its
// bones: a face whose own first frame already smiles adds its smile over a neutral reference.
@(test)
additive_layer_curves_subtract_their_reference_clip :: proc(t:^testing.T) {
    content:=host.Content_Animation{clip_count=2}
    testing.expect(t,lib.library_init(&content.lib,{max_clips=2,max_tracks=2,max_keys=4}))
    defer lib.library_destroy(&content.lib)
    smile:=base.name_hash("smile")
    neutral:=[1]lib.Keyframe{{value={0.2,0,0,0}}}
    grin:=[2]lib.Keyframe{{time=0,value={1,0,0,0}},{time=1,value={0.8,0,0,0}}}
    stand,_:=lib.clip_add(&content.lib,{name=base.name_hash("stand"),tracks={{target=smile,property=.Float,keys=neutral[:]}}})
    happy,_:=lib.clip_add(&content.lib,{name=base.name_hash("happy"),tracks={{target=smile,property=.Float,keys=grin[:]}}})
    playback:Playback;defer playback_free(&playback)
    state:=state_get(&playback,core.Entity(1));state.seen=1;playback.frame=1
    lib.fader_play(&state.fader,stand,1,0)
    lib.fader_play(&state.layers[1].fader,happy,1,0);state.layers[1].fader.current.time=1
    state.layers[1].clip,state.layers[1].weight=base.name_hash("happy"),1
    cases:=[?]struct {reference:string,want:f32}{{"stand",0.2+0.8-0.2},{"",0.2+0.8-1}}
    for c in cases {
        animation:=ANIMATION_DEFAULT
        testing.expect(t,test_layer(state,1,"happy",mode=.Additive,reference_clip=c.reference))
        sample_curves(state,&content,1,animation)
        got:=animation_curve(&playback,state.entity,"smile")
        testing.expectf(t,abs(got-c.want)<1e-5,"over reference %q the smile is %v, not %v",c.reference,got,c.want)
    }
}

@(test)
direct_clip_weights_preserve_zero_full_and_partial_trs_without_allocations :: proc(t:^testing.T) {
    content:=host.Content_Animation{clip_count=1}
    if !testing.expect(t,lib.library_init(&content.lib,{max_clips=1,max_tracks=3,max_keys=3})) {return}
    defer lib.library_destroy(&content.lib)
    target:=base.name_hash("bone")
    rest:=mm.Transform{position={1,2,3},rotation=mm.quat_axis_angle({1,0,0},.3),scale={.5,1,2}}
    posed:=mm.Transform{position={3,4,5},rotation=-mm.quat_axis_angle({0,1,0},1.2),scale={2,3,4}}
    clip,_:=lib.clip_add(&content.lib,{tracks={
        {target=target,property=.Position,keys={{value={3,4,5,0}}}},
        {target=target,property=.Rotation,keys={{value=lib.quat_vec4(posed.rotation)}}},
        {target=target,property=.Scale,keys={{value={2,3,4,0}}}},
    }})
    if !testing.expect(t,clip!=0) {return}
    state:=Playing{clip=0};defer playing_free(&state)
    append(&state.bindings,Binding{target=target,driven={.Position,.Rotation,.Scale},rest=rest})
    append(&state.local,rest)
    lib.fader_play(&state.fader,clip)
    playback:Playback;defer playback_free(&playback)
    if !testing.expect(t,tracks_bind(&playback,&state,&content)) {return}
    pose_sample(&playback,&state,&content.lib,ANIMATION_DEFAULT,{},nil)
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    matched:=true
    for source_weight in ([3]f32{0,.5,1}) {for weight in ([3]f32{0,.25,1}) {
        state.fader.current.weight=source_weight
        animation:=ANIMATION_DEFAULT;animation.weight=weight
        pose_sample(&playback,&state,&content.lib,animation,{},nil)
        expected:=mm.transform_interpolate(rest,posed,source_weight*weight)
        expected.rotation=mm.quat_slerp(rest.rotation,posed.rotation,source_weight*weight)
        for i in 0..<3 {matched &&=abs(state.local[0].position[i]-expected.position[i])<1e-5 && abs(state.local[0].scale[i]-expected.scale[i])<1e-5}
        matched &&=mm.quat_angle(state.local[0].rotation,expected.rotation)<1e-5
    }}
    context=saved
    testing.expect(t,matched)
}

@(test)
negative_speed_plays_a_once_clip_from_its_end_and_seeks_drive_progress :: proc(t:^testing.T) {
    content:=host.Content_Animation{clip_count=1}
    testing.expect(t,lib.library_init(&content.lib,{max_keys=2,max_tracks=1,max_clips=2,max_markers=0}))
    defer lib.library_destroy(&content.lib)
    walk,_:=lib.clip_add(&content.lib,{tracks={{target=base.name_hash("10"),property=.Position,keys={{time=0,value={}},{time=2,value={2,0,0,0}}}}}})
    testing.expect(t,walk!=0)
    state:=Playing{entity=core.entity_make(1,1),clip=-1}
    playback:Playback;defer playback_free(&playback)
    events:Animation_Events;defer delete(events.items)
    settings:=ANIMATION_DEFAULT;settings.speed=-2;settings.loop=false
    advance(&playback,&state,&content,settings,&events,0.25,nil)
    testing.expect(t,abs(state.time-1.5)<0.0001 && !state.ended && state.duration==2)
    settings.speed=1
    advance(&playback,&state,&content,settings,&events,1,nil)
    testing.expect(t,state.ended && abs(state.time-2)<0.0001)
    settings.speed=-1
    advance(&playback,&state,&content,settings,&events,0.5,nil)
    testing.expect(t,!state.ended && abs(state.time-1.5)<0.0001)
    advance(&playback,&state,&content,settings,&events,0,nil,0.25)
    testing.expect(t,abs(state.time-0.25)<0.0001)
    base.text_set(settings.clip[:],"missing")
    problems:core.Problems
    advance(&playback,&state,&content,settings,&events,0.5,&problems)
    advance(&playback,&state,&content,settings,&events,0.5,&problems)
    testing.expect(t,state.clip==-1 && state.duration==0)
    missing:=core.problem_find(&problems,state.entity,"animation.clip")
    if testing.expect(t,missing!=nil && problems.count==1,"a clip the animation lacks is a problem of its entity") {
        testing.expect_value(t,missing.count,u64(2))
        testing.expect(t,strings.contains(core.problem_text(missing),"Animation.clip is 'missing'"),core.problem_text(missing))
        testing.expect(t,strings.contains(core.problem_text(missing),"name one of its clips"),core.problem_text(missing))
    }
}

// The actor, hip below it, arm below hip, and leg below the actor; walk moves
// hip and leg, wave raises arm and leg, run moves hip twice as fast as walk.
@(private)
layer_fixture :: proc(t:^testing.T,content:^host.Content_Animation) -> Playing {
    content.id={1,2}
    testing.expect(t,lib.library_init(&content.lib,{max_keys=16,max_tracks=8,max_clips=6,max_markers=0}))
    hip,arm,leg:=base.name_hash("hip"),base.name_hash("arm"),base.name_hash("leg")
    walk:=[2]lib.Keyframe{{time=0},{time=2,value={2,0,0,0}}}
    stride:=[2]lib.Keyframe{{time=0},{time=2,value={0,0,2,0}}}
    raised:=[1]lib.Keyframe{{value={0,1,0,0}}}
    kicked:=[1]lib.Keyframe{{value={0,5,0,0}}}
    run:=[2]lib.Keyframe{{time=0},{time=1,value={4,0,0,0}}}
    clips:=[3]lib.Clip_Desc{
        {name=base.name_hash("walk"),tracks={{target=hip,property=.Position,keys=walk[:]},{target=leg,property=.Position,keys=stride[:]}}},
        {name=base.name_hash("wave"),tracks={{target=arm,property=.Position,keys=raised[:]},{target=leg,property=.Position,keys=kicked[:]}}},
        {name=base.name_hash("run"),tracks={{target=hip,property=.Position,keys=run[:]}}},
    }
    for clip in clips {added,_:=lib.clip_add(&content.lib,clip);testing.expect(t,added!=0)}
    for i in 0..<3 {content.lib.clips[3+i]=content.lib.clips[i];content.lib.clips[3+i].loop=.Loop}
    content.lib.clip_count=6;content.clip_count=3
    state:=Playing{entity=core.entity_make(1,1),clip=-1}
    targets:=[4]u64{0,hip,arm,leg}
    parents:=[4]i32{-1,0,1,0}
    for target,i in targets {
        append(&state.bindings,Binding{target=target,entity=core.NONE,driven={.Position},rest=mm.TRANSFORM_IDENTITY,parent=parents[i]})
        append(&state.parents,parents[i]);append(&state.targets,target);append(&state.rest,mm.TRANSFORM_IDENTITY)
    }
    resize(&state.local,4);resize(&state.world,4)
    return state
}

@(private="file")
layer_step :: proc(playback:^Playback,state:^Playing,content:^host.Content_Animation,animation:Animation,events:^Animation_Events,dt:f32) {
    copy(state.local[:],state.rest[:])
    advance(playback,state,content,animation,events,dt,nil)
    layers_advance(playback,state,content,animation,events,dt,nil)
    pose_sample(playback,state,&content.lib,animation,{},nil)
}

@(test)
layers_play_over_the_clip_inside_their_branch_by_weight_and_fade_out :: proc(t:^testing.T) {
    content:host.Content_Animation
    state:=layer_fixture(t,&content)
    defer lib.library_destroy(&content.lib);defer playing_free(&state)
    playback:Playback;defer playback_free(&playback)
    testing.expect(t,tracks_bind(&playback,&state,&content))
    events:Animation_Events;defer delete(events.items)
    animation:=ANIMATION_DEFAULT
    testing.expect(t,animation_clip(&animation,"walk",fade=0))
    layer_step(&playback,&state,&content,animation,&events,1)
    testing.expect(t,abs(state.local[1].position.x-1)<0.0001 && abs(state.local[3].position.z-1)<0.0001 && state.local[2].position==0)
    // Over the branch of hip: arm rises, leg keeps walking, hip keeps what wave does not move.
    testing.expect(t,test_layer(&state,1,"wave",over="hip"))
    layer_step(&playback,&state,&content,animation,&events,0)
    testing.expect(t,state.local[2].position==mm.Vec3{0,1,0} && state.local[3].position.y==0 && abs(state.local[1].position.x-1)<0.0001)
    testing.expect(t,test_layer(&state,1,"wave"))
    layer_step(&playback,&state,&content,animation,&events,0)
    testing.expect_value(t,state.local[3].position,mm.Vec3{0,5,0})
    testing.expect(t,test_layer_weight(&state,1,0.5))
    layer_step(&playback,&state,&content,animation,&events,0)
    testing.expect(t,abs(state.local[3].position.y-2.5)<0.0001 && abs(state.local[3].position.z-0.5)<0.0001)
    testing.expect(t,test_layer_stop(&state,1,0.5))
    layer_step(&playback,&state,&content,animation,&events,0.1)
    testing.expect(t,abs(state.layers[1].weight-0.3)<0.0001 && abs(state.local[3].position.y-1.5)<0.0001)
    layer_step(&playback,&state,&content,animation,&events,1)
    testing.expect(t,state.layers[1]==Layer_Playing{} && state.local[3].position.y==0)
    // A synchronized layer is where the clip below it is in its cycle: walk lasts 2 s and run 1 s.
    testing.expect(t,test_layer(&state,2,"run",sync=true))
    layer_step(&playback,&state,&content,animation,&events,0.5)
    run_time:=lib.player_time(&content.lib,state.layers[2].fader.current)
    testing.expect(t,abs(run_time-state.time/2)<0.0001 && abs(state.local[1].position.x-run_time*4)<0.0001)
    problems:core.Problems
    testing.expect(t,test_layer(&state,2,"missing"))
    copy(state.local[:],state.rest[:]);advance(&playback,&state,&content,animation,&events,0.1,nil);layers_advance(&playback,&state,&content,animation,&events,0.1,&problems)
    testing.expect(t,core.problem_find(&problems,state.entity,"animation.layer_clip")!=nil,"a layer whose clip the animation lacks is a problem of its entity")
    before:=animation
    long:="a clip whose name is longer than the sixty four bytes that the component can hold"
    zero:f32
    testing.expect(t,!animation_clip(&animation,long) && !animation_clip(&animation,"wave",fade=zero/zero) && !animation_clip(nil,"wave"))
    testing.expect_value(t,animation,before)
    // An additive layer over a reference clip adds what its clip changes from the pose of that
    // clip at reference: wave over walk at 1 s lifts the leg 5 and takes it back the 1 walk has
    // there; the arm, which walk does not move, changes from wave's own pose, by nothing.
    state.asked,state.layers={},{}
    layer_step(&playback,&state,&content,animation,&events,0)
    leg,arm:=state.local[3].position,state.local[2].position
    testing.expect(t,test_layer(&state,1,"wave",mode=.Additive,reference=1,reference_clip="walk"))
    layer_step(&playback,&state,&content,animation,&events,0)
    testing.expectf(t,linalg.length(state.local[3].position-(leg+mm.Vec3{0,5,-1}))<1e-4 && state.local[2].position==arm,"leg %v from %v",state.local[3].position,leg)
    testing.expect(t,test_layer(&state,1,"wave",mode=.Additive,reference_clip="missing"))
    copy(state.local[:],state.rest[:])
    pose_faults_report(&problems,state.entity,pose_layers(&playback,&state,&content.lib,animation))
    testing.expect(t,core.problem_find(&problems,state.entity,"animation.layer_reference")!=nil && state.local[3].position==0,"a reference clip the animation does not have is reported and the layer adds nothing")
}

@(test)
a_layer_in_the_space_of_the_rig_keeps_the_turn_of_its_clip_whatever_the_base_turns_above :: proc(t:^testing.T) {
    content:host.Content_Animation;content.id={1,3}
    testing.expect(t,lib.library_init(&content.lib,{max_keys=16,max_tracks=8,max_clips=4,max_markers=0}))
    defer lib.library_destroy(&content.lib)
    hip,arm:=base.name_hash("hip"),base.name_hash("arm")
    side:=mm.quat_axis_angle({0,1,0},mm.PI/2)
    turned:=[1]lib.Keyframe{{value={imag(side),jmag(side),kmag(side),real(side)}}}
    straight:=[1]lib.Keyframe{{value={0,0,0,1}}}
    // The base turns the hip sideways; the layer holds hip and arm straight, over the arm alone.
    clips:=[2]lib.Clip_Desc{
        {name=base.name_hash("turn"),tracks={{target=hip,property=.Rotation,keys=turned[:]}}},
        {name=base.name_hash("pose"),tracks={{target=hip,property=.Rotation,keys=straight[:]},{target=arm,property=.Rotation,keys=straight[:]}}},
    }
    for clip in clips {added,_:=lib.clip_add(&content.lib,clip);testing.expect(t,added!=0)}
    for i in 0..<2 {content.lib.clips[2+i]=content.lib.clips[i];content.lib.clips[2+i].loop=.Loop}
    content.lib.clip_count=4;content.clip_count=2
    state:=Playing{entity=core.entity_make(1,1),clip=-1};defer playing_free(&state)
    targets:=[3]u64{0,hip,arm};parents:=[3]i32{-1,0,1}
    for target,i in targets {
        append(&state.bindings,Binding{target=target,entity=core.NONE,driven={.Position,.Rotation},rest=mm.TRANSFORM_IDENTITY,parent=parents[i]})
        append(&state.parents,parents[i]);append(&state.targets,target);append(&state.rest,mm.TRANSFORM_IDENTITY)
    }
    resize(&state.local,3);resize(&state.world,3)
    playback:Playback;defer playback_free(&playback)
    testing.expect(t,tracks_bind(&playback,&state,&content))
    events:Animation_Events;defer delete(events.items)
    turns:[2]f32
    for mesh,i in ([2]bool{false,true}) {
        animation:=ANIMATION_DEFAULT
        testing.expect(t,animation_clip(&animation,"turn",fade=0) && test_layer(&state,1,"pose",over="arm",mesh_space=mesh))
        layer_step(&playback,&state,&content,animation,&events,0)
        turns[i]=mm.quat_angle(state.local[1].rotation*state.local[2].rotation,1)
    }
    testing.expectf(t,abs(turns[0]-mm.PI/2)<1e-4 && turns[1]<1e-4 && mm.quat_angle(state.local[1].rotation,side)<1e-4,"in its own space the arm turns with the hip, in the space of the rig it stays straight: %v",turns)
}

@(test)
animation_clip_sets_the_clip_of_the_component :: proc(t:^testing.T) {
    animation:=ANIMATION_DEFAULT
    animation.playing=false
    testing.expect(t,animation_clip(&animation,"jump",fade=0.08,loop=false,speed=0.5))
    testing.expect(t,base.text_get(animation.clip[:])=="jump" && animation.playing && !animation.loop && animation.fade==0.08 && animation.speed==0.5)
    testing.expect(t,animation_clip(&animation,"walk"))
    testing.expect(t,base.text_get(animation.clip[:])=="walk" && !animation.loop && animation.fade==0.08 && animation.speed==1)
}

@(private)
Runtime_Allocation_Failure :: struct {owner:runtime.Allocator,remaining,calls:int}
@(private)
runtime_failure_allocator :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
    state:=(^Runtime_Allocation_Failure)(data)
    if mode==.Alloc || mode==.Alloc_Non_Zeroed || mode==.Resize || mode==.Resize_Non_Zeroed {
        state.calls+=1
        if state.remaining==0 {return nil,.Out_Of_Memory}
        state.remaining-=1
    }
    return state.owner.procedure(state.owner.data,mode,size,alignment,old_memory,old_size,loc)
}

@(private="file")
Bind_World :: struct {
    using world:core.Test_World,
    transforms:core.Table(core.Transform),
    parents:core.Table(core.Parent),
    names:core.Table(core.Name),
    targets:core.Table(Animation_Target),
    animations:core.Table(Animation),
    hierarchy:core.Hierarchy,
    playback:Playback,
}

@(test)
animation_bind_is_transactional_when_allocations_fail_and_stops_at_nested_players :: proc(t:^testing.T) {
    w:Bind_World
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    root,bone,nested,nested_bone:=core.create(&w.entities),core.create(&w.entities),core.create(&w.entities),core.create(&w.entities)
    for e in ([4]core.Entity{root,bone,nested,nested_bone}) {core.add(&w.transforms,e,core.TRANSFORM_IDENTITY);core.add(&w.names,e,{})}
    core.add(&w.parents,bone,{entity=root});core.add(&w.parents,nested,{entity=root});core.add(&w.parents,nested_bone,{entity=nested})
    target:=Animation_Target{};base.text_set(target.path[:],"10");core.add(&w.targets,bone,target);core.add(&w.targets,nested_bone,target)
    core.add(&w.animations,root,ANIMATION_DEFAULT);core.add(&w.animations,nested,ANIMATION_DEFAULT)
    core.test_world_settle(&w)
    content:host.Content_Animation
    testing.expect(t,lib.library_init(&content.lib,{max_keys=2,max_tracks=1,max_clips=1,max_markers=0}))
    defer lib.library_destroy(&content.lib)
    still,_:=lib.clip_add(&content.lib,{tracks={{target=base.name_hash("10"),property=.Position,keys={{time=0,value={1,0,0,0}}}}}})
    testing.expect(t,still!=0)
    testing.expect(t,core.hierarchy_settle(&w.hierarchy,core.read(&w.parents),&w.entities))
    state:=Playing{entity=root}
    defer playing_free(&state)
    testing.expect(t,bind(&w.playback,&state,&content,core.ref(&w.hierarchy),&w.transforms,core.read(&w.names),core.read(&w.targets),core.read(&w.animations),nil))
    testing.expect_value(t,len(state.bindings),2)
    testing.expect_value(t,state.bindings[1].entity,bone)
    core.edit(&w.transforms,bone).position={9,0,0}
    core.edit(&w.transforms,bone).rotation=mm.quat_axis_angle({0,0,1},0.5)
    old_rest:=state.rest[1]
    old_pointer:=raw_data(state.bindings)
    succeeded:=false
    failure:=Runtime_Allocation_Failure{owner=context.allocator}
    for budget in 0..<24 {
        failure.remaining=budget
        saved_context:=context
        context.allocator={runtime_failure_allocator,&failure}
        context.temp_allocator=context.allocator
        ok:=bind(&w.playback,&state,&content,core.ref(&w.hierarchy),&w.transforms,core.read(&w.names),core.read(&w.targets),core.read(&w.animations),nil)
        context=saved_context
        if ok {succeeded=true;break}
        testing.expect_value(t,raw_data(state.bindings),old_pointer)
        testing.expect_value(t,len(state.local),2)
        testing.expect_value(t,state.rest[1],old_rest)
    }
    testing.expect(t,succeeded)
    testing.expect_value(t,state.rest[1],old_rest)
    core.remove(&w.animations,nested);core.test_world_settle(&w)
    append(&w.playback.rigs,Rig{entity=nested,skeleton={1,2}})
    testing.expect(t,bind(&w.playback,&state,&content,core.ref(&w.hierarchy),&w.transforms,core.read(&w.names),core.read(&w.targets),core.read(&w.animations),nil))
    testing.expect_value(t,len(state.bindings),2)
    testing.expect_value(t,len(state.previous),len(state.local))
    saved_context:=context
    context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    failed:Playback
    testing.expect_value(t,state_get(&failed,root),(^Playing)(nil))
    context=saved_context
    playback_free(&failed)
}
