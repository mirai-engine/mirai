package scene

import "core:fmt"
import "core:testing"
import "core:thread"
import "core:time"
import "mirai:asset"
import "mirai:core"
import "mirai:host"
import anim "mirai:std/anim"
import "mirai:std/base"
import "mirai:std/jobs"
import mm "mirai:std/math"

@(private) Loading_Model :: struct {mesh:base.Asset_Id}

@(private)
Loading_World :: struct {
    using world:core.Test_World,
    ids:core.Table(core.Id),
    names:core.Table(core.Name),
    transforms:core.Table(core.Transform),
    parents:core.Table(core.Parent),
    models:core.Table(Loading_Model),
    references:core.Table(Scene_Reference),
    instances:core.Table(Prefab_Instance),
    pendings:core.Table(Prefab_Pending),
    disabled:core.Table(core.Disabled),
    forms:Prefab_Forms,
}

// A project in a temporary folder of assets, with job threads or without,
// and a World of it its application made.
@(private)
Loading_Project :: struct {
    folder:string,
    types:asset.Types,
    info:core.World_Info,
    assets:host.Assets,
    app:host.App,
    world:^Loading_World,
}

@(private)
loading_open :: proc(t:^testing.T,p:^Loading_Project,name:string,threads:int) -> bool {
    p.folder=base.test_folder(t,fmt.tprintf("loading-%s",name))
    if p.folder=="" {return false}
    p.info=core.test_info(t,Loading_World,test_types) or_return
    asset.types_init(&p.types)
    if !testing.expect(t,host.assets_init(&p.assets,{root=p.folder,capacity=64})) {return false}
    p.app={info=&p.info,assets=&p.assets,allocator=context.allocator}
    if threads>0 && !testing.expect(t,jobs.system_init(&p.app.jobs,{threads=threads})) {return false}
    p.world=cast(^Loading_World)host.app_world_create(&p.app)
    return testing.expect(t,p.world!=nil)
}

@(private)
loading_close :: proc(p:^Loading_Project) {
    host.app_content_destroy(&p.app)
    host.app_world_free(&p.app,p.world)
    host.app_assets_releases_stop(&p.app)
    if jobs.worker_count(&p.app.jobs)>0 {jobs.system_destroy(&p.app.jobs)}
    delete(p.app.worlds)
    host.assets_marks_free(&p.app.asset_marks)
    host.assets_destroy(&p.assets)
    asset.types_destroy(&p.types)
    core.test_info_destroy(&p.info)
}

// A mesh of about bytes of clusters, with the material of its slot.
@(private)
loading_mesh :: proc(t:^testing.T,p:^Loading_Project,id:base.Asset_Id,bytes:int,material:=base.Asset_Id{}) {
    count:=max(bytes/(size_of(asset.Cluster_Vertex)+1),3)
    count-=count%3
    vertices:=make([]asset.Vertex,count)
    defer delete(vertices)
    indices:=make([]u32,count)
    defer delete(indices)
    for &v,i in vertices {v={position={f32(i%977),f32(i/977),f32(i%13)},normal=mm.normal_pack({0,0,1})}}
    for &index,i in indices {index=u32(i)}
    slots:=[1]asset.Material_Slot{{material=material}}
    desc:=asset.Mesh_Desc{id=id}
    testing.expect(t,asset.mesh_build({vertices=vertices},indices,nil,&desc.geometry,context.temp_allocator))
    if material!={} {desc.slots=slots[:]}
    testing.expect_value(t,asset.mesh_save(fmt.tprintf("%s/%x-%x.mesh",p.folder,id[0],id[1]),&p.types,desc),asset.Error.None)
}

