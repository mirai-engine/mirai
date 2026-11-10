package editor

import "core:testing"
import "mirai:core"
import "mirai:editor/history"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:std/geom"
import mm "mirai:std/math"

@(private)
Pick_Test_World :: struct {
    entities:core.Entities,
    ids:core.Table(core.Id),
    transforms:core.Table(core.Transform),
    parents:core.Table(core.Parent),
    meshes:core.Table(erender.Mesh_Renderer),
    highlights:core.Table(erender.Highlight),
    hidden:core.Table(erender.Hidden),
    hierarchy:core.Hierarchy,
}

@(test)
marquee_previews_the_committed_selection_without_changing_it :: proc(t:^testing.T) {
    world:Pick_Test_World
    core.entities_init(&world.entities)
    core.table_init(&world.ids,"Id")
    core.table_init(&world.transforms,"Transform")
    core.table_init(&world.parents,"Parent")
    core.table_init(&world.meshes,"Mesh_Renderer")
    core.table_init(&world.highlights,"Highlight")
    core.table_init(&world.hidden,"Hidden")
    defer core.entities_destroy(&world.entities)
    defer core.table_destroy(&world.ids)
    defer core.table_destroy(&world.transforms)
    defer core.table_destroy(&world.parents)
    defer core.value_free(&world.hierarchy,type_info_of(core.Hierarchy))
    defer core.table_destroy(&world.meshes)
    defer core.table_destroy(&world.highlights)
    defer core.table_destroy(&world.hidden)
    tables:=[6]core.Table_Info{
        {type=core.Id,offset=offset_of(Pick_Test_World,ids)},
        {type=core.Transform,offset=offset_of(Pick_Test_World,transforms)},
        {type=core.Parent,offset=offset_of(Pick_Test_World,parents)},
        {type=erender.Mesh_Renderer,offset=offset_of(Pick_Test_World,meshes)},
        {type=erender.Highlight,offset=offset_of(Pick_Test_World,highlights)},
        {type=erender.Hidden,offset=offset_of(Pick_Test_World,hidden)},
    }
    storages:=[1]core.Storage_Info{{type=core.Hierarchy,info=type_info_of(core.Hierarchy),offset=offset_of(Pick_Test_World,hierarchy)}}
    info:=core.World_Info{entities=offset_of(Pick_Test_World,entities),tables=tables[:],storages=storages[:]}
    ref:=core.world_ref(&world,&info)
    owner,child,other:=core.create(&world.entities),core.create(&world.entities),core.create(&world.entities)
    core.add(&world.ids,owner,core.Id{value=1})
    core.add(&world.ids,other,core.Id{value=2})
    for e in ([2]core.Entity{owner,child}) {core.add(&world.transforms,e,core.TRANSFORM_IDENTITY)}
    core.add(&world.transforms,other,core.Transform{position={3,0,0},rotation=1,scale={1,1,1}})
    core.add(&world.parents,child,core.Parent{entity=owner})
    core.add(&world.meshes,child,{shape=.Cube})
    core.add(&world.meshes,other,{shape=.Cube})
    core.table_settle(&world.ids,&world.entities)
    core.table_settle(&world.transforms,&world.entities)
    core.table_settle(&world.parents,&world.entities)
    core.hierarchy_settle(&world.hierarchy,core.read(&world.parents),&world.entities)
    core.table_settle(&world.meshes,&world.entities)
    viewport:=Viewport{size={800,600},capture=.Select,moved=true,press={300,200},pointer={500,400},show_indicators=true}
    defer viewport_free(&viewport)
    viewport.view_matrix=mm.look_at({0,0,10},{},{0,1,0})
    viewport.projection=mm.perspective(50*mm.RAD_PER_DEG,800.0/600,0.1,100)
    viewport.view_projection=viewport.projection*viewport.view_matrix
    picker:Picker
    defer picker_clear(&picker);defer delete(picker.meshes)
    selection:history.Selection
    defer delete(selection.entities)
    history.selection_set(&selection,{other})
    serial:=selection.serial
    app:host.App
    session:=Session{app=&app,viewport=&viewport,picker=&picker,selection=&selection}
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

@(test)
derived_geometry_selects_its_author_and_keeps_internal_nodes_out_of_the_tree :: proc(t:^testing.T) {
    world:Pick_Test_World
    core.entities_init(&world.entities)
    core.table_init(&world.ids,"Id")
    core.table_init(&world.transforms,"Transform")
    core.table_init(&world.parents,"Parent")
    core.table_init(&world.meshes,"Mesh_Renderer")
    defer core.entities_destroy(&world.entities)
    defer core.table_destroy(&world.ids)
    defer core.table_destroy(&world.transforms)
    defer core.table_destroy(&world.parents)
    defer core.value_free(&world.hierarchy,type_info_of(core.Hierarchy))
    defer core.table_destroy(&world.meshes)
    tables:=[4]core.Table_Info{
        {type=core.Id,offset=offset_of(Pick_Test_World,ids)},
        {type=core.Transform,offset=offset_of(Pick_Test_World,transforms)},
        {type=core.Parent,offset=offset_of(Pick_Test_World,parents)},
        {type=erender.Mesh_Renderer,offset=offset_of(Pick_Test_World,meshes)},
    }
    storages:=[1]core.Storage_Info{{type=core.Hierarchy,info=type_info_of(core.Hierarchy),offset=offset_of(Pick_Test_World,hierarchy)}}
    info:=core.World_Info{entities=offset_of(Pick_Test_World,entities),tables=tables[:],storages=storages[:]}
    ref:=core.world_ref(&world,&info)
    owner,child,empty,orphan:=core.create(&world.entities),core.create(&world.entities),core.create(&world.entities),core.create(&world.entities)
    core.add(&world.ids,owner,core.Id{value=1})
    for e in ([3]core.Entity{owner,child,empty}) {core.add(&world.transforms,e,core.TRANSFORM_IDENTITY)}
    core.add(&world.transforms,orphan,core.Transform{position={20,0,0},rotation=1,scale={1,1,1}})
    core.add(&world.parents,child,core.Parent{entity=owner})
    core.add(&world.parents,empty,core.Parent{entity=owner})
    core.add(&world.meshes,owner,{})
    core.add(&world.meshes,child,{shape=.Cube})
    core.table_settle(&world.ids,&world.entities)
    core.table_settle(&world.transforms,&world.entities)
    core.table_settle(&world.parents,&world.entities)
    core.hierarchy_settle(&world.hierarchy,core.read(&world.parents),&world.entities)
    core.table_settle(&world.meshes,&world.entities)
    testing.expect_value(t,entity_author(ref,child),owner)
    testing.expect_value(t,entity_author(ref,empty),owner)
    testing.expect_value(t,entity_author(ref,orphan),orphan)
    viewport:=Viewport{size={800,600},show_indicators=true}
    viewport.view_matrix=mm.look_at({0,0,10},{},{0,1,0})
    viewport.projection=mm.perspective(50*mm.RAD_PER_DEG,800.0/600,0.1,100)
    viewport.view_projection=viewport.projection*viewport.view_matrix
    picker:Picker
    defer picker_clear(&picker)
    defer delete(picker.meshes)
    selection:history.Selection
    defer delete(selection.entities)
    app:host.App
    session:=Session{app=&app,viewport=&viewport,picker=&picker,selection=&selection}
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

@(test)
hidden_and_turned_off_meshes_are_picked_as_ghosts_while_the_scene_is_edited :: proc(t:^testing.T) {
    Ghost_Test_World :: struct {
        entities:core.Entities,
        disabled:core.Table(core.Disabled),
        transforms:core.Table(core.Transform),
        parents:core.Table(core.Parent),
        meshes:core.Table(erender.Mesh_Renderer),
        hidden:core.Table(erender.Hidden),
        hierarchy:core.Hierarchy,
    }
    world:Ghost_Test_World
    core.entities_init(&world.entities)
    core.table_init(&world.disabled,"Disabled");core.table_init(&world.transforms,"Transform");core.table_init(&world.parents,"Parent")
    core.table_init(&world.meshes,"Mesh_Renderer");core.table_init(&world.hidden,"Hidden")
    world.disabled.base,world.transforms.base,world.parents.base=true,true,true
    defer core.entities_destroy(&world.entities)
    defer {core.table_destroy(&world.disabled);core.table_destroy(&world.transforms);core.table_destroy(&world.parents)}
    defer {core.table_destroy(&world.meshes);core.table_destroy(&world.hidden)}
    defer core.value_free(&world.hierarchy,type_info_of(core.Hierarchy))
    tables:=[5]core.Table_Info{
        {type=core.Disabled,offset=offset_of(Ghost_Test_World,disabled)},
        {type=core.Transform,offset=offset_of(Ghost_Test_World,transforms)},
        {type=core.Parent,offset=offset_of(Ghost_Test_World,parents)},
        {type=erender.Mesh_Renderer,offset=offset_of(Ghost_Test_World,meshes)},
        {type=erender.Hidden,offset=offset_of(Ghost_Test_World,hidden)},
    }
    storages:=[1]core.Storage_Info{{type=core.Hierarchy,info=type_info_of(core.Hierarchy),offset=offset_of(Ghost_Test_World,hierarchy)}}
    info:=core.World_Info{entities=offset_of(Ghost_Test_World,entities),tables=tables[:],storages=storages[:]}
    ref:=core.world_ref(&world,&info)
    hidden,off,turned:=core.create(&world.entities),core.create(&world.entities),core.create(&world.entities)
    places:=[3][3]f32{{-2,0,0},{2,0,0},{0,2,0}}
    for e,i in ([3]core.Entity{hidden,off,turned}) {
        core.add(&world.transforms,e,core.Transform{position=places[i],rotation=1,scale={1,1,1}})
        core.add(&world.meshes,e,{shape=.Cube})
    }
    core.add(&world.hidden,hidden,{})
    core.add(&world.disabled,off,{})
    core.disable(&world.meshes,turned)
    core.table_settle(&world.disabled,&world.entities)
    core.table_settle(&world.parents,&world.entities)
    core.hierarchy_settle(&world.hierarchy,core.read(&world.parents),&world.entities)
    core.entities_activity(&world.entities,core.read(&world.disabled),core.ref(&world.hierarchy))
    core.table_settle(&world.transforms,&world.entities)
    core.table_settle(&world.meshes,&world.entities)
    core.table_settle(&world.hidden,&world.entities)
    core.entities_settle(&world.entities)
    viewport:=Viewport{size={800,600}}
    defer viewport_free(&viewport)
    viewport.view_matrix=mm.look_at({0,0,10},{},{0,1,0})
    viewport.projection=mm.perspective(50*mm.RAD_PER_DEG,800.0/600,0.1,100)
    viewport.view_projection=viewport.projection*viewport.view_matrix
    picker:Picker
    defer picker_clear(&picker);defer delete(picker.meshes)
    selection:history.Selection
    defer delete(selection.entities)
    app:host.App
    session:=Session{app=&app,viewport=&viewport,picker=&picker,selection=&selection}
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

@(test)
retiring_generated_geometry_keeps_the_unrelated_picker_meshes :: proc(t:^testing.T) {
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root="assets",capacity=4})) {return}
    defer host.assets_destroy(&assets)
    positions:=[3]geom.Vec3{{0,0,0},{0,0,1},{1,0,0}}
    indices:=[3]u32{0,1,2}
    mesh:=geom.Mesh{positions=positions[:],indices=indices[:]}
    first,ok:=host.assets_mesh_generate(&assets,mesh,options={collision=true,no_lods=true})
    if !testing.expect(t,ok) {return}
    second,ok2:=host.assets_mesh_generate(&assets,mesh,options={collision=true,no_lods=true})
    if !testing.expect(t,ok2) {return}
    picker:Picker
    defer picker_clear(&picker);defer delete(picker.meshes)
    testing.expect(t,picker_mesh(&picker,&assets,{mesh=first})!=nil)
    testing.expect(t,picker_mesh(&picker,&assets,{mesh=second})!=nil)
    testing.expect(t,picker_mesh(&picker,&assets,{shape=.Cube})!=nil)
    testing.expect_value(t,picker.loads,u64(3))
    testing.expect(t,host.assets_mesh_release(&assets,first))
    testing.expect(t,picker_mesh(&picker,&assets,{mesh=second})!=nil)
    testing.expect_value(t,len(picker.meshes),2)
    testing.expect_value(t,picker.loads,u64(3))
    testing.expect(t,picker_mesh(&picker,&assets,{shape=.Cube})!=nil)
    testing.expect_value(t,picker.loads,u64(3))
}

