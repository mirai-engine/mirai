package geom

import "base:intrinsics"
import "base:runtime"
import "core:math"

// Simplification by edge collapse with quadric error metrics: a port of the
// simplifier of meshoptimizer 1.3 (src/simplifier.cpp, MIT, Arseny
// Kapoulkine), with the same arithmetic in f32 and the same order, so the
// same input gives the indices meshoptimizer gives.
//
// Vertices with one position are the wedges of one place: a seam of
// attributes splits them. Each place has a kind (manifold, border, seam,
// complex, fringe, locked) that says what it may collapse onto; a collapse
// moves every wedge of a place onto a wedge of another, so the output only
// names vertices of the input. Each pass ranks the collapses the topology
// allows by the error of the quadric of the place that moves (and of its
// attributes), sorts them by the top bits of that error and makes those
// whose places no other collapse of the pass touched and that turn no
// triangle over, until the target, the error limit or the error goal of the
// pass.
//
// Based on: Garland and Heckbert, Surface simplification using quadric error
// metrics (1997); Hoppe, New quadric metric for simplifying meshes with
// appearance attributes (1999); Teschner et al., Optimized spatial hashing
// for collision detection of deformable objects (2003).

Simplify_Option :: enum u8 {
    // Vertices on a border (an edge with a single triangle) do not move.
    Lock_Border,
    // The indices name a small part of the vertices: the work is that of the
    // part, and a relative error is relative to the extent of the part.
    Sparse,
    // target_error and the error returned are distances in the units of the
    // positions instead of shares of their extent.
    Error_Absolute,
    // Pieces of the mesh that do not touch go away whole once their size is
    // within the error, whatever stops collapses inside them.
    Prune,
    // More even triangles, at some cost in geometry and attributes.
    Regularize,
    Regularize_Light,
    // Collapses also cross the seams of attributes, except at vertices
    // flagged Protect.
    Permissive,
    // The error of the attributes of a place is at most the area it stands
    // for, so it reads as a distance as that of the positions does.
    Error_Clamped,
}
Simplify_Options :: bit_set[Simplify_Option;u32]

Simplify_Vertex_Flag :: enum u8 {
    Lock,     // the vertex does not move
    Protect,  // its seam of attributes stays, also with Permissive
    Priority, // collapses away from it cost more
}
Simplify_Vertex :: bit_set[Simplify_Vertex_Flag;u8]

SIMPLIFY_MAX_ATTRIBUTES :: 32

Simplify_Result :: struct {
    index_count:int,    // written to destination
    // The largest error of a collapse made, of positions and weighted
    // attributes, in the units of target_error.
    result_error:f32,
    // That of the positions alone, in the same units: how far the surface
    // moved. Without attributes it is result_error.
    position_error:f32,
}

Simplify_Error :: enum u8 {None,Invalid_Mesh,Invalid_Attributes,Out_Of_Memory}

@(private="file") KIND_MANIFOLD :: u8(0) // on no seam and no border
@(private="file") KIND_BORDER   :: u8(1) // on no seam, with exactly two open edges
@(private="file") KIND_SEAM     :: u8(2) // on a seam of attributes with exactly two seam edges
@(private="file") KIND_COMPLEX  :: u8(3) // moves only with all its wedges onto one target
@(private="file") KIND_FRINGE   :: u8(4) // complex on a border: moves only onto another fringe
@(private="file") KIND_LOCKED   :: u8(5)
@(private="file") KIND_COUNT    :: 6

// Collapsing a place of the row kind onto one of the column kind keeps the
// kind of the target.
@(private="file")
CAN_COLLAPSE :: [KIND_COUNT][KIND_COUNT]u8{
    {1,1,1,1,1,1},
    {0,1,0,0,1,1},
    {0,0,1,0,0,1},
    {0,0,0,1,1,1},
    {0,0,0,0,1,0},
    {0,0,0,0,0,0},
}

// Whether an edge between places of these kinds is seen from both sides
// (on a seam, from the other side of the position-only surface).
@(private="file")
HAS_OPPOSITE :: [KIND_COUNT][KIND_COUNT]u8{
    {1,1,1,1,1,1},
    {1,0,1,0,0,0},
    {1,1,1,0,0,1},
    {1,0,0,0,0,0},
    {1,0,0,0,0,0},
    {1,0,1,0,0,0},
}

@(private="file") Adjacent :: struct {next,prev:u32}
// The half-edges that leave each vertex: those of v are data[offsets[v]:offsets[v+1]].
@(private="file") Edge_Adjacency :: struct {offsets:[]u32,data:[]Adjacent}

// a00*x^2 + a11*y^2 + a22*z^2 + 2*(a10*xy + a20*xz + a21*yz) + 2*(b0*x + b1*y + b2*z) + c, of weight w
@(private="file") Quadric :: struct {a00,a11,a22,a10,a20,a21,b0,b1,b2,c,w:f32}
// gx*x + gy*y + gz*z + gw
@(private="file") Quadric_Grad :: struct {gx,gy,gz,gw:f32}
// Four f32 lanes: what keeps the hot loops fast without the optimizer.
@(private="file") F4 :: #simd[4]f32

// v0 onto v1; bits holds whether both directions are allowed until the
// collapse is ranked, and then its error.
@(private="file") Collapse :: struct {v0,v1:u32,bits:u32}

@(private="file")
adjacency_update :: proc "contextless" (adjacency:^Edge_Adjacency,indices:[]u32,vertex_count:int,remap:[]u32) #no_bounds_check {
    offsets:=adjacency.offsets[1:]
    data:=adjacency.data
    for &count in offsets[:vertex_count] {count=0}
    for index in indices {
        v:=len(remap)>0?remap[index]:index
        offsets[v]+=1
    }
    offset:u32
    for i in 0..<vertex_count {
        count:=offsets[i]
        offsets[i]=offset
        offset+=count
    }
    for t in 0..<len(indices)/3 {
        a,b,c:=indices[t*3],indices[t*3+1],indices[t*3+2]
        if len(remap)>0 {a,b,c=remap[a],remap[b],remap[c]}
        data[offsets[a]]={b,c};offsets[a]+=1
        data[offsets[b]]={c,a};offsets[b]+=1
        data[offsets[c]]={a,b};offsets[c]+=1
    }
    adjacency.offsets[0]=0
}

@(private="file")
edges_of :: #force_inline proc "contextless" (adjacency:^Edge_Adjacency,v:u32) -> []Adjacent #no_bounds_check {
    return adjacency.data[adjacency.offsets[v]:adjacency.offsets[v+1]]
}

@(private="file")
hash_buckets :: proc "contextless" (count:int) -> int {
    buckets:=1
    for buckets<count+count/4 {buckets*=2}
    return buckets
}

@(private="file")
position_bits_hash :: #force_inline proc "contextless" (p:Vec3) -> u32 {
    x,y,z:=transmute(u32)p.x,transmute(u32)p.y,transmute(u32)p.z
    // Negative zero hashes as zero.
    x=x==0x80000000?0:x
    y=y==0x80000000?0:y
    z=z==0x80000000?0:z
    // Integer coordinates get entropy in the low bits.
    x~=x>>17
    y~=y>>17
    z~=z>>17
    return (x*73856093)~(y*19349663)~(z*83492791)
}

@(private="file")
sparse_position :: #force_inline proc "contextless" (positions:[]Vec3,sparse:[]u32,i:u32) -> Vec3 #no_bounds_check {
    return positions[len(sparse)>0?sparse[i]:i]
}

