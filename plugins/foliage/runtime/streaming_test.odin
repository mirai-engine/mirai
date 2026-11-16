package foliage

import "core:fmt"
import "core:os"
import "core:testing"
import "mirai:core"
import scene "mirai:engine/scene"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"
import physics "plugins:physics/runtime"

// coords_near finds every cell a source may keep resident, whatever the
// reaches and however many sources, without the cells far from all of them.
@(test)
the_cells_near_the_sources_are_found_by_rows_and_every_one_they_keep :: proc(t:^testing.T) {
    s:Source
    defer source_destroy(&s)
    for z:=i32(-40);z<=40;z+=2 {for x:=i32(-60);x<=60;x+=3 {source_cell(&s,{x,z},true)}}
    Case :: struct {points:[][3]f32,reach:f32,few:bool}
    cases:=[]Case{
        {{{100,0,50}},200,true},
        {{{100,0,50},{-900,0,-300}},150,true},
        {{{-5000,0,0}},10,true},     // far from every cell: none
        {{{0,0,0}},1e9,false},       // a reach past the whole foliage: every one
    }
    out:=make([dynamic]u32)
    defer delete(out)
    for c in cases {
        sources:scene.Streaming_Sources
        for p,i in c.points {sources.items[i]={position=p,ahead=p}}
        sources.count=len(c.points)
        near:=scene.sources_near(&sources,mm.MAT4_IDENTITY,c.reach)
        coords_near(s.cells[:],&near,&out)
        for i in 1..<len(out) {testing.expect(t,out[i-1]<out[i],"each once, in their order")}
        found:=0
        for &cell,k in s.cells {
            low,high:=cell_box(cell.coord)
            if scene.box_near(&near,low,high)>scene.RESIDENT_KEEP {continue}
            found+=1
            hit:=false
            for at in out {hit||=int(at)==k}
            testing.expectf(t,hit,"cell %v, which a source keeps, is found (%v)",cell.coord,c)
        }
        if c.few {testing.expectf(t,len(out)<=2*found+64 && len(out)<len(s.cells)/2,"%d found for %d near of %d",len(out),found,len(s.cells))}
    }
}

// The cells to build go nearest first while the instances of a frame last,
// each by the most it shows; one goes while any are left.
@(test)
cells_are_built_nearest_first_within_the_instances_of_a_frame :: proc(t:^testing.T) {
    s:Source
    defer source_destroy(&s)
    grass:=source_type_add(&s,"grass",{1,1})
    grass.density=1
    for x in 0..<4 {source_cell(&s,{i32(x),0},true).generate=true}
    instances,_:=cell_bound(&s,&s.cells[0],1)
    testing.expect_value(t,instances,int(CELL_SIZE*CELL_SIZE)+1)
    Case :: struct {left,taken:int}
    for c in ([]Case{{2*instances,2},{2*instances-1,2},{2*instances+1,3},{1,1},{0,0}}) {
        builds:=[]scene.Resident_Order{{near=3,index=0},{near=0.5,index=1},{near=2,index=2},{near=0,index=3}}
        left:=c.left
        taken:=builds_take(builds,&s,1,&left)
        testing.expectf(t,taken==c.taken,"%v: %d taken",c,taken)
        testing.expect(t,builds[0].index==3 && builds[1].index==1 && builds[2].index==2,"nearest first")
    }
}

