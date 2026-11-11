package mirai_physics

import "mirai:std/base"
import "mirai:std/spatial"

// Null when a value of the description is not finite or the bodies are exhausted.
body_create :: proc(w:^World,desc:Body_Desc) -> Body_Handle {
    if !finite(desc.position,desc.linear_velocity,desc.angular_velocity) || !finite(desc.rotation) ||
       !finite(desc.linear_damping,desc.angular_damping,desc.gravity_scale,desc.sleep_threshold) {return {}}
    index:=w.body_free
    if index>=0 {
        w.body_free=w.bodies[index].shape_list
    } else if int(w.body_high)<len(w.bodies) {
        index=w.body_high
        w.body_high+=1
    } else {
        w.stats.body_capacity_exhausted+=1
        return {}
    }
    w.body_count+=1
    body:=&w.bodies[index]
    stamp(w,body)
    rotation:=q_normalize(desc.rotation)
    body^={
        user_data=desc.user_data,
        position=desc.position,rotation=rotation,center=desc.position,
        linear_damping=max(desc.linear_damping,0),angular_damping=max(desc.angular_damping,0),
        gravity_scale=desc.gravity_scale,sleep_threshold=max(desc.sleep_threshold,0),
        shape_list=-1,contact_list=-1,joint_list=-1,island=-1,island_prev=-1,island_next=-1,solver_index=-1,awake_prev=-1,awake_next=-1,
        generation=body.generation+1,type=desc.type,flags=desc.locks&BODY_LOCKS,
    }
    if desc.bullet {body.flags+={.Bullet}}
    if desc.sleep_disabled {body.flags+={.Sleep_Disabled}}
    if desc.debris {body.flags+={.Debris}}
    if desc.type!=.Static {
        body.linear_velocity,body.angular_velocity=desc.linear_velocity,desc.angular_velocity
        if !desc.asleep || desc.sleep_disabled {body_awake_set(w,index,true)}
        island_create(w,index)
    }
    body_update_mass(w,index)
    return body_handle(w,index)
}

body_destroy :: proc(w:^World,h:Body_Handle) {
    body,index:=body_get(w,h)
    if body==nil {return}
    w.grounds_stale=true
    if body.type==.Static {static_log_body(w,index)}
    body_clear_twin(w,h)
    for body.joint_list>=0 {joint_destroy_index(w,body.joint_list>>1)}
    for body.shape_list>=0 {shape_destroy_index(w,body.shape_list,false,false)}
    island_leave(w,index)
    body_awake_set(w,index,false)
    body.generation+=1
    body.flags={}
    body.shape_list=w.body_free
    w.body_free=index
    w.body_count-=1
}

// Wakes the body and its island.
@(private)
body_wake :: proc(w:^World,index:i32) {
    body:=&w.bodies[index]
    if body.type==.Static {return}
    if .Awake in body.flags {
        if body.sleep_time!=0 {stamp(w,body);body.sleep_time=0}
        return
    }
    for i:=w.islands[body.island].head;i>=0;i=w.bodies[i].island_next {
        other:=&w.bodies[i]
        stamp(w,other)
        body_awake_set(w,i,true)
        other.sleep_time=0
        if st:=&w.step;st.woken_count<len(st.woken) {st.woken[st.woken_count]=i;st.woken_count+=1}
        if .Debris not_in other.flags {event_push(w,w.events.wake,6,Body_Event{body_handle(w,i),other.user_data})}
    }
}

@(private)
body_sleep :: proc(w:^World,index:i32) {
    body:=&w.bodies[index]
    stamp(w,body)
    body_awake_set(w,index,false)
    body.linear_velocity,body.angular_velocity={},{}
    body.force,body.torque={},{}
    body.sleep_time=0
    body.solver_index=-1
    if .Debris not_in body.flags {event_push(w,w.events.sleep,5,Body_Event{body_handle(w,index),body.user_data})}
}

