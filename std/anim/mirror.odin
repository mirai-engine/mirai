package mirai_anim

import "core:math/linalg"
import math "mirai:std/math"

// The plane that separates the sides of a rig, in the space of its roots:
// points p with dot(normal,p)==offset.
Mirror_Plane :: struct {normal:math.Vec3,offset:f32}
MIRROR_PLANE_DEFAULT :: Mirror_Plane{normal={1,0,0}}

@(private="file")
mirror_separator :: #force_inline proc "contextless" (c:u8) -> bool {return c=='_' || c=='.' || c=='-' || c==':' || c==' ' || c=='|'}
@(private="file")
mirror_lower :: #force_inline proc "contextless" (c:u8) -> u8 {return c+32 if c>='A' && c<='Z' else c}

// The name of the bone on the other side: the last whole "l"/"r" token (as in
// thigh_l, hand.L, Bip01 L Thigh, l_arm) or else the first "left"/"right" (as
// in LeftArm) is swapped, keeping its case. False, with nothing written, for a
// name without side or that does not fit in out.
mirror_name :: proc "contextless" (name:string,out:[]u8) -> (string,bool) {
    swap :: proc "contextless" (name:string,at,length:int,with:string,out:[]u8) -> (string,bool) {
        size:=len(name)-length+len(with)
        if size>len(out) {return "",false}
        upper:=name[at]>='A' && name[at]<='Z'
        every:=upper && length>1 && name[at+1]>='A' && name[at+1]<='Z'
        copy(out,name[:at])
        for c,i in transmute([]u8)with {out[at+i]=c-32 if every || upper && i==0 else c}
        copy(out[at+len(with):],name[at+length:])
        return string(out[:size]),true
    }
    #reverse for c,i in transmute([]u8)name {
        lower:=mirror_lower(c)
        if lower!='l' && lower!='r' {continue}
        if i>0 && !mirror_separator(name[i-1]) || i+1<len(name) && !mirror_separator(name[i+1]) || len(name)==1 {continue}
        return swap(name,i,1,"r" if lower=='l' else "l",out)
    }
    for i in 0..<len(name) {
        for word in ([2]string{"left","right"}) {
            if i+len(word)>len(name) {continue}
            same:=true
            for c,j in transmute([]u8)word {if mirror_lower(name[i+j])!=c {same=false;break}}
            if same {return swap(name,i,len(word),"right" if word=="left" else "left",out)}
        }
    }
    return "",false
}

@(private="file")
mirror_valid :: proc "contextless" (parents,pairs:[]i32) -> bool {
    if len(parents)==0 || len(pairs)!=len(parents) {return false}
    for parent,i in parents {
        pair:=pairs[i]
        if parent< -1 || int(parent)>=i || pair<0 || int(pair)>=len(pairs) || pairs[pair]!=i32(i) || parent<0 && pair!=i32(i) || (parent<0)!=(parents[pair]<0) {return false}
    }
    return true
}

// The world of each bone relative to the roots, which stay at the identity.
@(private="file")
mirror_world :: proc "contextless" (parents:[]i32,local,world:[]math.Transform) -> bool {
    for parent,i in parents {
        world[i]=math.TRANSFORM_IDENTITY if parent<0 else math.transform_compose(world[parent],local[i])
        if !anim_transform_valid(world[i]) {return false}
    }
    return true
}

mirror_rotation :: #force_inline proc "contextless" (plane:Mirror_Plane,q:math.Quat) -> math.Quat {
    v:=math.Vec3{imag(q),jmag(q),kmag(q)}
    reflected:=2*plane.normal*linalg.dot(plane.normal,v)-v
    return quaternion(w=real(q),x=reflected.x,y=reflected.y,z=reflected.z)
}
mirror_vector :: #force_inline proc "contextless" (plane:Mirror_Plane,v:math.Vec3) -> math.Vec3 {
    return v-2*plane.normal*linalg.dot(plane.normal,v)
}
mirror_point :: #force_inline proc "contextless" (plane:Mirror_Plane,p:math.Vec3) -> math.Vec3 {
    return p-2*plane.normal*(linalg.dot(plane.normal,p)-plane.offset)
}