// Past CELL_GENERATED_MAX every type of a cell keeps the same share of its
// points, its first ones; thin keeps a share of those of the types without
// collision only, and 0 keeps none of them.
@(test)
a_cell_generates_at_most_its_cap_and_thin_keeps_the_first_points_of_what_does_not_collide :: proc(t:^testing.T) {
    s:Source
    defer source_destroy(&s)
    s.info.seed=5
    grass:=source_type_add(&s,"grass",{1,1})
    grass.density=200
    rock:=source_type_add(&s,"rock",{2,2})
    rock.density=200
    rock.collision,rock.size=.Box,{1,1,1}
    cell:=source_cell(&s,{1,-1},true)
    cell.generate=true
    share:=generated_share(&s)
    testing.expect(t,share<1 && share>0.6)
    work:Build_Work
    defer build_work_destroy(&work)
    count :: proc(placed:[]Placed,type:u32) -> (n:int) {
        for p in placed {if p.type==type {n+=1}}
        return
    }
    if !testing.expect(t,cell_build(&s,cell,{},&work)) {return}
    full_grass,full_rock:=count(work.placed[:],grass.id),count(work.placed[:],rock.id)
    testing.expect(t,len(work.placed)<=CELL_GENERATED_MAX+len(s.types),"no more than the cap")
    bound,_:=cell_bound(&s,cell,1)
    testing.expect(t,len(work.placed)<=bound,"no more than cell_bound")
    // The points kept are the first of the type, where they were.
    all:[dynamic]Generated
    defer delete(all)
    scatter(s.info.seed,cell.coord,s.types[0],&all)
    first:=work.placed[0]
    testing.expect(t,first.id==generated_id(grass.id,0) && abs(first.position.x-(all[0].position.x+CELL_SIZE))<1e-3)
    if !testing.expect(t,cell_build(&s,cell,{},&work,{},0.5)) {return}
    testing.expect(t,abs(count(work.placed[:],grass.id)-full_grass/2)<=1 && count(work.placed[:],rock.id)==full_rock)
    if !testing.expect(t,cell_build(&s,cell,{},&work,{},0)) {return}
    testing.expect(t,count(work.placed[:],grass.id)==0 && count(work.placed[:],rock.id)==full_rock)
}

// With a budget, the cells that collide are built nearest first and the
// rest wait for a later call without a body.
@(test)
the_collision_of_the_nearest_cells_is_built_first_within_its_budget :: proc(t:^testing.T) {
    w:physics.Physics_State
    if !testing.expect(t,physics.test_state_make(&w)) {return}
    defer physics.state_destroy(&w)
    s:Source
    defer source_destroy(&s)
    tree:=source_type_add(&s,"tree",{2,2})
    tree.collision,tree.size,tree.cull_distance,tree.fade_distance=.Capsule,{0.3,4,0},40,30
    for x in 0..<3 {source_instance_add(&s,tree.id,{f32(x)*CELL_SIZE+5,0,5},u32(mm.quat_pack(1,10)),{1,1})}
    for &cell,i in s.cells {cell.version=u32(i+1)}
    fp:Foliage_Physics
    defer core.value_free(&fp,type_info_of(Foliage_Physics))
    collision:physics.Collision_Settings
    sources:scene.Streaming_Sources
    sources.items[0]={position={2*CELL_SIZE+5,0,5},ahead={2*CELL_SIZE+5,0,5}}
    sources.count=1
    near:=scene.sources_near(&sources,mm.MAT4_IDENTITY,200)
    types:=make([dynamic]Type_Shape,context.temp_allocator)
    type_shapes(nil,nil,nil,nil,&s,nil,&types)
    budget:=Physics_Budget{instances=1}
    {complete,enough:=physics_owner_build(&fp,&w,&collision,7,&s,{scale={1,1,1},rotation=1},types[:],nil,true,nil,&near,&budget);testing.expect(t,complete && enough)}
    testing.expect(t,budget.waiting && int(w.world.body_count)==1 && fp.cells[2].body!={},"the nearest cell first")
    testing.expect(t,fp.cells[0].version==0 && fp.cells[0].body=={},"the others wait")
    for _ in 0..<2 {
        budget={instances=1}
        {complete,enough:=physics_owner_build(&fp,&w,&collision,7,&s,{scale={1,1,1},rotation=1},types[:],nil,false,nil,&near,&budget);testing.expect(t,complete && enough)}
    }
    testing.expect_value(t,int(w.world.body_count),3)
    budget={instances=1}
    {complete,enough:=physics_owner_build(&fp,&w,&collision,7,&s,{scale={1,1,1},rotation=1},types[:],nil,false,nil,&near,&budget);testing.expect(t,complete && enough)}
    testing.expect(t,!budget.waiting && budget.instances==1,"a stable call builds nothing")
}

