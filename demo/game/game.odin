package game

import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "mirai:core"
import destruct "plugins:destruct/runtime"
import gui "mirai:engine/gui"
import inp "mirai:engine/input"
import phys "plugins:physics/runtime"
import render "mirai:engine/render"
import scene "mirai:engine/scene"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:ui"

// The game of the demo project, for the scenes in ../assets. The
// player is a character of the physics world that walks on the colliders of
// the level, driven by the input actions of ../input.mirai:
//   move   W A S D, left stick      look   mouse, right stick
//   jump   Space, South             use    E, West: opens or closes a door,
//   throw  left button, right              or changes the material of a
//          trigger: a glowing cube         sample, when you stand near it;
//          that breaks what is destructible  turns a light switch
//   flashlight  F, East: turns the flashlight of the horror house
// Escape frees the mouse and captures it again. Spin, Bob, Door, Exhibit,
// Swatch and Pulse are given to objects in the editor; scenes store
// their values. The prefabs of the player and of the thrown cube are written
// by tools/demo_content.

WALK_SPEED :: f32(4)
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
// The materials a Swatch walks through.
SWATCH_MATERIALS :: [?]string{"Chrome","Satin metal","Brushed steel","Lacquer","Planks","Stained glass","Neon sign"}

THROWN_CUBE :: "characters/player/Thrown cube.prefab"

// Hidden has one writer: the scenes ask for it here.
@(storage,queue)
Show_Requests :: struct {queue:core.Queue(Show_Request)}
Show_Request :: struct {entity:core.Entity,hidden:bool}

ask_hidden :: proc(shows:^Show_Requests,e:core.Entity,hidden:bool) {core.push(&shows.queue,Show_Request{e,hidden})}

@(step="fixed",stage="end")
shows_apply :: proc(shows:^Show_Requests,hidden:^core.Table(render.Hidden)) {
    for show in core.take(&shows.queue) {render.set_hidden(hidden,show.entity,show.hidden)}
}
THROWN_CUBE_SIZE :: f32(0.25) // m, the side of a thrown cube

// On a body that opens doors, changes samples and throws cubes.
@(component,replicated)
Player :: struct {
    thrown:i32 `mirai:"transient,hidden"`, // cubes thrown in this run, for the HUD
}

@(component)
Spin :: struct {
    degrees_per_second:[3]f32,
    angles:[3]f32 `mirai:"transient"`, // Euler degrees in X, Y, Z order, added up since the first tick
    turning:bool `mirai:"transient"`,  // angles were taken from the rotation of the entity
}

@(component)
Bob :: struct {
    height:f32 `mirai:"min=0,unit=m"`,
    speed:f32,
    base_y:f32 `mirai:"transient"`, // where the entity was when it started
    ready:bool `mirai:"transient"`,
}

@(component)
Door :: struct {
    travel:f32 `mirai:"min=0,unit=m,local"`, // how far it slides up
    speed:f32 `mirai:"min=0,unit=m/s,local"`,
    reach:f32 `mirai:"min=0,unit=m,local"`,  // how near the player has to stand
    open:bool,
    lamp:core.Entity `mirai:"local"`,         // glows green while the door is open, red while it is closed
}

@(component)
Door_State :: struct {
    closed_y:f32 `mirai:"transient,local"`, // where the door was when it started
    ready:bool `mirai:"transient,local"`,
}

// A thrown cube: a body that gets its velocity once it exists.
@(component)
Projectile :: struct {
    speed:f32 `mirai:"min=0,unit=m/s"`, // along the forward of the entity
    seconds_left:f32,
    velocity:[3]f32 `mirai:"transient"`,
    launched:bool `mirai:"transient"`,
}

CAPTION_CAPACITY :: 128

// Its caption is shown while the player stands near: the name of the object,
// or caption when the text is longer than a name can be.
@(component)
Exhibit :: struct {
    reach:f32 `mirai:"min=0,unit=m"`,
    caption:[CAPTION_CAPACITY]u8 `mirai:"text"`,
}

