package anim

import "core:fmt"
import "core:math/linalg"
import "core:mem"
import "core:path/filepath"
import "core:slice"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import erender "mirai:engine/render"
import "mirai:host"
import gpu "mirai:render"
import "mirai:rhi"
import "mirai:rhi/shared_device"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"

// What animation_skin reads of the World, with the poses it draws.
@(private)
@(test_world)
Skin_World :: struct {
    using world:Test_World,
    meshes:core.Table(erender.Mesh_Renderer),
    skins:core.Table(Pose_Source),
    transforms:core.Table(core.Transform),
    parents:core.Table(core.Parent),
    worlds:core.Table(core.World_Transform),
    lives:core.Table(erender.Material_Live),
    hidden:core.Table(erender.Hidden),
    elsewhere:core.Table(erender.Drawn_Elsewhere),
    highlights:core.Table(erender.Highlight),
    outlines:core.Table(erender.Outline),
    offsets:core.Table(erender.Draw_Offset),
    parts:core.Table(Skin_Part),
    playback:Playback,
}

// The instances the posed meshes of a world are drawn with, as render_sync
// makes them, in the visual instances of the application: the mesh of each
// entity where it is drawn (erender.instance_place, with the Draw_Offset of
// what it hangs from), with its pose.
@(private)
skin_shown :: proc(app:^host.App,posed:^erender.Posed_Meshes,meshes:^core.Table(erender.Mesh_Renderer,$A),worlds:^core.Table(core.World_Transform,$B),offsets:^core.Table(erender.Draw_Offset,$C),parents:^core.Table(core.Parent,$D),frame:core.Frame_Time) {
    clear(&app.extras.instances)
    for pose,i in posed.poses.values {
        e:=posed.poses.entities[i]
        static,_:=core.get(meshes,e)
        world,_:=core.get(worlds,e)
        anchor,transform:=erender.instance_place(world,frame,offsets,parents,worlds,nil,nil,e)
        instance,_:=erender.mesh_instance(app.assets,static,transform)
        instance.mesh,instance.object_id,instance.anchor=pose.mesh,u64(e),anchor
        host.extras_instance_add(&app.extras,instance)
    }
}

