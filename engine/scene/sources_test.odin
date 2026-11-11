package scene

import "core:testing"
import "mirai:core"
import input "mirai:engine/input"
import mm "mirai:std/math"

@(private)
@(test_world)
Sources_World :: struct {
    using world:Test_World,
    seats:core.Table(input.Seat),
    marks:core.Table(Streaming_Source),
    worlds:core.Table(core.World_Transform),
    motions:core.Table(core.Motion),
}

// More sources than fit is a problem; a source that moves less than
// SOURCE_MOVE moves nothing that streams, and one that moves more does.
@(test)
sources_that_do_not_fit_are_a_problem_and_only_a_move_is_looked_at_again :: proc(t:^testing.T) {
    w:Sources_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    problems:=new(core.Problems);defer free(problems)
    first:core.Entity
    for i in 0..<SOURCES_MAX+6 {
        e:=core.create(&w.entities)
        if i==0 {first=e}
        core.add(&w.marks,e,Streaming_Source{})
        core.add(&w.worlds,e,core.World_Transform{transform={position={f32(i),0,0},rotation=1,scale=1}})
    }
    test_world_settle(&w)
    sources:Streaming_Sources
    run :: proc(sources:^Streaming_Sources,seats:^core.Table(input.Seat),marks:^core.Table(Streaming_Source),worlds:^core.Table(core.World_Transform),motions:^core.Table(core.Motion),problems:^core.Problems) {
        scene_sources(sources,{},{},core.read(seats),core.read(marks),core.read(worlds),core.read(motions),problems)
    }
    run(&sources,&w.seats,&w.marks,&w.worlds,&w.motions,problems)
    testing.expect_value(t,sources.count,SOURCES_MAX)
    testing.expect(t,core.problem_find(problems,core.NONE,"scene.sources")!=nil,"the sources past SOURCES_MAX are a problem")
    revision:=sources.revision
    core.edit(&w.worlds,first).position.x+=SOURCE_MOVE/2
    run(&sources,&w.seats,&w.marks,&w.worlds,&w.motions,problems)
    testing.expect_value(t,sources.revision,revision)
    core.edit(&w.worlds,first).position.x+=SOURCE_MOVE
    run(&sources,&w.seats,&w.marks,&w.worlds,&w.motions,problems)
    testing.expect_value(t,sources.revision,revision+1)
}

// What comes within the reach of a source is resident, stays until every
// source is RESIDENT_KEEP times its reach away, and past a budget only the
// nearest stay. A placed box sees the sources in its frame, scale and all.
@(test)
a_box_is_resident_near_a_source_and_goes_only_well_past_its_reach :: proc(t:^testing.T) {
    sources:Streaming_Sources
    sources.items[0]={position={30,0,0},ahead={30,0,0}}
    sources.items[1]={position={0,0,500},ahead={0,0,500},distance=1000}
    sources.count=1
    placed:=mm.transform_matrix({position={10,0,0},rotation=1,scale={2,2,2}})
    near:=sources_near(&sources,placed,10)
    // A box of 1 m around the origin of its frame: 2 m across in the world, from 8 to 12 along x.
    at:=box_near(&near,{-1,-1,-1},{1,1,1})
    testing.expect(t,abs(at-1.8)<1e-4,"18 m away, with a reach of 10 m")
    testing.expect(t,!resident(at,false) && !resident(at,true))
    testing.expect(t,resident(1.2,true) && !resident(1.2,false),"what was resident stays a while past its reach")
    sources.count=2
    near=sources_near(&sources,placed,10)
    testing.expect(t,box_near(&near,{-1,-1,-1},{1,1,1})<1,"a source with a distance of its own reaches as far as it says")
    order:=[]Resident_Order{{3,0},{1,1},{2,2}}
    past:=residents_past(order,2)
    testing.expect(t,len(past)==1 && past[0].index==0,"the farthest goes")
}

// The view goes where it went since the frame before, SOURCE_PREFETCH
// seconds ahead; a view that jumped (cut) goes nowhere.
@(test)
the_view_streams_ahead_of_where_it_moves_unless_it_jumped :: proc(t:^testing.T) {
    w:Sources_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    problems:=new(core.Problems);defer free(problems)
    sources:Streaming_Sources
    run :: proc(sources:^Streaming_Sources,view:core.View,dt:f32,seats:^core.Table(input.Seat),marks:^core.Table(Streaming_Source),worlds:^core.Table(core.World_Transform),motions:^core.Table(core.Motion),problems:^core.Problems) {
        scene_sources(sources,view,{dt=dt},core.read(seats),core.read(marks),core.read(worlds),core.read(motions),problems)
    }
    view:=core.View{position={0,0,0},size={640,480}}
    run(&sources,view,0.1,&w.seats,&w.marks,&w.worlds,&w.motions,problems)
    testing.expect(t,sources.count==1 && sources.items[0].ahead==sources.items[0].position,"a view seen once has not moved")
    view.position={1,0,0}
    run(&sources,view,0.1,&w.seats,&w.marks,&w.worlds,&w.motions,problems)
    testing.expectf(t,abs(sources.items[0].ahead.x-(1+10*SOURCE_PREFETCH))<1e-4,"at 10 m/s it streams ahead: %v",sources.items[0].ahead)
    view.position,view.cut={500,0,0},true
    run(&sources,view,0.1,&w.seats,&w.marks,&w.worlds,&w.motions,problems)
    testing.expect(t,sources.items[0].ahead==sources.items[0].position,"a jump is not a motion")
}
