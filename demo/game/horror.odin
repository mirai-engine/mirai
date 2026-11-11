package game

import "mirai:core"
import inp "mirai:engine/input"
import render "mirai:engine/render"
import mm "mirai:std/math"

// The horror house (horror/horror.scene): a dark room under the moon, lamps
// that a switch on the wall turns on and off with use (E), one of them
// flickering, and a flashlight the player carries and turns on and off with
// the flashlight action (F).

// A switch the player turns with use while standing within reach.
@(component,description="A wall switch: use (E) within reach turns on and off the House_Lamps that name it.")
Light_Switch :: struct {
    reach:f32 `mirai:"min=0,unit=m"`,
    on:bool,
}

LIGHT_SWITCH_DEFAULT :: Light_Switch{reach=2,on=true}

// A lamp of the house: its Point_Light gives `intensity` while its switch is
// on and, if it flickers, while its blinking lets it; its globe glows `glow`
// while it is lit.
@(component,description="A lamp that a Light_Switch turns on and off; it may flicker.")
House_Lamp :: struct {
    light_switch:core.Entity `mirai:"local"`,
    intensity:f32 `mirai:"min=0,unit=cd"`,
    globe:core.Entity `mirai:"local"`,
    glow:[3]f32 `mirai:"color"`,      // nits of the globe while lit
    flicker:f32 `mirai:"min=0"`,      // chances a second to blink; 0: steady
    lit:bool `mirai:"transient"`,
}

HOUSE_LAMP_DEFAULT :: House_Lamp{intensity=800}

// A light the player carries in front of the eyes: its entity follows where
// the player looks and its Spot_Light gives `intensity` while on.
@(component,description="A flashlight that follows the view of the player; the flashlight action (F) turns it on and off.")
Flashlight :: struct {
    intensity:f32 `mirai:"min=0,unit=cd"`,
    on:bool,
}

FLASHLIGHT_DEFAULT :: Flashlight{intensity=9425,on=true}

// The flashlight, a hand below and to the right of the eyes.
FLASHLIGHT_OFFSET :: [3]f32{0.25,-0.15,0}

// Use within reach of a switch turns it; the flashlight action turns every flashlight.
@(step="fixed")
horror_switches :: proc(
    players:core.Read(Player),switches:^core.Table(Light_Switch),flashlights:^core.Table(Flashlight),
    actions:inp.Input_Of(Action),worlds:core.Read(core.World_Transform),
) {
    for row in 0..<core.count(players) {
        e:=core.entity_at(players,row)
        placed,has_world:=core.get(worlds,e)
        if !has_world {continue}
        if inp.pressed(actions,e,.Use) {
            for at in 0..<core.count(switches) {
                switch_entity:=core.entity_at(switches,at)
                if in_reach(worlds,placed.position,switch_entity,core.at(switches,at).reach) {core.edit_at(switches,at).on=!core.at(switches,at).on}
            }
        }
        if inp.pressed(actions,e,.Flashlight) {
            for at in 0..<core.count(flashlights) {core.edit_at(flashlights,at).on=!core.at(flashlights,at).on}
        }
    }
}

// Each lamp gives its light while its switch is on and its flicker lets it;
// the flashlights follow the eyes of the first player.
@(step="fixed",stage="react")
horror_lights :: proc(
    lamps:^core.Table(House_Lamp),switches:core.Read(Light_Switch),points:^core.Table(render.Point_Light),
    flashlights:core.Read(Flashlight),spots:^core.Table(render.Spot_Light),transforms:^core.Table(core.Transform),
    players:core.Read(Player),moves:core.Read(inp.Move_Input),drivables:core.Read(inp.Drivable),worlds:core.Read(core.World_Transform),time:core.Time,
) {
    seconds:=f32(time.seconds)
    for row in 0..<core.count(lamps) {
        lamp:=core.at(lamps,row)
        on:=true
        if s,has:=core.get(switches,lamp.light_switch);has {on=s.on}
        if on && lamp.flicker>0 {
            // Blinks out for a share of each slice of time, chosen by a hash of the slice.
            slice:=u32(seconds*lamp.flicker*4)+u32(row)*7919
            on=flicker_hash(slice)>0.3
        }
        lamp.lit=on
        core.set_at(lamps,row,lamp)
        e:=core.entity_at(lamps,row)
        if light,lights:=core.get(points,e);lights {
            light.intensity=on?lamp.intensity:0
            core.set(points,e,light)
        }
    }
    player,found:=core.first(players)
    if !found {return}
    origin,_,aimed:=inp.aim(drivables,worlds,player)
    move,has_move:=core.get(moves,player)
    if !aimed || !has_move {return}
    turn:=mm.quat_from_euler({move.look_pitch,move.look_yaw,0})
    eye:=origin+mm.quat_rotate(turn,FLASHLIGHT_OFFSET)
    for row in 0..<core.count(flashlights) {
        e:=core.entity_at(flashlights,row)
        flashlight:=core.at(flashlights,row)
        // A write marks the light as moved, and a moved light restarts the indirect light around it.
        if row:=core.row_of(transforms,e);row>=0 {
            if placed:=core.at(transforms,row);placed.position!=eye || placed.rotation!=turn {
                if local:=core.free(transforms,e);local!=nil {local.position,local.rotation=eye,turn}
            }
        }
        if spot,lights:=core.get(spots,e);lights {
            spot.intensity=flashlight.on?flashlight.intensity:0
            core.set(spots,e,spot)
        }
    }
}

@(private="file")
flicker_hash :: proc "contextless" (v:u32) -> f32 {
    x:=v*747796405+2891336453
    x=((x>>((x>>28)+4))~x)*277803737
    x=(x>>22)~x
    return f32(x>>8)/f32(1<<24)
}

// The globe of each lamp glows while it is lit.
@(step="fixed")
horror_glow :: proc(tints:^core.Table(render.Material_Values),lamps:core.Read(House_Lamp)) {
    for row in 0..<core.count(lamps) {
        lamp:=core.at(lamps,row)
        if tint,found:=core.get(tints,lamp.globe);found {
            tint.emission=lamp.lit?lamp.glow:[3]f32{}
            core.set(tints,lamp.globe,tint)
        }
    }
}
