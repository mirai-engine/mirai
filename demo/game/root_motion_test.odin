package game

import inp "mirai:engine/input"
import "core:testing"
import "core:math/linalg"
import "mirai:asset"
import "mirai:core"
import locomotion "plugins:locomotion/runtime"
import phys "plugins:physics/runtime"
import render "mirai:engine/render"
import "mirai:host"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"
import anim "plugins:animation/runtime"
import animation_physics "plugins:animation_physics/runtime"

// The body of Mirai: the first mesh of the import of characters/mirai/mirai.glb, by the id its
// package keeps. The demo lists it from its packages in the machine store.
@(private)
MIRAI_BODY :: "f0c947702bb8141dc1d27444a341d52c"

// The asset of a character and that of the body of Mirai, which a test of the demo plays it on.
@(private)
mirai_assets :: proc(t:^testing.T,assets:^host.Assets,character:string,loc:=#caller_location) -> (ids:[2]base.Asset_Id,ok:bool) {
    record,present:=asset.registry_find_path(&assets.registry,character)
    if !testing.expectf(t,present,"the demo has %s",character,loc=loc) {return}
    body,_:=base.asset_id_parse(MIRAI_BODY)
    _,built:=asset.registry_find(&assets.registry,body)
    if !testing.expectf(t,built,"the demo has the body of Mirai %s: mirai build editor demo imports it",MIRAI_BODY,loc=loc) {return}
    return {record.id,body},true
}

@(private)
Animation_Input_Fixture :: struct {
    entities:core.Entities,
    assets:host.Assets,app:host.App,
    transforms:core.Table(core.Transform),worlds:core.Table(core.World_Transform),parents:core.Table(core.Parent),names:core.Table(core.Name),hierarchy:core.Hierarchy,propagation:core.Propagation,jumps:core.Jumps,
    inputs:core.Table(inp.Move_Input),root_bodies:core.Table(animation_physics.Root_Motion_Body),
    walks:core.Table(locomotion.Walk),flights:core.Table(locomotion.Fly),swims:core.Table(locomotion.Swim),remotes:core.Table(core.Remote),character_moves:core.Table(phys.Character_Move),locomotion_requests:locomotion.Locomotion_Requests,
    characters:core.Table(phys.Character),locomotion_states:core.Table(locomotion.Locomotion_State),rigids:core.Table(phys.Rigid_Body),colliders:core.Table(phys.Collider),joints:core.Table(phys.Joint),meshes:core.Table(render.Mesh_Renderer),
    body_states:core.Table(core.Motion),replicas:core.Table(core.Pose_Target),character_states:core.Table(phys.Character_State),joint_states:core.Table(phys.Joint_State),
    physics:phys.Physics_State,settings:phys.Physics_Settings,body_requests:phys.Body_Requests,body_events:phys.Physics_Events,collider_meshes:phys.Collider_Meshes,problems:core.Problems,
    animations:core.Table(anim.Animation),targets:core.Table(anim.Animation_Target),played:core.Table(anim.Animation_Played),requests:anim.Animation_Requests,events:anim.Animation_Events,playback:anim.Playback,skeletons:anim.Skeleton_Assets,
    attachments:core.Table(anim.Bone_Attachment),sources:core.Table(anim.Pose_Source),modifiers:anim.Modifier_Runtime,
    actions:anim.Action_Runtime,motion:anim.Motion_Runtime,content_sources:anim.Source_Assets,
}

@(private)
animation_input_fixture_destroy :: proc(f:^Animation_Input_Fixture) {
    host.app_content_destroy(&f.app);phys.state_destroy(&f.physics);phys.collider_meshes_destroy(&f.collider_meshes);host.assets_destroy(&f.assets)
    anim.playback_free(&f.playback);anim.skeleton_assets_free(&f.skeletons)
    anim.actions_runtime_free(&f.actions);anim.motion_runtime_free(&f.motion);anim.source_assets_free(&f.content_sources)
    core.value_free(f,type_info_of(Animation_Input_Fixture))
}

