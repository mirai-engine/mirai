package mirai_physics

import cmath "core:math"

// A joint is one six-axis record: the three linear and the three angular axes of frame A, each free, locked
// or limited and with an optional drive. Two or three limited linear axes share one limit, on the length of
// the offset across them (a rope, a rod), whose drive is that of the first of them; the two swings (Y and Z)
// limited together share one, a cone around X whose angle toward each side is the limit of that side, and
// which is round when the four are equal. The solver picks a kernel in lanes by the pattern of the axes (a
// fixed, ball, hinge, slider or distance joint) and solves any other pattern one axis at a time.
Joint_Motion :: enum u32 {Free,Locked,Limited}
Joint_Drive_Flag :: enum u32 {Position,Velocity,Disabled}
Joint_Drive :: bit_set[Joint_Drive_Flag;u32]
// lower, upper and position are meters or radians; velocity m/s or rad/s; max_force N or N m. A drive
// pulls toward position with hertz and damping_ratio, toward velocity, or both, with at most max_force.
Joint_Axis :: struct {
    motion:Joint_Motion,
    drive:Joint_Drive,
    lower,upper,position,velocity,hertz,damping_ratio,max_force:f32,
}
#assert(size_of(Joint_Axis)==36)
Joint_Error :: enum u8 {None,Invalid_Value,Unsupported_Option,Invalid_Axis,Invalid_Bodies,Capacity}
@(private) Axis_Impulse :: struct {drive,lower,upper,lock:f32}

@(private) Joint_Kernel :: enum u32 {Fixed,Spherical,Revolute,Prismatic,Distance,General}
Joint_Flag :: enum u32 {Collide_Connected,Limit,Drive,Cone}
Joint_Flags :: bit_set[Joint_Flag;u32]

Joint_Desc :: struct {
    body_a,body_b:Body_Handle,
    frame_a,frame_b:Transform, // in the frame of each body; a zero rotation means identity
    collide_connected:bool,
    break_force,break_torque:f32, // N and N m that break the joint; zero is unbreakable
    user_data:u64,
    linear,angular:[3]Joint_Axis,
}

Joint :: struct {
    user_data:u64,
    body_a,body_b:i32,
    edges:[2]Contact_Edge,
    kernel:Joint_Kernel, // by the pattern of its axes
    flags:Joint_Flags,
    generation:u32,
    frame_a,frame_b:Transform,
    break_force,break_torque:f32,
    // Impulses of the last substep of a kernel in lanes, for warm starting.
    linear_impulse,angular_impulse:Vec3,
    lower_impulse,upper_impulse,drive_impulse,cone_impulse:f32,
    _:u32,
}
#assert(size_of(Joint)==152)

@(private)
Joint_Axes :: struct {
    linear_axes,angular_axes:[3]Joint_Axis,
    linear_axes_impulse,angular_axes_impulse:[3]Axis_Impulse,
}
#assert(size_of(Joint_Axes)==312)

@(private) axis_driven :: #force_inline proc "contextless" (axis:Joint_Axis) -> bool {return axis.drive!={} && .Disabled not_in axis.drive}
@(private) axis_free :: #force_inline proc "contextless" (axis:Joint_Axis) -> bool {return axis.motion==.Free && !axis_driven(axis)}
// The two swings share a cone.
@(private) axes_cone :: #force_inline proc "contextless" (angular:[3]Joint_Axis) -> bool {return angular[1].motion==.Limited && angular[2].motion==.Limited}
// The first of the limited linear axes that share a limit on their length, or -1.
@(private)
axes_distance :: proc "contextless" (linear:[3]Joint_Axis) -> int {
    first,count:=-1,0
    for axis,i in linear {
        if axis.motion!=.Limited {continue}
        if first<0 {first=i}
        count+=1
    }
    return count>=2?first:-1
}

