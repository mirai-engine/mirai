package foliage

import "core:math/linalg"
import "core:mem"
import "core:testing"
import "mirai:core"
import render "mirai:engine/render"
import scene "mirai:engine/scene"
import volume "mirai:engine/volume"
import "mirai:host"
import mm "mirai:std/math"
import pcg "plugins:pcg/runtime"

@(private)
@(test_world)
Micro_World :: struct {
    using world:Test_World,
    ids:core.Table(core.Id),
    parents:core.Table(core.Parent),
    foliages:core.Table(Foliage),
    graphs:core.Table(pcg.Pcg_Graph),
    worlds:core.Table(core.World_Transform),
    volumes:core.Table(volume.Volume),
    splines:core.Table(volume.Spline),
    zones:core.Table(pcg.Pcg_Zone),
}

MICRO_TEST_CELL :: f32(8)
MICRO_TEST_SAMPLES :: 9

// A Foliage whose graph has a Macro tree layer and a Micro grass layer, its
// data, the flat ground of cell (0, 0), what the graph placed there, and the
// micro state of the world with the look of the grass (of mesh) and the tile
// of that cell, which waits to be generated.
@(private)
Micro_Fixture :: struct {
    w:Micro_World,
    data:pcg.Pcg_Data,
    grounds:pcg.Pcg_Ground,
    generated:pcg.Pcg_Generated,
    micro:Foliage_Micro,
    assets:host.Assets,
    app:host.App,
    sources:scene.Streaming_Sources,
    e:core.Entity,
    tree,grass:u32,
}

@(private)
micro_fixture_init :: proc(t:^testing.T,f:^Micro_Fixture,mesh:render.Mesh_Handle=1,renderer:^render.Renderer=nil) -> bool {
    if !test_world_init(t,&f.w) {return false}
    f.app=host.App{allocator=context.allocator,assets=&f.assets,renderer=renderer}
    s:pcg.Pcg_Source
    pcg.source_init(&s)
    s.info.cell_size,s.info.seed=MICRO_TEST_CELL,5
    tree:=pcg.source_layer_add(&s,.Scatter,.Macro)
    tree.density,tree.radius,tree.scale=0.05,1,{1,1}
    f.tree=tree.id
    grass:=pcg.source_layer_add(&s,.Scatter,.Micro)
    grass.density,grass.asset,grass.scale,grass.height,grass.cull_distance,grass.fade_distance=16,{5,5},{0.15,0.15},{1,1},60,50
    f.grass=grass.id
    if issue:=pcg.source_compile(&s);!testing.expect_value(t,issue.kind,pcg.Pcg_Issue_Kind.None) {return false}
    append(&f.data.entries,pcg.Pcg_Data_Entry{id={9,9},epoch=1,loads=1,source=s})
    e:=core.create(&f.w.entities)
    core.add(&f.w.foliages,e,FOLIAGE_DEFAULT)
    core.add(&f.w.graphs,e,pcg.Pcg_Graph{source={9,9}})
    core.add(&f.w.worlds,e,core.World_Transform{transform=mm.TRANSFORM_IDENTITY})
    test_world_settle(&f.w)
    f.e=e
    // The flat ground of the cell, read whole.
    n:=MICRO_TEST_SAMPLES
    pool:=pcg.Ground_Pool{samples=u32(n)}
    resize(&pool.heights,n*n)
    resize(&pool.weights,n*n)
    resize(&pool.kept,pcg.KEPT_WORDS)
    append(&pool.coords,[2]i32{0,0})
    owner:=pcg.Pcg_Ground_Owner{entity=e,cell_size=MICRO_TEST_CELL,samples=u32(n),revision=1}
    append(&owner.pools,pool)
    append(&owner.tiles,pcg.Pcg_Ground_Tile{coord={0,0},revision=1})
    append(&owner.cells,pcg.Ground_Want{coord={0,0}})
    append(&f.grounds.owners,owner)
    // What the graph placed there, and where its trees stand before anything is taken out.
    graph:=pcg.Generated_Graph{entity=e,key=77,cells=make([dynamic]pcg.Generated_Cell)}
    cell:=pcg.Generated_Cell{coord={0,0},built=true,revision=1,placed=make([dynamic]pcg.Placed)}
    if !micro_place(t,f,&cell) {return false}
    append(&graph.cells,cell)
    append(&f.generated.graphs,graph)
    // The micro state as micro_refresh leaves it.
    look:=Micro_Look{entity=e,layer=f.grass,index=1,mesh=mesh,side=32,thin=max(u32),seed=5,pose=mm.TRANSFORM_IDENTITY,frame=linalg.MATRIX4F32_IDENTITY,cell_size=MICRO_TEST_CELL}
    look.row.sphere={0,0,0,0.87}
    look.row.scale={0.15,0.15,1,1}
    look.row.distance={50,60,0,0}
    look.row.mesh={u32(mesh),1,0,32*32}
    f.micro.app=&f.app
    append(&f.micro.looks,look)
    block,taken:=micro_block_take(&f.micro,32*32)
    if !testing.expect(t,taken) {return false}
    _,revision:=pcg.ground_cell(&f.grounds.owners[0],{0,0})
    want:=micro_tile_key(77,revision,f.generated.graphs[0].cells[0].occupied_hash,f.grass,32,max(u32))
    append(&f.micro.tiles,Micro_Tile{used=true,entity=e,layer=f.grass,coord={0,0},block=block,want=want})
    f.micro.visible=32*32
    return true
}

