package game

import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:strings"
import "mirai:core"
import destruct "plugins:destruct/runtime"
import gui "mirai:engine/gui"
import inp "mirai:engine/input"
import locomotion "plugins:locomotion/runtime"
import phys "plugins:physics/runtime"
import render "mirai:engine/render"
import scene "mirai:engine/scene"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"

// The game of the demo project, for the scenes in ../assets. The
// player is a character of the physics world that walks on the colliders of
// the level, driven by these input actions:
//   move   W A S D, left stick      look   mouse, right stick
//   jump   Space, South             use    E, West: opens or closes a door,
//   throw  left button, right              or changes the material of a
//          trigger: a glowing cube         sample, when you stand near it;
//          that breaks what is destructible  turns a light switch
//   flashlight  F, East: turns the flashlight of the horror house
// Escape frees the mouse and captures it again. Spin, Bob, Door, Exhibit,
// Swatch and Pulse are given to objects in the editor; scenes store
// their values.

LOOK_SPEED :: inp.LOOK_SPEED
VIEW_FOV :: f32(70)*mm.RAD_PER_DEG     // vertical
THROW_SPEED :: f32(12)
CUBE_SECONDS :: f32(8)
PROJECTILE_MASS :: 60   // kg a thrown cube hits a destructible with
PROJECTILE_REACH :: 0.8 // m around the point of the hit that take the blow
// The lamp of a door of the portal chamber, a dim room: nits.
DOOR_OPEN_GLOW   :: [3]f32{3,48,10}
DOOR_CLOSED_GLOW :: [3]f32{48,4,2.4}
// The nose of the dog when it barks, nits, in the light of the control scene.
BARK_GLOW :: [3]f32{64,25,4.8}
// The materials a Swatch walks through, by their paths in the assets.
SWATCH_MATERIALS :: [?]string{
    "surfaces/metal/Chrome.mat","surfaces/metal/Satin metal.mat","surfaces/metal/Brushed steel.mat",
    "surfaces/paint/Lacquer.mat","surfaces/wood/Planks.mat","surfaces/glass/Stained glass.mat","surfaces/neon/Neon sign.mat",
}

THROWN_CUBE :: "characters/player/Thrown cube.scene"

THROWN_CUBE_SIZE :: f32(0.25) // m, the side of a thrown cube

// On a body that opens doors, changes samples and throws cubes: they are
// Interactables it uses with the use action (its Interactor).
@(component,replicated)
Player :: struct {
    thrown:i32 `mirai:"transient"`, // cubes thrown in this run, for the HUD
}

@(component)
Spin :: struct {
    degrees_per_second:[3]f32,
    angles:[3]f32 `mirai:"transient"`, // Euler degrees in X, Y, Z order, added up since the first tick
}

@(component)
Bob :: struct {
    height:f32 `mirai:"min=0,unit=m"`,
    speed:f32,
    base_y:f32 `mirai:"transient"`, // where the entity was when it started
}

// Its Interactable opens and closes it.
@(component)
Door :: struct {
    travel:f32 `mirai:"min=0,unit=m,local"`, // how far it slides up
    speed:f32 `mirai:"min=0,unit=m/s,local"`,
    open:bool,
    lamp:core.Entity `mirai:"local"`,         // glows green while the door is open, red while it is closed
    closed_y:f32 `mirai:"transient,local"`,   // where the door was when it started
}

// A thrown cube: a body that gets its velocity once it exists.
@(component)
Projectile :: struct {
    speed:f32 `mirai:"min=0,unit=m/s"`, // along the forward of the entity
    seconds_left:f32 `mirai:"min=0,unit=s"`, // it goes this long after it is launched
    flight:core.Countdown `mirai:"transient"`, // from its launch; not running before it
    velocity:[3]f32 `mirai:"transient"`,
}

CAPTION_CAPACITY :: 128

// Its caption is shown while the player stands near: the name of the object,
// or caption when the text is longer than a name can be.
@(component)
Exhibit :: struct {
    reach:f32 `mirai:"min=0,unit=m"`,
    caption:[CAPTION_CAPACITY]u8 `mirai:"text"`,
}

// A sample whose material the player changes by using its Interactable.
@(component)
Swatch :: struct {
    index:i32 `mirai:"min=0"`, // which of SWATCH_MATERIALS it shows
}

