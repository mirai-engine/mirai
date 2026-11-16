package mirai_physics

// Islands persist from step to step. A constraint that links two dynamic bodies joins their islands at once,
// and one that goes away only counts against its island: the island comes apart when it is about to sleep.

@(private)
island_alloc :: proc(w:^World) -> i32 {
    id:=w.island_free
    if id>=0 {
        w.island_free=w.islands[id].head
    } else {
        // Never full: every island holds at least one body that is not static.
        id=w.island_high
        w.island_high+=1
    }
    w.island_count+=1
    stamp(w,.Islands,id)
    w.islands[id]={head=-1,tail=-1}
    return id
}

@(private)
island_release :: proc(w:^World,id:i32) {
    stamp(w,.Islands,id)
    w.islands[id]={head=w.island_free,tail=-1}
    w.island_free=id
    w.island_count-=1
}

@(private)
island_append :: proc "contextless" (w:^World,id,index:i32) #no_bounds_check {
    island:=&w.islands[id]
    body:=&w.bodies[index]
    stamp(w,.Islands,id)
    stamp(w,body)
    body.island,body.island_prev,body.island_next=id,island.tail,-1
    if island.tail>=0 {stamp(w,.Bodies,island.tail);w.bodies[island.tail].island_next=index} else {island.head=index}
    island.tail=index
    island.count+=1
}

// A body that is not static starts alone in an island.
@(private)
island_create :: proc(w:^World,index:i32) {
    island_append(w,island_alloc(w),index)
}

// Takes a body out of its island, which may have come apart without it. Returns the island that is left, or -1.
@(private)
island_remove :: proc(w:^World,index:i32) -> i32 {
    body:=&w.bodies[index]
    id:=body.island
    if id<0 {return -1}
    island:=&w.islands[id]
    stamp(w,.Islands,id)
    stamp(w,body)
    if body.island_prev>=0 {stamp(w,.Bodies,body.island_prev);w.bodies[body.island_prev].island_next=body.island_next} else {island.head=body.island_next}
    if body.island_next>=0 {stamp(w,.Bodies,body.island_next);w.bodies[body.island_next].island_prev=body.island_prev} else {island.tail=body.island_prev}
    body.island,body.island_prev,body.island_next=-1,-1,-1
    island.count-=1
    island.removed+=1
    if island.count==0 {
        island_release(w,id)
        return -1
    }
    return id
}

// Joins the islands of two awake dynamic bodies that a constraint connects. The smaller island moves into the
// larger one; on a tie, the one of the higher slot into the other.
@(private)
island_link :: proc(w:^World,a,b:i32) #no_bounds_check {
    body_a,body_b:=&w.bodies[a],&w.bodies[b]
    if body_a.type!=.Dynamic || body_b.type!=.Dynamic || .Character in (body_a.flags+body_b.flags) {return}
    if body_a.island==body_b.island || body_a.island<0 || body_b.island<0 || .Awake not_in (body_a.flags&body_b.flags) {return}
    keep,gone:=body_a.island,body_b.island
    if count_keep,count_gone:=w.islands[keep].count,w.islands[gone].count;count_gone>count_keep || count_gone==count_keep && gone<keep {keep,gone=gone,keep}
    kept,moved:=&w.islands[keep],&w.islands[gone]
    stamp(w,.Islands,keep)
    for i:=moved.head;i>=0;i=w.bodies[i].island_next {stamp(w,.Bodies,i);w.bodies[i].island=keep}
    stamp(w,.Bodies,kept.tail)
    w.bodies[kept.tail].island_next=moved.head
    w.bodies[moved.head].island_prev=kept.tail
    kept.tail=moved.tail
    kept.count+=moved.count
    kept.removed+=moved.removed
    island_release(w,gone)
}

// A constraint between two bodies is gone: if they shared an island, it may have come apart.
@(private)
island_unlink :: proc "contextless" (w:^World,a,b:i32) {
    id:=w.bodies[a].island
    if id>=0 && id==w.bodies[b].island {stamp(w,.Islands,id);w.islands[id].removed+=1}
}

// What a constraint does in a step to the islands of its bodies: two dynamic bodies share an island; a
// kinematic body or a character that moves keeps awake the dynamic body it touches or drives. A character
// never joins an island, which it would keep awake.
@(private)
island_constraint :: proc(w:^World,a,b:i32) #no_bounds_check {
    body_a,body_b:=&w.bodies[a],&w.bodies[b]
    if body_a.type==.Dynamic && body_b.type==.Dynamic && .Character not_in (body_a.flags+body_b.flags) {
        if body_a.island!=body_b.island {island_link(w,a,b)}
        return
    }
    for pair in ([2][2]^Body{{body_a,body_b},{body_b,body_a}}) {
        mover,moved:=pair[0],pair[1]
        if moved.type!=.Dynamic || .Character in moved.flags {continue}
        pushed:=.Character in mover.flags?length(mover.linear_velocity)>mover.sleep_threshold:mover.type==.Kinematic && (mover.linear_velocity!={} || mover.angular_velocity!={})
        if pushed && moved.sleep_time!=0 {stamp(w,moved);moved.sleep_time=0}
    }
}

