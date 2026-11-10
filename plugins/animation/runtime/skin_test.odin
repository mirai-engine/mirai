package anim

import "core:fmt"
import "core:math/linalg"
import "core:os"
import "core:path/filepath"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import erender "mirai:engine/render"
import "mirai:host"
import gpu "mirai:render"
import "mirai:rhi"
import "mirai:rhi/shared_device"
import "mirai:std/base"
import mm "mirai:std/math"

@(test)
skeletal_instances_use_independent_dense_poses_and_eighth_influence :: proc(t:^testing.T) {
    problems:core.Problems
    temp,_:=os.temp_directory(context.temp_allocator)
    directory:=fmt.tprintf("%s/mirai-animation-skin-%d",temp,os.get_pid())
    os.make_directory(directory);defer os.remove(directory)
    path,_:=filepath.join({directory,"rig.mesh"},context.temp_allocator)
    defer os.remove(path)
    skeleton_path,_:=filepath.join({directory,"rig.skeleton"},context.temp_allocator)
    defer os.remove(skeleton_path)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    vertices:=[3]asset.Vertex{
        {position={-1,0,0},normal=mm.normal_pack({0,0,1}),color=0xffffffff},
        {position={1,0,0},normal=mm.normal_pack({0,0,1}),color=0xffffffff},
        {position={0,1,0},normal=mm.normal_pack({0,0,1}),color=0xffffffff},
    }
    influences:=[3]asset.Skin_Vertex{}
    for &influence in influences {influence.weights[7]=255}
    nodes:=[2]asset.Skeleton_Bone{{parent=-1,rotation=1,scale={1,1,1}},{parent=0,rotation=1,scale={1,1,1}}}
    for &node,i in nodes {
        name:="root" if i==0 else "foot"
        path:="root" if i==0 else "root/foot"
        base.text_set(node.name[:],name);base.text_set(node.path[:],path);node.target=base.name_hash(path)
    }
    joints:=[1]asset.Rig_Joint{{node=1,inverse_bind=1}}
    id:=base.Asset_Id{0x517,0x99}
    skeleton_id:=base.Asset_Id{0x518,0x98}
    if !testing.expect_value(t,asset.skeleton_save(skeleton_path,&types,{id=skeleton_id,bones=nodes[:]}),asset.Error.None) {return}
    if !testing.expect_value(t,rig_mesh_save(path,&types,{id=id,skeleton=skeleton_id,joints=joints[:]},vertices[:],{0,1,2},influences[:]),asset.Error.None) {return}
    device,message:=shared_device.take(t, hardware_rt = false)
    if device==nil {if !rhi.gpu_skip_allowed() {testing.expect(t,false,message)};return}
    renderer:=new(gpu.Renderer);defer free(renderer)
    settings:=gpu.DEFAULT_SETTINGS;settings.gi_enabled,settings.reflections,settings.taa=false,false,false
    if !testing.expect(t,gpu.renderer_init(renderer,{device=device,width=96,height=64,settings=settings}),renderer.error) {return}
    defer gpu.renderer_destroy(renderer)
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=directory,renderer=renderer})) {return}
    defer host.assets_destroy(&assets)
    app:=host.App{allocator=context.allocator,renderer=renderer,assets=&assets}
    defer host.extras_free(&app.extras)
    cache:Skin_Runtime;defer skin_runtime_free(&cache)
    state:Skin_Instances;defer skin_instances_free(&state)
    playback:Playback;defer playback_free(&playback)
    skeleton_assets:Skeleton_Assets;defer skeleton_assets_free(&skeleton_assets)
    entities:core.Entities;core.entities_init(&entities);defer core.entities_destroy(&entities)
    meshes:core.Table(erender.Mesh_Renderer);defer core.table_destroy(&meshes)
    skins:core.Table(Pose_Source);defer core.table_destroy(&skins)
    transforms:core.Table(core.Transform);defer core.table_destroy(&transforms)
    parents:core.Table(core.Parent);defer core.table_destroy(&parents)
    worlds:core.Table(core.World_Transform);defer core.table_destroy(&worlds)
    tints:core.Table(erender.Tint);defer core.table_destroy(&tints)
    overrides:core.Table(erender.Material_Override);defer core.table_destroy(&overrides)
    hidden:core.Table(erender.Hidden);defer core.table_destroy(&hidden)
    elsewhere:core.Table(erender.Drawn_Elsewhere);defer core.table_destroy(&elsewhere)
    highlights:core.Table(erender.Highlight);defer core.table_destroy(&highlights)
    offsets:core.Table(erender.Draw_Offset);defer core.table_destroy(&offsets)
    roots,draws:[2]core.Entity
    for i in 0..<2 {
        roots[i]=core.create(&entities);draws[i]=core.create(&entities)
        core.add(&parents,draws[i],{entity=roots[i]})
        core.add(&skins,draws[i],{rig=roots[i]})
        core.add(&meshes,draws[i],{mesh=id})
        transform:=mm.TRANSFORM_IDENTITY;transform.position.x=f32(i)*3
        core.add(&transforms,roots[i],core.Transform(transform))
        core.add(&worlds,roots[i],{transform=transform,previous=transform})
        core.add(&worlds,draws[i],{transform=transform,previous=transform})
    }
    core.add(&offsets,roots[0],{offset={0,2,0}})
    core.table_settle(&offsets,&entities)
    core.table_settle(&parents,&entities);core.table_settle(&skins,&entities);core.table_settle(&transforms,&entities)
    core.table_settle(&meshes,&entities);core.table_settle(&worlds,&entities)
    definition:=skeleton_content(&skeleton_assets,&app,skeleton_id)
    if !testing.expect(t,definition!=nil) {return}
    for rig,i in roots {
        pose:=state_get(&playback,rig)
        if !testing.expect(t,pose!=nil && skeleton_bind(&playback,pose,definition,nil,&transforms)) {return}
        pose.local[2].position.y=f32(i)+0.5
        copy(pose.previous[:],pose.local[:]);pose.pose_ready=true
        testing.expect_value(t,len(pose.local),3)
        testing.expect(t,pose.bindings[1].entity==core.NONE && pose.bindings[2].entity==core.NONE)
    }
    tick :: proc(app:^host.App,cache:^Skin_Runtime,state:^Skin_Instances,playback:^Playback,meshes:^core.Table(erender.Mesh_Renderer),skins:^core.Table(Pose_Source),parents:^core.Table(core.Parent),worlds:^core.Table(core.World_Transform),tints:^core.Table(erender.Tint),overrides:^core.Table(erender.Material_Override),hidden:^core.Table(erender.Hidden),elsewhere:^core.Table(erender.Drawn_Elsewhere),highlights:^core.Table(erender.Highlight),offsets:^core.Table(erender.Draw_Offset),problems:^core.Problems,time:core.Time={},frame:=core.FRAME_TIME_DEFAULT) {
        clear(&app.extras.instances)
        outlines:core.Table(erender.Outline);defer core.table_destroy(&outlines)
        animation_skin(core.read(meshes),core.read(skins),core.read(parents),core.read(worlds),core.read(tints),core.read(overrides),core.read(hidden),core.read(elsewhere),core.read(highlights),core.read(&outlines),core.read(offsets),cache,state,app,time,frame,core.Ref(Playback){ptr=playback},{},problems,{},nil,ANIMATION_BUDGET_CONFIG_DEFAULT,{},{},{},{})
    }
    tick(&app,&cache,&state,&playback,&meshes,&skins,&parents,&worlds,&tints,&overrides,&hidden,&elsewhere,&highlights,&offsets,&problems)
    if !testing.expect_value(t,len(host.extras_instances(&app.extras)),2) {return}
    testing.expect_value(t,host.extras_instances(&app.extras)[0].transform[1,3],f32(2))
    testing.expect_value(t,len(cache.rigs),1)
    testing.expect_value(t,problems.count,0)
    for instance in state.instances.values {testing.expect_value(t,len(instance.palette),1)}
    gpu.scene_set(renderer,host.extras_instances(&app.extras),nil,{},gpu.Environment{sky={1,1,1}})
    if !testing.expect(t,gpu.renderer_frame(renderer,{camera={position={1,2,8},forward={0,-1,-8},up={0,1,0},fov_y=50,near=0.1,far=100}}),renderer.error) {return}
    for instance,i in state.instances.values {
        record:=renderer.scene.meshes[instance.mesh]
        result:[3]gpu.Gpu_Posed_Vertex
        testing.expect(t,rhi.buffer_read_slice(device,renderer.scene.vertex_buffer,u64(record.posed_word)*4,result[:]))
        for v,j in vertices {testing.expect_value(t,result[j].position,v.position+[3]f32{0,f32(i)+0.5,0})}
    }
    // A tick that changes the poses, which the frames between it and the next interpolate.
    playback.frame+=1
    for root,i in roots {
        pose:=constraint_playing(&playback,root)
        pose.changed=playback.frame
        pose.local[0].rotation=mm.quat_axis_angle({0,0,1},0.3)
        pose.local[0].scale={1.3,0.8,-1.1}
        pose.previous[0]=pose.local[0]
        pose.local[2].position.y+=1
        for entity in ([2]core.Entity{root,draws[i]}) {
            placed:=core.get(&worlds,entity)
            placed.transform,placed.previous=pose.local[0],pose.local[0]
        }
    }
    for alpha in ([4]f32{0,0.25,0.75,1}) {
        tick(&app,&cache,&state,&playback,&meshes,&skins,&parents,&worlds,&tints,&overrides,&hidden,&elsewhere,&highlights,&offsets,&problems,{playing=true},{alpha=alpha})
        gpu.scene_set(renderer,host.extras_instances(&app.extras),nil,{},gpu.Environment{sky={1,1,1}})
        if !testing.expect(t,gpu.renderer_frame(renderer,{camera={position={1,2,8},forward={0,-1,-8},up={0,1,0},fov_y=50,near=0.1,far=100}}),renderer.error) {return}
        for instance,i in state.instances.values {
            record:=renderer.scene.meshes[instance.mesh]
            result:[3]gpu.Gpu_Posed_Vertex
            testing.expect(t,rhi.buffer_read_slice(device,renderer.scene.vertex_buffer,u64(record.posed_word)*4,result[:]))
            for vertex,j in vertices {testing.expect(t,linalg.length(result[j].position-(vertex.position+[3]f32{0,f32(i)+0.5+alpha,0}))<1e-5)}
        }
    }
    // A tick that left the poses as they were: between ticks they are drawn
    // as they are, and only the mesh that moved makes its palette again.
    playback.frame+=1
    for &instance in state.instances.values {instance.palette[0]={}}
    tick(&app,&cache,&state,&playback,&meshes,&skins,&parents,&worlds,&tints,&overrides,&hidden,&elsewhere,&highlights,&offsets,&problems,{playing=true},{alpha=0.5})
    for instance in state.instances.values {testing.expect_value(t,instance.palette[0],gpu.Mat4{})}
    moved:=core.get(&worlds,draws[1]);moved.transform.position.x+=1;moved.previous=moved.transform
    tick(&app,&cache,&state,&playback,&meshes,&skins,&parents,&worlds,&tints,&overrides,&hidden,&elsewhere,&highlights,&offsets,&problems,{playing=true},{alpha=0.5})
    testing.expect_value(t,state.instances.values[0].palette[0],gpu.Mat4{})
    testing.expect(t,state.instances.values[1].palette[0]!=gpu.Mat4{})
    testing.expect_value(t,problems.count,0)
    // Shown again in a tick whose pose changed, it is drawn with that pose even at alpha 0: the one
    // before is of a tick it was hidden in, as the rest pose of a weapon whose action starts as it shows.
    core.add(&hidden,draws[0],{});core.table_settle(&hidden,&entities)
    tick(&app,&cache,&state,&playback,&meshes,&skins,&parents,&worlds,&tints,&overrides,&hidden,&elsewhere,&highlights,&offsets,&problems,{playing=true},{alpha=0.5})
    testing.expect(t,core.entity_map_get(&state.instances,draws[0])==nil)
    shown:=constraint_playing(&playback,roots[0]);shown.previous[2]=shown.local[2];shown.local[2].position.y+=1;shown.changed=playback.frame
    core.remove(&hidden,draws[0]);core.table_settle(&hidden,&entities)
    for alpha in ([2]f32{0,0.5}) {
        tick(&app,&cache,&state,&playback,&meshes,&skins,&parents,&worlds,&tints,&overrides,&hidden,&elsewhere,&highlights,&offsets,&problems,{playing=true},{alpha=alpha})
        instance:=core.entity_map_get(&state.instances,draws[0])
        if !testing.expect(t,instance!=nil && instance.copied) {return}
        gpu.scene_set(renderer,host.extras_instances(&app.extras),nil,{},gpu.Environment{sky={1,1,1}})
        if !testing.expect(t,gpu.renderer_frame(renderer,{camera={position={1,2,8},forward={0,-1,-8},up={0,1,0},fov_y=50,near=0.1,far=100}}),renderer.error) {return}
        result:[3]gpu.Gpu_Posed_Vertex
        testing.expect(t,rhi.buffer_read_slice(device,renderer.scene.vertex_buffer,u64(renderer.scene.meshes[instance.mesh].posed_word)*4,result[:]))
        for vertex,j in vertices {testing.expectf(t,linalg.length(result[j].position-(vertex.position+[3]f32{0,2.5,0}))<1e-5,"alpha %v: %v",alpha,result[j].position)}
    }
    testing.expect_value(t,problems.count,0)
    core.remove(&meshes,draws[0]);core.table_settle(&meshes,&entities)
    tick(&app,&cache,&state,&playback,&meshes,&skins,&parents,&worlds,&tints,&overrides,&hidden,&elsewhere,&highlights,&offsets,&problems)
    testing.expect_value(t,len(host.extras_instances(&app.extras)),1)
    testing.expect(t,len(state.instances.values)==1 && core.entity_map_get(&state.instances,draws[0])==nil && core.entity_map_get(&state.instances,draws[1]).valid)
    testing.expectf(t,rhi.device_validation_errors(device)==0,"validation: %s",rhi.device_validation_message(device))
}

