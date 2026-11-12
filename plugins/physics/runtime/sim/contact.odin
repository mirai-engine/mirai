package mirai_physics

import cmath "core:math"
import "core:slice"
import "core:sync"
import "mirai:std/spatial"
import math "mirai:std/math"

@(private)
contact_mix_material :: proc "contextless" (w:^World,contact:^Contact) {
    a,b:=&w.shapes[contact.shape_a],&w.shapes[contact.shape_b]
    stamp(w,contact)
    contact.friction=cmath.sqrt(a.friction*b.friction)
    contact.restitution=max(a.restitution,b.restitution)
    contact.rolling_resistance=max(a.rolling_resistance,b.rolling_resistance)
}

// Links a new contact between two shapes of different bodies. The shape of the higher type is A, so
// the narrow phase needs one routine per unordered pair of types.
@(private)
contact_create :: proc(w:^World,shape_a,shape_b:i32) -> i32 {
    index:=w.contact_free
    if index>=0 {
        w.contact_free=w.contacts[index].shape_a
    } else if int(w.contact_high)<len(w.contacts) {
        index=w.contact_high
        w.contact_high+=1
    } else {
        w.stats.contact_capacity_exhausted+=1
        return -1
    }
    w.contact_count+=1
    a,b:=shape_a,shape_b
    if w.shapes[a].type<w.shapes[b].type || (w.shapes[a].type==w.shapes[b].type && a>b) {a,b=b,a}
    contact:=&w.contacts[index]
    contact^={shape_a=a,shape_b=b,body_a=w.shapes[a].body,body_b=w.shapes[b].body,extra=-1}
    if filter_response(w.shapes[a].filter,w.shapes[b].filter)==.Overlap {contact.flags+={.Overlap}}
    contact_mix_material(w,contact)
    if w.shapes[a].type>=.Mesh {
        // A shape can rest on several faces of a mesh: room for more manifolds, if any is left.
        if block:=w.block_free;block>=0 {
            w.block_free=w.blocks[block].next_free
            contact.extra=block
        } else if int(w.block_high)<len(w.blocks) {
            contact.extra=w.block_high
            w.block_high+=1
        } else {
            w.stats.manifold_capacity_exhausted+=1
        }
        if contact.extra>=0 {stamp(w,.Blocks,contact.extra);w.blocks[contact.extra]={}}
    }
    for body_index,side in ([2]i32{contact.body_a,contact.body_b}) {
        body:=&w.bodies[body_index]
        stamp(w,body)
        key:=index<<1|i32(side)
        contact.edges[side]={-1,body.contact_list}
        if body.contact_list>=0 {stamp(w,.Contacts,body.contact_list>>1);w.contacts[body.contact_list>>1].edges[body.contact_list&1].prev=key}
        body.contact_list=key
        body.contact_count+=1
    }
    return index
}

@(private)
contact_destroy :: proc(w:^World,index:i32,wake:=true) {
    contact:=&w.contacts[index]
    if contact.flags&{.Touching,.Overlap}=={.Touching} {island_unlink(w,contact.body_a,contact.body_b)}
    if wake && contact.flags&{.Touching,.Overlap}=={.Touching} {
        for body_index in ([2]i32{contact.body_a,contact.body_b}) {
            body:=&w.bodies[body_index]
            // One without an island is changing type (body_set_type), which wakes it.
            if body.type!=.Static && .Awake not_in body.flags && body.island>=0 {body_wake(w,body_index)}
        }
    }
    for body_index,side in ([2]i32{contact.body_a,contact.body_b}) {
        body:=&w.bodies[body_index]
        stamp(w,body)
        edge:=contact.edges[side]
        if edge.prev>=0 {stamp(w,.Contacts,edge.prev>>1);w.contacts[edge.prev>>1].edges[edge.prev&1].next=edge.next} else {body.contact_list=edge.next}
        if edge.next>=0 {stamp(w,.Contacts,edge.next>>1);w.contacts[edge.next>>1].edges[edge.next&1].prev=edge.prev}
        body.contact_count-=1
    }
    if contact.extra>=0 {
        stamp(w,.Blocks,contact.extra)
        w.blocks[contact.extra].next_free=w.block_free
        w.block_free=contact.extra
    }
    stamp(w,contact)
    contact^={shape_a=w.contact_free,shape_b=-1,extra=-1}
    w.contact_free=index
    w.contact_count-=1
}