// The trees of the cell of the fixture, placed by the generator of pcg.
@(private="file")
micro_place :: proc(t:^testing.T,f:^Micro_Fixture,cell:^pcg.Generated_Cell,suppressed:[]u64=nil) -> bool {
    scratch:pcg.Pcg_Scratch
    if !testing.expect(t,pcg.scratch_init(&scratch)) {return false}
    defer pcg.scratch_destroy(&scratch)
    ground,_:=pcg.ground_cell(&f.grounds.owners[0],{0,0})
    s:=&f.data.entries[0].source
    cin:=pcg.Pcg_Cell_Input{source=s,seed=5,coord={0,0},ground=ground,frame=linalg.MATRIX4F32_IDENTITY,domain={volume=volume.world(),pose=mm.TRANSFORM_IDENTITY},suppressed=suppressed,share=1}
    clear(&cell.placed)
    if !testing.expect(t,pcg.cell_generate(&cin,&scratch,&cell.placed)) {return false}
    cell.occupied,cell.occupied_hash=scratch.occupied,scratch.occupied_hash
    return true
}

@(private)
micro_fixture_destroy :: proc(f:^Micro_Fixture) {
    foliage_micro_free(&f.micro)
    pcg.pcg_generated_free(&f.generated)
    for &owner in f.grounds.owners {pcg.ground_owner_destroy(&owner)}
    delete(f.grounds.owners)
    pcg.pcg_data_free(&f.data)
    test_world_destroy(&f.w)
}

@(private)
micro_where :: proc(f:^Micro_Fixture) -> volume.Where {
    return {volumes=core.read(&f.w.volumes),worlds=core.read(&f.w.worlds),parents=core.read(&f.w.parents),splines=core.read(&f.w.splines)}
}

@(private)
micro_jobs_of :: proc(f:^Micro_Fixture,problems:^core.Problems) {
    micro_jobs(&f.micro,&f.data,&f.grounds,&f.generated,core.read(&f.w.graphs),core.read(&f.w.zones),core.read(&f.w.ids),micro_where(f),problems)
}

