package anim

import "base:runtime"
import "core:fmt"
import "core:math/linalg"
import "core:os"
import "core:slice"
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

// What animation_advance reads and writes of the World, with the tables a test fills.
// The rows of the constraints go where the World holds them, in its Modifier_Runtime.
@(private)
@(test_world)
Rig_World :: struct {
    using world:Test_World,
    transforms:core.Table(core.Transform),
    parents:core.Table(core.Parent),
    labels:core.Table(core.Name),
    meshes:core.Table(erender.Mesh_Renderer),
    skins:core.Table(Pose_Source),
    animations:core.Table(Animation),
    targets:core.Table(Animation_Target),
    progress:core.Table(Animation_Progress),
    attachments:core.Table(Bone_Attachment),
    worlds:core.Table(core.World_Transform),
    time:core.Time,
    frame_time:core.Frame_Time,
    requests:Animation_Requests,
    events:Animation_Events,
    playback:Playback,
    constraints:Animation_Constraints,
    grounding:Grounding_Runtime,
    modifiers:Modifier_Runtime,
    actions:Action_Runtime,
    motion:Motion_Runtime,
    played:core.Table(Animation_Played),
    remotes:core.Table(core.Remote),
}

// A Rig_World with what the application holds for it. The World goes first:
// the loop of the host is given it.
@(private="file")
Rig_Test :: struct {
    using w:Rig_World,
    cache:Skeleton_Assets,
    characters:Character_Assets,
    sources:Source_Assets,
    problems:core.Problems,
}

@(private="file")
rig_test_init :: proc(t:^testing.T,f:^Rig_Test) -> bool {return test_world_init(t,&f.w)}

@(private="file")
rig_test_destroy :: proc(f:^Rig_Test) {
    test_world_destroy(&f.w)
    skeleton_assets_free(&f.cache);character_assets_free(&f.characters);source_assets_free(&f.sources)
}

@(private="file")
rig_test_settle :: proc(f:^Rig_Test) {
    test_world_settle(&f.w)
    core.table_settle(&f.modifiers.ik,&f.entities)
}

@(private="file")
rig_test_advance :: proc(f:^Rig_Test,app:^host.App,time:core.Time,frame:core.Frame_Time={}) {
    if app.assets!=nil {rigs_update(&f.playback,core.read(&f.meshes),core.read(&f.skins),app.assets)}
    animation_tick(core.read(&f.animations),&f.transforms,core.read(&f.parents),{},core.read(&f.labels),&f.requests,&f.events,core.read(&f.targets),&f.playback,app,time,frame,&f.cache,&f.problems,&f.characters,&f.actions,&f.motion,&f.sources,core.read(&f.remotes),&f.played,{},core.CLOCK_DEFAULT,ANIMATION_BUDGET_CONFIG_DEFAULT)
    m:=&f.modifiers
    inputs:=Constraint_Inputs{core.read(&m.ik),core.read(&m.look),core.read(&m.limits),core.read(&m.sockets),core.read(&f.worlds),0,&f.cache,&f.problems}
    ground_inputs:=Grounding_Inputs{core.read(&m.grounding),{},core.read(&f.transforms),core.read(&f.parents),0,&f.problems,{}}
    animation_finish(&f.playback,inputs,&f.constraints,&f.transforms,&f.parents,time.dt,&f.grounding,ground_inputs,final_poses=core.take(&f.requests.final_poses))
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

@(test)
skeleton_content_follows_a_skeleton_held_in_the_memory_of_the_registry :: proc(t:^testing.T) {
    directory:=base.test_folder(t,"held-skeleton")
    skeleton_id,_,_,saved:=rig_assets(t,directory);if !saved {return}
    assets:host.Assets;if !testing.expect(t,host.assets_init(&assets,{root=directory})) {return};defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets,allocator=context.allocator}
    skeletons:Skeleton_Assets;defer skeleton_assets_free(&skeletons)
    content:=skeleton_content(&skeletons,app.assets,app.allocator,skeleton_id)
    if !testing.expect(t,content!=nil && len(content.bones)==3) {return}
    path:=fmt.tprintf("%s/rig.skeleton",directory)
    disk,_:=os.read_entire_file(path,context.temp_allocator)
    bone:=asset.Skeleton_Bone{parent=-1,rotation=1,scale={1,1,1},target=base.name_hash("alone")}
    base.text_set(bone.path[:],"alone");base.text_set(bone.name[:],"alone")
    doc:asset.Document;defer asset.document_destroy(&doc)
    if !testing.expect_value(t,asset.skeleton_document(&doc,&assets.types,{id=skeleton_id,bones={bone}}),asset.Error.None) {return}
    bytes,error:=asset.document_bytes(&doc,context.temp_allocator);if !testing.expect_value(t,error,asset.Error.None) {return}
    // What an editor holds until its step is written: only the registry has it,
    // and only its revision tells.
    revision:=assets.revision
    testing.expect_value(t,asset.registry_memory_set(&assets.registry,"rig.skeleton",bytes),asset.Error.None)
    content=skeleton_content(&skeletons,app.assets,app.allocator,skeleton_id)
    testing.expect(t,content!=nil && len(content.bones)==1 && base.text_get(content.bones[0].name[:])=="alone")
    after,_:=os.read_entire_file(path,context.temp_allocator)
    testing.expect(t,assets.revision==revision && string(after)==string(disk))
    {dropped,_:=asset.registry_memory_drop(&assets.registry,"rig.skeleton");testing.expect(t,dropped)}
    content=skeleton_content(&skeletons,app.assets,app.allocator,skeleton_id)
    testing.expect(t,content!=nil && len(content.bones)==3)
}

