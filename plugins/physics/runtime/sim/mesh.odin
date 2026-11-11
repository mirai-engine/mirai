package mirai_physics

import cmath "core:math"
import "core:mem"
import "core:slice"
import "mirai:std/base"
import "mirai:std/spatial"
import math "mirai:std/math"

// Static triangle mesh. Triangles are one-sided: counter-clockwise seen from the side that collides.
Mesh :: struct {
    vertices:[]Vec3,
    triangles:[][3]u32,
    flags:[]u8, // bit i: the edge from vertex i to the next can be hit; flat and concave inner edges cannot
    bvh:spatial.Bvh,
    aabb:Aabb,
}
Mesh_Desc :: struct {
    vertices:[]Vec3,
    indices:[]u32,
    disabled_edges:[]u8, // per input triangle: bits 0,1,2 disable its ordered edges
    // The vertices were mirrored (scaled by an odd number of negative axes): each triangle turns the other
    // way, so it still collides from the side it faced.
    inside_out:bool,
}

// Grid of heights over the local XZ plane. Sample (column,row) is at (column*cell.x, height*cell.y, row*cell.z).
// Every cell is split along the diagonal that joins (column+1,row) and (column,row+1).
Heightfield :: struct {
    heights:[]f32,
    columns,rows:int,
    cell:Vec3,
    aabb:Aabb,
    disabled_borders:[]u8, // MinX, MaxX (rows-1 each), MinZ, MaxZ (columns-1 each); bytes 0 or 1
    holes:[]u8,            // one per cell, row after row, or none: 1 where the cell has no surface
}
Heightfield_Desc :: struct {heights:[]f32,columns,rows:int,cell:Vec3,disabled_borders:[]u8,holes:[]u8}

// An inner edge can be hit only where the surface folds down by more than this sine.
@(private) ACTIVE_EDGE_SINE :: 0.05

// The reference triangle has a unit normal and distinct edge endpoints.
mesh_edge_active :: proc "contextless" (normal,a,b,opposite:Vec3) -> bool {
    edge:=normalize(b-a)
    offset:=opposite-a
    across:=offset-edge*dot(offset,edge)
    return dot(normal,offset)< -ACTIVE_EDGE_SINE*length(across)
}

