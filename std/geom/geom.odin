// Geometry processing on plain slices: primitives, convex hulls, mass
// properties, plane slicing, Voronoi fracture, triangulation, simplification,
// clusters and their DAG, and convex decomposition.
//
// Determinism: equal input gives byte-identical output on every machine. The
// package only uses IEEE-754 add, subtract, multiply, divide, square root and
// floor, never the platform's libm; every loop has a fixed order and no result
// depends on addresses or on the iteration order of a hash table.
//
// Precision: coordinates enter and leave as f32. Predicates (side of a plane,
// orientation, visibility) and accumulations (areas, volumes) are evaluated
// in f64, where a product of two f32 values is exact. The ports of
// meshoptimizer (simplify, clusters, partition) compute in f32 as it does, to
// give its results.
//
// Tolerance: every tolerance is an absolute distance in the units of the
// input. `tolerance_noise` gives the smallest distance the package trusts for
// a set of coordinates; an operation uses the larger of that floor and the
// tolerance its caller asks for. Points closer than the tolerance to a plane
// are on the plane.
package geom

import "base:runtime"
import "core:math"
import "core:math/linalg"
import "mirai:std/base"

Vec2 :: [2]f32
Vec3 :: [3]f32
Vec4 :: [4]f32
Mat3 :: matrix[3,3]f32

// Points with dot(normal,p)==d are on the plane; the front is where dot(normal,p)>d.
Plane :: struct {normal:Vec3,d:f32}

EPSILON    :: 1.1920929e-7 // f32 machine epsilon
NOISE_ULPS :: 8
NONE       :: max(u32)

// Smallest distance trusted between coordinates of magnitude max_abs.
tolerance_noise :: proc "contextless" (max_abs:f32) -> f32 {return NOISE_ULPS*EPSILON*max_abs}

// Neither NaN nor infinite: x-x is NaN for both.
@(private) finite2 :: #force_inline proc "contextless" (p:Vec2) -> bool {return p.x-p.x==0 && p.y-p.y==0}
@(private) finite3 :: #force_inline proc "contextless" (p:Vec3) -> bool {return p.x-p.x==0 && p.y-p.y==0 && p.z-p.z==0}

positions_max_abs :: proc "contextless" (positions:[]Vec3) -> f32 {
    m:f32
    for p in positions {m=max(m,abs(p.x),abs(p.y),abs(p.z))}
    return m
}

plane_from_point :: proc "contextless" (normal,point:Vec3) -> Plane {
    return {normal,f32(ddot(dvec(normal),dvec(point)))}
}

plane_distance :: proc "contextless" (plane:Plane,p:Vec3) -> f32 {
    return f32(ddot(dvec(plane.normal),dvec(p))-f64(plane.d))
}

@(private) DVec2 :: [2]f64
@(private) DVec3 :: [3]f64

@(private) dvec :: #force_inline proc "contextless" (v:Vec3) -> DVec3 {return {f64(v.x),f64(v.y),f64(v.z)}}
@(private) fvec :: #force_inline proc "contextless" (v:DVec3) -> Vec3 {return {f32(v.x),f32(v.y),f32(v.z)}}
@(private) ddot :: #force_inline proc "contextless" (a,b:DVec3) -> f64 {return a.x*b.x+a.y*b.y+a.z*b.z}
@(private) dcross :: #force_inline proc "contextless" (a,b:DVec3) -> DVec3 {
    return {a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x}
}
@(private) dlength :: #force_inline proc "contextless" (a:DVec3) -> f64 {return math.sqrt(ddot(a,a))}
@(private) dnormalize :: #force_inline proc "contextless" (a:DVec3) -> DVec3 {
    l:=dlength(a)
    return a/l if l>0 else DVec3{}
}
@(private) fnormalize :: #force_inline proc "contextless" (a:Vec3,fallback:Vec3) -> Vec3 {
    l:=linalg.length(a)
    return a/l if l>1e-20 else fallback
}

// Unit plane in f64. ok is false for a normal without length.
@(private) DPlane :: struct {n:DVec3,d:f64}
@(private) dplane :: proc "contextless" (plane:Plane) -> (out:DPlane,ok:bool) {
    n:=dvec(plane.normal)
    l:=dlength(n)
    if !(l>1e-30) {return {},false}
    return {n/l,f64(plane.d)/l},true
}

// Two unit vectors that complete the normal to a right-handed basis (u×v=n).
@(private) plane_basis :: proc "contextless" (n:DVec3) -> (u,v:DVec3) {
    axis:=DVec3{1,0,0}
    ax,ay,az:=abs(n.x),abs(n.y),abs(n.z)
    if ay<ax && ay<=az {axis={0,1,0}} else if az<ax && az<ay {axis={0,0,1}}
    u=dnormalize(dcross(axis,n))
    v=dcross(n,u)
    return
}

// Sine and cosine of a fraction of a turn (turn 1 is 2π), computed without
// libm so that generated geometry is identical on every machine. Quadrant
// boundaries are exact.
@(private) turn_sincos :: proc "contextless" (turn:f64) -> (s,c:f64) {
    t:=turn-math.floor(turn)
    octant:=int(math.floor(t*8))
    if octant>7 {octant=7}
    quadrant:=(octant+1)/2
    r:=(t-f64(quadrant)*0.25)*(2*math.PI)
    r2:=r*r
    sr:=r*(1+r2*(-1.0/6+r2*(1.0/120+r2*(-1.0/5040+r2*(1.0/362880+r2*(-1.0/39916800+r2*(1.0/6227020800)))))))
    cr:=1+r2*(-0.5+r2*(1.0/24+r2*(-1.0/720+r2*(1.0/40320+r2*(-1.0/3628800+r2*(1.0/479001600+r2*(-1.0/87178291200)))))))
    switch quadrant&3 {
    case 0: return sr,cr
    case 1: return cr,0-sr
    case 2: return 0-sr,-cr
    }
    return -cr,sr
}