@(test)
skeleton_discovery_preserves_logical_rigs_on_unrelated_changes_and_retries_allocation_failure :: proc(t:^testing.T) {
    directory:=base.test_folder(t,"rig-discovery")
    _,mesh_id,_,saved:=rig_assets(t,directory);if !saved {return}
    assets:host.Assets;if !testing.expect(t,host.assets_init(&assets,{root=directory})) {return};defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets,allocator=context.allocator}
    w:Rig_Test;if !rig_test_init(t,&w) {return};defer rig_test_destroy(&w)
    first,second,third:=core.create(&w.entities),core.create(&w.entities),core.create(&w.entities)
    core.add(&w.meshes,second,{mesh=mesh_id});core.add(&w.meshes,first,{mesh=mesh_id});rig_test_settle(&w)
    testing.expect(t,rigs_update(&w.playback,core.read(&w.meshes),core.read(&w.skins),app.assets))
    stamp:=w.playback.rigs_stamp;pointer:=raw_data(w.playback.rigs)
    testing.expect(t,rig_find(&w.playback,first)>=0 && rig_find(&w.playback,second)>=0 && rig_find(&w.playback,third)<0)
    assets.revision+=1;core.edit(&w.meshes,first).materials[0]={0xab,0xcd}
    saved_context:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    testing.expect(t,rigs_update(&w.playback,core.read(&w.meshes),core.read(&w.skins),app.assets))
    context=saved_context
    testing.expect(t,w.playback.rigs_stamp==stamp && raw_data(w.playback.rigs)==pointer)
    core.add(&w.meshes,third,{mesh=mesh_id});rig_test_settle(&w)
    inputs:=w.playback.rigs_seen
    context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    testing.expect(t,!rigs_update(&w.playback,&w.meshes,&w.skins,app.assets))
    context=saved_context
    testing.expect(t,w.playback.rigs_seen==inputs && w.playback.rigs_stamp==stamp && raw_data(w.playback.rigs)==pointer && len(w.playback.rigs)==2)
    testing.expect(t,rigs_update(&w.playback,&w.meshes,&w.skins,app.assets))
    testing.expect(t,w.playback.rigs_stamp==stamp+1 && len(w.playback.rigs)==3 && rig_find(&w.playback,third)>=0)
    testing.expect(t,rig_find(&w.playback,core.entity_make(core.entity_index(first),core.entity_generation(first)+1))<0)
}

