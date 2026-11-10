package spawn

import "mirai:core"
import input "mirai:engine/input"
import scene "mirai:engine/scene"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"

// Bodies for the seats. A Spawn_Point is a place where bodies appear, with the
// prefab of the body of a player there, or else Spawn_Settings.prefab, the
// body of the project. While a body is to be had (the project names one, or a
// point does), every seat (local or of a connection) that has no body gets
// one: it arrived, its body was destroyed, it came back. spawn gives a seat a body when the game
// asks, and respawn places an existing body at a point. Without a point asked
// for, the points are used in turn, in the order of the table. On a client
// the server decides: it spawns nothing. In the Play of the editor a body
// without a point appears where the editor put the player (Play_Origin); one
// it asked for there (Play from here) is the first body of player 1, before
// any point.

SPAWN_CAPACITY :: 8 // bodies that appear for seats in one tick
SPAWN_RETRY :: 0.5  // s the seats wait after a body could not appear for one

@(component,description="A place where the bodies of the players appear: for each seat that has none, a body of its prefab, or else of the project setting Spawn_Settings.prefab.")
Spawn_Point :: struct {
    prefab:base.Asset_Id, // the body of a player here; none: the one of Spawn_Settings
}

// A body that appeared for a seat: it goes when its seat goes (a player who
// left the game).
@(component,description="A body the spawn library gave to a seat: it is destroyed when that seat goes away.")
Seat_Body :: struct {}

// How spawn gives bodies to the players. A project setting.
@(storage,setting)
Spawn_Settings :: struct {
    prefab:base.Asset_Id, // the body of a player where the request and the point name none; none and no point with one: the game gives them bodies
}

// What this library derives while the world runs.
@(storage)
Spawning :: struct {
    next:u32,         // the point that comes next in turn
    retry_after:u64,  // tick before which the seats without a body wait
    asked_given:bool, // player 1 got its body where the Play of the editor asked
}

// The bodies placed in this tick where the Play of the editor put the player
// and not at a Spawn_Point: a library that knows their shape fits them
// there (spawn_physics).
@(storage)
Spawned_At_Origin :: struct {
    using queue:core.Events(core.Entity),
}

Spawn_Kind :: enum u8 {
    Spawn,   // a body appears at a spawn point and seat drives it
    Respawn, // entity (a body) is placed at a spawn point
}

Spawn_Request :: struct {
    kind:Spawn_Kind,
    seat:core.Entity,
    entity:core.Entity,
    point:core.Entity,     // none: the next one in turn
    path:[scene.SCENE_PATH_CAPACITY]u8 `mirai:"text"`, // of the prefab; empty: the one of the point
}

@(storage,queue)
Spawn_Requests :: struct {
    using queue:core.Queue(Spawn_Request),
}

// A body for seat at point (none: the next one in turn), of the prefab at
// path of the assets ("": the one of the point).
spawn :: proc(r:^Spawn_Requests,seat:core.Entity,path:="",point:=core.NONE) {
    request:=Spawn_Request{kind=.Spawn,seat=seat,point=point}
    base.text_set(request.path[:],path)
    core.push(&r.queue,request)
}
// Places body at point (none: the next one in turn).
respawn :: proc(r:^Spawn_Requests,body:core.Entity,point:=core.NONE) {
    core.push(&r.queue,Spawn_Request{kind=.Respawn,entity=body,point=point})
}

@(private)
Apply :: struct {
    commands:core.Commands,
    assets:^host.Assets,
    bodies:^core.Table(Seat_Body),
    seats:core.Read(input.Seat),
    points:core.Read(Spawn_Point),
    placer:core.Placer,
    driving:^input.Seat_Requests,
    spawning:^Spawning,
    settings:Spawn_Settings,
    origin:scene.Play_Origin,
    at_origin:^Spawned_At_Origin,
    given:[SPAWN_CAPACITY]core.Entity, // the seats a body appeared for in this tick
    given_count:int,
    problems:^core.Problems,
}

