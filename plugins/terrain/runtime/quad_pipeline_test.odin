package terrain

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import phys "plugins:physics/runtime"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/jobs"

// One call of terrain_update and the physics after it, with the one
// streaming source at viewer when it is given.
@(private="file")
quad_tick :: proc(w:^Terrain_Test_World,resident:^Terrain_Resident,app:^host.App,settings:Terrain_Settings,view:=core.View{}) {
    if w.settings=={} {w.settings={bodies=256,shapes=256,contacts=64,joints=1,characters=1,hulls=1,meshes=256,heightfields=256}}
    test_step(&w.terrain,core.commands_of(test_world_ref(&w.w)),resident,app,&w.problems,settings,view=view)
    test_world_settle(&w.w)
    terrain_test_physics(w,app)
    test_world_settle(&w.w)
}

@(private="file")
quad_viewer :: proc(w:^Terrain_Test_World,position:[3]f32) {
    if w.streaming.count==1 && w.streaming.items[0].position==position {return}
    w.streaming.items[0]={position,position,0}
    w.streaming.count=1
    w.streaming.revision+=1
}

@(private="file")
quad_settle :: proc(w:^Terrain_Test_World,resident:^Terrain_Resident,app:^host.App,settings:Terrain_Settings,view:=core.View{},ticks:=32) {
    for _ in 0..<ticks {
        quad_tick(w,resident,app,settings,view)
        idle:=!work_busy(&w.data,nil)
        for &source in resident.sources {if len(source.pending)>0 {idle=false}}
        if idle {break}
    }
    quad_tick(w,resident,app,settings,view)
}

// How many chunks of an owner no piece it shows covers, and how many more than one does.
@(private="file")
quad_coverage :: proc(owner:^Resident_Owner) -> (holes,overlaps:int) {
    q:=&owner.quad
    count:=make([]int,q.first[1],context.temp_allocator)
    for node,i in owner.nodes {
        if !node.visible {continue}
        a,b:=quad_chunks(q,i)
        for z in a.y..<b.y {for x in a.x..<b.x {count[x+q.counts[0].x*z]+=1}}
    }
    for c in count {if c==0 {holes+=1} else if c>1 {overlaps+=1}}
    return
}

@(private="file")
quad_bump :: proc "contextless" (x,z:int) -> f32 {return f32((x*7+z*3)%5)*0.125}

@(private="file")
quad_source :: proc(t:^testing.T,root:string,samples,cells:int,id:base.Asset_Id,base_height:f32=0) {
    source:Source;testing.expect(t,source_make(&source,.Heightfield,{samples,1,samples},1,cells));defer source_destroy(&source)
    for z in 0..<samples {for x in 0..<samples {testing.expect(t,source_set(&source,{x,0,z},base_height+quad_bump(x,z)))}}
    source.revision=1
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    testing.expect_value(t,source_save(&source,fmt.tprintf("%s/source.terrain",root),id,&types),asset.Error.None)
}

@(private="file")
quad_owner :: proc(w:^Terrain_Test_World,id:base.Asset_Id,position:[3]f32={}) -> core.Entity {
    owner:=core.create(&w.entities)
    place:=core.TRANSFORM_IDENTITY
    place.position=position
    core.add(&w.transforms,owner,place)
    core.add(&w.worlds,owner,core.World_Transform{transform={position=place.position,rotation=place.rotation,scale=place.scale}})
    core.add(&w.terrains,owner,Terrain{source=id,solid=true})
    test_world_settle(&w.w)
    return owner
}

