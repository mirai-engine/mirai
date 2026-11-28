package mirai_physics

import "core:mem"
import "mirai:std/geom"
import math "mirai:std/math"

// What a breakable has become, as data small enough to send: the cuts by their plane, the body and the
// flags of every piece, and every bond. No geometry: whoever reads it made the same breakable
// from the same description and repeats the cuts. Pieces and bonds are named by their place in the
// lists of the breakable, which is the same wherever the same events were applied. Where its bodies are
// travels apart, by group (Breakable_Pose), so that a recording of it keeps a state only when it changes.

// Where a body of a breakable is and how it moves, named by its group (Piece_Info.group).
Breakable_Pose :: struct {
    rotation:Quat,       // zero means identity
    position:Vec3,
    group:u32,
    linear,angular:Vec3, // m/s of its center of mass, rad/s
    remaining:u32,       // steps until its pieces expire; max: never, or as they are
}

@(private) Break_State_Header :: struct {pieces,connections,original,revision:u32}
@(private) Break_State_Piece :: struct {remaining:u64,parent:i32,group:u32,flags:Piece_Flags,front:u32,normal:Vec3,offset:f32,cluster:i32,_:u32}
@(private) Break_State_Bond :: struct {a,b:i32,flags:Bond_Flags,area,strain:f32,center:Vec3,strength:f32,cluster:i32}
#assert(size_of(Break_State_Header)==16 && size_of(Break_State_Piece)==48 && size_of(Break_State_Bond)==40)

@(private)
cluster_ordinal :: proc(w:^World,d:^Breakable,slot:i32) -> i32 {
    ordinal:i32
    for at:=d.bond_list;at>=0;at=w.bonds[at].next {
        if .Cluster not_in w.bonds[at].flags {continue}
        if at==slot {return ordinal}
        ordinal+=1
    }
    return -1
}

// Counts every group that left, every cut and every piece removed: whoever mirrors the pieces of the
// breakable looks at them again when it changes. Zero while it is as created.
breakable_revision :: proc(w:^World,h:Breakable_Handle) -> u32 {
    d,_:=breakable_read(w,h)
    return d!=nil?d.revision:0
}

// Cuts the hull of a piece by a plane of its frame into two new pieces, the one in front first, which
// are not in the list of the breakable nor on a body yet. False, with nothing made, when a side has no
// volume or a capacity runs out.
@(private)
piece_cut :: proc(w:^World,index,current:i32,n:Vec3,offset:f32,slicer:^geom.Slicer,buffers:^[3]geom.Mesh_Buffer,counts,indices:^[dynamic]u8) -> (halves:[2]i32,ok:bool) {
    halves={-1,-1}
    hull:=hull_get(w,w.pieces[current].hull)
    if hull==nil {return}
    hull_to_mesh(hull,&buffers[0])
    result,error:=geom.mesh_slice(slicer,geom.mesh_buffer_view(&buffers[0]),geom.Plane{n,offset},&buffers[1],&buffers[2])
    if error!=.None || result.front.triangles==0 || result.back.triangles==0 {return}
    halves[0]=piece_build(w,index,buffers[1].positions[:],counts,indices)
    if halves[0]<0 {return}
    halves[1]=piece_build(w,index,buffers[2].positions[:],counts,indices)
    if halves[1]<0 {
        piece_release(w,halves[0])
        halves[0]=-1
        return
    }
    for half,k in halves {
        w.piece_origins[half]={source=-1,parent=current,plane=n,offset=offset,front=k==0}
        w.pieces[half].group=w.pieces[current].group
        w.pieces[half].expire=w.pieces[current].expire
        w.pieces[half].cluster=w.pieces[current].cluster
    }
    return halves,true
}

// Place of each piece in the list of its breakable, into the scratch.
@(private)
piece_ordinals :: proc(w:^World,d:^Breakable) -> []i32 {
    ordinals:=w.breaking.parent
    ordinal:i32
    for slot:=d.piece_list;slot>=0;slot=w.pieces[slot].next {
        ordinals[slot]=ordinal
        ordinal+=1
    }
    return ordinals
}