filter_response :: #force_inline proc "contextless" (a,b:Filter) -> Response {
    if a.group!=0 && a.group==b.group {return .Ignore}
    if (a.block|a.overlap)&b.layers==0 || (b.block|b.overlap)&a.layers==0 {return .Ignore}
    return a.block&b.layers!=0 && b.block&a.layers!=0?.Block:.Overlap
}

@(private)
shapes_should_collide :: proc "contextless" (w:^World,a,b:^Shape) -> bool #no_bounds_check {
    if a.body==b.body {return false}
    response:=filter_response(a.filter,b.filter)
    if response==.Ignore || a.type>=.Mesh && b.type>=.Mesh {return false}
    body_a,body_b:=&w.bodies[a.body],&w.bodies[b.body]
    if .Debris in (body_a.flags+body_b.flags) && ((body_a.type!=.Static && body_b.type!=.Static) || response==.Overlap) {return false}
    if body_a.type!=.Dynamic && body_b.type!=.Dynamic {
        // Without a dynamic body only an overlap against a moving body reports anything.
        if response!=.Overlap || (body_a.type==.Static && body_b.type==.Static) {return false}
    }
    from:=body_a.joint_list
    other:=b.body
    for key:=from;key>=0; {
        joint:=&w.joints[key>>1]
        side:=key&1
        if (side==0?joint.body_b:joint.body_a)==other && .Collide_Connected not_in joint.flags {return false}
        key=joint.edges[side].next
    }
    return true
}

@(private)
contact_find :: proc "contextless" (w:^World,shape_a,shape_b:i32) -> i32 #no_bounds_check {
    body_a,body_b:=&w.bodies[w.shapes[shape_a].body],&w.bodies[w.shapes[shape_b].body]
    body:=body_a.contact_count<=body_b.contact_count?body_a:body_b
    for key:=body.contact_list;key>=0; {
        contact:=&w.contacts[key>>1]
        if (contact.shape_a==shape_a && contact.shape_b==shape_b) || (contact.shape_a==shape_b && contact.shape_b==shape_a) {return key>>1}
        key=contact.edges[key&1].next
    }
    return -1
}

@(private) PAIR_BATCH :: 64 // pairs a worker gathers before it takes room in the shared buffer

// Takes room for a batch of pairs in the shared buffer and writes the part that fits. The room taken goes on
// past the buffer when the pairs do not fit: the broad phase then runs again on one thread, which fills it
// the same way every time.
@(private)
pairs_flush :: proc "contextless" (st:^Step,batch:[]u64) {
    if len(batch)==0 {return}
    first:=sync.atomic_add(&st.pair_count,len(batch))
    if first<len(st.pairs) {copy(st.pairs[first:],batch)}
}

@(private)
pairs_task :: proc(data:rawptr,first,last,worker:int) #no_bounds_check {
    w:=(^World)(data)
    st:=&w.step
    batch:[PAIR_BATCH]u64=---
    count:=0
    for i in first..<last {
        index:=st.moved[i]
        shape:=&w.shapes[index]
        is_static:=w.bodies[shape.body].type==.Static
        for tree in ([2]int{DYNAMIC_TREE,STATIC_TREE}) {
            if tree==STATIC_TREE && is_static {continue}
            query:=spatial.dynamic_tree_query(&w.trees[tree],shape.fat)
            for _,user in spatial.tree_query_next(&query) {
                other_index:=i32(user)
                if other_index==index {continue}
                other:=&w.shapes[other_index]
                // When both moved, each finds the other: the lower index reports the pair.
                if .Moved in other.flags && other_index<index {continue}
                if !shapes_should_collide(w,shape,other) || contact_find(w,index,other_index)>=0 {continue}
                batch[count]=u64(min(index,other_index))<<32|u64(max(index,other_index))
                count+=1
                if count==PAIR_BATCH {
                    pairs_flush(st,batch[:])
                    count=0
                }
            }
        }
    }
    pairs_flush(st,batch[:count])
}

