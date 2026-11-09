package anim

import "base:runtime"
import "core:fmt"
import "core:math/linalg"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:platform"
import lib "mirai:std/anim"
import "mirai:std/base"
import "mirai:std/jobs"
import mm "mirai:std/math"

// What animation_advance reads and writes, with the tables a test fills.
@(private="file")
Rig_World :: struct {
    entities:core.Entities,
    transforms:core.Table(core.Transform),
    parents:core.Table(core.Parent),
    labels:core.Table(core.Name),
    meshes:core.Table(erender.Mesh_Renderer),
    skins:core.Table(Pose_Source),
    animations:core.Table(Animation),
    targets:core.Table(Animation_Target),
    ik:core.Table(IK_Constraint),
    look:core.Table(Look_Constraint),
    limits:core.Table(Rotation_Constraint),
    feet:core.Table(Foot_Contact_Constraint),
    sockets:core.Table(Bone_Binding),
    retargets:core.Table(Retarget_Mapping),
    roots:core.Table(Root_Motion),
    worlds:core.Table(core.World_Transform),
    motions:core.Table(Root_Delta),
    grounded:core.Table(Foot_Grounding),
    requests:Animation_Requests,
    events:Animation_Events,
    playback:Playback,
    constraints:Animation_Constraints,
    cache:Skeleton_Assets,
    grounding:Grounding_Runtime,
    problems:core.Problems,
}

@(private="file")
rig_world_destroy :: proc(w:^Rig_World) {
    core.table_destroy(&w.transforms);core.table_destroy(&w.parents);core.table_destroy(&w.labels);core.table_destroy(&w.meshes);core.table_destroy(&w.skins)
    core.table_destroy(&w.ik);core.table_destroy(&w.look);core.table_destroy(&w.limits);core.table_destroy(&w.feet);core.table_destroy(&w.sockets)
    core.table_destroy(&w.retargets);core.table_destroy(&w.roots);core.table_destroy(&w.worlds);core.table_destroy(&w.motions);core.table_destroy(&w.grounded)
    core.table_destroy(&w.animations);core.table_destroy(&w.targets)
    delete(w.requests.seeks.items);delete(w.requests.distances.items);delete(w.requests.poses.items);delete(w.requests.final_poses.items);delete(w.events.items)
    playback_free(&w.playback);constraints_free(&w.constraints);skeleton_assets_free(&w.cache);grounding_free(&w.grounding)
    core.entities_destroy(&w.entities)
}

@(private="file")
rig_world_settle :: proc(w:^Rig_World) {
    core.table_settle(&w.transforms,&w.entities);core.table_settle(&w.meshes,&w.entities);core.table_settle(&w.animations,&w.entities);core.table_settle(&w.ik,&w.entities)
}

@(private="file")
rig_world_advance :: proc(w:^Rig_World,app:^host.App,time:core.Time,frame:core.Frame_Time={}) {
    if app.assets!=nil {rigs_update(&w.playback,core.read(&w.meshes),core.read(&w.skins),app)}
    animation_tick(core.read(&w.animations),&w.transforms,core.read(&w.parents),{},core.read(&w.labels),&w.requests,&w.events,core.read(&w.targets),core.read(&w.roots),&w.playback,app,time,frame,&w.cache,&w.problems)
    inputs:=Constraint_Inputs{core.read(&w.ik),core.read(&w.look),core.read(&w.limits),core.read(&w.feet),core.read(&w.sockets),core.read(&w.retargets),core.read(&w.roots),core.read(&w.worlds),0,&w.cache,&w.problems}
    ground_inputs:=Grounding_Inputs{core.read(&w.grounded),{},core.read(&w.transforms),core.read(&w.parents),0,&w.problems,{}}
    animation_finish(&w.playback,inputs,&w.constraints,&w.transforms,core.read(&w.parents),time.dt,&w.grounding,ground_inputs,final_poses=core.take(&w.requests.final_poses))
}

// A skeleton of three bones in a column, a mesh bound to it and a clip that turns the upper bone a quarter.
@(private="file")
rig_assets :: proc(t:^testing.T,directory:string) -> (skeleton,mesh,clips:base.Asset_Id,ok:bool) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    bones:=[3]asset.Skeleton_Bone{{parent=-1,translation={0,2,0},rotation=1,scale={1,1,1}},{parent=0,translation={0,-1,0},rotation=1,scale={1,1,1}},{parent=1,translation={0,-1,0},rotation=1,scale={1,1,1}}}
    paths:=[3]string{"upper","upper/lower","upper/lower/foot"}
    names:=[3]string{"upper","lower","foot"}
    for &bone,i in bones {base.text_set(bone.path[:],paths[i]);base.text_set(bone.name[:],names[i]);bone.target=base.name_hash(paths[i])}
    skeleton,mesh,clips={0x533,0x224},{0x533,0x225},{0x533,0x226}
    vertices:=[3]asset.Vertex{{position={-1,0,0},color=0xffffffff},{position={1,0,0},color=0xffffffff},{position={0,1,0},color=0xffffffff}}
    influences:[3]asset.Skin_Vertex
    for &influence in influences {influence.weights[0]=255}
    joints:=[1]asset.Rig_Joint{{node=0,inverse_bind=1}}
    turn:=[2]lib.Keyframe{{time=0,value=lib.quat_vec4(1)},{time=1,value=lib.quat_vec4(mm.quat_axis_angle({1,0,0},mm.PI*0.5))}}
    ok=testing.expect_value(t,asset.skeleton_save(fmt.tprintf("%s/rig.skeleton",directory),&types,{id=skeleton,bones=bones[:]}),asset.Error.None) &&
       testing.expect_value(t,rig_mesh_save(fmt.tprintf("%s/rig.mesh",directory),&types,{id=mesh,skeleton=skeleton,joints=joints[:]},vertices[:],{0,1,2},influences[:]),asset.Error.None) &&
       testing.expect_value(t,asset.animation_save(fmt.tprintf("%s/rig.anim",directory),&types,{id=clips,clips={{name="lift",tracks={{target="upper",property=.Rotation,keys=turn[:]}}}}}),asset.Error.None)
    return
}

@(private="file")
rig_directory :: proc(name:string) -> string {
    directory:=fmt.tprintf(".mirai/test-%s-%d",name,os.get_pid())
    os.make_directory_all(directory)
    return directory
}

@(private="file")
rig_directory_remove :: proc(directory:string) {
    for file in ([3]string{"rig.skeleton","rig.mesh","rig.anim"}) {os.remove(fmt.tprintf("%s/%s",directory,file))}
    os.remove(directory)
}

