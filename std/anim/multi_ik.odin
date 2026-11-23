package mirai_anim

import cmath "core:math"
import "core:math/linalg"
import math "mirai:std/math"

Multi_IK_Root_Policy :: enum u8 {Fixed,Translate}
// How a joint turns about one of its limit axes from its rest rotation: freely, between min and
// max radians, or not at all.
Multi_IK_Axis :: enum u8 {Free,Limited,Locked}
Multi_IK_Limit :: struct {kind:Multi_IK_Axis,min,max:f32}
// frame orients the limit axes X, Y and Z in the frame of the bone at rest: a knee is a hinge when
// two axes are Locked.
Multi_IK_Joint :: struct {bone:i32,stiffness:f32,preferred:math.Quat,preferred_weight:f32,frame:math.Quat,limits:[3]Multi_IK_Limit}
MULTI_IK_JOINT_DEFAULT :: Multi_IK_Joint{preferred=1,frame=1}
// A bone that reaches position by position_weight and rotation by rotation_weight. With use_pole
// the chain above it bends toward pole, a point in the space of the pose. reach softens its
// approach to full extension and stretches it past it, from the topmost joint above it.
Multi_IK_Effector :: struct {bone:i32,position:math.Vec3,rotation:math.Quat,position_weight,rotation_weight:f32,pole:math.Vec3,use_pole:bool,reach:Chain_Reach}
MULTI_IK_EFFECTOR_DEFAULT :: Multi_IK_Effector{rotation=1,position_weight=1}
MULTI_IK_EFFECTORS :: 16
// The turn of each joint of a straight chain toward its pole before the solve, in radians.
@(private) MULTI_IK_POLE_BEND :: .05
Multi_IK :: struct {
    root:i32 `mirai:"transient"`,
    root_policy:Multi_IK_Root_Policy `mirai:"optional"`,
    root_stiffness:f32 `mirai:"optional,min=0,max=1"`,
    max_root_translation:f32 `mirai:"optional,min=0"`,
    relaxation:f32 `mirai:"optional,min=0,max=1"`,
    iterations:int `mirai:"optional,min=1,max=256"`,
    tolerance:f32 `mirai:"optional,min=0"`,
    angular_tolerance:f32 `mirai:"optional,min=0,unit=rad"`,
}
MULTI_IK_DEFAULT :: Multi_IK{iterations=32,tolerance=.001,angular_tolerance=.001,relaxation=.7,max_root_translation=1}
// recomposed: the bone transforms the solve composed, its cost.
Multi_IK_Result :: struct {residual,angular_error:f32,iterations,recomposed:int,reached:bool}

// Recomposes the branch of bone and counts its bones, whose links pose_world_branch checked.
@(private)
multi_ik_refresh :: #force_inline proc "contextless" (hierarchy:Pose_Hierarchy,local,world:[]math.Transform,bone:int,root_transform:math.Transform,recomposed:^int) -> bool {
    return pose_world_branch(hierarchy,local,world,bone,root_transform,recomposed)
}

// The rotation of a bone in its parent's space that the limits allow, from `rotation`: each
// component of its rotation vector from rest about the axes of frame kept in its range, 0 when
// Locked. Fails on a limit that is out of range or not finite.
joint_limit_axes :: proc "contextless" (rotation,rest,frame:math.Quat,limits:[3]Multi_IK_Limit) -> (limited:math.Quat,ok:bool) {
    if !multi_ik_limits_valid(limits) || !anim_rotation_valid(rotation) || !anim_rotation_valid(rest) || !anim_rotation_valid(frame) {return rotation,false}
    axes:=rest*frame
    delta:=conj(axes)*rotation*frame
    if real(delta)<0 {delta=-delta}
    v:=math.Vec3{imag(delta),jmag(delta),kmag(delta)}
    length:=linalg.length(v)
    vector:=v*(2*cmath.atan2(length,real(delta))/length) if length>1e-9 else 2*v
    clamped:=vector
    for limit,i in limits {
        switch limit.kind {
        case .Free:
        case .Limited: clamped[i]=clamp(vector[i],limit.min,limit.max)
        case .Locked: clamped[i]=0
        }
    }
    if linalg.length(clamped-vector)<=1e-6 {return rotation,true}
    return linalg.normalize0(axes*math.quat_axis_angle(clamped,linalg.length(clamped))*conj(frame)),true
}
@(private)
multi_ik_limits_valid :: proc "contextless" (limits:[3]Multi_IK_Limit) -> bool {
    for limit in limits {if limit.kind>max(Multi_IK_Axis) || !anim_finite(limit.min) || !anim_finite(limit.max) || limit.min>limit.max || limit.min< -math.PI || limit.max>math.PI {return false}}
    return true
}
@(private)
multi_ik_limited :: proc "contextless" (joint:Multi_IK_Joint) -> bool {return joint.limits[0].kind!=.Free || joint.limits[1].kind!=.Free || joint.limits[2].kind!=.Free}