// Builds a mesh outside any world, as mesh_create does inside one: for whoever keeps it and gives a copy
// to every world that needs it. False on the descriptions mesh_create refuses.
mesh_build :: proc(mesh:^Mesh,desc:Mesh_Desc,allocator:mem.Allocator) -> bool {
    mesh^={}
    count:=len(desc.indices)/3
    if count==0 || len(desc.indices)%3!=0 || len(desc.vertices)<3 {return false}
    if len(desc.disabled_edges)!=0 && len(desc.disabled_edges)!=count {return false}
    for mask in desc.disabled_edges {if mask&~u8(0b111)!=0 {return false}}
    for index in desc.indices {
        if int(index)>=len(desc.vertices) {return false}
    }
    for v in desc.vertices {
        if !finite(v) {return false}
    }
    indices,disabled,count_kept:=mesh_sanitize(desc,allocator)
    defer delete(indices,allocator)
    defer delete(disabled,allocator)
    count=count_kept
    if count==0 {return false}
    error:mem.Allocator_Error
    if mesh.vertices,error=make([]Vec3,len(desc.vertices),allocator);error!=nil {return false}
    if mesh.triangles,error=make([][3]u32,count,allocator);error!=nil {mesh_release(mesh,allocator);return false}
    if mesh.flags,error=make([]u8,count,allocator);error!=nil {mesh_release(mesh,allocator);return false}
    copy(mesh.vertices,desc.vertices)
    if !spatial.bvh_build_triangles(&mesh.bvh,desc.vertices,indices,{allocator=allocator}) {mesh_release(mesh,allocator);return false}
    // Triangles are stored in leaf order, so a leaf is a contiguous range.
    for original,i in mesh.bvh.order {
        mesh.triangles[i]={indices[3*original],indices[3*original+1],indices[3*original+2]}
    }
    mesh.aabb=spatial.bvh_bounds(&mesh.bvh)
    // Pair the edges to tell which inner edges fold down enough to be hit.
    Edge :: struct {key:u64,triangle:u32,edge:u32}
    edges,edge_error:=make([]Edge,3*count,allocator)
    if edge_error!=nil {mesh_release(mesh,allocator);return false}
    defer delete(edges,allocator)
    for triangle,i in mesh.triangles {
        for e in 0..<3 {
            a,b:=triangle[e],triangle[(e+1)%3]
            edges[3*i+e]={u64(min(a,b))<<32|u64(max(a,b)),u32(i),u32(e)}
        }
    }
    slice.sort_by(edges,proc(x,y:Edge) -> bool {return x.key<y.key || (x.key==y.key && (x.triangle<y.triangle || (x.triangle==y.triangle && x.edge<y.edge)))})
    for first:=0;first<len(edges); {
        last:=first+1
        for last<len(edges) && edges[last].key==edges[first].key {last+=1}
        if last-first!=2 {
            for edge in edges[first:last] {mesh.flags[edge.triangle]|=1<<edge.edge}
        } else {
            for pair in ([2][2]Edge{{edges[first],edges[first+1]},{edges[first+1],edges[first]}}) {
                triangle:=mesh.triangles[pair[0].triangle]
                other:=mesh.triangles[pair[1].triangle]
                a,b,c:=mesh.vertices[triangle[0]],mesh.vertices[triangle[1]],mesh.vertices[triangle[2]]
                normal:=normalize(cross(b-a,c-a))
                opposite:=mesh.vertices[other[(pair[1].edge+2)%3]]
                e:=pair[0].edge
                if mesh_edge_active(normal,mesh.vertices[triangle[e]],mesh.vertices[triangle[(e+1)%3]],opposite) {
                    mesh.flags[pair[0].triangle]|=1<<e
                }
            }
        }
        first=last
    }
    for original,i in mesh.bvh.order {
        if len(disabled)>0 {mesh.flags[i]&=~disabled[original]}
        mesh.bvh.order[i]=u32(i)
    }
    return true
}

// The triangles of a mesh that collide, in their input order, each turned as the mesh is and with its disabled
// edges: those with area and the first of each repeat (the same corners in the same turn), as Jolt's
// MeshShapeSettings::Sanitize keeps. A sliver along an edge would switch the edge off, and a repeat would
// switch on every edge it shares. Empty when out of memory.
@(private)
mesh_sanitize :: proc(desc:Mesh_Desc,allocator:mem.Allocator) -> (indices:[]u32,disabled:[]u8,count:int) {
    corners_of :: proc "contextless" (desc:Mesh_Desc,triangle:int) -> [3]u32 {
        t:=[3]u32{desc.indices[3*triangle],desc.indices[3*triangle+1],desc.indices[3*triangle+2]}
        if desc.inside_out {t[1],t[2]=t[2],t[1]}
        return t
    }
    Corners :: struct {key:[3]u32,triangle:int}
    corners,error:=make([]Corners,len(desc.indices)/3,allocator)
    if error!=nil {return}
    defer delete(corners,allocator)
    for i in 0..<len(corners) {
        t:=corners_of(desc,i)
        a,b,c:=desc.vertices[t[0]],desc.vertices[t[1]],desc.vertices[t[2]]
        n:=cross(b-a,c-a)
        // Its height over its longest edge below 1e-6: Jolt's |n|^2 <= 1e-12, at any size.
        longest:=max(dot(b-a,b-a),dot(c-b,c-b),dot(a-c,a-c))
        if !(dot(n,n)>1e-12*longest*longest) {continue}
        first:=t[0]<t[1]?(t[0]<t[2]?0:2):(t[1]<t[2]?1:2)
        corners[count]={{t[first],t[(first+1)%3],t[(first+2)%3]},i}
        count+=1
    }
    slice.sort_by(corners[:count],proc(x,y:Corners) -> bool {
        for k in 0..<3 {if x.key[k]!=y.key[k] {return x.key[k]<y.key[k]}}
        return x.triangle<y.triangle
    })
    unique:=0
    for c,at in corners[:count] {
        if at>0 && c.key==corners[at-1].key {continue}
        corners[unique]=c
        unique+=1
    }
    count=unique
    slice.sort_by(corners[:count],proc(x,y:Corners) -> bool {return x.triangle<y.triangle})
    if indices,error=make([]u32,3*count,allocator);error!=nil {return nil,nil,0}
    if len(desc.disabled_edges)>0 {
        if disabled,error=make([]u8,count,allocator);error!=nil {delete(indices,allocator);return nil,nil,0}
    }
    for c,at in corners[:count] {
        t:=corners_of(desc,c.triangle)
        copy(indices[3*at:],t[:])
        if len(disabled)==0 {continue}
        mask:=desc.disabled_edges[c.triangle]
        // Turned, its edge 0 is the old edge 2 and its edge 2 the old edge 0.
        if desc.inside_out {mask=mask&0b010|mask>>2&1|(mask&1)<<2}
        disabled[at]=mask
    }
    return
}

