package exchange

import "mirai:store"
import wire "mirai:net"

@(private)
want_slot :: proc(x:^Exchange,address:store.Hash) -> int {
    mask:=len(x.want_slots)-1
    h:=int(u32(address[4])|u32(address[5])<<8|u32(address[6])<<16|u32(address[7])<<24)&mask
    for {
        k:=x.want_slots[h]
        if k<0 || x.wants[k].address==address {return h}
        h=(h+1)&mask
    }
}

@(private)
want_find :: proc(x:^Exchange,address:store.Hash) -> int {
    return int(x.want_slots[want_slot(x,address)])
}

@(private)
want_add :: proc(x:^Exchange,address:store.Hash,priority:int,measure:=false) -> (int,Error) {
    if i:=want_find(x,address);i>=0 {
        w:=&x.wants[i]
        // A want of the whole object takes over one that only measured it.
        if w.measure && !measure {
            w.measure=false
            want_begin(x,i)
            x.dirty=true
        }
        if priority>w.priority {
            w.priority=priority
            order_place(x,i)
        }
        // A want kept complete may have been swept since: success is what the store says now.
        if w.state==.Complete && !want_present(x,w) {
            want_begin(x,i)
            x.dirty=true
        }
        return i,.None
    }
    for &w,i in x.wants {
        if w.used {continue}
        generation:=w.generation+1
        w={used=true,measure=measure,generation=generation,address=address,priority=priority,order=x.sequence,first=-1,last=-1,total=-1}
        x.sequence+=1
        x.want_slots[want_slot(x,address)]=i32(i)
        x.order[x.want_count]=i
        w.rank=x.want_count
        x.want_count+=1
        order_place(x,i)
        x.dirty=true
        want_begin(x,i)
        return i,.None
    }
    return -1,.Full
}

// Whether the root of a complete want is still in the store.
@(private)
want_present :: proc(x:^Exchange,w:^Want) -> bool {
    return store.chunk_has(x.desc.store,w.address)
}

// From what this store value knows now, without reading its root again: an
// object whose root is here walked from it by a job, or nothing. What another process committed since is fetched again, harmlessly.
@(private)
want_begin :: proc(x:^Exchange,i:int) {
    needs_clear(x,i)
    w:=&x.wants[i]
    if w.settling {x.settling-=1}
    // Results of jobs for what the want was are not taken.
    w.generation+=1
    w.state,w.total,w.here=.Asking,-1,0
    w.walking,w.walked,w.blocked,w.walk_job,w.shared,w.depth=false,false,false,false,false,0
    w.settling,w.committing=false,false
    if w.rootless {
        w.rootless=false
        x.rootless-=1
    }
    order_place(x,i)
    if store.chunk_here(x.desc.store,w.address) {
        // Its owner reads the size of a root here from the store.
        if !w.measure {want_walk_root(x,i)}
        return
    }
    if !need_add(x,i,.Root,w.address,0,0) {
        w.rootless=true
        x.rootless+=1
    }
}

// Starts the walk of a want at its root, which is here: a job reads it.
@(private)
want_walk_root :: proc(x:^Exchange,i:int) {
    w:=&x.wants[i]
    w.walking,w.walked,w.blocked,w.depth=true,false,false,1
    w.stack[0]={address=w.address}
    attend(x,i)
}

@(private)
want_release :: proc(x:^Exchange,i:int) {
    needs_clear(x,i)
    w:=&x.wants[i]
    if w.rootless {
        w.rootless=false
        x.rootless-=1
    }
    if w.settling {
        w.settling=false
        x.settling-=1
    }
    w.used=false
    // The slot leaves the index: entries after it that probed past it move back.
    mask:=len(x.want_slots)-1
    hole:=want_slot(x,w.address)
    j:=hole
    for {
        j=(j+1)&mask
        m:=x.want_slots[j]
        if m<0 {break}
        a:=x.wants[m].address
        home:=int(u32(a[4])|u32(a[5])<<8|u32(a[6])<<16|u32(a[7])<<24)&mask
        if (j>hole && (home<=hole || home>j)) || (j<hole && home<=hole && home>j) {
            x.want_slots[hole]=m
            hole=j
        }
    }
    x.want_slots[hole]=-1
    k:=w.rank
    copy(x.order[k:x.want_count-1],x.order[k+1:x.want_count])
    x.want_count-=1
    for j in k..<x.want_count {x.wants[x.order[j]].rank=j}
}

