package mirai_math

import "core:math"
import "core:math/linalg"
import "mirai:std/base"

// Ranges and distributions over base.Rng, the generator with explicit state.
// A seed gives the same values on every platform: the only functions used
// beyond arithmetic are the square root and core's software logarithm and
// sine, never the ones of the platform's C library.

Rng :: base.Rng
rng_make :: base.rng_make
rng_u32 :: base.rng_u32
rng_u64 :: base.rng_u64

// Uniform in [0,1).
random_f32 :: #force_inline proc "contextless" (r:^Rng) -> f32 {return f32(rng_u32(r)>>8)*(1.0/16777216.0)}
// Uniform in [low,high).
random_range :: #force_inline proc "contextless" (r:^Rng,low,high:f32) -> f32 {return low+(high-low)*random_f32(r)}
// Uniform integer in [0,bound), without the bias of a remainder. 0 when bound is 0.
random_below :: proc "contextless" (r:^Rng,bound:u32) -> u32 {
    if bound==0 {return 0}
    product:=u64(rng_u32(r))*u64(bound)
    if u32(product)<bound {
        threshold:=(~bound+1)%bound
        for u32(product)<threshold {product=u64(rng_u32(r))*u64(bound)}
    }
    return u32(product>>32)
}
// Uniform integer in [low,high). low when the range is empty.
random_int :: proc "contextless" (r:^Rng,low,high:int) -> int {
    if high<=low {return low}
    span:=u64(high-low)
    if span<=u64(max(u32)) {return low+int(random_below(r,u32(span)))}
    limit:=max(u64)-max(u64)%span
    for {
        if value:=rng_u64(r);value<limit {return low+int(value%span)}
    }
}
random_bool :: proc "contextless" (r:^Rng,probability:f32=0.5) -> bool {return random_f32(r)<probability}
// -1 or 1.
random_sign :: proc "contextless" (r:^Rng) -> f32 {return 1 if rng_u32(r)&0x80000000==0 else -1}

// Uniform over the unit disc.
random_in_disc :: proc "contextless" (r:^Rng) -> Vec2 {
    for {
        v:=Vec2{random_range(r,-1,1),random_range(r,-1,1)}
        if linalg.dot(v,v)<=1 {return v}
    }
}
// Uniform over the unit circle.
random_unit_vec2 :: proc "contextless" (r:^Rng) -> Vec2 {
    for {
        v:=Vec2{random_range(r,-1,1),random_range(r,-1,1)}
        if squared:=linalg.dot(v,v);squared<=1 && squared>1e-6 {return v/math.sqrt(squared)}
    }
}
// Uniform over the unit ball.
random_in_sphere :: proc "contextless" (r:^Rng) -> Vec3 {
    for {
        v:=Vec3{random_range(r,-1,1),random_range(r,-1,1),random_range(r,-1,1)}
        if linalg.dot(v,v)<=1 {return v}
    }
}
// Uniform over the unit sphere.
random_unit_vec3 :: proc "contextless" (r:^Rng) -> Vec3 {
    for {
        a,b:=random_range(r,-1,1),random_range(r,-1,1)
        squared:=a*a+b*b
        if squared>=1 {continue}
        factor:=2*math.sqrt(1-squared)
        return {a*factor,b*factor,1-2*squared}
    }
}
// A unit vector within half_angle radians of the axis, uniform over that cap of the sphere.
random_in_cone :: proc "contextless" (r:^Rng,axis:Vec3,half_angle:f32) -> Vec3 {
    _,limit:=math.sincos(f64(clamp(half_angle,0,PI)))
    z:=1-random_f32(r)*(1-f32(limit))
    around:=random_unit_vec2(r)*math.sqrt(max(1-z*z,0))
    n:=linalg.normalize0(axis)
    if n=={} {n={0,0,1}}
    // Two vectors that complete an orthonormal basis with n.
    sign:=f32(1) if n.z>=0 else -1
    a:=-1/(sign+n.z)
    b:=n.x*n.y*a
    tangent:=Vec3{1+sign*n.x*n.x*a,sign*b,-sign*n.x}
    bitangent:=Vec3{b,sign+n.y*n.y*a,-n.y}
    return linalg.normalize0(tangent*around.x+bitangent*around.y+n*z)
}
// A rotation uniform over all rotations.
random_quat :: proc "contextless" (r:^Rng) -> Quat {
    first:=random_in_disc(r)
    for {
        second:=random_in_disc(r)
        squared:=linalg.dot(second,second)
        if squared<1e-12 {continue}
        scale:=math.sqrt((1-linalg.dot(first,first))/squared)
        return quaternion(w=first.x,x=first.y,y=second.x*scale,z=second.y*scale)
    }
}
// Normal distribution.
random_gaussian :: proc "contextless" (r:^Rng,mean:f32=0,deviation:f32=1) -> f32 {
    for {
        a,b:=random_range(r,-1,1),random_range(r,-1,1)
        squared:=a*a+b*b
        if squared>=1 || squared<1e-12 {continue}
        return mean+deviation*a*math.sqrt(-2*ln_det(squared)/squared)
    }
}
// An index chosen with probability proportional to its weight; weights below
// 0 count as 0. -1 when no weight is positive.
random_weighted :: proc "contextless" (r:^Rng,weights:[]f32) -> int {
    total:f32
    for weight in weights {total+=max(weight,0)}
    if !(total>0) {return -1}
    target:=random_f32(r)*total
    last:=-1
    for weight,index in weights {
        if !(weight>0) {continue}
        last=index
        target-=weight
        if target<0 {return index}
    }
    return last
}
// Every order of the items is equally likely.
random_shuffle :: proc "contextless" (r:^Rng,items:[]$T) {
    for i:=len(items)-1;i>0;i-=1 {
        j:=int(random_below(r,u32(i+1)))
        items[i],items[j]=items[j],items[i]
    }
}