// remap[i] is the first vertex with the position of i; wedge[i] the next
// vertex with that position, in a cycle.
@(private="file")
position_remap_build :: proc(remap,wedge:[]u32,positions:[]Vec3,sparse:[]u32,scratch:runtime.Allocator) -> bool #no_bounds_check {
    vertex_count:=len(remap)
    table_size:=hash_buckets(vertex_count)
    table,failed:=make([]u32,table_size,scratch)
    if failed!=nil {return false}
    defer delete(table,scratch)
    for &entry in table {entry=NONE}
    hashmod:=table_size-1
    for i in 0..<vertex_count {
        p:=sparse_position(positions,sparse,u32(i))
        bucket:=int(position_bits_hash(p))&hashmod
        for probe in 0..=hashmod {
            item:=table[bucket]
            if item==NONE {
                table[bucket]=u32(i)
                remap[i]=u32(i)
                break
            }
            q:=sparse_position(positions,sparse,item)
            if q.x==p.x && q.y==p.y && q.z==p.z {
                remap[i]=item
                break
            }
            bucket=(bucket+probe+1)&hashmod
        }
    }
    if len(wedge)==0 {return true}
    for &w,i in wedge {w=u32(i)}
    for i in 0..<vertex_count {
        if remap[i]!=u32(i) {
            r:=remap[i]
            wedge[i]=wedge[r]
            wedge[r]=u32(i)
        }
    }
    return true
}

// Rewrites indices to the vertices they use, numbered in their first use,
// and gives the vertex each of those is.
@(private="file")
sparse_remap_build :: proc(indices:[]u32,vertex_count:int,scratch:runtime.Allocator) -> (remap:[]u32,ok:bool) #no_bounds_check {
    filter,failed:=make([]u8,(vertex_count+7)/8,scratch)
    if failed!=nil {return}
    unique:=0
    for index in indices {
        bit:=u8(1)<<(index%8)
        if filter[index/8]&bit==0 {unique+=1}
        filter[index/8]|=bit
    }
    delete(filter,scratch)
    remap,failed=make([]u32,unique,scratch)
    if failed!=nil {return}
    revremap_size:=hash_buckets(unique)
    revremap:[]u32
    revremap,failed=make([]u32,revremap_size,scratch)
    if failed!=nil {return}
    defer delete(revremap,scratch)
    for &entry in revremap {entry=NONE}
    hashmod:=revremap_size-1
    offset:u32
    for &index in indices {
        bucket:=int(index*0x5bd1e995)&hashmod
        for probe in 0..=hashmod {
            item:=revremap[bucket]
            if item==NONE {
                remap[offset]=index
                revremap[bucket]=offset
                index=offset
                offset+=1
                break
            }
            if remap[item]==index {
                index=item
                break
            }
            bucket=(bucket+probe+1)&hashmod
        }
    }
    return remap,true
}

@(private="file")
has_edge :: proc "contextless" (adjacency:^Edge_Adjacency,a,b:u32) -> bool #no_bounds_check {
    for edge in edges_of(adjacency,a) {
        if edge.next==b {return true}
    }
    return false
}

@(private="file")
has_edge_wedges :: proc "contextless" (adjacency:^Edge_Adjacency,a,b:u32,remap,wedge:[]u32) -> bool #no_bounds_check {
    v:=a
    for {
        for edge in edges_of(adjacency,v) {
            if remap[edge.next]==remap[b] {return true}
        }
        v=wedge[v]
        if v==a {break}
    }
    return false
}

@(private="file")
vertex_lock_of :: #force_inline proc "contextless" (vertex_lock:[]Simplify_Vertex,sparse:[]u32,i:u32) -> Simplify_Vertex #no_bounds_check {
    if len(vertex_lock)==0 {return {}}
    return vertex_lock[len(sparse)>0?sparse[i]:i]
}

@(private="file")
classify_vertices :: proc "contextless" (result:[]u8,loop,loopback:[]u32,adjacency:^Edge_Adjacency,remap,wedge:[]u32,vertex_lock:[]Simplify_Vertex,sparse:[]u32,options:Simplify_Options) #no_bounds_check {
    vertex_count:=len(result)
    for &l in loop {l=NONE}
    for &l in loopback {l=NONE}
    // Incoming and outgoing open edges: NONE without one, the vertex itself with more than one.
    openinc:=loopback
    openout:=loop
    for i in 0..<vertex_count {
        vertex:=u32(i)
        for edge in edges_of(adjacency,vertex) {
            target:=edge.next
            if target==vertex {
                // A degenerate triangle: its self edge would close the open edge of another.
                openinc[vertex]=vertex
                openout[vertex]=vertex
            } else if !has_edge(adjacency,target,vertex) {
                openinc[target]=openinc[target]==NONE?vertex:target
                openout[vertex]=openout[vertex]==NONE?target:vertex
            }
        }
    }
    for i in 0..<vertex_count {
        if remap[i]==u32(i) {
            if wedge[i]==u32(i) {
                openi,openo:=openinc[i],openout[i]
                if openi==NONE && openo==NONE {
                    result[i]=KIND_MANIFOLD
                } else if openi!=NONE && openo!=NONE && remap[openi]==remap[openo] && openi!=u32(i) {
                    // A half-seam: one vertex joined to both vertices of a seam.
                    result[i]=KIND_SEAM
                } else if openi!=u32(i) && openo!=u32(i) {
                    result[i]=KIND_BORDER
                } else {
                    result[i]=KIND_LOCKED
                }
            } else if wedge[wedge[i]]==u32(i) {
                w:=wedge[i]
                openiv,openov:=openinc[i],openout[i]
                openiw,openow:=openinc[w],openout[w]
                // A seam has one open half-edge per wedge, and they meet after remapping.
                if openiv!=NONE && openiv!=u32(i) && openov!=NONE && openov!=u32(i) &&
                   openiw!=NONE && openiw!=w && openow!=NONE && openow!=w &&
                   remap[openiv]==remap[openow] && remap[openov]==remap[openiw] && remap[openiv]!=remap[openov] {
                    result[i]=KIND_SEAM
                } else {
                    result[i]=KIND_LOCKED
                }
            } else {
                result[i]=KIND_LOCKED
            }
        } else {
            result[i]=result[remap[i]]
        }
    }
    if .Permissive in options {
        for i in 0..<vertex_count {
            if result[i]!=KIND_SEAM && result[i]!=KIND_LOCKED {continue}
            if remap[i]!=u32(i) {
                result[i]=result[remap[i]]
                continue
            }
            v:=u32(i)
            // Protect on any wedge keeps the place as it is.
            protect:=false
            for {
                protect||=.Protect in vertex_lock_of(vertex_lock,sparse,v)
                v=wedge[v]
                if v==u32(i) {break}
            }
            // An edge without its opposite puts the place on a border.
            border:=false
            for {
                for edge in edges_of(adjacency,v) {
                    border||=!has_edge_wedges(adjacency,edge.next,v,remap,wedge)
                }
                v=wedge[v]
                if v==u32(i) {break}
            }
            if !protect {result[i]=border?KIND_FRINGE:KIND_COMPLEX}
        }
    }
    if len(vertex_lock)>0 {
        // A lock on any wedge locks the place and all its wedges.
        for i in 0..<vertex_count {
            if .Lock in vertex_lock_of(vertex_lock,sparse,u32(i)) {result[remap[i]]=KIND_LOCKED}
        }
        for i in 0..<vertex_count {
            if result[remap[i]]==KIND_LOCKED {result[i]=KIND_LOCKED}
        }
    }
    if .Lock_Border in options {
        for &kind in result {
            if kind==KIND_BORDER || kind==KIND_FRINGE {kind=KIND_LOCKED}
        }
    }
}

