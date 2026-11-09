package streaming

import "core:testing"
import "mirai:core"
import scene "mirai:engine/scene"

// A source that comes near turns a section on, one at mid distance loads it
// off, and one that goes away turns it off or drops it only once it is
// scene.RESIDENT_KEEP times as far.
@(test)
a_section_follows_how_near_its_sources_are :: proc(t:^testing.T) {
    es:core.Entities;core.entities_init(&es);defer core.entities_destroy(&es)
    references:core.Table(scene.Scene_Reference);core.table_init(&references,"Scene_Reference");defer core.table_destroy(&references)
    worlds:core.Table(core.World_Transform);core.table_init(&worlds,"World_Transform");defer core.table_destroy(&worlds)
    requests:scene.Section_Requests;defer delete(requests.queue.items)
    e:=core.create(&es)
    core.add(&references,e,scene.Scene_Reference{extents={10,10,10},rule=.Spatial,streamed=.Unloaded})
    core.add(&worlds,e,core.World_Transform{transform={rotation=1,scale=1}})
    core.table_settle(&references,&es);core.table_settle(&worlds,&es)
    settings:=Streaming_Settings{active=20,load=50}
    seen:Streaming_Seen
    sources:scene.Streaming_Sources
    want :: proc(t:^testing.T,x:f32,references:^core.Table(scene.Scene_Reference),worlds:^core.Table(core.World_Transform),settings:^Streaming_Settings,seen:^Streaming_Seen,sources:^scene.Streaming_Sources,requests:^scene.Section_Requests) -> scene.Section_State {
        sources.revision+=1
        sources.items[0]={position={x,0,0},ahead={x,0,0}}
        sources.count=1
        clear(&requests.queue.items)
        streaming_sections(core.ref(sources),core.read(references),core.read(worlds),core.ref(settings),seen,requests)
        state:=core.at(core.read(references),0).streamed
        if len(requests.queue.items)>0 {state=requests.queue.items[0].state}
        core.get(references,core.entity_at(core.read(references),0)).streamed=state
        return state
    }
    testing.expect_value(t,want(t,100,&references,&worlds,&settings,&seen,&sources,&requests),scene.Section_State.Unloaded)
    testing.expect_value(t,want(t,50,&references,&worlds,&settings,&seen,&sources,&requests),scene.Section_State.Loaded)
    testing.expect_value(t,want(t,25,&references,&worlds,&settings,&seen,&sources,&requests),scene.Section_State.Active)
    testing.expect_value(t,want(t,33,&references,&worlds,&settings,&seen,&sources,&requests),scene.Section_State.Active)
    testing.expect_value(t,want(t,40,&references,&worlds,&settings,&seen,&sources,&requests),scene.Section_State.Loaded)
    testing.expect_value(t,want(t,62,&references,&worlds,&settings,&seen,&sources,&requests),scene.Section_State.Loaded)
    testing.expect_value(t,want(t,75,&references,&worlds,&settings,&seen,&sources,&requests),scene.Section_State.Unloaded)
    // Once it looked, nothing is looked at again until a source or a section moves.
    streaming_sections(core.ref(&sources),core.read(&references),core.read(&worlds),core.ref(&settings),&seen,&requests)
    clear(&requests.queue.items)
    sources.items[0].position,sources.items[0].ahead={25,0,0},{25,0,0}
    streaming_sections(core.ref(&sources),core.read(&references),core.read(&worlds),core.ref(&settings),&seen,&requests)
    testing.expect_value(t,len(requests.queue.items),0)
}

