package anim

import "mirai:core"
import audio "mirai:engine/audio"
import "mirai:std/base"
import mm "mirai:std/math"

Cue_Anchor :: enum u8 {Entity,Bone,Socket}

Animation_Cue :: struct {
    marker:[32]u8 `mirai:"text"`,
    sound:base.Asset_Id `mirai:"kind=.sound .sound_set"`,
    channel:[core.CHANNEL_NAME_BYTES]u8 `mirai:"text"`,
    anchor:Cue_Anchor,
    name:[64]u8 `mirai:"text"`,
    align_up:bool,
}

@(component,description="Marker cues played by this animated entity.")
Animation_Cues :: struct {bindings:[4]Animation_Cue `mirai:"trim"`}

ANIMATION_CUE_ROOM :: 256

@(step="fixed",stage="react",loops="game",after="animation_advance")
animation_cues :: proc(
    bindings:^core.Table(Animation_Cues,.Read),
    events:core.Ref(Animation_Events),playback:core.Ref(Playback),skeletons:core.Ref(Skeleton_Assets),
    transforms:^core.Table(core.Transform,.Read),parents:^core.Table(core.Parent,.Read),
    worlds:^core.Table(core.World_Transform,.Read),sounds:^audio.Sound_Requests,births:^core.Births,
    time:core.Time,problems:^core.Problems,
) {
    if !time.playing || core.count(bindings)==0 {return}
    for event in events.items {
        if event.kind!=.Marker {continue}
        row:=core.row_of(bindings,event.entity)
        if row<0 {continue}
        config:=core.view_at(bindings,row)
        for i in 0..<len(config.bindings) {
            cue:=&config.bindings[i]
            if cue.marker[0]==0 || base.name_hash(base.text_get(cue.marker[:]))!=event.name {continue}
            pose,placed:=cue_pose(cue,event.entity,playback,skeletons,transforms,parents,worlds)
            if !placed {
                core.report(problems,event.entity,"animation.cue_anchor",
                    "the marker cue needs an entity transform or a valid bone or socket")
                continue
            }
            cue_emit(cue,event.entity,pose,sounds,births,time,problems)
        }
    }
}

@(private)
cue_pose :: proc(
    cue:^Animation_Cue,entity:core.Entity,playback:core.Ref(Playback),skeletons:core.Ref(Skeleton_Assets),
    transforms:^core.Table(core.Transform,.Read),parents:^core.Table(core.Parent,.Read),
    worlds:^core.Table(core.World_Transform,.Read),
) -> (mm.Transform,bool) {
    if cue.anchor==.Entity {return constraint_world(transforms,parents,worlds,entity)}
    if cue.name[0]==0 {return {},false}
    rig:=constraint_playing(playback,entity)
    if rig==nil || rig.seen!=playback.frame || !rig.pose_ready {return {},false}
    name:=base.name_hash(base.text_get(cue.name[:]))
    bone:=-1
    offset:=mm.TRANSFORM_IDENTITY
    switch cue.anchor {
    case .Entity:
    case .Bone: bone=bone_find(rig,name)
    case .Socket: bone,offset=spatial_socket_find(rig,skeletons.ptr,name)
    }
    poses:=playing_pose(rig,.World)
    if bone<0 || bone>=len(poses) {return {},false}
    return mm.transform_compose(poses[bone],offset),true
}

@(private)
cue_emit :: proc(
    cue:^Animation_Cue,entity:core.Entity,pose:mm.Transform,sounds:^audio.Sound_Requests,
    births:^core.Births,time:core.Time,problems:^core.Problems,
) {
    full:=false
    if cue.sound!={} && sounds!=nil && !time.resimulating {
        if cue_room(&sounds.queue) {audio.play_id(sounds,cue.sound,pose.position)} else {full=true}
    }
    if cue.channel[0]!=0 && births!=nil {
        birth:=core.Birth{channel=core.birth_channel(base.text_get(cue.channel[:])),
            position=pose.position}
        if cue.align_up {birth.normal=mm.quat_rotate(pose.rotation,{0,1,0})}
        core.push(&births.queue,birth)
    }
    if full {
        core.report(problems,entity,"animation.cue_capacity",
            "the marker cue did not fit in the sound queue; use fewer simultaneous cues")
    }
}

@(private)
cue_room :: proc(queue:^core.Queue($T)) -> bool {
    if cap(queue.items)<ANIMATION_CUE_ROOM && reserve(&queue.items,ANIMATION_CUE_ROOM)!=nil {
        return false
    }
    return len(queue.items)<cap(queue.items)
}
