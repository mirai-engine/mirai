package mirai_physics

import cmath "core:math"
import "core:mem"
import "core:slice"
import "mirai:std/spatial"
import math "mirai:std/math"

@(private) CCD_OVERLAP_CAPACITY :: 4 // shapes that only overlap a bullet it keeps for their events in one step
@(private) CCD_MAX_IMPACTS :: 4      // of a bullet in one step; after the last one it waits for the next step
@(private) CCD_MIN_REST :: 1e-4      // fraction of the step below which what is left after an impact is not swept
@(private) CCD_SAFETY :: 0.5         // of its smallest extent: a dynamic that moves more in a step is swept
@(private) CCD_CORE :: 0.25          // of its smallest extent: the core swept when the shapes start touching

@(private) CCD_Hit :: struct {fraction:f32,shape_a,shape_b:i32}

// A bullet of the step and what its search found in the current pass.
@(private) CCD_Bullet :: struct {
    index:i32,
    hit:CCD_Hit,     // first impact, in time of the step
    dropped:i32,     // overlaps of the pass that did not fit
    found:u8,        // overlaps of the pass, after the kept ones in its slots
    impacts:u8,
    stationary:bool, // the other body stood still in the search: the impact holds even if it was stopped before
    continues:bool,  // stopped by a static body in this pass: it moves on for the rest of the step
    retry:bool,      // its impact was on a trajectory that another impact cut short: it searches again
}

// What the continuous run knows of a body: valid only with the stamp of the run.
@(private) CCD_Body :: struct {
    sweep:Sweep,
    start,fraction:f32, // in time of the step: the sweep spans [start,1], and the body stopped at fraction
    stamp:u32,
    bullet:i32,         // its record in bullets, or -1
    moving:bool,        // moved in the step: its shapes are in the tree with swept boxes
    crossed:u8,         // overlaps kept in its slots
}

// Scratch of the continuous collision of a step.
@(private)
Continuous :: struct {
    bodies:[]CCD_Body,         // by body slot
    bounds:[]math.Aabb,        // by shape slot, of moving bodies: the box its sweep covers
    proxies:[]i32,             // by shape slot, of moving bodies: its proxy in tree
    overlaps:[]CCD_Hit,        // CCD_OVERLAP_CAPACITY by body slot: what only overlaps a bullet and its sweep met
    bullets:[]CCD_Bullet,      // of the step, in slot order
    active:[]i32,              // the bullets that search in the pass
    order:[]u64,
    tree:spatial.Dynamic_Tree, // the bodies that moved in the step; the persistent trees hold the rest
    stamp:u32,
}

@(private)
continuous_init :: proc(c:^Continuous,d:World_Desc,a:mem.Allocator) -> bool {
    ok:=true
    alloc :: proc(slice:^[]$T,count:int,a:mem.Allocator,ok:^bool) {
        if count<=0 {return}
        error:mem.Allocator_Error
        slice^,error=make([]T,count,a)
        if error!=nil {ok^=false}
    }
    alloc(&c.bodies,d.body_capacity,a,&ok)
    alloc(&c.bounds,d.shape_capacity,a,&ok)
    alloc(&c.proxies,d.shape_capacity,a,&ok)
    alloc(&c.overlaps,d.body_capacity*CCD_OVERLAP_CAPACITY,a,&ok)
    alloc(&c.bullets,d.body_capacity,a,&ok)
    alloc(&c.active,d.body_capacity,a,&ok)
    alloc(&c.order,d.body_capacity,a,&ok)
    ok&&=spatial.dynamic_tree_init(&c.tree,{proxy_capacity=d.shape_capacity,allocator=a})
    return ok
}

@(private)
continuous_destroy :: proc(c:^Continuous,a:mem.Allocator) {
    delete(c.bodies,a);delete(c.bounds,a);delete(c.proxies,a);delete(c.overlaps,a)
    delete(c.bullets,a);delete(c.active,a);delete(c.order,a)
    spatial.dynamic_tree_destroy(&c.tree)
    c^={}
}

@(private) Toi_Visit :: struct {proxy:Proxy,sweep,other:Sweep,start:Vec3,best:^f32,keep,core:f32}

