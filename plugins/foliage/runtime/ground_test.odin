package foliage

import "core:testing"
import "mirai:core"
import scene "mirai:engine/scene"
import mm "mirai:std/math"

// A ground that is the plane y = height over x and z from -32 to 32 m, with
// no surface over x and z from 4 to 8 m, as a provider of core.Ground_Queries
// gives it.
@(private)
@(test_world)
Ground_World :: struct {
    using world:Test_World,
    foliages:core.Table(Foliage),
    worlds:core.Table(core.World_Transform),
    data:Foliage_Data,
    ground:Foliage_Ground,
    requests:Foliage_Ground_Requests,
    streaming:scene.Streaming_Sources,
    queries:core.Ground_Queries,
}

@(private="file")
Ground_Test :: struct {
    using w:Ground_World,
    height:f32,
    coarse:int, // probes asked coarse
    plant:core.Entity,
    problems:core.Problems,
}

@(private="file")
ground_test_open :: proc(w:core.World_Ref) -> (core.Ground_Query,bool) {
    f:=cast(^Ground_Test)w.data
    probe :: proc(user:rawptr,origin,down:[3]f32,coarse:bool) -> (hit:core.Ground_Hit,found:core.Ground_Found) {
        f:=cast(^Ground_Test)user
        if coarse {f.coarse+=1}
        if abs(origin.x)>32 || abs(origin.z)>32 {return}
        if origin.x>4 && origin.x<8 && origin.z>4 && origin.z<8 {return {},.Empty}
        return {point={origin.x,f.height,origin.z},normal={0,1,0},weights={0,255,0,0},layers={1={7,7}}},.Ground
    }
    return {user=f,probe=probe,spacing=1},true
}

@(private="file")
ground_test_step :: proc(f:^Ground_Test) {
    foliage_ground(&f.ground,&f.requests,core.ref(&f.data),core.read(&f.foliages),core.read(&f.worlds),core.ref(&f.streaming),core.ref(&f.queries),{data=f},nil,&f.problems)
    clear(&f.queries.changed.items)
}

@(private="file")
tile_revision :: proc(owner:^Ground_Owner,coord:[2]i32) -> u32 {
    at:=ground_tile_find(owner,coord)
    return at<0?0:owner.tiles[at].revision
}

