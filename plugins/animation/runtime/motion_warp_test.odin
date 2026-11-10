package anim

import "base:runtime"
import "core:testing"
import "core:math/linalg"
import "mirai:asset"
import "mirai:core"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/serial"
import lib "mirai:std/anim"
import mm "mirai:std/math"

@(test)
root_warp_skips_idle_without_channels_and_retries_after_a_transient_root_error :: proc(t:^testing.T) {
    content:host.Content_Animation;state:=layer_fixture(t,&content);defer {lib.library_destroy(&content.lib);playing_free(&state)}
    content.roots=make([]asset.Animation_Root,3);defer delete(content.roots)
    base.text_set(content.roots[0].bone[:],"hip");content.roots[0].translation=true
    state.clip=2;state.root_enabled,state.was_playing=true,true;state.bound=1
    state.fader.current=lib.player_make(3);state.fader.current.time=.25
    state.prev_fader.current=lib.player_make(3)
    cache:=Motion_Assets{allocator=context.allocator};defer motion_assets_free(&cache)
    append(&cache.contents,Motion_Content{id={1,2},checked=1,revision=1,profile=motion_test_profile(),valid=true})
    motion:Motion_Runtime;defer motion_runtime_free(&motion)
    append(&motion.instances,Motion_Instance{entity=state.entity});resize(&motion.rows,2);motion.rows[1]=1
    requests:Motion_Requests;defer delete(requests.targets.items)
    goal:=mm.TRANSFORM_IDENTITY;goal.position.x=4
    motion_target(&requests,state.entity,"ledge",spatial_world(goal));motion_take_requests(&motion,&requests,nil)
    assets:host.Assets;app:=host.App{assets=&assets,allocator=context.allocator}
    state.motion={translation={.1,0,0},rotation=1};before:=state.motion
    testing.expect(t,motion_apply_root(&motion,&cache,app.assets,app.allocator,&state,{1,2},&content,mm.TRANSFORM_IDENTITY,.25) && motion.instances[0].error==.None && state.motion==before)
    clock:=Motion_Clock{player=lib.player_make(1),from=0,to=.25,root={translation=true},weight=1,active=true}
    testing.expect(t,!motion_apply_root(&motion,&cache,app.assets,app.allocator,&state,{1,2},&content,mm.TRANSFORM_IDENTITY,.25,clock=clock) && motion.instances[0].error==.Unbound_Bone)
    clock.root.bone=bone_ref("hip")
    testing.expect(t,motion_apply_root(&motion,&cache,app.assets,app.allocator,&state,{1,2},&content,mm.TRANSFORM_IDENTITY,.25,clock=clock) && motion.instances[0].error==.None && motion.instances[0].window==0)
}