@(test)
skeleton_content_follows_a_skeleton_held_unsaved_in_the_memory_of_the_registry :: proc(t:^testing.T) {
    directory:=rig_directory("unsaved-skeleton");defer rig_directory_remove(directory)
    skeleton_id,_,_,saved:=rig_assets(t,directory);if !saved {return}
    assets:host.Assets;if !testing.expect(t,host.assets_init(&assets,{root=directory})) {return};defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets,allocator=context.allocator}
    skeletons:Skeleton_Assets;defer skeleton_assets_free(&skeletons)
    content:=skeleton_content(&skeletons,&app,skeleton_id)
    if !testing.expect(t,content!=nil && len(content.bones)==3) {return}
    path:=fmt.tprintf("%s/rig.skeleton",directory)
    disk,_:=os.read_entire_file(path,context.temp_allocator)
    bone:=asset.Skeleton_Bone{parent=-1,rotation=1,scale={1,1,1},target=base.name_hash("alone")}
    base.text_set(bone.path[:],"alone");base.text_set(bone.name[:],"alone")
    doc:asset.Document;defer asset.document_destroy(&doc)
    if !testing.expect_value(t,asset.skeleton_document(&doc,&assets.types,{id=skeleton_id,bones={bone}}),asset.Error.None) {return}
    bytes,error:=asset.document_bytes(&doc,context.temp_allocator);if !testing.expect_value(t,error,asset.Error.None) {return}
    // What an editor leaves unsaved: only the registry holds it, and only its revision tells.
    revision:=assets.revision
    testing.expect_value(t,asset.registry_memory_set(&assets.registry,"rig.skeleton",bytes),asset.Error.None)
    content=skeleton_content(&skeletons,&app,skeleton_id)
    testing.expect(t,content!=nil && len(content.bones)==1 && base.text_get(content.bones[0].name[:])=="alone")
    after,_:=os.read_entire_file(path,context.temp_allocator)
    testing.expect(t,assets.revision==revision && string(after)==string(disk))
    testing.expect(t,asset.registry_memory_drop(&assets.registry,"rig.skeleton"))
    content=skeleton_content(&skeletons,&app,skeleton_id)
    testing.expect(t,content!=nil && len(content.bones)==3)
}

@(test)
skeleton_discovery_preserves_logical_rigs_on_unrelated_changes_and_retries_allocation_failure :: proc(t:^testing.T) {
    directory:=rig_directory("rig-discovery");defer rig_directory_remove(directory)
    _,mesh_id,_,saved:=rig_assets(t,directory);if !saved {return}
    assets:host.Assets;if !testing.expect(t,host.assets_init(&assets,{root=directory})) {return};defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets,allocator=context.allocator}
    w:Rig_World;core.entities_init(&w.entities);defer rig_world_destroy(&w)
    first,second,third:=core.create(&w.entities),core.create(&w.entities),core.create(&w.entities)
    core.add(&w.meshes,second,{mesh=mesh_id});core.add(&w.meshes,first,{mesh=mesh_id});rig_world_settle(&w)
    testing.expect(t,rigs_update(&w.playback,core.read(&w.meshes),core.read(&w.skins),&app))
    stamp:=w.playback.rigs_stamp;pointer:=raw_data(w.playback.rigs)
    testing.expect(t,rig_find(&w.playback,first)>=0 && rig_find(&w.playback,second)>=0 && rig_find(&w.playback,third)<0)
    assets.revision+=1;core.get(&w.meshes,first).materials[0]={0xab,0xcd}
    saved_context:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    testing.expect(t,rigs_update(&w.playback,core.read(&w.meshes),core.read(&w.skins),&app))
    context=saved_context
    testing.expect(t,w.playback.rigs_stamp==stamp && raw_data(w.playback.rigs)==pointer)
    core.add(&w.meshes,third,{mesh=mesh_id});rig_world_settle(&w)
    inputs:=w.playback.rigs_inputs
    context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    testing.expect(t,!rigs_update(&w.playback,core.read(&w.meshes),core.read(&w.skins),&app))
    context=saved_context
    testing.expect(t,w.playback.rigs_inputs==inputs && w.playback.rigs_stamp==stamp && raw_data(w.playback.rigs)==pointer && len(w.playback.rigs)==2)
    testing.expect(t,rigs_update(&w.playback,core.read(&w.meshes),core.read(&w.skins),&app))
    testing.expect(t,w.playback.rigs_stamp==stamp+1 && len(w.playback.rigs)==3 && rig_find(&w.playback,third)>=0)
    testing.expect(t,rig_find(&w.playback,core.entity_make(core.entity_index(first),core.entity_generation(first)+1))<0)
}

