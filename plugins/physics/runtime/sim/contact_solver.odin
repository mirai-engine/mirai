package mirai_physics

import "base:intrinsics"
import "core:simd"

// Contact constraints are solved four at a time: the manifolds of one graph color share no body they move,
// so each lane of a block holds one of them. The manifolds that found no color share bodies and run in order,
// one per block of a single lane, through the same code.
@(private) WIDE :: 4
@(private) F4 :: #simd[WIDE]f32
@(private) Sym3 :: struct($N:int) {xx,yy,zz,xy,xz,yz:#simd[N]f32}

@(private) dot4 :: #force_inline proc "contextless" (a,b:[3]#simd[$N]f32) -> #simd[N]f32 {return a.x*b.x+a.y*b.y+a.z*b.z}
@(private) cross4 :: #force_inline proc "contextless" (a,b:[3]#simd[$N]f32) -> [3]#simd[N]f32 {
    return {a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x}
}
@(private) sym_mul4 :: #force_inline proc "contextless" (m:Sym3($N),v:[3]#simd[N]f32) -> [3]#simd[N]f32 {
    return {m.xx*v.x+m.xy*v.y+m.xz*v.z,m.xy*v.x+m.yy*v.y+m.yz*v.z,m.xz*v.x+m.yz*v.y+m.zz*v.z}
}
// v turned by the inverse of the unit quaternion q, given as x, y, z, w.
@(private) rotate_inverse4 :: #force_inline proc "contextless" (q:[4]#simd[$N]f32,v:[3]#simd[N]f32) -> [3]#simd[N]f32 {
    u:=[3]#simd[N]f32{q[0],q[1],q[2]}
    t:=cross4(u,v)
    s:=cross4(u,t)-q[3]*t
    return v+s+s
}

@(private) lane_set :: #force_inline proc "contextless" (v:^#simd[$N]f32,lane:int,x:f32) {(^[N]f32)(v)[lane]=x}
@(private) lane_get :: #force_inline proc "contextless" (v:^#simd[$N]f32,lane:int) -> f32 {return (^[N]f32)(v)[lane]}
@(private) lane_set3 :: #force_inline proc "contextless" (v:^[3]#simd[$N]f32,lane:int,x:Vec3) {
    lane_set(&v[0],lane,x.x);lane_set(&v[1],lane,x.y);lane_set(&v[2],lane,x.z)
}
@(private) lane_get3 :: #force_inline proc "contextless" (v:^[3]#simd[$N]f32,lane:int) -> Vec3 {
    return {lane_get(&v[0],lane),lane_get(&v[1],lane),lane_get(&v[2],lane)}
}
@(private) lane_set_sym :: #force_inline proc "contextless" (m:^Sym3($N),lane:int,x:Mat3) {
    lane_set(&m.xx,lane,x[0,0]);lane_set(&m.yy,lane,x[1,1]);lane_set(&m.zz,lane,x[2,2])
    lane_set(&m.xy,lane,x[0,1]);lane_set(&m.xz,lane,x[0,2]);lane_set(&m.yz,lane,x[1,2])
}

@(private) Point_Wide :: struct($N:int) {
    ra,rb:[3]#simd[N]f32,
    base_separation,relative_velocity,normal_impulse,total_impulse,normal_mass,lever_arm:#simd[N]f32,
}

