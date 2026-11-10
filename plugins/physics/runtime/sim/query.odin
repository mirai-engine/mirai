package mirai_physics

import cmath "core:math"
import "mirai:std/spatial"
import math "mirai:std/math"

// What a query sees. By channel, with `objects` zero, the query is one more shape of `filter`: a shape
// meets it with the weaker answer of the two, as a pair of shapes does. By object type it sees the shapes
// of the layers in `objects`, whatever they answer, and all of them block it.
Query_Filter :: struct {
    filter:Filter,
    ignore_body:Body_Handle,
    objects:Collision_Layers,
    overlaps:bool, // also report the shapes that only overlap the query: in a list of hits, those before the first that blocks
    debris:bool,   // also report debris bodies
}
QUERY_FILTER_DEFAULT :: Query_Filter{filter=FILTER_DEFAULT}

// `normal` points out of the shape that was hit. A query that starts inside a shape reports fraction zero
// and a zero normal. `overlap`: the shape does not block the query.
Ray_Hit :: struct {shape:Shape_Handle,body:Body_Handle,point,normal:Vec3,fraction:f32,overlap:bool}
Closest_Hit :: struct {
    shape:Shape_Handle,
    body:Body_Handle,
    point:Vec3,       // on the shape found
    query_point:Vec3, // on the query shape
    normal:Vec3,      // from the shape found toward the query; zero when they overlap
    distance:f32,
}

// How a query meets a shape of filter `target`, before looking at its body.
query_filter_response :: #force_inline proc "contextless" (filter:Query_Filter,target:Filter) -> Response {
    if filter.objects!=0 {
        if filter.filter.group!=0 && filter.filter.group==target.group {return .Ignore}
        return target.layers&filter.objects!=0?.Block:.Ignore
    }
    response:=filter_response(filter.filter,target)
    return response==.Overlap && !filter.overlaps?.Ignore:response
}

@(private)
query_response :: #force_inline proc "contextless" (w:^World,shape:^Shape,filter:Query_Filter) -> Response {
    if !filter.debris && .Debris in w.bodies[shape.body].flags {return .Ignore}
    if filter.ignore_body!={} && body_handle(w,shape.body)==filter.ignore_body {return .Ignore}
    return query_filter_response(filter,shape.filter)
}

// The hits after the first that blocks are dropped; by object type nothing blocks a list.
@(private)
hits_cut :: proc "contextless" (hits:[]Ray_Hit,count:int,filter:Query_Filter) -> int {
    if filter.objects!=0 {return count}
    for hit,i in hits[:count] {if !hit.overlap {return i+1}}
    return count
}

@(private)
ray_sphere :: proc "contextless" (o,d:Vec3,radius,max_fraction:f32) -> (t:f32,normal:Vec3,hit:bool) {
    c:=dot(o,o)-radius*radius
    if c<=0 {return 0,{},true}
    a:=dot(d,d)
    b:=dot(o,d)
    if a<1e-20 || b>=0 {return}
    discriminant:=b*b-a*c
    if discriminant<0 {return}
    t=(-b-cmath.sqrt(discriminant))/a
    if t<0 || t>max_fraction {return 0,{},false}
    return t,normalize(o+d*t),true
}

@(private)
ray_capsule :: proc "contextless" (o,d:Vec3,radius,half_height,max_fraction:f32) -> (t:f32,normal:Vec3,hit:bool) {
    if length2(o-Vec3{0,clamp(o.y,-half_height,half_height),0})<=radius*radius {return 0,{},true}
    t=max(f32)
    // The side of the cylinder.
    a:=d.x*d.x+d.z*d.z
    b:=o.x*d.x+o.z*d.z
    c:=o.x*o.x+o.z*o.z-radius*radius
    if a>1e-20 && c>0 && b<0 {
        if discriminant:=b*b-a*c;discriminant>=0 {
            side:=(-b-cmath.sqrt(discriminant))/a
            if y:=o.y+side*d.y;side>=0 && side<=max_fraction && abs(y)<=half_height {
                t,normal,hit=side,normalize({o.x+side*d.x,0,o.z+side*d.z}),true
            }
        }
    }
    for end in ([2]f32{-half_height,half_height}) {
        if cap,cap_normal,cap_hit:=ray_sphere(o-{0,end,0},d,radius,max_fraction);cap_hit && cap<t {t,normal,hit=cap,cap_normal,true}
    }
    return hit?t:0,normal,hit
}

