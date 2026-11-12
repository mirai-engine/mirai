package terrain

import "core:fmt"
import "core:math"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:std/base"
import mm "mirai:std/math"
import phys "plugins:physics/runtime"

@(private)
@(test_world)
Ground_World :: struct {
    using world:Test_World,
    using terrain:Test_Terrain,
}

// A call of terrain_update as its readers see it: what it pushed in it, and
// the ground they open from the world.
@(private="file")
ground_step :: proc(w:^Ground_World,resident:^Terrain_Resident,focus:=Terrain_Focus{}) -> core.Ground_Query {
    clear(&w.ground_queries.changed.items);clear(&w.ground_queries.unloaded.items)
    ground_update(&w.terrain_ground,resident,&w.data,core.read(&w.terrains),&w.colliders,core.read(&w.worlds),focus,&w.ground_queries)
    w.ground_queries.open=ground_open
    return core.ground_query(test_world_ref(w),core.ref(&w.ground_queries))
}

@(private="file")
ground_entry :: proc(w:^Ground_World,id:base.Asset_Id,s:Source,at:[3]f32) -> core.Entity {
    entry:=Data_Source{id=id,source=s,change=1}
    n:=chunk_counts(&entry.source)
    entry.versions=make([]u32,n.x*n.y*n.z)
    for &version in entry.versions {version=1}
    append(&w.data.entries,entry)
    e:=core.create(&w.entities)
    core.add(&w.terrains,e,Terrain{source=id,solid=true})
    core.add(&w.worlds,e,core.World_Transform{transform={position=at,rotation=1,scale={1,1,1}}})
    test_world_settle(w)
    return e
}