// The positions in the box of the vertices scaled to [0,1] by its largest
// extent, which is returned with the corner of the box.
@(private="file")
rescale_positions :: proc "contextless" (result:[]Vec3,positions:[]Vec3,vertex_count:int,sparse:[]u32) -> (extent:f32,offset:Vec3) #no_bounds_check {
    minv:=Vec3{max(f32),max(f32),max(f32)}
    maxv:=Vec3{-max(f32),-max(f32),-max(f32)}
    for i in 0..<vertex_count {
        v:=sparse_position(positions,sparse,u32(i))
        if len(result)>0 {result[i]=v}
        for j in 0..<3 {
            vj:=v[j]
            minv[j]=minv[j]>vj?vj:minv[j]
            maxv[j]=maxv[j]<vj?vj:maxv[j]
        }
    }
    extent=(maxv[0]-minv[0])<extent?extent:(maxv[0]-minv[0])
    extent=(maxv[1]-minv[1])<extent?extent:(maxv[1]-minv[1])
    extent=(maxv[2]-minv[2])<extent?extent:(maxv[2]-minv[2])
    if len(result)>0 {
        scale:=extent==0?f32(0):1/extent
        for &p in result[:vertex_count] {
            p.x=(p.x-minv[0])*scale
            p.y=(p.y-minv[1])*scale
            p.z=(p.z-minv[2])*scale
        }
    }
    return extent,minv
}

@(private="file")
quadric_add :: #force_inline proc "contextless" (q:^Quadric,r:Quadric) #no_bounds_check {
    r:=r
    to,from:=(^[11]f32)(q),(^[11]f32)(&r)
    // The first eight fields in two lane groups, field by field as before.
    intrinsics.unaligned_store((^F4)(&to[0]),intrinsics.unaligned_load((^F4)(&to[0]))+intrinsics.unaligned_load((^F4)(&from[0])))
    intrinsics.unaligned_store((^F4)(&to[4]),intrinsics.unaligned_load((^F4)(&to[4]))+intrinsics.unaligned_load((^F4)(&from[4])))
    to[8]+=from[8];to[9]+=from[9];to[10]+=from[10]
}

@(private="file")
grads_add :: #force_inline proc "contextless" (g,r:[]Quadric_Grad) #no_bounds_check {
    for k in 0..<len(g) {intrinsics.unaligned_store((^F4)(&g[k]),intrinsics.unaligned_load((^F4)(&g[k]))+intrinsics.unaligned_load((^F4)(&r[k])))}
}

@(private="file")
quadric_eval :: #force_inline proc "contextless" (q:^Quadric,v:Vec3) -> f32 {
    rx:=(q.b0+q.a10*v.y)*2
    ry:=(q.b1+q.a21*v.z)*2
    rz:=(q.b2+q.a20*v.x)*2
    rx+=q.a00*v.x
    ry+=q.a11*v.y
    rz+=q.a22*v.z
    return q.c+rx*v.x+ry*v.y+rz*v.z
}

@(private="file")
quadric_error :: #force_inline proc "contextless" (q:^Quadric,v:Vec3) -> f32 {
    r:=quadric_eval(q,v)
    s:=q.w==0?f32(0):1/q.w
    return abs(r)*s
}

@(private="file")
quadric_error_attributes :: #force_inline proc "contextless" (q:^Quadric,g:[]Quadric_Grad,v:Vec3,va:[]f32,clamped:bool) -> f32 #no_bounds_check {
    r:=quadric_eval(q,v)
    // The terms of (eval(pos)-attr)^2 that depend on attr, four attributes
    // per lane group, each added to r in turn as the scalar loop adds them.
    k:=0
    position:=F4{v.x,v.y,v.z,1}
    for ;k+4<=len(g);k+=4 {
        gk:F4
        #unroll for j in 0..<4 {
            p:=intrinsics.unaligned_load((^F4)(&g[k+j]))*position
            gk=intrinsics.simd_replace(gk,j,intrinsics.simd_extract(p,0)+intrinsics.simd_extract(p,1)+intrinsics.simd_extract(p,2)+intrinsics.simd_extract(p,3))
        }
        a:=intrinsics.unaligned_load((^F4)(&va[k]))
        t:=a*(a*F4(q.w)-2*gk)
        r+=intrinsics.simd_extract(t,0)
        r+=intrinsics.simd_extract(t,1)
        r+=intrinsics.simd_extract(t,2)
        r+=intrinsics.simd_extract(t,3)
    }
    for ;k<len(g);k+=1 {
        a:=va[k]
        gk:=v.x*g[k].gx+v.y*g[k].gy+v.z*g[k].gz+g[k].gw
        r+=a*(a*q.w-2*gk)
    }
    // Not normalized by the weight, which keeps the scale of the edges.
    e:=abs(r)
    return clamped?(e<q.w?e:q.w):e
}

@(private="file")
quadric_from_plane :: #force_inline proc "contextless" (a,b,c,d,w:f32) -> (q:Quadric) {
    aw,bw,cw,dw:=a*w,b*w,c*w,d*w
    q.a00=a*aw;q.a11=b*bw;q.a22=c*cw
    q.a10=a*bw;q.a20=a*cw;q.a21=b*cw
    q.b0=a*dw;q.b1=b*dw;q.b2=c*dw
    q.c=d*dw
    q.w=w
    return
}

@(private="file")
quadric_from_point :: #force_inline proc "contextless" (x,y,z,w:f32) -> (q:Quadric) {
    q.a00,q.a11,q.a22=w,w,w
    q.b0=-x*w;q.b1=-y*w;q.b2=-z*w
    q.c=(x*x+y*y+z*z)*w
    q.w=w
    return
}

@(private="file")
normalize_f32 :: #force_inline proc "contextless" (v:^Vec3) -> f32 {
    length:=math.sqrt(v.x*v.x+v.y*v.y+v.z*v.z)
    if length>0 {
        v.x/=length
        v.y/=length
        v.z/=length
    }
    return length
}

@(private="file")
quadric_from_triangle :: proc "contextless" (p0,p1,p2:Vec3,weight:f32) -> Quadric {
    p10:=Vec3{p1.x-p0.x,p1.y-p0.y,p1.z-p0.z}
    p20:=Vec3{p2.x-p0.x,p2.y-p0.y,p2.z-p0.z}
    normal:=Vec3{p10.y*p20.z-p10.z*p20.y,p10.z*p20.x-p10.x*p20.z,p10.x*p20.y-p10.y*p20.x}
    area:=normalize_f32(&normal)
    distance:=normal.x*p0.x+normal.y*p0.y+normal.z*p0.z
    // The square root of the area scales the error linearly, which keeps silhouettes.
    return quadric_from_plane(normal.x,normal.y,normal.z,-distance,math.sqrt(area)*weight)
}

