package spawn

import "core:testing"
import "mirai:core"
import input "mirai:engine/input"
import scene "mirai:engine/scene"

@(private)
@(test_world)
Spawn_World :: struct {
    using world:Test_World,
    bodies:core.Table(Seat_Body),
    points:core.Table(Spawn_Point),
    seats:core.Table(input.Seat),
    transforms:core.Table(core.Transform),
    parents:core.Table(core.Parent),
    hierarchy:core.Hierarchy,
    places:core.Places,
    jumps:core.Jumps,
}

@(test)
a_body_given_to_a_seat_goes_when_the_seat_goes :: proc(t:^testing.T) {
    w:Spawn_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    es,bodies,hierarchy:=&w.entities,&w.bodies,&w.hierarchy
    seat,given,other:=core.create(es),core.create(es),core.create(es)
    core.add(bodies,given,Seat_Body{seat})
    core.add(&w.seats,seat,input.Seat{body=other})
    test_world_settle(&w)
    spawn_seat_bodies({entities=es},core.ref(hierarchy),core.read(bodies))
    test_world_settle(&w)
    testing.expect(t,core.alive(es,given),"a body stays while its seat is there")
    core.destroy(es,seat)
    test_world_settle(&w)
    spawn_seat_bodies({entities=es},core.ref(hierarchy),core.read(bodies))
    test_world_settle(&w)
    testing.expect(t,!core.alive(es,given),"the body spawn gave goes with its seat")
    testing.expect(t,core.alive(es,other),"a body nobody gave is left to the game")
}

// Without a point asked for, a seat takes the points of the players in turn
// and the game the others: a point of an enemy never gives a player its body.
// A body needs a point with a prefab, a point asked for is the one used, and
// what the game spawns has no camera of the editor to fall back on. Seats get
// bodies by themselves while a prefab is named: by the project or a point of
// the players.
@(test)
spawn_points_are_taken_in_turn_by_their_kind_or_as_asked :: proc(t:^testing.T) {
    w:Spawn_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    es,points:=&w.entities,&w.points
    bare,first,enemy,second,crate:=core.create(es),core.create(es),core.create(es),core.create(es),core.create(es)
    core.add(points,bare,Spawn_Point{players=true})
    core.add(points,first,Spawn_Point{prefab={1,1},players=true})
    core.add(points,enemy,Spawn_Point{prefab={1,3}})
    core.add(points,second,Spawn_Point{prefab={1,2},players=true})
    core.add(points,crate,Spawn_Point{})
    test_world_settle(&w)
    spawning:Spawning
    problems:core.Problems
    a:=Apply{points=core.read(points),spawning=&spawning,origin=scene.Play_Origin{set=true},problems=&problems}
    cases:=[?]struct{players,needs_prefab:bool,asked,picked:core.Entity}{
        {true,true,core.NONE,first},
        {false,true,core.NONE,enemy},
        {true,true,core.NONE,second},
        {false,true,core.NONE,enemy},
        {true,true,core.NONE,first},
        {true,false,core.NONE,second},
        {false,false,core.NONE,crate},
        {false,true,second,second},
        {true,true,enemy,enemy},
    }
    for c,i in cases {
        picked,ok:=spawn_pick(&a,core.NONE,c.asked,c.players,c.needs_prefab)
        testing.expectf(t,ok && picked==c.picked,"case %d: %v picked, %v wanted",i,picked,c.picked)
    }
    _,ok:=spawn_pick(&a,core.NONE,core.create(es),true,true)
    testing.expect(t,!ok && core.problem_find(&problems,core.NONE,"spawn.not_a_point")!=nil)
    core.destroy(es,enemy)
    test_world_settle(&w)
    _,ok=spawn_pick(&a,core.NONE,core.NONE,false,true)
    testing.expect(t,!ok && core.problem_find(&problems,core.NONE,"spawn.no_spawn_point")!=nil,"a spawn of the game without a point of its kind is a problem, also in the Play of the editor")
    testing.expect_value(t,problems.count,2)

    testing.expect(t,prefab_found(&a),"a point of the players names a body")
    core.remove(points,first)
    core.remove(points,second)
    core.add(points,core.create(es),Spawn_Point{prefab={1,4}})
    test_world_settle(&w)
    testing.expect(t,!prefab_found(&a),"no point of the players names a body; the game's is not for them")
    a.settings.prefab={1,9}
    testing.expect(t,prefab_found(&a),"the project names one")
}

// Where the Play of the editor asks, player 1 gets its first body before any
// point, of the prefab of a point of the players when the project has none;
// the other seats, and player 1 afterwards, take the points of the players.
@(test)
the_place_the_editor_asks_comes_before_the_points_for_player_1_once :: proc(t:^testing.T) {
    w:Spawn_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    es,points,seats:=&w.entities,&w.points,&w.seats
    point,enemy,first,second,remote:=core.create(es),core.create(es),core.create(es),core.create(es),core.create(es)
    core.add(points,point,Spawn_Point{prefab={1,1},players=true})
    core.add(points,enemy,Spawn_Point{prefab={1,3}})
    core.add(seats,first,input.Seat{slot=0})
    core.add(seats,second,input.Seat{slot=1})
    core.add(seats,remote,input.Seat{slot=0,peer=7})
    test_world_settle(&w)
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
    at,asked,_=spawn_where(&a,{kind=.Spawn})
    testing.expect(t,at==enemy && !asked,"what the game spawns takes a point of the game with a prefab, not the body of the project")
    a.origin.asked=false
    at,asked,_=spawn_where(&a,{kind=.Spawn,seat=first})
    testing.expect(t,at==point && !asked,"the camera of a Play not asked from a place leaves the points first")
    testing.expect_value(t,problems.count,0)
}

// A body the game respawns is asked of the owner of its Transform (physics) at its point at rest:
// it stops there instead of keeping the speed it fell at.
@(test)
a_respawned_body_is_placed_at_rest_at_its_point :: proc(t:^testing.T) {
    w:Spawn_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    es:=&w.entities
    point,body:=core.create(es),core.create(es)
    core.add(&w.points,point,Spawn_Point{})
    core.add(&w.transforms,point,core.Transform{position={1,2,3},rotation=1,scale=1})
    core.add(&w.transforms,body,core.Transform{position={0,-40,0},rotation=1,scale=1})
    test_world_settle(&w)
    resize(&w.transforms.owners,core.entity_index(body)+1)
    w.transforms.owners[core.entity_index(body)]=core.Row_Owner{generation=core.entity_generation(body),id=1}
    spawning:Spawning
    problems:core.Problems
    a:=Apply{seats=core.read(&w.seats),points=core.read(&w.points),placer={&w.transforms,core.read(&w.parents),&w.places,&w.jumps},spawning=&spawning,problems=&problems}
    testing.expect(t,respawn_body(&a,{kind=.Respawn,entity=body}))
    asked:=w.places.queue.items[:]
    testing.expect(t,len(asked)==1 && asked[0].entity==body && asked[0].position==[3]f32{1,2,3} && asked[0].at_rest,"it is placed at its point at rest")
    testing.expect_value(t,problems.count,0)
}
