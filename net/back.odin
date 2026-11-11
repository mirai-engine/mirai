package mirai_net

import "core:mem"
import "mirai:std/base"
import "mirai:std/serial"

// Network half of replication.
//
// The server keeps one canonical quantized state per object, shared by every
// connection, and per connection and object a link: where the replica is in
// its life on that connection, which fields it still has to receive (dirty)
// and up to two baselines, copies of the state both ends are known to share.
// An update carries the dirty fields, each written as its difference to the
// active baseline. Now and then an update also asks the receiver to keep the
// result as a new baseline; it then carries every field changed since the
// active one, so both ends hold the same words once it is acknowledged.
// What was in a lost datagram becomes dirty again.
//
// A client keeps the replicas it was sent, and runs the same writer towards
// the server for the objects whose authority it holds.

@(private) System_Message :: enum u8 {Event,Authority_Request,Authority_Release}
@(private) Link :: enum u8 {None,Pending_Create,Creating,Created,Pending_Destroy,Destroying}
@(private) LINK_ROLE :: 1 // the role has to be sent
@(private) LINK_FULL :: 2 // the whole state has to be sent, even to the holder of the authority
@(private) LINK_RETYPE :: 4 // the replica the connection has, or is being sent, is of the type before: it takes the creation again
@(private) LINK_TICK :: 8 // a message about the object went out: an update with the whole state follows it, changed or not
@(private) GENERATION_WIDTHS :: [4]u8{4,8,16,32}
@(private) BASELINES_LOOSE :: 3
@(private) FILL_TRIES :: 10    // objects behind one that did not fit that may fail to fit too before the datagram is closed
@(private) FILL_MIN_BITS :: 64 // left in the update below which none is tried

// Blocks of words named by an id. A freed block leaves a hole that the next block of its size takes; a
// block that finds neither a hole nor room at the top first slides every live block down. The pool never
// fragments: an allocation fails only when the live blocks and the new one exceed its words.
@(private) POOL_HOLE :: u32(1)<<31
@(private)
Word_Pool :: struct {
    words:[]u32,  // per block a header, its id or POOL_HOLE|size, and then its words
    at:[]u32,     // per id, where its words start plus one; zero without a block
    size:[]u16,   // per id, its words
    free:[MAX_STATE_WORDS+1]u32, // per size, the header of a hole plus one; the hole names the next in its first word
    top,used:int, // used: words of the live blocks, headers included
}
@(private)
pool_init :: proc(h:^Host,pool:^Word_Pool,words,ids:int) {
    pool.words=host_make(h,u32,words)
    pool.at=host_make(h,u32,ids)
    pool.size=host_make(h,u16,ids)
}
@(private)
pool_destroy :: proc(pool:^Word_Pool,a:mem.Allocator) {delete(pool.words,a);delete(pool.at,a);delete(pool.size,a)}
@(private)
pool_reset :: proc(pool:^Word_Pool) {
    mem.zero_slice(pool.at)
    pool.top,pool.used,pool.free=0,0,{}
}
@(private)
pool_alloc :: proc(pool:^Word_Pool,id,count:int) -> bool {
    if count<=0 || count>MAX_STATE_WORDS || pool.at[id]!=0 {return false}
    header:int
    if hole:=pool.free[count];hole!=0 {
        header=int(hole-1)
        pool.free[count]=pool.words[header+1]
    } else {
        if pool.top+count+1>len(pool.words) {
            if pool.used+count+1>len(pool.words) {return false}
            pool_compact(pool)
        }
        header=pool.top
        pool.top+=count+1
    }
    pool.words[header]=u32(id)
    pool.at[id],pool.size[id]=u32(header+2),u16(count)
    pool.used+=count+1
    return true
}
@(private)
pool_free :: proc(pool:^Word_Pool,id:int) {
    at:=int(pool.at[id])
    if at==0 {return}
    count:=int(pool.size[id])
    header:=at-2
    pool.at[id]=0
    pool.used-=count+1
    if header+count+1==pool.top {pool.top=header;return}
    pool.words[header]=POOL_HOLE|u32(count)
    pool.words[header+1]=pool.free[count]
    pool.free[count]=u32(header+1)
}
@(private)
pool_compact :: proc(pool:^Word_Pool) {
    to:=0
    for from:=0;from<pool.top; {
        header:=pool.words[from]
        if header&POOL_HOLE!=0 {
            from+=1+int(header&~POOL_HOLE)
            continue
        }
        count:=1+int(pool.size[header])
        if to!=from {mem.copy(&pool.words[to],&pool.words[from],count*4)}
        pool.at[header]=u32(to+2)
        to+=count
        from+=count
    }
    pool.top,pool.free=to,{}
}
@(private)
pool_has :: #force_inline proc "contextless" (pool:^Word_Pool,id:int) -> bool {return pool.at[id]!=0}
@(private)
pool_words :: #force_inline proc "contextless" (pool:^Word_Pool,id:int) -> []u32 {return pool.words[pool.at[id]-1:][:pool.size[id]]}

@(private)
Repl :: struct {
    protocol:^Protocol,
    server:bool,
    max,high:int,
    index_bits,kind_bits,peer_words:int, // kind_bits: of a fragment of the protocol
    // The quantized state of each object (id: the object), and the baselines: on a server, blocks shared by
    // the links that took them, named by ids of base_free; on a client, two per replica (id: object*2+slot).
    states,bases:Word_Pool,
    base_refs:[]u16,  // server, per baseline: links holding it as active or pending
    base_free:[]u32,
    base_free_count:int,
    base_count:[]u16, // server, per object: its baselines
    fresh:[]u32,      // server, per object: the baseline plus one that holds its current state, zero if none
    state_failures,baseline_failures:u64,
    // Per object. live: 0 free, 1 alive, 2 destroyed and waiting for its connections.
    live:[]u8,
    generation:[]u32,
    type:[]Type_Id,
    type_before:[]Type_Id, // server, per object: the one before it was last retyped; what an older epoch still sends is of it
    simulation:[]Simulation,
    role:[]Role, // client
    epoch:[]u8,
    owner,holder:[]Connection,
    priority,radius:[]f32,
    position:[][3]f32,
    nonzero:[]u64,
    filter:[]Filter,
    auto:[]bool,
    groups:[]Groups, // server, per object: a connection must have one of them to see it; none: of no group
    visibility:[]u32, // server, per object: a connection must share a bit with it to see it; 0: any
    parent:[]u32,
    refs:[]u16,
    lease:[]u32,
    watchers:[]u64, // per object, the connections that track its changes
    always:[]u64,
    held:int,
    scope_stale:bool,
    grid:base.Hash_Map(i32), // cell key -> the first object of the cell; only cells with objects are in it
    grid_next,grid_prev:[]i32,
    grid_cell:[]u64,         // per object, the key of its cell while grid_listed
    grid_listed:[]bool,
    grid_dirty:[]u64,
    grid_pending,radius_stale:bool,
    grid_updates:u64,
    wanted:[]u64,
    keys:[]u64,
    key_count,key_cursor:int,
    key_overflow,key_wrote:bool,
    special,dying:[]u32,
    special_count,dying_count:int,
    special_stale:bool,
    max_radius:f32,
    words,previous:[MAX_STATE_WORDS]u32,
    type_stats:[]Type_Stats,
    object_bits,shared_bits:[]u64,
    remote_tick:u32,
    ticks_since_send:int,
    events:Byte_Ring,   // client: reliable events about replicas that have not arrived yet
    deferred:Byte_Ring, // server: events waiting for the next evaluation of scope
}