@(test)
skeleton_without_clips_evaluates_named_ik_and_pose_requests_without_bone_entities_or_stable_allocations :: proc(t:^testing.T) {
    directory:=rig_directory("procedural-skeleton");defer rig_directory_remove(directory)
    _,mesh_id,_,saved:=rig_assets(t,directory)
    if !saved {return}
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=directory})) {return}
    defer host.assets_destroy(&assets)
    content:host.Content
    app:=host.App{assets=&assets,allocator=context.allocator,content=&content}
    w:Rig_World;core.entities_init(&w.entities);defer rig_world_destroy(&w)
    rig,helper:=core.create(&w.entities),core.create(&w.entities)
    placed:=core.TRANSFORM_IDENTITY;placed.position.x=7
    core.add(&w.transforms,rig,placed);core.add(&w.meshes,rig,{mesh=mesh_id})
    leg:=IK_CONSTRAINT_DEFAULT;leg.rig=rig;leg.root=bone_ref("upper");leg.joint=bone_ref("lower");leg.end=bone_ref("foot")
    leg.target=spatial_point({7,0.2,0.2});leg.pole={7,1,2}
    core.add(&w.ik,helper,leg)
    rig_world_settle(&w)
    for iteration in 0..<3 {
        failure:=Runtime_Allocation_Failure{owner=context.allocator,remaining=0}
        previous_context:=context
        previous_allocator:=app.allocator
        if iteration>0 {context.allocator={runtime_failure_allocator,&failure};context.temp_allocator=context.allocator;app.allocator=context.allocator}
        rig_world_advance(&w,&app,{dt=1.0/60,playing=true})
        context=previous_context;app.allocator=previous_allocator;w.cache.allocator=previous_allocator
        if iteration>0 {testing.expect_value(t,failure.calls,0)}
        pose,found:=animation_bone_transform(&w.playback,rig,bone_ref("foot"))
        testing.expect(t,found && linalg.length(pose.position-leg.target.position)<0.001)
    }
    testing.expect_value(t,len(w.playback.rigs),1)
    testing.expect_value(t,len(w.playback.states),1)
    testing.expect_value(t,len(w.playback.states[0].local),4)
    testing.expect_value(t,len(w.transforms.values),1)
    testing.expect_value(t,w.entities.alive,2)
    for binding in w.playback.states[0].bindings[1:] {testing.expect_value(t,binding.entity,core.NONE)}
    state:=&w.playback.states[0]
    testing.expect_value(t,bone_resolve(state,bone_ref("upper/lower/foot")),3)
    testing.expect_value(t,bone_resolve(state,bone_ref("foot")),3)
    testing.expect_value(t,bone_resolve(state,bone_ref("missing")),-1)
    core.get(&w.ik,helper).enabled=false
    authored:=mm.Transform{position={0,2,0},rotation=mm.quat_axis_angle({0,1,0},0.4),scale={1,1,1}}
    animation_pose(&w.requests,rig,bone_ref("upper"),authored)
    rig_world_advance(&w,&app,{dt=1.0/60,playing=true})
    testing.expect_value(t,state.local[1],authored)
    testing.expect_value(t,w.problems.count,0)
    bound:=state.bound
    core.get(&w.ik,helper).enabled=true
    // A skin follows the pose of another rig: its entity is no rig of its own.
    follower:=core.create(&w.entities)
    core.add(&w.transforms,follower,placed);core.add(&w.meshes,follower,{mesh=mesh_id});core.add(&w.skins,follower,{rig=rig})
    core.table_settle(&w.skins,&w.entities);rig_world_settle(&w)
    rig_world_advance(&w,&app,{dt=1.0/60,playing=true})
    testing.expect(t,len(w.playback.rigs)==1 && w.playback.rigs[0].entity==rig && len(w.playback.states)==1)
    core.remove(&w.meshes,follower);core.remove(&w.skins,follower);core.remove(&w.transforms,follower)
    core.table_settle(&w.skins,&w.entities)
    for stage in 0..<7 {
        switch stage {
        case 0: core.add(&w.animations,rig,ANIMATION_DEFAULT)
        case 1: core.remove(&w.animations,rig)
        case 2: core.add(&w.animations,rig,ANIMATION_DEFAULT)
        case 3: core.remove(&w.animations,rig);core.remove(&w.meshes,rig)
        case 4: core.add(&w.meshes,rig,{mesh=mesh_id})
        case 5: core.remove(&w.transforms,rig)
        case 6: core.add(&w.transforms,rig,placed)
        }
        rig_world_settle(&w)
        rig_world_advance(&w,&app,{dt=1.0/60,playing=true})
        pose,found:=animation_bone_transform(&w.playback,rig,bone_ref("foot"))
        if stage==3 || stage==5 {
            testing.expect(t,!found && len(w.playback.states)==0)
        } else {
            testing.expect(t,found && linalg.length(pose.position-leg.target.position)<0.001)
            if stage==4 || stage==6 {testing.expect(t,w.playback.states[0].bound>bound);bound=w.playback.states[0].bound}
        }
    }
}

@(test)
preview_plays_the_clip_in_the_editor_and_returns_to_its_start_when_it_stops :: proc(t:^testing.T) {
    directory:=rig_directory("preview");defer rig_directory_remove(directory)
    _,mesh_id,clips_id,saved:=rig_assets(t,directory)
    if !saved {return}
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=directory})) {return}
    defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets,allocator=context.allocator}
    defer host.app_content_destroy(&app)
    w:Rig_World;core.entities_init(&w.entities);defer rig_world_destroy(&w)
    rig:=core.create(&w.entities)
    core.add(&w.transforms,rig,core.TRANSFORM_IDENTITY);core.add(&w.meshes,rig,{mesh=mesh_id})
    animation:=ANIMATION_DEFAULT;animation.asset=clips_id
    testing.expect(t,animation_play(&animation,"lift",fade=0,loop=false))
    core.add(&w.animations,rig,animation)
    rig_world_settle(&w)
    editor,preview:=core.Time{},core.Frame_Time{dt=0.25,alpha=1}
    upper:=mm.Quat(1)
    time :: proc(w:^Rig_World,rig:core.Entity) -> f32 {clip_time,_,_,_:=animation_progress(&w.playback,rig);return clip_time}
    for _ in 0..<2 {rig_world_advance(&w,&app,editor,preview)}
    testing.expect(t,time(&w,rig)==0 && w.playback.states[0].local[1].rotation==upper)
    core.get(&w.animations,rig).preview=true
    rig_world_advance(&w,&app,editor,preview);rig_world_advance(&w,&app,editor,preview)
    testing.expect(t,abs(time(&w,rig)-0.5)<0.0001)
    testing.expect(t,abs(mm.quat_angle(w.playback.states[0].local[1].rotation,upper)-mm.PI*0.25)<0.001)
    core.get(&w.animations,rig).preview=false
    rig_world_advance(&w,&app,editor,preview)
    testing.expect(t,time(&w,rig)==0 && mm.quat_angle(w.playback.states[0].local[1].rotation,upper)<0.0001)
    rig_world_advance(&w,&app,{dt=0.25,playing=true})
    testing.expect(t,abs(time(&w,rig)-0.25)<0.0001)
    testing.expect_value(t,w.problems.count,0)
}

// A Rig_World the game loop of the host runs: its fixed tick advances the rig.
@(private="file")
Rig_Frame_World :: struct {
    time:core.Time,
    frame_time:core.Frame_Time,
    rig:Rig_World,
}

@(private="file")
rig_frame_fixed :: proc(world,shared,editor,app:rawptr) {
    w:=cast(^Rig_Frame_World)world
    rig_world_advance(&w.rig,cast(^host.App)app,w.time,w.frame_time)
}

