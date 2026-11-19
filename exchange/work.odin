package exchange

import "core:sync"
import "mirai:std/jobs"
import "mirai:store"

// What runs on the jobs of the owner's worker: checking and storing received
// chunks, walking trees in the store, serving, committing and checking a copy
// a receiver reported. Each job owns a slot sized at init and touches nothing
// else of the exchange; the pump hands work to a slot and applies its result
// under the lock, so a job never takes the lock and the pump may wait for one.
// Without a job system each job runs on the pump when it is handed out.

@(private)
Walk_Found :: struct {address:store.Hash,kind:Need_Kind,level:int,size:u64}

// A depth-first walk over what a store holds of a tree, which records the
// chunks it lacks: data chunks as it passes them, and a missing node, with the
// missing nodes after it, where it stops.
@(private)
Walker :: struct {
    s:^store.Store,
    stack:[WALK_DEPTH]Walk_Frame,
    depth:int,
    root:bool,         // the bottom of the stack is the root of the object
    found:[]Walk_Found,
    count,limit:int,
    here:i64,          // data bytes it found stored
    total:i64,         // of the root, once read; -1
    walked:bool,       // the stack emptied
    blocked:bool,      // stopped at the missing node of the top frame's entry
    waiting:store.Hash, // that node
    error:store.Error, // Missing: a node it walked is gone; Corrupt: one does not hold together
    buffer:[]u8,       // a node read from the store; nil: it reads none and stops where it would
    unread:bool,       // it stopped where it would read the store
    given:store.Hash,  // a node whose bytes are at hand
    given_bytes:[]u8,
    viewing:bool,
    view_address:store.Hash,
    view:store.Node_View,
}

@(private)
walker_begin :: proc(k:^Walker,address:store.Hash,root:bool,limit:int,given:[]u8={}) {
    k.stack[0]={address=address}
    // Room is left for the missing node it may stop at and the ones it asks ahead.
    k.depth,k.root,k.count,k.limit,k.here,k.total=1,root,0,min(limit,len(k.found)-PREFETCH_NODES-1),0,-1
    k.walked,k.blocked,k.error,k.viewing,k.unread=false,false,.None,false,false
    k.given,k.given_bytes=address,given
}

@(private)
walker_node :: proc(k:^Walker,address:store.Hash) -> (n:store.Node_View,error:store.Error) {
    if k.viewing && k.view_address==address {return k.view,.None}
    k.viewing=false
    bytes:[]u8
    if address==k.given && k.given_bytes!=nil {
        bytes=k.given_bytes
    } else {
        if k.buffer==nil {
            k.unread=true
            return {},.Missing
        }
        bytes=store.chunk_read(k.s,address,k.buffer) or_return
        if raw_data(bytes)!=raw_data(k.buffer) {copy(k.buffer,bytes)}
        bytes=k.buffer[:len(bytes)]
    }
    n=store.node_parse(bytes) or_return
    k.view_address,k.view,k.viewing=address,n,true
    return n,.None
}

@(private)
walker_found :: proc(k:^Walker,kind:Need_Kind,address:store.Hash,level:int,size:u64) {
    if k.count<len(k.found) {
        k.found[k.count]={address=address,kind=kind,level=level,size=size}
        k.count+=1
    }
}

// Walks until limit chunks are found, a missing node stops it or the stack empties.
@(private)
walker_run :: proc(k:^Walker) {
    for k.depth>0 {
        if k.count>=k.limit {return}
        f:=&k.stack[k.depth-1]
        n,error:=walker_node(k,f.address)
        if k.unread {return}
        if error!=.None {
            k.error=.Missing if error==.Missing else .Corrupt
            return
        }
        if k.root && k.depth==1 && k.total<0 {k.total=i64(n.total)}
        if f.index>=len(n.entries) {
            k.depth-=1
            continue
        }
        e:=n.entries[f.index]
        if n.level==0 {
            f.index+=1
            if store.chunk_here(k.s,e.address) {k.here+=i64(e.size)} else {walker_found(k,.Data,e.address,0,e.size)}
            continue
        }
        if store.chunk_here(k.s,e.address) {
            level:=n.level
            child,child_error:=walker_node(k,e.address)
            if k.unread {return}
            if child_error!=.None || child.level!=level-1 || child.total!=e.size || len(child.groups)>0 || len(child.meta)>0 || k.depth==WALK_DEPTH {
                k.error=.Corrupt
                return
            }
            f.index+=1
            k.stack[k.depth]={address=e.address}
            k.depth+=1
            continue
        }
        walker_found(k,.Node,e.address,n.level-1,e.size)
        // The next missing nodes are asked now, so they are here when the walk reaches them.
        ahead:=0
        for next in n.entries[f.index+1:] {
            if ahead==PREFETCH_NODES {break}
            ahead+=1
            if !store.chunk_here(k.s,next.address) {walker_found(k,.Node,next.address,n.level-1,next.size)}
        }
        k.blocked,k.waiting=true,e.address
        return
    }
    k.walked=true
}

