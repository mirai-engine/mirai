package geom

import "base:runtime"
import "core:math"
import "core:slice"

// Delaunay triangulation of a set of points by sweeping the hull outwards
// from a seed triangle and flipping the edges that break the empty circle
// rule. Writes counter-clockwise triangles as indices into points and returns
// how many; `halfedges`, when given, gets for every triangle edge (3*triangle
// + corner, from that corner to the next) the opposite edge, or NONE on the
// hull. Repeated points are left out; points on one line, a point that is
// not finite, or no memory give no triangles.
delaunay_triangulate :: proc(points:[]Vec2,triangles:^[dynamic]u32,halfedges:^[dynamic]u32=nil) -> int #no_bounds_check {
    clear(triangles)
    if halfedges!=nil {clear(halfedges)}
    n:=len(points)
    if n<3 {return 0}
    for p in points {
        if !finite2(p) {return 0}
    }
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore=temp_is(triangles.allocator))
    scratch:=context.temp_allocator
    d:Delaunay
    d.points=make([]DVec2,n,scratch)
    lo,hi:=DVec2{max(f64),max(f64)},DVec2{-max(f64),-max(f64)}
    for p,i in points {
        d.points[i]={f64(p.x),f64(p.y)}
        lo={min(lo.x,d.points[i].x),min(lo.y,d.points[i].y)}
        hi={max(hi.x,d.points[i].x),max(hi.y,d.points[i].y)}
    }
    middle:=(lo+hi)*0.5
    distance2 :: #force_inline proc "contextless" (a,b:DVec2) -> f64 {
        dx,dy:=a.x-b.x,a.y-b.y
        return dx*dx+dy*dy
    }
    // Seed: the point nearest to the middle, the point nearest to it, and
    // the point that makes the smallest circle with both.
    i0,i1,i2:=-1,-1,-1
    best:=max(f64)
    for p,i in d.points {
        if distance:=distance2(p,middle);distance<best {best=distance;i0=i}
    }
    best=max(f64)
    for p,i in d.points {
        if i==i0 {continue}
        if distance:=distance2(p,d.points[i0]);distance<best && distance>0 {best=distance;i1=i}
    }
    if i1<0 {return 0}
    best=max(f64)
    for p,i in d.points {
        if i==i0 || i==i1 {continue}
        if _,radius:=circumcircle(d.points[i0],d.points[i1],p);radius<best {best=radius;i2=i}
    }
    if i2<0 || best==max(f64) {return 0}
    if orient2(d.points[i0],d.points[i1],d.points[i2])<0 {i1,i2=i2,i1}
    d.center,_=circumcircle(d.points[i0],d.points[i1],d.points[i2])

    Order :: struct {distance:f64,index:u32}
    order:=make([]Order,n,scratch)
    for p,i in d.points {order[i]={distance2(p,d.center),u32(i)}}
    slice.sort_by(order,proc(a,b:Order) -> bool {return a.distance<b.distance || (a.distance==b.distance && a.index<b.index)})

    capacity:=max(2*n-5,1)*3
    d.triangles=make([]u32,capacity,scratch)
    d.halfedges=make([]u32,capacity,scratch)
    d.hull_prev=make([]u32,n,scratch)
    d.hull_next=make([]u32,n,scratch)
    d.hull_tri=make([]u32,n,scratch)
    d.hash=make([]u32,int(math.ceil(math.sqrt(f64(n)))),scratch)
    d.stack=make([dynamic]u32,0,64,scratch)
    for &h in d.hash {h=NONE}
    a,b,c:=u32(i0),u32(i1),u32(i2)
    d.hull_start=a
    d.hull_next[a]=b;d.hull_prev[c]=b
    d.hull_next[b]=c;d.hull_prev[a]=c
    d.hull_next[c]=a;d.hull_prev[b]=a
    d.hull_tri[a]=0;d.hull_tri[b]=1;d.hull_tri[c]=2
    d.hash[hash_key(&d,d.points[a])]=a
    d.hash[hash_key(&d,d.points[b])]=b
    d.hash[hash_key(&d,d.points[c])]=c
    triangle_add(&d,a,b,c,NONE,NONE,NONE)

    previous:DVec2
    for entry,k in order {
        i:=entry.index
        p:=d.points[i]
        if k>0 && p==previous {continue}
        previous=p
        if i==a || i==b || i==c {continue}
        // A hull edge that sees the point, starting near its direction.
        start:=u32(0)
        key:=hash_key(&d,p)
        for j in 0..<len(d.hash) {
            start=d.hash[(key+j)%len(d.hash)]
            if start!=NONE && start!=d.hull_next[start] {break}
        }
        start=d.hull_prev[start]
        e:=start
        visible:=true
        for {
            q:=d.hull_next[e]
            if orient2(p,d.points[e],d.points[q])<0 {break}
            e=q
            if e==start {visible=false;break}
        }
        if !visible {continue}
        t:=triangle_add(&d,e,i,d.hull_next[e],NONE,NONE,d.hull_tri[e])
        d.hull_tri[i]=legalize(&d,t+2)
        d.hull_tri[e]=t
        // Forwards along the hull while its edges see the point.
        next:=d.hull_next[e]
        for {
            q:=d.hull_next[next]
            if !(orient2(p,d.points[next],d.points[q])<0) {break}
            t=triangle_add(&d,next,i,q,d.hull_tri[i],NONE,d.hull_tri[next])
            d.hull_tri[i]=legalize(&d,t+2)
            d.hull_next[next]=next
            next=q
        }
        // And backwards when the search began at the first edge.
        if e==start {
            for {
                q:=d.hull_prev[e]
                if !(orient2(p,d.points[q],d.points[e])<0) {break}
                t=triangle_add(&d,q,i,e,NONE,d.hull_tri[e],d.hull_tri[q])
                legalize(&d,t+2)
                d.hull_tri[q]=t
                d.hull_next[e]=e
                e=q
            }
        }
        d.hull_start=e
        d.hull_prev[i]=e
        d.hull_next[e]=i
        d.hull_prev[next]=i
        d.hull_next[i]=next
        d.hash[hash_key(&d,p)]=i
        d.hash[hash_key(&d,d.points[e])]=e
    }
    if d.refused {return 0}
    if _,err:=append(triangles,..d.triangles[:d.count]);err!=nil {return 0}
    if halfedges!=nil {
        if _,err:=append(halfedges,..d.halfedges[:d.count]);err!=nil {
            clear(triangles)
            return 0
        }
    }
    return d.count/3
}