// A streamed Heightfield shows its far chunks as nodes of its quadtree: the
// terrain covers its region once at every tick as the viewer crosses it.
@(test)
a_streamed_terrain_never_disappears_far_away_and_covers_itself_once_as_the_viewer_crosses :: proc(t:^testing.T) {
    root:=base.test_folder(t,"terrain")
    id:=base.Asset_Id{321,322}
    quad_source(t,root,257,16,id)
    counter:=Terrain_Test_Allocator{owner=runtime.heap_allocator()}
    context.allocator={terrain_test_allocator,&counter}
    assets:host.Assets;testing.expect(t,host.assets_init(&assets,{root=root,capacity=1024}));defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets,allocator=context.allocator}
    w:Terrain_Test_World
    if !terrain_test_world_init(t,&w) {return}
    defer terrain_test_world_free(&w)
    resident:Terrain_Resident;defer terrain_resident_free(&resident)
    quad_owner(&w,id)
    settings:=Terrain_Settings{resident_distance=40}
    corner:=[3]f32{-110,0,-110}
    quad_viewer(&w,corner)
    quad_settle(&w,&resident,&app,settings)
    o:=&resident.owners[0]
    holes,overlaps:=quad_coverage(o)
    testing.expect(t,holes==0 && overlaps==0,"the terrain covers its region once")
    nodes,chunks:=0,0
    for node,i in o.nodes {
        if !node.visible {continue}
        if i<o.quad.first[1] {chunks+=1} else {nodes+=1}
    }
    testing.expectf(t,nodes>0 && chunks>0 && chunks<64,"chunks near the viewer, nodes far from it: %d and %d",chunks,nodes)
    testing.expect(t,resident.sources[0].chunks[quad_total(&o.quad)-1].shown,"the root of a streamed source stays built")
    testing.expect_value(t,len(w.statics.values),nodes+chunks)
    s:=&w.data.entries[0].source
    testing.expect(t,grid_dense(&s.field)<len(s.field.pages)*PAGE*PAGE/2,"the pages far from the viewer are not in memory")
    hit,ok:=phys.raycast({&w.state},corner+{0,20,0},{0,-1,0})
    testing.expect(t,ok && abs(hit.point.y)<1)
    hit,ok=phys.raycast({&w.state},{110,20,110},{0,-1,0})
    testing.expect(t,ok && piece_depth(&w,hit)>0,"far ground collides with its node")
    // A frame that changes nothing builds and allocates nothing.
    calls,built:=counter.requests,resident.stats.built
    for _ in 0..<5 {quad_tick(&w,&resident,&app,settings)}
    testing.expect_value(t,counter.requests,calls)
    testing.expect_value(t,resident.stats.built,built)
    // The viewer crosses to the far corner: at every tick the terrain covers itself once.
    for step in 1..=8 {
        at:=corner+[3]f32{1,0,1}*f32(step)*27.5
        quad_viewer(&w,at)
        for _ in 0..<3 {
            quad_tick(&w,&resident,&app,settings)
            holes,overlaps=quad_coverage(&resident.owners[0])
            testing.expectf(t,holes==0 && overlaps==0,"at %v: %d chunks without a piece and %d with more than one",at,holes,overlaps)
        }
    }
    quad_settle(&w,&resident,&app,settings)
    hit,ok=phys.raycast({&w.state},{110,20,110},{0,-1,0})
    testing.expect(t,ok,"the chunks near the viewer collide")
    hit,ok=phys.raycast({&w.state},corner+{0,20,0},{0,-1,0})
    testing.expect(t,ok && piece_depth(&w,hit)>0,"the corner it left collides with its node")
    testing.expect_value(t,w.problems.count,0)
}

// A chunk of a terrain far above 0 is resident near a viewer before it is
// built: its distance takes the heights of its samples.
@(test)
an_elevated_chunk_becomes_resident_near_a_viewer_before_it_is_built :: proc(t:^testing.T) {
    root:=base.test_folder(t,"terrain")
    id:=base.Asset_Id{323,324}
    quad_source(t,root,129,16,id,800)
    assets:host.Assets;testing.expect(t,host.assets_init(&assets,{root=root,capacity=256}));defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets,allocator=context.allocator}
    w:Terrain_Test_World
    if !terrain_test_world_init(t,&w) {return}
    defer terrain_test_world_free(&w)
    resident:Terrain_Resident;defer terrain_resident_free(&resident)
    quad_owner(&w,id)
    quad_viewer(&w,{0,801,0})
    settings:=Terrain_Settings{resident_distance=30}
    quad_tick(&w,&resident,&app,settings)
    for range in w.data.entries[0].source.coarse.ranges {testing.expect(t,range.x>=800 && range.y<=801)}
    quad_settle(&w,&resident,&app,settings)
    hit,ok:=phys.raycast({&w.state},{0,900,0},{0,-1,0})
    testing.expectf(t,ok && abs(hit.point.y-800)<1,"a viewer standing on it has ground: %v",hit.point)
    near:=0
    for node in resident.owners[0].nodes[:64] {if node.cut {near+=1}}
    testing.expect(t,near>0 && near<64)
}

