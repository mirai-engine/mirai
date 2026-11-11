package mirai_physics

import cmath "core:math"
import "core:simd"

// Joints of every kernel but General are solved four at a time, like contacts: a block holds joints of one
// kernel and one graph color. The joints without color share bodies and run in order on blocks of one lane.
// General joints go through joint_solve, one at a time.
@(private) LANE_JOINT_KERNELS :: int(Joint_Kernel.General)

@(private) Joint_Block :: struct($N:int) {
    a,b:[N]i32,             // solver bodies, -1 when static or asleep
    write_a,write_b:[N]i32, // the same for the bodies the joint moves, else -1
    joint:[N]i32,           // slot of the joint, -1 in an empty lane
    kernel:Joint_Kernel,
    flags:Joint_Flags,      // of all the lanes
    _:[2]u32,
    ma,mb:#simd[N]f32,
    ia,ib:Sym3(N),
    angular_mass:Sym3(N),   // inverse of ia+ib
    ra,rb:[3]#simd[N]f32,   // anchors from the centers of mass at the start of the step, world axes
    qa,qb:[4]#simd[N]f32,   // world rotation of the frames at the start of the step: x, y, z, w
    dc:[3]#simd[N]f32,      // center of B less center of A at the start of the step
    lower,upper,cone,length:#simd[N]f32,
    target,drive_speed,max_drive_impulse:#simd[N]f32, // of the drive: position, velocity and force times the substep
    drive_bias,drive_mass,drive_decay:#simd[N]f32,    // softness of the drive: rigid without a position
    limit,drive,coned:#simd[N]u32, // lanes that have each option
    linear,angular:[3]#simd[N]f32,
    lower_impulse,upper_impulse,drive_impulse,cone_impulse:#simd[N]f32,
}
#assert(offset_of(Joint_Block(WIDE),ma)==96)

