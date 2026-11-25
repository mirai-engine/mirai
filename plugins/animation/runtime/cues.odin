package anim

import "core:slice"
import "mirai:core"
import audio "mirai:engine/audio"
import "mirai:std/base"
import mm "mirai:std/math"

// What a marker plays each time a clip crosses it (a footstep, a reload click,
// the dust of a landing, the creak of a door), at the animated entity or at a
// bone or a socket of its skeleton. A .character holds the rows of its rigs,
// one per marker name, resolved when the set loads (Cue_Ready). Anything else
// that plays clips (a door, a chest, a weapon) carries them as components: a
// Marker_Cue on the entity whose Animation plays, or on entities under it, one
// per row; their names are resolved when those tables change. The table of a
// .character is the one of its rigs: their Marker_Cue components play nothing.
Cue_Anchor :: enum u8 {Entity,Bone,Socket}

@(component,description="Plays a sound and a particle birth each time a clip of the nearest Animation at or above this entity crosses the marker, unless that Animation plays a .character, whose cues are the ones of its rig.")
Marker_Cue :: struct {
    marker:[32]u8 `mirai:"text"`,
    anchor:Cue_Anchor `mirai:"optional"`,
    at:[64]u8 `mirai:"text,optional"`, // the bone or the socket of anchor
    cue:audio.Cue,
}

CHARACTER_CUES :: 256 // rows of the cues of a .character

// A row of the cues of a set with its names hashed.
Cue_Ready :: struct {marker,at:u64,channel:core.Birth_Channel}

// The Marker_Cue components with their names hashed, by the animated entity
// each plays for and the marker, found again when the cues, the parents or the
// animations change. Rows that pass CUE_ANCESTORS parents, or under no
// Animation, play nothing.
@(storage)
Marker_Cues_Ready :: struct {
    rows:[dynamic]Marker_Cue_Ready,
    seen_cues,seen_parents,seen_animations:core.Seen,
}
Marker_Cue_Ready :: struct {animated,row:core.Entity,ready:Cue_Ready}
CUE_ANCESTORS :: 64

@(private)
marker_cue_check :: proc(row:Marker_Cue) -> bool {
    return row.marker[0]!=0 && row.anchor<=max(Cue_Anchor) && (row.anchor==.Entity || row.at[0]!=0)
}

@(private)
marker_cues_check :: proc(cues:[]Marker_Cue) -> bool {
    if len(cues)>CHARACTER_CUES {return false}
    for &row,i in cues {
        if !marker_cue_check(row) {return false}
        for &other in cues[:i] {if other.marker==row.marker {return false}}
    }
    return true
}

@(private)
marker_cue_ready :: proc(row:Marker_Cue) -> Cue_Ready {
    row:=row
    ready:=Cue_Ready{marker=base.name_hash(base.text_get(row.marker[:])),channel=audio.cue_channel(row.cue)}
    if row.anchor!=.Entity {ready.at=base.name_hash(base.text_get(row.at[:]))}
    return ready
}

@(private)
marker_cues_ready :: proc(cues:[]Marker_Cue,ready:[]Cue_Ready) {
    for row,i in cues {ready[i]=marker_cue_ready(row)}
}

// Finds again the animated entity of each Marker_Cue and hashes its names.
@(private)
marker_cues_index :: proc(index:^Marker_Cues_Ready,cues:^core.Table(Marker_Cue,.Read),animations:^core.Table(Animation,.Read),parents:^core.Table(core.Parent,.Read),problems:^core.Problems) {
    clear(&index.rows)
    if core.count(cues)>0 && reserve(&index.rows,core.count(cues))!=nil {
        core.report(problems,core.NONE,"animation.memory","out of memory for the Marker_Cue components; they play nothing until there is: free memory")
        index.seen_cues={}
        return
    }
    for row in 0..<core.count(cues) {
        e,cue:=core.entity_at(cues,row),core.at(cues,row)
        if !marker_cue_check(cue) {
            core.report(problems,e,"animation.cue","its Marker_Cue plays nothing: name its marker and, for an anchor Bone or Socket, the bone or the socket in at")
            continue
        }
        animated:=e
        for _ in 0..<CUE_ANCESTORS {
            if animated==core.NONE || core.has(animations,animated) {break}
            parent,has:=core.get(parents,animated)
            animated=parent.entity if has && parent.entity!=animated else core.NONE
        }
        if animated==core.NONE || !core.has(animations,animated) {continue}
        append(&index.rows,Marker_Cue_Ready{animated=animated,row=e,ready=marker_cue_ready(cue)})
    }
    slice.sort_by(index.rows[:],marker_cue_before)
}