// Without resident distance, past Terrain_Settings.chunks the far chunks show
// as coarser nodes, nearest first: nothing goes, whatever their index.
@(test)
past_the_chunk_budget_far_chunks_show_as_nodes_by_distance_not_by_index :: proc(t:^testing.T) {
    root:=base.test_folder(t,"terrain")
    id:=base.Asset_Id{325,326}
    quad_source(t,root,129,16,id)
    assets:host.Assets;testing.expect(t,host.assets_init(&assets,{root=root,capacity=256}));defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets,allocator=context.allocator}
    w:Terrain_Test_World
    if !terrain_test_world_init(t,&w) {return}
    defer terrain_test_world_free(&w)
    resident:Terrain_Resident;defer terrain_resident_free(&resident)
    owner:=quad_owner(&w,id)
    view:=core.VIEW_DEFAULT
    // The far corner: the chunks of the highest indices are the nearest.
    view.position,view.size={60,5,60},{64,64}
    settings:=Terrain_Settings{chunks=20}
    quad_settle(&w,&resident,&app,settings,view)
    o:=&resident.owners[0]
    holes,overlaps:=quad_coverage(o)
    testing.expect(t,holes==0 && overlaps==0,"nothing goes")
    visible,chunks:=0,0
    for node,i in o.nodes {if node.visible {visible+=1;if i<64 {chunks+=1}}}
    testing.expectf(t,visible<=20 && chunks>0,"%d pieces, %d chunks",visible,chunks)
    testing.expect(t,o.nodes[63].visible,"the nearest chunk shows")
    testing.expect(t,!o.nodes[0].visible,"the farthest shows in a node")
    testing.expect_value(t,len(w.statics.values),visible)
    // The far ground collides with the triangles its node shows: a long ray from the view stops on it.
    hit,ok:=phys.raycast({&w.state},view.position,linalg.normalize([3]f32{-57,0,-57}-view.position),400)
    testing.expectf(t,ok && piece_depth(&w,hit)>0 && hit.point.x<-30 && hit.point.y>-0.01 && hit.point.y<0.51,"the ray hits the node of the far corner: %v",hit.point)
    testing.expect(t,core.problem_find(&w.problems,owner,"terrain.chunks_full")==nil)
    // The view moves to the other corner: the nodes open there.
    view.position={-60,5,-60}
    quad_settle(&w,&resident,&app,settings,view)
    holes,overlaps=quad_coverage(o)
    testing.expect(t,holes==0 && overlaps==0)
    testing.expect(t,o.nodes[0].visible && !o.nodes[63].visible)
}

// The world of the plan in small: 64 terrains of one source, 8 by 8, streamed
// around a viewer. Each covers itself once; the far ones show their roots;
// the colliders are those of the nearest chunks; a frame that changes
// nothing allocates nothing.
@(test)
sixty_four_terrains_of_one_source_stream_without_holes_caps_or_allocations :: proc(t:^testing.T) {
    root:=base.test_folder(t,"terrain")
    id:=base.Asset_Id{327,328}
    quad_source(t,root,129,16,id)
    counter:=Terrain_Test_Allocator{owner=runtime.heap_allocator()}
    context.allocator={terrain_test_allocator,&counter}
    assets:host.Assets;testing.expect(t,host.assets_init(&assets,{root=root,capacity=8192}));defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets,allocator=context.allocator}
    testing.expect(t,jobs.system_init(&app.jobs,{threads=3,allocator=runtime.heap_allocator()}))
    defer jobs.system_destroy(&app.jobs)
    w:Terrain_Test_World
    if !terrain_test_world_init(t,&w) {return}
    defer terrain_test_world_free(&w)
    resident:Terrain_Resident;defer terrain_resident_free(&resident)
    for k in 0..<64 {quad_owner(&w,id,{f32(k%8)*128,0,f32(k/8)*128})}
    settings:=Terrain_Settings{resident_distance=60}
    viewer:=[3]f32{448,0,448}
    quad_viewer(&w,viewer)
    quad_settle(&w,&resident,&app,settings,ticks=64)
    testing.expect_value(t,len(w.data.entries),1)
    testing.expect_value(t,len(resident.owners),64)
    pieces,roots:=0,0
    for &o in resident.owners {
        holes,overlaps:=quad_coverage(&o)
        testing.expectf(t,holes==0 && overlaps==0,"terrain %v: %d chunks without a piece, %d with more",o.entity,holes,overlaps)
        for node in o.nodes {if node.visible {pieces+=1}}
        if o.nodes[quad_total(&o.quad)-1].visible {roots+=1}
    }
    testing.expectf(t,roots>32,"the far terrains show their roots: %d",roots)
    testing.expectf(t,pieces<64*64/4,"far from the viewer a terrain is a few pieces: %d",pieces)
    testing.expect_value(t,len(w.statics.values),pieces)
    testing.expect(t,len(w.colliders.values)>0 && len(w.colliders.values)<=256)
    hit,ok:=phys.raycast({&w.state},viewer+{0,20,0},{0,-1,0})
    testing.expect(t,ok && abs(hit.point.y)<1,"the viewer stands on ground")
    for &p in core.problems_list(&w.problems) {testing.expectf(t,false,"%s",core.problem_text(&p))}
    calls,built:=counter.requests,resident.stats.built
    for _ in 0..<5 {quad_tick(&w,&resident,&app,settings)}
    testing.expect_value(t,counter.requests,calls)
    testing.expect_value(t,resident.stats.built,built)
    // The viewer walks 300 m: every terrain covers itself once at every tick.
    for step in 1..=10 {
        quad_viewer(&w,viewer+[3]f32{30,0,0}*f32(step))
        quad_tick(&w,&resident,&app,settings)
        for &o in resident.owners {
            holes,overlaps:=quad_coverage(&o)
            testing.expectf(t,holes==0 && overlaps==0,"step %d, terrain %v: %d chunks without a piece, %d with more",step,o.entity,holes,overlaps)
        }
    }
}

