package mirai_physics

import "core:mem"
import cmath "core:math"
import "core:time"
import "mirai:std/spatial"
import math "mirai:std/math"

// Response of a soft constraint over a substep: how much of the error it removes and how the accumulated
// impulse decays, from a frequency and a damping ratio.
@(private) Softness :: struct {bias_rate,mass_scale,impulse_scale:f32}

@(private)
soft_make :: proc "contextless" (hertz,zeta,h:f32) -> Softness {
    if hertz==0 {return {}}
    omega:=2*PI*hertz
    a1:=2*zeta+h*omega
    a2:=h*omega*a1
    a3:=1/(1+a2)
    return {omega/a1,a2*a3,a3}
}

// Velocity of an awake body and its motion since the start of the step.
// Four rows of four floats, which the contact solver loads as lanes.
@(private) Solver_Body :: struct {v:Vec3,flags:Body_Flags,w:Vec3,_:u32,dp:Vec3,_:u32,dq:Quat}
#assert(size_of(Solver_Body)==64 && offset_of(Solver_Body,dq)==48)
@(private) Solver_Params :: struct {
    inv_inertia:Mat3, // world
    inertia:Mat3,     // local
    q0:Quat,
    linear_acceleration,angular_acceleration:Vec3,
    inv_mass,linear_damping,angular_damping:f32,
}
@(private) SOLVER_BODY_REST :: Solver_Body{dq=QUAT_IDENTITY}

// `bucket` orders the manifolds of a step: by color, then by number of points.
@(private) Constraint_Ref :: struct {contact,manifold,bucket:i32}

@(private) OVERFLOW_COLOR :: GRAPH_COLORS
@(private) DYNAMIC_COLORS :: GRAPH_COLORS-4

@(private)
Step :: struct {
    dt,inv_dt,h,inv_h:f32,
    contact_softness,static_softness,joint_softness:Softness,
    use_bias:bool,
    stage_offset:int,
    awake:[]i32,
    awake_count:int,
    bodies:[]Solver_Body,
    params:[]Solver_Params,
    island_time:[]f32,   // per island: the least time its bodies have been still
    island_bodies:[]i32, // bodies of the island being split
    island_stack:[]i32,
    island_group:[]i32,
    island_local:[]i32,  // per body: its place in the island being split, else -1
    island_edges:[][2]i32, // bodies of the touching contacts of the step, when bodies may sleep
    island_edge_count:int,
    island_head:[]i32,
    groups:[]i32,        // per body: a body of its group in bodies_group, where grouped is grouping
    grouped:[]u32,
    grouping:u32,        // a new number for each bodies_group
    moved:[]i32,
    woken:[]i32,
    woken_count:int,
    pairs:[]u64,
    pair_count:int, // taken by the workers with atomics; past len(pairs) when they did not fit
    active:[]i32,
    active_count:int,
    refs:[]Constraint_Ref,        // manifold of each lane of each block; contact -1 in an empty lane
    ref_scratch:[]Constraint_Ref, // manifolds of the step; once gathered, the first single_count found no color
    ref_count:int,
    pass:Solve_Pass,
    block_memory:[]Contact_Block(WIDE), // holds the blocks of the step, then the singles
    wide:[]Contact_Block(WIDE),         // by color, then a spare that continuous collision uses
    wide_start:[GRAPH_COLORS+1]int,
    singles:[]Contact_Block(1),
    single_count:int,
    joint_order:[]i32,      // joints solved one at a time, by color
    joint_slots:[]i32,
    joint_count:int,
    joint_color_start:[GRAPH_COLORS+2]int,
    joint_data:[]Joint_Solver,
    joint_blocks:[]Joint_Block(WIDE),
    joint_lanes:[]i32,      // joint of each lane of each block, -1 in an empty lane
    joint_block_start:[GRAPH_COLORS+1]int,
    joint_scratch:[]Joint_Lane,
    joint_singles:[]Joint_Block(1),
    joint_single_slots:[]i32,
    joint_single_count:int,
    joint_solved:[]i32,     // every joint of the step, for the ones that break
    joint_solved_count:int,
    color_bits:[]u64,
    color_words:int,
    characters:[]Character_Solver,
    character_count:int,
    wet:[]Wet,                // per awake body, while fluid_active; made with the first fluid
    clips:[]Clip_Scratch,     // per worker, made with the first fluid
    fluid_active:bool,        // the world has fluids in this step
    ccd:Continuous,
}