// Frees what mesh_build made, with the allocator it was given.
mesh_release :: proc(mesh:^Mesh,allocator:mem.Allocator) {
    delete(mesh.vertices,allocator);delete(mesh.triangles,allocator);delete(mesh.flags,allocator)
    spatial.bvh_destroy(&mesh.bvh)
    mesh^={}
}

// Registers a triangle mesh that shapes can share. Allocates and builds a BVH: do it when loading.
mesh_create :: proc(w:^World,desc:Mesh_Desc) -> (Mesh_Handle,bool) {
    for &slot,index in w.meshes {
        if slot.generation&1!=0 {continue}
        if !mesh_build(&slot.mesh,desc,w.allocator) {return {},false}
        slot.generation+=1
        slot.refs=0
        return Mesh_Handle(base.handle_make(u32(index),slot.generation)),true
    }
    w.stats.geometry_capacity_exhausted+=1
    return {},false
}

// Registers a copy of a built mesh: nothing is computed again, its triangles
// and its tree are copied. The source is not kept.
mesh_create_copy :: proc(w:^World,source:^Mesh) -> (Mesh_Handle,bool) {
    if len(source.triangles)==0 || len(source.bvh.nodes)==0 {return {},false}
    for &slot,index in w.meshes {
        if slot.generation&1!=0 {continue}
        mesh:=&slot.mesh
        mesh^={aabb=source.aabb}
        errors:[5]mem.Allocator_Error
        mesh.vertices,errors[0]=make([]Vec3,len(source.vertices),w.allocator)
        mesh.triangles,errors[1]=make([][3]u32,len(source.triangles),w.allocator)
        mesh.flags,errors[2]=make([]u8,len(source.flags),w.allocator)
        mesh.bvh.nodes,errors[3]=mem.make_aligned([]spatial.Bvh_Node,len(source.bvh.nodes),64,w.allocator)
        mesh.bvh.order,errors[4]=make([]u32,len(source.bvh.order),w.allocator)
        mesh.bvh.allocator=w.allocator
        for error in errors {
            if error!=nil {mesh_release(mesh,w.allocator);return {},false}
        }
        copy(mesh.vertices,source.vertices);copy(mesh.triangles,source.triangles);copy(mesh.flags,source.flags)
        copy(mesh.bvh.nodes,source.bvh.nodes);copy(mesh.bvh.order,source.bvh.order)
        slot.generation+=1
        slot.refs=0
        return Mesh_Handle(base.handle_make(u32(index),slot.generation)),true
    }
    w.stats.geometry_capacity_exhausted+=1
    return {},false
}