// Hash of what the breakable has become: the body and the flags of every piece and which bonds
// are broken. Two worlds that applied the same events to equal breakables give the same; strains and
// poses are left out, and so is whether a piece of debris expired, which each world decides.
breakable_check :: proc(w:^World,h:Breakable_Handle) -> u32 {
    d,_:=breakable_read(w,h)
    if d==nil {return 0}
    mix :: #force_inline proc "contextless" (hash:^u32,value:u32) {hash^ = (hash^~value)*16777619}
    ordinals:=piece_ordinals(w,d)
    hash:=u32(2166136261)
    for slot:=d.piece_list;slot>=0;slot=w.pieces[slot].next {
        piece:=&w.pieces[slot]
        flags:=piece.flags
        if .Debris in flags {flags-={.Gone}}
        mix(&hash,piece.group)
        mix(&hash,transmute(u32)flags)
    }
    for slot:=d.bond_list;slot>=0;slot=w.bonds[slot].next {
        c:=&w.bonds[slot]
        mix(&hash,.Cluster in c.flags?u32(cluster_ordinal(w,d,slot)):u32(ordinals[c.a])<<16|u32(ordinals[c.b]))
        mix(&hash,transmute(u32)c.flags)
    }
    return hash
}

// Bytes breakable_state_write needs now.
breakable_state_size :: proc(w:^World,h:Breakable_Handle) -> int {
    d,_:=breakable_read(w,h)
    if d==nil {return 0}
    return size_of(Break_State_Header)+int(d.piece_count)*size_of(Break_State_Piece)+int(d.bond_count)*size_of(Break_State_Bond)
}

// Changes when what breakable_state_write writes changes, the passing of time aside: what a recording of
// the breakable writes again.
breakable_state_version :: proc(w:^World,h:Breakable_Handle) -> u32 {
    d,_:=breakable_read(w,h)
    return d!=nil?d.version:0
}

// Writes what the breakable has become since it was created: its cuts, the body and the flags of
// every piece and the strain of every bond. Debris is written as gone, since it is of each world, unless
// debris asks for it, as a recording of this world does. Returns the bytes written; zero when `out` is
// too small.
breakable_state_write :: proc(w:^World,h:Breakable_Handle,out:[]u8,debris:=false) -> int {
    d,_:=breakable_read(w,h)
    size:=breakable_state_size(w,h)
    if d==nil || len(out)<size {return 0}
    ordinals:=piece_ordinals(w,d)
    header:=Break_State_Header{pieces=u32(d.piece_count),connections=u32(d.bond_count),revision=d.revision}
    at:=size_of(Break_State_Header)
    for slot:=d.piece_list;slot>=0;slot=w.pieces[slot].next {
        piece:=&w.pieces[slot]
        origin:=w.piece_origins[slot]
        remaining:=piece.expire==max(u64)?max(u64):piece.expire>w.tick?piece.expire-w.tick:0
        record:=Break_State_Piece{remaining=remaining,parent=-1,group=piece.group,flags=piece.flags,front=u32(origin.front),normal=origin.plane,offset=origin.offset,cluster=cluster_ordinal(w,d,piece.cluster)}
        if origin.parent>=0 {record.parent=ordinals[origin.parent]} else {header.original+=1}
        if !shape_valid(w,piece.shape) || .Debris in piece.flags && !debris {record.flags+={.Gone}}
        mem.copy(&out[at],&record,size_of(Break_State_Piece))
        at+=size_of(Break_State_Piece)
    }
    for slot:=d.bond_list;slot>=0;slot=w.bonds[slot].next {
        c:=&w.bonds[slot]
        record:=Break_State_Bond{a=c.a>=0?ordinals[c.a]:-1,b=c.b>=0 && .Cluster not_in c.flags?ordinals[c.b]:-1,flags=c.flags,area=c.area,strain=c.strain,center=c.center,strength=c.strength,cluster=cluster_ordinal(w,d,c.cluster)}
        mem.copy(&out[at],&record,size_of(Break_State_Bond))
        at+=size_of(Break_State_Bond)
    }
    mem.copy(&out[0],&header,size_of(Break_State_Header))
    return at
}

