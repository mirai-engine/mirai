package spatial

import "base:intrinsics"
import "core:simd"
import math "mirai:std/math"

Aabb :: math.Aabb

// One instruction each. The min and max builtins, and core:math/linalg on top of them, also order
// NaN, which costs several times more in the loops that live on these.
@(private) fmin :: #force_inline proc "contextless" (a,b:f32) -> f32 {return a<b?a:b}
@(private) fmax :: #force_inline proc "contextless" (a,b:f32) -> f32 {return a>b?a:b}
@(private) vmin :: #force_inline proc "contextless" (a,b:[3]f32) -> [3]f32 {return {fmin(a.x,b.x),fmin(a.y,b.y),fmin(a.z,b.z)}}
@(private) vmax :: #force_inline proc "contextless" (a,b:[3]f32) -> [3]f32 {return {fmax(a.x,b.x),fmax(a.y,b.y),fmax(a.z,b.z)}}

// Surface area.
aabb_area :: #force_inline proc "contextless" (a:Aabb) -> f32 {
    e:=a.max-a.min
    return 2*(e.x*e.y+e.y*e.z+e.z*e.x)
}
aabb_center :: #force_inline proc "contextless" (a:Aabb) -> [3]f32 {return a.min*0.5+a.max*0.5}
// Half size.
aabb_extents :: #force_inline proc "contextless" (a:Aabb) -> [3]f32 {return a.max*0.5-a.min*0.5}
// The box that bounds a and a displaced by d.
aabb_translate_extend :: #force_inline proc "contextless" (a:Aabb, d:[3]f32) -> Aabb {
    return {a.min+vmin(d,{}),a.max+vmax(d,{})}
}
aabb_valid :: proc "contextless" (a:Aabb) -> bool {
    for i in 0..<3 {
        if !(a.min[i]<=a.max[i]&&a.min[i]>=min(f32)&&a.max[i]<=max(f32)) {return false}
    }
    return true
}

// Four lanes for three axes: the last lane repeats z, so reducing all four reduces the axes.
@(private) F4 :: #simd[4]f32
@(private) INFINITY :: f32(0h7f800000)
@(private) lanes :: #force_inline proc "contextless" (v:[3]f32) -> F4 {return {v.x,v.y,v.z,v.z}}
// Reads 16 bytes: the vector must be followed by 4 readable bytes, as the bounds of a node are.
@(private) lanes_load :: #force_inline proc "contextless" (v:^[3]f32) -> F4 {
    return simd.swizzle(intrinsics.unaligned_load((^F4)(v)),0,1,2,2)
}
// As fmin and fmax: the second operand when either one is NaN.
@(private) min4 :: #force_inline proc "contextless" (a,b:F4) -> F4 {return simd.select(simd.lanes_lt(a,b),a,b)}
@(private) max4 :: #force_inline proc "contextless" (a,b:F4) -> F4 {return simd.select(simd.lanes_gt(a,b),a,b)}
@(private) boxes_overlap :: #force_inline proc "contextless" (a_lo,a_hi,b_lo,b_hi:F4) -> bool {
    return simd.extract_msbs(simd.bit_and(simd.lanes_le(a_lo,b_hi),simd.lanes_le(b_lo,a_hi)))=={0,1,2,3}
}

// A segment prepared for slab tests. An axis it cannot cross (a zero in the translation, or a
// component too small to divide by) has an infinite inverse: its slab yields -inf, +inf or, with
// the origin on a face, NaN, and the test below reads each of them as inside or outside the slab.
@(private) Segment :: struct {origin,inverse,extents:F4}
@(private) SEGMENT_PARALLEL :: 1e-20

@(private) segment_make :: proc "contextless" (origin,translation,extents:[3]f32) -> Segment {
    inverse:[3]f32
    for i in 0..<3 {inverse[i]=abs(translation[i])<SEGMENT_PARALLEL?INFINITY:1/translation[i]}
    return {lanes(origin),lanes(inverse),lanes(extents)}
}

// Entry fraction of the segment into the closed box [lo,hi], grown by the extents of the segment
// when SWEEP. The order of the operands drops every NaN: one face of a slab with the origin on it
// gives no bound. A box that contains another never reports a later entry, or a miss the inner one
// does not, because every operation is monotonic: a traversal that prunes with this test finds
// exactly the leaves the test accepts.
@(private) segment_box :: #force_inline proc "contextless" (s:^Segment, lo,hi:F4, max_fraction:f32, $SWEEP:bool) -> (fraction:f32, hit:bool) {
    lo,hi:=lo,hi
    when SWEEP {lo-=s.extents;hi+=s.extents}
    a,b:=(lo-s.origin)*s.inverse,(hi-s.origin)*s.inverse
    enter:=max4(min4(b,a),F4{})
    leave:=min4(max4(a,b),F4{max_fraction,max_fraction,max_fraction,max_fraction})
    enter=max4(enter,simd.swizzle(enter,2,3,0,1))
    leave=min4(leave,simd.swizzle(leave,2,3,0,1))
    fraction=fmax(simd.extract(enter,0),simd.extract(enter,1))
    return fraction,fraction<=fmin(simd.extract(leave,0),simd.extract(leave,1))
}

// Slab test of the segment origin + t*translation, t in [0,max_fraction], against a closed box.
// The fraction is where the segment enters the box: 0 when it starts inside.
aabb_ray :: proc "contextless" (a:Aabb, origin,translation:[3]f32, max_fraction:f32) -> (fraction:f32, hit:bool) {
    s:=segment_make(origin,translation,{})
    return segment_box(&s,lanes(a.min),lanes(a.max),max_fraction,false)
}
// The same test for a box that moves by translation: the fraction where it first touches a.
aabb_sweep :: proc "contextless" (a,moving:Aabb, translation:[3]f32, max_fraction:f32) -> (fraction:f32, hit:bool) {
    s:=segment_make(aabb_center(moving),translation,aabb_extents(moving))
    return segment_box(&s,lanes(a.min),lanes(a.max),max_fraction,true)
}
