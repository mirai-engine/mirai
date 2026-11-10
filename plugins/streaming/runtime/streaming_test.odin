package streaming

import "core:testing"
import "mirai:core"
import scene "mirai:engine/scene"

@(private)
Streaming_World :: struct {
    using world:core.Test_World,
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
    if !core.test_world_init(t,&w) {return}
    defer core.test_world_destroy(&w)
    e:=core.create(&w.entities)
    core.add(&w.references,e,scene.Scene_Reference{extents={10,10,10},rule=.Spatial,streamed=.Unloaded})
    core.add(&w.worlds,e,core.World_Transform{transform={rotation=1,scale=1}})
    core.test_world_settle(&w)
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
        state:=core.at(core.read(references),0).streamed
        if len(w.requests.queue.items)>0 {state=w.requests.queue.items[0].state}
        core.get(references,core.entity_at(core.read(references),0)).streamed=state
        return state
    }
    testing.expect_value(t,want(&w,100,&settings,&seen,&sources),scene.Section_State.Unloaded)
    testing.expect_value(t,want(&w,50,&settings,&seen,&sources),scene.Section_State.Loaded)
    testing.expect_value(t,want(&w,25,&settings,&seen,&sources),scene.Section_State.Active)
    testing.expect_value(t,want(&w,33,&settings,&seen,&sources),scene.Section_State.Active)
    testing.expect_value(t,want(&w,40,&settings,&seen,&sources),scene.Section_State.Loaded)
    testing.expect_value(t,want(&w,62,&settings,&seen,&sources),scene.Section_State.Loaded)
    testing.expect_value(t,want(&w,75,&settings,&seen,&sources),scene.Section_State.Unloaded)
    // Once it looked, nothing is looked at again until a source or a section moves.
    streaming_sections(core.ref(&sources),core.read(&w.references),core.read(&w.worlds),core.ref(&settings),&seen,&w.requests)
    clear(&w.requests.queue.items)
    sources.items[0].position,sources.items[0].ahead={25,0,0},{25,0,0}
    streaming_sections(core.ref(&sources),core.read(&w.references),core.read(&w.worlds),core.ref(&settings),&seen,&w.requests)
    testing.expect_value(t,len(w.requests.queue.items),0)
}

// A crate that rolls out of its section passes, where it is, to the section
// whose box holds it, and out of every box to the root.
@(test)
what_moves_out_of_its_section_hangs_from_the_one_that_holds_it :: proc(t:^testing.T) {
    w:Streaming_World
    if !core.test_world_init(t,&w) {return}
    defer core.test_world_destroy(&w)
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
        core.test_world_settle(w)
        streaming_crossings(core.read(&w.motions),core.read(&w.references),core.read(&w.worlds),core.read(&w.roaming),core.ref(&w.hierarchy),&w.parents,&w.transforms,&w.members,&w.crossings,nil)
        core.test_world_settle(w)
    }
    run(&w)
    parent,_:=core.get(core.read(&w.parents),crate)
    testing.expect_value(t,parent.entity,b)
    pose,_:=core.get(core.read(&w.transforms),crate)
    testing.expect_value(t,pose.position,[3]f32{-5,0,0})
    testing.expect(t,!core.has(core.read(&w.members),crate),"it is no longer of the scene of a")
    core.get(&w.worlds,crate).position={100,0,0}
    run(&w)
    testing.expect(t,!core.has(core.read(&w.parents),crate),"out of every box, a root")
    pose,_=core.get(core.read(&w.transforms),crate)
    testing.expect_value(t,pose.position,[3]f32{100,0,0})
    // An agent that roams, off at the root, hangs again from the section on whose box holds it.
    agent:=core.create(&w.entities)
    core.add(&w.roaming,agent,scene.Roaming{})
    core.disable(&w.roaming,agent)
    core.add(&w.transforms,agent,core.Transform{{32,0,0},1,{1,1,1}})
    core.add(&w.worlds,agent,core.World_Transform{transform={position={32,0,0},rotation=1,scale=1}})
    run(&w)
    parent,_=core.get(core.read(&w.parents),agent)
    testing.expect_value(t,parent.entity,b)
    pose,_=core.get(core.read(&w.transforms),agent)
    testing.expect_value(t,pose.position,[3]f32{2,0,0})
}