// Makes a breakable made from the same description as another one what breakable_state_write described
// of that one, in place: the same cuts, pieces gone, groups, bonds and strains. The cuts both share stay
// and the others are undone; the body of a group both have stays where it is, with its velocity, and a
// group it lacks starts in the frame of the breakable, at rest: whoever wrote the state says where its
// bodies are (breakable_poses_apply). Only repeating a cut allocates. False when the state is not of such
// a breakable or a capacity runs out; the breakable may then be half changed and is only good for
// breakable_destroy.
breakable_state_apply :: proc(w:^World,h:Breakable_Handle,state:[]u8) -> bool {
    d,index:=breakable_get(w,h)
    if d==nil || len(state)<size_of(Break_State_Header) {return false}
    header:Break_State_Header
    mem.copy(&header,raw_data(state),size_of(Break_State_Header))
    pieces,original,connections:=int(header.pieces),int(header.original),int(header.connections)
    s:=&w.breaking
    slots:=s.source // the slot of the piece at each place of the list
    count,made:=0,0
    for slot:=d.piece_list;slot>=0;slot=w.pieces[slot].next {
        slots[count]=slot
        made+=int(w.piece_origins[slot].parent<0)
        count+=1
    }
    if original!=made || pieces<original || (pieces-original)%2!=0 || pieces>len(w.pieces) {return false}
    if len(state)<size_of(Break_State_Header)+pieces*size_of(Break_State_Piece)+connections*size_of(Break_State_Bond) {return false}
    piece_record :: proc(state:[]u8,at:int) -> (record:Break_State_Piece) {
        mem.copy(&record,&state[size_of(Break_State_Header)+at*size_of(Break_State_Piece)],size_of(Break_State_Piece))
        return
    }
    bond_record :: proc(state:[]u8,pieces,at:int) -> (record:Break_State_Bond) {
        mem.copy(&record,&state[size_of(Break_State_Header)+pieces*size_of(Break_State_Piece)+at*size_of(Break_State_Bond)],size_of(Break_State_Bond))
        return
    }
    // The clusters are those it was made with, which keep their hulls, and come before what they hold.
    standing,clusters:=0,0
    for slot:=d.bond_list;slot>=0;slot=w.bonds[slot].next {standing+=int(.Cluster in w.bonds[slot].flags)}
    for at in 0..<connections {
        record:=bond_record(state,pieces,at)
        is_cluster:=.Cluster in record.flags
        if record.flags-{.Broken,.Cluster}!={} || record.a<0 || int(record.a)>=pieces || !is_cluster && (record.b<0 || int(record.b)>=pieces) || is_cluster && record.b!=-1 ||
           record.cluster < -1 || int(record.cluster)>=clusters || !finite(record.area,record.strain,record.strength,record.center.x,record.center.y,record.center.z) ||
           record.area<0 || record.strain<0 || record.strength<0 || is_cluster && (at!=clusters || clusters>=len(s.ids)) {return false}
        clusters+=int(is_cluster)
    }
    if clusters!=standing {return false}
    for at in 0..<pieces {
        record:=piece_record(state,at)
        if record.flags-{.Anchor,.Debris,.Gone}!={} || record.cluster < -1 || int(record.cluster)>=clusters {return false}
        if at<original || (at-original)%2!=0 {continue}
        back:=piece_record(state,at+1)
        if record.parent<0 || int(record.parent)>=at || back.parent!=record.parent || record.front==0 || back.front!=0 ||
           !finite(record.offset,record.normal.x,record.normal.y,record.normal.z) {return false}
    }
    // The cuts it shares with the state, from the first, stay.
    same_cut :: proc(w:^World,slots:[]i32,slot:i32,record:Break_State_Piece) -> bool {
        origin:=w.piece_origins[slot]
        return origin.parent==slots[record.parent] && origin.front==(record.front!=0) && origin.plane==record.normal && origin.offset==record.offset
    }
    keep:=original
    for at:=original;at<min(pieces,count);at+=2 {
        if !same_cut(w,slots,slots[at],piece_record(state,at)) || !same_cut(w,slots,slots[at+1],piece_record(state,at+1)) {break}
        keep=at+2
    }
    if int(w.piece_count)-(count-keep)+(pieces-keep)>len(w.pieces) || int(w.bond_count)-int(d.bond_count)+connections>len(w.bonds) ||
       pieces>count && !piece_hulls_available(w,pieces-count) {
        w.stats.breakable_capacity_exhausted+=1
        return false
    }
    // The bodies it has, by group, and each group of the state once with the body it keeps: the one of
    // that group, of the same kind.
    break_bodies(w,d)
    ids,bodies:=s.ids,s.made_body
    have:=0
    for at in 0..<count {
        body:=s.body[slots[at]]
        group:=w.pieces[slots[at]].group
        if body=={} || body==d.body {continue}
        known:=false
        for id in ids[:have] {known||=id==group}
        if !known {ids[have],bodies[have]=group,body;have+=1}
    }
    wanted,to:=s.parent,s.from
    groups,kept:=0,0
    mark:=break_mark(s)
    for at in 0..<pieces {
        record:=piece_record(state,at)
        if .Gone in record.flags || record.group==0 {continue}
        known:=false
        for group in wanted[:groups] {known||=group==i32(record.group)}
        if known {continue}
        wanted[groups],to[groups]=i32(record.group),{}
        for id,k in ids[:have] {
            if id!=record.group || body_is_debris(w,bodies[k])!=(.Debris in record.flags) || s.marks[body_slot(bodies[k])]==mark {continue}
            to[groups]=bodies[k]
            s.marks[body_slot(bodies[k])]=mark
            kept+=1
        }
        groups+=1
    }
    if world_stats(w).bodies-(have-kept)+(groups-kept)>w.desc.body_capacity {
        w.stats.breakable_capacity_exhausted+=1
        s.refused[index]+={.Bodies}
        return false
    }
    defer break_settle(w)
    // The bodies of the groups it keeps no more go first, with their shapes, and so do the cuts it undoes.
    for body in bodies[:have] {
        if s.marks[body_slot(body)]!=mark {body_destroy(w,body)}
    }
    #reverse for slot in slots[keep:count] {
        piece_detach(w,slot)
        piece_release(w,slot)
    }
    if keep<count {
        d.piece_tail,d.piece_count=slots[keep-1],i32(keep)
        w.pieces[d.piece_tail].next=-1
    }
    if pieces>keep {
        slicer:geom.Slicer
        buffers:[3]geom.Mesh_Buffer
        geom.slicer_init(&slicer,w.allocator)
        for &buffer in buffers {geom.mesh_buffer_init(&buffer,w.allocator)}
        counts:=make([dynamic]u8,w.allocator)
        indices:=make([dynamic]u8,w.allocator)
        defer {
            geom.slicer_destroy(&slicer)
            for &buffer in buffers {geom.mesh_buffer_destroy(&buffer)}
            delete(counts)
            delete(indices)
        }
        for at:=keep;at<pieces;at+=2 {
            front:=piece_record(state,at)
            parent:=slots[front.parent]
            if hull_get(w,w.pieces[parent].hull)==nil {return false}
            halves:=piece_cut(w,index,parent,front.normal,front.offset,&slicer,&buffers,&counts,&indices) or_return
            piece_detach(w,parent)
            for half,k in halves {
                piece_append(w,d,half)
                slots[at+k]=half
            }
        }
    }
    // What is gone leaves, and every other piece goes to the body of its group.
    xf:=body_transform(w,d.body)
    for at in 0..<pieces {
        record:=piece_record(state,at)
        slot:=slots[at]
        piece:=&w.pieces[slot]
        piece.group,piece.flags=record.group,record.flags
        piece.expire=record.remaining==max(u64)?max(u64):w.tick+min(record.remaining,max(u64)-w.tick)
        s.body[slot]={}
        if .Gone in record.flags {continue}
        if hull_get(w,piece.hull)==nil {return false}
        s.body[slot]=d.body
        for group,k in wanted[:groups] {
            if group!=i32(record.group) {continue}
            if to[k]=={} {
                if to[k]=break_body_create(w,d,xf,.Debris in record.flags);to[k]=={} {
                    w.stats.breakable_capacity_exhausted+=1
                    s.refused[index]+={.Bodies}
                    return false
                }
            }
            s.body[slot]=to[k]
            break
        }
    }
    phantoms:=s.cluster_body // the slot of the hull of each cluster, in order
    clusters=0
    for slot:=d.bond_list;slot>=0; {
        next:=w.bonds[slot].next
        if .Cluster in w.bonds[slot].flags {
            phantoms[clusters]=w.bonds[slot].b
            clusters+=1
        }
        stamp(w,.Bonds,slot)
        w.bonds[slot]={next=w.bond_free}
        w.bond_free=slot
        w.bond_count-=1
        slot=next
    }
    d.bond_list,d.bond_tail,d.bond_count=-1,-1,0
    clusters=0
    for at in 0..<connections {
        record:=bond_record(state,pieces,at)
        is_cluster:=.Cluster in record.flags
        parent:=record.cluster>=0?i32(s.ids[record.cluster]):-1
        bond_append(w,d,{a=slots[record.a],b=is_cluster?phantoms[clusters]:slots[record.b],flags=record.flags,area=record.area,strain=record.strain,center=record.center,strength=record.strength,cluster=parent})
        if is_cluster {s.ids[clusters]=u32(d.bond_tail);clusters+=1}
    }
    for at in 0..<pieces {
        record:=piece_record(state,at)
        w.pieces[slots[at]].cluster=record.cluster>=0?i32(s.ids[record.cluster]):-1
    }
    d.revision=header.revision
    d.version+=1
    return break_collide(w,index,true)
}