// Fails while a shape uses the mesh.
mesh_destroy :: proc(w:^World,h:Mesh_Handle) -> bool {
    slot,_:=mesh_slot(w,h)
    if slot==nil || slot.refs>0 {return false}
    mesh_release(&slot.mesh,w.allocator)
    slot.generation+=1
    return true
}

// Borrowed immutable geometry, valid until the handle is destroyed.
mesh_geometry :: proc(w:^World,h:Mesh_Handle) -> ^Mesh {
    slot,_:=mesh_slot(w,h)
    return slot!=nil?&slot.mesh:nil
}

heightfield_geometry :: proc(w:^World,h:Heightfield_Handle) -> ^Heightfield {
    slot,_:=heightfield_slot(w,h)
    return slot!=nil?&slot.field:nil
}

@(private)
heightfield_free :: proc(field:^Heightfield,allocator:mem.Allocator) {
    delete(field.heights,allocator)
    delete(field.disabled_borders,allocator)
    delete(field.holes,allocator)
    field^={}
}

// Registers a heightfield that shapes can share. `heights` has columns*rows samples, row after row.
heightfield_create :: proc(w:^World,desc:Heightfield_Desc) -> (Heightfield_Handle,bool) {
    if desc.columns<2 || desc.rows<2 || desc.columns>max(int)/desc.rows || len(desc.heights)!=desc.columns*desc.rows {return {},false}
    if len(desc.disabled_borders)>0 {
        if desc.columns-1>max(int)/2-(desc.rows-1) || len(desc.disabled_borders)!=2*(desc.rows-1)+2*(desc.columns-1) {return {},false}
        for flag in desc.disabled_borders {if flag>1 {return {},false}}
    }
    if len(desc.holes)>0 {
        if len(desc.holes)!=(desc.columns-1)*(desc.rows-1) {return {},false}
        for hole in desc.holes {if hole>1 {return {},false}}
    }
    if !(desc.cell.x>0 && desc.cell.y>0 && desc.cell.z>0) || !finite(desc.cell) {return {},false}
    extent:=Vec3{f32(desc.columns-1)*desc.cell.x,0,f32(desc.rows-1)*desc.cell.z}
    if !finite(extent) {return {},false}
    for &slot,index in w.heightfields {
        if slot.generation&1!=0 {continue}
        heights,error:=make([]f32,len(desc.heights),w.allocator)
        if error!=nil {return {},false}
        copy(heights,desc.heights)
        borders,borders_error:=make([]u8,len(desc.disabled_borders),w.allocator)
        if borders_error!=nil {delete(heights,w.allocator);return {},false}
        copy(borders,desc.disabled_borders)
        holes,holes_error:=make([]u8,len(desc.holes),w.allocator)
        if holes_error!=nil {delete(heights,w.allocator);delete(borders,w.allocator);return {},false}
        copy(holes,desc.holes)
        low,high:=max(f32),min(f32)
        for h in heights {
            height:=h*desc.cell.y
            if height-height!=0 {delete(heights,w.allocator);delete(borders,w.allocator);delete(holes,w.allocator);return {},false}
            low,high=min(low,height),max(high,height)
        }
        slot.field={heights,desc.columns,desc.rows,desc.cell,{{0,low,0},{extent.x,high,extent.z}},borders,holes}
        slot.generation+=1
        slot.refs=0
        return Heightfield_Handle(base.handle_make(u32(index),slot.generation)),true
    }
    w.stats.geometry_capacity_exhausted+=1
    return {},false
}
// Fails while a shape uses the heightfield.
heightfield_destroy :: proc(w:^World,h:Heightfield_Handle) -> bool {
    slot,_:=heightfield_slot(w,h)
    if slot==nil || slot.refs>0 {return false}
    heightfield_free(&slot.field,w.allocator)
    slot.generation+=1
    return true
}

@(private)
heightfield_point :: #force_inline proc "contextless" (field:^Heightfield,column,row:int) -> Vec3 {
    return {f32(column)*field.cell.x,field.heights[row*field.columns+column]*field.cell.y,f32(row)*field.cell.z}
}