@(private)
marker_cue_before :: proc(a,b:Marker_Cue_Ready) -> bool {
    return a.animated<b.animated || a.animated==b.animated && a.ready.marker<b.ready.marker
}

// Plays the cue of each marker an entity crossed in the tick, through
// audio.cue_play by that entity: the row of its .character for that name or,
// without a .character, its Marker_Cue rows of that marker.
@(step="fixed",stage="react",loops="game",after="animation_advance")
animation_cues :: proc(
    animations:^core.Table(Animation,.Read),events:core.Ref(Animation_Events),playback:core.Ref(Playback),
    characters:core.Ref(Character_Assets),skeletons:core.Ref(Skeleton_Assets),
    cues:^core.Table(Marker_Cue,.Read),index:^Marker_Cues_Ready,
    transforms:^core.Table(core.Transform,.Read),parents:^core.Table(core.Parent,.Read),
    worlds:^core.Table(core.World_Transform,.Read),sounds:^audio.Sound_Requests,births:^core.Births,
    time:core.Time,problems:^core.Problems,
) {
    if core.touched(cues,&index.seen_cues) | core.touched(parents,&index.seen_parents) | core.touched(animations,&index.seen_animations) {
        if core.count(cues)>0 || len(index.rows)>0 {marker_cues_index(index,cues,animations,parents,problems)}
    }
    if !time.playing || events.ptr==nil {return}
    for event in events.items {
        if event.kind!=.Marker {continue}
        animation,animated:=core.get(animations,event.entity)
        if !animated {continue}
        if content:=character_cached(characters,animation.asset);content!=nil {
            for ready,i in content.cues {
                if ready.marker==event.name {cue_fire(content.set.cues[i],ready,event.entity,"its .character",playback,skeletons,transforms,parents,worlds,sounds,births,problems)}
            }
            continue
        }
        rows:=index.rows[:]
        key:=Marker_Cue_Ready{animated=event.entity,ready={marker=event.name}}
        first,last:=0,len(rows)
        for first<last {
            mid:=(first+last)/2
            if marker_cue_before(rows[mid],key) {first=mid+1} else {last=mid}
        }
        for at in first..<len(rows) {
            if rows[at].animated!=event.entity || rows[at].ready.marker!=event.name {break}
            if row,has:=core.get(cues,rows[at].row);has {cue_fire(row,rows[at].ready,event.entity,"its Marker_Cue",playback,skeletons,transforms,parents,worlds,sounds,births,problems)}
        }
    }
}

@(private)
cue_fire :: proc(
    row:Marker_Cue,ready:Cue_Ready,entity:core.Entity,owner:string,playback:core.Ref(Playback),skeletons:core.Ref(Skeleton_Assets),
    transforms:^core.Table(core.Transform,.Read),parents:^core.Table(core.Parent,.Read),
    worlds:^core.Table(core.World_Transform,.Read),sounds:^audio.Sound_Requests,births:^core.Births,problems:^core.Problems,
) {
    row:=row
    pose,placed:=cue_pose(row.anchor,ready.at,entity,playback,skeletons,transforms,parents,worlds)
    if !placed {
        core.report(problems,entity,"animation.cue_anchor",
            "the cue of marker '%s' needs the entity placed, or a bone or a socket '%s' of its skeleton; fix %s",
            base.text_get(row.marker[:]),base.text_get(row.at[:]),owner)
        return
    }
    audio.cue_play(sounds,births,row.cue,ready.channel,pose,entity)
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