@(private)
Peer_Repl :: struct {
    link:[]Link,
    flags,active,pending,away:[]u8,
    request:[]u8, // counts the baselines the link asked for: an acknowledgement settles only the one it carries
    flight:[]u16,
    dirty,since_base,since_pending:[]u64,
    base:[2][]u32, // per slot of the receiver, the baseline plus one
    base_tick:[]u32,
    accum:[]f64,
    scope,work,done:[]u64,
    visibility:u32, // the visibility bits it has
    groups:[]u64,   // the groups it has, by number
    position:[3]f32,
    view_radius:f32,
    has_view:bool,
    everywhere:bool, // the view has no edge
    filter_tick:u32,
    filter_due:bool,
    held:bool,       // it sees no object until it is let go
    inputs:[]u32,
    input_ticks:[INPUT_RING]u32,
    input_newest,input_acked,input_sent:u32,
    input_any,input_has_ack:bool,
    in_scope:u32,
}

@(private)
back_init :: proc(h:^Host) -> Error {
    r:=&h.back.repl
    d:=h.desc.replication
    protocol:=h.desc.protocol
    n:=d.max_objects
    r.protocol,r.server,r.max=protocol,h.desc.mode==.Server,n
    r.index_bits=max(serial.bit_count_for(u64(n-1)),1)
    r.kind_bits=max(serial.bit_count_for(u64(max(len(protocol.fragments),1)-1)),1)
    r.peer_words=(h.desc.max_connections+63)/64
    pool_init(h,&r.states,d.state_words,n)
    if r.server {
        smallest:=protocol.smallest_words
        ids:=d.baseline_words/(smallest+1)
        pool_init(h,&r.bases,d.baseline_words,ids)
        r.base_refs=host_make(h,u16,ids);r.base_free=host_make(h,u32,ids);r.fresh=host_make(h,u32,n);r.base_count=host_make(h,u16,n)
        for &id,i in r.base_free {id=u32(ids-1-i)}
        r.base_free_count=ids
    } else {
        pool_init(h,&r.bases,d.baseline_words,n*2)
    }
    r.live=host_make(h,u8,n);r.generation=host_make(h,u32,n);r.type=host_make(h,Type_Id,n);r.type_before=host_make(h,Type_Id,n)
    r.simulation=host_make(h,Simulation,n);r.role=host_make(h,Role,n);r.epoch=host_make(h,u8,n)
    r.type_stats=host_make(h,Type_Stats,TYPE_CAPACITY)
    if d.object_stats {r.object_bits=host_make(h,u64,n);r.shared_bits=host_make(h,u64,n)}
    if r.server {
        r.owner=host_make(h,Connection,n);r.holder=host_make(h,Connection,n)
        r.priority=host_make(h,f32,n);r.radius=host_make(h,f32,n);r.position=host_make(h,[3]f32,n)
        r.nonzero=host_make(h,u64,n);r.filter=host_make(h,Filter,n);r.auto=host_make(h,bool,n);r.groups=host_make(h,Groups,n)
        r.visibility=host_make(h,u32,n)
        r.parent=host_make(h,u32,n);r.refs=host_make(h,u16,n);r.lease=host_make(h,u32,n)
        r.watchers=host_make(h,u64,n*r.peer_words)
        r.always=host_make(h,u64,(n+63)/64);r.wanted=host_make(h,u64,(n+63)/64)
        if !base.hash_map_init(&r.grid,max(n,1),h.allocator) {h.failed=true}
        r.grid_next=host_make(h,i32,n);r.grid_prev=host_make(h,i32,n)
        r.grid_cell=host_make(h,u64,n);r.grid_listed=host_make(h,bool,n)
        r.grid_dirty=host_make(h,u64,(n+63)/64)
        for &next in r.grid_next {next=-1}
        for &prev in r.grid_prev {prev=-1}
        r.keys=host_make(h,u64,d.max_updates);r.special=host_make(h,u32,n);r.dying=host_make(h,u32,n)
        r.deferred.data=host_make(h,u8,64<<10)
    } else {
        r.events.data=host_make(h,u8,16<<10)
    }
    largest,largest_event:=0,0
    largest=protocol.object_words
    for event in protocol.events {largest_event=max(largest_event,event.desc.words)}
    entries:=PACKET_BYTES*8/(r.index_bits+6)
    h.back.reserve_bytes+=entries*(largest*4+8)+(PACKET_BYTES/11+1)*(largest_event*4+8)+8*(protocol.input.words*4+8)
    h.back.reserve_count+=entries+8
    return .None
}
@(private)
back_destroy :: proc(h:^Host) {
    r:=&h.back.repl
    a:=h.allocator
    pool_destroy(&r.states,a);pool_destroy(&r.bases,a);delete(r.base_refs,a);delete(r.base_free,a);delete(r.fresh,a);delete(r.base_count,a)
    delete(r.live,a);delete(r.generation,a);delete(r.type,a);delete(r.type_before,a);delete(r.simulation,a);delete(r.role,a)
    delete(r.epoch,a);delete(r.type_stats,a);delete(r.object_bits,a);delete(r.shared_bits,a);delete(r.owner,a);delete(r.holder,a)
    delete(r.priority,a);delete(r.radius,a);delete(r.position,a);delete(r.nonzero,a);delete(r.filter,a);delete(r.auto,a);delete(r.groups,a);delete(r.visibility,a)
    delete(r.parent,a);delete(r.refs,a);delete(r.lease,a);delete(r.watchers,a);delete(r.always,a);delete(r.wanted,a)
    base.hash_map_destroy(&r.grid);delete(r.grid_next,a);delete(r.grid_prev,a);delete(r.grid_cell,a);delete(r.grid_listed,a);delete(r.grid_dirty,a)
    delete(r.keys,a);delete(r.events.data,a);delete(r.special,a);delete(r.dying,a);delete(r.deferred.data,a)
}

@(private)
repl_peer_allocate :: proc(h:^Host,p:^Peer) {
    pr:=&p.repl
    n:=h.desc.replication.max_objects
    sets:=(n+63)/64
    pr.link=host_make(h,Link,n);pr.flags=host_make(h,u8,n);pr.dirty=host_make(h,u64,n);pr.work=host_make(h,u64,sets)
    if h.desc.mode==.Server {
        pr.active=host_make(h,u8,n);pr.pending=host_make(h,u8,n);pr.away=host_make(h,u8,n);pr.request=host_make(h,u8,n);pr.flight=host_make(h,u16,n)
        pr.since_base=host_make(h,u64,n);pr.since_pending=host_make(h,u64,n)
        pr.base[0]=host_make(h,u32,n);pr.base[1]=host_make(h,u32,n);pr.base_tick=host_make(h,u32,n);pr.accum=host_make(h,f64,n)
        pr.scope=host_make(h,u64,sets);pr.done=host_make(h,u64,sets)
        pr.groups=host_make(h,u64,(h.desc.replication.groups+64)/64)
    } else if h.desc.protocol.has_input {
        pr.inputs=host_make(h,u32,INPUT_RING*h.desc.protocol.input.words)
    }
}
@(private)
repl_peer_release :: proc(h:^Host,p:^Peer) {
    pr:=&p.repl
    a:=h.allocator
    delete(pr.link,a);delete(pr.flags,a);delete(pr.dirty,a);delete(pr.work,a);delete(pr.active,a);delete(pr.pending,a);delete(pr.away,a);delete(pr.request,a)
    delete(pr.flight,a);delete(pr.since_base,a);delete(pr.since_pending,a);delete(pr.base[0],a);delete(pr.base[1],a)
    delete(pr.base_tick,a);delete(pr.accum,a);delete(pr.scope,a);delete(pr.done,a)
    delete(pr.inputs,a);delete(pr.groups,a)
}

