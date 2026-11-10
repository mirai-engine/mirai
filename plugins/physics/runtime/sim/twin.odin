package mirai_physics

import "mirai:std/base"
import "mirai:std/spatial"
import math "mirai:std/math"

// Two rules that take part of a shape out of the world and put a body in two
// places at once, as an opening that leads somewhere else needs.
//
// A cut is a box where a shape, or every shape of a body, is not: its contacts
// with points inside it do not count, and queries do not hit it there.
//
// A twin is a second place of a body: copies of its shapes sit where a rigid
// transform carries them, collide only in front of a plane, and their contacts
// act on the body through the transform. The contact is solved in the frame of
// the body, so for the body it is one more contact, and the other side feels it
// where the copy is.

CUT_CAPACITY :: 32
TWIN_CAPACITY :: 8

// An oriented box in the world.
Region :: struct {
    center:Vec3,
    rotation:Quat,
    half:Vec3,
}

// Inside `region` the shape is not there; without `shape`, every shape of `body` but its twins.
Cut :: struct {
    body:Body_Handle,
    shape:Shape_Handle,
    region:Region,
}
#assert(size_of(Cut)==56)

@(private)
Twin :: struct {
    body:Body_Handle,
    shapes:i32, // first copy, linked by next and prev
    count:i32,
    through:Transform,
    front:Plane, // the copies collide where dot(n,p)>=d
    _:u32,
}
#assert(size_of(Twin)==64)

region_contains :: #force_inline proc "contextless" (region:Region,p:Vec3) -> bool {
    local:=q_inv_rotate(region.rotation,p-region.center)
    return abs(local.x)<=region.half.x && abs(local.y)<=region.half.y && abs(local.z)<=region.half.z
}

// Replaces the cuts of the world; the rotation of a region is a unit quaternion. False, changing nothing,
// for more than CUT_CAPACITY cuts or a region that is not finite. Cuts of handles that are no longer live
// do nothing. Setting the cuts the world has changes nothing either.
world_set_cuts :: proc(w:^World,cuts:[]Cut) -> bool {
    if len(cuts)>CUT_CAPACITY {return false}
    for cut in cuts {
        r:=cut.region
        q:=r.rotation.x+r.rotation.y+r.rotation.z+r.rotation.w
        if !is_finite3(r.center) || !is_finite3(r.half) || q-q!=0 {return false}
    }
    same:=int(w.cut_count)==len(cuts)
    for cut,i in cuts {same=same && w.cuts[i]==cut}
    if same {return true}
    // Bodies near the cuts that go away wake as well.
    for cut in w.cuts[:w.cut_count] {
        if body,index:=body_get(w,cut.body);body!=nil {
            body_wake(w,index)
        } else if shape,_:=shape_get(w,cut.shape);shape!=nil {
            body_wake(w,shape.body)
        }
    }
    w.cuts={}
    copy(w.cuts[:],cuts)
    w.cut_count=i32(len(cuts))
    // Contacts that the cuts change come back at the next narrow phase; sleepers near them wake.
    for cut in cuts {
        if body,index:=body_get(w,cut.body);body!=nil {
            body_wake(w,index)
        } else if shape,_:=shape_get(w,cut.shape);shape!=nil {
            body_wake(w,shape.body)
        }
    }
    w.grounds_stale=true
    return true
}
world_cuts :: proc(w:^World) -> []Cut {return w.cuts[:w.cut_count]}

