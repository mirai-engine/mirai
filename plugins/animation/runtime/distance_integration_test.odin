package anim

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:host"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"

@(test)
distance_tick_preserves_physical_fade_clocks_root_metadata_and_manual_warp_overrides :: proc(t:^testing.T) {
    assets:host.Assets;app:=host.App{assets=&assets,allocator=context.allocator};defer host.app_content_destroy(&app)
    content:=host.app_content(&app)
    source:host.Content_Animation;initial:=program_test_content(t,&source);defer playing_free(&initial)
    // The run has the span ledge, which the warp window of the same name warps.
    delete(source.lib.markers);source.lib.markers=make([]lib.Marker,3);source.lib.marker_count=3
    source.lib.markers[0],source.lib.markers[1],source.lib.markers[2]={time=.25,id=0},{time=0,id=1,duration=1},{time=.125,id=0}
    for index in ([2]int{2,5}) {source.lib.clips[index].first_marker,source.lib.clips[index].marker_count=1,2}
    delete(source.markers);source.markers=make([]u64,2);source.markers[0],source.markers[1]=base.name_hash("step"),base.name_hash("ledge")
    source.id,source.generation={0x710,0x711},1;append(&content.animations,source);content.index[source.id]={kind=.Animation,index=0}
    test_character_register(&assets,{1,2});defer test_registry_free(&assets)
    entities:core.Entities;core.entities_init(&entities);defer core.entities_destroy(&entities)
    transforms:core.Table(core.Transform);parents:core.Table(core.Parent);names:core.Table(core.Name);targets:core.Table(Animation_Target);animations:core.Table(Animation);roots:core.Table(Root_Motion)
    defer {core.table_destroy(&transforms);core.table_destroy(&parents);core.table_destroy(&names);core.table_destroy(&targets);core.table_destroy(&animations);core.table_destroy(&roots)}
    actor,hip:=core.create(&entities),core.create(&entities)
    core.add(&transforms,actor,core.TRANSFORM_IDENTITY);core.add(&transforms,hip,core.TRANSFORM_IDENTITY);core.add(&parents,hip,{entity=actor})
    name:core.Name;base.text_set(name.text[:],"hip");core.add(&names,hip,name)
    animation:=ANIMATION_DEFAULT;animation.asset=source.id;animation.loop=false;animation.root_motion=.Extract;base.text_set(animation.clip[:],"walk")
    core.add(&animations,actor,animation)
    manual:=Root_Motion{bone=bone_ref("hip"),translation=true};core.add(&roots,actor,manual)
    core.table_settle(&transforms,&entities);core.table_settle(&parents,&entities);core.table_settle(&names,&entities);core.table_settle(&targets,&entities);core.table_settle(&animations,&entities);core.table_settle(&roots,&entities)
    hierarchy:core.Hierarchy;defer core.value_free(&hierarchy,type_info_of(core.Hierarchy))
    core.hierarchy_settle(&hierarchy,core.read(&parents),&entities)
    requests:Animation_Requests;events:Animation_Events;playback:Playback;skeletons:Skeleton_Assets
    defer {delete(requests.timeline.items);delete(requests.poses.items);delete(requests.distances.items);delete(events.items);playback_free(&playback);skeleton_assets_free(&skeletons)}
    motion:Motion_Runtime;motion_requests:Motion_Requests;motion_assets:Character_Assets
    defer {motion_runtime_free(&motion);delete(motion_requests.targets.items);delete(motion_requests.locomotion.items);character_assets_free(&motion_assets)}
    profile:=motion_test_profile();defer motion_test_free(&profile)
    test_character_seed(&motion_assets,{1,2},{info={animation=source.id},motion=profile})
    problems:core.Problems
    step:=proc(animations:^core.Table(Animation),transforms:^core.Table(core.Transform),parents:^core.Table(core.Parent),hierarchy:^core.Hierarchy,names:^core.Table(core.Name),targets:^core.Table(Animation_Target),roots:^core.Table(Root_Motion),requests:^Animation_Requests,events:^Animation_Events,playback:^Playback,app:^host.App,skeletons:^Skeleton_Assets,motion:^Motion_Runtime,motion_requests:^Motion_Requests,motion_assets:^Character_Assets,dt:f32,problems:^core.Problems) {
        animation_tick(core.read(animations),transforms,core.read(parents),core.ref(hierarchy),core.read(names),requests,events,core.read(targets),core.read(roots),playback,app,{dt=dt,playing=true},{},skeletons,problems,characters=motion_assets,motion=motion,motion_requests=motion_requests)
    }
    step(&animations,&transforms,&parents,&hierarchy,&names,&targets,&roots,&requests,&events,&playback,&app,&skeletons,&motion,&motion_requests,&motion_assets,.1,&problems)
    state:=&playback.states[0]
    animation_distance(&requests,actor,base.name_hash("walk"),.8)
    step(&animations,&transforms,&parents,&hierarchy,&names,&targets,&roots,&requests,&events,&playback,&app,&skeletons,&motion,&motion_requests,&motion_assets,.1,&problems)
    testing.expect(t,abs(state.time-.8)<1e-5 && abs(state.motion.translation.x-.7)<1e-5 && len(events.items)==1)
    animation_clip(core.edit_at(&animations,0),"run",fade=1,loop=false)
    step(&animations,&transforms,&parents,&hierarchy,&names,&targets,&roots,&requests,&events,&playback,&app,&skeletons,&motion,&motion_requests,&motion_assets,.1,&problems)
    animation_distance(&requests,actor,base.name_hash("run"),.8)
    step(&animations,&transforms,&parents,&hierarchy,&names,&targets,&roots,&requests,&events,&playback,&app,&skeletons,&motion,&motion_requests,&motion_assets,.1,&problems)
    content.animations[0].roots[2]={}
    clock:=animation_motion_clock(state,&content.animations[0],nil,.1,.7)
    testing.expect(t,abs(state.fader.current.time-.8)<1e-5 && abs(state.fader.outgoing[0].player.time-1)<1e-5 && abs(state.fader.elapsed-.2)<1e-5)
    testing.expect(t,clock.player.clip==1 && abs(clock.from-.9)<1e-5 && abs(clock.to-1)<1e-5 && abs(clock.weight-.8)<1e-5 && clock.root.translation)
    value:=core.edit_at(&animations,0);value.asset={1,2};value.fade=0
    animation_distance(&requests,actor,base.name_hash("run"),0,true)
    step(&animations,&transforms,&parents,&hierarchy,&names,&targets,&roots,&requests,&events,&playback,&app,&skeletons,&motion,&motion_requests,&motion_assets,.1,&problems)
    testing.expect(t,state.motion==ROOT_DELTA_DEFAULT && len(events.items)==0)
    state.fader.outgoing_count=0;state.fader.duration=0
    target:=mm.TRANSFORM_IDENTITY;target.position.x=7;motion_target(&motion_requests,actor,"ledge",spatial_world(target))
    animation_distance(&requests,actor,base.name_hash("run"),1)
    step(&animations,&transforms,&parents,&hierarchy,&names,&targets,&roots,&requests,&events,&playback,&app,&skeletons,&motion,&motion_requests,&motion_assets,.1,&problems)
    testing.expect(t,abs(state.motion.translation.x-7)<1e-5 && motion.instances[0].error==.None && problems.count==0,fmt.tprint(core.problems_list(&problems)))
}

