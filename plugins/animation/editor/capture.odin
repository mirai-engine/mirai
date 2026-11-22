package animation_editor

import "mirai:core"
import "mirai:editor"
import erender "mirai:engine/render"
import lib "mirai:std/anim"
import mm "mirai:std/math"
import anim "plugins:animation/runtime"

// The rigs of a world over the image capture takes with debug Skeleton, as
// they posed in their last tick: a line from each bone to its parent, a cross
// at each joint and the axes of each socket.
@(storage)
Skeleton_Capture :: struct {provider:editor.Capture_Overlay_Provider}

SKELETON_CAPTURE_DEFAULT :: Skeleton_Capture{provider={draw=skeleton_capture_draw}}

SKELETON_CAPTURE_BONE :: [4]f32{0.3,0.85,1,1}
SKELETON_CAPTURE_JOINT :: [4]f32{1,1,1,1}
SKELETON_CAPTURE_JOINT_SIZE :: f32(0.015) // m, half the cross at a joint
SKELETON_CAPTURE_SOCKET_SIZE :: f32(0.08) // m, of the axes of a socket

@(private)
skeleton_capture_draw :: proc(s:^editor.Session,w:core.World_Ref,shown:editor.Api_Capture_Debug,lines:^erender.Debug_Lines) -> editor.Api_Capture_Debug {
    if .Skeleton not_in shown {return {}}
    playback:=core.world_storage_of(w,anim.Playback)
    transforms,parents:=core.world_table_of(w,core.Transform),core.world_table_of(w,core.Parent)
    if playback==nil || transforms==nil {return {.Skeleton}}
    cache:^anim.Skeleton_Assets
    if s.app!=nil && s.app.shared!=nil {cache=core.world_storage_of(core.world_ref(s.app.shared,s.info,.Shared),anim.Skeleton_Assets)}
    for &state in playback.states {
        if !state.pose_ready || state.skeleton=={} {continue}
        actor,placed:=core.world_of(transforms,parents,state.entity)
        pose,posed:=anim.pose_space(core.ref(playback),state.entity,context.temp_allocator)
        if !placed || !posed {continue}
        bones:=anim.playing_topology(&state).parents[:]
        if len(bones)!=len(pose) {continue}
        for &joint in pose {joint=mm.transform_compose(actor,joint)}
        for parent,bone in bones {
            if bone==0 {continue}
            at:=pose[bone].position
            if parent>0 && int(parent)<len(pose) {erender.debug_line(lines,pose[parent].position,at,SKELETON_CAPTURE_BONE)}
            for axis in 0..<3 {
                step:[3]f32
                step[axis]=SKELETON_CAPTURE_JOINT_SIZE
                erender.debug_line(lines,at-step,at+step,SKELETON_CAPTURE_JOINT)
            }
        }
        content:=cache!=nil && s.app.assets!=nil?anim.skeleton_content(cache,s.app.assets,s.app.allocator,state.skeleton):nil
        if content==nil {continue}
        for &socket in content.sockets {
            bone:=anim.skeleton_bone_find(content.bones,content.body,anim.Bone_Ref{path=socket.bone})
            if bone<0 {continue}
            if placed,found:=lib.skeleton_socket(pose,bone+1,socket.offset);found {
                erender.debug_axes(lines,mm.transform_matrix(placed),SKELETON_CAPTURE_SOCKET_SIZE)
            }
        }
    }
    return {.Skeleton}
}