@(private)
step_init :: proc(st:^Step,d:World_Desc,a:mem.Allocator) -> bool {
    ok:=true
    alloc :: proc($T:typeid,count:int,a:mem.Allocator,ok:^bool) -> []T {
        if count<=0 {return nil}
        slice,error:=make([]T,count,a)
        if error!=nil {ok^=false}
        return slice
    }
    manifolds:=d.contact_capacity+EXTRA_MANIFOLDS*(d.contact_capacity/4)
    st.awake=alloc(i32,d.body_capacity,a,&ok)
    st.bodies=alloc(Solver_Body,d.body_capacity,a,&ok)
    st.params=alloc(Solver_Params,d.body_capacity,a,&ok)
    st.island_bodies=alloc(i32,d.body_capacity,a,&ok)
    st.island_stack=alloc(i32,d.body_capacity,a,&ok)
    st.island_group=alloc(i32,d.body_capacity,a,&ok)
    st.island_local=alloc(i32,d.body_capacity,a,&ok)
    for &slot in st.island_local {slot=-1}
    st.island_edges=alloc([2]i32,d.contact_capacity,a,&ok)
    st.island_time=alloc(f32,d.body_capacity,a,&ok)
    st.island_head=alloc(i32,d.body_capacity,a,&ok)
    st.groups=alloc(i32,d.body_capacity,a,&ok)
    st.grouped=alloc(u32,d.body_capacity,a,&ok)
    st.moved=alloc(i32,d.shape_capacity,a,&ok)
    st.woken=alloc(i32,d.body_capacity,a,&ok)
    st.pairs=alloc(u64,d.contact_capacity,a,&ok)
    st.active=alloc(i32,d.contact_capacity,a,&ok)
    blocks:=(manifolds+WIDE-1)/WIDE+GRAPH_COLORS+2
    st.refs=alloc(Constraint_Ref,blocks*WIDE,a,&ok)
    st.ref_scratch=alloc(Constraint_Ref,manifolds,a,&ok)
    // Blocks of four take a quarter of the bytes of a single per manifold, and the singles share the room.
    st.block_memory=alloc(Contact_Block(WIDE),(manifolds*size_of(Contact_Block(1))+(GRAPH_COLORS+2)*size_of(Contact_Block(WIDE)))/size_of(Contact_Block(WIDE))+1,a,&ok)
    st.joint_order=alloc(i32,d.joint_capacity,a,&ok)
    st.joint_slots=alloc(i32,d.joint_capacity,a,&ok)
    st.joint_data=alloc(Joint_Solver,d.joint_capacity,a,&ok)
    joint_blocks:=d.joint_capacity>0?d.joint_capacity/WIDE+GRAPH_COLORS*LANE_JOINT_TYPES:0
    st.joint_blocks=alloc(Joint_Block(WIDE),joint_blocks,a,&ok)
    st.joint_lanes=alloc(i32,joint_blocks*WIDE,a,&ok)
    st.joint_scratch=alloc(Joint_Lane,d.joint_capacity,a,&ok)
    st.joint_singles=alloc(Joint_Block(1),d.joint_capacity,a,&ok)
    st.joint_single_slots=alloc(i32,d.joint_capacity,a,&ok)
    st.joint_solved=alloc(i32,d.joint_capacity,a,&ok)
    st.color_words=(d.body_capacity+63)/64
    st.color_bits=alloc(u64,st.color_words*GRAPH_COLORS,a,&ok)
    st.characters=alloc(Character_Solver,d.character_capacity,a,&ok)
    if !continuous_init(&st.ccd,d,a) {ok=false}
    return ok
}

