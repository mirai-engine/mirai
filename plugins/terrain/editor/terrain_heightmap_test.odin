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
heights_and_weightmaps_go_out_and_come_back_in_each_format :: proc(t:^testing.T) {
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
    if !testing.expect(t,terrain.source_make(&source,.Heightfield,{9,1,9},1,4)) {return}
    if !testing.expect(t,terrain.grid_prepare(&source.field,{},{8,0,8},source.allocator)) {return}
    for z in 0..<9 {for x in 0..<9 {terrain.grid_set(&source.field,x,z,f32(x*x)*0.731-f32(z)*1.3+500.25)}}
    testing.expect(t,terrain.source_layer_set(&source,1,terrain.LAYER_DEFAULT))
    testing.expect(t,terrain.source_edit(&source,{kind=.Paint,center={},radius=3,amount=0.7,layer=1}).changed)
    id:=base.Asset_Id{93,94};source.revision=1
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
    if !prepare(t,&s,&tool,&world,owner) {return}
    before:terrain.Source;defer terrain.source_destroy(&before)
    if !testing.expect(t,terrain.source_clone(&before,&tool.stroke.source)) {return}

    // Each format back into a flat ground: R32 as it was, the others within a step of 16 bits.
    cases:=[3]struct {file:string,worst:f32}{{"ground.r32",0},{"ground.r16",0.5*70/65535+1e-4},{"ground.png",0.5*70/65535+1e-4}}
    for entry in cases {
        file:=fmt.tprintf("%s/%s",root,entry.file)
        if !testing.expect(t,heightmap_export(&s,&tool,file)) {continue}
        flat:=terrain.Brush{kind=.Flatten,center={},radius=100,amount=1,target=0}
        if !prepare(t,&s,&tool,&world,owner) {return}
        testing.expect(t,stroke_baseline(&tool))
        testing.expect(t,terrain.source_edit(&tool.stroke.source,flat).changed)
        tool.stroke.changed,tool.stroke.dirty_all=true,true
        stroke_end(&s,&tool,ref,app.assets,label="Flatten")
        if !prepare(t,&s,&tool,&world,owner) {return}
        if !testing.expect(t,heightmap_import(&s,&tool,ref,app.assets,file)) {continue}
        if !prepare(t,&s,&tool,&world,owner) {return}
        worst:=f32(0)
        for z in 0..<9 {for x in 0..<9 {worst=max(worst,abs(terrain.grid_get(&tool.stroke.source.field,x,z)-terrain.grid_get(&before.field,x,z)))}}
        testing.expectf(t,worst<=entry.worst,"%s gives the heights back within %v, not %v",entry.file,entry.worst,worst)
    }

    // The weight of a layer goes out and back after it is erased.
    file:=fmt.tprintf("%s/layer.png",root)
    testing.expect(t,weightmap_export(&s,&tool,file,1))
    if !prepare(t,&s,&tool,&world,owner) {return}
    testing.expect(t,stroke_baseline(&tool))
    testing.expect(t,terrain.source_edit(&tool.stroke.source,{kind=.Erase,center={},radius=100,amount=1,layer=1}).changed)
    tool.stroke.changed,tool.stroke.dirty_all=true,true
    stroke_end(&s,&tool,ref,app.assets,label="Erase")
    if !prepare(t,&s,&tool,&world,owner) {return}
    testing.expect(t,weightmap_import(&s,&tool,ref,app.assets,file,1))
    if !prepare(t,&s,&tool,&world,owner) {return}
    for z in 0..<9 {for x in 0..<9 {
        got,want:=terrain.grid_get(&tool.stroke.source.weights,x,z),terrain.grid_get(&before.weights,x,z)
        g,w:=terrain.weights_float(got),terrain.weights_float(want)
        testing.expectf(t,abs(g[1]-w[1])<=1.5/terrain.WEIGHT_FULL && abs(g[0]+g[1]+g[2]-1)<1e-5,"weight %v at %d,%d, not %v",got,x,z,want)
    }}
    // A weightmap of another size, or a file of an unknown kind, changes nothing.
    testing.expect(t,!weightmap_import(&s,&tool,ref,app.assets,fmt.tprintf("%s/ground.txt",root),1))
}