@(private) Joint_Row :: struct($N:int) {lin,ang_a,ang_b:[3]#simd[N]f32,mass:#simd[N]f32}

// Constants of a pass, in every lane.
@(private) Joint_Pass :: struct($N:int) {bias_rate,mass_scale,impulse_scale,inv_h,zero,one:#simd[N]f32,warm,use_bias:bool}

@(private) lane_mask_set :: #force_inline proc "contextless" (m:^#simd[$N]u32,lane:int,on:bool) {(^[N]u32)(m)[lane]=on?~u32(0):0}

@(private) quat_conj4 :: #force_inline proc "contextless" (q:[4]#simd[$N]f32) -> [4]#simd[N]f32 {return {-q[0],-q[1],-q[2],q[3]}}
// Product of quaternions given as x, y, z, w.
@(private)
quat_mul4 :: #force_inline proc "contextless" (a,b:[4]#simd[$N]f32) -> [4]#simd[N]f32 {
    return {
        a[3]*b[0]+a[0]*b[3]+a[1]*b[2]-a[2]*b[1],
        a[3]*b[1]-a[0]*b[2]+a[1]*b[3]+a[2]*b[0],
        a[3]*b[2]+a[0]*b[1]-a[1]*b[0]+a[2]*b[3],
        a[3]*b[3]-a[0]*b[0]-a[1]*b[1]-a[2]*b[2],
    }
}
@(private)
rotate4 :: #force_inline proc "contextless" (q:[4]#simd[$N]f32,v:[3]#simd[N]f32) -> [3]#simd[N]f32 {
    u:=[3]#simd[N]f32{q[0],q[1],q[2]}
    t:=cross4(u,v)
    s:=cross4(u,t)+q[3]*t
    return v+s+s
}
// Axis X, Y or Z of the frame that q turns to.
@(private)
quat_axis4 :: #force_inline proc "contextless" (q:[4]#simd[$N]f32,$AXIS:int) -> [3]#simd[N]f32 {
    x,y,z,w:=q[0],q[1],q[2],q[3]
    one:#simd[N]f32=1
    two:#simd[N]f32=2
    when AXIS==0 {
        return {one-two*(y*y+z*z),two*(x*y+w*z),two*(x*z-w*y)}
    } else when AXIS==1 {
        return {two*(x*y-w*z),one-two*(x*x+z*z),two*(y*z+w*x)}
    } else {
        return {two*(x*z+w*y),two*(y*z-w*x),one-two*(x*x+y*y)}
    }
}
// Zero for a vector too short to give a direction.
@(private)
normalize_length4 :: #force_inline proc "contextless" (v:[3]#simd[$N]f32) -> (n:[3]#simd[N]f32,l:#simd[N]f32) {
    zero:#simd[N]f32=0
    l=simd.sqrt(dot4(v,v))
    long:=simd.lanes_ge(l,1e-20)
    s:=simd.select(long,1/simd.max(l,1e-20),zero)
    return v*s,simd.select(long,l,zero)
}
@(private)
atan2_lanes :: proc "contextless" (y,x:#simd[$N]f32) -> (out:#simd[N]f32) {
    y,x:=y,x
    for i in 0..<N {lane_set(&out,i,cmath.atan2(lane_get(&y,i),lane_get(&x,i)))}
    return
}
// Angle of a revolute joint or twist of a spherical one, in (-pi,pi].
@(private)
twist_angle4 :: proc "contextless" (qa,qb:[4]#simd[$N]f32) -> #simd[N]f32 {
    rel:=quat_mul4(quat_conj4(qa),qb)
    zero:#simd[N]f32=0
    x:=simd.select(simd.lanes_lt(rel[3],zero),-rel[0],rel[0])
    return 2*atan2_lanes(x,simd.abs(rel[3]))
}
@(private) sym_add4 :: #force_inline proc "contextless" (a,b:Sym3($N)) -> Sym3(N) {
    return {a.xx+b.xx,a.yy+b.yy,a.zz+b.zz,a.xy+b.xy,a.xz+b.xz,a.yz+b.yz}
}
// Solves k x = b for symmetric k; zero in the lanes where k is singular, with the tolerance of mat3_solve.
@(private)
sym_solve4 :: proc "contextless" (k:Sym3($N),b:[3]#simd[N]f32) -> [3]#simd[N]f32 {
    zero:#simd[N]f32=0
    largest:#simd[N]f32=max(f32)
    scale:=simd.max(simd.max(simd.max(simd.abs(k.xx),simd.abs(k.yy)),simd.max(simd.abs(k.zz),simd.abs(k.xy))),simd.max(simd.abs(k.xz),simd.abs(k.yz)))
    valid:=simd.bit_and(simd.lanes_ge(scale,1.1754944e-38),simd.lanes_le(scale,largest))
    inv:=simd.select(valid,1/scale,zero)
    xx,yy,zz,xy,xz,yz:=inv*k.xx,inv*k.yy,inv*k.zz,inv*k.xy,inv*k.xz,inv*k.yz
    c_xx:=yy*zz-yz*yz
    c_xy:=xz*yz-xy*zz
    c_xz:=xy*yz-xz*yy
    c_yy:=xx*zz-xz*xz
    c_yz:=xy*xz-xx*yz
    c_zz:=xx*yy-xy*xy
    det:=xx*c_xx+xy*c_xy+xz*c_xz
    s:=inv/det
    ok:=simd.bit_and(simd.bit_and(valid,simd.lanes_ge(simd.abs(det),MAT3_SINGULAR)),simd.lanes_le(simd.abs(s),largest))
    s=simd.select(ok,s,zero)
    return {s*(c_xx*b.x+c_xy*b.y+c_xz*b.z),s*(c_xy*b.x+c_yy*b.y+c_yz*b.z),s*(c_xz*b.x+c_yz*b.y+c_zz*b.z)}
}
// (ma+mb) I - [ra]x Ia [ra]x - [rb]x Ib [rb]x: the mass that resists moving the anchors apart.
@(private)
point_mass4 :: #force_inline proc "contextless" (jb:^Joint_Block($N),ra,rb:[3]#simd[N]f32) -> (k:Sym3(N)) {
    zero:#simd[N]f32=0
    m:=jb.ma+jb.mb
    k.xx,k.yy,k.zz=m,m,m
    add :: #force_inline proc "contextless" (k:^Sym3($N),i:Sym3(N),r:[3]#simd[N]f32) {
        zero:#simd[N]f32=0
        c0:=cross4(sym_mul4(i,[3]#simd[N]f32{zero,r.z,-r.y}),r)
        c1:=cross4(sym_mul4(i,[3]#simd[N]f32{-r.z,zero,r.x}),r)
        c2:=cross4(sym_mul4(i,[3]#simd[N]f32{r.y,-r.x,zero}),r)
        k.xx+=c0.x;k.xy+=c1.x;k.xz+=c2.x
        k.yy+=c1.y;k.yz+=c2.y;k.zz+=c2.z
    }
    add(&k,jb.ia,ra)
    add(&k,jb.ib,rb)
    return
}

@(private)
joint_row4 :: #force_inline proc "contextless" (jb:^Joint_Block($N),lin,ang_a,ang_b:[3]#simd[N]f32) -> (row:Joint_Row(N)) {
    zero:#simd[N]f32=0
    k:=dot4(lin,lin)*(jb.ma+jb.mb)+dot4(ang_a,sym_mul4(jb.ia,ang_a))+dot4(ang_b,sym_mul4(jb.ib,ang_b))
    row.lin=lin
    row.ang_a=ang_a
    row.ang_b=ang_b
    row.mass=simd.select(simd.lanes_gt(k,zero),1/simd.max(k,1e-30),zero)
    return
}
@(private)
row_speed4 :: #force_inline proc "contextless" (row:^Joint_Row($N),a,b:^Body_Wide(N)) -> #simd[N]f32 {
    return dot4(row.lin,b.v-a.v)+dot4(row.ang_b,b.w)-dot4(row.ang_a,a.w)
}
@(private)
row_apply4 :: #force_inline proc "contextless" (jb:^Joint_Block($N),row:^Joint_Row(N),a,b:^Body_Wide(N),impulse:#simd[N]f32) {
    a.v-=(jb.ma*impulse)*row.lin
    a.w-=sym_mul4(jb.ia,impulse*row.ang_a)
    b.v+=(jb.mb*impulse)*row.lin
    b.w+=sym_mul4(jb.ib,impulse*row.ang_b)
}

// A limit is a hard velocity constraint, so no motor or load pushes through it; only the correction of a
// violation is soft.
@(private)
row_limits4 :: proc "contextless" (jb:^Joint_Block($N),row:^Joint_Row(N),a,b:^Body_Wide(N),pass:^Joint_Pass(N),position:#simd[N]f32,lanes:#simd[N]u32) {
    for is_upper in ([2]bool{false,true}) {
        c:=is_upper?jb.upper-position:position-jb.lower
        soft:=pass.use_bias?pass.bias_rate*c:pass.zero
        bias:=simd.select(simd.lanes_gt(c,pass.zero),c*pass.inv_h,soft)
        accumulated:=is_upper?&jb.upper_impulse:&jb.lower_impulse
        speed:=row_speed4(row,a,b)
        impulse:=-row.mass*((is_upper?-speed:speed)+bias)
        next:=simd.max(accumulated^+impulse,pass.zero)
        impulse=simd.select(lanes,next-accumulated^,pass.zero)
        accumulated^+=impulse
        row_apply4(jb,row,a,b,is_upper?-impulse:impulse)
    }
}

// Drive and limits along one row, as axis_solve does them; `position` is the angle, translation or length along
// it.
@(private)
row_solve4 :: proc "contextless" (jb:^Joint_Block($N),row:^Joint_Row(N),a,b:^Body_Wide(N),pass:^Joint_Pass(N),position:#simd[N]f32,flags:Joint_Flags) {
    if pass.warm {
        row_apply4(jb,row,a,b,jb.drive_impulse+jb.lower_impulse-jb.upper_impulse)
        return
    }
    if .Drive in flags {
        impulse:=-row.mass*jb.drive_mass*(row_speed4(row,a,b)-jb.drive_speed+(position-jb.target)*jb.drive_bias)-jb.drive_decay*jb.drive_impulse
        next:=simd.clamp(jb.drive_impulse+impulse,-jb.max_drive_impulse,jb.max_drive_impulse)
        impulse=simd.select(jb.drive,next-jb.drive_impulse,pass.zero)
        jb.drive_impulse+=impulse
        row_apply4(jb,row,a,b,impulse)
    }
    if .Limit in flags {row_limits4(jb,row,a,b,pass,position,jb.limit)}
}

// The anchors coincide.
@(private)
joint_point4 :: proc "contextless" (jb:^Joint_Block($N),a,b:^Body_Wide(N),pass:^Joint_Pass(N),ra,rb,d:[3]#simd[N]f32) {
    impulse:=jb.linear
    if !pass.warm {
        speed:=b.v+cross4(b.w,rb)-a.v-cross4(a.w,ra)
        impulse=-pass.mass_scale*sym_solve4(point_mass4(jb,ra,rb),speed+pass.bias_rate*d)-pass.impulse_scale*jb.linear
        jb.linear+=impulse
    }
    a.v-=jb.ma*impulse
    a.w-=sym_mul4(jb.ia,cross4(ra,impulse))
    b.v+=jb.mb*impulse
    b.w+=sym_mul4(jb.ib,cross4(rb,impulse))
}

// The frames keep their relative rotation.
@(private)
joint_lock4 :: proc "contextless" (jb:^Joint_Block($N),a,b:^Body_Wide(N),pass:^Joint_Pass(N),qa,qb:[4]#simd[N]f32) {
    impulse:=jb.angular
    if !pass.warm {
        rel:=quat_mul4(qb,quat_conj4(qa))
        two:#simd[N]f32=2
        sign:=simd.select(simd.lanes_lt(rel[3],pass.zero),-two,two)
        c:=[3]#simd[N]f32{sign*rel[0],sign*rel[1],sign*rel[2]}
        impulse=-pass.mass_scale*sym_mul4(jb.angular_mass,b.w-a.w+pass.bias_rate*c)-pass.impulse_scale*jb.angular
        jb.angular+=impulse
    }
    a.w-=sym_mul4(jb.ia,impulse)
    b.w+=sym_mul4(jb.ib,impulse)
}

// Two coupled rows along the Y and Z axes of frame A; `error` is their position error.
@(private)
joint_pair4 :: proc "contextless" (jb:^Joint_Block($N),a,b:^Body_Wide(N),pass:^Joint_Pass(N),row_y,row_z:^Joint_Row(N),kyy,kzz,kyz,error_y,error_z:#simd[N]f32,impulse:^[2]#simd[N]f32) {
    applied:=impulse^
    if !pass.warm {
        rhs_y:=row_speed4(row_y,a,b)+pass.bias_rate*error_y
        rhs_z:=row_speed4(row_z,a,b)+pass.bias_rate*error_z
        det:=kyy*kzz-kyz*kyz
        inv:=simd.select(simd.lanes_ne(det,pass.zero),1/det,pass.zero)
        applied[0]=-pass.mass_scale*(kzz*rhs_y-kyz*rhs_z)*inv-pass.impulse_scale*impulse[0]
        applied[1]=-pass.mass_scale*(kyy*rhs_z-kyz*rhs_y)*inv-pass.impulse_scale*impulse[1]
        impulse[0]+=applied[0]
        impulse[1]+=applied[1]
    }
    row_apply4(jb,row_y,a,b,applied[0])
    row_apply4(jb,row_z,a,b,applied[1])
}

// One pass over a block. `warm` applies the accumulated impulses; otherwise each constraint is solved in turn,
// softly against its position error when `use_bias` is set.
@(private)
joint_block_solve :: #force_inline proc "contextless" (st:^Step,jb:^Joint_Block($N),warm:bool) #no_bounds_check {
    rest:=SOLVER_BODY_REST
    a:=bodies_gather(st.bodies,jb.a,&rest,true)
    b:=bodies_gather(st.bodies,jb.b,&rest,true)
    use_bias:=st.use_bias && !warm
    soft:=use_bias?st.joint_softness:Softness{0,1,0}
    pass:=Joint_Pass(N){soft.bias_rate,soft.mass_scale,soft.impulse_scale,st.inv_h,0,1,warm,use_bias}
    ra:=rotate4(a.dq,jb.ra)
    rb:=rotate4(b.dq,jb.rb)
    qa:=quat_mul4(a.dq,jb.qa)
    qb:=quat_mul4(b.dq,jb.qb)
    d:=b.dp-a.dp+jb.dc+rb-ra
    ax:=quat_axis4(qa,0)
    switch jb.kernel {
    case .Fixed:
        joint_lock4(jb,&a,&b,&pass,qa,qb)
        joint_point4(jb,&a,&b,&pass,ra,rb,d)
    case .Revolute:
        if jb.flags&{.Drive,.Limit}!={} {
            row:=joint_row4(jb,{},ax,ax)
            position:=pass.zero
            if !warm {position=twist_angle4(qa,qb)}
            row_solve4(jb,&row,&a,&b,&pass,position,jb.flags&{.Drive,.Limit})
        }
        // The X axes stay aligned: no rotation about the Y and Z axes of frame A.
        ay,az:=quat_axis4(qa,1),quat_axis4(qa,2)
        row_y,row_z:=joint_row4(jb,{},ay,ay),joint_row4(jb,{},az,az)
        inertia:=sym_add4(jb.ia,jb.ib)
        error:=cross4(ax,quat_axis4(qb,0))
        impulse:=[2]#simd[N]f32{jb.angular.y,jb.angular.z}
        joint_pair4(jb,&a,&b,&pass,&row_y,&row_z,dot4(ay,sym_mul4(inertia,ay)),dot4(az,sym_mul4(inertia,az)),dot4(ay,sym_mul4(inertia,az)),dot4(ay,error),dot4(az,error),&impulse)
        jb.angular.y,jb.angular.z=impulse[0],impulse[1]
        joint_point4(jb,&a,&b,&pass,ra,rb,d)
    case .Prismatic:
        if jb.flags&{.Drive,.Limit}!={} {
            row:=joint_row4(jb,ax,cross4(d+ra,ax),cross4(rb,ax))
            row_solve4(jb,&row,&a,&b,&pass,dot4(d,ax),jb.flags&{.Drive,.Limit})
        }
        joint_lock4(jb,&a,&b,&pass,qa,qb)
        // No translation across the axis.
        ay,az:=quat_axis4(qa,1),quat_axis4(qa,2)
        row_y:=joint_row4(jb,ay,cross4(d+ra,ay),cross4(rb,ay))
        row_z:=joint_row4(jb,az,cross4(d+ra,az),cross4(rb,az))
        kyy:=simd.select(simd.lanes_gt(row_y.mass,pass.zero),1/simd.max(row_y.mass,1e-30),pass.zero)
        kzz:=simd.select(simd.lanes_gt(row_z.mass,pass.zero),1/simd.max(row_z.mass,1e-30),pass.zero)
        kyz:=dot4(row_y.ang_a,sym_mul4(jb.ia,row_z.ang_a))+dot4(row_y.ang_b,sym_mul4(jb.ib,row_z.ang_b))
        impulse:=[2]#simd[N]f32{jb.linear.y,jb.linear.z}
        joint_pair4(jb,&a,&b,&pass,&row_y,&row_z,kyy,kzz,kyz,dot4(d,ay),dot4(d,az),&impulse)
        jb.linear.y,jb.linear.z=impulse[0],impulse[1]
    case .Spherical:
        bx:=quat_axis4(qb,0)
        if .Cone in jb.flags {
            // The swing between the X axes stays inside the cone.
            axis,sine:=normalize_length4(cross4(ax,bx))
            along:=dot4(ax,bx)
            // Folded exactly back the swing has no side of its own: it opens about the Y axis of frame A.
            back:=simd.bit_and(simd.lanes_le(sine,1e-6),simd.lanes_lt(along,pass.zero))
            ay:=quat_axis4(qa,1)
            axis={simd.select(back,ay.x,axis.x),simd.select(back,ay.y,axis.y),simd.select(back,ay.z,axis.z)}
            swings:=simd.bit_and(jb.coned,simd.bit_or(simd.lanes_gt(sine,1e-6),back))
            row:=joint_row4(jb,{},axis,axis)
            impulse:=jb.cone_impulse
            if !warm {
                c:=jb.cone-atan2_lanes(sine,along)
                soft_bias:=use_bias?pass.bias_rate*c:pass.zero
                bias:=simd.select(simd.lanes_gt(c,pass.zero),c*pass.inv_h,soft_bias)
                next:=simd.max(jb.cone_impulse-row.mass*(bias-row_speed4(&row,&a,&b)),pass.zero)
                impulse=next-jb.cone_impulse
                jb.cone_impulse=simd.select(swings,next,simd.select(jb.coned,pass.zero,jb.cone_impulse))
            }
            row_apply4(jb,&row,&a,&b,-simd.select(swings,impulse,pass.zero))
        }
        if .Limit in jb.flags {
            twist,length:=normalize_length4(ax+bx)
            straight:=simd.lanes_eq(length,pass.zero)
            twist={simd.select(straight,ax.x,twist.x),simd.select(straight,ax.y,twist.y),simd.select(straight,ax.z,twist.z)}
            row:=joint_row4(jb,{},twist,twist)
            position:=pass.zero
            if !warm {position=twist_angle4(qa,qb)}
            row_solve4(jb,&row,&a,&b,&pass,position,{.Limit})
        }
        joint_point4(jb,&a,&b,&pass,ra,rb,d)
    case .Distance:
        axis,distance:=normalize_length4(d)
        near:=simd.lanes_lt(distance,1e-6)
        axis={simd.select(near,ax.x,axis.x),simd.select(near,ax.y,axis.y),simd.select(near,ax.z,axis.z)}
        row:=joint_row4(jb,axis,cross4(ra,axis),cross4(rb,axis))
        // Driven or free between the limits, or rigid at its length.
        springy:=simd.bit_or(jb.drive,jb.limit)
        if warm {
            row_apply4(jb,&row,&a,&b,simd.select(springy,jb.drive_impulse+jb.lower_impulse-jb.upper_impulse,jb.linear.x))
        } else {
            if jb.flags&{.Drive,.Limit}!={} {row_solve4(jb,&row,&a,&b,&pass,distance,jb.flags&{.Drive,.Limit})}
            impulse:=-row.mass*pass.mass_scale*(row_speed4(&row,&a,&b)+pass.bias_rate*(distance-jb.length))-pass.impulse_scale*jb.linear.x
            impulse=simd.select(springy,pass.zero,impulse)
            jb.linear.x+=impulse
            row_apply4(jb,&row,&a,&b,impulse)
        }
    case .General:
    }
    bodies_scatter(st.bodies,jb.write_a,&a)
    bodies_scatter(st.bodies,jb.write_b,&b)
}