// A cylinder along Y: its side, then its caps.
@(private)
ray_cylinder :: proc "contextless" (o,d:Vec3,radius,half_height,max_fraction:f32) -> (t:f32,normal:Vec3,hit:bool) {
    c:=o.x*o.x+o.z*o.z-radius*radius
    if c<=0 && abs(o.y)<=half_height {return 0,{},true}
    t=max(f32)
    a:=d.x*d.x+d.z*d.z
    b:=o.x*d.x+o.z*d.z
    if a>1e-20 && c>0 && b<0 {
        if discriminant:=b*b-a*c;discriminant>=0 {
            side:=(-b-cmath.sqrt(discriminant))/a
            if y:=o.y+side*d.y;side>=0 && side<=max_fraction && abs(y)<=half_height {
                t,normal,hit=side,normalize({o.x+side*d.x,0,o.z+side*d.z}),true
            }
        }
    }
    if abs(o.y)>half_height && o.y*d.y<0 {
        cap:=(abs(o.y)-half_height)/abs(d.y)
        x,z:=o.x+cap*d.x,o.z+cap*d.z
        if cap<=max_fraction && cap<t && x*x+z*z<=radius*radius {t,normal,hit=cap,{0,o.y>0?1:-1,0},true}
    }
    return hit?t:0,normal,hit
}

// A rounded shape: the cast of a point against its core inflated by its radius.
@(private)
ray_rounded :: proc(w:^World,shape:^Shape,o,d:Vec3,max_fraction:f32) -> (t:f32,normal:Vec3,hit:bool) {
    storage:[8]Vec3=---
    origin:=[1]Vec3{}
    out:=gjk_cast(shape_proxy(w,shape,&storage),{origin[:],0,0},{o,QUAT_IDENTITY},d,max_fraction)
    return out.fraction,out.normal,out.hit
}

@(private)
ray_box :: proc "contextless" (o,d,half:Vec3,max_fraction:f32) -> (t:f32,normal:Vec3,hit:bool) {
    enter,exit:=f32(0),max_fraction
    axis:=-1
    for i in 0..<3 {
        if abs(d[i])<1e-20 {
            if abs(o[i])>half[i] {return}
            continue
        }
        inv:=1/d[i]
        t1,t2:=(-half[i]-o[i])*inv,(half[i]-o[i])*inv
        if t1>t2 {t1,t2=t2,t1}
        if t1>enter {enter=t1;axis=i}
        exit=min(exit,t2)
        if enter>exit {return}
    }
    if axis<0 {return 0,{},true}
    normal[axis]=d[axis]>0?-1:1
    return enter,normal,true
}

@(private)
ray_hull :: proc "contextless" (hull:^Hull,o,d:Vec3,max_fraction:f32) -> (t:f32,normal:Vec3,hit:bool) {
    enter,exit:=f32(0),max_fraction
    face:=-1
    for plane,i in hull.planes {
        distance:=plane_distance(plane,o)
        approach:=dot(plane.n,d)
        if abs(approach)<1e-20 {
            if distance>0 {return}
            continue
        }
        crossing:=-distance/approach
        if approach<0 {
            if crossing>enter {enter=crossing;face=i}
        } else {
            exit=min(exit,crossing)
        }
        if enter>exit {return}
    }
    if face<0 {return 0,{},true}
    return enter,hull.planes[face].n,true
}

// Only the front of the triangle is hit.
@(private)
ray_triangle :: #force_inline proc "contextless" (o,d,a,b,c:Vec3,max_fraction:f32) -> (t:f32,hit:bool) {
    e1,e2:=b-a,c-a
    p:=cross(d,e2)
    det:=dot(e1,p)
    if det<=1e-20 {return}
    s:=o-a
    u:=dot(s,p)
    if u<0 || u>det {return}
    q:=cross(s,e1)
    v:=dot(d,q)
    if v<0 || u+v>det {return}
    t=dot(e2,q)/det
    return t,t>=0 && t<=max_fraction
}