@(test)
skeletal_instances_use_independent_dense_poses_and_eighth_influence :: proc(t:^testing.T) {
    problems:core.Problems
    directory:=base.test_folder(t,"animation-skin")
    path,_:=filepath.join({directory,"rig.mesh"},context.temp_allocator)
    skeleton_path,_:=filepath.join({directory,"rig.skeleton"},context.temp_allocator)
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
    device:=shared_device.take_or_skip(t,hardware_rt=false)
    if device==nil {return}
    renderer:=new(gpu.Renderer);defer free(renderer)
    settings:=gpu.DEFAULT_SETTINGS;settings.gi_enabled,settings.taa=false,false
    if !testing.expect(t,gpu.renderer_init(renderer,{device=device,width=96,height=64,settings=settings}),renderer.error) {return}
    defer gpu.renderer_destroy(renderer)
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=directory,renderer=renderer})) {return}
    defer host.assets_destroy(&assets)
    app:=host.App{allocator=context.allocator,renderer=renderer,assets=&assets}
    defer host.extras_free(&app.extras)
    cache:Skin_Runtime;defer skin_runtime_free(&cache)
    state:Skin_Instances;defer skin_instances_free(&state)
    posed:erender.Posed_Meshes;defer core.value_free(&posed,type_info_of(erender.Posed_Meshes))
    skeleton_assets:Skeleton_Assets;defer skeleton_assets_free(&skeleton_assets)
    w:Skin_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    roots,draws:[2]core.Entity
    for i in 0..<2 {
        roots[i]=core.create(&w.entities);draws[i]=core.create(&w.entities)
        core.add(&w.parents,draws[i],{entity=roots[i]})
        core.add(&w.skins,draws[i],{rig=roots[i]})
        core.add(&w.meshes,draws[i],{mesh=id})
        transform:=mm.TRANSFORM_IDENTITY;transform.position.x=f32(i)*3
        core.add(&w.transforms,roots[i],core.Transform(transform))
        core.add(&w.worlds,roots[i],{transform=transform,previous=transform})
        core.add(&w.worlds,draws[i],{transform=transform,previous=transform})
    }
    core.add(&w.offsets,roots[0],{offset={0,2,0}})
    test_world_settle(&w)
    definition:=skeleton_content(&skeleton_assets,app.assets,app.allocator,skeleton_id)
    if !testing.expect(t,definition!=nil) {return}
    for rig,i in roots {
        pose:=state_get(&w.playback,rig)
        if !testing.expect(t,pose!=nil && skeleton_bind(&w.playback,pose,definition,nil,&w.transforms)) {return}
        playing_pose(pose,.Local)[2].position.y=f32(i)+0.5
        copy(playing_pose(pose,.Previous),playing_pose(pose,.Local));pose.pose_ready=true
        testing.expect_value(t,len(playing_pose(pose,.Local)),3)
        testing.expect(t,pose.bindings[1].entity==core.NONE && pose.bindings[2].entity==core.NONE)
    }
    tick :: proc(app:^host.App,cache:^Skin_Runtime,state:^Skin_Instances,w:^Skin_World,problems:^core.Problems,posed:^erender.Posed_Meshes,time:core.Time={},frame:=core.FRAME_TIME_DEFAULT) {
        clear(&app.extras.instances)
        animation_skin(core.read(&w.meshes),core.read(&w.skins),core.read(&w.parents),core.read(&w.worlds),&w.lives,core.read(&w.hidden),core.read(&w.elsewhere),cache,state,app.assets,app.renderer,posed,&app.jobs,app.allocator,time,frame,core.Ref(Playback){ptr=&w.playback},{},problems,{},nil,ANIMATION_BUDGET_CONFIG_DEFAULT,{},{},{},{})
        skin_shown(app,posed,core.read(&w.meshes),core.read(&w.worlds),core.read(&w.offsets),core.read(&w.parents),frame)
    }
    tick(&app,&cache,&state,&w,&problems,&posed)
    if !testing.expect_value(t,len(host.extras_instances(&app.extras)),2) {return}
    testing.expect_value(t,host.extras_instances(&app.extras)[0].transform[1,3],f32(2))
    testing.expect_value(t,len(cache.rigs),1)
    testing.expect_value(t,problems.count,0)
    for instance in state.instances.values {testing.expect_value(t,len(instance.palette),1)}
    gpu.scene_set_environment(renderer,{},gpu.Environment{sky={1,1,1}})
    gpu.scene_update(renderer,0,host.extras_instances(&app.extras),true)
    if !testing.expect(t,gpu.renderer_frame(renderer,{camera={position={1,2,8},forward={0,-1,-8},up={0,1,0},fov_y=50,near=0.1,far=100}}),renderer.error) {return}
    for instance,i in state.instances.values {
        record:=renderer.scene.meshes[instance.mesh]
        result:[3]gpu.Gpu_Posed_Vertex
        testing.expect(t,rhi.buffer_read_slice(device,renderer.scene.vertex_buffer,u64(record.posed_word)*4,result[:]))
        for v,j in vertices {testing.expect_value(t,result[j].position,v.position+[3]f32{0,f32(i)+0.5,0})}
    }
    // A tick that changes the poses, which the frames between it and the next interpolate.
    w.playback.frame+=1
    for root,i in roots {
        pose:=constraint_playing(core.ref(&w.playback),root)
        pose.changed=w.playback.frame
        playing_pose(pose,.Local)[0].rotation=mm.quat_axis_angle({0,0,1},0.3)
        playing_pose(pose,.Local)[0].scale={1.3,0.8,-1.1}
        playing_pose(pose,.Previous)[0]=playing_pose(pose,.Local)[0]
        playing_pose(pose,.Local)[2].position.y+=1
        for entity in ([2]core.Entity{root,draws[i]}) {
            placed:=core.edit(&w.worlds,entity)
            placed.transform,placed.previous=playing_pose(pose,.Local)[0],playing_pose(pose,.Local)[0]
        }
    }
    for alpha in ([4]f32{0,0.25,0.75,1}) {
        tick(&app,&cache,&state,&w,&problems,&posed,{playing=true},{alpha=alpha})
        gpu.scene_set_environment(renderer,{},gpu.Environment{sky={1,1,1}})
        gpu.scene_update(renderer,0,host.extras_instances(&app.extras),true)
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
    w.playback.frame+=1
    for &instance in state.instances.values {instance.palette[0]={}}
    tick(&app,&cache,&state,&w,&problems,&posed,{playing=true},{alpha=0.5})
    for instance in state.instances.values {testing.expect_value(t,instance.palette[0],gpu.Mat4{})}
    moved:=core.edit(&w.worlds,draws[1]);moved.transform.position.x+=1;moved.previous=moved.transform
    tick(&app,&cache,&state,&w,&problems,&posed,{playing=true},{alpha=0.5})
    testing.expect_value(t,state.instances.values[0].palette[0],gpu.Mat4{})
    testing.expect(t,state.instances.values[1].palette[0]!=gpu.Mat4{})
    testing.expect_value(t,problems.count,0)
    // Shown again in a tick whose pose changed, it is drawn with that pose even at alpha 0: the one
    // before is of a tick it was w.hidden in, as the rest pose of a weapon whose action starts as it shows.
    core.add(&w.hidden,draws[0],{});test_world_settle(&w)
    tick(&app,&cache,&state,&w,&problems,&posed,{playing=true},{alpha=0.5})
    testing.expect(t,core.entity_map_get(&state.instances,draws[0])==nil)
    shown:=constraint_playing(core.ref(&w.playback),roots[0]);playing_pose(shown,.Previous)[2]=playing_pose(shown,.Local)[2];playing_pose(shown,.Local)[2].position.y+=1;shown.changed=w.playback.frame
    core.remove(&w.hidden,draws[0]);test_world_settle(&w)
    for alpha in ([2]f32{0,0.5}) {
        tick(&app,&cache,&state,&w,&problems,&posed,{playing=true},{alpha=alpha})
        instance:=core.entity_map_get(&state.instances,draws[0])
        if !testing.expect(t,instance!=nil && instance.copied) {return}
        gpu.scene_set_environment(renderer,{},gpu.Environment{sky={1,1,1}})
        gpu.scene_update(renderer,0,host.extras_instances(&app.extras),true)
        if !testing.expect(t,gpu.renderer_frame(renderer,{camera={position={1,2,8},forward={0,-1,-8},up={0,1,0},fov_y=50,near=0.1,far=100}}),renderer.error) {return}
        result:[3]gpu.Gpu_Posed_Vertex
        testing.expect(t,rhi.buffer_read_slice(device,renderer.scene.vertex_buffer,u64(renderer.scene.meshes[instance.mesh].posed_word)*4,result[:]))
        for vertex,j in vertices {testing.expectf(t,linalg.length(result[j].position-(vertex.position+[3]f32{0,2.5,0}))<1e-5,"alpha %v: %v",alpha,result[j].position)}
    }
    testing.expect_value(t,problems.count,0)
    core.remove(&w.meshes,draws[0]);test_world_settle(&w)
    tick(&app,&cache,&state,&w,&problems,&posed)
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
    directory:=base.test_folder(t,"animation-skin-part")
    path,_:=filepath.join({directory,"rig.mesh"},context.temp_allocator)
    skeleton_path,_:=filepath.join({directory,"rig.skeleton"},context.temp_allocator)
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
    device:=shared_device.take_or_skip(t,hardware_rt=false)
    if device==nil {return}
    renderer:=new(gpu.Renderer);defer free(renderer)
    settings:=gpu.DEFAULT_SETTINGS;settings.gi_enabled,settings.taa=false,false
    if !testing.expect(t,gpu.renderer_init(renderer,{device=device,width=96,height=64,settings=settings}),renderer.error) {return}
    defer gpu.renderer_destroy(renderer)
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=directory,renderer=renderer})) {return}
    defer host.assets_destroy(&assets)
    app:=host.App{allocator=context.allocator,renderer=renderer,assets=&assets}
    defer host.extras_free(&app.extras)
    cache:Skin_Runtime;defer skin_runtime_free(&cache)
    state:Skin_Instances;defer skin_instances_free(&state)
    posed:erender.Posed_Meshes;defer core.value_free(&posed,type_info_of(erender.Posed_Meshes))
    skeleton_assets:Skeleton_Assets;defer skeleton_assets_free(&skeleton_assets)
    w:Skin_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    rig,draw:=core.create(&w.entities),core.create(&w.entities)
    core.add(&w.parents,draw,{entity=rig})
    core.add(&w.skins,draw,{rig=rig})
    core.add(&w.meshes,draw,{mesh=id})
    core.add(&w.parts,draw,{bone=bone_ref("head"),layers=1<<15})
    core.add(&w.transforms,rig,core.Transform(mm.TRANSFORM_IDENTITY))
    core.add(&w.worlds,rig,{transform=mm.TRANSFORM_IDENTITY,previous=mm.TRANSFORM_IDENTITY})
    core.add(&w.worlds,draw,{transform=mm.TRANSFORM_IDENTITY,previous=mm.TRANSFORM_IDENTITY})
    test_world_settle(&w)
    definition:=skeleton_content(&skeleton_assets,app.assets,app.allocator,skeleton_id)
    if !testing.expect(t,definition!=nil) {return}
    pose:=state_get(&w.playback,rig)
    if !testing.expect(t,pose!=nil && skeleton_bind(&w.playback,pose,definition,nil,&w.transforms)) {return}
    playing_pose(pose,.Local)[2].position={0.5,2,0}
    copy(playing_pose(pose,.Previous),playing_pose(pose,.Local));pose.pose_ready=true
    animation_skin(core.read(&w.meshes),core.read(&w.skins),core.read(&w.parents),core.read(&w.worlds),&w.lives,core.read(&w.hidden),core.read(&w.elsewhere),&cache,&state,app.assets,app.renderer,&posed,&app.jobs,app.allocator,{},core.FRAME_TIME_DEFAULT,core.Ref(Playback){ptr=&w.playback},{},&problems,{},nil,ANIMATION_BUDGET_CONFIG_DEFAULT,core.read(&w.parts),{},{},{})
    skin_shown(&app,&posed,core.read(&w.meshes),core.read(&w.worlds),core.read(&w.offsets),core.read(&w.parents),core.FRAME_TIME_DEFAULT)
    testing.expect_value(t,problems.count,0)
    if !testing.expect_value(t,len(state.instances.values),1) {return}
    instance:=state.instances.values[0]
    testing.expect(t,instance.part==3 && instance.copied,"the copy is made with the part of bone head")
    gpu.scene_set_environment(renderer,{},gpu.Environment{sky={1,1,1}})
    gpu.scene_update(renderer,0,host.extras_instances(&app.extras),true)
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