// Emission that breathes between two shares of what the object has in the scene.
@(component)
Pulse :: struct {
    speed:f32,
    low:f32 `mirai:"min=0"`,
    high:f32 `mirai:"min=0"`,
    base:[3]f32 `mirai:"transient"`, // the emission of the entity when it started
}

SPIN_DEFAULT :: Spin{degrees_per_second={0,90,0}}
BOB_DEFAULT :: Bob{height=0.25,speed=1.5}
DOOR_DEFAULT :: Door{travel=2.9,speed=3}
EXHIBIT_DEFAULT :: Exhibit{reach=4}
PULSE_DEFAULT :: Pulse{speed=2,low=0.3,high=1}
PROJECTILE_DEFAULT :: Projectile{speed=THROW_SPEED,seconds_left=CUBE_SECONDS}

// The actions the game reads, those of interface_demo.odin too; move and look are of the engine
// (inp.Move_Action, inp.Look_Action) and jump of the locomotion (locomotion.Walk_Action).
@(actions)
Action :: enum u8 {
    Use,Flashlight,Throw,Bark,Switch_Body,Overhead_View,
    Gallery_Previous,Gallery_Next,Gallery_Overview,Physics_Reset,
    Portal_Blue,Portal_Orange,Grab,Camera_Mode,Aim,
    Hud_Style,Interface_Menu,Inventory,Talk,
}

// Their bindings. The editor (Project Settings > Input), settings.set and the
// player keep in Input_Settings of settings.mirai only what they change of these.
action_defaults :: proc "contextless" () -> [Action]inp.Action_Bindings {
    key :: inp.binding_key
    pad :: inp.binding_gamepad_button
    mouse :: inp.binding_mouse_button
    trigger :: inp.binding_gamepad_axis
    return {
        .Use=inp.action_default(.Button,key(.E),pad(.West)),
        .Flashlight=inp.action_default(.Button,key(.F),pad(.East)),
        .Throw=inp.action_default(.Button,mouse(.Left),trigger(.Right_Trigger)),
        .Bark=inp.action_default(.Button,key(.E),pad(.West)),
        .Switch_Body=inp.action_default(.Button,key(.Tab),pad(.North)),
        .Overhead_View=inp.action_default(.Button,key(.V),pad(.Right_Shoulder)),
        .Gallery_Previous=inp.action_default(.Button,key(.Left)),
        .Gallery_Next=inp.action_default(.Button,key(.Right)),
        .Gallery_Overview=inp.action_default(.Button,key(.Home)),
        .Physics_Reset=inp.action_default(.Button,key(.R)),
        .Portal_Blue=inp.action_default(.Button,mouse(.Left),trigger(.Left_Trigger)),
        .Portal_Orange=inp.action_default(.Button,mouse(.Right),pad(.Left_Shoulder)),
        .Grab=inp.action_default(.Button,key(.E),pad(.West)),
        .Camera_Mode=inp.action_default(.Button,key(.C),pad(.Left_Stick)),
        .Aim=inp.action_default(.Button,mouse(.Right),trigger(.Left_Trigger)),
        .Hud_Style=inp.action_default(.Button,key(.H),pad(.Dpad_Up)),
        .Interface_Menu=inp.action_default(.Button,key(.M),pad(.Dpad_Down)),
        .Inventory=inp.action_default(.Button,key(.I),pad(.Back)),
        .Talk=inp.action_default(.Button,key(.T),pad(.Right_Stick)),
    }
}

// The Menu action blocks the actions of the focused seat, and a blocked look frees the mouse; again,
// it gives them back. The seat keeps driving its body.
@(step="frame")
game_menu :: proc(events:core.Ref(gui.UI_Events),state:core.Ref(inp.Seats),seats:^core.Table(inp.Seat,.Read),requests:^inp.Seat_Requests) {
    if !gui.menu_pressed(events) {return}
    seat:=inp.focused(state,seats)
    if seat==core.NONE {return}
    if inp.blocking(state,seat) {inp.input_unblock(requests,seat)} else {inp.input_block(requests,seat,seat)}
}

swatch_index :: proc(swatch:Swatch) -> int {return int(swatch.index)%%len(SWATCH_MATERIALS)}

@(params)
Demo_Controls :: struct {
    aims:inp.Aims,
    actions:inp.Input_Of(Action),
}