@(private)
joint_kernel_of :: proc "contextless" (linear,angular:[3]Joint_Axis) -> Joint_Kernel {
    locked :: proc "contextless" (axes:[3]Joint_Axis,first:int) -> bool {
        for i in first..<3 {if axes[i].motion!=.Locked {return false}}
        return true
    }
    if locked(linear,0) && locked(angular,0) {return .Fixed}
    if locked(linear,0) && locked(angular,1) {return .Revolute}
    if locked(angular,0) && locked(linear,1) {return .Prismatic}
    round:=angular[1].upper==angular[2].upper && angular[1].lower==angular[2].lower && angular[1].lower== -angular[1].upper
    swings:=axis_free(angular[1]) && axis_free(angular[2]) || axes_cone(angular) && round && !axis_driven(angular[1]) && !axis_driven(angular[2])
    if locked(linear,0) && angular[0].motion!=.Locked && !axis_driven(angular[0]) && swings {return .Spherical}
    if axis_free(angular[0]) && axis_free(angular[1]) && axis_free(angular[2]) && axes_distance(linear)==0 && linear[1].motion==.Limited && linear[2].motion==.Limited && !axis_driven(linear[1]) && !axis_driven(linear[2]) {return .Distance}
    return .General
}

// The axis whose limit and drive a kernel in lanes solves.
@(private)
joint_kernel_axis :: proc "contextless" (kernel:Joint_Kernel,linear,angular:[3]Joint_Axis) -> Joint_Axis {
    #partial switch kernel {
    case .Revolute,.Spherical: return angular[0]
    case .Prismatic,.Distance: return linear[0]
    }
    return {}
}

@(private)
joint_flags_of :: proc "contextless" (kernel:Joint_Kernel,axes:^Joint_Axes,collide:bool) -> (flags:Joint_Flags) {
    if collide {flags+={.Collide_Connected}}
    axis:=joint_kernel_axis(kernel,axes.linear_axes,axes.angular_axes)
    if axis.motion==.Limited && (kernel!=.Distance || axis.lower<axis.upper) {flags+={.Limit}}
    if axis_driven(axis) {flags+={.Drive}}
    if kernel==.Spherical && axes_cone(axes.angular_axes) {flags+={.Cone}}
    return
}

joint_configuration_error :: proc "contextless" (desc:Joint_Desc) -> Joint_Error {
    finite :: proc "contextless" (value:f32) -> bool {return value>=-max(f32) && value<=max(f32)}
    for value in ([8]f32{desc.break_force,desc.break_torque,desc.frame_a.p.x,desc.frame_a.p.y,desc.frame_a.p.z,desc.frame_b.p.x,desc.frame_b.p.y,desc.frame_b.p.z}) {if !finite(value) {return .Invalid_Value}}
    for q in ([2]Quat{desc.frame_a.q,desc.frame_b.q}) {
        for value in ([4]f32{q.x,q.y,q.z,q.w}) {if !finite(value) {return .Invalid_Value}}
    }
    if desc.break_force<0 || desc.break_torque<0 {return .Invalid_Value}
    for axes,angular in ([2][3]Joint_Axis{desc.linear,desc.angular}) {
        for axis in axes {
            if axis.motion>.Limited || axis.drive&~(Joint_Drive{.Position,.Velocity,.Disabled})!={} {return .Invalid_Axis}
            for value in ([7]f32{axis.lower,axis.upper,axis.position,axis.velocity,axis.hertz,axis.damping_ratio,axis.max_force}) {if !finite(value) {return .Invalid_Axis}}
            if axis.motion==.Limited && (axis.lower>axis.upper || angular==1 && (axis.lower< -PI || axis.upper>PI)) {return .Invalid_Axis}
            if axis.hertz<0 || axis.damping_ratio<0 || axis.max_force<0 || axis.drive!={} && (axis.motion==.Locked || axis.max_force<=0) || .Position in axis.drive && axis.hertz<=0 {return .Invalid_Axis}
        }
    }
    if axes_cone(desc.angular) {
        for i in 1..<3 {if desc.angular[i].lower>0 || desc.angular[i].upper<0 {return .Invalid_Axis}}
    }
    if first:=axes_distance(desc.linear);first>=0 {
        shared:=desc.linear[first]
        if shared.lower<0 {return .Invalid_Axis}
        for axis,i in desc.linear {
            if axis.motion!=.Limited || i==first {continue}
            if axis.lower!=shared.lower || axis.upper!=shared.upper {return .Invalid_Axis}
            if axis.drive!={} {return .Unsupported_Option}
        }
    }
    return .None
}

