package terrain_editor

import "core:fmt"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/history"
import "mirai:host"
import terrain "plugins:terrain/runtime"
import "mirai:std/base"

@(test)
terrain_layers_paint_and_holes_are_steps_of_undo :: proc(t:^testing.T) {
    root:=base.test_folder(t,"terrain")
    path:=fmt.tprintf("%s/ground.terrain",root)
    relative:="ground.terrain"
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=root,capacity=8})) {return}
    defer host.assets_destroy(&assets)
    world:Create_Test_World
    if !test_world_init(t,&world) {return}
    defer test_world_destroy(&world)
    ref:=test_world_ref(&world)
    source:terrain.Source;defer terrain.source_destroy(&source)
    if !testing.expect(t,terrain.source_make(&source,.Heightfield,{9,1,9},1,4)) {return}
    id:=base.Asset_Id{91,92};source.revision=1
    testing.expect_value(t,terrain.source_save(&source,path,id,&assets.types),asset.Error.None)
    host.assets_scan(&assets)
    owner:=core.create(&world.entities)
    core.add(&world.ids,owner,core.Id{value=base.Entity_Id(100+u64(owner))})
    core.add(&world.transforms,owner,core.TRANSFORM_IDENTITY)
    core.add(&world.terrains,owner,terrain.Terrain{source=id,revision=1})
    core.world_settle(ref)
    selection:history.Selection;defer delete(selection.entities)
    edits:history.Edits;defer history.edits_free(&edits)
    history.edits_reset(&edits,ref)
    app:=host.App{allocator=context.allocator,assets=&assets}
    s:=editor.Session{app=&app,info=ref.info,edit_world=&world,assets_root=root,headless=true,selection=&selection,edits=&edits}
    tool:Terrain_Tool;tool_ready(&tool);defer terrain_tool_free(&tool)
    core.add(&world.worlds,owner,core.World_Transform{transform={rotation=1,scale={1,1,1}}})
    test_world_settle(&world)
    prepare :: proc(t:^testing.T,s:^editor.Session,tool:^Terrain_Tool,world:^Create_Test_World,owner:core.Entity) -> bool {
        terrain_sync(s,tool,core.read(&world.terrains),s.app.assets)
        return testing.expect(t,stroke_prepare(tool,s.app.assets,s.app.allocator,&world.terrains,&world.worlds,editor.Pick{entity=owner}))
    }
    disk:=registry_source(t,&assets,id)
    defer terrain.source_destroy(&disk)
    testing.expect_value(t,disk.layer_count,u32(1))

    // A new terrain has one layer, which stays; each other is a step.
    if !prepare(t,&s,&tool,&world,owner) {return}
    testing.expect(t,!terrain_layer_commit(&s,&tool,ref,app.assets,0,{},true))
    testing.expect_value(t,edits.cursor,0)
    testing.expect(t,terrain_layer_commit(&s,&tool,ref,app.assets,1,terrain.LAYER_DEFAULT,false))
    testing.expect(t,history.edits_commit(&edits,ref,&selection))
    rock:=terrain.LAYER_DEFAULT;rock.tiling=9
    if !prepare(t,&s,&tool,&world,owner) {return}
    testing.expect(t,terrain_layer_commit(&s,&tool,ref,app.assets,2,rock,false))
    testing.expect(t,history.edits_commit(&edits,ref,&selection))
    testing.expect(t,!terrain_layer_commit(&s,&tool,ref,app.assets,5,rock,false))
    held:=registry_source(t,&assets,id);testing.expect_value(t,held.layer_count,u32(3));testing.expect_value(t,held.layers[2].tiling,f32(9));terrain.source_destroy(&held)

    // A stroke of paint.
    if !prepare(t,&s,&tool,&world,owner) {return}
    if !testing.expect(t,stroke_baseline(&tool)) {return}
    tool.stroke.active=true
    change:=terrain.source_edit(&tool.stroke.source,{kind=.Paint,center={0,0,0},radius=1.5,amount=1,layer=1})
    testing.expect(t,change.changed && change.error==.None)
    tool.stroke.changed=true
    stroke_end(&s,&tool,ref,app.assets,label="Paint terrain")
    testing.expect(t,history.edits_commit(&edits,ref,&selection))
    held=registry_source(t,&assets,id);testing.expect(t,terrain.weights_float(terrain.grid_get(&held.weights,4,4))[1]>200.0/255);terrain.source_destroy(&held)

    // A hole.
    if !prepare(t,&s,&tool,&world,owner) {return}
    if !testing.expect(t,stroke_baseline(&tool)) {return}
    tool.stroke.active=true
    testing.expect(t,terrain.source_edit(&tool.stroke.source,{kind=.Hole,center={0.5,0,0.5},radius=0.6}).changed)
    tool.stroke.changed=true
    stroke_end(&s,&tool,ref,app.assets,label="Cut terrain")
    testing.expect(t,history.edits_commit(&edits,ref,&selection))
    held=registry_source(t,&assets,id);testing.expect(t,terrain.source_hole(&held,4,4));terrain.source_destroy(&held)
    testing.expect_value(t,edits.cursor,4)

    // A color painted over the layers.
    if !prepare(t,&s,&tool,&world,owner) {return}
    if !testing.expect(t,stroke_baseline(&tool)) {return}
    tool.stroke.active=true
    testing.expect(t,terrain.source_edit(&tool.stroke.source,{kind=.Tint,center={0,0,0},radius=1.5,amount=1,color={1,0,0}}).changed)
    tool.stroke.changed=true
    stroke_end(&s,&tool,ref,app.assets,label="Tint terrain")
    testing.expect(t,history.edits_commit(&edits,ref,&selection))
    held=registry_source(t,&assets,id);testing.expect_value(t,terrain.grid_get(&held.paint,4,4),terrain.Paint{255,0,0,terrain.PAINT_ROUGHNESS_NEUTRAL});terrain.source_destroy(&held)
    testing.expect(t,history.undo(&edits,ref,&selection));terrain_sync(&s,&tool,core.read(&world.terrains),app.assets)
    held=registry_source(t,&assets,id);testing.expect(t,terrain.grid_none(&held.paint) || terrain.grid_get(&held.paint,4,4)==terrain.PAINT_NEUTRAL);terrain.source_destroy(&held)

    // Undo goes back through the hole, the paint and the layers.
    testing.expect(t,history.undo(&edits,ref,&selection));terrain_sync(&s,&tool,core.read(&world.terrains),app.assets)
    held=registry_source(t,&assets,id);testing.expect(t,!terrain.source_hole(&held,4,4) && terrain.weights_float(terrain.grid_get(&held.weights,4,4))[1]>200.0/255);terrain.source_destroy(&held)
    testing.expect(t,history.undo(&edits,ref,&selection));terrain_sync(&s,&tool,core.read(&world.terrains),app.assets)
    held=registry_source(t,&assets,id);testing.expect_value(t,terrain.grid_get(&held.weights,4,4),terrain.WEIGHTS_FIRST);terrain.source_destroy(&held)
    testing.expect(t,history.undo(&edits,ref,&selection));terrain_sync(&s,&tool,core.read(&world.terrains),app.assets)
    testing.expect(t,history.undo(&edits,ref,&selection));terrain_sync(&s,&tool,core.read(&world.terrains),app.assets)
    held=registry_source(t,&assets,id);testing.expect_value(t,held.layer_count,u32(1));terrain.source_destroy(&held)
    testing.expect(t,history.redo(&edits,ref,&selection));terrain_sync(&s,&tool,core.read(&world.terrains),app.assets)
    held=registry_source(t,&assets,id);testing.expect_value(t,held.layer_count,u32(2));terrain.source_destroy(&held)

    // The material that blends the layers is a value of its source, and a step.
    sand:=base.Asset_Id{93,94}
    if !prepare(t,&s,&tool,&world,owner) {return}
    testing.expect(t,terrain_material_commit(&s,&tool,ref,app.assets,sand))
    testing.expect(t,history.edits_commit(&edits,ref,&selection))
    held=registry_source(t,&assets,id);testing.expect_value(t,held.layers_material,sand);terrain.source_destroy(&held)
    testing.expect(t,history.undo(&edits,ref,&selection));terrain_sync(&s,&tool,core.read(&world.terrains),app.assets)
    held=registry_source(t,&assets,id);testing.expect_value(t,held.layers_material,base.Asset_Id{});terrain.source_destroy(&held)
}

