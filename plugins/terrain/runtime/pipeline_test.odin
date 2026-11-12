package terrain

import "base:runtime"
import "core:fmt"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import phys "plugins:physics/runtime"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/jobs"

// One call of terrain_update in a phase, and the physics that follows it.
@(private="file")
pipeline_tick :: proc(w:^Terrain_Test_World,resident:^Terrain_Resident,app:^host.App,settings:=TERRAIN_TEST_SETTINGS,view:=core.View{},phase:=core.Phase.Fixed,playing:=true) {
    if w.settings=={} {w.settings={bodies=256,shapes=256,contacts=64,joints=1,characters=1,hulls=1,meshes=256,heightfields=256}}
    if view.size.x>0 && view.size.y>0 {source_place(w,view.position)}
    test_step(&w.terrain,core.commands_of(test_world_ref(&w.w)),resident,app,&w.problems,settings,{playing=playing},{phase=phase},view)
    test_world_settle(&w.w)
    terrain_test_physics(w,app)
    test_world_settle(&w.w)
}

@(private="file")
pipeline_source :: proc(t:^testing.T,root:string,kind:Source_Kind,samples:[3]int,cells:int,id:base.Asset_Id,bumpy:=false) -> string {
    source:Source;testing.expect(t,source_make(&source,kind,samples,1,cells));defer source_destroy(&source)
    if bumpy {for z in 0..<samples.z {for x in 0..<samples.x {testing.expect(t,source_set(&source,{x,0,z},pipeline_bump(x,z)))}}}
    source.revision=1
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    path:=fmt.tprintf("%s/source.terrain",root)
    testing.expect_value(t,source_save(&source,path,id,&types),asset.Error.None)
    return path
}

@(private="file")
pipeline_owner :: proc(w:^Terrain_Test_World,id:base.Asset_Id,solid:=true) -> core.Entity {
    owner:=core.create(&w.entities)
    core.add(&w.transforms,owner,core.TRANSFORM_IDENTITY)
    core.add(&w.terrains,owner,Terrain{source=id,solid=solid})
    test_world_settle(&w.w)
    return owner
}

@(private="file")
pipeline_meshes :: proc(resident:^Terrain_Resident,out:[]base.Asset_Id) {
    for chunk,i in resident.sources[0].chunks[:resident.sources[0].quad.first[1]] {if i<len(out) {out[i]=chunk.mesh}}
}

@(test)
rebuilt_chunks_show_in_the_next_tick_whatever_the_threads_and_stale_results_are_let_go :: proc(t:^testing.T) {
    root:=base.test_folder(t,"terrain")
    id:=base.Asset_Id{301,302}
    pipeline_source(t,root,.Heightfield,{33,1,33},8,id)
    for threads in ([2]int{0,3}) {
        counter:=Terrain_Test_Allocator{owner=runtime.heap_allocator()}
        context.allocator={terrain_test_allocator,&counter}
        assets:host.Assets;testing.expect(t,host.assets_init(&assets,{root=root,capacity=256}));defer host.assets_destroy(&assets)
        app:=host.App{assets=&assets,allocator=context.allocator}
        if threads>0 {testing.expect(t,jobs.system_init(&app.jobs,{threads=threads,allocator=runtime.heap_allocator()}))}
        defer if threads>0 {jobs.system_destroy(&app.jobs)}
        w:Terrain_Test_World
        if !terrain_test_world_init(t,&w) {return}
        defer terrain_test_world_free(&w)
        resident:Terrain_Resident;defer terrain_resident_free(&resident)
        owner:=pipeline_owner(&w,id)
        pipeline_tick(&w,&resident,&app)
        testing.expect_value(t,len(w.chunks.values),16)
        testing.expect_value(t,len(w.colliders.values),16)
        testing.expect_value(t,resident.stats.built,u64(16))
        before:[16]base.Asset_Id;pipeline_meshes(&resident,before[:])
        dig(&w.terrain_requests,{kind=.Raise,center={-12,0,-12},radius=0.4,amount=1},owner)
        pipeline_tick(&w,&resident,&app)
        now:[16]base.Asset_Id;pipeline_meshes(&resident,now[:])
        testing.expect(t,now==before,"the tick of the edit keeps what every chunk showed")
        hit,ok:=phys.raycast({&w.state},{-12,20,-12},{0,-1,0})
        testing.expect(t,ok && abs(hit.point.y)<1e-4)
        pipeline_tick(&w,&resident,&app)
        pipeline_meshes(&resident,now[:])
        changed:=0
        for mesh,i in now {if mesh!=before[i] {changed+=1}}
        testing.expectf(t,changed==1,"the next tick shows the rebuilt chunk (%d threads)",threads)
        hit,ok=phys.raycast({&w.state},{-12,20,-12},{0,-1,0})
        testing.expect(t,ok && abs(hit.point.y-1)<1e-4)
        // Out of Play, an edit of the frame changes the source while the job of the fixed call reads it.
        stale:=resident.stats.stale
        dig(&w.terrain_requests,{kind=.Raise,center={-12,0,-12},radius=0.4,amount=1},owner)
        pipeline_tick(&w,&resident,&app,playing=false)
        dig(&w.terrain_requests,{kind=.Raise,center={-12,0,-12},radius=0.4,amount=1},owner)
        pipeline_tick(&w,&resident,&app,phase=.Frame,playing=false)
        pipeline_tick(&w,&resident,&app,playing=false)
        testing.expect_value(t,resident.stats.stale,stale+1)
        for _ in 0..<2 {pipeline_tick(&w,&resident,&app,playing=false)}
        hit,ok=phys.raycast({&w.state},{-12,20,-12},{0,-1,0})
        testing.expect(t,ok && abs(hit.point.y-3)<1e-4,"the chunk shows both edits once its stale build is done again")
        calls,built,version:=counter.requests,resident.stats.built,w.statics.version
        for _ in 0..<10 {pipeline_tick(&w,&resident,&app)}
        testing.expect_value(t,counter.requests,calls)
        testing.expect_value(t,resident.stats.built,built)
        testing.expect_value(t,w.statics.version,version)
        testing.expect_value(t,w.problems.count,0)
    }
}

