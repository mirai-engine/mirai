package volume

import "mirai:core"
import "mirai:std/base"
import mm "mirai:std/math"

// A path, as a Volume is a region: what goes along it is another component of
// the same entity, of the library that does it. A Fluid makes it water along
// it (a river); its material, a ribbon on the ground (a road, a path); a
// patrol walks it. It lives beside Volume because every library that reads one
// reads the other, and none of them depends on another to read it.
//
// Its points are in the frame of its entity, each with the width of what goes
// along it there and its height over the ground. Its curve is sampled by length
// (spline_sample) and each sample lies on the ground under it (spline_lay), or
// where the curve is where there is no ground.

SPLINE_POINTS :: 64

@(component,description="A path through its points on the ground under them, each with a width and a height over the ground. A Fluid on its entity makes it water along the path (a river); its material draws it as a ribbon on the ground (a road, a path).")
Spline :: struct {
    count:u16 `mirai:"max=64"`,
    points:[SPLINE_POINTS]mm.Path_Point `mirai:"section=Points"`, // in the frame of the entity; width and height in m
    material:base.Asset_Id `mirai:"kind=.mat"`, // of the ribbon drawn along it, its UVs in meters; none: not drawn
}

// A path of 12 m along -Z, 3 m wide and 0.05 m over the ground.
SPLINE_DEFAULT :: Spline{count=2,points={0={{0,0,0},3,0.05},1={{0,0,-12},3,0.05}}}

@(private) DOWN :: [3]f32{0,-1,0}

// The curve of a spline sampled by length, in the frame of its entity, piece
// meters apart or farther when out cannot hold that many (mm.path_sample).
// Zero for fewer than two points, more than SPLINE_POINTS, or a point that is
// not finite or has no width.
spline_sample :: proc(s:^Spline,piece:f32,out:[]mm.Path_Point) -> int {
    points:=spline_points(s)
    return len(points)>0?mm.path_sample(points,piece,out):0
}

// Its points, or none when spline_sample takes none of them.
@(private)
spline_points :: proc(s:^Spline) -> []mm.Path_Point {
    count:=int(s.count)
    if count<2 || count>SPLINE_POINTS {return nil}
    for p in s.points[:count] {
        q:=p.position
        if !(q.x-q.x==0 && q.y-q.y==0 && q.z-q.z==0) || !(p.width>0 && p.width<max(f32)) || !(abs(p.height)<max(f32)) {return nil}
    }
    return s.points[:count]
}

// Where a spline placed at place lies, seen from above: a box of the world
// around its curve and its width, through every height, since each of its
// points lies on the highest ground under it (spline_lay). The ground changes
// under it only within a box that overlaps this one. False for a spline that
// spline_sample does not sample.
spline_reach :: proc(s:^Spline,place:mm.Transform) -> (mm.Aabb,bool) {
    points:=spline_points(s)
    if len(points)==0 {return {},false}
    // Each span of the Catmull-Rom curve is a cubic Bezier through a and b, so
    // it stays within the box of those two and its two inner control points.
    local:=mm.Aabb{points[0].position,points[0].position}
    for i in 0..<len(points)-1 {
        a,b:=points[i],points[i+1]
        before:=i>0?points[i-1].position:2*a.position-b.position
        after:=i+2<len(points)?points[i+2].position:2*b.position-a.position
        half:=max(a.width,b.width)*0.5
        for c in ([4][3]f32{a.position,a.position+(b.position-before)/6,b.position-(after-a.position)/6,b.position}) {
            local=mm.aabb_merge(local,{c-{half,0,half},c+{half,0,half}})
        }
    }
    box:=mm.aabb_transform(local,mm.transform_matrix(place))
    box.min.y,box.max.y=-max(f32),max(f32)
    return box,true
}

// Whether e has a spline, placed at place, whose reach one of boxes overlaps:
// one to lay again where the ground changed in those boxes.
spline_under :: proc(splines:core.Read(Spline),e:core.Entity,place:mm.Transform,boxes:[]mm.Aabb) -> bool {
    if splines.table==nil {return false}
    spline,has:=core.get(splines,e)
    if !has {return false}
    reach:=spline_reach(&spline,place) or_return
    for box in boxes {
        if mm.aabb_overlaps(reach,box) {return true}
    }
    return false
}

// A point of a spline placed at place, in the world: on the ground under it,
// or where it is without ground there, and raised by height.
spline_lay :: proc(q:core.Ground_Query,place:mm.Transform,local:[3]f32,height:f32) -> [3]f32 {
    p:=mm.transform_point(place,local)
    if q.probe!=nil {
        if hit,found:=q.probe(q.user,p,DOWN,false);found==.Ground {p.y=hit.point.y}
    }
    return p+{0,height,0}
}