@(private)
ray_mesh :: proc(mesh:^Mesh,o,d:Vec3,max_fraction:f32) -> (t:f32,normal:Vec3,hit:bool) {
    ray:=spatial.bvh_ray(&mesh.bvh,o,d,max_fraction)
    for leaf in spatial.bvh_ray_next(&ray) {
        for index in leaf {
            triangle:=mesh.triangles[index]
            a,b,c:=mesh.vertices[triangle[0]],mesh.vertices[triangle[1]],mesh.vertices[triangle[2]]
            if fraction,ok:=ray_triangle(o,d,a,b,c,ray.max_fraction);ok {
                t,hit=fraction,true
                normal=normalize(cross(b-a,c-a))
                ray.max_fraction=fraction
            }
        }
    }
    return
}

// Walks the cells under the ray in order, so the first cell with a hit ends the search.
@(private)
ray_heightfield :: proc "contextless" (field:^Heightfield,o,d:Vec3,max_fraction:f32) -> (t:f32,normal:Vec3,hit:bool) {
    start,inside:=spatial.aabb_ray(field.aabb,o,d,max_fraction)
    if !inside {return}
    entry:=o+d*start
    column:=clamp(int(entry.x/field.cell.x),0,field.columns-2)
    row:=clamp(int(entry.z/field.cell.z),0,field.rows-2)
    step_column:=d.x>0?1:-1
    step_row:=d.z>0?1:-1
    next_column:=abs(d.x)>1e-20?(f32(column+(d.x>0?1:0))*field.cell.x-o.x)/d.x:max(f32)
    next_row:=abs(d.z)>1e-20?(f32(row+(d.z>0?1:0))*field.cell.z-o.z)/d.z:max(f32)
    delta_column:=abs(d.x)>1e-20?field.cell.x/abs(d.x):max(f32)
    delta_row:=abs(d.z)>1e-20?field.cell.z/abs(d.z):max(f32)
    for column>=0 && column<=field.columns-2 && row>=0 && row<=field.rows-2 {
        triangles,_,open:=heightfield_cell(field,column,row)
        best:=max_fraction
        for triangle in triangles[:open?2:0] {
            if fraction,ok:=ray_triangle(o,d,triangle[0],triangle[1],triangle[2],best);ok {
                best,t,hit=fraction,fraction,true
                normal=normalize(cross(triangle[1]-triangle[0],triangle[2]-triangle[0]))
            }
        }
        if hit {return}
        if min(next_column,next_row)>max_fraction {return}
        if next_column<next_row {
            column+=step_column
            next_column+=delta_column
        } else {
            row+=step_row
            next_row+=delta_row
        }
    }
    return
}

// Ray against one shape, in the frame of the shape.
@(private)
shape_ray :: proc(w:^World,shape:^Shape,o,d:Vec3,max_fraction:f32) -> (t:f32,normal:Vec3,hit:bool) {
    if shape.radius>0 {return ray_rounded(w,shape,o,d,max_fraction)}
    switch shape.type {
    case .Sphere: return ray_sphere(o,d,shape.size.x,max_fraction)
    case .Capsule: return ray_capsule(o,d,shape.size.x,shape.size.y,max_fraction)
    case .Box: return ray_box(o,d,shape.size,max_fraction)
    case .Cylinder: return ray_cylinder(o,d,shape.size.x,shape.size.y,max_fraction)
    case .Hull: return ray_hull(&w.hulls[shape.resource].hull,o,d,max_fraction)
    case .Mesh: return ray_mesh(&w.meshes[shape.resource].mesh,o,d,max_fraction)
    case .Heightfield: return ray_heightfield(&w.heightfields[shape.resource].field,o,d,max_fraction)
    }
    return
}

@(private)
hits_insert :: proc "contextless" (hits:[]Ray_Hit,count:^int,hit:Ray_Hit) {
    if len(hits)==0 {return}
    position:=count^
    if position==len(hits) {
        if hit.fraction>=hits[position-1].fraction {return}
        position-=1
    } else {
        count^+=1
    }
    for position>0 && hits[position-1].fraction>hit.fraction {
        hits[position]=hits[position-1]
        position-=1
    }
    hits[position]=hit
}

@(private) Ray_Mode :: enum {Closest,Any,All}

