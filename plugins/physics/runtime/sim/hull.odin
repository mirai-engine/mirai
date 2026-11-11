package mirai_physics

import "core:mem"
import "base:intrinsics"
import "base:runtime"
import "mirai:std/geom"

// dot(n,p)==d on the plane; n points out of the solid.
Plane :: struct {n:Vec3,d:f32}

// Half edge of a convex polyhedron. The twin of edge e is e~1.
Half_Edge :: struct {next:u16,origin:u8,face:u8}

HULL_MAX_VERTICES :: 255
HULL_MAX_FACES :: 255
HULL_MAX_HALF_EDGES :: 1024

// Convex polyhedron in its own frame. Immutable once built.
Hull :: struct {
    vertices:[]Vec3,
    planes:[]Plane,
    face_edges:[]u16, // first half edge of each face
    edges:[]Half_Edge,
    center:Vec3,      // center of mass
    volume:f32,
    inertia:Mat3,     // about the center, for unit density
    aabb:Aabb,
    inner_radius:f32, // largest sphere centered at `center` that fits inside
    // Collisions see `core`, every face moved in by convex_radius, inflated by it: the faces stay where
    // they are and the edges are rounded. The rest (bounds, mass, debug lines) is the hull as given.
    convex_radius:f32,
    core:^Hull, // nil without a convex radius
}

// Faces are loops of vertex indices, counter-clockwise seen from outside: face i has face_counts[i]
// indices, consecutive in face_indices. Every edge must be shared by exactly two faces.
Hull_Desc :: struct {vertices:[]Vec3,face_counts:[]u8,face_indices:[]u8}

@(private) plane_distance :: #force_inline proc "contextless" (p:Plane,point:Vec3) -> f32 {return dot(p.n,point)-p.d}

// Builds the half edges of a closed polyhedron given by face loops. `edges` needs one entry per loop index.
@(private)
hull_topology_build :: proc(vertex_count:int,face_counts,face_indices:[]u8,edges:[]Half_Edge,face_edges:[]u16) -> bool {
    total:=0
    for count in face_counts {
        if count<3 {return false}
        total+=int(count)
    }
    if total!=len(face_indices) || total!=len(edges) || total>HULL_MAX_HALF_EDGES || total%2!=0 {return false}
    // Directed edge a->b to its half edge plus one; zero is unseen.
    seen:=make([]u16,vertex_count*vertex_count,context.temp_allocator)
    pairs:=0
    cursor:=0
    for count,face in face_counts {
        loop:=face_indices[cursor:][:count]
        first,previous:=-1,-1
        for i in 0..<int(count) {
            a:=int(loop[i]);b:=int(loop[(i+1)%int(count)])
            if a>=vertex_count || b>=vertex_count || a==b || seen[a*vertex_count+b]!=0 {return false}
            index:int
            if twin:=seen[b*vertex_count+a];twin!=0 {
                index=int(twin-1)+1
            } else {
                index=2*pairs
                pairs+=1
            }
            seen[a*vertex_count+b]=u16(index+1)
            edges[index]={next=0,origin=u8(a),face=u8(face)}
            if previous>=0 {edges[previous].next=u16(index)} else {first=index}
            previous=index
        }
        edges[previous].next=u16(first)
        face_edges[face]=u16(first)
        cursor+=int(count)
    }
    if 2*pairs!=total {return false}
    for a in 0..<vertex_count {
        for b in 0..<vertex_count {
            if (seen[a*vertex_count+b]!=0)!=(seen[b*vertex_count+a]!=0) {return false}
        }
    }
    return true
}

