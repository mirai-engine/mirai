package mirai_physics

import cmath "core:math"
import "mirai:std/spatial"
import "mirai:std/base"
import math "mirai:std/math"

// How the weight of a volume goes from its border (x=0) to its center (x=1): the falloff curves of a force field.
Radial_Falloff :: enum u8 {
    Constant,    // 1
    Linear,      // x
    Inverse,     // 2(1-1/(x+1)): drops slowly near the center and fast near the border
    Squared,     // x*x: drops fast near the center and slowly near the border
    Logarithmic, // log2(x+1)
}

// Weights at the border (min) and at the center (max): the curve goes from one to the other. The zero value is {0,1}.
Weight_Range :: struct {min,max:f32}

// Gradient noise that scales the weight of a volume: features about `scale` meters across, fixed to the frame
// of the volume, taken from 0..1 to `range`. Zero scale is no noise.
Field_Noise :: struct {
    scale:f32, // m
    seed:u32,
    range:Weight_Range,
}

@(private) NOISE_REACH :: f32(1<<24) // noise coordinates beyond it repeat the border instead of overflowing

@(private)
weight_range_valid :: #force_inline proc "contextless" (range:Weight_Range) -> bool {
    return range.min>=-max(f32) && range.min<=max(f32) && range.max>=-max(f32) && range.max<=max(f32)
}

@(private)
field_noise_valid :: #force_inline proc "contextless" (noise:Field_Noise) -> bool {
    return noise.scale==0 || noise.scale>0 && noise.scale<=max(f32) && weight_range_valid(noise.range)
}

@(private)
weight_from_range :: #force_inline proc "contextless" (range:Weight_Range,x:f32) -> f32 {
    if range=={} {return x}
    return range.min+(range.max-range.min)*x
}

@(private)
falloff_curve :: proc "contextless" (x:f32,falloff:Radial_Falloff) -> f32 {
    switch falloff {
    case .Constant: return 1
    case .Linear: return x
    case .Inverse: return 2*(1-1/(x+1))
    case .Squared: return x*x
    case .Logarithmic: return cmath.log2(x+1)
    }
    return 0
}

// Weight of the noise of a volume at a point: 1 without noise, zero for a noise that is not valid.
noise_weight :: proc "contextless" (point,center:Vec3,rotation:Quat,noise:Field_Noise) -> f32 {
    if noise.scale==0 {return 1}
    if !field_noise_valid(noise) {return 0}
    local:=q_inv_rotate(q_normalize(rotation),point-center)/noise.scale
    for &value in local {value=clamp(value,-NOISE_REACH,NOISE_REACH)}
    value:=clamp(0.5*(math.noise_perlin3(local,noise.seed)+1),0,1)
    return weight_from_range(noise.range,value)
}

// A region of the world that forces and impulses are applied in, as whoever asks for them describes it:
// the model has no shape of its own for it. `weight` says how much of the region a point is in, 0 outside
// it and up to 1 inside; `bounds` is a box of the world that holds it, which may have no end.
Area :: struct {
    bounds:Aabb,
    center:Vec3,   // what a radial push goes away from
    rotation:Quat, // with the center, the frame of the noise
    weight:proc "contextless" (user:rawptr,point:Vec3) -> f32,
    user:rawptr,
}

// A force (N) or, with `impulse`, an impulse (N s; a velocity change, m/s, with `velocity_change`) on every
// dynamic body the filter sees whose center of mass is in the area, once per body. `radial` pushes away from
// the center of the area by force.x (negative pulls in); without it the force is the vector. The falloff
// curve takes the weight of the area at the body to the share of the force it gets, in `range`, scaled by
// the noise. count: the bodies pushed. ok is false, and nothing is pushed, for values that are not valid.
world_apply_area :: proc(w:^World,area:Area,force:Vec3,radial:=false,impulse:=false,velocity_change:=false,falloff:Radial_Falloff=.Linear,filter:=QUERY_FILTER_DEFAULT,range:Weight_Range={},noise:Field_Noise={}) -> (count:int,ok:bool) {
    if w==nil || len(w.bodies)==0 || area.weight==nil || falloff>.Logarithmic || !weight_range_valid(range) || !field_noise_valid(noise) || velocity_change && !impulse {return 0,false}
    if !finite(area.center,force) || !finite(area.rotation) {return 0,false}
    box:=area.bounds
    for axis in 0..<3 {if !(box.min[axis]>=-max(f32) && box.max[axis]<=max(f32) && box.min[axis]<=box.max[axis]) {return 0,false}}
    frame:=q_normalize(area.rotation)
    marks:=w.step.color_bits[:w.step.color_words]
    for &word in marks {word=0}
    query:=spatial.dynamic_tree_query(&w.trees[DYNAMIC_TREE],box)
    for _,user in spatial.tree_query_next(&query) {
        shape:=&w.shapes[user]
        body:=&w.bodies[shape.body]
        if body.type!=.Dynamic || query_response(w,shape,filter)==.Ignore || !math.aabb_overlaps(shape.aabb,box) {continue}
        slot:=int(shape.body)
        bit:=u64(1)<<u32(slot&63)
        if marks[slot>>6]&bit!=0 {continue}
        marks[slot>>6]|=bit
        at:=area.weight(area.user,body.center)
        if !(at>0) {continue}
        vector:=force
        if radial {vector=normalize(body.center-area.center)*force.x}
        vector*=weight_from_range(range,falloff_curve(min(at,1),falloff))
        if noise.scale!=0 {vector*=noise_weight(body.center,area.center,frame,noise)}
        if vector=={} {continue}
        handle:=body_handle(w,shape.body)
        if impulse {
            if velocity_change {vector*=body.mass}
            if .Character in body.flags {
                for &character,character_slot in w.characters[:w.character_high] {
                    if character.generation&1!=0 && character.body==handle {
                        character_launch(w,Character_Handle(base.handle_make(u32(character_slot),character.generation)),vector*body.inv_mass)
                        break
                    }
                }
                count+=1
                continue
            }
            body_apply_impulse(w,handle,vector)
        } else {
            body_apply_force(w,handle,vector)
        }
        count+=1
    }
    return count,true
}