@(test)
motion_targets_queued_before_the_first_tick_bind_and_warp_the_same_interval :: proc(t:^testing.T) {
    problems:core.Problems
    assets:host.Assets;app:=host.App{assets=&assets,allocator=context.allocator};defer host.app_content_destroy(&app)
    content:=host.app_content(&app)
    source:host.Content_Animation;initial:=program_test_content(t,&source);defer playing_free(&initial)
    source.id,source.generation={0x810,0x811},1;append(&content.animations,source);content.index[source.id]={kind=.Animation,index=0}
    entities:core.Entities;core.entities_init(&entities);defer core.entities_destroy(&entities)
    transforms:core.Table(core.Transform);parents:core.Table(core.Parent);names:core.Table(core.Name);targets:core.Table(Animation_Target);animations:core.Table(Animation);roots:core.Table(Root_Motion)
    defer {core.table_destroy(&transforms);core.table_destroy(&parents);core.table_destroy(&names);core.table_destroy(&targets);core.table_destroy(&animations);core.table_destroy(&roots)}
    actor,hip:=core.create(&entities),core.create(&entities)
    core.add(&transforms,actor,core.TRANSFORM_IDENTITY);core.add(&transforms,hip,core.TRANSFORM_IDENTITY);core.add(&parents,hip,{entity=actor})
    name:core.Name;base.text_set(name.text[:],"hip");core.add(&names,hip,name)
    animation:=ANIMATION_DEFAULT;animation.asset=source.id;animation.loop=false;animation.root_motion=.Extract;animation.motion={1,2};base.text_set(animation.clip[:],"walk")
    core.add(&animations,actor,animation);core.add(&roots,actor,Root_Motion{bone=bone_ref("hip"),translation=true})
    core.table_settle(&transforms,&entities);core.table_settle(&parents,&entities);core.table_settle(&names,&entities);core.table_settle(&targets,&entities);core.table_settle(&animations,&entities);core.table_settle(&roots,&entities)
    hierarchy:core.Hierarchy;defer core.value_free(&hierarchy,type_info_of(core.Hierarchy))
    core.hierarchy_settle(&hierarchy,core.read(&parents),&entities)
    requests:Animation_Requests;events:Animation_Events;playback:Playback;skeletons:Skeleton_Assets
    defer {delete(requests.timeline.items);delete(requests.poses.items);delete(requests.distances.items);delete(events.items);playback_free(&playback);skeleton_assets_free(&skeletons)}
    motion:Motion_Runtime;motion_requests:Motion_Requests;motion_assets:=Motion_Assets{allocator=context.allocator}
    defer {motion_runtime_free(&motion);delete(motion_requests.targets.items);delete(motion_requests.locomotion.items);motion_assets_free(&motion_assets)}
    profile:=motion_test_profile();profile.windows[0].end=1
    append(&motion_assets.contents,Motion_Content{id={1,2},checked=1,revision=1,profile=profile,valid=true})
    target:=mm.TRANSFORM_IDENTITY;target.position.x=4
    testing.expect(t,len(playback.states)==0)
    motion_target(&motion_requests,actor,"ledge",spatial_world(target))
    testing.expect_value(t,len(motion_requests.targets.items),1)
    animation_tick(core.read(&animations),&transforms,core.read(&parents),core.ref(&hierarchy),core.read(&names),&requests,&events,core.read(&targets),core.read(&roots),&playback,&app,{dt=.25,playing=true},{},&skeletons,&problems,motion=&motion,motion_requests=&motion_requests,motion_assets=&motion_assets)
    instance:=motion_instance(&motion,actor)
    testing.expect(t,instance!=nil && len(instance.targets)==1 && instance.error==.None && instance.targets[0].world==target && problems.count==0 && len(motion_requests.targets.items)==0)
    testing.expect(t,len(playback.states)==1 && abs(playback.states[0].motion.translation.x-1)<1e-5)
}

@(private)
motion_test_profile :: proc() -> Motion_Profile {
    profile:=Motion_Profile{info={pose=POSE_WARP_PROFILE_DEFAULT}}
    profile.windows=make([]Motion_Window,1);profile.windows[0]=MOTION_WINDOW_DEFAULT
    base.text_set(profile.windows[0].clip[:],"walk");base.text_set(profile.windows[0].name[:],"ledge");profile.windows[0].end=2
    profile.distances=make([]Motion_Distance,1);base.text_set(profile.distances[0].clip[:],"walk");base.text_set(profile.distances[0].name[:],"stop");profile.distances[0].count=3
    profile.keys=make([]lib.Distance_Key,3);profile.keys[0],profile.keys[1],profile.keys[2]={0,3},{1,1},{2,0}
    return profile
}

@(test)
motion_profiles_roundtrip_windows_distance_keys_and_reject_overlapping_windows :: proc(t:^testing.T) {
    profile:=motion_test_profile();defer motion_profile_free(&profile)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    doc:asset.Document;defer asset.document_destroy(&doc)
    if !testing.expect_value(t,motion_profile_document(&doc,&types,{11,22},profile),asset.Error.None) {return}
    writer:serial.Writer;serial.writer_init(&writer);defer serial.writer_destroy(&writer)
    if !testing.expect_value(t,asset.document_write(&doc,&writer),asset.Error.None) {return}
    file:asset.Asset;defer asset.asset_close(&file)
    if !testing.expect_value(t,asset.asset_open(&file,serial.writer_bytes(&writer)),asset.Error.None) {return}
    view,error:=motion_profile_view(&file,&types)
    testing.expect_value(t,error,asset.Error.None);testing.expect_value(t,view.info,profile.info)
    testing.expect_value(t,view.windows[0],profile.windows[0]);testing.expect_value(t,view.keys[2],profile.keys[2])
    time,clip,ok:=motion_distance_time(view,"stop",2);testing.expect(t,ok && time==.5 && clip==profile.distances[0].clip)
    profile.windows[0].start=2;testing.expect(t,!motion_profile_check(profile));profile.windows[0].start=0
    duplicate:=[2]Motion_Window{profile.windows[0],profile.windows[0]};invalid:=profile;invalid.windows=duplicate[:]
    testing.expect(t,!motion_profile_check(invalid))
    profile.keys[1].distance=3;testing.expect(t,!motion_profile_check(profile))
}

@(private="file")
Motion_Warp_World :: struct {
    using world:core.Test_World,
    animations:core.Table(Animation),
    worlds:core.Table(core.World_Transform),
}