// Gives a body the Awake flag or takes it away, and keeps it in the list of the awake bodies, which the step
// walks instead of every slot.
@(private)
body_awake_set :: proc "contextless" (w:^World,index:i32,awake:bool) #no_bounds_check {
    body:=&w.bodies[index]
    if (.Awake in body.flags)==awake {return}
    stamp(w,body)
    if awake {
        body.flags+={.Awake}
        body.awake_prev,body.awake_next=-1,w.awake_head
        if w.awake_head>=0 {stamp(w,.Bodies,w.awake_head);w.bodies[w.awake_head].awake_prev=index}
        w.awake_head=index
        return
    }
    body.flags-={.Awake}
    if body.awake_prev>=0 {stamp(w,.Bodies,body.awake_prev);w.bodies[body.awake_prev].awake_next=body.awake_next} else {w.awake_head=body.awake_next}
    if body.awake_next>=0 {stamp(w,.Bodies,body.awake_next);w.bodies[body.awake_next].awake_prev=body.awake_prev}
}

// The awake bodies in `out`, in the order of their list, which the state holds: the order of the step.
// Returns how many there are.
@(private)
bodies_awake :: proc(w:^World,out:[]i32) -> int #no_bounds_check {
    count:=0
    for i:=w.awake_head;i>=0;i=w.bodies[i].awake_next {
        out[count]=i
        count+=1
    }
    return count
}

// Wakes the bodies in contact with a body or joined to it: what it supported or pushed may now move.
@(private)
body_wake_touching :: proc(w:^World,index:i32) {
    body:=&w.bodies[index]
    for key:=body.contact_list;key>=0; {
        contact:=&w.contacts[key>>1]
        side:=key&1
        if contact.flags&{.Touching,.Overlap}=={.Touching} {body_wake(w,side==0?contact.body_b:contact.body_a)}
        key=contact.edges[side].next
    }
    for key:=body.joint_list;key>=0; {
        joint:=&w.joints[key>>1]
        side:=key&1
        body_wake(w,side==0?joint.body_b:joint.body_a)
        key=joint.edges[side].next
    }
}

@(private) body_transform_of :: #force_inline proc "contextless" (body:^Body) -> Transform {return {body.position,body.rotation}}

// Mass, center and inertia from the shapes, unless the caller fixed them.
@(private)
body_update_mass :: proc(w:^World,index:i32) {
    body:=&w.bodies[index]
    stamp(w,body)
    body.max_extent,body.min_extent=0,max(f32)
    mass:f32
    center:Vec3
    inertia:Mat3
    for s:=body.shape_list;s>=0;s=w.shapes[s].next {
        shape:=&w.shapes[s]
        m:=shape_mass(w,shape)
        body.min_extent=min(body.min_extent,m.inner_radius)
        if m.mass<=0 {continue}
        mass+=m.mass
        center+=m.mass*m.center
        inertia+=m.inertia+mat3_point_inertia(m.mass,m.center)
    }
    if body.min_extent==max(f32) {body.min_extent=0}
    if .Mass_Override not_in body.flags {
        // Only a dynamic body keeps a given mass: one made dynamic again is given it anew.
        given:=.Mass_Given in body.flags && body.type==.Dynamic?body.mass:0
        if given==0 {body.flags-={.Mass_Given}}
        body.mass,body.inv_mass=0,0
        body.inertia,body.inv_inertia={},{}
        body.local_center={}
        if body.type==.Dynamic {
            if mass>0 {
                body.local_center=center/mass
                body.mass=mass
                body.inertia=inertia-mat3_point_inertia(mass,body.local_center)
                if given>0 {
                    for row in 0..<3 {for column in 0..<3 {body.inertia[row,column]*=given/mass}}
                    body.mass=given
                }
            } else {
                body.mass=given>0?given:1
                body.inertia=mat3_diagonal({body.mass,body.mass,body.mass})
            }
            body.inv_mass=1/body.mass
            body.inv_inertia=mat3_inverse(body.inertia)
        }
    }
    body.center=body.position+q_rotate(body.rotation,body.local_center)
    for s:=body.shape_list;s>=0;s=w.shapes[s].next {
        body.max_extent=max(body.max_extent,shape_extent(w,&w.shapes[s],body.local_center))
    }
}