// Puts want i where it goes in the order: the open ones first, most
// important first (higher priority, then asked earlier), then the closed.
@(private)
order_place :: proc(x:^Exchange,i:int) {
    order:=x.order[:x.want_count]
    at:=x.wants[i].rank
    for at>0 && want_before(x,i,order[at-1]) {
        order[at]=order[at-1]
        x.wants[order[at]].rank=at
        at-=1
    }
    for at+1<len(order) && want_before(x,order[at+1],i) {
        order[at]=order[at+1]
        x.wants[order[at]].rank=at
        at+=1
    }
    order[at]=i
    x.wants[i].rank=at
}

@(private)
want_closed :: #force_inline proc(w:^Want) -> bool {return w.state==.Complete || w.state==.Failed}

@(private)
want_before :: proc(x:^Exchange,a,b:int) -> bool {
    wa,wb:=&x.wants[a],&x.wants[b]
    ca,cb:=want_closed(wa),want_closed(wb)
    if ca!=cb {return cb}
    return wa.priority>wb.priority || wa.priority==wb.priority && wa.order<wb.order
}

@(private)
want_complete :: proc(x:^Exchange,i:int) {
    needs_clear(x,i)
    w:=&x.wants[i]
    w.state=.Complete
    if w.total>=0 {w.here=w.total}
    order_place(x,i)
    x.dirty=true
}

@(private)
want_fail :: proc(x:^Exchange,i:int,error:Error,store_error:store.Error) {
    needs_clear(x,i)
    w:=&x.wants[i]
    if w.settling {
        w.settling=false
        x.settling-=1
    }
    w.state,w.error,w.store_error=.Failed,error,store_error
    order_place(x,i)
    x.dirty=true
}

// The tree under a verified root does not hold together: every peer would
// send the same, so the want fails.
@(private)
want_corrupt :: proc(x:^Exchange,i:int) {
    want_fail(x,i,.Store,.Corrupt)
}

// The walk is done and nothing it found is missing: once the store commits,
// the want is complete. A chunk another want was asked for is looked up
// again by a walk over the whole tree.
@(private)
want_check :: proc(x:^Exchange,i:int) {
    w:=&x.wants[i]
    if w.state!=.Asking || !w.walked || w.needs>0 || w.settling || w.walk_job {return}
    if w.shared {
        w.shared=false
        want_walk_root(x,i)
        return
    }
    w.settling=true
    x.settling+=1
    x.dirty=true
}

@(private)
need_slot :: proc(x:^Exchange,address:store.Hash) -> int {
    mask:=len(x.need_slots)-1
    h:=int(u32(address[0])|u32(address[1])<<8|u32(address[2])<<16|u32(address[3])<<24)&mask
    for {
        k:=x.need_slots[h]
        if k<0 || x.needs[k].address==address {return h}
        h=(h+1)&mask
    }
}

@(private)
need_find :: proc(x:^Exchange,address:store.Hash) -> int {
    return int(x.need_slots[need_slot(x,address)])
}

// Records a chunk want i lacks. False when the table is full: nothing is
// recorded, and the caller makes the want find it again (walk_take, want_begin).
@(private)
need_add :: proc(x:^Exchange,i:int,kind:Need_Kind,address:store.Hash,level:int,size:u64) -> bool {
    if x.need_count==len(x.needs) {return false}
    slot:=need_slot(x,address)
    if x.need_slots[slot]>=0 {return true}
    k:=x.need_free[len(x.needs)-1-x.need_count]
    x.need_count+=1
    x.need_serial+=1
    w:=&x.wants[i]
    x.needs[k]={address=address,used=true,kind=kind,level=level,size=size,want=i32(i),serial=x.need_serial,peer=-1,next=-1,prev=w.last}
    if w.last>=0 {x.needs[w.last].next=k} else {w.first=k}
    w.last=k
    x.ask_due=true
    w.needs+=1
    w.free+=1
    x.free+=1
    x.need_slots[slot]=k
    x.dirty=true
    return true
}

// The roots of wants that found the table of needs full, asked once it has room.
@(private)
rootless_ask :: proc(x:^Exchange) {
    if x.rootless==0 || x.need_count==len(x.needs) {return}
    for k in 0..<x.want_count {
        i:=x.order[k]
        w:=&x.wants[i]
        if !w.rootless {continue}
        if w.state==.Asking && !w.walking && !need_add(x,i,.Root,w.address,0,0) {return}
        w.rootless=false
        x.rootless-=1
        attend(x,i)
    }
}