// Drives the axes toward a translation and a rotation of frame B in frame A: linear drives with max_force,
// angular ones with max_torque, each axis left out when its force is zero. A locked axis it drives becomes
// free.
joint_drive_pose :: proc "contextless" (desc:^Joint_Desc,translation:Vec3,rotation:Quat,hertz,damping_ratio,max_force,max_torque:f32) -> Joint_Error {
    if desc==nil {return .Invalid_Value}
    for value in translation {if !(value>=-max(f32) && value<=max(f32)) {return .Invalid_Value}}
    for value in ([4]f32{hertz,damping_ratio,max_force,max_torque}) {if !(value>=0 && value<=max(f32)) {return .Invalid_Value}}
    if (max_force>0 || max_torque>0) && hertz==0 {return .Invalid_Value}
    for value in ([4]f32{rotation.x,rotation.y,rotation.z,rotation.w}) {if !(value>=-max(f32) && value<=max(f32)) {return .Invalid_Value}}
    next:=desc^
    target:=q_rotation_vector(q_normalize(rotation))
    driven :: proc "contextless" (axis:Joint_Axis,position,hertz,damping_ratio,max_force:f32) -> Joint_Axis {
        return {motion=axis.motion==.Locked?.Free:axis.motion,drive={.Position},lower=axis.lower,upper=axis.upper,position=position,hertz=hertz,damping_ratio=damping_ratio,max_force=max_force}
    }
    for i in 0..<3 {
        if max_force>0 {next.linear[i]=driven(next.linear[i],translation[i],hertz,damping_ratio,max_force)}
        if max_torque>0 {next.angular[i]=driven(next.angular[i],target[i],hertz,damping_ratio,max_torque)}
    }
    if error:=joint_configuration_error(next);error!=.None {return error}
    desc^=next
    return .None
}

// Frames for a joint from a world anchor and a world axis, which becomes the X axis of both frames.
joint_frames :: proc(w:^World,body_a,body_b:Body_Handle,anchor,axis:Vec3) -> (frame_a,frame_b:Transform) {
    q:=q_between({1,0,0},normalize(axis)=={}?Vec3{1,0,0}:normalize(axis))
    xf_a,xf_b:=body_transform(w,body_a),body_transform(w,body_b)
    return {xf_inv_point(xf_a,anchor),conj(xf_a.q)*q},{xf_inv_point(xf_b,anchor),conj(xf_b.q)*q}
}

joint_local_frames :: proc(w:^World,h:Joint_Handle) -> (frame_a,frame_b:Transform,ok:bool) {
    joint,_:=joint_read(w,h)
    if joint==nil {return}
    return joint.frame_a,joint.frame_b,true
}

