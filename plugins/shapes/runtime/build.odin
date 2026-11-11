package shapes

import "base:runtime"
import "core:hash"
import "core:math/linalg"
import "core:slice"
import "mirai:std/base"
import "mirai:std/geom"
import mm "mirai:std/math"

// What draws and collides a shape, made from its source alone, on any
// thread; the ribbon of a spline from its points (ribbon.odin). The drawn
// mesh has one material slot. A polygon alone has its caps with planar UVs and
// its sides with UVs that run along the perimeter, flat normals where a loop
// turns sharply and shared ones where it turns little, so a circle looks
// round; the bands of a bevel continue the UVs of its sides. A Solid with
// brushes has the UVs of a box projection. Both scale their UVs by uv_scale; a
// ribbon runs u across and v along it in meters. What collides is, for a static shape,
// the triangles of the mesh joined by position (of a polygon alone, its caps
// and sides without the bevel), with the edges between coplanar triangles
// disabled so nothing catches on the seams of a flat face; for a body, the
// convex pieces of shape_pieces_build, each a hull of the collider. A ribbon
// collides with nothing.

// A side shares the normal of a vertex with the next side when the two turn less than this cosine apart.
@(private) SMOOTH_COS :: 0.82
// Two triangles whose normals are closer than this cosine are one plane.
@(private) PLANE_COS :: 0.999999

// Convex pieces whose union is the solid of a shape: the points of each, one
// piece after another, and how many points each has.
Shape_Pieces :: struct {
    points:[dynamic]geom.Vec3,
    sizes:[dynamic]u32,
}

Shape_Geometry :: struct {
    mesh:geom.Mesh_Buffer,      // drawn: positions, normals and uvs
    collision:geom.Mesh_Buffer, // of a static shape: positions and indices
    disabled_edges:[dynamic]u8, // of a static shape: per triangle of collision
    pieces:Shape_Pieces,        // of a body: at least 4 points each
    brush:geom.Mesh_Buffer,
    work:geom.Mesh_Buffer,
    indices,sizes:[dynamic]u32,
    ribbon:[dynamic][3]f32,     // of a spline, rows of columns points: what the build makes its mesh from
    columns:int,
}

shape_geometry_init :: proc(g:^Shape_Geometry,allocator:=context.allocator) {
    geom.mesh_buffer_init(&g.mesh,allocator)
    geom.mesh_buffer_init(&g.collision,allocator)
    geom.mesh_buffer_init(&g.brush,allocator)
    geom.mesh_buffer_init(&g.work,allocator)
    g.disabled_edges=make([dynamic]u8,allocator)
    g.pieces.points=make([dynamic]geom.Vec3,allocator)
    g.pieces.sizes=make([dynamic]u32,allocator)
    g.indices=make([dynamic]u32,allocator)
    g.sizes=make([dynamic]u32,allocator)
    g.ribbon=make([dynamic][3]f32,allocator)
}

shape_geometry_destroy :: proc(g:^Shape_Geometry) {
    geom.mesh_buffer_destroy(&g.mesh);geom.mesh_buffer_destroy(&g.collision)
    geom.mesh_buffer_destroy(&g.brush);geom.mesh_buffer_destroy(&g.work)
    delete(g.disabled_edges);delete(g.pieces.points);delete(g.pieces.sizes);delete(g.indices);delete(g.sizes);delete(g.ribbon)
    g^={}
}

@(private)
shape_geometry_clear :: proc(g:^Shape_Geometry) {
    geom.mesh_buffer_clear(&g.mesh);geom.mesh_buffer_clear(&g.collision)
    clear(&g.disabled_edges);clear(&g.pieces.points);clear(&g.pieces.sizes)
}

// Builds the mesh of a shape and what collides: for a body its convex
// pieces, else the static triangles. The brushes, in order, are those of the
// Solid. On an error g holds nothing usable.
shape_geometry_build :: proc(s:^Shape,brushes:[]Brush,body:bool,g:^Shape_Geometry) -> Shape_Error {
    shape_geometry_clear(g)
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    if error:=solid_build(s,brushes,g);error!=.None {
        shape_geometry_clear(g)
        return error
    }
    if !body {
        if !static_collision(g) {
            shape_geometry_clear(g)
            return .Out_Of_Memory
        }
        return .None
    }
    geom.mesh_buffer_clear(&g.collision)
    if error:=shape_pieces_build(s,brushes,g);error!=.None {
        shape_geometry_clear(g)
        return error
    }
    return .None
}

