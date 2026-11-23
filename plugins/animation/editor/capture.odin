package animation_editor

import "mirai:core"
import "mirai:editor"
import erender "mirai:engine/render"
import lib "mirai:std/anim"
import mm "mirai:std/math"
import anim "plugins:animation/runtime"

// The rigs of a world over the image capture takes with debug skeleton, as
// they posed in their last tick: a line from each bone to its parent, a cross
// at each joint and the axes of each socket.
@(storage)
Skeleton_Capture :: struct {provider:editor.Capture_Overlay_Provider}

SKELETON_CAPTURE_DEFAULT :: Skeleton_Capture{provider={name="skeleton",draw=skeleton_capture_draw}}

SKELETON_CAPTURE_BONE :: [4]f32{0.3,0.85,1,1}
SKELETON_CAPTURE_JOINT :: [4]f32{1,1,1,1}
SKELETON_CAPTURE_JOINT_SIZE :: f32(0.015) // m, half the cross at a joint
SKELETON_CAPTURE_SOCKET_SIZE :: f32(0.08) // m, of the axes of a socket

@(private)
skeleton_capture_draw :: proc(s:^editor.Session,w:core.World_Ref,lines:^erender.Debug_Lines) {
    playback:=core.world_storage_of(w,anim.Playback)
    transforms,parents:=core.world_table_of(w,core.Transform),core.world_table_of(w,core.Parent)
    if playback==nil || transforms==nil {return}
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
}

// The motion matching of the rigs of a world over the image capture takes with debug match: the
// trajectory the last search of each asked for and that of the row it chose (a line through
// where the body was, is and goes, with where it faces at each point ahead), and the lag of the
// root of its pose from the body.
@(storage)
Match_Capture :: struct {provider:editor.Capture_Overlay_Provider}

MATCH_CAPTURE_DEFAULT :: Match_Capture{provider={name="match",draw=match_capture_draw}}

MATCH_CAPTURE_QUERY :: [4]f32{0.2,0.9,1,1}
MATCH_CAPTURE_CANDIDATE :: [4]f32{1,0.6,0.1,1}
MATCH_CAPTURE_LAG :: [4]f32{1,0.2,0.8,1}
MATCH_CAPTURE_FACING :: f32(0.25) // m, of the line of where it faces at a point
MATCH_CAPTURE_LIFT :: f32(0.02)   // m, over the ground of the body, so the floor does not hide it

@(private)
match_capture_draw :: proc(s:^editor.Session,w:core.World_Ref,lines:^erender.Debug_Lines) {
    playback:=core.world_storage_of(w,anim.Playback)
    transforms,parents:=core.world_table_of(w,core.Transform),core.world_table_of(w,core.Parent)
    if playback==nil || transforms==nil || s.app==nil || s.app.shared==nil {return}
    for &state in playback.states {
        value,matching:=anim.animation_match(core.ref(playback),state.entity)
        if !matching {continue}
        actor,placed:=core.world_of(transforms,parents,state.entity)
        if !placed {continue}
        actor.position.y+=MATCH_CAPTURE_LIFT
        if value.lag!={} {erender.debug_line(lines,actor.position,actor.position+value.lag,MATCH_CAPTURE_LAG)}
        searched,searching:=anim.match_searched(core.ref(playback),state.entity)
        if !searching {continue}
        _,db:=match_database(s,w,&state)
        query,candidate,chosen:=match_trajectories(db,searched)
        facing:=lib.match_yaw(mm.quat_rotate(actor.rotation,mm.FORWARD))
        match_capture_trajectory(lines,actor.position,facing,query,MATCH_CAPTURE_QUERY)
        if chosen {match_capture_trajectory(lines,actor.position,facing,candidate,MATCH_CAPTURE_CANDIDATE)}
    }
}

// A trajectory of matching from where the body is, turned to where it faces.
@(private)
match_capture_trajectory :: proc(lines:^erender.Debug_Lines,at:mm.Vec3,facing:mm.Quat,t:lib.Match_Trajectory,color:[4]f32) {
    world :: proc(at:mm.Vec3,facing:mm.Quat,v:[2]f32) -> mm.Vec3 {return at+mm.quat_rotate(facing,mm.Vec3{v.x,0,v.y})}
    erender.debug_line(lines,world(at,facing,t.past),at,color)
    previous:=at
    for position,k in t.positions {
        point:=world(at,facing,position)
        erender.debug_line(lines,previous,point,color)
        erender.debug_line(lines,point,point+mm.quat_rotate(facing,mm.Vec3{t.directions[k].x,0,t.directions[k].y})*MATCH_CAPTURE_FACING,color)
        previous=point
    }
}