joint_create :: proc(w:^World,desc:Joint_Desc) -> Joint_Handle {
    if joint_configuration_error(desc)!=.None {return {}}
    body_a,index_a:=body_get(w,desc.body_a)
    body_b,index_b:=body_get(w,desc.body_b)
    if body_a==nil || body_b==nil || index_a==index_b {return {}}
    index:=w.joint_free
    if index>=0 {
        w.joint_free=w.joints[index].body_a
    } else if int(w.joint_high)<len(w.joints) {
        index=w.joint_high
        w.joint_high+=1
    } else {
        w.stats.joint_capacity_exhausted+=1
        return {}
    }
    w.joint_count+=1
    joint:=&w.joints[index]
    stamp(w,joint)
    axes:=&w.joint_axes[index]
    axes^={linear_axes=desc.linear,angular_axes=desc.angular}
    joint^={
        user_data=desc.user_data,body_a=index_a,body_b=index_b,generation=joint.generation+1,
        frame_a={desc.frame_a.p,q_normalize(desc.frame_a.q)},frame_b={desc.frame_b.p,q_normalize(desc.frame_b.q)},
        break_force=desc.break_force,break_torque=desc.break_torque,kernel=joint_kernel_of(desc.linear,desc.angular),
    }
    joint.flags=joint_flags_of(joint.kernel,axes,desc.collide_connected)
    for body,side in ([2]^Body{body_a,body_b}) {
        key:=index<<1|i32(side)
        joint.edges[side]={-1,body.joint_list}
        if body.joint_list>=0 {stamp(w,.Joints,body.joint_list>>1);w.joints[body.joint_list>>1].edges[body.joint_list&1].prev=key}
        body.joint_list=key
    }
    if !desc.collide_connected {
        // The joined bodies stop colliding with each other.
        for key:=body_a.contact_list;key>=0; {
            contact_index:=key>>1
            contact:=&w.contacts[contact_index]
            key=contact.edges[key&1].next
            if contact.body_a==index_b || contact.body_b==index_b {contact_destroy(w,contact_index)}
        }
    }
    body_wake(w,index_a)
    body_wake(w,index_b)
    island_link(w,index_a,index_b)
    return joint_handle(w,index)
}

joint_destroy :: proc(w:^World,h:Joint_Handle) {
    joint,index:=joint_get(w,h)
    if joint!=nil {joint_destroy_index(w,index)}
}

@(private)
joint_destroy_index :: proc(w:^World,index:i32) {
    joint:=&w.joints[index]
    stamp(w,joint)
    island_unlink(w,joint.body_a,joint.body_b)
    for body_index,side in ([2]i32{joint.body_a,joint.body_b}) {
        body:=&w.bodies[body_index]
        stamp(w,body)
        edge:=joint.edges[side]
        if edge.prev>=0 {stamp(w,.Joints,edge.prev>>1);w.joints[edge.prev>>1].edges[edge.prev&1].next=edge.next} else {body.joint_list=edge.next}
        if edge.next>=0 {stamp(w,.Joints,edge.next>>1);w.joints[edge.next>>1].edges[edge.next&1].prev=edge.prev}
        body_wake(w,body_index)
    }
    if .Collide_Connected not_in joint.flags {
        // The bodies may collide again: their pairs are searched at the next step.
        for s:=w.bodies[joint.body_a].shape_list;s>=0;s=w.shapes[s].next {shape_moved(w,s)}
    }
    joint^={generation=joint.generation+1,body_a=w.joint_free}
    w.joint_free=index
    w.joint_count-=1
}

joint_bodies :: proc(w:^World,h:Joint_Handle) -> (Body_Handle,Body_Handle) {
    joint,_:=joint_read(w,h)
    if joint==nil {return {},{}}
    return body_handle(w,joint.body_a),body_handle(w,joint.body_b)
}
joint_user_data :: proc(w:^World,h:Joint_Handle) -> u64 {
    joint,_:=joint_read(w,h)
    return joint==nil?0:joint.user_data
}

joint_set_break :: proc(w:^World,h:Joint_Handle,force,torque:f32) {
    joint,_:=joint_get(w,h)
    if joint!=nil {joint.break_force,joint.break_torque=max(force,0),max(torque,0)}
}

