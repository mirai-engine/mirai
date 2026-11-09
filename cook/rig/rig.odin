package rig

import "core:fmt"
import "core:math/linalg"
import "mirai:asset"
import "mirai:std/base"
import mm "mirai:std/math"

// A skeleton and the skin of meshes that have none: the joints of a template
// are fitted to the meshes, by the sections of a person (fit.odin) or by
// deforming an animal's surface onto them (register.odin), and the vertices
// weighted to them (weights.odin).
//
// The skin is bound where the joints are in the mesh, and the rest of the
// skeleton is the template's pose (Mesh2Motion's) with the lengths of the
// mesh: a bone keeps the rotations of the template, so the clips of that rig
// and a retarget from its skeleton read the same rest, whatever pose the mesh
// was modelled in. The bones are those of the template under its root node,
// with the same paths as an import of that rig, so its clips target them by
// path.

ROOT_NAME :: "Armature"

Rig :: struct {
    bones:[]asset.Skeleton_Bone, // parents before children; the first is the template's root node
    joints:[]asset.Rig_Joint,    // one per bone, its frame in the mesh as inverse_bind
    skins:[][]asset.Skin_Vertex, // by mesh, by vertex; joints are rows of joints
    fit:Fit,                     // of a humanoid
    warnings:[]string,
}

Error :: enum u8 {
    None,
    Empty, // no triangles, or a mesh without height
}

// Above this coverage (Registration) the template could not take the shape
// of the mesh. Below it the mesh may still be another animal: the
// deformation covers most shapes, so the kind of animal is the caller's.
COVERAGE_POOR :: 0.04

// The humanoid rig of meshes, in the space of the model: +Y up, facing -Z.
humanoid :: proc(meshes:[]Mesh,hints:Hints={},allocator:=context.allocator) -> (rig:Rig,error:Error) {
    f,ok:=fit(meshes,hints,allocator)
    if !ok {return {},.Empty}
    rig.fit=f
    bones:=make([]Bone,len(HUMANOID),context.temp_allocator)
    for b,i in HUMANOID {bones[i]={b.name,b.parent,b.translation,b.rotation}}
    rig_build(&rig,meshes,ROOT_NAME,bones,f.joints,Humanoid_Body{crotch=f.crotch,center=f.center,arms_down=f.arms_down,pelvis=bone_index("pelvis")},allocator)
    warnings:=make([dynamic]string,allocator)
    if f.confidence[.Crotch]<1 {append(&warnings,fmt.aprintf("rig: the legs do not part (a skirt or a coat?); the crotch is assumed at %.2f m: import again with rig_crotch at its height if it is not",f.crotch,allocator=allocator))}
    if f.confidence[.Neck]<1 {append(&warnings,fmt.aprintf("rig: no neck was found; it is assumed at %.2f m: import again with rig_neck at its height if it is not",f.neck,allocator=allocator))}
    for side in ([2]Landmark{.Arm_L,.Arm_R}) {
        name:="left" if side==.Arm_L else "right"
        switch {
        case f.confidence[side]==0: append(&warnings,fmt.aprintf("rig: no %s arm stands out of the torso; it is placed by the template: model the arms apart from the body (T- or A-pose)",name,allocator=allocator))
        case f.confidence[side]<1: append(&warnings,fmt.aprintf("rig: the arms have different lengths; check the %s hand",name,allocator=allocator))
        }
    }
    rig.warnings=warnings[:]
    return rig,.None
}

// The rig of an animal of Mesh2Motion fitted to meshes, in the space of the
// model: +Y up, facing -Z, as the template stands.
animal :: proc(meshes:[]Mesh,kind:Animal,allocator:=context.allocator) -> (rig:Rig,error:Error) {
    template:=ANIMALS[kind]
    registered,ok:=register(template,meshes,allocator)
    if !ok {return {},.Empty}
    rig_build(&rig,meshes,template.root,template.bones,registered.joints,nil,allocator)
    warnings:=make([dynamic]string,allocator)
    if registered.coverage>COVERAGE_POOR {append(&warnings,fmt.aprintf("rig: the %v template covers the mesh poorly (%.1f%% of its size apart): check that it is that animal, standing on +Y and facing -Z like the template",kind,registered.coverage*100,allocator=allocator))}
    rig.warnings=warnings[:]
    return rig,.None
}