@(private)
ray_cast :: proc(w:^World,origin,translation:Vec3,filter:Query_Filter,mode:Ray_Mode,hits:[]Ray_Hit) -> int {
    count:=0
    for &tree in w.trees {
        ray:=spatial.dynamic_tree_ray(&tree,origin,translation,mode==.Closest && count>0?hits[0].fraction:1)
        for _,user in spatial.tree_ray_next(&ray) {
            shape:=&w.shapes[user]
            response:=query_response(w,shape,filter)
            if response==.Ignore || response==.Overlap && mode!=.All {continue}
            xf:=shape_transform_of(w,shape)
            limit:=mode==.All?f32(1):ray.max_fraction
            t,normal,hit:=shape_ray(w,shape,xf_inv_point(xf,origin),q_inv_rotate(xf.q,translation),limit)
            if !hit || (w.cut_count>0 || .Twin in shape.flags) && point_cut(w,i32(user),shape,origin+translation*t) {continue}
            result:=Ray_Hit{shape_handle(w,i32(user)),body_handle(w,shape.body),origin+translation*t,q_rotate(xf.q,normal),t,response==.Overlap}
            switch mode {
            case .Any:
                return 1
            case .Closest:
                hits[0]=result
                count=1
                ray.max_fraction=t
            case .All:
                hits_insert(hits,&count,result)
                if count>0 && count==len(hits) {ray.max_fraction=hits[count-1].fraction}
                if response==.Block && filter.objects==0 {ray.max_fraction=min(ray.max_fraction,t)}
            }
        }
    }
    return mode==.All?hits_cut(hits,count,filter):count
}

// First shape hit by the segment from `origin` to `origin+translation`.
ray_cast_closest :: proc(w:^World,origin,translation:Vec3,filter:=QUERY_FILTER_DEFAULT) -> (Ray_Hit,bool) {
    hit:[1]Ray_Hit
    found:=ray_cast(w,origin,translation,filter,.Closest,hit[:])
    return hit[0],found>0
}
// Whether the segment hits anything: the cheapest of the three.
ray_cast_any :: proc(w:^World,origin,translation:Vec3,filter:=QUERY_FILTER_DEFAULT) -> bool {
    return ray_cast(w,origin,translation,filter,.Any,nil)>0
}
// The shapes hit by the segment, nearest first, written to `hits`: by channel up to the first that blocks,
// by object type all of them. When there are more than fit, the nearest are kept. Returns how many were written.
ray_cast_all :: proc(w:^World,origin,translation:Vec3,hits:[]Ray_Hit,filter:=QUERY_FILTER_DEFAULT) -> int {
    return ray_cast(w,origin,translation,filter,.All,hits)
}
// Ray against a single shape, whatever its filter.
shape_ray_cast :: proc(w:^World,h:Shape_Handle,origin,translation:Vec3) -> (Ray_Hit,bool) {
    shape,index:=shape_read(w,h)
    if shape==nil {return {},false}
    xf:=shape_transform_of(w,shape)
    t,normal,hit:=shape_ray(w,shape,xf_inv_point(xf,origin),q_inv_rotate(xf.q,translation),1)
    if !hit {return {},false}
    return {shape_handle(w,index),body_handle(w,shape.body),origin+translation*t,q_rotate(xf.q,normal),t,false},true
}

// Ray against the shapes of one body as if the body were at a pose, whatever their filter: where it was at
// another time.
body_ray_cast :: proc(w:^World,h:Body_Handle,at:Transform,origin,translation:Vec3) -> (best:Ray_Hit,found:bool) {
    body,_:=body_read(w,h)
    if body==nil {return}
    best.fraction=1
    for s:=body.shape_list;s>=0;s=w.shapes[s].next {
        shape:=&w.shapes[s]
        xf:=xf_mul(at,shape.local)
        if t,normal,hit:=shape_ray(w,shape,xf_inv_point(xf,origin),q_inv_rotate(xf.q,translation),best.fraction);hit {
            best,found={shape_handle(w,s),h,origin+translation*t,q_rotate(xf.q,normal),t,false},true
        }
    }
    return
}

