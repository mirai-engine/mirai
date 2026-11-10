package game

import "mirai:core"
import anim "plugins:animation/runtime"
import "mirai:std/base"

// The scene assets/showcase/showcase.scene: a lift that an Animation moves, a
// HUD (UI_Screen) and a sign above the lift (World_Widget) that show this
// component, and a speaker with a sound. tools/demo_content writes the scene
// and every asset it uses.

SHOWCASE_LIFT :: "Lift"         // the entity with the Animation
SHOWCASE_RIDE_SECONDS :: f32(4) // length of its clip; the lift is at the top half way

// What the interfaces of the showcase are bound to.
@(component)
Showcase :: struct {
    label:[32]u8 `mirai:"text"`,
    charge:f32 `mirai:"min=0,max=1"`, // how far up the lift is
    trips:i32,                        // times it reached the top
    running:bool,
}

// The button of the sign stops and resumes the lift; every arrival at the
// top, a marker of the clip, is counted.
@(step="fixed",stage="react")
game_showcase :: proc(
    shown:^core.Table(Showcase),animations:core.Read(anim.Animation),playback:core.Ref(anim.Playback),
    markers:core.Ref(anim.Animation_Events),names:core.Read(core.Name),
) {
    if core.count(shown)==0 {return}
    arrivals:=i32(0)
    for marker in markers.items {
        if marker.kind==.Marker && marker.name==base.name_hash("top") {arrivals+=1}
    }
    lift:=core.entity_named(names,SHOWCASE_LIFT)
    animation,animated:=core.get(animations,lift)
    lift_time,_,_,has_progress:=anim.animation_progress(playback.ptr,lift)
    for &showcase in core.writable(shown) {
        showcase.trips+=arrivals
        if !animated {continue}
        showcase.running=animation.playing
        if has_progress {showcase.charge=1-abs(lift_time/SHOWCASE_RIDE_SECONDS*2-1)}
    }
}