// A scene with an entity for each mesh, and the references given.
@(private)
loading_scene :: proc(t:^testing.T,p:^Loading_Project,id:base.Asset_Id,meshes:[]base.Asset_Id,references:[]Scene_Reference=nil,prefab:=false) {
    document:asset.Scene;asset.scene_init(&document,&p.types,id);defer asset.scene_destroy(&document)
    if prefab {document.doc.flags+={.Prefab}}
    for mesh,i in meshes {
        asset.scene_entity_add(&document,base.Entity_Id(i+1),0,"Model")
        asset.scene_set(&document,base.Entity_Id(i+1),"Loading_Model",&Loading_Model{mesh})
    }
    for &reference,i in references {
        asset.scene_entity_add(&document,base.Entity_Id(100+i),0,"Section")
        asset.scene_set(&document,base.Entity_Id(100+i),"Scene_Reference",&reference)
    }
    testing.expect_value(t,asset.scene_save(&document,fmt.tprintf("%s/%x-%x.scene",p.folder,id[0],id[1])),asset.Error.None)
}

// Steps loads frame after frame, each at most until it is done, waiting for
// their jobs between frames: the frames it took and, of each, the bytes
// the loads gave the renderer and how many assets each one took.
@(private)
Loading_Frame :: struct {bytes:int,taken:[4]int}

@(private)
loading_frames :: proc(t:^testing.T,p:^Loading_Project,loads:[]^Load_Job,frames:^[dynamic]Loading_Frame) -> bool {
    done:=make([]bool,len(loads),context.temp_allocator)
    started:=time.tick_now()
    for {
        p.app.stats.frames+=1
        frame:Loading_Frame
        all:=true
        for job,i in loads {
            if done[i] {continue}
            before:=job.phase==.Warming?job.taken:0
            done[i]=load_step(job)
            if job.phase==.Warming || job.phase==.Idle {frame.taken[i]=job.taken-before}
            all&&=done[i]
        }
        if p.assets.loads.frame==p.app.stats.frames {frame.bytes=p.assets.loads.bytes}
        append(frames,frame)
        if all {return true}
        if !testing.expect(t,time.duration_seconds(time.tick_since(started))<60,"the loads end") {return false}
        thread.yield()
    }
}

// A load reads its documents and the assets its scene names in jobs: of a
// mesh larger than the bytes of a frame and of a mesh with a material and a
// texture, textures first. The main thread gives the renderer the part of
// each frame the load has, and the large mesh in a frame of its own.
@(test)
a_load_reads_in_jobs_and_a_large_asset_goes_in_a_frame_alone :: proc(t:^testing.T) {
    p:Loading_Project
    if !loading_open(t,&p,"jobs",2) {return}
    defer loading_close(&p)
    BIG :: base.Asset_Id{0x10ad,1}
    SMALL :: base.Asset_Id{0x10ad,2}
    MATERIAL :: base.Asset_Id{0x10ad,3}
    TEXTURE :: base.Asset_Id{0x10ad,4}
    LEVEL :: base.Asset_Id{0x10ad,5}
    loading_mesh(t,&p,BIG,host.LOAD_FRAME_BYTES+(1<<20))
    loading_mesh(t,&p,SMALL,host.LOAD_FRAME_BYTES/4,MATERIAL)
    pixels:=make([]u8,256*256*4)
    defer delete(pixels)
    mips:=[1][]u8{pixels}
    testing.expect_value(t,asset.texture_save(fmt.tprintf("%s/stone.tex",p.folder),&p.types,{id=TEXTURE,width=256,height=256,format=.RGBA8,mips=mips[:]}),asset.Error.None)
    info:=asset.MATERIAL_DEFAULTS
    info.maps.base_color.texture=TEXTURE
    testing.expect_value(t,asset.material_save(fmt.tprintf("%s/stone.mat",p.folder),&p.types,{id=MATERIAL,info=info}),asset.Error.None)
    loading_scene(t,&p,LEVEL,{SMALL,BIG})
    host.assets_scan(&p.assets)

    job,error:=load_begin(&p.app,LEVEL)
    if !testing.expect_value(t,error,Error.None) {return}
    testing.expect_value(t,load_progress(job).phase,Load_Phase.Reading)
    frames:=make([dynamic]Loading_Frame,context.temp_allocator)
    warming:=false
    for !warming && !load_step(job) {
        warming=job.phase==.Warming
        thread.yield()
    }
    if !testing.expect(t,warming) {return}
    // Each asset after what it takes: the texture, its material, then the meshes.
    kinds:=[4]asset.Fourcc{asset.KIND_TEXTURE,asset.KIND_MATERIAL,asset.KIND_MESH,asset.KIND_MESH}
    if testing.expect_value(t,len(job.items),4) {
        for item,i in job.items {testing.expect_value(t,item.prepared.source.kind,kinds[i])}
    }
    if !loading_frames(t,&p,{job},&frames) {return}
    for frame in frames {
        testing.expect(t,frame.bytes<=host.LOAD_FRAME_BYTES || frame.taken[0]==1,"past the bytes of a frame only one asset, alone")
    }
    for id in ([4]base.Asset_Id{BIG,SMALL,MATERIAL,TEXTURE}) {testing.expect(t,host.assets_loaded(&p.assets,id))}
    testing.expect_value(t,p.assets.stats.loads,4)
    _,error=load_end(job,host.app_world_ref(&p.app,p.world))
    testing.expect_value(t,error,Error.None)
    testing.expect_value(t,core.count(&p.world.models),2)
}

