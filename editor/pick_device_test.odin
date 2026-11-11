package editor

import "core:testing"
import "mirai:core"
import "mirai:editor/history"
import erender "mirai:engine/render"
import "mirai:host"
import gpu "mirai:render"
import "mirai:rhi/shared_device"
import mm "mirai:std/math"

@(private)
pick_device_open :: proc(t:^testing.T,d:^Pick_Device) -> bool {
    device:=shared_device.take_or_skip(t,hardware_rt=false)
    if device==nil {return false}
    settings:=gpu.DEFAULT_SETTINGS;settings.gi_enabled=false
    if !testing.expect(t,gpu.renderer_init(&d.renderer,{device=device,width=64,height=64,settings=settings}),d.renderer.error) {return false}
    if !testing.expect(t,host.assets_init(&d.assets,{root="assets",capacity=8,renderer=&d.renderer})) {
        gpu.renderer_destroy(&d.renderer)
        return false
    }
    d.open=true
    return true
}

@(test)
derived_geometry_selects_its_author_and_keeps_internal_nodes_out_of_the_tree :: proc(t:^testing.T) {
    world:Pick_Test_World
    if !test_world_init(t,&world) {return}
    defer test_world_destroy(&world)
    ref:=test_world_ref(&world)
    owner,child,empty,orphan:=core.create(&world.entities),core.create(&world.entities),core.create(&world.entities),core.create(&world.entities)
    core.add(&world.ids,owner,core.Id{value=1})
    for e in ([3]core.Entity{owner,child,empty}) {core.add(&world.transforms,e,core.TRANSFORM_IDENTITY)}
    core.add(&world.transforms,orphan,core.Transform{position={20,0,0},rotation=1,scale={1,1,1}})
    core.add(&world.parents,child,core.Parent{entity=owner})
    core.add(&world.parents,empty,core.Parent{entity=owner})
    core.add(&world.meshes,owner,{})
    core.add(&world.meshes,child,{shape=.Cube})
    test_world_settle(&world)
    testing.expect_value(t,entity_author(ref,child),owner)
    testing.expect_value(t,entity_author(ref,empty),owner)
    testing.expect_value(t,entity_author(ref,orphan),orphan)
    viewport:=Viewport{size={800,600},show_indicators=true}
    viewport.view_matrix=mm.look_at({0,0,10},{},{0,1,0})
    viewport.projection=mm.perspective(50*mm.RAD_PER_DEG,800.0/600,0.1,100)
    viewport.view_projection=viewport.projection*viewport.view_matrix
    device:=new(Pick_Device);defer free(device)
    if !pick_device_open(t,device) {return}
    defer pick_device_close(device)
    selection:history.Selection
    defer delete(selection.entities)
    app:=host.App{assets=&device.assets,renderer=&device.renderer}
    session:=Session{app=&app,viewport=&viewport,selection=&selection}
    hit:=pick_point(&session,ref,{400,300})
    testing.expect_value(t,hit.entity,owner)
    testing.expect(t,!hit.indicator && abs(hit.distance-9.5)<1e-4)
    marquee_select(&session,ref,{300,200,200,200},false)
    testing.expect_value(t,len(selection.entities),1)
    testing.expect_value(t,selection.entities[0],owner)
    outliner:Outliner
    defer delete(outliner.nodes);defer delete(outliner.children);defer delete(outliner.node_of)
    outliner_sync(&outliner,ref)
    testing.expect_value(t,len(outliner.nodes),2)
    iter:=scene_items(&session,ref)
    indicators:=0
    for item in scene_item_next(&iter) {if item.indicator {indicators+=1}}
    testing.expect_value(t,indicators,0)
}

@(private) @(test_world) Ghost_Test_World :: struct {
    using world:Test_World,
    disabled:core.Table(core.Disabled),
    transforms:core.Table(core.Transform),
    parents:core.Table(core.Parent),
    meshes:core.Table(erender.Mesh_Renderer),
    hidden:core.Table(erender.Hidden),
    hierarchy:core.Hierarchy,
}