// Broad phase: new contacts for the shapes that were created or left their fat boxes.
@(private)
pairs_update :: proc(w:^World) {
    st:=&w.step
    moved:=0
    for i:=w.moved_head;i>=0;i=w.shapes[i].moved_next {
        st.moved[moved]=i
        moved+=1
    }
    if moved==0 {return}
    st.pair_count=0
    world_parallel(w,moved,64,w,pairs_task)
    overflow:=st.pair_count>len(st.pairs)
    if overflow {
        // Which pairs fit must not depend on how the workers split the shapes.
        st.pair_count=0
        pairs_task(w,0,moved,0)
    }
    total:=min(st.pair_count,len(st.pairs))
    // Sorted, the pairs do not depend on the order in which the workers found them.
    slice.sort(st.pairs[:total])
    for pair in st.pairs[:total] {
        if contact_create(w,i32(pair>>32),i32(pair&0xffffffff))<0 {overflow=true}
    }
    // Pairs that did not fit are searched again at the next step.
    if !overflow {
        for i in st.moved[:moved] {stamp(w,.Shapes,i);w.shapes[i].flags-={.Moved}}
        w.moved_head=-1
    }
}

@(private)
shapes_collide :: proc(w:^World,a,b:^Shape,xf:Transform,speculative:f32,out:^[1+EXTRA_MANIFOLDS]Local_Manifold,sat:^Sat_Cache) -> int #no_bounds_check {
    m:=&out[0]
    m.count=0
    switch a.type {
    case .Sphere:
        collide_spheres(m,{},a.size.x,xf.p,b.size.x,speculative)
    case .Capsule:
        p,q:=Vec3{0,-a.size.y,0},Vec3{0,a.size.y,0}
        if b.type==.Sphere {
            collide_capsule_sphere(m,p,q,a.size.x,xf.p,b.size.x,speculative)
        } else {
            axis:=q_rotate(xf.q,{0,b.size.y,0})
            collide_capsules(m,p,q,a.size.x,xf.p-axis,xf.p+axis,b.size.x,speculative)
        }
    case .Box,.Hull:
        if a.radius+b.radius>0 {
            collide_rounded(w,m,a,b,xf,speculative,sat)
            break
        }
        storage_a,storage_b:Box_Hull=---,---
        scaled_a,scaled_b:Scaled_Hull=---,---
        hull_a:=a.type==.Box?box_hull(&storage_a,a.size):shape_hull_of(w,a,false,&scaled_a)^
        #partial switch b.type {
        case .Sphere:
            collide_hull_sphere(m,&hull_a,xf.p,b.size.x,speculative)
        case .Capsule:
            axis:=q_rotate(xf.q,{0,b.size.y,0})
            collide_hull_capsule(m,&hull_a,xf.p-axis,xf.p+axis,b.size.x,speculative)
        case .Box,.Hull:
            if a.type==.Box && b.type==.Box {
                collide_boxes(m,a.size,b.size,xf,speculative)
                break
            }
            hull_b:=b.type==.Box?box_hull(&storage_b,b.size):shape_hull_of(w,b,false,&scaled_b)^
            collide_hulls(m,&hull_a,&hull_b,xf,speculative,sat)
        }
    case .Cylinder:
        collide_cylinder(w,m,a,b,xf,speculative)
    case .Mesh:
        return mesh_collide(w,&w.meshes[a.resource].mesh,b,xf,speculative,out)
    case .Heightfield:
        return heightfield_collide(w,&w.heightfields[a.resource].field,b,xf,speculative,out)
    }
    return m.count>0?1:0
}