// A sample whose material the player changes.
@(component)
Swatch :: struct {
    reach:f32 `mirai:"min=0,unit=m,local"`,
    index:i32 `mirai:"min=0"`, // which of SWATCH_MATERIALS it shows
}

// Emission that breathes between two shares of what the object has in the scene.
@(component)
Pulse :: struct {
    speed:f32,
    low:f32 `mirai:"min=0"`,
    high:f32 `mirai:"min=0"`,
    base:[3]f32 `mirai:"transient"`, // the emission of the entity when it started
    ready:bool `mirai:"transient"`,
}

// SWATCH_MATERIALS, found once.
@(storage)
Palette :: struct {
    materials:[len(SWATCH_MATERIALS)]base.Asset_Id,
    ready:bool,
}

@(storage)
Game :: struct {
    left:core.Entity, // the body the Menu action let go of
}

SPIN_DEFAULT :: Spin{degrees_per_second={0,90,0}}
BOB_DEFAULT :: Bob{height=0.25,speed=1.5}
DOOR_DEFAULT :: Door{travel=2.9,speed=3,reach=3.5}
EXHIBIT_DEFAULT :: Exhibit{reach=4}
SWATCH_DEFAULT :: Swatch{reach=3}
PULSE_DEFAULT :: Pulse{speed=2,low=0.3,high=1}
PROJECTILE_DEFAULT :: Projectile{speed=THROW_SPEED,seconds_left=CUBE_SECONDS}

// The id of the material <name>.mat, which follows from its name.
material_asset :: proc(name:string) -> base.Asset_Id {
    buffer:[192]u8
    return base.asset_id_named(fmt.bprintf(buffer[:],"material\x1fsource/materials/%s.json\x1f%s",name,name))
}

// The look yaw of an upright character body: where its front, -Z, heads.
yaw_of :: proc "contextless" (rotation:mm.Quat) -> f32 {
    ahead:=mm.quat_forward(rotation)
    return mm.yaw_of_direction(ahead)
}

player_walk :: proc "contextless" () -> phys.Walk {
    walk:=phys.WALK_DEFAULT
    walk.max_speed=WALK_SPEED
    return walk
}

// The actions the game reads, bound by Demo_Actions, those of interface_demo.odin too; move and
// jump are of physics (phys.Walk_Action) and look of the engine (inp.Look_Action).
@(actions)
Action :: enum u8 {
    Use,Flashlight,Throw,Bark,Switch_Body,Overhead_View,
    Gallery_Previous,Gallery_Next,Gallery_Overview,Physics_Reset,
    Portal_Blue,Portal_Orange,Grab,Camera_Mode,Aim,
    Hud_Style,Interface_Menu,Inventory,Talk,
}

// The bindings of the actions of the demo. The editor (Project Settings > Input), input.set and
// the player write in an input.mirai only what they change.
@(storage,host)
Demo_Actions :: struct {defaults:[Action]inp.Action_Default}

demo_actions_default :: proc "contextless" () -> Demo_Actions {
    key :: inp.binding_key
    pad :: inp.binding_gamepad_button
    mouse :: inp.binding_mouse_button
    trigger :: inp.binding_gamepad_axis
    return {defaults={
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
    }}
}

// The Menu action lets the focused seat go of its body, and that frees the mouse; again, it takes
// the body back. The animation gallery lets go too while its player adjusts a panel.
@(step="frame")
game_menu :: proc(game:^Game,g:^gui.Gui,state:core.Ref(inp.Seats),seats:core.Read(inp.Seat),drivables:core.Read(inp.Drivable),moves:^core.Table(inp.Move_Input),requests:^inp.Seat_Requests) {
    if !gui.menu_pressed(gui.events_this_frame(g)) {return}
    seat:=inp.focused(state.ptr,seats)
    if seat==core.NONE {return}
    if body:=inp.body_of(drivables,seat);body!=core.NONE {
        game.left=body
        inp.release(requests,seat)
        // Nobody writes the Move_Input of a body no seat drives: it would keep walking.
        if move:=core.get(moves,body);move!=nil {move.move,move.buttons={},{}}
    } else if game.left!=core.NONE {
        inp.drive(requests,seat,game.left)
        game.left=core.NONE
    }
}