// Recomputes the boxes of the shapes after the body moved outside a step.
@(private)
body_update_proxies :: proc(w:^World,index:i32) {
    body:=&w.bodies[index]
    xf:=body_transform_of(body)
    tree:=&w.trees[body.type==.Static?STATIC_TREE:DYNAMIC_TREE]
    for s:=body.shape_list;s>=0;s=w.shapes[s].next {
        shape:=&w.shapes[s]
        stamp(w,shape)
        shape.aabb=shape_aabb(w,shape,xf)
        shape.fat=body.type==.Static?shape.aabb:shape_fat(shape.aabb)
        shape_moved(w,s)
        if shape.proxy>=0 {spatial.dynamic_tree_move(tree,shape.proxy,shape.fat)}
    }
}

body_transform :: proc(w:^World,h:Body_Handle) -> Transform {
    body,_:=body_read(w,h)
    if body==nil {return TRANSFORM_IDENTITY}
    return {body.position,body.rotation}
}
body_position :: proc(w:^World,h:Body_Handle) -> Vec3 {
    body,_:=body_read(w,h)
    return body==nil?Vec3{}:body.position
}
body_rotation :: proc(w:^World,h:Body_Handle) -> Quat {
    body,_:=body_read(w,h)
    return body==nil?QUAT_IDENTITY:body.rotation
}
// World center of mass.
body_center :: proc(w:^World,h:Body_Handle) -> Vec3 {
    body,_:=body_read(w,h)
    return body==nil?Vec3{}:body.center
}

// Teleports the body. Contacts are re-evaluated at the next step. Like every setter of the solver, it
// returns false and changes nothing for a handle that is not live or a value that is not finite.
body_set_transform :: proc(w:^World,h:Body_Handle,position:Vec3,rotation:Quat) -> bool {
    if !finite(position) || !finite(rotation) {return false}
    body,index:=body_get(w,h)
    if body==nil {return false}
    w.grounds_stale=true
    body_wake_touching(w,index)
    if body.type==.Static {static_log_body(w,index)}
    body.position=position
    body.rotation=q_normalize(rotation)
    body.center=position+q_rotate(body.rotation,body.local_center)
    body_update_proxies(w,index)
    if body.type==.Static {static_log_body(w,index)}
    body_wake(w,index)
    return true
}

body_linear_velocity :: proc(w:^World,h:Body_Handle) -> Vec3 {
    body,_:=body_read(w,h)
    return body==nil?Vec3{}:body.linear_velocity
}
body_angular_velocity :: proc(w:^World,h:Body_Handle) -> Vec3 {
    body,_:=body_read(w,h)
    return body==nil?Vec3{}:body.angular_velocity
}
// Velocity of a world point moving with the body.
body_point_velocity :: proc(w:^World,h:Body_Handle,point:Vec3) -> Vec3 {
    body,_:=body_read(w,h)
    if body==nil {return {}}
    return body.linear_velocity+cross(body.angular_velocity,point-body.center)
}

// False also for a static body.
body_set_velocity :: proc(w:^World,h:Body_Handle,linear,angular:Vec3) -> bool {
    if !finite(linear,angular) {return false}
    body,index:=body_get(w,h)
    if body==nil || body.type==.Static {return false}
    body.linear_velocity,body.angular_velocity=linear,angular
    if linear!={} || angular!={} {
        body_wake(w,index)
        if body.type==.Kinematic {body_wake_touching(w,index)}
    }
    return true
}
body_set_linear_velocity :: proc(w:^World,h:Body_Handle,linear:Vec3) -> bool {
    return body_set_velocity(w,h,linear,body_angular_velocity(w,h))
}
body_set_angular_velocity :: proc(w:^World,h:Body_Handle,angular:Vec3) -> bool {
    return body_set_velocity(w,h,body_linear_velocity(w,h),angular)
}

// Gives a kinematic body the velocity that takes it to a pose in one step of dt seconds, so that it
// pushes and carries what it touches instead of teleporting.
body_set_kinematic_target :: proc(w:^World,h:Body_Handle,position:Vec3,rotation:Quat,dt:f32) -> bool {
    body,_:=body_read(w,h)
    if body==nil || body.type!=.Kinematic || !(dt>0) || !finite(dt) || !finite(position) || !finite(rotation) {return false}
    target:=q_normalize(rotation)
    angular:=q_rotation_vector(target*conj(body.rotation))/dt
    center:=position+q_rotate(target,body.local_center)
    return body_set_velocity(w,h,(center-body.center)/dt,angular)
}