// The clip of an .anim that compresses in a job does not play while it compresses: a frame that
// found it pending is played again from a copy of the World the same, with the clip ready.
@(test)
frames_played_again_while_a_clip_compressed_progress_as_they_did :: proc(t:^testing.T) {
    directory:=rig_directory("replay");defer rig_directory_remove(directory)
    _,mesh_id,clips_id,saved:=rig_assets(t,directory)
    if !saved {return}
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=directory})) {return}
    defer host.assets_destroy(&assets)
    p,error:=platform.create({headless=true,fixed_dt=1.0/60,pacing=platform.Frame_Pacing{}})
    if !testing.expect_value(t,error,platform.Error.None) {return}
    defer platform.destroy(p)
    storages:=[2]core.Storage_Info{
        {name="Time",type=core.Time,info=type_info_of(core.Time),
            offset=offset_of(Rig_Frame_World,time)},
        {name="Frame_Time",type=core.Frame_Time,info=type_info_of(core.Frame_Time),
            offset=offset_of(Rig_Frame_World,frame_time)},
    }
    info:=core.World_Info{storages=storages[:]}
    info.loops[.Game][.Fixed]=rig_frame_fixed
    app:=host.App{assets=&assets,allocator=context.allocator,info=&info,platform=p}
    app.tick_dt,app.max_ticks=1.0/60,4
    if !testing.expect(t,jobs.system_init(&app.jobs,{threads=2})) {return}
    defer {host.app_content_destroy(&app);jobs.system_destroy(&app.jobs);delete(app.worlds)}
    // The World the run starts from, and the copy it is played again from.
    make_world :: proc(w:^Rig_Frame_World,mesh,clips:base.Asset_Id) -> core.Entity {
        w.frame_time=core.FRAME_TIME_DEFAULT
        core.entities_init(&w.rig.entities)
        rig:=core.create(&w.rig.entities)
        core.add(&w.rig.transforms,rig,core.TRANSFORM_IDENTITY)
        core.add(&w.rig.meshes,rig,{mesh=mesh})
        animation:=ANIMATION_DEFAULT;animation.asset=clips
        animation_play(&animation,"lift",fade=0,loop=false)
        core.add(&w.rig.animations,rig,animation)
        rig_world_settle(&w.rig)
        return rig
    }
    played,replayed:Rig_Frame_World
    rig:=make_world(&played,mesh_id,clips_id);defer rig_world_destroy(&played.rig)
    make_world(&replayed,mesh_id,clips_id);defer rig_world_destroy(&replayed.rig)
    time :: proc(w:^Rig_Frame_World,rig:core.Entity) -> f32 {
        clip_time,_,_,_:=animation_progress(&w.rig.playback,rig)
        return clip_time
    }

    records:[4]host.Frame_Record
    times:[len(records)]f32
    for &record,i in records {
        host.app_game_frame(&app,&played,dt=f64(app.tick_dt),record=&record)
        times[i]=time(&played,rig)
        // The compression ends and is taken between frames, as an API call takes it.
        if i>0 {continue}
        testing.expect(t,host.content_animation_pending(&app,clips_id))
        testing.expect(t,host.content_animation_wait(&app,clips_id)!=nil)
    }
    testing.expect(t,times[0]==0 && times[len(times)-1]>0,"the clip plays once it is ready")
    for &record,i in records {
        host.app_game_frame(&app,&replayed,replay=&record)
        testing.expect_value(t,time(&replayed,rig),times[i])
    }
    testing.expect_value(t,played.rig.problems.count+replayed.rig.problems.count,0)
}

@(test)
shared_profiles_accept_multiple_goals_at_the_origin_and_evaluate_without_stable_allocations :: proc(t:^testing.T) {
    directory:=rig_directory("profiles");defer rig_directory_remove(directory)
    defer os.remove(fmt.tprintf("%s/rig.pose",directory))
    skeleton,mesh,_,ok:=rig_assets(t,directory);if !ok {return}
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    ik:=IK_CONSTRAINT_DEFAULT;ik.root,ik.joint,ik.end=bone_ref("upper"),bone_ref("lower"),bone_ref("foot");ik.target=spatial_point({.5,0,0})
    look:=LOOK_CONSTRAINT_DEFAULT;look.bone=bone_ref("foot");look.target=spatial_point({0,0,1})
    profile:=Pose_Profile{ik={ik,ik},look={look}}
    id:=base.Asset_Id{0x533,0x999}
    if !testing.expect_value(t,pose_profile_save(fmt.tprintf("%s/rig.pose",directory),&types,id,profile),asset.Error.None) {return}
    app:host.App;app.allocator=context.allocator
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=directory})) {return};defer host.assets_destroy(&assets);app.assets=&assets
    w:Rig_World;core.entities_init(&w.entities);defer rig_world_destroy(&w)
    rig:=core.create(&w.entities)
    core.add(&w.transforms,rig,core.TRANSFORM_IDENTITY)
    core.add(&w.meshes,rig,{mesh=mesh});rig_world_settle(&w)
    configs:core.Table(Pose_Modifiers);defer core.table_destroy(&configs)
    attachments:core.Table(Bone_Attachment);defer core.table_destroy(&attachments)
    core.add(&configs,rig,{profile=id,weight=1,enabled=true});core.table_settle(&configs,&w.entities)
    cache:Pose_Assets;defer pose_assets_free(&cache)
    modifiers:Modifier_Runtime;defer modifier_runtime_free(&modifiers)
    requests:Modifier_Requests;defer delete(requests.queue.items);defer delete(requests.controls.items)
    step :: proc(w:^Rig_World,app:^host.App,configs:^core.Table(Pose_Modifiers),attachments:^core.Table(Bone_Attachment),cache:^Pose_Assets,modifiers:^Modifier_Runtime,requests:^Modifier_Requests) {
        progress:core.Table(Animation_Progress);defer core.table_destroy(&progress)
        animation_sample(core.read(&w.animations),&progress,core.read(configs),core.read(attachments),&w.transforms,core.read(&w.parents),{},core.read(&w.labels),core.read(&w.targets),core.read(&w.meshes),core.read(&w.skins),&w.requests,&w.events,requests,modifiers,&w.playback,cache,&w.cache,app,{dt=1.0/60,playing=true},{},&w.problems,nil,nil,nil,nil,nil,nil,nil,nil,nil,{},core.CLOCK_DEFAULT)
        animation_advance(core.read(configs),&w.transforms,core.read(&w.parents),core.read(&w.worlds),requests,modifiers,&w.playback,&w.constraints,&w.grounding,{},{},{dt=1.0/60,playing=true},&w.requests,{},&w.problems,nil,nil,{},{},core.CLOCK_DEFAULT)
    }
    modifier_goal(&requests,{rig=rig,kind=.Look,target=spatial_point({}),weight=1,enabled=true})
    modifier_goal(&requests,{rig=rig,kind=.IK,slot=1,target=spatial_point({.75,.2,0}),weight=1,enabled=true})
    step(&w,&app,&configs,&attachments,&cache,&modifiers,&requests)
    testing.expect_value(t,len(modifiers.ik.values),2)
    testing.expect_value(t,len(w.playback.states[0].local),4)
    testing.expect_value(t,modifiers.look.values[0].target.position,mm.Vec3{})
    testing.expect_value(t,modifiers.ik.values[1].target.position,mm.Vec3{.75,.2,0})
    testing.expect_value(t,w.problems.count,0)
    copy:Modifier_Runtime;core.value_copy(&copy,&modifiers,type_info_of(Modifier_Runtime));defer modifier_runtime_free(&copy)
    testing.expect(t,raw_data(copy.ik.values)!=raw_data(modifiers.ik.values) && raw_data(copy.goals)!=raw_data(modifiers.goals))
    before:=w.playback.binding_revision
    geometry:=w.constraints.revision
    version:=modifiers.ik.version
    modifier_goal(&requests,{rig=rig,kind=.IK,slot=1,target=spatial_point({.6,.2,0}),weight=1,enabled=true})
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    step(&w,&app,&configs,&attachments,&cache,&modifiers,&requests)
    context=saved
    testing.expect_value(t,w.playback.binding_revision,before)
    testing.expect_value(t,modifiers.ik.values[1].target.position,mm.Vec3{.6,.2,0})
    testing.expect(t,modifiers.ik.version>version)
    testing.expect_value(t,w.constraints.revision,geometry)
    modifier_control(&requests,{rig=rig,kind=.Look,weight=.25,enabled=true,fade=.1})
    modifier_control(&requests,{rig=rig,kind=.IK,slot=1,weight=1,enabled=false,fade=.1})
    saved=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    for _ in 0..<8 {step(&w,&app,&configs,&attachments,&cache,&modifiers,&requests)}
    context=saved
    testing.expect_value(t,modifiers.ik.values[0].weight,f32(1))
    testing.expect_value(t,modifiers.ik.values[1].weight,f32(0))
    testing.expect(t,!modifiers.ik.values[1].enabled)
    testing.expect_value(t,modifiers.look.values[0].weight,f32(.25))
    testing.expect_value(t,modifiers.look.values[0].target.position,mm.Vec3{})
    testing.expect_value(t,w.playback.binding_revision,before)
    testing.expect_value(t,w.constraints.revision,geometry)
    testing.expect_value(t,w.problems.count,0)
    testing.expect_value(t,w.playback.states[0].skeleton,skeleton)
    core.get(&configs,rig).weight=.5
    step(&w,&app,&configs,&attachments,&cache,&modifiers,&requests)
    testing.expect_value(t,modifiers.ik.values[1].weight,f32(0))
    testing.expect_value(t,modifiers.look.values[0].weight,f32(.125))
    core.remove(&configs,rig);core.table_settle(&configs,&w.entities)
    step(&w,&app,&configs,&attachments,&cache,&modifiers,&requests)
    testing.expect_value(t,len(modifiers.goals),0)
    testing.expect_value(t,len(modifiers.controls),0)
    testing.expect_value(t,len(modifiers.ik.values),0)
}

