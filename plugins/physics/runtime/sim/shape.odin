package mirai_physics

import cmath "core:math"
import "mirai:std/base"
import "mirai:std/spatial"
import math "mirai:std/math"

@(private)
hull_slot :: proc "contextless" (w:^World,h:Hull_Handle) -> (^Hull_Slot,u32) {
    index:=base.handle_index(base.Handle(h))
    generation:=base.handle_generation(base.Handle(h))
    if index>=u32(len(w.hulls)) || generation&1==0 || w.hulls[index].generation!=generation {return nil,0}
    return &w.hulls[index],index
}
@(private)
mesh_slot :: proc "contextless" (w:^World,h:Mesh_Handle) -> (^Mesh_Slot,u32) {
    index:=base.handle_index(base.Handle(h))
    generation:=base.handle_generation(base.Handle(h))
    if index>=u32(len(w.meshes)) || generation&1==0 || w.meshes[index].generation!=generation {return nil,0}
    return &w.meshes[index],index
}
@(private)
heightfield_slot :: proc "contextless" (w:^World,h:Heightfield_Handle) -> (^Heightfield_Slot,u32) {
    index:=base.handle_index(base.Handle(h))
    generation:=base.handle_generation(base.Handle(h))
    if index>=u32(len(w.heightfields)) || generation&1==0 || w.heightfields[index].generation!=generation {return nil,0}
    return &w.heightfields[index],index
}

// Registers a convex hull that shapes can share, its edges rounded by convex_radius (m) without moving its
// faces; the radius must be below the distance from its center of mass to its nearest face. Allocates: do it
// when loading, not per tick.
hull_create :: proc(w:^World,desc:Hull_Desc,convex_radius:f32=0) -> (Hull_Handle,bool) {
    for &slot,index in w.hulls {
        if slot.generation&1!=0 {continue}
        if !hull_init(&slot.hull,desc,w.allocator,convex_radius) {return {},false}
        slot.generation+=1
        slot.refs=0
        return Hull_Handle(base.handle_make(u32(index),slot.generation)),true
    }
    w.stats.geometry_capacity_exhausted+=1
    return {},false
}
// Builds the hull again from desc under the same handle while no shape uses it: whoever repeats what
// made it gets the same handle. A snapshot whose shapes name the hull as it was is refused afterwards.
// The old geometry stays when desc is not valid.
hull_rebuild :: proc(w:^World,h:Hull_Handle,desc:Hull_Desc) -> bool {
    slot,_:=hull_slot(w,h)
    if slot==nil || slot.refs>0 {return false}
    next:Hull
    if !hull_init(&next,desc,w.allocator) {return false}
    hull_free(&slot.hull,w.allocator)
    slot.hull=next
    slot.revision+=1
    return true
}

// The hull of a live handle, or nil. Read only: shapes share it.
hull_get :: proc(w:^World,h:Hull_Handle) -> ^Hull {
    slot,_:=hull_slot(w,h)
    return slot!=nil?&slot.hull:nil
}

// Whether a shape uses the hull: it cannot be rebuilt or destroyed then.
hull_in_use :: proc(w:^World,h:Hull_Handle) -> bool {
    slot,_:=hull_slot(w,h)
    return slot!=nil && slot.refs>0
}

// Hull slots that hull_create can still take.
hulls_free :: proc(w:^World) -> int {
    count:=0
    for &slot in w.hulls {count+=int(slot.generation&1==0)}
    return count
}

// Gives the hull the mass properties of what it stands for, for unit density, before a shape uses it:
// a center of mass inside it, and the inertia about that center.
hull_set_mass :: proc(w:^World,h:Hull_Handle,volume:f32,center:Vec3,inertia:Mat3) -> bool {
    slot,_:=hull_slot(w,h)
    if slot==nil || slot.refs>0 {return false}
    slot.hull.volume,slot.hull.center,slot.hull.inertia=volume,center,inertia
    slot.hull.inner_radius=max(f32)
    for plane in slot.hull.planes {slot.hull.inner_radius=min(slot.hull.inner_radius,-plane_distance(plane,center))}
    slot.revision+=1
    return true
}

