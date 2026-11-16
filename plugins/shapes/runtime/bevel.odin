package shapes

import "core:math"
import "core:math/linalg"
import "core:slice"
import "mirai:std/geom"

// The bevel of an Outline. Each point of a loop moves its cap point in along
// the bisector of its corner, offsetting both its edges by its inset; the
// rings of the profile lie on the segment between the point and its cap
// point, and fall along Z by the drop, the bevel or most of half the depth
// when that is less, the same for every point so the bands do not twist
// along an edge; where an inset is clamped its profile is steeper. The
// insets are clamped so every cap keeps part of each edge and of each gap
// across the shape, and checked: a band that turns over or cap edges that
// meet halve the insets of their points, and a bevel that still does not fit
// after a few halvings is left out.

// How far a cap point may move along the bisector, in insets: sharper corners are inset less than their edges.
@(private) MITER_LIMIT :: 4
// The part of an edge, of a gap across the shape and of the depth that a clamped bevel leaves.
@(private) BEVEL_KEEP :: 0.1
@(private) BEVEL_SEGMENTS_DEFAULT :: 4
@(private) BEVEL_TRIES :: 10
// Edge passes after which insets that still collapse an edge are halved by the check.
@(private) BEVEL_PASSES :: 64

// A point of the profile and its normal in the plane across the rim: across
// from the side (1 at the cap) and along from the cap (1 at the side), the
// normal out from the side and up from the cap.
@(private)
Bevel_Ring :: struct {across,along,out,up:f32}

// The rings of the profile of an Outline from the cap to the side, in
// temporary memory; none without a bevel.
@(private)
bevel_rings :: proc(s:^Shape) -> (rings:[]Bevel_Ring,error:Shape_Error) {
    if !(s.bevel>=0 && s.bevel<max(f32)) {return nil,.Invalid}
    if s.bevel==0 {return nil,.None}
    switch s.bevel_profile {
    case .Round:
        n:=int(s.bevel_segments)
        if n==0 {n=BEVEL_SEGMENTS_DEFAULT}
        if n>BEVEL_SEGMENTS {return nil,.Invalid}
        rings=make([]Bevel_Ring,n+1,context.temp_allocator)
        for k in 0..=n {
            a:=0.5*math.PI*f64(k)/f64(n)
            sin,cos:=f32(math.sin(a)),f32(math.cos(a))
            rings[k]={1-sin,1-cos,sin,cos}
        }
        rings[0]={1,0,0,1}
        rings[n]={0,1,1,0}
    case .Chamfer:
        rings=make([]Bevel_Ring,2,context.temp_allocator)
        c:=f32(math.SQRT_TWO*0.5)
        rings[0],rings[1]={1,0,c,c},{0,1,c,c}
    case .Points:
        n:=int(s.bevel_point_count)
        if n>BEVEL_POINTS {return nil,.Invalid}
        rings=make([]Bevel_Ring,n+2,context.temp_allocator)
        rings[0],rings[n+1]={across=1},{along=1}
        for p,i in s.bevel_points[:n] {
            if !(p.x>=0 && p.x<=1 && p.y>=0 && p.y<=1) {return nil,.Invalid}
            rings[i+1]={across=p.x,along=p.y}
        }
        // Each segment has length and goes out and down; a ring takes the
        // normal of its segments, shared between two.
        for k in 0..<n+1 {
            a,b:=rings[k],rings[k+1]
            out,down:=a.across-b.across,b.along-a.along
            if out<0 || down<0 || out==0 && down==0 {return nil,.Invalid}
            normal:=linalg.normalize(geom.Vec2{down,out})
            rings[k].out+=normal.x;rings[k].up+=normal.y
            rings[k+1].out+=normal.x;rings[k+1].up+=normal.y
        }
        for &r in rings {
            normal:=linalg.normalize(geom.Vec2{r.out,r.up})
            r.out,r.up=normal.x,normal.y
        }
    case:
        return nil,.Invalid
    }
    return rings,.None
}

// What a bevel moves: per point of the loops, the offset of its cap point
// and its inset, the distance its edges move in.
@(private)
Bevel_Insets :: struct {
    offsets:[]geom.Vec2,
    insets:[]f32,
    next:[]int, // the next point of the loop of each
}