@(test)
root_warp_targets_reach_the_window_endpoint_copy_and_update_without_stable_allocations :: proc(t:^testing.T) {
    w:Motion_Warp_World
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    entity:=core.create(&w.entities)
    content:host.Content_Animation;state:=layer_fixture(t,&content);state.entity=entity;state.clip=0
    defer lib.library_destroy(&content.lib);defer playing_free(&state)
    content.roots=make([]asset.Animation_Root,3);defer delete(content.roots)
    base.text_set(content.roots[0].bone[:],"hip");content.roots[0].translation=true
    cache:=Motion_Assets{allocator=context.allocator};defer motion_assets_free(&cache)
    append(&cache.contents,Motion_Content{id={1,2},checked=1,revision=1,profile=motion_test_profile(),valid=true})
    host_assets:host.Assets;app:=host.App{assets=&host_assets,allocator=context.allocator}
    motion:Motion_Runtime;defer motion_runtime_free(&motion)
    append(&motion.instances,Motion_Instance{entity=entity,window=-1});resize(&motion.rows,core.entity_index(entity)+1);motion.rows[core.entity_index(entity)]=1
    requests:Motion_Requests;defer delete(requests.targets.items);defer delete(requests.locomotion.items)
    actor:=mm.TRANSFORM_IDENTITY;target:=actor;target.position.x=4
    motion_target(&requests,entity,"ledge",spatial_world(target));motion_take_requests(&motion,&requests,nil)
    testing.expect(t,motion_bind(&motion.instances[0],&state,&cache.contents[0]))
    state.was_playing,state.root_enabled=true,true
    copied:Motion_Runtime;core.value_copy(&copied,&motion,type_info_of(Motion_Runtime));defer motion_runtime_free(&copied)
    copied.instances[0].targets[0].world.position.x=7
    testing.expect(t,motion.instances[0].targets[0].world.position.x==4)
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator();app.allocator=context.allocator
    ok:=true
    for tick in 0..<4 {
        state.prev_fader.current=lib.player_make(1);state.prev_fader.current.time=f32(tick)*.5
        state.fader.current=lib.player_make(1);state.fader.current.time=f32(tick+1)*.5
        state.motion={translation={.5,0,0},rotation=1}
        ok &&=motion_apply_root(&motion,&cache,app.assets,app.allocator,&state,{1,2},&content,actor,.5)
        actor=mm.transform_compose(actor,{position=state.motion.translation,rotation=state.motion.rotation,scale={1,1,1}})
    }
    endpoint:=actor
    state.motion={translation={.5,0,0},rotation=1};before:=state.motion
    ok &&=motion_apply_root(&motion,&cache,app.assets,app.allocator,&state,{1,2},&content,actor,.5,true)
    seek_delta:=state.motion
    state.fader.current.speed=0;ok &&=motion_apply_root(&motion,&cache,app.assets,app.allocator,&state,{1,2},&content,actor,.5)
    zero_speed:=motion.instances[0].error==.None && state.motion==before
    state.fader.current.speed= -1;ok &&=motion_apply_root(&motion,&cache,app.assets,app.allocator,&state,{1,2},&content,actor,.5)
    reverse_error:=motion.instances[0].error
    target.position.x=5;motion_target(&requests,entity,"ledge",spatial_world(target))
    motion_take_requests(&motion,&requests,nil)
    context=saved;cache.allocator=saved.allocator
    testing.expect(t,ok && abs(endpoint.position.x-4)<1e-5 && seek_delta==before && zero_speed && reverse_error==.Unsupported_Clock)
    testing.expect(t,motion.instances[0].targets[0].world.position.x==5)
}

@(test)
motion_requests_reject_invalid_values_and_missing_entity_targets_never_use_stale_positions :: proc(t:^testing.T) {
    entity:=core.entity_make(1,1);target_entity:=core.entity_make(2,1)
    requests:Motion_Requests;defer delete(requests.targets.items);defer delete(requests.locomotion.items)
    motion_target(nil,entity,"x",spatial_world(mm.TRANSFORM_IDENTITY));motion_target(&requests,core.NONE,"x",spatial_world(mm.TRANSFORM_IDENTITY));motion_target(&requests,entity,"",spatial_world(mm.TRANSFORM_IDENTITY))
    testing.expect_value(t,requests.targets.refused,2)
    value:=MOTION_LOCOMOTION_DEFAULT;value.rig=entity;value.velocity.x=f32(0h7fc00000);motion_locomotion(&requests,value)
    testing.expect_value(t,requests.locomotion.refused,1)
    motion:Motion_Runtime;defer motion_runtime_free(&motion)
    append(&motion.instances,Motion_Instance{entity=entity});resize(&motion.rows,2);motion.rows[1]=1
    motion_target(&requests,entity,"ledge",spatial_entity(target_entity))
    motion_take_requests(&motion,&requests,nil);motion_resolve_targets(&motion,nil,nil,{},{},{})
    testing.expect(t,!motion.instances[0].targets[0].resolved && motion.instances[0].error==.Missing_Target)
    for _ in 0..=cap(requests.targets.items) {motion_target(&requests,entity,"ledge",spatial_world(mm.TRANSFORM_IDENTITY))}
    testing.expect_value(t,requests.targets.dropped,1)
}