// A node chosen by its error opens and closes within LOD_HYSTERESIS of its
// spacing too: wherever the view stops, from near to far, choosing the levels
// again keeps what was chosen, and a still view builds nothing. Chunks of 63
// cells, as imported landscapes have, do not line up with the pages.
@(test)
a_still_view_builds_nothing_once_settled_at_any_distance_for_chunks_of_odd_cells :: proc(t:^testing.T) {
    root:=base.test_folder(t,"terrain")
    id:=base.Asset_Id{333,334}
    samples:=253
    {
        source:Source;testing.expect(t,source_make(&source,.Heightfield,{samples,1,samples},1,63));defer source_destroy(&source)
        for z in 0..<samples {for x in 0..<samples {testing.expect(t,source_set(&source,{x,0,z},10*math.sin(f32(x)*0.37)*math.cos(f32(z)*0.29)))}}
        source.revision=1
        types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
        testing.expect_value(t,source_save(&source,fmt.tprintf("%s/source.terrain",root),id,&types),asset.Error.None)
    }
    assets:host.Assets;testing.expect(t,host.assets_init(&assets,{root=root,capacity=1024}));defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets,allocator=context.allocator}
    w:Terrain_Test_World
    if !terrain_test_world_init(t,&w) {return}
    defer terrain_test_world_free(&w)
    resident:Terrain_Resident;defer terrain_resident_free(&resident)
    // Without colliders no chunk is needed: the error and the spacing alone open the nodes.
    core.edit(&w.terrains,quad_owner(&w,id)).solid=false
    view:=core.VIEW_DEFAULT
    view.size={1440,900}
    opened,closed:=false,false
    for height:=f32(100);height<4000;height*=1.03 {
        view.position={0,height,0}
        quad_settle(&w,&resident,&app,{},view)
        built:=resident.stats.built
        // Whatever else asks for the levels again, as other pieces arriving do.
        for _ in 0..<4 {resident.marks+=1;quad_tick(&w,&resident,&app,{},view)}
        testing.expectf(t,resident.stats.built==built,"%v m above: %d pieces built with the view still",height,resident.stats.built-built)
        o:=&resident.owners[0]
        if o.nodes[o.quad.first[1]].open {opened=true} else {closed=true}
    }
    testing.expect(t,opened && closed,"the sweep crosses the distance where the nodes close")
    testing.expect_value(t,w.problems.count,0)
}