// New axes for a joint: the impulses of an axis whose motion, drive or limits changed start again, and all of
// them when its kernel changes.
joint_set_axes :: proc(w:^World,h:Joint_Handle,linear,angular:[3]Joint_Axis) -> Joint_Error {
    joint,index:=joint_get(w,h)
    if joint==nil {return .Invalid_Bodies}
    if error:=joint_configuration_error({linear=linear,angular=angular});error!=.None {return error}
    axes:=&w.joint_axes[index]
    if axes.linear_axes==linear && axes.angular_axes==angular {return .None}
    changed :: proc "contextless" (old,axis:Joint_Axis) -> bool {
        return old.motion!=axis.motion || old.drive!=axis.drive || old.lower!=axis.lower || old.upper!=axis.upper
    }
    kernel:=joint_kernel_of(linear,angular)
    if kernel!=joint.kernel || changed(joint_kernel_axis(kernel,axes.linear_axes,axes.angular_axes),joint_kernel_axis(kernel,linear,angular)) {
        joint.linear_impulse,joint.angular_impulse={},{}
        joint.lower_impulse,joint.upper_impulse,joint.drive_impulse,joint.cone_impulse=0,0,0,0
    }
    for axis,i in linear {if kernel!=joint.kernel || changed(axes.linear_axes[i],axis) {axes.linear_axes_impulse[i]={}}}
    for axis,i in angular {if kernel!=joint.kernel || changed(axes.angular_axes[i],axis) {axes.angular_axes_impulse[i]={}}}
    axes.linear_axes,axes.angular_axes=linear,angular
    joint.kernel=kernel
    joint.flags=joint_flags_of(kernel,axes,.Collide_Connected in joint.flags)
    body_wake(w,joint.body_a)
    body_wake(w,joint.body_b)
    return .None
}

@(private)
twist_angle :: proc "contextless" (qa,qb:Quat) -> f32 {
    rel:=conj(qa)*qb
    return 2*cmath.atan2(rel.w<0?-rel.x:rel.x,abs(rel.w))
}

// Rotation of frame B about the X axis of frame A, radians in (-pi,pi].
joint_angle :: proc(w:^World,h:Joint_Handle) -> f32 {
    joint,_:=joint_read(w,h)
    if joint==nil {return 0}
    return twist_angle(w.bodies[joint.body_a].rotation*joint.frame_a.q,w.bodies[joint.body_b].rotation*joint.frame_b.q)
}
// Translation of frame B along the X axis of frame A, meters.
joint_translation :: proc(w:^World,h:Joint_Handle) -> f32 {
    joint,_:=joint_read(w,h)
    if joint==nil {return 0}
    a,b:=&w.bodies[joint.body_a],&w.bodies[joint.body_b]
    d:=xf_point(body_transform_of(b),joint.frame_b.p)-xf_point(body_transform_of(a),joint.frame_a.p)
    return dot(d,q_rotate(a.rotation*joint.frame_a.q,Vec3{1,0,0}))
}
// Distance between the two anchors, meters.
joint_distance :: proc(w:^World,h:Joint_Handle) -> f32 {
    joint,_:=joint_read(w,h)
    if joint==nil {return 0}
    a,b:=&w.bodies[joint.body_a],&w.bodies[joint.body_b]
    return length(xf_point(body_transform_of(b),joint.frame_b.p)-xf_point(body_transform_of(a),joint.frame_a.p))
}

// A joint of a pattern no kernel in lanes solves, solved one axis at a time.
@(private)
Joint_Solver :: struct {
    joint:i32,
    a,b:i32,
    ma,mb:f32,
    ia,ib:Mat3,
    ra,rb:Vec3, // anchors from the centers of mass at the start of the step, world axes
    qa,qb:Quat, // world rotation of the frames at the start of the step
    dc:Vec3,    // center of B minus center of A at the start of the step
    axes:^Joint_Axes,
}

@(private) Joint_Velocity :: struct {va,wa,vb,wb:Vec3}
// One scalar constraint: its velocity is lin.(vb-va)+ang_b.wb-ang_a.wa.
@(private) Axis_Row :: struct {lin,ang_a,ang_b:Vec3,mass:f32}

@(private)
row_make :: #force_inline proc "contextless" (js:^Joint_Solver,lin,ang_a,ang_b:Vec3) -> Axis_Row {
    k:=dot(lin,lin)*(js.ma+js.mb)+dot(ang_a,js.ia*ang_a)+dot(ang_b,js.ib*ang_b)
    return {lin,ang_a,ang_b,k>0?1/k:0}
}
@(private)
row_speed :: #force_inline proc "contextless" (row:Axis_Row,v:^Joint_Velocity) -> f32 {
    return dot(row.lin,v.vb-v.va)+dot(row.ang_b,v.wb)-dot(row.ang_a,v.wa)
}
@(private)
row_apply :: #force_inline proc "contextless" (js:^Joint_Solver,row:Axis_Row,v:^Joint_Velocity,impulse:f32) {
    v.va-=(js.ma*impulse)*row.lin
    v.wa-=js.ia*(impulse*row.ang_a)
    v.vb+=(js.mb*impulse)*row.lin
    v.wb+=js.ib*(impulse*row.ang_b)
}