@(test)
root_warp_uses_action_clocks_handles_rotating_window_prefixes_and_respects_zero_contribution :: proc(t:^testing.T) {
    content:host.Content_Animation;state:=layer_fixture(t,&content);defer playing_free(&state)
    lib.library_destroy(&content.lib);testing.expect(t,lib.library_init(&content.lib,{max_keys=6,max_tracks=2,max_clips=1}))
    defer lib.library_destroy(&content.lib)
    first:=mm.quat_axis_angle({0,0,1},.8);last:=first*mm.quat_axis_angle({0,1,0},.6)
    position:=[3]lib.Keyframe{{time=0},{time=1,value={1,0,0,0}},{time=2,value={2,0,0,0}}}
    rotation:=[3]lib.Keyframe{{time=0,value={0,0,0,1}},{time=1,value={imag(first),jmag(first),kmag(first),real(first)}},{time=2,value={imag(last),jmag(last),kmag(last),real(last)}}}
    clip,_:=lib.clip_add(&content.lib,{name=base.name_hash("walk"),tracks={{target=base.name_hash("hip"),property=.Position,keys=position[:]},{target=base.name_hash("hip"),property=.Rotation,keys=rotation[:]}}})
    state.root_enabled,state.was_playing=true,true;state.clip=0;state.fader.current=lib.player_make(2)
    profile:=motion_test_profile();profile.windows[0].start=1
    cache:=Motion_Assets{allocator=context.allocator};defer motion_assets_free(&cache)
    append(&cache.contents,Motion_Content{id={1,2},checked=1,revision=1,profile=profile,valid=true})
    assets:host.Assets;app:=host.App{assets=&assets,allocator=context.allocator}
    motion:Motion_Runtime;defer motion_runtime_free(&motion)
    append(&motion.instances,Motion_Instance{entity=state.entity});resize(&motion.rows,2);motion.rows[1]=1
    actor:=mm.Transform{{3,1,-4},mm.quat_axis_angle({0,1,0},.4),{2,1,3}}
    target:=mm.transform_compose(actor,{position={3,2,1},rotation=mm.quat_axis_angle({1,0,0},1),scale={1,1,1}})
    requests:Motion_Requests;defer delete(requests.targets.items);defer delete(requests.locomotion.items)
    motion_target(&requests,state.entity,"ledge",spatial_world(target));motion_take_requests(&motion,&requests,nil)
    clock:=Motion_Clock{player=lib.player_make(clip),from=0,to=2,root={bone=bone_ref("hip"),translation=true,rotation=true},weight=1,active=true}
    state.motion={translation={2,0,0},rotation=last}
    testing.expect(t,motion_apply_root(&motion,&cache,app.assets,app.allocator,&state,{1,2},&content,actor,2,false,clock))
    endpoint:=mm.transform_compose(actor,{position=state.motion.translation,rotation=state.motion.rotation,scale={1,1,1}})
    testing.expect(t,linalg.length(endpoint.position-target.position)<1e-5 && mm.quat_angle(endpoint.rotation,target.rotation)<1e-5)
    state.motion={translation={2,0,0},rotation=last};before:=state.motion;clock.weight=0
    testing.expect(t,motion_apply_root(&motion,&cache,app.assets,app.allocator,&state,{1,2},&content,actor,2,false,clock) && state.motion==before)
    clock.active=false;clock.weight=1
    testing.expect(t,motion_apply_root(&motion,&cache,app.assets,app.allocator,&state,{1,2},&content,actor,2,false,clock) && state.motion==before)
    state.fader.current=lib.player_make(clip);content.roots=make([]asset.Animation_Root,1);defer delete(content.roots)
    base.text_set(content.roots[0].bone[:],"hip");content.roots[0].translation,content.roots[0].rotation=true,true
    testing.expect(t,motion_apply_root(&motion,&cache,app.assets,app.allocator,&state,{1,2},&content,actor,2,false,{},0) && state.motion==before)
}