in_reach :: proc(worlds:core.Read(core.World_Transform),from:[3]f32,e:core.Entity,reach:f32) -> bool {
    placed,found:=core.get(worlds,e)
    return found && linalg.distance(placed.position,from)<reach
}

swatch_index :: proc(swatch:Swatch) -> int {return int(swatch.index)%%len(SWATCH_MATERIALS)}

// What the seat of a body pressed this tick: open a door, change a sample, throw a cube.
@(step="fixed")
game_use :: proc(
    players:^core.Table(Player),doors:^core.Table(Door),swatches:^core.Table(Swatch),inputs:core.Read(inp.Move_Input),
    drivables:core.Read(inp.Drivable),actions:inp.Input_Of(Action),worlds:core.Read(core.World_Transform),names:core.Read(core.Name),spawner:scene.Spawner,
) {
    for row in 0..<core.count(players) {
        e:=core.entity_at(players,row)
        input,has_input:=core.get(inputs,e)
        placed,has_world:=core.get(worlds,e)
        if !has_input || !has_world {continue}
        feet:=placed.position
        if inp.pressed(actions,e,.Use) {
            for at in 0..<core.count(doors) {
                door:=core.at(doors,at)
                other:=core.entity_at(doors,at)
                if !in_reach(worlds,feet,other,door.reach) {continue}
                door.open=!door.open
                log.infof("%s %s",core.name_get(names,other),door.open?"opened":"closed")
            }
            for at in 0..<core.count(swatches) {
                swatch:=core.at(swatches,at)
                if in_reach(worlds,feet,core.entity_at(swatches,at),swatch.reach) {swatch.index=i32((swatch_index(swatch^)+1)%len(SWATCH_MATERIALS))}
            }
        }
        if origin,aim,aimed:=inp.aim(drivables,worlds,e);aimed && inp.pressed(actions,e,.Throw) {
            from:=origin+aim*0.8
            turn:=mm.quat_from_euler({input.look_pitch,input.look_yaw,0})
            scene.spawn(spawner,THROWN_CUBE,{from,turn,THROWN_CUBE_SIZE},transient=true)
            core.at(players,row).thrown+=1
        }
    }
}

// Doors slide towards where their state, or a button pressed for them, says, at a constant speed.
@(step="fixed")
game_doors :: proc(doors:core.Read(Door),buttons:core.Read(Floor_Button),states:^core.Table(Door_State),transforms:^core.Table(core.Transform),time:core.Time) {
    for row in 0..<core.count(doors) {
        e:=core.entity_at(doors,row)
        door:=core.at(doors,row)
        local:=core.free(transforms,e)
        if local==nil {continue}
        state:=core.get(states,e)
        if state==nil {
            core.add(states,e,Door_State{closed_y=local.position.y,ready=true})
            continue
        }
        target:=state.closed_y+(door_opened(doors,buttons,e)?door.travel:0)
        if local.position.y==target {continue}
        step:=door.speed*time.dt
        local.position.y+=clamp(target-local.position.y,-step,step)
    }
}

// What a sample shows follows its index, wherever the index was decided. The
// meshes are written through the world so that their version changes only
// when a material does.
@(step="fixed")
game_swatches :: proc(meshes:^core.Table(render.Mesh_Renderer),palette:^Palette,swatches:core.Read(Swatch)) {
    if !palette.ready {
        for name,i in SWATCH_MATERIALS {palette.materials[i]=material_asset(name)}
        palette.ready=true
    }
    for row in 0..<core.count(swatches) {
        mesh:=core.get(meshes,core.entity_at(swatches,row))
        if mesh==nil {continue}
        wanted:=palette.materials[swatch_index(core.at(swatches,row))]
        if mesh.materials[0]==wanted {continue}
        for &material in mesh.materials {material=wanted}
    }
}