// The convex pieces of a Solid whose mesh g already holds: when every brush
// adds, the convex partition of its polygon extruded into prisms and its
// brushes; else an approximate decomposition of its mesh.
shape_pieces_build :: proc(s:^Shape,brushes:[]Brush,g:^Shape_Geometry) -> Shape_Error {
    clear(&g.pieces.points);clear(&g.pieces.sizes)
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    adds:=true
    for b in brushes {adds&&=b.op==.Union}
    if adds && s.loop_count>0 {
        points,sizes,error:=outline_loops(s)
        if error!=.None {return error}
        clear(&g.indices);clear(&g.sizes)
        if geom.polygon_convex_partition(points,sizes,&g.indices,&g.sizes)==0 {return .Geometry}
        h:=0.5*s.depth
        at:=0
        for size in g.sizes {
            for i in g.indices[at:][:size] {append(&g.pieces.points,geom.Vec3{points[i].x,points[i].y,h})}
            for i in g.indices[at:][:size] {append(&g.pieces.points,geom.Vec3{points[i].x,points[i].y,-h})}
            append(&g.pieces.sizes,2*size)
            at+=int(size)
        }
    }
    if adds {
        for b in brushes {
            if !brush_valid(b) {return .Invalid}
            brush_mesh(b,&g.brush)
            append(&g.pieces.points,..g.brush.positions[:])
            append(&g.pieces.sizes,u32(len(g.brush.positions)))
        }
    } else {
        if len(g.mesh.indices)==0 {return .Empty}
        parts,error:=geom.mesh_decompose(geom.mesh_buffer_view(&g.mesh),{},context.temp_allocator)
        if error!=.None {return .Geometry}
        for hull in parts.hulls {
            if len(hull.vertices)<4 {continue}
            append(&g.pieces.points,..hull.vertices)
            append(&g.pieces.sizes,u32(len(hull.vertices)))
        }
    }
    if len(g.pieces.sizes)==0 {return .Empty}
    return .None
}

// What a build depends on: the source, its brushes in order and whether it is a body.
shape_key :: proc(s:^Shape,brushes:[]Brush,body:bool) -> u64 {
    points,loops:=shape_counts(s)
    bevel_points:=min(int(s.bevel_point_count),BEVEL_POINTS)
    head:=struct {
        body:bool,loops:u8,points:u16,depth:f32,uv_scale:[2]f32,material:base.Asset_Id,
        bevel:f32,profile:Bevel_Profile,segments,bevel_points:u8,
    } {
        body,u8(loops),u16(points),s.depth,s.uv_scale,s.material,
        s.bevel,s.bevel_profile,s.bevel_segments,u8(bevel_points),
    }
    h:=hash.fnv64a(slice.bytes_from_ptr(&head,size_of(head)))
    h=hash.fnv64a(slice.to_bytes(s.loops[:loops]),h)
    h=hash.fnv64a(slice.to_bytes(s.points[:points]),h)
    h=hash.fnv64a(slice.to_bytes(s.bevel_points[:bevel_points]),h)
    for b in brushes {
        // Field by field: the padding of a Brush is not part of it.
        values:=[12]f32{
            f32(b.kind),f32(b.op),b.place.position.x,b.place.position.y,b.place.position.z,
            b.place.rotation.x,b.place.rotation.y,b.place.rotation.z,b.place.rotation.w,
            b.place.scale.x,b.place.scale.y,b.place.scale.z,
        }
        h=hash.fnv64a(slice.to_bytes(values[:]),h)
    }
    return h
}

// ------------------------------------------------------------------ outline

// The loops of the polygon of a Solid, its outline counter-clockwise and its
// holes clockwise, in temporary memory, checked.
@(private)
outline_loops :: proc(s:^Shape) -> (points:[]geom.Vec2,sizes:[]int,error:Shape_Error) {
    if error=shape_valid_counts(s);error!=.None {return}
    if !(s.depth>0 && s.depth<max(f32)) {return nil,nil,.Invalid}
    for p in s.points[:s.point_count] {
        if !finite2(p) {return nil,nil,.Invalid}
    }
    if !shape_outline_clear(s) {return nil,nil,.Self_Intersecting}
    points=make([]geom.Vec2,int(s.point_count),context.temp_allocator)
    sizes=make([]int,int(s.loop_count),context.temp_allocator)
    first:=0
    for l in 0..<int(s.loop_count) {
        n:=int(s.loops[l])
        sizes[l]=n
        copy(points[first:first+n],s.points[first:first+n])
        if (loop_area(points[first:first+n])>0)!=(l==0) {loop_reverse(points[first:first+n])}
        first+=n
    }
    return
}

