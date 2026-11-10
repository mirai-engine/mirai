package terrain_editor

import "core:fmt"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:editor"
import "mirai:host"
import terrain "plugins:terrain/runtime"
import "mirai:std/base"

@(test)
terrain_layers_paint_and_holes_are_steps_of_undo_kept_unsaved :: proc(t:^testing.T) {
    root:=base.test_folder(t,"terrain")
    path:=fmt.tprintf("%s/ground.terrain",root)
    relative:="ground.terrain"
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=root,capacity=8})) {return}
    defer host.assets_destroy(&assets)
    world:Create_Test_World
    if !core.test_world_init(t,&world,test_types) {return}
    defer core.test_world_destroy(&world)
    ref:=core.test_world_ref(&world)
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
    selection:editor.Selection;defer delete(selection.entities)
    edits:editor.Edits;defer editor.edits_free(&edits)
    editor.edits_reset(&edits,ref)
    app:=host.App{allocator=context.allocator,assets=&assets}
    s:=editor.Session{app=&app,info=ref.info,edit_world=&world,assets_root=root,headless=true,selection=&selection,edits=&edits}
    tool:Terrain_Tool;tool_ready(&tool);defer terrain_tool_free(&tool)
    core.add(&world.worlds,owner,core.World_Transform{transform={rotation=1,scale={1,1,1}}})
    core.test_world_settle(&world)
    prepare :: proc(t:^testing.T,s:^editor.Session,tool:^Terrain_Tool,world:^Create_Test_World,owner:core.Entity) -> bool {
        terrain_sync(s,tool,core.read(&world.terrains),s.app.assets)
        return testing.expect(t,stroke_prepare(tool,s.app.assets,s.app.allocator,core.read(&world.terrains),core.read(&world.worlds),editor.Pick{entity=owner}))
    }
    disk:=registry_source(t,&assets,id)
    defer terrain.source_destroy(&disk)
    testing.expect_value(t,disk.layer_count,u32(1))

    // A new terrain has one layer, which stays; each other is a step.
    if !prepare(t,&s,&tool,&world,owner) {return}
    testing.expect(t,!terrain_layer_commit(&s,&tool,ref,app.assets,0,{},true))
    testing.expect_value(t,edits.cursor,0)
    testing.expect(t,terrain_layer_commit(&s,&tool,ref,app.assets,1,terrain.LAYER_DEFAULT,false))
    testing.expect(t,editor.edits_commit(&edits,ref,&selection))
    rock:=terrain.LAYER_DEFAULT;rock.tiling=9
    if !prepare(t,&s,&tool,&world,owner) {return}
    testing.expect(t,terrain_layer_commit(&s,&tool,ref,app.assets,2,rock,false))
    testing.expect(t,editor.edits_commit(&edits,ref,&selection))
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
    testing.expect(t,editor.edits_commit(&edits,ref,&selection))
    held=registry_source(t,&assets,id);testing.expect(t,terrain.grid_get(&held.weights,4,4)[1]>200);terrain.source_destroy(&held)

    // A hole.
    if !prepare(t,&s,&tool,&world,owner) {return}
    if !testing.expect(t,stroke_baseline(&tool)) {return}
    tool.stroke.active=true
    testing.expect(t,terrain.source_edit(&tool.stroke.source,{kind=.Hole,center={0.5,0,0.5},radius=0.6}).changed)
    tool.stroke.changed=true
    stroke_end(&s,&tool,ref,app.assets,label="Cut terrain")
    testing.expect(t,editor.edits_commit(&edits,ref,&selection))
    held=registry_source(t,&assets,id);testing.expect(t,terrain.source_hole(&held,4,4));terrain.source_destroy(&held)
    testing.expect_value(t,edits.cursor,4)

    // Undo goes back through the hole, the paint and the layers.
    testing.expect(t,editor.undo(&edits,ref,&selection));terrain_sync(&s,&tool,core.read(&world.terrains),app.assets)
    held=registry_source(t,&assets,id);testing.expect(t,!terrain.source_hole(&held,4,4) && terrain.grid_get(&held.weights,4,4)[1]>200);terrain.source_destroy(&held)
    testing.expect(t,editor.undo(&edits,ref,&selection));terrain_sync(&s,&tool,core.read(&world.terrains),app.assets)
    held=registry_source(t,&assets,id);testing.expect_value(t,terrain.grid_get(&held.weights,4,4),terrain.Weights{255,0,0,0});terrain.source_destroy(&held)
    testing.expect(t,editor.undo(&edits,ref,&selection));terrain_sync(&s,&tool,core.read(&world.terrains),app.assets)
    testing.expect(t,editor.undo(&edits,ref,&selection));terrain_sync(&s,&tool,core.read(&world.terrains),app.assets)
    held=registry_source(t,&assets,id);testing.expect_value(t,held.layer_count,u32(1));terrain.source_destroy(&held)
    testing.expect(t,editor.redo(&edits,ref,&selection));terrain_sync(&s,&tool,core.read(&world.terrains),app.assets)
    held=registry_source(t,&assets,id);testing.expect_value(t,held.layer_count,u32(2));terrain.source_destroy(&held)

    // The material that blends the layers is a value of its source, and a
    // step; slot 0 shows the layers, and a Heightfield has no other.
    sand:=base.Asset_Id{93,94}
    if !prepare(t,&s,&tool,&world,owner) {return}
    testing.expect(t,terrain_material_commit(&s,&tool,ref,app.assets,LAYERS_SLOT,sand))
    testing.expect(t,!terrain_material_commit(&s,&tool,ref,app.assets,0,sand))
    testing.expect(t,!terrain_material_commit(&s,&tool,ref,app.assets,1,sand))
    testing.expect(t,editor.edits_commit(&edits,ref,&selection))
    held=registry_source(t,&assets,id);testing.expect_value(t,held.layers_material,sand);terrain.source_destroy(&held)
    testing.expect(t,editor.undo(&edits,ref,&selection));terrain_sync(&s,&tool,core.read(&world.terrains),app.assets)
    held=registry_source(t,&assets,id);testing.expect_value(t,held.layers_material,base.Asset_Id{});terrain.source_destroy(&held)
}

// The source the registry holds for a terrain, unsaved or on disk.
@(private="file")
registry_source :: proc(t:^testing.T,a:^host.Assets,id:base.Asset_Id) -> (s:terrain.Source) {
    testing.expect(t,terrain.terrain_read(&s,a,id,editable=false))
    return
}