@(private)
repl_peer_connected :: proc(h:^Host,p:^Peer) {
    if h.desc.protocol==nil {return}
    pr:=&p.repl
    mem.zero_slice(pr.link);mem.zero_slice(pr.flags);mem.zero_slice(pr.dirty);mem.zero_slice(pr.work)
    mem.zero_slice(pr.active);mem.zero_slice(pr.pending);mem.zero_slice(pr.away);mem.zero_slice(pr.since_base)
    mem.zero_slice(pr.since_pending);mem.zero_slice(pr.base[0]);mem.zero_slice(pr.base[1]);mem.zero_slice(pr.accum)
    mem.zero_slice(pr.scope);mem.zero_slice(pr.done);mem.zero_slice(pr.groups)
    pr.position,pr.view_radius,pr.has_view,pr.everywhere,pr.visibility={},0,false,false,0
    pr.filter_due,pr.in_scope=true,0
    pr.held=h.desc.hold
    pr.input_ticks={}
    pr.input_newest,pr.input_acked,pr.input_sent,pr.input_any,pr.input_has_ack=0,0,0,false,false
}

@(private)
repl_peer_disconnected :: proc(h:^Host,p:^Peer) {
    if h.desc.protocol==nil {return}
    r:=&h.back.repl
    pr:=&p.repl
    if !r.server {
        mem.zero_slice(r.live)
        pool_reset(&r.states);pool_reset(&r.bases)
        r.events.head,r.events.used=0,0
        return
    }
    handle:=peer_handle(h,p)
    for o in 0..<r.high {
        if pr.link[o]!=.None {link_clear(h,p,o)}
        if r.holder[o]==handle {authority_set(h,o,0,0)}
        if r.owner[o]==handle {r.owner[o]=0}
    }
}

@(private)
object_from :: proc(r:^Repl,handle:u64) -> (int,bool) {
    index:=int(base.handle_index(base.Handle(handle)))
    if handle==0 || index>=r.max || r.live[index]!=1 || r.generation[index]!=base.handle_generation(base.Handle(handle)) {return 0,false}
    return index,true
}
@(private)
object_handle :: #force_inline proc(r:^Repl,o:int) -> Object {return Object(base.handle_make(u32(o),r.generation[o]))}

@(private)
slot_release :: proc(h:^Host,o:int) {
    r:=&h.back.repl
    out:=h.back.outbox
    pool_free(&r.states,o)
    r.live[o]=0
    out.released[out.released_count]=u32(o)
    out.released_count+=1
}

// A baseline of the current state of o, shared with every link that takes one before the state changes.
@(private)
baseline_take :: proc(r:^Repl,o:int) -> u32 {
    if fresh:=r.fresh[o];fresh!=0 {
        r.base_refs[fresh-1]+=1
        return fresh
    }
    if r.base_free_count==0 {r.baseline_failures+=1;return 0}
    id:=int(r.base_free[r.base_free_count-1])
    if !pool_alloc(&r.bases,id,r.protocol.types[r.type[o]].words) {r.baseline_failures+=1;return 0}
    r.base_free_count-=1
    copy(pool_words(&r.bases,id),pool_words(&r.states,o))
    r.base_refs[id]=1
    r.base_count[o]+=1
    r.fresh[o]=u32(id+1)
    return u32(id+1)
}
@(private)
baseline_release :: proc(r:^Repl,o:int,base:u32) {
    if base==0 {return}
    id:=int(base-1)
    r.base_refs[id]-=1
    if r.base_refs[id]>0 {return}
    pool_free(&r.bases,id)
    r.base_count[o]-=1
    r.base_free[r.base_free_count]=u32(id)
    r.base_free_count+=1
    if r.fresh[o]==base {r.fresh[o]=0}
}
@(private)
baselines_drop :: proc(r:^Repl,pr:^Peer_Repl,o:int) {
    for &slots in pr.base {
        baseline_release(r,o,slots[o])
        slots[o]=0
    }
    pr.active[o],pr.pending[o]=0,0
}

// The connection forgets the object. A destroyed object whose last connection forgot it frees its slot.
@(private)
link_clear :: proc(h:^Host,p:^Peer,o:int) {
    r:=&h.back.repl
    pr:=&p.repl
    baselines_drop(r,pr,o)
    r.watchers[o*r.peer_words+int(p.index)>>6]&~=1<<(p.index&63)
    bitset_clear(pr.work,o)
    pr.link[o],pr.flags[o],pr.dirty[o]=.None,0,0
    r.refs[o]-=1
    if r.live[o]==2 && r.refs[o]==0 {slot_release(h,o)}
}

@(private)
peer_owns :: #force_inline proc(h:^Host,p:^Peer,o:int) -> bool {return h.back.repl.owner[o]==peer_handle(h,p)}
@(private)
peer_role :: proc(h:^Host,p:^Peer,o:int) -> Role {
    r:=&h.back.repl
    handle:=peer_handle(h,p)
    return r.holder[o]==handle?.Held:r.owner[o]==handle?.Predicted:.Shown
}

// Moves the link towards what the connection should have: the replica if the
// object is alive and in scope, nothing otherwise. Links with a datagram in
// flight wait for its fate.
@(private)
link_sync :: proc(h:^Host,p:^Peer,o:int) {
    r:=&h.back.repl
    pr:=&p.repl
    wanted:=r.live[o]==1 && pool_has(&r.states,o) && bitset_test(pr.scope,o) && !bitset_test(pr.done,o)
    if r.live[o]==2 && r.simulation[o]==.Each && pr.link[o]==.Pending_Create {wanted=true}
    type:=&r.protocol.types[r.type[o]]
    switch pr.link[o] {
    case .None:
        if wanted {
            pr.link[o],pr.accum[o]=.Pending_Create,0
            r.refs[o]+=1
            bitset_set(pr.work,o)
        }
    case .Pending_Create:
        if !wanted {link_clear(h,p,o)}
    case .Creating,.Destroying:
    case .Created:
        if !wanted {
            baselines_drop(r,pr,o)
            r.watchers[o*r.peer_words+int(p.index)>>6]&~=1<<(p.index&63)
            pr.link[o]=.Pending_Destroy
            bitset_set(pr.work,o)
        } else if pr.flags[o]!=0 || pr.dirty[o]&(peer_owns(h,p,o)?type.owner:type.others)!=0 {
            bitset_set(pr.work,o)
        }
    case .Pending_Destroy:
        if wanted && pr.flags[o]&LINK_RETYPE!=0 {
            pr.link[o],pr.flags[o],pr.dirty[o],pr.accum[o]=.Pending_Create,0,0,0
        } else if wanted {
            pr.link[o]=.Created
            r.watchers[o*r.peer_words+int(p.index)>>6]|=1<<(p.index&63)
            pr.dirty[o],pr.flags[o]=type.all,LINK_ROLE|LINK_FULL
        }
        bitset_set(pr.work,o)
    }
}

// The replica the connection has is of the type the object had before: it
// takes the creation again, which carries the type, or goes when the
// connection should not have it.
@(private)
link_retype :: proc(h:^Host,p:^Peer,o:int) {
    r:=&h.back.repl
    pr:=&p.repl
    baselines_drop(r,pr,o)
    r.watchers[o*r.peer_words+int(p.index)>>6]&~=1<<(p.index&63)
    wanted:=r.live[o]==1 && pool_has(&r.states,o) && bitset_test(pr.scope,o) && !bitset_test(pr.done,o)
    pr.link[o],pr.flags[o],pr.dirty[o],pr.accum[o]=wanted?.Pending_Create:.Pending_Destroy,wanted?0:LINK_RETYPE,0,0
    bitset_set(pr.work,o)
}