@(private)
toi_triangle :: proc(data:rawptr,a,b,c:Vec3) -> bool {
    visit:=(^Toi_Visit)(data)
    // One-sided, as the contacts of meshes: a bullet that starts behind a face goes through it.
    if dot(cross(b-a,c-a),visit.start-a)<0 {return true}
    points:=[3]Vec3{a,b,c}
    out:=continuous_toi(visit.proxy,{points[:],0,0},visit.sweep,visit.other,visit.best^,visit.keep,visit.core)
    if out.state==.Hit && out.fraction<visit.best^ {visit.best^=out.fraction}
    return true
}

@(private)
continuous_shape_sweep :: proc "contextless" (body:^Body,shape:^Shape,sweep:Sweep) -> Sweep {
    return {q_inv_rotate(shape.local.q,body.local_center-shape.local.p),sweep.c1,sweep.c2,sweep.q1*shape.local.q,sweep.q2*shape.local.q}
}

// The part of a sweep over [start,1] of the step that comes after `from`, as a sweep over [from,1].
@(private)
sweep_after :: proc "contextless" (s:Sweep,start,from:f32) -> Sweep {
    if from<=start {return s}
    t:=(from-start)/(1-start)
    return {s.local_center,s.c1+(s.c2-s.c1)*t,s.c2,sweep_transform(s,t).q,s.q2}
}

@(private)
sweep_still :: #force_inline proc "contextless" (body:^Body) -> Sweep {
    return {body.local_center,body.center,body.center,body.rotation,body.rotation}
}

@(private)
continuous_bound :: proc "contextless" (w:^World,shape:^Shape,body:^Body,sweep:Sweep) -> math.Aabb {
    radius:=shape_extent(w,shape,body.local_center)
    extent:=Vec3{radius,radius,radius}
    return {vmin(sweep.c1,sweep.c2)-extent,vmax(sweep.c1,sweep.c2)+extent}
}

// The outer TOI clearance is not an impact when the shapes already start inside it: the search goes on with
// the clearance `keep` of the gap there was at the start. Zero searches the real surfaces and leaves a start
// in contact to the solver of the step; a bullet that resumes after an impact keeps half the gap, so that no
// impact of the step leaves it touching what it would then go through unseen. Shapes that start touching sweep
// a sphere of radius `core` at the center of mass instead, so a body in contact still cannot go through.
@(private)
continuous_toi :: proc(a,b:Proxy,sa,sb:Sweep,fraction:f32,keep,core:f32) -> Toi_Output {
    out:=time_of_impact(a,b,sa,sb,fraction)
    if out.state==.Overlapped {
        center:=[1]Vec3{sa.local_center}
        out=time_of_impact({center[:],core,0},b,sa,sb,fraction)
        return out.state==.Hit && out.fraction>0?out:{.Overlapped,0}
    }
    if out.state!=.Hit || out.fraction!=0 {return out}
    clearance:f32
    if keep>0 {
        gap:=gjk_distance(a,b,xf_inv_mul(sweep_transform(sa,0),sweep_transform(sb,0)),nil).distance-a.radius-b.radius
        clearance=max(keep*gap,0)
    }
    return toi_solve(a,b,sa,sb,fraction,clearance)
}

@(private) CCD_RESUME_KEEP :: 0.5

@(private)
continuous_fraction :: #force_inline proc "contextless" (c:^Continuous,index:i32) -> f32 {
    entry:=&c.bodies[index]
    return entry.stamp==c.stamp?entry.fraction:1
}