// A lane without a manifold has no bodies and zero data, which solves to zero impulses.
@(private) Contact_Block :: struct($N:int) {
    a,b:[N]i32,             // solver bodies, -1 when static or asleep
    write_a,write_b:[N]i32, // the same for the bodies the constraint moves, else -1
    count:i32,              // points of the lane that has the most
    bounce:b32,             // some lane has restitution
    rolls:b32,              // some lane has rolling resistance
    _:i32,
    inv_mass_a,inv_mass_b:#simd[N]f32,
    inv_inertia_a,inv_inertia_b:Sym3(N),
    normal:[3]#simd[N]f32,
    bias_rate,mass_scale,impulse_scale:#simd[N]f32, // bias_rate already times mass_scale
    tangent1,tangent2:[3]#simd[N]f32,
    center_a,center_b:[3]#simd[N]f32, // where friction acts
    tangent_mass:[3]#simd[N]f32,      // inverse of the symmetric 2x2: xx, xy, yy
    friction_impulse:[2]#simd[N]f32,
    twist_mass,twist_impulse,friction,restitution:#simd[N]f32,
    push_cap:#simd[N]f32,             // N s of each point: a push rule over the substep, else max(f32)
    rolling_mass:Sym3(N),             // inverse of the sum of the inverse inertias
    rolling_impulse:[3]#simd[N]f32,
    rolling_resistance:#simd[N]f32,
    surface:[3]#simd[N]f32,           // velocity of the surface of B less that of A, along the contact plane
    points:[MANIFOLD_MAX_POINTS]Point_Wide(N),
    // A single whose side `turn_side` (1: A, 2: B) is a body seen through a twin: its motion turns by `turn`
    // into the frame of the contact (twin.odin).
    turn:Quat,
    turn_side:i32,
}
#assert(offset_of(Contact_Block(WIDE),inv_mass_a)==80)

// Velocities and motion of the bodies of the lanes. The tails carry what shares a row with a vector.
@(private) Body_Wide :: struct($N:int) {v:[3]#simd[N]f32,v_tail:#simd[N]f32,w:[3]#simd[N]f32,w_tail:#simd[N]f32,dp:[3]#simd[N]f32,dq:[4]#simd[N]f32}

@(private)
rows_transpose :: #force_inline proc "contextless" (r0,r1,r2,r3:F4) -> (x,y,z,t:F4) {
    t0:=simd.shuffle(r0,r1,0,4,1,5)
    t1:=simd.shuffle(r0,r1,2,6,3,7)
    t2:=simd.shuffle(r2,r3,0,4,1,5)
    t3:=simd.shuffle(r2,r3,2,6,3,7)
    return simd.shuffle(t0,t2,0,1,4,5),simd.shuffle(t0,t2,2,3,6,7),simd.shuffle(t1,t3,0,1,4,5),simd.shuffle(t1,t3,2,3,6,7)
}

@(private)
bodies_gather :: #force_inline proc "contextless" (bodies:[]Solver_Body,indices:[$N]i32,rest:^Solver_Body,$MOTION:bool) -> (out:Body_Wide(N)) #no_bounds_check {
    when N==WIDE {
        load :: #force_inline proc "contextless" (p:rawptr) -> F4 {return intrinsics.unaligned_load((^F4)(p))}
        p:[WIDE]^Solver_Body=---
        for i in 0..<WIDE {p[i]=indices[i]>=0?&bodies[indices[i]]:rest}
        out.v.x,out.v.y,out.v.z,out.v_tail=rows_transpose(load(&p[0].v),load(&p[1].v),load(&p[2].v),load(&p[3].v))
        out.w.x,out.w.y,out.w.z,out.w_tail=rows_transpose(load(&p[0].w),load(&p[1].w),load(&p[2].w),load(&p[3].w))
        when MOTION {
            out.dp.x,out.dp.y,out.dp.z,_=rows_transpose(load(&p[0].dp),load(&p[1].dp),load(&p[2].dp),load(&p[3].dp))
            out.dq[0],out.dq[1],out.dq[2],out.dq[3]=rows_transpose(load(&p[0].dq),load(&p[1].dq),load(&p[2].dq),load(&p[3].dq))
        }
    } else {
        for i in 0..<N {
            p:=indices[i]>=0?&bodies[indices[i]]:rest
            lane_set3(&out.v,i,p.v)
            lane_set3(&out.w,i,p.w)
            when MOTION {
                lane_set3(&out.dp,i,p.dp)
                lane_set(&out.dq[0],i,p.dq.x);lane_set(&out.dq[1],i,p.dq.y);lane_set(&out.dq[2],i,p.dq.z);lane_set(&out.dq[3],i,p.dq.w)
            }
        }
    }
    return
}