@(private="file")
quadric_from_triangle_edge :: proc "contextless" (p0,p1,p2:Vec3,weight:f32) -> Quadric {
    p10:=Vec3{p1.x-p0.x,p1.y-p0.y,p1.z-p0.z}
    lengthsq:=p10.x*p10.x+p10.y*p10.y+p10.z*p10.z
    length:=math.sqrt(lengthsq)
    // The projection of p2-p0 on the unnormalized p1-p0, corrected by scaling p2-p0.
    p20:=Vec3{p2.x-p0.x,p2.y-p0.y,p2.z-p0.z}
    p20p:=p20.x*p10.x+p20.y*p10.y+p20.z*p10.z
    perp:=Vec3{p20.x*lengthsq-p10.x*p20p,p20.y*lengthsq-p10.y*p20p,p20.z*lengthsq-p10.z*p20p}
    normalize_f32(&perp)
    distance:=perp.x*p0.x+perp.y*p0.y+perp.z*p0.z
    // Weighted by the length of the edge, as a triangle by the square root of its area.
    return quadric_from_plane(perp.x,perp.y,perp.z,-distance,length*weight)
}

// The quadric of (eval(pos)-attr)^2 for each attribute, eval interpolating it
// over the triangle, weighted by the area: a change of 1 in a weighted
// attribute over a distance d costs about as a move of d.
@(private="file")
quadric_from_attributes :: proc "contextless" (g:[]Quadric_Grad,p0,p1,p2:Vec3,va0,va1,va2:[]f32) -> (q:Quadric) #no_bounds_check {
    p10:=Vec3{p1.x-p0.x,p1.y-p0.y,p1.z-p0.z}
    p20:=Vec3{p2.x-p0.x,p2.y-p0.y,p2.z-p0.z}
    normal:=Vec3{p10.y*p20.z-p10.z*p20.y,p10.z*p20.x-p10.x*p20.z,p10.x*p20.y-p10.y*p20.x}
    area:=math.sqrt(normal.x*normal.x+normal.y*normal.y+normal.z*normal.z)*0.5
    w:=area
    // Gradients from barycentric coordinates.
    v0:=p10
    v1:=p20
    d00:=v0.x*v0.x+v0.y*v0.y+v0.z*v0.z
    d01:=v0.x*v1.x+v0.y*v1.y+v0.z*v1.z
    d11:=v1.x*v1.x+v1.y*v1.y+v1.z*v1.z
    denom:=d00*d11-d01*d01
    denomr:=denom==0?f32(0):1/denom
    gx1:=(d11*v0.x-d01*v1.x)*denomr
    gx2:=(d00*v1.x-d01*v0.x)*denomr
    gy1:=(d11*v0.y-d01*v1.y)*denomr
    gy2:=(d00*v1.y-d01*v0.y)*denomr
    gz1:=(d11*v0.z-d01*v1.z)*denomr
    gz2:=(d00*v1.z-d01*v0.z)*denomr
    q.w=w
    // a00,a11,a22,a10 and a20,a21,b0,b1 in lanes, each summed over the attributes in order.
    first,second:F4
    weight:=F4(w)
    for k in 0..<len(g) {
        a0,a1,a2:=va0[k],va1[k],va2[k]
        gx:=gx1*(a1-a0)+gx2*(a2-a0)
        gy:=gy1*(a1-a0)+gy2*(a2-a0)
        gz:=gz1*(a1-a0)+gz2*(a2-a0)
        gw:=a0-p0.x*gx-p0.y*gy-p0.z*gz
        first+=weight*(F4{gx,gy,gz,gy}*F4{gx,gy,gz,gx})
        second+=weight*(F4{gz,gz,gx,gy}*F4{gx,gy,gw,gw})
        q.b2+=w*(gz*gw)
        q.c+=w*(gw*gw)
        // The terms that depend on attr are added when the error is evaluated.
        intrinsics.unaligned_store((^F4)(&g[k]),weight*F4{gx,gy,gz,gw})
    }
    q.a00,q.a11,q.a22,q.a10=intrinsics.simd_extract(first,0),intrinsics.simd_extract(first,1),intrinsics.simd_extract(first,2),intrinsics.simd_extract(first,3)
    q.a20,q.a21,q.b0,q.b1=intrinsics.simd_extract(second,0),intrinsics.simd_extract(second,1),intrinsics.simd_extract(second,2),intrinsics.simd_extract(second,3)
    return
}

@(private="file")
fill_face_quadrics :: proc "contextless" (vertex_quadrics:[]Quadric,indices:[]u32,positions:[]Vec3,remap:[]u32) #no_bounds_check {
    for t in 0..<len(indices)/3 {
        i0,i1,i2:=indices[t*3],indices[t*3+1],indices[t*3+2]
        q:=quadric_from_triangle(positions[i0],positions[i1],positions[i2],1)
        quadric_add(&vertex_quadrics[remap[i0]],q)
        quadric_add(&vertex_quadrics[remap[i1]],q)
        quadric_add(&vertex_quadrics[remap[i2]],q)
    }
}

// A small point quadric per place steadies the triangulation without
// changing the shape or the error.
@(private="file")
fill_vertex_quadrics :: proc "contextless" (vertex_quadrics:[]Quadric,positions:[]Vec3,remap:[]u32,vertex_lock:[]Simplify_Vertex,sparse:[]u32,options:Simplify_Options) #no_bounds_check {
    factor:=.Regularize_Light in options?f32(1e-2):(.Regularize in options?f32(1e-1):f32(1e-7))
    for i in 0..<len(remap) {
        if remap[i]!=u32(i) {continue}
        priority:=.Priority in vertex_lock_of(vertex_lock,sparse,u32(i))
        p:=positions[i]
        w:=vertex_quadrics[i].w*(priority?1:factor)
        quadric_add(&vertex_quadrics[i],quadric_from_point(p.x,p.y,p.z,w))
    }
}

@(private="file")
fill_edge_quadrics :: proc "contextless" (vertex_quadrics:[]Quadric,indices:[]u32,positions:[]Vec3,remap:[]u32,vertex_kind:[]u8,loop,loopback:[]u32) #no_bounds_check {
    NEXT :: [4]int{1,2,0,1}
    next:=NEXT
    for t in 0..<len(indices)/3 {
        i:=t*3
        for e in 0..<3 {
            i0:=indices[i+e]
            i1:=indices[i+next[e]]
            k0,k1:=vertex_kind[i0],vertex_kind[i1]
            // A manifold vertex is never on a border.
            if k0==KIND_MANIFOLD || k1==KIND_MANIFOLD {continue}
            if k0!=KIND_BORDER && k0!=KIND_SEAM && k0!=KIND_FRINGE && k1!=KIND_BORDER && k1!=KIND_SEAM && k1!=KIND_FRINGE {continue}
            // Border and seam ends must be on the same loop; edges to locked ends count too, for the error at corners.
            if (k0==KIND_BORDER || k0==KIND_SEAM) && loop[i0]!=i1 {continue}
            if (k1==KIND_BORDER || k1==KIND_SEAM) && loopback[i1]!=i0 {continue}
            // Fringes have no loops: their edges to fringes or locked ends get the quadric.
            if (k0==KIND_FRINGE || k1==KIND_FRINGE) && (k0==KIND_COMPLEX || k1==KIND_COMPLEX) {continue}
            i2:=indices[i+next[e+1]]
            // Borders keep their shape; seams may move more freely (the weight counts twice, once per side).
            EDGE_WEIGHT_SEAM :: 0.5
            EDGE_WEIGHT_BORDER :: 10
            edge_weight:=f32(EDGE_WEIGHT_SEAM if k0==KIND_SEAM || k1==KIND_SEAM else EDGE_WEIGHT_BORDER)
            q:=quadric_from_triangle_edge(positions[i0],positions[i1],positions[i2],edge_weight)
            qt:=quadric_from_triangle(positions[i0],positions[i1],positions[i2],edge_weight)
            // Mixed with the plane of the triangle to steady collapses both ways; both weigh as the edge.
            qt.w=0
            quadric_add(&q,qt)
            quadric_add(&vertex_quadrics[remap[i0]],q)
            quadric_add(&vertex_quadrics[remap[i1]],q)
        }
    }
}