@(test)
a_distance_request_takes_the_clip_of_a_program_to_its_time_without_allocations :: proc(t:^testing.T) {
    content:host.Content_Animation;state:=program_test_content(t,&content);defer {program_test_content_free(&content);playing_free(&state)}
    playback:Playback;events:Animation_Events;defer {playback_free(&playback);delete(events.items)}
    testing.expect(t,tracks_bind(&playback,&state,&content))
    built:=program_test_output(program_test_leaf("walk",0));output:=&built
    animation:=ANIMATION_DEFAULT;animation.loop=false;animation.root_motion=.Extract
    testing.expect(t,program_buffers(&state,&content) && program_players(&state,output,&content,animation,&events,&playback,.1,-1,nil))
    testing.expect(t,program_pose(&playback,&state,&content,animation,output))
    request:=Animation_Distance_Request{entity=state.entity,clip=base.name_hash("walk"),time=.8}
    testing.expect_value(t,distance_request_check(&state,&content,request),Distance_Error.None)
    clear(&events.items)
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    ok:=program_players(&state,output,&content,animation,&events,&playback,.1,-1,nil,&request) && program_pose(&playback,&state,&content,animation,output)
    clock:=animation_motion_clock(&state,&content,output,.1,.1)
    walk:f32
    for slot in state.program.players {if slot.seen!=state.program.frame {continue};clip:=lib.clip_data(&content.lib,slot.player.clip);if clip.name==base.name_hash("walk") {walk=slot.player.time}}
    context=saved
    testing.expect(t,ok && abs(walk-.8)<1e-5 && abs(state.motion.translation.x-.7)<1e-5)
    testing.expect(t,clock.active && clock.player.clip==1 && abs(clock.from-.1)<1e-5 && abs(clock.to-.8)<1e-5 && abs(clock.weight-1)<1e-5)
}