// Whether a cell has no surface; a cell outside the field has none either.
heightfield_hole :: #force_inline proc "contextless" (field:^Heightfield,column,row:int) -> bool #no_bounds_check {
    if column<0 || row<0 || column>=field.columns-1 || row>=field.rows-1 {return true}
    return len(field.holes)>0 && field.holes[row*(field.columns-1)+column]!=0
}

// The two triangles of a cell with the flags of their edges; open false for
// a hole. An edge next to a hole is a border: it can always be hit.
@(private)
heightfield_cell :: proc "contextless" (field:^Heightfield,column,row:int) -> (triangles:[2][3]Vec3,flags:[2]u8,open:bool) #no_bounds_check {
    if len(field.holes)>0 && field.holes[row*(field.columns-1)+column]!=0 {return}
    open=true
    p00,p10:=heightfield_point(field,column,row),heightfield_point(field,column+1,row)
    p01,p11:=heightfield_point(field,column,row+1),heightfield_point(field,column+1,row+1)
    triangles={{p00,p01,p10},{p10,p01,p11}}
    n0:=normalize(cross(p01-p00,p10-p00))
    n1:=normalize(cross(p01-p10,p11-p10))
    // Each outer edge is checked against the far vertex of the triangle across it; borders can always be hit.
    flags={0b111,0b111}
    if !mesh_edge_active(n0,p01,p10,p11) {flags[0]&=~u8(0b010)}
    if !mesh_edge_active(n1,p10,p01,p00) {flags[1]&=~u8(0b001)}
    if column>0 {
        if !heightfield_hole(field,column-1,row) && !mesh_edge_active(n0,p00,p01,heightfield_point(field,column-1,row+1)) {flags[0]&=~u8(0b001)}
    } else if len(field.disabled_borders)>0 && field.disabled_borders[row]!=0 {flags[0]&=~u8(0b001)}
    if row>0 {
        if !heightfield_hole(field,column,row-1) && !mesh_edge_active(n0,p10,p00,heightfield_point(field,column+1,row-1)) {flags[0]&=~u8(0b100)}
    } else if len(field.disabled_borders)>0 && field.disabled_borders[2*(field.rows-1)+column]!=0 {flags[0]&=~u8(0b100)}
    if row+2<field.rows {
        if !heightfield_hole(field,column,row+1) && !mesh_edge_active(n1,p01,p11,heightfield_point(field,column,row+2)) {flags[1]&=~u8(0b010)}
    } else if len(field.disabled_borders)>0 && field.disabled_borders[2*(field.rows-1)+(field.columns-1)+column]!=0 {flags[1]&=~u8(0b010)}
    if column+2<field.columns {
        if !heightfield_hole(field,column+1,row) && !mesh_edge_active(n1,p11,p10,heightfield_point(field,column+2,row)) {flags[1]&=~u8(0b100)}
    } else if len(field.disabled_borders)>0 && field.disabled_borders[field.rows-1+row]!=0 {flags[1]&=~u8(0b100)}
    return
}

@(private) CLUSTER_POINTS :: 24
@(private) Triangle_Cluster :: struct {normal:Vec3,deepest:f32,count:int,points:[CLUSTER_POINTS]Local_Point}
// Contact points of a convex shape against many triangles, grouped by normal. flat holds the contacts on
// edges that cannot be hit, taken on the plane of their face: a direction takes them only when no triangle
// gave it a contact of its own.
@(private) Triangle_Collector :: struct {clusters,flat:[1+EXTRA_MANIFOLDS]Triangle_Cluster,count,flat_count:int}