@(private="file")
fill_attribute_quadrics :: proc "contextless" (attribute_quadrics:[]Quadric,attribute_gradients:[]Quadric_Grad,indices:[]u32,positions:[]Vec3,attributes:[]f32,attribute_count:int) #no_bounds_check {
    g:[SIMPLIFY_MAX_ATTRIBUTES]Quadric_Grad
    n:=attribute_count
    for t in 0..<len(indices)/3 {
        i0,i1,i2:=int(indices[t*3]),int(indices[t*3+1]),int(indices[t*3+2])
        qa:=quadric_from_attributes(g[:n],positions[i0],positions[i1],positions[i2],attributes[i0*n:][:n],attributes[i1*n:][:n],attributes[i2*n:][:n])
        quadric_add(&attribute_quadrics[i0],qa)
        quadric_add(&attribute_quadrics[i1],qa)
        quadric_add(&attribute_quadrics[i2],qa)
        grads_add(attribute_gradients[i0*n:][:n],g[:n])
        grads_add(attribute_gradients[i1*n:][:n],g[:n])
        grads_add(attribute_gradients[i2*n:][:n],g[:n])
    }
}

// Whether triangle abc turns over when c moves to d.
@(private="file")
has_triangle_flip :: #force_inline proc "contextless" (a,b,c,d:Vec3) -> bool {
    eb:=Vec3{b.x-a.x,b.y-a.y,b.z-a.z}
    ec:=Vec3{c.x-a.x,c.y-a.y,c.z-a.z}
    ed:=Vec3{d.x-a.x,d.y-a.y,d.z-a.z}
    nbc:=Vec3{eb.y*ec.z-eb.z*ec.y,eb.z*ec.x-eb.x*ec.z,eb.x*ec.y-eb.y*ec.x}
    nbd:=Vec3{eb.y*ed.z-eb.z*ed.y,eb.z*ed.x-eb.x*ed.z,eb.x*ed.y-eb.y*ed.x}
    ndp:=nbc.x*nbd.x+nbc.y*nbd.y+nbc.z*nbd.z
    abc:=nbc.x*nbc.x+nbc.y*nbc.y+nbc.z*nbc.z
    abd:=nbd.x*nbd.x+nbd.y*nbd.y+nbd.z*nbd.z
    // cos 75 degrees: at 90 a series of collapses could turn a triangle over.
    return ndp<=0.25*math.sqrt(abc*abd)
}

@(private="file")
has_triangle_flips :: proc "contextless" (adjacency:^Edge_Adjacency,positions:[]Vec3,collapse_remap:[]u32,i0,i1:u32) -> bool #no_bounds_check {
    v0,v1:=positions[i0],positions[i1]
    for edge in edges_of(adjacency,i0) {
        a,b:=collapse_remap[edge.next],collapse_remap[edge.prev]
        // Triangles this collapse or an earlier one removes.
        if a==i1 || b==i1 || a==b {continue}
        if has_triangle_flip(positions[a],positions[b],v0,v1) {return true}
    }
    return false
}

// The wedge of the place of target that a wedge v of a complex place moves
// to: the one its open edges lead to, guided by the loops.
@(private="file")
complex_target :: #force_inline proc "contextless" (v,target:u32,remap,loop,loopback:[]u32) -> u32 #no_bounds_check {
    r:=remap[target]
    if loop[v]!=NONE && remap[loop[v]]==r {return loop[v]}
    if loopback[v]!=NONE && remap[loopback[v]]==r {return loopback[v]}
    return target
}

@(private="file")
bound_edge_collapses :: proc "contextless" (adjacency:^Edge_Adjacency,vertex_count,index_count:int,vertex_kind:[]u8) -> int #no_bounds_check {
    dual_count:=0
    for i in 0..<vertex_count {
        k:=vertex_kind[i]
        e:=int(adjacency.offsets[i+1]-adjacency.offsets[i])
        dual_count+=(k==KIND_MANIFOLD || k==KIND_SEAM)?e:0
    }
    // Padded by 3 so that overflow is checked once per triangle.
    return (index_count-dual_count/2)+3
}

@(private="file")
pick_edge_collapses :: proc "contextless" (collapses:[]Collapse,indices:[]u32,remap:[]u32,vertex_kind:[]u8,loop,loopback:[]u32) -> int #no_bounds_check {
    can_collapse:=CAN_COLLAPSE
    has_opposite:=HAS_OPPOSITE
    NEXT :: [3]int{1,2,0}
    next:=NEXT
    collapse_count:=0
    for t in 0..<len(indices)/3 {
        // The bound is never reached; past it the rest is dropped.
        if collapse_count+3>len(collapses) {break}
        for e in 0..<3 {
            i0:=indices[t*3+e]
            i1:=indices[t*3+next[e]]
            // A zero-length edge, or what a collapse of complex topology leaves: kept, it holds the mesh together.
            if remap[i0]==remap[i1] {continue}
            k0,k1:=vertex_kind[i0],vertex_kind[i1]
            if can_collapse[k0][k1]|can_collapse[k1][k0]==0 {continue}
            // An edge seen from both sides is taken once.
            if has_opposite[k0][k1]!=0 && remap[i1]>remap[i0] {continue}
            // Ends on a border or a seam without an edge between them are on two loops.
            if (k0==KIND_BORDER || k0==KIND_SEAM) && k1!=KIND_MANIFOLD && loop[i0]!=i1 {continue}
            if (k1==KIND_BORDER || k1==KIND_SEAM) && k0!=KIND_MANIFOLD && loopback[i1]!=i0 {continue}
            if can_collapse[k0][k1]&can_collapse[k1][k0]!=0 {
                collapses[collapse_count]={i0,i1,1}
            } else {
                e0:=can_collapse[k0][k1]!=0?i0:i1
                e1:=can_collapse[k0][k1]!=0?i1:i0
                collapses[collapse_count]={e0,e1,0}
            }
            collapse_count+=1
        }
    }
    return collapse_count
}

@(private="file")
Rank :: struct {
    positions:[]Vec3,
    attributes:[]f32,
    vertex_quadrics:[]Quadric,
    attribute_quadrics:[]Quadric,
    attribute_gradients:[]Quadric_Grad,
    attribute_count:int,
    remap,wedge:[]u32,
    vertex_kind:[]u8,
    loop,loopback:[]u32,
    clamped:bool,
}

@(private="file")
rank_attribute_error :: #force_inline proc "contextless" (r:^Rank,v,target:u32) -> f32 #no_bounds_check {
    n:=r.attribute_count
    return quadric_error_attributes(&r.attribute_quadrics[v],r.attribute_gradients[int(v)*n:][:n],r.positions[target],r.attributes[int(target)*n:][:n],r.clamped)
}