@(test)
pose_warp_runtime_binds_named_bones_preserves_source_knee_planes_reuses_buffers_and_rejects_replaced_bones :: proc(t:^testing.T) {
    entity:=core.entity_make(1,1);state:=Playing{entity=entity,bound=1};defer playing_free(&state)
    parents:=[6]i32{-1,0,1,2,3,1};names:=[6]string{"","pelvis","hip","knee","foot","spine"}
    rest:=[6]mm.Transform{mm.TRANSFORM_IDENTITY,mm.TRANSFORM_IDENTITY,mm.TRANSFORM_IDENTITY,mm.TRANSFORM_IDENTITY,mm.TRANSFORM_IDENTITY,mm.TRANSFORM_IDENTITY}
    actor:=mm.Transform{{4,0,-3},mm.quat_axis_angle({0,1,0},.4),{1,1,1}}
    rest[0]=actor;rest[1].position={0,2,0};rest[3].position={0,-.8,.3};rest[4].position={0,-.7,.4};rest[5].position={0,1,0}
    for name,i in names {
        target:=base.name_hash(name) if i>0 else 0
        append(&state.parents,parents[i]);append(&state.targets,target);append(&state.aliases,target);append(&state.rest,rest[i]);append(&state.local,rest[i]);append(&state.world,rest[i])
    }
    config:=POSE_WARP_PROFILE_DEFAULT;config.pelvis=bone_ref("pelvis");config.spine[0]=bone_ref("spine");config.spine_count=1
    config.legs[0]={hip=bone_ref("hip"),knee=bone_ref("knee"),foot=bone_ref("foot")};config.count=1;config.orientation,config.stride=true,true;config.max_angle=.5
    cache:=Motion_Assets{allocator=context.allocator};defer motion_assets_free(&cache)
    append(&cache.contents,Motion_Content{id={3,4},revision=1,profile={info={pose=config}},valid=true})
    motion:Motion_Runtime;defer motion_runtime_free(&motion)
    append(&motion.instances,Motion_Instance{entity=entity});resize(&motion.rows,2);motion.rows[1]=1
    requests:Motion_Requests;defer delete(requests.targets.items);defer delete(requests.locomotion.items)
    goal:=MOTION_LOCOMOTION_DEFAULT;goal.rig=entity;goal.velocity=mm.transform_direction(actor,{1.5,0,0});goal.source_velocity=mm.transform_direction(actor,{0,0,1})
    motion_locomotion(&requests,goal);motion_take_requests(&motion,&requests,nil)
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    ok:=true
    source:=motion.instances[0].locomotion.source_velocity
    motion.instances[0].locomotion.velocity=source
    copy(state.local[:],rest[:]);ok &&=motion_apply_pose(&motion,&state,{3,4},actor,mm.TRANSFORM_IDENTITY,&cache,nil)
    identity:=true;for bone,i in state.local {identity &&=bone==rest[i]}
    motion.instances[0].locomotion.velocity=goal.velocity
    for _ in 0..<120 {copy(state.local[:],rest[:]);ok &&=motion_apply_pose(&motion,&state,{3,4},actor,mm.TRANSFORM_IDENTITY,&cache,nil)}
    final:=state.local[1];spine:=state.world[5];upper:=linalg.length(state.world[3].position-state.world[2].position);lower:=linalg.length(state.world[4].position-state.world[3].position)
    motion.instances[0].locomotion.weight=0;copy(state.local[:],rest[:]);ok &&=motion_apply_pose(&motion,&state,{3,4},actor,mm.TRANSFORM_IDENTITY,&cache,nil)
    unwarped:=state.local[1]==rest[1]
    // A body that nearly stops leaves the pose nearly as the clip has it, as one that stops does:
    // the warp fades out with the speed instead of shrinking the stride to its minimum.
    motion.instances[0].locomotion.weight=1;motion.instances[0].locomotion.velocity=goal.velocity*.003
    copy(state.local[:],rest[:]);ok &&=motion_apply_pose(&motion,&state,{3,4},actor,mm.TRANSFORM_IDENTITY,&cache,nil)
    nearly:=true;for bone,i in state.local {nearly &&=mm.quat_angle(bone.rotation,rest[i].rotation)<1e-2 && linalg.length(bone.position-rest[i].position)<1e-2}
    context=saved
    testing.expect(t,nearly,"a body at 5 mm/s keeps the pose of the clip")
    testing.expect(t,ok && identity && final.rotation!=rest[1].rotation && mm.quat_angle(spine.rotation,actor.rotation)<1e-5 && unwarped)
    testing.expect(t,abs(upper-linalg.length(rest[3].position))<1e-5 && abs(lower-linalg.length(rest[4].position))<1e-5)
    state.targets[4]=base.name_hash("replaced");state.aliases[4]=state.targets[4];state.bound+=1
    testing.expect(t,!motion_apply_pose(&motion,&state,{3,4},actor,mm.TRANSFORM_IDENTITY,&cache,nil) && motion.instances[0].error==.Unbound_Bone)
}

