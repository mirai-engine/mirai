package terrain_editor

import "core:fmt"
import "core:os"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/history"
import "mirai:host"
import terrain "plugins:terrain/runtime"
import "mirai:std/base"
import "mirai:std/serial"

@(private)
unsaved_test_held :: proc(a:^host.Assets,relative:string) -> bool {_,found:=asset.registry_memory_find(&a.registry,relative);return found}

// One stroke of the tool on owner, confirmed as a step.
@(private)
unsaved_test_sculpt :: proc(t:^testing.T,s:^editor.Session,tool:^Terrain_Tool,ref:core.World_Ref,world:^Create_Test_World,owner:core.Entity,height:f32) {
    unsaved_test_stroke(t,s,tool,ref,world,owner,{kind=.Raise,center={0,0,0},radius=1,amount=height})
}

@(private)
unsaved_test_stroke :: proc(t:^testing.T,s:^editor.Session,tool:^Terrain_Tool,ref:core.World_Ref,world:^Create_Test_World,owner:core.Entity,brush:terrain.Brush) {
    terrain_sync(s,tool,core.read(&world.terrains),s.app.assets)
    if !testing.expect(t,stroke_prepare(tool,s.app.assets,s.app.allocator,&world.terrains,&world.worlds,editor.Pick{entity=owner})) {return}
    if !testing.expect(t,stroke_baseline(tool)) {return}
    tool.stroke.active=true
    change:=terrain.source_edit(&tool.stroke.source,brush)
    testing.expect(t,change.changed && change.error==.None)
    tool.stroke.changed=true
    stroke_end(s,tool,ref,s.app.assets)
    testing.expect(t,history.edits_commit(s.edits,ref,s.selection))
}

@(test)
terrain_history_follows_a_save_and_a_discard_of_its_file :: proc(t:^testing.T) {
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
    if !testing.expect(t,terrain.source_make(&source,.Heightfield,{5,1,5},1,4)) {return}
    id:=base.Asset_Id{81,82};source.revision=1
    testing.expect_value(t,terrain.source_save(&source,path,id,&assets.types),asset.Error.None)
    host.assets_scan(&assets)
    disk:=test_held(t,&assets,relative);defer delete(disk)
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
    unsaved:=unsaved_test_held
    sculpt:=unsaved_test_sculpt
    middle:=[3]int{2,0,2}

    // A stroke stays in memory; Save writes it and the history keeps it.
    sculpt(t,&s,&tool,ref,&world,owner,2)
    testing.expect(t,unsaved(&assets,relative))
    on_disk,_:=serial.file_read(path);testing.expect(t,string(on_disk)==string(disk));delete(on_disk)
    stroked:=test_held(t,&assets,relative);defer delete(stroked)
    saved,written:=editor.assets_save(&s,{relative})
    testing.expect(t,written && saved==1 && !unsaved(&assets,relative))
    on_disk,_=serial.file_read(path);testing.expect(t,string(on_disk)==string(stroked));delete(on_disk)
    terrain_sync(&s,&tool,core.read(&world.terrains),app.assets)
    testing.expect(t,history.undo(&edits,ref,&selection))
    terrain_sync(&s,&tool,core.read(&world.terrains),app.assets)
    testing.expect(t,unsaved(&assets,relative))
    undone:=test_held(t,&assets,relative);testing.expect(t,string(undone)==string(disk));delete(undone)
    testing.expect(t,history.redo(&edits,ref,&selection))
    terrain_sync(&s,&tool,core.read(&world.terrains),app.assets)
    testing.expect(t,!unsaved(&assets,relative))

    // Discard takes back the disk: the revision the owners are at holds it,
    // and redo does not bring the discarded stroke back.
    sculpt(t,&s,&tool,ref,&world,owner,5)
    testing.expect_value(t,core.at(&world.terrains,core.row_of(&world.terrains,owner)).revision,u32(3))
    testing.expect(t,unsaved(&assets,relative))
    testing.expect_value(t,editor.assets_discard(&s,{relative}),1)
    terrain_sync(&s,&tool,core.read(&world.terrains),app.assets)
    head:=editor.revision_head(&tool.history,id,3)
    if !testing.expect(t,head!=nil) {return}
    testing.expect_value(t,terrain.source_value(head,middle),f32(2))
    testing.expect(t,stroke_prepare(&tool,app.assets,app.allocator,&world.terrains,&world.worlds,editor.Pick{entity=owner}))
    testing.expect_value(t,terrain.source_value(&tool.stroke.source,middle),f32(2))
    testing.expect(t,history.undo(&edits,ref,&selection))
    terrain_sync(&s,&tool,core.read(&world.terrains),app.assets)
    testing.expect(t,!unsaved(&assets,relative))
    testing.expect(t,history.redo(&edits,ref,&selection))
    terrain_sync(&s,&tool,core.read(&world.terrains),app.assets)
    testing.expect(t,!unsaved(&assets,relative))
    on_disk,_=serial.file_read(path);testing.expect(t,string(on_disk)==string(stroked));delete(on_disk)
}