@(private)
multi_ik_descendant :: proc "contextless" (skeleton:Skeleton,bone,root:i32) -> bool {
    bone:=bone
    for bone>=0 {if bone==root {return true};bone=skeleton.parents[bone]}
    return false
}

// The topmost joint above bone up to root, where its chain hangs from; -1 without one.
@(private)
multi_ik_chain_root :: proc "contextless" (skeleton:Skeleton,joints:[]Multi_IK_Joint,bone,root:i32) -> i32 {
    top:=i32(-1)
    if bone==root {return top}
    for at:=skeleton.parents[bone];at>=0;at=skeleton.parents[at] {
        for joint in joints {if joint.bone==at {top=at;break}}
        if at==root {break}
    }
    return top
}
@(private)
multi_ik_reaches :: proc "contextless" (effector:Multi_IK_Effector) -> bool {return effector.reach.soft_distance!=0 || effector.reach.max_stretch!=0}
@(private)
multi_ik_joint :: proc "contextless" (joints:[]Multi_IK_Joint,bone:i32) -> (Multi_IK_Joint,bool) {
    for joint in joints {if joint.bone==bone {return joint,true}}
    return {},false
}
@(private)
multi_ik_parent_rotation :: proc "contextless" (skeleton:Skeleton,world:[]math.Transform,bone:i32,root_transform:math.Transform) -> math.Quat {
    parent:=skeleton.parents[bone]
    return world[parent].rotation if parent>=0 else root_transform.rotation
}
// The rotation of joint in its parent's space that turns its world rotation by turn, within its
// limits; clamped reports that the limits took some of it.
@(private)
multi_ik_turned :: proc "contextless" (skeleton:Skeleton,world:[]math.Transform,joint:Multi_IK_Joint,turn:math.Quat,root_transform:math.Transform) -> (rotation:math.Quat,clamped,ok:bool) {
    desired:=linalg.normalize0(conj(multi_ik_parent_rotation(skeleton,world,joint.bone,root_transform))*turn*world[joint.bone].rotation)
    if !multi_ik_limited(joint) {return desired,false,true}
    rotation,ok=joint_limit_axes(desired,skeleton.rest[joint.bone].rotation,joint.frame,joint.limits)
    return rotation,ok && math.quat_angle(rotation,desired)>1e-4,ok
}