@(test)
hidden_and_turned_off_meshes_are_picked_as_ghosts_while_the_scene_is_edited :: proc(t:^testing.T) {
    world:Ghost_Test_World
    if !test_world_init(t,&world) {return}
    defer test_world_destroy(&world)
    ref:=test_world_ref(&world)
    hidden,off,turned:=core.create(&world.entities),core.create(&world.entities),core.create(&world.entities)
    places:=[3][3]f32{{-2,0,0},{2,0,0},{0,2,0}}
    for e,i in ([3]core.Entity{hidden,off,turned}) {
        core.add(&world.transforms,e,core.Transform{position=places[i],rotation=1,scale={1,1,1}})
        core.add(&world.meshes,e,{shape=.Cube})
    }
    core.add(&world.hidden,hidden,{})
    core.add(&world.disabled,off,{})
    core.disable(&world.meshes,turned)
    test_world_settle(&world)
    viewport:=Viewport{size={800,600}}
    defer viewport_free(&viewport)
    viewport.view_matrix=mm.look_at({0,0,10},{},{0,1,0})
    viewport.projection=mm.perspective(50*mm.RAD_PER_DEG,800.0/600,0.1,100)
    viewport.view_projection=viewport.projection*viewport.view_matrix
    device:=new(Pick_Device);defer free(device)
    if !pick_device_open(t,device) {return}
    defer pick_device_close(device)
    selection:history.Selection
    defer delete(selection.entities)
    app:=host.App{assets=&device.assets,renderer=&device.renderer}
    session:=Session{app=&app,viewport=&viewport,selection=&selection}
    for e,i in ([2]core.Entity{hidden,off}) {
        point,_:=viewport_screen(&viewport,places[i])
        testing.expect_value(t,pick_point(&session,ref,point).entity,core.NONE)
        testing.expect_value(t,pick_point(&session,ref,point,ghosts_shown(&session)).entity,e)
    }
    point,_:=viewport_screen(&viewport,places[2])
    testing.expect(t,pick_point(&session,ref,point,true).entity==core.NONE,"a mesh turned off by itself is not there")
    marquee_select(&session,ref,{0,0,800,600},false)
    testing.expect_value(t,len(selection.entities),2)
    session.mode=.Play
    testing.expect(t,!ghosts_shown(&session))
    marquee_select(&session,ref,{0,0,800,600},false)
    testing.expect_value(t,len(selection.entities),0)
}

@(private) @(test_world) Through_Test_World :: struct {
    using world:Test_World,
    transforms:core.Table(core.Transform),
    parents:core.Table(core.Parent),
    meshes:core.Table(erender.Mesh_Renderer),
}

// The ray of the menu of a right click goes through every body on its way,
// nearest first, and keeps the nearest when they do not fit.
@(test)
a_ray_through_the_scene_lists_what_it_crosses_nearest_first :: proc(t:^testing.T) {
    world:Through_Test_World
    if !test_world_init(t,&world) {return}
    defer test_world_destroy(&world)
    ref:=test_world_ref(&world)
    far,near,middle,aside:=core.create(&world.entities),core.create(&world.entities),core.create(&world.entities),core.create(&world.entities)
    places:=[4][3]f32{{0,0,-6},{0,0,0},{0,0,-3},{4,0,0}}
    for e,i in ([4]core.Entity{far,near,middle,aside}) {
        core.add(&world.transforms,e,core.Transform{position=places[i],rotation=1,scale={1,1,1}})
        core.add(&world.meshes,e,{shape=.Cube})
    }
    test_world_settle(&world)
    viewport:=Viewport{size={800,600}}
    defer viewport_free(&viewport)
    viewport.view_matrix=mm.look_at({0,0,10},{},{0,1,0})
    viewport.projection=mm.perspective(50*mm.RAD_PER_DEG,800.0/600,0.1,100)
    viewport.view_projection=viewport.projection*viewport.view_matrix
    device:=new(Pick_Device);defer free(device)
    if !pick_device_open(t,device) {return}
    defer pick_device_close(device)
    app:=host.App{assets=&device.assets,renderer=&device.renderer}
    session:=Session{app=&app,viewport=&viewport}
    point,_:=viewport_screen(&viewport,{})
    picks:[4]Pick
    count:=pick_through(&session,ref,point,picks[:])
    if !testing.expect_value(t,count,3) {return}
    testing.expect(t,picks[0].entity==near && picks[1].entity==middle && picks[2].entity==far)
    testing.expect(t,picks[0].distance<picks[1].distance && picks[1].distance<picks[2].distance)
    count=pick_through(&session,ref,point,picks[:2])
    testing.expect(t,count==2 && picks[0].entity==near && picks[1].entity==middle,"the farthest are left out")
}
