package foliage_terrain

import "core:math"
import "core:mem"
import "core:testing"
import "mirai:core"
import scene "mirai:engine/scene"
import foliage "plugins:foliage/runtime"
import terrain "plugins:terrain/runtime"

@(private="file")
Bridge_World :: struct {
    using world:core.Test_World,
    using land:terrain.Test_Terrain,
    foliages:core.Table(foliage.Foliage),
    foliage_data:foliage.Foliage_Data,
    ground:foliage.Foliage_Ground,
    ground_requests:foliage.Foliage_Ground_Requests,
    bridge:Foliage_Terrain,
}

@(private="file")
bridge_types :: proc(types:^[dynamic]core.Test_Type) {
    foliage.test_types(types)
    terrain.test_types(types)
}

// A heightfield of 64 m centered on its entity and a Foliage over it, with
// two cells on the terrain and one far from it. No streaming source: every
// tile is fine.
@(private="file")
Bridge_Test :: struct {
    using w:Bridge_World,
    plant:core.Entity,
}

@(private="file")
bridge_init :: proc(t:^testing.T,b:^Bridge_Test) -> bool {
    if !core.test_world_init(t,&b.w,bridge_types) {return false}
    s:terrain.Source
    if !testing.expect(t,terrain.source_make(&s,.Heightfield,{65,1,65},1,16)) {return false}
    hill:=core.create(&b.entities)
    b.plant=core.create(&b.entities)
    identity:=core.World_Transform{transform={rotation=1,scale={1,1,1}}}
    core.add(&b.terrains,hill,terrain.Terrain{source={3,3}})
    core.add(&b.worlds,hill,identity)
    core.add(&b.foliages,b.plant,foliage.Foliage{source={4,4}})
    core.add(&b.worlds,b.plant,identity)
    core.test_world_settle(&b.w)
    entry:=terrain.Data_Source{id={3,3},source=s}
    n:=terrain.chunk_counts(&entry.source)
    entry.versions=make([]u32,n.x*n.y*n.z)
    for &v in entry.versions {v=1}
    append(&b.data.entries,entry)
    plants:foliage.Source
    foliage.source_cell(&plants,{0,0},true).generate=true
    foliage.source_cell(&plants,{-1,-1},true).generate=true
    foliage.source_cell(&plants,{10,10},true).generate=true
    append(&b.foliage_data.entries,foliage.Data_Entry{id={4,4},epoch=1,loads=1,source=plants})
    b.foliage_data.made=1
    return true
}

@(private="file")
bridge_destroy :: proc(b:^Bridge_Test) {core.test_world_destroy(&b.w)}

@(private="file")
bridge_step :: proc(b:^Bridge_Test) {
    foliage_terrain_ground(&b.bridge,&b.ground,&b.ground_requests,core.ref(&b.foliage_data),core.read(&b.foliages),core.read(&b.terrains),core.ref(&b.data),core.read(&b.worlds),core.ref(&b.streaming),nil,{},nil)
}

@(private="file")
tile_revision :: proc(owner:^foliage.Ground_Owner,coord:[2]i32) -> u32 {
    at:=foliage.ground_tile_find(owner,coord)
    return at<0?0:owner.tiles[at].revision
}