@(private="file")
rank_edge_collapses :: proc "contextless" (r:^Rank,collapses:[]Collapse) #no_bounds_check {
    for &c in collapses {
        i0,i1:=c.v0,c.v1
        bidi:=c.bits!=0
        ei:=quadric_error(&r.vertex_quadrics[r.remap[i0]],r.positions[i1])
        ej:=bidi?quadric_error(&r.vertex_quadrics[r.remap[i1]],r.positions[i0]):max(f32)
        if r.attribute_count>0 {
            ei+=rank_attribute_error(r,i0,i1)
            ej+=bidi?rank_attribute_error(r,i1,i0):0
            if r.vertex_kind[i0]==KIND_SEAM {
                // The other side of the seam: the loops find it, as the target may be locked with more than two wedges.
                s0:=r.wedge[i0]
                s1:=r.loop[i0]==i1?r.loopback[s0]:r.loop[s0]
                s1=s1!=NONE?s1:r.wedge[i1]
                ei+=rank_attribute_error(r,s0,s1)
                ej+=bidi?rank_attribute_error(r,s1,s0):0
            } else {
                // Every wedge of a complex place moves, each to its own target.
                if r.vertex_kind[i0]==KIND_COMPLEX || r.vertex_kind[i0]==KIND_FRINGE {
                    for v:=r.wedge[i0];v!=i0;v=r.wedge[v] {
                        ei+=rank_attribute_error(r,v,complex_target(v,i1,r.remap,r.loop,r.loopback))
                    }
                }
                if (r.vertex_kind[i1]==KIND_COMPLEX || r.vertex_kind[i1]==KIND_FRINGE) && bidi {
                    for v:=r.wedge[i1];v!=i1;v=r.wedge[v] {
                        ej+=rank_attribute_error(r,v,complex_target(v,i0,r.remap,r.loop,r.loopback))
                    }
                }
            }
        }
        rev:=bidi && ej<ei
        c.v0=rev?i1:i0
        c.v1=rev?i0:i1
        c.bits=transmute(u32)(ej<ei?ej:ei)
    }
}

// A counting sort by the top 12 bits of the error (8 of exponent, 4 of
// mantissa); errors far above 1 share the last bin.
@(private="file")
sort_edge_collapses :: proc "contextless" (sort_order:[]u32,collapses:[]Collapse) #no_bounds_check {
    SORT_BITS :: 12
    SORT_BINS :: 2048+512
    histogram:[SORT_BINS]u32
    for c in collapses {
        key:=(c.bits<<1)>>(32-SORT_BITS)
        key=key<SORT_BINS?key:SORT_BINS-1
        histogram[key]+=1
    }
    sum:u32
    for &count in histogram {
        n:=count
        count=sum
        sum+=n
    }
    for c,i in collapses {
        key:=(c.bits<<1)>>(32-SORT_BITS)
        key=key<SORT_BINS?key:SORT_BINS-1
        sort_order[histogram[key]]=u32(i)
        histogram[key]+=1
    }
}

@(private="file")
collapse_error :: #force_inline proc "contextless" (c:Collapse) -> f32 {return transmute(f32)c.bits}

@(private="file")
perform_edge_collapses :: proc "contextless" (collapse_remap:[]u32,collapse_locked:[]u8,collapses:[]Collapse,collapse_order:[]u32,remap,wedge:[]u32,vertex_kind:[]u8,loop,loopback:[]u32,positions:[]Vec3,adjacency:^Edge_Adjacency,triangle_collapse_goal:int,error_limit:f32,result_error:^f32) -> int #no_bounds_check {
    collapse_count:=len(collapses)
    edge_collapses:=0
    triangle_collapses:=0
    // Most collapses remove two triangles: an estimate that bounds the error of the pass.
    edge_collapse_goal:=triangle_collapse_goal/2
    for i in 0..<collapse_count {
        c:=collapses[collapse_order[i]]
        error:=collapse_error(c)
        if error>error_limit {break}
        if triangle_collapses>=triangle_collapse_goal {break}
        // Collapses that share places with one made are skipped, so the error a pass accepts grows by a factor.
        error_goal:=edge_collapse_goal<collapse_count?1.5*collapse_error(collapses[collapse_order[edge_collapse_goal]]):max(f32)
        // Each collapse locks about 6 others: a pass ends early only past a sixth of its goal.
        if error>error_goal && error>result_error^ && triangle_collapses>triangle_collapse_goal/6 {break}
        i0,i1:=c.v0,c.v1
        r0,r1:=remap[i0],remap[i1]
        kind:=vertex_kind[i0]
        // A place moves once per pass, and nothing moves onto a place that moved.
        if collapse_locked[r0]|collapse_locked[r1]!=0 {continue}
        if has_triangle_flips(adjacency,positions,collapse_remap,r0,r1) {
            // An invalid collapse does not count towards the goal.
            edge_collapse_goal+=1
            continue
        }
        if kind==KIND_COMPLEX || kind==KIND_FRINGE {
            collapse_remap[i0]=i1
            for v:=wedge[i0];v!=i0;v=wedge[v] {collapse_remap[v]=complex_target(v,i1,remap,loop,loopback)}
        } else if kind==KIND_SEAM {
            // Both sides of the seam move together.
            s0:=wedge[i0]
            s1:=loop[i0]==i1?loopback[s0]:loop[s0]
            s1=s1!=NONE?s1:wedge[i1]
            collapse_remap[i0]=i1
            collapse_remap[s0]=s1
        } else {
            collapse_remap[i0]=i1
        }
        collapse_locked[r0]=1
        collapse_locked[r1]=1
        // A border collapse removes one triangle; fringes count as two to be safe.
        triangle_collapses+=kind==KIND_BORDER?1:2
        edge_collapses+=1
        result_error^=result_error^<error?error:result_error^
    }
    return edge_collapses
}

@(private="file")
update_quadrics :: proc "contextless" (collapse_remap:[]u32,vertex_quadrics,attribute_quadrics:[]Quadric,attribute_gradients:[]Quadric_Grad,attribute_count:int,positions:[]Vec3,remap:[]u32,vertex_error:^f32) #no_bounds_check {
    n:=attribute_count
    for i in 0..<len(collapse_remap) {
        if collapse_remap[i]==u32(i) {continue}
        i0:=u32(i)
        i1:=collapse_remap[i]
        r0,r1:=remap[i0],remap[i1]
        // The quadric of a place is added once, with its first vertex.
        if i0==r0 {quadric_add(&vertex_quadrics[r1],vertex_quadrics[r0])}
        if n>0 {
            quadric_add(&attribute_quadrics[i1],attribute_quadrics[i0])
            grads_add(attribute_gradients[int(i1)*n:][:n],attribute_gradients[int(i0)*n:][:n])
            if i0==r0 {
                // With attributes the collapses do not track the distance: it is measured here.
                derr:=quadric_error(&vertex_quadrics[r0],positions[r1])
                vertex_error^=vertex_error^<derr?derr:vertex_error^
            }
        }
    }
}

@(private="file")
remap_index_buffer :: proc "contextless" (indices:[]u32,collapse_remap,remap:[]u32) -> int #no_bounds_check {
    write:=0
    for t in 0..<len(indices)/3 {
        v0:=collapse_remap[indices[t*3]]
        v1:=collapse_remap[indices[t*3+1]]
        v2:=collapse_remap[indices[t*3+2]]
        // Triangles without area go even when their corners differ: collapses onto a seam pair leave them.
        r0,r1,r2:=remap[v0],remap[v1],remap[v2]
        if r0!=r1 && r0!=r2 && r1!=r2 {
            indices[write]=v0
            indices[write+1]=v1
            indices[write+2]=v2
            write+=3
        }
    }
    return write
}