@(private)
need_remove :: proc(x:^Exchange,k:int) {
    n:=&x.needs[k]
    w:=&x.wants[n.want]
    x.ask_due=true
    if n.prev>=0 {x.needs[n.prev].next=n.next} else {w.first=n.next}
    if n.next>=0 {x.needs[n.next].prev=n.prev} else {w.last=n.prev}
    w.needs-=1
    if n.peer<0 {
        w.free-=1
        x.free-=1
    }
    // Backward shift: the entries after the hole that probed past it move into it.
    mask:=len(x.need_slots)-1
    hole:=need_slot(x,n.address)
    j:=hole
    for {
        j=(j+1)&mask
        m:=x.need_slots[j]
        if m<0 {break}
        a:=x.needs[m].address
        home:=int(u32(a[0])|u32(a[1])<<8|u32(a[2])<<16|u32(a[3])<<24)&mask
        if (j>hole && (home<=hole || home>j)) || (j<hole && home<=hole && home>j) {
            x.need_slots[hole]=m
            hole=j
        }
    }
    x.need_slots[hole]=-1
    n.used=false
    x.need_count-=1
    x.need_free[len(x.needs)-1-x.need_count]=i32(k)
}

@(private)
needs_clear :: proc(x:^Exchange,i:int) {
    w:=&x.wants[i]
    for w.first>=0 {need_remove(x,int(w.first))}
}

// Peer p sent a chunk of the want that failed its address: what it was asked of the want goes
// to others, and it is not asked for it again.
@(private)
lie :: proc(x:^Exchange,i:int,p:int) {
    if p<0 {return}
    w:=&x.wants[i]
    bit:=u64(1)<<uint(p)
    if w.wrong&bit==0 {x.peers[p].lies+=1}
    w.wrong|=bit
    peer:=&x.peers[p]
    for k in 0..<peer.flight_count {
        f:=&peer.flights[(peer.flight_head+k)%len(peer.flights)]
        if int(f.want)==i {flight_release(x,p,f)}
    }
    x.dirty=true
}

// Gives back what a flight reserved, once: a late answer of a peer whose
// flight timed out does not release what another peer was asked since.
@(private)
flight_release :: proc(x:^Exchange,p:int,f:^Flight) {
    if f.released {return}
    f.released=true
    if f.need<0 {return}
    n:=&x.needs[f.need]
    if !n.used || n.serial!=f.serial || int(n.peer)!=p {return}
    n.peer=-1
    x.wants[n.want].free+=1
    x.free+=1
    x.ask_due=true
}

// What peer i was asked goes back to be asked of others; its asks stay counted.
@(private)
flights_release :: proc(x:^Exchange,i:int) {
    p:=&x.peers[i]
    for k in 0..<p.flight_count {flight_release(x,i,&p.flights[(p.flight_head+k)%len(p.flights)])}
}

// Peer i made progress on want wi: what it was asked of it stays reserved.
@(private)
flights_heard :: proc(x:^Exchange,i,wi:int) {
    p:=&x.peers[i]
    for k in 0..<p.flight_count {
        f:=&p.flights[(p.flight_head+k)%len(p.flights)]
        if int(f.want)==wi {f.heard=x.now}
    }
}

// The entry of the oldest ask of peer i an answer about address belongs to:
// its own entry when one names it, from the one being answered on, else the
// entry being answered, whose descendant it is. nil without an ask in flight.
@(private)
flight_answer :: proc(x:^Exchange,i:int,address:store.Hash) -> (f:^Flight,own:bool) {
    p:=&x.peers[i]
    if p.batches==0 {return nil,false}
    size:=p.batch_sizes[p.batch_head]
    for k in p.answering..<size {
        e:=&p.flights[(p.flight_head+k)%len(p.flights)]
        if e.address==address {
            p.answering=k
            return e,true
        }
    }
    return &p.flights[(p.flight_head+p.answering)%len(p.flights)],false
}

@(private)
batch_bytes :: proc(x:^Exchange,i:int) -> int {
    p:=&x.peers[i]
    rtt:=f64(0)
    if stats,ok:=wire.connection_stats(p.host,p.connection);ok {rtt=f64(stats.rtt)}
    return int(clamp(p.receive_rate*rtt,MIN_BATCH_BYTES,ASK_BYTES))
}