@(private)
step_destroy :: proc(st:^Step,a:mem.Allocator) {
    delete(st.awake,a);delete(st.bodies,a);delete(st.params,a);delete(st.island_bodies,a);delete(st.island_stack,a);delete(st.island_group,a);delete(st.island_local,a);delete(st.island_edges,a)
    delete(st.island_time,a);delete(st.island_head,a);delete(st.groups,a);delete(st.grouped,a);delete(st.moved,a);delete(st.woken,a)
    delete(st.pairs,a);delete(st.active,a);delete(st.refs,a);delete(st.ref_scratch,a);delete(st.block_memory,a)
    delete(st.joint_order,a);delete(st.joint_slots,a);delete(st.joint_data,a);delete(st.color_bits,a)
    delete(st.joint_blocks,a);delete(st.joint_lanes,a);delete(st.joint_scratch,a);delete(st.joint_singles,a)
    delete(st.joint_single_slots,a);delete(st.joint_solved,a)
    delete(st.characters,a);delete(st.wet,a);delete(st.clips,a)
    continuous_destroy(&st.ccd,a)
    st^={}
}

// Advances the world by dt seconds. Equal state and equal calls give equal results on the same binary,
// whatever the number of workers.
world_step :: proc(w:^World,dt:f32) {
    w.events.counts={}
    if !(dt>0) || w.kept {return}
    st:=&w.step
    st.dt,st.inv_dt=dt,1/dt
    st.h=dt/f32(w.desc.substeps)
    st.inv_h=1/st.h
    contact_hertz:=min(w.desc.contact_hertz,0.25*st.inv_h)
    st.contact_softness=soft_make(contact_hertz,w.desc.contact_damping_ratio,st.h)
    st.static_softness=soft_make(2*contact_hertz,w.desc.contact_damping_ratio,st.h)
    st.joint_softness=soft_make(min(w.desc.joint_hertz,0.25*st.inv_h),w.desc.joint_damping_ratio,st.h)

    mark:=time.tick_now()
    characters_update(w)
    twins_refresh(w)
    pairs_update(w)
    profile_lap(&w.profile.pairs,&mark)
    contacts_update(w)
    profile_lap(&w.profile.narrow_phase,&mark)
    solver_bodies_gather(w)
    characters_prepare(w)
    fluids_prepare(w)
    constraints_gather(w)
    world_parallel(w,st.joint_count,16,w,joints_prepare_task)
    world_parallel(w,st.joint_block_start[GRAPH_COLORS],8,w,joint_blocks_prepare_task)
    world_parallel(w,st.joint_single_count,16,w,joint_singles_prepare_task)
    world_parallel(w,st.wide_start[GRAPH_COLORS],8,w,contacts_prepare_task)
    world_parallel(w,st.single_count,32,w,contacts_singles_prepare_task)
    profile_lap(&w.profile.prepare,&mark)
    for _ in 0..<w.desc.substeps {
        world_parallel(w,st.awake_count,64,w,integrate_velocities_task)
        solve_stage(w,.Warm_Start)
        st.use_bias=true
        characters_solve(w)
        solve_stage(w,.Solve)
        world_parallel(w,st.awake_count,64,w,integrate_positions_task)
        st.use_bias=false
        characters_solve(w)
        solve_stage(w,.Solve)
    }
    solve_stage(w,.Restitution)
    world_parallel(w,st.wide_start[GRAPH_COLORS],16,w,contacts_store_task)
    world_parallel(w,st.single_count,64,w,contacts_singles_store_task)
    world_parallel(w,st.joint_block_start[GRAPH_COLORS],16,w,joint_blocks_store_task)
    world_parallel(w,st.joint_single_count,32,w,joint_singles_store_task)
    profile_lap(&w.profile.solve,&mark)
    world_parallel(w,st.awake_count,32,w,finalize_task)
    continuous_update(w)
    proxies_update(w)
    twins_refresh(w)
    characters_ground(w)
    profile_lap(&w.profile.finalize,&mark)
    step_events(w)
    joints_break(w)
    islands_sleep(w)
    step_hits(w)
    for i in st.active[:st.active_count] {w.contacts[i].flags-={.Visited}}
    w.stats.awake_bodies=st.awake_count
    w.stats.active_contacts=st.active_count
    w.stats.constraints=st.ref_count
    w.tick+=1
    w.time+=f64(dt)
    breakables_update(w)
    profile_lap(&w.profile.sleep,&mark)
}