// The bodies whose seat went away go with it, before input_drive lets go of them.
@(step="fixed",stage="input",before="input_drive")
spawn_seat_bodies :: proc(es:core.Commands,hierarchy:core.Ref(core.Hierarchy),bodies:core.Read(Seat_Body),drivables:core.Read(input.Drivable)) {
    for row in 0..<core.count(bodies) {
        body:=core.entity_at(bodies,row)
        driven,_:=core.get(drivables,body)
        if driven.seat!=core.NONE && !core.alive(es.entities,driven.seat) {core.destroy_tree(es.entities,hierarchy,body)}
    }
}

// Before driving in the tick (input_drive), which gives the bodies that
// appear to their seats in the same tick.
@(step="fixed",stage="input",after="input_seats")
spawn_step :: proc(
    commands:core.Commands,assets:^host.Assets,drivables:core.Read(input.Drivable),bodies:^core.Table(Seat_Body),
    seats:core.Read(input.Seat),points:core.Read(Spawn_Point),placer:core.Placer,driving:^input.Seat_Requests,requests:^Spawn_Requests,spawning:^Spawning,
    settings:core.Ref(Spawn_Settings),network:core.Ref(core.Network),time:core.Time,origin:core.Ref(scene.Play_Origin),at_origin:^Spawned_At_Origin,problems:^core.Problems,
) {
    a:=Apply{commands=commands,assets=assets,bodies=bodies,seats=seats,points=points,placer=placer,driving=driving,spawning=spawning,at_origin=at_origin,problems=problems}
    if settings.ptr!=nil {a.settings=settings.ptr^}
    if origin.ptr!=nil {a.origin=origin.ptr^}
    client:=network.role==.Client
    for request in core.take(&requests.queue) {
        switch request.kind {
        case .Spawn:
            if client {
                core.report(problems,request.seat,"spawn.client_spawn","a client asked to spawn a body for this seat: in a network game the server gives bodies; ask on the server, or give Spawn_Settings.prefab the body of the players")
            } else {spawn_body(&a,request)}
        case .Respawn:
            respawn_body(&a,request)
        }
    }
    if client || !core.due(time,spawning.retry_after) || !prefab_found(&a) {return}
    for row in 0..<core.count(seats) {
        seat:=core.entity_at(seats,row)
        if input.body_of(drivables,seat)!=core.NONE {continue}
        given:=false
        for other in a.given[:a.given_count] {given ||= other==seat}
        if given {continue}
        if !spawn_body(&a,{kind=.Spawn,seat=seat}) {
            spawning.retry_after=core.deadline(time,SPAWN_RETRY)
            return
        }
    }
}

// Whether a seat can be given a body without naming its prefab: the project
// names one, or a point does.
@(private)
prefab_found :: proc(a:^Apply) -> bool {
    if a.settings.prefab!={} {return true}
    for point in a.points.table.values[:core.count(a.points)] {
        if point.prefab!={} {return true}
    }
    return false
}

// The point asked for, or else the next one in turn that has what is needed;
// without one it is a problem of subject.
@(private)
spawn_pick :: proc(a:^Apply,subject,asked:core.Entity,needs_prefab:bool) -> (point:core.Entity,ok:bool) {
    if asked!=core.NONE {
        if !core.has(a.points,asked) {
            core.report(a.problems,subject,"spawn.not_a_point","entity 0x%016x was asked as a spawn point and has no Spawn_Point; give it one, or ask for no point to take the next one in turn",u64(asked))
            return
        }
        return asked,true
    }
    count:=core.count(a.points)
    for i in 0..<count {
        row:=int((a.spawning.next+u32(i))%u32(count))
        if needs_prefab && a.points.table.values[row].prefab=={} {continue}
        a.spawning.next=u32(row+1)
        return core.entity_at(a.points,row),true
    }
    // In the Play of the editor a body without a point appears at its camera.
    if a.origin.set {return core.NONE,true}
    if needs_prefab {
        core.report(a.problems,subject,"spawn.no_spawn_point","no Spawn_Point has a prefab to spawn for this seat; give a Spawn_Point a prefab, give Spawn_Settings.prefab the body of the project, or spawn with a prefab")
    } else {
        core.report(a.problems,subject,"spawn.no_spawn_point","the scene has no Spawn_Point to place this body at; add one")
    }
    return
}

