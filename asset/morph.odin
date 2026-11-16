package asset

import "core:math"

// The morph targets of a mesh: shapes its vertices blend toward by weight.
//
//   morphs         Morph_Target: a range of morph_deltas each
//   morph_deltas   bulk   Morph_Cluster_Delta, by vertex inside each target
//
// A target moves the vertices its deltas name, of any level; the others stay.
// A mesh without them has neither table.
//
// Deltas are stored as the renderer reads them (render.Morph_Delta). A
// position is in steps of Mesh_Info.morph_step, the finest power of two whose
// MORPH_POSITION_LIMIT steps reach the largest component of the mesh's
// deltas, so each component is off by at most morph_step/2. A normal or a
// tangent, the difference of two unit vectors, is clamped to [-2,2] per
// component and off by at most MORPH_NORMAL_STEP/2 or MORPH_TANGENT_STEP/2.

MESH_MAX_MORPHS :: 256
// Weights an entity sets by name over those of its mesh (Morph_Weights of
// the animation plugin): overrides and a node's own rest weights. Animation
// curves drive the others without one.
MORPH_WEIGHTS :: 16

MORPH_POSITION_LIMIT :: 32767
MORPH_NORMAL_LIMIT :: 32767
MORPH_TANGENT_LIMIT :: 511
MORPH_NORMAL_STEP :: 2.0/MORPH_NORMAL_LIMIT
MORPH_TANGENT_STEP :: 2.0/MORPH_TANGENT_LIMIT

Morph_Target :: struct {
    name:[64]u8 `mirai:"text"`,
    weight:f32,      // without animation or override
    first,count:u32, // rows of morph_deltas
}

// What a target at weight 1 adds to a vertex, in the space of the mesh: to
// its position, and to its normal and its tangent before they are made unit
// length again. Importers and generators give it at full precision
// (Mesh_Source); mesh_build quantizes it.
Morph_Delta :: struct {
    vertex:u32,
    position:[3]f32 `mirai:"unit=m"`,
    normal,tangent:[3]f32,
}

// A Morph_Delta of a vertex of the clusters, quantized: 20 bytes.
Morph_Cluster_Delta :: struct {
    vertex:u32,
    position:[3]i16, // steps of Mesh_Info.morph_step
    normal:[3]i16,   // steps of MORPH_NORMAL_STEP
    tangent:u32,     // x, y and z in bits 0-9, 10-19 and 20-29: signed steps of MORPH_TANGENT_STEP
}
#assert(size_of(Morph_Cluster_Delta)==20)

// The step of the positions of deltas whose largest component is largest.
morph_step :: proc "contextless" (largest:f32) -> f32 {
    need:=max(f64(largest)/MORPH_POSITION_LIMIT,1e-12)
    return f32(math.pow(2,math.ceil(math.log2(need))))
}

// A finite delta on the step of its mesh: each component the nearest step,
// short of those past the largest f32.
morph_quantize :: proc "contextless" (delta:Morph_Delta,step:f32) -> (q:Morph_Cluster_Delta) {
    q.vertex=delta.vertex
    limit:=min(MORPH_POSITION_LIMIT,math.floor(f64(max(f32))/f64(step)))
    for axis in 0..<3 {
        q.position[axis]=i16(clamp(math.round(f64(delta.position[axis])/f64(step)),-limit,limit))
        q.normal[axis]=i16(math.round(f64(clamp(delta.normal[axis],-2,2))*MORPH_NORMAL_LIMIT/2))
        tangent:=i32(math.round(f64(clamp(delta.tangent[axis],-2,2))*MORPH_TANGENT_LIMIT/2))
        q.tangent|=(u32(tangent)&0x3ff)<<(10*u32(axis))
    }
    return
}

morph_position :: #force_inline proc "contextless" (position:[3]i16,step:f32) -> [3]f32 {
    return {f32(position.x),f32(position.y),f32(position.z)}*step
}

morph_normal :: #force_inline proc "contextless" (normal:[3]i16) -> [3]f32 {
    return {f32(normal.x),f32(normal.y),f32(normal.z)}*MORPH_NORMAL_STEP
}

morph_tangent :: #force_inline proc "contextless" (tangent:u32) -> (v:[3]f32) {
    for axis in 0..<3 {v[axis]=f32(i32(tangent<<(22-10*u32(axis)))>>22)*MORPH_TANGENT_STEP}
    return
}

morph_decode :: proc "contextless" (delta:Morph_Cluster_Delta,step:f32) -> Morph_Delta {
    return {vertex=delta.vertex,position=morph_position(delta.position,step),normal=morph_normal(delta.normal),tangent=morph_tangent(delta.tangent)}
}

// The targets of mesh_check: named once each, with finite weights and
// consecutive ranges that cover the deltas, on a step of positions only
// when there are targets.
@(private)
mesh_morph_check :: proc(view:Mesh_View) -> bool {
    if len(view.morphs)>MESH_MAX_MORPHS {return false}
    stepped:=step_valid(view.info.morph_step) if len(view.morphs)>0 else view.info.morph_step==0
    if !stepped {return false}
    used:u64
    for &target,i in view.morphs {
        if target.name[0]==0 || !text_valid(target.name[:]) || !finite(target.weight) || u64(target.first)!=used {return false}
        for other in view.morphs[:i] {if other.name==target.name {return false}}
        used+=u64(target.count)
    }
    return used==u64(len(view.morph_deltas))
}

// The deltas of mesh_check_indices: each names a vertex, after the one before
// it in its target, with nothing past the bits of its tangent.
@(private)
mesh_morph_check_deltas :: proc(view:Mesh_View) -> bool {
    for target in view.morphs {
        for delta,d in view.morph_deltas[target.first:][:target.count] {
            if int(delta.vertex)>=len(view.vertices) || d>0 && delta.vertex<=view.morph_deltas[int(target.first)+d-1].vertex {return false}
            if delta.tangent>>30!=0 {return false}
        }
    }
    return true
}