@(private)
profile_lap :: #force_inline proc(slot:^f32,mark:^time.Tick) {
    now:=time.tick_now()
    slot^=f32(time.duration_milliseconds(time.tick_diff(mark^,now)))
    mark^=now
}

@(private) Solve_Pass :: enum u8 {Warm_Start,Solve,Restitution}

// Runs one solver pass: the constraints that found no color first, on this thread, then color by color.
// Constraints of one color share no body that they move, so they can be solved in any order.
@(private)
solve_stage :: proc(w:^World,pass:Solve_Pass) {
    st:=&w.step
    st.pass=pass
    joints:=pass!=.Restitution
    // The drives of a spherical joint go before the rest of it, which is solved in lanes.
    if joints {
        st.stage_offset=st.joint_color_start[OVERFLOW_COLOR]
        if count:=st.joint_color_start[OVERFLOW_COLOR+1]-st.stage_offset;count>0 {joints_scalar_task(w,0,count,0)}
        joint_singles(w)
    }
    contacts_singles(w)
    for color in 0..<GRAPH_COLORS {
        if joints {
            st.stage_offset=st.joint_color_start[color]
            world_parallel(w,st.joint_color_start[color+1]-st.stage_offset,8,w,joints_scalar_task)
            st.stage_offset=st.joint_block_start[color]
            world_parallel(w,st.joint_block_start[color+1]-st.stage_offset,4,w,joint_blocks_task)
        }
        st.stage_offset=st.wide_start[color]
        world_parallel(w,st.wide_start[color+1]-st.stage_offset,8,w,contacts_pass_task)
    }
}

// Awake bodies in the order of their list, with their velocities and the constants of the step.
@(private)
solver_bodies_gather :: proc(w:^World) #no_bounds_check {
    st:=&w.step
    st.awake_count=bodies_awake(w,st.awake)
    for i,count in st.awake[:st.awake_count] {
        body:=&w.bodies[i]
        body.solver_index=i32(count)
        st.bodies[count]={v=body.linear_velocity,flags=body.flags,w=body.angular_velocity,dq=QUAT_IDENTITY}
        params:=&st.params[count]
        if body.type==.Dynamic {
            inv_inertia:=body_inv_inertia_world(body)
            params^={
                inv_inertia=inv_inertia,inertia=body.inertia,q0=body.rotation,
                linear_acceleration=body.inv_mass*body.force+body.gravity_scale*body_gravity_of(w,body),
                angular_acceleration=inv_inertia*body.torque,
                inv_mass=body.inv_mass,linear_damping=body.linear_damping,angular_damping=body.angular_damping,
            }
        } else {
            params^={q0=body.rotation}
        }
    }
}

// The root of the set of index, in a forest where parents[i]==i is a root. Halves the paths it walks.
union_find :: proc "contextless" (parents:[]i32,index:i32) -> i32 #no_bounds_check {
    i:=index
    for parents[i]!=i {
        parents[i]=parents[parents[i]]
        i=parents[i]
    }
    return i
}

// Joins the sets of a and b under the lower root.
union_join :: #force_inline proc "contextless" (parents:[]i32,a,b:i32) {
    ra,rb:=union_find(parents,a),union_find(parents,b)
    if ra<rb {parents[rb]=ra} else if rb<ra {parents[ra]=rb}
}