// The motion of a body as the frame of a contact sees it, and back.
@(private)
body_turn :: #force_inline proc "contextless" (body:^Body_Wide($N),q:Quat,$MOTION:bool) #no_bounds_check {
    for i in 0..<N {
        lane_set3(&body.v,i,q_rotate(q,lane_get3(&body.v,i)))
        lane_set3(&body.w,i,q_rotate(q,lane_get3(&body.w,i)))
        when MOTION {
            lane_set3(&body.dp,i,q_rotate(q,lane_get3(&body.dp,i)))
            dq:Quat=quaternion(w=lane_get(&body.dq[3],i),x=lane_get(&body.dq[0],i),y=lane_get(&body.dq[1],i),z=lane_get(&body.dq[2],i))
            dq=q*dq*conj(q)
            lane_set(&body.dq[0],i,dq.x);lane_set(&body.dq[1],i,dq.y);lane_set(&body.dq[2],i,dq.z);lane_set(&body.dq[3],i,dq.w)
        }
    }
}
@(private)
body_unturn :: #force_inline proc "contextless" (body:^Body_Wide($N),q:Quat) #no_bounds_check {
    for i in 0..<N {
        lane_set3(&body.v,i,q_inv_rotate(q,lane_get3(&body.v,i)))
        lane_set3(&body.w,i,q_inv_rotate(q,lane_get3(&body.w,i)))
    }
}

@(private)
bodies_scatter :: #force_inline proc "contextless" (bodies:[]Solver_Body,indices:[$N]i32,body:^Body_Wide(N)) #no_bounds_check {
    when N==WIDE {
        v,w:[WIDE]F4=---,---
        v[0],v[1],v[2],v[3]=rows_transpose(body.v.x,body.v.y,body.v.z,body.v_tail)
        w[0],w[1],w[2],w[3]=rows_transpose(body.w.x,body.w.y,body.w.z,body.w_tail)
        for i in 0..<WIDE {
            if indices[i]<0 {continue}
            target:=&bodies[indices[i]]
            intrinsics.unaligned_store((^F4)(&target.v),v[i])
            intrinsics.unaligned_store((^F4)(&target.w),w[i])
        }
    } else {
        for i in 0..<N {
            if indices[i]<0 {continue}
            target:=&bodies[indices[i]]
            target.v=lane_get3(&body.v,i)
            target.w=lane_get3(&body.w,i)
        }
    }
}

