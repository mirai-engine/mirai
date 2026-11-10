package spawn

import "core:testing"
import "mirai:core"
import input "mirai:engine/input"
import scene "mirai:engine/scene"

@(private="file")
Spawn_World :: struct {
    using world:core.Test_World,
    bodies:core.Table(Seat_Body),
    points:core.Table(Spawn_Point),
    seats:core.Table(input.Seat),
    hierarchy:core.Hierarchy,
}

@(test)
a_body_given_to_a_seat_goes_when_the_seat_goes :: proc(t:^testing.T) {
    w:Spawn_World
    if !core.test_world_init(t,&w,input.test_types) {return}
    defer core.test_world_destroy(&w)
    es,bodies,hierarchy:=&w.entities,&w.bodies,&w.hierarchy
    seat,given,other:=core.create(es),core.create(es),core.create(es)
    core.add(bodies,given,Seat_Body{seat})
    core.add(&w.seats,seat,input.Seat{body=other})
    core.test_world_settle(&w)
    spawn_seat_bodies({entities=es},core.ref(hierarchy),core.read(bodies))
    core.test_world_settle(&w)
    testing.expect(t,core.alive(es,given),"a body stays while its seat is there")
    core.destroy(es,seat)
    core.test_world_settle(&w)
    spawn_seat_bodies({entities=es},core.ref(hierarchy),core.read(bodies))
    core.test_world_settle(&w)
    testing.expect(t,!core.alive(es,given),"the body spawn gave goes with its seat")
    testing.expect(t,core.alive(es,other),"a body nobody gave is left to the game")
}

// Without a point asked for, the points are taken in turn; a body needs a
// point with a prefab, and a point asked for is the one used. Seats get
// bodies by themselves while a prefab is named: by the project or a point.
@(test)
spawn_points_are_taken_in_turn_or_as_asked :: proc(t:^testing.T) {
    w:Spawn_World
    if !core.test_world_init(t,&w,input.test_types) {return}
    defer core.test_world_destroy(&w)
    es,points:=&w.entities,&w.points
    bare,first,second:=core.create(es),core.create(es),core.create(es)
    core.add(points,bare,Spawn_Point{})
    core.add(points,first,Spawn_Point{prefab={1,1}})
    core.add(points,second,Spawn_Point{prefab={1,2}})
    core.test_world_settle(&w)
    spawning:Spawning
    problems:core.Problems
    a:=Apply{points=core.read(points),spawning=&spawning,problems=&problems}
    picked:[4]core.Entity
    for &e in picked {e,_=spawn_pick(&a,core.NONE,core.NONE,true)}
    testing.expect_value(t,picked,[4]core.Entity{first,second,first,second})
    any,_:=spawn_pick(&a,core.NONE,core.NONE,false)
    testing.expect_value(t,any,bare)
    asked,_:=spawn_pick(&a,core.NONE,second,true)
    testing.expect_value(t,asked,second)
    _,ok:=spawn_pick(&a,core.NONE,core.create(es),true)
    testing.expect(t,!ok && core.problem_find(&problems,core.NONE,"spawn.not_a_point")!=nil)
    testing.expect_value(t,problems.count,1)

    testing.expect(t,prefab_found(&a),"a point names a body")
    core.remove(points,first)
    core.remove(points,second)
    core.test_world_settle(&w)
    testing.expect(t,!prefab_found(&a),"no body is named: the game gives them")
    a.settings.prefab={1,9}
    testing.expect(t,prefab_found(&a),"the project names one")
}

// Where the Play of the editor asks, player 1 gets its first body before any
// point, of the prefab of a point when the project has none; the other
// seats, and player 1 afterwards, take the points.
@(test)
the_place_the_editor_asks_comes_before_the_points_for_player_1_once :: proc(t:^testing.T) {
    w:Spawn_World
    if !core.test_world_init(t,&w,input.test_types) {return}
    defer core.test_world_destroy(&w)
    es,points,seats:=&w.entities,&w.points,&w.seats
    point,first,second,remote:=core.create(es),core.create(es),core.create(es),core.create(es)
    core.add(points,point,Spawn_Point{prefab={1,1}})
    core.add(seats,first,input.Seat{slot=0})
    core.add(seats,second,input.Seat{slot=1})
    core.add(seats,remote,input.Seat{slot=0,peer=7})
    core.test_world_settle(&w)
    spawning:Spawning
    problems:core.Problems
    a:=Apply{seats=core.read(seats),points=core.read(points),spawning=&spawning,origin=scene.Play_Origin{set=true,asked=true},problems=&problems}
    cases:=[?]struct{seat:core.Entity,given:bool,point:core.Entity,asked:bool}{
        {second,false,point,false},
        {remote,false,point,false},
        {first,false,point,true},
        {first,true,point,false},
    }
    for c in cases {
        spawning.asked_given=c.given
        at,asked,ok:=spawn_where(&a,{kind=.Spawn,seat=c.seat})
        testing.expect(t,ok)
        testing.expect_value(t,at,c.point)
        testing.expect_value(t,asked,c.asked)
    }
    spawning.asked_given=false
    a.settings.prefab={1,9}
    at,asked,_:=spawn_where(&a,{kind=.Spawn,seat=first})
    testing.expect(t,at==core.NONE && asked,"the body of the project needs no point")
    a.origin.asked=false
    at,asked,_=spawn_where(&a,{kind=.Spawn,seat=first})
    testing.expect(t,at==point && !asked,"the camera of a Play not asked from a place leaves the points first")
    testing.expect_value(t,problems.count,0)
}
