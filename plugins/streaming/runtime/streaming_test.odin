package streaming

import "core:fmt"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import render "mirai:engine/render"
import scene "mirai:engine/scene"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/jobs"
import mm "mirai:std/math"

@(private)
@(test_world)
Streaming_World :: struct {
    using world:Test_World,
    references:core.Table(scene.Scene_Reference),
    worlds:core.Table(core.World_Transform),
    motions:core.Table(core.Motion),
    parents:core.Table(core.Parent),
    transforms:core.Table(core.Transform),
    members:core.Table(scene.Section_Member),
    roaming:core.Table(scene.Roaming),
    disabled:core.Table(core.Disabled),
    hierarchy:core.Hierarchy,
    requests:scene.Section_Requests,
    crossings:Streaming_Crossings,
}

// A source that comes near turns a section on, one at mid distance loads it
// off, and one that goes away turns it off or drops it only once it is
// scene.RESIDENT_KEEP times as far.
@(test)
a_section_follows_how_near_its_sources_are :: proc(t:^testing.T) {
    w:Streaming_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    e:=core.create(&w.entities)
    core.add(&w.references,e,scene.Scene_Reference{extents={10,10,10},rule=.Spatial,streamed=.Unloaded})
    core.add(&w.worlds,e,core.World_Transform{transform={rotation=1,scale=1}})
    test_world_settle(&w)
    settings:=Streaming_Settings{active=20,load=50}
    seen:Streaming_Seen
    sources:scene.Streaming_Sources
    want :: proc(w:^Streaming_World,x:f32,settings:^Streaming_Settings,seen:^Streaming_Seen,sources:^scene.Streaming_Sources) -> scene.Section_State {
        references,worlds,requests:=&w.references,&w.worlds,&w.requests
        sources.revision+=1
        sources.items[0]={position={x,0,0},ahead={x,0,0}}
        sources.count=1
        clear(&w.requests.queue.items)
        streaming_sections(core.ref(sources),core.read(references),core.read(worlds),core.ref(settings),seen,requests)
        state:=core.at(references,0).streamed
        if len(w.requests.queue.items)>0 {state=w.requests.queue.items[0].state}
        core.edit(references,core.entity_at(references,0)).streamed=state
        return state
    }
    testing.expect_value(t,want(&w,100,&settings,&seen,&sources),scene.Section_State.Unloaded)
    testing.expect_value(t,want(&w,50,&settings,&seen,&sources),scene.Section_State.Loaded)
    testing.expect_value(t,want(&w,25,&settings,&seen,&sources),scene.Section_State.Active)
    testing.expect_value(t,want(&w,33,&settings,&seen,&sources),scene.Section_State.Active)
    testing.expect_value(t,want(&w,40,&settings,&seen,&sources),scene.Section_State.Loaded)
    testing.expect_value(t,want(&w,62,&settings,&seen,&sources),scene.Section_State.Loaded)
    testing.expect_value(t,want(&w,75,&settings,&seen,&sources),scene.Section_State.Unloaded)
    // A section with a distance of its own loads at it, and turns on at the same share of it.
    testing.expect_value(t,want(&w,90,&settings,&seen,&sources),scene.Section_State.Unloaded)
    core.edit(&w.references,e).distance=100
    testing.expect_value(t,want(&w,90,&settings,&seen,&sources),scene.Section_State.Loaded)
    testing.expect_value(t,want(&w,45,&settings,&seen,&sources),scene.Section_State.Active)
    core.edit(&w.references,e).distance=0
    testing.expect_value(t,want(&w,75,&settings,&seen,&sources),scene.Section_State.Unloaded)
    // Once it looked, nothing is looked at again until a source or a section moves.
    streaming_sections(core.ref(&sources),core.read(&w.references),core.read(&w.worlds),core.ref(&settings),&seen,&w.requests)
    clear(&w.requests.queue.items)
    sources.items[0].position,sources.items[0].ahead={25,0,0},{25,0,0}
    streaming_sections(core.ref(&sources),core.read(&w.references),core.read(&w.worlds),core.ref(&settings),&seen,&w.requests)
    testing.expect_value(t,len(w.requests.queue.items),0)
}