// The pose of every body of the breakable, the one it was created as first, written to `out`; returns
// how many there are.
breakable_poses :: proc(w:^World,h:Breakable_Handle,out:[]Breakable_Pose) -> int {
    d,_:=breakable_read(w,h)
    if d==nil {return 0}
    s:=&w.breaking
    mark:=break_mark(s)
    s.marks[body_slot(d.body)]=mark
    pose :: proc(w:^World,body:Body_Handle,group:u32,remaining:u32) -> Breakable_Pose {
        xf:=body_transform(w,body)
        return {rotation=xf.q,position=xf.p,group=group,linear=body_linear_velocity(w,body),angular=body_angular_velocity(w,body),remaining=remaining}
    }
    if len(out)>0 {out[0]=pose(w,d.body,0,max(u32))}
    count:=1
    for slot:=d.piece_list;slot>=0;slot=w.pieces[slot].next {
        piece:=&w.pieces[slot]
        body:=shape_body(w,piece.shape)
        if body=={} || s.marks[body_slot(body)]==mark {continue}
        s.marks[body_slot(body)]=mark
        if count<len(out) {
            remaining:=max(u32)
            if piece.expire!=max(u64) {remaining=u32(min(u64(max(u32)-1),piece.expire>w.tick?piece.expire-w.tick:0))}
            out[count]=pose(w,body,piece.group,remaining)
        }
        count+=1
    }
    return count
}