@(test)
the_ground_of_foliage_follows_the_chunks_of_the_terrain_that_change :: proc(t:^testing.T) {
    track:mem.Tracking_Allocator
    mem.tracking_allocator_init(&track,context.allocator)
    defer mem.tracking_allocator_destroy(&track)
    track.bad_free_callback=mem.tracking_allocator_bad_free_callback_add_to_array
    context.allocator=mem.tracking_allocator(&track)
    b:Bridge_Test
    defer {
        bridge_destroy(&b)
        testing.expect_value(t,len(track.bad_free_array),0)
    }
    if !bridge_init(t,&b) {return}
    s:=&b.data.entries[0].source
    testing.expect(t,terrain.source_edit(s,{kind=.Raise,center={-16,0,-16},radius=4,amount=2}).changed)
    bridge_step(&b)
    owner:=foliage.ground_owner(&b.ground,b.plant)
    if !testing.expect(t,owner!=nil) {return}
    testing.expect_value(t,owner.samples,u32(33))
    testing.expect(t,foliage.ground_tile_find(owner,{0,0})>=0 && foliage.ground_tile_find(owner,{-1,-1})>=0)
    testing.expect_value(t,foliage.ground_tile_find(owner,{10,10}),-1)
    tile,_:=foliage.ground_cell(owner,{-1,-1})
    h,_,ok:=foliage.ground_at(tile,16,16)
    testing.expect(t,ok && abs(h-terrain.source_height(s,-16,-16))<1e-3,"the height of the terrain under the cell")
    // A stable step writes nothing.
    revision:=owner.revision
    bridge_step(&b)
    testing.expect_value(t,owner.revision,revision)
    // An edit of a chunk under cell (0,0) reads that tile again, and not the other.
    before:=tile_revision(owner,{-1,-1})
    change:=terrain.source_edit(s,{kind=.Raise,center={20,0,20},radius=3,amount=1.5})
    testing.expect(t,change.changed)
    low,high:=terrain.chunk_range(s,change)
    for z in low.z..=high.z {for x in low.x..=high.x {b.data.entries[0].versions[terrain.chunk_index(s,{i32(x),0,i32(z)})]+=1}}
    b.data.entries[0].change+=1
    bridge_step(&b)
    testing.expect(t,tile_revision(owner,{0,0})>revision,"the tile over the edit")
    testing.expect_value(t,tile_revision(owner,{-1,-1}),before)
    tile,_=foliage.ground_cell(owner,{0,0})
    h,_,ok=foliage.ground_at(tile,20,20)
    testing.expect(t,ok && abs(h-terrain.source_height(s,20,20))<1e-3 && h>0.5)
    // A cell asked for gets its tile; one off every terrain does not.
    foliage.ground_request(&b.ground_requests,b.plant,{-1,0})
    foliage.ground_request(&b.ground_requests,b.plant,{20,0})
    bridge_step(&b)
    testing.expect(t,foliage.ground_tile_find(owner,{-1,0})>=0)
    testing.expect_value(t,foliage.ground_tile_find(owner,{20,0}),-1)
    // The terrain moves away: its tiles go.
    world:=core.edit(&b.worlds,core.entity_at(core.read(&b.terrains),0))
    world.transform.position={1000,0,0}
    b.worlds.version+=1
    bridge_step(&b)
    testing.expect_value(t,len(owner.tiles),0)
    // It comes back: the cells it covers have their tiles again.
    world.transform.position={}
    b.worlds.version+=1
    bridge_step(&b)
    testing.expect(t,foliage.ground_tile_find(owner,{0,0})>=0 && foliage.ground_tile_find(owner,{-1,-1})>=0,"the cells under a terrain that comes")
    testing.expect_value(t,foliage.ground_tile_find(owner,{10,10}),-1)
}