// The trees of a cell occupy the ground the Micro layers scatter on as they
// stood before anything was taken out: suppressing every tree leaves the
// cell empty and its occupancy as it was, so no grass sprouts at a stump.
// Where a tree stands the grass has no density; elsewhere, all of it.
@(test)
micro_occupancy_is_that_of_the_points_before_they_are_suppressed :: proc(t:^testing.T) {
    f:=new(Micro_Fixture)
    defer free(f)
    if !micro_fixture_init(t,f) {return}
    defer micro_fixture_destroy(f)
    cell:=&f.generated.graphs[0].cells[0]
    if !testing.expect(t,len(cell.placed)>0 && cell.occupied_hash!=0,"trees stand and occupy their ground") {return}
    before,hash:=cell.occupied,cell.occupied_hash
    trees:=make([dynamic]pcg.Placed,context.temp_allocator)
    append(&trees,..cell.placed[:])
    ids:=make([dynamic]u64,context.temp_allocator)
    for p in trees {append(&ids,p.id)}
    slice_sort(ids[:])
    if !micro_place(t,f,cell,ids[:]) {return}
    testing.expect_value(t,len(cell.placed),0)
    testing.expect(t,cell.occupied_hash==hash && cell.occupied==before,"taking the trees out keeps their ground occupied")
    // A source without Micro layers keeps no occupancy.
    s:=&f.data.entries[0].source
    s.layers[1].tier=.Meso
    if !micro_place(t,f,cell) {return}
    testing.expect_value(t,cell.occupied_hash,u64(0))
    s.layers[1].tier=.Micro
    if !micro_place(t,f,cell) {return}
    // The densities the grass scatters at.
    scratch:pcg.Pcg_Scratch
    if !testing.expect(t,pcg.scratch_init(&scratch)) {return}
    defer pcg.scratch_destroy(&scratch)
    ground,_:=pcg.ground_cell(&f.grounds.owners[0],{0,0})
    cin:=pcg.Pcg_Cell_Input{source=s,seed=5,coord={0,0},ground=ground,frame=linalg.MATRIX4F32_IDENTITY,domain={volume=volume.world(),pose=mm.TRANSFORM_IDENTITY},share=1}
    n:=pcg.MICRO_SAMPLES
    samples:=make([]u8,n*n,context.temp_allocator)
    if !testing.expect(t,pcg.micro_samples(&cin,&scratch,1,&cell.occupied,samples)) {return}
    step:=MICRO_TEST_CELL/f32(n-1)
    for p in trees {
        x,z:=int(p.position.x/step+0.5),int(p.position.z/step+0.5)
        if x<0 || z<0 || x>=n || z>=n {continue}
        testing.expectf(t,samples[z*n+x]==0,"no grass where a tree stands at %v",p.position)
    }
    free_ground:=0
    for v in samples {
        testing.expect(t,v==0 || v==255,"flat ground without a field: all of the density or none")
        if v==255 {free_ground+=1}
    }
    testing.expect(t,free_ground>n*n/2,"the grass covers the ground the trees leave")
    // A field halves it.
    if !testing.expect(t,pcg.source_layer_texts(s,f.grass,"0.5") && pcg.source_compile(s).kind==.None) {return}
    testing.expect(t,pcg.micro_samples(&cin,&scratch,1,nil,samples))
    testing.expect_value(t,samples[n*n/2],u8(128))
}

@(private="file")
slice_sort :: proc(ids:[]u64) {
    for i in 1..<len(ids) {
        for j:=i;j>0 && ids[j]<ids[j-1];j-=1 {ids[j],ids[j-1]=ids[j-1],ids[j]}
    }
}

// A tile is generated when what it stands on changes and only then: the
// first frame makes its packet (the heights of its ground tile and the
// densities of its layer), and once the Simulate stage generated it a frame
// with the same inputs makes no job and allocates nothing. Another revision of
// its ground tile, or of where the trees occupy its cell, changes what it is
// generated from; the inputs the tiles are chosen from change with them.
@(test)
a_micro_tile_is_generated_once_until_its_ground_or_occupancy_changes :: proc(t:^testing.T) {
    f:=new(Micro_Fixture)
    defer free(f)
    if !micro_fixture_init(t,f) {return}
    defer micro_fixture_destroy(f)
    problems:core.Problems
    m:=&f.micro
    micro_jobs_of(f,&problems)
    if !testing.expect_value(t,len(m.jobs),1) {return}
    job:=m.jobs[0]
    n:=pcg.MICRO_SAMPLES
    testing.expect_value(t,job.packet[1],u32(MICRO_TEST_SAMPLES*MICRO_TEST_SAMPLES+(n*n+3)/4))
    testing.expect(t,job.gen.a=={0,m.blocks[0].first,32,MICRO_TEST_SAMPLES} && job.gen.b[1]==max(u32) && job.gen.b[2]==u32(n) && job.gen.c[0]==MICRO_TEST_CELL)
    testing.expect_value(t,job.key,m.tiles[0].want)
    // What the Simulate stage does with it.
    m.tiles[0].key=job.key
    clear(&m.jobs)
    tracking:mem.Tracking_Allocator
    mem.tracking_allocator_init(&tracking,context.allocator)
    defer mem.tracking_allocator_destroy(&tracking)
    {
        context.allocator=mem.tracking_allocator(&tracking)
        for _ in 0..<3 {micro_jobs_of(f,&problems)}
    }
    testing.expect_value(t,len(m.jobs),0)
    testing.expect_value(t,tracking.total_allocation_count,i64(0))
    // What it is generated from.
    cell:=&f.generated.graphs[0].cells[0]
    key:=micro_tile_key(77,1,cell.occupied_hash,f.grass,32,max(u32))
    testing.expect_value(t,key,m.tiles[0].want)
    testing.expect(t,micro_tile_key(77,2,cell.occupied_hash,f.grass,32,max(u32))!=key,"another ground tile")
    testing.expect(t,micro_tile_key(77,1,cell.occupied_hash~1,f.grass,32,max(u32))!=key,"another occupancy")
    testing.expect(t,micro_tile_key(78,1,cell.occupied_hash,f.grass,32,max(u32))!=key,"another source, seed or frame")
    testing.expect(t,micro_tile_key(77,1,cell.occupied_hash,f.grass,32,max(u32)/2)!=key,"another detail")
    detail:=FOLIAGE_DETAIL[.High]
    inputs:=micro_inputs(&f.data,&f.grounds,&f.generated,core.read(&f.w.foliages),core.read(&f.w.graphs),core.read(&f.w.worlds),&f.sources,detail,&f.app)
    testing.expect(t,inputs!=0 && inputs==micro_inputs(&f.data,&f.grounds,&f.generated,core.read(&f.w.foliages),core.read(&f.w.graphs),core.read(&f.w.worlds),&f.sources,detail,&f.app),"the same inputs, the same hash")
    f.grounds.owners[0].revision+=1
    testing.expect(t,inputs!=micro_inputs(&f.data,&f.grounds,&f.generated,core.read(&f.w.foliages),core.read(&f.w.graphs),core.read(&f.w.worlds),&f.sources,detail,&f.app),"a ground read again")
    f.grounds.owners[0].revision-=1
    f.generated.graphs[0].revision+=1
    testing.expect(t,inputs!=micro_inputs(&f.data,&f.grounds,&f.generated,core.read(&f.w.foliages),core.read(&f.w.graphs),core.read(&f.w.worlds),&f.sources,detail,&f.app),"a cell placed again")
    f.generated.graphs[0].revision-=1
    f.sources.revision+=1
    testing.expect(t,inputs!=micro_inputs(&f.data,&f.grounds,&f.generated,core.read(&f.w.foliages),core.read(&f.w.graphs),core.read(&f.w.worlds),&f.sources,detail,&f.app),"the sources moved")
    // A tile whose want changed is generated again, keeping what it drew meanwhile.
    m.tiles[0].want=micro_tile_key(77,2,cell.occupied_hash,f.grass,32,max(u32))
    micro_jobs_of(f,&problems)
    testing.expect(t,len(m.jobs)==1 && m.tiles[0].key==job.key)
}

