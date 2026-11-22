package animation_editor

import "base:runtime"
import "core:strings"
import "mirai:core"
import "mirai:editor"
import "mirai:std/base"
import anim "plugins:animation/runtime"

// The poses of the rigs of a world as they ended their last tick, for what
// watches them along ticks (the audit of the playtest plugin).
@(storage)
Rig_Poses :: struct {provider:editor.Rig_Provider}

RIG_POSES_DEFAULT :: Rig_Poses{provider={poses=rig_poses}}

@(private)
rig_poses :: proc(s:^editor.Session,w:core.World_Ref,out:^[dynamic]editor.Rig_Pose,allocator:runtime.Allocator) {
    playback:=core.world_storage_of(w,anim.Playback)
    if playback==nil {return}
    cache:^anim.Skeleton_Assets
    if s.app!=nil && s.app.shared!=nil {cache=core.world_storage_of(core.world_ref(s.app.shared,s.info,.Shared),anim.Skeleton_Assets)}
    for &state in playback.states {
        if !state.pose_ready || state.skeleton=={} {continue}
        pose,posed:=anim.pose_space(core.ref(playback),state.entity,context.temp_allocator)
        if !posed {continue}
        bones,bones_error:=make([][3]f32,len(pose),allocator)
        names,names_error:=make([]string,len(pose),allocator)
        if bones_error!=nil || names_error!=nil {return}
        for joint,i in pose {bones[i]=joint.position}
        content:=cache!=nil && s.app.assets!=nil?anim.skeleton_content(cache,s.app.assets,s.app.allocator,state.skeleton):nil
        if content!=nil {
            // A bone of the skeleton is at its index plus one.
            for &bone,i in content.bones[:min(len(content.bones),len(names)-1)] {names[i+1]=strings.clone(base.text_get(bone.name[:]),allocator)}
        }
        clip:=state.clip>=0 && state.duration>0 && !state.ended
        append(out,editor.Rig_Pose{entity=state.entity,playing=state.playing && state.speed!=0 && (clip || state.stack>0),bones=bones,names=names})
    }
}