// Fails while a shape uses the hull. Snapshots taken while a shape used it must not be restored afterwards.
hull_destroy :: proc(w:^World,h:Hull_Handle) -> bool {
    slot,_:=hull_slot(w,h)
    if slot==nil || slot.refs>0 {return false}
    hull_free(&slot.hull,w.allocator)
    slot.generation+=1
    return true
}

@(private)
shape_refs_add :: proc "contextless" (w:^World,shape:^Shape,delta:i32) {
    #partial switch shape.type {
    case .Hull: w.hulls[shape.resource].refs+=delta
    case .Mesh: w.meshes[shape.resource].refs+=delta
    case .Heightfield: w.heightfields[shape.resource].refs+=delta
    }
}

// Without update_mass the caller updates the mass of the body once, after its last shape, with
// body_mass_update.
shape_create :: proc(w:^World,body_handle:Body_Handle,desc:Shape_Desc,update_mass:=true) -> Shape_Handle {
    w.grounds_stale=true
    body,body_index:=body_get(w,body_handle)
    if body==nil {return {}}
    type:Shape_Type
    size:Vec3
    resource:u32
    radius:f32
    round:=desc.convex_radius
    if !(round>=0 && round<max(f32)) {return {}}
    switch g in desc.geometry {
    case Sphere:
        if !(g.radius>0) {return {}}
        type=.Sphere;size.x=g.radius
    case Capsule:
        if !(g.radius>0) || !(g.half_height>=0) {return {}}
        if g.half_height<LINEAR_SLOP {
            type=.Sphere;size.x=g.radius
        } else {
            type=.Capsule;size={g.radius,g.half_height,0}
        }
    case Box:
        if !(g.half_extents.x>0 && g.half_extents.y>0 && g.half_extents.z>0) {return {}}
        if !(round<min(g.half_extents.x,g.half_extents.y,g.half_extents.z)) {return {}}
        type=.Box;size=g.half_extents;radius=round
    case Cylinder:
        if !(g.radius>0 && g.radius<max(f32)) || !(g.half_height>0 && g.half_height<max(f32)) {return {}}
        if !(round<min(g.radius,g.half_height)) {return {}}
        type=.Cylinder;size={g.radius,g.half_height,0};radius=round
    case Hull_Handle:
        slot,index:=hull_slot(w,g)
        if slot==nil {return {}}
        type=.Hull;resource=index;radius=slot.hull.convex_radius
    case Mesh_Handle:
        slot,index:=mesh_slot(w,g)
        if slot==nil {return {}}
        type=.Mesh;resource=index
    case Heightfield_Handle:
        slot,index:=heightfield_slot(w,g)
        if slot==nil {return {}}
        type=.Heightfield;resource=index
    case:
        return {}
    }
    tree:=&w.trees[body.type==.Static?STATIC_TREE:DYNAMIC_TREE]
    index:=w.shape_free
    if index<0 && int(w.shape_high)>=len(w.shapes) {
        w.stats.shape_capacity_exhausted+=1
        return {}
    }
    if index>=0 {
        w.shape_free=w.shapes[index].next
    } else {
        index=w.shape_high
        w.shape_high+=1
    }
    w.shape_count+=1
    shape:=&w.shapes[index]
    stamp(w,shape)
    shape^={
        user_data=desc.user_data,
        local={desc.transform.p,q_normalize(desc.transform.q)},size=size,
        friction=max(desc.friction,0),restitution=clamp(desc.restitution,0,1),density=max(desc.density,0),
        filter=desc.filter,body=body_index,next=body.shape_list,prev=-1,rolling_resistance=max(desc.rolling_resistance,0),
        resource=resource,generation=shape.generation+1,type=type,flags={.Moved},
        dominance=i32(desc.dominance),surface_speed=finite_or_zero(desc.surface_speed),radius=radius,
    }
    shape.drag=desc.drag>0 && desc.drag<=max(f32)?desc.drag:shape_drag_default(type)
    if desc.one_way {shape.flags+={.One_Way}}
    if desc.hits {shape.flags+={.Hits};w.hit_shapes+=1}
    shape.tag=desc.tag
    if body.shape_list>=0 {stamp(w,.Shapes,body.shape_list);w.shapes[body.shape_list].prev=index}
    body.shape_list=index
    body.shape_count+=1
    shape_refs_add(w,shape,1)
    shape.aabb=shape_aabb(w,shape,body_transform_of(body))
    shape.fat=body.type==.Static?shape.aabb:shape_fat(shape.aabb)
    shape.proxy,_=spatial.dynamic_tree_insert(tree,shape.fat,u64(index))
    if body.type==.Static {static_log_push(w,shape.aabb)}
    if update_mass {body_update_mass(w,body_index)}
    handle:=shape_handle(w,index)
    if w.twin_count>0 {twin_source_added(w,body_index,index)}
    return handle
}