@(test)
root_warp_crosses_multiple_windows_in_time_order_and_includes_prior_window_corrections :: proc(t:^testing.T) {
    content:host.Content_Animation;state:=layer_fixture(t,&content);state.clip=0;defer lib.library_destroy(&content.lib);defer playing_free(&state)
    content.roots=make([]asset.Animation_Root,1);defer delete(content.roots);base.text_set(content.roots[0].bone[:],"hip");content.roots[0].translation=true
    profile:=motion_test_profile();first:=profile.windows[0];first.end=1;base.text_set(first.name[:],"first")
    last:=profile.windows[0];last.start=1;base.text_set(last.name[:],"last")
    delete(profile.windows);profile.windows=make([]Motion_Window,2);profile.windows[0],profile.windows[1]=last,first
    testing.expect(t,motion_profile_check(profile))
    cache:=Motion_Assets{allocator=context.allocator};defer motion_assets_free(&cache);append(&cache.contents,Motion_Content{id={1,2},checked=1,revision=1,profile=profile,valid=true})
    assets:host.Assets;app:=host.App{assets=&assets,allocator=context.allocator}
    motion:Motion_Runtime;defer motion_runtime_free(&motion);append(&motion.instances,Motion_Instance{entity=state.entity});resize(&motion.rows,2);motion.rows[1]=1
    requests:Motion_Requests;defer delete(requests.targets.items);defer delete(requests.locomotion.items)
    target:=mm.TRANSFORM_IDENTITY;target.position.x=3;motion_target(&requests,state.entity,"first",spatial_world(target));target.position.x=5;motion_target(&requests,state.entity,"last",spatial_world(target));motion_take_requests(&motion,&requests,nil)
    state.root_enabled,state.was_playing=true,true;state.fader.current=lib.player_make(1);state.fader.current.time=2;state.prev_fader.current=lib.player_make(1)
    state.motion={translation={2,0,0},rotation=1}
    testing.expect(t,motion_apply_root(&motion,&cache,app.assets,app.allocator,&state,{1,2},&content,mm.TRANSFORM_IDENTITY,2) && abs(state.motion.translation.x-5)<1e-5 && motion.instances[0].window==0)
}

@(test)
motion_runtime_reuses_generational_entity_slots_and_retires_only_the_mapping_it_owns :: proc(t:^testing.T) {
    problems:core.Problems
    w:Motion_Warp_World
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    playback:Playback;defer playback_free(&playback)
    motion:Motion_Runtime;defer motion_runtime_free(&motion)
    requests:Motion_Requests;defer {delete(requests.targets.items);delete(requests.locomotion.items)}
    cache:=Motion_Assets{allocator=context.allocator};defer motion_assets_free(&cache)
    append(&cache.contents,Motion_Content{id={1,2},checked=1,revision=1,profile=motion_test_profile(),valid=true})
    host_assets:host.Assets;app:=host.App{assets=&host_assets,allocator=context.allocator}
    entity:=core.create(&w.entities);index:=core.entity_index(entity)
    append(&playback.states,Playing{entity=entity,bound=1});resize(&playback.rows,index+1);playback.rows[index]=1
    config:=ANIMATION_DEFAULT;config.motion={1,2};core.add(&w.animations,entity,config);core.test_world_settle(&w)
    testing.expect(t,motion_prepare(&motion,&requests,core.read(&w.animations),&playback,&cache,app.assets,app.allocator,&problems))
    motion_target(&requests,entity,"ledge",spatial_world(mm.TRANSFORM_IDENTITY))
    motion_take_requests(&motion,&requests,&problems)
    old:=entity
    testing.expect(t,core.destroy(&w.entities,entity));core.test_world_settle(&w)
    entity=core.create(&w.entities);testing.expect(t,core.entity_index(entity)==index && entity!=old)
    core.add(&w.animations,entity,config);core.test_world_settle(&w);playback.states[0].entity=entity
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    ok:=motion_prepare(&motion,&requests,core.read(&w.animations),&playback,&cache,app.assets,app.allocator,&problems)
    target:=mm.TRANSFORM_IDENTITY;target.position.x=7
    motion_target(&requests,entity,"ledge",spatial_world(target))
    ok &&=motion_prepare(&motion,&requests,core.read(&w.animations),&playback,&cache,app.assets,app.allocator,&problems)
    current:=motion_instance(&motion,entity);old_instance:=motion_instance(&motion,old)
    preserved:=current!=nil && len(current.targets)==1 && current.targets[0].world==target && len(motion.instances)==1 && old_instance==nil
    context=saved
    testing.expect(t,ok && preserved && problems.count==0)
    core.remove(&w.animations,entity);core.test_world_settle(&w)
    testing.expect(t,motion_prepare(&motion,&requests,core.read(&w.animations),&playback,&cache,app.assets,app.allocator,&problems) && motion_instance(&motion,entity)==nil && motion.rows[index]==0)
}