// The probe as foliage and any other reader ask it, against a Heightfield
// of 64 m at the origin and a Volume read by pages at x 500, with only the
// blocks around (-8, 0, -8) of its space in memory, as far from every viewer.
@(test)
the_ground_answers_each_line_as_its_terrain_has_it :: proc(t:^testing.T) {
    w:Ground_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    resident:Terrain_Resident
    defer terrain_resident_free(&resident)
    // Without terrains no line has ground.
    q:=ground_step(&w,&resident)
    _,found:=q.probe(q.user,{0,10,0},{0,-1,0},false)
    testing.expect_value(t,found,core.Ground_Found.None)
    hill:Source
    if !testing.expect(t,source_make(&hill,.Heightfield,{65,1,65},1,16)) {return}
    testing.expect(t,source_edit(&hill,{kind=.Raise,center={-16,0,-16},radius=4,amount=2}).changed)
    testing.expect(t,source_edit(&hill,{kind=.Hole,center={16.5,0,-16.5},radius=0.6}).changed)
    whole,paged:Source
    if !testing.expect(t,source_make(&whole,.Volume,{97,97,97},1,16)) {return}
    defer source_destroy(&whole)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    path:=fmt.tprintf("%s/ground.terrain",base.test_folder(t,"terrain"))
    testing.expect_value(t,source_save(&whole,path,{5,5},&types),asset.Error.None)
    front:asset.Asset
    if !testing.expect_value(t,asset.asset_load_front(&front,path),asset.Error.None) {return}
    _,read:=source_read(&paged,&front,&types,pages=path)
    asset.asset_close(&front)
    if !testing.expect(t,read && source_region_read(&paged,{36,44,36},{44,52,44})) {return}
    land:=ground_entry(&w,{3,3},hill,{})
    ground_entry(&w,{5,5},paged,{500,0,0})
    q=ground_step(&w,&resident)
    s:=&w.data.entries[0].source
    coarse,_,_,_:=source_coarse_at(s,-20,-16)
    testing.expect(t,abs(coarse-source_height(s,-20,-16))>1e-2,"the coarse grid is not the samples there")
    testing.expect_value(t,q.spacing,f32(1))
    Case :: struct {origin:[3]f32,coarse:bool,found:core.Ground_Found,height:f32,why:string}
    cases:=[]Case{
        {{-16,50,-16},false,.Ground,source_height(s,-16,-16),"the samples of the Heightfield"},
        {{-20,50,-16},true,.Ground,coarse,"its coarse grid, asked far from the viewers"},
        {{16.5,50,-16.5},false,.Empty,0,"a hole"},
        {{200,50,0},false,.None,0,"off every terrain"},
        {{492,90,-8},false,.Ground,0,"the top of the Volume where its blocks are in memory"},
        {{530,90,30},false,.Unloaded,0,"where they are not"},
        {{math.nan_f32(),50,0},false,.None,0,"a line that is not a number"},
    }
    for c in cases {
        hit,found:=q.probe(q.user,c.origin,{0,-1,0},c.coarse)
        testing.expectf(t,found==c.found,"%s: %v",c.why,found)
        if found!=.Ground {continue}
        testing.expectf(t,abs(hit.point.y-c.height)<0.6 && abs(hit.point.x-c.origin.x)+abs(hit.point.z-c.origin.z)<1e-3,"%s: %v, not %v",c.why,hit.point,c.height)
        testing.expect(t,hit.weights=={255,0,0,0} && hit.layers[0]==LAYER_DEFAULT.material && hit.normal.y>0.9)
    }
    _,found=q.probe(q.user,{0,10,0},{0,0,0},false)
    testing.expect_value(t,found,core.Ground_Found.None)
    changed:=&w.ground_queries.changed.items
    // A call where nothing changed announces nothing.
    q=ground_step(&w,&resident)
    testing.expect_value(t,len(changed),0)
    // A stroke held over (12, 12) leaves its region without surface until it ends, announced both times.
    held:=Terrain_Focus{source={3,3},center={12,0,12},radius=2,stroke=true,low={10,10},high={14,14}}
    q=ground_step(&w,&resident,held)
    _,found=q.probe(q.user,{12,50,12},{0,-1,0},false)
    testing.expect(t,found==.Empty && len(changed)==1)
    q=ground_step(&w,&resident)
    _,found=q.probe(q.user,{12,50,12},{0,-1,0},false)
    testing.expect(t,found==.Ground && len(changed)==1)
    // An edit announces the box of its chunks, and a terrain that moves all it covered and covers.
    change:=source_edit(s,{kind=.Raise,center={20,0,20},radius=3,amount=1.5})
    low,high:=chunk_range(s,change)
    w.data.entries[0].change=2
    for z in low.z..=high.z {for x in low.x..=high.x {w.data.entries[0].versions[chunk_index(s,{i32(x),0,i32(z)})]=2}}
    q=ground_step(&w,&resident)
    testing.expect(t,len(changed)==1 && mm.aabb_contains(changed[0],{{20,0,20},{20,0,20}}) && !mm.aabb_contains(changed[0],{{-16,0,-16},{-16,0,-16}}))
    hit,_:=q.probe(q.user,{20,50,20},{0,-1,0},false)
    testing.expect(t,hit.point.y>1)
    core.edit(&w.worlds,land).transform.position={0,0,100}
    test_world_settle(&w)
    q=ground_step(&w,&resident)
    testing.expect_value(t,len(changed),2)
    // Another epoch of the data starts the resident anew (terrain_update): every terrain is announced.
    w.data.epoch+=1
    terrain_resident_free(&resident)
    q=ground_step(&w,&resident)
    testing.expect_value(t,len(changed),2)
    q=ground_step(&w,&resident)
    testing.expect_value(t,len(changed),0)
}