// Force in newtons through the center of mass, accumulated until the next step.
// False also for a body that is not dynamic, as for the impulses.
body_apply_force :: proc(w:^World,h:Body_Handle,force:Vec3,wake:=true) -> bool {
    return body_apply_force_at(w,h,force,body_center(w,h),wake)
}
body_apply_force_at :: proc(w:^World,h:Body_Handle,force,point:Vec3,wake:=true) -> bool {
    if !finite(force,point) {return false}
    body,index:=body_get(w,h)
    if body==nil || body.type!=.Dynamic {return false}
    if wake {body_wake(w,index)}
    if .Awake in body.flags {
        body.force+=force
        body.torque+=cross(point-body.center,force)
    }
    return true
}
body_apply_torque :: proc(w:^World,h:Body_Handle,torque:Vec3,wake:=true) -> bool {
    if !finite(torque) {return false}
    body,index:=body_get(w,h)
    if body==nil || body.type!=.Dynamic {return false}
    if wake {body_wake(w,index)}
    if .Awake in body.flags {body.torque+=torque}
    return true
}

@(private)
body_inv_inertia_world :: proc "contextless" (body:^Body) -> Mat3 {
    m:=mat3_rotate(body.rotation,body.inv_inertia)
    if body.flags&{.Lock_Angular_X,.Lock_Angular_Y,.Lock_Angular_Z}!={} {
        for axis,i in ([3]Body_Flag{.Lock_Angular_X,.Lock_Angular_Y,.Lock_Angular_Z}) {
            if axis in body.flags {
                for j in 0..<3 {m[i,j]=0;m[j,i]=0}
            }
        }
    }
    return m
}

// Impulse in newton seconds through the center of mass: changes the velocity at once.
body_apply_impulse :: proc(w:^World,h:Body_Handle,impulse:Vec3,wake:=true) -> bool {
    return body_apply_impulse_at(w,h,impulse,body_center(w,h),wake)
}
body_apply_impulse_at :: proc(w:^World,h:Body_Handle,impulse,point:Vec3,wake:=true) -> bool {
    if !finite(impulse,point) {return false}
    body,index:=body_get(w,h)
    if body==nil || body.type!=.Dynamic {return false}
    if wake {body_wake(w,index)}
    if .Awake in body.flags {
        body.linear_velocity+=body.inv_mass*impulse
        body.angular_velocity+=body_inv_inertia_world(body)*cross(point-body.center,impulse)
    }
    return true
}
body_apply_angular_impulse :: proc(w:^World,h:Body_Handle,impulse:Vec3,wake:=true) -> bool {
    if !finite(impulse) {return false}
    body,index:=body_get(w,h)
    if body==nil || body.type!=.Dynamic {return false}
    if wake {body_wake(w,index)}
    if .Awake in body.flags {body.angular_velocity+=body_inv_inertia_world(body)*impulse}
    return true
}

body_type :: proc(w:^World,h:Body_Handle) -> Body_Type {
    body,_:=body_read(w,h)
    return body==nil?.Static:body.type
}

// Changing the type discards the contacts of the body; they are found again at the next step.
body_set_type :: proc(w:^World,h:Body_Handle,type:Body_Type) {
    body,index:=body_get(w,h)
    if body==nil || body.type==type {return}
    if type==.Static {body_clear_twin(w,h)}
    w.grounds_stale=true
    body_wake_touching(w,index)
    island_leave(w,index)
    for body.contact_list>=0 {contact_destroy(w,body.contact_list>>1)}
    was_static:=body.type==.Static
    body.type=type
    if was_static!=(type==.Static) {
        for s:=body.shape_list;s>=0;s=w.shapes[s].next {
            shape:=&w.shapes[s]
            spatial.dynamic_tree_remove(&w.trees[was_static?STATIC_TREE:DYNAMIC_TREE],shape.proxy)
            shape.proxy=-1
        }
    }
    if type==.Static {
        body.linear_velocity,body.angular_velocity={},{}
        body_awake_set(w,index,false)
        body.solver_index=-1
    } else {
        body_awake_set(w,index,true)
        body.sleep_time=0
        island_create(w,index)
        for key:=body.joint_list;key>=0;key=w.joints[key>>1].edges[key&1].next {
            joint:=&w.joints[key>>1]
            island_link(w,joint.body_a,joint.body_b)
        }
    }
    body_update_mass(w,index)
    body_update_proxies(w,index)
    tree:=&w.trees[type==.Static?STATIC_TREE:DYNAMIC_TREE]
    for s:=body.shape_list;s>=0;s=w.shapes[s].next {
        shape:=&w.shapes[s]
        if shape.proxy<0 {shape.proxy,_=spatial.dynamic_tree_insert(tree,shape.fat,u64(s))}
    }
    if was_static!=(type==.Static) {static_log_body(w,index)}
}