// A stroke over the edge two Heightfields share writes both: the one beside
// takes its brushes as a step of its own, and the tool stays on the terrain
// it had.
@(test)
a_stroke_over_a_shared_edge_writes_the_terrain_beside :: proc(t:^testing.T) {
    root:=base.test_folder(t,"terrain")
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=root,capacity=16})) {return}
    defer host.assets_destroy(&assets)
    world:Create_Test_World
    if !test_world_init(t,&world) {return}
    defer test_world_destroy(&world)
    ref:=test_world_ref(&world)
    ids:=[2]base.Asset_Id{{95,1},{95,2}}
    owners:[2]core.Entity
    for id,k in ids {
        source:terrain.Source;defer terrain.source_destroy(&source)
        if !testing.expect(t,terrain.source_make(&source,.Heightfield,{9,1,9},1,4)) {return}
        source.revision=1
        testing.expect_value(t,terrain.source_save(&source,fmt.tprintf("%s/side%d.terrain",root,k),id,&assets.types),asset.Error.None)
    }
    host.assets_scan(&assets)
    for id,k in ids {
        owners[k]=core.create(&world.entities)
        core.add(&world.ids,owners[k],core.Id{value=base.Entity_Id(200+k)})
        place:=core.TRANSFORM_IDENTITY
        place.position.x=f32(8*k)
        core.add(&world.transforms,owners[k],place)
        core.add(&world.terrains,owners[k],terrain.Terrain{source=id,revision=1})
        core.add(&world.worlds,owners[k],core.World_Transform{transform={position=place.position,rotation=place.rotation,scale=place.scale}})
    }
    test_world_settle(&world)
    selection:history.Selection;defer delete(selection.entities)
    edits:history.Edits;defer history.edits_free(&edits)
    history.edits_reset(&edits,ref)
    app:=host.App{allocator=context.allocator,assets=&assets}
    s:=editor.Session{app=&app,info=ref.info,edit_world=&world,assets_root=root,headless=true,selection=&selection,edits=&edits}
    tool:Terrain_Tool;tool_ready(&tool);defer terrain_tool_free(&tool)
    terrain_sync(&s,&tool,core.read(&world.terrains),app.assets)
    if !testing.expect(t,stroke_prepare(&tool,app.assets,app.allocator,&world.terrains,&world.worlds,editor.Pick{entity=owners[0]})) {return}
    testing.expect(t,stroke_baseline(&tool))
    tool.stroke.active=true
    // On the edge at x 4 of the first, x -4 of the second.
    brush:=terrain.Brush{kind=.Raise,center={4,0,0},radius=2,amount=1}
    change:=terrain.source_edit(&tool.stroke.source,brush)
    testing.expect(t,change.changed)
    stroke_brush_keep(&tool,brush)
    stroke_changed(&tool.stroke,change)
    stroke_end(&s,&tool,ref,app.assets,layered=true)
    first,second:=registry_source(t,&assets,ids[0]),registry_source(t,&assets,ids[1])
    defer terrain.source_destroy(&first);defer terrain.source_destroy(&second)
    testing.expect(t,terrain.grid_get(&first.field,8,4)>0.5,"the terrain of the stroke is raised at its edge")
    testing.expect(t,terrain.grid_get(&second.field,0,4)>0.5,"and the one beside too")
    testing.expect(t,abs(terrain.grid_get(&first.field,8,4)-terrain.grid_get(&second.field,0,4))<1e-3)
    testing.expect_value(t,tool.stroke.entity,owners[0])
}

// The source the registry answers for a terrain.
@(private="file")
registry_source :: proc(t:^testing.T,a:^host.Assets,id:base.Asset_Id) -> (s:terrain.Source) {
    testing.expect(t,terrain.terrain_read(&s,a,id))
    return
}
