package game

import "core:math"
import "mirai:core"
import anim "plugins:animation/runtime"

@(component,description="Runs the three Jelly Jam examples: layered morph animation, skeletal combination and signed shape weights.")
Morph_Playground :: struct {variant:u8}

morph_playground_animate :: proc(items:core.Read(Morph_Playground),animations:^core.Table(anim.Animation),weights:^core.Table(anim.Morph_Weights),time:core.Time) {
    if !time.playing {return}
    for row in 0..<core.count(items) {
        entity:=core.entity_at(items,row);item:=core.at(items,row);seconds:=f32(time.seconds)+f32(item.variant)*.8
        if animation:=core.edit(animations,entity);animation!=nil {
            anim.animation_parameter(animation,"Mood",.5+.5*math.sin(seconds*.65))
            anim.animation_weight(animation,1,.25+.25*math.sin(seconds*.9))
        }
        if item.variant==2 {if value:=core.edit(weights,entity);value!=nil {anim.morph_weight_set(value,"Squash",1.35*math.sin(seconds));anim.morph_weight_set(value,"Wobble",.8*math.cos(seconds*.7),.Additive)}}
    }
}