// hierarchy is that of skeleton's parents (pose_hierarchy_prepare): a rotated joint recomposes
// only its own branch. The residual of an effector is from its goal: its target, or where its
// reach softens the target to.
multi_ik :: proc "contextless" (skeleton:Skeleton,hierarchy:Pose_Hierarchy,local,world:[]math.Transform,joints:[]Multi_IK_Joint,effectors:[]Multi_IK_Effector,settings:Multi_IK,residuals:[]f32,root_transform:math.Transform=math.TRANSFORM_IDENTITY) -> (result:Multi_IK_Result,ok:bool) {
    if !skeleton_validate(skeleton) || len(local)!=len(skeleton.rest) || len(world)!=len(local) || settings.root<0 || int(settings.root)>=len(local) || settings.root_policy>max(Multi_IK_Root_Policy) || settings.iterations<1 || settings.iterations>256 || !anim_finite(settings.tolerance) || settings.tolerance<0 || !anim_finite(settings.relaxation) || settings.relaxation<=0 || settings.relaxation>1 || !anim_finite(settings.root_stiffness) || settings.root_stiffness<0 || settings.root_stiffness>1 || !anim_finite(settings.max_root_translation) || settings.max_root_translation<0 || len(effectors)==0 || len(residuals)!=len(effectors) {return}
    if !anim_finite(settings.angular_tolerance) || settings.angular_tolerance<0 || len(hierarchy.parents)!=len(local) || raw_data(hierarchy.parents)!=raw_data(skeleton.parents) || len(hierarchy.links)!=len(local) {return}
    for joint,i in joints {
        if joint.bone<0 || int(joint.bone)>=len(local) || !multi_ik_descendant(skeleton,joint.bone,settings.root) || !anim_finite(joint.stiffness) || joint.stiffness<0 || joint.stiffness>1 || !anim_rotation_valid(joint.preferred) || !anim_finite(joint.preferred_weight) || joint.preferred_weight<0 || joint.preferred_weight>1 {return}
        for other in joints[:i] {if other.bone==joint.bone {return}}
        if !anim_rotation_valid(joint.frame) || !multi_ik_limits_valid(joint.limits) {return}
    }
    if len(effectors)>MULTI_IK_EFFECTORS {return}
    for effector in effectors {
        if effector.bone<0 || int(effector.bone)>=len(local) || !multi_ik_descendant(skeleton,effector.bone,settings.root) || !anim_vec3_valid(effector.position) || !anim_rotation_valid(effector.rotation) || !anim_finite(effector.position_weight) || effector.position_weight<0 || effector.position_weight>1 || !anim_finite(effector.rotation_weight) || effector.rotation_weight<0 || effector.rotation_weight>1 {return}
        if !anim_vec3_valid(effector.pole) || !anim_finite(effector.reach.soft_distance) || effector.reach.soft_distance<0 || !anim_finite(effector.reach.max_stretch) || effector.reach.max_stretch<0 {return}
    }
    if !pose_world(skeleton.parents,local,world,root_transform) {return}
    result.recomposed=len(local)
    // Where each effector hangs from and the position it solves for: its target, or where reach
    // softens it to, with the bones below the top stretched by the scale reach asks.
    tops:[MULTI_IK_EFFECTORS]i32;goals:[MULTI_IK_EFFECTORS]math.Vec3
    stretched:=false
    for effector,i in effectors {
        tops[i],goals[i]=multi_ik_chain_root(skeleton,joints,effector.bone,settings.root),effector.position
        if !multi_ik_reaches(effector) {continue}
        top:=tops[i]
        if top<0 {return}
        length:f32
        for at:=effector.bone;at!=top;at=skeleton.parents[at] {length+=linalg.length(world[at].position-world[skeleton.parents[at]].position)}
        adjusted,scale,valid:=chain_reach(world[top].position,effector.position,length,effector.reach)
        if !valid {return}
        goals[i]=adjusted
        if scale==1 {continue}
        for at:=effector.bone;at!=top;at=skeleton.parents[at] {
            // A bone of the chain of an earlier effector took its stretch already.
            shared:=false
            for other,j in effectors[:i] {if multi_ik_reaches(other) && tops[j]>=0 && at!=tops[j] && multi_ik_descendant(skeleton,other.bone,at) && multi_ik_descendant(skeleton,at,tops[j]) {shared=true;break}}
            if !shared {local[at].position*=scale;stretched=true}
        }
    }
    if stretched {
        if !pose_world(skeleton.parents,local,world,root_transform) {return}
        result.recomposed+=len(local)
    }
    // A straight chain has no side to bend to: its joints turn a little toward its pole first.
    for effector,i in effectors {
        top:=tops[i]
        if !effector.use_pole || top<0 || skeleton.parents[effector.bone]==top {continue}
        origin:=world[top].position
        axis,axis_ok:=anim_unit(world[effector.bone].position-origin)
        if !axis_ok {continue}
        straight:=true
        for at:=skeleton.parents[effector.bone];at!=top;at=skeleton.parents[at] {
            delta:=world[at].position-origin
            if linalg.length(delta-axis*linalg.dot(delta,axis))>1e-5 {straight=false;break}
        }
        if !straight {continue}
        pole:=effector.pole-origin
        bend:=chain_direction(pole-axis*linalg.dot(pole,axis),anim_perpendicular(axis))
        hinge:=linalg.cross(axis,bend)
        // Turning each joint about the hinge keeps the hinge in the frames of the joints below it.
        for at:=skeleton.parents[effector.bone];at>=0;at=skeleton.parents[at] {
            if joint,found:=multi_ik_joint(joints,at);found {
                rotation,_,valid:=multi_ik_turned(skeleton,world,joint,math.quat_axis_angle(hinge,MULTI_IK_POLE_BEND*(1-joint.stiffness)),root_transform)
                if !valid {return}
                local[at].rotation=rotation
            }
            if at==top {break}
        }
        if !multi_ik_refresh(hierarchy,local,world,int(top),root_transform,&result.recomposed) {return}
    }
    has_preferred:=false
    for joint in joints {if joint.preferred_weight>0 {has_preferred=true;break}}
    uniform_scale:=root_transform.scale.x>0 && abs(root_transform.scale.x-root_transform.scale.y)<=1e-5 && abs(root_transform.scale.y-root_transform.scale.z)<=1e-5
    if uniform_scale {
        for transform in local {
            s:=transform.scale
            if !(s.x>0 && abs(s.x-s.y)<=1e-5 && abs(s.y-s.z)<=1e-5) {uniform_scale=false;break}
        }
    }
    root_position:=world[settings.root].position
    for iteration in 0..<settings.iterations {
        if has_preferred {
            for joint in joints {
                if joint.preferred_weight<=0 {continue}
                local[joint.bone].rotation=math.quat_slerp(local[joint.bone].rotation,joint.preferred,joint.preferred_weight*settings.relaxation/f32(settings.iterations))
            }
            if !multi_ik_refresh(hierarchy,local,world,int(settings.root),root_transform,&result.recomposed) {return}
        }
        if settings.root_policy==.Translate {
            correction:math.Vec3;total:f32
            for effector,i in effectors {correction+=(goals[i]-world[effector.bone].position)*effector.position_weight;total+=effector.position_weight}
            if total>0 {
                desired:=world[settings.root].position+correction/total*settings.relaxation*(1-settings.root_stiffness)
                offset:=desired-root_position;distance:=linalg.length(offset)
                if distance>settings.max_root_translation {offset*=settings.max_root_translation/distance}
                parent:=skeleton.parents[settings.root]
                parent_pose:=world[parent] if parent>=0 else root_transform
                local[settings.root].position+=math.transform_inverse_vector(parent_pose,root_position+offset-world[settings.root].position)
                if !multi_ik_refresh(hierarchy,local,world,int(settings.root),root_transform,&result.recomposed) {return}
            }
        }
        for effector,e in effectors {
            bone:=skeleton.parents[effector.bone] if effector.bone!=settings.root else i32(-1)
            if uniform_scale {
                // With uniform scale, turning a joint rotates the effector position rigidly around
                // it; one branch refresh at the highest turned joint updates the chain for the rest.
                eff_pos:=world[effector.bone].position
                highest:=i32(-1)
                for bone>=0 {
                    for joint in joints {
                        if joint.bone!=bone {continue}
                        from,from_ok:=anim_unit(eff_pos-world[bone].position)
                        to,to_ok:=anim_unit(goals[e]-world[bone].position)
                        if from_ok && to_ok && linalg.dot(from,to)<1-1e-10 {
                            change:=math.quat_slerp(1,anim_between(from,to),settings.relaxation*effector.position_weight*(1-joint.stiffness))
                            parent:=skeleton.parents[bone]
                            parent_rot:=world[parent].rotation if parent>=0 else root_transform.rotation
                            old_world:=world[bone].rotation
                            desired:=linalg.normalize0(conj(parent_rot)*change*old_world)
                            if multi_ik_limited(joint) {desired,ok=joint_limit_axes(desired,skeleton.rest[bone].rotation,joint.frame,joint.limits);if !ok {return result,false}}
                            local[bone].rotation=desired
                            world_turn:=linalg.normalize0(parent_rot*desired)*conj(old_world)
                            eff_pos=world[bone].position+math.quat_rotate(world_turn,eff_pos-world[bone].position)
                            highest=bone
                        }
                        break
                    }
                    if bone==settings.root {break};bone=skeleton.parents[bone]
                }
                if highest>=0 {
                    if !multi_ik_refresh(hierarchy,local,world,int(highest),root_transform,&result.recomposed) {return result,false}
                }
            } else {
                for bone>=0 {
                    for joint in joints {
                        if joint.bone!=bone {continue}
                        from,from_ok:=anim_unit(world[effector.bone].position-world[bone].position)
                        to,to_ok:=anim_unit(goals[e]-world[bone].position)
                        if from_ok && to_ok && linalg.dot(from,to)<1-1e-10 {
                            change:=math.quat_slerp(1,anim_between(from,to),settings.relaxation*effector.position_weight*(1-joint.stiffness))
                            parent:=skeleton.parents[bone]
                            desired:=linalg.normalize0(conj(world[parent].rotation if parent>=0 else root_transform.rotation)*change*world[bone].rotation)
                            if multi_ik_limited(joint) {desired,ok=joint_limit_axes(desired,skeleton.rest[bone].rotation,joint.frame,joint.limits);if !ok {return result,false}}
                            local[bone].rotation=desired
                            if !multi_ik_refresh(hierarchy,local,world,int(bone),root_transform,&result.recomposed) {return result,false}
                        }
                        break
                    }
                    if bone==settings.root {break};bone=skeleton.parents[bone]
                }
            }
            // The chain turns about the line from its top to the effector, which keeps the
            // effector in place, until its bend faces the pole; a turn its limits clamp waits.
            if top:=tops[e];effector.use_pole && top>=0 {
                origin:=world[top].position
                axis,axis_ok:=anim_unit(world[effector.bone].position-origin)
                middle:math.Vec3;pole:=effector.pole-origin
                for at:=skeleton.parents[effector.bone];at!=top;at=skeleton.parents[at] {middle+=world[at].position-origin}
                a,a_ok:=anim_unit(middle-axis*linalg.dot(middle,axis))
                b,b_ok:=anim_unit(pole-axis*linalg.dot(pole,axis))
                joint,_:=multi_ik_joint(joints,top)
                if axis_ok && a_ok && b_ok && joint.stiffness<1 {
                    angle:=cmath.atan2(linalg.dot(axis,linalg.cross(a,b)),linalg.dot(a,b))*settings.relaxation*(1-joint.stiffness)
                    if abs(angle)>1e-5 {
                        rotation,clamped,valid:=multi_ik_turned(skeleton,world,joint,math.quat_axis_angle(axis,angle),root_transform)
                        if !valid {return result,false}
                        if !clamped {
                            local[top].rotation=rotation
                            if !multi_ik_refresh(hierarchy,local,world,int(top),root_transform,&result.recomposed) {return result,false}
                        }
                    }
                }
            }
            if effector.rotation_weight>0 {
                parent:=skeleton.parents[effector.bone]
                desired:=linalg.normalize0(conj(world[parent].rotation if parent>=0 else root_transform.rotation)*effector.rotation)
                stiffness:f32
                for joint in joints {if joint.bone==effector.bone {stiffness=joint.stiffness;if multi_ik_limited(joint) {desired,ok=joint_limit_axes(desired,skeleton.rest[effector.bone].rotation,joint.frame,joint.limits);if !ok {return result,false}};break}}
                local[effector.bone].rotation=math.quat_slerp(local[effector.bone].rotation,desired,effector.rotation_weight*settings.relaxation*(1-stiffness))
                if !multi_ik_refresh(hierarchy,local,world,int(effector.bone),root_transform,&result.recomposed) {return result,false}
            }
        }
        result.residual,result.angular_error=0,0
        for effector,i in effectors {
            positional:=linalg.length(world[effector.bone].position-goals[i])*effector.position_weight
            rotational:=math.quat_angle(world[effector.bone].rotation,effector.rotation)
            residuals[i]=positional
            if !anim_finite(residuals[i]) {return result,false}
            result.residual=max(result.residual,residuals[i])
            result.angular_error=max(result.angular_error,rotational*effector.rotation_weight)
        }
        result.iterations=iteration+1;result.reached=result.residual<=settings.tolerance && result.angular_error<=settings.angular_tolerance
        if result.reached {break}
    }
    return result,true
}
