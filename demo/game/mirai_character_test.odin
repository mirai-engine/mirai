package game

import "core:testing"
import "mirai:asset"
import "mirai:core"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"
import anim "plugins:animation/runtime"

@(test)
mirai_character_walk_binds_and_changes_its_leg_pose :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    skeleton_file,animation_file:asset.Asset
    defer asset.asset_close(&skeleton_file);defer asset.asset_close(&animation_file)
    if !testing.expect_value(t,asset.asset_load(&skeleton_file,"demo/assets/characters/mirai/Armature.skeleton"),asset.Error.None) {return}
    if !testing.expect_value(t,asset.asset_load(&animation_file,"demo/assets/characters/mirai/mirai_locomotion.anim"),asset.Error.None) {return}
    skel,se:=asset.skeleton_view(&skeleton_file,&types)
    clips,ae:=asset.animation_view(&animation_file,&types)
    if !testing.expect(t,se==.None && ae==.None) {return}
    library:lib.Library;defer lib.library_destroy(&library)
    if !testing.expect(t,lib.library_init(&library,asset.animation_library_desc(clips))) {return}
    if !testing.expect(t,asset.animation_clips_add(clips,&library,.Loop)!=0) {return}
    clip:=lib.clip_find(&library,base.name_hash("walk"))
    if !testing.expect(t,clip!=0) {return}
    playback:anim.Playback;defer anim.playback_free(&playback)
    state:anim.Playing;defer anim.playing_free(&state)
    entities:core.Entities;core.entities_init(&entities);defer core.entities_destroy(&entities)
    transforms:core.Table(core.Transform);defer core.table_destroy(&transforms)
    state.entity=core.create(&entities)
    core.add(&transforms,state.entity,core.TRANSFORM_IDENTITY);core.table_settle(&transforms,&entities)
    definition:=anim.Skeleton_Content{id=skeleton_file.blob.header.id,revision=1,bones=skel.bones}
    if !testing.expect(t,anim.skeleton_bind(&playback,&state,&definition,nil,&transforms)) {return}
    tracks:=make([]lib.Bone_Tracks,len(state.local));defer delete(tracks)
    if !testing.expect(t,lib.skeleton_bind(&library,clip,anim.playing_skeleton(&state),tracks)) {return}
    leg:=anim.bone_resolve(&state,anim.bone_ref("LeftUpLeg"))
    if !testing.expect(t,leg>=0) {return}
    if !testing.expect(t,lib.skeleton_sample(&library,tracks,state.rest[:],0,state.local[:])) {return}
    first:=state.local[leg].rotation
    if !testing.expect(t,lib.skeleton_sample(&library,tracks,state.rest[:],.35,state.local[:])) {return}
    second:=state.local[leg].rotation
    testing.expectf(t,abs(first.x-second.x)+abs(first.y-second.y)+abs(first.z-second.z)+abs(first.w-second.w)>.01,"walk should move the left leg")
    feet:=[4]int{anim.bone_resolve(&state,anim.bone_ref("LeftFoot")),anim.bone_resolve(&state,anim.bone_ref("LeftToeBase")),anim.bone_resolve(&state,anim.bone_ref("RightFoot")),anim.bone_resolve(&state,anim.bone_ref("RightToeBase"))}
    for foot in feet {if !testing.expect(t,foot>=0) {return}}
    rest:=make([]mm.Transform,len(state.rest),context.temp_allocator)
    if !testing.expect(t,lib.skeleton_world(anim.playing_skeleton(&state),state.rest[:],rest)) {return}
    for frame in 0..<60 {
        at:=lib.clip_duration(&library,clip)*f32(frame)/60
        if !testing.expect(t,lib.skeleton_sample(&library,tracks,state.rest[:],at,state.local[:]) && lib.skeleton_world(anim.playing_skeleton(&state),state.local[:],state.world[:])) {return}
        clearance:=max(f32)
        for foot in feet {clearance=min(clearance,state.world[foot].position.y-rest[foot].position.y)}
        testing.expectf(t,abs(clearance)<.015,"foot clearance %.3f m at %.3f s",clearance,at)
    }
}