// A convex shape B against one triangle in the frame of the mesh. Contacts with the back of the triangle
// and with inner edges that cannot be hit are dropped: those would catch bodies sliding over a flat surface.
// `body` is the Convex of a box, hull or cylinder.
@(private)
triangle_collide :: proc(w:^World,collector:^Triangle_Collector,shape:^Shape,body:^Convex,xf:Transform,a,b,c:Vec3,flags:u8,index:u32,speculative:f32,bounds:Aabb) #no_bounds_check {
    storage:Triangle_Hull=---
    triangle:=triangle_hull(&storage,a,b,c)
    normal:=storage.planes[0].n
    if normal=={} {return}
    m:Local_Manifold=---
    #partial switch shape.type {
    case .Sphere:
        closest:=triangle_closest_point(a,b,c,xf.p)
        direction,distance:=normalize_length(xf.p-closest)
        separation:=distance-shape.size.x
        if separation>speculative {return}
        m.normal=distance>1e-6?direction:normal
        m.points[0]={closest+m.normal*(0.5*separation),separation,0}
        m.count=1
    case .Capsule:
        axis:=q_rotate(xf.q,Vec3{0,shape.size.y,0})
        collide_hull_capsule(&m,&triangle,xf.p-axis,xf.p+axis,shape.size.x,speculative)
    case .Box,.Hull:
        // A rounded shape collides as its core, inflated back.
        collide_hulls(&m,&triangle,&body.hull,xf,speculative+shape.radius)
        if shape.radius>0 {manifold_inflate(&m,0,shape.radius)}
    case .Cylinder:
        // Above its plane by more than the speculative distance, or behind it, or away from its nearest point:
        // no contact.
        axis:=q_rotate(xf.q,{0,1,0})
        h,r,round:=body.proxy.points[1].y,body.proxy.disc,body.proxy.radius
        reach:=cylinder_reach(axis,normal,h,r,round)
        height:=dot(xf.p-a,normal)
        separation:=height-reach
        if separation>speculative || height+reach<0 {return}
        if away,distance:=normalize_length(xf.p-triangle_closest_point(a,b,c,xf.p));distance-cylinder_reach(axis,away,h,r,round)>speculative {return}
        // Its lowest points over the face: the face is the nearest feature and the normal is its own.
        side:[CLIP_MAX]Vec3=---
        count,_:=convex_face(body,q_inv_rotate(xf.q,-normal),&side)
        for &p in side[:count] {p=xf_point(xf,p)}
        points:[CLIP_MAX]Local_Point=---
        if kept:=faces_clip(points[:],storage.vertices[:],normal,side[:count],normal,false,speculative);kept>0 {
            deepest:=max(f32)
            for point in points[:kept] {deepest=min(deepest,point.separation)}
            if deepest<=separation+0.1*LINEAR_SLOP {
                m.normal=normal
                manifold_reduce(&m,points[:],kept,speculative)
                break
            }
        }
        // GJK sees the part of the triangle in the box of the cylinder: it holds every point within the
        // speculative distance, and its small size keeps GJK precise.
        polygon:[9]Vec3=---
        polygon[0],polygon[1],polygon[2]=a,b,c
        corners:=polygon_clip_box(&polygon,3,bounds)
        if corners<3 {return}
        face:=Convex{proxy={polygon[:corners],0,0},hull=triangle,type=.Mesh}
        collide_convex(&m,&face,body,xf,speculative,true)
    case:
        return
    }
    if m.count==0 {return}
    facing:=dot(m.normal,normal)
    if facing<=0 {return}
    if facing<0.99999 {
        // The contact leans away from the face, so it is with an edge or a corner. If every edge it can
        // belong to is one that cannot be hit, the neighbor across it owns the contact; but where the
        // neighbor finds it on the same edge too, as over a ridge too flat to be hit, both would leave
        // it, so it is kept apart on the plane of the face (Triangle_Collector.flat). The feature is
        // where the contact meets the triangle, half the separation under the point: from the point,
        // the two edges of a corner are not equally near, and only the nearest one would count.
        point:=m.points[0].point-m.normal*(0.5*m.points[0].separation)
        vertices:=[3]Vec3{a,b,c}
        distances:[3]f32
        nearest:=max(f32)
        for e in 0..<3 {
            distances[e]=length2(point-segment_closest_point(vertices[e],vertices[(e+1)%3],point))
            nearest=min(nearest,distances[e])
        }
        active:=false
        for e in 0..<3 {
            if distances[e]<=nearest+LINEAR_SLOP*LINEAR_SLOP && flags&(1<<u32(e))!=0 {active=true}
        }
        if !active {
            for &p in m.points[:m.count] {
                on_body:=p.point+m.normal*(0.5*p.separation)
                separation:=dot(on_body-a,normal)
                p.point,p.separation=on_body-normal*(0.5*separation),separation
            }
            m.normal=normal
            for &p in m.points[:m.count] {p.id~=index*0x9e3779b1}
            cluster_add(collector.flat[:],&collector.flat_count,m.normal,m.points[:m.count])
            return
        }
    }
    for &p in m.points[:m.count] {p.id~=index*0x9e3779b1}
    cluster_add(collector.clusters[:],&collector.count,m.normal,m.points[:m.count])
}

