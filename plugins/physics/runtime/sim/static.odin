package mirai_physics

import cmath "core:math"
import "mirai:std/spatial"
import math "mirai:std/math"

// Segments around the axis of a sphere, capsule or cylinder in shapes_triangles, and bands of latitude in a
// quarter turn of a sphere or of the end of a capsule: steps of 22.5 degrees both ways. The vertices lie on
// the surface and the facets fall inside it by at most radius*(1-cos(PI/TRIANGLE_SEGMENTS)), 2% of the
// radius; flat caps and sides are exact.
TRIANGLE_SEGMENTS :: 16
TRIANGLE_BANDS :: 4

// Where static collision changed: a ring of world boxes and how many were ever written. Scratch outside
// snapshots and hashes: nothing in the simulation reads it.
@(private)
Static_Log :: struct {
    boxes:[]Aabb,
    head:u64,  // changes written: the cursor of the next one
    floor:u64, // a cursor below it missed boxes the ring no longer holds
}

@(private)
static_log_push :: proc "contextless" (w:^World,box:Aabb) {
    log:=&w.static_log
    capacity:=u64(len(log.boxes))
    if capacity>0 {log.boxes[log.head%capacity]=box}
    log.head+=1
    if log.head>capacity {log.floor=max(log.floor,log.head-capacity)}
}

// One change with the boxes of every shape of the body.
@(private)
static_log_body :: proc "contextless" (w:^World,index:i32) {
    body:=&w.bodies[index]
    if body.shape_list<0 {return}
    box:=w.shapes[body.shape_list].aabb
    for s:=w.shapes[body.shape_list].next;s>=0;s=w.shapes[s].next {box=math.aabb_merge(box,w.shapes[s].aabb)}
    static_log_push(w,box)
}

// Anything may have changed: every cursor falls behind.
@(private)
static_log_restart :: proc "contextless" (w:^World) {
    log:=&w.static_log
    log.head+=1
    log.floor=log.head
}

// Reads into `out`, oldest first, the world boxes where static collision changed from cursor `since` on, and
// returns the cursor to read from next. Each reader keeps its own cursor, zero at first; a read that fills
// `out` leaves the rest for the next call.
// A change is a shape made or destroyed on a static body, a static body moved, destroyed or turned to or
// from static, or the filter of a static shape changed; one of a body is one box around all its shapes. A
// fluid made, changed or destroyed is the box it covers, which for a plane is everything under it.
// overflow, writing nothing and with next at the newest change: the reader fell behind more than
// World_Desc.static_change_capacity changes, its cursor is not one of this log, or a snapshot was restored
// since. It takes everything as changed.
static_changes :: proc(w:^World,since:u64,out:[]Aabb) -> (next:u64,count:int,overflow:bool) {
    log:=&w.static_log
    if since<log.floor || since>log.head {return log.head,0,true}
    count=int(min(log.head-since,u64(len(out))))
    for i in 0..<count {out[i]=log.boxes[(since+u64(i))%u64(len(log.boxes))]}
    return since+u64(count),count,false
}

// Builds the tree of the static shapes again, whole, once the shapes inserted or moved in it since its last
// build reach half of it: a load, whose shapes go in one at a time, costs about two builds, and a change now
// and then only its insertion. Between steps: a transaction that may allocate when it builds. False, with the
// tree as it was, without memory.
world_rebuild_static :: proc(w:^World) -> bool {
    tree:=&w.trees[STATIC_TREE]
    return 2*tree.placed<tree.proxy_count || spatial.dynamic_tree_rebuild(tree)
}

// Writes into the caller buffers, without allocating, the world triangles of the shapes of static bodies
// whose boxes overlap `box` and that block `filter`: what a query with it would be blocked by, never a
// sensor (a shape that blocks no layer) nor a shape it only overlaps. Three indices per triangle into
// `vertices`, counter-clockwise seen from outside, or from the side a mesh or heightfield collides from;
// `shapes`, when not empty, takes the shape of each triangle.
// - Boxes and hulls: their faces, fanned; with their size, without the rounding of a convex radius.
// - Spheres, capsules and cylinders: tessellated by TRIANGLE_SEGMENTS and TRIANGLE_BANDS.
// - Meshes: the triangles whose boxes overlap `box`. Heightfields: the cells whose boxes overlap it, without
//   holes, split along the diagonal of the model.
// The shapes come whole, the triangles of a mesh and the cells of a heightfield one by one. complete is
// false when the next did not fit: what was written stays. It only reads the world.
shapes_triangles :: proc(w:^World,box:Aabb,vertices:[]Vec3,indices:[]u32,filter:=QUERY_FILTER_DEFAULT,shapes:[]Shape_Handle=nil) -> (vertex_count,index_count:int,complete:bool) {
    out:=Triangle_Out{vertices=vertices,indices=indices,shapes=shapes}
    complete=true
    if spatial.aabb_valid(box) {
        query:=spatial.dynamic_tree_query(&w.trees[STATIC_TREE],box)
        for _,user in spatial.tree_query_next(&query) {
            shape:=&w.shapes[user]
            if shape.filter.block==0 || query_response(w,shape,filter)!=.Block || !math.aabb_overlaps(shape.aabb,box) {continue}
            out.shape=shape_handle(w,i32(user))
            if !shape_triangles(w,&out,shape,box) {
                complete=false
                break
            }
        }
    }
    return out.vertex_count,out.index_count,complete
}

