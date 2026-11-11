package mirai_anim

import "core:math/linalg"
import math "mirai:std/math"

// Keeps the crotch of a retargeted body off its floor as the source's keeps off its own: while
// the pelvis of the source is below its rest, the hips of the target stand at least the share of
// their rest height that the hips of the source keep of theirs, so a crouch reaches the floor
// when the source's does. The floor of a body is its lowest foot or toe joint at rest and its
// hips the mean of its hip joints.
Retarget_Crotch :: struct {
    source_up,target_up:math.Vec3,
    source_pelvis,target_pelvis:i32, // -1: nothing to keep
    source_rest,target_rest:f32, // heights of the pelvises at rest
    scale:f32, // the rest height of the hips of the target over that of the source, both over their floors
    legs:[2][3]i32, // hip, knee and foot of each leg of the target, which keep their feet; -1: none
}
RETARGET_CROTCH_NONE :: Retarget_Crotch{source_pelvis=-1,target_pelvis=-1,scale=1,legs={{-1,-1,-1},{-1,-1,-1}}}

Retarget_Error :: enum u8 {
    None,
    Invalid, // a skeleton, a body, a buffer or a value that is not valid
    Hips_Height, // the pelvis or the hips of a skeleton are not above its feet at rest
}

// Prepares what retarget_crotch_pose keeps, from both skeletons and their bodies: nothing unless
// both have a pelvis, hips and a foot or toe. source_world and target_world receive the poses at
// rest.
retarget_crotch_prepare :: proc "contextless" (source,target:Skeleton,source_body,target_body:Body_Map,source_world,target_world:[]math.Transform) -> (crotch:Retarget_Crotch,error:Retarget_Error) {
    crotch=RETARGET_CROTCH_NONE
    if !skeleton_validate(source) || !skeleton_validate(target) || len(source_world)!=len(source.rest) || len(target_world)!=len(target.rest) {return crotch,.Invalid}
    if !body_map_valid(source_body,len(source.rest)) || !body_map_valid(target_body,len(target.rest)) {return crotch,.Invalid}
    if !pose_world(source.parents,source.rest,source_world) || !pose_world(target.parents,target.rest,target_world) {return crotch,.Invalid}
    // The pelvis, the hips and the floor of a body along its up.
    heights :: proc "contextless" (map_:Body_Map,world:[]math.Transform) -> (up:math.Vec3,pelvis,hips,floor:f32,found:bool) {
        up=anim_unit(map_.up) or_return
        bone:=map_.bones[.Pelvis]
        if bone<0 {return}
        pelvis=linalg.dot(world[bone].position,up)
        count:f32
        for part in ([2]Body_Part{.Hip_L,.Hip_R}) {if hip:=map_.bones[part];hip>=0 {hips+=linalg.dot(world[hip].position,up);count+=1}}
        floor=max(f32)
        for part in ([4]Body_Part{.Foot_L,.Foot_R,.Toe_L,.Toe_R}) {if foot:=map_.bones[part];foot>=0 {floor=min(floor,linalg.dot(world[foot].position,up))}}
        if count==0 || floor==max(f32) {return}
        return up,pelvis,hips/count,floor,true
    }
    source_up,source_pelvis,source_hips,source_floor,source_ok:=heights(source_body,source_world)
    target_up,target_pelvis,target_hips,target_floor,target_ok:=heights(target_body,target_world)
    if !source_ok || !target_ok {return crotch,.None}
    if !anim_finite(source_pelvis-source_floor) || !anim_finite(target_pelvis-target_floor) || !anim_finite(source_hips-source_floor) || !anim_finite(target_hips-target_floor) {return crotch,.Invalid}
    reach:=1e-3*body_height(source_body,source_world)
    if source_pelvis-source_floor<=reach || target_pelvis-target_floor<=reach || source_hips-source_floor<=reach || target_hips-target_floor<=reach {return crotch,.Hips_Height}
    crotch.source_up,crotch.target_up=source_up,target_up
    crotch.source_pelvis,crotch.target_pelvis=source_body.bones[.Pelvis],target_body.bones[.Pelvis]
    crotch.source_rest,crotch.target_rest=source_pelvis,target_pelvis
    crotch.scale=(target_hips-target_floor)/(source_hips-source_floor)
    for parts,i in ([2][3]Body_Part{{.Hip_L,.Knee_L,.Foot_L},{.Hip_R,.Knee_R,.Foot_R}}) {
        leg:=[3]i32{target_body.bones[parts[0]],target_body.bones[parts[1]],target_body.bones[parts[2]]}
        if body_is_ancestor(target.parents,crotch.target_pelvis,leg[0]) && body_is_ancestor(target.parents,leg[0],leg[1]) && body_is_ancestor(target.parents,leg[1],leg[2]) && leg[0]!=leg[1] && leg[1]!=leg[2] {crotch.legs[i]=leg}
    }
    return crotch,.None
}

// Raises the pelvis of a pose of the target to what crotch asks for the pose of the source, and
// turns its legs so that its feet stay where they were. local is the pose and world receives it
// in the space of the roots; source_world is the pose of the source in the space of its roots.
// False, with the pose partly changed, for buffers or values that are not valid.
retarget_crotch_pose :: proc "contextless" (target:Skeleton,crotch:Retarget_Crotch,source_world,local,world:[]math.Transform) -> bool {
    n:=len(target.rest)
    if !skeleton_validate(target) || len(local)!=n || len(world)!=n || !anim_pose_valid(source_world) || !pose_world(target.parents,local,world) {return false}
    if crotch.source_pelvis<0 && crotch.target_pelvis<0 {return true}
    if int(crotch.source_pelvis)>=len(source_world) || crotch.source_pelvis<0 || crotch.target_pelvis<0 || int(crotch.target_pelvis)>=n || !body_up_valid(crotch.source_up) || !body_up_valid(crotch.target_up) || !anim_finite(crotch.source_rest) || !anim_finite(crotch.target_rest) || !anim_finite(crotch.scale) || crotch.scale<=0 {return false}
    for leg in crotch.legs {
        if leg[0]<0 {continue}
        for bone in leg {if bone<0 || int(bone)>=n {return false}}
        if !body_is_ancestor(target.parents,leg[0],leg[1]) || !body_is_ancestor(target.parents,leg[1],leg[2]) || leg[0]==leg[1] || leg[1]==leg[2] {return false}
    }
    lowered:=linalg.dot(source_world[crotch.source_pelvis].position,crotch.source_up)-crotch.source_rest
    if lowered>=0 {return true}
    raise:=crotch.target_rest+lowered*crotch.scale-linalg.dot(world[crotch.target_pelvis].position,crotch.target_up)
    if !(raise>0) {return anim_finite(raise)}
    feet:[2]math.Vec3
    for leg,i in crotch.legs {if leg[0]>=0 {feet[i]=world[leg[2]].position}}
    edit_move(target.parents,local,world,crotch.target_pelvis,crotch.target_up*raise) or_return
    for leg,i in crotch.legs {
        if leg[0]<0 {continue}
        edit_limb_ik(target.parents,local,world,leg[0],leg[1],leg[2],feet[i]) or_return
    }
    return anim_pose_valid(local)
}
