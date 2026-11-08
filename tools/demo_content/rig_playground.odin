package main

import "core:fmt"
import "core:math/linalg"
import "core:os"
import "mirai:asset"
import "mirai:core"
import game "mirai:demo/game"
import render "mirai:engine/render"
import "mirai:std/base"
import "mirai:std/geom"
import mm "mirai:std/math"
import anim "plugins:animation/runtime"

// Three chains of nine boxes, one per rig of the gallery: a spline, a reach that stretches and a
// corrective that a bend drives.
@(private)
gallery_rigs :: proc(g:^Gallery_Build,places:[3]Gallery_Place) {
    o,s:=g.o,g.s
    folder:="assets/models/rig-playground";os.make_directory_all(path(o,folder))
    skeleton,mesh:=asset.content_id(PROJECT,"skeleton","rig_playground"),asset.content_id(PROJECT,"mesh","rig_playground")
    bones:[9]asset.Skeleton_Bone;world:[9]mm.Transform;joints:[9]asset.Rig_Joint
    for &bone,i in bones {
        bone.parent=i32(i-1);bone.rotation,bone.scale=1,{1,1,1};if i>0 {bone.translation.y=.28}
        name:=fmt.tprintf("joint%d",i);base.text_set(bone.name[:],name)
        full:=fmt.tprintf("%s/%s",base.text_get(bones[i-1].path[:]),name) if i>0 else name;base.text_set(bone.path[:],full);bone.target=base.name_hash(full)
        world[i]={bone.translation,bone.rotation,bone.scale};if i>0 {world[i]=mm.transform_compose(world[i-1],world[i])}
        joints[i]={node=u32(i),inverse_bind=linalg.inverse(mm.transform_matrix(world[i]))}
    }
    asset.content_check(&o.content,"rig-playground.skeleton",asset.skeleton_save(path(o,fmt.tprintf("%s/chain.skeleton",folder)),&o.content.types,{id=skeleton,bones=bones[:]}))
    cube:geom.Mesh_Buffer;geom.mesh_buffer_init(&cube,context.temp_allocator);geom.cube_build(&cube)
    vertices:=make([dynamic]asset.Vertex,context.temp_allocator);indices:=make([dynamic]u32,context.temp_allocator);skin:=make([dynamic]asset.Skin_Vertex,context.temp_allocator)
    for i in 0..<8 {gallery_skin_box(&cube,&vertices,&indices,&skin,{{0,f32(i)*.28+.14,0},1,{.18,.25,.18}},u16(i),0xff6dbfe8 if i%2==0 else 0xffdaab4d)}
    gallery_skin_box(&cube,&vertices,&indices,&skin,{{0,2.24,0},1,{.24,.12,.24}},8,0xffd66ddf)
    mesh_write_built(o,"rig-playground.mesh",fmt.tprintf("%s/chain.mesh",folder),{id=mesh,joints=joints[:],skeleton=skeleton},{vertices=vertices[:],skin=skin[:]},indices[:])
    titles:=[game.Rig_Playground_Kind]string{.Spline="4.3  Spline IK",.Stretch="4.4  Soft reach and stretch",.Corrective="4.5  Pose corrective"}
    details:=[game.Rig_Playground_Kind]string{.Spline="one cubic curve, stable lengths and twist",.Stretch="soft zone 0.3 m, stretch limited to 0.4 m",.Corrective="the bend drives a bulge and a named curve"}
    for kind in game.Rig_Playground_Kind {
        place:=places[int(kind)];origin:=place.origin
        rig:=asset.builder_entity(s,titles[kind][5:],{position=origin});asset.builder_set(s,rig,render.Mesh_Renderer{mesh=mesh});asset.builder_set(s,rig,game.Rig_Playground{kind=kind,origin=origin})
        switch kind {
        case .Spline:
            spline:=anim.SPLINE_IK_CONSTRAINT_DEFAULT;base.text_set(spline.name[:],"tail");spline.root,spline.end=anim.bone_ref("joint0"),anim.bone_ref("joint8");spline.controls={anim.spatial_point(origin),anim.spatial_point(origin+{0,.7,0}),anim.spatial_point(origin+{.5,1.5,0}),anim.spatial_point(origin+{.4,2.3,0})};spline.up={0,0,1}
            gallery_profile(o,s,rig,"playground_spline",{spline_ik={spline}})
        case .Stretch:
            chain:=anim.CHAIN_IK_CONSTRAINT_DEFAULT;base.text_set(chain.name[:],"reach");chain.root,chain.end=anim.bone_ref("joint0"),anim.bone_ref("joint8");chain.target=anim.spatial_point(origin+{0,2.5,0});chain.pole=origin+{0,1,1};chain.use_pole=true;chain.reach={soft_distance=.3,max_stretch=.4}
            gallery_profile(o,s,rig,"playground_stretch",{chain_ik={chain}})
        case .Corrective:
            corrective:=anim.POSE_CORRECTIVE_DEFAULT;base.text_set(corrective.name[:],"bend_bulge");base.text_set(corrective.curve[:],"bulge");corrective.driver,corrective.bone=anim.bone_ref("joint3"),anim.bone_ref("joint3");corrective.sample_count=2
            corrective.samples[0],corrective.samples[1]=anim.POSE_CORRECTIVE_SAMPLE_DEFAULT,anim.POSE_CORRECTIVE_SAMPLE_DEFAULT;corrective.samples[1].rotation=mm.quat_axis_angle({0,0,1},1.4);corrective.samples[1].delta.scale={2,1,2};corrective.samples[1].curve_value=1
            gallery_profile(o,s,rig,"playground_corrective",{correctives={corrective}})
        }
        gallery_item(g,rig,.Rig,place,titles[kind],details[kind])
    }
}