// The insets of a bevel of size over the checked loops, clamped where the
// shape is smaller than it, in temporary memory.
@(private)
bevel_insets :: proc(points:[]geom.Vec2,sizes:[]int,size:f32) -> Bevel_Insets {
    n:=len(points)
    b:=Bevel_Insets{
        offsets=make([]geom.Vec2,n,context.temp_allocator),
        insets=make([]f32,n,context.temp_allocator),
        next=make([]int,n,context.temp_allocator),
    }
    miters:=make([]geom.Vec2,n,context.temp_allocator)
    inward:=make([]geom.Vec2,n,context.temp_allocator) // of the edge that starts at each point
    first:=0
    for size_of_loop in sizes {
        for i in 0..<size_of_loop {
            b.next[first+i]=first+(i+1)%size_of_loop
            inward[first+i]=-edge_normal(points[first+i],points[b.next[first+i]])
        }
        for i in 0..<size_of_loop {
            before,after:=inward[first+(i+size_of_loop-1)%size_of_loop],inward[first+i]
            // Offsets both edges by one: a bisector of length 1/cos of half the turn.
            m:=(before+after)/max(1+linalg.dot(before,after),1e-6)
            if !(linalg.length(m)<=MITER_LIMIT) {m=linalg.normalize0(before+after)*MITER_LIMIT}
            miters[first+i]=m
        }
        first+=size_of_loop
    }
    for &r in b.insets {r=size}
    // A point moving in must stay in front of each edge across from it as
    // that edge moves in too, keeping part of the gap between them.
    for p,i in points {
        for e in 0..<n {
            f:=b.next[e]
            if e==i || f==i {continue}
            a,c:=points[e],points[f]
            length:=linalg.length(c-a)
            if !(length>0) {continue}
            along:=linalg.dot(p-a,c-a)/(length*length)
            gap:=linalg.dot(p-a,inward[e])
            closing:=1-linalg.dot(miters[i],inward[e])
            if along<0 || along>1 || !(gap>0) || !(closing>0) {continue}
            limit:=(1-BEVEL_KEEP)*gap/closing
            b.insets[i]=min(b.insets[i],limit)
            b.insets[e]=min(b.insets[e],limit)
            b.insets[f]=min(b.insets[f],limit)
        }
    }
    // Every edge of a cap keeps part of its length.
    for _ in 0..<BEVEL_PASSES {
        changed:=false
        for i in 0..<n {
            j:=b.next[i]
            d:=points[j]-points[i]
            length:=linalg.length(d)
            if !(length>0) {continue}
            d/=length
            shrink:=b.insets[i]*linalg.dot(miters[i],d)-b.insets[j]*linalg.dot(miters[j],d)
            if shrink>(1-BEVEL_KEEP)*length {
                scale:=(1-BEVEL_KEEP)*length/shrink
                b.insets[i]*=scale
                b.insets[j]*=scale
                changed=true
            }
        }
        if !changed {break}
    }
    for i in 0..<n {b.offsets[i]=miters[i]*b.insets[i]}
    return b
}

// Whether the caps of the insets make a valid shape: every band between a
// loop and its cap loop keeps its turn, and the cap loops meet nowhere, keep
// their turn and nest as the loops do. bad marks the points whose insets take
// part in what does not.
@(private)
bevel_fits :: proc(s:^Shape,points:[]geom.Vec2,sizes:[]int,b:Bevel_Insets,bad:[]bool) -> bool {
    slice.fill(bad,false)
    caps:=s^
    fits:=true
    for p,i in points {
        q:=ring_point(p,b.offsets[i],1)
        caps.points[i]=q
        if !finite2(q) {bad[i],fits=true,false}
    }
    if !fits {return false}
    for p,i in points {
        j:=b.next[i]
        a,c,d,e:=dvec(p),dvec(points[j]),dvec(caps.points[j]),dvec(caps.points[i])
        if !(orient(a,c,d)>0 && orient(c,d,e)>0 && orient(d,e,a)>0 && orient(e,a,c)>0) {bad[i],bad[j],fits=true,true,false}
    }
    first:=0
    for size in sizes {
        before,after:=loop_area(points[first:first+size]),loop_area(caps.points[first:first+size])
        if after==0 || (after>0)!=(before>0) {
            slice.fill(bad[first:first+size],true)
            fits=false
        }
        first+=size
    }
    // Two edges that meet each fail their own check.
    for edge in 0..<len(points) {
        if !edge_clear(&caps,edge) {
            a,c:=edge_ends(&caps,edge)
            bad[a],bad[c],fits=true,true,false
        }
    }
    if fits && !loops_nested(&caps) {
        slice.fill(bad[sizes[0]:],true)
        fits=false
    }
    return fits
}

@(private)
ring_point :: #force_inline proc "contextless" (p,offset:geom.Vec2,across:f32) -> geom.Vec2 {
    return p+offset*across
}

// The height of a front ring: the back is its negative.
@(private)
ring_z :: #force_inline proc "contextless" (h,along,drop:f32) -> f32 {
    return h-along*drop
}