// The loop the automatic palette period runs in: the fixed steps of the animation and the skin.
@(private)
@(test_world)
Skin_Loop_World :: struct {
    using world:Test_World,
    transforms:core.Table(core.Transform),
    parents:core.Table(core.Parent),
    labels:core.Table(core.Name),
    meshes:core.Table(erender.Mesh_Renderer),
    skins:core.Table(Pose_Source),
    animations:core.Table(Animation),
    targets:core.Table(Animation_Target),
    progress:core.Table(Animation_Progress),
    attachments:core.Table(Bone_Attachment),
    worlds:core.Table(core.World_Transform),
    played:core.Table(Animation_Played),
    remotes:core.Table(core.Remote),
    lives:core.Table(erender.Material_Live),
    hidden:core.Table(erender.Hidden),
    elsewhere:core.Table(erender.Drawn_Elsewhere),
    parts:core.Table(Skin_Part),
    requests:Animation_Requests,
    events:Animation_Events,
    playback:Playback,
    modifiers:Modifier_Runtime,
    actions:Action_Runtime,
    motion:Motion_Runtime,
    budget:Budget_Runtime,
}

// The palettes the automatic period leaves for later are presentation only: from one snapshot, the
// same ticks with the camera near, where every palette is made, and far, where most wait, leave
// the simulation the same, bit for bit.
@(test)
the_automatic_period_leaves_the_simulation_as_it_is :: proc(t:^testing.T) {
    TICKS :: 30
    problems:core.Problems
    directory:=base.test_folder(t,"animation-skin-loop")
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    bones:=[3]asset.Skeleton_Bone{{parent=-1,translation={0,2,0},rotation=1,scale={1,1,1}},{parent=0,translation={0,-1,0},rotation=1,scale={1,1,1}},{parent=1,translation={0,-1,0},rotation=1,scale={1,1,1}}}
    paths:=[3]string{"upper","upper/lower","upper/lower/foot"}
    names:=[3]string{"upper","lower","foot"}
    for &bone,i in bones {base.text_set(bone.path[:],paths[i]);base.text_set(bone.name[:],names[i]);bone.target=base.name_hash(paths[i])}
    skeleton,mesh,clips:=base.Asset_Id{0x5b1,1},base.Asset_Id{0x5b1,2},base.Asset_Id{0x5b1,3}
    vertices:=[3]asset.Vertex{{position={-1,0,0},normal=mm.normal_pack({0,0,1}),color=0xffffffff},{position={1,0,0},normal=mm.normal_pack({0,0,1}),color=0xffffffff},{position={0,1,0},normal=mm.normal_pack({0,0,1}),color=0xffffffff}}
    influences:[3]asset.Skin_Vertex
    for &influence in influences {influence.weights[0]=255}
    joints:=[1]asset.Rig_Joint{{node=1,inverse_bind=1}}
    turn:=[2]lib.Keyframe{{time=0,value=lib.quat_vec4(1)},{time=1,value=lib.quat_vec4(mm.quat_axis_angle({1,0,0},mm.PI*0.5))}}
    if !testing.expect_value(t,asset.skeleton_save(fmt.tprintf("%s/rig.skeleton",directory),&types,{id=skeleton,bones=bones[:]}),asset.Error.None) ||
       !testing.expect_value(t,rig_mesh_save(fmt.tprintf("%s/rig.mesh",directory),&types,{id=mesh,skeleton=skeleton,joints=joints[:]},vertices[:],{0,1,2},influences[:]),asset.Error.None) ||
       !testing.expect_value(t,asset.animation_save(fmt.tprintf("%s/rig.anim",directory),&types,{id=clips,clips={{name="lift",tracks={{target="upper/lower",property=.Rotation,keys=turn[:]}}}}}),asset.Error.None) {return}
    device:=shared_device.take_or_skip(t,hardware_rt=false)
    if device==nil {return}
    renderer:=new(gpu.Renderer);defer free(renderer)
    settings:=gpu.DEFAULT_SETTINGS;settings.gi_enabled,settings.taa=false,false
    if !testing.expect(t,gpu.renderer_init(renderer,{device=device,width=96,height=64,settings=settings}),renderer.error) {return}
    defer gpu.renderer_destroy(renderer)
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=directory,renderer=renderer})) {return}
    defer host.assets_destroy(&assets)
    app:=host.App{allocator=context.allocator,renderer=renderer,assets=&assets}
    defer {host.extras_free(&app.extras);host.app_content_destroy(&app)}
    if !testing.expect(t,host.content_animation_wait(&app,clips)!=nil) {return}
    cache:Skin_Runtime;defer skin_runtime_free(&cache)
    state:Skin_Instances;defer skin_instances_free(&state)
    posed:erender.Posed_Meshes;defer core.value_free(&posed,type_info_of(erender.Posed_Meshes))
    skeletons:Skeleton_Assets;defer skeleton_assets_free(&skeletons)
    characters:Character_Assets;defer character_assets_free(&characters)
    sources:Source_Assets;defer source_assets_free(&sources)
    w,kept,near:=new(Skin_Loop_World),new(Skin_Loop_World),new(Skin_Loop_World)
    defer {free(w);free(kept);free(near)}
    if !test_world_init(t,w) || !test_world_init(t,kept) || !test_world_init(t,near) {return}
    defer {test_world_destroy(w);test_world_destroy(kept);test_world_destroy(near)}
    rig:=core.create(&w.entities)
    core.add(&w.transforms,rig,core.TRANSFORM_IDENTITY)
    core.add(&w.worlds,rig,{transform=mm.TRANSFORM_IDENTITY,previous=mm.TRANSFORM_IDENTITY})
    core.add(&w.meshes,rig,{mesh=mesh})
    animation:=ANIMATION_DEFAULT;animation.asset=clips;base.text_set(animation.clip[:],"lift")
    core.add(&w.animations,rig,animation)
    test_world_settle(w)
    view:=core.VIEW_DEFAULT;view.size={1920,1080}
    play :: proc(w:^Skin_Loop_World,app:^host.App,cache:^Skin_Runtime,state:^Skin_Instances,posed:^erender.Posed_Meshes,skeletons:^Skeleton_Assets,characters:^Character_Assets,sources:^Source_Assets,view:^core.View,problems:^core.Problems,ticks:int) {
        for _ in 0..<ticks {
            time:=core.Time{tick=w.playback.frame,dt=1.0/60,playing=true}
            animation_prepare(core.read(&w.animations),core.read(&w.attachments),core.read(&w.meshes),core.read(&w.skins),&w.modifiers,&w.playback,characters,skeletons,app,problems)
            animation_sample(core.read(&w.animations),core.read(&w.progress),&w.played,&w.transforms,core.read(&w.parents),{},core.read(&w.labels),core.read(&w.targets),core.read(&w.remotes),&w.requests,&w.events,&w.modifiers,&w.playback,characters,skeletons,app,time,{},problems,&w.actions,&w.motion,sources,{},core.CLOCK_DEFAULT,ANIMATION_BUDGET_CONFIG_DEFAULT,{},{})
            animation_advance(&w.transforms,core.read(&w.parents),core.read(&w.worlds),&w.requests,&w.modifiers,&w.playback,{},{},time,{ptr=skeletons},problems,&w.motion,characters,{},{},core.CLOCK_DEFAULT,nil)
            animation_skin(core.read(&w.meshes),core.read(&w.skins),core.read(&w.parents),core.read(&w.worlds),&w.lives,core.read(&w.hidden),core.read(&w.elsewhere),cache,state,app.assets,app.renderer,posed,&app.jobs,app.allocator,time,{dt=1.0/60,alpha=1},{ptr=&w.playback},{},problems,{},&w.budget,ANIMATION_BUDGET_CONFIG_DEFAULT,core.read(&w.parts),{},{ptr=view},{})
        }
    }
    play(w,&app,&cache,&state,&posed,&skeletons,&characters,&sources,&view,&problems,3)
    if !testing.expect(t,test_world_copy(kept,w)) {return}
    view.position={0,1,4}
    play(w,&app,&cache,&state,&posed,&skeletons,&characters,&sources,&view,&problems,TICKS)
    near_throttled:=w.budget.throttled-kept.budget.throttled
    if !testing.expect(t,test_world_copy(near,w) && test_world_copy(w,kept)) {return}
    view.position={0,1,600}
    play(w,&app,&cache,&state,&posed,&skeletons,&characters,&sources,&view,&problems,TICKS)
    far_throttled:=w.budget.throttled-kept.budget.throttled
    testing.expectf(t,near_throttled==0 && far_throttled>TICKS/2,"palettes left for later: %d near, %d far, of %d ticks",near_throttled,far_throttled,TICKS)
    testing.expect_value(t,problems.count,0)
    same :: proc(a,b:[]$T) -> bool {return len(a)==len(b) && mem.compare(slice.to_bytes(a),slice.to_bytes(b))==0}
    testing.expect(t,same(w.transforms.values[:],near.transforms.values[:]) && same(w.progress.values[:],near.progress.values[:]) && same(w.played.values[:],near.played.values[:]) && same(w.events.items[:],near.events.items[:]),"the tables of the simulation")
    if !testing.expect(t,len(w.playback.states)==1 && len(near.playback.states)==1) {return}
    a,b:=&w.playback.states[0],&near.playback.states[0]
    testing.expect(t,!same(playing_pose(a,.Local)[1:],playing_topology(a).rest[1:]),"the clip moves the rig")
    testing.expect(t,same(playing_pose(a,.Local),playing_pose(b,.Local)) && same(playing_pose(a,.Sampled),playing_pose(b,.Sampled)) && same(playing_pose(a,.Previous),playing_pose(b,.Previous)) && a.time==b.time && a.changed==b.changed && w.playback.frame==near.playback.frame,"the poses")
    testing.expectf(t,rhi.device_validation_errors(device)==0,"validation: %s",rhi.device_validation_message(device))
}