@(test)
chunks_without_a_slot_for_their_collider_still_show_their_ground_and_the_nearest_collide :: proc(t:^testing.T) {
    root:=base.test_folder(t,"terrain")
    id:=base.Asset_Id{303,304}
    pipeline_source(t,root,.Heightfield,{33,1,33},8,id)
    assets:host.Assets;testing.expect(t,host.assets_init(&assets,{root=root,capacity=256}));defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets,allocator=context.allocator}
    w:Terrain_Test_World
    if !terrain_test_world_init(t,&w) {return}
    defer terrain_test_world_free(&w)
    w.settings={bodies=64,shapes=64,contacts=64,joints=1,characters=1,hulls=1,meshes=8,heightfields=6}
    resident:Terrain_Resident;defer terrain_resident_free(&resident)
    owner:=pipeline_owner(&w,id)
    view:=core.VIEW_DEFAULT
    view.position,view.size={-14,5,-14},{64,64}
    for _ in 0..<2 {pipeline_tick(&w,&resident,&app,view=view)}
    // Every chunk shows its ground; Physics_Settings has room for six colliders: the nearest take them.
    testing.expect_value(t,len(w.statics.values),16)
    testing.expect_value(t,len(w.colliders.values),6)
    s:=&w.data.entries[0].source
    farthest_with:=f32(0)
    nearest_without:=max(f32)
    for chunk,i in resident.sources[0].chunks[:16] {
        low,high:=chunk_box(s,source_origin(s),i,{-1,1})
        distance:=scene_distance(low,high,view.position)
        e:=resident.owners[0].chunks[i]
        testing.expect(t,core.has(&w.statics,e),"no chunk waits for its collider to show its ground")
        if core.has(&w.colliders,e) {farthest_with=max(farthest_with,distance)} else {nearest_without=min(nearest_without,distance)}
        _=chunk
    }
    testing.expect(t,farthest_with<=nearest_without,"the colliders go to the nearest chunks")
    testing.expect(t,core.problem_find(&w.problems,owner,"terrain.collider_budget")==nil,"without a collision distance, the nearest that fit collide")
    hit,ok:=phys.raycast({&w.state},{-14,20,-14},{0,-1,0})
    testing.expect(t,ok && abs(hit.point.y)<1e-4)
    // Another collider takes a slot: the farthest of them lets it go and keeps its ground.
    holder:=core.create(&w.entities)
    core.add(&w.transforms,holder,core.TRANSFORM_IDENTITY)
    core.add(&w.colliders,holder,phys.collider_heightfield())
    test_world_settle(&w.w)
    for _ in 0..<3 {pipeline_tick(&w,&resident,&app,view=view)}
    testing.expect_value(t,len(w.statics.values),16)
    testing.expect_value(t,len(w.colliders.values),6)
    // A terrain that does not collide shows all of it.
    core.remove(&w.colliders,holder);test_world_settle(&w.w)
    core.edit(&w.terrains,owner).solid=false
    for _ in 0..<2 {pipeline_tick(&w,&resident,&app,view=view)}
    testing.expect_value(t,len(w.statics.values),16)
    testing.expect_value(t,len(w.colliders.values),0)

    // A collision distance past what the slots admit takes no more: the nearest still collide.
    core.edit(&w.terrains,owner).solid=true
    problems:=w.problems.count
    for _ in 0..<4 {pipeline_tick(&w,&resident,&app,Terrain_Settings{collision_distance=1000,lod_distance=-1},view)}
    testing.expect_value(t,len(w.statics.values),16)
    testing.expect_value(t,len(w.colliders.values),6)
    testing.expect_value(t,w.problems.count,problems)
    hit,ok=phys.raycast({&w.state},{-14,20,-14},{0,-1,0})
    testing.expect(t,ok && abs(hit.point.y)<1e-4)
    // A shorter one keeps only those within it.
    for _ in 0..<4 {pipeline_tick(&w,&resident,&app,Terrain_Settings{collision_distance=6,lod_distance=-1},view)}
    testing.expect(t,len(w.colliders.values)>0 && len(w.colliders.values)<6)
}