// Fills the lanes of a block from the manifolds that `refs` names; a lane whose contact is -1 stays empty.
@(private)
contact_block_prepare :: proc(w:^World,c:^Contact_Block($N),refs:[]Constraint_Ref) #no_bounds_check {
    st:=&w.step
    c^={}
    for lane in 0..<N {c.a[lane],c.b[lane],c.write_a[lane],c.write_b[lane]=-1,-1,-1,-1}
    for lane in 0..<N {
        ref:=refs[lane]
        if ref.contact<0 {continue}
        contact:=&w.contacts[ref.contact]
        manifold:=ref.manifold==0?&w.manifolds[ref.contact]:&w.extra_manifolds[contact.extra][ref.manifold-1]
        state:=ref.manifold==0?&contact.manifold:&w.blocks[contact.extra].manifolds[ref.manifold-1]
        a,b:=w.bodies[contact.body_a].solver_index,w.bodies[contact.body_b].solver_index
        body_a:=a>=0?st.bodies[a]:SOLVER_BODY_REST
        body_b:=b>=0?st.bodies[b]:SOLVER_BODY_REST
        ma,mb:f32
        ia,ib:Mat3
        if a>=0 {ma,ia=st.params[a].inv_mass,st.params[a].inv_inertia}
        if b>=0 {mb,ib=st.params[b].inv_mass,st.params[b].inv_inertia}
        shape_a,shape_b:=&w.shapes[contact.shape_a],&w.shapes[contact.shape_b]
        rotation_a:=w.bodies[contact.body_a].rotation*shape_a.local.q
        rotation_b:=w.bodies[contact.body_b].rotation*shape_b.local.q
        // Only singles have bodies that turn: the others turn a static or sleeping side, which does not move.
        if .Twin in (shape_a.flags+shape_b.flags) {
            turn,side:=contact_turn(w,contact)
            if side==1 {
                body_a.v,body_a.w=q_rotate(turn,body_a.v),q_rotate(turn,body_a.w)
                ia=mat3_rotate(turn,ia)
                rotation_a=turn*rotation_a
            } else if side==2 {
                body_b.v,body_b.w=q_rotate(turn,body_b.v),q_rotate(turn,body_b.w)
                ib=mat3_rotate(turn,ib)
                rotation_b=turn*rotation_b
            }
            when N==1 {c.turn,c.turn_side=turn,side}
        }
        push:f32
        if ma>0 && mb>0 && w.push_rule_count>0 {push=push_force_of(w,shape_a.filter.layers,shape_b.filter.layers)}
        // Between two dynamic bodies the shape of more dominance is not moved by the contact.
        if ma>0 && mb>0 && shape_a.dominance!=shape_b.dominance {
            if shape_a.dominance>shape_b.dominance {ma,ia=0,{}} else {mb,ib=0,{}}
        }
        normal:=manifold.normal
        tangent1:=perp(normal)
        tangent2:=cross(tangent1,normal)
        if shape_a.surface_speed!={} || shape_b.surface_speed!={} {
            surface:=q_rotate(rotation_b,shape_b.surface_speed)-q_rotate(rotation_a,shape_a.surface_speed)
            lane_set3(&c.surface,lane,surface-normal*dot(surface,normal))
        }
        c.a[lane],c.b[lane]=a,b
        c.write_a[lane],c.write_b[lane]=ma>0?a:-1,mb>0?b:-1
        c.count=max(c.count,manifold.count)
        if contact.restitution!=0 {c.bounce=true}
        if contact.rolling_resistance>0 {
            c.rolls=true
            lane_set(&c.rolling_resistance,lane,contact.rolling_resistance)
            lane_set_sym(&c.rolling_mass,lane,mat3_inverse(ia+ib))
            lane_set3(&c.rolling_impulse,lane,state.rolling_impulse)
        }
        lane_set3(&c.normal,lane,normal)
        lane_set3(&c.tangent1,lane,tangent1)
        lane_set3(&c.tangent2,lane,tangent2)
        lane_set(&c.inv_mass_a,lane,ma)
        lane_set(&c.inv_mass_b,lane,mb)
        lane_set_sym(&c.inv_inertia_a,lane,ia)
        lane_set_sym(&c.inv_inertia_b,lane,ib)
        lane_set(&c.friction,lane,contact.friction)
        lane_set(&c.restitution,lane,contact.restitution)
        lane_set(&c.push_cap,lane,push>0?push*st.h/f32(max(manifold.count,1)):max(f32))
        softness:=ma==0 || mb==0?st.static_softness:st.contact_softness
        lane_set(&c.bias_rate,lane,softness.mass_scale*softness.bias_rate)
        lane_set(&c.mass_scale,lane,softness.mass_scale)
        lane_set(&c.impulse_scale,lane,softness.impulse_scale)
        center_a,center_b:Vec3
        total_weight:f32
        for i in 0..<int(manifold.count) {
            point:=manifold.points[i]
            ra,rb:=point.anchor_a,point.anchor_b
            rna,rnb:=cross(ra,normal),cross(rb,normal)
            k:=ma+mb+dot(rna,ia*rna)+dot(rnb,ib*rnb)
            // Points that only speculate weigh little in the place where friction acts.
            weight:=clamp(2-point.separation/SPECULATIVE_DISTANCE,1e-10,1)
            center_a+=weight*ra
            center_b+=weight*rb
            total_weight+=weight
            wide:=&c.points[i]
            lane_set3(&wide.ra,lane,ra)
            lane_set3(&wide.rb,lane,rb)
            lane_set(&wide.base_separation,lane,point.separation-dot(rb-ra,normal))
            lane_set(&wide.relative_velocity,lane,dot(normal,body_b.v+cross(body_b.w,rb)-body_a.v-cross(body_a.w,ra)))
            lane_set(&wide.normal_impulse,lane,state.normal_impulses[i])
            lane_set(&wide.normal_mass,lane,k>0?1/k:0)
        }
        center_a/=total_weight
        center_b/=total_weight
        lane_set3(&c.center_a,lane,center_a)
        lane_set3(&c.center_b,lane,center_b)
        for i in 0..<int(manifold.count) {lane_set(&c.points[i].lever_arm,lane,length(manifold.points[i].anchor_a-center_a))}
        rta1,rta2:=cross(center_a,tangent1),cross(center_a,tangent2)
        rtb1,rtb2:=cross(center_b,tangent1),cross(center_b,tangent2)
        kxx:=ma+mb+dot(rta1,ia*rta1)+dot(rtb1,ib*rtb1)
        kyy:=ma+mb+dot(rta2,ia*rta2)+dot(rtb2,ib*rtb2)
        kxy:=dot(rta1,ia*rta2)+dot(rtb1,ib*rtb2)
        det:=kxx*kyy-kxy*kxy
        if det!=0 {
            lane_set(&c.tangent_mass[0],lane,kyy/det)
            lane_set(&c.tangent_mass[1],lane,-kxy/det)
            lane_set(&c.tangent_mass[2],lane,kxx/det)
        }
        lane_set(&c.friction_impulse[0],lane,dot(state.friction_impulse,tangent1))
        lane_set(&c.friction_impulse[1],lane,dot(state.friction_impulse,tangent2))
        kt:=dot(normal,(ia+ib)*normal)
        lane_set(&c.twist_mass,lane,kt>0?1/kt:0)
        lane_set(&c.twist_impulse,lane,state.twist_impulse)
    }
}