// What the connection is to the object changed: send the role and everything it may now see.
@(private)
link_role_changed :: proc(h:^Host,p:^Peer,o:int,full:bool) {
    r:=&h.back.repl
    pr:=&p.repl
    if pr.link[o]!=.Creating && pr.link[o]!=.Created {return}
    baselines_drop(r,pr,o)
    pr.dirty[o]=r.protocol.types[r.type[o]].all
    pr.flags[o]|=full?LINK_ROLE|LINK_FULL:LINK_ROLE
    if pr.link[o]==.Created {bitset_set(pr.work,o)}
}

// Fields in mask changed in the canonical state of o.
@(private)
object_changed :: proc(h:^Host,o:int,mask:u64) {
    r:=&h.back.repl
    r.fresh[o]=0
    for word in 0..<r.peer_words {
        for rest:=r.watchers[o*r.peer_words+word];rest!=0;rest&=rest-1 {
            p:=&h.back.peers[word*64+bitset_first(rest)]
            pr:=&p.repl
            pr.dirty[o]|=mask
            pr.since_base[o]|=mask
            pr.since_pending[o]|=mask
            if pr.link[o]==.Created && r.holder[o]!=peer_handle(h,p) {bitset_set(pr.work,o)}
        }
    }
}

@(private)
authority_set :: proc(h:^Host,o:int,holder:Connection,lease:u32) {
    r:=&h.back.repl
    previous:=r.holder[o]
    if previous==holder {
        if holder!=0 {r.lease[o]=r_lease(h,lease)}
        return
    }
    if previous!=0 {r.held-=1}
    if holder!=0 {r.held+=1}
    r.holder[o]=holder
    r.epoch[o]=(r.epoch[o]+1)&15
    r.lease[o]=r_lease(h,lease)
    if p:=peer_from(h,previous);p!=nil {link_role_changed(h,p,o,false)}
    if p:=peer_from(h,holder);p!=nil {link_role_changed(h,p,o,true)}
    command_push(h,{kind=.Authority_Changed,object=object_handle(r,o),connection=holder})
}
@(private)
r_lease :: #force_inline proc(h:^Host,ticks:u32) -> u32 {
    return h.back.tick+(ticks==0?u32(h.desc.replication.lease_ticks):ticks)
}

@(private)
repl_op :: proc(h:^Host,frame:^Frame,op:^Op) {
    b:=&h.back
    r:=&b.repl
    if r.protocol==nil {return}
    #partial switch op.kind {
    case .Object_Create:
        data:=op_data(frame,op)
        payload:Create_Payload
        mem.copy(&payload,raw_data(data),size_of(Create_Payload))
        o:=int(base.handle_index(base.Handle(op.handle)))
        type:=&r.protocol.types[payload.type]
        r.live[o],r.generation[o],r.type[o]=1,base.handle_generation(base.Handle(op.handle)),payload.type
        r.type_before[o]=payload.type
        r.simulation[o],r.owner[o],r.holder[o],r.epoch[o],r.lease[o]=payload.simulation,payload.owner,0,0,0
        r.priority[o],r.radius[o],r.position[o],r.filter[o]=payload.priority,payload.radius,payload.position,payload.filter
        r.auto[o],r.refs[o]=payload.auto,0
        r.groups[o],r.visibility[o]=payload.groups,payload.visibility
        r.parent[o]=0
        if parent,ok:=object_from(r,u64(payload.parent));ok {r.parent[o]=u32(parent)+1}
        r.fresh[o]=0
        if !pool_alloc(&r.states,o,type.words) {
            r.state_failures+=1
        } else {
            words:=pool_words(&r.states,o)
            mem.copy(raw_data(words),raw_data(data[offset_of(Create_Buffer,words):]),type.words*4)
            r.nonzero[o]=state_nonzero(type,words)
        }
        if payload.filter==.Always {bitset_set(r.always,o)}
        if len(r.object_bits)>0 {r.object_bits[o]=0}
        for &p in b.peers {
            if p.state==.Connected {bitset_clear(p.repl.done,o);bitset_clear(p.repl.scope,o)}
        }
        r.high=max(r.high,o+1)
        grid_mark(r,o)
        r.radius_stale=true
        r.scope_stale,r.special_stale=true,true
    case .Object_Retype:
        o,ok:=object_from(r,op.handle)
        if !ok || !r.server {return}
        data:=op_data(frame,op)
        payload:Create_Payload
        mem.copy(&payload,raw_data(data),size_of(Create_Payload))
        type:=&r.protocol.types[payload.type]
        // Whoever held it simulates the type before: the server takes it back, and
        // the epoch tells apart what that client still sends.
        if r.holder[o]!=0 {authority_set(h,o,0,0)}
        r.type_before[o],r.type[o]=r.type[o],payload.type
        r.epoch[o]=(r.epoch[o]+1)&15
        r.fresh[o]=0
        pool_free(&r.states,o)
        if !pool_alloc(&r.states,o,type.words) {
            r.state_failures+=1
        } else {
            words:=pool_words(&r.states,o)
            mem.copy(raw_data(words),raw_data(data[offset_of(Create_Buffer,words):]),type.words*4)
            r.nonzero[o]=state_nonzero(type,words)
        }
        for &p in b.peers {
            if p.state!=.Connected {continue}
            #partial switch p.repl.link[o] {
            case .Created:
                link_retype(h,&p,o)
            case .Creating,.Pending_Destroy,.Destroying:
                baselines_drop(r,&p.repl,o)
                p.repl.flags[o]|=LINK_RETYPE
            }
        }
    case .Object_State:
        if r.server {
            o,ok:=object_from(r,op.handle)
            if !ok || !pool_has(&r.states,o) {return}
            type:=&r.protocol.types[r.type[o]]
            words:=pool_words(&r.states,o)
            mask:=state_merge(type,words,op,op_data(frame,op))
            if mask==0 {return}
            r.nonzero[o]=r.nonzero[o]&~mask|state_nonzero(type,words)&mask
            object_changed(h,o,mask)
        } else {
            o:=int(base.handle_index(base.Handle(op.handle)))
            p:=&b.peers[0]
            if p.state!=.Connected || o>=r.max || r.live[o]!=1 || u64(object_handle(r,o))!=op.handle || r.role[o]!=.Held {return}
            type:=&r.protocol.types[r.type[o]]
            mask:=state_merge(type,pool_words(&r.states,o),op,op_data(frame,op))
            if mask==0 {return}
            p.repl.dirty[o]|=mask
            bitset_set(p.repl.work,o)
        }
    case .Object_Destroy:
        o,ok:=object_from(r,op.handle)
        if !ok {return}
        // A Local object goes through one evaluation of scope first, so creating and destroying it at once still sends it.
        if r.simulation[o]==.Each {
            r.dying[r.dying_count]=u32(o)
            r.dying_count+=1
            r.scope_stale=true
        } else {
            object_end(h,o)
        }
    case .Object_Owner:
        o,ok:=object_from(r,op.handle)
        if !ok || r.owner[o]==Connection(op.value) {return}
        previous:=r.owner[o]
        r.owner[o]=Connection(op.value)
        if p:=peer_from(h,previous);p!=nil {link_role_changed(h,p,o,false)}
        if p:=peer_from(h,r.owner[o]);p!=nil {link_role_changed(h,p,o,false)}
        r.scope_stale,r.special_stale=true,true
    case .Object_Priority:
        if o,ok:=object_from(r,op.handle);ok {r.priority[o]=op.v[0]>0?op.v[0]:1}
    case .Object_Position:
        if o,ok:=object_from(r,op.handle);ok {
            r.position[o]={op.v[0],op.v[1],op.v[2]}
            if r.filter[o]==.Spatial {
                key:=grid_position_key(r.position[o],h.desc.replication.cell_size)
                if !r.grid_listed[o] || r.grid_cell[o]!=key {grid_mark(r,o)}
            }
        }
    case .Object_Radius:
        if o,ok:=object_from(r,op.handle);ok && r.radius[o]!=op.v[0] {
            previous:=r.radius[o]
            r.radius[o]=op.v[0]
            if r.filter[o]==.Spatial {
                if r.radius[o]>r.max_radius {r.max_radius=r.radius[o]}
                else if previous==r.max_radius {r.radius_stale=true}
                r.scope_stale=true
            }
        }
    case .Object_Filter:
        if o,ok:=object_from(r,op.handle);ok {
            r.filter[o]=Filter(op.a)
            grid_mark(r,o)
            r.radius_stale=true
            if r.filter[o]==.Always {bitset_set(r.always,o)} else {bitset_clear(r.always,o)}
            r.scope_stale,r.special_stale=true,true
        }
    case .Object_Parent:
        if o,ok:=object_from(r,op.handle);ok {
            parent,has:=object_from(r,op.value)
            r.parent[o]=has && parent!=o?u32(parent)+1:0
            r.scope_stale,r.special_stale=true,true
        }
    case .Authority_Grant:
        if o,ok:=object_from(r,op.handle);ok && r.simulation[o]==.Lent {
            holder:=Connection(op.value)
            if holder!=0 && peer_from(h,holder)==nil {return}
            authority_set(h,o,holder,op.c)
        }
    case .Hold:
        // Also while the server's clock is paused: what it sees changes now.
        if p:=peer_from(h,Connection(op.handle));p!=nil && p.repl.held!=(op.a!=0) {p.repl.held,p.repl.filter_due,b.send_pending=op.a!=0,true,true}
    case .View:
        if p:=peer_from(h,Connection(op.handle));p!=nil {
            p.repl.position,p.repl.view_radius,p.repl.has_view,p.repl.everywhere={op.v[0],op.v[1],op.v[2]},max(op.v[3],0),true,op.v[3]<0
        }
    case .Object_Visibility:
        if o,ok:=object_from(r,op.handle);ok && r.visibility[o]!=op.c {
            r.visibility[o]=op.c
            r.scope_stale,r.special_stale=true,true
        }
    case .Connection_Visibility:
        // Also while the server's clock is paused: what it sees changes now.
        if p:=peer_from(h,Connection(op.handle));p!=nil && p.repl.visibility!=op.c {p.repl.visibility,p.repl.filter_due,b.send_pending=op.c,true,true}
    case .Object_Group:
        if o,ok:=object_from(r,op.handle);ok && r.groups[o]!=transmute(Groups)op.value {
            r.groups[o]=transmute(Groups)op.value
            r.scope_stale,r.special_stale=true,true
        }
    case .Connection_Group:
        p:=peer_from(h,Connection(op.handle))
        if p==nil {return}
        if op.c==0 {mem.zero_slice(p.repl.groups)} else if op.a!=0 {bitset_set(p.repl.groups,int(op.c))} else {bitset_clear(p.repl.groups,int(op.c))}
        // Also while the server's clock is paused: what it sees changes now.
        p.repl.filter_due,b.send_pending=true,true
    case .Event:
        data:=op_data(frame,op)
        // Events sent while scope is about to change wait for it, in order: the object may be new.
        header:=[3]u64{op.handle,op.value,u64(op.a)}
        if r.server && (r.scope_stale || r.deferred.used>0) && r.deferred.used+28+len(data)<=len(r.deferred.data) {
            ring_write(&r.deferred,mem.slice_data_cast([]u8,header[:]))
            ring_write_message(&r.deferred,data)
        } else {
            event_fanout(h,op.handle,op.value,op.a,data)
        }
    case .Authority_Request,.Authority_Release:
        b.applied_all[CHANNEL_SYSTEM]+=4+AUTHORITY_MESSAGE_BYTES
        p:=&b.peers[0]
        if r.server || p.state!=.Connected {return}
        buffer:[16]u8
        w:serial.Bit_Writer
        serial.bit_writer_init(&w,buffer[:])
        serial.bit_write(&w,u64(op.kind==.Authority_Request?System_Message.Authority_Request:System_Message.Authority_Release),3)
        serial.bit_write(&w,op.handle,64)
        channel_queue(h,p,CHANNEL_SYSTEM,serial.bit_writer_flush(&w))
    case .Input:
        p:=&b.peers[0]
        if r.server || p.state!=.Connected || len(p.repl.inputs)==0 {return}
        pr:=&p.repl
        words:=r.protocol.input.words
        slot:=int(op.c%INPUT_RING)
        mem.copy(&pr.inputs[slot*words],raw_data(op_data(frame,op)),words*4)
        pr.input_ticks[slot]=op.c+1
        pr.input_newest,pr.input_any=op.c,true
    }
}