@(private)
uv_scale_of :: proc "contextless" (s:^Shape) -> (scale:[2]f32,ok:bool) {
    for v,i in s.uv_scale {scale[i]=v if v!=0 else 1}
    return scale,scale.x>0 && scale.y>0 && scale.x<max(f32) && scale.y<max(f32)
}

@(private)
outline_build :: proc(s:^Shape,g:^Shape_Geometry) -> Shape_Error {
    k,usable:=uv_scale_of(s)
    if !usable {return .Invalid}
    points,sizes,error:=outline_loops(s)
    if error!=.None {return error}
    rings,bevel_error:=bevel_rings(s)
    if bevel_error!=.None {return bevel_error}
    triangles:=make([dynamic]u32,context.temp_allocator)
    if geom.polygon_triangulate(points,sizes,&triangles)<=0 {return .Geometry}
    h:=0.5*s.depth
    n:=u32(len(points))
    // What collides has no bevel: its caps over the points, front i and back
    // n+i, and a quad per edge between them.
    c:=&g.collision
    for p in points {append(&c.positions,geom.Vec3{p.x,p.y,h})}
    for p in points {append(&c.positions,geom.Vec3{p.x,p.y,-h})}
    for i:=0;i<len(triangles);i+=3 {
        a,b,d:=triangles[i],triangles[i+1],triangles[i+2]
        append(&c.indices,a,b,d,n+a,n+d,n+b)
    }
    first:=0
    for size in sizes {
        for i in 0..<size {
            fa,fb:=u32(first+i),u32(first+(i+1)%size)
            append(&c.indices,n+fa,n+fb,fb,n+fa,fb,fa)
        }
        first+=size
    }
    if len(rings)>0 && outline_bevel_build(s,points,sizes,rings,k,g) {return .None}
    m:=&g.mesh
    for p in points {
        append(&m.positions,geom.Vec3{p.x,p.y,h});append(&m.normals,geom.Vec3{0,0,1});append(&m.uvs,geom.Vec2{p.x,-p.y}*k)
    }
    for p in points {
        append(&m.positions,geom.Vec3{p.x,p.y,-h});append(&m.normals,geom.Vec3{0,0,-1});append(&m.uvs,geom.Vec2{-p.x,-p.y}*k)
    }
    for i:=0;i<len(triangles);i+=3 {
        a,b,d:=triangles[i],triangles[i+1],triangles[i+2]
        append(&m.indices,a,b,d,n+a,n+d,n+b)
    }
    first=0
    for size in sizes {
        loop:=points[first:first+size]
        side:=make([]geom.Vec2,size,context.temp_allocator)
        for i in 0..<size {side[i]=edge_normal(loop[i],loop[(i+1)%size])}
        for i in 0..<size {
            j:=(i+1)%size
            a,b:=loop[i],loop[j]
            start:=side_normal(side[(i+size-1)%size],side[i])
            end:=side_normal(side[j],side[i])
            u:=side_u(a,b)*k.x
            base:=u32(len(m.positions))
            append(&m.positions,geom.Vec3{a.x,a.y,-h},geom.Vec3{a.x,a.y,h},geom.Vec3{b.x,b.y,-h},geom.Vec3{b.x,b.y,h})
            append(&m.normals,geom.Vec3{start.x,start.y,0},geom.Vec3{start.x,start.y,0},geom.Vec3{end.x,end.y,0},geom.Vec3{end.x,end.y,0})
            append(&m.uvs,geom.Vec2{u[0],2*h*k.y},geom.Vec2{u[0],0},geom.Vec2{u[1],2*h*k.y},geom.Vec2{u[1],0})
            append(&m.indices,base,base+2,base+3,base,base+3,base+1)
        }
        first+=size
    }
    return .None
}

// Outward in the XY plane for an edge of a counter-clockwise outline or a clockwise hole.
@(private)
edge_normal :: proc "contextless" (a,b:geom.Vec2) -> geom.Vec2 {
    d:=b-a
    length:=linalg.length(d)
    return length>0?geom.Vec2{d.y,-d.x}/length:geom.Vec2{}
}