// Searches the first impact of each active swept body over what is left of its sweep: a bullet against every
// body, any other against static ones. Every other body moves on its own sweep while it has not stopped, and
// stands where it is once it has.
@(private)
continuous_task :: proc(data:rawptr,first,last,worker:int) #no_bounds_check {
    w:=(^World)(data)
    c:=&w.step.ccd
    for k in first..<last {
        b:=&c.bullets[c.active[k]]
        index:=b.index
        body:=&w.bodies[index]
        entry:=&c.bodies[index]
        start:=entry.start
        best:f32=1
        b.hit={fraction=1,shape_a=-1,shape_b=-1}
        b.stationary,b.continues,b.retry,b.dropped=false,false,false,0
        slots:=c.overlaps[int(index)*CCD_OVERLAP_CAPACITY:][:CCD_OVERLAP_CAPACITY]
        kept,found:=int(entry.crossed),0
        trees:=[3]^spatial.Dynamic_Tree{&w.trees[STATIC_TREE],&w.trees[DYNAMIC_TREE],&c.tree}
        core:=CCD_CORE*body.min_extent
        for s:=body.shape_list;s>=0;s=w.shapes[s].next {
            shape:=&w.shapes[s]
            if shape.filter.block|shape.filter.overlap==0 || shape.type>=.Mesh {continue}
            storage_a,storage_b:[8]Vec3=---,---
            proxy:=shape_proxy(w,shape,&storage_a)
            box:=c.bounds[s]
            for tree,which in trees[:.Bullet in body.flags?3:1] {
                query:=spatial.dynamic_tree_query(tree,box)
                for _,user in spatial.tree_query_next(&query) {
                    other:=&w.shapes[user]
                    if other.body==index {continue}
                    // Copies of twins, and shapes near a cut, are left to the contacts.
                    if .Twin in other.flags || w.cut_count>0 && (cut_touches(w,i32(user),other,box) || cut_touches(w,s,shape,box)) {continue}
                    other_entry:=&c.bodies[other.body]
                    moved:=other_entry.stamp==c.stamp && other_entry.moving
                    // What moved in the step is in tree with its swept box; the persistent box is stale.
                    if which==1 && moved {continue}
                    response:=filter_response(shape.filter,other.filter)
                    if response==.Ignore || !shapes_should_collide(w,shape,other) || !math.aabb_overlaps(moved?c.bounds[user]:other.aabb,box) {continue}
                    other_body:=&w.bodies[other.body]
                    // The pair is swept from when both trajectories are known.
                    moving:=moved && other_entry.fraction==1
                    from:=start
                    other_sweep:=sweep_still(other_body)
                    if moving {
                        from=max(start,other_entry.start)
                        other_sweep=sweep_after(other_entry.sweep,other_entry.start,from)
                    }
                    span:=1-from
                    if !(best>from) || span<CCD_MIN_REST {continue}
                    sweep:=continuous_shape_sweep(body,shape,sweep_after(entry.sweep,start,from))
                    other_sweep=continuous_shape_sweep(other_body,other,other_sweep)
                    contact:=contact_find(w,s,i32(user))
                    // What the bullet goes through without stopping: the pairs that only overlap, met from
                    // outside, are kept for their events once it is known how far the bullet went.
                    if response==.Overlap {
                        if other.type>=.Mesh || contact>=0 && .Touching in w.contacts[contact].flags {continue}
                        known:=false
                        for hit in slots[:kept+found] {known=known || hit.shape_a==s && hit.shape_b==i32(user)}
                        if known {continue}
                        out:=time_of_impact(proxy,shape_proxy(w,other,&storage_b),sweep,other_sweep,1)
                        if out.state!=.Hit {continue}
                        if kept+found>=CCD_OVERLAP_CAPACITY {
                            b.dropped+=1
                            continue
                        }
                        slots[kept+found]={from+out.fraction*span,s,i32(user)}
                        found+=1
                        continue
                    }
                    motion:=(sweep.c2-sweep.c1)-(other_sweep.c2-other_sweep.c1)
                    if one_way_passes(w,contact,other,motion) || one_way_passes(w,contact,shape,-motion) {continue}
                    limit:=(best-from)/span
                    local:=limit
                    keep:f32=start>0?CCD_RESUME_KEEP:0
                    if other.type<.Mesh {
                        out:=continuous_toi(proxy,shape_proxy(w,other,&storage_b),sweep,other_sweep,limit,keep,core)
                        if out.state==.Hit && out.fraction<local {local=out.fraction}
                    } else {
                        local_start:=xf_inv_mul(sweep_transform(other_sweep,0),sweep_transform(sweep,0))
                        local_end:=xf_inv_mul(sweep_transform(other_sweep,1),sweep_transform(sweep,1))
                        radius:=body.max_extent
                        if other_sweep.q1!=other_sweep.q2 {radius+=2*other_body.max_extent}
                        local_box:=math.aabb_expand(math.aabb_merge({local_start.p,local_start.p},{local_end.p,local_end.p}),radius)
                        visit:=Toi_Visit{proxy,sweep,other_sweep,local_start.p,&local,keep,core}
                        triangles_visit(w,other,local_box,{},&visit,toi_triangle)
                    }
                    if local<limit {
                        best=from+local*span
                        b.hit={best,s,i32(user)}
                        b.stationary=!moving
                    }
                }
            }
        }
        b.found=u8(found)
    }
}