@(test)
live_retarget_profile_changes_compare_full_asset_ids_and_preserve_source_identity :: proc(t:^testing.T) {
    directory:=rig_directory("retarget-profiles");defer os.remove(directory)
    a,b:=base.Asset_Id{1,2},base.Asset_Id{2,1}
    path_a,path_b:=fmt.tprintf("%s/a.pose",directory),fmt.tprintf("%s/b.pose",directory)
    defer os.remove(path_a);defer os.remove(path_b)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    mapping:=RETARGET_MAPPING_DEFAULT;mapping.mode=.Paths
    testing.expect_value(t,pose_profile_save(path_a,&types,a,{retarget={mapping}}),asset.Error.None)
    mapping.translation=.Scaled
    testing.expect_value(t,pose_profile_save(path_b,&types,b,{retarget={mapping}}),asset.Error.None)
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=directory})) {return};defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets,allocator=context.allocator}
    entities:core.Entities;core.entities_init(&entities);defer core.entities_destroy(&entities)
    source,target:=core.create(&entities),core.create(&entities)
    animations:core.Table(Animation);defer core.table_destroy(&animations)
    configs:core.Table(Pose_Modifiers);defer core.table_destroy(&configs)
    attachments:core.Table(Bone_Attachment);defer core.table_destroy(&attachments)
    player:=ANIMATION_DEFAULT;player.source,player.retarget=source,a
    core.add(&animations,target,player);core.table_settle(&animations,&entities)
    playback:Playback;defer playback_free(&playback)
    profiles:Pose_Assets;defer pose_assets_free(&profiles)
    skeletons:Skeleton_Assets;defer skeleton_assets_free(&skeletons)
    modifiers:Modifier_Runtime;defer modifier_runtime_free(&modifiers)
    testing.expect(t,modifier_prepare(&modifiers,core.read(&configs),core.read(&animations),core.read(&attachments),&profiles,&skeletons,&playback,&app,nil))
    testing.expect_value(t,modifiers.retargets.values[0].translation,lib.Retarget_Translation.Reference)
    geometry:=modifiers.geometry
    core.get(&animations,target).retarget=b
    testing.expect(t,modifier_prepare(&modifiers,core.read(&configs),core.read(&animations),core.read(&attachments),&profiles,&skeletons,&playback,&app,nil))
    testing.expect_value(t,modifiers.geometry,geometry+1)
    testing.expect_value(t,modifiers.retargets.values[0].translation,lib.Retarget_Translation.Scaled)
    testing.expect_value(t,modifiers.sources[0].profile,b)
    testing.expect_value(t,modifiers.sources[0].source,source)
}