shape_destroy :: proc(w:^World,h:Shape_Handle,update_mass:=true) {
    shape,index:=shape_get(w,h)
    // A copy of a twin goes with its source or its twin.
    if shape!=nil && .Twin not_in shape.flags {shape_destroy_index(w,index,update_mass,true)}
}

shape_tag :: proc(w:^World,h:Shape_Handle) -> u32 {
    shape,_:=shape_read(w,h)
    return shape!=nil?shape.tag:0
}

@(private)
shape_destroy_contacts :: proc(w:^World,index:i32) {
    body:=&w.bodies[w.shapes[index].body]
    for key:=body.contact_list;key>=0; {
        contact_index:=key>>1
        contact:=&w.contacts[contact_index]
        key=contact.edges[key&1].next
        if contact.shape_a==index || contact.shape_b==index {
            // The next edge of this body survives: a contact holds one edge per body.
            contact_destroy(w,contact_index)
        }
    }
}

// static_log false: the caller logs the change of the whole static body.
@(private)
shape_destroy_index :: proc(w:^World,index:i32,update_mass,static_log:bool) {
    w.grounds_stale=true
    if w.twin_count>0 {twin_source_removed(w,w.shapes[index].body,index)}
    shape:=&w.shapes[index]
    body:=&w.bodies[shape.body]
    stamp(w,shape)
    stamp(w,body)
    if static_log && body.type==.Static {static_log_push(w,shape.aabb)}
    shape_destroy_contacts(w,index)
    spatial.dynamic_tree_remove(&w.trees[body.type==.Static?STATIC_TREE:DYNAMIC_TREE],shape.proxy)
    if shape.prev>=0 {stamp(w,.Shapes,shape.prev);w.shapes[shape.prev].next=shape.next} else {body.shape_list=shape.next}
    if shape.next>=0 {stamp(w,.Shapes,shape.next);w.shapes[shape.next].prev=shape.prev}
    body.shape_count-=1
    if .Hits in shape.flags {w.hit_shapes-=1}
    shape_refs_add(w,shape,-1)
    body_index:=shape.body
    shape.generation+=1
    shape.flags={}
    shape.next=w.shape_free
    w.shape_free=index
    w.shape_count-=1
    if update_mass {
        body_update_mass(w,body_index)
        body_wake(w,body_index)
    }
}

// Volume and center of a shape in its own frame, from its geometry alone: zero for meshes and heightfields.
@(private)
shape_volume :: proc "contextless" (w:^World,shape:^Shape) -> (volume:f32,center:Vec3) {
    switch shape.type {
    case .Sphere:
        r:=shape.size.x
        volume=4.0/3*PI*r*r*r
    case .Capsule:
        r,h:=shape.size.x,shape.size.y
        volume=PI*r*r*2*h+4.0/3*PI*r*r*r
    case .Box:
        e:=shape.size
        volume=8*e.x*e.y*e.z
    case .Cylinder:
        volume=2*PI*shape.size.x*shape.size.x*shape.size.y
    case .Hull:
        hull:=&w.hulls[shape.resource].hull
        volume,center=hull.volume,hull.center
    case .Mesh,.Heightfield:
    }
    return
}

@(private) Shape_Mass :: struct {mass:f32,center:Vec3,inertia:Mat3,inner_radius:f32}