// Continuous collision of the awake bullets and of the dynamics that moved more than CCD_SAFETY of their smallest
// extent in the step (Box2D's fast bodies). Each pass searches in parallel the first impact of every active
// swept body; the impacts are accepted in order of time and slot. In the next pass a bullet stopped by a static
// body sweeps what is left of the step with its new velocity, and one whose target had stopped before meeting
// it searches again against where the target stands. Passes and impacts of a bullet stop at CCD_MAX_IMPACTS.
@(private)
continuous_update :: proc(w:^World) #no_bounds_check {
    st:=&w.step
    c:=&st.ccd
    count,bullets:=0,0
    for index in st.awake[:st.awake_count] {
        body:=&w.bodies[index]
        if body.type!=.Dynamic {continue}
        if .Bullet in body.flags {
            bullets+=1
        } else {
            // The motion of the farthest point, by the moves of the substeps and by the final velocity.
            solved:=&st.bodies[body.solver_index]
            turn:=2*length(Vec3{solved.dq.x,solved.dq.y,solved.dq.z})*body.max_extent
            motion:=max(length(solved.dp)+turn,(length(solved.v)+length(solved.w)*body.max_extent)*st.dt)
            if !(motion>CCD_SAFETY*body.min_extent) {continue}
        }
        c.bullets[count]={index=index}
        c.active[count]=i32(count)
        count+=1
    }
    if count==0 {return}
    c.stamp+=1
    if c.stamp==0 {
        for &entry in c.bodies {entry.stamp=0}
        c.stamp=1
    }
    // Bullets meet every body that moved in the step in tree; sleeping and static bodies are found in the
    // persistent trees. Without bullets only the swept bodies and the joint neighbours they stop are needed.
    spatial.dynamic_tree_clear(&c.tree)
    if bullets>0 {
        for index in st.awake[:st.awake_count] {continuous_enter(w,index,true)}
    } else {
        for b in c.bullets[:count] {continuous_enter(w,b.index,false)}
    }
    for b,k in c.bullets[:count] {c.bodies[b.index].bullet=i32(k)}
    active,contacts:=count,st.active_count
    for _ in 0..<CCD_MAX_IMPACTS {
        world_parallel(w,active,1,w,continuous_task)
        for a,k in c.active[:active] {
            c.order[k]=u64(transmute(u32)c.bullets[a].hit.fraction)<<32|u64(a)
            w.stats.ccd_overlaps_dropped+=int(c.bullets[a].dropped)
        }
        slice.sort(c.order[:active])
        for key in c.order[:active] {
            b:=&c.bullets[key&0xffffffff]
            hit:=b.hit
            if hit.shape_b<0 || continuous_fraction(c,b.index)<hit.fraction {continue}
            other:=w.shapes[hit.shape_b].body
            if !b.stationary && continuous_fraction(c,other)<hit.fraction {
                b.retry=true
                continue
            }
            // Two bullets that found each other answer once.
            if mirror:=&c.bodies[other];mirror.stamp==c.stamp && mirror.bullet>=0 {
                twin:=&c.bullets[mirror.bullet]
                if twin.hit.shape_a==hit.shape_b && twin.hit.shape_b==hit.shape_a {twin.hit.shape_b=-1}
            }
            continuous_clip(w,b.index,hit.fraction)
            continuous_clip(w,other,hit.fraction)
            // As in Box2D, a fast body that is not a bullet only stops at the impact: the contacts of the next
            // step answer it with every shape that touches, not the one pair the sweep found first.
            if .Bullet not_in w.bodies[b.index].flags {continue}
            continuous_contact(w,hit.shape_a,hit.shape_b)
            b.impacts+=1
            b.continues=w.bodies[other].type==.Static && !continuous_jointed(w,b.index)
        }
        // The overlaps of the pass count up to where each bullet stopped.
        for a in c.active[:active] {
            b:=&c.bullets[a]
            entry:=&c.bodies[b.index]
            slots:=c.overlaps[int(b.index)*CCD_OVERLAP_CAPACITY:][:CCD_OVERLAP_CAPACITY]
            kept:=int(entry.crossed)
            for hit in slots[entry.crossed:][:b.found] {
                if hit.fraction>entry.fraction {continue}
                slots[kept]=hit
                kept+=1
            }
            entry.crossed=u8(kept)
        }
        next:=0
        for a in c.active[:active] {
            b:=&c.bullets[a]
            start:=c.bodies[b.index].fraction
            if b.retry {
                c.active[next]=a
                next+=1
                continue
            }
            if !b.continues || b.impacts>=CCD_MAX_IMPACTS || 1-start<CCD_MIN_REST {continue}
            continuous_continue(w,b.index,start)
            c.active[next]=a
            next+=1
        }
        active=next
        if active==0 {break}
    }
    // The contacts that bullets answered were appended.
    if st.active_count!=contacts {slice.sort(st.active[:st.active_count])}
    continuous_crossings(w,count)
}

