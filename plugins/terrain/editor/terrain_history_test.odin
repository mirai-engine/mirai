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

@(test)
a_stroke_keeps_the_pages_it_changed_and_undo_and_redo_trade_them :: proc(t:^testing.T) {
    directory,_:=os.temp_directory(context.temp_allocator)
    root:=fmt.tprintf("%s/mirai-terrain-history-%d",directory,os.get_pid())
    path:=fmt.tprintf("%s/wide.terrain",root)
    relative:="wide.terrain"
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
    // 257 samples on a side: 25 pages of heights, a stroke in one of them.
    source:terrain.Source;defer terrain.source_destroy(&source)
    if !testing.expect(t,terrain.source_make(&source,.Heightfield,{257,1,257},1,32)) {return}
    for x in 0..<257 {for z in 0..<257 {terrain.grid_put(&source.heights,{x,0,z},f32((x*7+z*3)%11)*0.125,source.allocator)}}
    id:=base.Asset_Id{91,92};source.revision=1
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

    stroke :: proc(t:^testing.T,s:^editor.Session,tool:^Terrain_Tool,ref:core.World_Ref,world:^Create_Test_World,worlds:^core.Table(core.World_Transform),owner:core.Entity,brush:terrain.Brush) {
        terrain_sync(s,tool,core.read(&world.terrains),s.app.assets)
        if !testing.expect(t,stroke_prepare(tool,s.app.assets,s.app.allocator,core.read(&world.terrains),core.read(worlds),editor.Pick{entity=owner})) {return}
        if !testing.expect(t,stroke_baseline(tool)) {return}
        tool.stroke.active=true
        change:=terrain.source_edit(&tool.stroke.source,brush)
        testing.expect(t,change.changed && change.error==.None)
        stroke_changed(&tool.stroke,change)
        stroke_end(s,tool,ref,s.app.assets)
        testing.expect(t,editor.edits_commit(s.edits,ref,s.selection))
    }
    stroke(t,&s,&tool,ref,&world,&worlds,owner,{kind=.Raise,center={-100,0,-100},radius=3,amount=2})
    first:=test_held(t,&assets,relative);defer delete(first)
    stroke(t,&s,&tool,ref,&world,&worlds,owner,{kind=.Lower,center={90,0,90},radius=3,amount=1})
    second:=test_held(t,&assets,relative);defer delete(second)
    if !testing.expect_value(t,len(tool.steps),2) {return}
    for &step in tool.steps {
        testing.expect(t,!step.whole && !step.heights.whole && len(step.heights.pages)==1,"a stroke keeps the one page it changed")
    }
    // Undo twice and redo twice put back the bytes of each revision.
    walk :: proc(t:^testing.T,s:^editor.Session,tool:^Terrain_Tool,world:^Create_Test_World,app:^host.App,undo:bool) {
        if undo {testing.expect(t,editor.undo(s.edits,editor.edited_world(s),s.selection))} else {testing.expect(t,editor.redo(s.edits,editor.edited_world(s),s.selection))}
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
    stroke(t,&s,&tool,ref,&world,&worlds,owner,{kind=.Raise,center={0,0,0},radius=3,amount=1})
    testing.expect_value(t,len(tool.steps),2)
    testing.expect(t,editor.revision_find(&tool.history,id,2,3)>=0 && editor.revision_find(&tool.history,id,1,2)>=0)
}

@(test)
a_change_of_kind_keeps_the_whole_source_once :: proc(t:^testing.T) {
    head,edited:terrain.Source
    defer terrain.source_destroy(&head);defer terrain.source_destroy(&edited)
    testing.expect(t,terrain.source_make(&head,.Heightfield,{9,1,9},1,4))
    testing.expect(t,terrain.source_make(&edited,.Heightfield,{9,1,9},1,4))
    testing.expect(t,terrain.source_convert_heightfield(&edited,&edited,0))
    step:=Step{source={1,1},from=1,to=2}
    defer step_destroy(&step)
    testing.expect(t,step_make(&step,&head,&edited,{},{},false))
    testing.expect(t,step.whole && step.other.kind==.Heightfield && head.kind==.Mesh)
    step_apply(&step,&head)
    testing.expect(t,head.kind==.Heightfield && step.other.kind==.Mesh,"undo trades the whole source back")
}
