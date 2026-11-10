package terrain_editor

import "core:fmt"
import "core:os"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:editor"
import "mirai:host"
import terrain "plugins:terrain/runtime"
import "mirai:std/base"
import "mirai:std/serial"

@(private)
unsaved_test_held :: proc(a:^host.Assets,relative:string) -> bool {_,found:=asset.registry_memory_find(&a.registry,relative);return found}

// One stroke of the tool on owner, confirmed as a step.
@(private)
unsaved_test_sculpt :: proc(t:^testing.T,s:^editor.Session,tool:^Terrain_Tool,ref:core.World_Ref,world:^Create_Test_World,worlds:^core.Table(core.World_Transform),owner:core.Entity,height:f32) {
    unsaved_test_stroke(t,s,tool,ref,world,worlds,owner,{kind=.Raise,center={0,0,0},radius=1,amount=height})
}

@(private)
unsaved_test_stroke :: proc(t:^testing.T,s:^editor.Session,tool:^Terrain_Tool,ref:core.World_Ref,world:^Create_Test_World,worlds:^core.Table(core.World_Transform),owner:core.Entity,brush:terrain.Brush) {
    terrain_sync(s,tool,core.read(&world.terrains),s.app.assets)
    if !testing.expect(t,stroke_prepare(tool,s.app.assets,s.app.allocator,core.read(&world.terrains),core.read(worlds),editor.Pick{entity=owner})) {return}
    if !testing.expect(t,stroke_baseline(tool)) {return}
    tool.stroke.active=true
    change:=terrain.source_edit(&tool.stroke.source,brush)
    testing.expect(t,change.changed && change.error==.None)
    tool.stroke.changed=true
    stroke_end(s,tool,ref,s.app.assets)
    testing.expect(t,editor.edits_commit(s.edits,ref,s.selection))
}

@(test)
terrain_history_follows_a_save_and_a_discard_of_its_file :: proc(t:^testing.T) {
    directory,_:=os.temp_directory(context.temp_allocator)
    root:=fmt.tprintf("%s/mirai-terrain-unsaved-%d",directory,os.get_pid())
    path:=fmt.tprintf("%s/ground.terrain",root)
    relative:="ground.terrain"
    testing.expect_value(t,os.make_directory_all(root),nil)
    defer os.remove(root);defer os.remove(path)
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=root,capacity=8})) {return}
    defer host.assets_destroy(&assets)
    world:Create_Test_World
    create_test_world_init(&world);defer create_test_world_destroy(&world)
    tables:=create_test_tables()
    info:=core.World_Info{entities=offset_of(Create_Test_World,entities),tables=tables[:]}
    ref:=core.world_ref(&world,&info)
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
    selection:editor.Selection;defer delete(selection.entities)
    edits:editor.Edits;defer editor.edits_free(&edits)
    editor.edits_reset(&edits,ref)
    app:=host.App{allocator=context.allocator,assets=&assets}
    s:=editor.Session{app=&app,info=&info,edit_world=&world,assets_root=root,headless=true,selection=&selection,edits=&edits}
    tool:Terrain_Tool;tool_ready(&tool);defer terrain_tool_free(&tool)
    worlds:core.Table(core.World_Transform);core.table_init(&worlds,"World_Transform");defer core.table_destroy(&worlds)
    core.add(&worlds,owner,core.World_Transform{transform={rotation=1,scale={1,1,1}}})
    core.table_settle(&worlds,&world.entities)
    unsaved:=unsaved_test_held
    sculpt:=unsaved_test_sculpt
    middle:=[3]int{2,0,2}

    // A stroke stays in memory; Save writes it and the history keeps it.
    sculpt(t,&s,&tool,ref,&world,&worlds,owner,2)
    testing.expect(t,unsaved(&assets,relative))
    on_disk,_:=serial.file_read(path);testing.expect(t,string(on_disk)==string(disk));delete(on_disk)
    stroked:=test_held(t,&assets,relative);defer delete(stroked)
    saved,written:=editor.assets_save(&s,{relative})
    testing.expect(t,written && saved==1 && !unsaved(&assets,relative))
    on_disk,_=serial.file_read(path);testing.expect(t,string(on_disk)==string(stroked));delete(on_disk)
    terrain_sync(&s,&tool,core.read(&world.terrains),app.assets)
    testing.expect(t,editor.undo(&edits,ref,&selection))
    terrain_sync(&s,&tool,core.read(&world.terrains),app.assets)
    testing.expect(t,unsaved(&assets,relative))
    undone:=test_held(t,&assets,relative);testing.expect(t,string(undone)==string(disk));delete(undone)
    testing.expect(t,editor.redo(&edits,ref,&selection))
    terrain_sync(&s,&tool,core.read(&world.terrains),app.assets)
    testing.expect(t,!unsaved(&assets,relative))

    // Discard takes back the disk: the revision the owners are at holds it,
    // and redo does not bring the discarded stroke back.
    sculpt(t,&s,&tool,ref,&world,&worlds,owner,5)
    testing.expect_value(t,core.get(&world.terrains,owner).revision,u32(3))
    testing.expect(t,unsaved(&assets,relative))
    testing.expect_value(t,editor.assets_discard(&s,{relative}),1)
    terrain_sync(&s,&tool,core.read(&world.terrains),app.assets)
    head:=editor.revision_head(&tool.history,id,3)
    if !testing.expect(t,head!=nil) {return}
    testing.expect_value(t,terrain.source_value(head,middle),f32(2))
    testing.expect(t,stroke_prepare(&tool,app.assets,app.allocator,core.read(&world.terrains),core.read(&worlds),editor.Pick{entity=owner}))
    testing.expect_value(t,terrain.source_value(&tool.stroke.source,middle),f32(2))
    testing.expect(t,editor.undo(&edits,ref,&selection))
    terrain_sync(&s,&tool,core.read(&world.terrains),app.assets)
    testing.expect(t,!unsaved(&assets,relative))
    testing.expect(t,editor.redo(&edits,ref,&selection))
    terrain_sync(&s,&tool,core.read(&world.terrains),app.assets)
    testing.expect(t,!unsaved(&assets,relative))
    on_disk,_=serial.file_read(path);testing.expect(t,string(on_disk)==string(stroked));delete(on_disk)
}

