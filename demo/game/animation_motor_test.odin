package game

import inp "mirai:engine/input"
import "base:runtime"
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

@(test)
animation_motor_preserves_world_root_direction_facing_and_physical_speed_limits_without_allocations :: proc(t:^testing.T) {
    actor:=mm.Transform{rotation=mm.quat_axis_angle({0,1,0},.6),scale={2,1,3}}
    delta:=anim.Root_Delta{translation={.1,.5,.2},rotation=mm.quat_axis_angle({0,1,0},.3)}
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    input:=animation_motor_input(delta,actor,10,.1)
    world:=mm.quat_rotate(mm.quat_axis_angle({0,1,0},input.look_yaw),input.move)*10*.1
    requested:=mm.quat_rotate(actor.rotation,delta.translation*actor.scale);requested.y=0
    stopped:=animation_motor_input(delta,actor,10,0)
    clamped:=animation_motor_input({translation={100,0,0},rotation=1},actor,10,.1)
    context=saved
    testing.expect(t,linalg.length(world-requested)<1e-5 && abs(mm.angle_wrap(input.look_yaw-.9))<1e-5 && input.move.y==0 && stopped.move=={})
    testing.expect(t,abs(linalg.length(clamped.move)-1)<1e-5)
}

@(private)
Animation_Input_Fixture :: struct {
    entities:core.Entities,
    assets:host.Assets,app:host.App,
    transforms:core.Table(core.Transform),worlds:core.Table(core.World_Transform),parents:core.Table(core.Parent),names:core.Table(core.Name),hierarchy:core.Hierarchy,propagation:core.Propagation,jumps:core.Jumps,
    inputs:core.Table(inp.Move_Input),motors:core.Table(Animation_Motor),
    walks:core.Table(locomotion.Walk),flights:core.Table(locomotion.Fly),swims:core.Table(locomotion.Swim),remotes:core.Table(core.Remote),character_moves:core.Table(phys.Character_Move),locomotion_requests:locomotion.Locomotion_Requests,
    characters:core.Table(phys.Character),locomotion_states:core.Table(locomotion.Locomotion_State),rigids:core.Table(phys.Rigid_Body),colliders:core.Table(phys.Collider),joints:core.Table(phys.Joint),meshes:core.Table(render.Mesh_Renderer),
    body_states:core.Table(core.Motion),replicas:core.Table(core.Pose_Target),character_states:core.Table(phys.Character_State),joint_states:core.Table(phys.Joint_State),
    physics:phys.Physics_State,settings:phys.Physics_Settings,body_requests:phys.Body_Requests,body_events:phys.Physics_Events,collider_meshes:phys.Collider_Meshes,problems:core.Problems,
    animations:core.Table(anim.Animation),targets:core.Table(anim.Animation_Target),roots:core.Table(anim.Root_Motion),requests:anim.Animation_Requests,events:anim.Animation_Events,playback:anim.Playback,skeletons:anim.Skeleton_Assets,
    attachments:core.Table(anim.Bone_Attachment),sources:core.Table(anim.Pose_Source),modifiers:anim.Modifier_Runtime,modifier_requests:anim.Modifier_Requests,
}

@(private)
animation_input_fixture_destroy :: proc(f:^Animation_Input_Fixture) {
    host.app_content_destroy(&f.app);phys.state_destroy(&f.physics);phys.collider_meshes_destroy(&f.collider_meshes);host.assets_destroy(&f.assets)
    anim.playback_free(&f.playback);anim.skeleton_assets_free(&f.skeletons)
    core.value_free(f,type_info_of(Animation_Input_Fixture))
}

@(private)
animation_input_physics :: proc(f:^Animation_Input_Fixture,time:core.Time) {
    no_slides:core.Table(locomotion.Slide);no_mantles:core.Table(locomotion.Mantle);no_tacticals:core.Table(locomotion.Tactical_Sprint);no_ledges:core.Table(locomotion.Ledge_Jump)
    locomotion.locomotion_step(core.read(&f.characters),&f.locomotion_states,&f.character_moves,&f.inputs,core.read(&f.walks),core.read(&f.flights),core.read(&f.swims),core.read(&no_slides),core.read(&no_mantles),core.read(&no_tacticals),core.read(&no_ledges),core.read(&f.character_states),core.read(&f.body_states),core.read(&f.transforms),core.read(&f.parents),core.read(&f.remotes),{&f.physics},{},{},&f.locomotion_requests,time,core.CLOCK_DEFAULT,&f.problems)
    core.table_settle(&f.locomotion_states,&f.entities);core.table_settle(&f.inputs,&f.entities);core.table_settle(&f.character_moves,&f.entities)
    phys.physics_step(&f.physics,{&f.settings},&f.body_requests,&f.body_events,&f.collider_meshes,&f.app,time,core.read(&f.rigids),core.read(&f.colliders),core.read(&f.characters),core.read(&f.character_moves),&f.joints,core.read(&f.meshes),core.read(&f.parents),core.read(&f.names),&f.transforms,&f.body_states,core.read(&f.replicas),&f.character_states,&f.joint_states,{},nil,{},{},nil,nil,&f.problems,{},{},{},{},{},core.ref(&f.hierarchy),{})
    core.table_settle(&f.body_states,&f.entities);core.table_settle(&f.character_states,&f.entities);core.table_settle(&f.joint_states,&f.entities)
    core.hierarchy_settle(&f.hierarchy,core.read(&f.parents),&f.entities)
    core.transforms_propagate(core.read(&f.transforms),core.ref(&f.hierarchy),&f.worlds,&f.propagation,&f.jumps,{phase=.Fixed});core.table_settle(&f.worlds,&f.entities)
}