@(private="file")
scene_distance :: proc(low,high,p:[3]f32) -> f32 {
    d:=[3]f32{max(low.x-p.x,0,p.x-high.x),0,max(low.z-p.z,0,p.z-high.z)}
    return d.x*d.x+d.z*d.z
}

// The one streaming source of the world, as scene_sources leaves it.
@(private="file")
source_place :: proc(w:^Terrain_Test_World,position:[3]f32) {
    if w.streaming.count==1 && w.streaming.items[0].position==position {return}
    w.streaming.items[0]={position,position,0}
    w.streaming.count=1
    w.streaming.revision+=1
}

@(test)
letting_go_of_an_excavated_zone_and_reading_it_again_keeps_its_edits :: proc(t:^testing.T) {
    root:=base.test_folder(t,"terrain")
    id:=base.Asset_Id{307,308}
    path:=pipeline_source(t,root,.Heightfield,{257,1,257},32,id,bumpy=true)
    bump:=pipeline_bump(28,28)
    for threads in ([2]int{0,2}) {
        assets:host.Assets;testing.expect(t,host.assets_init(&assets,{root=root,capacity=512}));defer host.assets_destroy(&assets)
        app:=host.App{assets=&assets,allocator=context.allocator}
        if threads>0 {testing.expect(t,jobs.system_init(&app.jobs,{threads=threads}))}
        defer if threads>0 {jobs.system_destroy(&app.jobs)}
        w:Terrain_Test_World
        if !terrain_test_world_init(t,&w) {return}
        defer terrain_test_world_free(&w)
        resident:Terrain_Resident;defer terrain_resident_free(&resident)
        owner:=pipeline_owner(&w,id)
        test_world_settle(&w.w)
        near:=[3]f32{-100,0,-100}
        source_place(&w,near)
        settings:=Terrain_Settings{resident_distance=100,lod_distance=-1}
        // What it showed stays until the nodes that replace it are built.
        for _ in 0..<8 {pipeline_tick(&w,&resident,&app,settings)}
        s:=&w.data.entries[0].source
        testing.expect(t,source_paged(s),"a Heightfield on disk is read by pages")
        resident_chunks:=len(w.chunks.values)
        testing.expect(t,resident_chunks>0 && resident_chunks<64,"only the chunks near the viewer are resident")
        testing.expect(t,grid_dense(&s.field)<len(s.field.pages)*PAGE*PAGE,"only the pages they read are in memory")
        testing.expect(t,w.data.stats.pages_read>0,"the chunks farther from the viewer read their pages in jobs")
        hit,ok:=phys.raycast({&w.state},near+{0,20,0},{0,-1,0})
        testing.expect(t,ok && abs(hit.point.y)<1e-4)
        hit,ok=phys.raycast({&w.state},{100,20,100},{0,-1,0})
        testing.expect(t,ok && piece_depth(&w,hit)>0,"far from the viewer the ground collides with its node")
        // Excavate near the viewer.
        dig(&w.terrain_requests,{kind=.Lower,center=near,radius=0.4,amount=2},owner)
        for _ in 0..<2 {pipeline_tick(&w,&resident,&app,settings)}
        hit,ok=phys.raycast({&w.state},near+{0,20,0},{0,-1,0})
        testing.expect(t,ok && abs(hit.point.y+2)<1e-4)
        height,known:=terrain_height({&w.data},id,near.x,near.z)
        testing.expect(t,known && abs(height+2)<1e-4)
        change:=terrain_change({&w.data},id)
        // A snapshot of the World copies what is in memory.
        snapshot:Terrain_Data;defer terrain_data_free(&snapshot)
        testing.expect(t,terrain_data_copy(&snapshot,&w.data))
        // The viewer leaves: the zone lets go of its chunks and pages.
        far:=[3]f32{100,0,100}
        source_place(&w,far)
        // What it showed stays until the nodes that replace it are built.
        for _ in 0..<8 {pipeline_tick(&w,&resident,&app,settings)}
        s=&w.data.entries[0].source
        hit,ok=phys.raycast({&w.state},near+{0,20,0},{0,-1,0})
        testing.expect(t,ok && piece_depth(&w,hit)>0,"the zone let go of its chunk colliders: its node collides")
        _,known=terrain_height({&w.data},id,near.x,near.z)
        testing.expect(t,!known,"and of its pages")
        testing.expect(t,w.data.stats.pages_left>0)
        page:=int(near.x+128)/PAGE+s.field.counts.x*(int(near.z+128)/PAGE)
        testing.expect(t,grid_absent(&s.field,page) && s.field.blocks[page].own!=nil,"its edits stay in a block of its own")
        testing.expect(t,snapshot.entries[0].source.field.pages[page].values!=nil,"a snapshot keeps the pages it holds")
        hit,ok=phys.raycast({&w.state},far+{0,20,0},{0,-1,0})
        testing.expect(t,ok && abs(hit.point.y)<1e-4)
        // The chunks of the zone keep their change: only those that read pages that came take one.
        zone:=chunk_index(s,{i32(int(near.x+128)/32),0,i32(int(near.z+128)/32)})
        testing.expect(t,w.data.entries[0].versions[zone]<=change,"letting go is not a change of the zone; the pages that come mark the chunks that read them")
        // The viewer comes back: the zone shows the excavation again.
        source_place(&w,near)
        // What it showed stays until the nodes that replace it are built.
        for _ in 0..<8 {pipeline_tick(&w,&resident,&app,settings)}
        hit,ok=phys.raycast({&w.state},near+{0,20,0},{0,-1,0})
        testing.expectf(t,ok && abs(hit.point.y+2)<1e-4,"reading the zone again keeps its edits (%d threads): %v",threads,hit.point)
        height,known=terrain_height({&w.data},id,near.x,near.z)
        testing.expect(t,known && abs(height+2)<1e-4)
        // Saving writes every page, those in memory and those in blocks.
        request_save(&w.terrain_requests,owner,fmt.tprintf("%s/saved.terrain",root))
        pipeline_tick(&w,&resident,&app,settings)
        saved:Source;defer source_destroy(&saved)
        _,loaded:=source_load(&saved,fmt.tprintf("%s/saved.terrain",root),&assets.types)
        testing.expect(t,loaded && (source_value(&saved,{int(near.x)+128,0,int(near.z)+128}) or_else 0)==-2)
        testing.expect_value(t,w.problems.count,0)
        for &p in core.problems_list(&w.problems) {fmt.println(core.problem_text(&p))}
    }
    _=path
}