@(private)
Receive_Result :: enum u8 {
    Stored,   // checked and stored; a node also walked from
    Mismatch, // it does not hash to its address
    Corrupt,  // it hashes right but does not hold together with its parent
    Failed,   // the store refused it
    Checked,  // a descendant whose parent was not parsed when it came: hashed, not stored
}

// A received chunk on its way to the store. One the ask did not name and
// whose parent was not parsed yet (a descendant streamed under a budget) is
// only hashed and parsed; once its parent named it, it goes again to be stored.
@(private)
Receive_Slot :: struct {
    x:^Exchange,
    bytes:[]u8,   // in the ring of received bytes
    offset:int,
    size:int,
    address:store.Hash,
    need:i32,     // -1 while its parent was not parsed
    serial:u32,
    want:i32,
    generation:u32,
    peer:int,
    epoch:u32,
    kind:Need_Kind,
    level:int,
    entry:u64,    // data bytes its parent says are under it
    limit:int,    // chunks its walk may find
    result:Receive_Result,
    error:store.Error,
    parsed:bool,  // its bytes parse as a node, of level and total
    parsed_level:int,
    parsed_total:u64,
    parsed_plain:bool, // without groups or meta
    walk:^Walker, // a received node's: it walks from it
    light:Walker, // its own, which reads nothing
    counter:jobs.Counter,
    done:bool,
}

@(private)
receive_job :: proc(data:rawptr,worker:int) {
    r:=(^Receive_Slot)(data)
    defer sync.atomic_store(&r.done,true)
    bytes:=r.bytes[:r.size]
    if r.result!=.Checked {
        if store.address_of_bytes(bytes)!=r.address {
            r.result=.Mismatch
            return
        }
        if n,error:=store.node_parse(bytes);error==.None {
            r.parsed,r.parsed_level,r.parsed_total,r.parsed_plain=true,n.level,n.total,len(n.groups)==0 && len(n.meta)==0
        }
        if r.need<0 {
            r.result=.Checked
            return
        }
    }
    switch r.kind {
    case .Root:
        if !r.parsed {
            r.result=.Corrupt
            return
        }
    case .Node:
        if !r.parsed || r.parsed_level!=r.level || r.parsed_total!=r.entry || !r.parsed_plain {
            r.result=.Corrupt
            return
        }
    case .Data:
        if u64(r.size)!=r.entry {
            r.result=.Corrupt
            return
        }
    }
    if r.error=store.chunk_put(r.x.desc.store,r.address,bytes);r.error!=.None {
        r.result=.Failed
        return
    }
    r.result=.Stored
    if r.kind!=.Data && r.walk!=nil {
        walker_begin(r.walk,r.address,r.kind==.Root,r.limit,bytes)
        walker_run(r.walk)
    }
}

// A walk of a want over the store, from its stack.
@(private)
Walk_Slot :: struct {
    x:^Exchange,
    used:bool,
    want:i32,
    generation:u32,
    walk:Walker,
    counter:jobs.Counter,
    done:bool,
}

@(private)
walk_job :: proc(data:rawptr,worker:int) {
    k:=(^Walk_Slot)(data)
    defer sync.atomic_store(&k.done,true)
    walker_run(&k.walk)
}

@(private)
Commit_Item :: struct {
    want:i32,
    generation:u32,
}

// The commit of the batch that holds the last chunks of the wants that settle.
@(private)
Commit_Slot :: struct {
    x:^Exchange,
    used:bool,
    items:[]Commit_Item,
    count:int,
    committed:store.Error,
    counter:jobs.Counter,
    done:bool,
}

