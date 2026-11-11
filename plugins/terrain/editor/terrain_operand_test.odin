package terrain_editor

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/history"
import erender "mirai:engine/render"
import "mirai:host"
import terrain "plugins:terrain/runtime"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"

// What the registry of the assets answers for a file: what it holds until the flush, or the disk.
@(private)
test_held :: proc(t:^testing.T,assets:^host.Assets,relative:string) -> []u8 {
    data,error:=asset.registry_read(&assets.registry,relative,context.allocator)
    testing.expect_value(t,error,asset.Error.None)
    return data
}

// A closed mesh of the scene joins a Volume or is carved out of it as
// samples, wherever both stand, and its entity goes in the same step.
@(test)
a_closed_mesh_joins_or_carves_a_volume_as_samples_and_undo_brings_its_entity_back :: proc(t:^testing.T) {
    root:=base.test_folder(t,"terrain")
    path:=fmt.tprintf("%s/solid.terrain",root)
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=root,capacity=16})) {return}
    defer host.assets_destroy(&assets)
    for brush in ([2]terrain.Brush_Kind{.Add,.Carve}) {
        world:Create_Test_World
        if !test_world_init(t,&world) {return}
        defer test_world_destroy(&world)
        ref:=test_world_ref(&world)
        source:terrain.Source;defer terrain.source_destroy(&source)
        // Solid below the middle of its box, air above it.
        if !testing.expect(t,terrain.source_make(&source,.Volume,{33,33,33},1,16)) {return}
        id:=base.Asset_Id{41,42}
        source.revision=1
        testing.expect_value(t,terrain.source_save(&source,path,id,&assets.types),asset.Error.None)
        asset.registry_memory_drop(&assets.registry,"solid.terrain")
        host.assets_scan(&assets)
        before,before_error:=serial.file_read(path,context.allocator)
        defer delete(before)
        testing.expect_value(t,before_error,serial.File_Error.None)
        owner:=core.create(&world.entities)
        operand:=core.create(&world.entities)
        pose:=mm.Transform{position={10,4,-8},rotation=mm.quat_axis_angle({0,1,0},0.73),scale={1,1,1}}
        // A cube six a side, over the ground to add it and under it to carve it.
        centre:=brush==.Add?[3]f32{0,4,0}:[3]f32{0,-4,0}
        operand_pose:=mm.Transform{position=mm.transform_point(pose,centre),rotation=pose.rotation,scale={6,6,-6}}
        operand_static:=erender.Mesh_Renderer{shape=.Cube}
        for e in ([2]core.Entity{owner,operand}) {core.add(&world.ids,e,core.Id{value=base.Entity_Id(100+u64(e))})}
        core.add(&world.transforms,owner,core.Transform(pose))
        core.add(&world.transforms,operand,core.Transform(operand_pose))
        core.add(&world.worlds,owner,core.World_Transform{transform=pose})
        core.add(&world.worlds,operand,core.World_Transform{transform=operand_pose})
        core.add(&world.meshes,operand,operand_static)
        core.add(&world.terrains,owner,terrain.Terrain{source=id,revision=1})
        core.world_settle(ref)
        selection:history.Selection;defer delete(selection.entities)
        history.selection_set(&selection,{owner,operand})
        edits:history.Edits;defer history.edits_free(&edits)
        history.edits_reset(&edits,ref)
        app:=host.App{allocator=context.allocator,assets=&assets}
        document:editor.Document
        session:=editor.Session{app=&app,info=ref.info,edit_world=&world,assets_root=root,headless=true,selection=&selection,edits=&edits,document=&document}
        tool:Terrain_Tool;tool_ready(&tool);defer terrain_tool_free(&tool)
        tool.brush,tool.shaping,tool.shape,tool.blend=brush,true,.Selected,0
        terrain_sync(&session,&tool,core.read(&world.terrains),app.assets)
        if !testing.expect(t,stroke_prepare(&tool,app.assets,app.allocator,&world.terrains,&world.worlds,editor.Pick{entity=owner})) {return}
        // Without its terrain selected nothing changes.
        history.selection_set(&selection,{operand})
        terrain_operand(&session,&tool,ref,app.assets,app.allocator)
        testing.expect(t,core.alive(&world.entities,operand))
        testing.expect(t,!edits.open && !edits.commit)
        testing.expect_value(t,world.terrains.values[0].revision,u32(1))
        testing.expect_value(t,len(tool.steps),0)
        history.selection_set(&selection,{owner,operand})
        terrain_operand(&session,&tool,ref,app.assets,app.allocator)
        if !testing.expectf(t,edits.commit,"%v rejected: %s",brush,string(session.toast[:session.toast_length])) {continue}
        testing.expect(t,history.edits_commit(&edits,ref,&selection))
        testing.expect_value(t,edits.cursor,1)
        testing.expect(t,!core.alive(&world.entities,operand))
        testing.expect_value(t,history.selection_active(&selection),owner)
        testing.expect_value(t,world.terrains.values[0].revision,u32(2))
        on_disk,_:=serial.file_read(path,context.allocator);defer delete(on_disk)
        testing.expect(t,string(on_disk)==string(before),"the registry holds the step until its flush")
        loaded:terrain.Source;defer terrain.source_destroy(&loaded)
        if !testing.expect(t,terrain.terrain_read(&loaded,&assets,id)) {continue}
        testing.expect_value(t,loaded.revision,u32(2))
        // The sample at the middle of the cube, and one well outside it.
        inside:=[3]int{16,16+int(centre.y),16}
        outside:=[3]int{16+8,16+int(centre.y),16}
        if brush==.Add {
            testing.expect(t,terrain.source_value(&source,inside)>0 && terrain.source_value(&loaded,inside)<0,"the air the cube holds turns solid")
        } else {
            testing.expect(t,terrain.source_value(&source,inside)<0 && terrain.source_value(&loaded,inside)>0,"the ground the cube holds turns to air")
        }
        testing.expect_value(t,terrain.source_value(&loaded,outside),terrain.source_value(&source,outside))
        committed:=test_held(t,&assets,"solid.terrain")
        defer delete(committed)
        testing.expect(t,editor.files_flush(&session,true))
        flushed,_:=serial.file_read(path,context.allocator);defer delete(flushed)
        testing.expect(t,string(flushed)==string(committed))
        testing.expect(t,history.undo(&edits,ref,&selection))
        terrain_sync(&session,&tool,core.read(&world.terrains),app.assets)
        testing.expect(t,core.alive(&world.entities,operand))
        testing.expect_value(t,core.at(&world.meshes,core.row_of(&world.meshes,operand)),operand_static)
        testing.expect_value(t,core.at(&world.transforms,core.row_of(&world.transforms,operand)),core.Transform(operand_pose))
        undone:=test_held(t,&assets,"solid.terrain")
        defer delete(undone)
        testing.expect(t,string(undone)==string(before))
        testing.expect(t,history.redo(&edits,ref,&selection))
        terrain_sync(&session,&tool,core.read(&world.terrains),app.assets)
        testing.expect(t,!core.alive(&world.entities,operand))
        redone:=test_held(t,&assets,"solid.terrain")
        defer delete(redone)
        testing.expect(t,string(redone)==string(committed))
        // A mesh without an inside is refused, with what to do about it.
        if brush==.Add {
            open:=core.create(&world.entities)
            core.add(&world.ids,open,core.Id{value=base.Entity_Id(300)})
            core.add(&world.transforms,open,core.Transform(operand_pose))
            core.add(&world.worlds,open,core.World_Transform{transform=operand_pose})
            core.add(&world.meshes,open,erender.Mesh_Renderer{shape=.Plane})
            core.world_settle(ref)
            history.selection_set(&selection,{owner,open})
            terrain_operand(&session,&tool,ref,app.assets,app.allocator)
            testing.expect(t,core.alive(&world.entities,open) && !edits.commit)
            testing.expect(t,strings.contains(string(session.toast[:session.toast_length]),"not closed"))
        }
    }
}

