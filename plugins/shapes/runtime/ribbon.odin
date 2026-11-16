package shapes

import "core:math"
import "core:math/linalg"
import "mirai:core"
import volume "mirai:engine/volume"
import mm "mirai:std/math"

// The ribbon of a volume.Spline with a material: across its width at each
// sample of its curve, every point on the ground there and raised by the height.

RIBBON_SAMPLES :: 4096 // most samples along a ribbon; a longer one takes them farther apart
RIBBON_COLUMNS :: 17   // most points across a ribbon, which follow the ground there

// The points of the ribbon of a spline placed at place into g, in the frame
// of the spline: rows along the path of g.columns points each, from its left
// to its right. With a value out of range g.columns is zero.
@(private)
ribbon_lay :: proc(q:core.Ground_Query,s:^volume.Spline,place:mm.Transform,g:^Shape_Geometry) {
    clear(&g.ribbon)
    g.columns=0
    widest:f32
    for p in s.points[:min(int(s.count),volume.SPLINE_POINTS)] {widest=max(widest,p.width)}
    spacing:=q.spacing>0?q.spacing:widest
    samples:=make([]mm.Path_Point,RIBBON_SAMPLES,context.temp_allocator)
    count:=volume.spline_sample(s,min(1,spacing),samples)
    if count<2 {return}
    columns:=clamp(int(math.ceil(widest/spacing))+1,2,RIBBON_COLUMNS)
    back,inverted:=mm.transform_inverse_matrix(place)
    if !inverted || resize(&g.ribbon,count*columns)!=nil {return}
    for p,i in samples[:count] {
        along:=samples[min(i+1,count-1)].position-samples[max(i-1,0)].position
        right:=linalg.normalize0([3]f32{-along.z,0,along.x})
        for j in 0..<columns {
            local:=p.position+right*(p.width*(f32(j)/f32(columns-1)-0.5))
            g.ribbon[i*columns+j]=mm.mat4_point(back,volume.spline_lay(q,place,local,p.height))
        }
    }
    g.columns=columns
}