@(private)
contact_block_warm_start :: #force_inline proc "contextless" (st:^Step,c:^Contact_Block($N)) #no_bounds_check {
    rest:=SOLVER_BODY_REST
    a:=bodies_gather(st.bodies,c.a,&rest,false)
    b:=bodies_gather(st.bodies,c.b,&rest,false)
    when N==1 {contact_turn_in(c,&a,&b,false)}
    n:=c.normal
    linear:=c.friction_impulse[0]*c.tangent1+c.friction_impulse[1]*c.tangent2
    twist:=c.twist_impulse*n+c.rolling_impulse
    angular_a:=cross4(c.center_a,linear)+twist
    angular_b:=cross4(c.center_b,linear)+twist
    for &point in c.points[:c.count] {
        p:=point.normal_impulse*n
        linear+=p
        angular_a+=cross4(point.ra,p)
        angular_b+=cross4(point.rb,p)
    }
    a.v-=c.inv_mass_a*linear
    a.w-=sym_mul4(c.inv_inertia_a,angular_a)
    b.v+=c.inv_mass_b*linear
    b.w+=sym_mul4(c.inv_inertia_b,angular_b)
    when N==1 {contact_turn_out(c,&a,&b)}
    bodies_scatter(st.bodies,c.write_a,&a)
    bodies_scatter(st.bodies,c.write_b,&b)
}

