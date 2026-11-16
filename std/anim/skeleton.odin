package mirai_anim

import cmath "core:math"
import "core:math/linalg"
import math "mirai:std/math"

Skeleton :: struct {
    parents:[]i32,
    names:[]u64,
    rest:[]math.Transform,
}

Pose_Link :: struct {first_child,next_sibling:i32}
Pose_Hierarchy :: struct {parents:[]i32,links:[]Pose_Link}

pose_hierarchy_prepare :: proc "contextless" (parents:[]i32,links:[]Pose_Link) -> (hierarchy:Pose_Hierarchy,ok:bool) {
    if len(parents)==0 || len(parents)!=len(links) || len(parents)>int(max(i32)) {return}
    if inertial_buffers_overlap(parents,links) {return}
    for parent,i in parents {if parent< -1 || int(parent)>=i {return}}
    for &link in links {link={-1,-1}}
    #reverse for parent,i in parents {
        if parent<0 {continue}
        links[i].next_sibling=links[parent].first_child
        links[parent].first_child=i32(i)
    }
    return {parents,links},true
}

Bone_Tracks :: struct {position,rotation,scale:int}
BONE_TRACKS_NONE :: Bone_Tracks{-1,-1,-1}

@(private)
anim_finite :: #force_inline proc "contextless" (v:f32) -> bool {return abs(v)<=max(f32)}
@(private)
anim_vec3_valid :: #force_inline proc "contextless" (v:math.Vec3) -> bool {
    return anim_finite(v.x) && anim_finite(v.y) && anim_finite(v.z)
}
@(private)
anim_rotation_valid :: #force_inline proc "contextless" (q:math.Quat) -> bool {
    return abs(linalg.dot(q,q)-1)<0.002
}
@(private)
anim_transform_valid :: #force_inline proc "contextless" (t:math.Transform) -> bool {
    return anim_vec3_valid(t.position) && anim_vec3_valid(t.scale) && anim_rotation_valid(t.rotation)
}
@(private)
anim_pose_valid :: proc "contextless" (pose:[]math.Transform) -> bool {
    for t in pose {if !anim_transform_valid(t) {return false}}
    return true
}

skeleton_validate :: proc "contextless" (s:Skeleton) -> bool {
    if len(s.rest)==0 || len(s.parents)!=len(s.rest) || len(s.names)!=len(s.rest) {return false}
    for parent,i in s.parents {if parent< -1 || int(parent)>=i {return false}}
    return anim_pose_valid(s.rest)
}

skeleton_bind :: proc "contextless" (lib:^Library,clip:Clip,s:Skeleton,out:[]Bone_Tracks) -> bool {
    if !skeleton_validate(s) || len(out)!=len(s.rest) || !clip_valid(lib,clip) {return false}
    for &binding in out {binding=BONE_TRACKS_NONE}
    data:=clip_data(lib,clip)
    for track,i in clip_tracks(lib,clip) {
        if track.slot!=0 || track.property==.Float || track.property==.Vector {continue}
        for name,bone in s.names {
            if name!=track.target {continue}
            index:=int(data.first_track)+i
            switch track.property {
            case .Position: out[bone].position=index
            case .Rotation: out[bone].rotation=index
            case .Scale: out[bone].scale=index
            case .Float,.Vector:
            }
            break
        }
    }
    return true
}

skeleton_sample :: proc "contextless" (lib:^Library,bindings:[]Bone_Tracks,rest:[]math.Transform,time:f32,out:[]math.Transform) -> bool {
    if len(bindings)!=len(rest) || len(out)!=len(rest) || !anim_finite(time) || !anim_pose_valid(rest) {return false}
    for binding in bindings {
        indices:=[3]int{binding.position,binding.rotation,binding.scale}
        for index in indices {if index< -1 || index>=lib.track_count || index>=len(lib.tracks) {return false}}
    }
    for binding,i in bindings {
        value:=rest[i]
        if binding.position>=0 {value.position=clip_evaluate(lib,lib.tracks[binding.position],time).xyz}
        if binding.rotation>=0 {value.rotation=linalg.normalize0(vec4_quat(clip_evaluate(lib,lib.tracks[binding.rotation],time)))}
        if binding.scale>=0 {value.scale=clip_evaluate(lib,lib.tracks[binding.scale],time).xyz}
        if !anim_transform_valid(value) {return false}
        out[i]=value
    }
    return true
}

skeleton_world :: proc "contextless" (s:Skeleton,local:[]math.Transform,out:[]math.Transform,root_transform:math.Transform=math.TRANSFORM_IDENTITY) -> bool {
    if !skeleton_validate(s) {return false}
    return pose_world(s.parents,local,out,root_transform)
}