// Assigns a color where the constraint shares no dynamic body with another of the same color. Constraints
// against static or kinematic bodies take the last colors, solved last, which keeps stacks firm.
@(private)
color_assign :: proc "contextless" (st:^Step,a,b:i32) -> int #no_bounds_check {
    dynamic_a:=a>=0 && st.params[a].inv_mass>0
    dynamic_b:=b>=0 && st.params[b].inv_mass>0
    words:=st.color_words
    if dynamic_a && dynamic_b {
        wa,ma:=int(a>>6),u64(1)<<u64(a&63)
        wb,mb:=int(b>>6),u64(1)<<u64(b&63)
        for color in 0..<DYNAMIC_COLORS {
            bits:=st.color_bits[color*words:]
            if bits[wa]&ma!=0 || bits[wb]&mb!=0 {continue}
            bits[wa]|=ma
            bits[wb]|=mb
            return color
        }
    } else if dynamic_a || dynamic_b {
        body:=dynamic_a?a:b
        word,mask:=int(body>>6),u64(1)<<u64(body&63)
        for color:=GRAPH_COLORS-1;color>=1;color-=1 {
            bits:=st.color_bits[color*words:]
            if bits[word]&mask!=0 {continue}
            bits[word]|=mask
            return color
        }
    }
    return OVERFLOW_COLOR
}