// A dynamic body joined to the bullet: stopping the bullet stops it too, so the bullet does not move on alone.
@(private)
continuous_jointed :: proc "contextless" (w:^World,index:i32) -> bool {
    for key:=w.bodies[index].joint_list;key>=0; {
        joint:=&w.joints[key>>1]
        side:=key&1
        key=joint.edges[side].next
        if w.bodies[side==0?joint.body_b:joint.body_a].type==.Dynamic {return true}
    }
    return false
}

// The bullet sweeps what is left of the step from where it stopped, with the velocity of its response, and
// is put at the end of that sweep as the step put the others.
@(private)
continuous_continue :: proc(w:^World,index:i32,start:f32) {
    st:=&w.step
    c:=&st.ccd
    body:=&w.bodies[index]
    rest:=(1-start)*st.dt
    v,om:=body.linear_velocity,body.angular_velocity
    max_linear,max_angular:=w.desc.max_linear_speed,MAX_ROTATION*st.inv_dt
    if s:=length2(v);s>max_linear*max_linear {v*=max_linear/cmath.sqrt(s)}
    if s:=length2(om);s>max_angular*max_angular {om*=max_angular/cmath.sqrt(s)}
    sweep:=Sweep{body.local_center,body.center,body.center+v*rest,body.rotation,q_integrate(body.rotation,om*rest)}
    entry:=&c.bodies[index]
    entry.sweep,entry.start,entry.fraction=sweep,start,1
    continuous_place(w,index,sweep_transform(sweep,1))
    for s:=body.shape_list;s>=0;s=w.shapes[s].next {
        c.bounds[s]=continuous_bound(w,&w.shapes[s],body,sweep)
        spatial.dynamic_tree_move(&c.tree,c.proxies[s],c.bounds[s])
    }
}

@(private)
continuous_place :: proc(w:^World,index:i32,pose:Transform) {
    body:=&w.bodies[index]
    stamp(w,body)
    body.position,body.rotation=pose.p,pose.q
    body.center=pose.p+q_rotate(pose.q,body.local_center)
    for s:=body.shape_list;s>=0;s=w.shapes[s].next {
        shape:=&w.shapes[s]
        stamp(w,shape)
        shape.aabb=shape_aabb(w,shape,pose)
        if !math.aabb_contains(shape.fat,shape.aabb) {
            shape.fat=shape_fat(shape.aabb)
            body.flags+={.Enlarged}
        }
    }
}