// Carries the impulses of the points that persist: matched by feature id, or else by position on shape A,
// because clipping near-coincident edges names the same point differently from one step to the next.
@(private)
manifold_state_update :: proc "contextless" (state:^Manifold_State,local:^Local_Manifold) #no_bounds_check {
    old:=state^
    state.count=local.count
    state.normal=local.count>0?local.normal:{}
    used,matched:[MANIFOLD_MAX_POINTS]bool
    for i in 0..<int(local.count) {
        id:=local.points[i].id
        state.ids[i]=id
        state.points[i]=local.points[i].point
        state.separations[i]=local.points[i].separation
        state.normal_impulses[i]=0
        for j in 0..<int(old.count) {
            if old.ids[j]==id && !used[j] {
                state.normal_impulses[i]=old.normal_impulses[j]
                used[j],matched[i]=true,true
                break
            }
        }
    }
    for i in 0..<int(local.count) {
        if matched[i] {continue}
        nearest:=-1
        nearest_distance:f32=MATCH_DISTANCE*MATCH_DISTANCE
        for j in 0..<int(old.count) {
            if used[j] {continue}
            if d:=length2(old.points[j]-local.points[i].point);d<nearest_distance {nearest=j;nearest_distance=d}
        }
        if nearest>=0 {
            state.normal_impulses[i]=old.normal_impulses[nearest]
            used[nearest]=true
        }
    }
    if local.count==0 || old.count==0 {
        state.friction_impulse={}
        state.twist_impulse=0
        state.rolling_impulse={}
    }
}

@(private)
manifold_to_world :: proc "contextless" (out:^Manifold,local:^Local_Manifold,xf:Transform,center_a,center_b:Vec3) #no_bounds_check {
    out.normal=q_rotate(xf.q,local.normal)
    out.count=local.count
    for i in 0..<int(local.count) {
        point:=xf_point(xf,local.points[i].point)
        out.points[i]={point-center_a,point-center_b,point,local.points[i].separation,0,0}
    }
}

@(private) CARRY_DISTANCE :: 0.001 // m that B may move in the frame of A before its manifolds are collided again
@(private) CARRY_COS :: 0.9998477 // cosine of half the 2 degrees that B may turn in the frame of A

// The manifolds of the last narrow phase with B at `relative` in the frame of A: each point keeps its place on
// A and its place on B moves with B, so the separation follows the motion along the normal.
@(private)
manifolds_carry :: proc "contextless" (w:^World,contact:^Contact,relative:Transform,out:^[1+EXTRA_MANIFOLDS]Local_Manifold,count:int) #no_bounds_check {
    move:=xf_mul(relative,xf_inv(contact.relative))
    for m in 0..<count {
        state:=m==0?&contact.manifold:&w.blocks[contact.extra].manifolds[m-1]
        local:=&out[m]
        local.normal,local.count=state.normal,state.count
        for i in 0..<int(state.count) {
            half:=0.5*state.separations[i]*state.normal
            on_a,on_b:=state.points[i]-half,xf_point(move,state.points[i]+half)
            local.points[i]={0.5*(on_a+on_b),dot(on_b-on_a,state.normal),state.ids[i]}
        }
    }
}