// Points along a normal into the cluster of that direction.
@(private)
cluster_add :: proc "contextless" (clusters:[]Triangle_Cluster,count:^int,normal:Vec3,points:[]Local_Point) #no_bounds_check {
    deepest:=max(f32)
    for point in points {deepest=min(deepest,point.separation)}
    cluster:^Triangle_Cluster
    for &candidate in clusters[:count^] {
        if dot(candidate.normal,normal)>0.99 {cluster=&candidate;break}
    }
    if cluster==nil {
        if count^<len(clusters) {
            cluster=&clusters[count^]
            count^+=1
        } else {
            // No room for another direction: it replaces the shallowest one if it is deeper.
            shallowest:=&clusters[0]
            for &candidate in clusters[1:] {
                if candidate.deepest>shallowest.deepest {shallowest=&candidate}
            }
            if deepest>=shallowest.deepest {return}
            cluster=shallowest
        }
        cluster.normal=normal
        cluster.deepest=max(f32)
        cluster.count=0
    }
    if deepest<cluster.deepest {
        cluster.deepest=deepest
        cluster.normal=normal
    }
    for point in points {
        if cluster.count>=CLUSTER_POINTS {break}
        cluster.points[cluster.count]=point
        cluster.count+=1
    }
}

// Sutherland-Hodgman of a convex polygon in place against the six sides of a box.
@(private)
polygon_clip_box :: proc "contextless" (polygon:^[9]Vec3,count:int,box:Aabb) -> int #no_bounds_check {
    count:=count
    scratch:[9]Vec3=---
    for side in 0..<6 {
        axis:=side>>1
        sign:f32=side&1==0?-1:1
        limit:=side&1==0?-box.min[axis]:box.max[axis]
        kept:=0
        previous:=polygon[count-1]
        d1:=sign*previous[axis]-limit
        for i in 0..<count {
            current:=polygon[i]
            d2:=sign*current[axis]-limit
            if (d1<=0)!=(d2<=0) && kept<len(scratch) {
                scratch[kept]=previous+(current-previous)*(d1/(d1-d2))
                kept+=1
            }
            if d2<=0 && kept<len(scratch) {
                scratch[kept]=current
                kept+=1
            }
            previous,d1=current,d2
        }
        count=kept
        if count==0 {return 0}
        for i in 0..<count {polygon[i]=scratch[i]}
    }
    return count
}

// Deepest direction first: a contact that has room for one manifold keeps the one that matters most.
@(private)
collector_finish :: proc(collector:^Triangle_Collector,speculative:f32,out:^[1+EXTRA_MANIFOLDS]Local_Manifold) -> int #no_bounds_check {
    for &flat in collector.flat[:collector.flat_count] {
        owned:=false
        for cluster in collector.clusters[:collector.count] {owned||=dot(cluster.normal,flat.normal)>0.99}
        if !owned {cluster_add(collector.clusters[:],&collector.count,flat.normal,flat.points[:flat.count])}
    }
    clusters:=collector.clusters[:collector.count]
    for i in 1..<len(clusters) {
        for j:=i;j>0 && clusters[j].deepest<clusters[j-1].deepest;j-=1 {clusters[j],clusters[j-1]=clusters[j-1],clusters[j]}
    }
    count:=0
    for &cluster in clusters {
        out[count].normal=cluster.normal
        manifold_reduce(&out[count],cluster.points[:],cluster.count,speculative)
        if out[count].count>0 {count+=1}
    }
    return count
}

