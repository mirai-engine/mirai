package host

import "base:runtime"
import "core:fmt"
import "core:testing"
import "core:thread"
import "mirai:asset"
import "mirai:core"
import "mirai:render"
import "mirai:std/base"
import "mirai:std/jobs"
import mm "mirai:std/math"

// Three loads share a frame: each gets a part of what the ones before it
// left; one whose next asset does not fit its part, having taken nothing,
// gets the next frame alone, and the others wait it out.
@(test)
loads_share_each_frame_and_one_that_does_not_fit_gets_the_next_alone :: proc(t:^testing.T) {
    a:Assets
    loads:[3]u64
    for &load in loads {load=assets_load_open(&a)}
    first:=assets_load_share(&a,1,loads[0])
    testing.expect_value(t,first.bytes,LOAD_FRAME_BYTES/3)
    assets_load_spend(&a,0,first.bytes/2)
    second:=assets_load_share(&a,1,loads[1])
    testing.expect_value(t,second.bytes,(LOAD_FRAME_BYTES-first.bytes/2)/2)
    // The third takes nothing: its next asset is larger than its part.
    third:=assets_load_share(&a,1,loads[2])
    testing.expect(t,!third.alone && third.bytes<LOAD_FRAME_BYTES)
    assets_load_alone(&a,loads[2])
    assets_load_alone(&a,loads[0])
    testing.expect_value(t,a.loads.alone,loads[2])

    // The next frame is the third's: the others get nothing before it.
    testing.expect_value(t,assets_load_share(&a,2,loads[0]),Load_Share{})
    alone:=assets_load_share(&a,2,loads[2])
    testing.expect(t,alone.alone && alone.bytes==LOAD_FRAME_BYTES)
    assets_load_spend(&a,0,LOAD_FRAME_BYTES*2)
    testing.expect_value(t,assets_load_share(&a,2,loads[1]).bytes,0)
    // And the frame after is shared again.
    testing.expect_value(t,assets_load_share(&a,3,loads[1]).bytes,LOAD_FRAME_BYTES/3)
    for load in loads {assets_load_close(&a,load)}
    testing.expect_value(t,a.loads.loads,0)
}

// A load with nothing on the screen to keep smooth takes far more of each
// frame than the part of any other, and gives it back when it closes.
@(test)
a_load_with_the_whole_frame_takes_more_than_a_shared_part :: proc(t:^testing.T) {
    a:Assets
    load:=assets_load_open(&a)
    shared:=assets_load_share(&a,1,load)
    assets_load_whole(&a,load)
    whole:=assets_load_share(&a,2,load)
    testing.expect(t,whole.seconds>shared.seconds*10 && whole.bytes==LOAD_FRAME_BYTES)
    // What it took of the frame counts.
    assets_load_spend(&a,LOAD_WHOLE_FRAME_SECONDS,0)
    testing.expect_value(t,assets_load_share(&a,2,load).seconds,0)
    assets_load_close(&a,load)
    testing.expect_value(t,a.loads.whole,0)
}