// A Skin_Part makes the copy of its mesh with a part: its vertices on the
// bone of the part are drawn whole from the palette and collapsed into the
// bone from the other one, which takes the layers of the part.
@(test)
a_skin_part_collapses_the_vertices_of_its_bone_into_it :: proc(t:^testing.T) {
    problems:core.Problems
    temp,_:=os.temp_directory(context.temp_allocator)
    directory:=fmt.tprintf("%s/mirai-animation-skin-part-%d",temp,os.get_pid())
    os.make_directory(directory);defer os.remove(directory)
    path,_:=filepath.join({directory,"rig.mesh"},context.temp_allocator)
    defer os.remove(path)
    skeleton_path,_:=filepath.join({directory,"rig.skeleton"},context.temp_allocator)
    defer os.remove(skeleton_path)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    vertices:=[3]asset.Vertex{
        {position={-1,0,0},normal=mm.normal_pack({0,0,1}),color=0xffffffff},
        {position={1,0,0},normal=mm.normal_pack({0,0,1}),color=0xffffffff},
        {position={0,1,0},normal=mm.normal_pack({0,0,1}),color=0xffffffff},
    }
    influences:=[3]asset.Skin_Vertex{}
    for &influence in influences {influence.weights[0]=255}
    nodes:=[2]asset.Skeleton_Bone{{parent=-1,rotation=1,scale={1,1,1}},{parent=0,rotation=1,scale={1,1,1}}}
    for &node,i in nodes {
        name:="root" if i==0 else "head"
        bone_path:="root" if i==0 else "root/head"
        base.text_set(node.name[:],name);base.text_set(node.path[:],bone_path);node.target=base.name_hash(bone_path)
    }
    joints:=[1]asset.Rig_Joint{{node=1,inverse_bind=1}}
    id:=base.Asset_Id{0x519,0x97}
    skeleton_id:=base.Asset_Id{0x51a,0x96}
    if !testing.expect_value(t,asset.skeleton_save(skeleton_path,&types,{id=skeleton_id,bones=nodes[:]}),asset.Error.None) {return}
    if !testing.expect_value(t,rig_mesh_save(path,&types,{id=id,skeleton=skeleton_id,joints=joints[:]},vertices[:],{0,1,2},influences[:]),asset.Error.None) {return}
    device,message:=shared_device.take(t, hardware_rt = false)
    if device==nil {if !rhi.gpu_skip_allowed() {testing.expect(t,false,message)};return}
    renderer:=new(gpu.Renderer);defer free(renderer)
    settings:=gpu.DEFAULT_SETTINGS;settings.gi_enabled,settings.reflections,settings.taa=false,false,false
    if !testing.expect(t,gpu.renderer_init(renderer,{device=device,width=96,height=64,settings=settings}),renderer.error) {return}
    defer gpu.renderer_destroy(renderer)
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=directory,renderer=renderer})) {return}
    defer host.assets_destroy(&assets)
    app:=host.App{allocator=context.allocator,renderer=renderer,assets=&assets}
    defer host.extras_free(&app.extras)
    cache:Skin_Runtime;defer skin_runtime_free(&cache)
    state:Skin_Instances;defer skin_instances_free(&state)
    playback:Playback;defer playback_free(&playback)
    skeleton_assets:Skeleton_Assets;defer skeleton_assets_free(&skeleton_assets)
    entities:core.Entities;core.entities_init(&entities);defer core.entities_destroy(&entities)
    meshes:core.Table(erender.Mesh_Renderer);defer core.table_destroy(&meshes)
    skins:core.Table(Pose_Source);defer core.table_destroy(&skins)
    transforms:core.Table(core.Transform);defer core.table_destroy(&transforms)
    parents:core.Table(core.Parent);defer core.table_destroy(&parents)
    worlds:core.Table(core.World_Transform);defer core.table_destroy(&worlds)
    parts:core.Table(Skin_Part);defer core.table_destroy(&parts)
    empty_tints:core.Table(erender.Tint);defer core.table_destroy(&empty_tints)
    empty_overrides:core.Table(erender.Material_Override);defer core.table_destroy(&empty_overrides)
    empty_hidden:core.Table(erender.Hidden);defer core.table_destroy(&empty_hidden)
    empty_elsewhere:core.Table(erender.Drawn_Elsewhere);defer core.table_destroy(&empty_elsewhere)
    empty_highlights:core.Table(erender.Highlight);defer core.table_destroy(&empty_highlights)
    empty_outlines:core.Table(erender.Outline);defer core.table_destroy(&empty_outlines)
    empty_offsets:core.Table(erender.Draw_Offset);defer core.table_destroy(&empty_offsets)
    rig,draw:=core.create(&entities),core.create(&entities)
    core.add(&parents,draw,{entity=rig})
    core.add(&skins,draw,{rig=rig})
    core.add(&meshes,draw,{mesh=id})
    core.add(&parts,draw,{bone=bone_ref("head"),layers=1<<15})
    core.add(&transforms,rig,core.Transform(mm.TRANSFORM_IDENTITY))
    core.add(&worlds,rig,{transform=mm.TRANSFORM_IDENTITY,previous=mm.TRANSFORM_IDENTITY})
    core.add(&worlds,draw,{transform=mm.TRANSFORM_IDENTITY,previous=mm.TRANSFORM_IDENTITY})
    core.table_settle(&parents,&entities);core.table_settle(&skins,&entities);core.table_settle(&transforms,&entities)
    core.table_settle(&meshes,&entities);core.table_settle(&worlds,&entities);core.table_settle(&parts,&entities)
    definition:=skeleton_content(&skeleton_assets,&app,skeleton_id)
    if !testing.expect(t,definition!=nil) {return}
    pose:=state_get(&playback,rig)
    if !testing.expect(t,pose!=nil && skeleton_bind(&playback,pose,definition,nil,&transforms)) {return}
    pose.local[2].position={0.5,2,0}
    copy(pose.previous[:],pose.local[:]);pose.pose_ready=true
    animation_skin(core.read(&meshes),core.read(&skins),core.read(&parents),core.read(&worlds),core.read(&empty_tints),core.read(&empty_overrides),core.read(&empty_hidden),core.read(&empty_elsewhere),core.read(&empty_highlights),core.read(&empty_outlines),core.read(&empty_offsets),&cache,&state,&app,{},core.FRAME_TIME_DEFAULT,core.Ref(Playback){ptr=&playback},{},&problems,{},nil,ANIMATION_BUDGET_CONFIG_DEFAULT,core.read(&parts),{},{},{})
    testing.expect_value(t,problems.count,0)
    if !testing.expect_value(t,len(state.instances.values),1) {return}
    instance:=state.instances.values[0]
    testing.expect(t,instance.part==3 && instance.copied,"the copy is made with the part of bone head")
    gpu.scene_set(renderer,host.extras_instances(&app.extras),nil,{},gpu.Environment{sky={1,1,1}})
    if !testing.expect(t,gpu.renderer_frame(renderer,{camera={position={0,1,8},forward={0,0,-8},up={0,1,0},fov_y=50,near=0.1,far=100}}),renderer.error) {return}
    record:=renderer.scene.meshes[instance.mesh]
    whole,collapsed:[3]gpu.Gpu_Posed_Vertex
    testing.expect(t,rhi.buffer_read_slice(device,renderer.scene.vertex_buffer,u64(record.posed_word)*4,whole[:]))
    testing.expect(t,rhi.buffer_read_slice(device,renderer.scene.vertex_buffer,u64(record.part_word)*4,collapsed[:]))
    for v,j in vertices {
        testing.expectf(t,linalg.length(whole[j].position-(v.position+{0.5,2,0}))<1e-5,"vertex %d whole: %v",j,whole[j].position)
        testing.expectf(t,linalg.length(collapsed[j].position-[3]f32{0.5,2,0})<1e-5,"vertex %d collapsed into the bone: %v",j,collapsed[j].position)
    }
    testing.expect_value(t,renderer.scene.meshes[instance.mesh].skin.part_layers,u32(1<<15))
    testing.expectf(t,rhi.device_validation_errors(device)==0,"validation: %s",rhi.device_validation_message(device))
}

// Saves a skinned mesh of one level of vertices and indices, as an importer writes it.
@(private)
rig_mesh_save :: proc(path:string,types:^asset.Types,desc:asset.Mesh_Desc,vertices:[]asset.Vertex,indices:[]u32,skin:[]asset.Skin_Vertex) -> asset.Error {
    desc:=desc
    if !asset.mesh_build({vertices=vertices,skin=skin},indices,nil,&desc.geometry,context.temp_allocator) {return .Invalid}
    return asset.mesh_save(path,types,desc)
}