// The pose of a body belongs to the simulation: a spinning or bobbing body gets
// it as one kinematic request with both motions, the rest is written in place.
@(step="fixed")
game_animate :: proc(
    spins:^core.Table(Spin),bobs:^core.Table(Bob),transforms:^core.Table(core.Transform),
    worlds:core.Read(core.World_Transform),bodies:^phys.Body_Requests,time:core.Time,
) {
    seconds:=f32(time.seconds)
    for row in 0..<core.count(spins) {
        e:=core.entity_at(spins,row)
        local:=core.free(transforms,e)
        placed,body:=core.get(worlds,e)
        if local==nil && !body {continue}
        spin:=core.at(spins,row)
        if !spin.turning {
            spin.angles=mm.quat_to_euler(local!=nil?local.rotation:placed.rotation)*mm.DEG_PER_RAD
            spin.turning=true
        }
        spin.angles+=spin.degrees_per_second*time.dt
        for &angle in spin.angles {angle=math.mod(angle,360)}
        turned:=mm.quat_from_euler(spin.angles*mm.RAD_PER_DEG)
        if local!=nil {
            local.rotation=turned
            continue
        }
        position:=placed.position
        if bob:=core.get(bobs,e);bob!=nil {position.y=bob_height(bob,position.y,seconds)}
        phys.move_kinematic(bodies,e,position,turned)
    }
    for row in 0..<core.count(bobs) {
        e:=core.entity_at(bobs,row)
        bob:=core.at(bobs,row)
        if local:=core.free(transforms,e);local!=nil {
            local.position.y=bob_height(bob,local.position.y,seconds)
        } else if placed,body:=core.get(worlds,e);body && !core.has(spins,e) {
            phys.move_kinematic(bodies,e,{placed.position.x,bob_height(bob,placed.position.y,seconds),placed.position.z},placed.rotation)
        }
    }
}

@(private="file")
bob_height :: proc(bob:^Bob,y,seconds:f32) -> f32 {
    if !bob.ready {bob.base_y,bob.ready=y,true}
    return bob.base_y+math.sin(seconds*bob.speed)*bob.height
}

// Emission: pulses breathe, the lamp of a door shows its state, the nose of a dog flashes when it barks,
// the globe of a lamp of the horror house glows while lit.
@(step="fixed",after="physics_gallery_actions")
game_glow :: proc(
    tints:^core.Table(render.Tint),pulses:^core.Table(Pulse),doors:core.Read(Door),buttons:core.Read(Floor_Button),barkers:core.Read(Barker),
    hierarchy:core.Ref(core.Hierarchy),names:core.Read(core.Name),time:core.Time,
    gallery:core.Read(Physics_Gallery),view:destruct.Destruct_View,
    lamps:core.Read(House_Lamp),
) {
    physics_gallery_fade(gallery,view,tints,time)
    horror_glow(tints,lamps)
    seconds:=f32(time.seconds)
    for row in 0..<core.count(pulses) {
        tint:=core.get(tints,core.entity_at(pulses,row))
        if tint==nil {continue}
        pulse:=core.at(pulses,row)
        if !pulse.ready {
            pulse.base,pulse.ready=tint.emission,true
        }
        wave:=0.5+0.5*math.sin(seconds*pulse.speed)
        tint.emission=pulse.base*(pulse.low+(pulse.high-pulse.low)*wave)
    }
    for row in 0..<core.count(doors) {
        door:=core.at(doors,row)
        glow:=door_opened(doors,buttons,core.entity_at(doors,row))?DOOR_OPEN_GLOW:DOOR_CLOSED_GLOW
        if tint,has:=core.get(core.read(tints),door.lamp);has && tint.emission!=glow {core.get(tints,door.lamp).emission=glow}
    }
    for row in 0..<core.count(buttons) {
        button:=core.at(buttons,row)
        glow:=button.pressed?DOOR_OPEN_GLOW:DOOR_CLOSED_GLOW
        if tint,has:=core.get(core.read(tints),button.plate);has && tint.emission!=glow {core.get(tints,button.plate).emission=glow}
    }
    for row in 0..<core.count(barkers) {
        flashing:=core.at(barkers,row).flash_ticks>0
        for child:=core.first_child(hierarchy,core.entity_at(barkers,row));child!=core.NONE;child=core.next_sibling(hierarchy,child) {
            if core.name_get(names,child)!="Nose" {continue}
            if tint:=core.get(tints,child);tint!=nil {tint.emission=flashing?BARK_GLOW:[3]f32{}}
        }
    }
}