@(private)
asking :: proc(x:^Exchange) {
    periodic:=x.now-x.ask_time>=ASK_SECONDS
    for x.attention_count>0 {
        x.attention_count-=1
        i:=x.attention[x.attention_count]
        w:=&x.wants[i]
        w.attention=false
        if w.used && w.state==.Asking {want_attend(x,i)}
    }
    if periodic {
        x.ask_time=x.now
        connected:=connected_mask(x)
        for k in 0..<x.want_count {
            i:=x.order[k]
            w:=&x.wants[i]
            if want_closed(w) {break}
            if w.lack!=0 && x.now-w.lack_since>=LACK_RETRY {w.lack=0}
            if w.state==.Asking {want_attend(x,i)}
            if w.state!=.Asking && w.state!=.Missing {continue}
            // Missing when no peer may be asked for the want, or for a chunk of it.
            open:=connected&~(w.wrong|w.lack)
            for j:=w.first;j>=0 && open!=0;j=x.needs[j].next {
                n:=&x.needs[j]
                if n.lack!=0 && x.now-n.lack_since>=LACK_RETRY {n.lack=0}
                if n.peer<0 && !n.arriving && open&~n.lack==0 {open=0}
            }
            if open==0 {
                if w.state==.Asking {
                    w.state=.Missing
                    w.misses+=1
                    x.dirty=true
                }
            } else if w.state==.Missing {
                w.state=.Asking
                x.ask_due=true
            }
        }
        for &p,i in x.peers {
            if !p.used || p.bad {continue}
            for k in 0..<p.flight_count {
                f:=&p.flights[(p.flight_head+k)%len(p.flights)]
                if f.released || x.now-f.heard<=STALL_SECONDS {continue}
                // No progress on the want: others are asked, and this peer not for a while.
                w:=&x.wants[f.want]
                if w.used && w.generation==f.generation {
                    if w.lack==0 {w.lack_since=x.now}
                    w.lack|=u64(1)<<uint(i)
                }
                flight_release(x,i,f)
            }
        }
    }
    if !x.ask_due && !periodic {return}
    x.ask_due=false
    if x.free==0 {return}
    for &p,i in x.peers {
        if p.used && !p.bad && p.batches<BATCHES {batch_send(x,i)}
    }
}

// What a want that is asking does next: walk, or settle.
@(private)
want_attend :: proc(x:^Exchange,i:int) {
    walk_start(x,i)
    want_check(x,i)
}

// Has the next asking pass attend to want i.
@(private)
attend :: proc(x:^Exchange,i:int) {
    w:=&x.wants[i]
    x.ask_due=true
    if w.attention || x.attention_count==len(x.attention) {return}
    w.attention=true
    x.attention[x.attention_count]=i
    x.attention_count+=1
}

// Asks peer i for the most important chunks nobody was asked for, up to what
// it carries in a round trip. A root not here counts only against the entries
// of an ask, since most objects are small: an ask carries as many as fit, each
// with ROOT_BUDGET, so a small object comes whole.
@(private)
batch_send :: proc(x:^Exchange,i:int) {
    p:=&x.peers[i]
    bit:=u64(1)<<uint(i)
    budget:=batch_bytes(x,i)
    bytes:=0
    entries:[ASK_ENTRIES]Flight
    n:=0
    wants: for k in 0..<x.want_count {
        wi:=x.order[k]
        w:=&x.wants[wi]
        if want_closed(w) {break}
        if w.state!=.Asking || (w.wrong|w.lack)&bit!=0 || w.free==0 {continue}
        for j:=w.first;j>=0;j=x.needs[j].next {
            need:=&x.needs[j]
            if need.peer>=0 || need.arriving || need.lack&bit!=0 {continue}
            cost,left:=0,0
            switch need.kind {
            case .Root: left=0 if w.measure else ROOT_BUDGET
            case .Node: cost=NODE_ESTIMATE
            case .Data: cost=int(need.size)
            }
            if n>0 && bytes+cost>budget {break wants}
            entries[n]={need=j,serial=need.serial,want=i32(wi),generation=w.generation,address=need.address,left=i64(left),heard=x.now}
            n+=1
            bytes+=cost
            if n==ASK_ENTRIES {break wants}
        }
    }
    if n==0 {return}
    buffer:[MSG_ASK_MAX]u8
    out:=Writer{data=buffer[:]}
    write_u8(&out,MSG_ASK)
    write_u16(&out,u16(n))
    for &e in entries[:n] {
        write_bytes(&out,e.address[:])
        write_u32(&out,u32(e.left))
    }
    if !control_append(p,buffer[:out.n]) {return}
    for e in entries[:n] {
        x.needs[e.need].peer=i32(i)
        x.wants[e.want].free-=1
        x.free-=1
        p.flights[(p.flight_head+p.flight_count)%len(p.flights)]=e
        p.flight_count+=1
    }
    p.batch_sizes[(p.batch_head+p.batches)%BATCHES]=n
    p.batches+=1
}

