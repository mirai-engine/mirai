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
    curved:bool, // the plane bends along x and leans along z
    plant:core.Entity,
    problems:core.Problems,
}

@(private="file")
ground_test_open :: proc(w:core.World_Ref) -> (core.Ground_Query,bool) {
    f:=cast(^Ground_Test)w.data
    probe :: proc(user:rawptr,origin,down:[3]f32) -> (hit:core.Ground_Hit,found:core.Ground_Found) {
        f:=cast(^Ground_Test)user
        if abs(origin.x)>32 || abs(origin.z)>32 {return}
        if origin.x>4 && origin.x<8 && origin.z>4 && origin.z<8 {return {},.Empty}
        height:=f.height
        if f.curved {height+=0.02*origin.x*origin.x+0.3*origin.z}
        return {point={origin.x,height,origin.z},normal={0,1,0},weights={0,255,0,0},layers={1={7,7}}},.Ground
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
// and those the editor asks for; sparse far from the sources.
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
    // Far from every source a tile is sparse, until the editor asks for it.
    far:=[3]f32{-1000,0,-1000}
    f.streaming.items[0]={position=far,ahead=far}
    f.streaming.count,f.streaming.revision=1,1
    ground_test_step(&f)
    testing.expect(t,ground_tile_sparse(owner,{0,0}))
    ground_request(&f.requests,f.plant,{0,0})
    ground_test_step(&f)
    testing.expect(t,!ground_tile_sparse(owner,{0,0}) && ground_tile_samples(owner,{0,0})==owner.samples)
    // The Foliage moves off the ground: its tiles go.
    core.edit(&f.worlds,f.plant).transform.position={1000,0,0}
    test_world_settle(&f.w)
    for _ in 0..<2 {ground_test_step(&f)}
    testing.expect_value(t,len(owner.tiles),0)
}

// Far from the sources a tile keeps only the samples around the instances of
// the types seen that far, read as near: they stand where they stand on the
// whole tile.
@(test)
far_trees_stand_where_they_stand_near :: proc(t:^testing.T) {
    f:Ground_Test
    if !test_world_init(t,&f.w) {return}
    defer test_world_destroy(&f.w)
    f.plant=core.create(&f.entities)
    core.add(&f.foliages,f.plant,Foliage{source={4,4}})
    core.add(&f.worlds,f.plant,core.World_Transform{transform={rotation=1,scale={1,1,1}}})
    test_world_settle(&f.w)
    plants:Source
    tree:=source_type_add(&plants,"tree",{1,1})
    tree.density,tree.cull_distance,tree.align=0.02,0,1
    tree_id:=tree.id
    grass:=source_type_add(&plants,"grass",{2,2})
    grass.density,grass.cull_distance=0.5,50
    plant:=source_cell(&plants,{0,0},true)
    plant.generate=true
    append(&plant.manual,Foliage_Instance{id=1,type=tree_id,flags=INSTANCE_GROUNDED,position={20.3,0,9.7},scale={1,1}})
    append(&f.data.entries,Data_Entry{id={4,4},epoch=1,loads=1,source=plants})
    f.data.made=1
    f.queries.open=ground_test_open
    f.height,f.curved=2,true
    ground_test_step(&f)
    owner:=ground_owner(&f.ground,f.plant)
    if !testing.expect(t,owner!=nil && ground_tile_find(owner,{0,0})>=0 && !ground_tile_sparse(owner,{0,0})) {return}
    s:=&f.data.entries[0].source
    near,far:Build_Work
    defer build_work_destroy(&near)
    defer build_work_destroy(&far)
    tile,_:=ground_cell(owner,{0,0})
    if !testing.expect(t,cell_build(s,source_cell(s,{0,0}),tile,&near)) {return}
    away:=[3]f32{-2000,0,-2000}
    f.streaming.items[0]={position=away,ahead=away}
    f.streaming.count,f.streaming.revision=1,1
    ground_test_step(&f)
    if !testing.expect(t,ground_tile_sparse(owner,{0,0})) {return}
    tile,_=ground_cell(owner,{0,0})
    whole:=int(owner.samples*owner.samples)
    testing.expectf(t,len(tile.keys)>0 && len(tile.keys)<whole/4,"%d samples of %d",len(tile.keys),whole)
    if !testing.expect(t,cell_build(s,source_cell(s,{0,0}),tile,&far)) {return}
    trees:=0
    for p in near.placed {
        if p.type!=tree_id {continue}
        trees+=1
        kept:=false
        for q in far.placed {kept||=q.id==p.id && q.position==p.position && q.rotation==p.rotation}
        testing.expectf(t,kept,"tree %x stands far where it stands near",p.id)
    }
    // The grass is not read that far: only where it shares the samples of a tree.
    testing.expectf(t,trees>1 && len(far.placed)<trees+(len(near.placed)-trees)/4,"%d trees, %d far of %d near",trees,len(far.placed),len(near.placed))
}