// A convex query shape as a proxy; false for meshes, heightfields and invalid geometry. A hull keeps its
// convex radius.
@(private)
query_proxy :: proc "contextless" (w:^World,geometry:Geometry,storage:^[8]Vec3) -> (Proxy,bool) {
    #partial switch g in geometry {
    case Sphere:
        if !(g.radius>=0) {return {},false}
        storage[0]={}
        return {storage[:1],g.radius,0},true
    case Capsule:
        if !(g.radius>=0) || !(g.half_height>=0) {return {},false}
        storage[0],storage[1]={0,-g.half_height,0},{0,g.half_height,0}
        return {storage[:2],g.radius,0},true
    case Box:
        e:=g.half_extents
        if !(e.x>0 && e.y>0 && e.z>0) {return {},false}
        for i in 0..<8 {storage[i]={i&1!=0?e.x:-e.x,i&2!=0?e.y:-e.y,i&4!=0?e.z:-e.z}}
        return {storage[:],0,0},true
    case Cylinder:
        if !(g.radius>=0) || !(g.half_height>=0) {return {},false}
        storage[0],storage[1]={0,-g.half_height,0},{0,g.half_height,0}
        return {storage[:2],0,g.radius},true
    case Hull_Handle:
        slot,_:=hull_slot(w,g)
        if slot==nil {return {},false}
        return {hull_core(&slot.hull).vertices,slot.hull.convex_radius,0},true
    }
    return {},false
}

@(private)
proxy_aabb :: proc "contextless" (proxy:Proxy,xf:Transform) -> Aabb {
    first:=xf_point(xf,proxy.points[0])
    box:=Aabb{first,first}
    for p in proxy.points[1:] {
        point:=xf_point(xf,p)
        box={vmin(box.min,point),vmax(box.max,point)}
    }
    grow:=Vec3{proxy.radius,proxy.radius,proxy.radius}
    if proxy.disc!=0 {grow+=disc_extent(q_rotate(xf.q,{0,1,0}))*proxy.disc}
    return {box.min-grow,box.max+grow}
}

@(private) Triangle_Visit :: #type proc(data:rawptr,a,b,c:Vec3) -> bool

// Calls `visit` for the triangles of a mesh or heightfield whose boxes touch `box` swept by `translation`,
// all in the frame of the shape, until it returns false.
@(private)
triangles_visit :: proc(w:^World,shape:^Shape,box:Aabb,translation:Vec3,data:rawptr,visit:Triangle_Visit) {
    if shape.type==.Mesh {
        mesh:=&w.meshes[shape.resource].mesh
        sweep:=spatial.bvh_sweep(&mesh.bvh,box,translation,1)
        for leaf in spatial.bvh_sweep_next(&sweep) {
            for index in leaf {
                triangle:=mesh.triangles[index]
                if !visit(data,mesh.vertices[triangle[0]],mesh.vertices[triangle[1]],mesh.vertices[triangle[2]]) {return}
            }
        }
    } else if shape.type==.Heightfield {
        field:=&w.heightfields[shape.resource].field
        swept:=spatial.aabb_translate_extend(box,translation)
        column0,column1,row0,row1,ok:=heightfield_cells(field,swept)
        if !ok {return}
        for row in row0..=row1 {
            for column in column0..=column1 {
                triangles,_,open:=heightfield_cell(field,column,row)
                if !open {continue}
                for triangle in triangles {
                    if swept.min.y>max(triangle[0].y,triangle[1].y,triangle[2].y) {continue}
                    if !visit(data,triangle[0],triangle[1],triangle[2]) {return}
                }
            }
        }
    }
}

@(private) Cast_Visit :: struct {proxy:Proxy,xf:Transform,translation:Vec3,best:Cast_Output}

@(private)
cast_triangle :: proc(data:rawptr,a,b,c:Vec3) -> bool {
    visit:=(^Cast_Visit)(data)
    // A shape moving away from the front of a triangle does not hit it.
    if dot(cross(b-a,c-a),visit.translation)>=0 {return true}
    points:=[3]Vec3{a,b,c}
    out:=gjk_cast({points[:],0,0},visit.proxy,visit.xf,visit.translation,visit.best.hit?visit.best.fraction:1)
    if out.hit && (!visit.best.hit || out.fraction<visit.best.fraction) {visit.best=out}
    return !(out.hit && out.fraction==0)
}