// The texture coordinate along a side, from a to b: where each end lies along the side's own
// direction in the plane, so that what an edit adds elsewhere on the outline does not slide it.
@(private)
side_u :: proc "contextless" (a,b:geom.Vec2) -> [2]f32 {
    d:=linalg.normalize0(b-a)
    return {linalg.dot(a,d),linalg.dot(b,d)}
}

// The normal of side at a vertex it shares with other: shared where they turn little.
@(private)
side_normal :: proc "contextless" (other,side:geom.Vec2) -> geom.Vec2 {
    a,b:=other,side
    if linalg.dot(a,b)<SMOOTH_COS {return b}
    return linalg.normalize0(a+b)
}

// -------------------------------------------------------------------- solid

// The polygon of a Solid, when it has one, and then its brushes in order.
@(private)
solid_build :: proc(s:^Shape,brushes:[]Brush,g:^Shape_Geometry) -> Shape_Error {
    k,usable:=uv_scale_of(s)
    if !usable {return .Invalid}
    have:=s.loop_count>0
    if have {
        if error:=outline_build(s,g);error!=.None || len(brushes)==0 {return error}
        // Among brushes the polygon collides as what they make together.
        geom.mesh_buffer_clear(&g.collision)
    } else if len(brushes)==0 {return .Empty}
    for b in brushes {
        if !brush_valid(b) {return .Invalid}
    }
    // What cuts or intersects before the first that adds has nothing to work on: it is left out.
    for b in brushes {
        brush_mesh(b,&g.brush)
        if !have {
            if b.op!=.Union {continue}
            geom.mesh_buffer_clear(&g.mesh)
            append(&g.mesh.positions,..g.brush.positions[:])
            append(&g.mesh.normals,..g.brush.normals[:])
            append(&g.mesh.uvs,..g.brush.uvs[:])
            append(&g.mesh.indices,..g.brush.indices[:])
            have=true
            continue
        }
        error:=geom.mesh_boolean(geom.mesh_buffer_view(&g.mesh),geom.mesh_buffer_view(&g.brush),b.op,&g.work)
        if error!=.None {return .Geometry}
        g.mesh,g.work=g.work,g.mesh
        have=len(g.mesh.indices)>0
    }
    if !have {return .Empty}
    m:=&g.mesh
    clear(&m.colors);clear(&m.materials)
    if resize(&m.uvs,len(m.positions))!=nil {return .Out_Of_Memory}
    for p,i in m.positions {m.uvs[i]=box_uv(p,m.normals[i])*k}
    return .None
}

// The mesh of the ribbon of a spline from its points, g.ribbon: u across
// from its left side and v along its middle, in meters, and the normal of each
// point across the points around it, facing up.
@(private)
ribbon_build :: proc(g:^Shape_Geometry) -> Shape_Error {
    shape_geometry_clear(g)
    c:=g.columns
    if c<2 || len(g.ribbon)<2*c || len(g.ribbon)%c!=0 {return .Invalid}
    rows:=len(g.ribbon)/c
    m:=&g.mesh
    v:f32
    for r in 0..<rows {
        row:=g.ribbon[r*c:][:c]
        if r>0 {v+=linalg.length(row[c/2]-g.ribbon[(r-1)*c+c/2])}
        u:f32
        for p,j in row {
            if j>0 {u+=linalg.length(p-row[j-1])}
            across:=row[min(j+1,c-1)]-row[max(j-1,0)]
            along:=g.ribbon[min(r+1,rows-1)*c+j]-g.ribbon[max(r-1,0)*c+j]
            n:=linalg.normalize0(linalg.cross(across,along))
            if n.y<0 {n=-n}
            if n=={} {n={0,1,0}}
            append(&m.positions,p);append(&m.normals,n);append(&m.uvs,geom.Vec2{u,v})
        }
    }
    // Counter-clockwise seen from above: the columns go from left to right of the way along the rows.
    for r in 0..<rows-1 {
        for j in 0..<c-1 {
            a:=u32(r*c+j)
            append(&m.indices,a,a+1,a+u32(c),a+1,a+u32(c)+1,a+u32(c))
        }
    }
    return .None
}