// Mass of a shape in the frame of its body: center, and inertia about that center.
@(private)
shape_mass :: proc "contextless" (w:^World,shape:^Shape) -> (m:Shape_Mass) {
    local_inertia:Mat3
    volume,center:=shape_volume(w,shape)
    switch shape.type {
    case .Sphere:
        r:=shape.size.x
        local_inertia=(0.4*volume*r*r)*mat3_diagonal({1,1,1})
        m.inner_radius=r
    case .Capsule:
        r,h:=shape.size.x,shape.size.y
        cylinder:=PI*r*r*2*h
        sphere:=4.0/3*PI*r*r*r
        axial:=cylinder*0.5*r*r+sphere*0.4*r*r
        side:=cylinder*(0.25*r*r+h*h/3)+sphere*(0.4*r*r+h*h+0.75*h*r)
        local_inertia=mat3_diagonal({side,axial,side})
        m.inner_radius=r
    case .Box:
        e:=shape.size
        local_inertia=(volume/3)*mat3_diagonal({e.y*e.y+e.z*e.z,e.x*e.x+e.z*e.z,e.x*e.x+e.y*e.y})
        m.inner_radius=min(e.x,e.y,e.z)
    case .Cylinder:
        r,h:=shape.size.x,shape.size.y
        side:=volume*(0.25*r*r+h*h/3)
        local_inertia=mat3_diagonal({side,0.5*volume*r*r,side})
        m.inner_radius=min(r,h)
    case .Hull:
        hull:=&w.hulls[shape.resource].hull
        local_inertia=hull.inertia
        m.inner_radius=hull.inner_radius
    case .Mesh,.Heightfield:
        return
    }
    m.mass=shape.density*volume
    m.center=xf_point(shape.local,center)
    m.inertia=shape.density*mat3_rotate(shape.local.q,local_inertia)
    return
}

@(private)
resource_aabb :: #force_inline proc "contextless" (w:^World,shape:^Shape) -> Aabb {
    #partial switch shape.type {
    case .Hull: return w.hulls[shape.resource].hull.aabb
    case .Mesh: return w.meshes[shape.resource].mesh.aabb
    case .Heightfield: return w.heightfields[shape.resource].field.aabb
    }
    return {}
}

// Farthest distance from a point of the body frame to the shape.
@(private)
shape_extent :: proc "contextless" (w:^World,shape:^Shape,from:Vec3) -> f32 {
    offset:=length(shape.local.p-from)
    switch shape.type {
    case .Sphere: return offset+shape.size.x
    case .Capsule: return offset+shape.size.x+shape.size.y
    case .Box: return offset+length(shape.size)
    case .Cylinder: return offset+length(Vec3{shape.size.x,shape.size.y,0})
    case .Hull,.Mesh,.Heightfield:
        box:=resource_aabb(w,shape)
        return offset+length(vmax(vabs(box.min),vabs(box.max)))
    }
    return offset
}

@(private)
shape_aabb :: proc "contextless" (w:^World,shape:^Shape,body:Transform) -> Aabb #no_bounds_check {
    xf:=xf_mul(body,shape.local)
    switch shape.type {
    case .Sphere:
        r:=shape.size.x
        return {xf.p-r,xf.p+r}
    case .Capsule:
        r:=shape.size.x
        d:=vabs(q_rotate(xf.q,{0,shape.size.y,0}))+r
        return {xf.p-d,xf.p+d}
    case .Box:
        m:=q_matrix(xf.q)
        e:=shape.size
        d:=vabs(Vec3{m[0,0],m[1,0],m[2,0]})*e.x+vabs(Vec3{m[0,1],m[1,1],m[2,1]})*e.y+vabs(Vec3{m[0,2],m[1,2],m[2,2]})*e.z
        return {xf.p-d,xf.p+d}
    case .Cylinder:
        axis:=q_rotate(xf.q,{0,1,0})
        d:=vabs(axis)*shape.size.y+disc_extent(axis)*shape.size.x
        return {xf.p-d,xf.p+d}
    case .Hull,.Mesh,.Heightfield:
        box:=resource_aabb(w,shape)
        m:=q_matrix(xf.q)
        e:=0.5*(box.max-box.min)
        c:=xf_point(xf,0.5*(box.max+box.min))
        d:=vabs(Vec3{m[0,0],m[1,0],m[2,0]})*e.x+vabs(Vec3{m[0,1],m[1,1],m[2,1]})*e.y+vabs(Vec3{m[0,2],m[1,2],m[2,2]})*e.z
        return {c-d,c+d}
    }
    return {}
}

@(private)
shape_transform_of :: #force_inline proc "contextless" (w:^World,shape:^Shape) -> Transform {
    body:=&w.bodies[shape.body]
    xf:=xf_mul({body.position,body.rotation},shape.local)
    if .Twin in shape.flags {xf=xf_mul(twin_through(w,shape),xf)}
    return xf
}