@(private)
object_end :: proc(h:^Host,o:int) {
    r:=&h.back.repl
    if r.holder[o]!=0 {r.held-=1;r.holder[o]=0}
    r.live[o]=2
    grid_mark(r,o)
    if r.radius[o]==r.max_radius {r.radius_stale=true}
    bitset_clear(r.always,o)
    for &p in h.back.peers {
        if p.state==.Connected && p.repl.link[o]!=.None {link_sync(h,&p,o)}
    }
    // The creation of a Local object still reaches whoever was about to receive it.
    if r.simulation[o]!=.Each || r.refs[o]==0 {pool_free(&r.states,o)}
    if r.refs[o]==0 {slot_release(h,o)}
}

// Copies the words an Object_State operation carries into a state and returns the change bits that differ.
@(private)
state_merge :: proc(type:^Object_Type,words:[]u32,op:^Op,data:[]u8) -> (mask:u64) {
    fragment:=int(op.a)
    first:=int(op.b)
    count:=len(data)/4
    if fragment>=type.fragment_count || first+count>type.words {return 0}
    incoming:=mem.slice_data_cast([]u32,data)
    rest:=type.fragment_bits[fragment]
    for rest!=0 {
        bit:=uint(bitset_first(rest))
        rest&=rest-1
        from:=max(int(type.bit_word[bit]),first)
        size:=min(int(type.bit_word[bit])+int(type.bit_words[bit]),first+count)-from
        if size<=0 {continue}
        target:=words[from:][:size]
        source:=incoming[from-first:][:size]
        if mem.compare_ptrs(raw_data(target),raw_data(source),size*4)!=0 {
            copy(target,source)
            mask|=1<<bit
        }
    }
    return
}

// Writes one object of a server's connection, with whatever it needs first.
// Nothing changes unless the entry fits.
@(private) Entry_Result :: enum u8 {Nothing,Wrote,Partial,No_Room,No_Budget,Blocked} // Partial: part of a large state, the rest still dirty
// Bits of a large state that fit in this datagram and the budget, after a header of at most `header` bits.
@(private)
entry_room :: proc(w:^serial.Bit_Writer,limit,header:int) -> int {
    return min(serial.bit_writer_remaining(w)-SECTION_RESERVE,limit-serial.bit_writer_bits(w))-header
}
@(private)
entry_fits :: #force_inline proc(w:^serial.Bit_Writer,limit:int) -> Entry_Result {
    if w.overflow || serial.bit_writer_remaining(w)<SECTION_RESERVE {return .No_Room}
    return serial.bit_writer_bits(w)>limit?.No_Budget:.Wrote
}
// The type of a creation, as its list of fragments: the other end composes it
// the first time it reads it.
@(private)
kinds_write :: proc(w:^serial.Bit_Writer,r:^Repl,type:^Object_Type) {
    serial.bit_write(w,u64(type.fragment_count-1),4)
    for kind in type.kinds[:type.fragment_count] {serial.bit_write(w,u64(kind),r.kind_bits)}
}
@(private)
kinds_read :: proc(rd:^serial.Bit_Reader,r:^Repl) -> (Type_Id,bool) {
    #assert(MAX_FRAGMENTS<=16)
    kinds:[MAX_FRAGMENTS]Fragment_Id
    count:=int(serial.bit_read(rd,4))+1
    for &kind in kinds[:count] {kind=Fragment_Id(serial.bit_read(rd,r.kind_bits))}
    if rd.error {return TYPE_NONE,false}
    return type_compose(r.protocol,kinds[:count])
}

