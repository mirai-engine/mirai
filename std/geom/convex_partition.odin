package geom

import "base:runtime"
import "core:slice"
import "mirai:std/base"

// Convex partition of a polygon with holes (Hertel and Mehlhorn, 1983): the
// triangles of polygon_triangulate become faces of half-edges, and the
// diagonals between two faces are removed from the longest down whenever both
// of their ends stay convex, which is O(1) per diagonal. A piece is a union of
// triangles, so the pieces cover the polygon exactly with its own points, and
// they are at most four times the fewest convex pieces without new points.
//
// Points at the same position are one point (the first of them), so repeated
// points neither split pieces nor reach them. A face that does not come out
// strictly convex once its collinear points are dropped, which only zero-width
// spikes of degenerate input can cause, is given as its triangles instead.

// The bits of a position, with -0 as 0.
@(private="file") position_key :: #force_inline proc "contextless" (p:Vec2) -> u64 {
    return u64(transmute(u32)(p.x+0))<<32|u64(transmute(u32)(p.y+0))
}

@(private="file") edge_end :: #force_inline proc "contextless" (origin:[]u32,next:[]i32,edge:i32,higher:bool) -> u32 #no_bounds_check {
    u,v:=origin[edge],origin[next[edge]]
    return max(u,v) if higher else min(u,v)
}

// Stable counting sort of half-edges by one of their points.
@(private="file") edges_sort :: proc "contextless" (source,target,starts:[]i32,origin:[]u32,next:[]i32,higher:bool) #no_bounds_check {
    slice.zero(starts)
    for e in source {starts[edge_end(origin,next,e,higher)+1]+=1}
    for i in 1..<len(starts) {starts[i]+=starts[i-1]}
    for e in source {
        point:=edge_end(origin,next,e,higher)
        target[starts[point]]=e
        starts[point]+=1
    }
}

@(private="file") turn :: #force_inline proc "contextless" (a,b,c:DVec2) -> f64 {
    return (b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x)
}

// A convex corner or a straight one, not a spike that turns back.
@(private="file") corner_convex :: #force_inline proc "contextless" (a,b,c:DVec2) -> bool {
    o:=turn(a,b,c)
    return o>0 || (o==0 && (b.x-a.x)*(c.x-b.x)+(b.y-a.y)*(c.y-b.y)>0)
}

@(private="file") face_root :: proc "contextless" (parent:[]i32,face:i32) -> i32 #no_bounds_check {
    f:=face
    for parent[f]!=f {
        parent[f]=parent[parent[f]]
        f=parent[f]
    }
    return f
}

// Drops the points of `ring` without a turn into `kept`, and tells whether
// what is left is a strictly convex counter-clockwise polygon that winds once.
@(private="file") piece_clean :: proc(points:[]DVec2,ring:[]u32,kept:^[dynamic]u32) -> bool #no_bounds_check {
    clear(kept)
    n:=len(ring)
    for i in 0..<n {
        if turn(points[ring[(i+n-1)%n]],points[ring[i]],points[ring[(i+1)%n]])==0 {continue}
        if _,err:=append(kept,ring[i]);err!=nil {return false}
    }
    m:=len(kept)
    if m<3 {return false}
    area:f64
    changes:=0
    last:=points[kept[0]].x-points[kept[m-1]].x
    for i in 0..<m {
        a,b,c:=points[kept[i]],points[kept[(i+1)%m]],points[kept[(i+2)%m]]
        if turn(a,b,c)<=0 {return false}
        area+=a.x*b.y-b.x*a.y
        dx:=b.x-a.x
        if dx==0 {continue}
        if last!=0 && (dx>0)!=(last>0) {changes+=1}
        last=dx
    }
    return area>0 && changes<=2
}