// Half extents along the world axes of a disc of unit radius whose normal is the unit axis.
@(private)
disc_extent :: #force_inline proc "contextless" (axis:Vec3) -> Vec3 {
    return {cmath.sqrt(max(1-axis.x*axis.x,0)),cmath.sqrt(max(1-axis.y*axis.y,0)),cmath.sqrt(max(1-axis.z*axis.z,0))}
}

// Convex shape for GJK: its core as a point set, inflated by its radius. `storage` holds the points of
// spheres, capsules, boxes and cylinders.
@(private)
shape_proxy :: proc "contextless" (w:^World,shape:^Shape,storage:^[8]Vec3) -> Proxy #no_bounds_check {
    #partial switch shape.type {
    case .Sphere:
        storage[0]={}
        return {storage[:1],shape.size.x,0}
    case .Capsule:
        storage[0]={0,-shape.size.y,0}
        storage[1]={0,shape.size.y,0}
        return {storage[:2],shape.size.x,0}
    case .Box:
        e:=shape.size-shape.radius
        for i in 0..<8 {storage[i]={i&1!=0?e.x:-e.x,i&2!=0?e.y:-e.y,i&4!=0?e.z:-e.z}}
        return {storage[:],shape.radius,0}
    case .Cylinder:
        storage[0]={0,-(shape.size.y-shape.radius),0}
        storage[1]={0,shape.size.y-shape.radius,0}
        return {storage[:2],shape.radius,shape.size.x-shape.radius}
    case .Hull:
        hull:=&w.hulls[shape.resource].hull
        return {hull_core(hull).vertices,hull.convex_radius,0}
    }
    return {}
}

shape_body :: proc(w:^World,h:Shape_Handle) -> Body_Handle {
    shape,_:=shape_read(w,h)
    return shape==nil?{}:body_handle(w,shape.body)
}
shape_type :: proc(w:^World,h:Shape_Handle) -> Shape_Type {
    shape,_:=shape_read(w,h)
    return shape==nil?.Sphere:shape.type
}
// The hull of a hull shape; zero for any other.
shape_hull :: proc(w:^World,h:Shape_Handle) -> Hull_Handle {
    shape,_:=shape_read(w,h)
    if shape==nil || shape.type!=.Hull {return {}}
    return Hull_Handle(base.handle_make(shape.resource,w.hulls[shape.resource].generation))
}
// How much the edges of a box, hull or cylinder are rounded; zero for the other shapes.
shape_convex_radius :: proc(w:^World,h:Shape_Handle) -> f32 {
    shape,_:=shape_read(w,h)
    return shape==nil?0:shape.radius
}
// World box of the shape as of the last step or teleport.
shape_bounds :: proc(w:^World,h:Shape_Handle) -> Aabb {
    shape,_:=shape_read(w,h)
    return shape==nil?{}:shape.aabb
}
shape_world_transform :: proc(w:^World,h:Shape_Handle) -> Transform {
    shape,_:=shape_read(w,h)
    return shape==nil?TRANSFORM_IDENTITY:shape_transform_of(w,shape)
}