@(private)
entry_write :: proc(h:^Host,p:^Peer,w:^serial.Bit_Writer,o:int,seq:u16,limit:int,depth:=0) -> Entry_Result {
    r:=&h.back.repl
    pr:=&p.repl
    d:=&h.desc.replication
    if p.record_tail-p.record_head>=u32(len(p.records)) {return .No_Room}
    type:=&r.protocol.types[r.type[o]]
    mark:=w^
    serial.bit_write(w,1,1)
    serial.bit_write(w,u64(o),r.index_bits)
    owner_mask:=peer_owns(h,p,o)?type.owner:type.others
    #partial switch pr.link[o] {
    case .Pending_Create:
        if parent:=int(r.parent[o])-1;parent>=0 {
            #partial switch pr.link[parent] {
            case .Created:
            case .Creating:
                if pr.flight[parent]!=seq {w^=mark;return .Blocked}
            case .Pending_Create:
                w^=mark
                if depth>=4 || entry_write(h,p,w,parent,seq,limit,depth+1)!=.Wrote {return .Blocked}
                return entry_write(h,p,w,o,seq,limit,depth+1)
            case:
                w^=mark
                return .Blocked
            }
        }
        words:=pool_words(&r.states,o)
        mask:=r.nonzero[o]&owner_mask
        // A large state is created with what fits; the rest follows as updates once the creation is acknowledged,
        // and the baseline waits for a whole state.
        sent:=mask
        if type.large {
            sent=state_fit(type,mask,entry_room(w,limit,96))
            if sent==0 && mask!=0 {
                w^=mark
                return serial.bit_writer_remaining(w)-SECTION_RESERVE<limit-serial.bit_writer_bits(w)?.No_Room:.No_Budget
            }
        }
        block:=d.baseline_interval>=0 && r.simulation[o]!=.Each && sent==mask?baseline_take(r,o):0
        serial.bit_write(w,1,2)
        var_write(w,r.generation[o],GENERATION_WIDTHS)
        kinds_write(w,r,type)
        serial.bit_write(w,u64(peer_role(h,p,o)),2)
        serial.bit_write(w,u64(r.simulation[o]),2)
        serial.bit_write(w,u64(r.epoch[o]),4)
        serial.bit_write_bool(w,block!=0)
        mask_write(w,type,sent)
        state_write(w,type,sent,words,nil)
        if fit:=entry_fits(w,limit);fit!=.Wrote {
            baseline_release(r,o,block)
            w^=mark
            return fit
        }
        pr.link[o],pr.flight[o]=.Creating,seq
        pr.dirty[o],pr.since_base[o],pr.since_pending[o],pr.flags[o],pr.active[o],pr.pending[o]=mask&~sent,0,0,0,0,0
        if block!=0 {
            pr.base[0][o],pr.pending[o]=block,1
            pr.request[o]+=1
        }
        r.watchers[o*r.peer_words+int(p.index)>>6]|=1<<(p.index&63)
        record_push(p,{kind=.Create,object=u32(o)})
        r.type_stats[r.type[o]].creates+=1
    case .Created:
        flags:=pr.flags[o]
        mask:=pr.dirty[o]&owner_mask
        holder:=r.holder[o]==peer_handle(h,p)
        if holder && flags&LINK_FULL==0 {mask=0}
        if mask==0 && flags&(LINK_ROLE|LINK_TICK)==0 {
            w^=mark
            pr.dirty[o]=0
            return .Nothing
        }
        active:=int(pr.active[o])
        // After a message about the object, everything changed since what the connection is known to have: the
        // replica then holds the whole state of this tick, also when an update before was lost.
        complete:=flags&LINK_TICK!=0 && !holder
        if complete {mask=active==0?owner_mask:mask|pr.since_base[o]&owner_mask}
        block:=u32(0)
        slot:=active==1?1:0
        // Once the object holds BASELINES_LOOSE blocks, links due for a new baseline take it together, to share it:
        // when one holds the current state, on the tick of the object's phase, or a whole interval late.
        interval:=u32(max(d.baseline_interval,1))
        age:=h.back.tick-pr.base_tick[o]
        if d.baseline_interval>=0 && mask!=0 && !holder && pr.pending[o]==0 && (active==0 || age>=interval &&
            (r.base_count[o]<BASELINES_LOOSE || r.fresh[o]!=0 || (h.back.tick+u32(o))%interval==0 || age>=2*interval)) {
            block=baseline_take(r,o)
            if block!=0 {mask=active==0?owner_mask:mask|pr.since_base[o]&owner_mask}
        }
        words:=pool_words(&r.states,o)
        // A large state that does not fit goes in parts: no baseline from a part, the rest stays dirty.
        rest:=u64(0)
        if type.large && mask!=0 {
            if sent:=state_fit(type,mask,entry_room(w,limit,64));sent!=mask {
                if block!=0 {
                    baseline_release(r,o,block)
                    block=0
                    mask=pr.dirty[o]&owner_mask
                    if holder && flags&LINK_FULL==0 {mask=0}
                    sent=state_fit(type,mask,entry_room(w,limit,64))
                }
                if sent==0 && mask!=0 && flags&LINK_ROLE==0 {
                    w^=mark
                    return serial.bit_writer_remaining(w)-SECTION_RESERVE<limit-serial.bit_writer_bits(w)?.No_Room:.No_Budget
                }
                rest=mask&~sent
                mask=sent
            }
        }
        complete&&=rest==0
        if flags&LINK_ROLE!=0 {
            serial.bit_write(w,1<<2|u64(peer_role(h,p,o))<<3|u64(r.epoch[o])<<5,9)
        } else {
            serial.bit_write(w,0,3)
        }
        serial.bit_write_bool(w,complete)
        serial.bit_write(w,u64(active)|u64(block!=0)<<2|u64(slot)<<3,block!=0?4:3)
        mask_write(w,type,mask)
        state_write(w,type,mask,words,active!=0?pool_words(&r.bases,int(pr.base[active-1][o]-1)):nil)
        if fit:=entry_fits(w,limit);fit!=.Wrote {
            baseline_release(r,o,block)
            w^=mark
            return fit
        }
        pr.dirty[o],pr.flags[o]=rest,rest!=0?flags&LINK_TICK:0
        if block!=0 {
            pr.base[slot][o],pr.pending[o],pr.since_pending[o]=block,u8(slot+1),0
            pr.request[o]+=1
        }
        record_push(p,{kind=.Update,flags=block!=0?u8(slot+1):0,aux=u16(flags)|u16(pr.request[o])<<8,object=u32(o),mask=mask})
        r.type_stats[r.type[o]].updates+=1
        if rest!=0 {
            bits:=u64(serial.bit_writer_bits(w)-mark.bits)
            r.type_stats[r.type[o]].bits+=bits
            if len(r.object_bits)>0 {r.object_bits[o]+=bits}
            p.stats.objects_sent+=1
            return .Partial
        }
    case .Pending_Destroy:
        serial.bit_write(w,2,2)
        serial.bit_write_bool(w,r.live[o]!=1)
        if fit:=entry_fits(w,limit);fit!=.Wrote {w^=mark;return fit}
        pr.link[o],pr.flight[o]=.Destroying,seq
        record_push(p,{kind=.Destroy,object=u32(o)})
        r.type_stats[r.type[o]].destroys+=1
    case:
        w^=mark
        return .Nothing
    }
    bits:=u64(serial.bit_writer_bits(w)-mark.bits)
    r.type_stats[r.type[o]].bits+=bits
    if len(r.object_bits)>0 {r.object_bits[o]+=bits}
    p.stats.objects_sent+=1
    return .Wrote
}