@(test)
animation_motor_drives_the_sampled_root_motion_and_leaves_other_bodies_as_they_were_asked :: proc(t:^testing.T) {
    f:Animation_Input_Fixture;defer animation_input_fixture_destroy(&f)
    core.entities_init(&f.entities);testing.expect(t,host.assets_init(&f.assets,{root="assets",capacity=8}))
    f.app={assets=&f.assets,allocator=context.allocator};f.settings={bodies=8,shapes=8,contacts=32,joints=1,characters=2,hulls=1,meshes=1,heightfields=1}
    controlled,motor,hip,floor:=core.create(&f.entities),core.create(&f.entities),core.create(&f.entities),core.create(&f.entities)
    character:=phys.character_default()
    walk:=locomotion.WALK_DEFAULT;walk.max_speed=5;walk.acceleration,walk.braking=1000,1000
    for entity,i in ([2]core.Entity{controlled,motor}) {core.add(&f.inputs,entity,{});core.add(&f.characters,entity,character);core.add(&f.walks,entity,walk);core.add(&f.colliders,entity,phys.collider_character());core.add(&f.transforms,entity,{position={f32(i)*2,0,0},rotation=1,scale={1,1,1}})}
    core.add(&f.transforms,hip,core.TRANSFORM_IDENTITY);core.add(&f.parents,hip,{entity=motor});core.add(&f.names,hip,core.name_make("hip"));core.add(&f.motors,motor,ANIMATION_MOTOR_DEFAULT)
    core.add(&f.transforms,floor,{position={0,-.1,0},rotation=1,scale={1,1,1}});collider:=phys.COLLIDER_DEFAULT;collider.size={5,.1,5};core.add(&f.colliders,floor,collider)
    source:=host.Content_Animation{id={0x815,0x816},generation=1,clip_count=1}
    testing.expect(t,lib.library_init(&source.lib,{max_keys=2,max_tracks=1,max_clips=2}))
    advance,_:=lib.clip_add(&source.lib,{name=base.name_hash("advance"),tracks={{target=base.name_hash("hip"),property=.Position,keys={{time=0},{time=1,value={1,0,0,0}}}}}})
    testing.expect(t,advance==1)
    source.lib.clips[1]=source.lib.clips[0];source.lib.clips[1].loop=.Loop;source.lib.clip_count=2
    source.roots=make([]asset.Animation_Root,1);base.text_set(source.roots[0].bone[:],"hip");source.roots[0].translation=true
    content:=host.app_content(&f.app);append(&content.animations,source);content.index[source.id]={kind=.Animation,index=0}
    animation:=anim.ANIMATION_DEFAULT;animation.asset=source.id;animation.root_motion=.Extract;animation.loop,animation.playing=false,false;base.text_set(animation.clip[:],"advance");core.add(&f.animations,motor,animation)
    core.add(&f.roots,motor,{bone=anim.bone_ref("hip"),translation=true,in_place=true})
    core.table_settle(&f.inputs,&f.entities);core.table_settle(&f.characters,&f.entities);core.table_settle(&f.walks,&f.entities);core.table_settle(&f.transforms,&f.entities);core.table_settle(&f.parents,&f.entities);core.table_settle(&f.names,&f.entities);core.table_settle(&f.motors,&f.entities);core.table_settle(&f.colliders,&f.entities);core.table_settle(&f.animations,&f.entities);core.table_settle(&f.roots,&f.entities)
    time:=core.Time{dt=1.0/60,playing=true}
    for i in 0..<16 {time.tick=u64(i);animation_input_physics(&f,time)}
    core.edit(&f.inputs,controlled).move={.2,0,0}
    anim.animation_clip(core.edit(&f.animations,motor),"advance",fade=0,loop=false)
    progress:core.Table(anim.Animation_Progress);defer core.table_destroy(&progress)
    characters:anim.Character_Assets;defer anim.character_assets_free(&characters)
    anim.animation_sample(core.read(&f.animations),&progress,core.read(&f.attachments),&f.transforms,core.read(&f.parents),core.ref(&f.hierarchy),core.read(&f.names),core.read(&f.targets),core.read(&f.meshes),core.read(&f.sources),&f.requests,&f.events,&f.modifier_requests,&f.modifiers,&f.playback,&characters,&f.skeletons,&f.app,time,{},nil,nil,nil,nil,nil,{},core.CLOCK_DEFAULT,anim.ANIMATION_BUDGET_CONFIG_DEFAULT)
    delta,present:=anim.animation_root_delta(&f.playback,motor)
    testing.expect(t,present && abs(delta.translation.x-time.dt)<1e-5 && abs(f.playback.states[0].local[1].position.x-time.dt)<1e-5)
    before_control,_:=core.get(&f.transforms,controlled);before_motor,_:=core.get(&f.transforms,motor)
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    animation_motor_drive(core.read(&f.motors),&f.inputs,core.read(&f.walks),core.read(&f.worlds),{&f.playback},time)
    context=saved
    published_control,_:=core.get(&f.inputs,controlled);published_motor,_:=core.get(&f.inputs,motor)
    testing.expect(t,published_control.move.x==.2 && abs(published_motor.move.x-.2)<1e-5)
    time.tick+=1;animation_input_physics(&f,time)
    after_control,_:=core.get(&f.transforms,controlled);after_motor,_:=core.get(&f.transforms,motor)
    testing.expect(t,after_control.position.x>before_control.position.x && after_motor.position.x>before_motor.position.x)
    testing.expect_value(t,f.problems.count,0)
}
