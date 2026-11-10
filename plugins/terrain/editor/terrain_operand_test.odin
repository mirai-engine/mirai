package terrain_editor

import "core:fmt"
import "core:math/linalg"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/history"
import erender "mirai:engine/render"
import "mirai:host"
import terrain "plugins:terrain/runtime"
import "mirai:std/base"
import "mirai:std/geom"
import mm "mirai:std/math"
import "mirai:std/serial"

@(test)
terrain_conversion_requires_its_owner_to_remain_selected :: proc(t:^testing.T) {
    root:=base.test_folder(t,"terrain")
    path:=fmt.tprintf("%s/heightfield.terrain",root)
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=root,capacity=8})) {return}
    defer host.assets_destroy(&assets)
    world:Create_Test_World
    if !core.test_world_init(t,&world,test_types) {return}
    defer core.test_world_destroy(&world)
    ref:=core.test_world_ref(&world)
    source:terrain.Source;defer terrain.source_destroy(&source)
    if !testing.expect(t,terrain.source_make(&source,.Heightfield,{5,1,5},1,4)) {return}
    id:=base.Asset_Id{61,62};source.revision=1
    testing.expect_value(t,terrain.source_save(&source,path,id,&assets.types),asset.Error.None)
    host.assets_scan(&assets)
    before,before_error:=serial.file_read(path,context.allocator);defer delete(before)
    testing.expect_value(t,before_error,serial.File_Error.None)
    owner:=core.create(&world.entities);other:=core.create(&world.entities)
    for e in ([2]core.Entity{owner,other}) {
        core.add(&world.ids,e,core.Id{value=base.Entity_Id(100+u64(e))})
        core.add(&world.transforms,e,core.TRANSFORM_IDENTITY)
        core.add(&world.meshes,e,erender.Mesh_Renderer{})
    }
    core.add(&world.terrains,owner,terrain.Terrain{source=id,revision=1})
    core.world_settle(ref)
    selection:history.Selection;defer delete(selection.entities)
    history.selection_set(&selection,{other})
    edits:history.Edits;defer history.edits_free(&edits)
    history.edits_reset(&edits,ref)
    app:=host.App{allocator=context.allocator,assets=&assets}
    session:=editor.Session{app=&app,info=ref.info,edit_world=&world,assets_root=root,headless=true,selection=&selection,edits=&edits}
    tool:Terrain_Tool;tool_ready(&tool);defer terrain_tool_free(&tool)
    tool.assets=&assets;tool.stroke.id,tool.stroke.entity,tool.stroke.revision=id,owner,1
    if !testing.expect(t,terrain.source_clone(&tool.stroke.source,&source)) {return}
    terrain_sync(&session,&tool,core.read(&world.terrains),app.assets)
    terrain_convert(&session,&tool,ref,app.assets,app.allocator)
    testing.expect(t,!edits.open && !edits.commit)
    testing.expect_value(t,edits.cursor,0)
    testing.expect_value(t,core.get(&world.terrains,owner).revision,u32(1))
    testing.expect_value(t,tool.stroke.source.kind,terrain.Source_Kind.Heightfield)
    testing.expect_value(t,len(tool.steps),0)
    testing.expect_value(t,history.selection_active(&selection),other)
    untouched,untouched_error:=serial.file_read(path,context.allocator);defer delete(untouched)
    testing.expect_value(t,untouched_error,serial.File_Error.None)
    testing.expect_value(t,len(untouched),len(before))
    if len(untouched)==len(before) {for value,i in untouched {testing.expect_value(t,value,before[i])}}
    history.selection_set(&selection,{owner})
    terrain_convert(&session,&tool,ref,app.assets,app.allocator)
    testing.expect(t,history.edits_commit(&edits,ref,&selection))
    testing.expect_value(t,tool.stroke.source.kind,terrain.Source_Kind.Mesh)
    testing.expect_value(t,core.get(&world.terrains,owner).revision,u32(2))
    _,unsaved:=asset.registry_memory_find(&assets.registry,"heightfield.terrain")
    testing.expect(t,unsaved)
    testing.expect(t,history.undo(&edits,ref,&selection))
    terrain_sync(&session,&tool,core.read(&world.terrains),app.assets)
    undone:=test_held(t,&assets,"heightfield.terrain");defer delete(undone)
    testing.expect(t,string(undone)==string(before))
    _,unsaved=asset.registry_memory_find(&assets.registry,"heightfield.terrain")
    testing.expect(t,!unsaved)
}

// What the registry of the assets holds of a file: its memory, unsaved, or the disk.
@(private)
test_held :: proc(t:^testing.T,assets:^host.Assets,relative:string) -> []u8 {
    data,error:=asset.registry_read(&assets.registry,relative,context.allocator)
    testing.expect_value(t,error,asset.Error.None)
    return data
}