@(test)
skeleton_without_clips_evaluates_named_ik_and_pose_requests_without_bone_entities_or_stable_allocations :: proc(t:^testing.T) {
    directory:=base.test_folder(t,"procedural-skeleton")
    _,mesh_id,_,saved:=rig_assets(t,directory)
    if !saved {return}
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=directory})) {return}
    defer host.assets_destroy(&assets)
    content:host.Content
    app:=host.App{assets=&assets,allocator=context.allocator,content=&content}
    w:Rig_Test;if !rig_test_init(t,&w) {return};defer rig_test_destroy(&w)
    rig,helper:=core.create(&w.entities),core.create(&w.entities)
    placed:=core.TRANSFORM_IDENTITY;placed.position.x=7
    core.add(&w.transforms,rig,placed);core.add(&w.meshes,rig,{mesh=mesh_id})
    leg:=IK_CONSTRAINT_DEFAULT;leg.rig=rig;leg.root=bone_ref("upper");leg.joint=bone_ref("lower");leg.end=bone_ref("foot")
    leg.target=spatial_point({7,0.2,0.2});leg.pole={7,1,2}
    core.add(&w.modifiers.ik,helper,leg)
    rig_test_settle(&w)
    for iteration in 0..<3 {
        failure:=Runtime_Allocation_Failure{owner=context.allocator,remaining=0}
        previous_context:=context
        previous_allocator:=app.allocator
        if iteration>0 {context.allocator={runtime_failure_allocator,&failure};context.temp_allocator=context.allocator;app.allocator=context.allocator}
        rig_test_advance(&w,&app,{dt=1.0/60,playing=true})
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
    core.edit(&w.modifiers.ik,helper).enabled=false
    authored:=mm.Transform{position={0,2,0},rotation=mm.quat_axis_angle({0,1,0},0.4),scale={1,1,1}}
    animation_pose(&w.requests,rig,bone_ref("upper"),authored)
    rig_test_advance(&w,&app,{dt=1.0/60,playing=true})
    testing.expect_value(t,state.local[1],authored)
    testing.expect_value(t,w.problems.count,0)
    bound:=state.bound
    core.edit(&w.modifiers.ik,helper).enabled=true
    // A skin follows the pose of another rig: its entity is no rig of its own.
    follower:=core.create(&w.entities)
    core.add(&w.transforms,follower,placed);core.add(&w.meshes,follower,{mesh=mesh_id});core.add(&w.skins,follower,{rig=rig})
    rig_test_settle(&w)
    rig_test_advance(&w,&app,{dt=1.0/60,playing=true})
    testing.expect(t,len(w.playback.rigs)==1 && w.playback.rigs[0].entity==rig && len(w.playback.states)==1)
    core.remove(&w.meshes,follower);core.remove(&w.skins,follower);core.remove(&w.transforms,follower)
    rig_test_settle(&w)
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
        rig_test_settle(&w)
        rig_test_advance(&w,&app,{dt=1.0/60,playing=true})
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
    directory:=base.test_folder(t,"preview")
    _,mesh_id,clips_id,saved:=rig_assets(t,directory)
    if !saved {return}
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=directory})) {return}
    defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets,allocator=context.allocator}
    defer host.app_content_destroy(&app)
    w:Rig_Test;if !rig_test_init(t,&w) {return};defer rig_test_destroy(&w)
    rig:=core.create(&w.entities)
    core.add(&w.transforms,rig,core.TRANSFORM_IDENTITY);core.add(&w.meshes,rig,{mesh=mesh_id})
    animation:=ANIMATION_DEFAULT;animation.asset=clips_id
    testing.expect(t,animation_clip(&animation,"lift",fade=0,loop=false))
    core.add(&w.animations,rig,animation)
    rig_test_settle(&w)
    editor,preview:=core.Time{},core.Frame_Time{dt=0.25,alpha=1}
    upper:=mm.Quat(1)
    time :: proc(w:^Rig_Test,rig:core.Entity) -> f32 {clip_time,_,_,_:=animation_progress(&w.playback,rig);return clip_time}
    for _ in 0..<2 {rig_test_advance(&w,&app,editor,preview)}
    testing.expect(t,time(&w,rig)==0 && w.playback.states[0].local[1].rotation==upper)
    core.edit(&w.animations,rig).preview=true
    rig_test_advance(&w,&app,editor,preview);rig_test_advance(&w,&app,editor,preview)
    testing.expect(t,abs(time(&w,rig)-0.5)<0.0001)
    testing.expect(t,abs(mm.quat_angle(w.playback.states[0].local[1].rotation,upper)-mm.PI*0.25)<0.001)
    core.edit(&w.animations,rig).preview=false
    rig_test_advance(&w,&app,editor,preview)
    testing.expect(t,time(&w,rig)==0 && mm.quat_angle(w.playback.states[0].local[1].rotation,upper)<0.0001)
    rig_test_advance(&w,&app,{dt=0.25,playing=true})
    testing.expect(t,abs(time(&w,rig)-0.25)<0.0001)
    testing.expect_value(t,w.problems.count,0)
}

// The fixed tick of the game loop of the host advances the rig of the Rig_Test it runs.
@(private="file")
rig_frame_fixed :: proc(world,shared,editor,app:rawptr) {
    f:=cast(^Rig_Test)world
    rig_test_advance(f,cast(^host.App)app,f.time,f.frame_time)
}

// The clip of an .anim that compresses in a job does not play while it compresses: a frame that
// found it pending is played again from a copy of the World the same, with the clip ready.
@(test)
frames_played_again_while_a_clip_compressed_progress_as_they_did :: proc(t:^testing.T) {
    directory:=base.test_folder(t,"replay")
    _,mesh_id,clips_id,saved:=rig_assets(t,directory)
    if !saved {return}
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=directory})) {return}
    defer host.assets_destroy(&assets)
    p,error:=platform.create({headless=true,fixed_dt=1.0/60,pacing=platform.Frame_Pacing{}})
    if !testing.expect_value(t,error,platform.Error.None) {return}
    defer platform.destroy(p)
    info,described:=test_info(t,Rig_World)
    if !described {return}
    defer test_info_destroy(&info)
    info.loops[.Game][.Fixed]=rig_frame_fixed
    app:=host.App{assets=&assets,allocator=context.allocator,info=&info,platform=p}
    app.tick_dt,app.max_ticks=1.0/60,4
    if !testing.expect(t,jobs.system_init(&app.jobs,{threads=2})) {return}
    defer {host.app_content_destroy(&app);jobs.system_destroy(&app.jobs);delete(app.worlds)}
    // The World the run starts from, and the copy it is played again from.
    make_world :: proc(t:^testing.T,w:^Rig_Test,mesh,clips:base.Asset_Id) -> (rig:core.Entity,ok:bool) {
        if !rig_test_init(t,w) {return}
        rig=core.create(&w.entities)
        core.add(&w.transforms,rig,core.TRANSFORM_IDENTITY)
        core.add(&w.meshes,rig,{mesh=mesh})
        animation:=ANIMATION_DEFAULT;animation.asset=clips
        animation_clip(&animation,"lift",fade=0,loop=false)
        core.add(&w.animations,rig,animation)
        rig_test_settle(w)
        return rig,true
    }
    played,replayed:Rig_Test
    rig,made:=make_world(t,&played,mesh_id,clips_id);defer rig_test_destroy(&played)
    _,remade:=make_world(t,&replayed,mesh_id,clips_id);defer rig_test_destroy(&replayed)
    if !made || !remade {return}
    time :: proc(w:^Rig_Test,rig:core.Entity) -> f32 {
        clip_time,_,_,_:=animation_progress(&w.playback,rig)
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
    testing.expect_value(t,played.problems.count+replayed.problems.count,0)
}