// Splits the polygon of polygon_triangulate (First_Outline loops) into convex pieces whose
// union is the polygon. Appends to `indices` the points of each piece counter-clockwise, and to
// `sizes` how many points each piece has; returns how many pieces. Invalid input, or no memory
// for the pieces, gives none and appends nothing.
polygon_convex_partition :: proc(points:[]Vec2,loop_sizes:[]int,indices:^[dynamic]u32,sizes:^[dynamic]u32) -> int #no_bounds_check {
    total:=0
    for size in loop_sizes {
        if size<0 || size>len(points)-total {return 0}
        total+=size
    }
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore=temp_is(indices.allocator) || temp_is(sizes.allocator))
    scratch:=context.temp_allocator
    triangles:=make([dynamic]u32,scratch)
    count:=polygon_triangulate(points,loop_sizes,&triangles)
    if count<=0 || len(triangles)!=3*count {return 0}

    bits:=uint(1)
    for 1<<bits<2*total {bits+=1}
    table:=make([]i32,1<<bits,scratch)
    slice.fill(table,-1)
    same:=make([]u32,total,scratch)
    for p,i in points[:total] {
        key:=position_key(p)
        for slot:=int((key*0x9e3779b97f4a7c15)>>(64-bits));true;slot=(slot+1)&(len(table)-1) {
            j:=table[slot]
            if j<0 {table[slot]=i32(i);same[i]=u32(i);break}
            if position_key(points[j])==key {same[i]=u32(j);break}
        }
    }
    d:=make([]DVec2,total,scratch)
    for p,i in points[:total] {d[i]={f64(p.x),f64(p.y)}}

    // Half-edge 3t+k goes from corner k of triangle t to the next corner.
    edges:=3*count
    origin:=make([]u32,edges,scratch)
    next:=make([]i32,edges,scratch)
    prev:=make([]i32,edges,scratch)
    twin:=make([]i32,edges,scratch)
    parent:=make([]i32,count,scratch)
    head:=make([]i32,count,scratch)  // a half-edge of the face, at its root
    chain:=make([]i32,count,scratch) // next triangle of the same face, -1 at the end
    tail:=make([]i32,count,scratch)  // last triangle of the chain, at its root
    alive:=make([]bool,count,scratch)
    listed:=make([dynamic]i32,0,edges,scratch)
    for t in 0..<count {
        e:=i32(3*t)
        for k in i32(0)..<3 {
            origin[e+k]=same[triangles[e+k]]
            next[e+k]=e+(k+1)%3
            prev[e+k]=e+(k+2)%3
            twin[e+k]=-1
        }
        parent[t],head[t],chain[t],tail[t]=i32(t),e,-1,i32(t)
        a,b,c:=origin[e],origin[e+1],origin[e+2]
        alive[t]=a!=b && b!=c && a!=c && turn(d[a],d[b],d[c])>=0
        if !alive[t] {continue}
        append(&listed,e,e+1,e+2)
    }
    // The half-edges by their lower point, then their higher one, then their
    // index: two stable counting sorts.
    starts:=make([]i32,total+1,scratch)
    by_higher:=make([]i32,len(listed),scratch)
    by_lower:=make([]i32,len(listed),scratch)
    edges_sort(listed[:],by_higher,starts,origin,next,true)
    edges_sort(by_higher,by_lower,starts,origin,next,false)
    // An edge shared by exactly two faces in opposite directions is a diagonal;
    // one used more often belongs to an overlapping input and stays. A
    // diagonal goes in its order as the bits of its length, which sort as the
    // length does, above the half-edge.
    diagonals:=make([dynamic]u64,0,len(listed)/2,scratch)
    for i:=0;i<len(by_lower); {
        e:=by_lower[i]
        j:=i+1
        for j<len(by_lower) && edge_end(origin,next,by_lower[j],false)==edge_end(origin,next,e,false) &&
            edge_end(origin,next,by_lower[j],true)==edge_end(origin,next,e,true) {j+=1}
        if j-i==2 {
            f:=by_lower[i+1]
            if origin[e]!=origin[f] {
                twin[e],twin[f]=f,e
                delta:=d[origin[e]]-d[origin[f]]
                length:=transmute(u32)f32(delta.x*delta.x+delta.y*delta.y)
                append(&diagonals,u64(~length)<<32|u64(e))
            }
        }
        i=j
    }
    slice.sort(diagonals[:])
    for diagonal in diagonals {
        e:=i32(diagonal&0xffffffff)
        f:=twin[e]
        p,q:=face_root(parent,e/3),face_root(parent,f/3)
        if p==q {continue}
        u,v:=origin[e],origin[f]
        if !corner_convex(d[origin[prev[e]]],d[u],d[origin[next[next[f]]]]) {continue}
        if !corner_convex(d[origin[prev[f]]],d[v],d[origin[next[next[e]]]]) {continue}
        ne,nf:=next[e],next[f]
        next[prev[e]]=nf;prev[nf]=prev[e]
        next[prev[f]]=ne;prev[ne]=prev[f]
        parent[q]=p
        head[p]=ne
        chain[tail[p]]=q
        tail[p]=tail[q]
    }

    ring:=make([dynamic]u32,scratch)
    kept:=make([dynamic]u32,scratch)
    held:=[2]int{len(indices),len(sizes)}
    pieces:=0
    roomy:=true
    fill: for t in 0..<count {
        if !alive[t] || parent[t]!=i32(t) {continue}
        clear(&ring)
        for e:=head[t];len(ring)<=edges; {
            append(&ring,origin[e])
            e=next[e]
            if e==head[t] {break}
        }
        if piece_clean(d,ring[:],&kept) {
            _,no_indices:=append(indices,..kept[:])
            _,no_size:=append(sizes,u32(len(kept)))
            if no_indices!=nil || no_size!=nil {roomy=false;break fill}
            pieces+=1
            continue
        }
        for s:=i32(t);s>=0;s=chain[s] {
            a,b,c:=origin[3*s],origin[3*s+1],origin[3*s+2]
            if !alive[s] || turn(d[a],d[b],d[c])<=0 {continue}
            _,no_indices:=append(indices,a,b,c)
            _,no_size:=append(sizes,3)
            if no_indices!=nil || no_size!=nil {roomy=false;break fill}
            pieces+=1
        }
    }
    if !roomy {
        base.truncate(indices,held[0]);base.truncate(sizes,held[1])
        return 0
    }
    return pieces
}