// Lists the joints and manifolds to solve, grouped by color, and joins the islands they connect.
@(private)
constraints_gather :: proc(w:^World) #no_bounds_check {
    st:=&w.step
    for &cs in st.characters[:st.character_count] {
        if cs.standing && cs.ground>=0 {island_constraint(w,cs.body,cs.ground)}
    }
    used_words:=(st.awake_count+63)/64
    for color in 0..<GRAPH_COLORS {mem.zero_slice(st.color_bits[color*st.color_words:][:used_words])}
    counts:[GRAPH_COLORS+1]int

    st.joint_count=0
    st.joint_single_count=0
    // The joints of the awake bodies in their order; one of two awake bodies comes from the lower slot.
    st.joint_solved_count=0
    for index in st.awake[:st.awake_count] {
        for key:=w.bodies[index].joint_list;key>=0; {
            joint:=&w.joints[key>>1]
            other:=key&1==0?joint.body_b:joint.body_a
            if w.bodies[other].solver_index<0 || other>index {
                st.joint_solved[st.joint_solved_count]=key>>1
                st.joint_solved_count+=1
            }
            key=joint.edges[key&1].next
        }
    }
    JOINT_BUCKETS :: GRAPH_COLORS*LANE_JOINT_TYPES
    lane_buckets:[JOINT_BUCKETS]int
    lanes:=0
    for i in st.joint_solved[:st.joint_solved_count] {
        joint:=&w.joints[i]
        a,b:=w.bodies[joint.body_a].solver_index,w.bodies[joint.body_b].solver_index
        island_constraint(w,joint.body_a,joint.body_b)
        color:=color_assign(st,a,b)
        if joint.type==.SixDOF || joint.type==.Spherical && .Angular_Drive in joint.flags {
            st.joint_slots[st.joint_count]=i32(color)
            st.joint_data[st.joint_count].joint=i
            st.joint_count+=1
            counts[color]+=1
        }
        if joint.type==.SixDOF {continue}
        if color==OVERFLOW_COLOR {
            st.joint_single_slots[st.joint_single_count]=i
            st.joint_single_count+=1
            continue
        }
        bucket:=color*LANE_JOINT_TYPES+int(joint.type)
        st.joint_scratch[lanes]={i,i32(bucket)}
        lanes+=1
        lane_buckets[bucket]+=1
    }
    start:=0
    for color in 0..=GRAPH_COLORS {
        st.joint_color_start[color]=start
        start+=counts[color]
    }
    st.joint_color_start[GRAPH_COLORS+1]=start
    cursor:=st.joint_color_start
    for i in 0..<st.joint_count {
        color:=st.joint_slots[i]
        st.joint_order[cursor[color]]=i32(i)
        cursor[color]+=1
    }
    // A block holds joints of one type: each type of each color starts a block.
    lane_slots:[JOINT_BUCKETS]int
    joint_blocks:=0
    for color in 0..<GRAPH_COLORS {
        st.joint_block_start[color]=joint_blocks
        for type in 0..<LANE_JOINT_TYPES {
            bucket:=color*LANE_JOINT_TYPES+type
            lane_slots[bucket]=joint_blocks*WIDE
            joint_blocks+=(lane_buckets[bucket]+WIDE-1)/WIDE
        }
    }
    st.joint_block_start[GRAPH_COLORS]=joint_blocks
    for &slot in st.joint_lanes[:joint_blocks*WIDE] {slot=-1}
    for lane in st.joint_scratch[:lanes] {
        st.joint_lanes[lane_slots[lane.bucket]]=lane.joint
        lane_slots[lane.bucket]+=1
    }

    BUCKETS :: (GRAPH_COLORS+1)*MANIFOLD_MAX_POINTS
    buckets:[BUCKETS]int
    count:=0
    edges:=!w.desc.sleep_disabled
    st.island_edge_count=0
    for i in st.active[:st.active_count] {
        contact:=&w.contacts[i]
        if contact.flags&{.Touching,.Overlap}!={.Touching} {continue}
        island_constraint(w,contact.body_a,contact.body_b)
        if edges {
            st.island_edges[st.island_edge_count]={contact.body_a,contact.body_b}
            st.island_edge_count+=1
        }
        a,b:=w.bodies[contact.body_a].solver_index,w.bodies[contact.body_b].solver_index
        // A body seen through a twin turns: the contact is solved as a single.
        turned:=false
        if .Twin in (w.shapes[contact.shape_a].flags+w.shapes[contact.shape_b].flags) {
            _,side:=contact_turn(w,contact)
            turned=side==1 && a>=0 || side==2 && b>=0
        }
        for manifold in 0..<contact.manifold_count {
            points:=manifold==0?contact.manifold.count:w.blocks[contact.extra].manifolds[manifold-1].count
            if points==0 {continue}
            // A block runs every lane for the points of its fullest one: equal counts go together.
            bucket:=(turned?OVERFLOW_COLOR:color_assign(st,a,b))*MANIFOLD_MAX_POINTS+int(MANIFOLD_MAX_POINTS-points)
            st.ref_scratch[count]={i,manifold,i32(bucket)}
            count+=1
            buckets[bucket]+=1
        }
    }
    st.ref_count=count
    slots:[BUCKETS]int
    blocks,colors:=0,0
    for color in 0..<GRAPH_COLORS {
        st.wide_start[color]=blocks
        slot:=blocks*WIDE
        for k in color*MANIFOLD_MAX_POINTS..<(color+1)*MANIFOLD_MAX_POINTS {
            slots[k]=slot
            slot+=buckets[k]
        }
        if slot>blocks*WIDE {colors+=1}
        blocks=(slot+WIDE-1)/WIDE
    }
    st.wide_start[GRAPH_COLORS]=blocks
    w.stats.colors=colors
    for &ref in st.refs[:(blocks+1)*WIDE] {ref.contact=-1}
    // The manifolds without color move to the front of the scratch, in order: each gets a single.
    singles:=0
    for ref in st.ref_scratch[:count] {
        if int(ref.bucket)>=OVERFLOW_COLOR*MANIFOLD_MAX_POINTS {
            st.ref_scratch[singles]=ref
            singles+=1
            continue
        }
        st.refs[slots[ref.bucket]]=ref
        slots[ref.bucket]+=1
    }
    st.single_count=singles
    w.stats.overflow_constraints=singles
    st.wide=st.block_memory[:blocks+1]
    st.singles=([^]Contact_Block(1))(raw_data(st.block_memory[blocks+1:]))[:singles]
}