// Where a point is in the world, from the locals: a point of a scene that
// loaded in this frame has no world transform yet.
@(private)
spawn_place :: proc(a:^Apply,point:core.Entity) -> (placed:mm.Transform,ok:bool) {
    placed,ok=core.world_of(core.read(a.placer.transforms),a.placer.parents,point)
    if !ok {core.report(a.problems,point,"spawn.spawn_point_place","this Spawn_Point or a parent of it has no Transform, so bodies have no place to appear at; give them one")}
    return
}

// A body appears at a point, and the seat of the request drives it in the same tick.
@(private)
spawn_body :: proc(a:^Apply,r:Spawn_Request) -> bool {
    if r.seat!=core.NONE && a.given_count>=SPAWN_CAPACITY {
        core.report(a.problems,r.seat,"spawn.spawns_full","no body was spawned for this seat: %d bodies for seats were spawned in this tick, as many as fit; spawn fewer in one tick",SPAWN_CAPACITY)
        return false
    }
    point,asked:=spawn_where(a,r) or_return
    path:=r.path
    prefab:base.Asset_Id
    if path[0]==0 {
        if point!=core.NONE {prefab=core.at(a.points,core.row_of(a.points,point)).prefab}
        if prefab=={} {prefab=a.settings.prefab}
        if prefab=={} {
            core.report(a.problems,point!=core.NONE?point:r.seat,"spawn.no_prefab","a body was asked without a prefab where no point has one; give the point a prefab, Spawn_Settings.prefab the body of the project, or spawn with one")
            return false
        }
    }
    placed:=mm.Transform{a.origin.position,a.origin.rotation,{1,1,1}}
    if point!=core.NONE && !asked {placed=spawn_place(a,point) or_return}
    spawner:=scene.Spawner{a.commands,a.assets,a.problems}
    at:=core.Transform{placed.position,placed.rotation,{1,1,1}}
    root:=path[0]==0?scene.spawn(spawner,prefab,at,transient=true):scene.spawn(spawner,base.text_get(path[:]),at,transient=true)
    if root==core.NONE {return false}
    if asked || point==core.NONE {core.push(&a.at_origin.queue,root)}
    if asked {a.spawning.asked_given=true}
    if r.seat!=core.NONE {
        a.given[a.given_count]=r.seat
        a.given_count+=1
        input.drive(a.driving,r.seat,root)
        core.add(a.bodies,root,Seat_Body{})
    }
    return true
}

@(private)
respawn_body :: proc(a:^Apply,r:Spawn_Request) -> bool {
    point:=spawn_pick(a,r.entity,r.point,false) or_return
    placed:=mm.Transform{a.origin.position,a.origin.rotation,{1,1,1}}
    if point!=core.NONE {placed=spawn_place(a,point) or_return}
    if !core.place(a.placer,r.entity,placed.position,placed.rotation) {
        core.report(a.problems,r.entity,"spawn.respawn_place","this body could not be placed at Spawn_Point 0x%016x: it has no Transform, or a parent of it has a scale of zero; give it a Transform and its parents a scale",u64(point))
        return false
    }
    if point==core.NONE {core.push(&a.at_origin.queue,r.entity)}
    return true
}

// The point of a request (spawn_pick), and whether its body appears instead
// where the Play of the editor asked: once, for player 1, the body the scene
// gives it there (the point only lends its prefab; none with a prefab of its own).
@(private)
spawn_where :: proc(a:^Apply,r:Spawn_Request) -> (point:core.Entity,asked,ok:bool) {
    needs_prefab:=r.path[0]==0 && a.settings.prefab=={}
    if a.origin.asked && !a.spawning.asked_given && r.point==core.NONE && seat_first(a.seats,r.seat) {
        if !needs_prefab {return core.NONE,true,true}
        point,ok=spawn_pick(a,r.seat,core.NONE,true)
        return point,true,ok
    }
    point,ok=spawn_pick(a,r.seat,r.point,needs_prefab)
    return
}

// Player 1 of this machine.
@(private)
seat_first :: proc(seats:core.Read(input.Seat),seat:core.Entity) -> bool {
    s,ok:=core.get(seats,seat)
    return ok && input.seat_local(s) && s.slot==0
}
