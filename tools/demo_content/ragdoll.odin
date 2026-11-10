package main

import "core:fmt"
import "core:math/linalg"
import "core:os"
import "mirai:asset"
import lib "mirai:std/anim"
import "mirai:std/base"
import "mirai:std/geom"
import mm "mirai:std/math"

// The rig of the ragdoll station of the physics gallery: seven boxes on a skeleton and the wave of
// its right arm.
@(private)
physics_ragdoll :: proc(o:^Out) {
    folder::"assets/physics_gallery/ragdoll";os.make_directory_all(path(o,folder))
    skeleton_id,mesh_id,clip_id:=asset.content_id(PROJECT,"skeleton","physics-ragdoll"),asset.content_id(PROJECT,"mesh","physics-ragdoll"),asset.content_id(PROJECT,"animation","physics-ragdoll")
    names:=[7]string{"torso","head","arm.left","arm.right","hips","leg.left","leg.right"}
    parents:=[7]i32{-1,0,0,0,0,4,4}
    local:=[7]mm.Vec3{{0,1.7,0},{0,.7,0},{-.55,.05,0},{.55,.05,0},{0,-.65,0},{-.17,-.6,0},{.17,-.6,0}}
    sizes:=[7]mm.Vec3{{.7,.9,.35},{.4,.4,.4},{.25,.85,.25},{.25,.85,.25},{.6,.35,.3},{.22,.8,.25},{.22,.8,.25}}
    colors:=[7]u32{0xff77bcf4,0xffc7e5ff,0xff67aeed,0xff67aeed,0xff579bcf,0xffeec96a,0xffeec96a}
    bones:[7]asset.Skeleton_Bone;world:[7]mm.Transform;joints:[7]asset.Rig_Joint
    cube:geom.Mesh_Buffer;geom.mesh_buffer_init(&cube,context.temp_allocator);geom.cube_build(&cube)
    vertices:=make([dynamic]asset.Vertex,context.temp_allocator);indices:=make([dynamic]u32,context.temp_allocator);skin:=make([dynamic]asset.Skin_Vertex,context.temp_allocator)
    for &bone,i in bones {
        bone.parent,bone.translation,bone.rotation,bone.scale=parents[i],local[i],1,{1,1,1}
        base.text_set(bone.name[:],names[i]);base.text_set(bone.path[:],fmt.tprintf("%s/%s",base.text_get(bones[parents[i]].path[:]),names[i]) if parents[i]>=0 else names[i])
        bone.target=base.name_hash(base.text_get(bone.path[:]))
        world[i]={local[i],1,{1,1,1}};if parents[i]>=0 {world[i]=mm.transform_compose(world[parents[i]],world[i])}
        joints[i]={node=u32(i),inverse_bind=linalg.inverse(mm.transform_matrix(world[i]))}
        shape:=world[i];shape.scale=sizes[i]
        gallery_skin_box(&cube,&vertices,&indices,&skin,shape,u16(i),colors[i])
    }
    asset.content_check(&o.content,"physics-ragdoll.skeleton",asset.skeleton_save(path(o,folder+"/rig.skeleton"),&o.content.types,{id=skeleton_id,bones=bones[:]}))
    if !asset.mesh_tangents(&vertices,indices[:],&skin) {asset.content_check(&o.content,"physics-ragdoll.mesh",.Out_Of_Memory);return}
    mesh_write_built(o,"physics-ragdoll.mesh",folder+"/rig.mesh",{id=mesh_id,joints=joints[:],skeleton=skeleton_id},{vertices=vertices[:],skin=skin[:]},indices[:])
    keys:[5]lib.Keyframe
    for &key,i in keys {angle:f32=.6 if i%2==1 else -.6;q:=mm.quat_axis_angle({0,0,1},angle);key={time=f32(i)*.5,value={q.x,q.y,q.z,q.w},interpolation=.Linear}}
    track:=asset.Animation_Track_Desc{target=base.text_get(bones[3].path[:]),property=.Rotation,keys=keys[:]}
    clip:=asset.Animation_Clip_Desc{name="wave",tracks={track},skeleton=skeleton_id}
    asset.content_check(&o.content,"physics-ragdoll.anim",asset.animation_save(path(o,folder+"/wave.anim"),&o.content.types,{id=clip_id,clips={clip}}))
}