// A mesh larger than the bytes of a frame, read and checked on another
// thread and given to the assets on this one, loads as asking for it would;
// one whose file changed after it was read is left to whoever asks for it.
// Taken over frames it costs its frame nothing: the renderer sends its
// geometry with the frames that follow.
@(test)
a_mesh_prepared_on_another_thread_loads_as_asking_for_it :: proc(t:^testing.T) {
    root:=base.test_folder(t,"prepared")
    if root=="" {return}
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    COUNT :: LOAD_FRAME_BYTES/size_of(asset.Cluster_Vertex)+1024
    vertices:=make([]asset.Vertex,COUNT)
    defer delete(vertices)
    indices:=make([]u32,COUNT-COUNT%3)
    defer delete(indices)
    for &v,i in vertices {v={position={f32(i%1000),f32(i/1000),0},normal=mm.normal_pack({0,0,1})}}
    for &index,i in indices {index=u32(i)}
    BIG :: base.Asset_Id{0x6c6f6164,1}
    SMALL :: base.Asset_Id{0x6c6f6164,2}
    testing.expect_value(t,mesh_save_test(fmt.tprintf("%s/big.mesh",root),&types,BIG,vertices,indices),asset.Error.None)
    testing.expect_value(t,mesh_save_test(fmt.tprintf("%s/small.mesh",root),&types,SMALL,vertices[:3],indices[:3]),asset.Error.None)
    a:Assets
    if !testing.expect(t,assets_init(&a,{root=root,capacity=8})) {return}
    defer assets_destroy(&a)

    Work :: struct {prepared:[2]Assets_Prepared,limits:Assets_Limits}
    work:Work
    for &prepared,i in work.prepared {
        source,found:=assets_source(&a,i==0?BIG:SMALL,runtime.heap_allocator())
        if !testing.expect(t,found) {return}
        prepared.source=source
    }
    work.limits=assets_limits(&a)
    worker:=thread.create_and_start_with_poly_data(&work,proc(work:^Work) {
        types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
        for &prepared in work.prepared {assets_prepare(&prepared,work.limits,&types)}
    })
    thread.join(worker)
    thread.destroy(worker)
    defer {for &prepared in work.prepared {assets_prepared_free(&prepared)}}
    big:=&work.prepared[0]
    testing.expect(t,big.ok && big.cost>LOAD_FRAME_BYTES)
    testing.expect(t,!assets_prepared_split(big),"read for no renderer, it goes whole")
    big.renderer=true
    testing.expect(t,assets_prepared_split(big) && assets_prepared_cost(big)==big.cost)
    testing.expect_value(t,assets_prepared_cost(big,over_frames=true),0)
    big.renderer=false
    small:=&work.prepared[1]
    small.renderer=true
    testing.expect(t,!assets_prepared_split(small) && assets_prepared_cost(small,over_frames=true)==small.cost)
    assets_take(&a,big)
    testing.expect(t,assets_loaded(&a,BIG))
    mesh:=assets_mesh(&a,BIG)
    testing.expect(t,mesh!=nil && !mesh.failed && mesh.vertex_count==COUNT-COUNT%3)
    testing.expect_value(t,a.stats.loads,1)

    // The file changed after the job read it: what is taken is not that.
    testing.expect_value(t,mesh_save_test(fmt.tprintf("%s/small.mesh",root),&types,SMALL,vertices[3:6],indices[:3]),asset.Error.None)
    testing.expect(t,assets_refresh(&a,{"small.mesh"}))
    assets_take(&a,&work.prepared[1])
    testing.expect(t,!assets_loaded(&a,SMALL))
}

// A load waits while the geometry of a mesh it took over frames goes to the
// GPU, and what it read stays for the renderer to copy from; what the
// renderer no longer sends, or a renderer that is not there, leaves it.
@(test)
a_load_waits_for_the_geometry_of_the_meshes_it_took_over_frames :: proc(t:^testing.T) {
    app:=App{allocator=context.allocator}
    defer app_assets_releases_stop(&app)
    testing.expect(t,!app_assets_uploading(&app))
    app.asset_releases.uploading=make([dynamic]Assets_Prepared)
    append(&app.asset_releases.uploading,Assets_Prepared{kind=.Mesh,mesh_upload={mesh=1,serial=1}})
    testing.expect(t,app_assets_uploading(&app))
    app_assets_releases_step(&app)
    testing.expect(t,!app_assets_uploading(&app) && len(app.asset_releases.uploading)==0)
}

@(private="file") Building_Model :: struct {mesh:base.Asset_Id}
@(private="file") Building_World :: struct {using world:core.Test_World,models:core.Table(Building_Model),plain:core.Table(core.Name)}