// Runs of the buffer go back to the free ones that fit, and the free ones at
// the end give their room back.
@(test)
micro_blocks_reuse_their_room :: proc(t:^testing.T) {
    m:Foliage_Micro
    defer foliage_micro_free(&m)
    a,_:=micro_block_take(&m,100)
    b,_:=micro_block_take(&m,50)
    c,_:=micro_block_take(&m,100)
    testing.expect(t,a==1 && b==2 && c==3 && m.end==250)
    micro_block_free(&m,&a)
    d,_:=micro_block_take(&m,90)
    testing.expect(t,d==1 && m.blocks[0].first==0,"a free run that fits")
    e,_:=micro_block_take(&m,30)
    testing.expect(t,e==4 && m.end==280,"one that would waste more than half of a free run takes a new one")
    micro_block_free(&m,&e)
    micro_block_free(&m,&c)
    testing.expect(t,m.end==150 && len(m.blocks)==2 && a==0 && c==0 && e==0)
}

// Without a renderer (a dedicated server, a headless tool) the micro foliage
// does nothing: no tile, no buffer, no memory.
@(test)
micro_foliage_does_nothing_without_a_renderer :: proc(t:^testing.T) {
    f:=new(Micro_Fixture)
    defer free(f)
    if !micro_fixture_init(t,f) {return}
    defer micro_fixture_destroy(f)
    problems:core.Problems
    m:Foliage_Micro
    tracking:mem.Tracking_Allocator
    mem.tracking_allocator_init(&tracking,context.allocator)
    defer mem.tracking_allocator_destroy(&tracking)
    f.app.allocator=mem.tracking_allocator(&tracking)
    {
        context.allocator=mem.tracking_allocator(&tracking)
        for _ in 0..<3 {
            foliage_micro(&m,core.ref(&f.data),core.ref(&f.grounds),core.ref(&f.generated),core.read(&f.w.foliages),core.read(&f.w.graphs),core.read(&f.w.zones),core.read(&f.w.ids),micro_where(f),core.ref(&f.sources),{detail=.High},{index=1},&f.app,&problems)
        }
    }
    testing.expect_value(t,tracking.total_allocation_count,i64(0))
    testing.expect(t,m.app==nil && len(m.tiles)==0 && len(m.looks)==0 && m.capacity==0)
}