@(private)
@(test_world)
Far_World :: struct {
    using world:Test_World,
    ids:core.Table(core.Id),
    references:core.Table(scene.Scene_Reference),
    worlds:core.Table(core.World_Transform),
    transforms:core.Table(core.Transform),
    parents:core.Table(core.Parent),
    proxies:core.Table(scene.Section_Proxy),
    renderers:core.Table(render.Mesh_Renderer),
    hierarchy:core.Hierarchy,
}

// A loaded section whose far mesh was never read, asked to go the frame
// after it shows: it stays
// until jobs read its far mesh, which then shows in its place in the same
// frame it goes; no frame shows neither, and the proxy never names a mesh
// that is not loaded, which a frame would read.
@(test)
a_section_goes_once_its_far_mesh_is_read_to_take_its_place :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"streaming-far")
    if folder=="" {return}
    ROOM :: base.Asset_Id{0xfa,1}
    types:asset.Types
    asset.types_init(&types)
    defer asset.types_destroy(&types)
    room:asset.Scene;asset.scene_init(&room,&types,ROOM)
    asset.scene_entity_add(&room,1,0,"Floor")
    testing.expect_value(t,asset.scene_save(&room,fmt.tprintf("%s/room.scene",folder)),asset.Error.None)
    asset.scene_destroy(&room)
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=folder,capacity=8})) {return}
    defer host.assets_destroy(&assets)
    // Its far mesh, as the editor part makes it into the cache.
    FAR :: 64*1024
    mesh:=asset.far_cache_id(asset.far_key(&assets.registry,ROOM))
    {
        count:=FAR-FAR%3
        vertices:=make([]asset.Vertex,count,context.temp_allocator)
        indices:=make([]u32,count,context.temp_allocator)
        for &v,i in vertices {v={position={f32(i%97),f32(i/97),0},normal=mm.normal_pack({0,0,1})}}
        for &index,i in indices {index=u32(i)}
        desc:=asset.Mesh_Desc{id=mesh}
        testing.expect(t,asset.mesh_build({vertices=vertices},indices,nil,&desc.geometry,context.temp_allocator))
        testing.expect_value(t,asset.mesh_save(fmt.tprintf("%s/%x-%x.mesh",folder,mesh[0],mesh[1]),&types,desc),asset.Error.None)
    }
    host.assets_scan(&assets)
    info,ok:=test_info(t,Far_World)
    if !ok {return}
    defer test_info_destroy(&info)
    app:=host.App{info=&info,assets=&assets,allocator=context.allocator}
    if !testing.expect(t,jobs.system_init(&app.jobs,{threads=2})) {return}
    w:=cast(^Far_World)host.app_world_create(&app)
    defer {
        host.app_world_free(&app,w)
        host.app_assets_releases_stop(&app)
        jobs.system_destroy(&app.jobs)
        delete(app.worlds)
        host.assets_marks_free(&app.asset_marks)
        host.app_content_destroy(&app)
    }
    world:=host.app_world_ref(&app,w)
    e:=core.create(&w.entities)
    core.add(&w.ids,e,core.Id{1})
    core.add(&w.references,e,scene.Scene_Reference{scene=ROOM,rule=.Manual,loaded=ROOM})
    core.add(&w.transforms,e,core.TRANSFORM_IDENTITY)
    core.world_settle(world)
    far:Streaming_Far
    defer streaming_far_free(&far)
    loads:scene.Section_Loads
    defer scene.section_loads_free(&loads)
    requests:scene.Section_Requests
    defer delete(requests.queue.items)
    stays:scene.Section_Stays
    defer delete(stays.queue.items)
    loading:scene.Section_Loading
    problems:core.Problems
    shown:=false
    for frame in 0..<64 {
        app.stats.frames+=1
        scene.scene_sections(world,&app,&w.references,&requests,{},core.read(&w.worlds),core.read(&w.ids),&loads,&loading,{},{},nil,&stays,&problems)
        core.world_settle(world)
        streaming_far(world,&app,core.read(&w.references),{},&w.transforms,core.read(&w.parents),core.read(&w.proxies),core.read(&w.renderers),&far,&stays)
        core.world_settle(world)
        reference,_:=core.get(&w.references,e)
        proxied:=core.count(&w.proxies)>0
        if proxied {testing.expect(t,host.assets_loaded(&assets,core.at(&w.renderers,0).mesh),"the proxy names its far mesh once it is loaded")}
        testing.expect(t,reference.loaded!={} || proxied,"the section or its far mesh shows")
        shown||=proxied
        if shown && reference.loaded=={} {break}
        if frame==0 {scene.section_request(&requests,e,.Unloaded)}
        // Its jobs end between frames, whatever the speed of their threads.
        if far.scenes[0].warm!=nil {jobs.wait(&app.jobs,jobs.OWNER,&far.scenes[0].warm.counter)}
    }
    reference,_:=core.get(&w.references,e)
    testing.expect(t,shown && reference.loaded=={},"its far mesh took its place")
}