// Splits an island into the groups of its bodies that touching contacts and joints still connect. The first
// group keeps the slot of the island. Leaves the bodies of the island in step.island_bodies and returns how
// many there are.
@(private)
island_split :: proc(w:^World,id:i32,edges:[][2]i32=nil) -> int #no_bounds_check {
    st:=&w.step
    members:=st.island_bodies
    count:=0
    for i:=w.islands[id].head;i>=0;i=w.bodies[i].island_next {
        members[count]=i
        count+=1
    }
    island_release(w,id)
    // A large island goes over the touching contacts that the step listed, with union-find; a small one,
    // through the contact lists of its bodies.
    if edges!=nil && count*16>=len(edges) {
        // step.island_local names the k-th body of the island while it is split, and is -1 otherwise.
        local:=st.island_local
        for index,k in members[:count] {local[index]=i32(k)}
        parents:=st.island_stack
        for k in 0..<count {parents[k]=i32(k)}
        for edge in edges {
            a,b:=local[edge[0]],local[edge[1]]
            if a>=0 && b>=0 {union_join(parents,a,b)}
        }
        for index,k in members[:count] {
            for key:=w.bodies[index].joint_list;key>=0; {
                joint:=&w.joints[key>>1]
                other:=local[key&1==0?joint.body_b:joint.body_a]
                key=joint.edges[key&1].next
                if other>=0 {union_join(parents,i32(k),other)}
            }
        }
        for index in members[:count] {local[index]=-1}
        // The root of a group is its first body, so groups come in the order of their bodies.
        groups:=st.island_group
        for k in 0..<count {
            root:=union_find(parents,i32(k))
            if root==i32(k) {groups[k]=island_alloc(w)}
            island_append(w,groups[root],members[k])
        }
        return count
    }
    // -2 marks a body of the island that no group took yet.
    for index in members[:count] {stamp(w,.Bodies,index);w.bodies[index].island=-2}
    stack:=st.island_stack
    for seed in members[:count] {
        if w.bodies[seed].island!=-2 {continue}
        group:=island_alloc(w)
        w.bodies[seed].island=group
        stack[0]=seed
        top:=1
        for top>0 {
            top-=1
            index:=stack[top]
            island_append(w,group,index)
            body:=&w.bodies[index]
            for key:=body.contact_list;key>=0; {
                contact:=&w.contacts[key>>1]
                other:=key&1==0?contact.body_b:contact.body_a
                key=contact.edges[key&1].next
                if contact.flags&{.Touching,.Overlap}!={.Touching} || w.bodies[other].island!=-2 {continue}
                w.bodies[other].island=group
                stack[top]=other
                top+=1
            }
            for key:=body.joint_list;key>=0; {
                joint:=&w.joints[key>>1]
                other:=key&1==0?joint.body_b:joint.body_a
                key=joint.edges[key&1].next
                if w.bodies[other].island!=-2 {continue}
                w.bodies[other].island=group
                stack[top]=other
                top+=1
            }
        }
    }
    return count
}

// Least time that the bodies of each awake island have been still; returns how many islands there are.
@(private)
islands_time :: proc "contextless" (w:^World,awake:[]i32,times:[]f32) -> (islands:int) #no_bounds_check {
    for index in awake {times[w.bodies[index].island]=-1}
    for index in awake {
        body:=&w.bodies[index]
        id:=body.island
        if times[id]<0 {
            islands+=1
            times[id]=body.sleep_time
        } else {
            times[id]=min(times[id],body.sleep_time)
        }
    }
    return
}

// Puts to sleep the islands whose bodies have all been still for long enough. An island that may have come
// apart sleeps only once split: the ones ready to sleep are split at once, and of the others, the one with
// the stillest body, so that what rests can sleep apart from what still moves.
@(private)
islands_sleep :: proc(w:^World) #no_bounds_check {
    st:=&w.step
    times:=st.island_time
    awake:=st.awake[:st.awake_count]
    islands:=islands_time(w,awake,times)
    split:=i32(-1)
    stillest:f32=-1
    for index in awake {
        body:=&w.bodies[index]
        id:=body.island
        if body.sleep_time>=TIME_TO_SLEEP && body.sleep_time>stillest && times[id]<TIME_TO_SLEEP && w.islands[id].removed>0 {
            split=id
            stillest=body.sleep_time
        }
    }
    splits:=false
    edges:=st.island_edges[:st.island_edge_count]
    for index in awake {
        id:=w.bodies[index].island
        // The groups of an island already split have nothing removed.
        if w.islands[id].removed==0 || times[id]<TIME_TO_SLEEP && id!=split {continue}
        island_split(w,id,edges)
        splits=true
    }
    if splits {islands=islands_time(w,awake,times)}
    w.stats.islands=islands
    for index in awake {
        body:=&w.bodies[index]
        body.solver_index=-1
        if .Awake not_in body.flags || times[body.island]<TIME_TO_SLEEP || w.islands[body.island].removed>0 {continue}
        body_sleep(w,index)
    }
}

// Puts to sleep now the island of a body, once split if it may have come apart.
@(private)
island_sleep_from :: proc(w:^World,index:i32) {
    if w.islands[w.bodies[index].island].removed>0 {island_split(w,w.bodies[index].island)}
    for i:=w.islands[w.bodies[index].island].head;i>=0;i=w.bodies[i].island_next {body_sleep(w,i)}
}

// Takes a body out of its island for good. If it was asleep, the rest wakes: it may have rested on it.
@(private)
island_leave :: proc(w:^World,index:i32) {
    asleep:=.Awake not_in w.bodies[index].flags
    if left:=island_remove(w,index);asleep && left>=0 {body_wake(w,w.islands[left].head)}
}