// A heightfield of 4 by 4 chunks of 16 m: the first row has its colliders
// but for one chunk, the second shows one chunk empty, the rest is not loaded.
@(test)
the_chunks_of_a_terrain_without_collider_are_unloaded_ground :: proc(t:^testing.T) {
    w:Ground_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    hill:Source
    testing.expect(t,source_make(&hill,.Heightfield,{65,1,65},1,16))
    e:=ground_entry(&w,{3,3},hill,{})
    resident:Terrain_Resident
    defer terrain_resident_free(&resident)
    shown:=make([]Resident_Chunk,16)
    chunks:=make([]core.Entity,16)
    append(&resident.sources,Resident_Source{id={3,3},owner=e,chunks=shown})
    append(&resident.owners,Resident_Owner{entity=e,source={3,3},chunks=chunks,solid=true})
    defer {delete(shown);delete(chunks);clear(&resident.sources);clear(&resident.owners)}
    for x in 0..<4 {
        if x==2 {continue}
        chunks[x]=core.create(&w.entities)
        core.add(&w.colliders,chunks[x],phys.Collider{kind=.Heightfield})
        shown[x].shown=true
    }
    shown[5].shown=true
    test_world_settle(&w)
    q:=ground_step(&w,&resident)
    // Row 0: chunk 2. Row 1: chunk 4, and 6 to 7. Rows 2 and 3: one run each.
    testing.expect_value(t,len(q.unloaded),5)
    unloaded:=&w.ground_queries.unloaded.items
    testing.expect_value(t,len(unloaded),1)
    for box in q.unloaded {
        testing.expect(t,box.min.y<=-1e3 && box.max.y>=1e3)
        // The loaded chunks, from -32 to -16 m and -16 to 0 m along x on the first row, are left out.
        testing.expect(t,!(box.max.z<=-16 && box.min.x< -16+1e-3 && box.max.x> -32+1e-3 && box.max.x<= -16+1e-3))
    }
    // A call where nothing of the terrains changed looks at no chunk, also while another entity
    // moves: one that turns shown waits for its mark.
    shown[9].shown=true
    other:=core.create(&w.entities)
    core.add(&w.worlds,other,core.World_Transform{transform={rotation=1,scale={1,1,1}}})
    test_world_settle(&w)
    q=ground_step(&w,&resident)
    testing.expect(t,len(q.unloaded)==5 && len(unloaded)==0)
    resident.marks+=1
    q=ground_step(&w,&resident)
    testing.expect(t,len(q.unloaded)==6 && len(unloaded)==1 && mm.aabb_contains(unloaded[0],{{-16,0,0},{0,0,16}}))
    // Chunk 2 loads: one box fewer.
    chunks[2]=core.create(&w.entities)
    core.add(&w.colliders,chunks[2],phys.Collider{kind=.Heightfield})
    test_world_settle(&w)
    q=ground_step(&w,&resident)
    testing.expect(t,len(q.unloaded)==5 && len(unloaded)==1)
}

@(private)
@(test_world)
Dust_World :: struct {
    using world:Test_World,
    dusts:core.Table(Terrain_Dust),
    digs:Terrain_Digs,
    births:core.Births,
}

@(test)
a_dig_raises_dust_of_each_layer_it_took_on_its_channel :: proc(t:^testing.T) {
    w:Dust_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    dusty,bare:=core.create(&w.entities),core.create(&w.entities)
    dust:=TERRAIN_DUST_DEFAULT
    dust.layers[1].color={1,0,0,1}
    base.text_set(dust.layers[1].channel[:],"gravel")
    dust.layers[3].channel={}
    core.add(&w.dusts,dusty,dust)
    test_world_settle(&w)
    core.push(&w.digs.digs,Terrain_Dig{owner=dusty,center={1,2,3},volume=1,layers={0=0.5,1=0.25,3=0.25}})
    core.push(&w.digs.digs,Terrain_Dig{owner=bare,volume=1,layers={0=1}})
    terrain_dust(core.ref(&w.digs),core.read(&w.dusts),&w.births)
    births:=w.births.queue.items[:]
    if !testing.expect_value(t,len(births),2) {return}
    testing.expect(t,births[0].channel==core.birth_channel(CHANNEL_DUST) && births[0].count==20 && births[0].position==[3]f32{1,2,3})
    testing.expect(t,births[1].channel==core.birth_channel("gravel") && births[1].count==10 && births[1].color==[4]f32{1,0,0,1})
}