// The surface of a Volume goes to a plain .mesh beside it.
@(test)
the_surface_of_a_volume_is_saved_as_a_mesh_asset :: proc(t:^testing.T) {
    root:=base.test_folder(t,"terrain")
    path:=fmt.tprintf("%s/dug.terrain",root)
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=root,capacity=16})) {return}
    defer host.assets_destroy(&assets)
    world:Create_Test_World
    if !test_world_init(t,&world) {return}
    defer test_world_destroy(&world)
    ref:=test_world_ref(&world)
    source:terrain.Source;defer terrain.source_destroy(&source)
    if !testing.expect(t,terrain.source_make(&source,.Volume,{17,17,17},1,8)) {return}
    id:=base.Asset_Id{51,52}
    source.revision=1
    testing.expect_value(t,terrain.source_save(&source,path,id,&assets.types),asset.Error.None)
    host.assets_scan(&assets)
    owner:=core.create(&world.entities)
    core.add(&world.ids,owner,core.Id{value=base.Entity_Id(101)})
    core.add(&world.transforms,owner,core.TRANSFORM_IDENTITY)
    core.add(&world.worlds,owner,core.World_Transform{transform=mm.TRANSFORM_IDENTITY})
    core.add(&world.terrains,owner,terrain.Terrain{source=id,revision=1})
    core.world_settle(ref)
    selection:history.Selection;defer delete(selection.entities)
    history.selection_set(&selection,{owner})
    edits:history.Edits;defer history.edits_free(&edits)
    history.edits_reset(&edits,ref)
    app:=host.App{allocator=context.allocator,assets=&assets}
    document:editor.Document
    session:=editor.Session{app=&app,info=ref.info,edit_world=&world,assets_root=root,headless=true,selection=&selection,edits=&edits,document=&document}
    tool:Terrain_Tool;tool_ready(&tool);defer terrain_tool_free(&tool)
    terrain_sync(&session,&tool,core.read(&world.terrains),app.assets)
    if !testing.expect(t,stroke_prepare(&tool,app.assets,app.allocator,&world.terrains,&world.worlds,editor.Pick{entity=owner})) {return}
    terrain_surface_mesh(&session,&tool,app.assets,app.allocator)
    _,found:=asset.registry_memory_find(&assets.registry,"dug.mesh")
    if !testing.expectf(t,found,"no mesh was written: %s",string(session.toast[:session.toast_length])) {return}
    bytes:=test_held(t,&assets,"dug.mesh");defer delete(bytes)
    file:asset.Asset
    if !testing.expect_value(t,asset.asset_open(&file,bytes,context.allocator),asset.Error.None) {return}
    defer asset.asset_close(&file)
    view,error:=asset.mesh_view(&file,&assets.types)
    testing.expect_value(t,error,asset.Error.None)
    testing.expect(t,view.info!=nil && view.info.triangle_count>=2*14*14,"the top of the block and its sides")
    testing.expect(t,history.edits_commit(&edits,ref,&selection))
    testing.expect(t,editor.files_flush(&session,true) && os.exists(fmt.tprintf("%s/dug.mesh",root)))
}
