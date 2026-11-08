package game

import "mirai:core"
import destruct "plugins:destruct/runtime"
import inp "mirai:engine/input"
import phys "plugins:physics/runtime"
import save "mirai:engine/save"
import "mirai:std/base"
import mm "mirai:std/math"

// A small game built only with the public API of the engine, to copy from.
// The player is a physics character driven by the input actions move, look,
// jump, hit (breaks the wall in front of it), save and load (the slot
// "quick"), bound in code. assets/scenes/main.scene holds a floor, a
// spawn point with the prefab of the player, a destructible wall, a speaker
// that plays a sound, a HUD (UI_Screen) with a pulsing badge and a sign above
// the speaker (World_Widget); both interfaces show the Status component of
// their entity. settings.mirai has the spawn library give each player a body
// at that point: the player of this machine, and on a server each
// connection. Its camera is at its eyes (Camera_Follow Eyes). It runs
// alone, as a server (--server) or as a client (--connect): the server breaks
// the wall; every client predicts its own player. tools/content writes the
// scene, the prefab of the player and their assets. game/shell.odin is its
// main menu, pause and settings.

EYE_HEIGHT :: f32(1.6)
WALK_SPEED :: f32(4)
VIEW_FOV :: f32(70)*mm.RAD_PER_DEG     // vertical
HIT_REACH :: f32(3)                     // how far from the eye a hit lands
HIT_RADIUS :: f32(0.6)
HIT_IMPULSE :: f32(40)                  // N s, along the view
SAVE_SLOT :: "quick"

PLAYER_PREFAB :: base.Asset_Id{0x6d6972616967616d,0x706c617965720001}

// On the character of a player.
@(component)
Player :: struct {}

// What the HUD and the sign show: their interfaces bind to these fields by name.
@(component)
Status :: struct {
    message:[48]u8 `mirai:"text"`,
    hits:i32,
}

// The actions of the game, bound by Game_Actions; move and jump are of physics (phys.Walk_Action)
// and look of the engine (inp.Look_Action).
@(actions)
Action :: enum u8 {Hit,Save,Load}

// The bindings of the actions of the game. The editor (Project Settings > Input), input.set and the
// player write in an input.mirai only what they change of these.
@(storage,host)
Game_Actions :: struct {defaults:[Action]inp.Action_Default}

game_actions_default :: proc "contextless" () -> Game_Actions {
    return {defaults={
        .Hit=inp.action_default(.Button,inp.binding_mouse_button(.Left),inp.binding_gamepad_axis(.Right_Trigger)),
        .Save=inp.action_default(.Button,inp.binding_key(.F5),inp.binding_gamepad_button(.Start)),
        .Load=inp.action_default(.Button,inp.binding_key(.F9),inp.binding_gamepad_button(.Back)),
    }}
}

aim_of :: proc "contextless" (yaw,pitch:f32) -> [3]f32 {
    return mm.quat_rotate(mm.quat_from_euler({pitch,yaw,0}),[3]f32{0,0,-1})
}

player_walk :: proc "contextless" () -> phys.Walk {
    walk:=phys.WALK_DEFAULT
    walk.max_speed=WALK_SPEED
    return walk
}

@(private="file")
status_show :: proc(statuses:^core.Table(Status),message:string,hit:=false) {
    for &status in core.writable(statuses) {
        base.text_set(status.message[:],message)
        if hit {status.hits+=1}
    }
}

// A hit damages what the view meets within reach, where it meets it: the
// wall or a piece of it. The server decides it, and a session alone.
@(step="fixed",server)
game_hit :: proc(
    players:core.Read(Player),inputs:core.Read(inp.Move_Input),worlds:core.Read(core.World_Transform),
    actions:inp.Input_Of(Action),physics:core.Ref(phys.Physics_State),damage:^destruct.Destruct_Requests,
) {
    for row in 0..<core.count(players) {
        e:=core.entity_at(players,row)
        input,has_input:=core.get(inputs,e)
        placed,has_world:=core.get(worlds,e)
        if !has_input || !has_world || !inp.pressed(actions,e,.Hit) {continue}
        eye:=placed.position+[3]f32{0,EYE_HEIGHT,0}
        ahead:=aim_of(input.look_yaw,input.look_pitch)
        if hit,found:=phys.raycast(physics,eye,ahead,HIT_REACH,e);found {destruct.damage(damage,hit.entity,hit.point,HIT_RADIUS,ahead*HIT_IMPULSE)}
    }
}

// Every end counts the hits the wall took. Save and load use the slot of the
// game; a session on a network does not save.
@(step="fixed")
game_play :: proc(
    statuses:^core.Table(Status),broken:core.Ref(destruct.Destruct_Events),
    network:core.Ref(core.Network),actions:inp.Input_Of(Action),saves:^save.Save_Requests,results:core.Ref(save.Save_Results),
) {
    for _ in broken.applied.items {status_show(statuses,"Hit!",true)}
    if network.role!=.Standalone {return}
    if inp.pressed(actions,.Save) {save.request_save(saves,SAVE_SLOT)}
    if inp.pressed(actions,.Load) {save.request_load(saves,SAVE_SLOT)}
    for result in results.queue.items {
        if result.error!=.None {
            status_show(statuses,"The slot could not be used")
            continue
        }
        status_show(statuses,result.op==.Save?"Saved":"Loaded")
    }
}