@(test)
the_ground_of_foliage_carries_the_layers_the_terrain_shows_painted_and_by_their_rules :: proc(t:^testing.T) {
    b:Bridge_Test
    defer bridge_destroy(&b)
    if !bridge_init(t,&b) {return}
    s:=&b.data.entries[0].source
    testing.expect(t,terrain.source_edit(s,{kind=.Raise,center={-16,0,-16},radius=4,amount=2}).changed)
    // A new terrain shows its one layer everywhere.
    bridge_step(&b)
    owner:=foliage.ground_owner(&b.ground,b.plant)
    if !testing.expect(t,owner!=nil && len(owner.tiles)>0) {return}
    for pool in owner.pools {
        testing.expect_value(t,len(pool.weights),len(pool.heights))
        for w in pool.weights {testing.expect_value(t,w,[4]u8{255,0,0,0})}
    }
    tile,_:=foliage.ground_cell(owner,{-1,-1})
    first,known:=foliage.ground_weights_at(tile,16,16)
    testing.expect(t,known && first==[4]f32{1,0,0,0})
    // Layer 1 covers from 0.5 m up, layer 2 is painted around (20, 20).
    high:=terrain.LAYER_DEFAULT
    high.auto={enabled=true,slope={0,math.PI/2},height={0.5,terrain.HEIGHT_LIMIT}}
    testing.expect(t,terrain.source_layer_set(s,0,terrain.LAYER_DEFAULT) && terrain.source_layer_set(s,1,high) && terrain.source_layer_set(s,2,terrain.LAYER_DEFAULT))
    for _ in 0..<4 {terrain.source_paint(s,{kind=.Paint,center={20,0,20},radius=6,amount=1,layer=2,falloff=.Constant,hardness=1})}
    testing.expect(t,terrain.source_height(s,-16,-16)>0.5)
    for &v in b.data.entries[0].versions {v+=1}
    b.data.entries[0].change+=1
    bridge_step(&b)
    tile,_=foliage.ground_cell(owner,{-1,-1})
    w,ok:=foliage.ground_weights_at(tile,16,16)
    testing.expect(t,ok && w[1]>0.99,"the automatic layer on the hill")
    w,ok=foliage.ground_weights_at(tile,2,2)
    testing.expect(t,ok && w[0]>0.99,"the first layer off it")
    tile,_=foliage.ground_cell(owner,{0,0})
    w,ok=foliage.ground_weights_at(tile,20,20)
    testing.expect(t,ok && w[2]>0.99,"the painted layer")
    for pool in owner.pools {for weights in pool.weights {testing.expect_value(t,int(weights[0])+int(weights[1])+int(weights[2])+int(weights[3]),255)}}
    // A type that stands on layer 1 alone is only on the hill.
    plants:=&b.foliage_data.entries[0].source
    grass:=foliage.source_type_add(plants,"grass",{1,1})
    grass.density=0.2
    grass.rule={enabled=true,slope={0,math.PI/2},height={-foliage.POSITION_MAX,foliage.POSITION_MAX},layers=0b10,weight=0.5}
    work:foliage.Build_Work
    defer foliage.build_work_destroy(&work)
    tile,_=foliage.ground_cell(owner,{-1,-1})
    foliage.cell_build(plants,foliage.source_cell(plants,{-1,-1}),tile,&work)
    testing.expect(t,len(work.placed)>0)
    for p in work.placed {
        testing.expect(t,abs(p.position.x+16)<5 && abs(p.position.z+16)<5 && p.position.y>0.3,"on the hill")
    }
}

@(test)
the_ground_under_a_held_stroke_of_the_editor_goes_until_the_stroke_ends :: proc(t:^testing.T) {
    b:Bridge_Test
    defer bridge_destroy(&b)
    if !bridge_init(t,&b) {return}
    bridge_step(&b)
    owner:=foliage.ground_owner(&b.ground,b.plant)
    if !testing.expect(t,owner!=nil && foliage.ground_tile_find(owner,{0,0})>=0) {return}
    // A stroke held over cell (0,0): its tile has no ground, the other keeps it.
    focus:=terrain.Terrain_Focus{source={3,3},radius=4,center={10,0,10},stroke=true,low={6,6},high={14,14}}
    foliage_terrain_ground(&b.bridge,&b.ground,&b.ground_requests,core.ref(&b.foliage_data),core.read(&b.foliages),core.read(&b.terrains),core.ref(&b.data),core.read(&b.worlds),core.ref(&b.streaming),nil,focus,nil)
    tile,_:=foliage.ground_cell(owner,{0,0})
    _,_,ok:=foliage.ground_at(tile,10,10)
    testing.expect(t,!ok,"no ground under the stroke")
    other,_:=foliage.ground_cell(owner,{-1,-1})
    _,_,other_ok:=foliage.ground_at(other,16,16)
    testing.expect(t,other_ok)
    // The stroke ends: the tile is read again.
    bridge_step(&b)
    bridge_step(&b)
    tile,_=foliage.ground_cell(owner,{0,0})
    _,_,ok=foliage.ground_at(tile,10,10)
    testing.expect(t,ok,"the ground is back")
}