shape_local_transform :: proc(w:^World,h:Shape_Handle) -> Transform {
    shape,_:=shape_read(w,h)
    return shape!=nil?shape.local:Transform{}
}
shape_user_data :: proc(w:^World,h:Shape_Handle) -> u64 {
    shape,_:=shape_read(w,h)
    return shape==nil?0:shape.user_data
}
shape_set_user_data :: proc(w:^World,h:Shape_Handle,user_data:u64) {
    shape,_:=shape_get(w,h)
    if shape!=nil {shape.user_data=user_data}
}
shape_filter :: proc(w:^World,h:Shape_Handle) -> Filter {
    shape,_:=shape_read(w,h)
    return shape==nil?{}:shape.filter
}
// The contacts of the shape are discarded and found again at the next step under the new filter.
shape_set_filter :: proc(w:^World,h:Shape_Handle,filter:Filter) {
    shape,index:=shape_get(w,h)
    if shape==nil {return}
    w.grounds_stale=true
    if w.bodies[shape.body].type==.Static && shape.filter!=filter {static_log_push(w,shape.aabb)}
    shape.filter=filter
    shape_destroy_contacts(w,index)
    shape.flags+={.Moved}
    body_wake(w,shape.body)
}
// Takes effect on the contacts of the shape at once, as shape_set_material.
shape_set_rolling_resistance :: proc(w:^World,h:Shape_Handle,rolling_resistance:f32) {
    shape,index:=shape_get(w,h)
    if shape==nil {return}
    shape.rolling_resistance=max(rolling_resistance,0)
    body:=&w.bodies[shape.body]
    for key:=body.contact_list;key>=0; {
        contact:=&w.contacts[key>>1]
        if contact.shape_a==index || contact.shape_b==index {contact_mix_material(w,contact)}
        key=contact.edges[key&1].next
    }
}
// Takes effect on the contacts created from now on.
shape_material :: proc(w:^World,h:Shape_Handle) -> (friction,restitution:f32) {
    shape,_:=shape_read(w,h)
    if shape==nil {return}
    return shape.friction,shape.restitution
}
shape_set_material :: proc(w:^World,h:Shape_Handle,friction,restitution:f32) {
    shape,index:=shape_get(w,h)
    if shape==nil {return}
    shape.friction,shape.restitution=max(friction,0),clamp(restitution,0,1)
    body:=&w.bodies[shape.body]
    for key:=body.contact_list;key>=0; {
        contact:=&w.contacts[key>>1]
        if contact.shape_a==index || contact.shape_b==index {contact_mix_material(w,contact)}
        key=contact.edges[key&1].next
    }
}
// The rules of the contacts of the shape: how its surface moves, whether it blocks only from its +Y side
// and its dominance. They take effect on its contacts at the next step; turning one_way off lets the
// contacts that were going through it block again.
shape_set_surface :: proc(w:^World,h:Shape_Handle,surface_speed:Vec3,one_way:bool,dominance:i8) {
    shape,index:=shape_get(w,h)
    if shape==nil {return}
    shape.surface_speed,shape.dominance=finite_or_zero(surface_speed),i32(dominance)
    if one_way {shape.flags+={.One_Way}} else {shape.flags-={.One_Way}}
    body_wake(w,shape.body)
    body:=&w.bodies[shape.body]
    for key:=body.contact_list;key>=0; {
        contact:=&w.contacts[key>>1]
        side:=key&1
        key=contact.edges[side].next
        if contact.shape_a!=index && contact.shape_b!=index {continue}
        if !one_way && .Pass in contact.flags {stamp(w,contact);contact.flags-={.Pass}}
        body_wake(w,side==0?contact.body_b:contact.body_a)
    }
}
shape_surface :: proc(w:^World,h:Shape_Handle) -> (surface_speed:Vec3,one_way:bool,dominance:i8) {
    shape,_:=shape_read(w,h)
    if shape==nil {return}
    return shape.surface_speed,.One_Way in shape.flags,i8(shape.dominance)
}

// Changes the drag coefficient of a shape in a fluid; zero or less takes the measured value of its form.
shape_set_drag :: proc(w:^World,h:Shape_Handle,drag:f32) {
    shape,_:=shape_get(w,h)
    if shape==nil {return}
    shape.drag=drag>0 && drag<=max(f32)?drag:shape_drag_default(shape.type)
}
shape_drag :: proc(w:^World,h:Shape_Handle) -> f32 {
    shape,_:=shape_read(w,h)
    return shape!=nil?shape.drag:0
}

@(private)
finite_or_zero :: proc "contextless" (v:Vec3) -> Vec3 {
    for x in v {
        if !(x>=-max(f32) && x<=max(f32)) {return {}}
    }
    return v
}

shape_set_density :: proc(w:^World,h:Shape_Handle,density:f32) {
    shape,_:=shape_get(w,h)
    if shape==nil {return}
    shape.density=max(density,0)
    body_update_mass(w,shape.body)
}

// Box stored in the tree: the shape may move inside it without touching the tree. Small shapes get a
// small margin, so that a pile of them does not pair every shape with all of its neighbors.
@(private)
shape_fat :: #force_inline proc "contextless" (aabb:Aabb) -> Aabb {
    extent:=aabb.max-aabb.min
    return math.aabb_expand(aabb,min(AABB_MARGIN,0.125*max(extent.x,extent.y,extent.z)))
}