// Skinned parts following one root rig (including a chained follower rig such as a head with eyes)
// share one budget entry using the rig's largest screen footprint, so tiny parts never lag behind
// the body when the rig moves.
@(test)
multi_mesh_rig_parts_share_one_budget_decision :: proc(t:^testing.T) {
    problems:core.Problems
    directory:=base.test_folder(t,"animation-skin-rig-budget")
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    bones:=[2]asset.Skeleton_Bone{{parent=-1,rotation=1,scale={1,1,1}},{parent=0,translation={0,1,0},rotation=1,scale={1,1,1}}}
    for &bone,i in bones {
        name:="root" if i==0 else "head"
        path:="root" if i==0 else "root/head"
        base.text_set(bone.name[:],name);base.text_set(bone.path[:],path);bone.target=base.name_hash(path)
    }
    skeleton,body_id,eye_id:=base.Asset_Id{0x5c1,1},base.Asset_Id{0x5c1,2},base.Asset_Id{0x5c1,3}
    body_verts:=[3]asset.Vertex{{position={-1,0,0},normal=mm.normal_pack({0,0,1}),color=0xffffffff},{position={1,0,0},normal=mm.normal_pack({0,0,1}),color=0xffffffff},{position={0,2,0},normal=mm.normal_pack({0,0,1}),color=0xffffffff}}
    eye_verts:=[3]asset.Vertex{{position={-0.02,1,0},normal=mm.normal_pack({0,0,1}),color=0xffffffff},{position={0.02,1,0},normal=mm.normal_pack({0,0,1}),color=0xffffffff},{position={0,1.02,0},normal=mm.normal_pack({0,0,1}),color=0xffffffff}}
    influences:[3]asset.Skin_Vertex
    for &influence in influences {influence.weights[0]=255}
    joints:=[1]asset.Rig_Joint{{node=1,inverse_bind=1}}
    if !testing.expect_value(t,asset.skeleton_save(fmt.tprintf("%s/rig.skeleton",directory),&types,{id=skeleton,bones=bones[:]}),asset.Error.None) ||
       !testing.expect_value(t,rig_mesh_save(fmt.tprintf("%s/body.mesh",directory),&types,{id=body_id,skeleton=skeleton,joints=joints[:]},body_verts[:],{0,1,2},influences[:]),asset.Error.None) ||
       !testing.expect_value(t,rig_mesh_save(fmt.tprintf("%s/eye.mesh",directory),&types,{id=eye_id,skeleton=skeleton,joints=joints[:]},eye_verts[:],{0,1,2},influences[:]),asset.Error.None) {return}
    device:=shared_device.take_or_skip(t,hardware_rt=false)
    if device==nil {return}
    renderer:=new(gpu.Renderer);defer free(renderer)
    settings:=gpu.DEFAULT_SETTINGS;settings.gi_enabled,settings.taa=false,false
    if !testing.expect(t,gpu.renderer_init(renderer,{device=device,width=96,height=64,settings=settings}),renderer.error) {return}
    defer gpu.renderer_destroy(renderer)
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=directory,renderer=renderer})) {return}
    defer host.assets_destroy(&assets)
    app:=host.App{allocator=context.allocator,renderer=renderer,assets=&assets}
    defer host.extras_free(&app.extras)
    cache:Skin_Runtime;defer skin_runtime_free(&cache)
    state:Skin_Instances;defer skin_instances_free(&state)
    posed:erender.Posed_Meshes;defer core.value_free(&posed,type_info_of(erender.Posed_Meshes))
    skeleton_assets:Skeleton_Assets;defer skeleton_assets_free(&skeleton_assets)
    budget:Budget_Runtime;defer budget_runtime_free(&budget)
    w:Skin_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    root,body,head_rig,eyes:=core.create(&w.entities),core.create(&w.entities),core.create(&w.entities),core.create(&w.entities)
    core.add(&w.parents,body,{entity=root})
    core.add(&w.parents,head_rig,{entity=root})
    core.add(&w.parents,eyes,{entity=head_rig})
    core.add(&w.skins,body,{rig=root})
    core.add(&w.skins,head_rig,{rig=root})
    core.add(&w.skins,eyes,{rig=head_rig})
    core.add(&w.meshes,body,{mesh=body_id})
    core.add(&w.meshes,eyes,{mesh=eye_id})
    for e in ([4]core.Entity{root,body,head_rig,eyes}) {
        core.add(&w.transforms,e,core.TRANSFORM_IDENTITY)
        core.add(&w.worlds,e,{transform=mm.TRANSFORM_IDENTITY,previous=mm.TRANSFORM_IDENTITY})
    }
    test_world_settle(&w)
    definition:=skeleton_content(&skeleton_assets,app.assets,app.allocator,skeleton)
    if !testing.expect(t,definition!=nil) {return}
    root_pose:=state_get(&w.playback,root)
    head_pose:=state_get(&w.playback,head_rig)
    if !testing.expect(t,root_pose!=nil && head_pose!=nil && skeleton_bind(&w.playback,root_pose,definition,nil,&w.transforms) && skeleton_bind(&w.playback,head_pose,definition,nil,&w.transforms)) {return}
    head_pose.leader=root
    for p in ([2]^Playing{root_pose,head_pose}) {
        playing_pose(p,.Local)[2].position.y=0.5
        copy(playing_pose(p,.Previous),playing_pose(p,.Local))
        p.pose_ready=true
    }
    // At 15m, the 2m body spans ~140px (updates every frame at 60fps), while 2cm eyes span ~2px
    // and would wait 15 frames if budgeted independently. Both must stay in lockstep.
    view:=core.VIEW_DEFAULT;view.position={0,1,15};view.size={1920,1080}
    for tick in 1..=12 {
        w.playback.frame=u64(tick)
        for p in ([2]^Playing{root_pose,head_pose}) {
            copy(playing_pose(p,.Previous),playing_pose(p,.Local))
            playing_pose(p,.Local)[2].position.x=f32(tick)*0.1
            p.changed=w.playback.frame
        }
        animation_skin(core.read(&w.meshes),core.read(&w.skins),core.read(&w.parents),core.read(&w.worlds),&w.lives,core.read(&w.hidden),core.read(&w.elsewhere),&cache,&state,app.assets,app.renderer,&posed,&app.jobs,app.allocator,{tick=u64(tick),dt=1.0/60,playing=true},{dt=1.0/60,alpha=1},{ptr=&w.playback},{},&problems,{},&budget,ANIMATION_BUDGET_CONFIG_DEFAULT,{},{},{ptr=&view},{})
        testing.expect_value(t,len(state.candidates),1)
        body_inst:=core.entity_map_get(&state.instances,body)
        eyes_inst:=core.entity_map_get(&state.instances,eyes)
        if !testing.expect(t,body_inst!=nil && eyes_inst!=nil) {return}
        testing.expectf(t,body_inst.exact==eyes_inst.exact,"tick %d: body exact %d != eyes exact %d",tick,body_inst.exact,eyes_inst.exact)
    }
    testing.expect_value(t,budget.throttled,u64(0))
    testing.expect_value(t,problems.count,0)
    testing.expectf(t,rhi.device_validation_errors(device)==0,"validation: %s",rhi.device_validation_message(device))
}