@(private)
commit_job :: proc(data:rawptr,worker:int) {
    c:=(^Commit_Slot)(data)
    defer sync.atomic_store(&c.done,true)
    c.committed=store.commit(c.x.desc.store)
}

// A chunk a receiver reported damaged, checked against its address.
@(private)
Check_Slot :: struct {
    x:^Exchange,
    used:bool,
    address:store.Hash,
    counter:jobs.Counter,
    done:bool,
}

@(private)
check_job :: proc(data:rawptr,worker:int) {
    c:=(^Check_Slot)(data)
    defer sync.atomic_store(&c.done,true)
    store.chunk_check(c.x.desc.store,c.address)
}

// Runs a job of a slot on the owner's worker, or now without a job system.
// A chunk's work is short and the pump may wait for it, helping: it is of the
// frame class; a commit waits for the disk and is background.
@(private)
work_run :: proc(x:^Exchange,procedure:jobs.Job_Proc,data:rawptr,counter:^jobs.Counter,class:=jobs.Class.Frame) {
    js:=x.desc.worker.system
    if js==nil {
        procedure(data,0)
        return
    }
    jobs.run(js,x.desc.worker.worker,class,procedure,data,counter)
}

@(private)
work_wait :: proc(x:^Exchange,counter:^jobs.Counter) {
    if js:=x.desc.worker.system;js!=nil {jobs.wait(js,x.desc.worker.worker,counter)}
}

// Waits for every job of the exchange.
@(private)
work_wait_all :: proc(x:^Exchange) {
    if x.desc.worker.system==nil {return}
    for k in 0..<x.receive_count {work_wait(x,&x.receives[(x.receive_head+k)%len(x.receives)].counter)}
    for &k in x.walks {
        if k.used {work_wait(x,&k.counter)}
    }
    for &c in x.checks {
        if c.used {work_wait(x,&c.counter)}
    }
    for &p in x.peers {
        if sync.atomic_load(&p.serving) {work_wait(x,&p.serve_counter)}
    }
    if x.commit.used {work_wait(x,&x.commit.counter)}
}

// Applies what the jobs finished, receive slots in the order received.
@(private)
work_collect :: proc(x:^Exchange) {
    for x.receive_count>0 {
        r:=&x.receives[x.receive_head]
        if !sync.atomic_load(&r.done) {break}
        if receive_apply(x,r) {continue}
        receive_free(x,r)
        x.receive_head=(x.receive_head+1)%len(x.receives)
        x.receive_count-=1
    }
    for &k in x.walks {
        if k.used && sync.atomic_load(&k.done) {
            k.used=false
            walk_apply(x,&k)
        }
    }
    if x.commit.used && sync.atomic_load(&x.commit.done) {
        x.commit.used=false
        commit_apply(x)
    }
    for &c in x.checks {
        if c.used && sync.atomic_load(&c.done) {c.used=false}
    }
}

// A free receive slot with size bytes in the ring, the oldest applied first
// while there is no room.
@(private)
receive_slot :: proc(x:^Exchange,size:int) -> ^Receive_Slot {
    at:=-1
    for {
        if x.receive_count==0 {x.receive_tail=0}
        if x.receive_count<len(x.receives) {at=receive_room(x,size)}
        if at>=0 {break}
        r:=&x.receives[x.receive_head]
        work_wait(x,&r.counter)
        work_collect(x)
    }
    r:=&x.receives[(x.receive_head+x.receive_count)%len(x.receives)]
    x.receive_count+=1
    r.offset,r.size=at,size
    r.bytes=x.receive_bytes[at:][:size]
    x.receive_tail=at+size
    r.walk=nil
    sync.atomic_store(&r.done,false)
    return r
}

// Where size bytes fit after the last slot's in the ring; -1 when they do not.
@(private)
receive_room :: proc(x:^Exchange,size:int) -> int {
    if x.receive_count==0 {return 0}
    head:=x.receives[x.receive_head].offset
    tail:=x.receive_tail
    if tail>=head {
        if size<=len(x.receive_bytes)-tail {return tail}
        if size<head {return 0}
        return -1
    }
    return tail if size<head-tail else -1
}