// One Gauss-Seidel pass. With the bias it pushes penetration out softly; without it (relax) it removes
// the velocity the push added and applies friction.
@(private)
contact_block_solve :: #force_inline proc "contextless" (st:^Step,c:^Contact_Block($N),contact_speed:f32) #no_bounds_check {
    use_bias:=st.use_bias
    rest:=SOLVER_BODY_REST
    inv_h:#simd[N]f32=st.inv_h
    push:#simd[N]f32=-contact_speed
    zero:#simd[N]f32=0
    one:#simd[N]f32=1
    a:=bodies_gather(st.bodies,c.a,&rest,true)
    b:=bodies_gather(st.bodies,c.b,&rest,true)
    when N==1 {contact_turn_in(c,&a,&b,true)}
    bias_rate,mass_scale,impulse_scale:=zero,one,zero
    if use_bias {bias_rate,mass_scale,impulse_scale=c.bias_rate,c.mass_scale,c.impulse_scale}
    n:=c.normal
    ma,mb:=c.inv_mass_a,c.inv_mass_b
    // The anchors turned with their bodies: measured against the normal turned the other way.
    na:=rotate_inverse4(a.dq,n)
    nb:=rotate_inverse4(b.dq,n)
    travel:=dot4(b.dp-a.dp,n)
    approach:=dot4(b.v-a.v,n)
    total_normal,twist_limit:=zero,zero
    for &point in c.points[:c.count] {
        ra,rb:=point.ra,point.rb
        s:=travel+dot4(rb,nb)-dot4(ra,na)+point.base_separation
        // Speculative: allow exactly the approach that closes the gap in this substep.
        speculative:=simd.lanes_gt(s,zero)
        bias:=simd.select(speculative,s*inv_h,simd.max(bias_rate*s,push))
        point_mass_scale:=simd.select(speculative,one,mass_scale)
        point_impulse_scale:=simd.select(speculative,zero,impulse_scale)
        rna,rnb:=cross4(ra,n),cross4(rb,n)
        vn:=approach+dot4(b.w,rnb)-dot4(a.w,rna)
        old:=point.normal_impulse
        new:=simd.min(simd.max(old-point.normal_mass*(point_mass_scale*vn+bias)-point_impulse_scale*old,zero),c.push_cap)
        impulse:=new-old
        point.normal_impulse=new
        total_normal+=new
        twist_limit+=point.lever_arm*new
        if !use_bias {point.total_impulse+=new}
        da:=ma*impulse
        db:=mb*impulse
        a.v-=da*n
        a.w-=sym_mul4(c.inv_inertia_a,impulse*rna)
        b.v+=db*n
        b.w+=sym_mul4(c.inv_inertia_b,impulse*rnb)
        approach+=da+db
    }
    if !use_bias && c.rolls {
        // Rolling resistance: an angular impulse against the relative spin, bounded by the pressure.
        old:=c.rolling_impulse
        spin:=b.w-a.w
        impulse:=old-sym_mul4(c.rolling_mass,spin)
        limit:=c.rolling_resistance*total_normal
        l2:=dot4(impulse,impulse)
        impulse*=simd.select(simd.lanes_gt(l2,limit*limit),limit/simd.sqrt(simd.max(l2,1e-30)),one)
        c.rolling_impulse=impulse
        delta:=impulse-old
        a.w-=sym_mul4(c.inv_inertia_a,delta)
        b.w+=sym_mul4(c.inv_inertia_b,delta)
    }
    if !use_bias {
        // Friction against spinning about the normal, bounded by the pressure and its lever arm.
        {
            limit:=c.friction*twist_limit
            impulse:=simd.clamp(c.twist_impulse-c.twist_mass*dot4(n,b.w-a.w),-limit,limit)
            delta:=(impulse-c.twist_impulse)*n
            c.twist_impulse=impulse
            a.w-=sym_mul4(c.inv_inertia_a,delta)
            b.w+=sym_mul4(c.inv_inertia_b,delta)
        }
        // Friction against sliding, as one 2D impulse at the center of pressure.
        {
            ra,rb:=c.center_a,c.center_b
            vr:=b.v+cross4(b.w,rb)-a.v-cross4(a.w,ra)+c.surface
            vt0,vt1:=dot4(vr,c.tangent1),dot4(vr,c.tangent2)
            f0:=c.friction_impulse[0]-(c.tangent_mass[0]*vt0+c.tangent_mass[1]*vt1)
            f1:=c.friction_impulse[1]-(c.tangent_mass[1]*vt0+c.tangent_mass[2]*vt1)
            limit:=c.friction*total_normal
            l2:=f0*f0+f1*f1
            scale:=simd.select(simd.lanes_gt(l2,limit*limit),limit/simd.sqrt(l2),one)
            f0*=scale
            f1*=scale
            p:=(f0-c.friction_impulse[0])*c.tangent1+(f1-c.friction_impulse[1])*c.tangent2
            c.friction_impulse={f0,f1}
            a.v-=ma*p
            a.w-=sym_mul4(c.inv_inertia_a,cross4(ra,p))
            b.v+=mb*p
            b.w+=sym_mul4(c.inv_inertia_b,cross4(rb,p))
        }
    }
    when N==1 {contact_turn_out(c,&a,&b)}
    bodies_scatter(st.bodies,c.write_a,&a)
    bodies_scatter(st.bodies,c.write_b,&b)
}