pose_world :: proc "contextless" (parents:[]i32,local:[]math.Transform,out:[]math.Transform,root_transform:math.Transform=math.TRANSFORM_IDENTITY) -> bool {
    if len(local)==0 || len(parents)!=len(local) || len(out)!=len(local) || !anim_transform_valid(root_transform) {return false}
    if raw_data(local)!=raw_data(out) && inertial_buffers_overlap(local,out) {return false}
    for parent,i in parents {
        if parent< -1 || int(parent)>=i || !anim_transform_valid(local[i]) {return false}
        out[i]=math.transform_compose(root_transform,local[i]) if parent<0 else math.transform_compose(out[parent],local[i])
        if !anim_transform_valid(out[i]) {return false}
    }
    return true
}

pose_world_branch :: proc "contextless" (hierarchy:Pose_Hierarchy,local,world:[]math.Transform,bone:int,root_transform:math.Transform=math.TRANSFORM_IDENTITY) -> bool {
    count:=len(hierarchy.parents)
    if count==0 || len(hierarchy.links)!=count || len(local)!=count || len(world)!=count || bone<0 || bone>=count || !anim_transform_valid(root_transform) {return false}
    if raw_data(local)!=raw_data(world) && inertial_buffers_overlap(local,world) {return false}
    at:=bone
    for _ in 0..<count {
        parent:=hierarchy.parents[at]
        if parent< -1 || int(parent)>=at || !anim_transform_valid(local[at]) {return false}
        basis:=root_transform
        if parent>=0 {basis=world[parent];if !anim_transform_valid(basis) {return false}}
        world[at]=math.transform_compose(basis,local[at])
        if !anim_transform_valid(world[at]) {return false}
        child:=hierarchy.links[at].first_child
        if child>=0 {
            if int(child)<=at || int(child)>=count || hierarchy.parents[child]!=i32(at) {return false}
            at=int(child);continue
        }
        if child< -1 {return false}
        for at!=bone {
            sibling:=hierarchy.links[at].next_sibling
            parent=hierarchy.parents[at]
            if parent<0 || int(parent)>=at {return false}
            if sibling>=0 {
                if int(sibling)<=at || int(sibling)>=count || hierarchy.parents[sibling]!=parent {return false}
                at=int(sibling);break
            }
            if sibling< -1 {return false}
            at=int(parent)
        }
        if at==bone {return true}
    }
    return false
}

skeleton_palette :: proc "contextless" (world:[]math.Transform,inverse_bind:[]math.Mat4,out:[]math.Mat4) -> bool {
    if len(world)!=len(inverse_bind) || len(out)!=len(world) || !anim_pose_valid(world) {return false}
    for m in inverse_bind {for r in 0..<4 {for c in 0..<4 {if !anim_finite(m[r,c]) {return false}}}}
    for transform,i in world {out[i]=math.transform_matrix(transform)*inverse_bind[i]}
    return true
}

skeleton_socket :: proc "contextless" (world:[]math.Transform,bone:int,offset:math.Transform) -> (math.Transform,bool) {
    if bone<0 || bone>=len(world) || !anim_transform_valid(offset) || !anim_transform_valid(world[bone]) {return math.TRANSFORM_IDENTITY,false}
    return math.transform_compose(world[bone],offset),true
}

pose_mask_branch :: proc "contextless" (s:Skeleton,bone:int,weight:f32,out:[]f32) -> bool {
    if !skeleton_validate(s) || bone<0 || bone>=len(s.parents) || len(out)!=len(s.parents) || !anim_finite(weight) {return false}
    for i in 0..<len(out) {
        at:=i
        for at>bone {at=int(s.parents[at])}
        out[i]=math.saturate(weight) if at==bone else 0
    }
    return true
}

@(private)
anim_unit :: proc "contextless" (v:math.Vec3) -> (math.Vec3,bool) {
    length:=linalg.length(v)
    if !(length>1e-7) || !anim_finite(length) {return {},false}
    return v/length,true
}

@(private)
anim_perpendicular :: proc "contextless" (axis:math.Vec3) -> math.Vec3 {
    other:=math.Vec3{1,0,0} if abs(axis.x)<0.7 else math.Vec3{0,1,0}
    return linalg.normalize0(linalg.cross(axis,other))
}

@(private)
anim_between :: proc "contextless" (from,to:math.Vec3) -> math.Quat {
    dot:=linalg.dot(from,to)
    if dot< -0.999999 {return math.quat_axis_angle(anim_perpendicular(from),cmath.PI)}
    v:=linalg.cross(from,to)
    return linalg.normalize0(quaternion(w=1+dot,x=v.x,y=v.y,z=v.z))
}