// A walker for a received node: one that reads the store if one is free,
// else the slot's own, which walks only what the node names.
@(private)
receive_walker :: proc(x:^Exchange,r:^Receive_Slot) {
    if r.kind==.Data || r.walk!=nil {return}
    for &used,k in x.walker_used {
        if used {continue}
        used=true
        r.walk=&x.walkers[k]
        return
    }
    r.walk=&r.light
}

@(private)
receive_free :: proc(x:^Exchange,r:^Receive_Slot) {
    if r.walk!=nil && r.walk!=&r.light {
        for &k,j in x.walkers {
            if &k==r.walk {x.walker_used[j]=false}
        }
        r.walk=nil
    }
}

// Applies a receive slot; true when it went again to its job and stays.
@(private)
receive_apply :: proc(x:^Exchange,r:^Receive_Slot) -> bool {
    if r.want<0 {return false}
    w:=&x.wants[r.want]
    current:=w.used && w.generation==r.generation
    p:=&x.peers[r.peer]
    same_peer:=p.used && p.epoch==r.epoch
    if r.need<0 && r.result==.Mismatch {
        if current && same_peer {
            buffer:[MSG_ADDRESS_BYTES]u8
            if !control_append(p,buffer[:encode_address(buffer[:],MSG_BAD,r.address)]) {p.refused+=1}
            lie(x,int(r.want),r.peer)
        }
        return false
    }
    if r.result==.Checked {
        // Its parent was parsed since: stored only if it names it.
        k:=need_find(x,r.address)
        if !current || k<0 || int(x.needs[k].want)!=int(r.want) || x.needs[k].arriving {
            if same_peer {p.refused+=1}
            return false
        }
        n:=&x.needs[k]
        n.arriving=true
        r.need,r.serial,r.kind,r.level,r.entry=i32(k),n.serial,n.kind,n.level,n.size
        r.limit=walk_room(x,int(r.want))
        receive_walker(x,r)
        sync.atomic_store(&r.done,false)
        work_run(x,receive_job,r,&r.counter)
        return sync.atomic_load(&r.done)==false || receive_apply(x,r)
    }
    k:=int(r.need)
    held:=current && x.needs[k].used && x.needs[k].serial==r.serial
    if held {x.needs[k].arriving=false}
    if !held {return false}
    wi:=int(r.want)
    switch r.result {
    case .Checked,.Stored:
    case .Mismatch:
        if same_peer {
            buffer:[MSG_ADDRESS_BYTES]u8
            if !control_append(p,buffer[:encode_address(buffer[:],MSG_BAD,r.address)]) {p.refused+=1}
            lie(x,wi,r.peer)
        } else {
            n:=&x.needs[k]
            if n.peer>=0 {
                n.peer=-1
                w.free+=1
            }
        }
        return false
    case .Corrupt:
        want_corrupt(x,wi)
        return false
    case .Failed:
        want_fail(x,wi,.Store,r.error)
        return false
    }
    x.uncommitted=true
    kind,size:=r.kind,r.entry
    need_remove(x,k)
    x.dirty=true
    switch kind {
    case .Data: w.here+=i64(size)
    case .Root:
        w.total=i64(r.parsed_total)
        if !w.walk_job {
            if r.walk!=nil {
                w.walking,w.walked,w.blocked,w.depth=true,false,false,0
                walk_graft(x,wi,r.walk)
            } else {
                want_walk_root(x,wi)
            }
        }
    case .Node:
        // The walk waits for this node: what its job walked under it goes on its stack.
        if w.walking && w.blocked && !w.walk_job && w.waiting_for==r.address && r.walk!=nil {walk_graft(x,wi,r.walk)}
    }
    attend(x,wi)
    return false
}

// Puts on a want's walk what a job walked from a node of it: the root, or the
// node the walk waits for, whose entry the top frame then passes.
@(private)
walk_graft :: proc(x:^Exchange,wi:int,k:^Walker) {
    w:=&x.wants[wi]
    if k.error!=.None {
        if k.error==.Missing {want_begin(x,wi)} else {want_corrupt(x,wi)}
        return
    }
    if k.root && k.total>=0 {w.total=k.total}
    w.here+=k.here
    if w.depth>0 {w.stack[w.depth-1].index+=1}
    if !k.walked {
        if w.depth+k.depth>WALK_DEPTH {
            want_corrupt(x,wi)
            return
        }
        copy(w.stack[w.depth:],k.stack[:k.depth])
        w.depth+=k.depth
    }
    w.blocked,w.waiting_for=k.blocked,k.waiting
    walk_take(x,wi,k.found[:k.count])
    if w.depth==0 {w.walked=true}
}

