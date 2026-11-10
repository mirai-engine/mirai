package editor

import "core:testing"
import "mirai:core"
import "mirai:editor/history"
import erender "mirai:engine/render"
import "mirai:host"
import gpu "mirai:render"
import mm "mirai:std/math"

// The assets and the renderer a pick meets the meshes of the scene through.
@(private)
Pick_Device :: struct {
    renderer:gpu.Renderer,
    assets:host.Assets,
    open:bool,
}

@(private)
pick_device_close :: proc(d:^Pick_Device) {
    if !d.open {return}
    host.assets_destroy(&d.assets)
    gpu.renderer_destroy(&d.renderer)
    d^={}
}

@(private)
Pick_Test_World :: struct {
    using world:core.Test_World,
    using scene_tables:Test_Scene,
    meshes:core.Table(erender.Mesh_Renderer),
    highlights:core.Table(erender.Highlight),
    hidden:core.Table(erender.Hidden),
}

@(test)
marquee_previews_the_committed_selection_without_changing_it :: proc(t:^testing.T) {
    world:Pick_Test_World
    if !core.test_world_init(t,&world,test_types) {return}
    defer core.test_world_destroy(&world)
    ref:=core.test_world_ref(&world)
    owner,child,other:=core.create(&world.entities),core.create(&world.entities),core.create(&world.entities)
    core.add(&world.ids,owner,core.Id{value=1})
    core.add(&world.ids,other,core.Id{value=2})
    for e in ([2]core.Entity{owner,child}) {core.add(&world.transforms,e,core.TRANSFORM_IDENTITY)}
    core.add(&world.transforms,other,core.Transform{position={3,0,0},rotation=1,scale={1,1,1}})
    core.add(&world.parents,child,core.Parent{entity=owner})
    core.add(&world.meshes,child,{shape=.Cube})
    core.add(&world.meshes,other,{shape=.Cube})
    core.test_world_settle(&world)
    viewport:=Viewport{size={800,600},capture=.Select,moved=true,press={300,200},pointer={500,400},show_indicators=true}
    defer viewport_free(&viewport)
    viewport.view_matrix=mm.look_at({0,0,10},{},{0,1,0})
    viewport.projection=mm.perspective(50*mm.RAD_PER_DEG,800.0/600,0.1,100)
    viewport.view_projection=viewport.projection*viewport.view_matrix
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root="assets",capacity=4})) {return}
    defer host.assets_destroy(&assets)
    selection:history.Selection
    defer delete(selection.entities)
    history.selection_set(&selection,{other})
    serial:=selection.serial
    app:=host.App{assets=&assets}
    session:=Session{app=&app,viewport=&viewport,selection=&selection}
    highlight_sync(&session,ref)
    core.table_settle(&world.highlights,&world.entities)
    testing.expect_value(t,entity_level(&viewport,owner),HIGHLIGHT_SELECTED)
    testing.expect_value(t,core.get(&world.highlights,child).level,HIGHLIGHT_DESCENDANT)
    testing.expect_value(t,entity_level(&viewport,other),u8(0))
    testing.expect_value(t,selection.entities[0],other)
    testing.expect_value(t,selection.serial,serial)
    version:=world.highlights.version
    highlight_sync(&session,ref)
    testing.expect(t,world.highlights.version==version,"an unchanged rectangle does not rewrite highlight rows")
    viewport.pointer={350,250}
    highlight_sync(&session,ref)
    testing.expect_value(t,core.get(&world.highlights,child).level,u8(0))
    viewport.pointer={500,400}
    viewport.add=true
    highlight_sync(&session,ref)
    core.table_settle(&world.highlights,&world.entities)
    testing.expect_value(t,core.get(&world.highlights,other).level,HIGHLIGHT_SELECTED)
    viewport.add=false
    core.add(&world.hidden,owner,{})
    core.table_settle(&world.hidden,&world.entities)
    highlight_sync(&session,ref)
    testing.expect(t,entity_level(&viewport,owner)==HIGHLIGHT_SELECTED,"hidden author geometry stays in the preview as its ghost")
    core.remove(&world.hidden,owner)
    core.table_settle(&world.hidden,&world.entities)
    highlight_sync(&session,ref)
    testing.expect_value(t,entity_level(&viewport,owner),HIGHLIGHT_SELECTED)
    viewport.capture=.None
    highlight_sync(&session,ref)
    testing.expect(t,core.get(&world.highlights,child).level==0,"cancellation restores the existing selection")
    testing.expect_value(t,core.get(&world.highlights,other).level,HIGHLIGHT_SELECTED)
    testing.expect_value(t,selection.serial,serial)
    marquee_select(&session,ref,rect_from_points(viewport.press,viewport.pointer),false)
    highlight_sync(&session,ref)
    testing.expect_value(t,len(selection.entities),1)
    testing.expect_value(t,selection.entities[0],owner)
    testing.expect_value(t,core.get(&world.highlights,child).level,HIGHLIGHT_DESCENDANT)
    session.mode=.Play
    highlight_sync(&session,ref)
    testing.expect(t,entity_level(&viewport,owner)==0 && core.get(&world.highlights,child).level==0,"the game is drawn without the outline of the selection")
    testing.expect_value(t,len(selection.entities),1)
    session.mode=.Edit
    highlight_sync(&session,ref)
    testing.expect_value(t,core.get(&world.highlights,child).level,HIGHLIGHT_DESCENDANT)
}