// A crate that rolls out of its section passes, where it is, to the section
// whose box holds it, and out of every box to the root.
@(test)
what_moves_out_of_its_section_hangs_from_the_one_that_holds_it :: proc(t:^testing.T) {
    es:core.Entities;core.entities_init(&es);defer core.entities_destroy(&es)
    references:core.Table(scene.Scene_Reference);core.table_init(&references,"Scene_Reference");defer core.table_destroy(&references)
    worlds:core.Table(core.World_Transform);core.table_init(&worlds,"World_Transform");defer core.table_destroy(&worlds)
    motions:core.Table(core.Motion);core.table_init(&motions,"Motion");defer core.table_destroy(&motions)
    parents:core.Table(core.Parent);core.table_init(&parents,"Parent");defer core.table_destroy(&parents)
    transforms:core.Table(core.Transform);core.table_init(&transforms,"Transform");defer core.table_destroy(&transforms)
    members:core.Table(scene.Section_Member);core.table_init(&members,"Section_Member");defer core.table_destroy(&members)
    roaming:core.Table(scene.Roaming);core.table_init(&roaming,"Roaming");defer core.table_destroy(&roaming)
    hierarchy:core.Hierarchy;defer core.value_free(&hierarchy,type_info_of(core.Hierarchy))
    crossings:Streaming_Crossings;defer delete(crossings.homes)
    a,b,crate:=core.create(&es),core.create(&es),core.create(&es)
    core.add(&references,a,scene.Scene_Reference{scene={1,1},extents={10,10,10},loaded={1,1}})
    core.add(&references,b,scene.Scene_Reference{scene={2,2},extents={10,10,10},loaded={2,2}})
    core.add(&worlds,a,core.World_Transform{transform={position={0,0,0},rotation=1,scale=1}})
    core.add(&worlds,b,core.World_Transform{transform={position={30,0,0},rotation=1,scale=1}})
    core.add(&parents,crate,core.Parent{a,0})
    core.add(&members,crate,scene.Section_Member{7})
    core.add(&motions,crate,core.Motion{awake=true})
    core.add(&transforms,crate,core.Transform{{25,0,0},1,{1,1,1}})
    core.add(&worlds,crate,core.World_Transform{transform={position={25,0,0},rotation=1,scale=1}})
    run :: proc(es:^core.Entities,references:^core.Table(scene.Scene_Reference),worlds:^core.Table(core.World_Transform),motions:^core.Table(core.Motion),parents:^core.Table(core.Parent),transforms:^core.Table(core.Transform),members:^core.Table(scene.Section_Member),roaming:^core.Table(scene.Roaming),hierarchy:^core.Hierarchy,crossings:^Streaming_Crossings) {
        core.table_settle(references,es);core.table_settle(worlds,es);core.table_settle(motions,es)
        core.table_settle(parents,es);core.table_settle(transforms,es);core.table_settle(members,es);core.table_settle(roaming,es)
        core.hierarchy_settle(hierarchy,core.read(parents),es)
        core.entities_settle(es)
        streaming_crossings(core.read(motions),core.read(references),core.read(worlds),core.read(roaming),core.ref(hierarchy),parents,transforms,members,crossings,nil)
        core.table_settle(parents,es);core.table_settle(transforms,es);core.table_settle(members,es);core.table_settle(roaming,es)
        core.hierarchy_settle(hierarchy,core.read(parents),es)
    }
    run(&es,&references,&worlds,&motions,&parents,&transforms,&members,&roaming,&hierarchy,&crossings)
    parent,_:=core.get(core.read(&parents),crate)
    testing.expect_value(t,parent.entity,b)
    pose,_:=core.get(core.read(&transforms),crate)
    testing.expect_value(t,pose.position,[3]f32{-5,0,0})
    testing.expect(t,!core.has(core.read(&members),crate),"it is no longer of the scene of a")
    core.get(&worlds,crate).position={100,0,0}
    run(&es,&references,&worlds,&motions,&parents,&transforms,&members,&roaming,&hierarchy,&crossings)
    testing.expect(t,!core.has(core.read(&parents),crate),"out of every box, a root")
    pose,_=core.get(core.read(&transforms),crate)
    testing.expect_value(t,pose.position,[3]f32{100,0,0})
    // An agent that roams, off at the root, hangs again from the section on whose box holds it.
    agent:=core.create(&es)
    core.add(&roaming,agent,scene.Roaming{})
    core.disable(&roaming,agent)
    core.add(&transforms,agent,core.Transform{{32,0,0},1,{1,1,1}})
    core.add(&worlds,agent,core.World_Transform{transform={position={32,0,0},rotation=1,scale=1}})
    run(&es,&references,&worlds,&motions,&parents,&transforms,&members,&roaming,&hierarchy,&crossings)
    parent,_=core.get(core.read(&parents),agent)
    testing.expect_value(t,parent.entity,b)
    pose,_=core.get(core.read(&transforms),agent)
    testing.expect_value(t,pose.position,[3]f32{2,0,0})
}