// Narrow phase of one contact. Writes only to the contact and its manifolds, so contacts update in parallel.
@(private)
contact_update :: proc(w:^World,index:i32) #no_bounds_check {
    contact:=&w.contacts[index]
    a,b:=&w.shapes[contact.shape_a],&w.shapes[contact.shape_b]
    stamp(w,contact)
    if contact.extra>=0 {stamp(w,.Blocks,contact.extra)}
    contact.flags-={.Started,.Stopped,.Disjoint}
    was_touching:=.Touching in contact.flags
    if !math.aabb_overlaps(a.fat,b.fat) {
        contact.flags+={.Disjoint}
        if was_touching {contact.flags=contact.flags-{.Touching}+{.Stopped}}
        return
    }
    body_a,body_b:=&w.bodies[contact.body_a],&w.bodies[contact.body_b]
    xf_a:=shape_transform_of(w,a)
    xf_b:=shape_transform_of(w,b)
    overlap:=.Overlap in contact.flags
    locals:[1+EXTRA_MANIFOLDS]Local_Manifold=---
    speculative:f32=SPECULATIVE_DISTANCE
    if .Character in (body_a.flags+body_b.flags) {speculative+=length(body_b.linear_velocity-body_a.linear_velocity)*w.step.dt}
    relative:=xf_inv_mul(xf_a,xf_b)
    // Jolt's body pair cache: a pair that barely moved since its last narrow phase keeps its manifolds,
    // moved with B. What the narrow phase decides beyond geometry (overlaps, one-way shapes, characters, twins
    // and cuts) always collides.
    carry:=!overlap && w.cut_count==0 && (a.flags+b.flags)&{.One_Way,.Twin}=={} && .Character not_in (body_a.flags+body_b.flags)
    count:int
    if carry && length2(relative.p-contact.relative.p)<=CARRY_DISTANCE*CARRY_DISTANCE && abs(q_dot(relative.q,contact.relative.q))>=CARRY_COS {
        count=int(contact.manifold_count)
        manifolds_carry(w,contact,relative,&locals,count)
        contact.flags+={.Carried}
    } else {
        count=shapes_collide(w,a,b,relative,overlap?0:speculative,&locals,&contact.sat)
        contact.relative=carry?relative:{}
        contact.flags-={.Carried}
    }
    if count>0 && (w.cut_count>0 || .Twin in (a.flags+b.flags)) {count=manifolds_cut(w,contact,a,b,xf_a,&locals,count)}
    // A shape that meets a one-way shape from its back goes through it for as long as the two touch.
    if count>0 && !overlap && .One_Way in (a.flags+b.flags) {
        if .Pass in contact.flags || !was_touching && !one_way_blocks(a,b,xf_a,xf_b,&locals[0],body_b.linear_velocity-body_a.linear_velocity,w.step.dt) {
            contact.flags+={.Pass}
            count=0
        }
    } else if count==0 {
        contact.flags-={.Pass}
    }
    if overlap {
        contact.manifold_count=0
        contact.manifold.count=0
    } else {
        if count>1 && contact.extra<0 {count=1}
        contact.manifold_count=i32(count)
        if count==0 {locals[0].count=0}
        // A contact of a copy of a twin is solved in the frame of the body of the copy.
        frame:=xf_a
        center_a,center_b:=body_a.center,body_b.center
        if .Twin in (a.flags+b.flags) {
            to:=xf_inv(contact_through(w,contact))
            frame=xf_mul(to,xf_a)
            center_a=xf_point(to,xf_point(twin_through(w,a),center_a))
            center_b=xf_point(to,xf_point(twin_through(w,b),center_b))
        }
        carried:=.Carried in contact.flags
        if !carried {manifold_state_update(&contact.manifold,&locals[0])}
        manifold_to_world(&w.manifolds[index],&locals[0],frame,center_a,center_b)
        if contact.extra>=0 {
            block:=&w.blocks[contact.extra]
            for i in 1..=EXTRA_MANIFOLDS {
                if i>=count {locals[i].count=0}
                if !carried {manifold_state_update(&block.manifolds[i-1],&locals[i])}
                manifold_to_world(&w.extra_manifolds[contact.extra][i-1],&locals[i],frame,center_a,center_b)
            }
        }
    }
    touching:=count>0
    if touching {contact.flags+={.Touching}} else {contact.flags-={.Touching}}
    if touching && !was_touching {contact.flags+={.Started}}
    if !touching && was_touching {contact.flags+={.Stopped}}
}

@(private) ONE_WAY_COS :: 0.7    // the normal of a contact leans at least this much toward the open side of a one-way shape
@(private) ONE_WAY_DEPTH :: 0.05 // m besides what they closed in the last step: deeper, they came in through the back or the side

