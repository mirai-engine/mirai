package mirai_physics

import cmath "core:math"
import math "mirai:std/math"

// A river is a path of points, each with the width, the depth and the speed
// of the water there. Its surface goes through the points on a Catmull-Rom
// curve and is level across, between banks at half its width on each side;
// its floor is its depth under the surface; it flows along the path. It ends
// at its first and its last point. Bodies float and drift in it, and the
// water draws it, from the one path the simulation keeps (river_samples).

FLUID_RIVER_POINTS :: 16
FLUID_RIVER_SAMPLES :: 128 // of the curve of a river: its pieces are FLUID_RIVER_PIECE long, or longer when it is too long for these
FLUID_RIVER_PIECE :: f32(1) // m

River_Point :: struct {
    position:Vec3, // of the middle of the surface
    width:f32,     // m from bank to bank
    depth:f32,     // m from the surface to the floor
    speed:f32,     // m/s along the path, toward the last point; below zero, back
}

// The path of a river as the simulation follows it: its points and, between
// two, more on the curve through them, about FLUID_RIVER_PIECE apart, with
// width, depth and speed in proportion; the sample each point is at in at.
// Returns how many; zero for fewer than two points.
river_samples :: proc "contextless" (points:[]River_Point,out:^[FLUID_RIVER_SAMPLES]River_Point,at:^[FLUID_RIVER_POINTS]u8) -> int {
    n:=min(len(points),FLUID_RIVER_POINTS)
    if n<2 {return 0}
    whole:f32
    for i in 1..<n {whole+=length(points[i].position-points[i-1].position)}
    // Each span takes at most one piece more than its share, so the pieces fit.
    piece:=max(FLUID_RIVER_PIECE,whole/f32(FLUID_RIVER_SAMPLES-1-(n-1)))
    count:=0
    for i in 0..<n-1 {
        a,b:=points[i],points[i+1]
        // The ends go on straight.
        before:=i>0?points[i-1].position:2*a.position-b.position
        after:=i+2<n?points[i+2].position:2*b.position-a.position
        steps:=max(int(cmath.ceil(length(b.position-a.position)/piece)),1)
        at[i]=u8(count)
        for k in 0..<steps {
            t:=f32(k)/f32(steps)
            out[count]={
                position=math.catmull_rom(before,a.position,b.position,after,t),
                width=a.width+(b.width-a.width)*t,depth=a.depth+(b.depth-a.depth)*t,speed=a.speed+(b.speed-a.speed)*t,
            }
            count+=1
        }
    }
    out[count]=points[n-1]
    at[n-1]=u8(count)
    return count+1
}

@(private)
river_valid :: proc "contextless" (d:Fluid_Desc) -> bool {
    if d.river_count<2 || d.river_count>FLUID_RIVER_POINTS {return false}
    d:=d
    for p,i in d.river[:d.river_count] {
        if !is_finite3(p.position) || !(p.width>0 && p.width<=max(f32)) || !(p.depth>0 && p.depth<=max(f32)) || !(abs(p.speed)<=max(f32)) {return false}
        if i>0 {
            q:=d.river[i-1].position
            if !((p.position.x-q.x)*(p.position.x-q.x)+(p.position.z-q.z)*(p.position.z-q.z)>1e-6) {return false}
        }
    }
    return true
}

// Where a river is over (x, z): the nearest point of its path, the way it goes there and its width, depth
// and speed; inside when (x, z) is between its banks and its ends.
@(private)
River_Spot :: struct {
    center:Vec3,
    along:Vec3, // unit
    half,depth,speed:f32,
    inside:bool,
}

@(private)
river_spot :: proc "contextless" (f:^Fluid,x,z:f32) -> (spot:River_Spot) #no_bounds_check {
    count:=int(f.river_at[f.river_count-1])+1
    best:=max(f32)
    for j in 0..<count-1 {
        a,b:=f.river[j],f.river[j+1]
        ab:=[2]f32{b.position.x-a.position.x,b.position.z-a.position.z}
        ap:=[2]f32{x-a.position.x,z-a.position.z}
        long:=ab.x*ab.x+ab.y*ab.y
        if !(long>0) {continue}
        raw:=(ap.x*ab.x+ap.y*ab.y)/long
        t:=clamp(raw,0,1)
        off:=ap-ab*t
        far:=off.x*off.x+off.y*off.y
        if far>=best {continue}
        best=far
        half:=0.5*(a.width+(b.width-a.width)*t)
        spot={
            center=a.position+(b.position-a.position)*t,along=normalize(b.position-a.position),half=half,
            depth=a.depth+(b.depth-a.depth)*t,speed=a.speed+(b.speed-a.speed)*t,
            inside=far<=half*half && !(j==0 && raw<0) && !(j==count-2 && raw>1),
        }
    }
    return
}

// The normal of the surface of a river where it goes along `along`: level across, sloped along.
@(private)
river_normal :: #force_inline proc "contextless" (along:Vec3) -> Vec3 {
    across:=cmath.sqrt(along.x*along.x+along.z*along.z)
    if !(across>0) {return UP}
    return normalize(Vec3{-along.x*along.y,across*across,-along.z*along.y})
}

// The banks and the floor of a river where it is nearest to a point, as outward planes.
@(private)
river_planes :: proc "contextless" (f:^Fluid,p:Vec3) -> [3]Plane {
    spot:=river_spot(f,p.x,p.z)
    side:=normalize(Vec3{-spot.along.z,0,spot.along.x})
    n:=river_normal(spot.along)
    return {{side,dot(side,spot.center)+spot.half},{-side,-dot(side,spot.center)+spot.half},{-n,-dot(n,spot.center-UP*spot.depth)}}
}

@(private)
river_aabb :: proc "contextless" (f:^Fluid) -> Aabb {
    count:=int(f.river_at[f.river_count-1])+1
    box:=Aabb{{max(f32),max(f32),max(f32)},{-max(f32),-max(f32),-max(f32)}}
    for p in f.river[:count] {
        half:=0.5*p.width
        box.min=math.vec3_min(box.min,p.position-{half,p.depth,half})
        box.max=math.vec3_max(box.max,p.position+{half,0,half})
    }
    return box
}