body_mass :: proc(w:^World,h:Body_Handle) -> f32 {
    body,_:=body_read(w,h)
    return body==nil?0:body.mass
}
// Local center of mass and inertia tensor about it, in the body frame.

body_mass_properties :: proc(w:^World,h:Body_Handle) -> (mass:f32,local_center:Vec3,inertia:Mat3) {
    body,_:=body_read(w,h)
    if body==nil {return}
    return body.mass,body.local_center,body.inertia
}
// Fixes the mass properties of a dynamic body; shapes added later do not change them.
body_set_mass_properties :: proc(w:^World,h:Body_Handle,mass:f32,local_center:Vec3,inertia:Mat3) -> bool {
    if !(mass>0) || !finite(mass) || !finite(local_center) || !finite(inertia) {return false}
    body,index:=body_get(w,h)
    if body==nil || body.type!=.Dynamic {return false}
    body.flags+={.Mass_Override}
    body.mass,body.inv_mass=mass,1/mass
    body.local_center=local_center
    body.inertia=inertia
    body.inv_inertia=mat3_inverse(inertia)
    body_update_mass(w,index)
    return true
}
// Returns to mass properties computed from the shapes.
// Mass, center and inertia from the shapes again, once, after shapes made or destroyed without
// update_mass. A moving body keeps the velocity of its matter: its center takes the velocity it had where it
// moves to, and it wakes.
body_mass_update :: proc(w:^World,h:Body_Handle) {
    body,index:=body_get(w,h)
    if body==nil {return}
    center:=body.center
    body_update_mass(w,index)
    if body.type!=.Dynamic {return}
    body.linear_velocity+=cross(body.angular_velocity,body.center-center)
    body_wake(w,index)
}

// Gives a dynamic body a mass, kg, whose center and inertia its shapes give, now and whenever they change;
// zero or less takes the mass of its shapes too. A mass it already has changes nothing.
body_set_mass :: proc(w:^World,h:Body_Handle,mass:f32) -> bool {
    body,index:=body_read(w,h)
    if body==nil || body.type!=.Dynamic || !finite(mass) {return false}
    given:=mass>0
    if .Mass_Override not_in body.flags && given==(.Mass_Given in body.flags) && (!given || body.mass==mass) {return true}
    body,_=body_get(w,h)
    body.flags-={.Mass_Override,.Mass_Given}
    if given {body.flags+={.Mass_Given};body.mass=mass}
    body_update_mass(w,index)
    return true
}

body_reset_mass_properties :: proc(w:^World,h:Body_Handle) {
    body,index:=body_get(w,h)
    if body==nil {return}
    body.flags-={.Mass_Override,.Mass_Given}
    body_update_mass(w,index)
}

body_is_awake :: proc(w:^World,h:Body_Handle) -> bool {
    body,_:=body_read(w,h)
    return body!=nil && .Awake in body.flags
}
// Putting a body to sleep also puts to sleep the bodies it touches or is joined to, directly or not.
body_set_awake :: proc(w:^World,h:Body_Handle,awake:bool) {
    body,index:=body_get(w,h)
    if body==nil || body.type==.Static {return}
    if awake {
        body_wake(w,index)
    } else if .Awake in body.flags && .Sleep_Disabled not_in body.flags {
        island_sleep_from(w,index)
    }
}
// Leaves a dynamic body asleep at a pose, alone in its island and without waking what touches it: for a pose
// known from elsewhere to be one of rest. Any other body is moved there and stopped.
body_rest :: proc(w:^World,h:Body_Handle,position:Vec3,rotation:Quat) -> bool {
    if !finite(position) || !finite(rotation) {return false}
    body,index:=body_get(w,h)
    if body==nil {return false}
    if body.type!=.Dynamic || .Sleep_Disabled in body.flags {
        body_set_transform(w,h,position,rotation)
        body_set_velocity(w,h,{},{})
        return true
    }
    if .Awake in body.flags {body_sleep(w,index)}
    island_remove(w,index)
    island_create(w,index)
    body.position=position
    body.rotation=q_normalize(rotation)
    body.center=position+q_rotate(body.rotation,body.local_center)
    body_update_proxies(w,index)
    return true
}