// A cube that the seat of a body throws where it aims.
@(step="fixed")
game_throw :: proc(players:^core.Table(Player),controls:Demo_Controls,spawner:scene.Spawner) {
    for row in 0..<core.count(players) {
        e:=core.entity_at(players,row)
        if origin,aim,turn,aimed:=inp.aim(controls.aims,e);aimed && inp.pressed(controls.actions,e,.Throw) {
            scene.spawn(spawner,THROWN_CUBE,{origin+aim*0.8,turn,THROWN_CUBE_SIZE},transient=true)
            core.edit_at(players,row).thrown+=1
        }
    }
}

// A door used opens or closes. Doors slide towards where they are, or a button pressed for them,
// says, at a constant speed; one that is a body as a kinematic request.
@(step="fixed")
game_doors :: proc(
    doors:^core.Table(Door),buttons:^core.Table(Floor_Button,.Read),used:core.Ref(scene.Interaction_Events),
    transforms:^core.Table(core.Transform),worlds:^core.Table(core.World_Transform,.Read),bodies:^phys.Body_Requests,
    names:^core.Table(core.Name,.Read),time:core.Time,
) {
    for event in used.items {
        if event.kind!=.Completed {continue}
        if door:=core.edit(doors,event.target);door!=nil {
            door.open=!door.open
            log.infof("%s %s",core.name_get(names,event.target),door.open?"opened":"closed")
        }
    }
    for row in 0..<core.count(doors) {
        e:=core.entity_at(doors,row)
        placed,has_place:=core.get(transforms,e)
        if !has_place {continue}
        if core.added(doors,row) {core.edit_at(doors,row).closed_y=placed.position.y}
        door:=core.at(doors,row)
        target:=door.closed_y+(door_opened(doors,buttons,e)?door.travel:0)
        if placed.position.y==target {continue}
        rise:=clamp(target-placed.position.y,-door.speed*time.dt,door.speed*time.dt)
        if local:=core.free(transforms,e);local!=nil {
            local.position.y+=rise
        } else if world,body:=core.get(worlds,e);body {
            // Up in the frame of its parent: its world turn without its own.
            up:=mm.quat_rotate(world.rotation*conj(placed.rotation),[3]f32{0,rise,0})
            phys.move_kinematic(bodies,e,world.position+up,world.rotation)
        }
    }
}

// A sample used shows the next material; what it shows follows its index, wherever the index was
// decided.
@(step="fixed")
game_swatches :: proc(meshes:^core.Table(render.Mesh_Renderer),swatches:^core.Table(Swatch),used:core.Ref(scene.Interaction_Events),assets:^host.Assets) {
    for event in used.items {
        if event.kind!=.Completed {continue}
        if swatch:=core.edit(swatches,event.target);swatch!=nil {swatch.index=i32((swatch_index(swatch^)+1)%len(SWATCH_MATERIALS))}
    }
    paths:=SWATCH_MATERIALS
    for row in 0..<core.count(swatches) {
        at:=core.row_of(meshes,core.entity_at(swatches,row))
        wanted,found:=host.assets_id(assets,paths[swatch_index(core.at(swatches,row))])
        if at<0 || !found {continue}
        for material in core.view_at(meshes,at).materials {
            if material==wanted {continue}
            for &value in core.edit_at(meshes,at).materials {value=wanted}
            break
        }
    }
}

// The pose of a body belongs to the simulation: a spinning or bobbing body gets
// it as one kinematic request with both motions, the rest is written in place.
@(step="fixed")
game_animate :: proc(
    spins:^core.Table(Spin),bobs:^core.Table(Bob),transforms:^core.Table(core.Transform),
    worlds:^core.Table(core.World_Transform,.Read),bodies:^phys.Body_Requests,time:core.Time,
) {
    seconds:=f32(time.seconds)
    for row in 0..<core.count(spins) {
        e:=core.entity_at(spins,row)
        local:=core.free(transforms,e)
        placed,body:=core.get(worlds,e)
        if local==nil && !body {continue}
        spin:=core.at(spins,row)
        angles:=spin.angles
        if core.added(spins,row) {angles=mm.quat_to_euler(local!=nil?local.rotation:placed.rotation)*mm.DEG_PER_RAD}
        angles+=spin.degrees_per_second*time.dt
        for &angle in angles {angle=math.mod(angle,360)}
        if spin.angles!=angles {core.edit_at(spins,row).angles=angles}
        turned:=mm.quat_from_euler(angles*mm.RAD_PER_DEG)
        if local!=nil {
            local.rotation=turned
            continue
        }
        position:=placed.position
        if at:=core.row_of(bobs,e);at>=0 {position.y=bob_height(bobs,at,position.y,seconds)}
        phys.move_kinematic(bodies,e,position,turned)
    }
    for row in 0..<core.count(bobs) {
        e:=core.entity_at(bobs,row)
        if local:=core.free(transforms,e);local!=nil {
            local.position.y=bob_height(bobs,row,local.position.y,seconds)
        } else if placed,body:=core.get(worlds,e);body && !core.has(spins,e) {
            phys.move_kinematic(bodies,e,{placed.position.x,bob_height(bobs,row,placed.position.y,seconds),placed.position.z},placed.rotation)
        }
    }
}