// The shapes that only overlap and that a bullet went through in the step: each pair begins and ends in it,
// unless the bullet stopped before reaching it or is still inside at the end, which the next step reports.
@(private)
continuous_crossings :: proc(w:^World,bullets:int) #no_bounds_check {
    c:=&w.step.ccd
    for b in c.bullets[:bullets] {
        entry:=&c.bodies[b.index]
        for hit in c.overlaps[int(b.index)*CCD_OVERLAP_CAPACITY:][:entry.crossed] {
            a,s:=&w.shapes[hit.shape_a],&w.shapes[hit.shape_b]
            storage_a,storage_b:[8]Vec3=---,---
            xf:=xf_inv_mul(shape_transform_of(w,a),shape_transform_of(w,s))
            if gjk_distance(shape_proxy(w,a,&storage_a),shape_proxy(w,s,&storage_b),xf,nil,true).distance<=0 {continue}
            shape_a,shape_b:=shape_handle(w,hit.shape_a),shape_handle(w,hit.shape_b)
            body_a,body_b:=body_handle(w,a.body),body_handle(w,s.body)
            users,swapped:=event_users(w,hit.shape_a,hit.shape_b)
            event_push(w,w.events.overlap_begin,2,Overlap_Event{shape_a,shape_b,body_a,body_b,true,users})
            event_push(w,w.events.overlap_begin,2,Overlap_Event{shape_b,shape_a,body_b,body_a,true,swapped})
            event_push(w,w.events.overlap_end,3,Overlap_Event{shape_a,shape_b,body_a,body_b,true,users})
            event_push(w,w.events.overlap_end,3,Overlap_Event{shape_b,shape_a,body_b,body_a,true,swapped})
        }
    }
}

// Stops a body at time `fraction` of the step, where its sweep had it then. Joint neighbours share the time:
// stopping one link alone tears the solved chain apart.
@(private)
continuous_clip :: proc(w:^World,index:i32,fraction:f32) {
    st:=&w.step
    c:=&st.ccd
    if w.bodies[index].type==.Static || continuous_fraction(c,index)<=fraction {return}
    queue:=st.island_head
    queue[0]=index
    continuous_stop(w,index,fraction)
    count,visited:=1,0
    for visited<count {
        current:=queue[visited]
        visited+=1
        body:=&w.bodies[current]
        if entry:=&c.bodies[current];entry.moving {
            continuous_place(w,current,sweep_transform(entry.sweep,max(fraction-entry.start,0)/(1-entry.start)))
        }
        for key:=body.joint_list;key>=0; {
            joint:=&w.joints[key>>1]
            side:=key&1
            key=joint.edges[side].next
            other:=side==0?joint.body_b:joint.body_a
            if w.bodies[other].type!=.Dynamic || continuous_fraction(c,other)<=fraction {continue}
            continuous_stop(w,other,fraction)
            queue[count]=other
            count+=1
        }
    }
}

// The sweep of an awake body over the step, and its box.
@(private)
continuous_enter :: proc(w:^World,index:i32,insert:bool) {
    st:=&w.step
    c:=&st.ccd
    body:=&w.bodies[index]
    i:=body.solver_index
    sweep:=Sweep{body.local_center,body.center-st.bodies[i].dp,body.center,st.params[i].q0,body.rotation}
    if sweep.q1.w*sweep.q2.w+sweep.q1.x*sweep.q2.x+sweep.q1.y*sweep.q2.y+sweep.q1.z*sweep.q2.z<0 {sweep.q1=-sweep.q1}
    c.bodies[index]={sweep=sweep,fraction=1,stamp=c.stamp,bullet=-1,moving=true}
    for s:=body.shape_list;s>=0;s=w.shapes[s].next {
        c.bounds[s]=continuous_bound(w,&w.shapes[s],body,sweep)
        if insert {c.proxies[s],_=spatial.dynamic_tree_insert(&c.tree,c.bounds[s],u64(s))}
    }
}

// Records that a body stopped at `fraction`; one the run did not know moves on its sweep if it is awake and
// stands still where it is otherwise.
@(private)
continuous_stop :: proc(w:^World,index:i32,fraction:f32) {
    st:=&w.step
    c:=&st.ccd
    entry:=&c.bodies[index]
    if entry.stamp!=c.stamp {
        i:=w.bodies[index].solver_index
        if i>=0 && int(i)<st.awake_count && st.awake[i]==index {
            continuous_enter(w,index,false)
        } else {
            entry^={sweep=sweep_still(&w.bodies[index]),stamp=c.stamp,bullet=-1}
        }
    }
    entry.fraction=fraction
}