// Gives the body a twin where `through` carries it, colliding only in front of the plane through `point`
// facing `normal`, or moves the one it has; the same values change nothing. Its shapes made later get
// their copy too. False for a static body, without room among TWIN_CAPACITY twins or for the copies, or
// for values that are not finite.
body_set_twin :: proc(w:^World,h:Body_Handle,through:Transform,point,normal:Vec3) -> bool {
    body,index:=body_get(w,h)
    if body==nil || body.type==.Static {return false}
    n:=normalize(normal)
    if !is_finite3(through.p) || !is_finite3(point) || n=={} {return false}
    q:=through.q.x+through.q.y+through.q.z+through.q.w
    if q-q!=0 {return false}
    rotation:=q_normalize(through.q)
    carried:=Transform{through.p,rotation}
    front:=Plane{n,dot(n,point)}
    t:=twin_find(w,index)
    if t!=nil && t.through==carried && t.front==front {return true}
    if t==nil {
        if w.twin_count>=TWIN_CAPACITY {return false}
        t=&w.twins[w.twin_count]
        w.twin_count+=1
        t^={body=h,shapes=-1,through=carried,front=front}
        for s:=body.shape_list;s>=0;s=w.shapes[s].next {
            if twin_shape_create(w,t,s)<0 {
                body_clear_twin(w,h)
                return false
            }
        }
    }
    t.through,t.front=carried,front
    twin_refresh(w,t)
    body_wake(w,index)
    return true
}

body_clear_twin :: proc(w:^World,h:Body_Handle) {
    body,index:=body_get(w,h)
    if body==nil {return}
    t:=twin_find(w,index)
    if t==nil {return}
    for t.shapes>=0 {twin_shape_destroy(w,t,t.shapes)}
    last:=&w.twins[w.twin_count-1]
    if t!=last {t^=last^}
    last^={}
    w.twin_count-=1
    body_wake(w,index)
}

// The twin of the body: where it carries the body and the plane its copies collide in front of.
body_twin :: proc(w:^World,h:Body_Handle) -> (through:Transform,point,normal:Vec3,ok:bool) {
    body,index:=body_get(w,h)
    if body==nil {return}
    t:=twin_find(w,index)
    if t==nil {return}
    return t.through,t.front.n*t.front.d,t.front.n,true
}

// The bodies that have a twin, written to `out`; returns how many there are.
world_twins :: proc(w:^World,out:[]Body_Handle) -> int {
    for t,i in w.twins[:w.twin_count] {
        if i<len(out) {out[i]=t.body}
    }
    return int(w.twin_count)
}

// The box of the shapes of the body as of the last step or teleport, without the copies of its twin.
body_bounds :: proc(w:^World,h:Body_Handle) -> (box:Aabb,ok:bool) {
    body,_:=body_get(w,h)
    if body==nil || body.shape_list<0 {return}
    box=w.shapes[body.shape_list].aabb
    for s:=w.shapes[body.shape_list].next;s>=0;s=w.shapes[s].next {box=math.aabb_merge(box,w.shapes[s].aabb)}
    return box,true
}

// Whether the shape is a copy of a twin.
shape_is_twin :: proc(w:^World,h:Shape_Handle) -> bool {
    shape,_:=shape_get(w,h)
    return shape!=nil && .Twin in shape.flags
}

@(private)
twin_find :: #force_inline proc "contextless" (w:^World,body:i32) -> ^Twin #no_bounds_check {
    for &t in w.twins[:w.twin_count] {
        if i32(base.handle_index(base.Handle(t.body)))==body {return &t}
    }
    return nil
}

// Where the twin of the body of a copy carries it; identity for any other shape.
@(private)
twin_through :: #force_inline proc "contextless" (w:^World,shape:^Shape) -> Transform {
    if .Twin not_in shape.flags {return TRANSFORM_IDENTITY}
    if t:=twin_find(w,shape.body);t!=nil {return t.through}
    return TRANSFORM_IDENTITY
}