@(private)
row_limits :: proc "contextless" (js:^Joint_Solver,row:Axis_Row,v:^Joint_Velocity,position,lower,upper:f32,lower_impulse,upper_impulse:^f32,soft:Softness,use_bias:bool,inv_h:f32) {
        for is_upper in ([2]bool{false,true}) {
            c:=is_upper?upper-position:position-lower
            bias:f32
            if c>0 {
                bias=c*inv_h
            } else if use_bias {
                bias=soft.bias_rate*c
            }
            sign:f32=is_upper?-1:1
            accumulated:=is_upper?upper_impulse:lower_impulse
            impulse:=-row.mass*(sign*row_speed(row,v)+bias)
            new_impulse:=max(accumulated^+impulse,0)
            impulse=new_impulse-accumulated^
            accumulated^=new_impulse
            row_apply(js,row,v,sign*impulse)
        }
}

@(private)
axis_solve :: proc "contextless" (st:^Step,js:^Joint_Solver,row:Axis_Row,v:^Joint_Velocity,axis:Joint_Axis,accumulated:^Axis_Impulse,position:f32,warm,use_bias:bool) {
    if warm {
        row_apply(js,row,v,accumulated.drive+accumulated.lower-accumulated.upper+accumulated.lock)
        return
    }
    soft:=use_bias?st.joint_softness:Softness{0,1,0}
    if axis.motion==.Locked {
        impulse:=-row.mass*soft.mass_scale*(row_speed(row,v)+soft.bias_rate*position)-soft.impulse_scale*accumulated.lock
        accumulated.lock+=impulse
        row_apply(js,row,v,impulse)
        return
    }
    if axis_driven(axis) {
        softness:=Softness{0,1,0}
        target:=axis.position
        if axis.motion==.Limited {target=clamp(target,axis.lower,axis.upper)}
        if .Position in axis.drive {softness=soft_make(min(axis.hertz,0.25*st.inv_h),axis.damping_ratio,st.h)}
        speed:=.Velocity in axis.drive?axis.velocity:f32(0)
        impulse:=-row.mass*softness.mass_scale*(row_speed(row,v)-speed+softness.bias_rate*(position-target))-softness.impulse_scale*accumulated.drive
        limit:=axis.max_force*st.h
        next:=clamp(accumulated.drive+impulse,-limit,limit)
        impulse=next-accumulated.drive
        accumulated.drive=next
        row_apply(js,row,v,impulse)
    }
    if axis.motion==.Limited {row_limits(js,row,v,position,axis.lower,axis.upper,&accumulated.lower,&accumulated.upper,soft,use_bias,st.inv_h)}
}