// Groups the awake bodies that touching contacts and joints connect now: what a push given to one could
// reach. body_group reads the groups until the next step.
bodies_group :: proc(w:^World) #no_bounds_check {
    st:=&w.step
    st.grouping+=1
    awake:=st.awake[:st.awake_count]
    for index in awake {st.groups[index],st.grouped[index]=index,st.grouping}
    for index in awake {
        body:=&w.bodies[index]
        for key:=body.contact_list;key>=0; {
            contact:=&w.contacts[key>>1]
            other:=key&1==0?contact.body_b:contact.body_a
            key=contact.edges[key&1].next
            if contact.flags&{.Touching,.Overlap}=={.Touching} && st.grouped[other]==st.grouping {union_join(st.groups,index,other)}
        }
        for key:=body.joint_list;key>=0; {
            joint:=&w.joints[key>>1]
            other:=key&1==0?joint.body_b:joint.body_a
            key=joint.edges[key&1].next
            if st.grouped[other]==st.grouping {union_join(st.groups,index,other)}
        }
    }
}

// The group bodies_group gave a body: the same number for the bodies of a group, 0 for one that was not awake.
body_group :: proc(w:^World,h:Body_Handle) -> u32 {
    _,index:=body_read(w,h)
    if index<0 || w.step.grouped[index]!=w.step.grouping {return 0}
    return u32(union_find(w.step.groups,index))+1
}

body_set_sleep_disabled :: proc(w:^World,h:Body_Handle,disabled:bool) {
    body,index:=body_get(w,h)
    if body==nil {return}
    if disabled {
        body.flags+={.Sleep_Disabled}
        body_wake(w,index)
    } else {
        body.flags-={.Sleep_Disabled}
    }
}
body_set_sleep_threshold :: proc(w:^World,h:Body_Handle,threshold:f32) -> bool {
    if !finite(threshold) {return false}
    body,_:=body_get(w,h)
    if body!=nil {body.sleep_threshold=max(threshold,0)}
    return body!=nil
}

body_set_damping :: proc(w:^World,h:Body_Handle,linear,angular:f32) -> bool {
    if !finite(linear,angular) {return false}
    body,_:=body_get(w,h)
    if body!=nil {body.linear_damping,body.angular_damping=max(linear,0),max(angular,0)}
    return body!=nil
}
body_gravity_scale :: proc(w:^World,h:Body_Handle) -> f32 {
    body,_:=body_read(w,h)
    return body==nil?0:body.gravity_scale
}
body_set_gravity_scale :: proc(w:^World,h:Body_Handle,scale:f32) -> bool {
    if !finite(scale) {return false}
    body,index:=body_get(w,h)
    if body!=nil {body.gravity_scale=scale;body_wake(w,index)}
    return body!=nil
}

// The gravity a body falls with, m/s2: its own, or that of the world.
body_gravity :: proc(w:^World,h:Body_Handle) -> Vec3 {
    body,_:=body_read(w,h)
    return body==nil?w.gravity:body_gravity_of(w,body)
}
body_gravity_of :: #force_inline proc "contextless" (w:^World,body:^Body) -> Vec3 {
    return .Own_Gravity in body.flags?body.gravity:w.gravity
}

