package main

import "core:fmt"
import "core:math/linalg"
import "core:os"
import "mirai:asset"
import "mirai:core"
import game "mirai:demo/game"
import phys "plugins:physics/runtime"
import render "mirai:engine/render"
import lib "mirai:std/anim"
import "mirai:std/base"
import "mirai:std/geom"
import mm "mirai:std/math"
import anim "plugins:animation/runtime"
import rag "plugins:ragdoll/runtime"

physics_ragdoll_station :: proc(o:^Out,s:^Scene_Out,origin:mm.Vec3) -> base.Entity_Id {
    folder::"assets/physics_gallery/ragdoll";os.make_directory_all(path(o,folder))
    skeleton_id,mesh_id,clip_id:=id_of("skeleton","physics-ragdoll"),id_of("mesh","physics-ragdoll"),id_of("animation","physics-ragdoll")
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
    check(o,"physics-ragdoll.skeleton",asset.skeleton_save(path(o,folder+"/rig.skeleton"),&o.types,{id=skeleton_id,bones=bones[:]}))
    if !asset.mesh_tangents(&vertices,indices[:],&skin) {check(o,"physics-ragdoll.mesh",.Out_Of_Memory);return {}}
    mesh_write_built(o,"physics-ragdoll.mesh",folder+"/rig.mesh",{id=mesh_id,joints=joints[:],skeleton=skeleton_id},{vertices=vertices[:],skin=skin[:]},indices[:])
    keys:[5]lib.Keyframe
    for &key,i in keys {angle:f32=.6 if i%2==1 else -.6;q:=mm.quat_axis_angle({0,0,1},angle);key={time=f32(i)*.5,value={q.x,q.y,q.z,q.w},interpolation=.Linear}}
    track:=asset.Animation_Track_Desc{target=base.text_get(bones[3].path[:]),property=.Rotation,keys=keys[:]}
    clip:=asset.Animation_Clip_Desc{name="wave",tracks={track},skeleton=skeleton_id}
    check(o,"physics-ragdoll.anim",asset.animation_save(path(o,folder+"/wave.anim"),&o.types,{id=clip_id,clips={clip}}))
    root:=entity(s,"Ragdoll: animation / simulation / motors",origin)
    put(s,root,"Mesh_Renderer",&render.Mesh_Renderer{mesh=mesh_id})
    animation:=anim.ANIMATION_DEFAULT;animation.asset=clip_id;base.text_set(animation.clip[:],"wave");put(s,root,"Animation",&animation)
    config:=rag.RAGDOLL_DEFAULT;config.mode=.Animated;config.hertz=8;config.max_torque=120
    put(s,root,"Ragdoll",&config)
    put(s,root,"Ragdoll_Gallery",&game.Ragdoll_Gallery{auto_cycle=true})
    bodies:[7]base.Entity_Id
    for i in 0..<7 {
        bodies[i]=entity(s,fmt.tprintf("Ragdoll body %s",names[i]),origin+world[i].position)
        body:=phys.RIGID_BODY_DYNAMIC;body.mass=5 if i>0 else 15;body.linear_damping=.1;body.angular_damping=.1
        put(s,bodies[i],"Rigid_Body",&body)
        collider:=phys.collider_box(sizes[i]*.5);collider.group=core.Entity(root);collider.friction=.7;put(s,bodies[i],"Collider",&collider)
        bone:=rag.RAGDOLL_BONE_DEFAULT;bone.rig=core.Entity(root);bone.bone=anim.bone_ref(names[i]);put(s,bodies[i],"Ragdoll_Bone",&bone)
        if parents[i]>=0 {
            parent:=parents[i];anchor:=mm.Vec3{0,sizes[i].y*.4,0}
            if i==4 {anchor={0,.175,0}}
            joint:=phys.joint_sixdof(core.Entity(bodies[parent]),anchor);joint.auto_target=false;joint.target_anchor=world[i].position+anchor-world[parent].position
            for &axis in joint.angular {axis.motion=.Limited;axis.lower=-1.1;axis.upper=1.1}
            if i==1 {for &axis in joint.angular {axis.lower=-.4;axis.upper=.4}}
            put(s,bodies[i],"Joint",&joint)
        }
    }
    return root
}
