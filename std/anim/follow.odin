package mirai_anim

import "core:math/linalg"
import math "mirai:std/math"

// How a bone of a skeleton follows the pose of another skeleton: the bone of
// the leader whose pose it takes (-1: it keeps its own), and whether its parent
// follows the parent of that bone, so that its local transform is the leader's
// as is; otherwise its place in the world is the leader's.
Follow_Bone :: struct {leader:i32,local:bool}

// Pairs each bone of follower with the bone of leader of its name, or of its
// path when a name repeats in either skeleton; a name or path 0 pairs with
// nothing. names are the hashes of the names of the bones, the paths those
// of the skeletons. Gives how many bones follow.
follow_prepare :: proc "contextless" (follower,leader:Skeleton,follower_names,leader_names:[]u64,out:[]Follow_Bone) -> (shared:int,ok:bool) {
    if len(follower.parents)!=len(out) || len(follower.names)!=len(out) || len(follower_names)!=len(out) || len(leader.names)!=len(leader.parents) || len(leader_names)!=len(leader.parents) {return 0,false}
    for parent,i in follower.parents {if parent< -1 || int(parent)>=i {return 0,false}}
    for parent,i in leader.parents {if parent< -1 || int(parent)>=i {return 0,false}}
    unique :: proc "contextless" (names:[]u64,name:u64) -> (at:int,count:int) {
        at=-1
        for value,i in names {if value==name {if count==0 {at=i};count+=1}}
        return
    }
    for &bone,i in out {
        bone={leader=-1}
        name:=follower_names[i]
        if name!=0 {
            if mine,count:=unique(follower_names,name);count==1 && mine==i {
                if theirs,found:=unique(leader_names,name);found==1 {bone.leader=i32(theirs);continue}
            }
        }
        if path:=follower.names[i];path!=0 {
            if theirs,found:=unique(leader.names,path);found==1 {bone.leader=i32(theirs)}
        }
    }
    for &bone,i in out {
        if bone.leader<0 {continue}
        shared+=1
        parent,leader_parent:=follower.parents[i],leader.parents[bone.leader]
        bone.local=parent>=0 && leader_parent>=0 && out[parent].leader==leader_parent
    }
    return shared,true
}

// Gives the bones of a follower that follow a leader bone the pose of that
// bone, and leaves the others their local transform under the parent that now
// moves them. leader_local is the pose of the leader and leader_world that pose
// in the world; local is the pose of the follower, changed in place, and world
// receives it in the world, under root.
follow_pose :: proc "contextless" (parents:[]i32,bones:[]Follow_Bone,leader_local,leader_world,local,world:[]math.Transform,root:math.Transform=math.TRANSFORM_IDENTITY) -> bool {
    if len(parents)!=len(local) || len(bones)!=len(local) || len(world)!=len(local) || len(leader_world)!=len(leader_local) || !anim_transform_valid(root) {return false}
    if inertial_buffers_overlap(local,world) || inertial_buffers_overlap(local,leader_local) || inertial_buffers_overlap(world,leader_world) || inertial_buffers_overlap(local,leader_world) {return false}
    for parent,i in parents {
        if parent< -1 || int(parent)>=i {return false}
        above:=world[parent] if parent>=0 else root
        if from:=bones[i].leader;from>=0 {
            if int(from)>=len(leader_local) {return false}
            if bones[i].local {
                local[i]=leader_local[from]
            } else {
                placed,ok:=math.transform_relative(leader_world[from],above)
                if !ok {return false}
                placed.rotation=linalg.normalize0(placed.rotation)
                local[i]=placed
            }
        }
        if !anim_transform_valid(local[i]) {return false}
        world[i]=math.transform_compose(above,local[i])
        if !anim_transform_valid(world[i]) {return false}
    }
    return true
}

// The poses of a bone, summed by their weights until they are applied, so
// that the order in which they are added does not change the result. Full
// poses sum their transforms; additive ones sum their translations and the
// logarithms of their rotations, and multiply their scale factors.
Pose_Accumulator :: struct {
    position,scale:math.Vec3,
    rotation:[4]f32, // quaternion components, each on the side of the first
    weight:f32,
    shift,turn:math.Vec3, // additive: summed translation and logarithm of rotation
    factor:math.Vec3,     // additive: product of scale factors, while added
    added:bool,
}

// Adds a full pose of a bone by its weight, clamped to 0..1.
pose_accumulate :: proc "contextless" (sum:^Pose_Accumulator,pose:math.Transform,weight:f32) -> bool {
    if sum==nil || !anim_transform_valid(pose) || !anim_finite(weight) || !anim_finite(sum.weight) {return false}
    weight:=clamp(weight,0,1)
    if weight==0 {return true}
    turn:=[4]f32{pose.rotation.x,pose.rotation.y,pose.rotation.z,pose.rotation.w}
    if sum.weight>0 && turn.x*sum.rotation.x+turn.y*sum.rotation.y+turn.z*sum.rotation.z+turn.w*sum.rotation.w<0 {turn=-turn}
    sum.position+=pose.position*weight
    sum.scale+=pose.scale*weight
    sum.rotation+=turn*weight
    sum.weight+=weight
    return true
}

// Adds an additive pose of a bone by its weight, clamped to 0..1: delta is in
// the space of the parent of the bone, and its scale is the factor it
// multiplies by. With one pose, its rotation is the slerp from none to it.
pose_delta_accumulate :: proc "contextless" (sum:^Pose_Accumulator,delta:math.Transform,weight:f32) -> bool {
    if sum==nil || !anim_transform_valid(delta) || !anim_finite(weight) {return false}
    weight:=clamp(weight,0,1)
    if weight==0 {return true}
    rotation:=delta.rotation
    if real(rotation)<0 {rotation=-rotation}
    factor:=math.Vec3{1,1,1}+(delta.scale-math.Vec3{1,1,1})*weight
    sum.shift+=delta.position*weight
    sum.turn+=quat_log(rotation)*weight
    sum.factor=sum.factor*factor if sum.added else factor
    sum.added=true
    return true
}

// Applies the poses summed for a bone to its local transform: first the full
// ones, which it blends to by their weight up to 1 and past it normalized so
// that only the poses count, then the additive ones over that.
pose_accumulated_apply :: proc "contextless" (local:^math.Transform,sum:Pose_Accumulator) -> bool {
    if local==nil || !anim_finite(sum.weight) || !(sum.weight>0) && !sum.added {return false}
    next:=local^
    if sum.weight>0 {
        average:=math.Transform{position=sum.position/sum.weight,scale=sum.scale/sum.weight}
        q:=sum.rotation/sum.weight
        average.rotation=linalg.normalize0(math.Quat(quaternion(w=q.w,x=q.x,y=q.y,z=q.z)))
        if !anim_transform_valid(average) {return false}
        t:=min(sum.weight,1)
        next={position=next.position+(average.position-next.position)*t,rotation=math.quat_slerp(next.rotation,average.rotation,t),scale=next.scale+(average.scale-next.scale)*t}
    }
    if sum.added {
        next.position+=sum.shift
        next.rotation=linalg.normalize0(quat_exp(sum.turn)*next.rotation)
        next.scale*=sum.factor
    }
    if !anim_transform_valid(next) {return false}
    local^=next
    return true
}