// A thrown cube is a body: it is launched the first tick its body exists,
// tumbles and bounces on its own, and goes after CUBE_SECONDS. A destructible
// it strikes takes a blow of its velocity before the strike times PROJECTILE_MASS;
// destruct leaves alone what is not one.
@(step="fixed",stage="react",before="destruct_step")
game_projectiles :: proc(
    es:^core.Entities,projectiles:^core.Table(Projectile),transforms:core.Read(core.Transform),body_states:core.Read(core.Motion),
    events:core.Ref(phys.Physics_Events),bodies:^phys.Body_Requests,
    damage:^destruct.Destruct_Requests,time:core.Time,
) {
    strike :: proc(projectiles:^core.Table(Projectile),damage:^destruct.Destruct_Requests,cube,struck:core.Entity,point:[3]f32) {
        projectile:=core.get(projectiles,cube)
        if projectile==nil || !projectile.launched {return}
        destruct.damage(damage,struck,point,PROJECTILE_REACH,projectile.velocity*PROJECTILE_MASS)
    }
    for contact in events.contact_begin.items {
        strike(projectiles,damage,contact.a,contact.b,contact.point)
        strike(projectiles,damage,contact.b,contact.a,contact.point)
    }
    for row in 0..<core.count(projectiles) {
        e:=core.entity_at(projectiles,row)
        projectile:=core.at(projectiles,row)
        if state,has:=core.get(body_states,e);has {
            if projectile.launched {
                projectile.velocity=state.linear
            } else if local,placed:=core.get(transforms,e);placed {
                projectile.velocity=mm.quat_forward(local.rotation)*projectile.speed
                phys.set_velocity(bodies,e,projectile.velocity,{6,4,0})
                projectile.launched=true
            }
        }
        projectile.seconds_left-=time.dt
        if projectile.seconds_left<=0 {core.destroy(es,e)}
    }
}

// A box of the HUD placed on its parent.
hud_box :: proc(ctx:^ui.Context,name:string,anchor,pivot:ui.Anchor,offset:[2]f32,width,height:ui.Size,fill:ui.Color,padding:[4]f32={}) -> ui.Box {
    return {
        id=ui.id(ctx,name),layout={width=width,height=height,padding=padding,align_y=.Center},
        float={to=.Parent,anchor=anchor,pivot=pivot,offset=offset,layer=ctx.layer},fill=fill,
    }
}

