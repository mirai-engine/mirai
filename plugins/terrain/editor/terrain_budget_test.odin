package terrain_editor

import "core:testing"
import "mirai:core"
import "mirai:editor"
import phys "plugins:physics/runtime"
import terrain "plugins:terrain/runtime"
import "mirai:std/base"

@(private="file")
Budget_World :: struct {
    using world:core.Test_World,
    terrains:core.Table(terrain.Terrain),
    data:terrain.Terrain_Data,
    settings:terrain.Terrain_Settings,
    physics:phys.Physics_State,
}

@(test)
terrain_editor_budget_counts_sources_chunks_and_replacement_without_double_charging :: proc(t:^testing.T) {
    w:Budget_World
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    // A Heightfield costs the samples of its pages that hold their own values.
    w.settings={sources=2,chunks=8,samples=13000}
    ids:=[2]base.Asset_Id{{11,12},{13,14}}
    for id in ids {
        entry:=terrain.Data_Source{id=id,versions=make([]u32,1)}
        testing.expect(t,terrain.source_make(&entry.source,.Heightfield,{5,1,5},1,4))
        testing.expect(t,terrain.source_set(&entry.source,{1,0,1},1))
        append(&w.data.entries,entry)
    }
    source:terrain.Source;defer terrain.source_destroy(&source)
    testing.expect(t,terrain.source_make(&source,.Heightfield,{9,1,9},1,4))
    testing.expect_value(t,terrain.source_cost(&source),0)
    testing.expect(t,terrain.source_set(&source,{1,0,1},1))
    // Each page holds its samples: those of its source of 5 by 5, those of 9 by 9.
    page,cost:=terrain.source_cost(&w.data.entries[0].source),terrain.source_cost(&source)
    testing.expect(t,page==25 && cost==81)
    session:editor.Session
    world:=core.test_world_ref(&w)
    testing.expect_value(t,terrain_samples_left(world,{}),13000-2*page)
    testing.expect_value(t,terrain_samples_left(world,ids[0]),13000-page)
    testing.expect(t,!terrain_budget(&session,world,&source))
    testing.expect(t,terrain_budget(&session,world,&source,ids[0]))
    w.settings.sources=3
    testing.expect(t,terrain_budget(&session,world,&source))
    w.settings.samples=u32(2*page+cost-1)
    testing.expect(t,!terrain_budget(&session,world,&source))
    testing.expect(t,terrain_budget(&session,world,&source,ids[0]))
    w.data.ready=true;w.data.settings={sources=8,chunks=64,samples=20000}
    testing.expect_value(t,terrain_samples_left(world,{}),20000-2*page)
    testing.expect(t,terrain_budget(&session,world,&source))
}

@(test)
terrain_editor_budget_leaves_chunks_and_colliders_to_the_runtime :: proc(t:^testing.T) {
    w:Budget_World
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    testing.expect(t,phys.test_state_make(&w.physics,{bodies=4,shapes=4,contacts=4,joints=1,characters=1,hulls=1,meshes=1,heightfields=16}))
    w.settings={chunks=64}
    source:terrain.Source;defer terrain.source_destroy(&source)
    testing.expect(t,terrain.source_make(&source,.Heightfield,{1025,1,1025},1,64))
    world:=core.test_world_ref(&w)
    session:editor.Session
    testing.expect(t,terrain_budget(&session,world,&source),"256 chunks show as nodes past 64 pieces, and the nearest take the 16 heightfields")
    volume:terrain.Source;defer terrain.source_destroy(&volume)
    testing.expect(t,terrain.source_make(&volume,.Volume,{65,65,65},1,8))
    testing.expect(t,terrain_budget(&session,world,&volume),"512 chunks of a Volume show as nodes past 64 pieces too")
}