@(private) position_hash :: #force_inline proc "contextless" (p:Vec3) -> u64 {
    // Adding zero folds -0 into +0, which compare equal.
    x,y,z:=transmute(u32)(p.x+0),transmute(u32)(p.y+0),transmute(u32)(p.z+0)
    return base.hash_u64(base.hash_u64(u64(x)|u64(y)<<32)~u64(z))
}

// Open addressing map from a u64 key to a u32. Lookups depend only on the
// keys inserted, and nothing iterates the table. It grows only in
// key_map_reset, which takes how many keys it will hold: key_map_entry
// allocates nothing and may add no more than those.
@(private) Key_Map :: struct {keys:[dynamic]u64,values:[dynamic]u32}
@(private) KEY_EMPTY :: max(u64)

@(private) key_map_init :: proc(m:^Key_Map,allocator:runtime.Allocator) {
    m.keys=make([dynamic]u64,allocator)
    m.values=make([dynamic]u32,allocator)
}
@(private) key_map_destroy :: proc(m:^Key_Map) {delete(m.keys);delete(m.values);m^={}}
// Empties the map and makes room for `expected` keys. Without memory the map
// is left without a table, where key_map_find finds nothing.
@(private) key_map_reset :: proc(m:^Key_Map,expected:int) -> runtime.Allocator_Error {
    capacity:=table_capacity(expected)
    if capacity==0 || non_zero_resize(&m.keys,capacity)!=nil || non_zero_resize(&m.values,capacity)!=nil {
        clear(&m.keys);clear(&m.values)
        return .Out_Of_Memory
    }
    for &k in m.keys {k=KEY_EMPTY}
    return nil
}
// Slots of a table that stays at most half full with `expected` entries; 0
// for a count no table holds.
@(private) table_capacity :: proc "contextless" (expected:int) -> int {
    if expected<0 || expected>max(int)/8 {return 0}
    capacity:=64
    for capacity<expected*2 {capacity*=2}
    return capacity
}
// Pointer to the value of key, inserting `value` when it is absent. The
// pointer is valid until the next reset.
@(private) key_map_entry :: proc(m:^Key_Map,key:u64,value:u32) -> (entry:^u32,inserted:bool) #no_bounds_check {
    mask:=u64(len(m.keys)-1)
    slot:=base.hash_u64(key)&mask
    for {
        k:=m.keys[slot]
        if k==key {return &m.values[slot],false}
        if k==KEY_EMPTY {break}
        slot=(slot+1)&mask
    }
    m.keys[slot]=key;m.values[slot]=value
    return &m.values[slot],true
}
@(private) key_map_find :: proc(m:^Key_Map,key:u64) -> (value:u32,found:bool) #no_bounds_check {
    if len(m.keys)==0 {return 0,false}
    mask:=u64(len(m.keys)-1)
    slot:=base.hash_u64(key)&mask
    for {
        k:=m.keys[slot]
        if k==key {return m.values[slot],true}
        if k==KEY_EMPTY {return 0,false}
        slot=(slot+1)&mask
    }
}
@(private) pair_key :: #force_inline proc "contextless" (a,b:u32) -> u64 {return u64(a)<<32|u64(b)}

// Set of distinct positions held in an external array; slots hold index+1.
// Like Key_Map, it grows only in point_set_reset.
@(private) Point_Set :: struct {slots:[dynamic]u32}
@(private) point_set_reset :: proc(s:^Point_Set,expected:int) -> runtime.Allocator_Error {
    capacity:=table_capacity(expected)
    if capacity==0 || non_zero_resize(&s.slots,capacity)!=nil {
        clear(&s.slots)
        return .Out_Of_Memory
    }
    for &slot in s.slots {slot=0}
    return nil
}
// Index of p in points, appended when it is new: points has the capacity for
// every point the set was reset for.
@(private) point_set_add :: proc(s:^Point_Set,points:^[dynamic]Vec3,p:Vec3) -> (index:u32,added:bool) #no_bounds_check {
    mask:=u64(len(s.slots)-1)
    slot:=position_hash(p)&mask
    for {
        v:=s.slots[slot]
        if v==0 {break}
        if points[v-1]==p {return v-1,false}
        slot=(slot+1)&mask
    }
    index=u32(len(points))
    push(points,p)
    s.slots[slot]=index+1
    return index,true
}

@(private) temp_is :: #force_inline proc(allocator:runtime.Allocator) -> bool {
    return allocator.data==context.temp_allocator.data && allocator.procedure==context.temp_allocator.procedure
}

// Room for `extra` more elements, grown by doubling: reserve takes exactly
// what it is asked for, and an array that fills in steps would be copied at
// each of them.
@(private) reserve_more :: proc(array:^[dynamic]$T,extra:int) -> runtime.Allocator_Error {
    need:=len(array)+extra
    if need<=cap(array) {return nil}
    return reserve(array,max(2*cap(array),need))
}

// append for an array whose capacity is already reserved.
@(private) push :: #force_inline proc "contextless" (array:^[dynamic]$T,value:T) #no_bounds_check {
    raw:=(^runtime.Raw_Dynamic_Array)(array)
    ([^]T)(raw.data)[raw.len]=value
    raw.len+=1
}