// The crosshair, the count of cubes, what the use action does here and the caption of the nearest exhibit.
@(step="ui")
game_hud :: proc(
    g:^gui.Gui,players:core.Read(Player),doors:core.Read(Door),swatches:core.Read(Swatch),exhibits:core.Read(Exhibit),
    barkers:core.Read(Barker),demos:core.Read(Control_Demo),drivables:core.Read(inp.Drivable),
    seat_state:core.Ref(inp.Seats),locals:core.Read(inp.Seat),worlds:core.Read(core.World_Transform),names:core.Read(core.Name),
    app:^host.App,
) {
    ctx:=gui.gui_context(g)
    if ctx==nil {return}
    body:=inp.body_of(drivables,inp.focused(seat_state.ptr,locals))
    player,has_player:=core.get(players,body)
    placed,has_world:=core.get(worlds,body)
    barker,has_barker:=core.get(barkers,body)
    if !has_player && !has_barker || !has_world {return}
    feet:=placed.position
    pixels:=host.app_player_rect(app,seat_state.focus,seat_state.local_count)
    rect:=[4]f32{f32(pixels.x),f32(pixels.y),f32(pixels.z),f32(pixels.w)}/max(app.density,0.01)
    root:=ui.Box{
        id=ui.id(ctx,"game.hud"),layout={width=ui.fixed(f32(rect.z)),height=ui.fixed(f32(rect.w))},
        float={to=.Surface,layer=1000,offset={f32(rect.x),f32(rect.y)}},
    }
    ui.box_begin(ctx,root)
    defer ui.box_end(ctx,root)
    white:=ui.Color{255,255,255,204}
    if ui.box(ctx,hud_box(ctx,"cross.v",.Center,.Center,{},ui.fixed(2),ui.fixed(14),white)) {}
    if ui.box(ctx,hud_box(ctx,"cross.h",.Center,.Center,{},ui.fixed(14),ui.fixed(2),white)) {}
    if has_player {
        if ui.box(ctx,hud_box(ctx,"thrown",.Top_Left,.Top_Left,{10,48},ui.fit(),ui.fixed(26),{0,0,0,128},ui.padding_xy(8,0))) {
            ui.label(ctx,fmt.tprintf("Cubes thrown: %d",player.thrown))
        }
    }
    hint:=""
    for row in 0..<core.count(doors) {
        if hint!="" || !in_reach(worlds,feet,core.entity_at(doors,row),core.at(doors,row).reach) {continue}
        hint=fmt.tprintf("E: %s the door",core.at(doors,row).open?"close":"open")
    }
    swatch_names:=SWATCH_MATERIALS
    for row in 0..<core.count(swatches) {
        swatch:=core.at(swatches,row)
        if hint!="" || !in_reach(worlds,feet,core.entity_at(swatches,row),swatch.reach) {continue}
        hint=fmt.tprintf("E: change the material (%s)",swatch_names[swatch_index(swatch)])
    }
    if hint!="" {
        if ui.box(ctx,hud_box(ctx,"hint",.Center,.Top_Center,{0,40},ui.fit(),ui.fit(),{},ui.padding_xy(4,2))) {
            ui.label(ctx,hint,color=ctx.theme.accent)
        }
    }
    caption:=""
    distance:=max(f32)
    for row in 0..<core.count(exhibits) {
        e:=core.entity_at(exhibits,row)
        exhibit:=core.at(exhibits,row)
        exhibit_placed,found:=core.get(worlds,e)
        if !found {continue}
        away:=linalg.distance(exhibit_placed.position,feet)
        if away>=exhibit.reach || away>=distance {continue}
        distance=away
        caption=fmt.tprintf("%s",base.text_get(exhibit.caption[:]))
        if caption=="" {caption=core.name_get(names,e)}
    }
    if caption!="" {
        if ui.box(ctx,hud_box(ctx,"caption",.Bottom_Center,.Bottom_Center,{0,-44},ui.fit(),ui.fixed(32),{0,0,0,140},ui.padding_xy(14,0))) {
            ui.label(ctx,caption)
        }
    }
    if core.count(demos)>0 {
        box:=hud_box(ctx,"control",.Top_Left,.Top_Left,{12,88},ui.fixed(min(430,f32(rect.z)-24)),ui.fit(),{0,0,0,160},ui.padding_xy(10,6))
        box.layout.direction=.Column
        box.layout.gap=4
        if ui.box(ctx,box) {
            ui.label(ctx,"Tab / North: swap body")
            ui.label(ctx,"V / RB: overhead camera   C / L3: camera mode")
            ui.label(ctx,"Right mouse / LT: aim")
            ui.label(ctx,fmt.tprintf("Controlling %s   E / West: use + bark",has_barker?"Dog":"Person"))
            if has_barker {ui.label(ctx,fmt.tprintf("Barks: %d",barker.count))}
        }
    }
}