@(private)
@(test_world)
Stroke_World :: struct {
    using world:Test_World,
    foliages:core.Table(Foliage),
}

// The cells of a stroke show over the file of their source, each taking the
// next version and the others keeping theirs, without reading the file; once
// the stroke is cleared the file is read again.
@(test)
the_cells_of_a_stroke_show_over_its_file_until_it_is_cleared :: proc(t:^testing.T) {
    root:=base.test_folder(t,"foliage-stroke")
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=root,capacity=8})) {return}
    defer host.assets_destroy(&assets)
    file:Source
    defer source_destroy(&file)
    file.info.seed=1
    moss:=source_type_add(&file,"moss",{2,2})
    for x in 0..<3 {source_instance_add(&file,moss.id,{f32(x)*CELL_SIZE+1,0,1},u32(mm.quat_pack(1,10)),{1,1})}
    id:=base.Asset_Id{91,92}
    bytes,_:=source_bytes(&file,id,&assets.types)
    _=os.write_entire_file(fmt.tprintf("%s/patch.foliage",root),bytes)
    delete(bytes)
    host.assets_scan(&assets)
    w:Stroke_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    core.add(&w.foliages,core.create(&w.entities),Foliage{source=id})
    test_world_settle(&w)
    data:Foliage_Data
    defer {for &entry in data.entries {source_destroy(&entry.source)};delete(data.entries)}
    stroke:Foliage_Stroke
    defer {stroke_clear(&stroke);delete(stroke.cells)}
    problems:core.Problems
    load :: proc(data:^Foliage_Data,w:^Stroke_World,stroke:^Foliage_Stroke,assets:^host.Assets,problems:^core.Problems) {
        foliage_load(data,core.read(&w.foliages),core.ref(stroke),assets,context.allocator,problems)
    }
    load(&data,&w,&stroke,&assets,&problems)
    if !testing.expect_value(t,len(data.entries),1) {return}
    entry:=&data.entries[0]
    if !testing.expect_value(t,len(entry.source.cells),3) {return}
    versions:=[3]u32{entry.source.cells[0].version,entry.source.cells[1].version,entry.source.cells[2].version}
    reads:=data.stats.loads
    // A touch adds an instance to the first cell and takes the second away.
    source_instance_add(&file,moss.id,{3,0,3},u32(mm.quat_pack(1,10)),{1,1})
    stroke.source,stroke.instances=id,file.info.instances
    testing.expect(t,stroke_cell_set(&stroke,{0,0},source_cell(&file,{0,0}),true))
    testing.expect(t,stroke_cell_set(&stroke,{1,0},nil,true))
    testing.expect(t,stroke_cell_set(&stroke,{9,9},nil,false) && len(stroke.cells)==2,"where nothing is or was, nothing is held")
    stroke.revision+=1
    loads:=entry.loads
    load(&data,&w,&stroke,&assets,&problems)
    testing.expect_value(t,data.stats.loads,reads)
    testing.expect(t,entry.loads>loads && len(entry.source.cells)==2)
    testing.expect(t,len(entry.source.cells[0].manual)==2 && entry.source.cells[0].version>versions[2],"the cell changed takes the next version")
    testing.expect(t,entry.source.cells[1].coord==[2]i32{2,0} && entry.source.cells[1].version==versions[2],"the others keep theirs")
    loads=entry.loads
    load(&data,&w,&stroke,&assets,&problems)
    testing.expect_value(t,entry.loads,loads)
    // Cleared, the file is what shows.
    stroke_clear(&stroke)
    load(&data,&w,&stroke,&assets,&problems)
    testing.expect(t,data.stats.loads==reads+1 && len(entry.source.cells)==3 && len(entry.source.cells[0].manual)==1)
    testing.expect_value(t,entry.source.cells[2].version,versions[2])
}
