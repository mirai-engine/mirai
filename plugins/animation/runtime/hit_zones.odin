package anim

import "core:math/linalg"
import "mirai:core"
import scene "mirai:engine/scene"
import "mirai:std/base"
import mm "mirai:std/math"

// Hit zones: shapes on the bones of a rig that gameplay tests rays against (a head, a torso, a
// limb), with tags a hit takes, so a headshot is a row of data. They are analytic shapes, not
// physics bodies: the collider of the entity says whether a ray reaches it, and its zones say
// where. Their world places follow the finished pose of each tick, and a rig that has them is read
// by gameplay: the far cadence never skips its pose.

HIT_ZONES :: 16

Hit_Zone_Shape :: enum u8 {None,Capsule,Sphere,Box}

// A zone in the axes of its bone: a capsule lies along the Y axis of the bone.
Hit_Zone :: struct {
    bone:[32]u8 `mirai:"text"`, // a bone of the skeleton, or a part of its body (@head)
    shape:Hit_Zone_Shape,
    offset:[3]f32 `mirai:"unit=m"`, // center from the bone, in its axes
    size:[3]f32 `mirai:"min=0,unit=m"`, // sphere: radius; capsule: radius and half length; box: half extents
    tags:scene.Tags, // a hit in this zone takes them besides those of the entity
}

@(component,description="Hit zones of this rig: analytic shapes on bones of its skeleton (a head, a torso) that ray hitboxes test after its collider, whose tags pick the effect of a hit. Its pose is evaluated in every tick, at any distance.")
Hit_Zone_Set :: struct {
    zones:core.Record(Hit_Zones),
}

// Where a zone is in the world: its center and the axes of its bone.
Zone_Placed :: struct {
    position:[3]f32,
    rotation:mm.Quat,
}

// The world places of the zones of a rig, from its finished pose of the tick: each end works it out
// and a copy of the world carries it, never sent or saved.
@(component,derived,description="Where the hit zones of this rig are in the world, from its finished pose of the tick.")
Hit_Zone_Pose :: struct {
    placed:[HIT_ZONES]Zone_Placed `mirai:"transient,readonly,hidden"`,
    bones:[HIT_ZONES]i16 `mirai:"transient,readonly,hidden"`, // in the pose of the rig; -1: none
    placed_bits:u16 `mirai:"transient,readonly,hidden"`, // bit i: zone i is placed
    bound:u64 `mirai:"transient,readonly,hidden"`,       // the binding of the rig its bones were found in
    generation:u32 `mirai:"transient,readonly,hidden"`,  // of the zone records they were found by
}

// The zone a ray met first, where and how far along it, with the tags of the zone.
Zone_Hit :: struct {
    zone:int,
    distance:f32,
    point,normal:[3]f32,
    tags:scene.Tags,
}

// The zones of set placed at placed (bit i of placed_bits: zone i is placed) that a ray from origin
// along direction meets within max_distance, the nearest; radius thickens the ray (a sphere swept
// along it: the zones grow by it, a box to a box larger by radius on each side).
zones_ray :: proc "contextless" (set:^Hit_Zones,placed:[]Zone_Placed,placed_bits:u16,origin,direction:[3]f32,max_distance,radius:f32) -> (hit:Zone_Hit,ok:bool) {
    if set==nil || !(max_distance>0) || !(radius>=0) {return}
    length:=linalg.length(direction)
    if !(length>1e-12 && length<=max(f32)) {return}
    ray:=mm.Ray{origin,direction/length}
    best:=max_distance
    for &zone,i in set.zones[:min(len(placed),HIT_ZONES)] {
        if placed_bits&(u16(1)<<u16(i))==0 || zone.shape==.None {continue}
        at:=placed[i]
        t:f32
        n:[3]f32
        met:bool
        switch zone.shape {
        case .None:
        case .Sphere: t,n,met=mm.ray_sphere(ray,{at.position,zone.size.x+radius})
        case .Capsule:
            along:=mm.quat_rotate(at.rotation,[3]f32{0,zone.size.y,0})
            t,n,met=mm.ray_capsule(ray,{at.position-along,at.position+along,zone.size.x+radius})
        case .Box: t,n,met=mm.ray_obb(ray,{at.position,at.rotation,zone.size+radius})
        }
        if !met || !(t<best) {continue}
        best=t
        hit={zone=i,distance=t,point=ray.origin+ray.direction*t,normal=n,tags=zone.tags}
        ok=true
    }
    return
}

