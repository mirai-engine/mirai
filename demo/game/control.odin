package game

import "core:math"
import "core:math/linalg"
import "mirai:core"
import cam "mirai:engine/camera"
import anim "plugins:animation/runtime"
import inp "mirai:engine/input"
import render "mirai:engine/render"
import "mirai:engine/scene"
import "mirai:host"
import phys "plugins:physics/runtime"
import "mirai:std/base"
import mm "mirai:std/math"

// The person and its dog. Each player has a seat and gets a person at a spawn
// point (the spawn plugin); here each person gets a dog that Follows
// it: its AI writes the Move_Input of the dog where this end decides. Every
// body a seat drives moves from the actions of its seat. Tab drives the dog
// instead, and the person follows; V blends into the shared overhead camera
// and back; C blends the camera of the body into the next mode.

CONTROL_INTRO :: "Control intro"
CONTROL_SHARED_CAMERA :: "Shared overhead camera"
DOG_BEHIND :: [3]f32{-1.2,0,1.5} // m from its person, in the frame of the person, where a dog appears
OVERHEAD_BLEND :: cam.Camera_Blend{seconds=0.8,ease=.Cubic_In_Out}
CAMERA_CYCLE :: [cam.Camera_Preset]cam.Camera_Preset{.Third_Person=.First_Person,.First_Person=.Isometric,.Isometric=.Top_Down,.Top_Down=.Side,.Side=.Third_Person,.Aim=.Third_Person}

DOG_PREFAB :: "control/Dog.scene"

// An AI that walks its body after the body of its leader while no seat drives it.
@(component,description="An AI walks this body after the leader body while no player drives it.")
Follow :: struct {
    leader:core.Entity,
    distance:f32 `mirai:"min=0,unit=m"`,
}

FOLLOW_DEFAULT :: Follow{distance=2}

@(component,replicated)
Barker :: struct {
    count:u32,
    flash_until:u64, // the tick its nose stops glowing at
}

BARK_FLASH_SECONDS :: 0.3

// Marks the root of the scene of the person and the dog.
@(component)
Control_Demo :: struct {}

dog_character :: proc "contextless" () -> phys.Character {
    dog:=phys.character_default()
    dog.mass=20
    return dog
}

dog_walk :: proc "contextless" () -> phys.Walk {
    dog:=player_walk()
    dog.max_speed=4.5
    return dog
}

// Lower and thinner than the capsule of a person.
dog_capsule :: proc "contextless" () -> phys.Collider {return phys.collider_character(0.25,0.85)}

// What the players ask of their seats; a dog whose person left goes with it.
@(step="fixed")
game_seats :: proc(
    es:core.Commands,follows:^core.Table(Follow),drivables:core.Read(inp.Drivable),
    seats:core.Read(inp.Seat),actions:inp.Input_Of(Action),hierarchy:core.Ref(core.Hierarchy),names:core.Read(core.Name),demos:core.Read(Control_Demo),
    requests:^inp.Seat_Requests,shown:core.Ref(cam.Cameras),camera_requests:^cam.Camera_Requests,
    camera_changes:^cam.Camera_Changes,camera_follows:core.Read(cam.Camera_Follow),cameras:core.Read(render.Camera),
) {
    if core.count(demos)==0 {return}
    for row in 0..<core.count(follows) {
        if core.alive(es.entities,core.at(follows,row).leader) {continue}
        core.destroy_tree(es.entities,hierarchy,core.entity_at(follows,row))
    }
    for row in 0..<core.count(seats) {
        seat:=core.entity_at(seats,row)
        body:=inp.body_of(drivables,seat)
        companion:=companion_of(core.read(follows),body)
        if companion!=core.NONE && inp.seat_pressed(actions,seat,.Switch_Body) {
            // The seat drives the dog, and the person follows it.
            inp.drive(requests,seat,companion)
            follow:=core.at(follows,core.row_of(follows,companion))
            follow.leader=companion
            core.remove(follows,companion)
            core.add(follows,body,follow)
        }
        if inp.seat_pressed(actions,seat,.Overhead_View) {
            if cam.camera_overriding(shown.ptr,seat) {
                cam.camera_override_remove(camera_requests,seat)
            } else if camera:=core.entity_named(names,CONTROL_SHARED_CAMERA);camera!=core.NONE {
                cam.camera_override(camera_requests,seat,seat,camera,blend=OVERHEAD_BLEND)
            }
        }
        if owner,driven:=core.get(drivables,body);driven && inp.seat_pressed(actions,seat,.Camera_Mode) {
            next:=cam.Camera_Preset.Third_Person
            if mode,preset:=cam.camera_preset_of(camera_follows,cameras,owner.camera);preset {
                cycle:=CAMERA_CYCLE
                next=cycle[mode]
            }
            cam.camera_mode(camera_changes,owner.camera,next)
        }
    }
}

