package mirai_physics

import cmath "core:math"
import math "mirai:std/math"

// Water along a path: the samples of a curve (math.path_sample), each with
// the width of the water there and its height, which is its depth. The
// surface goes through the samples and is level across, between banks at
// half the width on each side; the floor is the depth under it. It ends at
// its first and its last sample. Its current is in the frame of the path:
// -Z along it toward the last sample, +Y up and +X to the right. Bodies
// float and drift in it, and the water draws it, from these samples.

FLUID_PATH_SAMPLES :: 128

Path_Point :: math.Path_Point

@(private)
path_valid :: proc "contextless" (path:[]Path_Point) -> bool {
    if len(path)<2 || len(path)>FLUID_PATH_SAMPLES {return false}
    for p,i in path {
        if !finite(p.position) || !(p.width>0 && p.width<=max(f32)) || !(p.height>0 && p.height<=max(f32)) {return false}
        if i>0 {
            q:=path[i-1].position
            if !((p.position.x-q.x)*(p.position.x-q.x)+(p.position.z-q.z)*(p.position.z-q.z)>1e-6) {return false}
        }
    }
    return true
}

// Where a path is over (x, z): the nearest point of it, the way it goes there and its width and depth;
// inside when (x, z) is between its banks and its ends.
@(private)
Path_Spot :: struct {
    center:Vec3,
    along:Vec3, // unit
    half,depth:f32,
    inside:bool,
}

@(private)
path_spot :: proc "contextless" (f:^Fluid,x,z:f32) -> (spot:Path_Spot) #no_bounds_check {
    count:=int(f.path_count)
    best:=max(f32)
    for j in 0..<count-1 {
        a,b:=f.path[j],f.path[j+1]
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
            depth=a.height+(b.height-a.height)*t,
            inside=far<=half*half && !(j==0 && raw<0) && !(j==count-2 && raw>1),
        }
    }
    return
}

// The normal of the surface of a path where it goes along `along`: level across, sloped along.
@(private)
path_normal :: #force_inline proc "contextless" (along:Vec3) -> Vec3 {
    across:=cmath.sqrt(along.x*along.x+along.z*along.z)
    if !(across>0) {return UP}
    return normalize(Vec3{-along.x*along.y,across*across,-along.z*along.y})
}

// The current of a path where it goes along `along`, from the current in its frame.
@(private)
path_current :: #force_inline proc "contextless" (along,current:Vec3) -> Vec3 {
    right:=normalize(Vec3{-along.z,0,along.x})
    return right*current.x+UP*current.y-along*current.z
}

// The banks and the floor of a path where it is nearest to a point, as outward planes.
@(private)
path_planes :: proc "contextless" (f:^Fluid,p:Vec3) -> [3]Plane {
    spot:=path_spot(f,p.x,p.z)
    side:=normalize(Vec3{-spot.along.z,0,spot.along.x})
    n:=path_normal(spot.along)
    return {{side,dot(side,spot.center)+spot.half},{-side,-dot(side,spot.center)+spot.half},{-n,-dot(n,spot.center-UP*spot.depth)}}
}

@(private)
path_aabb :: proc "contextless" (f:^Fluid) -> Aabb {
    box:=Aabb{{max(f32),max(f32),max(f32)},{-max(f32),-max(f32),-max(f32)}}
    for p in f.path[:f.path_count] {
        half:=0.5*p.width
        box.min=math.vec3_min(box.min,p.position-{half,p.height,half})
        box.max=math.vec3_max(box.max,p.position+{half,0,half})
    }
    return box
}