// A World a job builds is not read by the marks: what only it names unloads,
// and what it names counts once it is done. A table that never changed and
// one that holds no asset ids are not marked again.
@(test)
the_marks_leave_out_a_world_a_job_builds :: proc(t:^testing.T) {
    root:=base.test_folder(t,"building")
    if root=="" {return}
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    vertices:=[3]asset.Vertex{{position={0,0,0},normal=mm.normal_pack({0,1,0})},{position={1,0,0},normal=mm.normal_pack({0,1,0})},{position={0,0,1},normal=mm.normal_pack({0,1,0})}}
    meshes:=[2]base.Asset_Id{{0x6275696c,1},{0x6275696c,2}}
    for id,i in meshes {
        testing.expect_value(t,mesh_save_test(fmt.tprintf("%s/m%d.mesh",root,i),&types,id,vertices[:],{0,2,1}),asset.Error.None)
    }
    assets:Assets
    if !testing.expect(t,assets_init(&assets,{root=root,capacity=8})) {return}
    defer assets_destroy(&assets)

    info,described:=core.test_info(t,Building_World)
    if !described {return}
    defer core.test_info_destroy(&info)
    app:=App{info=&info,assets=&assets,allocator=context.allocator}
    app.worlds=make([dynamic]World_Slot)
    defer delete(app.worlds)
    defer assets_marks_free(&app.asset_marks)
    live:=cast(^Building_World)app_world_create(&app)
    built:=cast(^Building_World)app_world_create(&app)
    if !testing.expect(t,live!=nil && built!=nil) {return}
    defer {app_world_free(&app,live);app_world_free(&app,built)}
    for pair in ([2]struct{w:^Building_World,mesh:base.Asset_Id}{{live,meshes[0]},{built,meshes[1]}}) {
        e:=core.create(&pair.w.entities)
        core.add(&pair.w.models,e,Building_Model{pair.mesh})
        core.table_settle(&pair.w.models,&pair.w.entities)
        _=assets_mesh(&assets,pair.mesh)
    }
    app_assets_building(&app,built,true)
    app.seconds=1
    testing.expect_value(t,app_assets_mark(&app),1)
    testing.expect(t,assets_loaded(&assets,meshes[0]) && !assets_loaded(&assets,meshes[1]),"what only the World being built names goes")
    marks:=&app.asset_marks.worlds[0]
    testing.expect(t,marks.columns[0].marked && !marks.columns[1].marked,"a table without asset ids is not marked")
    _=assets_mesh(&assets,meshes[1])
    app_assets_building(&app,built,false)
    app.seconds+=ASSETS_MARK_SECONDS
    testing.expect_value(t,app_assets_mark(&app),0)
    testing.expect(t,assets_loaded(&assets,meshes[1]),"done, what it names counts")
    testing.expect_value(t,len(app.asset_marks.building),0)
}

// Saves a mesh of one level of vertices and indices, as an importer writes it.
@(private)
mesh_save_test :: proc(path:string,types:^asset.Types,id:base.Asset_Id,vertices:[]asset.Vertex,indices:[]u32,slots:[]asset.Material_Slot=nil,flags:asset.Mesh_Flags={}) -> asset.Error {
    g:asset.Mesh_Geometry
    if !asset.mesh_build({vertices=vertices,flags=flags},indices,nil,&g,context.temp_allocator) {return .Invalid}
    return asset.mesh_save(path,types,{id=id,geometry=g,slots=slots})
}