// Each person gets a dog behind it.
@(step="fixed",server)
game_dogs :: proc(
    spawner:scene.Spawner,follows:core.Read(Follow),drivables:core.Read(inp.Drivable),players:core.Read(Player),
    seats:core.Read(inp.Seat),demos:core.Read(Control_Demo),worlds:core.Read(core.World_Transform),
) {
    if core.count(demos)==0 {return}
    for row in 0..<core.count(seats) {
        body:=inp.body_of(drivables,core.entity_at(seats,row))
        if !core.has(players,body) || companion_of(follows,body)!=core.NONE {continue}
        placed,found:=core.get(worlds,body)
        if !found {continue}
        at:=core.Transform{placed.position+mm.quat_rotate(placed.rotation,DOG_BEHIND),placed.rotation,{1,1,1}}
        if dog:=scene.spawn(spawner,DOG_PREFAB,at);dog!=core.NONE {
            follow:=FOLLOW_DEFAULT
            follow.leader=body
            core.commands_add(spawner.commands,dog,follow)
        }
    }
}

@(private="file")
companion_of :: proc(follows:core.Read(Follow),leader:core.Entity) -> core.Entity {
    for row in 0..<core.count(follows) {
        if core.at(follows,row).leader==leader {return core.entity_at(follows,row)}
    }
    return core.NONE
}

// A follower no seat drives turns to the body of its leader and walks until
// it is near, where this end decides what it does.
@(step="fixed")
game_follow :: proc(
    follows:core.Read(Follow),drivables:core.Read(inp.Drivable),moves:^core.Table(inp.Move_Input),
    worlds:core.Read(core.World_Transform),remotes:core.Read(core.Remote),
) {
    for row in 0..<core.count(follows) {
        e:=core.entity_at(follows,row)
        follow:=core.at(follows,row)
        move:=core.edit(moves,e)
        placed,here:=core.get(worlds,e)
        goal,there:=core.get(worlds,follow.leader)
        if move==nil || !here || !there || inp.seat_of(drivables,e)!=core.NONE || !core.owned(remotes,e) {continue}
        delta:=goal.position-placed.position
        delta.y=0
        distance:=linalg.length(delta)
        move.move,move.buttons={},{}
        if distance<=max(follow.distance,0.5) {continue}
        move.look_yaw=mm.yaw_of_direction(delta)
        move.move.z=-min(distance-follow.distance,1)
    }
}

// A bark counts when its seat presses bark or the intro asks for it, and flashes the nose for a moment.
@(step="fixed",stage="react")
game_barker :: proc(
    barkers:^core.Table(Barker),actions:inp.Input_Of(Action),events:core.Ref(anim.Animation_Events),time:core.Time,
) {
    intro_bark:=false
    for event in events.items {intro_bark ||= event.kind==.Marker && event.name==base.name_hash("intro.bark")}
    for row in 0..<core.count(barkers) {
        if intro_bark || inp.pressed(actions,core.entity_at(barkers,row),.Bark) {
            barker:=core.edit_at(barkers,row)
            barker.count+=1
            barker.flash_until=core.deadline(time,BARK_FLASH_SECONDS)
        }
    }
}

Actor_Part :: struct {name:string,position,scale:[3]f32,color:[4]f32}
HUMAN_PARTS :: [?]Actor_Part{
    {"Torso",{0,1.15,0},{0.45,0.6,0.28},{0.05,0.15,0.8,1}},
    {"Head",{0,1.6,0},{0.35,0.35,0.35},{1,0.78,0.12,1}},
    {"Arm left",{-0.32,1.12,0},{0.12,0.6,0.12},{1,0.78,0.12,1}},
    {"Arm right",{0.32,1.12,0},{0.12,0.6,0.12},{1,0.78,0.12,1}},
    {"Leg left",{-0.13,0.42,0},{0.16,0.8,0.18},{0.05,0.15,0.8,1}},
    {"Leg right",{0.13,0.42,0},{0.16,0.8,0.18},{0.05,0.15,0.8,1}},
}
DOG_PARTS :: [?]Actor_Part{
    {"Body",{0,0.5,0},{0.42,0.34,0.7},{0.65,0.43,0.2,1}},
    {"Head",{0,0.74,-0.38},{0.33,0.3,0.35},{0.75,0.52,0.28,1}},
    {"Nose",{0,0.68,-0.6},{0.16,0.14,0.17},{0.15,0.09,0.04,1}},
    {"Ear left",{-0.12,0.94,-0.37},{0.09,0.2,0.14},{0.65,0.43,0.2,1}},
    {"Ear right",{0.12,0.94,-0.37},{0.09,0.2,0.14},{0.65,0.43,0.2,1}},
    {"Leg front left",{-0.15,0.2,-0.22},{0.09,0.4,0.1},{0.6,0.4,0.18,1}},
    {"Leg front right",{0.15,0.2,-0.22},{0.09,0.4,0.1},{0.6,0.4,0.18,1}},
    {"Leg back left",{-0.15,0.2,0.22},{0.09,0.4,0.1},{0.6,0.4,0.18,1}},
    {"Leg back right",{0.15,0.2,0.22},{0.09,0.4,0.1},{0.6,0.4,0.18,1}},
    {"Tail",{0,0.65,0.4},{0.08,0.3,0.08},{0.65,0.43,0.2,1}},
}

Actor_Parts :: struct {items:[len(DOG_PARTS)]Actor_Part,count:int}

// The rigid cubes that show a person or a dog, children of its body.
actor_parts :: proc(dog:bool) -> (parts:Actor_Parts) {
    if dog {
        for part,i in DOG_PARTS {parts.items[i]=part}
        parts.count=len(DOG_PARTS)
    } else {
        for part,i in HUMAN_PARTS {parts.items[i]=part}
        parts.count=len(HUMAN_PARTS)
    }
    return
}