@(private)
integrate_velocities_task :: proc(data:rawptr,first,last,worker:int) #no_bounds_check {
    w:=(^World)(data)
    st:=&w.step
    h:=st.h
    for i in first..<last {
        params:=&st.params[i]
        if params.inv_mass==0 {continue}
        body:=&st.bodies[i]
        v,om:Vec3
        if st.fluid_active && st.wet[i].fluid>=0 {
            // The fluid, with its drags implicit: v-u shrinks by 1+h k |v-u|, w by 1+h k_a |w| I^-1, each speed
            // the one at the start of the substep.
            linear,angular,k,angular_k:=fluid_forces(w,i,worker)
            current:=st.wet[i].current
            v=body.v+h*(params.linear_acceleration+linear)
            if k>0 {v=current+(v-current)*(1/(1+h*k*length(body.v-current)))}
            v*=1/(1+h*params.linear_damping)
            om=body.w+h*(params.angular_acceleration+angular)
            if angular_k>0 {om=mat3_solve(mat3_diagonal({1,1,1})+(h*angular_k*length(body.w))*params.inv_inertia,om)}
            om*=1/(1+h*params.angular_damping)
        } else {
            v=(body.v+h*params.linear_acceleration)*(1/(1+h*params.linear_damping))
            om=(body.w+h*params.angular_acceleration)*(1/(1+h*params.angular_damping))
        }
        // Gyroscopic torque, implicit: one Newton step of I(om2-om1)+h om2×Iom2=0 in body axes.
        q:=body.dq*params.q0
        local:=q_inv_rotate(q,om)
        momentum:=params.inertia*local
        residual:=h*cross(local,momentum)
        jacobian:=params.inertia+h*(mat3_skew(local)*params.inertia-mat3_skew(momentum))
        om=q_rotate(q,local-mat3_solve(jacobian,residual))
        if body.flags&BODY_LOCKS!={} {v,om=locks_apply(body.flags,v,om)}
        body.v,body.w=v,om
    }
}

@(private)
locks_apply :: proc "contextless" (flags:Body_Flags,v,om:Vec3) -> (Vec3,Vec3) {
    v,om:=v,om
    if .Lock_Linear_X in flags {v.x=0}
    if .Lock_Linear_Y in flags {v.y=0}
    if .Lock_Linear_Z in flags {v.z=0}
    if .Lock_Angular_X in flags {om.x=0}
    if .Lock_Angular_Y in flags {om.y=0}
    if .Lock_Angular_Z in flags {om.z=0}
    return v,om
}

@(private)
integrate_positions_task :: proc(data:rawptr,first,last,worker:int) #no_bounds_check {
    w:=(^World)(data)
    st:=&w.step
    h:=st.h
    max_linear:=w.desc.max_linear_speed
    max_angular:=MAX_ROTATION*st.inv_dt
    for i in first..<last {
        body:=&st.bodies[i]
        v,om:=body.v,body.w
        if body.flags&BODY_LOCKS!={} && st.params[i].inv_mass>0 {v,om=locks_apply(body.flags,v,om)}
        if s:=length2(v);s>max_linear*max_linear {v*=max_linear/cmath.sqrt(s)}
        if s:=length2(om);s>max_angular*max_angular {om*=max_angular/cmath.sqrt(s)}
        body.v,body.w=v,om
        body.dp+=h*v
        body.dq=q_integrate(body.dq,h*om)
    }
}

// Writes the result of the step to the bodies and refreshes the boxes of their shapes.
@(private)
finalize_task :: proc(data:rawptr,first,last,worker:int) #no_bounds_check {
    w:=(^World)(data)
    st:=&w.step
    sleep_allowed:=!w.desc.sleep_disabled
    for i in first..<last {
        index:=st.awake[i]
        body:=&w.bodies[index]
        solved:=&st.bodies[i]
        // The passes after the last move of the substeps leave velocity along locked axes that never moves the body.
        if body.flags&BODY_LOCKS!={} && st.params[i].inv_mass>0 {solved.v,solved.w=locks_apply(body.flags,solved.v,solved.w)}
        body.linear_velocity,body.angular_velocity=solved.v,solved.w
        body.center+=solved.dp
        body.rotation=q_normalize(solved.dq*body.rotation)
        body.position=body.center-q_rotate(body.rotation,body.local_center)
        body.force,body.torque={},{}
        speed:=max(length(solved.v),length(solved.w)*body.max_extent)
        if !sleep_allowed || .Sleep_Disabled in body.flags || speed>body.sleep_threshold || st.fluid_active && st.wet[i].restless {
            body.sleep_time=0
        } else {
            body.sleep_time+=st.dt
        }
        xf:=Transform{body.position,body.rotation}
        body.flags-={.Enlarged}
        for s:=body.shape_list;s>=0;s=w.shapes[s].next {
            shape:=&w.shapes[s]
            shape.aabb=shape_aabb(w,shape,xf)
            reach:=shape.aabb
            if .Character in body.flags {reach=spatial.aabb_translate_extend(reach,solved.v*st.dt)}
            if !math.aabb_contains(shape.fat,reach) {
                shape.fat=shape_fat(reach)
                body.flags+={.Enlarged}
            }
        }
    }
}