// Whether two shapes that begin to touch meet each one-way shape among them from the side it blocks.
// `relative` is the velocity of B less that of A.
@(private)
one_way_blocks :: proc "contextless" (a,b:^Shape,xf_a,xf_b:Transform,local:^Local_Manifold,relative:Vec3,dt:f32) -> bool #no_bounds_check {
    normal:=q_rotate(xf_a.q,local.normal)
    depth:=ONE_WAY_DEPTH+max(-dot(relative,normal),0)*dt
    for i in 0..<int(local.count) {
        if local.points[i].separation< -depth {return false}
    }
    if .One_Way in a.flags && dot(normal,q_rotate(xf_a.q,UP))<ONE_WAY_COS {return false}
    if .One_Way in b.flags && dot(normal,q_rotate(xf_b.q,UP))> -ONE_WAY_COS {return false}
    return true
}

// Whether a bullet that moves by `motion` relative to a one-way shape comes at it from the back, or is going
// through it already: then it does not stop there.
@(private)
one_way_passes :: proc "contextless" (w:^World,contact:i32,one_way:^Shape,motion:Vec3) -> bool {
    if .One_Way not_in one_way.flags {return false}
    if contact>=0 && .Pass in w.contacts[contact].flags {return true}
    return dot(motion,q_rotate(shape_transform_of(w,one_way).q,UP))>=0
}

@(private)
narrow_task :: proc(data:rawptr,first,last,worker:int) #no_bounds_check {
    w:=(^World)(data)
    for i in first..<last {contact_update(w,w.step.active[i])}
}

@(private)
contact_handles :: proc(w:^World,contact:^Contact) -> (shape_a,shape_b:Shape_Handle,body_a,body_b:Body_Handle) {
    return shape_handle(w,contact.shape_a),shape_handle(w,contact.shape_b),body_handle(w,contact.body_a),body_handle(w,contact.body_b)
}

// The user data of two shapes and of their bodies, and the same seen from the second shape.
@(private)
event_users :: proc "contextless" (w:^World,shape_a,shape_b:i32) -> (users,swapped:Event_Users) #no_bounds_check {
    a,b:=&w.shapes[shape_a],&w.shapes[shape_b]
    users={w.bodies[a.body].user_data,w.bodies[b.body].user_data,a.user_data,b.user_data}
    return users,{users.body_b,users.body_a,users.shape_b,users.shape_a}
}

// Whether two bodies overlap by another pair of shapes of the same users as those of contact: the pieces of
// one sensor (an outline, a hull of several pieces) are one overlap, which begins with the first pair and
// ends with the last. Of pairs that begin, or end, in the same step, the first in the contacts speaks.
@(private)
overlap_shared :: proc "contextless" (w:^World,contact:^Contact,ending:bool) -> bool #no_bounds_check {
    users:=[2]u64{w.shapes[contact.shape_a].user_data,w.shapes[contact.shape_b].user_data}
    self:=(uintptr(contact)-uintptr(&w.contacts[0]))/size_of(Contact)
    for key:=w.bodies[contact.body_a].contact_list;key>=0; {
        other:=&w.contacts[key>>1]
        earlier:=uintptr(key>>1)<self
        key=other.edges[key&1].next
        if other==contact || .Overlap not_in other.flags {continue}
        pair:=[2]u64{w.shapes[other.shape_a].user_data,w.shapes[other.shape_b].user_data}
        if pair!=users && pair!=users.yx {continue}
        if .Touching in other.flags && (ending || .Started not_in other.flags || earlier) {return true}
        if ending && .Stopped in other.flags && earlier {return true}
    }
    return false
}

