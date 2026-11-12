package editor

import "core:testing"
import "mirai:core"
import "mirai:editor/history"
import erender "mirai:engine/render"
import "mirai:host"
import gpu "mirai:render"
import "mirai:std/base"
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
@(test_world)
Pick_Test_World :: struct {
    using world:Test_World,
    using scene_tables:Test_Scene,
    meshes:core.Table(erender.Mesh_Renderer),
    highlights:core.Table(erender.Highlight),
    hidden:core.Table(erender.Hidden),
    points:core.Table(erender.Point_Light),
}

@(test)
marquee_previews_the_committed_selection_without_changing_it :: proc(t:^testing.T) {
    world:Pick_Test_World
    if !test_world_init(t,&world) {return}
    defer test_world_destroy(&world)
    ref:=test_world_ref(&world)
    owner,child,other:=core.create(&world.entities),core.create(&world.entities),core.create(&world.entities)
    core.add(&world.ids,owner,core.Id{value=1})
    core.add(&world.ids,other,core.Id{value=2})
    for e in ([2]core.Entity{owner,child}) {core.add(&world.transforms,e,core.TRANSFORM_IDENTITY)}
    core.add(&world.transforms,other,core.Transform{position={3,0,0},rotation=1,scale={1,1,1}})
    core.add(&world.parents,child,core.Parent{entity=owner})
    core.add(&world.meshes,child,{shape=.Cube})
    core.add(&world.meshes,other,{shape=.Cube})
    test_world_settle(&world)
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
    testing.expect_value(t,core.at(&world.highlights,core.row_of(&world.highlights,child)).level,HIGHLIGHT_DESCENDANT)
    testing.expect_value(t,entity_level(&viewport,other),u8(0))
    testing.expect_value(t,selection.entities[0],other)
    testing.expect_value(t,selection.serial,serial)
    version:=world.highlights.version
    highlight_sync(&session,ref)
    testing.expect(t,world.highlights.version==version,"an unchanged rectangle does not rewrite highlight rows")
    viewport.pointer={350,250}
    highlight_sync(&session,ref)
    testing.expect_value(t,core.at(&world.highlights,core.row_of(&world.highlights,child)).level,u8(0))
    viewport.pointer={500,400}
    viewport.add=true
    highlight_sync(&session,ref)
    core.table_settle(&world.highlights,&world.entities)
    testing.expect_value(t,core.at(&world.highlights,core.row_of(&world.highlights,other)).level,HIGHLIGHT_SELECTED)
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
    testing.expect(t,core.at(&world.highlights,core.row_of(&world.highlights,child)).level==0,"cancellation restores the existing selection")
    testing.expect_value(t,core.at(&world.highlights,core.row_of(&world.highlights,other)).level,HIGHLIGHT_SELECTED)
    testing.expect_value(t,selection.serial,serial)
    marquee_select(&session,ref,rect_from_points(viewport.press,viewport.pointer),false)
    highlight_sync(&session,ref)
    testing.expect_value(t,len(selection.entities),1)
    testing.expect_value(t,selection.entities[0],owner)
    testing.expect_value(t,core.at(&world.highlights,core.row_of(&world.highlights,child)).level,HIGHLIGHT_DESCENDANT)
    session.mode=.Play
    highlight_sync(&session,ref)
    testing.expect(t,entity_level(&viewport,owner)==0 && core.at(&world.highlights,core.row_of(&world.highlights,child)).level==0,"the game is drawn without the outline of the selection")
    testing.expect_value(t,len(selection.entities),1)
    session.mode=.Edit
    highlight_sync(&session,ref)
    testing.expect_value(t,core.at(&world.highlights,core.row_of(&world.highlights,child)).level,HIGHLIGHT_DESCENDANT)
}

@(test)
discs_show_near_the_camera_and_the_selected_one_at_any_distance :: proc(t:^testing.T) {
    world:Pick_Test_World
    if !test_world_init(t,&world) {return}
    defer test_world_destroy(&world)
    ref:=test_world_ref(&world)
    eye:=[3]f32{0,0,10}
    // From the eye: well inside the fade, inside it, past the reach.
    Case :: struct {place:[3]f32,shown:bool,whole:bool}
    cases:=[3]Case{{{-2,0,0},true,true},{{4,0,eye.z-(INDICATOR_FADE+INDICATOR_REACH)*0.5},true,false},{{30,0,eye.z-INDICATOR_REACH*4},false,false}}
    lights:[len(cases)]core.Entity
    for c,i in cases {
        lights[i]=core.create(&world.entities)
        core.add(&world.ids,lights[i],core.Id{value=base.Entity_Id(i+1)})
        core.add(&world.transforms,lights[i],core.Transform{position=c.place,rotation=1,scale={1,1,1}})
        core.add(&world.points,lights[i],erender.Point_Light{})
    }
    test_world_settle(&world)
    viewport:=Viewport{size={800,600},show_indicators=true}
    defer viewport_free(&viewport)
    viewport.camera={position=eye,forward={0,0,-1},up={0,1,0},fov_y=VIEW_FOV,near=VIEW_NEAR}
    viewport.view_matrix=mm.look_at(eye,{},{0,1,0})
    viewport.projection=mm.perspective_infinite(VIEW_FOV*mm.RAD_PER_DEG,800.0/600,VIEW_NEAR)
    viewport.view_projection=viewport.projection*viewport.view_matrix
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root="assets",capacity=4})) {return}
    defer host.assets_destroy(&assets)
    selection:history.Selection
    defer delete(selection.entities)
    app:=host.App{assets=&assets}
    session:=Session{app=&app,viewport=&viewport,selection=&selection}
    picks:[4]Pick
    for c,i in cases {
        e:=lights[i]
        shade:=indicator_shade(&session,e,c.place,indicator_zoom(&viewport))
        testing.expectf(t,c.shown==(shade>0) && c.whole==(shade==1),"case %d: shade %v",i,shade)
        point,front:=viewport_screen(&viewport,c.place)
        if !testing.expect(t,front && point.x>0 && point.x<800 && point.y>0 && point.y<600) {continue}
        testing.expect_value(t,pick_point(&session,ref,point).entity,c.shown?e:core.NONE)
        testing.expect_value(t,pick_through(&session,ref,point,picks[:]),c.shown?1:0)
    }
    marquee_select(&session,ref,{0,0,800,600},false)
    testing.expect_value(t,len(selection.entities),2)
    testing.expect(t,!history.selection_has(&selection,lights[2]),"a rectangle does not take a disc past the reach")
    // Selected, the far one shows and is picked wherever it is.
    history.selection_set(&selection,{lights[2]})
    testing.expect_value(t,indicator_shade(&session,lights[2],cases[2].place,indicator_zoom(&viewport)),f32(1))
    point,_:=viewport_screen(&viewport,cases[2].place)
    testing.expect_value(t,pick_point(&session,ref,point).entity,lights[2])
    history.selection_clear(&selection)
    // A narrower field of view brings it into reach.
    viewport.camera.fov_y=VIEW_FOV/8
    testing.expect(t,indicator_shade(&session,lights[2],cases[2].place,indicator_zoom(&viewport))>0)
}