@(test)
final_world_poses_update_skin_and_sockets_in_the_same_tick_without_stable_allocations :: proc(t:^testing.T) {
    directory:=rig_directory("physical-poses");defer rig_directory_remove(directory)
    _,mesh_id,_,saved:=rig_assets(t,directory)
    if !saved {return}
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=directory})) {return}
    defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets,allocator=context.allocator}
    w:Rig_World;core.entities_init(&w.entities);defer rig_world_destroy(&w)
    rig,socket:=core.create(&w.entities),core.create(&w.entities)
    core.add(&w.transforms,rig,core.from_math(mm.TRANSFORM_IDENTITY))
    core.add(&w.transforms,socket,core.from_math(mm.TRANSFORM_IDENTITY))
    core.add(&w.meshes,rig,{mesh=mesh_id})
    binding:=BONE_BINDING_DEFAULT;binding.rig=rig;binding.bone=bone_ref("foot");binding.offset.position={0,0,.25}
    core.add(&w.sockets,socket,binding);core.table_settle(&w.sockets,&w.entities)
    rig_world_settle(&w);rig_world_advance(&w,&app,{dt=1.0/60,playing=true})
    upper,upper_ok:=animation_bone_bind(&w.playback,rig,bone_ref("upper"))
    foot,foot_ok:=animation_bone_bind(&w.playback,rig,bone_ref("foot"))
    testing.expect(t,upper_ok && foot_ok)
    for iteration in 0..<4 {
        a:=mm.Transform{{2+f32(iteration),3,0},mm.quat_axis_angle({0,0,1},.5),{1,1,1}}
        b:=mm.Transform{{4+f32(iteration),1,0},mm.quat_axis_angle({0,1,0},.25),{1,1,1}}
        animation_pose_final(&w.requests,foot,b)
        animation_pose_final(&w.requests,upper,a)
        failure:=Runtime_Allocation_Failure{owner=context.allocator,remaining=0};previous_context:=context;previous_allocator:=app.allocator
        if iteration>0 {context.allocator={runtime_failure_allocator,&failure};context.temp_allocator=context.allocator;app.allocator=context.allocator}
        rig_world_advance(&w,&app,{dt=1.0/60,playing=true})
        context=previous_context;app.allocator=previous_allocator;w.cache.allocator=previous_allocator
        if iteration>0 {testing.expect_value(t,failure.calls,0)}
        actual_a,ok_a:=animation_bone_transform(&w.playback,rig,bone_ref("upper"))
        actual_b,ok_b:=animation_bone_transform(&w.playback,rig,bone_ref("foot"))
        testing.expect(t,ok_a && ok_b && linalg.length(actual_a.position-a.position)<.001 && linalg.length(actual_b.position-b.position)<.001)
        placed,_:=core.get(core.read(&w.transforms),socket)
        expected:=mm.transform_compose(b,binding.offset)
        testing.expect(t,linalg.length(placed.position-expected.position)<.001)
        sampled:[4]mm.Transform
        count,revision,ok:=animation_sample_pose(&w.playback,rig,sampled[:])
        testing.expect(t,ok && count==4 && revision==upper.revision && linalg.length(sampled[foot.index].position-b.position)>1)
    }
    stale:=upper;stale.revision+=1
    animation_pose_final(&w.requests,stale,mm.TRANSFORM_IDENTITY)
    rig_world_advance(&w,&app,{dt=1.0/60,playing=true})
    stale_problem:=core.problem_find(&w.problems,rig,"animation.final_pose_binding")
    testing.expect(t,stale_problem!=nil && strings.contains(core.problem_text(stale_problem),"bind the bone again"),"a final pose through a stale handle is reported on its rig with the fix")
    animation_pose_final(&w.requests,rig,bone_ref("upper"),mm.Transform{})
    testing.expect_value(t,w.requests.final_poses.refused,1)
}

@(test)
partial_final_world_poses_blend_once_and_do_not_stretch_a_translated_chain :: proc(t:^testing.T) {
    directory:=rig_directory("partial-physical-poses");defer rig_directory_remove(directory)
    _,mesh_id,_,saved:=rig_assets(t,directory)
    if !saved {return}
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=directory})) {return}
    defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets,allocator=context.allocator}
    w:Rig_World;core.entities_init(&w.entities);defer rig_world_destroy(&w)
    rig:=core.create(&w.entities)
    core.add(&w.transforms,rig,core.from_math(mm.TRANSFORM_IDENTITY))
    core.add(&w.meshes,rig,{mesh=mesh_id})
    rig_world_settle(&w);rig_world_advance(&w,&app,{dt=1.0/60,playing=true})
    parent,parent_ok:=animation_bone_bind(&w.playback,rig,bone_ref("upper"))
    child,child_ok:=animation_bone_bind(&w.playback,rig,bone_ref("lower"))
    if !testing.expect(t,parent_ok && child_ok) {return}
    original_parent,_:=animation_bone_transform(&w.playback,rig,bone_ref("upper"))
    original_child,_:=animation_bone_transform(&w.playback,rig,bone_ref("lower"))
    target_parent,target_child:=original_parent,original_child
    target_parent.position+={10,0,0};target_child.position+={10,0,0}
    for reversed in ([2]bool{false,true}) {
        if reversed {
            animation_pose_final(&w.requests,child,target_child,.5)
            animation_pose_final(&w.requests,parent,target_parent,.5)
        } else {
            animation_pose_final(&w.requests,parent,target_parent,.5)
            animation_pose_final(&w.requests,child,target_child,.5)
        }
        rig_world_advance(&w,&app,{dt=1.0/60,playing=true})
        a,_:=animation_bone_transform(&w.playback,rig,bone_ref("upper"))
        b,_:=animation_bone_transform(&w.playback,rig,bone_ref("lower"))
        testing.expect(t,linalg.length(a.position-original_parent.position-{5,0,0})<.001)
        testing.expect(t,linalg.length(b.position-original_child.position-{5,0,0})<.001)
        testing.expect(t,abs(linalg.length(b.position-a.position)-linalg.length(original_child.position-original_parent.position))<.001)
    }
    target_child.position={999,999,999}
    animation_pose_final(&w.requests,parent,target_parent)
    animation_pose_final(&w.requests,child,target_child,0)
    rig_world_advance(&w,&app,{dt=1.0/60,playing=true})
    zero,_:=animation_bone_transform(&w.playback,rig,bone_ref("lower"))
    testing.expect(t,linalg.length(zero.position-original_child.position-{10,0,0})<.001)
    target_parent=original_parent;target_child=original_child
    turn:=mm.quat_axis_angle({0,0,1},.8)
    target_parent.rotation=turn*original_parent.rotation
    target_child.rotation=turn*original_child.rotation
    target_child.position=original_parent.position+mm.quat_rotate(turn,original_child.position-original_parent.position)
    animation_pose_final(&w.requests,child,target_child,.5)
    animation_pose_final(&w.requests,parent,target_parent,.5)
    rig_world_advance(&w,&app,{dt=1.0/60,playing=true})
    rotated,_:=animation_bone_transform(&w.playback,rig,bone_ref("lower"))
    expected:=mm.transform_interpolate(original_child,target_child,.5)
    testing.expect(t,linalg.length(rotated.position-expected.position)<.001 && mm.quat_angle(rotated.rotation,expected.rotation)<.001)
}