// Far from the sources, past the reach of the meshes of its types, a tile
// is coarse, from the coarse grid of the terrain; near them, or where the
// editor asks, it is fine.
@(test)
the_ground_far_from_the_sources_is_coarse_and_fine_near_them :: proc(t:^testing.T) {
    b:Bridge_Test
    defer bridge_destroy(&b)
    if !bridge_init(t,&b) {return}
    s:=&b.data.entries[0].source
    testing.expect(t,terrain.source_edit(s,{kind=.Raise,center={-13,0,-16},radius=4,amount=2}).changed)
    grass:=foliage.source_type_add(&b.foliage_data.entries[0].source,"grass",{1,1})
    grass.fade_distance,grass.cull_distance=10,20
    far:=[3]f32{-1000,0,-1000}
    b.streaming.items[0]={position=far,ahead=far}
    b.streaming.count,b.streaming.revision=1,1
    bridge_step(&b)
    owner:=foliage.ground_owner(&b.ground,b.plant)
    if !testing.expect(t,owner!=nil) {return}
    testing.expect_value(t,foliage.ground_tile_samples(owner,{-1,-1}),u32(COARSE_SAMPLES))
    testing.expect_value(t,foliage.ground_tile_samples(owner,{0,0}),u32(COARSE_SAMPLES))
    tile,_:=foliage.ground_cell(owner,{-1,-1})
    h,_,ok:=foliage.ground_at(tile,12,16)
    coarse,_,_,known:=terrain.source_coarse_at(s,-20,-16)
    testing.expect(t,ok && known && abs(h-coarse)<1e-3,"the coarse grid of the terrain")
    testing.expect(t,abs(coarse-terrain.source_height(s,-20,-16))>1e-2,"which is not its samples there")
    // The editor asks for a cell: it is fine.
    foliage.ground_request(&b.ground_requests,b.plant,{0,0})
    bridge_step(&b)
    testing.expect_value(t,foliage.ground_tile_samples(owner,{0,0}),owner.samples)
    // A source comes: the tiles near it are fine.
    b.streaming.items[0]={}
    b.streaming.revision=2
    bridge_step(&b)
    testing.expect_value(t,foliage.ground_tile_samples(owner,{-1,-1}),owner.samples)
    tile,_=foliage.ground_cell(owner,{-1,-1})
    h,_,ok=foliage.ground_at(tile,16,16)
    testing.expect(t,ok && abs(h-terrain.source_height(s,-16,-16))<1e-3,"the samples of the terrain")
    // It goes far again: they are coarse, and a stable step writes nothing.
    b.streaming.items[0]={position=far,ahead=far}
    b.streaming.revision=3
    bridge_step(&b)
    testing.expect_value(t,foliage.ground_tile_samples(owner,{-1,-1}),u32(COARSE_SAMPLES))
    testing.expect_value(t,foliage.ground_tile_samples(owner,{0,0}),u32(COARSE_SAMPLES))
    revision:=owner.revision
    bridge_step(&b)
    testing.expect_value(t,owner.revision,revision)
}

// An allocator that serves `remaining` requests of its owner and refuses the rest.
@(private="file")
Memory_Limit :: struct {owner:mem.Allocator,remaining,refused:int}

@(private="file")
memory_limit_proc :: proc(data:rawptr,mode:mem.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,mem.Allocator_Error) {
    limit:=(^Memory_Limit)(data)
    if mode==.Alloc || mode==.Alloc_Non_Zeroed || mode==.Resize || mode==.Resize_Non_Zeroed {
        if limit.remaining<=0 {limit.refused+=1;return nil,.Out_Of_Memory}
        limit.remaining-=1
    }
    return limit.owner.procedure(limit.owner.data,mode,size,alignment,old_memory,old_size,loc)
}

// The first step of a world with a terrain under a foliage, with the memory
// ending at each request in turn: it ends, and what it could not remember of
// the chunks of the terrain is a problem; with memory enough it reports none.
@(test)
a_step_without_memory_ends_and_reports_the_chunks_it_could_not_remember :: proc(t:^testing.T) {
    owner:=context.allocator
    limit:=Memory_Limit{owner=owner}
    whole,forgot:=false,false
    for served in 0..<256 {
        b:Bridge_Test
        if !bridge_init(t,&b) {return}
        // As after its terrain loads: the chunks of its source are seen for the first time.
        b.data.epoch=1
        problems:core.Problems
        limit.remaining,limit.refused=served,0
        context.allocator={memory_limit_proc,&limit}
        foliage_terrain_ground(&b.bridge,&b.ground,&b.ground_requests,core.ref(&b.foliage_data),core.read(&b.foliages),core.read(&b.terrains),core.ref(&b.data),core.read(&b.worlds),core.ref(&b.streaming),nil,{},&problems)
        context.allocator=owner
        limit.remaining=max(int)
        whole=limit.refused==0
        forgot||=problems.count>0
        if whole {testing.expectf(t,problems.count==0 && len(b.bridge.sources)==1 && len(b.bridge.sources[0].versions)==len(b.data.entries[0].versions),"with %d requests served: %d problems, %d sources seen",served,problems.count,len(b.bridge.sources))}
        bridge_destroy(&b)
        if whole {break}
    }
    testing.expect(t,whole && forgot,"a problem without memory, and none with it")
}