// A pick reads what it needs of the meshes and makes the BVH of those whose
// box its ray reaches; what the assets change of other meshes, past what
// their log of changes keeps, does not make it read or build them again.
@(test)
a_pick_builds_only_what_its_ray_reaches_and_keeps_it_while_other_meshes_change :: proc(t:^testing.T) {
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root="assets",capacity=4})) {return}
    defer host.assets_destroy(&assets)
    positions:=[3]geom.Vec3{{0,0,0},{0,0,1},{1,0,0}}
    indices:=[3]u32{0,1,2}
    triangle:=geom.Mesh{positions=positions[:],indices=indices[:]}
    near,ok:=host.assets_mesh_generate(&assets,triangle,options={collision=true,no_lods=true})
    far,ok2:=host.assets_mesh_generate(&assets,triangle,options={collision=true,no_lods=true})
    if !testing.expect(t,ok && ok2) {return}
    world:Pick_Test_World
    core.entities_init(&world.entities)
    core.table_init(&world.ids,"Id")
    core.table_init(&world.transforms,"Transform")
    core.table_init(&world.parents,"Parent")
    core.table_init(&world.meshes,"Mesh_Renderer")
    defer core.entities_destroy(&world.entities)
    defer core.table_destroy(&world.ids)
    defer core.table_destroy(&world.transforms)
    defer core.table_destroy(&world.parents)
    defer core.value_free(&world.hierarchy,type_info_of(core.Hierarchy))
    defer core.table_destroy(&world.meshes)
    tables:=[4]core.Table_Info{
        {type=core.Id,offset=offset_of(Pick_Test_World,ids)},
        {type=core.Transform,offset=offset_of(Pick_Test_World,transforms)},
        {type=core.Parent,offset=offset_of(Pick_Test_World,parents)},
        {type=erender.Mesh_Renderer,offset=offset_of(Pick_Test_World,meshes)},
    }
    storages:=[1]core.Storage_Info{{type=core.Hierarchy,info=type_info_of(core.Hierarchy),offset=offset_of(Pick_Test_World,hierarchy)}}
    info:=core.World_Info{entities=offset_of(Pick_Test_World,entities),tables=tables[:],storages=storages[:]}
    ref:=core.world_ref(&world,&info)
    a,b:=core.create(&world.entities),core.create(&world.entities)
    core.add(&world.ids,a,core.Id{value=1})
    core.add(&world.ids,b,core.Id{value=2})
    core.add(&world.transforms,a,core.TRANSFORM_IDENTITY)
    core.add(&world.transforms,b,core.Transform{position={100,0,0},rotation=1,scale={1,1,1}})
    core.add(&world.meshes,a,{mesh=near})
    core.add(&world.meshes,b,{mesh=far})
    core.table_settle(&world.ids,&world.entities)
    core.table_settle(&world.transforms,&world.entities)
    core.table_settle(&world.parents,&world.entities)
    core.hierarchy_settle(&world.hierarchy,core.read(&world.parents),&world.entities)
    core.table_settle(&world.meshes,&world.entities)
    picker:Picker
    defer picker_clear(&picker);defer delete(picker.meshes)
    app:=host.App{assets=&assets}
    session:=Session{app=&app,picker=&picker}
    down:=mm.Ray{{0.2,5,0.2},{0,-1,0}}
    hit:=pick_ray(&session,ref,down)
    testing.expect_value(t,hit.entity,a)
    testing.expect(t,abs(hit.distance-5)<1e-4)
    testing.expect_value(t,picker.builds,u64(1))
    // More meshes come and go than the log of changes of the assets keeps.
    for _ in 0..<80 {
        other,made:=host.assets_mesh_generate(&assets,triangle,options={collision=true,no_lods=true})
        if !testing.expect(t,made) {return}
        testing.expect(t,host.assets_mesh_release(&assets,other))
    }
    loads:=picker.loads
    testing.expect_value(t,pick_ray(&session,ref,down).entity,a)
    testing.expect_value(t,pick_ray(&session,ref,{{100.2,5,0.2},{0,-1,0}}).entity,b)
    testing.expect_value(t,picker.loads,loads)
    testing.expect_value(t,picker.builds,u64(2))
    // A mesh released goes, and only it.
    testing.expect(t,host.assets_mesh_release(&assets,far))
    testing.expect_value(t,pick_ray(&session,ref,down).entity,a)
    testing.expect_value(t,picker.builds,u64(2))
    for &m in picker.meshes {testing.expect(t,m.id!=far || len(m.indices)==0,"the triangles of the released mesh are not kept")}
}