@(private="file")
remap_edge_loops :: proc "contextless" (loop,collapse_remap:[]u32) #no_bounds_check {
    for i in 0..<len(loop) {
        // Vertices that moved keep their loops: the remapping still reads them.
        if loop[i]==NONE {continue}
        l:=loop[i]
        r:=collapse_remap[l]
        // The seam edge collapsed against the direction of the loop.
        if u32(i)==r {
            loop[i]=loop[l]!=NONE?collapse_remap[loop[l]]:NONE
        } else {
            loop[i]=r
        }
    }
}

@(private="file")
component_follow :: proc "contextless" (parents:[]u32,index:u32) -> u32 #no_bounds_check {
    index:=index
    for index!=parents[index] {
        parent:=parents[index]
        parents[index]=parents[parent]
        index=parent
    }
    return index
}

@(private="file")
build_components :: proc "contextless" (components:[]u32,indices:[]u32,remap:[]u32) -> int #no_bounds_check {
    vertex_count:=len(components)
    for &c,i in components {c=u32(i)}
    NEXT :: [3]int{1,2,0}
    next:=NEXT
    // Union-find whose root is the smallest index of a component.
    for t in 0..<len(indices)/3 {
        for e in 0..<3 {
            r0:=component_follow(components,remap[indices[t*3+e]])
            r1:=component_follow(components,remap[indices[t*3+next[e]]])
            if r0!=r1 {components[r0<r1?r1:r0]=r0<r1?r0:r1}
        }
    }
    for i in 0..<vertex_count {
        if remap[i]==u32(i) {components[i]=component_follow(components,u32(i))}
    }
    next_component:u32
    for i in 0..<vertex_count {
        if remap[i]==u32(i) {
            root:=components[i]
            if root==u32(i) {
                components[i]=next_component
                next_component+=1
            } else {
                components[i]=components[root]
            }
        } else {
            components[i]=components[remap[i]]
        }
    }
    return int(next_component)
}

// The squared radius of each component around the mean of its vertices,
// in the units of the quadrics. component_errors holds 4 per component.
@(private="file")
measure_components :: proc "contextless" (component_errors:[]f32,component_count:int,components:[]u32,positions:[]Vec3) #no_bounds_check {
    for &e in component_errors[:component_count*4] {e=0}
    for i in 0..<len(components) {
        c:=components[i]
        v:=positions[i]
        component_errors[c*4]+=v.x
        component_errors[c*4+1]+=v.y
        component_errors[c*4+2]+=v.z
        component_errors[c*4+3]+=1
    }
    for i in 0..<component_count {
        w:=component_errors[i*4+3]
        iw:=w==0?f32(0):1/w
        component_errors[i*4]*=iw
        component_errors[i*4+1]*=iw
        component_errors[i*4+2]*=iw
        component_errors[i*4+3]=0
    }
    for i in 0..<len(components) {
        c:=components[i]
        dx:=positions[i].x-component_errors[c*4]
        dy:=positions[i].y-component_errors[c*4+1]
        dz:=positions[i].z-component_errors[c*4+2]
        r:=dx*dx+dy*dy+dz*dz
        component_errors[c*4+3]=component_errors[c*4+3]<r?r:component_errors[c*4+3]
    }
    for i in 0..<component_count {component_errors[i]=component_errors[i*4+3]}
}

@(private="file")
prune_components :: proc "contextless" (indices:[]u32,components:[]u32,component_errors:[]f32,error_cutoff:f32,nexterror:^f32) -> int #no_bounds_check {
    write:=0
    min_error:=max(f32)
    for t in 0..<len(indices)/3 {
        v0,v1,v2:=indices[t*3],indices[t*3+1],indices[t*3+2]
        c:=components[v0]
        if component_errors[c]>error_cutoff {
            min_error=min_error>component_errors[c]?component_errors[c]:min_error
            indices[write]=v0
            indices[write+1]=v1
            indices[write+2]=v2
            write+=3
        }
    }
    nexterror^=min_error
    return write
}

// The extent of the positions: what a relative error is a share of.
simplify_scale :: proc "contextless" (positions:[]Vec3) -> f32 {
    extent,_:=rescale_positions(nil,positions,len(positions),nil)
    return extent
}

