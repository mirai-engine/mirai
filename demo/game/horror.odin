package game

import "mirai:core"
import inp "mirai:engine/input"
import "mirai:engine/scene"
import render "mirai:engine/render"
import mm "mirai:std/math"

// The horror house (horror/horror.scene): a dark room under the moon, lamps
// that a switch on the wall turns on and off with use (E), one of them
// flickering, and a flashlight the player carries and turns on and off with
// the flashlight action (F).

// A switch the player turns by using its Interactable.
@(component,description="A wall switch: using its Interactable (E) turns on and off the House_Lamps that name it.")
Light_Switch :: struct {
    on:bool,
}

LIGHT_SWITCH_DEFAULT :: Light_Switch{on=true}

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

// A switch used turns; the flashlight action turns every flashlight.
@(step="fixed")
horror_switches :: proc(
    players:^core.Table(Player,.Read),switches:^core.Table(Light_Switch),flashlights:^core.Table(Flashlight),
    used:core.Ref(scene.Interaction_Events),actions:inp.Input_Of(Action),
) {
    for event in used.items {
        if event.kind!=.Completed {continue}
        if light_switch:=core.edit(switches,event.target);light_switch!=nil {light_switch.on=!light_switch.on}
    }
    for row in 0..<core.count(players) {
        if !inp.pressed(actions,core.entity_at(players,row),.Flashlight) {continue}
        for at in 0..<core.count(flashlights) {core.edit_at(flashlights,at).on=!core.at(flashlights,at).on}
    }
}

// Each lamp gives its light, and its globe glows, while its switch is on and
// its flicker lets it; the flashlights follow the eyes of the first player.
@(step="fixed",stage="react")
horror_lights :: proc(
    lamps:^core.Table(House_Lamp,.Read),tints:^core.Table(render.Material_Values),switches:^core.Table(Light_Switch,.Read),points:^core.Table(render.Point_Light),
    flashlights:^core.Table(Flashlight,.Read),spots:^core.Table(render.Spot_Light),transforms:^core.Table(core.Transform),
    players:^core.Table(Player,.Read),aims:inp.Aims,time:core.Time,
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
        glow_set(tints,lamp.globe,on?lamp.glow:[3]f32{})
        intensity:=lamp.intensity if on else 0
        if at:=core.row_of(points,core.entity_at(lamps,row));at>=0 && core.at(points,at).intensity!=intensity {
            core.edit_at(points,at).intensity=intensity
        }
    }
    player,found:=core.first(players)
    if !found {return}
    origin,_,turn,aimed:=inp.aim(aims,player)
    if !aimed {return}
    eye:=origin+mm.quat_rotate(turn,FLASHLIGHT_OFFSET)
    for row in 0..<core.count(flashlights) {
        e:=core.entity_at(flashlights,row)
        flashlight:=core.at(flashlights,row)
        // A write marks the light as moved, and a moved light restarts the indirect light around it.
        if pose,placed:=core.get(transforms,e);placed && (pose.position!=eye || pose.rotation!=turn) {
            if local:=core.free(transforms,e);local!=nil {local.position,local.rotation=eye,turn}
        }
        intensity:=flashlight.intensity if flashlight.on else 0
        if at:=core.row_of(spots,e);at>=0 && core.at(spots,at).intensity!=intensity {
            core.edit_at(spots,at).intensity=intensity
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
