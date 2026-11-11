package previews_editor

import "core:math/linalg"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import gpu "mirai:render"
import "mirai:rhi"
import "mirai:rhi/shared_device"
import anim "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"
import eanim "plugins:animation/runtime"

@(private)
@(test_world)
Skin_World :: struct {
    using world:Test_World,
    skins:core.Table(eanim.Pose_Source),
}

@(test)
preview_samples_compact_bones_and_frames_the_clip_without_changing_authored_poses :: proc(t:^testing.T) {
    device:=shared_device.take_or_skip(t,hardware_rt=false)
    if device==nil {return}
    renderer:gpu.Renderer
    settings:=gpu.DEFAULT_SETTINGS;settings.gi_enabled=false
    if !testing.expect(t,gpu.renderer_init(&renderer,{device=device,width=64,height=64,settings=settings}),renderer.error) {return}
    defer gpu.renderer_destroy(&renderer)
    p:Animation
    defer animation_destroy(&p,context.allocator)
    p.subject.renderer=&renderer
    if !testing.expect(t,anim.library_init(&p.lib,{max_clips=1,max_tracks=1,max_keys=2})) {return}
    target:=base.name_hash("root/foot")
    clip,_:=anim.clip_add(&p.lib,{tracks={{target=target,property=.Position,keys={{time=0,value={0,1,0,0}},{time=1,value={0,2,0,0}}}}}})
    w:Skin_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    root,body:=core.create(&w.entities),core.create(&w.entities)
    sub:=&p.subject
    sub.part_count=2
    sub.parts[0]={entity=root,parent=-1,local={position={2,1,0},rotation=1,scale={1,1,1}}}
    sub.parts[1]={entity=body,parent=0,local=mm.TRANSFORM_IDENTITY,count=3,skinned=true}
    points:=[3]asset.Vertex{{position={0,0,0}},{position={1,0,0}},{position={0,1,0}}}
    influences:[3]asset.Skin_Vertex
    for &point,i in points {point.normal=mm.normal_pack({0,0,1});influences[i].joints[0]=0;influences[i].weights[0]=255}
    indices:=[3]u32{2,0,1}
    inverse:=mm.transform_matrix({position={0,-1,0},rotation=1,scale={1,1,1}})
    joints:=[1]asset.Rig_Joint{{node=1,inverse_bind=inverse}}
    info:=asset.Mesh_Info{skeleton={1,1}}
    view:=asset.Mesh_View{info=&info,joints=joints[:]}
    if !testing.expect(t,asset.mesh_build({vertices=points[:],skin=influences[:]},indices[:],nil,&view.geometry,context.temp_allocator)) {return}
    skin:=Subject_Skin{rig=root,part=1,rig_part=0}
    if !testing.expect(t,skin_geometry_load(&skin.geometry,view)) {return}
    skin.parents=make([]i32,2);skin.names=make([]u64,2);skin.rest=make([]mm.Transform,2)
    skin.local=make([]mm.Transform,2);skin.world=make([]mm.Transform,2);skin.palette=make([]gpu.Mat4,1)
    skin.parents[0],skin.parents[1]=-1,0;skin.names[0],skin.names[1]=base.name_hash("root"),target
    skin.rest[0],skin.rest[1]=mm.TRANSFORM_IDENTITY,{position={0,1,0},rotation=1,scale={1,1,1}}
    append(&sub.skins,skin)
    if !testing.expect(t,gpu.skin_preview_init(&renderer,&sub.skins[0].buffers,skin_geometry_level(&sub.skins[0].geometry),skin.geometry.influences,1)) {return}
    for index in indices {append(&sub.locals,gpu.Thumbnail_Vertex{position=points[index].position,normal={0,0,1}})}
    resize(&sub.posed,len(sub.locals))
    authored:=sub.parts
    subject_pose(&p,clip,0.5);subject_place(sub)
    if !testing.expect(t,subject_skins_place(&p)) {return}
    for index,i in indices {testing.expect(t,linalg.length(sub.posed[i].position-(points[index].position+[3]f32{2,1.5,0}))<0.0001)}
    testing.expect_value(t,sub.parts,authored)
    subject_fit(&p,clip)
    testing.expect(t,linalg.length(sub.fit[0]-[3]f32{2,1,0})<0.0001 && linalg.length(sub.fit[1]-[3]f32{3,3,0})<0.0001)
    subject_pose(&p,0,0);subject_place(sub)
    testing.expect(t,subject_skins_place(&p))
    testing.expect(t,linalg.length(sub.posed[1].position-[3]f32{2,1,0})<0.0001)
    core.add(&w.skins,body,{rig=root})
    test_world_settle(&w)
    testing.expect_value(t,animation_subject({skins=&w.skins},body),root)
    testing.expect_value(t,animation_subject({},root),root)
    testing.expectf(t,rhi.device_validation_errors(device)==0,"validation: %s",rhi.device_validation_message(device))
}