@(test)
shared_profiles_accept_multiple_goals_at_the_origin_and_evaluate_without_stable_allocations :: proc(t:^testing.T) {
    directory:=base.test_folder(t,"profiles")
    skeleton,mesh,_,ok:=rig_assets(t,directory);if !ok {return}
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    ik:=IK_CONSTRAINT_DEFAULT;ik.root,ik.joint,ik.end=bone_ref("upper"),bone_ref("lower"),bone_ref("foot");ik.target=spatial_point({.5,0,0})
    look:=LOOK_CONSTRAINT_DEFAULT;look.bone=bone_ref("foot");look.target=spatial_point({0,0,1})
    id:=base.Asset_Id{0x533,0x999}
    if !test_character_save(t,directory,"rig",&types,id,{pose={ik={ik,ik},look={look}}}) {return}
    app:host.App;app.allocator=context.allocator
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=directory})) {return};defer host.assets_destroy(&assets);app.assets=&assets
    w:Rig_Test;if !rig_test_init(t,&w) {return};defer rig_test_destroy(&w)
    rig:=core.create(&w.entities)
    core.add(&w.transforms,rig,core.TRANSFORM_IDENTITY)
    core.add(&w.meshes,rig,{mesh=mesh});rig_test_settle(&w)
    // A set without clips: its modifiers alone.
    player:=ANIMATION_DEFAULT;player.asset=id;core.add(&w.animations,rig,player);rig_test_settle(&w)
    cache:=&w.characters
    step :: proc(w:^Rig_Test,app:^host.App,cache:^Character_Assets) {
        animation_sample(core.read(&w.animations),&w.progress,&w.played,core.read(&w.attachments),&w.transforms,core.read(&w.parents),{},core.read(&w.labels),core.read(&w.targets),core.read(&w.meshes),core.read(&w.skins),core.read(&w.remotes),&w.requests,&w.events,&w.modifiers,&w.playback,cache,&w.cache,app,{dt=1.0/60,playing=true},{},&w.problems,&w.actions,&w.motion,&w.sources,{},core.CLOCK_DEFAULT,ANIMATION_BUDGET_CONFIG_DEFAULT)
        animation_advance(&w.transforms,core.read(&w.parents),core.read(&w.worlds),&w.requests,&w.modifiers,&w.playback,&w.constraints,&w.grounding,{},{},{dt=1.0/60,playing=true},{},&w.problems,&w.motion,cache,{},{},core.CLOCK_DEFAULT,nil)
    }
    modifier_goal(&w.requests,{rig=rig,kind=.Look,target=spatial_point({}),weight=1,enabled=true})
    modifier_goal(&w.requests,{rig=rig,kind=.IK,slot=1,target=spatial_point({.75,.2,0}),weight=1,enabled=true})
    step(&w,&app,cache)
    testing.expect_value(t,len(w.modifiers.ik.values),2)
    testing.expect_value(t,len(w.playback.states[0].local),4)
    testing.expect_value(t,w.modifiers.look.values[0].target.position,mm.Vec3{})
    testing.expect_value(t,w.modifiers.ik.values[1].target.position,mm.Vec3{.75,.2,0})
    testing.expect_value(t,w.problems.count,0)
    copy:Modifier_Runtime;core.value_copy(&copy,&w.modifiers,type_info_of(Modifier_Runtime));defer modifier_runtime_free(&copy)
    testing.expect(t,raw_data(copy.ik.values)!=raw_data(w.modifiers.ik.values) && raw_data(copy.goals)!=raw_data(w.modifiers.goals))
    before:=w.playback.binding_revision
    geometry:=w.constraints.revision
    version:=w.modifiers.ik.version
    modifier_goal(&w.requests,{rig=rig,kind=.IK,slot=1,target=spatial_point({.6,.2,0}),weight=1,enabled=true})
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    step(&w,&app,cache)
    context=saved
    testing.expect_value(t,w.playback.binding_revision,before)
    testing.expect_value(t,w.modifiers.ik.values[1].target.position,mm.Vec3{.6,.2,0})
    testing.expect(t,w.modifiers.ik.version>version)
    testing.expect_value(t,w.constraints.revision,geometry)
    modifier_control(&w.requests,{rig=rig,kind=.Look,weight=.25,enabled=true,fade=.1})
    modifier_control(&w.requests,{rig=rig,kind=.IK,slot=1,weight=1,enabled=false,fade=.1})
    saved=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    for _ in 0..<8 {step(&w,&app,cache)}
    context=saved
    testing.expect_value(t,w.modifiers.ik.values[0].weight,f32(1))
    testing.expect_value(t,w.modifiers.ik.values[1].weight,f32(0))
    testing.expect(t,!w.modifiers.ik.values[1].enabled)
    testing.expect_value(t,w.modifiers.look.values[0].weight,f32(.25))
    testing.expect_value(t,w.modifiers.look.values[0].target.position,mm.Vec3{})
    testing.expect_value(t,w.playback.binding_revision,before)
    testing.expect_value(t,w.constraints.revision,geometry)
    testing.expect_value(t,w.problems.count,0)
    testing.expect_value(t,w.playback.states[0].skeleton,skeleton)
    core.remove(&w.animations,rig);rig_test_settle(&w)
    step(&w,&app,cache)
    testing.expect_value(t,len(w.modifiers.goals),0)
    testing.expect_value(t,len(w.modifiers.controls),0)
    testing.expect_value(t,len(w.modifiers.ik.values),0)
}