// The ray against the zones of rig as the last tick placed them; false for a rig without zones,
// or without one of them placed, as for a ray that meets none.
hit_zones_ray :: proc(poses:^core.Table(Hit_Zone_Pose,$A),sets:^core.Table(Hit_Zone_Set,$B),zones:core.Records(Hit_Zones),rig:core.Entity,origin,direction:[3]f32,max_distance:f32,radius:f32=0) -> (hit:Zone_Hit,ok:bool) {
    pose,posed:=core.get(poses,rig)
    if !posed || pose.placed_bits==0 {return}
    set,has:=core.get(sets,rig)
    if !has {return}
    return zones_ray(zones_of(zones,set.zones),pose.placed[:],pose.placed_bits,origin,direction,max_distance,radius)
}

// The row a reference names, where its table keeps it; nil for none.
zones_of :: proc "contextless" (zones:core.Records(Hit_Zones),ref:core.Record(Hit_Zones)) -> ^Hit_Zones {
    if zones.set==nil || ref=={} {return nil}
    at:=core.record_index(zones.set,ref.table,ref.row,size_of(Hit_Zones))
    return nil if at<0 else cast(^Hit_Zones)&zones.set.values[at*size_of(Hit_Zones)]
}

// Whether rig has zones that are placed: a ray that reaches its collider and meets none of them
// misses it.
hit_zones_placed :: proc(poses:^core.Table(Hit_Zone_Pose,$A),rig:core.Entity) -> bool {
    pose,posed:=core.get(poses,rig)
    return posed && pose.placed_bits!=0
}

// Places the hit zones of every rig that has them on its finished pose of the tick. Nothing runs in
// a world without zones.
@(step="fixed",loops="game",stage="react",after="animation_advance")
animation_hit_zones :: proc(sets:^core.Table(Hit_Zone_Set,.Read),poses:^core.Table(Hit_Zone_Pose),zones:core.Records(Hit_Zones),playback:core.Ref(Playback),problems:^core.Problems) {
    if core.count(sets)==0 && len(poses.entities)==0 {return}
    for e in poses.entities {
        if !core.has(sets,e) {core.remove(poses,e)}
    }
    generation:=core.records_generation(zones)
    for row in 0..<core.count(sets) {
        e:=core.entity_at(sets,row)
        set:=core.at(sets,row)
        record:=zones_of(zones,set.zones)
        if record==nil && set.zones!={} {core.record_missing(zones.set,set.zones.table,set.zones.row,"Hit_Zones",problems,e)}
        state:=constraint_playing(playback,e)
        pose,posed:=core.get(poses,e)
        if !posed {
            pose={}
            for &bone in pose.bones {bone=-1}
        }
        placed:u16
        if record!=nil && state!=nil && state.pose_ready {
            world:=playing_pose(state,.World)
            if !posed || pose.bound!=state.bound || pose.generation!=generation {
                pose.bound,pose.generation=state.bound,generation
                for &zone,i in record.zones {
                    pose.bones[i]=-1
                    if zone.shape==.None {continue}
                    name:=base.text_get(zone.bone[:])
                    bone:=bone_find(state,base.name_hash(name)) if name!="" else -1
                    if bone<0 || bone>=len(world) || bone>int(max(i16)) {
                        core.report(problems,e,"animation.hit_zone","zone %d of its Hit_Zone_Set names the bone '%s', which its skeleton does not have; name a bone of the skeleton or a part of its body (@head)",i,name)
                        continue
                    }
                    pose.bones[i]=i16(bone)
                }
            }
            for &zone,i in record.zones {
                bone:=int(pose.bones[i])
                if bone<0 || bone>=len(world) || zone.shape==.None {continue}
                at:=world[bone]
                pose.placed[i]={at.position+mm.quat_rotate(at.rotation,zone.offset),at.rotation}
                placed|=u16(1)<<u16(i)
            }
        }
        pose.placed_bits=placed
        if !posed {
            if placed!=0 && !core.add(poses,e,pose) {memory_problem(problems,e,"the places of its hit zones")}
            continue
        }
        if current,_:=core.get(poses,e);current!=pose {core.edit(poses,e)^=pose}
    }
}