@(test)
a_volume_lets_go_of_the_blocks_far_from_its_viewers_and_reading_them_again_keeps_its_edits :: proc(t:^testing.T) {
    root:=base.test_folder(t,"terrain")
    id:=base.Asset_Id{311,312}
    pipeline_source(t,root,.Volume,{129,33,129},16,id)
    for threads in ([2]int{0,2}) {
        assets:host.Assets;testing.expect(t,host.assets_init(&assets,{root=root,capacity=512}));defer host.assets_destroy(&assets)
        app:=host.App{assets=&assets,allocator=context.allocator}
        if threads>0 {testing.expect(t,jobs.system_init(&app.jobs,{threads=threads}))}
        defer if threads>0 {jobs.system_destroy(&app.jobs)}
        w:Terrain_Test_World
        if !terrain_test_world_init(t,&w) {return}
        defer terrain_test_world_free(&w)
        resident:Terrain_Resident;defer terrain_resident_free(&resident)
        owner:=pipeline_owner(&w,id)
        test_world_settle(&w.w)
        near:=[3]f32{-50,0,-50}
        source_place(&w,near)
        settings:=Terrain_Settings{resident_distance=30,lod_distance=-1}
        for _ in 0..<8 {pipeline_tick(&w,&resident,&app,settings)}
        s:=&w.data.entries[0].source
        testing.expect(t,source_paged(s),"a Volume on disk is read by blocks")
        resident_chunks:=len(w.chunks.values)
        testing.expect(t,resident_chunks>0 && resident_chunks<32,"only the chunks near the viewer are resident")
        testing.expect(t,grid_dense(&s.field)<len(s.field.pages)*PAGE_VALUES/4,"only the blocks they read are in memory")
        testing.expect(t,w.data.stats.pages_read>0,"the chunks farther from the viewer read their blocks in jobs")
        hit,ok:=phys.raycast({&w.state},near+{0,20,0},{0,-1,0})
        testing.expectf(t,ok && abs(hit.point.y)<1e-3,"the top of the box: %v",hit.point)
        _,ok=phys.raycast({&w.state},{50,20,50},{0,-1,0})
        testing.expect(t,!ok,"far from the viewer there is no collider")
        // Excavate near the viewer.
        dig(&w.terrain_requests,{kind=.Carve,center=near,radius=2,amount=1},owner)
        for _ in 0..<2 {pipeline_tick(&w,&resident,&app,settings)}
        hit,ok=phys.raycast({&w.state},near+{0,20,0},{0,-1,0})
        testing.expectf(t,ok && hit.point.y< -1.5,"the excavation: %v",hit.point)
        excavated:=hit.point.y
        at:=[3]int{14,16,14}
        dug:=source_value(s,at) or_else 0
        testing.expect(t,dug>0)
        // A snapshot of the World copies what is in memory.
        snapshot:Terrain_Data;defer terrain_data_free(&snapshot)
        testing.expect(t,terrain_data_copy(&snapshot,&w.data))
        // The viewer leaves: the zone lets go of its chunks and blocks.
        far:=[3]f32{50,0,50}
        source_place(&w,far)
        // The node over the zone is built from its blocks before they leave; a node is taken when its job ends.
        for _ in 0..<48 {work_wait(&w.data,nil);pipeline_tick(&w,&resident,&app,settings)}
        s=&w.data.entries[0].source
        hit,ok=phys.raycast({&w.state},near+{0,20,0},{0,-1,0})
        testing.expect(t,ok && piece_depth(&w,hit)>0,"the zone let go of its chunk colliders: its node collides")
        // What is far shows as a node of the octree: one mesh for the surface of its chunks, with the excavation.
        zone:=core.NONE
        for chunk,row in w.chunks.values[:core.count(&w.chunks)] {
            if chunk.depth>0 && chunk.coord=={0,0,0} && core.has(&w.statics,w.chunks.entities[row]) {zone=w.chunks.entities[row]}
            testing.expect(t,chunk.depth>0 || chunk.coord.x>=4 || chunk.coord.z>=4,"no chunk of the zone stays")
        }
        if testing.expect(t,zone!=core.NONE,"a node shows the zone the viewer left") {
            // A dig there, far from every viewer, shows on the node.
            before:=core.at(&w.statics,core.row_of(&w.statics,zone)).mesh
            dig(&w.terrain_requests,{kind=.Carve,center=near+{20,0,20},radius=3,amount=1},owner)
            for _ in 0..<24 {work_wait(&w.data,nil);pipeline_tick(&w,&resident,&app,settings)}
            shown,still:=core.get(&w.statics,zone)
            testing.expect(t,still && shown.mesh!={} && shown.mesh!=before,"the node is built again with what was dug under it")
            // Far from every viewer its block may be in the file: it is read to be looked at.
            testing.expect(t,source_region_read(s,{34,14,34},{34,14,34}))
            testing.expect(t,(source_value(s,{34,14,34}) or_else 0)>0)
        }
        testing.expect(t,w.data.stats.pages_left>0)
        block,_:=grid_page_at(&s.field,at)
        testing.expect(t,grid_absent(&s.field,block) && grid_block(&s.field,block).own!=nil,"its edits stay in a block of its own")
        testing.expect(t,grid_page(&snapshot.entries[0].source.field,block).values!=nil,"a snapshot keeps the blocks it holds")
        hit,ok=phys.raycast({&w.state},far+{0,20,0},{0,-1,0})
        testing.expect(t,ok && abs(hit.point.y)<1e-3)
        // The viewer comes back: the zone shows the excavation again.
        source_place(&w,near)
        for _ in 0..<8 {pipeline_tick(&w,&resident,&app,settings)}
        hit,ok=phys.raycast({&w.state},near+{0,20,0},{0,-1,0})
        testing.expectf(t,ok && hit.point.y==excavated,"reading the zone again keeps its edits (%d threads): %v",threads,hit.point)
        testing.expect_value(t,source_value(&w.data.entries[0].source,at) or_else 0,dug)
        // Saving writes every block, those in memory and those in blocks of their own or in the file.
        request_save(&w.terrain_requests,owner,fmt.tprintf("%s/saved.terrain",root))
        pipeline_tick(&w,&resident,&app,settings)
        saved:Source;defer source_destroy(&saved)
        _,loaded:=source_load(&saved,fmt.tprintf("%s/saved.terrain",root),&assets.types)
        testing.expect(t,loaded && (source_value(&saved,at) or_else 0)==dug && (source_value(&saved,{110,10,110}) or_else 0)<0)
        testing.expect_value(t,w.problems.count,0)
        for &p in core.problems_list(&w.problems) {fmt.println(core.problem_text(&p))}
    }
}