// Bounce: points that approached faster than the threshold and carried load leave with the restitution speed.
@(private)
contact_block_restitution :: #force_inline proc "contextless" (st:^Step,c:^Contact_Block($N),restitution_threshold:f32) #no_bounds_check {
    if !c.bounce {return}
    rest:=SOLVER_BODY_REST
    threshold:#simd[N]f32=-restitution_threshold
    zero:#simd[N]f32=0
    a:=bodies_gather(st.bodies,c.a,&rest,false)
    b:=bodies_gather(st.bodies,c.b,&rest,false)
    when N==1 {contact_turn_in(c,&a,&b,false)}
    n:=c.normal
    bouncy:=simd.lanes_ne(c.restitution,zero)
    for &point in c.points[:c.count] {
        rna,rnb:=cross4(point.ra,n),cross4(point.rb,n)
        vn:=dot4(b.v-a.v,n)+dot4(b.w,rnb)-dot4(a.w,rna)
        applies:=simd.bit_and(bouncy,simd.bit_and(simd.lanes_le(point.relative_velocity,threshold),simd.lanes_ne(point.total_impulse,zero)))
        old:=point.normal_impulse
        new:=simd.min(simd.max(old-point.normal_mass*(vn+c.restitution*point.relative_velocity),zero),c.push_cap)
        impulse:=simd.select(applies,new-old,zero)
        point.normal_impulse=simd.select(applies,new,old)
        point.total_impulse+=impulse
        a.v-=(c.inv_mass_a*impulse)*n
        a.w-=sym_mul4(c.inv_inertia_a,impulse*rna)
        b.v+=(c.inv_mass_b*impulse)*n
        b.w+=sym_mul4(c.inv_inertia_b,impulse*rnb)
    }
    when N==1 {contact_turn_out(c,&a,&b)}
    bodies_scatter(st.bodies,c.write_a,&a)
    bodies_scatter(st.bodies,c.write_b,&b)
}

@(private)
contact_turn_in :: #force_inline proc "contextless" (c:^Contact_Block($N),a,b:^Body_Wide(N),$MOTION:bool) {
    if c.turn_side==1 {body_turn(a,c.turn,MOTION)} else if c.turn_side==2 {body_turn(b,c.turn,MOTION)}
}
@(private)
contact_turn_out :: #force_inline proc "contextless" (c:^Contact_Block($N),a,b:^Body_Wide(N)) {
    if c.turn_side==1 {body_unturn(a,c.turn)} else if c.turn_side==2 {body_unturn(b,c.turn)}
}