// Planes by Newell's method, mass properties by signed tetrahedra, bounds and inner radius.
@(private)
hull_finish :: proc "contextless" (hull:^Hull) -> bool {
    reference:=hull.vertices[0]
    volume:f32
    center:Vec3
    covariance:Mat3
    canonical:=Mat3{1.0/60,1.0/120,1.0/120, 1.0/120,1.0/60,1.0/120, 1.0/120,1.0/120,1.0/60}
    for first,face in hull.face_edges {
        normal,centroid:Vec3
        count:=0
        edge:=first
        for {
            e:=hull.edges[edge]
            a:=hull.vertices[e.origin]-reference
            b:=hull.vertices[hull.edges[e.next].origin]-reference
            normal+={(a.y-b.y)*(a.z+b.z),(a.z-b.z)*(a.x+b.x),(a.x-b.x)*(a.y+b.y)}
            centroid+=a
            count+=1
            edge=e.next
            if edge==first {break}
        }
        normal=normalize(normal)
        if normal=={} {return false}
        centroid=centroid/f32(count)+reference
        hull.planes[face]={normal,dot(normal,centroid)}
        a:=hull.vertices[hull.edges[first].origin]-reference
        edge=hull.edges[first].next
        for hull.edges[edge].next!=first {
            b:=hull.vertices[hull.edges[edge].origin]-reference
            c:=hull.vertices[hull.edges[hull.edges[edge].next].origin]-reference
            det:=dot(a,cross(b,c))
            volume+=det/6
            center+=(det/24)*(a+b+c)
            m:=mat3_columns(a,b,c)
            covariance+=det*(m*canonical*intrinsics.transpose(m))
            edge=hull.edges[edge].next
        }
    }
    if volume<=1e-12 {return false}
    center/=volume
    trace:=covariance[0,0]+covariance[1,1]+covariance[2,2]
    inertia:=mat3_diagonal({trace,trace,trace})-covariance
    hull.inertia=inertia-mat3_point_inertia(volume,center)
    hull.center=center+reference
    hull.volume=volume
    hull.aabb={hull.vertices[0],hull.vertices[0]}
    for v in hull.vertices {hull.aabb={vmin(hull.aabb.min,v),vmax(hull.aabb.max,v)}}
    hull.inner_radius=max(f32)
    tolerance:=1e-3*length(hull.aabb.max-hull.aabb.min)+1e-5
    for plane in hull.planes {
        hull.inner_radius=min(hull.inner_radius,-plane_distance(plane,hull.center))
        for v in hull.vertices {
            if plane_distance(plane,v)>tolerance {return false}
        }
    }
    return hull.inner_radius>0
}

// Validates and builds a hull from vertices and face loops, rounded by convex_radius, which must be below its
// inner radius. Allocates: a transaction, not a per-tick path.
hull_init :: proc(hull:^Hull,desc:Hull_Desc,allocator:mem.Allocator,convex_radius:f32=0) -> bool {
    hull^={}
    if !(convex_radius>=0 && convex_radius<max(f32)) {return false}
    vertex_count:=len(desc.vertices);face_count:=len(desc.face_counts)
    if vertex_count<4 || vertex_count>HULL_MAX_VERTICES || face_count<4 || face_count>HULL_MAX_FACES {return false}
    for v in desc.vertices {
        if !finite(v) {return false}
    }
    error:mem.Allocator_Error
    if hull.vertices,error=make([]Vec3,vertex_count,allocator);error!=nil {return false}
    if hull.planes,error=make([]Plane,face_count,allocator);error!=nil {hull_free(hull,allocator);return false}
    if hull.face_edges,error=make([]u16,face_count,allocator);error!=nil {hull_free(hull,allocator);return false}
    if hull.edges,error=make([]Half_Edge,len(desc.face_indices),allocator);error!=nil {hull_free(hull,allocator);return false}
    copy(hull.vertices,desc.vertices)
    if !hull_topology_build(vertex_count,desc.face_counts,desc.face_indices,hull.edges,hull.face_edges) || !hull_finish(hull) {
        hull_free(hull,allocator)
        return false
    }
    if convex_radius>0 && !hull_core_build(hull,convex_radius,allocator) {
        hull_free(hull,allocator)
        return false
    }
    return true
}

// The intersection of the planes of the hull moved in by the radius. Its vertices are the faces of the hull of
// the dual points n/(d-radius-n·center), and its faces come from the hull of those vertices.
@(private)
hull_core_build :: proc(hull:^Hull,radius:f32,allocator:mem.Allocator) -> bool {
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    if !(radius<hull.inner_radius) {return false}
    dual:=make([]Vec3,len(hull.planes),context.temp_allocator)
    for plane,i in hull.planes {
        height:=plane.d-radius-dot(plane.n,hull.center)
        if !(height>1e-6*hull.inner_radius) {return false}
        dual[i]=plane.n/height
    }
    faces,dual_error:=geom.hull_build(dual,{},context.temp_allocator)
    if dual_error!=.None || geom.hull_is_flat(faces) {return false}
    corners:=make([]Vec3,len(faces.planes),context.temp_allocator)
    for plane,i in faces.planes {
        if !(plane.d>0) {return false}
        corners[i]=hull.center+plane.normal/plane.d
    }
    built,error:=geom.hull_build(corners,{},context.temp_allocator)
    if error!=.None || geom.hull_is_flat(built) || len(built.vertices)>HULL_MAX_VERTICES || len(built.faces)>HULL_MAX_FACES || len(built.face_vertices)>HULL_MAX_HALF_EDGES {return false}
    counts:=make([]u8,len(built.faces),context.temp_allocator)
    indices:=make([]u8,len(built.face_vertices),context.temp_allocator)
    for face,i in built.faces {
        if face.vertex_count>255 {return false}
        counts[i]=u8(face.vertex_count)
    }
    for vertex,i in built.face_vertices {indices[i]=u8(vertex)}
    core,core_error:=new(Hull,allocator)
    if core_error!=nil {return false}
    if !hull_init(core,{built.vertices,counts,indices},allocator) {
        free(core,allocator)
        return false
    }
    hull.core,hull.convex_radius=core,radius
    return true
}