@(private="file")
bob_height :: proc(bobs:^core.Table(Bob),row:int,y,seconds:f32) -> f32 {
    if core.added(bobs,row) {core.edit_at(bobs,row).base_y=y}
    bob:=core.at(bobs,row)
    return bob.base_y+math.sin(seconds*bob.speed)*bob.height
}

// Emission: pulses breathe, the lamp of a door shows its state, the nose of a dog flashes when it barks.
@(step="fixed")
game_glow :: proc(
    tints:^core.Table(render.Material_Values),pulses:^core.Table(Pulse),doors:^core.Table(Door,.Read),buttons:^core.Table(Floor_Button,.Read),barkers:^core.Table(Barker,.Read),
    hierarchy:core.Ref(core.Hierarchy),names:^core.Table(core.Name,.Read),time:core.Time,
) {
    seconds:=f32(time.seconds)
    for row in 0..<core.count(pulses) {
        entity:=core.entity_at(pulses,row)
        at:=core.row_of(tints,entity)
        if at<0 {continue}
        tint:=core.view_at(tints,at)
        pulse:=core.at(pulses,row)
        if core.added(pulses,row) {
            pulse.base=tint.emission
            core.edit_at(pulses,row).base=pulse.base
        }
        wave:=0.5+0.5*math.sin(seconds*pulse.speed)
        glow_set(tints,entity,pulse.base*(pulse.low+(pulse.high-pulse.low)*wave))
    }
    for row in 0..<core.count(doors) {
        door:=core.at(doors,row)
        glow:=door_opened(doors,buttons,core.entity_at(doors,row))?DOOR_OPEN_GLOW:DOOR_CLOSED_GLOW
        glow_set(tints,door.lamp,glow)
    }
    for row in 0..<core.count(buttons) {
        button:=core.at(buttons,row)
        glow:=button.pressed?DOOR_OPEN_GLOW:DOOR_CLOSED_GLOW
        glow_set(tints,button.plate,glow)
    }
    for row in 0..<core.count(barkers) {
        flashing:=core.countdown_running(core.at(barkers,row).flash,time)
        for child:=core.first_child(hierarchy,core.entity_at(barkers,row));child!=core.NONE;child=core.next_sibling(hierarchy,child) {
            if core.name_get(names,child)!="Nose" {continue}
            glow_set(tints,child,flashing?BARK_GLOW:[3]f32{})
        }
    }
}

// A thrown cube is a body: it is launched the first tick its body exists,
// tumbles and bounces on its own, and goes after CUBE_SECONDS. A destructible
// it strikes takes a blow of its velocity before the strike times PROJECTILE_MASS;
// destruct leaves alone what is not one.
@(step="fixed",stage="react")
game_projectiles :: proc(
    es:core.Commands,projectiles:^core.Table(Projectile),transforms:^core.Table(core.Transform,.Read),body_states:^core.Table(core.Motion,.Read),
    events:core.Ref(phys.Physics_Events),bodies:^phys.Body_Requests,
    damage:^destruct.Destruct_Requests,time:core.Time,
) {
    strike :: proc(projectiles:^core.Table(Projectile),damage:^destruct.Destruct_Requests,cube,struck:core.Entity,point:[3]f32) {
        if projectile,found:=core.get(projectiles,cube);found && projectile.flight.active {
            destruct.damage(damage,struck,point,PROJECTILE_REACH,projectile.velocity*PROJECTILE_MASS)
        }
    }
    for contact in events.contact_begin.items {
        strike(projectiles,damage,contact.a,contact.b,contact.point)
        strike(projectiles,damage,contact.b,contact.a,contact.point)
    }
    for row in 0..<core.count(projectiles) {
        e:=core.entity_at(projectiles,row)
        projectile:=core.at(projectiles,row)
        motion,moving:=core.get(body_states,e)
        switch {
        case !projectile.flight.active:
            local,placed:=core.get(transforms,e)
            if !moving || !placed {continue}
            launched:=core.edit_at(projectiles,row)
            launched.velocity=mm.quat_forward(local.rotation)*projectile.speed
            core.countdown_start(&launched.flight,time,projectile.seconds_left)
            phys.set_velocity(bodies,e,launched.velocity,{6,4,0})
        case core.countdown_ended(projectile.flight,time):
            core.destroy(es,e)
        case moving && projectile.velocity!=motion.linear:
            core.edit_at(projectiles,row).velocity=motion.linear
        }
    }
}