// Box of a convex shape placed at `xf`, in that frame.
@(private)
shape_aabb_at :: proc "contextless" (w:^World,shape:^Shape,xf:Transform) -> Aabb {
    return shape_aabb(w,shape,xf_mul(xf,xf_inv(shape.local)))
}

@(private)
mesh_collide :: proc(w:^World,mesh:^Mesh,shape:^Shape,xf:Transform,speculative:f32,out:^[1+EXTRA_MANIFOLDS]Local_Manifold) -> int #no_bounds_check {
    box:=math.aabb_expand(shape_aabb_at(w,shape,xf),speculative)
    storage:Box_Hull=---
    points:[8]Vec3=---
    body:Convex=---
    if shape.type>=.Box {body=convex_of(w,shape,&points,&storage)}
    collector:Triangle_Collector=---
    collector.count,collector.flat_count=0,0
    query:=spatial.bvh_query(&mesh.bvh,box)
    for leaf in spatial.bvh_query_next(&query) {
        for index in leaf {
            triangle:=mesh.triangles[index]
            a,b,c:=mesh.vertices[triangle[0]],mesh.vertices[triangle[1]],mesh.vertices[triangle[2]]
            if !math.aabb_overlaps(box,{vmin(a,vmin(b,c)),vmax(a,vmax(b,c))}) {continue}
            triangle_collide(w,&collector,shape,&body,xf,a,b,c,mesh.flags[index],index,speculative,box)
        }
    }
    return collector_finish(&collector,speculative,out)
}

@(private)
heightfield_cells :: proc "contextless" (field:^Heightfield,box:Aabb) -> (column0,column1,row0,row1:int,ok:bool) {
    if box.max.x<0 || box.max.z<0 || box.min.y>field.aabb.max.y || box.max.y<field.aabb.min.y {return}
    column0=max(int(box.min.x/field.cell.x),0)
    column1=min(int(box.max.x/field.cell.x),field.columns-2)
    row0=max(int(box.min.z/field.cell.z),0)
    row1=min(int(box.max.z/field.cell.z),field.rows-2)
    return column0,column1,row0,row1,column0<=column1 && row0<=row1
}

@(private)
heightfield_collide :: proc(w:^World,field:^Heightfield,shape:^Shape,xf:Transform,speculative:f32,out:^[1+EXTRA_MANIFOLDS]Local_Manifold) -> int #no_bounds_check {
    box:=math.aabb_expand(shape_aabb_at(w,shape,xf),speculative)
    column0,column1,row0,row1,ok:=heightfield_cells(field,box)
    if !ok {return 0}
    storage:Box_Hull=---
    points:[8]Vec3=---
    body:Convex=---
    if shape.type>=.Box {body=convex_of(w,shape,&points,&storage)}
    collector:Triangle_Collector=---
    collector.count,collector.flat_count=0,0
    for row in row0..=row1 {
        for column in column0..=column1 {
            triangles,flags,open:=heightfield_cell(field,column,row)
            if !open {continue}
            for triangle,i in triangles {
                a,b,c:=triangle[0],triangle[1],triangle[2]
                if box.min.y>max(a.y,b.y,c.y) || box.max.y<min(a.y,b.y,c.y) {continue}
                triangle_collide(w,&collector,shape,&body,xf,a,b,c,flags[i],u32(2*(row*field.columns+column)+i),speculative,box)
            }
        }
    }
    return collector_finish(&collector,speculative,out)
}