@(test)
reading_a_paged_source_again_keeps_the_pages_its_file_still_holds :: proc(t:^testing.T) {
    root:=base.test_folder(t,"terrain")
    id:=base.Asset_Id{309,310}
    pipeline_source(t,root,.Heightfield,{129,1,129},16,id,bumpy=true)
    assets:host.Assets;testing.expect(t,host.assets_init(&assets,{root=root,capacity=16}));defer host.assets_destroy(&assets)
    first,second:Source;defer source_destroy(&first);defer source_destroy(&second)
    testing.expect(t,terrain_read(&first,&assets,id,paged=true))
    testing.expect(t,source_paged(&first) && grid_dense(&first.field)==0)
    testing.expect(t,source_region_read(&first,{0,0,0},{70,0,70}))
    held:=grid_dense(&first.field)
    testing.expect(t,held==4*PAGE*PAGE)
    testing.expect(t,grid_put(&first.field,{2,0,2},5,first.allocator))
    testing.expect(t,terrain_read(&second,&assets,id,paged=true))
    change,ok:=source_compare(&second,&first)
    testing.expect(t,ok && change.changed && change.low.x==0 && change.high.x==PAGE-1 && change.high.z==PAGE-1,"only the edited page differs from the file")
    testing.expect_value(t,grid_dense(&second.field),held-PAGE*PAGE)
}

