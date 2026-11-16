package terrain_editor

import "core:fmt"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/history"
import volume "mirai:engine/volume"
import "mirai:host"
import terrain "plugins:terrain/runtime"
import "mirai:std/base"

@(test)
strokes_on_an_edit_layer_and_a_conformed_spline_are_steps_of_undo :: proc(t:^testing.T) {
    root:=base.test_folder(t,"terrain")
    path:=fmt.tprintf("%s/ground.terrain",root)
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=root,capacity=8})) {return}
    defer host.assets_destroy(&assets)
    world:Create_Test_World
    if !test_world_init(t,&world) {return}
    defer test_world_destroy(&world)
    ref:=test_world_ref(&world)
    source:terrain.Source;defer terrain.source_destroy(&source)
    if !testing.expect(t,terrain.source_make(&source,.Heightfield,{33,1,33},1,16)) {return}
    id:=base.Asset_Id{95,96};source.revision=1
    testing.expect_value(t,terrain.source_save(&source,path,id,&assets.types),asset.Error.None)
    host.assets_scan(&assets)
    owner:=core.create(&world.entities)
    core.add(&world.ids,owner,core.Id{value=base.Entity_Id(100+u64(owner))})
    core.add(&world.transforms,owner,core.TRANSFORM_IDENTITY)
    core.add(&world.terrains,owner,terrain.Terrain{source=id,revision=1})
    core.add(&world.worlds,owner,core.World_Transform{transform={rotation=1,scale={1,1,1}}})
    core.world_settle(ref)
    selection:history.Selection;defer delete(selection.entities)
    edits:history.Edits;defer history.edits_free(&edits)
    history.edits_reset(&edits,ref)
    app:=host.App{allocator=context.allocator,assets=&assets}
    s:=editor.Session{app=&app,info=ref.info,edit_world=&world,assets_root=root,headless=true,selection=&selection,edits=&edits}
    tool:Terrain_Tool;tool_ready(&tool);defer terrain_tool_free(&tool)
    test_world_settle(&world)
    prepare :: proc(t:^testing.T,s:^editor.Session,tool:^Terrain_Tool,world:^Create_Test_World,owner:core.Entity) -> bool {
        terrain_sync(s,tool,core.read(&world.terrains),s.app.assets)
        return testing.expect(t,stroke_prepare(tool,s.app.assets,s.app.allocator,&world.terrains,&world.worlds,editor.Pick{entity=owner}))
    }
    held :: proc(t:^testing.T,a:^host.Assets,id:base.Asset_Id,x,z:int) -> (height:f32,layers:u32) {
        s:terrain.Source;defer terrain.source_destroy(&s)
        testing.expect(t,terrain.terrain_read(&s,a,id))
        return terrain.grid_get(&s.field,x,z),s.edit_count
    }
    undo :: proc(t:^testing.T,s:^editor.Session,tool:^Terrain_Tool,world:^Create_Test_World,redo:=false) {
        ref:=test_world_ref(world)
        testing.expect(t,redo?history.redo(s.edits,ref,s.selection):history.undo(s.edits,ref,s.selection))
        terrain_sync(s,tool,core.read(&world.terrains),s.app.assets)
    }

    // A layer, and a stroke on it: the ground takes it and the layer keeps it apart.
    if !prepare(t,&s,&tool,&world,owner) {return}
    at,added:=edit_layer_commit(&s,&tool,ref,app.assets,0,true,false,false)
    testing.expect(t,added && at==0)
    testing.expect(t,history.edits_commit(&edits,ref,&selection))
    tool.edit_layer=1
    if !prepare(t,&s,&tool,&world,owner) {return}
    testing.expect(t,stroke_baseline(&tool))
    tool.stroke.active=true
    change:=terrain.source_edit(&tool.stroke.source,{kind=.Raise,center={},radius=4,amount=3,falloff=.Constant})
    stroke_changed(&tool.stroke,change)
    tool.stroke.changed=true
    stroke_end(&s,&tool,ref,app.assets,layered=true)
    testing.expect(t,history.edits_commit(&edits,ref,&selection))
    height,layers:=held(t,&assets,id,16,16)
    testing.expect(t,height==3 && layers==1)
    // Hidden, the ground is as before it; undo shows it again.
    if !prepare(t,&s,&tool,&world,owner) {return}
    _,hid:=edit_layer_commit(&s,&tool,ref,app.assets,0,false,false,true)
    testing.expect(t,hid)
    testing.expect(t,history.edits_commit(&edits,ref,&selection))
    height,_=held(t,&assets,id,16,16);testing.expect_value(t,height,f32(0))
    undo(t,&s,&tool,&world)
    height,_=held(t,&assets,id,16,16);testing.expect_value(t,height,f32(3))

    // A road made in a gesture: its bed is cut a metre into the raised ground,
    // in the step of that gesture, which takes both back.
    gesture :: proc(t:^testing.T,s:^editor.Session,tool:^Terrain_Tool,world:^Create_Test_World,label:string,change:proc(world:^Create_Test_World,road:core.Entity),road:core.Entity) {
        ref:=test_world_ref(world)
        testing.expect(t,history.edits_begin(s.edits,s.selection,label))
        change(world,road)
        core.world_settle(ref)
        test_world_settle(world)
        terrain_splines_follow(s,tool,ref,s.app.assets)
        history.edits_end(s.edits)
        testing.expect(t,history.edits_commit(s.edits,ref,s.selection))
    }
    road:=core.create(&world.entities)
    tool.edit_layer=0
    steps:=edits.cursor
    gesture(t,&s,&tool,&world,"Road",proc(world:^Create_Test_World,road:core.Entity) {
        core.add(&world.transforms,road,core.TRANSFORM_IDENTITY)
        core.add(&world.worlds,road,core.World_Transform{transform={rotation=1,scale={1,1,1}}})
        core.add(&world.splines,road,volume.Spline{count=2,points={0={position={0,0,-16},width=2},1={position={0,0,16},width=2}}})
        core.add(&world.conforms,road,terrain.Terrain_Conform{depth=1,sides=1,smooth=0})
    },road)
    testing.expect_value(t,edits.cursor,steps+1)
    height,layers=held(t,&assets,id,16,16)
    testing.expect(t,abs(height-2)<1e-3 && layers==2,"the bed lies a metre under the raised ground, in a layer of its own")
    height,_=held(t,&assets,id,16,0);testing.expect(t,abs(height-(-1))<1e-3)
    // Moved, it follows; undo puts the road and its bed back where they were.
    gesture(t,&s,&tool,&world,"Move road",proc(world:^Create_Test_World,road:core.Entity) {
        core.edit(&world.worlds,road).transform.position.x=8
        core.edit(&world.transforms,road).position.x=8
    },road)
    height,_=held(t,&assets,id,16,0);testing.expect(t,abs(height)<1e-3,"the old bed is gone")
    height,_=held(t,&assets,id,24,0);testing.expect(t,abs(height-(-1))<1e-3)
    undo(t,&s,&tool,&world)
    height,_=held(t,&assets,id,16,0);testing.expect(t,abs(height-(-1))<1e-3)
    height,_=held(t,&assets,id,24,0);testing.expect(t,abs(height)<1e-3)
    // Without its road the layer of splines goes.
    gesture(t,&s,&tool,&world,"Delete road",proc(world:^Create_Test_World,road:core.Entity) {core.remove(&world.conforms,road)},road)
    height,layers=held(t,&assets,id,16,16)
    testing.expect(t,height==3 && layers==1)
    undo(t,&s,&tool,&world)
    height,layers=held(t,&assets,id,16,16)
    testing.expect(t,abs(height-2)<1e-3 && layers==2)
}