@(test)
final_world_poses_update_skin_and_sockets_in_the_same_tick_without_stable_allocations :: proc(t:^testing.T) {
    directory:=base.test_folder(t,"physical-poses")
    _,mesh_id,_,saved:=rig_assets(t,directory)
    if !saved {return}
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=directory})) {return}
    defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets,allocator=context.allocator}
    w:Rig_Test;if !rig_test_init(t,&w) {return};defer rig_test_destroy(&w)
    rig,socket:=core.create(&w.entities),core.create(&w.entities)
    core.add(&w.transforms,rig,core.from_math(mm.TRANSFORM_IDENTITY))
    core.add(&w.transforms,socket,core.from_math(mm.TRANSFORM_IDENTITY))
    core.add(&w.meshes,rig,{mesh=mesh_id})
    binding:=BONE_BINDING_DEFAULT;binding.rig=rig;binding.bone=bone_ref("foot");binding.offset.position={0,0,.25}
    core.add(&w.modifiers.sockets,socket,binding);core.table_settle(&w.modifiers.sockets,&w.entities)
    rig_test_settle(&w);rig_test_advance(&w,&app,{dt=1.0/60,playing=true})
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
        rig_test_advance(&w,&app,{dt=1.0/60,playing=true})
        context=previous_context;app.allocator=previous_allocator;w.cache.allocator=previous_allocator
        if iteration>0 {testing.expect_value(t,failure.calls,0)}
        actual_a,ok_a:=animation_bone_transform(&w.playback,rig,bone_ref("upper"))
        actual_b,ok_b:=animation_bone_transform(&w.playback,rig,bone_ref("foot"))
        testing.expect(t,ok_a && ok_b && linalg.length(actual_a.position-a.position)<.001 && linalg.length(actual_b.position-b.position)<.001)
        placed,_:=core.get(&w.transforms,socket)
        expected:=mm.transform_compose(b,binding.offset)
        testing.expect(t,linalg.length(placed.position-expected.position)<.001)
        sampled:[4]mm.Transform
        count,revision,ok:=animation_sample_pose(&w.playback,rig,sampled[:])
        testing.expect(t,ok && count==4 && revision==upper.revision && linalg.length(sampled[foot.index].position-b.position)>1)
    }
    stale:=upper;stale.revision+=1
    animation_pose_final(&w.requests,stale,mm.TRANSFORM_IDENTITY)
    rig_test_advance(&w,&app,{dt=1.0/60,playing=true})
    stale_problem:=core.problem_find(&w.problems,rig,"animation.final_pose_binding")
    testing.expect(t,stale_problem!=nil && strings.contains(core.problem_text(stale_problem),"bind the bone again"),"a final pose through a stale handle is reported on its rig with the fix")
    animation_pose_final(&w.requests,rig,bone_ref("upper"),mm.Transform{})
    testing.expect_value(t,w.requests.final_poses.refused,1)
}