@(private)
Triangle_Out :: struct {
    vertices:[]Vec3,
    indices:[]u32,
    shapes:[]Shape_Handle,
    vertex_count,index_count:int,
    shape:Shape_Handle,
}

@(private)
triangles_fit :: #force_inline proc "contextless" (out:^Triangle_Out,vertices,triangles:int) -> bool {
    return out.vertex_count+vertices<=len(out.vertices) && out.index_count+3*triangles<=len(out.indices) &&
        (len(out.shapes)==0 || out.index_count/3+triangles<=len(out.shapes))
}

@(private)
vertex_add :: #force_inline proc "contextless" (out:^Triangle_Out,p:Vec3) #no_bounds_check {
    out.vertices[out.vertex_count]=p
    out.vertex_count+=1
}

@(private)
triangle_add :: #force_inline proc "contextless" (out:^Triangle_Out,a,b,c:u32) #no_bounds_check {
    out.indices[out.index_count],out.indices[out.index_count+1],out.indices[out.index_count+2]=a,b,c
    if len(out.shapes)>0 {out.shapes[out.index_count/3]=out.shape}
    out.index_count+=3
}

// False when the shape, or the next triangle of a mesh or cell of a heightfield, does not fit.
@(private)
shape_triangles :: proc(w:^World,out:^Triangle_Out,shape:^Shape,box:Aabb) -> bool {
    xf:=shape_transform_of(w,shape)
    profile:[2*TRIANGLE_BANDS+2][2]f32
    count:=0
    switch shape.type {
    case .Sphere:
        for band in 0..=2*TRIANGLE_BANDS {profile[count]=profile_arc(shape.size.x,0,band);count+=1}
        return lathe_triangles(out,profile[:count],xf)
    case .Capsule:
        r,h:=shape.size.x,shape.size.y
        for band in 0..=TRIANGLE_BANDS {profile[count]=profile_arc(r,-h,band);count+=1}
        for band in TRIANGLE_BANDS..=2*TRIANGLE_BANDS {profile[count]=profile_arc(r,h,band);count+=1}
        return lathe_triangles(out,profile[:count],xf)
    case .Cylinder:
        r,h:=shape.size.x,shape.size.y
        profile[0],profile[1],profile[2],profile[3]={0,-h},{r,-h},{r,h},{0,h}
        return lathe_triangles(out,profile[:4],xf)
    case .Box:
        storage:Box_Hull=---
        hull:=box_hull(&storage,shape.size)
        return hull_triangles(out,&hull,xf)
    case .Hull:
        return hull_triangles(out,&w.hulls[shape.resource].hull,xf)
    case .Mesh:
        return mesh_triangles(out,&w.meshes[shape.resource].mesh,xf,box)
    case .Heightfield:
        return heightfield_triangles(out,&w.heightfields[shape.resource].field,xf,box)
    }
    return true
}

// (radius,height) of an arc of `radius` about `center` on the Y axis, `band` bands up from its bottom pole.
@(private)
profile_arc :: proc "contextless" (radius,center:f32,band:int) -> [2]f32 {
    if band<=0 {return {0,center-radius}}
    if band>=2*TRIANGLE_BANDS {return {0,center+radius}}
    angle:=0.5*PI*f32(band-TRIANGLE_BANDS)/TRIANGLE_BANDS
    return {radius*cmath.cos(angle),center+radius*cmath.sin(angle)}
}

// The surface that a profile of (radius,height) points, from bottom to top, sweeps about the local Y axis
// at xf; a point of zero radius is a pole. Writes nothing when it does not fit.
@(private)
lathe_triangles :: proc "contextless" (out:^Triangle_Out,profile:[][2]f32,xf:Transform) -> bool #no_bounds_check {
    S :: TRIANGLE_SEGMENTS
    vertices,triangles:=0,0
    for p,i in profile {
        vertices+=p[0]>0?S:1
        if i>0 {triangles+=(profile[i-1][0]>0?S:0)+(p[0]>0?S:0)}
    }
    if !triangles_fit(out,vertices,triangles) {return false}
    turn:[S][2]f32
    for k in 0..<S {
        angle:=2*PI*f32(k)/S
        turn[k]={cmath.cos(angle),-cmath.sin(angle)}
    }
    previous:u32
    for p,i in profile {
        first:=u32(out.vertex_count)
        if p[0]>0 {
            for k in 0..<S {vertex_add(out,xf_point(xf,{p[0]*turn[k][0],p[1],p[0]*turn[k][1]}))}
        } else {
            vertex_add(out,xf_point(xf,{0,p[1],0}))
        }
        if i>0 {
            low,high:=profile[i-1][0]>0,p[0]>0
            for k in 0..<u32(S) {
                k1:=(k+1)%S
                a,b:=previous+(low?k:0),previous+(low?k1:0)
                c,d:=first+(high?k1:0),first+(high?k:0)
                if low {triangle_add(out,a,b,c)}
                if high {triangle_add(out,a,c,d)}
            }
        }
        previous=first
    }
    return true
}