// A load in phases is the record of the scene: the documents and entities
// its jobs read and made count in its phases, and the assets they prepared
// by kind. Ready once the scene is the world, it waits for an asset that
// loads on demand after it, which counts as finished after it was ready, and
// is resident at the end of the first frame with nothing busy.
@(test)
a_load_reports_its_phases_and_the_assets_that_finish_after_it :: proc(t:^testing.T) {
    p:Loading_Project
    if !loading_open(t,&p,"profile",2) {return}
    defer loading_close(&p)
    p.assets.load_profile=&p.app.load_profile
    defer host.load_profile_destroy(&p.app)
    MESH :: base.Asset_Id{0x10ad,0x21}
    LATER :: base.Asset_Id{0x10ad,0x22}
    LEVEL :: base.Asset_Id{0x10ad,0x23}
    loading_mesh(t,&p,MESH,host.LOAD_FRAME_BYTES/8)
    loading_mesh(t,&p,LATER,host.LOAD_FRAME_BYTES/8)
    loading_scene(t,&p,LEVEL,{MESH})
    host.assets_scan(&p.assets)

    job,error:=load_begin(&p.app,LEVEL)
    if !testing.expect_value(t,error,Error.None) {return}
    frames:=make([dynamic]Loading_Frame,context.temp_allocator)
    if !loading_frames(t,&p,{job},&frames) {return}
    host.load_profile_frame(&p.app,true)
    summary,found:=host.load_summary(&p.app,.Scene,host.LOAD_SLOWEST,context.temp_allocator)
    if !testing.expect(t,found) {return}
    testing.expect(t,summary.state==.Loading && !summary.ready,"not resident before the scene is the world")
    _,error=load_end(job,host.app_world_ref(&p.app,p.world))
    if !testing.expect_value(t,error,Error.None) {return}

    testing.expect(t,host.assets_mesh(&p.assets,LATER)!=nil)
    host.load_profile_frame(&p.app,true)
    summary,_=host.load_summary(&p.app,.Scene,host.LOAD_SLOWEST,context.temp_allocator)
    testing.expect(t,summary.state==.Loading && summary.ready && .Assets in summary.waiting,"a frame that loaded an asset is not resident")
    host.load_profile_frame(&p.app,true)
    summary,_=host.load_summary(&p.app,.Scene,host.LOAD_SLOWEST,context.temp_allocator)
    if !testing.expect_value(t,summary.state,host.Load_State.Done) {return}
    testing.expect(t,summary.resident_ms>=summary.ready_ms && summary.ready_ms>0)
    testing.expect_value(t,summary.entities,1)
    counted:[host.Load_Phase]i64
    for phase in summary.phases {counted[phase.phase]=phase.count}
    testing.expect_value(t,counted[.Read],1)
    testing.expect_value(t,counted[.Instantiate],1)
    meshes:host.Load_Assets
    for k in summary.assets {if k.kind==.Mesh {meshes=k.totals}}
    testing.expect(t,meshes.count==2 && meshes.later==1 && meshes.bytes>0,"both meshes, one after it was ready")
    later:=false
    for item in summary.slowest {if item.id==LATER {later=item.later && !item.job}}
    testing.expect(t,later,"the mesh loaded on demand is among the slowest, after it was ready")
    waited:=false
    for w in summary.waits {waited||=w.busy==.Assets && w.until_ms>=summary.ready_ms}
    testing.expect(t,waited,"it waited for the asset after it was ready")
}