// Fills the lanes of a block from the joints of `slots`; a lane whose slot is -1 stays empty.
@(private)
joint_block_prepare :: proc(w:^World,jb:^Joint_Block($N),slots:[]i32) #no_bounds_check {
    st:=&w.step
    jb^={}
    for lane in 0..<N {jb.a[lane],jb.b[lane],jb.write_a[lane],jb.write_b[lane],jb.joint[lane]=-1,-1,-1,-1,slots[lane]}
    for lane in 0..<N {
        index:=slots[lane]
        if index<0 {continue}
        joint:=&w.joints[index]
        axes:=&w.joint_axes[index]
        body_a,body_b:=&w.bodies[joint.body_a],&w.bodies[joint.body_b]
        a,b:=body_a.solver_index,body_b.solver_index
        ma,mb:f32
        ia,ib:Mat3
        if a>=0 {ma,ia=st.params[a].inv_mass,st.params[a].inv_inertia}
        if b>=0 {mb,ib=st.params[b].inv_mass,st.params[b].inv_inertia}
        jb.kernel=joint.kernel
        jb.flags+=joint.flags
        jb.a[lane],jb.b[lane]=a,b
        jb.write_a[lane],jb.write_b[lane]=ma>0?a:-1,mb>0?b:-1
        lane_set(&jb.ma,lane,ma)
        lane_set(&jb.mb,lane,mb)
        lane_set_sym(&jb.ia,lane,ia)
        lane_set_sym(&jb.ib,lane,ib)
        if joint.kernel==.Fixed || joint.kernel==.Prismatic {lane_set_sym(&jb.angular_mass,lane,mat3_inverse(ia+ib))}
        lane_set3(&jb.ra,lane,q_rotate(body_a.rotation,joint.frame_a.p-body_a.local_center))
        lane_set3(&jb.rb,lane,q_rotate(body_b.rotation,joint.frame_b.p-body_b.local_center))
        qa,qb:=body_a.rotation*joint.frame_a.q,body_b.rotation*joint.frame_b.q
        lane_set(&jb.qa[0],lane,qa.x);lane_set(&jb.qa[1],lane,qa.y);lane_set(&jb.qa[2],lane,qa.z);lane_set(&jb.qa[3],lane,qa.w)
        lane_set(&jb.qb[0],lane,qb.x);lane_set(&jb.qb[1],lane,qb.y);lane_set(&jb.qb[2],lane,qb.z);lane_set(&jb.qb[3],lane,qb.w)
        lane_set3(&jb.dc,lane,body_b.center-body_a.center)
        axis:=joint_kernel_axis(joint.kernel,axes.linear_axes,axes.angular_axes)
        lane_set(&jb.lower,lane,axis.lower)
        lane_set(&jb.upper,lane,axis.upper)
        lane_set(&jb.cone,lane,axes.angular_axes[1].upper)
        lane_set(&jb.length,lane,axis.lower)
        lane_set(&jb.target,lane,axis.position)
        lane_set(&jb.drive_speed,lane,.Velocity in axis.drive?axis.velocity:0)
        lane_set(&jb.max_drive_impulse,lane,axis.max_force*st.h)
        drive:=.Position in axis.drive?soft_make(min(axis.hertz,0.25*st.inv_h),axis.damping_ratio,st.h):Softness{0,1,0}
        lane_set(&jb.drive_bias,lane,drive.bias_rate)
        lane_set(&jb.drive_mass,lane,drive.mass_scale)
        lane_set(&jb.drive_decay,lane,drive.impulse_scale)
        lane_mask_set(&jb.limit,lane,.Limit in joint.flags)
        lane_mask_set(&jb.drive,lane,.Drive in joint.flags)
        lane_mask_set(&jb.coned,lane,.Cone in joint.flags)
        lane_set3(&jb.linear,lane,joint.linear_impulse)
        lane_set3(&jb.angular,lane,joint.angular_impulse)
        lane_set(&jb.lower_impulse,lane,joint.lower_impulse)
        lane_set(&jb.upper_impulse,lane,joint.upper_impulse)
        lane_set(&jb.drive_impulse,lane,joint.drive_impulse)
        lane_set(&jb.cone_impulse,lane,joint.cone_impulse)
    }
}