// A chunk is taken only as the answer to an entry asked of that peer, or as a
// descendant of the entry it is answering within its budget, and goes to a
// job that stores it only once it hashes to the address the ask or its parent
// named: one that does not is reported back, and the peer is not asked for
// that want again. A descendant whose parent was not parsed yet waits, hashed,
// until it is.
@(private)
on_chunk :: proc(x:^Exchange,i:int,data:[]u8) {
    r:=Reader{data=data[1:],ok=true}
    address:=read_hash(&r)
    codec:=read_u8(&r)
    raw:=int(read_u32(&r))
    bytes:=data[min(MSG_CHUNK_HEAD,len(data)):]
    plain:=codec==store.CODEC_NONE && raw==len(bytes)
    encoded:=codec==store.CODEC_MDC2 && len(bytes)<raw
    if !r.ok || !plain && !encoded || len(bytes)==0 || raw>store.CHUNK_MAX {peer_bad(x,i);return}
    // What jobs finished is applied first: a parent parsed names its descendants.
    work_collect(x)
    p:=&x.peers[i]
    f,own:=flight_answer(x,i,address)
    if f==nil {p.refused+=1;return}
    if !own {
        f.left-=i64(len(bytes))
        if f.left<0 {peer_bad(x,i);return}
    }
    bit:=u64(1)<<uint(i)
    k:=need_find(x,address)
    if k<0 {
        fw:=&x.wants[f.want]
        if own || f.released || !fw.used || fw.generation!=f.generation || fw.state!=.Asking || fw.wrong&bit!=0 {p.refused+=1;return}
        slot:=receive_slot(x,len(bytes)+(raw if encoded else 0))
        receive_fill(x,slot,i,address,codec,raw,bytes,int(f.want))
        slot.need=-1
        work_run(x,receive_job,slot,&slot.counter)
        return
    }
    need:=&x.needs[k]
    wi:=int(need.want)
    w:=&x.wants[wi]
    under:=!own && !f.released && int(f.want)==wi && f.generation==w.generation
    if int(need.peer)!=i && !under || need.arriving {p.refused+=1;return}
    if w.wrong&bit!=0 {return}
    flights_heard(x,i,wi)
    slot:=receive_slot(x,len(bytes)+(raw if encoded else 0))
    // The table may have moved while a slot was waited for.
    k=need_find(x,address)
    if k<0 || x.needs[k].arriving || int(x.needs[k].want)!=wi {
        x.receive_count-=1
        p.refused+=1
        return
    }
    need=&x.needs[k]
    need.arriving=true
    receive_fill(x,slot,i,address,codec,raw,bytes,wi)
    slot.need,slot.serial,slot.kind,slot.level,slot.entry=i32(k),need.serial,need.kind,need.level,need.size
    slot.limit=walk_room(x,wi)
    receive_walker(x,slot)
    work_run(x,receive_job,slot,&slot.counter)
}

@(private)
// The slot holds the chunk's raw bytes, and after them its encoded bytes, which
// its job decodes in front of them.
receive_fill :: proc(x:^Exchange,slot:^Receive_Slot,i:int,address:store.Hash,codec:u8,raw:int,bytes:[]u8,wi:int) {
    p:=&x.peers[i]
    w:=&x.wants[wi]
    slot.codec,slot.stored=codec,0
    if codec!=store.CODEC_NONE {
        slot.size,slot.stored=raw,len(bytes)
        copy(slot.bytes[raw:],bytes)
    } else {
        copy(slot.bytes,bytes)
    }
    slot.address=address
    slot.want,slot.generation=i32(wi),w.generation
    slot.peer,slot.epoch=i,p.epoch
    slot.result,slot.error,slot.parsed=.Stored,.None,false
    slot.limit=0
    p.received+=u64(len(bytes))
}