@(private)
contact_block_store :: proc(w:^World,c:^Contact_Block($N),refs:[]Constraint_Ref) #no_bounds_check {
    for lane in 0..<N {
        ref:=refs[lane]
        if ref.contact<0 {continue}
        contact:=&w.contacts[ref.contact]
        manifold:=ref.manifold==0?&w.manifolds[ref.contact]:&w.extra_manifolds[contact.extra][ref.manifold-1]
        state:=ref.manifold==0?&contact.manifold:&w.blocks[contact.extra].manifolds[ref.manifold-1]
        for i in 0..<int(manifold.count) {
            state.normal_impulses[i]=lane_get(&c.points[i].normal_impulse,lane)
            manifold.points[i].impulse=lane_get(&c.points[i].total_impulse,lane)
            manifold.points[i].approach=-lane_get(&c.points[i].relative_velocity,lane)
        }
        state.friction_impulse=lane_get(&c.friction_impulse[0],lane)*lane_get3(&c.tangent1,lane)+lane_get(&c.friction_impulse[1],lane)*lane_get3(&c.tangent2,lane)
        state.twist_impulse=lane_get(&c.twist_impulse,lane)
        state.rolling_impulse=lane_get3(&c.rolling_impulse,lane)
    }
}

@(private)
contacts_prepare_task :: proc(data:rawptr,first,last,worker:int) #no_bounds_check {
    w:=(^World)(data)
    for index in first..<last {contact_block_prepare(w,&w.step.wide[index],w.step.refs[index*WIDE:][:WIDE])}
}

@(private)
contacts_singles_prepare_task :: proc(data:rawptr,first,last,worker:int) #no_bounds_check {
    w:=(^World)(data)
    for index in first..<last {contact_block_prepare(w,&w.step.singles[index],w.step.ref_scratch[index:][:1])}
}

// One pass over the blocks of a color, from step.stage_offset.
@(private)
contacts_pass_task :: proc(data:rawptr,first,last,worker:int) #no_bounds_check {
    w:=(^World)(data)
    st:=&w.step
    blocks:=st.wide[st.stage_offset+first:st.stage_offset+last]
    switch st.pass {
    case .Warm_Start: for &c in blocks {contact_block_warm_start(st,&c)}
    case .Solve: for &c in blocks {contact_block_solve(st,&c,w.desc.contact_speed)}
    case .Restitution: for &c in blocks {contact_block_restitution(st,&c,w.desc.restitution_threshold)}
    }
}

@(private)
contacts_solve_task :: proc(data:rawptr,first,last,worker:int) {
    w:=(^World)(data)
    w.step.pass=.Solve
    contacts_pass_task(data,first,last,worker)
}

@(private)
contacts_restitution_task :: proc(data:rawptr,first,last,worker:int) {
    w:=(^World)(data)
    w.step.pass=.Restitution
    contacts_pass_task(data,first,last,worker)
}

@(private)
contacts_store_task :: proc(data:rawptr,first,last,worker:int) #no_bounds_check {
    w:=(^World)(data)
    for index in first..<last {contact_block_store(w,&w.step.wide[index],w.step.refs[index*WIDE:][:WIDE])}
}

@(private)
contacts_singles_store_task :: proc(data:rawptr,first,last,worker:int) #no_bounds_check {
    w:=(^World)(data)
    for index in first..<last {contact_block_store(w,&w.step.singles[index],w.step.ref_scratch[index:][:1])}
}

// The manifolds that found no color may share bodies: one pass over them in order, on this thread.
@(private)
contacts_singles :: proc(w:^World) #no_bounds_check {
    st:=&w.step
    singles:=st.singles[:st.single_count]
    switch st.pass {
    case .Warm_Start: for &c in singles {contact_block_warm_start(st,&c)}
    case .Solve: for &c in singles {contact_block_solve(st,&c,w.desc.contact_speed)}
    case .Restitution: for &c in singles {contact_block_restitution(st,&c,w.desc.restitution_threshold)}
    }
}