@(private)
twin_shape_create :: proc(w:^World,t:^Twin,source:i32) -> i32 {
    index:=w.shape_free
    if index<0 && int(w.shape_high)>=len(w.shapes) {
        w.stats.shape_capacity_exhausted+=1
        return -1
    }
    if index>=0 {
        w.shape_free=w.shapes[index].next
    } else {
        index=w.shape_high
        w.shape_high+=1
    }
    w.shape_count+=1
    shape:=&w.shapes[index]
    generation:=shape.generation+1
    shape^=w.shapes[source]
    shape.generation=generation
    shape.flags=shape.flags-{.Moved}+{.Twin}
    shape_moved(w,index)
    shape.source=source
    shape.next,shape.prev=t.shapes,-1
    if t.shapes>=0 {w.shapes[t.shapes].prev=index}
    t.shapes=index
    t.count+=1
    if .Hits in shape.flags {w.hit_shapes+=1}
    shape_refs_add(w,shape,1)
    shape.aabb=shape_aabb(w,shape,xf_mul(t.through,body_transform_of(&w.bodies[shape.body])))
    shape.fat=shape_fat(shape.aabb)
    shape.proxy,_=spatial.dynamic_tree_insert(&w.trees[DYNAMIC_TREE],shape.fat,u64(index))
    w.grounds_stale=true
    return index
}

@(private)
twin_shape_destroy :: proc(w:^World,t:^Twin,index:i32) {
    w.grounds_stale=true
    shape:=&w.shapes[index]
    shape_destroy_contacts(w,index)
    spatial.dynamic_tree_remove(&w.trees[DYNAMIC_TREE],shape.proxy)
    if shape.prev>=0 {w.shapes[shape.prev].next=shape.next} else {t.shapes=shape.next}
    if shape.next>=0 {w.shapes[shape.next].prev=shape.prev}
    t.count-=1
    if .Hits in shape.flags {w.hit_shapes-=1}
    shape_refs_add(w,shape,-1)
    shape_unmoved(w,index)
    shape.generation+=1
    shape.flags={}
    shape.next=w.shape_free
    w.shape_free=index
    w.shape_count-=1
}

// A shape of a body with a twin was made or is going away: so is its copy.
@(private)
twin_source_added :: proc(w:^World,body,source:i32) {
    if t:=twin_find(w,body);t!=nil {
        if twin_shape_create(w,t,source)<0 {body_clear_twin(w,t.body)}
    }
}
@(private)
twin_source_removed :: proc(w:^World,body,source:i32) {
    t:=twin_find(w,body)
    if t==nil {return}
    for s:=t.shapes;s>=0; {
        next:=w.shapes[s].next
        if w.shapes[s].source==source {twin_shape_destroy(w,t,s)}
        s=next
    }
}

// Takes what the shapes of the body are now into their copies and puts the copies where the twin
// carries them. A copy that took another filter meets the others again.
@(private)
twin_refresh :: proc(w:^World,t:^Twin) #no_bounds_check {
    body:=&w.bodies[base.handle_index(base.Handle(t.body))]
    xf:=xf_mul(t.through,body_transform_of(body))
    motion:=q_rotate(t.through.q,body.linear_velocity)*w.step.dt
    tree:=&w.trees[DYNAMIC_TREE]
    for s:=t.shapes;s>=0;s=w.shapes[s].next {
        shape:=&w.shapes[s]
        source:=&w.shapes[shape.source]
        if shape.filter!=source.filter {
            shape.filter=source.filter
            shape_destroy_contacts(w,s)
            shape_moved(w,s)
        }
        shape.local,shape.size,shape.radius=source.local,source.size,source.radius
        shape.friction,shape.restitution,shape.rolling_resistance=source.friction,source.restitution,source.rolling_resistance
        shape.surface_speed,shape.dominance,shape.drag=source.surface_speed,source.dominance,source.drag
        shape.flags=shape.flags-{.One_Way}+(source.flags&{.One_Way})
        shape.aabb=shape_aabb(w,shape,xf)
        reach:=spatial.aabb_translate_extend(shape.aabb,motion)
        if !math.aabb_contains(shape.fat,reach) {
            shape.fat=shape_fat(reach)
            shape_moved(w,s)
            spatial.dynamic_tree_move(tree,shape.proxy,shape.fat)
        }
    }
}

@(private)
twins_refresh :: proc(w:^World) {
    for &t in w.twins[:w.twin_count] {twin_refresh(w,&t)}
}