// What the use action does at what the body focuses.
Player_Hint :: enum u8 {None,Open_Door,Close_Door,Swatch}

// What player_hud.ui shows of the body it is on, a person or the dog: the
// screen is on the body, so it shows in the view of its player, and only then.
@(component,description="The HUD of a body a seat drives: the crosshair, the cubes it threw, what the use action does where it stands and the caption of the nearest exhibit.")
Player_Hud :: struct {
    person:bool,      // it throws cubes
    thrown:i32,
    hint:Player_Hint,
    material:[24]u8 `mirai:"text"`, // of the sample it focuses
    captioned:bool,
    caption:[CAPTION_CAPACITY]u8 `mirai:"text"`,
    control:bool,     // the scene hands control between bodies
    dog:bool,
    barks:i32,
}

// The caption of the exhibit nearest to a point, within its reach: its own, or its name.
exhibit_caption :: proc(out:[]u8,exhibits:^core.Table(Exhibit,$A),worlds:^core.Table(core.World_Transform,$B),names:^core.Table(core.Name,$C),from:[3]f32) -> bool {
    found:=false
    distance:=max(f32)
    for row in 0..<core.count(exhibits) {
        e:=core.entity_at(exhibits,row)
        exhibit:=core.at(exhibits,row)
        placed,has:=core.get(worlds,e)
        if !has {continue}
        away:=linalg.distance(placed.position,from)
        if away>=exhibit.reach || away>=distance {continue}
        caption:=base.text_get(exhibit.caption[:])
        if caption=="" {caption=core.name_get(names,e)}
        if caption=="" {continue}
        distance,found=away,true
        base.text_set(out,caption)
    }
    return found
}

@(step="frame")
player_hud :: proc(
    huds:^core.Table(Player_Hud),players:^core.Table(Player,.Read),doors:^core.Table(Door,.Read),swatches:^core.Table(Swatch,.Read),exhibits:^core.Table(Exhibit,.Read),
    barkers:^core.Table(Barker,.Read),demos:^core.Table(Control_Demo,.Read),focus:^core.Table(scene.Interaction_State,.Read),
    worlds:^core.Table(core.World_Transform,.Read),names:^core.Table(core.Name,.Read),
) {
    for row in 0..<core.count(huds) {
        body:=core.entity_at(huds,row)
        next:Player_Hud
        player,has_player:=core.get(players,body)
        barker,has_barker:=core.get(barkers,body)
        if placed,has_world:=core.get(worlds,body);has_world && (has_player || has_barker) {
            next.person,next.thrown=has_player,player.thrown
            next.control,next.dog,next.barks=core.count(demos)>0,has_barker,i32(barker.count)
            focused,_:=core.get(focus,body)
            if door,is_door:=core.get(doors,focused.target);is_door {next.hint=door.open?.Close_Door:.Open_Door}
            if swatch,is_swatch:=core.get(swatches,focused.target);is_swatch {
                next.hint=.Swatch
                // Its name is that of its file.
                materials:=SWATCH_MATERIALS
                path:=materials[swatch_index(swatch)]
                base.text_set(next.material[:],path[strings.last_index_byte(path,'/')+1:len(path)-len(".mat")])
            }
            next.captioned=exhibit_caption(next.caption[:],exhibits,worlds,names,placed.position)
        }
        if core.at(huds,row)!=next {core.edit_at(huds,row)^=next}
    }
}

@(private)
glow_set :: proc(tints:^core.Table(render.Material_Values),entity:core.Entity,emission:[3]f32) {
    if at:=core.row_of(tints,entity);at>=0 && core.view_at(tints,at).emission!=emission {
        core.edit_at(tints,at).emission=emission
    }
}
