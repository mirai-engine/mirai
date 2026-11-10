package anim

import "core:math/linalg"
import "core:testing"
import "mirai:core"
import "mirai:host"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"

// An imported armature above the root bone scales centimeters to meters and, as the importer
// leaves it for a model that faces -Z, turns Z up into Y up with a quarter turn about +X:
// the root motion of the rig is that of the clip carried through it, and a root without such a
// parent keeps it as the clip gives it.
@(test)
root_motion_is_carried_into_the_rig_by_the_bones_above_the_root :: proc(t:^testing.T) {
    state:Playing;defer playing_free(&state)
    append(&state.targets,base.name_hash("Armature"),base.name_hash("Armature/Hips"))
    append(&state.parents,-1,0)
    armature:=mm.Transform{{0,0,0},mm.quat_axis_angle({1,0,0},mm.PI*.5),{.01,.01,.01}}
    append(&state.rest,armature,mm.TRANSFORM_IDENTITY)
    turn:=mm.quat_axis_angle({0,0,1},.4)
    moved,turned:=root_motion_to_rig(&state,base.name_hash("Armature/Hips"),{0,-150,0},turn)
    testing.expectf(t,linalg.length(moved-mm.Vec3{0,0,-1.5})<1e-4,"150 cm along the armature's -Y are 1.5 m along -Z, the front: %v",moved)
    testing.expectf(t,mm.quat_angle(turned,mm.quat_axis_angle({0,1,0},-.4))<1e-4,"a turn about the armature's Z is one about -Y: %v",turned)
    kept,same:=root_motion_to_rig(&state,base.name_hash("Armature"),{1,2,3},turn)
    testing.expect(t,kept==mm.Vec3{1,2,3} && same==turn)
}

// A bound rig's first slot is its entity, with the Transform it had when bound as its rest: a
// character spawned facing back still gets the root motion in its own axes, which the game turns
// by its current rotation, not by the one it was spawned with.
@(test)
root_motion_leaves_out_the_transform_the_entity_was_bound_with :: proc(t:^testing.T) {
    state:Playing;defer playing_free(&state)
    append(&state.targets,0,base.name_hash("Armature"),base.name_hash("Armature/root"))
    append(&state.parents,-1,0,1)
    spawned:=mm.Transform{{3,0,5},mm.quat_axis_angle({0,1,0},mm.PI),{1,1,1}}
    append(&state.rest,spawned,mm.TRANSFORM_IDENTITY,mm.TRANSFORM_IDENTITY)
    turn:=mm.quat_axis_angle({0,1,0},.3)
    moved,turned:=root_motion_to_rig(&state,base.name_hash("Armature/root"),{0,0,-0.1},turn)
    testing.expectf(t,linalg.length(moved-mm.Vec3{0,0,-0.1})<1e-6,"forward in the clip is forward of the entity: %v",moved)
    testing.expectf(t,mm.quat_angle(turned,turn)<1e-5,"its turn is its own: %v",turned)
}

@(private="file")
Root_Metadata_World :: struct {
    using world:core.Test_World,
    transforms:core.Table(core.Transform),
    parents:core.Table(core.Parent),
    names:core.Table(core.Name),
    targets:core.Table(Animation_Target),
    animations:core.Table(Animation),
    hierarchy:core.Hierarchy,
    requests:Animation_Requests,
    events:Animation_Events,
    playback:Playback,
    constraints:Animation_Constraints,
}

@(test)
selected_clip_root_metadata_drives_extraction_and_in_place_without_a_rebuilt_table :: proc(t:^testing.T) {
    problems:core.Problems
    assets:host.Assets;app:=host.App{assets=&assets,allocator=context.allocator};defer host.app_content_destroy(&app)
    content:=host.app_content(&app)
    source:host.Content_Animation;initial:=program_test_content(t,&source);defer playing_free(&initial)
    source.id,source.generation={0xa10,0xa11},1
    source.roots[2].translation,source.roots[2].rotation=false,true
    append(&content.animations,source);content.index[source.id]={kind=.Animation,index=0}
    w:Root_Metadata_World
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    actor,hip:=core.create(&w.entities),core.create(&w.entities)
    core.add(&w.transforms,actor,core.TRANSFORM_IDENTITY);core.add(&w.transforms,hip,core.TRANSFORM_IDENTITY);core.add(&w.parents,hip,{entity=actor})
    name:core.Name;base.text_set(name.text[:],"hip");core.add(&w.names,hip,name)
    animation:=ANIMATION_DEFAULT;animation.asset=source.id;animation.loop=false;animation.fade=0;animation.root_motion=.Extract;base.text_set(animation.clip[:],"walk")
    core.add(&w.animations,actor,animation)
    core.test_world_settle(&w)
    core.hierarchy_settle(&w.hierarchy,core.read(&w.parents),&w.entities)
    skeletons:Skeleton_Assets;defer skeleton_assets_free(&skeletons)
    for stage in 0..<5 {
        switch stage {
        case 1: animation_clip(core.get(&w.animations,actor),"run",fade=0,loop=false)
        case 2: core.get(&w.animations,actor).root_motion=.None
        case 3: value:=core.get(&w.animations,actor);value.root_motion=.In_Place;animation_clip(value,"walk",fade=0,loop=false)
        case 4: animation_clip(core.get(&w.animations,actor),"wave",fade=1,loop=false)
        }
        animation_tick(core.read(&w.animations),&w.transforms,core.read(&w.parents),core.ref(&w.hierarchy),core.read(&w.names),&w.requests,&w.events,core.read(&w.targets),{},&w.playback,&app,{dt=.25,playing=true},{},&skeletons,&problems)
        state:=&w.playback.states[0]
        switch stage {
        case 0: testing.expect(t,state.has_base_root && state.base_root.translation && abs(state.motion.translation.x-.25)<1e-5)
        case 1: testing.expect(t,state.clip==2 && state.has_base_root && !state.base_root.translation && state.base_root.rotation && state.motion.translation=={})
        case 2: testing.expect(t,!state.has_base_root && state.motion.translation=={})
        case 3: testing.expect(t,state.base_root.in_place && state.local[1].position==state.rest[1].position,"an in-place clip blends its root at rest")
        case 4: testing.expect(t,!state.has_base_root && lib.fader_fading(state.fader) && state.local[1].position==state.rest[1].position,"a clip fading out under one without root motion keeps its root in place")
        }
        animation_finish(&w.playback,{problems=&problems},&w.constraints,&w.transforms,core.read(&w.parents),.25,nil,{})
        if stage>=3 {testing.expect(t,state.local[1].position==state.rest[1].position)}
    }
    testing.expect(t,problems.count==0)
}