@(test)
partial_final_world_poses_blend_once_and_do_not_stretch_a_translated_chain :: proc(t:^testing.T) {
    directory:=base.test_folder(t,"partial-physical-poses")
    _,mesh_id,_,saved:=rig_assets(t,directory)
    if !saved {return}
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=directory})) {return}
    defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets,allocator=context.allocator}
    w:Rig_Test;if !rig_test_init(t,&w) {return};defer rig_test_destroy(&w)
    rig:=core.create(&w.entities)
    core.add(&w.transforms,rig,core.from_math(mm.TRANSFORM_IDENTITY))
    core.add(&w.meshes,rig,{mesh=mesh_id})
    rig_test_settle(&w);rig_test_advance(&w,&app,{dt=1.0/60,playing=true})
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
        rig_test_advance(&w,&app,{dt=1.0/60,playing=true})
        a,_:=animation_bone_transform(&w.playback,rig,bone_ref("upper"))
        b,_:=animation_bone_transform(&w.playback,rig,bone_ref("lower"))
        testing.expect(t,linalg.length(a.position-original_parent.position-{5,0,0})<.001)
        testing.expect(t,linalg.length(b.position-original_child.position-{5,0,0})<.001)
        testing.expect(t,abs(linalg.length(b.position-a.position)-linalg.length(original_child.position-original_parent.position))<.001)
    }
    target_child.position={999,999,999}
    animation_pose_final(&w.requests,parent,target_parent)
    animation_pose_final(&w.requests,child,target_child,0)
    rig_test_advance(&w,&app,{dt=1.0/60,playing=true})
    zero,_:=animation_bone_transform(&w.playback,rig,bone_ref("lower"))
    testing.expect(t,linalg.length(zero.position-original_child.position-{10,0,0})<.001)
    target_parent=original_parent;target_child=original_child
    turn:=mm.quat_axis_angle({0,0,1},.8)
    target_parent.rotation=turn*original_parent.rotation
    target_child.rotation=turn*original_child.rotation
    target_child.position=original_parent.position+mm.quat_rotate(turn,original_child.position-original_parent.position)
    animation_pose_final(&w.requests,child,target_child,.5)
    animation_pose_final(&w.requests,parent,target_parent,.5)
    rig_test_advance(&w,&app,{dt=1.0/60,playing=true})
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
    directory:=base.test_folder(t,"body-labels")
    mesh_id,_,bones,saved:=figure_assets(t,directory,true);if !saved {return}
    assets:host.Assets;if !testing.expect(t,host.assets_init(&assets,{root=directory})) {return};defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets,allocator=context.allocator}
    w:Rig_Test;if !rig_test_init(t,&w) {return};defer rig_test_destroy(&w)
    rig:=core.create(&w.entities)
    core.add(&w.transforms,rig,core.TRANSFORM_IDENTITY);core.add(&w.meshes,rig,{mesh=mesh_id});rig_test_settle(&w)
    rig_test_advance(&w,&app,{dt=1.0/60,playing=true})
    if !testing.expect_value(t,len(w.playback.states),1) {return}
    state:=&w.playback.states[0]
    hand,head:=figure_bone(bones,"hand_l"),figure_bone(bones,"head")
    // A part is one bone wherever one is named; a region is no bone.
    testing.expect_value(t,bone_resolve(state,bone_ref("@hand_l")),hand)
    testing.expect_value(t,bone_resolve(state,bone_ref("@knee_l")),figure_bone(bones,"calf_l"))
    testing.expect_value(t,bone_resolve(state,bone_ref("@head")),head)
    testing.expect_value(t,bone_resolve(state,bone_ref_part(.Foot_R)),figure_bone(bones,"foot_r"))
    testing.expect_value(t,bone_resolve(state,bone_ref("@upper_body")),-1)
    testing.expect_value(t,bone_resolve(state,bone_ref("@tail")),-1)
    testing.expect_value(t,bone_resolve(state,bone_ref("hand_l")),hand)
    // In a mask a region holds its bones, and wins over the part of its name; a depth fades it in
    // from where it starts, and several branches take the most each gives.
    Mask_Case :: struct {name:string,over:Layer_Over,shares:[]struct {bone:string,share:f32}}
    mask_cases:=[]Mask_Case{
        {"a region",{0={base.name_hash("@upper_body"),0}},{{"spine_01",1},{"head",1},{"hand_r",1},{"pelvis",0},{"thigh_l",0},{"root",0}}},
        {"a region over a depth",{0={base.name_hash("@upper_body"),3}},{{"spine_01",1.0/3},{"neck_01",2.0/3},{"clavicle_l",2.0/3},{"head",1},{"upperarm_l",1},{"pelvis",0}}},
        {"a region that wins over its part",{0={base.name_hash("@head"),0}},{{"neck_01",1},{"spine_01",0}}},
        {"a part over a depth",{0={base.name_hash("@shoulder_l"),2}},{{"upperarm_l",.5},{"lowerarm_l",1},{"hand_l",1},{"clavicle_l",0}}},
        {"two branches",{0={base.name_hash("@hand_l"),0},1={base.name_hash("@arm_r"),4}},{{"hand_l",1},{"lowerarm_l",0},{"clavicle_r",.25},{"hand_r",1},{"head",0}}},
        {"the whole pose",{},{{"root",1},{"pelvis",1},{"hand_l",1}}},
    }
    weights:=make([]f32,len(state.bindings),context.temp_allocator)
    for c in mask_cases {
        testing.expectf(t,layer_mask(state,c.over,weights),"%s: the rig has it",c.name)
        for want in c.shares {
            bone:=figure_bone(bones,want.bone) if want.bone!="root" else 0
            testing.expectf(t,abs(weights[bone]-want.share)<1e-6,"%s: %s takes %v of the layer, not %v",c.name,want.bone,weights[bone],want.share)
        }
    }
    testing.expect(t,!layer_mask(state,{0={base.name_hash("@tail"),0}},weights) && weights[hand]==0,"a branch the rig does not have moves nothing")
    // A final pose asked for a part moves its bone.
    animation_pose_final(&w.requests,rig,bone_ref("@hand_l"),{position={2,3,4},rotation=1,scale={1,1,1}})
    rig_test_advance(&w,&app,{dt=1.0/60,playing=true})
    moved,posed:=animation_bone_transform(&w.playback,rig,bone_ref("@hand_l"))
    testing.expect(t,posed && linalg.length(moved.position-mm.Vec3{2,3,4})<0.001)
    testing.expect_value(t,w.problems.count,0)
}