// Builds the drawn mesh of an Outline with a bevel into g.mesh: its caps
// inset, the rings of the profile on its front and back rims and its sides
// between them. False, with nothing built, when no inset fits.
@(private)
outline_bevel_build :: proc(s:^Shape,points:[]geom.Vec2,sizes:[]int,rings:[]Bevel_Ring,k:[2]f32,g:^Shape_Geometry) -> bool {
    h:=0.5*s.depth
    b:=bevel_insets(points,sizes,s.bevel)
    caps:=make([]geom.Vec2,len(points),context.temp_allocator)
    triangles:=make([dynamic]u32,context.temp_allocator)
    bad:=make([]bool,len(points),context.temp_allocator)
    fits:=false
    for _ in 0..<BEVEL_TRIES {
        if bevel_fits(s,points,sizes,b,bad) {
            for p,i in points {caps[i]=ring_point(p,b.offsets[i],1)}
            clear(&triangles)
            if geom.polygon_triangulate(caps,sizes,&triangles)>0 {
                fits=true
                break
            }
            slice.fill(bad,true)
        }
        for halve,i in bad {
            if halve {b.offsets[i]*=0.5;b.insets[i]*=0.5}
        }
    }
    if !fits {return false}
    count:=len(rings)
    drop:=min(s.bevel,(1-BEVEL_KEEP)*h)
    top:=ring_z(h,1,drop)
    // Per point and ring, the length of the profile from the side.
    arcs:=make([]f32,len(points)*count,context.temp_allocator)
    for i in 0..<len(points) {
        arc:=arcs[i*count:][:count]
        for r:=count-2;r>=0;r-=1 {
            step:=geom.Vec2{(rings[r].across-rings[r+1].across)*b.insets[i],(rings[r+1].along-rings[r].along)*drop}
            arc[r]=arc[r+1]+linalg.length(step)
        }
    }
    m:=&g.mesh
    n:=u32(len(points))
    for q in caps {
        append(&m.positions,geom.Vec3{q.x,q.y,h});append(&m.normals,geom.Vec3{0,0,1});append(&m.uvs,geom.Vec2{q.x,-q.y}*k)
    }
    for q in caps {
        append(&m.positions,geom.Vec3{q.x,q.y,-h});append(&m.normals,geom.Vec3{0,0,-1});append(&m.uvs,geom.Vec2{-q.x,-q.y}*k)
    }
    for i:=0;i<len(triangles);i+=3 {
        a,c,d:=triangles[i],triangles[i+1],triangles[i+2]
        append(&m.indices,a,c,d,n+a,n+d,n+c)
    }
    first:=0
    for size in sizes {
        loop:=points[first:first+size]
        side:=make([]geom.Vec2,size,context.temp_allocator)
        for i in 0..<size {side[i]=edge_normal(loop[i],loop[(i+1)%size])}
        for i in 0..<size {
            j:=(i+1)%size
            ends:=[2]int{first+i,first+j}
            across:=[2]geom.Vec2{side_normal(side[(i+size-1)%size],side[i]),side_normal(side[j],side[i])}
            u:=side_u(loop[i],loop[j])*k.x
            base:=u32(len(m.positions))
            for e in 0..<2 {
                p:=points[ends[e]]
                append(&m.positions,geom.Vec3{p.x,p.y,-top},geom.Vec3{p.x,p.y,top})
                append(&m.normals,geom.Vec3{across[e].x,across[e].y,0},geom.Vec3{across[e].x,across[e].y,0})
                append(&m.uvs,geom.Vec2{u[e],2*top*k.y},geom.Vec2{u[e],0})
            }
            append(&m.indices,base,base+2,base+3,base,base+3,base+1)
            // The front band, then the back one: a vertex per ring and end.
            for face in 0..<2 {
                sign:=f32(1) if face==0 else -1
                base=u32(len(m.positions))
                for r in 0..<count {
                    ring:=rings[r]
                    for e in 0..<2 {
                        at:=ends[e]
                        p:=ring_point(points[at],b.offsets[at],ring.across)
                        // The normal of the profile scaled by the inset across and the drop along.
                        normal:=linalg.normalize0(geom.Vec3{across[e].x*ring.out*drop,across[e].y*ring.out*drop,sign*ring.up*b.insets[at]})
                        arc:=arcs[at*count+r]
                        v:=-arc*k.y if face==0 else (2*top+arc)*k.y
                        append(&m.positions,geom.Vec3{p.x,p.y,sign*ring_z(h,ring.along,drop)})
                        append(&m.normals,normal)
                        append(&m.uvs,geom.Vec2{u[e],v})
                    }
                }
                for r in 0..<u32(count-1) {
                    // Front: ring r is above r+1; back: below it.
                    lo,hi:=base+2*(r+1),base+2*r
                    if face==1 {lo,hi=hi,lo}
                    append(&m.indices,lo,lo+1,hi+1,lo,hi+1,hi)
                }
            }
        }
        first+=size
    }
    return true
}