@(private)
on_lack :: proc(x:^Exchange,i:int,data:[]u8) {
    r:=Reader{data=data[1:],ok=true}
    address:=read_hash(&r)
    if !read_end(&r) {peer_bad(x,i);return}
    p:=&x.peers[i]
    f,own:=flight_answer(x,i,address)
    if f==nil || !own {p.refused+=1;return}
    flight_release(x,i,f)
    k:=need_find(x,address)
    if k<0 {return}
    n:=&x.needs[k]
    bit:=u64(1)<<uint(i)
    if n.lack==0 {n.lack_since=x.now}
    n.lack|=bit
    if n.kind==.Root {
        w:=&x.wants[n.want]
        if w.lack==0 {w.lack_since=x.now}
        w.lack|=bit
    }
    x.dirty=true
}

@(private)
on_done :: proc(x:^Exchange,i:int,data:[]u8) {
    p:=&x.peers[i]
    if len(data)!=1 || p.batches==0 {peer_bad(x,i);return}
    n:=p.batch_sizes[p.batch_head]
    p.batch_head=(p.batch_head+1)%BATCHES
    p.batches-=1
    x.ask_due=true
    p.answering=0
    for _ in 0..<n {
        f:=&p.flights[p.flight_head]
        flight_release(x,i,f)
        p.flight_head=(p.flight_head+1)%len(p.flights)
        p.flight_count-=1
    }
    x.dirty=true
}

@(private)
on_ref :: proc(x:^Exchange,i:int,data:[]u8) {
    r:=Reader{data=data[1:],ok=true}
    namespace:=read_name(&r)
    name:=read_name(&r)
    found:=read_u8(&r)
    address:=read_hash(&r)
    if !read_end(&r) || found>1 {peer_bad(x,i);return}
    bit:=u64(1)<<uint(i)
    for &q in x.queries {
        if !q.used || q.kind!=.Ref || q.asked&bit==0 || q.answered&bit!=0 {continue}
        if string(q.namespace[:q.namespace_len])!=namespace || string(q.name[:q.name_len])!=name {continue}
        q.answered|=bit
        x.peers[i].queries-=1
        if found==1 && q.state==.Waiting {q.state,q.address=.Found,address}
        x.dirty=true
        return
    }
}

@(private)
on_names :: proc(x:^Exchange,i:int,data:[]u8) {
    r:=Reader{data=data[1:],ok=true}
    namespace:=read_name(&r)
    after:=read_name(&r,empty=true)
    more:=read_u8(&r)
    count:=int(read_u16(&r))
    start:=r.at
    for _ in 0..<count {
        read_name(&r)
        read_hash(&r)
    }
    if !read_end(&r) || more>1 || count>NAMES_PER_REPLY {peer_bad(x,i);return}
    bit:=u64(1)<<uint(i)
    for &q in x.queries {
        if !q.used || q.kind!=.Names || q.peer!=i || q.asked&bit==0 || q.answered&bit!=0 {continue}
        if string(q.namespace[:q.namespace_len])!=namespace || string(q.name[:q.name_len])!=after {continue}
        q.answered|=bit
        x.peers[i].queries-=NAMES_CREDITS
        entries:=Reader{data=data[1:],at=start,ok=true}
        used:=0
        for k in 0..<count {
            name:=read_name(&entries)
            copy(q.name_bytes[used:],name)
            q.names[k]={name=string(q.name_bytes[used:][:len(name)]),address=read_hash(&entries)}
            used+=len(name)
        }
        q.name_count,q.more,q.state=count,more==1,.Found
        x.dirty=true
        return
    }
}


// A peer told of a change of one of its refs: the owner hears it at once.
@(private)
on_ref_changed :: proc(x:^Exchange,i:int,data:[]u8) {
    r:=Reader{data=data[1:],ok=true}
    namespace:=read_name(&r)
    name:=read_name(&r)
    address:=read_hash(&r)
    if !read_end(&r) {peer_bad(x,i);return}
    if x.desc.hint!=nil {x.desc.hint(x.desc.user,peer_id(&x.peers[i]),namespace,name,address)}
}