// A load ends once the .anim its World can play are loaded, also one it names through a prefab
// (a spawner's): while the first load of one compresses in a job, it waits, frame after frame,
// and a load to its end waits for the compression. Nothing it plays holds a rest pose meanwhile.
@(test)
a_load_waits_for_the_animations_its_world_can_play :: proc(t:^testing.T) {
    p:Loading_Project
    if !loading_open(t,&p,"animations",2) {return}
    defer loading_close(&p)
    p.app.animation_cache=""
    CLIPS :: base.Asset_Id{0xa111,1}
    PREFAB :: base.Asset_Id{0xa111,2}
    LEVEL :: base.Asset_Id{0xa111,3}
    keys:[31]anim.Keyframe
    for &key,k in keys {key={time=f32(k)/30,value={0,f32(k)*.01,0,0}}}
    tracks:=[1]asset.Animation_Track_Desc{{target="hips",property=.Position,keys=keys[:]}}
    clips:=[1]asset.Animation_Clip_Desc{{name="walk",tracks=tracks[:]}}
    testing.expect_value(t,asset.animation_save(fmt.tprintf("%s/walk.anim",p.folder),&p.types,{id=CLIPS,clips=clips[:]}),asset.Error.None)
    loading_scene(t,&p,PREFAB,{CLIPS},prefab=true)
    loading_scene(t,&p,LEVEL,{PREFAB})
    host.assets_scan(&p.assets)

    job,error:=load_begin(&p.app,LEVEL)
    if !testing.expect_value(t,error,Error.None) {return}
    defer load_free(job)
    for job.phase==.Reading {
        if !testing.expect(t,!load_step(job),"it waits for the .anim") {return}
        thread.yield()
    }
    if !testing.expect(t,len(job.animations)==1 && job.animations[0]==CLIPS,"the .anim of the prefab it names") {return}
    // A compression a job ended is taken at the start of a frame, which these steps never begin.
    for _ in 0..<4 {
        testing.expect(t,host.content_animation_pending(&p.app,CLIPS))
        if !testing.expect(t,!load_step(job),"it waits while the .anim compresses") {return}
    }
    testing.expect(t,load_step(job,all=true) && job.error==.None)
    testing.expect(t,host.content_animation(&p.app,CLIPS)!=nil && !host.content_animation_pending(&p.app,CLIPS),"loaded when the load ends")
}

// Three loads at once share the bytes of every frame: each takes its part in
// each frame, and together no more than a frame has.
@(test)
loads_under_way_share_every_frame :: proc(t:^testing.T) {
    p:Loading_Project
    if !loading_open(t,&p,"share",2) {return}
    defer loading_close(&p)
    loads:[3]^Load_Job
    defer {for job in loads {if job!=nil {load_free(job)}}}
    for &job,l in loads {
        meshes:[4]base.Asset_Id
        for &mesh,i in meshes {
            mesh={0x5a,u64(l*4+i+1)}
            loading_mesh(t,&p,mesh,host.LOAD_FRAME_BYTES/8)
        }
        loading_scene(t,&p,{0x5b,u64(l+1)},meshes[:])
    }
    host.assets_scan(&p.assets)
    for &job,l in loads {
        error:Error
        job,error=load_begin(&p.app,{0x5b,u64(l+1)})
        if !testing.expect_value(t,error,Error.None) {return}
    }
    // All of them read and prepared, the frames show only how they share.
    for job in loads {
        for job.phase==.Reading {
            if jobs.pending(&job.counter) {jobs.wait(&p.app.jobs,jobs.OWNER,&job.counter)}
            if job.error!=.None || len(job.wanted)>0 {break}
            load_named(job)
        }
        if !testing.expect_value(t,job.phase,Load_Phase.Warming) {return}
        jobs.wait(&p.app.jobs,jobs.OWNER,&job.counter)
    }
    frames:=make([dynamic]Loading_Frame,context.temp_allocator)
    if !loading_frames(t,&p,loads[:],&frames) {return}
    first:=frames[0]
    testing.expect(t,first.taken[0]>0 && first.taken[1]>0 && first.taken[2]>0,"each load takes its part of the first frame")
    for frame in frames {testing.expect(t,frame.bytes<=host.LOAD_FRAME_BYTES,"together no more than a frame")}
    for job in loads {testing.expect_value(t,job.taken,4)}
}