@(test)
skeleton_bone_find_takes_a_path_a_unique_name_or_a_part_of_the_body :: proc(t:^testing.T) {
    directory:=base.test_folder(t,"body-find")
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
    directory:=base.test_folder(t,"body-layer")
    mesh_id,clips_id,bones,saved:=figure_assets(t,directory,true);if !saved {return}
    set:=base.Asset_Id{0x5e7,0x1}
    {
        types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
        if !test_action_set_save(t,directory,"figure",&types,set,clips_id,{test_stack_layer("raise",over="@arm_l")}) {return}
    }
    assets:host.Assets;if !testing.expect(t,host.assets_init(&assets,{root=directory})) {return};defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets,allocator=context.allocator}
    defer host.app_content_destroy(&app)
    w:Rig_Test;if !rig_test_init(t,&w) {return};defer rig_test_destroy(&w)
    rig:=core.create(&w.entities)
    animation:=ANIMATION_DEFAULT;animation.asset=set
    testing.expect(t,animation_clip(&animation,"still",fade=0))
    core.add(&w.transforms,rig,core.TRANSFORM_IDENTITY);core.add(&w.meshes,rig,{mesh=mesh_id});core.add(&w.animations,rig,animation);rig_test_settle(&w)
    left,right:=figure_bone(bones,"upperarm_l"),figure_bone(bones,"upperarm_r")
    for iteration in 0..<3 {
        failure:=Runtime_Allocation_Failure{owner=context.allocator,remaining=0}
        previous_context:=context
        previous_allocator:=app.allocator
        if iteration>1 {context.allocator={runtime_failure_allocator,&failure};context.temp_allocator=context.allocator;app.allocator=context.allocator}
        rig_test_advance(&w,&app,{dt=1.0/60,playing=true})
        context=previous_context;app.allocator=previous_allocator;w.cache.allocator,w.characters.allocator,w.actions.allocator=previous_allocator,previous_allocator,previous_allocator
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
    directory:=base.test_folder(t,"body-missing")
    mesh_id,_,bones,saved:=figure_assets(t,directory,false);if !saved {return}
    assets:host.Assets;if !testing.expect(t,host.assets_init(&assets,{root=directory})) {return};defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets,allocator=context.allocator}
    w:Rig_Test;if !rig_test_init(t,&w) {return};defer rig_test_destroy(&w)
    rig:=core.create(&w.entities)
    core.add(&w.transforms,rig,core.TRANSFORM_IDENTITY);core.add(&w.meshes,rig,{mesh=mesh_id});rig_test_settle(&w)
    rig_test_advance(&w,&app,{dt=1.0/60,playing=true})
    if !testing.expect_value(t,len(w.playback.states),1) {return}
    state:=&w.playback.states[0]
    testing.expect_value(t,bone_resolve(state,bone_ref("@hand_l")),-1)
    testing.expect_value(t,bone_resolve(state,bone_ref("hand_l")),figure_bone(bones,"hand_l"))
    testing.expect(t,len(state.regions)==0 && state.body=={})
    animation_pose(&w.requests,rig,bone_ref("@hand_l"),core.to_math(core.TRANSFORM_IDENTITY))
    rig_test_advance(&w,&app,{dt=1.0/60,playing=true})
    problems:=core.problems_list(&w.problems)
    if !testing.expect_value(t,len(problems),1) {return}
    text:=base.text_get(problems[0].text[:])
    testing.expectf(t,base.text_get(problems[0].code[:])=="animation.pose_bone" && strings.contains(text,"'@hand_l'") && strings.contains(text,"skeleton.body.detect"),"%s",text)
}

