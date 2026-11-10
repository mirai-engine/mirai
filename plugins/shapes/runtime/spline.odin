package shapes

import "core:math"
import "core:math/linalg"
import "mirai:core"
import physics "plugins:physics/runtime"
import mm "mirai:std/math"

// Where a Spline lies: its curve sampled by length in the frame of its entity
// (mm.path_sample), each sample on the ground under it, or on the plane of the
// entity without ground there, and its height over that.

RIBBON_SAMPLES :: 4096 // most samples along a ribbon; a longer one takes them farther apart
RIBBON_COLUMNS :: 17   // most points across a ribbon, which follow the ground there
@(private) DOWN :: [3]f32{0,-1,0}

// The points of a Spline as the sampler takes them, in the frame of its
// entity; nil with a value out of range.
@(private)
spline_points :: proc(s:^Shape) -> []mm.Path_Point {
    if shape_valid_counts(s)!=.None {return nil}
    points:=make([]mm.Path_Point,int(s.point_count),context.temp_allocator)
    for &p,i in points {
        if !finite2(s.points[i]) || !(s.widths[i]>0 && s.widths[i]<max(f32)) || !(abs(s.heights[i])<max(f32)) {return nil}
        p={{s.points[i].x,0,s.points[i].y},s.widths[i],s.heights[i]}
    }
    return points
}

// A point of the plane of a spline placed in the world, moved onto the ground under it, and raised by height.
@(private)
lay :: proc(q:^core.Ground_Query,place:mm.Transform,local:[3]f32,height:f32) -> [3]f32 {
    p:=mm.transform_point(place,local)
    if q.probe!=nil {
        if hit,found:=q.probe(q.user,p,DOWN,false);found==.Ground {p.y=hit.point.y}
    }
    return p+{0,height,0}
}

// Writes the path of the Fluid of a spline, in the world, for the physics: what it floats and the water draws.
@(private)
path_write :: proc(u:^Update,e:core.Entity,s:^Shape,place:mm.Transform) {
    value:physics.Fluid_Path
    points:=spline_points(s)
    count:=mm.path_sample(points,1,value.points[:])
    if count==0 {
        core.report(u.problems,e,"shapes.spline","the Spline makes no path for its Fluid: it needs from 2 to %d points, each finite with a width above 0, and fewer than %d; fix its points",SHAPE_POINTS,physics.FLUID_PATH_SAMPLES)
        if core.has(u.paths,e) {core.remove(u.paths,e)}
        return
    }
    for &p in value.points[:count] {p.position=lay(u.ground,place,p.position,p.height)}
    value.count=u16(count)
    if row:=core.edit(u.paths,e);row!=nil {row^=value} else {core.add(u.paths,e,value)}
}

// The points of the ribbon of a spline without a Fluid into g, in the frame
// of the spline: rows along the path of g.columns points each, from its left
// to its right, every one on the ground there and raised by the height. With
// a value out of range g.columns is zero.
@(private)
ribbon_lay :: proc(u:^Update,s:^Shape,place:mm.Transform,g:^Shape_Geometry) {
    clear(&g.ribbon)
    g.columns=0
    points:=spline_points(s)
    if len(points)==0 {return}
    widest:f32
    for p in points {widest=max(widest,p.width)}
    spacing:=u.ground.spacing>0?u.ground.spacing:widest
    piece:=min(1,spacing)
    samples:=make([]mm.Path_Point,RIBBON_SAMPLES,context.temp_allocator)
    count:=mm.path_sample(points,piece,samples)
    columns:=clamp(int(math.ceil(widest/spacing))+1,2,RIBBON_COLUMNS)
    if count<2 || resize(&g.ribbon,count*columns)!=nil {return}
    back,inverted:=mm.transform_inverse_matrix(place)
    if !inverted {return}
    for p,i in samples[:count] {
        along:=samples[min(i+1,count-1)].position-samples[max(i-1,0)].position
        right:=linalg.normalize0([3]f32{-along.z,0,along.x})
        for j in 0..<columns {
            local:=p.position+right*(p.width*(f32(j)/f32(columns-1)-0.5))
            g.ribbon[i*columns+j]=mm.mat4_point(back,lay(u.ground,place,local,p.height))
        }
    }
    g.columns=columns
}