// Cast of a convex proxy against one shape. `xf` and `translation` are in the frame of the shape.
@(private)
shape_cast_local :: proc(w:^World,shape:^Shape,proxy:Proxy,xf:Transform,translation:Vec3,max_fraction:f32) -> Cast_Output {
    if shape.type<.Mesh {
        storage:[8]Vec3=---
        return gjk_cast(shape_proxy(w,shape,&storage),proxy,xf,translation,max_fraction)
    }
    visit:=Cast_Visit{proxy=proxy,xf=xf,translation=translation}
    triangles_visit(w,shape,proxy_aabb(proxy,xf),translation,&visit,cast_triangle)
    if visit.best.hit && visit.best.fraction>max_fraction {visit.best.hit=false}
    return visit.best
}

@(private)
shape_cast :: proc(w:^World,geometry:Geometry,transform:Transform,translation:Vec3,filter:Query_Filter,all:bool,hits:[]Ray_Hit) -> int {
    storage:[8]Vec3=---
    proxy,ok:=query_proxy(w,geometry,&storage)
    if !ok || len(hits)==0 {return 0}
    start:=Transform{transform.p,q_normalize(transform.q)}
    box:=proxy_aabb(proxy,start)
    count:=0
    for &tree in w.trees {
        sweep:=spatial.dynamic_tree_sweep(&tree,box,translation,!all && count>0?hits[0].fraction:1)
        for _,user in spatial.tree_sweep_next(&sweep) {
            shape:=&w.shapes[user]
            response:=query_response(w,shape,filter)
            if response==.Ignore || response==.Overlap && !all {continue}
            xf:=shape_transform_of(w,shape)
            out:=shape_cast_local(w,shape,proxy,xf_inv_mul(xf,start),q_inv_rotate(xf.q,translation),all?1:sweep.max_fraction)
            if !out.hit || (w.cut_count>0 || .Twin in shape.flags) && point_cut(w,i32(user),shape,xf_point(xf,out.point)) {continue}
            result:=Ray_Hit{shape_handle(w,i32(user)),body_handle(w,shape.body),xf_point(xf,out.point),q_rotate(xf.q,out.normal),out.fraction,response==.Overlap}
            if all {
                hits_insert(hits,&count,result)
                if count==len(hits) {sweep.max_fraction=hits[count-1].fraction}
                if response==.Block && filter.objects==0 {sweep.max_fraction=min(sweep.max_fraction,out.fraction)}
            } else if count==0 || result.fraction<hits[0].fraction {
                hits[0]=result
                count=1
                sweep.max_fraction=result.fraction
            }
        }
    }
    return all?hits_cut(hits,count,filter):count
}

// First shape touched by a sphere, capsule, box, cylinder or hull that moves by `translation` without rotating.
// `point` is the point of first contact and `fraction` how much of the translation was covered.
shape_cast_closest :: proc(w:^World,geometry:Geometry,transform:Transform,translation:Vec3,filter:=QUERY_FILTER_DEFAULT) -> (Ray_Hit,bool) {
    hit:[1]Ray_Hit
    found:=shape_cast(w,geometry,transform,translation,filter,false,hit[:])
    return hit[0],found>0
}
// The shapes touched along the way, nearest first, as ray_cast_all; returns how many were written.
shape_cast_all :: proc(w:^World,geometry:Geometry,transform:Transform,translation:Vec3,hits:[]Ray_Hit,filter:=QUERY_FILTER_DEFAULT) -> int {
    return shape_cast(w,geometry,transform,translation,filter,true,hits)
}

@(private) Distance_Visit :: struct {proxy:Proxy,xf:Transform,best:Gjk_Output,limit:f32,found:bool}

@(private)
distance_triangle :: proc(data:rawptr,a,b,c:Vec3) -> bool {
    visit:=(^Distance_Visit)(data)
    points:=[3]Vec3{a,b,c}
    out:=gjk_distance({points[:],0,0},visit.proxy,visit.xf,nil,true)
    if out.distance<=visit.limit && (!visit.found || out.distance<visit.best.distance) {
        visit.best,visit.found,visit.limit=out,true,out.distance
    }
    return out.distance>0
}