// The coarse data comes from the file without a page in memory, as measuring
// the samples gives it, and taking a layer away rewrites the pages in their
// blocks without keeping them.
@(test)
a_paged_heightfield_reads_its_coarse_data_and_loses_a_layer_without_holding_its_pages :: proc(t:^testing.T) {
    root:=base.test_folder(t,"terrain")
    id:=base.Asset_Id{313,314}
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    {
        source:Source;defer source_destroy(&source)
        testing.expect(t,source_make(&source,.Heightfield,{129,1,97},1,16))
        testing.expect(t,source_layer_set(&source,1,LAYER_DEFAULT) && source_layer_set(&source,2,LAYER_DEFAULT))
        for z in 0..<97 {for x in 0..<129 {
            testing.expect(t,source_set(&source,{x,0,z},pipeline_bump(x,z)))
            a:=u8((x*7+z*3)%150)
            testing.expect(t,grid_put(&source.weights,{x,0,z},Weights{255-a-u8(z),a,u8(z),0},source.allocator))
        }}
        testing.expect_value(t,source_save(&source,fmt.tprintf("%s/source.terrain",root),id,&types),asset.Error.None)
    }
    assets:host.Assets;testing.expect(t,host.assets_init(&assets,{root=root,capacity=16}));defer host.assets_destroy(&assets)
    paged,whole:Source;defer source_destroy(&paged);defer source_destroy(&whole)
    testing.expect(t,terrain_read(&paged,&assets,id,paged=true))
    testing.expect(t,coarse_ready(&paged) && grid_dense(&paged.field)==0 && grid_dense(&paged.weights)==0,"the coarse data reads no page")
    _,loaded:=source_load(&whole,fmt.tprintf("%s/source.terrain",root),&types)
    testing.expect(t,loaded && !coarse_ready(&whole) && source_coarse_build(&whole))
    same :: proc(t:^testing.T,a,b:^Source) {
        testing.expect(t,a.coarse.size==b.coarse.size && len(a.coarse.errors)==len(b.coarse.errors))
        for j in 0..<a.coarse.size.y {for i in 0..<a.coarse.size.x {
            testing.expect_value(t,grid_get(&a.coarse.heights,i,j),grid_get(&b.coarse.heights,i,j))
            testing.expect_value(t,grid_get(&a.coarse.weights,i,j),grid_get(&b.coarse.weights,i,j))
        }}
        for range,i in a.coarse.ranges {testing.expect(t,abs(range.x-b.coarse.ranges[i].x)<=HEIGHT_STEP && abs(range.y-b.coarse.ranges[i].y)<=HEIGHT_STEP)}
        for e,i in a.coarse.errors {
            testing.expect(t,abs(e.coarse-b.coarse.errors[i].coarse)<=HEIGHT_STEP)
            for level,l in e.levels {testing.expect(t,abs(level-b.coarse.errors[i].levels[l])<=HEIGHT_STEP)}
        }
    }
    same(t,&paged,&whole)
    testing.expect(t,source_layer_remove(&paged,1) && source_layer_remove(&whole,1))
    testing.expect(t,grid_dense(&paged.weights)==0 && paged.layer_count==2,"the pages it rewrote are not in memory")
    testing.expect(t,source_region_read(&paged,{},{128,0,96}))
    for z in 0..<97 {for x in 0..<129 {testing.expect_value(t,grid_value(&paged.weights,{x,0,z}),grid_value(&whole.weights,{x,0,z}))}}
    testing.expect(t,source_coarse_build(&whole))
    same(t,&paged,&whole)
}