@(private)
objects_write :: proc(h:^Host,p:^Peer,w:^serial.Bit_Writer,seq:u16,budget:^int,more:^bool,last:bool) -> (wrote:bool) {
    r:=&h.back.repl
    if r.protocol==nil {return false}
    pr:=&p.repl
    start:=serial.bit_writer_bits(w)
    if r.server {
        // An object larger than the whole budget still goes out, alone, as the first of the update.
        limit:=start+(r.key_wrote?budget^:max(budget^,MAX_STATE_BYTES*8))
        starved:=false
        for budget^>0 && r.key_cursor<r.key_count && serial.bit_writer_bits(w)<start+budget^ {
            o:=int(r.keys[r.key_count-1-r.key_cursor]&KEY_OBJECT)
            result:=bitset_test(pr.work,o)?entry_write(h,p,w,o,seq,limit):.Nothing
            if result==.No_Room || result==.No_Budget {
                starved=result==.No_Budget
                // Nothing after it goes in this update, so smaller objects behind it fill what is left; it keeps
                // its priority. Another datagram of the update would start with it instead.
                if (starved || last) && objects_fill(h,p,w,seq,limit) {wrote,r.key_wrote=true,true}
                break
            }
            // A part of a large state fills the datagram: the next one goes on with the other objects, and the
            // rest waits for the next update with the priority it had, so it takes one datagram per update.
            if result==.Partial {
                wrote,r.key_wrote=true,true
                r.key_cursor+=1
                break
            }
            r.key_cursor+=1
            if result==.Blocked {continue}
            bitset_clear(pr.work,o)
            pr.accum[o]=0
            if result==.Wrote {
                wrote,r.key_wrote=true,true
                limit=start+budget^
            }
        }
        waiting:=r.key_cursor<r.key_count || r.key_overflow
        if waiting && budget^-(serial.bit_writer_bits(w)-start)<=0 {starved=true}
        more^=r.key_cursor<r.key_count && !starved
        if starved {p.stats.budget_starved+=1}
    } else {
        for word,i in pr.work {
            for rest:=word;rest!=0;rest&=rest-1 {
                o:=i*64+bitset_first(rest)
                if r.live[o]!=1 || r.role[o]!=.Held || pr.dirty[o]==0 {bitset_clear(pr.work,o);continue}
                type:=&r.protocol.types[r.type[o]]
                mark:=w^
                sent:=pr.dirty[o]
                if type.large {sent=state_fit(type,sent,serial.bit_writer_remaining(w)-SECTION_RESERVE-1-r.index_bits-4)}
                if sent==0 {more^=true;break}
                serial.bit_write(w,1,1)
                serial.bit_write(w,u64(o),r.index_bits)
                serial.bit_write(w,u64(r.epoch[o]),4)
                mask_write(w,type,sent)
                state_write(w,type,sent,pool_words(&r.states,o),nil)
                if w.overflow || serial.bit_writer_remaining(w)<SECTION_RESERVE || !record_push(p,{kind=.Update,object=u32(o),mask=sent}) {
                    w^=mark
                    more^=true
                    break
                }
                pr.dirty[o]&=~sent
                if pr.dirty[o]!=0 {
                    p.stats.objects_sent+=1
                    wrote,more^=true,true
                    break
                }
                bitset_clear(pr.work,o)
                p.stats.objects_sent+=1
                wrote=true
            }
        }
    }
    used:=serial.bit_writer_bits(w)-start
    budget^-=used
    p.stats.object_bytes_sent+=u64(used+7)/8
    serial.bit_write(w,0,1)
    return
}

// Writes the small objects after the cursor that still fit, until FILL_TRIES do not or FILL_MIN_BITS are left.
@(private)
objects_fill :: proc(h:^Host,p:^Peer,w:^serial.Bit_Writer,seq:u16,limit:int) -> (wrote:bool) {
    r:=&h.back.repl
    pr:=&p.repl
    failed:=0
    for index:=r.key_cursor+1;index<r.key_count && failed<FILL_TRIES && entry_room(w,limit,0)>=FILL_MIN_BITS;index+=1 {
        o:=int(r.keys[r.key_count-1-index]&KEY_OBJECT)
        if !bitset_test(pr.work,o) || r.protocol.types[r.type[o]].large {continue}
        result:=entry_write(h,p,w,o,seq,limit)
        if result==.No_Room || result==.No_Budget {failed+=1;continue}
        if result==.Blocked {continue}
        bitset_clear(pr.work,o)
        pr.accum[o]=0
        wrote=wrote || result==.Wrote
    }
    return
}

@(private)
repl_resolve :: proc(h:^Host,p:^Peer,record:Record,seq:u16,received:bool) {
    r:=&h.back.repl
    pr:=&p.repl
    o:=int(record.object)
    #partial switch record.kind {
    case .Input:
        if received && (!pr.input_has_ack || i32(record.object-pr.input_acked)>0) {pr.input_acked,pr.input_has_ack=record.object,true}
    case .Create:
        if pr.link[o]!=.Creating || pr.flight[o]!=seq {return}
        if !received {
            baselines_drop(r,pr,o)
            r.watchers[o*r.peer_words+int(p.index)>>6]&~=1<<(p.index&63)
            pr.link[o]=.Pending_Create
            pr.flags[o]&~=LINK_RETYPE
            bitset_set(pr.work,o)
        } else if pr.flags[o]&LINK_RETYPE!=0 {
            link_retype(h,p,o)
        } else if r.simulation[o]==.Each {
            link_clear(h,p,o)
            bitset_set(pr.done,o)
            return
        } else {
            pr.link[o]=.Created
            if pr.pending[o]!=0 {
                pr.active[o],pr.pending[o],pr.base_tick[o]=pr.pending[o],0,h.back.tick
                pr.since_base[o]=pr.since_pending[o]
            }
        }
        link_sync(h,p,o)
    case .Update:
        if pr.link[o]!=.Created {return}
        if !r.server {
            if !received {pr.dirty[o]|=record.mask;bitset_set(pr.work,o)}
            return
        }
        // A baseline the link forgot and asked for again since then is another request, even in the same slot.
        slot:=record.flags
        asked:=slot!=0 && pr.pending[o]==slot && pr.request[o]==u8(record.aux>>8)
        if received {
            if asked {
                if previous:=pr.active[o];previous!=0 && previous!=slot {
                    baseline_release(r,o,pr.base[previous-1][o])
                    pr.base[previous-1][o]=0
                }
                pr.active[o],pr.pending[o],pr.base_tick[o]=slot,0,h.back.tick
                pr.since_base[o]=pr.since_pending[o]
            }
            return
        }
        pr.dirty[o]|=record.mask
        pr.flags[o]|=u8(record.aux)
        if asked {
            baseline_release(r,o,pr.base[slot-1][o])
            pr.base[slot-1][o],pr.pending[o]=0,0
        }
        bitset_set(pr.work,o)
    case .Destroy:
        if pr.link[o]!=.Destroying || pr.flight[o]!=seq {return}
        if received {
            link_clear(h,p,o)
            if r.live[o]!=0 {link_sync(h,p,o)}
        } else {
            pr.link[o]=.Pending_Destroy
            link_sync(h,p,o)
        }
    }
}