@(private)
contact_end_events :: proc(w:^World,contact:^Contact) {
    if .Debris in (w.bodies[contact.body_a].flags+w.bodies[contact.body_b].flags) {return}
    shape_a,shape_b,body_a,body_b:=contact_handles(w,contact)
    users,swapped:=event_users(w,contact.shape_a,contact.shape_b)
    if .Overlap in contact.flags {
        if overlap_shared(w,contact,true) {return}
        event_push(w,w.events.overlap_end,3,Overlap_Event{shape_a,shape_b,body_a,body_b,false,users})
        event_push(w,w.events.overlap_end,3,Overlap_Event{shape_b,shape_a,body_b,body_a,false,swapped})
    } else {
        event_push(w,w.events.contact_end,1,Contact_End_Event{shape_a,shape_b,body_a,body_b,users})
    }
}

// A contact stopped touching: its end events, and its island may have come apart.
@(private)
contact_stopped :: proc(w:^World,contact:^Contact) {
    contact_end_events(w,contact)
    if .Overlap not_in contact.flags {island_unlink(w,contact.body_a,contact.body_b)}
}

// Narrow phase of the step: updates every contact with an awake body, in the order of the awake bodies, then
// applies in order the consequences that touch shared state: events, wake-ups and the removal of separated pairs.
@(private)
contacts_update :: proc(w:^World) #no_bounds_check {
    st:=&w.step
    count:=0
    // One of two awake bodies comes from the lower slot.
    for index:=w.awake_head;index>=0;index=w.bodies[index].awake_next {
        for key:=w.bodies[index].contact_list;key>=0; {
            contact:=&w.contacts[key>>1]
            other:=key&1==0?contact.body_b:contact.body_a
            if .Awake not_in w.bodies[other].flags || other>index {
                st.active[count]=key>>1
                count+=1
                stamp(w,contact)
                contact.flags+={.Visited}
            }
            key=contact.edges[key&1].next
        }
    }
    world_parallel(w,count,32,w,narrow_task)
    st.woken_count=0
    kept:=0
    for i in st.active[:count] {
        contact:=&w.contacts[i]
        if .Stopped in contact.flags {contact_stopped(w,contact)}
        if .Disjoint in contact.flags {
            contact_destroy(w,i,false)
            continue
        }
        st.active[kept]=i
        kept+=1
        if .Touching not_in contact.flags {continue}
        if .Overlap in contact.flags {
            if .Started in contact.flags && !overlap_shared(w,contact,false) {
                shape_a,shape_b,body_a,body_b:=contact_handles(w,contact)
                users,swapped:=event_users(w,contact.shape_a,contact.shape_b)
                event_push(w,w.events.overlap_begin,2,Overlap_Event{shape_a,shape_b,body_a,body_b,false,users})
                event_push(w,w.events.overlap_begin,2,Overlap_Event{shape_b,shape_a,body_b,body_a,false,swapped})
            }
            continue
        }
        // A sleeping dynamic body wakes, with its island, when touched by an awake dynamic body or by a
        // kinematic body that moves. body_wake lists who woke.
        for pair in ([2][2]i32{{contact.body_a,contact.body_b},{contact.body_b,contact.body_a}}) {
            body,other:=&w.bodies[pair[0]],&w.bodies[pair[1]]
            if body.type!=.Dynamic || .Awake in body.flags || .Awake not_in other.flags {continue}
            if other.type==.Dynamic || other.linear_velocity!={} || other.angular_velocity!={} {body_wake(w,pair[0])}
        }
    }
    // The contacts of the islands woken here were skipped above: their manifolds are stale.
    for body_index in st.woken[:st.woken_count] {
        for key:=w.bodies[body_index].contact_list;key>=0; {
            contact_index:=key>>1
            contact:=&w.contacts[contact_index]
            key=contact.edges[key&1].next
            if .Visited in contact.flags {continue}
            contact_update(w,contact_index)
            if .Stopped in contact.flags {contact_stopped(w,contact)}
            if .Disjoint in contact.flags {
                contact_destroy(w,contact_index,false)
                continue
            }
            contact.flags+={.Visited}
            st.active[kept]=contact_index
            kept+=1
        }
    }
    st.active_count=kept
}