// Whether a point of a contact or a hit of the shape is where the shape is not: behind the plane of the
// twin it is a copy of, or inside a cut of it.
@(private)
point_cut :: proc "contextless" (w:^World,index:i32,shape:^Shape,p:Vec3) -> bool #no_bounds_check {
    if .Twin in shape.flags {
        if t:=twin_find(w,shape.body);t!=nil && dot(t.front.n,p)<t.front.d {return true}
    }
    if w.cut_count==0 {return false}
    handle:=shape_handle(w,index)
    body:=body_handle(w,shape.body)
    for &cut in w.cuts[:w.cut_count] {
        applies:=cut.shape!={}?cut.shape==handle:cut.body==body && .Twin not_in shape.flags
        if applies && region_contains(cut.region,p) {return true}
    }
    return false
}

// Whether a cut of the shape reaches into a world box: near it, a bullet leaves the shape to the contacts.
@(private)
cut_touches :: proc "contextless" (w:^World,index:i32,shape:^Shape,box:Aabb) -> bool #no_bounds_check {
    handle:=shape_handle(w,index)
    body:=body_handle(w,shape.body)
    for &cut in w.cuts[:w.cut_count] {
        if !(cut.shape!={}?cut.shape==handle:cut.body==body && .Twin not_in shape.flags) {continue}
        m:=q_matrix(cut.region.rotation)
        h:=cut.region.half
        d:=vabs(Vec3{m[0,0],m[1,0],m[2,0]})*h.x+vabs(Vec3{m[0,1],m[1,1],m[2,1]})*h.y+vabs(Vec3{m[0,2],m[1,2],m[2,2]})*h.z
        if math.aabb_overlaps({cut.region.center-d,cut.region.center+d},box) {return true}
    }
    return false
}

// Drops the points of the manifolds that a twin or a cut takes away, and the manifolds left empty.
@(private)
manifolds_cut :: proc "contextless" (w:^World,contact:^Contact,a,b:^Shape,xf_a:Transform,locals:^[1+EXTRA_MANIFOLDS]Local_Manifold,count:int) -> int #no_bounds_check {
    kept:=0
    for m in 0..<count {
        local:=&locals[m]
        points:i32
        for i in 0..<int(local.count) {
            lp:=local.points[i]
            p:=xf_point(xf_a,lp.point+local.normal*(0.5*lp.separation))
            if point_cut(w,contact.shape_a,a,p) || point_cut(w,contact.shape_b,b,p) {continue}
            local.points[points]=lp
            points+=1
        }
        local.count=points
        if points==0 {continue}
        if kept!=m {locals[kept]=local^}
        kept+=1
    }
    return kept
}

// Where the frame a contact is solved in sits in the world: that of the body of a copy, carried by its
// twin; the world for a contact without copies. The copy of shape A gives it when both are copies.
@(private)
contact_through :: #force_inline proc "contextless" (w:^World,contact:^Contact) -> Transform {
    a,b:=&w.shapes[contact.shape_a],&w.shapes[contact.shape_b]
    if .Twin in a.flags {return twin_through(w,a)}
    return twin_through(w,b)
}

// How the side of a contact that is not in the frame of the contact turns into it: `side` 1 for A, 2 for
// B, 0 when neither turns.
@(private)
contact_turn :: #force_inline proc "contextless" (w:^World,contact:^Contact) -> (turn:Quat,side:i32) {
    a,b:=&w.shapes[contact.shape_a],&w.shapes[contact.shape_b]
    turn=QUAT_IDENTITY
    if .Twin not_in (a.flags+b.flags) {return}
    if .Twin in a.flags {
        turn,side=conj(twin_through(w,a).q)*twin_through(w,b).q,2
    } else {
        turn,side=conj(twin_through(w,b).q),1
    }
    if abs(turn.w)>=1-1e-7 {return QUAT_IDENTITY,0}
    return
}
