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

@(test)
selected_clip_root_metadata_drives_extraction_and_in_place_without_a_rebuilt_table :: proc(t:^testing.T) {
    problems:core.Problems
    assets:host.Assets;app:=host.App{assets=&assets,allocator=context.allocator};defer host.app_content_destroy(&app)
    content:=host.app_content(&app)
    source:host.Content_Animation;initial:=program_test_content(t,&source);defer playing_free(&initial)
    source.id,source.generation={0xa10,0xa11},1
    source.roots[2].translation,source.roots[2].rotation=false,true
    append(&content.animations,source);content.index[source.id]={kind=.Animation,index=0}
    entities:core.Entities;core.entities_init(&entities);defer core.entities_destroy(&entities)
    transforms:core.Table(core.Transform);parents:core.Table(core.Parent);names:core.Table(core.Name);targets:core.Table(Animation_Target);animations:core.Table(Animation)
    defer {core.table_destroy(&transforms);core.table_destroy(&parents);core.table_destroy(&names);core.table_destroy(&targets);core.table_destroy(&animations)}
    actor,hip:=core.create(&entities),core.create(&entities)
    core.add(&transforms,actor,core.TRANSFORM_IDENTITY);core.add(&transforms,hip,core.TRANSFORM_IDENTITY);core.add(&parents,hip,{entity=actor})
    name:core.Name;base.text_set(name.text[:],"hip");core.add(&names,hip,name)
    animation:=ANIMATION_DEFAULT;animation.asset=source.id;animation.loop=false;animation.fade=0;animation.root_motion=.Extract;base.text_set(animation.clip[:],"walk")
    core.add(&animations,actor,animation)
    core.table_settle(&transforms,&entities);core.table_settle(&parents,&entities);core.table_settle(&names,&entities);core.table_settle(&targets,&entities);core.table_settle(&animations,&entities)
    hierarchy:core.Hierarchy;defer core.value_free(&hierarchy,type_info_of(core.Hierarchy))
    core.hierarchy_settle(&hierarchy,core.read(&parents),&entities)
    requests:Animation_Requests;events:Animation_Events;playback:Playback;skeletons:Skeleton_Assets;constraints:Animation_Constraints
    defer {delete(requests.seeks.items);delete(requests.poses.items);delete(requests.distances.items);delete(events.items);playback_free(&playback);skeleton_assets_free(&skeletons);constraints_free(&constraints)}
    for stage in 0..<5 {
        switch stage {
        case 1: animation_play(core.get(&animations,actor),"run",fade=0,loop=false)
        case 2: core.get(&animations,actor).root_motion=.None
        case 3: value:=core.get(&animations,actor);value.root_motion=.In_Place;animation_play(value,"walk",fade=0,loop=false)
        case 4: animation_play(core.get(&animations,actor),"wave",fade=1,loop=false)
        }
        animation_tick(core.read(&animations),&transforms,core.read(&parents),core.ref(&hierarchy),core.read(&names),&requests,&events,core.read(&targets),{},&playback,&app,{dt=.25,playing=true},{},&skeletons,&problems)
        state:=&playback.states[0]
        switch stage {
        case 0: testing.expect(t,state.has_base_root && state.base_root.translation && abs(state.motion.translation.x-.25)<1e-5)
        case 1: testing.expect(t,state.clip==2 && state.has_base_root && !state.base_root.translation && state.base_root.rotation && state.motion.translation=={})
        case 2: testing.expect(t,!state.has_base_root && state.motion.translation=={})
        case 3: testing.expect(t,state.base_root.in_place && state.local[1].position==state.rest[1].position,"an in-place clip blends its root at rest")
        case 4: testing.expect(t,!state.has_base_root && lib.fader_fading(state.fader) && state.local[1].position==state.rest[1].position,"a clip fading out under one without root motion keeps its root in place")
        }
        animation_finish(&playback,{problems=&problems},&constraints,&transforms,core.read(&parents),.25,nil,{})
        if stage>=3 {testing.expect(t,state.local[1].position==state.rest[1].position)}
    }
    testing.expect(t,problems.count==0)
}