@(private)
replica_remove :: proc(h:^Host,p:^Peer,o:int,ended:bool) {
    r:=&h.back.repl
    pr:=&p.repl
    command_push(h,{kind=.Object_Destroyed,object=object_handle(r,o),connection=peer_handle(h,p),ended=ended})
    pool_free(&r.states,o);pool_free(&r.bases,o*2);pool_free(&r.bases,o*2+1)
    r.live[o],r.role[o]=0,.None
    pr.link[o],pr.dirty[o]=.None,0
    bitset_clear(pr.work,o)
}

// False when the section cannot be parsed. A connection that runs out of room is closed here.
@(private)
objects_read :: proc(h:^Host,p:^Peer,rd:^serial.Bit_Reader) -> bool {
    r:=&h.back.repl
    if r.protocol==nil {return true}
    pr:=&p.repl
    start:=rd.position
    defer p.stats.object_bytes_received+=u64(rd.position-start+7)/8
    handle:=peer_handle(h,p)
    for serial.bit_read_bool(rd) {
        o:=int(serial.bit_read(rd,r.index_bits))
        if rd.error || o>=r.max {return false}
        p.stats.objects_received+=1
        if r.server {
            if r.live[o]==0 {return false}
            epoch:=u8(serial.bit_read(rd,4))
            // What an epoch before a retype still sends is of the type before, and is read to be dropped.
            type:=&r.protocol.types[epoch==r.epoch[o]?r.type[o]:r.type_before[o]]
            mask:=mask_read(rd,type) or_return
            scratch:=r.words[:type.words]
            current:=epoch==r.epoch[o] && r.live[o]==1 && pool_has(&r.states,o)
            if current {copy(scratch,pool_words(&r.states,o))}
            state_read(rd,type,mask,scratch,nil) or_return
            if !current || r.holder[o]!=handle {continue}
            words:=pool_words(&r.states,o)
            changed:=state_diff(type,scratch,words,mask)
            r.lease[o]=r_lease(h,0)
            if changed==0 {continue}
            copy(words,scratch)
            r.nonzero[o]=r.nonzero[o]&~changed|state_nonzero(type,words)&changed
            object_changed(h,o,changed)
            if command:=command_push(h,{kind=.Object_Updated,object=object_handle(r,o),type=r.type[o],tick=h.back.tick,mask=changed,connection=handle},nil,type.words);command!=nil {
                copy(command.words,words)
            }
            continue
        }
        switch serial.bit_read(rd,2) {
        case 1:
            generation:=var_read(rd,GENERATION_WIDTHS)
            index,known:=kinds_read(rd,r)
            role:=Role(serial.bit_read(rd,2))
            simulation:=serial.bit_read(rd,2)
            epoch:=u8(serial.bit_read(rd,4))
            keep:=serial.bit_read_bool(rd)
            if rd.error || !known || simulation>u64(max(Simulation)) || generation==0 || role==.None {return false}
            type:=&r.protocol.types[index]
            mask:=mask_read(rd,type) or_return
            scratch:=r.words[:type.words]
            mem.zero_slice(scratch)
            state_read(rd,type,mask,scratch,nil) or_return
            // The creation of a replica this end has, again: its object goes on, of this type from now on.
            retyped:=r.live[o]==1 && r.generation[o]==generation
            if retyped {
                pool_free(&r.states,o);pool_free(&r.bases,o*2);pool_free(&r.bases,o*2+1)
                pr.dirty[o]=0
                bitset_clear(pr.work,o)
            } else if r.live[o]!=0 {
                replica_remove(h,p,o,true)
            }
            stored:=pool_alloc(&r.states,o,type.words) && (!keep || pool_alloc(&r.bases,o*2,type.words))
            command:=command_push(h,{kind=.Object_Created,type=Type_Id(index),role=role,simulation=Simulation(simulation),tick=r.remote_tick,
                mask=type.all,connection=handle,object=Object(base.handle_make(u32(o),generation)),retyped=retyped},nil,type.words)
            if !stored || command==nil {
                pool_free(&r.states,o);pool_free(&r.bases,o*2)
                peer_drop(h,p,.Capacity,true)
                return true
            }
            copy(pool_words(&r.states,o),scratch)
            r.live[o],r.generation[o],r.type[o]=1,generation,Type_Id(index)
            r.role[o],r.simulation[o],r.epoch[o]=role,Simulation(simulation),epoch
            pr.link[o]=role==.Held?.Created:.None
            if keep {copy(pool_words(&r.bases,o*2),scratch)}
            copy(command.words,scratch)
            events_flush(h,p)
            if p.state!=.Connected {return true}
        case 0:
            if r.live[o]!=1 {return false}
            type:=&r.protocol.types[r.type[o]]
            role_changed:=serial.bit_read_bool(rd)
            role,epoch:=r.role[o],r.epoch[o]
            if role_changed {
                role=Role(serial.bit_read(rd,2))
                epoch=u8(serial.bit_read(rd,4))
                if role==.None {return false}
            }
            complete:=serial.bit_read_bool(rd)
            use:=int(serial.bit_read(rd,2))
            keep:=serial.bit_read_bool(rd)
            slot:=keep?int(serial.bit_read(rd,1)):0
            if rd.error || use==3 || (use!=0 && !pool_has(&r.bases,o*2+use-1)) || (keep && use==slot+1) {return false}
            mask:=mask_read(rd,type) or_return
            words:=pool_words(&r.states,o)
            state_read(rd,type,mask,words,use!=0?pool_words(&r.bases,o*2+use-1):nil) or_return
            if keep {
                if !pool_has(&r.bases,o*2+slot) && !pool_alloc(&r.bases,o*2+slot,type.words) {peer_drop(h,p,.Capacity,true);return true}
                copy(pool_words(&r.bases,o*2+slot),words)
            }
            object:=object_handle(r,o)
            if role_changed {
                r.role[o],r.epoch[o]=role,epoch
                pr.link[o]=role==.Held?.Created:.None
                if role!=.Held {pr.dirty[o]=0;bitset_clear(pr.work,o)}
                command_push(h,{kind=.Role_Changed,object=object,role=role,connection=handle})
            }
            // Without changes, the update that follows a message about the object (LINK_TICK).
            if mask!=0 || !role_changed {
                command:=command_push(h,{kind=.Object_Updated,object=object,type=r.type[o],tick=r.remote_tick,mask=mask,connection=handle,complete=complete},nil,type.words)
                if command==nil {peer_drop(h,p,.Capacity,true);return true}
                copy(command.words,words)
            }
        case 2:
            ended:=serial.bit_read_bool(rd)
            if r.live[o]==1 {replica_remove(h,p,o,ended)}
        case:
            return false
        }
    }
    return !rd.error
}

@(private)
repl_share_stats :: proc(h:^Host) {
    r:=&h.back.repl
    if r.protocol==nil {return}
    copy(h.shared_type_stats,r.type_stats)
    if len(r.object_bits)>0 {copy(r.shared_bits,r.object_bits)}
    stats:=&h.shared_stats
    stats.state_words_used,stats.baseline_words_used=r.states.used,r.bases.used
    stats.state_failures,stats.baseline_failures=r.state_failures,r.baseline_failures
}