hull_free :: proc(hull:^Hull,allocator:mem.Allocator) {
    delete(hull.vertices,allocator);delete(hull.planes,allocator)
    delete(hull.face_edges,allocator);delete(hull.edges,allocator)
    if hull.core!=nil {
        hull_free(hull.core,allocator)
        free(hull.core,allocator)
    }
    hull^={}
}

// What collisions see of a hull: its core, or the hull itself without a convex radius.
@(private)
hull_core :: #force_inline proc "contextless" (hull:^Hull) -> ^Hull {return hull.core!=nil?hull.core:hull}

@(private) hull_proxy :: #force_inline proc "contextless" (hull:^Hull) -> Proxy {return {hull.vertices,0,0}}

@(private)
hull_support :: proc "contextless" (hull:^Hull,direction:Vec3) -> int #no_bounds_check {
    best:=0
    best_value:=dot(hull.vertices[0],direction)
    for i in 1..<len(hull.vertices) {
        value:=dot(hull.vertices[i],direction)
        if value>best_value {best_value=value;best=i}
    }
    return best
}

// Box vertex i has +x for bit 0, +y for bit 1, +z for bit 2. Faces: -x,+x,-y,+y,-z,+z.
BOX_FACE_COUNTS :: [6]u8{4,4,4,4,4,4}
BOX_FACE_INDICES :: [24]u8{0,4,6,2, 1,3,7,5, 0,1,5,4, 2,6,7,3, 0,2,3,1, 4,5,7,6}

@(private,rodata) BOX_EDGES:=[24]Half_Edge{
    {2,0,0},{16,4,2},{4,4,0},{19,6,5},{6,6,0},{20,2,3},{0,2,0},{23,0,4},
    {10,1,1},{17,3,4},{12,3,1},{22,7,3},{14,7,1},{21,5,5},{8,5,1},{18,1,2},
    {15,0,2},{7,1,4},{1,5,2},{13,4,5},{11,6,3},{3,7,5},{5,3,3},{9,2,4},
}
@(private,rodata) BOX_FACE_EDGES:=[6]u16{0,8,16,5,7,19}

// Storage of a box seen as a hull, built per use on the stack.
Box_Hull :: struct {vertices:[8]Vec3,planes:[6]Plane}

@(private)
box_hull :: proc "contextless" (storage:^Box_Hull,half:Vec3) -> Hull #no_bounds_check {
    for i in 0..<8 {
        storage.vertices[i]={i&1!=0?half.x:-half.x,i&2!=0?half.y:-half.y,i&4!=0?half.z:-half.z}
    }
    storage.planes={{{-1,0,0},half.x},{{1,0,0},half.x},{{0,-1,0},half.y},{{0,1,0},half.y},{{0,0,-1},half.z},{{0,0,1},half.z}}
    return {
        vertices=storage.vertices[:],planes=storage.planes[:],face_edges=BOX_FACE_EDGES[:],edges=BOX_EDGES[:],
        volume=8*half.x*half.y*half.z,aabb={-half,half},inner_radius=min(half.x,half.y,half.z),
    }
}

// Triangle seen as a two-sided hull: face 0 is the front (a,b,c counter-clockwise), face 1 the back.
@(private,rodata) TRIANGLE_EDGES:=[6]Half_Edge{{2,0,0},{5,1,1},{4,1,0},{1,2,1},{0,2,0},{3,0,1}}
@(private,rodata) TRIANGLE_FACE_EDGES:=[2]u16{0,5}

Triangle_Hull :: struct {vertices:[3]Vec3,planes:[2]Plane}

@(private)
triangle_hull :: proc "contextless" (storage:^Triangle_Hull,a,b,c:Vec3) -> Hull #no_bounds_check {
    storage.vertices={a,b,c}
    n:=normalize(cross(b-a,c-a))
    storage.planes={{n,dot(n,a)},{-n,-dot(n,a)}}
    return {
        vertices=storage.vertices[:],planes=storage.planes[:],face_edges=TRIANGLE_FACE_EDGES[:],edges=TRIANGLE_EDGES[:],
        center=(a+b+c)/3,aabb={vmin(a,vmin(b,c)),vmax(a,vmax(b,c))},
    }
}
