package mirai_anim

import cmath "core:math"
import "core:math/linalg"
import math "mirai:std/math"

Chain_Limit :: struct {min_bend,max_bend:f32}
CHAIN_LIMIT_FREE :: Chain_Limit{0,cmath.PI}
Chain_IK :: struct {target,pole:math.Vec3,use_pole:bool,iterations:int,tolerance:f32}
CHAIN_IK_DEFAULT :: Chain_IK{iterations=24,tolerance=0.001}
Chain_IK_Result :: struct {error:f32,iterations:int,reached:bool}

@(private)
chain_buffers_overlap :: proc "contextless" (a,b:[]math.Vec3) -> bool {
    if len(a)==0 || len(b)==0 {return false}
    first,second:=uintptr(raw_data(a)),uintptr(raw_data(b))
    return second-first<uintptr(len(a))*size_of(math.Vec3) if second>=first else first-second<uintptr(len(b))*size_of(math.Vec3)
}

@(private)
chain_direction :: proc "contextless" (value,fallback:math.Vec3) -> math.Vec3 {
    result,ok:=anim_unit(value)
    if !ok {result,ok=anim_unit(fallback)}
    return result if ok else math.Vec3{1,0,0}
}

@(private)
chain_limit_direction :: proc "contextless" (incoming,outgoing,pole:math.Vec3,limit:Chain_Limit) -> math.Vec3 {
    cosine:=clamp(linalg.dot(incoming,outgoing),-1,1)
    angle:=cmath.acos(cosine)
    bounded:=clamp(angle,limit.min_bend,limit.max_bend)
    if abs(bounded-angle)<1e-6 {return outgoing}
    tangent,ok:=anim_unit(outgoing-incoming*cosine)
    if !ok {
        tangent,ok=anim_unit(pole-incoming*linalg.dot(pole,incoming))
        if !ok {tangent=anim_perpendicular(incoming)}
    }
    sine,cos:=cmath.sincos(bounded)
    return incoming*cos+tangent*sine
}

chain_ik :: proc "contextless" (points:[]math.Vec3,lengths:[]f32,limits:[]Chain_Limit,settings:Chain_IK,out:[]math.Vec3) -> (result:Chain_IK_Result,ok:bool) {
    count:=len(points)
    if count<2 || len(out)!=count || len(lengths)!=count-1 || (len(limits)!=0 && len(limits)!=count-2) || !anim_vec3_valid(settings.target) || !anim_vec3_valid(settings.pole) || settings.iterations<1 || settings.iterations>256 || !anim_finite(settings.tolerance) || settings.tolerance<0 {return}
    if raw_data(points)!=raw_data(out) && chain_buffers_overlap(points,out) {return}
    for point in points {if !anim_vec3_valid(point) {return}}
    reach:f64
    for length in lengths {if !anim_finite(length) || length<=1e-6 {return};reach+=f64(length)}
    if reach>f64(max(f32)) {return}
    for limit in limits {if !anim_finite(limit.min_bend) || !anim_finite(limit.max_bend) || limit.min_bend<0 || limit.min_bend>limit.max_bend || limit.max_bend>cmath.PI {return}}
    copy(out,points)
    root:=points[0]
    target_distance:=linalg.length(settings.target-root)
    if !anim_finite(target_distance) {return}
    if target_distance>=f32(reach) && len(limits)==0 {
        direction:=chain_direction(settings.target-root,out[1]-root)
        for i in 1..<count {out[i]=out[i-1]+direction*lengths[i-1]}
    } else {
        if settings.use_pole {
            axis:=chain_direction(settings.target-root,out[count-1]-root)
            bend:=settings.pole-root
            bend-=axis*linalg.dot(axis,bend)
            bend=chain_direction(bend,anim_perpendicular(axis))
            collinear:=true
            for i in 1..<count-1 {
                delta:=out[i]-root
                if linalg.length(delta-axis*linalg.dot(delta,axis))>1e-5 {collinear=false;break}
            }
            if collinear {for i in 1..<count-1 {out[i]+=bend*(lengths[i-1]*0.05)}}
        }
        for iteration in 0..<settings.iterations {
            out[count-1]=settings.target
            for i:=count-2;i>=0;i-=1 {
                direction:=chain_direction(out[i]-out[i+1],root-settings.target)
                out[i]=out[i+1]+direction*lengths[i]
            }
            out[0]=root
            for i in 1..<count {
                direction:=chain_direction(out[i]-out[i-1],settings.target-root)
                if i>1 && len(limits)>0 {
                    incoming:=chain_direction(out[i-1]-out[i-2],direction)
                    direction=chain_limit_direction(incoming,direction,settings.pole-out[i-1],limits[i-2])
                }
                out[i]=out[i-1]+direction*lengths[i-1]
            }
            if settings.use_pole {
                axis,axis_ok:=anim_unit(out[count-1]-root)
                if axis_ok {
                    pole:=settings.pole-root
                    pole-=axis*linalg.dot(pole,axis)
                    middle:math.Vec3
                    for i in 1..<count-1 {middle+=out[i]-root}
                    middle-=axis*linalg.dot(middle,axis)
                    a,a_ok:=anim_unit(middle)
                    b,b_ok:=anim_unit(pole)
                    if a_ok && b_ok {
                        angle:=cmath.atan2(linalg.dot(axis,linalg.cross(a,b)),linalg.dot(a,b))
                        turn:=math.quat_axis_angle(axis,angle)
                        for i in 1..<count-1 {out[i]=root+math.quat_rotate(turn,out[i]-root)}
                    }
                }
            }
            result.iterations=iteration+1
            if linalg.length(out[count-1]-settings.target)<=settings.tolerance {break}
        }
    }
    for point in out {if !anim_vec3_valid(point) {return result,false}}
    result.error=linalg.length(out[count-1]-settings.target)
    result.reached=result.error<=settings.tolerance
    return result,anim_finite(result.error)
}