// A job reads the levels of a texture from the one asked for, and names the
// file as their source; what loads far away (tail) reads only the small ones.
@(test)
a_texture_is_read_from_the_level_asked_for :: proc(t:^testing.T) {
    root:=base.test_folder(t,"levels")
    if root=="" {return}
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    SIZE :: 512
    mips:=make([dynamic][]u8,context.temp_allocator)
    for side:=SIZE;;side/=2 {
        append(&mips,make([]u8,side*side*4,context.temp_allocator))
        if side==1 {break}
    }
    ID :: base.Asset_Id{0x6c6576,1}
    testing.expect_value(t,asset.texture_save(fmt.tprintf("%s/stone.tex",root),&types,{id=ID,width=SIZE,height=SIZE,format=.RGBA8,mips=mips[:]}),asset.Error.None)
    a:Assets
    if !testing.expect(t,assets_init(&a,{root=root,capacity=8})) {return}
    defer assets_destroy(&a)
    read :: proc(t:^testing.T,a:^Assets,types:^asset.Types,level:int,tail:bool) -> (first,levels:int,source:[2]int) {
        prepared:=Assets_Prepared{level=level}
        found:bool
        prepared.source,found=assets_source(a,ID,runtime.heap_allocator())
        if !testing.expect(t,found) {return}
        // As a renderer that takes every size, without blocks.
        assets_prepare(&prepared,{renderer=true,texture={max_size=4096},tail=tail},types)
        defer assets_prepared_free(&prepared)
        testing.expect(t,prepared.ok)
        data:=prepared.levels.data
        return data.level,len(data.levels),data.source
    }
    first,levels,source:=read(t,&a,&types,0,false)
    testing.expect(t,first==0 && levels==len(mips) && source=={SIZE,SIZE},"every level")
    first,levels,_=read(t,&a,&types,3,false)
    testing.expect(t,first==3 && levels==len(mips)-3,"from the one asked for")
    first,_,source=read(t,&a,&types,0,true)
    testing.expect(t,SIZE>>uint(first)==render.TEXTURE_TAIL && source=={SIZE,SIZE},"far away, from the side of the tail")
}

// A texture whose levels take more than the bytes of a frame splits when a
// load takes it over frames: in its frame it costs only its levels of side
// render.TEXTURE_TAIL, which fit the share of a load among others; taken at
// once, or far away with only its small levels, it costs what it reads.
@(test)
a_texture_larger_than_a_frame_costs_its_small_levels_in_the_frame_it_is_taken :: proc(t:^testing.T) {
    root:=base.test_folder(t,"split")
    if root=="" {return}
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    SIZE :: 2048
    mips:=make([dynamic][]u8,context.temp_allocator)
    for side:=SIZE;;side/=2 {
        append(&mips,make([]u8,side*side*4,context.temp_allocator))
        if side==1 {break}
    }
    ID :: base.Asset_Id{0x73706c74,1}
    testing.expect_value(t,asset.texture_save(fmt.tprintf("%s/wall.tex",root),&types,{id=ID,width=SIZE,height=SIZE,format=.RGBA8,mips=mips[:]}),asset.Error.None)
    a:Assets
    if !testing.expect(t,assets_init(&a,{root=root,capacity=8})) {return}
    defer assets_destroy(&a)
    prepare :: proc(t:^testing.T,a:^Assets,types:^asset.Types,tail:bool) -> (prepared:Assets_Prepared) {
        found:bool
        prepared.source,found=assets_source(a,ID,runtime.heap_allocator())
        testing.expect(t,found)
        assets_prepare(&prepared,{renderer=true,texture={max_size=4096},tail=tail},types)
        testing.expect(t,prepared.ok)
        return
    }
    near:=prepare(t,&a,&types,false)
    defer assets_prepared_free(&near)
    first:=render.texture_tail_first(near.levels.data)
    testing.expect_value(t,SIZE>>uint(first),render.TEXTURE_TAIL)
    small:=0
    for level in near.levels.data.levels[first:] {small+=len(level)}
    testing.expect(t,assets_prepared_split(&near) && near.cost>LOAD_FRAME_BYTES)
    testing.expect_value(t,assets_prepared_cost(&near),near.cost)
    testing.expect_value(t,assets_prepared_cost(&near,over_frames=true),small)
    // Among three loads its share holds it.
    loads:[3]u64
    for &load in loads {load=assets_load_open(&a)}
    share:=assets_load_share(&a,1,loads[0])
    testing.expect(t,assets_prepared_cost(&near,over_frames=true)<=share.bytes && near.cost>share.bytes)
    for load in loads {assets_load_close(&a,load)}

    far:=prepare(t,&a,&types,true)
    defer assets_prepared_free(&far)
    testing.expect(t,!assets_prepared_split(&far) && assets_prepared_cost(&far,over_frames=true)==far.cost,"its small levels alone go whole")
    // Data whose loader cannot read its levels again goes whole.
    plain:=near.levels.data
    plain.source={}
    testing.expect_value(t,render.texture_tail_first(plain),0)
    // Without a renderer there are no levels to give over frames.
    testing.expect_value(t,assets_take(&a,&near,over_frames=true),Assets_Take.Taken)
    testing.expect(t,assets_loaded(&a,ID))
}