@(test)
motion_discovers_changed_profiles_retries_first_targets_and_compacts_instances_in_world_copies :: proc(t:^testing.T) {
    w:Motion_Warp_World
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    first,second,plain:=core.create(&w.entities),core.create(&w.entities),core.create(&w.entities)
    for entity in ([3]core.Entity{first,second,plain}) {core.add(&w.animations,entity,ANIMATION_DEFAULT)}
    core.test_world_settle(&w)
    playback:Playback;defer playback_free(&playback)
    for entity in ([2]core.Entity{first,second}) {append(&playback.states,Playing{entity=entity,bound=1});index:=core.entity_index(entity);resize(&playback.rows,index+1);playback.rows[index]=i32(len(playback.states))}
    cache:=Motion_Assets{allocator=context.allocator};defer motion_assets_free(&cache)
    append(&cache.contents,Motion_Content{id={3,4},checked=1,revision=1,profile=motion_test_profile(),valid=true},Motion_Content{id={3,5},checked=1,revision=1,profile=motion_test_profile(),valid=true})
    host_assets:host.Assets;app:=host.App{assets=&host_assets,allocator=context.allocator}
    motion:Motion_Runtime;defer motion_runtime_free(&motion)
    requests:Motion_Requests;defer {delete(requests.targets.items);delete(requests.locomotion.items)}
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=context.allocator;app.allocator=context.allocator
    prepared:=motion_prepare(&motion,&requests,core.read(&w.animations),&playback,&cache,app.assets,app.allocator,nil)
    context=saved;app.allocator=saved.allocator
    testing.expect(t,prepared && len(motion.instances)==0 && cap(motion.rows)==0)
    core.edit(&w.animations,first).motion={3,4};core.edit(&w.animations,second).motion={3,5}
    target:=mm.TRANSFORM_IDENTITY;target.position.x=4;motion_target(&requests,first,"ledge",spatial_world(target))
    observed:=motion.animations_seen
    context.allocator=runtime.nil_allocator();context.temp_allocator=context.allocator;app.allocator=context.allocator
    prepared=motion_prepare(&motion,&requests,core.read(&w.animations),&playback,&cache,app.assets,app.allocator,nil)
    context=saved;app.allocator=saved.allocator
    testing.expect(t,!prepared && len(motion.instances)==0 && len(requests.targets.items)==1 && motion.animations_seen==observed)
    testing.expect(t,motion_prepare(&motion,&requests,core.read(&w.animations),&playback,&cache,app.assets,app.allocator,nil) && len(motion.instances)==2 && motion_instance(&motion,first).targets[0].world==target && len(requests.targets.items)==0)
    copied:Motion_Runtime;core.value_copy(&copied,&motion,type_info_of(Motion_Runtime));defer motion_runtime_free(&copied)
    motion_instance(&copied,first).targets[0].world.position.x=9
    testing.expect(t,motion_instance(&motion,first).targets[0].world.position.x==4)
    core.edit(&w.animations,first).motion={3,5};core.edit(&w.animations,second).motion={};core.edit(&w.animations,plain).weight=.3
    context.allocator=runtime.nil_allocator();context.temp_allocator=context.allocator;app.allocator=context.allocator
    prepared=motion_prepare(&motion,&requests,core.read(&w.animations),&playback,&cache,app.assets,app.allocator,nil)
    context=saved;app.allocator=saved.allocator;cache.allocator=saved.allocator
    testing.expect(t,prepared && len(motion.instances)==1 && motion_instance(&motion,second)==nil && motion_instance(&motion,first).profile==base.Asset_Id{3,5} && motion_instance(&motion,first).targets[0].world==target)
    testing.expect(t,len(copied.instances)==2 && motion_instance(&copied,second)!=nil)
    core.remove(&w.animations,first);core.test_world_settle(&w)
    testing.expect(t,motion_prepare(&motion,&requests,core.read(&w.animations),&playback,&cache,app.assets,app.allocator,nil) && len(motion.instances)==0 && motion_instance(&motion,first)==nil)
}