// The faces of a hull at xf, each fanned from its first vertex. Writes nothing when they do not fit.
@(private)
hull_triangles :: proc "contextless" (out:^Triangle_Out,hull:^Hull,xf:Transform) -> bool #no_bounds_check {
    // Every half edge is on one face: a face of n edges gives n-2 triangles.
    if !triangles_fit(out,len(hull.vertices),len(hull.edges)-2*len(hull.face_edges)) {return false}
    first:=u32(out.vertex_count)
    for v in hull.vertices {vertex_add(out,xf_point(xf,v))}
    for start in hull.face_edges {
        origin:=first+u32(hull.edges[start].origin)
        for e:=hull.edges[start].next;hull.edges[e].next!=start;e=hull.edges[e].next {
            triangle_add(out,origin,first+u32(hull.edges[e].origin),first+u32(hull.edges[hull.edges[e].next].origin))
        }
    }
    return true
}

// The box, in the frame xf, around a world box.
@(private)
box_in_frame :: proc "contextless" (xf:Transform,box:Aabb) -> Aabb {
    m:=q_matrix(conj(xf.q))
    e:=0.5*box.max-0.5*box.min
    c:=xf_inv_point(xf,0.5*box.max+0.5*box.min)
    d:=vabs(Vec3{m[0,0],m[1,0],m[2,0]})*e.x+vabs(Vec3{m[0,1],m[1,1],m[2,1]})*e.y+vabs(Vec3{m[0,2],m[1,2],m[2,2]})*e.z
    return {c-d,c+d}
}

@(private)
triangle_box :: #force_inline proc "contextless" (a,b,c:Vec3) -> Aabb {return {vmin(vmin(a,b),c),vmax(vmax(a,b),c)}}

@(private)
mesh_triangles :: proc(out:^Triangle_Out,mesh:^Mesh,xf:Transform,box:Aabb) -> bool #no_bounds_check {
    query:=spatial.bvh_query(&mesh.bvh,box_in_frame(xf,box))
    for leaf in spatial.bvh_query_next(&query) {
        for index in leaf {
            t:=mesh.triangles[index]
            a,b,c:=xf_point(xf,mesh.vertices[t[0]]),xf_point(xf,mesh.vertices[t[1]]),xf_point(xf,mesh.vertices[t[2]])
            if !math.aabb_overlaps(triangle_box(a,b,c),box) {continue}
            if !triangles_fit(out,3,1) {return false}
            first:=u32(out.vertex_count)
            vertex_add(out,a);vertex_add(out,b);vertex_add(out,c)
            triangle_add(out,first,first+1,first+2)
        }
    }
    return true
}

@(private)
heightfield_triangles :: proc "contextless" (out:^Triangle_Out,field:^Heightfield,xf:Transform,box:Aabb) -> bool #no_bounds_check {
    local:=box_in_frame(xf,box)
    if !math.aabb_overlaps(local,field.aabb) {return true}
    // Inside the field the cell indices stay in range for a box of any size.
    column0,column1,row0,row1,ok:=heightfield_cells(field,{vmax(local.min,field.aabb.min),vmin(local.max,field.aabb.max)})
    if !ok {return true}
    for row in row0..=row1 {
        for column in column0..=column1 {
            if heightfield_hole(field,column,row) {continue}
            p00,p01:=xf_point(xf,heightfield_point(field,column,row)),xf_point(xf,heightfield_point(field,column,row+1))
            p10,p11:=xf_point(xf,heightfield_point(field,column+1,row)),xf_point(xf,heightfield_point(field,column+1,row+1))
            if !math.aabb_overlaps(math.aabb_merge(triangle_box(p00,p01,p10),{p11,p11}),box) {continue}
            if !triangles_fit(out,4,2) {return false}
            first:=u32(out.vertex_count)
            vertex_add(out,p00);vertex_add(out,p01);vertex_add(out,p10);vertex_add(out,p11)
            triangle_add(out,first,first+1,first+2)
            triangle_add(out,first+2,first+1,first+3)
        }
    }
    return true
}

// The box around every static shape, as the broad phase holds it (with its margin); false without any.
static_bounds :: proc "contextless" (w:^World) -> (box:Aabb,ok:bool) {
    tree:=&w.trees[STATIC_TREE]
    if tree.root==spatial.NULL_NODE || int(tree.root)>=len(tree.nodes) {return}
    return tree.nodes[tree.root].aabb,true
}