@(private)
angular_axes_solve :: proc "contextless" (st:^Step,js:^Joint_Solver,v:^Joint_Velocity,qa,qb:Quat,warm,use_bias:bool) {
    rotation:=q_rotation_vector(conj(qa)*qb)
    angle2:=dot(rotation,rotation)
    coefficient:f32=1.0/12
    if angle2>1e-6 {
        angle:=cmath.sqrt(angle2)
        coefficient=(1-0.5*angle/cmath.tan(0.5*angle))/angle2
    }
    cone:=axes_cone(js.axes.angular_axes)
    for axis,i in js.axes.angular_axes {
        // The swings of a cone keep their drives; the cone limits them together below.
        axis:=axis
        if cone && i>0 {axis.motion=.Free}
        if axis_free(axis) {continue}
        basis:Vec3
        basis[i]=1
        jacobian:=q_rotate(qa,basis+0.5*cross(rotation,basis)+coefficient*cross(rotation,cross(rotation,basis)))
        axis_solve(st,js,row_make(js,{},jacobian,jacobian),v,axis,&js.axes.angular_axes_impulse[i],rotation[i],warm,use_bias)
    }
    if !cone {return}
    // The swing between the X axes stays inside the cone, whose angle toward the side it swings to is that of
    // the ellipse of the limits of that side; its impulse is kept as the upper one of axis Y.
    impulse:=&js.axes.angular_axes_impulse[1].upper
    ax,bx:=q_rotate(qa,Vec3{1,0,0}),q_rotate(qb,Vec3{1,0,0})
    normal:=cross(ax,bx)
    sine:=length(normal)
    if sine<=1e-6 {
        if !warm {impulse^=0}
        return
    }
    row:=row_make(js,{},normal/sine,normal/sine)
    if warm {
        row_apply(js,row,v,-impulse^)
        return
    }
    side:=q_inv_rotate(qa,normal/sine)
    y,z:=js.axes.angular_axes[1],js.axes.angular_axes[2]
    reach_y,reach_z:=max(side.y>0?y.upper:-y.lower,1e-4),max(side.z>0?z.upper:-z.lower,1e-4)
    reach:=1/cmath.sqrt(side.y*side.y/(reach_y*reach_y)+side.z*side.z/(reach_z*reach_z))
    c:=reach-cmath.atan2(sine,dot(ax,bx))
    bias:f32=c>0?c*st.inv_h:(use_bias?st.joint_softness.bias_rate*c:0)
    next:=max(impulse^-row.mass*(bias-row_speed(row,v)),0)
    row_apply(js,row,v,-(next-impulse^))
    impulse^=next
}

@(private)
joints_prepare_task :: proc(data:rawptr,first,last,worker:int) #no_bounds_check {
    w:=(^World)(data)
    st:=&w.step
    for &js in st.joint_data[first:last] {
        joint:=&w.joints[js.joint]
        body_a,body_b:=&w.bodies[joint.body_a],&w.bodies[joint.body_b]
        js.a,js.b=body_a.solver_index,body_b.solver_index
        js.ma,js.mb=0,0
        js.ia,js.ib={},{}
        if js.a>=0 {js.ma,js.ia=st.params[js.a].inv_mass,st.params[js.a].inv_inertia}
        if js.b>=0 {js.mb,js.ib=st.params[js.b].inv_mass,st.params[js.b].inv_inertia}
        js.ra=q_rotate(body_a.rotation,joint.frame_a.p-body_a.local_center)
        js.rb=q_rotate(body_b.rotation,joint.frame_b.p-body_b.local_center)
        js.qa,js.qb=body_a.rotation*joint.frame_a.q,body_b.rotation*joint.frame_b.q
        js.dc=body_b.center-body_a.center
        js.axes=&w.joint_axes[js.joint]
    }
}