@(test)
root_warp_reaches_a_bone_or_socket_of_another_rig_from_the_pose_it_sampled_in_the_previous_tick :: proc(t:^testing.T) {
    content:host.Content_Animation;state:=layer_fixture(t,&content);state.clip=0;defer lib.library_destroy(&content.lib);defer playing_free(&state)
    content.roots=make([]asset.Animation_Root,1);defer delete(content.roots);base.text_set(content.roots[0].bone[:],"hip");content.roots[0].translation=true
    cache:=Motion_Assets{allocator=context.allocator};defer motion_assets_free(&cache);append(&cache.contents,Motion_Content{id={1,2},checked=1,revision=1,profile=motion_test_profile(),valid=true})
    assets:host.Assets;app:=host.App{assets=&assets,allocator=context.allocator}
    motion:Motion_Runtime;defer motion_runtime_free(&motion);append(&motion.instances,Motion_Instance{entity=state.entity});resize(&motion.rows,2);motion.rows[1]=1
    other:=core.entity_make(3,1)
    playback:=Playback{frame=5};defer playback_free(&playback)
    append(&playback.states,rig_test_state(other,3,.5));resize(&playback.rows,4);playback.rows[3]=1
    sampled:=&playback.states[0];sampled.seen=4;sampled.skeleton={4,5}
    w:Motion_Warp_World
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    testing.expect(t,modifier_append(&w.worlds,other,core.World_Transform{transform={{10,0,0},1,{1,1,1}}}))
    sockets:=make([]asset.Skeleton_Socket,1)
    base.text_set(sockets[0].name[:],"grip");base.text_set(sockets[0].bone[:],"joint3");sockets[0].offset=mm.TRANSFORM_IDENTITY;sockets[0].offset.position={0,.2,0}
    skeletons:Skeleton_Assets;defer skeleton_assets_free(&skeletons)
    append(&skeletons.contents,Skeleton_Content{id=sampled.skeleton,sockets=sockets})
    requests:Motion_Requests;defer delete(requests.targets.items);defer delete(requests.locomotion.items)
    motion_target(&requests,state.entity,"ledge",spatial_bone(other,"joint3"));motion_take_requests(&motion,&requests,nil)
    testing.expect(t,!motion.instances[0].targets[0].resolved,"a bone is found before the rigs sample, not when it is asked")
    motion_resolve_targets(&motion,&playback,&skeletons,{},{},core.read(&w.worlds))
    target:=motion.instances[0].targets[0]
    testing.expect(t,target.resolved && linalg.length(target.world.position-mm.Vec3{10,1,0})<1e-5)
    state.root_enabled,state.was_playing=true,true;state.fader.current=lib.player_make(1);state.fader.current.time=2;state.prev_fader.current=lib.player_make(1)
    state.motion={translation={2,0,0},rotation=1}
    testing.expect(t,motion_apply_root(&motion,&cache,app.assets,app.allocator,&state,{1,2},&content,mm.TRANSFORM_IDENTITY,2) && linalg.length(state.motion.translation-mm.Vec3{10,1,0})<1e-4 && motion.instances[0].remaining_error<1e-4)
    motion_target(&requests,state.entity,"ledge",spatial_socket(other,"grip"));motion_take_requests(&motion,&requests,nil)
    motion_resolve_targets(&motion,&playback,&skeletons,{},{},core.read(&w.worlds))
    testing.expect(t,len(motion.instances[0].targets)==1 && motion.instances[0].targets[0].resolved && linalg.length(motion.instances[0].targets[0].world.position-mm.Vec3{10,1.2,0})<1e-5)
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    stable:=true
    for _ in 0..<8 {motion_resolve_targets(&motion,&playback,&skeletons,{},{},core.read(&w.worlds));stable &&=motion.instances[0].targets[0].resolved}
    context=saved
    testing.expect(t,stable)
    sampled.seen=5
    motion_resolve_targets(&motion,&playback,&skeletons,{},{},core.read(&w.worlds))
    testing.expect(t,!motion.instances[0].targets[0].resolved && motion.instances[0].error==.Missing_Target,"a rig not sampled in the previous tick names no place")
}