@(test)
a_streamed_volume_past_its_budget_shows_nodes_in_place_of_its_far_chunks :: proc(t:^testing.T) {
    root:=base.test_folder(t,"terrain")
    id:=base.Asset_Id{311,312}
    pipeline_source(t,root,.Volume,{33,9,33},8,id)
    assets:host.Assets;testing.expect(t,host.assets_init(&assets,{root=root,capacity=64}));defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets,allocator=context.allocator}
    w:Terrain_Test_World
    if !terrain_test_world_init(t,&w) {return}
    defer terrain_test_world_free(&w)
    resident:Terrain_Resident;defer terrain_resident_free(&resident)
    owner:=pipeline_owner(&w,id)
    view:=core.VIEW_DEFAULT
    view.position,view.size={-16,0,-16},{64,64}
    settings:=Terrain_Settings{chunks=8,resident_distance=1000,lod_distance=-1}
    for _ in 0..<6 {pipeline_tick(&w,&resident,&app,settings,view)}
    o:=&resident.owners[0]
    chunks:=o.quad.first[1]
    visible,nodes:=0,0
    for node,i in o.nodes {if node.visible {visible+=1;if i>=chunks {nodes+=1}}}
    testing.expectf(t,visible<=8 && nodes>0 && visible>nodes,"%d pieces, %d of them nodes",visible,nodes)
    corner:=chunk_index(&w.data.entries[0].source,{0,0,0})
    testing.expect(t,o.nodes[corner].visible,"the nearest chunk shows")
    testing.expect(t,!o.nodes[chunks-1].visible,"the farthest shows in a node")
    testing.expect(t,core.problem_find(&w.problems,owner,"terrain.chunks_full")==nil)
}

// The heights of a bumpy source: no page of it is uniform.
@(private="file")
pipeline_bump :: proc "contextless" (x,z:int) -> f32 {return f32((x*7+z*3)%5)*0.125}