// Undo of a new terrain takes its file away although the strokes after it
// changed the file and the tool did not restore their revisions in between
// (consecutive undos of the API run no frame).
@(test)
undoing_a_new_terrain_takes_its_file_away_after_its_strokes :: proc(t:^testing.T) {
    root:=base.test_folder(t,"terrain")
    relative:="terrain/Heightfield Terrain.terrain"
    path:=fmt.tprintf("%s/%s",root,relative)
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=root,capacity=8})) {return}
    defer host.assets_destroy(&assets)
    world:Create_Test_World
    if !test_world_init(t,&world) {return}
    defer test_world_destroy(&world)
    ref:=test_world_ref(&world)
    app:=host.App{allocator=context.allocator,assets=&assets}
    selection:history.Selection;defer delete(selection.entities)
    edits:history.Edits;defer history.edits_free(&edits)
    history.edits_reset(&edits,ref)
    viewport:editor.Viewport
    s:=editor.Session{app=&app,info=ref.info,edit_world=&world,assets_root=root,headless=true,selection=&selection,edits=&edits,viewport=&viewport,id_state=517}
    tool:Terrain_Tool;tool_ready(&tool);defer terrain_tool_free(&tool)
    tool.create_kind=.Heightfield;tool.samples,tool.chunk_cells=5,4
    terrain_create(&s,&tool,ref,app.assets,app.allocator)
    if !testing.expect(t,history.edits_commit(&edits,ref,&selection)) {return}
    if !testing.expect_value(t,len(world.terrains.values),1) {return}
    owner:=world.terrains.entities[0]
    created:=test_held(t,&assets,relative);defer delete(created)
    core.add(&world.worlds,owner,core.World_Transform{transform={rotation=1,scale={1,1,1}}})
    test_world_settle(&world)
    unsaved_test_sculpt(t,&s,&tool,ref,&world,owner,2)
    unsaved_test_sculpt(t,&s,&tool,ref,&world,owner,3)
    stroked:=test_held(t,&assets,relative);defer delete(stroked)
    testing.expect_value(t,edits.cursor,3)
    for _ in 0..<3 {testing.expect(t,history.undo(&edits,ref,&selection))}
    testing.expect_value(t,len(world.terrains.values),0)
    testing.expect(t,!editor.file_exists(&s,path) && !unsaved_test_held(&assets,relative))
    testing.expect(t,history.redo(&edits,ref,&selection))
    held:=test_held(t,&assets,relative);testing.expect(t,string(held)==string(created));delete(held)
    for _ in 0..<2 {testing.expect(t,history.redo(&edits,ref,&selection))}
    terrain_sync(&s,&tool,core.read(&world.terrains),app.assets)
    held=test_held(t,&assets,relative);testing.expect(t,string(held)==string(stroked));delete(held)
    testing.expect(t,!os.exists(path))
}