// The skeleton of bones with its joints at joints, and the skin of meshes to it.
@(private)
rig_build :: proc(rig:^Rig,meshes:[]Mesh,root_name:string,bones:[]Bone,joints:[]mm.Vec3,body:Maybe(Humanoid_Body),allocator:=context.allocator) {
    count:=len(bones)+1
    rig.bones=make([]asset.Skeleton_Bone,count,allocator)
    rig.joints=make([]asset.Rig_Joint,count,allocator)
    // The template's rest in the world, and where each bone points to.
    rotations:=make([]mm.Quat,len(bones),context.temp_allocator)
    positions:=make([]mm.Vec3,len(bones),context.temp_allocator)
    first_child:=make([]int,len(bones),context.temp_allocator)
    for &c in first_child {c=-1}
    for bone,i in bones {
        local:=quaternion(x=bone.rotation[0],y=bone.rotation[1],z=bone.rotation[2],w=bone.rotation[3])
        rotations[i],positions[i]=local,bone.translation
        if bone.parent>=0 {
            positions[i]=positions[bone.parent]+mm.quat_rotate(rotations[bone.parent],bone.translation)
            rotations[i]=rotations[bone.parent]*local
            if first_child[bone.parent]<0 {first_child[bone.parent]=i}
        }
    }
    root:=asset.Skeleton_Bone{parent=-1,rotation=1,scale=1}
    base.text_set(root.name[:],root_name)
    base.text_set(root.path[:],root_name)
    root.target=base.name_hash(root_name)
    rig.bones[0]=root
    rig.joints[0]={node=0,inverse_bind=1}
    turns:=make([]mm.Quat,len(bones),context.temp_allocator)
    for bone,i in bones {
        row:=&rig.bones[i+1]
        row.parent=i32(bone.parent+1)
        row.scale=1
        row.rotation=quaternion(x=bone.rotation[0],y=bone.rotation[1],z=bone.rotation[2],w=bone.rotation[3])
        base.text_set(row.name[:],bone.name)
        path:=fmt.tprintf("%s/%s",base.text_get(rig.bones[row.parent].path[:]),bone.name)
        base.text_set(row.path[:],path)
        row.target=base.name_hash(path)
        if bone.parent<0 {
            row.translation=joints[i]
        } else if length:=linalg.length(bone.translation);length>1e-6 {
            row.translation=bone.translation/length*linalg.length(joints[i]-joints[bone.parent])
        }
        // The bind frame: the template's, turned to point where the mesh's bone points.
        turns[i]=turns[bone.parent] if bone.parent>=0 else 1
        if child:=first_child[i];child>=0 {
            was,now:=positions[child]-positions[i],joints[child]-joints[i]
            if linalg.length(was)>1e-6 && linalg.length(now)>1e-6 {turns[i]=mm.quat_between(linalg.normalize(was),linalg.normalize(now))}
        }
        bind:=mm.Transform{position=joints[i],rotation=linalg.normalize(turns[i]*rotations[i]),scale=1}
        inverse,_:=mm.transform_inverse_matrix(bind)
        rig.joints[i+1]={node=u32(i+1),inverse_bind=inverse}
    }
    names:=make([]string,len(bones),context.temp_allocator)
    parents:=make([]i32,len(bones),context.temp_allocator)
    for bone,i in bones {names[i],parents[i]=bone.name,bone.parent}
    influences:=weigh(meshes,{names=names,parents=parents,joints=joints},body,context.temp_allocator)
    rig.skins=make([][]asset.Skin_Vertex,len(meshes),allocator)
    for mesh,m in influences {
        rig.skins[m]=make([]asset.Skin_Vertex,len(mesh),allocator)
        for influence,v in mesh {
            weights:[8]f32
            weights[0],weights[1]=influence.weight[0],influence.weight[1]
            skin:=&rig.skins[m][v]
            skin.weights=asset.skin_weights_quantize(weights)
            for k in 0..<2 {if skin.weights[k]>0 {skin.joints[k]=u16(influence.bone[k]+1)}}
        }
    }
}