// A figure, a mesh bound to it and two clips: still moves the pelvis, raise
// turns both upper arms. With body, its .skeleton keeps what detection finds.
@(private="file")
figure_assets :: proc(t:^testing.T,directory:string,body:bool) -> (mesh,clips:base.Asset_Id,bones:[]asset.Skeleton_Bone,ok:bool) {
    Row :: struct {name:string,parent:i32,at:[3]f32}
    rows:=[?]Row{
        {"root",-1,{}},{"pelvis",0,{0,1,0}},{"spine_01",1,{0,1.2,0}},{"neck_01",2,{0,1.5,0}},{"head",3,{0,1.6,0}},
        {"clavicle_l",2,{.05,1.45,0}},{"upperarm_l",5,{.2,1.45,0}},{"lowerarm_l",6,{.45,1.45,-.02}},{"hand_l",7,{.7,1.45,0}},
        {"clavicle_r",2,{-.05,1.45,0}},{"upperarm_r",9,{-.2,1.45,0}},{"lowerarm_r",10,{-.45,1.45,-.02}},{"hand_r",11,{-.7,1.45,0}},
        {"thigh_l",1,{.1,.95,0}},{"calf_l",13,{.1,.5,.02}},{"foot_l",14,{.1,.08,0}},{"ball_l",15,{.1,.02,.12}},
        {"thigh_r",1,{-.1,.95,0}},{"calf_r",17,{-.1,.5,.02}},{"foot_r",18,{-.1,.08,0}},{"ball_r",19,{-.1,.02,.12}},
    }
    bones=make([]asset.Skeleton_Bone,len(rows),context.temp_allocator)
    for row,i in rows {
        bone:=&bones[i]
        base.text_set(bone.name[:],row.name)
        path:=row.name if row.parent<0 else fmt.tprintf("%s/%s",base.text_get(bones[row.parent].path[:]),row.name)
        base.text_set(bone.path[:],path);bone.target=base.name_hash(path)
        bone.parent=row.parent;bone.rotation=1;bone.scale={1,1,1}
        bone.translation=row.at-(rows[row.parent].at if row.parent>=0 else {})
    }
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    skeleton:=base.Asset_Id{0x534,0x224}
    mesh,clips={0x534,0x225},{0x534,0x226}
    desc:=asset.Skeleton_Desc{id=skeleton,bones=bones}
    found:asset.Skeleton_Body
    parts:[len(lib.Body_Part)]asset.Skeleton_Body_Part
    if body {
        map_,detected:=asset.skeleton_body_detect(bones,lib.body_map_empty())
        count,written:=asset.skeleton_body_rows(bones,map_,&found,&parts)
        if !testing.expect(t,detected && written) {return}
        desc.body,desc.body_parts=&found,parts[:count]
    }
    vertices:=[3]asset.Vertex{{position={-1,0,0},color=0xffffffff},{position={1,0,0},color=0xffffffff},{position={0,1,0},color=0xffffffff}}
    influences:[3]asset.Skin_Vertex
    for &influence in influences {influence.weights[0]=255}
    joints:=[1]asset.Rig_Joint{{node=0,inverse_bind=1}}
    still:=[2]lib.Keyframe{{time=0,value={0,1,0,0}},{time=1,value={0,1,0,0}}}
    turn:=[2]lib.Keyframe{{time=0,value=lib.quat_vec4(mm.quat_axis_angle({0,0,1},.5))},{time=1,value=lib.quat_vec4(mm.quat_axis_angle({0,0,1},.5))}}
    upper_l,upper_r:=base.text_get(bones[6].path[:]),base.text_get(bones[10].path[:])
    ok=testing.expect_value(t,asset.skeleton_save(fmt.tprintf("%s/rig.skeleton",directory),&types,desc),asset.Error.None) &&
       testing.expect_value(t,rig_mesh_save(fmt.tprintf("%s/rig.mesh",directory),&types,{id=mesh,skeleton=skeleton,joints=joints[:]},vertices[:],{0,1,2},influences[:]),asset.Error.None) &&
       testing.expect_value(t,asset.animation_save(fmt.tprintf("%s/rig.anim",directory),&types,{id=clips,clips={
           {name="still",tracks={{target="root/pelvis",property=.Position,keys=still[:]}}},
           {name="raise",tracks={{target=upper_l,property=.Rotation,keys=turn[:]},{target=upper_r,property=.Rotation,keys=turn[:]}}},
       }}),asset.Error.None)
    return
}

// The bone of the rig with this name: the skeleton's index plus the entity at 0.
@(private="file")
figure_bone :: proc(bones:[]asset.Skeleton_Bone,name:string) -> int {
    for &bone,i in bones {if base.text_get(bone.name[:])==name {return i+1}}
    return -1
}

@(test)
body_labels_name_the_parts_and_regions_the_skeleton_keeps :: proc(t:^testing.T) {
    directory:=rig_directory("body-labels");defer rig_directory_remove(directory)
    mesh_id,_,bones,saved:=figure_assets(t,directory,true);if !saved {return}
    assets:host.Assets;if !testing.expect(t,host.assets_init(&assets,{root=directory})) {return};defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets,allocator=context.allocator}
    w:Rig_World;core.entities_init(&w.entities);defer rig_world_destroy(&w)
    rig:=core.create(&w.entities)
    core.add(&w.transforms,rig,core.TRANSFORM_IDENTITY);core.add(&w.meshes,rig,{mesh=mesh_id});rig_world_settle(&w)
    rig_world_advance(&w,&app,{dt=1.0/60,playing=true})
    if !testing.expect_value(t,len(w.playback.states),1) {return}
    state:=&w.playback.states[0]
    hand,head,neck,spine,pelvis,thigh:=figure_bone(bones,"hand_l"),figure_bone(bones,"head"),figure_bone(bones,"neck_01"),figure_bone(bones,"spine_01"),figure_bone(bones,"pelvis"),figure_bone(bones,"thigh_l")
    // A part is one bone wherever one is named; a region is no bone.
    testing.expect_value(t,bone_resolve(state,bone_ref("@hand_l")),hand)
    testing.expect_value(t,bone_resolve(state,bone_ref("@knee_l")),figure_bone(bones,"calf_l"))
    testing.expect_value(t,bone_resolve(state,bone_ref("@head")),head)
    testing.expect_value(t,bone_resolve(state,bone_ref_part(.Foot_R)),figure_bone(bones,"foot_r"))
    testing.expect_value(t,bone_resolve(state,bone_ref("@upper_body")),-1)
    testing.expect_value(t,bone_resolve(state,bone_ref("@tail")),-1)
    testing.expect_value(t,bone_resolve(state,bone_ref("hand_l")),hand)
    // In a mask a region holds its bones, and wins over the part of its name.
    upper,found:=bone_select(state,base.name_hash("@upper_body"))
    testing.expect(t,found && upper.bone<0)
    testing.expect(t,bone_selected(state,upper,spine) && bone_selected(state,upper,head) && bone_selected(state,upper,figure_bone(bones,"hand_r")))
    testing.expect(t,!bone_selected(state,upper,pelvis) && !bone_selected(state,upper,thigh) && !bone_selected(state,upper,0))
    region,_:=bone_select(state,base.name_hash("@head"))
    testing.expect(t,region.bone<0 && bone_selected(state,region,neck) && !bone_selected(state,region,spine))
    branch,_:=bone_select(state,base.name_hash("@hand_l"))
    testing.expect(t,branch.bone==hand && bone_selected(state,branch,hand) && !bone_selected(state,branch,figure_bone(bones,"lowerarm_l")))
    _,unknown:=bone_select(state,base.name_hash("@tail"));testing.expect(t,!unknown)
    // A final pose asked for a part moves its bone.
    animation_pose_final(&w.requests,rig,bone_ref("@hand_l"),{position={2,3,4},rotation=1,scale={1,1,1}})
    rig_world_advance(&w,&app,{dt=1.0/60,playing=true})
    moved,posed:=animation_bone_transform(&w.playback,rig,bone_ref("@hand_l"))
    testing.expect(t,posed && linalg.length(moved.position-mm.Vec3{2,3,4})<0.001)
    testing.expect_value(t,w.problems.count,0)
}

