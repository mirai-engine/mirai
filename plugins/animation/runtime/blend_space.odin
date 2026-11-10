package anim

import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"

// A space of a .character: aim offsets or additive poses a layer samples at the place its axes
// are set to (set), each axis a parameter by its name.
Blend_Axis :: struct {name:[32]u8 `mirai:"text"`,min,max:f32}
Blend_Info :: struct {name:[32]u8 `mirai:"text"`,dimension:lib.Blend_Dimension,x,y:Blend_Axis}
// A sample of the space of index space; animation: of its clip, empty for the set's.
Blend_Sample :: struct {space:u16,position:mm.Vec2,clip:[64]u8 `mirai:"text"`,speed:f32,animation:base.Asset_Id}

blend_position :: proc "contextless" (info:Blend_Info,position:mm.Vec2) -> mm.Vec2 {
    x:=(f64(position.x)-f64(info.x.min))/(f64(info.x.max)-f64(info.x.min))
    y:f64
    if info.dimension==.Two {y=(f64(position.y)-f64(info.y.min))/(f64(info.y.max)-f64(info.y.min))}
    magnitude:=max(abs(x),abs(y))
    if magnitude>1e30 {factor:=1e30/magnitude;x*=factor;y*=factor}
    return {f32(x),f32(y)}
}

@(private)
blend_definition_check :: proc "contextless" (info:Blend_Info,samples:[]Blend_Sample) -> bool {
    info:=info
    if !blend_text_valid(info.name[:],false) || info.dimension>max(lib.Blend_Dimension) || len(samples)==0 || len(samples)>lib.BLEND_MAX_SAMPLES {return false}
    axes:=[2]Blend_Axis{info.x,info.y}
    for &axis,i in axes {
        if i==1 && info.dimension==.One {continue}
        if !blend_text_valid(axis.name[:],false) || !finite(axis.min) || !finite(axis.max) || axis.min>=axis.max {return false}
    }
    for &sample in samples {
        if !finite(sample.position.x) || !finite(sample.position.y) || !finite(sample.speed) || !blend_text_valid(sample.clip[:],false) {return false}
        if sample.position.x<info.x.min || sample.position.x>info.x.max {return false}
        if info.dimension==.Two && (sample.position.y<info.y.min || sample.position.y>info.y.max) {return false}
    }
    return true
}
@(private)
blend_text_valid :: proc "contextless" (value:[]u8,empty:bool) -> bool {
    for byte,i in value {if byte==0 {return empty || i>0}}
    return false
}

// The weights of the samples of a ready space at position, in the axes of its space.
space_sample :: proc "contextless" (info:Blend_Info,ready:^Space_Ready,position:mm.Vec2) -> (lib.Blend_Weights,bool) {
    if ready==nil || !finite(position.x) || !finite(position.y) {return {},false}
    return lib.blend_space_sample(ready.space,blend_position(info,position))
}