skeleton_chain_ik :: proc "contextless" (
    skeleton:Skeleton,local,world:[]math.Transform,bones:[]i32,limits:[]Chain_Limit,settings:Chain_IK,
    points,solved:[]math.Vec3,lengths:[]f32,weight:f32=1,root_transform:math.Transform=math.TRANSFORM_IDENTITY,reach:Chain_Reach={},
) -> (result:Chain_IK_Result,ok:bool) {
    count:=len(bones)
    if count<2 || len(points)!=count || len(solved)!=count || len(lengths)!=count-1 || chain_buffers_overlap(points,solved) || !anim_finite(weight) || !skeleton_validate(skeleton) || len(local)!=len(skeleton.rest) || len(world)!=len(local) {return}
    for bone,i in bones {
        if bone<0 || int(bone)>=len(local) || (i>0 && skeleton.parents[bone]!=bones[i-1]) {return}
    }
    if !pose_world(skeleton.parents,local,world,root_transform) {return}
    for bone,i in bones {points[i]=world[bone].position;if i>0 {lengths[i-1]=linalg.length(points[i]-points[i-1])}}
    solve_settings:=settings;stretch:f32=1
    if reach.soft_distance!=0 || reach.max_stretch!=0 {
        length:f32;for value in lengths {length+=value}
        adjusted,scale,valid:=chain_reach(points[0],settings.target,length,reach)
        if !valid {return}
        solve_settings.target=adjusted;stretch=scale
        for &value in lengths {value*=stretch}
    }
    result,ok=chain_ik(points,lengths,limits,solve_settings,solved)
    if !ok {return}
    weight:=math.saturate(weight)
    end_rotation:=world[bones[count-1]].rotation
    for bone,i in bones[:count-1] {
        if i>0 && stretch!=1 {local[bone].position*=1+(stretch-1)*weight}
        old_direction:=chain_direction(points[i+1]-points[i],{})
        new_direction:=chain_direction(solved[i+1]-solved[i],old_direction)
        turn:=anim_between(old_direction,new_direction)
        target_rotation:=linalg.normalize0(turn*world[bone].rotation)
        parent:=skeleton.parents[bone]
        parent_rotation:=root_transform.rotation if parent<0 else world[parent].rotation
        local[bone].rotation=math.quat_slerp(local[bone].rotation,linalg.normalize0(conj(parent_rotation)*target_rotation),weight)
        world[bone]=math.transform_compose(root_transform if parent<0 else world[parent],local[bone])
    }
    end:=bones[count-1]
    parent:=skeleton.parents[end]
    if stretch!=1 {local[end].position*=1+(stretch-1)*weight}
    local[end].rotation=math.quat_slerp(local[end].rotation,linalg.normalize0(conj(world[parent].rotation)*end_rotation),weight)
    if !pose_world(skeleton.parents,local,world,root_transform) {return result,false}
    result.error=linalg.length(world[end].position-settings.target)
    result.reached=result.error<=settings.tolerance
    return result,anim_finite(result.error)
}