// A load reads the scenes of the references that load with its document and
// leaves those another rule loads, and only what it reads it takes from the
// registry.
@(test)
a_load_reads_only_the_sections_that_load_with_it :: proc(t:^testing.T) {
    p:Loading_Project
    if !loading_open(t,&p,"rule",0) {return}
    defer loading_close(&p)
    WITH :: base.Asset_Id{0x7e,1}
    MANUAL :: base.Asset_Id{0x7e,2}
    LEVEL :: base.Asset_Id{0x7e,3}
    OTHER :: base.Asset_Id{0x7e,4}
    loading_scene(t,&p,WITH,nil)
    loading_scene(t,&p,MANUAL,nil)
    loading_scene(t,&p,OTHER,nil)
    loading_scene(t,&p,LEVEL,nil,{{scene=WITH},{scene=MANUAL,rule=.Manual}})
    host.assets_scan(&p.assets)
    job,error:=load_begin(&p.app,LEVEL)
    if !testing.expect_value(t,error,Error.None) {return}
    defer load_free(job)
    testing.expect(t,load_step(job,all=true))
    testing.expect_value(t,job.error,Error.None)
    testing.expect_value(t,job.asked,2)
    testing.expect(t,WITH in job.documents && !(MANUAL in job.documents) && !(OTHER in job.documents))
    testing.expect_value(t,job.report.sections,1)
}

// The sections loading apart tell how far they are: reading what they need
// as it is found, then their assets as they reach the renderer; a section
// that loaded is no longer there.
@(test)
the_sections_loading_tell_how_far_they_are :: proc(t:^testing.T) {
    p:Loading_Project
    if !loading_open(t,&p,"sections",0) {return}
    defer loading_close(&p)
    ROOM :: base.Asset_Id{0x5ec,1}
    LAMP :: base.Asset_Id{0x5ec,2}
    meshes:=[2]base.Asset_Id{{0x5ec,3},{0x5ec,4}}
    for mesh in meshes {loading_mesh(t,&p,mesh,host.LOAD_FRAME_BYTES*6/10)}
    loading_scene(t,&p,LAMP,meshes[1:],prefab=true)
    {
        lamp:asset.Scene
        file:asset.Asset
        if !testing.expect_value(t,asset.asset_load(&file,fmt.tprintf("%s/%x-%x.scene",p.folder,LAMP[0],LAMP[1])),asset.Error.None) {return}
        defer asset.asset_close(&file)
        testing.expect_value(t,asset.scene_from_asset(&lamp,&p.types,&file),asset.Error.None)
        defer asset.scene_destroy(&lamp)
        room:asset.Scene;asset.scene_init(&room,&p.types,ROOM);defer asset.scene_destroy(&room)
        asset.scene_entity_add(&room,1,0,"Model")
        asset.scene_set(&room,1,"Loading_Model",&Loading_Model{meshes[0]})
        _,placed:=asset.scene_instantiate(&room,&lamp,LAMP,0)
        testing.expect_value(t,placed,asset.Error.None)
        testing.expect_value(t,asset.scene_save(&room,fmt.tprintf("%s/room.scene",p.folder)),asset.Error.None)
    }
    host.assets_scan(&p.assets)

    w:=p.world
    world:=host.app_world_ref(&p.app,w)
    e:=core.create(&w.entities)
    core.add(&w.ids,e,core.Id{9})
    core.add(&w.references,e,Scene_Reference{scene=ROOM,rule=.Manual})
    core.settle(&p.info,w,nil)
    requests:Section_Requests
    loads:Section_Loads
    loading:Section_Loading
    problems:core.Problems
    defer {for l in loads.items {if l.job!=nil {load_free(l.job)}}}
    step :: proc(p:^Loading_Project,world:core.World_Ref,requests:^Section_Requests,loads:^Section_Loads,loading:^Section_Loading,problems:^core.Problems) {
        p.app.stats.frames+=1
        // A frame with time to spare: what it takes is decided by bytes, not by how loaded the machine is.
        b:=&p.assets.loads
        b.frame,b.seconds,b.bytes,b.served=p.app.stats.frames,-3600,0,0
        w:=cast(^Loading_World)world.data
        scene_sections(world,&p.app,&w.references,requests,loads,loading,{},{},nil,problems)
        core.settle(&p.info,w,nil)
    }
    // Its scene is read and asks for the prefab its instance follows.
    step(&p,world,&requests,&loads,&loading,&problems)
    if !testing.expect_value(t,loading.count,1) {return}
    item:=loading.items[0]
    testing.expect_value(t,item.entity,e)
    testing.expect_value(t,item.loading.phase,Load_Phase.Reading)
    testing.expect_value(t,item.loading.scene,ROOM)
    testing.expect(t,item.loading.done==1 && item.loading.total==2,"read one of the two documents found")
    // The prefab, for what spawns it, and the first mesh: the second does not fit in the frame.
    step(&p,world,&requests,&loads,&loading,&problems)
    if !testing.expect_value(t,loading.count,1) {return}
    item=loading.items[0]
    testing.expect_value(t,item.loading.phase,Load_Phase.Warming)
    testing.expect(t,item.loading.done==2 && item.loading.total==3,"the prefab and one of its two meshes")
    step(&p,world,&requests,&loads,&loading,&problems)
    testing.expect_value(t,loading.count,0)
    reference,_:=core.get(&w.references,e)
    testing.expect_value(t,reference.loaded,ROOM)
    testing.expect_value(t,core.count(&w.models),2)
}