@(private)
joint_block_store :: proc(w:^World,jb:^Joint_Block($N)) #no_bounds_check {
    for lane in 0..<N {
        index:=jb.joint[lane]
        if index<0 {continue}
        joint:=&w.joints[index]
        joint.linear_impulse,joint.angular_impulse=lane_get3(&jb.linear,lane),lane_get3(&jb.angular,lane)
        joint.lower_impulse,joint.upper_impulse=lane_get(&jb.lower_impulse,lane),lane_get(&jb.upper_impulse,lane)
        joint.drive_impulse,joint.cone_impulse=lane_get(&jb.drive_impulse,lane),lane_get(&jb.cone_impulse,lane)
    }
}

@(private)
joint_blocks_prepare_task :: proc(data:rawptr,first,last,worker:int) #no_bounds_check {
    w:=(^World)(data)
    for index in first..<last {joint_block_prepare(w,&w.step.joint_blocks[index],w.step.joint_lanes[index*WIDE:][:WIDE])}
}

@(private)
joint_singles_prepare_task :: proc(data:rawptr,first,last,worker:int) #no_bounds_check {
    w:=(^World)(data)
    for index in first..<last {joint_block_prepare(w,&w.step.joint_singles[index],w.step.joint_single_slots[index:][:1])}
}