// A crate that rolls out of its section passes, where it is, to the section
// whose box holds it, and out of every box to the root.
@(test)
what_moves_out_of_its_section_hangs_from_the_one_that_holds_it :: proc(t:^testing.T) {
    w:Streaming_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    a,b,crate:=core.create(&w.entities),core.create(&w.entities),core.create(&w.entities)
    core.add(&w.references,a,scene.Scene_Reference{scene={1,1},extents={10,10,10},loaded={1,1}})
    core.add(&w.references,b,scene.Scene_Reference{scene={2,2},extents={10,10,10},loaded={2,2}})
    core.add(&w.worlds,a,core.World_Transform{transform={position={0,0,0},rotation=1,scale=1}})
    core.add(&w.worlds,b,core.World_Transform{transform={position={30,0,0},rotation=1,scale=1}})
    core.add(&w.parents,crate,core.Parent{a,0})
    core.add(&w.members,crate,scene.Section_Member{7})
    core.add(&w.motions,crate,core.Motion{awake=true})
    core.add(&w.transforms,crate,core.Transform{{25,0,0},1,{1,1,1}})
    core.add(&w.worlds,crate,core.World_Transform{transform={position={25,0,0},rotation=1,scale=1}})
    run :: proc(w:^Streaming_World) {
        test_world_settle(w)
        streaming_crossings(core.read(&w.motions),core.read(&w.references),core.read(&w.worlds),core.read(&w.roaming),core.ref(&w.hierarchy),&w.parents,&w.transforms,&w.members,&w.crossings,nil)
        test_world_settle(w)
    }
    run(&w)
    parent,_:=core.get(&w.parents,crate)
    testing.expect_value(t,parent.entity,b)
    pose,_:=core.get(&w.transforms,crate)
    testing.expect_value(t,pose.position,[3]f32{-5,0,0})
    testing.expect(t,!core.has(&w.members,crate),"it is no longer of the scene of a")
    core.edit(&w.worlds,crate).position={100,0,0}
    run(&w)
    testing.expect(t,!core.has(&w.parents,crate),"out of every box, a root")
    pose,_=core.get(&w.transforms,crate)
    testing.expect_value(t,pose.position,[3]f32{100,0,0})
    // An agent that roams, off at the root, hangs again from the section on whose box holds it.
    agent:=core.create(&w.entities)
    core.add(&w.roaming,agent,scene.Roaming{})
    core.disable(&w.roaming,agent)
    core.add(&w.transforms,agent,core.Transform{{32,0,0},1,{1,1,1}})
    core.add(&w.worlds,agent,core.World_Transform{transform={position={32,0,0},rotation=1,scale=1}})
    run(&w)
    parent,_=core.get(&w.parents,agent)
    testing.expect_value(t,parent.entity,b)
    pose,_=core.get(&w.transforms,agent)
    testing.expect_value(t,pose.position,[3]f32{2,0,0})
}