// Moves in the tree the proxies whose fat box changed, which then need new pairs. Serial: the tree and the list
// of the moved shapes are shared.
@(private)
proxies_update :: proc(w:^World) #no_bounds_check {
    st:=&w.step
    tree:=&w.trees[DYNAMIC_TREE]
    for index in st.awake[:st.awake_count] {
        body:=&w.bodies[index]
        if .Enlarged not_in body.flags {continue}
        for s:=body.shape_list;s>=0;s=w.shapes[s].next {
            shape:=&w.shapes[s]
            if spatial.dynamic_tree_aabb(tree,shape.proxy)==shape.fat {continue}
            spatial.dynamic_tree_move(tree,shape.proxy,shape.fat)
            shape_moved(w,s)
        }
    }
}

// Contact events with the impulse of the step, in contact order.
@(private)
step_events :: proc(w:^World) {
    st:=&w.step
    for i in st.active[:st.active_count] {
        contact:=&w.contacts[i]
        if contact.flags&{.Started,.Overlap,.Touching}!={.Started,.Touching} {continue}
        if .Debris in (w.bodies[contact.body_a].flags+w.bodies[contact.body_b].flags) {continue}
        manifold:=&w.manifolds[i]
        shape_a,shape_b,body_a,body_b:=contact_handles(w,contact)
        event:=Contact_Begin_Event{shape_a=shape_a,shape_b=shape_b,body_a=body_a,body_b=body_b,normal=manifold.normal}
        event.users,_=event_users(w,contact.shape_a,contact.shape_b)
        for point in manifold.points[:manifold.count] {
            event.point+=point.point/f32(manifold.count)
            event.impulse+=point.impulse
        }
        // In the world, where the copy of a twin touched.
        if through:=contact_through(w,contact);through!=TRANSFORM_IDENTITY {
            event.point,event.normal=xf_point(through,event.point),q_rotate(through.q,event.normal)
        }
        event_push(w,w.events.contact_begin,0,event)
    }
}

// Hits of the contacts of shapes that raise them: the points that approached faster than hit_speed.
@(private)
step_hits :: proc(w:^World) {
    if w.hit_shapes==0 {return}
    st:=&w.step
    for i in st.active[:st.active_count] {
        contact:=&w.contacts[i]
        if contact.shape_b<0 || contact.flags&{.Touching,.Overlap}!={.Touching} {continue}
        if .Hits not_in (w.shapes[contact.shape_a].flags+w.shapes[contact.shape_b].flags) {continue}
        if .Debris in (w.bodies[contact.body_a].flags+w.bodies[contact.body_b].flags) {continue}
        impulse:f32
        point:Vec3
        points:=0
        for m in 0..<contact.manifold_count {
            manifold:=m==0?&w.manifolds[i]:&w.extra_manifolds[contact.extra][m-1]
            for p in manifold.points[:manifold.count] {
                if p.approach<w.desc.hit_speed {continue}
                impulse+=p.impulse
                point+=p.point
                points+=1
            }
        }
        if points==0 || impulse<=0 {continue}
        shape_a,shape_b,_,_:=contact_handles(w,contact)
        through:=contact_through(w,contact)
        event_push(w,w.events.hit,7,Contact_Hit_Event{shape_a=shape_a,shape_b=shape_b,point=xf_point(through,point/f32(points)),normal=q_rotate(through.q,w.manifolds[i].normal),impulse=impulse})
    }
}