// One pass over the joint blocks of a color, from step.stage_offset.
@(private)
joint_blocks_task :: proc(data:rawptr,first,last,worker:int) #no_bounds_check {
    st:=&(^World)(data).step
    warm:=st.pass==.Warm_Start
    for &jb in st.joint_blocks[st.stage_offset+first:st.stage_offset+last] {joint_block_solve(st,&jb,warm)}
}

// The joints without color may share bodies: one pass over them in order, on this thread.
@(private)
joint_singles :: proc(w:^World) #no_bounds_check {
    st:=&w.step
    warm:=st.pass==.Warm_Start
    for &jb in st.joint_singles[:st.joint_single_count] {joint_block_solve(st,&jb,warm)}
}

@(private)
joint_blocks_store_task :: proc(data:rawptr,first,last,worker:int) #no_bounds_check {
    w:=(^World)(data)
    for &jb in w.step.joint_blocks[first:last] {joint_block_store(w,&jb)}
}

@(private)
joint_singles_store_task :: proc(data:rawptr,first,last,worker:int) #no_bounds_check {
    w:=(^World)(data)
    for &jb in w.step.joint_singles[first:last] {joint_block_store(w,&jb)}
}

// A joint of the step and the bucket of its color and type.
@(private) Joint_Lane :: struct {joint,bucket:i32}