@(private)
animation_input_physics :: proc(f:^Animation_Input_Fixture,time:core.Time) {
    places:core.Places
    locomotion.locomotion_prepare(core.read(&f.characters),core.read(&f.colliders),&f.locomotion_states,&f.character_moves,core.read(&f.remotes),
        core.read(&f.walks),core.read(&f.flights),core.read(&f.swims),&f.locomotion_requests,time,&f.problems)
    core.table_settle(&f.locomotion_states,&f.entities)
    locomotion.locomotion_step(core.read(&f.characters),&f.locomotion_states,&f.character_moves,&f.inputs,core.read(&f.walks),core.read(&f.flights),core.read(&f.swims),core.read(&f.character_states),core.read(&f.body_states),core.read(&f.transforms),core.read(&f.parents),core.read(&f.remotes),{&f.physics},{&places},{},{},time,core.CLOCK_DEFAULT,&f.problems)
    core.table_settle(&f.locomotion_states,&f.entities);core.table_settle(&f.inputs,&f.entities);core.table_settle(&f.character_moves,&f.entities)
    phys.physics_step(&f.physics,{&f.settings},&f.body_requests,&f.body_events,&f.collider_meshes,&f.app,time,core.read(&f.rigids),core.read(&f.colliders),core.read(&f.characters),&f.character_moves,&f.joints,core.read(&f.meshes),core.read(&f.parents),core.read(&f.names),&f.transforms,&f.body_states,core.read(&f.replicas),&f.character_states,&f.joint_states,{},nil,{},{},nil,nil,&f.problems,{},{},{},{},{},core.ref(&f.hierarchy),{},{},{},{})
    core.table_settle(&f.body_states,&f.entities);core.table_settle(&f.character_states,&f.entities);core.table_settle(&f.joint_states,&f.entities)
    core.hierarchy_settle(&f.hierarchy,&f.parents,&f.entities)
    core.transforms_propagate(core.read(&f.transforms),core.ref(&f.hierarchy),&f.worlds,&f.propagation,&f.jumps,{phase=.Fixed});core.table_settle(&f.worlds,&f.entities)
}