// Records what a walk found that is not asked already.
@(private)
walk_take :: proc(x:^Exchange,wi:int,found:[]Walk_Found) {
    w:=&x.wants[wi]
    for f in found {
        if k:=need_find(x,f.address);k>=0 {
            if int(x.needs[k].want)!=wi {w.shared=true}
            continue
        }
        need_add(x,wi,f.kind,f.address,f.level,f.size)
    }
}

// How many chunks a walk of want i may find now.
@(private)
walk_room :: proc(x:^Exchange,i:int) -> int {
    w:=&x.wants[i]
    return max(min(WALK_AHEAD-w.free,len(x.needs)-x.need_count),0)
}

// Hands the walk of want i to a job, when it may go on and a slot is free.
@(private)
walk_start :: proc(x:^Exchange,i:int) {
    w:=&x.wants[i]
    if w.state!=.Asking || !w.walking || w.walked || w.walk_job || w.settling {return}
    if w.blocked && need_find(x,w.waiting_for)>=0 {return}
    room:=walk_room(x,i)
    if room==0 {return}
    for &k in x.walks {
        if k.used {continue}
        k.used,k.want,k.generation=true,i32(i),w.generation
        walker_begin(&k.walk,{},true,room)
        copy(k.walk.stack[:],w.stack[:w.depth])
        k.walk.depth=w.depth
        k.walk.given,k.walk.given_bytes={},nil
        if w.total>=0 {k.walk.total=w.total}
        w.walk_job=true
        sync.atomic_store(&k.done,false)
        work_run(x,walk_job,&k,&k.counter)
        return
    }
}

@(private)
walk_apply :: proc(x:^Exchange,k:^Walk_Slot) {
    wi:=int(k.want)
    w:=&x.wants[wi]
    if !w.used || w.generation!=k.generation {return}
    w.walk_job=false
    if w.state!=.Asking || !w.walking {return}
    if k.walk.error!=.None {
        if k.walk.error==.Missing {want_begin(x,wi)} else {want_corrupt(x,wi)}
        return
    }
    if k.walk.total>=0 {w.total=k.walk.total}
    w.here+=k.walk.here
    copy(w.stack[:],k.walk.stack[:k.walk.depth])
    w.depth=k.walk.depth
    w.blocked,w.waiting_for=k.walk.blocked,k.walk.waiting
    walk_take(x,wi,k.walk.found[:k.walk.count])
    w.walked=k.walk.walked
    attend(x,wi)
    x.dirty=true
}

// Commits for the wants that settle, at most once a COMMIT_SECONDS, and what
// arrived meanwhile once a COMMIT_IDLE.
@(private)
settle :: proc(x:^Exchange) {
    c:=&x.commit
    if c.used {return}
    if x.settling==0 && !(x.uncommitted && x.now-x.commit_time>=COMMIT_IDLE) {return}
    if x.settling>0 && x.now-x.commit_time<COMMIT_SECONDS {return}
    x.commit_time,x.uncommitted=x.now,false
    c.count=0
    for k in 0..<x.want_count {
        i:=x.order[k]
        w:=&x.wants[i]
        if !w.settling || w.committing || c.count==len(c.items) {continue}
        w.committing=true
        c.items[c.count]={want=i32(i),generation=w.generation}
        c.count+=1
    }
    c.used=true
    sync.atomic_store(&c.done,false)
    work_run(x,commit_job,c,&c.counter,.Background)
}

@(private)
commit_apply :: proc(x:^Exchange) {
    c:=&x.commit
    for item in c.items[:c.count] {
        i:=int(item.want)
        w:=&x.wants[i]
        if !w.used || w.generation!=item.generation || !w.committing {continue}
        w.committing=false
        if !w.settling {continue}
        w.settling=false
        x.settling-=1
        switch c.committed {
        case .None: want_complete(x,i)
        case .Missing: want_begin(x,i) // a chunk a sweep dropped beside the batch
        case .Corrupt,.Invalid_Argument,.Unsupported_Layout,.Io,.No_Space,.Out_Of_Memory:
            want_fail(x,i,.Store,c.committed)
        }
    }
    x.dirty=true
}