// Puts each body of the breakable where the pose of its group says, with its velocities, and the pieces
// of a group that expires that many steps from their end; a body without a pose, or static, stays as it
// is. hold keeps them there from now on: held (body_hold) at rest, taking no hits and not expiring, for
// the next poses to move them, as a replay of a recording of the breakable does; let go, they have their
// own type again, with the velocities of these poses, unless something else holds them. False, with
// nothing changed, for a value that is not finite.
breakable_poses_apply :: proc(w:^World,h:Breakable_Handle,poses:[]Breakable_Pose,hold:bool) -> bool {
    d,_:=breakable_get(w,h)
    if d==nil {return false}
    for p in poses {
        if !finite(p.position) || !finite(p.rotation) || !finite(p.linear,p.angular) {return false}
    }
    s:=&w.breaking
    if hold!=(.Held in d.flags) {
        break_hold(w,d,hold)
        if hold {d.flags+={.Held}} else {d.flags-={.Held}}
    }
    mark:=break_mark(s)
    for slot:=d.piece_list;slot>=0;slot=w.pieces[slot].next {
        piece:=&w.pieces[slot]
        body:=shape_body(w,piece.shape)
        if body=={} {continue}
        at:=body_slot(body)
        if s.marks[at]!=mark {
            s.marks[at],s.keeper[at]=mark,-1
            for p,k in poses {
                if p.group==piece.group {s.keeper[at]=i32(k);break}
            }
            if k:=s.keeper[at];k>=0 && body_type(w,body)!=.Static {
                p:=poses[k]
                moving:=!hold && body_type(w,body)==body_own_type(w,body) // what else holds it keeps it at rest
                body_set_transform(w,body,p.position,p.rotation==0?QUAT_IDENTITY:p.rotation)
                body_set_velocity(w,body,moving?p.linear:{},moving?p.angular:{})
            }
        }
        if k:=s.keeper[at];k>=0 && piece.group!=0 && piece.expire!=max(u64) && poses[k].remaining!=max(u32) {
            piece.expire=w.tick+u64(poses[k].remaining)
        }
    }
    return true
}

// The poses between two lists of the poses of one breakable, at t from 0 (from) to 1 (to), into `out`: a
// group in both goes between them, and one in only one of them is where that one says. Returns how many
// there are.
breakable_poses_blend :: proc(from,to:[]Breakable_Pose,t:f32,out:[]Breakable_Pose) -> int {
    t:=t
    if !(t>0) {t=0} else if t>1 {t=1}
    count:=0
    for b in to {
        p:=b
        for a in from {
            if a.group!=b.group {continue}
            p.position=a.position+(b.position-a.position)*t
            p.rotation=math.quat_slerp(a.rotation==0?QUAT_IDENTITY:a.rotation,b.rotation==0?QUAT_IDENTITY:b.rotation,t)
            p.linear,p.angular=a.linear+(b.linear-a.linear)*t,a.angular+(b.angular-a.angular)*t
            if a.remaining==max(u32) || b.remaining==max(u32) {
                p.remaining=t<0.5?a.remaining:b.remaining
            } else {
                p.remaining=u32(f64(a.remaining)+(f64(b.remaining)-f64(a.remaining))*f64(t)+0.5)
            }
            break
        }
        if count<len(out) {out[count]=p}
        count+=1
    }
    for a in from {
        alone:=true
        for b in to {alone&&=a.group!=b.group}
        if !alone {continue}
        if count<len(out) {out[count]=a}
        count+=1
    }
    return count
}