// Writes to destination (at least as long as indices; it may be indices
// itself) the indices of the mesh with at most target_index_count of them,
// or as close as topology and target_error allow. They name the vertices of
// the input; no vertex moves. target_error is a share of the extent of the
// positions (simplify_scale), or a distance with Error_Absolute, and the
// errors of the result are in the same units. attributes holds len(attribute_weights) values per vertex, which
// weigh against the positions as their weight says; vertex_lock is empty
// or one per vertex. Scratch memory comes from context.temp_allocator and is
// freed before returning. A vertex that is not finite, an index out of
// range, a destination too short or attributes of another length give
// Invalid_Mesh or Invalid_Attributes and write nothing.
simplify :: proc(destination,indices:[]u32,positions:[]Vec3,target_index_count:int,target_error:f32,options:Simplify_Options={},attributes:[]f32=nil,attribute_weights:[]f32=nil,vertex_lock:[]Simplify_Vertex=nil) -> (result:Simplify_Result,error:Simplify_Error) #no_bounds_check {
    vertex_count:=len(positions)
    if len(indices)%3!=0 || len(destination)<len(indices) || vertex_count>=int(NONE) || target_index_count<0 || !(target_error>=0) {return {},.Invalid_Mesh}
    if len(vertex_lock)!=0 && len(vertex_lock)!=vertex_count {return {},.Invalid_Mesh}
    for index in indices {
        if int(index)>=vertex_count || !finite3(positions[index]) {return {},.Invalid_Mesh}
    }
    if len(attribute_weights)>SIMPLIFY_MAX_ATTRIBUTES || len(attributes)!=vertex_count*len(attribute_weights) {return {},.Invalid_Attributes}
    for weight in attribute_weights {
        if !(weight>=0) || weight-weight!=0 {return {},.Invalid_Attributes}
    }
    if len(attribute_weights)>0 {
        stride:=len(attribute_weights)
        for index in indices {
            for a in attributes[int(index)*stride:][:stride] {
                if a-a!=0 {return {},.Invalid_Attributes}
            }
        }
    }

    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    scratch:=context.temp_allocator
    out:=destination[:len(indices)]
    copy(out,indices)
    index_count:=len(indices)

    sparse:[]u32
    if .Sparse in options {
        ok:bool
        sparse,ok=sparse_remap_build(out,vertex_count,scratch)
        if !ok {return {},.Out_Of_Memory}
        vertex_count=len(sparse)
    }

    adjacency:Edge_Adjacency
    remap,wedge,loop,loopback:[]u32
    vertex_kind:[]u8
    vertex_positions:[]Vec3
    vertex_quadrics:[]Quadric
    {
        failed:runtime.Allocator_Error
        alloc :: proc(failed:^runtime.Allocator_Error,$T:typeid,count:int,scratch:runtime.Allocator) -> []T {
            out,err:=make([]T,count,scratch)
            if err!=nil {failed^=err}
            return out
        }
        adjacency.offsets=alloc(&failed,u32,vertex_count+1,scratch)
        adjacency.data=alloc(&failed,Adjacent,index_count,scratch)
        remap=alloc(&failed,u32,vertex_count,scratch)
        wedge=alloc(&failed,u32,vertex_count,scratch)
        vertex_kind=alloc(&failed,u8,vertex_count,scratch)
        loop=alloc(&failed,u32,vertex_count,scratch)
        loopback=alloc(&failed,u32,vertex_count,scratch)
        vertex_positions=alloc(&failed,Vec3,vertex_count,scratch)
        vertex_quadrics=alloc(&failed,Quadric,vertex_count,scratch)
        if failed!=nil {return {},.Out_Of_Memory}
    }
    adjacency_update(&adjacency,out,vertex_count,nil)
    if !position_remap_build(remap,wedge,positions,sparse,scratch) {return {},.Out_Of_Memory}
    classify_vertices(vertex_kind,loop,loopback,&adjacency,remap,wedge,vertex_lock,sparse,options)

    vertex_scale,_:=rescale_positions(vertex_positions,positions,vertex_count,sparse)

    // Only attributes of weight above 0 enter the quadrics.
    attribute_count:=0
    vertex_attributes:[]f32
    attribute_quadrics:[]Quadric
    attribute_gradients:[]Quadric_Grad
    if len(attribute_weights)>0 {
        attribute_remap:[SIMPLIFY_MAX_ATTRIBUTES]int
        for weight,i in attribute_weights {
            if weight>0 {
                attribute_remap[attribute_count]=i
                attribute_count+=1
            }
        }
        stride:=len(attribute_weights)
        failed,failed_quadrics,failed_gradients:runtime.Allocator_Error
        vertex_attributes,failed=make([]f32,vertex_count*attribute_count,scratch)
        attribute_quadrics,failed_quadrics=make([]Quadric,attribute_count>0?vertex_count:0,scratch)
        attribute_gradients,failed_gradients=make([]Quadric_Grad,vertex_count*attribute_count,scratch)
        if failed!=nil || failed_quadrics!=nil || failed_gradients!=nil {return {},.Out_Of_Memory}
        for i in 0..<vertex_count {
            ri:=len(sparse)>0?int(sparse[i]):i
            for k in 0..<attribute_count {
                rk:=attribute_remap[k]
                vertex_attributes[i*attribute_count+k]=attributes[ri*stride+rk]*attribute_weights[rk]
            }
        }
    }

    fill_face_quadrics(vertex_quadrics,out,vertex_positions,remap)
    fill_vertex_quadrics(vertex_quadrics,vertex_positions,remap,vertex_lock,sparse,options)
    fill_edge_quadrics(vertex_quadrics,out,vertex_positions,remap,vertex_kind,loop,loopback)
    if attribute_count>0 {fill_attribute_quadrics(attribute_quadrics,attribute_gradients,out,vertex_positions,vertex_attributes,attribute_count)}

    components:[]u32
    component_errors:[]f32
    component_count:=0
    component_nexterror:f32
    if .Prune in options {
        failed:runtime.Allocator_Error
        components,failed=make([]u32,vertex_count,scratch)
        if failed!=nil {return {},.Out_Of_Memory}
        component_count=build_components(components,out,remap)
        // Four per component while they are measured.
        component_errors,failed=make([]f32,component_count*4,scratch)
        if failed!=nil {return {},.Out_Of_Memory}
        measure_components(component_errors,component_count,components,vertex_positions)
        component_nexterror=max(f32)
        for e in component_errors[:component_count] {component_nexterror=component_nexterror>e?e:component_nexterror}
    }

    collapse_capacity:=bound_edge_collapses(&adjacency,vertex_count,index_count,vertex_kind)
    edge_collapses,failed_collapses:=make([]Collapse,collapse_capacity,scratch)
    collapse_order,failed_order:=make([]u32,collapse_capacity,scratch)
    collapse_remap,failed_remap:=make([]u32,vertex_count,scratch)
    collapse_locked,failed_locked:=make([]u8,vertex_count,scratch)
    if failed_collapses!=nil || failed_order!=nil || failed_remap!=nil || failed_locked!=nil {return {},.Out_Of_Memory}

    result_count:=index_count
    result_error_sq:f32
    vertex_error:f32
    // target_error is linear and the quadrics measure squares.
    error_scale:=.Error_Absolute in options?vertex_scale:1
    error_limit:=(target_error*target_error)/(error_scale*error_scale)

    rank:=Rank{
        positions=vertex_positions,attributes=vertex_attributes,vertex_quadrics=vertex_quadrics,
        attribute_quadrics=attribute_quadrics,attribute_gradients=attribute_gradients,attribute_count=attribute_count,
        remap=remap,wedge=wedge,vertex_kind=vertex_kind,loop=loop,loopback=loopback,clamped=.Error_Clamped in options,
    }
    for result_count>target_index_count {
        // The adjacency follows the welded topology of the result so far.
        adjacency_update(&adjacency,out[:result_count],vertex_count,remap)
        edge_collapse_count:=pick_edge_collapses(edge_collapses,out[:result_count],remap,vertex_kind,loop,loopback)
        // Topology allows no more collapses.
        if edge_collapse_count==0 {break}
        picked:=edge_collapses[:edge_collapse_count]
        rank_edge_collapses(&rank,picked)
        sort_edge_collapses(collapse_order,picked)
        triangle_collapse_goal:=(result_count-target_index_count)/3
        for &r,i in collapse_remap {r=u32(i)}
        for &l in collapse_locked {l=0}
        collapses:=perform_edge_collapses(collapse_remap,collapse_locked,picked,collapse_order,remap,wedge,vertex_kind,loop,loopback,vertex_positions,&adjacency,triangle_collapse_goal,error_limit,&result_error_sq)
        // The error limit or the goal stop every collapse.
        if collapses==0 {break}
        update_quadrics(collapse_remap,vertex_quadrics,attribute_quadrics,attribute_gradients,attribute_count,vertex_positions,remap,&vertex_error)
        // Without attributes the error of the collapses is that of the positions.
        vertex_error=attribute_count==0?result_error_sq:vertex_error
        // Loops can still point at a vertex no longer joined, which does not change any collapse.
        remap_edge_loops(loop,collapse_remap)
        remap_edge_loops(loopback,collapse_remap)
        result_count=remap_index_buffer(out[:result_count],collapse_remap,remap)
        if .Prune in options && result_count>target_index_count && component_nexterror<=vertex_error {
            result_count=prune_components(out[:result_count],components,component_errors,vertex_error,&component_nexterror)
        }
    }

    // component_nexterror may name a component that collapses already removed.
    component_nextstale:=true
    // Short of the target: prune more, up to the error limit.
    prune:=.Prune in options
    for prune && result_count>target_index_count && component_nexterror<=error_limit {
        component_cutoff:=component_nexterror*1.5<error_limit?component_nexterror*1.5:error_limit
        component_maxerror:f32
        for e in component_errors[:component_count] {
            if e>component_maxerror && e<=component_cutoff {component_maxerror=e}
        }
        new_count:=prune_components(out[:result_count],components,component_errors,component_cutoff,&component_nexterror)
        if new_count==result_count && !component_nextstale {break}
        component_nextstale=false
        result_count=new_count
        result_error_sq=result_error_sq<component_maxerror?component_maxerror:result_error_sq
        vertex_error=vertex_error<component_maxerror?component_maxerror:vertex_error
    }

    if len(sparse)>0 {
        for &index in out[:result_count] {index=sparse[index]}
    }
    return {result_count,math.sqrt(result_error_sq)*error_scale,math.sqrt(vertex_error)*error_scale},.None
}
