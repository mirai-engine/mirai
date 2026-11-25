package anim

import "mirai:core"
import audio "mirai:engine/audio"
import "mirai:std/base"
import mm "mirai:std/math"

// The cues of a .character: what a marker of its clips plays each time a clip
// crosses it (a footstep, a reload click, the dust of a landing), at the
// animated entity or at a bone or a socket of its skeleton. One row per marker
// name; the set resolves the names when it loads (Cue_Ready).
Cue_Anchor :: enum u8 {Entity,Bone,Socket}

Marker_Cue :: struct {
    marker:[32]u8 `mirai:"text"`,
    anchor:Cue_Anchor `mirai:"optional"`,
    at:[64]u8 `mirai:"text,optional"`, // the bone or the socket of anchor
    cue:audio.Cue,
}

CHARACTER_CUES :: 256 // rows of the cues of a .character

// A row of the cues of a set with its names hashed.
Cue_Ready :: struct {marker,at:u64,channel:core.Birth_Channel}

@(private)
marker_cues_check :: proc(cues:[]Marker_Cue) -> bool {
    if len(cues)>CHARACTER_CUES {return false}
    for &row,i in cues {
        if row.marker[0]==0 || row.anchor>max(Cue_Anchor) || row.anchor!=.Entity && row.at[0]==0 {return false}
        for &other in cues[:i] {if other.marker==row.marker {return false}}
    }
    return true
}

@(private)
marker_cues_ready :: proc(cues:[]Marker_Cue,ready:[]Cue_Ready) {
    for &row,i in cues {
        ready[i]={marker=base.name_hash(base.text_get(row.marker[:])),channel=audio.cue_channel(row.cue)}
        if row.anchor!=.Entity {ready[i].at=base.name_hash(base.text_get(row.at[:]))}
    }
}

// Plays the cue of each marker an entity crossed in the tick whose .character
// has one for its name, through audio.cue_play by that entity.
@(step="fixed",stage="react",loops="game",after="animation_advance")
animation_cues :: proc(
    animations:^core.Table(Animation,.Read),events:core.Ref(Animation_Events),playback:core.Ref(Playback),
    characters:core.Ref(Character_Assets),skeletons:core.Ref(Skeleton_Assets),
    transforms:^core.Table(core.Transform,.Read),parents:^core.Table(core.Parent,.Read),
    worlds:^core.Table(core.World_Transform,.Read),sounds:^audio.Sound_Requests,births:^core.Births,
    time:core.Time,problems:^core.Problems,
) {
    if !time.playing || events.ptr==nil {return}
    for event in events.items {
        if event.kind!=.Marker {continue}
        animation,animated:=core.get(animations,event.entity)
        if !animated {continue}
        content:=character_cached(characters,animation.asset)
        if content==nil {continue}
        for &ready,i in content.cues {
            if ready.marker!=event.name {continue}
            row:=&content.set.cues[i]
            pose,placed:=cue_pose(row.anchor,ready.at,event.entity,playback,skeletons,transforms,parents,worlds)
            if !placed {
                core.report(problems,event.entity,"animation.cue_anchor",
                    "the cue of marker '%s' needs the entity placed, or a bone or a socket '%s' of its skeleton; fix the cues of its .character",
                    base.text_get(row.marker[:]),base.text_get(row.at[:]))
                continue
            }
            audio.cue_play(sounds,births,row.cue,ready.channel,pose,event.entity)
        }
    }
}

@(private)
cue_pose :: proc(
    anchor:Cue_Anchor,at:u64,entity:core.Entity,playback:core.Ref(Playback),skeletons:core.Ref(Skeleton_Assets),
    transforms:^core.Table(core.Transform,.Read),parents:^core.Table(core.Parent,.Read),
    worlds:^core.Table(core.World_Transform,.Read),
) -> (mm.Transform,bool) {
    if anchor==.Entity {return constraint_world(transforms,parents,worlds,entity)}
    rig:=constraint_playing(playback,entity)
    if rig==nil || rig.seen!=playback.frame || !rig.pose_ready {return {},false}
    bone:=-1
    offset:=mm.TRANSFORM_IDENTITY
    switch anchor {
    case .Entity:
    case .Bone: bone=bone_find(rig,at)
    case .Socket: bone,offset=spatial_socket_find(rig,skeletons.ptr,at)
    }
    poses:=playing_pose(rig,.World)
    if bone<0 || bone>=len(poses) {return {},false}
    return mm.transform_compose(poses[bone],offset),true
}