// The mesh of a brush in the frame of the shape: its primitive of one meter
// scaled, turned and moved by its place.
@(private)
brush_mesh :: proc(b:Brush,out:^geom.Mesh_Buffer) {
    geom.mesh_buffer_clear(out)
    switch b.kind {
    case .Box:      geom.cube_build(out)
    case .Sphere:   geom.sphere_build(out)
    case .Cylinder: geom.cylinder_build(out)
    }
    q:=brush_rotation(b)
    scale:=b.place.scale
    for &p in out.positions {p=mm.quat_rotate(q,p*scale)+b.place.position}
    // A normal scales by the inverse: it stays across the surface when the scale is uneven.
    for &n in out.normals {n=linalg.normalize0(mm.quat_rotate(q,n/scale))}
}

// Box projection: the plane of the axis the normal faces most.
@(private)
box_uv :: proc "contextless" (p,n:geom.Vec3) -> geom.Vec2 {
    a:=geom.Vec3{abs(n.x),abs(n.y),abs(n.z)}
    if a.x>=a.y && a.x>=a.z {return {n.x>=0?-p.z:p.z,-p.y}}
    if a.y>=a.z {return {p.x,n.y>=0?p.z:-p.z}}
    return {n.z>=0?p.x:-p.x,-p.y}
}

// ---------------------------------------------------------------- collision

// The static triangles of the mesh, joined by position, without those that
// joining leaves without area, and the edges between coplanar ones disabled.
@(private)
static_collision :: proc(g:^Shape_Geometry) -> bool {
    c:=&g.collision
    if len(c.indices)==0 {
        m:=&g.mesh
        remap:=make([]u32,len(m.positions),context.temp_allocator)
        lo,hi:=geom.mesh_bounds(m.positions[:])
        extent:=max(abs(lo.x),abs(lo.y),abs(lo.z),abs(hi.x),abs(hi.y),abs(hi.z))
        geom.positions_weld(m.positions[:],max(1e-6*extent,geom.tolerance_noise(extent)),remap)
        if _,error:=append(&c.positions,..m.positions[:]);error!=nil {return false}
        for i:=0;i<len(m.indices);i+=3 {
            a,b,d:=remap[m.indices[i]],remap[m.indices[i+1]],remap[m.indices[i+2]]
            if a==b || b==d || a==d {continue}
            if _,error:=append(&c.indices,a,b,d);error!=nil {return false}
        }
    }
    return coplanar_edges(c.positions[:],c.indices[:],&g.disabled_edges)
}

// Per triangle, the bits of its ordered edges that a triangle in its plane shares.
@(private)
coplanar_edges :: proc(positions:[]geom.Vec3,indices:[]u32,out:^[dynamic]u8) -> bool {
    count:=len(indices)/3
    if resize(out,count)!=nil {return false}
    slice.zero(out[:])
    Edge :: struct {key:u64,triangle:u32,edge:u8}
    edges:=make([]Edge,3*count,context.temp_allocator)
    for t in 0..<count {
        for e in 0..<3 {
            a,b:=indices[3*t+e],indices[3*t+(e+1)%3]
            edges[3*t+e]={u64(min(a,b))<<32|u64(max(a,b)),u32(t),u8(e)}
        }
    }
    slice.sort_by(edges,proc(x,y:Edge) -> bool {return x.key<y.key || x.key==y.key && x.triangle<y.triangle})
    for first:=0;first<len(edges); {
        last:=first+1
        for last<len(edges) && edges[last].key==edges[first].key {last+=1}
        if last-first==2 {
            x,y:=edges[first],edges[first+1]
            nx,ny:=triangle_normal(positions,indices,x.triangle),triangle_normal(positions,indices,y.triangle)
            lx,ly:=linalg.length(nx),linalg.length(ny)
            if lx>0 && ly>0 && linalg.dot(nx,ny)>=PLANE_COS*lx*ly {
                out[x.triangle]|=1<<x.edge
                out[y.triangle]|=1<<y.edge
            }
        }
        first=last
    }
    return true
}

@(private)
triangle_normal :: proc "contextless" (positions:[]geom.Vec3,indices:[]u32,t:u32) -> [3]f64 {
    a,b,c:=positions[indices[3*t]],positions[indices[3*t+1]],positions[indices[3*t+2]]
    u:=[3]f64{f64(b.x-a.x),f64(b.y-a.y),f64(b.z-a.z)}
    v:=[3]f64{f64(c.x-a.x),f64(c.y-a.y),f64(c.z-a.z)}
    return linalg.cross(u,v)
}