// Choosing what a terrain shows walks its tree from the roots and goes down
// only where it is near or seen finer: a large terrain seen from above one
// corner looks at a small part of its nodes, wherever the corner is.
@(test)
choosing_the_pieces_of_a_large_terrain_looks_at_what_is_near_not_at_every_node :: proc(t:^testing.T) {
    root:=base.test_folder(t,"terrain")
    id:=base.Asset_Id{335,336}
    samples:=1025
    {
        source:Source;testing.expect(t,source_make(&source,.Heightfield,{samples,1,samples},1,4));defer source_destroy(&source)
        for z in 0..<samples {for x in 0..<samples {testing.expect(t,source_set(&source,{x,0,z},2*math.sin(f32(x)*0.013)*math.cos(f32(z)*0.011)))}}
        source.revision=1
        types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
        testing.expect_value(t,source_save(&source,fmt.tprintf("%s/source.terrain",root),id,&types),asset.Error.None)
    }
    assets:host.Assets;testing.expect(t,host.assets_init(&assets,{root=root,capacity=8192}));defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets,allocator=context.allocator}
    w:Terrain_Test_World
    if !terrain_test_world_init(t,&w) {return}
    defer terrain_test_world_free(&w)
    resident:Terrain_Resident;defer terrain_resident_free(&resident)
    quad_owner(&w,id)
    view:=core.VIEW_DEFAULT
    view.size={1440,900}
    nodes:=0
    looked:[2]u32
    for corner,k in ([2][3]f32{{-500,20,-500},{480,20,470}}) {
        view.position=corner
        quad_settle(&w,&resident,&app,{},view)
        // Chosen again once what the corner before showed has gone.
        for _ in 0..<2 {resident.marks+=1;quad_tick(&w,&resident,&app,{},view)}
        looked[k]=resident.stats.visited
        nodes=len(resident.owners[0].nodes)
        holes,overlaps:=quad_coverage(&resident.owners[0])
        testing.expectf(t,holes==0 && overlaps==0,"%d chunks without a piece, %d with more",holes,overlaps)
    }
    testing.expectf(t,int(looked[0])*10<nodes && int(looked[1])*10<nodes,"%v of %d nodes looked at",looked,nodes)
    testing.expect_value(t,w.problems.count,0)
}

// A terrain that opens under a view builds in its first tick only what has
// to be there: its root, from the coarse grid of its file, which collides
// while it stands in, so neither the view nor a body lacks ground, and what
// the ground under the body needs to show. Its other pieces come from jobs
// over the ticks that follow, and in every tick the terrain covers its
// region once.
@(test)
a_terrain_that_opens_builds_its_root_and_the_ground_under_bodies_at_once_and_the_rest_in_jobs :: proc(t:^testing.T) {
    root:=base.test_folder(t,"terrain")
    id:=base.Asset_Id{331,332}
    quad_source(t,root,129,16,id)
    assets:host.Assets;testing.expect(t,host.assets_init(&assets,{root=root,capacity=256}));defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets,allocator=context.allocator}
    w:Terrain_Test_World
    if !terrain_test_world_init(t,&w) {return}
    defer terrain_test_world_free(&w)
    resident:Terrain_Resident;defer terrain_resident_free(&resident)
    quad_owner(&w,id)
    body:=core.create(&w.entities)
    at:=[3]f32{-50,2,-50}
    placed:=core.TRANSFORM_IDENTITY
    placed.position=at
    core.add(&w.transforms,body,placed)
    core.add(&w.worlds,body,core.World_Transform{transform={position=placed.position,rotation=placed.rotation,scale=placed.scale}})
    core.add(&w.rigids,body,phys.Rigid_Body{type=.Dynamic})
    test_world_settle(&w.w)
    view:=core.VIEW_DEFAULT
    view.position,view.size={40,6,40},{64,64}
    settings:=Terrain_Settings{}
    quad_tick(&w,&resident,&app,settings,view)
    o:=&resident.owners[0]
    holes,overlaps:=quad_coverage(o)
    testing.expectf(t,holes==0 && overlaps==0,"the first tick covers the region once: %d chunks without a piece, %d with more",holes,overlaps)
    testing.expect(t,resident.sources[0].chunks[quad_total(&o.quad)-1].shown,"the root shows in the first tick")
    hit,ok:=phys.raycast({&w.state},at+{0,20,0},{0,-1,0})
    testing.expect(t,ok && piece_depth(&w,hit)>=0 && abs(hit.point.y)<1,"the body has ground in the first tick")
    first:=resident.stats.built
    testing.expectf(t,first<16,"the rest comes from jobs: %d pieces built in the first tick",first)
    for _ in 0..<32 {
        quad_tick(&w,&resident,&app,settings,view)
        holes,overlaps=quad_coverage(&resident.owners[0])
        testing.expectf(t,holes==0 && overlaps==0,"every tick covers the region once: %d and %d",holes,overlaps)
    }
    testing.expect(t,resident.stats.built>first+16,"the pieces the view wants arrived")
    testing.expect(t,!resident.owners[0].nodes[quad_total(&o.quad)-1].visible,"the root gave way to them")
    testing.expect_value(t,w.problems.count,0)
}