// Closest points between a convex proxy and one shape, in the frame of the shape, if within `limit`.
@(private)
shape_distance_local :: proc(w:^World,shape:^Shape,proxy:Proxy,xf:Transform,limit:f32) -> (Gjk_Output,bool) {
    if shape.type<.Mesh {
        storage:[8]Vec3=---
        out:=gjk_distance(shape_proxy(w,shape,&storage),proxy,xf,nil,true)
        return out,out.distance<=limit
    }
    visit:=Distance_Visit{proxy=proxy,xf=xf,limit=limit}
    triangles_visit(w,shape,math.aabb_expand(proxy_aabb(proxy,xf),limit),{},&visit,distance_triangle)
    return visit.best,visit.found
}

// Shapes that overlap a sphere, capsule, box, cylinder or hull placed at `transform`, written to `out`.
// Returns how many overlap, which can exceed what fits.
overlap_shape :: proc(w:^World,geometry:Geometry,transform:Transform,out:[]Shape_Handle,filter:=QUERY_FILTER_DEFAULT) -> int {
    storage:[8]Vec3=---
    proxy,ok:=query_proxy(w,geometry,&storage)
    if !ok {return 0}
    xf_query:=Transform{transform.p,q_normalize(transform.q)}
    box:=proxy_aabb(proxy,xf_query)
    count:=0
    for &tree in w.trees {
        query:=spatial.dynamic_tree_query(&tree,box)
        for _,user in spatial.tree_query_next(&query) {
            shape:=&w.shapes[user]
            if query_response(w,shape,filter)==.Ignore || !math.aabb_overlaps(shape.aabb,box) {continue}
            if _,touching:=shape_distance_local(w,shape,proxy,xf_inv_mul(shape_transform_of(w,shape),xf_query),0);!touching {continue}
            if count<len(out) {out[count]=shape_handle(w,i32(user))}
            count+=1
        }
    }
    return count
}

// Shapes whose boxes overlap a world box, written to `out`. Returns how many overlap.
overlap_aabb :: proc(w:^World,box:Aabb,out:[]Shape_Handle,filter:=QUERY_FILTER_DEFAULT) -> int {
    count:=0
    for &tree in w.trees {
        query:=spatial.dynamic_tree_query(&tree,box)
        for _,user in spatial.tree_query_next(&query) {
            shape:=&w.shapes[user]
            if query_response(w,shape,filter)==.Ignore || !math.aabb_overlaps(shape.aabb,box) {continue}
            if count<len(out) {out[count]=shape_handle(w,i32(user))}
            count+=1
        }
    }
    return count
}

// Nearest shape to a convex query shape within `max_distance`, with the closest points of both.
closest_shape :: proc(w:^World,geometry:Geometry,transform:Transform,max_distance:f32,filter:=QUERY_FILTER_DEFAULT) -> (hit:Closest_Hit,found:bool) {
    storage:[8]Vec3=---
    proxy,ok:=query_proxy(w,geometry,&storage)
    if !ok || !(max_distance>=0) {return}
    xf_query:=Transform{transform.p,q_normalize(transform.q)}
    limit:=max_distance
    for &tree in w.trees {
        query:=spatial.dynamic_tree_query(&tree,math.aabb_expand(proxy_aabb(proxy,xf_query),max_distance))
        for _,user in spatial.tree_query_next(&query) {
            shape:=&w.shapes[user]
            if query_response(w,shape,filter)!=.Block {continue}
            xf:=shape_transform_of(w,shape)
            out,within:=shape_distance_local(w,shape,proxy,xf_inv_mul(xf,xf_query),limit)
            if !within || (found && out.distance>=hit.distance) {continue}
            if (w.cut_count>0 || .Twin in shape.flags) && point_cut(w,i32(user),shape,xf_point(xf,out.point_a)) {continue}
            hit={shape_handle(w,i32(user)),body_handle(w,shape.body),xf_point(xf,out.point_a),xf_point(xf,out.point_b),q_rotate(xf.q,out.normal),out.distance}
            found=true
            limit=out.distance
        }
    }
    return
}

// Nearest point of any shape to a world point within `max_distance`. Inside a shape the distance is zero.
closest_point :: proc(w:^World,point:Vec3,max_distance:f32,filter:=QUERY_FILTER_DEFAULT) -> (Closest_Hit,bool) {
    return closest_shape(w,Sphere{0},{point,QUAT_IDENTITY},max_distance,filter)
}
