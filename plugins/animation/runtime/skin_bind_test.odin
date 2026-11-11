package anim

import "core:log"
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

// What animation_skin reads of the World, with the poses it draws.
@(private)
@(test_world)
Bind_Pose_World :: struct {
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
    playback:Playback,
    modifiers:Modifier_Runtime,
}

// Many rigs of one skinned mesh at its bind pose draw the mesh of the world,
// shared, and make no copy of it until a pose leaves the bind.
@(test)
rigs_at_the_bind_pose_share_their_mesh_until_a_pose_leaves_it :: proc(t:^testing.T) {
    RIGS :: 64
    SIDE :: 64
    problems:core.Problems
    directory:=base.test_folder(t,"animation-bind")
    path,_:=filepath.join({directory,"grid.mesh"},context.temp_allocator)
    skeleton_path,_:=filepath.join({directory,"grid.skeleton"},context.temp_allocator)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    vertices:=make([]asset.Vertex,SIDE*SIDE);defer delete(vertices)
    influences:=make([]asset.Skin_Vertex,SIDE*SIDE);defer delete(influences)
    indices:=make([dynamic]u32);defer delete(indices)
    for y in 0..<SIDE {
        for x in 0..<SIDE {
            vertices[y*SIDE+x]={position={f32(x)/SIDE,f32(y)/SIDE,0},normal=mm.normal_pack({0,0,1}),color=0xffffffff}
            influences[y*SIDE+x].weights[7]=255
            if x+1<SIDE && y+1<SIDE {
                at:=u32(y*SIDE+x)
                append(&indices,at,at+1,at+SIDE,at+1,at+SIDE+1,at+SIDE)
            }
        }
    }
    nodes:=[2]asset.Skeleton_Bone{{parent=-1,rotation=1,scale={1,1,1}},{parent=0,rotation=1,scale={1,1,1}}}
    for &node,i in nodes {
        named:="root" if i==0 else "foot"
        full:="root" if i==0 else "root/foot"
        base.text_set(node.name[:],named);base.text_set(node.path[:],full);node.target=base.name_hash(full)
    }
    joints:=[1]asset.Rig_Joint{{node=1,inverse_bind=1}}
    id:=base.Asset_Id{0x617,0x99}
    skeleton_id:=base.Asset_Id{0x618,0x98}
    if !testing.expect_value(t,asset.skeleton_save(skeleton_path,&types,{id=skeleton_id,bones=nodes[:]}),asset.Error.None) {return}
    if !testing.expect_value(t,rig_mesh_save(path,&types,{id=id,skeleton=skeleton_id,joints=joints[:]},vertices,indices[:],influences),asset.Error.None) {return}
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
    w:Bind_Pose_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    roots,draws:[RIGS]core.Entity
    for i in 0..<RIGS {
        roots[i]=core.create(&w.entities);draws[i]=core.create(&w.entities)
        core.add(&w.parents,draws[i],{entity=roots[i]})
        core.add(&w.skins,draws[i],{rig=roots[i]})
        core.add(&w.meshes,draws[i],{mesh=id})
        transform:=mm.TRANSFORM_IDENTITY;transform.position.x=f32(i)*2
        core.add(&w.transforms,roots[i],core.Transform(transform))
        core.add(&w.worlds,roots[i],{transform=transform,previous=transform})
        core.add(&w.worlds,draws[i],{transform=transform,previous=transform})
    }
    test_world_settle(&w)
    definition:=skeleton_content(&skeleton_assets,app.assets,app.allocator,skeleton_id)
    if !testing.expect(t,definition!=nil) {return}
    for rig in roots {
        pose:=state_get(&w.playback,rig)
        if !testing.expect(t,pose!=nil && skeleton_bind(&w.playback,pose,definition,nil,&w.transforms)) {return}
        copy(pose.previous[:],pose.local[:]);pose.pose_ready=true
    }
    tick :: proc(app:^host.App,cache:^Skin_Runtime,state:^Skin_Instances,w:^Bind_Pose_World,problems:^core.Problems,posed:^erender.Posed_Meshes,modifiers:^Modifier_Runtime=nil) {
        clear(&app.extras.instances)
        animation_skin(core.read(&w.meshes),core.read(&w.skins),core.read(&w.parents),core.read(&w.worlds),&w.lives,core.read(&w.hidden),core.read(&w.elsewhere),cache,state,app.assets,app.renderer,posed,&app.jobs,app.allocator,{},core.FRAME_TIME_DEFAULT,core.Ref(Playback){ptr=&w.playback},{},problems,{},nil,ANIMATION_BUDGET_CONFIG_DEFAULT,{},core.Ref(Modifier_Runtime){ptr=modifiers},{},nil)
        skin_shown(app,posed,core.read(&w.meshes),core.read(&w.worlds),core.read(&w.offsets),core.read(&w.parents),core.FRAME_TIME_DEFAULT)
    }
    measure :: proc(renderer:^gpu.Renderer,label:string) -> int {
        s:=&renderer.scene
        bytes:=len(s.vertices)*size_of(u32)+len(s.blas_nodes)*size_of(gpu.Gpu_Bvh_Node)+len(s.blas_triangles)*size_of(gpu.Gpu_Bvh_Triangle)
        log.infof("%s: %d skinned copies, %d vertices, %d BVH nodes, %d BVH triangles, %.1f MB of geometry",label,len(s.skinned),len(s.vertices),len(s.blas_nodes),len(s.blas_triangles),f64(bytes)/(1<<20))
        return len(s.skinned)
    }
    measure(renderer,"loaded")
    tick(&app,&cache,&state,&w,&problems,&posed)
    testing.expect_value(t,problems.count,0)
    testing.expect_value(t,measure(renderer,"64 rigs at the bind pose"),0)
    testing.expect_value(t,len(host.extras_instances(&app.extras)),0)

    // A pose that leaves the bind makes the copy of that rig alone.
    pose:=constraint_playing(&w.playback,roots[0])
    pose.local[1].position.y=0.5
    copy(pose.previous[:],pose.local[:])
    pose.changed+=1
    tick(&app,&cache,&state,&w,&problems,&posed)
    testing.expect_value(t,measure(renderer,"one rig posed"),1)
    if !testing.expect_value(t,len(host.extras_instances(&app.extras)),1) {return}
    gpu.scene_set_environment(renderer,{},gpu.Environment{sky={1,1,1}})
    gpu.scene_update(renderer,0,host.extras_instances(&app.extras),true)
    if !testing.expect(t,gpu.renderer_frame(renderer,{camera={position={1,2,8},forward={0,-1,-8},up={0,1,0},fov_y=50,near=0.1,far=100}}),renderer.error) {return}
    record:=renderer.scene.meshes[core.entity_map_get(&state.instances,draws[0]).mesh]
    result:[1]gpu.Gpu_Posed_Vertex
    testing.expect(t,rhi.buffer_read_slice(device,renderer.scene.vertex_buffer,u64(record.posed_word)*4,result[:]))
    testing.expect_value(t,result[0].position,vertices[0].position+[3]f32{0,0.5,0})
    testing.expect_value(t,problems.count,0)

    // A rig at the bind whose curves move a material value stays the mesh of the world: the value is the Material_Live of its mesh.
    still:=constraint_playing(&w.playback,roots[1])
    append(&still.curves,Curve_Output{target=base.name_hash("blush"),property=.Float,value={1,0,0,0},weight=1})
    blush:=CURVE_MATERIAL_DEFAULT;blush.rig,blush.every,blush.scale=roots[1],true,{1,0,0,0}
    base.text_set(blush.curve[:],"blush");base.text_set(blush.parameter[:],"base_color")
    testing.expect(t,modifier_append(&w.modifiers.curve_materials,roots[1],blush))
    tick(&app,&cache,&state,&w,&problems,&posed,&w.modifiers)
    test_world_settle(&w)
    testing.expect_value(t,measure(renderer,"one rig posed and one with curve materials"),1)
    live,_:=core.get(&w.lives,draws[1])
    given:=erender.material_value_find(&live,0,base.name_hash("base_color"))
    testing.expect(t,given>=0 && live.values[given]==[4]f32{1,0,0,0},"the value of the curve is live on the entity")
    instance:=core.entity_map_get(&state.instances,draws[1])
    testing.expect(t,instance!=nil && !instance.copied,"the still rig with curve materials makes no copy")
    // A curve that stops playing takes its value away.
    still.curves[0].weight=0
    tick(&app,&cache,&state,&w,&problems,&posed,&w.modifiers)
    test_world_settle(&w)
    testing.expect(t,!core.has(&w.lives,draws[1]))
    testing.expect_value(t,problems.count,0)
    testing.expectf(t,rhi.device_validation_errors(device)==0,"validation: %s",rhi.device_validation_message(device))
    testing.expectf(t,rhi.device_validation_errors(device)==0,"validation: %s",rhi.device_validation_message(device))
}