// One pass over a joint. `warm` applies the accumulated impulses; otherwise each axis is solved in turn,
// softly against its position error when `use_bias` is set. The impulses accumulate in Joint_Axes.
@(private)
joint_solve :: proc "contextless" (st:^Step,js:^Joint_Solver,warm,use_bias:bool) #no_bounds_check {
    body_a:=js.a>=0?st.bodies[js.a]:SOLVER_BODY_REST
    body_b:=js.b>=0?st.bodies[js.b]:SOLVER_BODY_REST
    v:=Joint_Velocity{body_a.v,body_a.w,body_b.v,body_b.w}
    qa,qb:=body_a.dq*js.qa,body_b.dq*js.qb
    angular_axes_solve(st,js,&v,qa,qb,warm,use_bias)
    ra,rb:=q_rotate(body_a.dq,js.ra),q_rotate(body_b.dq,js.rb)
    d:=body_b.dp-body_a.dp+js.dc+rb-ra
    shared:=axes_distance(js.axes.linear_axes)
    across:Vec3
    for axis,i in js.axes.linear_axes {
        basis:Vec3
        basis[i]=1
        direction:=q_rotate(qa,basis)
        if shared>=0 && axis.motion==.Limited {
            across+=dot(d,direction)*direction
            continue
        }
        if axis_free(axis) {continue}
        row:=row_make(js,direction,cross(d+ra,direction),cross(rb,direction))
        axis_solve(st,js,row,&v,axis,&js.axes.linear_axes_impulse[i],dot(d,direction),warm,use_bias)
    }
    if shared>=0 {
        // The length of the offset across the limited axes, along it.
        distance:=length(across)
        basis:Vec3
        basis[shared]=1
        direction:=distance>1e-6?across/distance:q_rotate(qa,basis)
        row:=row_make(js,direction,cross(d+ra,direction),cross(rb,direction))
        axis_solve(st,js,row,&v,js.axes.linear_axes[shared],&js.axes.linear_axes_impulse[shared],distance,warm,use_bias)
    }
    if js.ma>0 {st.bodies[js.a].v,st.bodies[js.a].w=v.va,v.wa}
    if js.mb>0 {st.bodies[js.b].v,st.bodies[js.b].w=v.vb,v.wb}
}

// One pass over the joints of a color solved one at a time, from step.stage_offset.
@(private)
joints_scalar_task :: proc(data:rawptr,first,last,worker:int) #no_bounds_check {
    st:=&(^World)(data).step
    warm:=st.pass==.Warm_Start
    for i in st.joint_order[st.stage_offset+first:st.stage_offset+last] {joint_solve(st,&st.joint_data[i],warm,!warm && st.use_bias)}
}

// Force in newtons and torque in newton meters that the joint applied in the last step.
joint_reaction :: proc(w:^World,h:Joint_Handle) -> (force,torque:f32) {
    joint,index:=joint_read(w,h)
    if joint==nil || w.step.inv_h==0 {return}
    return joint_load(joint,&w.joint_axes[index],w.step.inv_h)
}

@(private)
joint_load :: proc "contextless" (joint:^Joint,axes:^Joint_Axes,inv_h:f32) -> (force,torque:f32) {
    axial:=abs(joint.drive_impulse+joint.lower_impulse-joint.upper_impulse)
    switch joint.kernel {
    case .Fixed: force,torque=length(joint.linear_impulse),length(joint.angular_impulse)
    case .Spherical: force,torque=length(joint.linear_impulse),axial+joint.cone_impulse
    case .Revolute: force,torque=length(joint.linear_impulse),length(Vec3{axial,joint.angular_impulse.y,joint.angular_impulse.z})
    case .Prismatic: force,torque=length(Vec3{axial,joint.linear_impulse.y,joint.linear_impulse.z}),length(joint.angular_impulse)
    case .Distance: force=abs(joint.linear_impulse.x)+axial
    case .General:
        linear,angular:Vec3
        for accumulated,i in axes.linear_axes_impulse {linear[i]=accumulated.drive+accumulated.lower-accumulated.upper+accumulated.lock}
        for accumulated,i in axes.angular_axes_impulse {angular[i]=accumulated.drive+accumulated.lower-accumulated.upper+accumulated.lock}
        force,torque=length(linear),length(angular)
    }
    return force*inv_h,torque*inv_h
}

// Removes the joints loaded beyond their strength and reports them.
@(private)
joints_break :: proc(w:^World) {
    st:=&w.step
    for index in st.joint_solved[:st.joint_solved_count] {
        joint:=&w.joints[index]
        if joint.break_force<=0 && joint.break_torque<=0 {continue}
        force,torque:=joint_load(joint,&w.joint_axes[index],st.inv_h)
        if (joint.break_force>0 && force>joint.break_force) || (joint.break_torque>0 && torque>joint.break_torque) {
            event_push(w,w.events.joint_break,4,Joint_Break_Event{
                joint_handle(w,index),body_handle(w,joint.body_a),body_handle(w,joint.body_b),force,torque,
            })
            joint_destroy_index(w,index)
        }
    }
}