@(private="file") Delaunay :: struct {
    points:   []DVec2,
    center:   DVec2,
    triangles:[]u32,
    halfedges:[]u32,
    count:    int, // corners in use
    hull_prev:[]u32,
    hull_next:[]u32, // a vertex that left the hull points to itself
    hull_tri: []u32, // edge of the hull that leaves each hull vertex
    hull_start:u32,
    hash:     []u32, // a hull vertex per direction from the center
    stack:    [dynamic]u32,
    refused:  bool, // the stack found no memory: edges were left unflipped
}

@(private="file") orient2 :: #force_inline proc "contextless" (a,b,c:DVec2) -> f64 {
    return (b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x)
}

// Center and squared radius of the circle through three points; the radius
// is max(f64) when they are on one line.
@(private="file") circumcircle :: proc "contextless" (a,b,c:DVec2) -> (center:DVec2,radius2:f64) {
    dx,dy:=b.x-a.x,b.y-a.y
    ex,ey:=c.x-a.x,c.y-a.y
    bl,cl:=dx*dx+dy*dy,ex*ex+ey*ey
    cross:=dx*ey-dy*ex
    if cross==0 {return a,max(f64)}
    scale:=0.5/cross
    x,y:=(ey*bl-dy*cl)*scale,(dx*cl-ex*bl)*scale
    radius2=x*x+y*y
    if !(radius2<max(f64)) {return a,max(f64)}
    return {a.x+x,a.y+y},radius2
}