// Undo of a new terrain takes its file away although the strokes after it
// changed the file and the tool did not restore their revisions in between
// (consecutive undos of the API run no frame).
@(test)
undoing_a_new_terrain_takes_its_file_away_after_its_strokes :: proc(t:^testing.T) {
    directory,_:=os.temp_directory(context.temp_allocator)
    root:=fmt.tprintf("%s/mirai-terrain-new-%d",directory,os.get_pid())
    relative:="terrain/Heightfield Terrain.terrain"
    path:=fmt.tprintf("%s/%s",root,relative)
    testing.expect_value(t,os.make_directory_all(root),nil)
    defer os.remove(root)
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=root,capacity=8})) {return}
    defer host.assets_destroy(&assets)
    world:Create_Test_World
    create_test_world_init(&world);defer create_test_world_destroy(&world)
    tables:=create_test_tables()
    info:=core.World_Info{entities=offset_of(Create_Test_World,entities),tables=tables[:]}
    ref:=core.world_ref(&world,&info)
    app:=host.App{allocator=context.allocator,assets=&assets}
    selection:editor.Selection;defer delete(selection.entities)
    edits:editor.Edits;defer editor.edits_free(&edits)
    editor.edits_reset(&edits,ref)
    viewport:editor.Viewport
    s:=editor.Session{app=&app,info=&info,edit_world=&world,assets_root=root,headless=true,selection=&selection,edits=&edits,viewport=&viewport,id_state=517}
    tool:Terrain_Tool;tool_ready(&tool);defer terrain_tool_free(&tool)
    tool.create_kind=.Heightfield;tool.samples,tool.chunk_cells=5,4
    terrain_create(&s,&tool,ref,app.assets,app.allocator)
    if !testing.expect(t,editor.edits_commit(&edits,ref,&selection)) {return}
    if !testing.expect_value(t,len(world.terrains.values),1) {return}
    owner:=world.terrains.entities[0]
    created:=test_held(t,&assets,relative);defer delete(created)
    worlds:core.Table(core.World_Transform);core.table_init(&worlds,"World_Transform");defer core.table_destroy(&worlds)
    core.add(&worlds,owner,core.World_Transform{transform={rotation=1,scale={1,1,1}}})
    core.table_settle(&worlds,&world.entities)
    unsaved_test_sculpt(t,&s,&tool,ref,&world,&worlds,owner,2)
    unsaved_test_sculpt(t,&s,&tool,ref,&world,&worlds,owner,3)
    stroked:=test_held(t,&assets,relative);defer delete(stroked)
    testing.expect_value(t,edits.cursor,3)
    for _ in 0..<3 {testing.expect(t,editor.undo(&edits,ref,&selection))}
    testing.expect_value(t,len(world.terrains.values),0)
    testing.expect(t,!editor.file_exists(&s,path) && !unsaved_test_held(&assets,relative))
    testing.expect(t,editor.redo(&edits,ref,&selection))
    held:=test_held(t,&assets,relative);testing.expect(t,string(held)==string(created));delete(held)
    for _ in 0..<2 {testing.expect(t,editor.redo(&edits,ref,&selection))}
    terrain_sync(&s,&tool,core.read(&world.terrains),app.assets)
    held=test_held(t,&assets,relative);testing.expect(t,string(held)==string(stroked));delete(held)
    testing.expect(t,!os.exists(path))
}