@(test)
skeleton_bone_find_takes_a_path_a_unique_name_or_a_part_of_the_body :: proc(t:^testing.T) {
    directory:=rig_directory("body-find");defer rig_directory_remove(directory)
    _,_,bones,saved:=figure_assets(t,directory,false);if !saved {return}
    body,detected:=asset.skeleton_body_detect(bones,lib.body_map_empty());if !testing.expect(t,detected) {return}
    hand:=figure_bone(bones,"hand_l")-1
    testing.expect_value(t,skeleton_bone_find(bones,body,bone_ref(base.text_get(bones[hand].path[:]))),hand)
    testing.expect_value(t,skeleton_bone_find(bones,body,bone_ref("hand_l")),hand)
    testing.expect_value(t,skeleton_bone_find(bones,body,bone_ref("@hand_l")),hand)
    testing.expect_value(t,skeleton_bone_find(bones,body,bone_ref("@knee_r")),figure_bone(bones,"calf_r")-1)
    testing.expect_value(t,skeleton_bone_find(bones,lib.body_map_empty(),bone_ref("@hand_l")),-1)
    testing.expect_value(t,skeleton_bone_find(bones,body,bone_ref("@upper_body")),-1)
    testing.expect_value(t,skeleton_bone_find(bones,body,{}),-1)
}

@(test)
layers_play_over_a_region_of_the_body_without_stable_allocations :: proc(t:^testing.T) {
    directory:=rig_directory("body-layer");defer rig_directory_remove(directory)
    mesh_id,clips_id,bones,saved:=figure_assets(t,directory,true);if !saved {return}
    assets:host.Assets;if !testing.expect(t,host.assets_init(&assets,{root=directory})) {return};defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets,allocator=context.allocator}
    defer host.app_content_destroy(&app)
    w:Rig_World;core.entities_init(&w.entities);defer rig_world_destroy(&w)
    rig:=core.create(&w.entities)
    animation:=ANIMATION_DEFAULT;animation.asset=clips_id
    testing.expect(t,animation_play(&animation,"still",fade=0))
    testing.expect(t,animation_play(&animation,"raise",fade=0,layer=1,over="@arm_l"))
    core.add(&w.transforms,rig,core.TRANSFORM_IDENTITY);core.add(&w.meshes,rig,{mesh=mesh_id});core.add(&w.animations,rig,animation);rig_world_settle(&w)
    left,right:=figure_bone(bones,"upperarm_l"),figure_bone(bones,"upperarm_r")
    for iteration in 0..<3 {
        failure:=Runtime_Allocation_Failure{owner=context.allocator,remaining=0}
        previous_context:=context
        previous_allocator:=app.allocator
        if iteration>1 {context.allocator={runtime_failure_allocator,&failure};context.temp_allocator=context.allocator;app.allocator=context.allocator}
        rig_world_advance(&w,&app,{dt=1.0/60,playing=true})
        context=previous_context;app.allocator=previous_allocator;w.cache.allocator=previous_allocator
        if iteration>1 {testing.expect_value(t,failure.calls,0)}
        if !testing.expect_value(t,len(w.playback.states),1) {return}
        state:=&w.playback.states[0]
        testing.expect(t,abs(mm.quat_angle(state.local[left].rotation,state.rest[left].rotation)-.5)<0.001)
        testing.expect(t,mm.quat_angle(state.local[right].rotation,state.rest[right].rotation)<0.0001)
    }
    testing.expect_value(t,w.problems.count,0)
}

@(test)
body_labels_of_a_skeleton_without_body_say_how_to_give_it_one :: proc(t:^testing.T) {
    directory:=rig_directory("body-missing");defer rig_directory_remove(directory)
    mesh_id,_,bones,saved:=figure_assets(t,directory,false);if !saved {return}
    assets:host.Assets;if !testing.expect(t,host.assets_init(&assets,{root=directory})) {return};defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets,allocator=context.allocator}
    w:Rig_World;core.entities_init(&w.entities);defer rig_world_destroy(&w)
    rig:=core.create(&w.entities)
    core.add(&w.transforms,rig,core.TRANSFORM_IDENTITY);core.add(&w.meshes,rig,{mesh=mesh_id});rig_world_settle(&w)
    rig_world_advance(&w,&app,{dt=1.0/60,playing=true})
    if !testing.expect_value(t,len(w.playback.states),1) {return}
    state:=&w.playback.states[0]
    testing.expect_value(t,bone_resolve(state,bone_ref("@hand_l")),-1)
    testing.expect_value(t,bone_resolve(state,bone_ref("hand_l")),figure_bone(bones,"hand_l"))
    testing.expect(t,len(state.regions)==0 && state.body=={})
    animation_pose(&w.requests,rig,bone_ref("@hand_l"),core.to_math(core.TRANSFORM_IDENTITY))
    rig_world_advance(&w,&app,{dt=1.0/60,playing=true})
    problems:=core.problems_list(&w.problems)
    if !testing.expect_value(t,len(problems),1) {return}
    text:=base.text_get(problems[0].text[:])
    testing.expectf(t,base.text_get(problems[0].code[:])=="animation.pose_bone" && strings.contains(text,"'@hand_l'") && strings.contains(text,"skeleton.body.detect"),"%s",text)
}