@(private)
continuous_body_prepare :: proc(w:^World,index:i32) {
    body:=&w.bodies[index]
    if body.type==.Static {return}
    st:=&w.step
    first:=st.woken_count
    body_wake(w,index)
    for other in st.woken[first:st.woken_count] {
        b:=&w.bodies[other]
        i:=i32(st.awake_count)
        b.solver_index=i
        st.awake[i]=other
        st.awake_count+=1
    }
    i:=body.solver_index
    st.bodies[i]={v=body.linear_velocity,w=body.angular_velocity,flags=body.flags,dq=QUAT_IDENTITY}
    st.params[i]={q0=body.rotation}
    if body.type==.Dynamic {st.params[i].inv_mass,st.params[i].inv_inertia=body.inv_mass,body_inv_inertia_world(body)}
}

// Answers an accepted impact at the pose of the impact: updates the manifold and solves it at once with the
// spare block of the contact solver. A contact can answer again at a later impact of the same step.
@(private)
continuous_contact :: proc(w:^World,shape_a,shape_b:i32) {
    index:=contact_find(w,shape_a,shape_b)
    if index<0 {index=contact_create(w,shape_a,shape_b)}
    if index<0 {return}
    contact:=&w.contacts[index]
    started:=.Started in contact.flags
    prepared:=int(contact.manifold_count) if .Visited in contact.flags else 0
    contact_update(w,index)
    if .Stopped in contact.flags {
        // A pair that began in this step has not said so yet: it begins and ends without events.
        if started {
            island_unlink(w,contact.body_a,contact.body_b)
            started=false
        } else {contact_stopped(w,contact)}
    }
    if contact.manifold_count==0 {return}
    if started {contact.flags+={.Started}}
    st:=&w.step
    if .Visited not_in contact.flags {
        st.active[st.active_count]=index
        st.active_count+=1
        contact.flags+={.Visited}
    }
    continuous_body_prepare(w,contact.body_a)
    continuous_body_prepare(w,contact.body_b)
    a,b:=&w.bodies[contact.body_a],&w.bodies[contact.body_b]
    island_link(w,contact.body_a,contact.body_b)
    spare:=len(st.wide)-1
    for lane in 0..<WIDE {st.refs[spare*WIDE+lane]={contact=-1}}
    st.stage_offset=spare
    st.use_bias=false
    for m in 0..<int(contact.manifold_count) {
        st.refs[spare*WIDE]={index,i32(m),0}
        contacts_prepare_task(w,spare,spare+1,0)
        block:=&st.wide[spare]
        // What the step already applied is in the velocities: this answer accumulates from zero, and the
        // next warm start gets both.
        applied:[MANIFOLD_MAX_POINTS]f32
        for &point,i in block.points[:block.count] {
            // TOI leaves a small gap; this accepted impact must remove the approach immediately.
            ra,rb:=lane_get3(&point.ra,0),lane_get3(&point.rb,0)
            lane_set(&point.base_separation,0,-dot(rb-ra,lane_get3(&block.normal,0)))
            applied[i]=lane_get(&point.normal_impulse,0)
            lane_set(&point.normal_impulse,0,0)
        }
        friction:=[2]f32{lane_get(&block.friction_impulse[0],0),lane_get(&block.friction_impulse[1],0)}
        twist,rolling:=lane_get(&block.twist_impulse,0),lane_get3(&block.rolling_impulse,0)
        lane_set(&block.friction_impulse[0],0,0);lane_set(&block.friction_impulse[1],0,0)
        lane_set(&block.twist_impulse,0,0);lane_set3(&block.rolling_impulse,0,{})
        contacts_solve_task(w,0,1,0)
        contacts_restitution_task(w,0,1,0)
        for &point,i in block.points[:block.count] {lane_set(&point.normal_impulse,0,lane_get(&point.normal_impulse,0)+applied[i])}
        for k in 0..<2 {lane_set(&block.friction_impulse[k],0,lane_get(&block.friction_impulse[k],0)+friction[k])}
        lane_set(&block.twist_impulse,0,lane_get(&block.twist_impulse,0)+twist)
        lane_set3(&block.rolling_impulse,0,lane_get3(&block.rolling_impulse,0)+rolling)
        contacts_store_task(w,spare,spare+1,0)
    }
    for body in ([2]^Body{a,b}) {
        if body.type!=.Dynamic {continue}
        solved:=&st.bodies[body.solver_index]
        solved.v,solved.w=locks_apply(body.flags,solved.v,solved.w)
        body.linear_velocity,body.angular_velocity=solved.v,solved.w
    }
    st.ref_count+=int(contact.manifold_count)-prepared
}