// Rigs under cross-fades and layers, posed on the owner thread and in jobs of one rig and of five:
// each takes the same pose, and a tick whose rigs are bound takes no memory.
@(test)
rig_poses_do_not_depend_on_how_their_jobs_are_split :: proc(t:^testing.T) {
    RIGS :: 17
    directory:=base.test_folder(t,"pose-jobs")
    _,mesh_id,_,saved:=rig_assets(t,directory)
    if !saved {return}
    moves:=base.Asset_Id{0x533,0x227}
    sets:=[3]base.Asset_Id{{0x5e7,1},{0x5e7,2},{0x5e7,3}}
    {
        types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
        turns:[4][2]lib.Keyframe
        for &keys,i in turns {keys={{time=0,value=lib.quat_vec4(1)},{time=1,value=lib.quat_vec4(mm.quat_axis_angle(linalg.normalize(mm.Vec3{1,f32(i),.5}),.4+f32(i)*.3))}}}
        slides:=[2][2]lib.Keyframe{{{time=0,value={0,-1,0,0}},{time=1,value={.5,-1,.25,0}}},{{time=0,value={0,2,0,0}},{time=1,value={-.25,2.5,0,0}}}}
        clips:=[?]asset.Animation_Clip_Desc{
            {name="lift",tracks={{target="upper",property=.Rotation,keys=turns[0][:]},{target="upper/lower",property=.Rotation,keys=turns[1][:]}}},
            {name="kick",tracks={{target="upper/lower/foot",property=.Rotation,keys=turns[2][:]},{target="upper/lower",property=.Position,keys=slides[0][:]}}},
            {name="sway",tracks={{target="upper",property=.Position,keys=slides[1][:]},{target="upper/lower/foot",property=.Rotation,keys=turns[3][:]},{target="upper",property=.Rotation,keys=turns[2][:]}}},
        }
        if !testing.expect_value(t,asset.animation_save(fmt.tprintf("%s/moves.anim",directory),&types,{id=moves,clips=clips[:]}),asset.Error.None) {return}
        // The layers a rig has: a kick over its lower bone, a sway added over the lift, or both.
        kick:=test_stack_layer("kick",over="lower",weight=.6)
        sway:=test_stack_layer("sway",weight=.5,mode=.Additive,reference=.25,reference_clip="lift")
        if !test_action_set_save(t,directory,"kick",&types,sets[0],moves,{kick}) || !test_action_set_save(t,directory,"sway",&types,sets[1],moves,{sway}) || !test_action_set_save(t,directory,"both",&types,sets[2],moves,{kick,sway}) {return}
    }
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=directory})) {return}
    defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets,allocator=context.allocator}
    if !testing.expect(t,jobs.system_init(&app.jobs,{threads=3})) {return}
    defer {host.app_content_destroy(&app);jobs.system_destroy(&app.jobs)}
    if !testing.expect(t,host.content_animation_wait(&app,moves)!=nil) {return}

    names:=[3]string{"lift","kick","sway"}
    budgets:=[3]Animation_Budget_Config{{job_grain=4},{job_grain=1,parallel=true},{job_grain=5,parallel=true}}
    worlds:[3]Rig_Test;made:[3]bool
    defer for &w,i in worlds {if made[i] {rig_test_destroy(&w)}}
    rigs:[RIGS]core.Entity
    for &w,k in worlds {
        if made[k]=rig_test_init(t,&w);!made[k] {return}
        for i in 0..<RIGS {
            rig:=core.create(&w.entities);rigs[i]=rig
            core.add(&w.transforms,rig,core.TRANSFORM_IDENTITY)
            core.add(&w.meshes,rig,{mesh=mesh_id})
            animation:=ANIMATION_DEFAULT;animation.asset=moves;animation.weight=1-f32(i%4)*.2
            animation_clip(&animation,names[i%3],fade=.1);animation.speed=.5+f32(i)*.2
            if i%2==0 && i%5!=0 {animation.asset=sets[2]} else if i%2==0 {animation.asset=sets[0]} else if i%5!=0 {animation.asset=sets[1]}
            core.add(&w.animations,rig,animation)
        }
        rig_test_settle(&w)
    }
    step :: proc(w:^Rig_Test,app:^host.App,budget:Animation_Budget_Config) {
        animation_sample(core.read(&w.animations),&w.progress,&w.played,core.read(&w.attachments),&w.transforms,core.read(&w.parents),{},core.read(&w.labels),core.read(&w.targets),core.read(&w.meshes),core.read(&w.skins),core.read(&w.remotes),&w.requests,&w.events,&w.modifiers,&w.playback,&w.characters,&w.cache,app,{dt=1.0/60,playing=true},{},&w.problems,&w.actions,&w.motion,&w.sources,{},core.CLOCK_DEFAULT,budget)
        animation_advance(&w.transforms,core.read(&w.parents),core.read(&w.worlds),&w.requests,&w.modifiers,&w.playback,&w.constraints,&w.grounding,{},{},{dt=1.0/60,playing=true},{},&w.problems,&w.motion,&w.characters,{},{},core.CLOCK_DEFAULT,nil)
    }
    same,moved:=true,false
    for tick in 0..<10 {
        saved:=context
        // The clip of some changes at the fourth tick, so they cross-fade; the last ticks are stable.
        if tick==4 {for &w in worlds {for rig,i in rigs {if i%4==1 {animation_clip(core.edit(&w.animations,rig),names[(i+1)%3],fade=.1)}}}}
        if tick>=8 {context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()}
        for &w,k in worlds {step(&w,&app,budgets[k])}
        context=saved
        for rig in rigs {
            owner:=constraint_playing(&worlds[0].playback,rig)
            if !testing.expect(t,owner!=nil && len(owner.sampled)==4) {return}
            moved||=owner.sampled[2]!=owner.rest[2]
            for &w in worlds[1:] {
                other:=constraint_playing(&w.playback,rig)
                same&&=other!=nil && slice.equal(other.sampled[:],owner.sampled[:]) && slice.equal(other.local[:],owner.local[:]) && other.motion==owner.motion
            }
        }
    }
    testing.expect(t,same && moved,"a rig posed in a job takes the pose it takes on the owner thread")
    testing.expect(t,len(worlds[0].playback.scratch)==1 && len(worlds[1].playback.scratch)==jobs.worker_count(&app.jobs) && len(worlds[0].playback.track_maps)==1,"the rigs of one skeleton and content share one map, and only jobs take scratch of their own")
    for &w in worlds {testing.expect_value(t,w.problems.count,0)}
}