// A section load that waits for the libraries ends once a frame passed in
// which none named what it names, never in the frame it began to wait.
@(test)
a_load_waits_while_a_library_names_what_it_names :: proc(t:^testing.T) {
    a,b:=base.Asset_Id{1,2},base.Asset_Id{3,4}
    job:Load_Job
    job.phase=.Waiting
    job.names=make([dynamic]base.Asset_Id,context.temp_allocator)
    append(&job.names,a)
    loads:Section_Loads
    loads.items[0]={job=&job}
    loads_waits_settle(&loads,nil)
    testing.expect(t,!job.ready,"the frame it began to wait")
    loads_waits_settle(&loads,{a,b})
    testing.expect(t,!job.ready,"a library still prepares what it names")
    loads_waits_settle(&loads,{b})
    testing.expect(t,job.ready,"a frame without its assets named")
    named:=make([dynamic]base.Asset_Id,context.temp_allocator)
    loads_waiting(&loads,&named)
    testing.expect_value(t,len(named),1)
}

// A spawn of a prefab that is not loaded reads nothing in the call: its root
// comes at once, alone, where it was asked, and jobs read the prefab and the
// mesh it names; within frames the root takes them and keeps what it was
// given meanwhile. A scene load reads the prefabs its fields name,
// with what they take: a spawn after it is whole in the call.
@(test)
a_spawn_of_a_prefab_not_loaded_returns_its_root_and_jobs_fill_it :: proc(t:^testing.T) {
    p:Loading_Project
    if !loading_open(t,&p,"spawn",2) {return}
    defer loading_close(&p)
    MESH :: base.Asset_Id{0x5a,1}
    PREFAB :: base.Asset_Id{0x5a,2}
    LEVEL :: base.Asset_Id{0x5a,3}
    loading_mesh(t,&p,MESH,host.LOAD_FRAME_BYTES/8)
    loading_scene(t,&p,PREFAB,{MESH},prefab=true)
    loading_scene(t,&p,LEVEL,{PREFAB})
    host.assets_scan(&p.assets)
    w:=host.app_world_ref(&p.app,p.world)
    warms:Prefab_Warms
    defer prefab_warms_free(&warms)

    report,error:=spawn_prefab(core.commands_of(w),&p.assets,{prefab=PREFAB,transform={position={1,2,3}}})
    root:=report.root
    testing.expect_value(t,error,Error.None)
    testing.expect(t,p.assets.stats.loads==0 && !host.assets_loaded(&p.assets,PREFAB),"the call reads nothing")
    core.add(&p.world.models,root,Loading_Model{LEVEL})
    core.world_settle(w)
    pose,_:=core.get(&p.world.transforms,root)
    testing.expect(t,core.raw_row(core.raw(&p.world.pendings),root)>=0 && !core.has(&p.world.names,root) && pose.position==[3]f32{1,2,3},"its root alone, where it was asked")
    started:=time.tick_now()
    for frame:=0;core.raw_row(core.raw(&p.world.pendings),root)>=0;frame+=1 {
        p.app.stats.frames+=1
        spawns_fill(w,&p.app,&warms,nil)
        core.world_settle(w)
        if !testing.expect(t,time.duration_seconds(time.tick_since(started))<60,"the spawn is filled") {return}
        thread.yield()
    }
    testing.expect_value(t,len(warms.items),0)
    testing.expect(t,host.assets_loaded(&p.assets,PREFAB) && host.assets_loaded(&p.assets,MESH) && p.assets.stats.loads==2,"jobs read the prefab and its mesh")
    model,_:=core.get(&p.world.models,root)
    name,_:=core.get(&p.world.names,root)
    testing.expect(t,core.has(&p.world.models,root) && model.mesh==LEVEL && base.text_get(name.text[:])=="Model","it keeps what it was given, with the rest of its prefab")
    pose,_=core.get(&p.world.transforms,root)
    testing.expect_value(t,pose.position,[3]f32{1,2,3})

    // A copy of an entity of a section that is not loaded waits the same way, and takes it.
    section:=PREFAB
    section[1]=5
    loading_scene(t,&p,section,{MESH,MESH})
    host.assets_scan(&p.assets)
    loads:=p.assets.stats.loads
    copied,copy_error:=spawn_member(core.commands_of(w),&p.assets,section,0,2,{position={4,0,0},rotation=1,scale={1,1,1}})
    testing.expect(t,copy_error==.None && p.assets.stats.loads==loads && !host.assets_loaded(&p.assets,section),"the call reads nothing")
    core.world_settle(w)
    for core.raw_row(core.raw(&p.world.pendings),copied.root)>=0 {
        p.app.stats.frames+=1
        spawns_fill(w,&p.app,&warms,nil)
        core.world_settle(w)
        if !testing.expect(t,time.duration_seconds(time.tick_since(started))<60,"the copy is filled") {return}
        thread.yield()
    }
    copied_model,copied_has:=core.get(&p.world.models,copied.root)
    testing.expect(t,copied_has && copied_model.mesh==MESH && !core.has(&p.world.ids,copied.root),"the entity of the section, without an Id")

    // A scene whose field names the prefab reads it with what it takes: the next spawn is whole at once.
    other:=PREFAB
    other[1]=4
    loading_scene(t,&p,other,{MESH},prefab=true)
    loading_scene(t,&p,LEVEL,{other})
    host.assets_scan(&p.assets)
    job,begun:=load_begin(&p.app,LEVEL)
    if !testing.expect_value(t,begun,Error.None) {return}
    frames:=make([dynamic]Loading_Frame,context.temp_allocator)
    if !loading_frames(t,&p,{job},&frames) {return}
    testing.expect(t,host.assets_loaded(&p.assets,other),"the load read the prefab its field names")
    _,error=load_end(job,w)
    testing.expect_value(t,error,Error.None)
    report,error=spawn_prefab(core.commands_of(w),&p.assets,{prefab=other})
    core.world_settle(w)
    testing.expect(t,error==.None && core.has(&p.world.models,report.root) && core.raw_row(core.raw(&p.world.pendings),report.root)<0,"whole in the call")
}
