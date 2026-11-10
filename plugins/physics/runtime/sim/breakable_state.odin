package mirai_physics

import "core:mem"
import "mirai:std/geom"

// What a breakable has become, as data small enough to send: the cuts by their plane, the body and the
// flags of every piece, and every bond. No geometry: whoever reads it made the same breakable
// from the same description and repeats the cuts. Pieces and bonds are named by their place in the
// lists of the breakable, which is the same wherever the same events were applied.

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

// Writes what the breakable has become since it was created: its cuts, the body and the flags of
// every piece and the strain of every bond. Debris is written as gone, since it is of each world.
// Returns the bytes written; zero when `out` is too small.
breakable_state_write :: proc(w:^World,h:Breakable_Handle,out:[]u8) -> int {
    d,_:=breakable_read(w,h)
    size:=breakable_state_size(w,h)
    if d==nil || len(out)<size {return 0}
    w.breaking.tick=w.tick
    ordinals:=piece_ordinals(w,d)
    header:=Break_State_Header{pieces=u32(d.piece_count),connections=u32(d.bond_count),revision=d.revision}
    at:=size_of(Break_State_Header)
    for slot:=d.piece_list;slot>=0;slot=w.pieces[slot].next {
        piece:=&w.pieces[slot]
        origin:=w.piece_origins[slot]
        remaining:=piece.expire==max(u64)?max(u64):piece.expire>w.breaking.tick?piece.expire-w.breaking.tick:0
        record:=Break_State_Piece{remaining=remaining,parent=-1,group=piece.group,flags=piece.flags,front=u32(origin.front),normal=origin.plane,offset=origin.offset,cluster=cluster_ordinal(w,d,piece.cluster)}
        if origin.parent>=0 {record.parent=ordinals[origin.parent]} else {header.original+=1}
        if !shape_valid(w,piece.shape) || .Debris in piece.flags {record.flags+={.Gone}}
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

// Makes a breakable that is still as created what breakable_state_write described of another one
// made from the same description: the same cuts, pieces gone, bodies and strains. Every body starts in
// the frame of the breakable, at rest: whoever sent the state says where they are. False when the
// state is not of such a breakable or a capacity runs out; the breakable may then be half changed
// and is only good for breakable_destroy. A transaction that allocates.
breakable_state_apply :: proc(w:^World,h:Breakable_Handle,state:[]u8) -> bool {
    d,index:=breakable_get(w,h)
    if d==nil || d.revision!=0 || len(state)<size_of(Break_State_Header) {return false}
    header:Break_State_Header
    mem.copy(&header,raw_data(state),size_of(Break_State_Header))
    pieces,original,connections:=int(header.pieces),int(header.original),int(header.connections)
    if original!=int(d.piece_count) || pieces<original || (pieces-original)%2!=0 {return false}
    if len(state)<size_of(Break_State_Header)+pieces*size_of(Break_State_Piece)+connections*size_of(Break_State_Bond) {return false}
    if int(w.piece_count)+pieces-original>len(w.pieces) || int(w.bond_count)-int(d.bond_count)+connections>len(w.bonds) {
        w.stats.breakable_capacity_exhausted+=1
        return false
    }
    piece_record :: proc(state:[]u8,at:int) -> (record:Break_State_Piece) {
        mem.copy(&record,&state[size_of(Break_State_Header)+at*size_of(Break_State_Piece)],size_of(Break_State_Piece))
        return
    }
    bond_record :: proc(state:[]u8,pieces,at:int) -> (record:Break_State_Bond) {
        mem.copy(&record,&state[size_of(Break_State_Header)+pieces*size_of(Break_State_Piece)+at*size_of(Break_State_Bond)],size_of(Break_State_Bond))
        return
    }
    s:=&w.breaking
    w.breaking.tick=w.tick
    // The clusters are those it was made with, which keep their hulls, and come before what they hold.
    standing,clusters:=0,0
    for slot:=d.bond_list;slot>=0;slot=w.bonds[slot].next {standing+=int(.Cluster in w.bonds[slot].flags)}
    for at in 0..<connections {
        record:=bond_record(state,pieces,at)
        is_cluster:=.Cluster in record.flags
        if record.a<0 || int(record.a)>=pieces || !is_cluster && (record.b<0 || int(record.b)>=pieces) || is_cluster && record.b!=-1 ||
           record.cluster < -1 || int(record.cluster)>=clusters || !break_finite(record.area,record.strain,record.strength,record.center.x,record.center.y,record.center.z) ||
           record.area<0 || record.strain<0 || record.strength<0 || is_cluster && (at!=clusters || clusters>=len(s.ids)) {return false}
        clusters+=int(is_cluster)
    }
    if clusters!=standing {return false}
    defer break_settle(w)
    slots:=s.source // the slot of the piece at each place of the list
    count:=0
    for slot:=d.piece_list;slot>=0;slot=w.pieces[slot].next {
        slots[count]=slot
        count+=1
    }
    if pieces>original {
        // The cuts take the pieces out of their clusters.
        break_bodies(w,d)
        if !break_collide(w,index,false) {return false}
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
        for at:=original;at<pieces;at+=2 {
            front,back:=piece_record(state,at),piece_record(state,at+1)
            if front.parent<0 || int(front.parent)>=at || back.parent!=front.parent || front.front==0 || back.front!=0 {return false}
            parent:=slots[front.parent]
            if !shape_valid(w,w.pieces[parent].shape) {return false}
            halves:=piece_cut(w,index,parent,front.normal,front.offset,&slicer,&buffers,&counts,&indices) or_return
            piece_detach(w,parent)
            w.pieces[parent].flags+={.Gone}
            for half,k in halves {
                piece_append(w,d,half)
                if !piece_attach(w,half,d.body) {return false}
                slots[at+k]=half
            }
        }
    }
    // What is gone leaves, and every other piece goes to the body of its group.
    ids,made:=s.ids,s.made_body
    groups:=0
    first:=d.body
    for at in 0..<pieces {
        record:=piece_record(state,at)
        slot:=slots[at]
        piece:=&w.pieces[slot]
        piece.group=record.group
        piece.expire=record.remaining==max(u64)?max(u64):w.breaking.tick+min(record.remaining,max(u64)-w.breaking.tick)
        if .Gone in record.flags {
            s.body[slot]={}
            piece.flags+=record.flags&{.Gone,.Debris}
            continue
        }
        if !shape_valid(w,piece.shape) {return false}
        s.body[slot]=first
        if record.group==0 {continue}
        to:Body_Handle
        for id,k in ids[:groups] {
            if id==record.group {to=made[k]}
        }
        if to=={} {
            xf:=body_transform(w,d.body)
            desc:=BODY_DESC_DEFAULT
            desc.gravity_scale=d.gravity_scale
            desc.position,desc.rotation,desc.user_data=xf.p,xf.q,d.user_data
            to=body_create(w,desc)
            if to=={} {
                w.stats.breakable_capacity_exhausted+=1
                s.refused[index]+={.Bodies}
                return false
            }
            ids[groups],made[groups]=record.group,to
            groups+=1
        }
        s.body[slot]=to
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
        if record.cluster < -1 || int(record.cluster)>=clusters {return false}
        w.pieces[slots[at]].cluster=record.cluster>=0?i32(s.ids[record.cluster]):-1
    }
    d.revision=header.revision
    return break_collide(w,index,true)
}