// What a load takes leaves the caller, and a job frees what it read, between
// frames, one job at a time, with what a library hands it; levels that still
// go to the GPU wait for the renderer, and without job threads it is freed
// in the call.
@(test)
what_a_load_read_is_freed_in_a_job :: proc(t:^testing.T) {
    root:=base.test_folder(t,"release")
    if root=="" {return}
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    vertices:=[3]asset.Vertex{{position={0,0,0},normal=mm.normal_pack({0,1,0})},{position={1,0,0},normal=mm.normal_pack({0,1,0})},{position={0,0,1},normal=mm.normal_pack({0,1,0})}}
    meshes:=[3]base.Asset_Id{{0x72656c65,1},{0x72656c65,2},{0x72656c65,3}}
    for id,i in meshes {
        testing.expect_value(t,mesh_save_test(fmt.tprintf("%s/m%d.mesh",root,i),&types,id,vertices[:],{0,2,1}),asset.Error.None)
    }
    a:Assets
    if !testing.expect(t,assets_init(&a,{root=root,capacity=8})) {return}
    defer assets_destroy(&a)
    prepare :: proc(t:^testing.T,a:^Assets,types:^asset.Types,id:base.Asset_Id) -> (prepared:Assets_Prepared) {
        found:bool
        prepared.source,found=assets_source(a,id,runtime.heap_allocator())
        testing.expect(t,found)
        assets_prepare(&prepared,{},types)
        testing.expect(t,prepared.ok && prepared.opened)
        return
    }
    app:=App{assets=&a,allocator=context.allocator}
    if !testing.expect(t,jobs.system_init(&app.jobs,{threads=1})) {return}
    defer jobs.system_destroy(&app.jobs)
    rel:=&app.asset_releases

    prepared:=prepare(t,&a,&types,meshes[0])
    testing.expect(t,app_assets_take(&app,&prepared))
    testing.expect(t,assets_loaded(&a,meshes[0]))
    testing.expect(t,prepared.source.id=={} && !prepared.opened,"the caller no longer holds it")
    testing.expect_value(t,len(rel.queued),1)
    // Levels that went, or a renderer that is not there, join the queue.
    append(&rel.uploading,prepare(t,&a,&types,meshes[1]))
    app_assets_releases_step(&app)
    testing.expect(t,len(rel.uploading)==0 && len(rel.queued)==0,"the job has them")
    // A job that frees takes no other until it is done.
    unused:=prepare(t,&a,&types,meshes[2])
    app_assets_release(&app,&unused)
    jobs.wait(&app.jobs,jobs.OWNER,&rel.counter)
    testing.expect_value(t,len(rel.freeing),0)
    testing.expect_value(t,len(rel.queued),1)
    // What a library read goes with the same job.
    freed:=0
    count :: proc(data:rawptr) {(^int)(data)^+=1}
    app_release(&app,{count,&freed})
    testing.expect(t,freed==0 && len(rel.calls)==1,"it waits for the job")
    app_assets_releases_step(&app)
    jobs.wait(&app.jobs,jobs.OWNER,&rel.counter)
    testing.expect_value(t,freed,1)
    app_release(&app,{count,&freed})
    app_assets_releases_stop(&app)
    testing.expect(t,freed==2,"what was left goes when it stops")
    testing.expect(t,rel.queued==nil && rel.freeing==nil && rel.calls==nil && !jobs.pending(&rel.counter))

    alone:=App{assets=&a,allocator=context.allocator}
    inline:=prepare(t,&a,&types,meshes[2])
    app_assets_release(&alone,&inline)
    testing.expect(t,alone.asset_releases.queued==nil && inline.source.id=={},"freed in the call")
    app_release(&alone,{count,&freed})
    testing.expect(t,freed==3 && alone.asset_releases.calls==nil,"called in the call")
}