// Positive when p is inside the circle through the counter-clockwise a b c.
// The four points are taken in the order of their indices, so that the two
// triangles on an edge always agree on which of them is illegal.
@(private="file") in_circle :: proc(d:^Delaunay,ia,ib,ic,ip:u32) -> f64 #no_bounds_check {
    index:=[4]u32{ia,ib,ic,ip}
    sign:=f64(1)
    for i in 1..<4 {
        for j:=i;j>0 && index[j-1]>index[j];j-=1 {
            index[j-1],index[j]=index[j],index[j-1]
            sign=-sign
        }
    }
    a,b,c,p:=d.points[index[0]],d.points[index[1]],d.points[index[2]],d.points[index[3]]
    dx,dy:=a.x-p.x,a.y-p.y
    ex,ey:=b.x-p.x,b.y-p.y
    fx,fy:=c.x-p.x,c.y-p.y
    ap,bp,cp:=dx*dx+dy*dy,ex*ex+ey*ey,fx*fx+fy*fy
    return sign*(dx*(ey*cp-bp*fy)-dy*(ex*cp-bp*fx)+ap*(ex*fy-ey*fx))
}

// Direction from the center as a number that grows with the angle, in [0,1).
@(private="file") hash_key :: proc(d:^Delaunay,p:DVec2) -> int {
    dx,dy:=p.x-d.center.x,d.center.y-p.y
    norm:=abs(dx)+abs(dy)
    t:=dx/norm if norm>0 else 0
    angle:=(3-t if dy>0 else 1+t)/4
    return int(math.floor(angle*f64(len(d.hash))))%len(d.hash)
}

@(private="file") link :: #force_inline proc(d:^Delaunay,a,b:u32) #no_bounds_check {
    d.halfedges[a]=b
    if b!=NONE {d.halfedges[b]=a}
}

@(private="file") triangle_add :: proc(d:^Delaunay,i0,i1,i2,a,b,c:u32) -> u32 #no_bounds_check {
    t:=u32(d.count)
    d.triangles[t]=i0;d.triangles[t+1]=i1;d.triangles[t+2]=i2
    link(d,t,a);link(d,t+1,b);link(d,t+2,c)
    d.count+=3
    return t
}

// Flips edges from `edge` on until every pair of triangles keeps the fourth
// point out of its circle. Returns the edge that ends up on the far side.
@(private="file") legalize :: proc(d:^Delaunay,edge:u32) -> u32 #no_bounds_check {
    a:=edge
    ar:u32
    clear(&d.stack)
    // A bound on the flips keeps inexact circles from flipping forever.
    for _ in 0..<len(d.points)*8+64 {
        b:=d.halfedges[a]
        a0:=a-a%3
        ar=a0+(a+2)%3
        if b==NONE {
            if len(d.stack)==0 {break}
            a=pop(&d.stack)
            continue
        }
        b0:=b-b%3
        al:=a0+(a+1)%3
        bl:=b0+(b+2)%3
        p0,pr,pl,p1:=d.triangles[ar],d.triangles[a],d.triangles[al],d.triangles[bl]
        if in_circle(d,p0,pr,pl,p1)>0 {
            d.triangles[a]=p1
            d.triangles[b]=p0
            hbl:=d.halfedges[bl]
            // The flipped edge was on the hull: the hull points to its new place.
            if hbl==NONE {
                e:=d.hull_start
                for {
                    if d.hull_tri[e]==bl {d.hull_tri[e]=a;break}
                    e=d.hull_prev[e]
                    if e==d.hull_start {break}
                }
            }
            link(d,a,hbl)
            link(d,b,d.halfedges[ar])
            link(d,ar,bl)
            if _,err:=append(&d.stack,b0+(b+1)%3);err!=nil {d.refused=true}
        } else {
            if len(d.stack)==0 {break}
            a=pop(&d.stack)
        }
    }
    return ar
}