// The ray of the menu of a right click goes through every body on its way,
// nearest first, and keeps the nearest when they do not fit.
@(test)
a_ray_through_the_scene_lists_what_it_crosses_nearest_first :: proc(t:^testing.T) {
    Through_Test_World :: struct {
        entities:core.Entities,
        transforms:core.Table(core.Transform),
        parents:core.Table(core.Parent),
        meshes:core.Table(erender.Mesh_Renderer),
    }
    world:Through_Test_World
    core.entities_init(&world.entities)
    core.table_init(&world.transforms,"Transform");core.table_init(&world.parents,"Parent");core.table_init(&world.meshes,"Mesh_Renderer")
    world.transforms.base,world.parents.base=true,true
    defer core.entities_destroy(&world.entities)
    defer {core.table_destroy(&world.transforms);core.table_destroy(&world.parents);core.table_destroy(&world.meshes)}
    tables:=[3]core.Table_Info{
        {type=core.Transform,offset=offset_of(Through_Test_World,transforms)},
        {type=core.Parent,offset=offset_of(Through_Test_World,parents)},
        {type=erender.Mesh_Renderer,offset=offset_of(Through_Test_World,meshes)},
    }
    info:=core.World_Info{entities=offset_of(Through_Test_World,entities),tables=tables[:]}
    ref:=core.world_ref(&world,&info)
    far,near,middle,aside:=core.create(&world.entities),core.create(&world.entities),core.create(&world.entities),core.create(&world.entities)
    places:=[4][3]f32{{0,0,-6},{0,0,0},{0,0,-3},{4,0,0}}
    for e,i in ([4]core.Entity{far,near,middle,aside}) {
        core.add(&world.transforms,e,core.Transform{position=places[i],rotation=1,scale={1,1,1}})
        core.add(&world.meshes,e,{shape=.Cube})
    }
    core.table_settle(&world.transforms,&world.entities)
    core.table_settle(&world.parents,&world.entities)
    core.table_settle(&world.meshes,&world.entities)
    core.entities_settle(&world.entities)
    viewport:=Viewport{size={800,600}}
    defer viewport_free(&viewport)
    viewport.view_matrix=mm.look_at({0,0,10},{},{0,1,0})
    viewport.projection=mm.perspective(50*mm.RAD_PER_DEG,800.0/600,0.1,100)
    viewport.view_projection=viewport.projection*viewport.view_matrix
    picker:Picker
    defer picker_clear(&picker);defer delete(picker.meshes)
    app:host.App
    session:=Session{app=&app,viewport=&viewport,picker=&picker}
    point,_:=viewport_screen(&viewport,{})
    picks:[4]Pick
    count:=pick_through(&session,ref,point,picks[:])
    if !testing.expect_value(t,count,3) {return}
    testing.expect(t,picks[0].entity==near && picks[1].entity==middle && picks[2].entity==far)
    testing.expect(t,picks[0].distance<picks[1].distance && picks[1].distance<picks[2].distance)
    count=pick_through(&session,ref,point,picks[:2])
    testing.expect(t,count==2 && picks[0].entity==near && picks[1].entity==middle,"the farthest are left out")
}