// What foliage asks of the ground and when: nothing without a provider; the
// cells of each Foliage once; again only those under a change it announces
// and those the editor asks for; coarse far from the sources.
@(test)
the_ground_of_foliage_is_read_where_the_ground_changed :: proc(t:^testing.T) {
    f:Ground_Test
    if !test_world_init(t,&f.w) {return}
    defer test_world_destroy(&f.w)
    f.plant=core.create(&f.entities)
    core.add(&f.foliages,f.plant,Foliage{source={4,4}})
    core.add(&f.worlds,f.plant,core.World_Transform{transform={rotation=1,scale={1,1,1}}})
    test_world_settle(&f.w)
    plants:Source
    source_cell(&plants,{0,0},true).generate=true
    source_cell(&plants,{-1,-1},true).generate=true
    source_cell(&plants,{10,10},true).generate=true
    append(&f.data.entries,Data_Entry{id={4,4},epoch=1,loads=1,source=plants})
    f.data.made=1
    ground_request(&f.requests,f.plant,{0,0})
    ground_test_step(&f)
    testing.expect(t,len(f.ground.owners)==0 && len(f.requests.cells.items)==0,"without a provider the plane of the entity is the ground")
    f.queries.open=ground_test_open
    f.height=2
    ground_test_step(&f)
    owner:=ground_owner(&f.ground,f.plant)
    if !testing.expect(t,owner!=nil) {return}
    testing.expect_value(t,owner.samples,u32(33))
    testing.expect_value(t,ground_tile_find(owner,{10,10}),-1)
    off,_:=ground_cell(owner,{10,10})
    testing.expect(t,off.absent && f.problems.count==1 && f.problems.entries[0].entity==f.plant,"a cell that generates off the ground has none, and says so")
    tile,_:=ground_cell(owner,{0,0})
    height,_,ok:=ground_at(tile,16,16)
    testing.expect(t,ok && height==2)
    _,_,ok=ground_at(tile,6,6)
    testing.expect(t,!ok,"no ground where it shows no surface")
    weights,_:=ground_weights_at(tile,16,16)
    testing.expect(t,weights=={0,1,0,0} && owner.layers[1]=={7,7} && owner.layer_count==1)
    // A stable call reads nothing.
    revision:=owner.revision
    ground_test_step(&f)
    testing.expect_value(t,owner.revision,revision)
    // A change over cell (0,0) reads it again, and not the other.
    other:=tile_revision(owner,{-1,-1})
    f.height=3
    core.push(&f.queries.changed,mm.Aabb{{1,-10,1},{20,10,20}})
    ground_test_step(&f)
    testing.expect(t,tile_revision(owner,{0,0})>revision && tile_revision(owner,{-1,-1})==other)
    core.push(&f.queries.changed,mm.Aabb{{-20,-10,-20},{-1,10,-1}})
    ground_test_step(&f)
    tile,_=ground_cell(owner,{-1,-1})
    height,_,_=ground_at(tile,16,16)
    testing.expect(t,height==3 && tile_revision(owner,{-1,-1})>other)
    // Far from every source a tile is coarse, until the editor asks for it.
    far:=[3]f32{-1000,0,-1000}
    f.streaming.items[0]={position=far,ahead=far}
    f.streaming.count,f.streaming.revision=1,1
    ground_test_step(&f)
    testing.expect(t,f.coarse>0 && ground_tile_samples(owner,{0,0})==COARSE_SAMPLES)
    ground_request(&f.requests,f.plant,{0,0})
    ground_test_step(&f)
    testing.expect_value(t,ground_tile_samples(owner,{0,0}),owner.samples)
    // The Foliage moves off the ground: its tiles go.
    core.edit(&f.worlds,f.plant).transform.position={1000,0,0}
    test_world_settle(&f.w)
    for _ in 0..<2 {ground_test_step(&f)}
    testing.expect_value(t,len(owner.tiles),0)
}

// The tiles to read are read once each: those the editor asks for first,
// then the nearest a source, whatever order they were asked in.
@(test)
the_ground_is_read_nearest_the_sources_first_and_each_tile_once :: proc(t:^testing.T) {
    f:Ground_Test
    if !test_world_init(t,&f.w) {return}
    defer test_world_destroy(&f.w)
    f.plant=core.create(&f.entities)
    core.add(&f.foliages,f.plant,Foliage{source={4,4}})
    core.add(&f.worlds,f.plant,core.World_Transform{transform={rotation=1,scale={1,1,1}}})
    test_world_settle(&f.w)
    plants:Source
    for x in 0..<40 {source_cell(&plants,{i32(x),0},true).generate=true}
    append(&f.data.entries,Data_Entry{id={4,4},epoch=1,loads=1,source=plants})
    f.data.made=1
    far:=[3]f32{39*CELL_SIZE+16,0,16}
    f.streaming.items[0]={position=far,ahead=far}
    f.streaming.count=1
    for x in 0..<40 {ground_ask(&f.ground,f.plant,{i32(x),0})}
    ground_ask(&f.ground,f.plant,{5,0})
    ground_ask(&f.ground,f.plant,{1,0},true)
    queue_order(&f.ground,&f.data,core.read(&f.foliages),core.read(&f.worlds),&f.streaming)
    queue:=f.ground.queue[:]
    if !testing.expect_value(t,len(queue),40) {return}
    testing.expect(t,queue[39].coord==[2]i32{1,0} && queue[39].fine,"what the editor asks for is read first")
    testing.expect(t,queue[38].coord==[2]i32{39,0},"then the nearest a source")
    for i in 1..<39 {testing.expect(t,queue[i-1].near>=queue[i].near && queue[i].coord!=queue[i-1].coord)}
}