@(test)
terrain_boolean_consumes_a_transformed_operand_and_undo_restores_geometry_materials_and_selection :: proc(t:^testing.T) {
    root:=base.test_folder(t,"terrain")
    path:=fmt.tprintf("%s/solid.terrain",root)
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=root,capacity=16})) {return}
    defer host.assets_destroy(&assets)
    for scenario in 0..<3 {
        brush:=scenario==1?terrain.Brush_Kind.Subtract:.Union
        shared_overrides:=scenario==2
        world:Create_Test_World
        if !core.test_world_init(t,&world,test_types) {return}
        defer core.test_world_destroy(&world)
        ref:=core.test_world_ref(&world)
        geometry:geom.Mesh_Buffer
        geom.mesh_buffer_init(&geometry);defer geom.mesh_buffer_destroy(&geometry)
        geom.cube_build(&geometry,{8,6,8})
        for &p in geometry.positions {p.y-=3}
        source:terrain.Source;defer terrain.source_destroy(&source)
        red,blue:=base.Asset_Id{21,22},base.Asset_Id{31,32}
        slots:=[1]base.Asset_Id{red}
        if !testing.expect(t,terrain.source_from_mesh(&source,geom.mesh_buffer_view(&geometry),1,4,slots[:])) {return}
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
        shared:=core.NONE
        pose:=mm.Transform{position={10,4,-8},rotation=mm.quat_axis_angle({0,1,0},0.73),scale={2,1.5,3}}
        to_world:=mm.transform_matrix(pose)
        operand_pose:=pose
        operand_pose.position=(to_world*[4]f32{4,-3,0,1}).xyz
        operand_pose.scale*=mm.Vec3{-4,2,2}
        operand_static:=erender.Mesh_Renderer{shape=.Cube}
        operand_static.materials[0]=shared_overrides?red:blue
        // Slot 0 shows the layers, which no override of an owner reaches: red joins it.
        shared_override:=erender.Material_Override{count=1}
        shared_override.names[0],shared_override.values[0]=base.name_hash("roughness"),{0.2,0,0,0}
        for e in ([2]core.Entity{owner,operand}) {
            core.add(&world.ids,e,core.Id{value=base.Entity_Id(100+u64(e))})
        }
        core.add(&world.transforms,owner,core.Transform(pose))
        core.add(&world.transforms,operand,core.Transform(operand_pose))
        core.add(&world.worlds,owner,core.World_Transform{transform=pose})
        core.add(&world.worlds,operand,core.World_Transform{transform=operand_pose})
        core.add(&world.meshes,operand,operand_static)
        core.add(&world.terrains,owner,terrain.Terrain{source=id,revision=1})
        if shared_overrides {
            shared=core.create(&world.entities)
            core.add(&world.ids,shared,core.Id{value=base.Entity_Id(100+u64(shared))})
            core.add(&world.transforms,shared,core.TRANSFORM_IDENTITY)
            core.add(&world.worlds,shared,core.World_Transform{transform=mm.TRANSFORM_IDENTITY})
            core.add(&world.overrides,shared,shared_override)
            core.add(&world.terrains,shared,terrain.Terrain{source=id,revision=1})
        }
        core.world_settle(ref)
        selection:history.Selection;defer delete(selection.entities)
        history.selection_set(&selection,{owner,operand})
        edits:history.Edits;defer history.edits_free(&edits)
        history.edits_reset(&edits,ref)
        app:=host.App{allocator=context.allocator,assets=&assets}
        document:editor.Document
        session:=editor.Session{app=&app,info=ref.info,edit_world=&world,assets_root=root,headless=true,selection=&selection,edits=&edits,document=&document}
        tool:Terrain_Tool;tool_ready(&tool);defer terrain_tool_free(&tool)
        tool.brush=brush
        terrain_sync(&session,&tool,core.read(&world.terrains),app.assets)
        if !testing.expect(t,stroke_prepare(&tool,app.assets,app.allocator,core.read(&world.terrains),core.read(&world.worlds),editor.Pick{entity=owner})) {return}
        history.selection_set(&selection,{operand})
        terrain_operand(&session,&tool,ref,app.assets,app.allocator)
        testing.expect(t,core.alive(&world.entities,operand))
        testing.expect(t,!edits.open && !edits.commit)
        testing.expect_value(t,edits.cursor,0)
        testing.expect_value(t,world.terrains.values[0].revision,u32(1))
        testing.expect_value(t,tool.stroke.revision,u32(1))
        testing.expect_value(t,len(tool.steps),0)
        testing.expect_value(t,len(tool.stroke.source.slots),0)
        testing.expect_value(t,tool.stroke.source.layers[0].material,red)
        untouched,untouched_error:=serial.file_read(path,context.allocator)
        defer delete(untouched)
        testing.expect_value(t,untouched_error,serial.File_Error.None)
        testing.expect_value(t,len(untouched),len(before))
        if len(untouched)==len(before) {for value,i in untouched {testing.expect_value(t,value,before[i])}}
        history.selection_set(&selection,{owner,operand})
        terrain_operand(&session,&tool,ref,app.assets,app.allocator)
        if !testing.expectf(t,edits.commit,"%v rejected: %s",brush,string(session.toast[:session.toast_length])) {continue}
        testing.expect(t,history.edits_commit(&edits,ref,&selection))
        testing.expect_value(t,edits.cursor,1)
        testing.expect(t,!core.alive(&world.entities,operand))
        testing.expect_value(t,history.selection_active(&selection),owner)
        testing.expect_value(t,len(selection.entities),1)
        testing.expect_value(t,world.terrains.values[0].revision,u32(2))
        on_disk,_:=serial.file_read(path,context.allocator);defer delete(on_disk)
        testing.expect(t,string(on_disk)==string(before))
        loaded:terrain.Source;defer terrain.source_destroy(&loaded)
        if !testing.expect(t,terrain.terrain_read(&loaded,&assets,id)) {continue}
        testing.expect_value(t,loaded.revision,u32(2))
        testing.expect(t,terrain.source_mesh_collect(&loaded,&geometry))
        volume:=geom.mesh_volume(geometry.positions[:],geometry.indices[:])
        expected:=brush==.Union?f32(392):f32(376)
        testing.expectf(t,abs(volume-expected)<0.002,"%v transformed volume %g != %g",brush,volume,expected)
        testing.expect(t,geom.mesh_is_closed(geometry.positions[:],geometry.indices[:]))
        for face in 0..<len(geometry.indices)/3 {
            i,j,k:=geometry.indices[face*3],geometry.indices[face*3+1],geometry.indices[face*3+2]
            cross:=linalg.cross(geometry.positions[j]-geometry.positions[i],geometry.positions[k]-geometry.positions[i])
            if linalg.length(cross)<1e-4 {continue}
            normal:=linalg.normalize0(cross)
            testing.expectf(t,linalg.dot(normal,geometry.normals[i])>0.999,"%v normal did not follow reflected winding",brush)
        }
        if brush==.Union {
            expected_slots:=shared_overrides?1:2
            testing.expect_value(t,len(loaded.slots),expected_slots-1)
            if expected_slots==2 && len(loaded.slots)==1 {testing.expect_value(t,loaded.slots[0],blue)}
            has_operand,has_original:=false,false
            for m in geometry.materials {if m==u32(expected_slots-1) {has_operand=true};if m==0 {has_original=true};testing.expect(t,int(m)<expected_slots)}
            testing.expect(t,has_operand && has_original)
        } else {testing.expect_value(t,len(loaded.slots),0)}
        if shared_overrides {
            testing.expect_value(t,core.get(&world.overrides,shared)^,shared_override)
            testing.expect_value(t,core.get(&world.terrains,shared).revision,u32(2))
        }
        committed:=test_held(t,&assets,"solid.terrain")
        defer delete(committed)
        testing.expect(t,history.undo(&edits,ref,&selection))
        terrain_sync(&session,&tool,core.read(&world.terrains),app.assets)
        testing.expect(t,core.alive(&world.entities,operand))
        testing.expect_value(t,core.get(&world.meshes,operand)^,operand_static)
        testing.expect_value(t,core.get(&world.transforms,operand)^,core.Transform(operand_pose))
        testing.expect_value(t,len(selection.entities),2)
        testing.expect_value(t,history.selection_active(&selection),operand)
        if shared_overrides {
            testing.expect_value(t,core.get(&world.overrides,shared)^,shared_override)
            testing.expect_value(t,core.get(&world.terrains,shared).revision,u32(1))
        }
        undone:=test_held(t,&assets,"solid.terrain")
        defer delete(undone)
        testing.expect_value(t,len(undone),len(before))
        if len(undone)==len(before) {for value,i in undone {testing.expect_value(t,value,before[i])}}
        testing.expect(t,history.redo(&edits,ref,&selection))
        terrain_sync(&session,&tool,core.read(&world.terrains),app.assets)
        testing.expect(t,!core.alive(&world.entities,operand))
        if shared_overrides {
            testing.expect_value(t,core.get(&world.overrides,shared)^,shared_override)
            testing.expect_value(t,core.get(&world.terrains,shared).revision,u32(2))
        }
        redone:=test_held(t,&assets,"solid.terrain")
        defer delete(redone)
        testing.expect_value(t,len(redone),len(committed))
        if len(redone)==len(committed) {for value,i in redone {testing.expect_value(t,value,committed[i])}}
    }
}
