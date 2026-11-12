package terrain

import "base:runtime"
import "mirai:core"
import "mirai:std/base"
import camera "mirai:engine/camera"
import render "mirai:engine/render"
import scene "mirai:engine/scene"
import "mirai:host"
import phys "plugins:physics/runtime"

// The tables and the storages of a World that terrain_update runs on, after
// those of physics, which its chunks collide in. The test world of a library
// that uses terrain holds them after its header with
// `using terrain:terrain.Test_Terrain` and steps with terrain.test_step.
// The Terrain_Resident of the world is of its application: the test holds it.
Test_Terrain :: struct {
    using physics:phys.Test_Physics,
    ids:core.Table(core.Id),
    terrains:core.Table(Terrain),
    chunks:core.Table(Terrain_Chunk),
    looks:core.Table(render.Material_Values),
    streaming:scene.Streaming_Sources,
    data:Terrain_Data,
    terrain_requests:Terrain_Requests,
    digs:Terrain_Digs,
    ground_queries:core.Ground_Queries,
    terrain_ground:Terrain_Ground,
}

// What test_step runs with unless told: every chunk at level 0, so that a
// count of builds does not follow the levels an edit changes.
TERRAIN_TEST_SETTINGS :: Terrain_Settings{lod_distance=-1}

// terrain_update alone, on the rows as they are and as the loop calls it: in
// a fixed tick of a world that plays, unless told. commands are those of the
// world that holds the tables.
test_step :: proc(g:^Test_Terrain,commands:core.Commands,resident:^Terrain_Resident,app:^host.App,problems:^core.Problems,settings:=TERRAIN_TEST_SETTINGS,time:=core.Time{playing=true},frame:=core.Frame_Time{phase=.Fixed},view:=core.View{},locals:=core.Ref(camera.Camera_Views){}) {
    terrain_update(
        commands,&g.terrains,&g.chunks,core.read(&g.transforms),core.read(&g.parents),core.read(&g.ids),&g.colliders,
        &g.statics,&g.looks,&g.data,resident,&g.terrain_requests,&g.digs,settings,app,time,frame,
        view,locals,core.read(&g.worlds),core.ref(&g.streaming),{},g.settings,{},nil,problems,{},&g.ground_queries,&g.terrain_ground,
    )
}

// The chunks that show the table of the layers of Terrain_Layers over their material.
@(private)
layered_chunks :: proc(g:^Test_Terrain) -> (count:int) {
    for &look in g.looks.values[:core.count(&g.looks)] {
        if table,has:=render.material_texture_of(&look,0,base.name_hash("layers"));has && table!={} {count+=1}
    }
    return
}

// An allocator that serves remaining allocations of owner and then fails; below 0, all.
@(private)
Failing_Allocator :: struct {owner:runtime.Allocator,remaining:int}

@(private)
failing_allocator :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
    state:=(^Failing_Allocator)(data)
    if mode==.Alloc || mode==.Alloc_Non_Zeroed || mode==.Resize || mode==.Resize_Non_Zeroed {
        if state.remaining==0 {return nil,.Out_Of_Memory}
        state.remaining-=1
    }
    return state.owner.procedure(state.owner.data,mode,size,alignment,old_memory,old_size,loc)
}