// Prepares the mirror of a rig from its rest pose. pairs gives for each bone
// the bone on the other side, or itself; pairs are mutual and roots pair
// with themselves. The plane goes between the paired bones at rest (the X
// plane when nothing is paired). corrections keeps, by bone, the turn from the
// reflection of its pair at rest to the bone at rest: rigs whose sides use
// different bone axes mirror too. scratch holds a pose. False, writing nothing,
// for an invalid rig or buffers of other sizes.
mirror_prepare :: proc "contextless" (parents,pairs:[]i32,rest:[]math.Transform,corrections:[]math.Quat,scratch:[]math.Transform) -> (plane:Mirror_Plane,ok:bool) {
    n:=len(parents)
    if !mirror_valid(parents,pairs) || len(rest)!=n || len(corrections)!=n || len(scratch)<n || !anim_pose_valid(rest) {return}
    world:=scratch[:n]
    if !mirror_world(parents,rest,world) {return}
    across:math.Vec3;middle:f64;count:int
    for pair,i in pairs {
        if int(pair)<=i {continue}
        side:=world[i].position-world[pair].position
        if linalg.dot(side,across)<0 {side=-side}
        across+=side
    }
    plane=MIRROR_PLANE_DEFAULT
    if length:=linalg.length(across);length>1e-6 && anim_vec3_valid(across) {plane.normal=across/length}
    for pair,i in pairs {
        if int(pair)<=i {continue}
        middle+=f64(linalg.dot(plane.normal,world[i].position+world[pair].position))*.5;count+=1
    }
    if count>0 {plane.offset=f32(middle/f64(count))}
    if !anim_finite(plane.offset) {return {},false}
    for pair,i in pairs {corrections[i]=1 if parents[i]<0 else linalg.normalize0(conj(mirror_rotation(plane,world[pair].rotation))*world[i].rotation)}
    return plane,true
}

// The transform of a bone, relative to the roots, that mirrors the one of its pair.
mirror_transform :: #force_inline proc "contextless" (plane:Mirror_Plane,correction:math.Quat,pair:math.Transform) -> math.Transform {
    return {mirror_point(plane,pair.position),mirror_rotation(plane,pair.rotation)*correction,pair.scale}
}

// Writes into out the local pose of the other side: every bone takes the
// world of its pair reflected across the plane, relative to the roots, which
// keep their transform. out may be local itself; scratch holds two poses.
// False, with out unspecified, for buffers of other sizes, an unprepared rig
// or values that are not finite.
pose_mirror :: proc "contextless" (parents,pairs:[]i32,corrections:[]math.Quat,plane:Mirror_Plane,local,out,scratch:[]math.Transform) -> bool {
    n:=len(parents)
    if !mirror_valid(parents,pairs) || len(corrections)!=n || len(local)!=n || len(out)!=n || len(scratch)<2*n {return false}
    if !anim_vec3_valid(plane.normal) || !anim_finite(plane.offset) || abs(linalg.dot(plane.normal,plane.normal)-1)>1e-3 {return false}
    world,mirrored:=scratch[:n],scratch[n:2*n]
    if !mirror_world(parents,local,world) {return false}
    for parent,i in parents {mirrored[i]=math.TRANSFORM_IDENTITY if parent<0 else mirror_transform(plane,corrections[i],world[pairs[i]])}
    for parent,i in parents {
        if parent<0 {out[i]=local[i];continue}
        relative,valid:=math.transform_relative(mirrored[i],mirrored[parent])
        if !valid || !anim_transform_valid(relative) {return false}
        out[i]=relative
    }
    return true
}