// A Character with a Root_Motion_Body walks and turns by the root motion of the clip it plays (here
// 1 m a second along +X while it turns 1 rad a second left), physically, through its locomotion:
// the root delta becomes a layered move of the tick. A body without one walks as it is asked.
@(test)
root_motion_walks_and_turns_a_physical_character_and_leaves_other_bodies_as_they_were_asked :: proc(t:^testing.T) {
    f:Animation_Input_Fixture;defer animation_input_fixture_destroy(&f)
    core.entities_init(&f.entities);testing.expect(t,host.assets_init(&f.assets,{root="assets",capacity=8}))
    f.app={assets=&f.assets,allocator=context.allocator};f.settings={bodies=8,shapes=8,contacts=32,joints=1,characters=2,hulls=1,meshes=1,heightfields=1}
    controlled,driven,hip,floor:=core.create(&f.entities),core.create(&f.entities),core.create(&f.entities),core.create(&f.entities)
    character:=phys.character_default()
    walk:=locomotion.WALK_DEFAULT;walk.max_speed=5;walk.acceleration,walk.braking=1000,1000
    for entity,i in ([2]core.Entity{controlled,driven}) {core.add(&f.inputs,entity,{});core.add(&f.characters,entity,character);core.add(&f.walks,entity,walk);core.add(&f.colliders,entity,phys.collider_character());core.add(&f.transforms,entity,{position={f32(i)*2,0,0},rotation=1,scale={1,1,1}})}
    core.add(&f.transforms,hip,core.TRANSFORM_IDENTITY);core.add(&f.parents,hip,{entity=driven});core.add(&f.names,hip,core.name_make("hip"));core.add(&f.root_bodies,driven,animation_physics.ROOT_MOTION_BODY_DEFAULT)
    core.add(&f.transforms,floor,{position={0,-.1,0},rotation=1,scale={1,1,1}});collider:=phys.COLLIDER_DEFAULT;collider.size={5,.1,5};core.add(&f.colliders,floor,collider)
    source:=host.Content_Animation{id={0x815,0x816},generation=1,clip_count=1}
    testing.expect(t,lib.library_init(&source.lib,{max_keys=4,max_tracks=2,max_clips=2}))
    turned:=mm.quat_axis_angle({0,1,0},1)
    advance,_:=lib.clip_add(&source.lib,{name=base.name_hash("advance"),tracks={
        {target=base.name_hash("hip"),property=.Position,keys={{time=0},{time=1,value={1,0,0,0}}}},
        {target=base.name_hash("hip"),property=.Rotation,keys={{time=0,value={0,0,0,1}},{time=1,value={turned.x,turned.y,turned.z,turned.w}}}},
    }})
    testing.expect(t,advance==1)
    source.lib.clips[1]=source.lib.clips[0];source.lib.clips[1].loop=.Loop;source.lib.clip_count=2
    source.roots=make([]asset.Animation_Root,1);base.text_set(source.roots[0].bone[:],"hip");source.roots[0].translation,source.roots[0].rotation=true,true
    content:=host.app_content(&f.app);append(&content.animations,source);content.index[source.id]={kind=.Animation,index=0}
    animation:=anim.ANIMATION_DEFAULT;animation.asset=source.id;animation.root_motion=.Extract;animation.loop,animation.playing=false,false;base.text_set(animation.clip[:],"advance");core.add(&f.animations,driven,animation)
    core.table_settle(&f.inputs,&f.entities);core.table_settle(&f.characters,&f.entities);core.table_settle(&f.walks,&f.entities);core.table_settle(&f.transforms,&f.entities);core.table_settle(&f.parents,&f.entities);core.table_settle(&f.names,&f.entities);core.table_settle(&f.root_bodies,&f.entities);core.table_settle(&f.colliders,&f.entities);core.table_settle(&f.animations,&f.entities)
    time:=core.Time{dt=1.0/60,playing=true}
    for i in 0..<16 {time.tick=u64(i);animation_input_physics(&f,time)}
    core.edit(&f.inputs,controlled).move={.2,0,0}
    anim.play_clip(&f.requests,driven,"advance",fade=0,loop=false)
    progress:core.Table(anim.Animation_Progress);defer core.table_destroy(&progress)
    characters:anim.Character_Assets;defer anim.character_assets_free(&characters)
    anim.animation_prepare(core.read(&f.animations),core.read(&f.attachments),core.read(&f.meshes),core.read(&f.sources),&f.modifiers,&f.playback,&characters,&f.skeletons,&f.app,nil)
    anim.animation_sample(core.read(&f.animations),core.read(&progress),&f.played,&f.transforms,core.read(&f.parents),core.ref(&f.hierarchy),core.read(&f.names),core.read(&f.targets),core.read(&f.remotes),&f.requests,&f.events,&f.modifiers,&f.playback,&characters,&f.skeletons,&f.app,time,{},nil,&f.actions,&f.motion,&f.content_sources,{},core.CLOCK_DEFAULT,anim.ANIMATION_BUDGET_CONFIG_DEFAULT,{},{})
    delta,present:=anim.animation_root_delta(core.ref(&f.playback),driven)
    testing.expect(t,present && abs(delta.translation.x-time.dt)<1e-5)
    before_control,_:=core.get(&f.transforms,controlled);before_driven,_:=core.get(&f.transforms,driven)
    yaw:=core.get(&f.locomotion_states,driven) or_else locomotion.Locomotion_State{}
    animation_physics.animation_root_motion(core.read(&f.root_bodies),core.read(&f.locomotion_states),core.read(&f.worlds),nil,nil,core.ref(&f.playback),&f.locomotion_requests,time,core.CLOCK_DEFAULT)
    // The clip advances 1 m/s and turns 1 rad/s: one layered move of the driven body asks for that.
    if testing.expect_value(t,len(f.locomotion_requests.queue.items),1) {
        asked:=f.locomotion_requests.queue.items[0]
        testing.expectf(t,asked.entity==driven && linalg.length(asked.move.velocity-mm.Vec3{1,0,0})<1e-3 && abs(asked.move.turn-1)<1e-3,"%v",asked)
    }
    time.tick+=1;animation_input_physics(&f,time)
    after_control,_:=core.get(&f.transforms,controlled);after_driven,_:=core.get(&f.transforms,driven)
    turned_to:=core.get(&f.locomotion_states,driven) or_else locomotion.Locomotion_State{}
    testing.expect(t,after_control.position.x>before_control.position.x && after_driven.position.x>before_driven.position.x)
    testing.expectf(t,abs(mm.angle_wrap(turned_to.yaw-yaw.yaw)-time.dt)<1e-4,"it turned %v in the tick",turned_to.yaw-yaw.yaw)
    testing.expect_value(t,f.problems.count,0)
}
