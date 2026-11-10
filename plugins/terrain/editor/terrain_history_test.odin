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
a_stroke_keeps_the_pages_it_changed_and_undo_and_redo_trade_them :: proc(t:^testing.T) {
    root:=base.test_folder(t,"terrain")
    path:=fmt.tprintf("%s/wide.terrain",root)
    relative:="wide.terrain"
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=root,capacity=8})) {return}
    defer host.assets_destroy(&assets)
    world:Create_Test_World
    if !core.test_world_init(t,&world,test_types) {return}
    defer core.test_world_destroy(&world)
    ref:=core.test_world_ref(&world)
    // 257 samples on a side: 25 pages of heights, a stroke in one of them.
    source:terrain.Source;defer terrain.source_destroy(&source)
    if !testing.expect(t,terrain.source_make(&source,.Heightfield,{257,1,257},1,32)) {return}
    for x in 0..<257 {for z in 0..<257 {terrain.grid_put(&source.field,{x,0,z},f32((x*7+z*3)%11)*0.125,source.allocator)}}
    id:=base.Asset_Id{91,92};source.revision=1
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
    core.test_world_settle(&world)

    stroke :: proc(t:^testing.T,s:^editor.Session,tool:^Terrain_Tool,ref:core.World_Ref,world:^Create_Test_World,owner:core.Entity,brush:terrain.Brush) {
        terrain_sync(s,tool,core.read(&world.terrains),s.app.assets)
        if !testing.expect(t,stroke_prepare(tool,s.app.assets,s.app.allocator,core.read(&world.terrains),core.read(&world.worlds),editor.Pick{entity=owner})) {return}
        if !testing.expect(t,stroke_baseline(tool)) {return}
        tool.stroke.active=true
        change:=terrain.source_edit(&tool.stroke.source,brush)
        testing.expect(t,change.changed && change.error==.None)
        stroke_changed(&tool.stroke,change)
        stroke_end(s,tool,ref,s.app.assets)
        testing.expect(t,history.edits_commit(s.edits,ref,s.selection))
    }
    stroke(t,&s,&tool,ref,&world,owner,{kind=.Raise,center={-100,0,-100},radius=3,amount=2})
    first:=test_held(t,&assets,relative);defer delete(first)
    stroke(t,&s,&tool,ref,&world,owner,{kind=.Lower,center={90,0,90},radius=3,amount=1})
    second:=test_held(t,&assets,relative);defer delete(second)
    if !testing.expect_value(t,len(tool.steps),2) {return}
    for &step in tool.steps {
        testing.expect(t,!step.whole && !step.field.whole && len(step.field.pages)==1,"a stroke keeps the one page it changed")
    }
    // Undo twice and redo twice put back the bytes of each revision.
    walk :: proc(t:^testing.T,s:^editor.Session,tool:^Terrain_Tool,world:^Create_Test_World,app:^host.App,undo:bool) {
        if undo {testing.expect(t,history.undo(s.edits,editor.edited_world(s),s.selection))} else {testing.expect(t,history.redo(s.edits,editor.edited_world(s),s.selection))}
        terrain_sync(s,tool,core.read(&world.terrains),app.assets)
    }
    walk(t,&s,&tool,&world,&app,true)
    held:=test_held(t,&assets,relative);testing.expect(t,string(held)==string(first));delete(held)
    testing.expect_value(t,terrain.source_value(&tool.stroke.source,{218,0,218}),terrain.source_value(&source,{218,0,218}))
    walk(t,&s,&tool,&world,&app,true)
    held=test_held(t,&assets,relative);testing.expect(t,string(held)==string(disk));delete(held)
    walk(t,&s,&tool,&world,&app,false)
    walk(t,&s,&tool,&world,&app,false)
    held=test_held(t,&assets,relative);testing.expect(t,string(held)==string(second));delete(held)
    testing.expect(t,terrain.source_value(&tool.stroke.source,{218,0,218})<terrain.source_value(&source,{218,0,218}),"the source the tool edits follows its head")
    // A stroke after an undo replaces the history it undid.
    walk(t,&s,&tool,&world,&app,true)
    stroke(t,&s,&tool,ref,&world,owner,{kind=.Raise,center={0,0,0},radius=3,amount=1})
    testing.expect_value(t,len(tool.steps),2)
    testing.expect(t,editor.revision_find(&tool.history,id,2,3)>=0 && editor.revision_find(&tool.history,id,1,2)>=0)
}

@(test)
a_change_of_kind_keeps_the_whole_source_once :: proc(t:^testing.T) {
    head,edited:terrain.Source
    defer terrain.source_destroy(&head);defer terrain.source_destroy(&edited)
    testing.expect(t,terrain.source_make(&head,.Heightfield,{9,1,9},1,4))
    testing.expect(t,terrain.source_make(&edited,.Volume,{9,9,9},1,4))
    step:=Step{source={1,1},from=1,to=2}
    defer step_destroy(&step)
    testing.expect(t,step_make(&step,&head,&edited,{},{},false))
    testing.expect(t,step.whole && step.other.kind==.Heightfield && head.kind==.Volume)
    step_apply(&step,&head)
    testing.expect(t,head.kind==.Heightfield && step.other.kind==.Volume,"undo trades the whole source back")
}

@(test)
terrain_initial_asset_revision_is_the_baseline_of_the_first_undo :: proc(t:^testing.T) {
    world:Create_Test_World
    if !core.test_world_init(t,&world,test_types) {return}
    defer core.test_world_destroy(&world)
    ref:=core.test_world_ref(&world)
    edits:history.Edits;defer history.edits_free(&edits)
    selection:history.Selection;defer delete(selection.entities)
    assets:host.Assets
    app:=host.App{allocator=context.allocator,assets=&assets}
    session:=editor.Session{app=&app,info=ref.info,edit_world=&world,selection=&selection,edits=&edits,id_state=42}
    owner:=editor.entity_create(&session,{name="Terrain"})
    core.add(&world.terrains,owner,{source={1,2},revision=1})
    core.test_world_settle(&world)
    history.edits_reset(&edits,ref)
    initial:=history.edits_state(&edits)
    core.edit(&world.terrains,owner).revision=7
    tool:Terrain_Tool;defer terrain_tool_free(&tool)
    terrain_sync(&session,&tool,core.read(&world.terrains),app.assets)
    testing.expect_value(t,history.edits_state(&edits),initial)
    testing.expect_value(t,len(edits.steps),0)
    history.edits_begin(&edits,&selection,"Sculpt")
    core.edit(&world.terrains,owner).revision=8
    testing.expect(t,!history.edits_sync_initial(&edits,ref))
    history.edits_end(&edits)
    testing.expect(t,history.edits_commit(&edits,ref,&selection))
    testing.expect(t,history.undo(&edits,ref,&selection))
    testing.expect_value(t,core.at(&world.terrains,core.row_of(&world.terrains,owner)).revision,u32(7))
    testing.expect(t,!history.edits_sync_initial(&edits,ref))
    testing.expect(t,history.redo(&edits,ref,&selection))
    testing.expect_value(t,core.at(&world.terrains,core.row_of(&world.terrains,owner)).revision,u32(8))
    testing.expect(t,!history.edits_sync_initial(nil,{}))
}