// The strokes of a Volume are steps of undo; the snapshots of its history
// hold the blocks the surface crosses, not every sample.
@(test)
volume_strokes_are_steps_of_undo_that_keep_only_their_blocks :: proc(t:^testing.T) {
    root:=base.test_folder(t,"terrain")
    relative:="terrain/Volumetric Terrain.terrain"
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=root,capacity=8})) {return}
    defer host.assets_destroy(&assets)
    world:Create_Test_World
    if !test_world_init(t,&world) {return}
    defer test_world_destroy(&world)
    ref:=test_world_ref(&world)
    app:=host.App{allocator=context.allocator,assets=&assets}
    selection:history.Selection;defer delete(selection.entities)
    edits:history.Edits;defer history.edits_free(&edits)
    history.edits_reset(&edits,ref)
    viewport:editor.Viewport
    s:=editor.Session{app=&app,info=ref.info,edit_world=&world,assets_root=root,headless=true,selection=&selection,edits=&edits,viewport=&viewport,id_state=519}
    tool:Terrain_Tool;tool_ready(&tool);defer terrain_tool_free(&tool)
    tool.create_kind=.Volume;tool.samples,tool.depth,tool.chunk_cells=97,97,16
    terrain_create(&s,&tool,ref,app.assets,app.allocator)
    if !testing.expect(t,history.edits_commit(&edits,ref,&selection)) {return}
    if !testing.expect_value(t,len(world.terrains.values),1) {return}
    owner:=world.terrains.entities[0]
    id:=world.terrains.values[0].source
    core.add(&world.worlds,owner,core.World_Transform{transform={rotation=1,scale={1,1,1}}})
    test_world_settle(&world)
    created:=test_held(t,&assets,relative);defer delete(created)
    cave:=[3]f32{-8.5,-24.5,-8.5}
    deep:=[3]int{40,24,40}
    unsaved_test_stroke(t,&s,&tool,ref,&world,owner,{kind=.Carve,center=cave,radius=20,amount=1})
    carved:=test_held(t,&assets,relative);defer delete(carved)
    unsaved_test_stroke(t,&s,&tool,ref,&world,owner,{kind=.Add,center=cave,radius=6,amount=1})
    filled:=test_held(t,&assets,relative);defer delete(filled)
    testing.expect_value(t,edits.cursor,3)
    // The head holds values only for the blocks the surface crosses, and each
    // step only the blocks its stroke changed.
    head:=editor.revision_head(&tool.history,id,3)
    if !testing.expect(t,head!=nil) {return}
    testing.expect(t,terrain.grid_dense(&head.field)<97*97*97,"the head holds no values for the blocks all air or all solid")
    block,_:=terrain.grid_page_at(&head.field,deep)
    steps,carved_air:=0,false
    for &step in tool.steps {
        if step.source!=id {continue}
        steps+=1
        testing.expect(t,!step.whole && !step.field.whole && len(step.field.pages)<head.field.counts.x*head.field.counts.y*head.field.counts.z,"a step keeps the blocks its stroke changed")
        // The step to the filling keeps the carved revision, its block all air.
        if step.to==3 {for entry in step.field.pages {if entry.index==block {carved_air=entry.page.values==nil}}}
    }
    testing.expect_value(t,steps,2)
    testing.expect(t,carved_air,"the carved block is all air in the step that fills it")
    // Undo and redo bring back the file of each step.
    testing.expect(t,history.undo(&edits,ref,&selection))
    terrain_sync(&s,&tool,core.read(&world.terrains),app.assets)
    held:=test_held(t,&assets,relative);testing.expect(t,string(held)==string(carved));delete(held)
    testing.expect(t,history.undo(&edits,ref,&selection))
    terrain_sync(&s,&tool,core.read(&world.terrains),app.assets)
    held=test_held(t,&assets,relative);testing.expect(t,string(held)==string(created));delete(held)
    loaded:terrain.Source;defer terrain.source_destroy(&loaded)
    testing.expect(t,terrain.terrain_read(&loaded,&assets,id))
    testing.expect(t,terrain.source_value(&loaded,deep)<0,"undoing the carving gives back the solid")
    for _ in 0..<2 {
        testing.expect(t,history.redo(&edits,ref,&selection))
        terrain_sync(&s,&tool,core.read(&world.terrains),app.assets)
    }
    held=test_held(t,&assets,relative);testing.expect(t,string(held)==string(filled));delete(held)
}