// Gives the world the gravity world, and each awake dynamic body the gravity
// of the place of its center as at says, on the workers of the world; with
// nil, that of the world. all: also the bodies asleep, each of which wakes
// when its gravity changes, the one of the world included: what a change of
// the fields asks.
world_set_body_gravity :: proc(w:^World,world:Vec3,at:proc(user:rawptr,point:Vec3) -> Vec3,user:rawptr,all:=false) -> bool {
    if !finite(world) {return false}
    previous:=w.gravity
    w.gravity=world
    Gravity_Task :: struct {w:^World,at:proc(user:rawptr,point:Vec3) -> Vec3,user:rawptr,awake:[]i32}
    task :: proc(data:rawptr,first,last,worker:int) {
        t:=(^Gravity_Task)(data)
        for index in t.awake[first:last] {
            body:=&t.w.bodies[index]
            if body.type!=.Dynamic {continue}
            body_gravity_take(t.w,body,t.at==nil?t.w.gravity:t.at(t.user,body.center))
        }
    }
    // Between steps the bodies of an island being split are free scratch.
    awake:=w.step.island_bodies[:bodies_awake(w,w.step.island_bodies)]
    data:=Gravity_Task{w,at,user,awake}
    world_parallel(w,len(awake),64,&data,task)
    if !all {return true}
    for &body,index in w.bodies[:w.body_high] {
        if body.generation&1==0 || body.type!=.Dynamic || .Awake in body.flags {continue}
        before:=.Own_Gravity in body.flags?body.gravity:previous
        g:=at==nil?world:at(user,body.center)
        body_gravity_take(w,&body,g)
        if g!=before {body_wake(w,i32(index))}
    }
    return true
}

// A body falls with g: as one of its own, or with the world when it is that one.
@(private)
body_gravity_take :: #force_inline proc "contextless" (w:^World,body:^Body,g:Vec3) {
    if g==w.gravity {
        if .Own_Gravity not_in body.flags {return}
        body.flags-={.Own_Gravity}
    } else {
        if .Own_Gravity in body.flags && body.gravity==g {return}
        body.gravity=g
        body.flags+={.Own_Gravity}
    }
    stamp(w,body)
}
body_locks :: proc(w:^World,h:Body_Handle) -> Body_Flags {
    body,_:=body_read(w,h)
    return body==nil?{}:body.flags&BODY_LOCKS
}
body_set_locks :: proc(w:^World,h:Body_Handle,locks:Body_Flags) {
    body,index:=body_get(w,h)
    if body==nil {return}
    body.flags=body.flags-BODY_LOCKS+(locks&BODY_LOCKS)
    body_wake(w,index)
}
body_set_bullet :: proc(w:^World,h:Body_Handle,bullet:bool) {
    body,_:=body_get(w,h)
    if body==nil {return}
    if bullet {body.flags+={.Bullet}} else {body.flags-={.Bullet}}
}
body_user_data :: proc(w:^World,h:Body_Handle) -> u64 {
    body,_:=body_read(w,h)
    return body==nil?0:body.user_data
}
body_set_user_data :: proc(w:^World,h:Body_Handle,user_data:u64) {
    body,_:=body_get(w,h)
    if body!=nil {body.user_data=user_data}
}

// Shapes of a body written to a caller buffer; returns how many the body has.
body_is_debris :: proc(w:^World,h:Body_Handle) -> bool {
    body,_:=body_read(w,h)
    return body!=nil && .Debris in body.flags
}

body_shapes :: proc(w:^World,h:Body_Handle,out:[]Shape_Handle) -> int {
    body,_:=body_read(w,h)
    if body==nil {return 0}
    count:=0
    for s:=body.shape_list;s>=0;s=w.shapes[s].next {
        if count<len(out) {out[count]=shape_handle(w,s)}
        count+=1
    }
    return count
}

Contact_Info :: struct {
    shape_a,shape_b:Shape_Handle,
    body_a,body_b:Body_Handle,
    manifold:Manifold, // of the last step; the first manifold when the contact is with a mesh
}

// Touching contacts of an awake body after a step, written to a caller buffer; returns how many there are.
body_contacts :: proc(w:^World,h:Body_Handle,out:[]Contact_Info) -> int {
    body,_:=body_read(w,h)
    if body==nil || .Awake not_in body.flags {return 0}
    count:=0
    for key:=body.contact_list;key>=0; {
        index:=key>>1
        contact:=&w.contacts[index]
        if contact.flags&{.Touching,.Overlap}=={.Touching} {
            if count<len(out) {
                out[count]={
                    shape_handle(w,contact.shape_a),shape_handle(w,contact.shape_b),
                    body_handle(w,contact.body_a),body_handle(w,contact.body_b),w.manifolds[index],
                }
            }
            count+=1
        }
        key=contact.edges[key&1].next
    }
    return count
}