// The strokes of a Volume are steps of undo; the snapshots of its history
// hold the blocks the surface crosses, not every sample.
@(test)
volume_strokes_are_steps_of_undo_that_keep_only_their_blocks :: proc(t:^testing.T) {
    directory,_:=os.temp_directory(context.temp_allocator)
    root:=fmt.tprintf("%s/mirai-terrain-volume-undo-%d",directory,os.get_pid())
    relative:="terrain/Volumetric Terrain.terrain"
    testing.expect_value(t,os.make_directory_all(root),nil)
    defer os.remove_all(root)
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=root,capacity=8})) {return}
    defer host.assets_destroy(&assets)
    world:Create_Test_World
    create_test_world_init(&world);defer create_test_world_destroy(&world)
    tables:=create_test_tables()
    info:=core.World_Info{entities=offset_of(Create_Test_World,entities),tables=tables[:]}
    ref:=core.world_ref(&world,&info)
    app:=host.App{allocator=context.allocator,assets=&assets}
    selection:editor.Selection;defer delete(selection.entities)
    edits:editor.Edits;defer editor.edits_free(&edits)
    editor.edits_reset(&edits,ref)
    viewport:editor.Viewport
    s:=editor.Session{app=&app,info=&info,edit_world=&world,assets_root=root,headless=true,selection=&selection,edits=&edits,viewport=&viewport,id_state=519}
    tool:Terrain_Tool;tool_ready(&tool);defer terrain_tool_free(&tool)
    tool.create_kind=.Volume;tool.samples,tool.depth,tool.chunk_cells=97,97,16
    terrain_create(&s,&tool,ref,app.assets,app.allocator)
    if !testing.expect(t,editor.edits_commit(&edits,ref,&selection)) {return}
    if !testing.expect_value(t,len(world.terrains.values),1) {return}
    owner:=world.terrains.entities[0]
    id:=world.terrains.values[0].source
    worlds:core.Table(core.World_Transform);core.table_init(&worlds,"World_Transform");defer core.table_destroy(&worlds)
    core.add(&worlds,owner,core.World_Transform{transform={rotation=1,scale={1,1,1}}})
    core.table_settle(&worlds,&world.entities)
    created:=test_held(t,&assets,relative);defer delete(created)
    cave:=[3]f32{-8.5,-24.5,-8.5}
    deep:=[3]int{40,24,40}
    unsaved_test_stroke(t,&s,&tool,ref,&world,&worlds,owner,{kind=.Remove,center=cave,radius=20,amount=1})
    carved:=test_held(t,&assets,relative);defer delete(carved)
    unsaved_test_stroke(t,&s,&tool,ref,&world,&worlds,owner,{kind=.Add,center=cave,radius=6,amount=1})
    filled:=test_held(t,&assets,relative);defer delete(filled)
    testing.expect_value(t,edits.cursor,3)
    // The head holds values only for the blocks the surface crosses, and each
    // step only the blocks its stroke changed.
    head:=editor.revision_head(&tool.history,id,3)
    if !testing.expect(t,head!=nil) {return}
    testing.expect(t,terrain.grid_dense(&head.distances)<97*97*97,"the head holds no values for the blocks all air or all solid")
    block,_:=terrain.grid_page_at(&head.distances,deep)
    steps,carved_air:=0,false
    for &step in tool.steps {
        if step.source!=id {continue}
        steps+=1
        testing.expect(t,!step.whole && !step.distances.whole && len(step.distances.pages)<len(head.distances.pages),"a step keeps the blocks its stroke changed")
        // The step to the filling keeps the carved revision, its block all air.
        if step.to==3 {for entry in step.distances.pages {if entry.index==block {carved_air=entry.page.values==nil}}}
    }
    testing.expect_value(t,steps,2)
    testing.expect(t,carved_air,"the carved block is all air in the step that fills it")
    // Undo and redo bring back the file of each step.
    testing.expect(t,editor.undo(&edits,ref,&selection))
    terrain_sync(&s,&tool,core.read(&world.terrains),app.assets)
    held:=test_held(t,&assets,relative);testing.expect(t,string(held)==string(carved));delete(held)
    testing.expect(t,editor.undo(&edits,ref,&selection))
    terrain_sync(&s,&tool,core.read(&world.terrains),app.assets)
    held=test_held(t,&assets,relative);testing.expect(t,string(held)==string(created));delete(held)
    loaded:terrain.Source;defer terrain.source_destroy(&loaded)
    testing.expect(t,terrain.terrain_read(&loaded,&assets,id))
    testing.expect(t,terrain.source_value(&loaded,deep)<0,"undoing the carving gives back the solid")
    for _ in 0..<2 {
        testing.expect(t,editor.redo(&edits,ref,&selection))
        terrain_sync(&s,&tool,core.read(&world.terrains),app.assets)
    }
    held=test_held(t,&assets,relative);testing.expect(t,string(held)==string(filled));delete(held)
}
