package navigation_terrain

import "core:testing"
import "mirai:core"
import nav "plugins:navigation/runtime"
import phys "plugins:physics/runtime"
import terrain "plugins:terrain/runtime"

@(private="file")
Chunks_World :: struct {
    using world:core.Test_World,
    using terrain:terrain.Test_Terrain,
}

// A heightfield of 4 by 4 chunks of 16 m: the first row has its colliders
// but for one chunk, the second shows one chunk empty, the rest is not loaded.
@(test)
the_chunks_of_a_terrain_without_collider_are_unloaded_for_navigation :: proc(t:^testing.T) {
    w:Chunks_World
    if !core.test_world_init(t,&w,terrain.test_types) {return}
    defer core.test_world_destroy(&w)
    entry:=terrain.Data_Source{id={3,3}}
    testing.expect(t,terrain.source_make(&entry.source,.Heightfield,{65,1,65},1,16))
    append(&w.data.entries,entry)
    hill:=core.create(&w.entities)
    core.add(&w.terrains,hill,terrain.Terrain{source={3,3},solid=true})
    core.add(&w.worlds,hill,core.World_Transform{transform={rotation=1,scale={1,1,1}}})
    resident:terrain.Terrain_Resident
    shown:=make([]terrain.Resident_Chunk,16);defer delete(shown)
    chunks:=make([]core.Entity,16);defer delete(chunks)
    append(&resident.sources,terrain.Resident_Source{id={3,3},owner=hill,chunks=shown})
    append(&resident.owners,terrain.Resident_Owner{entity=hill,source={3,3},chunks=chunks,solid=true})
    defer {delete(resident.sources);delete(resident.owners)}
    for x in 0..<4 {
        if x==2 {continue}
        chunks[x]=core.create(&w.entities)
        core.add(&w.colliders,chunks[x],phys.Collider{kind=.Heightfield})
        shown[x].shown=true
    }
    shown[5].shown=true
    core.test_world_settle(&w)
    state:Navigation_Terrain
    unloaded:nav.Nav_Unloaded
    defer nav.nav_unloaded_free(&unloaded)
    step :: proc(state:^Navigation_Terrain,unloaded:^nav.Nav_Unloaded,resident:^terrain.Terrain_Resident,w:^Chunks_World) {
        navigation_terrain_unloaded(state,unloaded,core.ref(resident),core.ref(&w.data),core.read(&w.terrains),core.read(&w.colliders),core.read(&w.worlds))
    }
    step(&state,&unloaded,&resident,&w)
    // Row 0: chunk 2. Row 1: chunk 4, and 6 to 7. Rows 2 and 3: one run each.
    testing.expect_value(t,len(unloaded.boxes),5)
    revision:=unloaded.revision
    testing.expect(t,revision>0)
    for box in unloaded.boxes {
        testing.expect(t,box.min.y<=-1e3 && box.max.y>=1e3)
        // The loaded chunks, from -32 to -16 m and -16 to 0 m along x on the first row, are left out.
        testing.expect(t,!(box.max.z<=-16 && box.min.x< -16+1e-3 && box.max.x> -32+1e-3 && box.max.x<= -16+1e-3))
    }
    step(&state,&unloaded,&resident,&w)
    testing.expect_value(t,unloaded.revision,revision)
    // Chunk 2 loads: one box fewer.
    chunks[2]=core.create(&w.entities)
    core.add(&w.colliders,chunks[2],phys.Collider{kind=.Heightfield})
    core.test_world_settle(&w)
    step(&state,&unloaded,&resident,&w)
    testing.expect_value(t,len(unloaded.boxes),4)
    testing.expect(t,unloaded.revision>revision)
}
