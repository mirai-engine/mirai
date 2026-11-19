package exchange

import "base:runtime"
import "core:slice"
import "core:sync"
import wire "mirai:net"
import "mirai:std/jobs"
import "mirai:store"

// Objects and refs between peers over the connections of net hosts that the
// owner runs. An object travels as its chunks, asked by address: any peer that
// has a chunk answers, also one still receiving the object. The receiver walks
// the tree of what it wants, asks only the chunks it lacks, most important
// first and spread over peers, and checks every chunk against the address its
// parent or its ask named before the store keeps it.
//
// The owner adds the CHANNELS of channels() to every host, gives each
// connection with peer_add, hands every Message command to receive and calls
// update once per frame, before host_update. Every procedure takes the lock
// of the Exchange, so fetch may wait on a job thread while the owner pumps.

CHANNELS :: 2
MAX_PEERS :: 64
ASK_ENTRIES :: 256        // chunks one ask names
ASK_BYTES :: 16<<20       // chunk bytes one ask expects at most
BATCHES :: 2              // asks in flight to a peer
ROOT_BUDGET :: 96<<10     // descendant bytes asked with a root not here: a small object comes whole in one round trip
NAMES_PER_REPLY :: 128

@(private) LANE_CONTROL :: 0 // asks, reports, refs and their answers
@(private) LANE_DATA :: 1    // chunks and the end of each ask
@(private) CONTROL_BYTES :: 64<<10
@(private) DATA_QUEUE_BYTES :: 4<<20
@(private) NAMES_REPLY_BYTES :: 16<<10
@(private) MIN_BATCH_BYTES :: 1<<20
@(private) QUERY_CREDITS :: 32 // questions a peer keeps waiting: a ref costs one, a listing NAMES_CREDITS, so their answers fit in CONTROL_BYTES
@(private) NAMES_CREDITS :: 10
@(private) FETCH_WINDOW :: 256 // objects or refs a blocking form waits on at once
@(private) LACK_RETRY :: 2.0    // s a peer that lacked a chunk is not asked for it again
@(private) STALL_SECONDS :: 5.0 // s a peer keeps what it was asked of a want without progress on it, before others are asked
@(private) RATE_SECONDS :: 1.0  // time constant of the smoothed rates
@(private) WALK_AHEAD :: 1024   // chunks a want keeps found and not asked
@(private) PREFETCH_NODES :: 16 // missing nodes asked ahead of the walk, which waits at the first
@(private) NODE_ESTIMATE :: 16<<10 // bytes an ask counts for a node, whose size is not known
@(private) COMMIT_SECONDS :: 0.005 // between two commits that complete wants
@(private) COMMIT_IDLE :: 1.0      // s between two commits of what arrived while no want completes
@(private) WALK_DEPTH :: store.NODE_LEVEL_MAX+1
@(private) ASK_SECONDS :: 0.05 // between asking passes when nothing changed: lacks and reservations expire
@(private) RECEIVE_SLOTS :: 512     // chunks received and not yet checked and stored
@(private) RECEIVE_BYTES :: 8<<20   // their bytes, in a ring
@(private) RECEIVE_WALKERS :: 8     // received nodes walked from at once, reading the store
@(private) LIGHT_FOUND :: 64        // chunks the walk of a received node finds without reading the store
@(private) WALK_SLOTS :: 4     // walks reading the store at once
@(private) SEND_BYTES :: 1<<20      // answers of a peer read and not yet sent, in a ring
@(private) CHECK_SLOTS :: 4    // reports of damage being checked at once

// Whether peers may read the refs of namespace.
Expose :: #type proc(user:rawptr,namespace:string) -> bool

Desc :: struct {
    store:^store.Store,
    channel:int, // index of the first of the CHANNELS channels in the channels of every host
    peers:int,   // connections at once, default 8, at most MAX_PEERS
    wants:int,   // objects asked at once, default 256
    queries:int, // ref questions at once, default 16
    needs:int,   // chunks known missing at once over every want, default 8192
    worker:jobs.Worker_Ref, // of the thread that pumps: reading, hashing, storing and committing run as its jobs; zero: on the pump
    expose:Expose, // nil exposes no namespace
    expose_user:rawptr,
    allocator:runtime.Allocator,
}

Error :: enum u8 {
    None,
    Invalid,       // bad argument, or a host without the channels of the exchange
    Full,          // a capacity of the Desc is exhausted
    Missing,       // no connected peer has it
    Store,         // the store refused it: Progress.store_error
    Closed,        // the exchange was destroyed while waiting
    Out_Of_Memory, // only from init
}

State :: enum u8 {
    Asking,   // being received
    Complete, // in the store, committed
    Missing,  // no connected peer has it, or one of its chunks, now; asked again when a peer joins or after a while
    Failed,   // error
}

Progress :: struct {
    state:State,
    here:i64,  // data bytes in the store
    total:i64, // -1 until the root is known
    error:Error,
    store_error:store.Error,
}

Peer_Progress :: struct {
    receive_rate,send_rate:f64, // chunk bytes per second, smoothed
    received,sent:u64,          // chunk bytes
    lies:int,                   // wants it sent a chunk for that failed its address, or a wrong alias
    refused:u64,                // its messages refused
    bad:bool,                   // it sent what no peer sends: it is neither asked nor served
}

Query :: struct {index,generation:u32}

Query_State :: enum u8 {Waiting,Found,Not_Found}

Name :: struct {name:string,address:store.Hash}

Query_Result :: struct {
    state:Query_State,
    address:store.Hash, // of a ref
    names:[]Name,       // of a namespace, sorted, valid until query_end
    more:bool,          // the namespace has names after the last: ask again with it as after
}

@(private)
Walk_Frame :: struct {address:store.Hash,index:int}

@(private)
Want :: struct {
    address:store.Hash, // as wanted: the root of an object, or a blob
    root:store.Hash,    // of its object, once rooted
    used,wanted:bool,
    rooted:bool,  // the root is known: the address is one, or a peer named the blob's
    blob:bool,    // a peer named the address as a blob: complete once its bytes hash to it
    alias_peer:int,
    waiters:int,
    generation:u32,
    priority:int,
    order:u64,
    rank:int,       // its place in Exchange.order
    attention:bool, // in Exchange.attention
    state:State,
    error:Error,
    store_error:store.Error,
    total,here:i64,
    wrong,lack:u64, // peers that lied about it, and that lack it
    lack_since:f64,
    misses:u32,     // times it went Missing
    needs,free:int, // its needs, and those not asked of a peer
    first,last:i32, // its needs, in the order its walk found them
    stack:[WALK_DEPTH]Walk_Frame,
    depth:int,
    walking:bool,    // the walk began at the root
    walked:bool,     // the walk reached the end
    blocked:bool,    // the walk waits for the node of the entry at the top of its stack
    waiting_for:store.Hash, // that node
    walk_job:bool,   // a walk job holds the stack
    shared:bool,     // the walk passed a chunk another want needs
    settling:bool,   // complete once the batch that holds its last chunk is committed
    committing:bool, // in the commit job running
}

@(private)
Need_Kind :: enum u8 {Root,Node,Data}

// A chunk a want lacks, found by its walk, until it is here.
@(private)
Need :: struct {
    address:store.Hash,
    used:bool,
    kind:Need_Kind,
    level:int,  // of a node
    size:u64,   // data bytes under it, as its parent says
    want:i32,
    serial:u32,
    peer:i32,   // asked of; -1
    lack:u64,   // peers that lacked it
    lack_since:f64,
    arriving:bool, // its chunk is in a receive slot
    next,prev:i32,
}

@(private)
Flight :: struct {
    need:i32,
    serial:u32,
    want:i32,
    generation:u32,     // of the want
    address:store.Hash, // what answers it: the chunk asked, or the root an alias named
    left:i64,           // descendant bytes it may still bring
    released:bool,      // what it reserved went back to be asked of others
    heard:f64,          // when it was sent or the peer last made progress on its want
}

@(private)
Serve_Kind :: enum u8 {Ask,Done}

@(private)
Serve :: struct {kind:Serve_Kind,address:store.Hash,budget:u32}

@(private)
Peer :: struct {
    used,bad:bool,
    exchange:^Exchange,
    host:^wire.Host,
    connection:wire.Connection,
    // Asking: the entries of the asks in flight, oldest first.
    flights:[]Flight,
    flight_head,flight_count:int,
    batch_sizes:[BATCHES]int,
    batch_head,batches:int,
    answering:int, // the entry of the oldest ask being answered
    queries:int,   // credits of the questions asked of it and not answered
    // Serving: the entries of the asks received, oldest first, taken by its
    // serve job; the pump appends at serve_tail, the job takes at serve_head.
    serve:[]Serve,
    serve_head,serve_tail:int,
    serving:bool,  // its serve job runs and owns what follows, up to the send slots
    stop:bool,     // its serve job stops at the next answer
    draining:bool, // it left while its serve job ran: the slot frees once it ends
    epoch:u32,     // of the peer in the slot: results of jobs for another are not its
    started:bool,  // the chunk of the first entry went
    aliased:bool,  // its address was a blob, replaced by its root
    sent_under:i64, // descendant bytes of the first entry sent
    stack:[WALK_DEPTH]Walk_Frame,
    depth:int,
    node:[]u8,     // a node being streamed
    node_address:store.Hash,
    node_view:store.Node_View,
    node_held:bool,
    serve_counter:jobs.Counter,
    // Answers the serve job made and the pump sends in order, each its size as
    // a u32 and its bytes padded to 4; the job writes at send_tail, the pump
    // sends from send_head, both counting bytes from the start.
    send:[]u8,
    send_head,send_tail:int,
    out_sent:int,
    control:[]u8,
    control_start,control_end:int,
    // Receiving, per lane: a message that arrives in pieces.
    assembly:[CHANNELS][]u8,
    assembled:[CHANNELS]int,
    overflow:[CHANNELS]bool,
    received,sent,received_mark,sent_mark:u64,
    receive_rate,send_rate:f64,
    lies:int,
    refused:u64,
}

@(private)
Query_Kind :: enum u8 {Ref,Names}

@(private)
Query_Slot :: struct {
    used:bool,
    ended:bool, // its owner is done with it; it stays until every peer asked answers, which frees their credits
    generation:u32,
    kind:Query_Kind,
    state:Query_State,
    waiters:int,
    namespace,name:[store.NAME_MAX]u8, // name: the name of a ref, or after of a listing
    namespace_len,name_len:int,
    peer:int,
    asked,answered:u64,
    address:store.Hash,
    more:bool,
    names:[]Name,
    name_count:int,
    name_bytes:[]u8,
}

Exchange :: struct {
    desc:Desc,
    allocator:runtime.Allocator,
    lock:sync.Mutex,
    changed:sync.Cond,
    wants:[]Want,
    order:[]int, // wants in use, most important first
    want_count:int,
    sequence:u64,
    needs:[]Need,
    need_slots:[]i32, // open addressing by address, -1 empty
    need_free:[]i32,
    need_count:int,
    need_serial:u32,
    peers:[]Peer,
    queries:[]Query_Slot,
    want_slots:[]i32, // open addressing by address, -1 empty
    settling:int,
    commit_time:f64,
    uncommitted:bool, // chunks arrived since the last commit
    ask_due:bool,     // something changed that the asking pass reads
    free:int,         // needs not asked of a peer, over every want
    attention:[]int,  // wants something happened to, for the next asking pass
    attention_count:int,
    ask_time:f64,     // of the last asking pass
    receives:[]Receive_Slot, // a ring: applied in the order received
    receive_head,receive_count:int,
    receive_bytes:[]u8,      // of the slots, a ring in their order
    receive_tail:int,        // where the next slot's bytes go
    walkers:[]Walker,        // for received nodes
    light_found:[]Walk_Found, // of the slots' own walkers
    walker_used:[RECEIVE_WALKERS]bool,
    walks:[]Walk_Slot,
    commit:Commit_Slot,
    checks:[]Check_Slot,
    found:[]Walk_Found, // what applying a walk adds, deduplicated
    now,rate_time:f64,
    dirty:bool,
    closing:bool, // destroy is waiting for the waiters to leave
    waiting:int,  // fetch calls waiting
}

channels :: proc() -> [CHANNELS]wire.Channel_Desc {
    return {{kind=.Reliable,queue_bytes=CONTROL_BYTES},{kind=.Reliable,queue_bytes=DATA_QUEUE_BYTES}}
}

init :: proc(x:^Exchange,desc:Desc) -> Error {
    x^={desc=desc}
    d:=&x.desc
    x.allocator=d.allocator.procedure==nil?context.allocator:d.allocator
    if d.store==nil || d.channel<0 {return .Invalid}
    if d.peers<=0 {d.peers=8}
    if d.wants<=0 {d.wants=256}
    if d.queries<=0 {d.queries=16}
    if d.needs<=0 {d.needs=8192}
    if d.peers>MAX_PEERS || d.needs>1<<24 || d.wants>1<<24 {return .Invalid}
    failed:=false
    make_into :: proc(x:^Exchange,slot:^$T/[]$E,count:int,failed:^bool) {
        made,error:=make(T,count,x.allocator)
        if error!=nil {failed^=true;return}
        slot^=made
    }
    slots:=1
    for slots<2*d.needs {slots*=2}
    want_slots:=1
    for want_slots<2*d.wants {want_slots*=2}
    make_into(x,&x.wants,d.wants,&failed)
    make_into(x,&x.order,d.wants,&failed)
    make_into(x,&x.want_slots,want_slots,&failed)
    make_into(x,&x.attention,d.wants,&failed)
    make_into(x,&x.needs,d.needs,&failed)
    make_into(x,&x.need_slots,slots,&failed)
    make_into(x,&x.need_free,d.needs,&failed)
    make_into(x,&x.peers,d.peers,&failed)
    make_into(x,&x.queries,d.queries,&failed)
    make_into(x,&x.receives,RECEIVE_SLOTS,&failed)
    make_into(x,&x.receive_bytes,RECEIVE_BYTES,&failed)
    make_into(x,&x.walkers,RECEIVE_WALKERS,&failed)
    make_into(x,&x.light_found,RECEIVE_SLOTS*LIGHT_FOUND,&failed)
    make_into(x,&x.walks,WALK_SLOTS,&failed)
    make_into(x,&x.checks,CHECK_SLOTS,&failed)
    make_into(x,&x.found,WALK_AHEAD+PREFETCH_NODES,&failed)
    make_into(x,&x.commit.items,d.wants,&failed)
    if failed {destroy(x);return .Out_Of_Memory}
    for &s in x.need_slots {s=-1}
    for &s in x.want_slots {s=-1}
    for k in 0..<d.needs {x.need_free[k]=i32(d.needs-1-k)}
    if failed {destroy(x);return .Out_Of_Memory}
    for &r,k in x.receives {
        r.x=x
        r.light.s=x.desc.store
        r.light.found=x.light_found[k*LIGHT_FOUND:][:LIGHT_FOUND]
    }
    for &k in x.walkers {walker_make(x,&k,&failed)}
    for &k in x.walks {
        k.x=x
        walker_make(x,&k.walk,&failed)
    }
    for &c in x.checks {c.x=x}
    x.commit.x=x
    for &p in x.peers {
        p.exchange=x
        make_into(x,&p.flights,BATCHES*ASK_ENTRIES,&failed)
        make_into(x,&p.serve,BATCHES*(ASK_ENTRIES+1),&failed)
        make_into(x,&p.send,SEND_BYTES,&failed)
        make_into(x,&p.node,store.CHUNK_MAX,&failed)
        make_into(x,&p.control,CONTROL_BYTES,&failed)
        make_into(x,&p.assembly[LANE_CONTROL],CONTROL_BYTES,&failed)
        make_into(x,&p.assembly[LANE_DATA],MSG_CHUNK_MAX,&failed)
    }
    for &q in x.queries {
        make_into(x,&q.names,NAMES_PER_REPLY,&failed)
        make_into(x,&q.name_bytes,NAMES_PER_REPLY*store.NAME_MAX,&failed)
    }
    if failed {destroy(x);return .Out_Of_Memory}
    return .None
}

@(private)
walker_make :: proc(x:^Exchange,k:^Walker,failed:^bool) {
    k.s=x.desc.store
    buffer,e:=make([]u8,store.CHUNK_MAX,x.allocator)
    found,f:=make([]Walk_Found,WALK_AHEAD+PREFETCH_NODES,x.allocator)
    if e!=nil || f!=nil {failed^=true}
    k.buffer,k.found=buffer,found
}

// Wakes every fetch with Closed, waits for the jobs it runs and frees once no
// fetch waits; the owner stops calling the exchange first and calls this from
// the thread that pumps.
destroy :: proc(x:^Exchange) {
    sync.mutex_lock(&x.lock)
    x.closing=true
    sync.cond_broadcast(&x.changed)
    for x.waiting>0 {sync.cond_wait(&x.changed,&x.lock)}
    for &p in x.peers {sync.atomic_store(&p.stop,true)}
    work_wait_all(x)
    sync.mutex_unlock(&x.lock)
    for &p in x.peers {
        delete(p.flights,x.allocator);delete(p.serve,x.allocator)
        delete(p.send,x.allocator)
        delete(p.node,x.allocator);delete(p.control,x.allocator)
        for a in p.assembly {delete(a,x.allocator)}
    }
    for q in x.queries {delete(q.names,x.allocator);delete(q.name_bytes,x.allocator)}
    for k in x.walkers {delete(k.buffer,x.allocator);delete(k.found,x.allocator)}
    delete(x.walkers,x.allocator);delete(x.receive_bytes,x.allocator);delete(x.light_found,x.allocator)
    for k in x.walks {delete(k.walk.buffer,x.allocator);delete(k.walk.found,x.allocator)}
    delete(x.wants,x.allocator);delete(x.order,x.allocator);delete(x.want_slots,x.allocator);delete(x.attention,x.allocator);delete(x.peers,x.allocator)
    delete(x.needs,x.allocator);delete(x.need_slots,x.allocator);delete(x.need_free,x.allocator)
    delete(x.queries,x.allocator);delete(x.receives,x.allocator);delete(x.walks,x.allocator)
    delete(x.checks,x.allocator);delete(x.found,x.allocator);delete(x.commit.items,x.allocator)
    x^={}
}

// Starts exchanging with a connection of h from its start, when its Connected
// command comes: a message on it that began before is not read from its middle.
// The host must carry the channels of the exchange at Desc.channel.
peer_add :: proc(x:^Exchange,h:^wire.Host,connection:wire.Connection) -> Error {
    sync.mutex_guard(&x.lock)
    if h==nil || connection==0 || x.desc.channel+CHANNELS>h.channel_count {return .Invalid}
    for lane in 0..<CHANNELS {
        if h.channels[x.desc.channel+lane].kind!=.Reliable {return .Invalid}
    }
    if peer_find(x,h,connection)>=0 {return .None}
    for &p,i in x.peers {
        if p.used {continue}
        peer_reset(&p)
        p.used,p.host,p.connection=true,h,connection
        clear_peer_bits(x,i)
        x.dirty,x.ask_due=true,true
        return .None
    }
    return .Full
}

// Stops exchanging with a connection: what it gave stays, what it was asked goes to others.
peer_remove :: proc(x:^Exchange,h:^wire.Host,connection:wire.Connection) {
    sync.mutex_guard(&x.lock)
    if i:=peer_find(x,h,connection);i>=0 {peer_drop(x,i)}
    signal(x)
}

peer_progress :: proc(x:^Exchange,h:^wire.Host,connection:wire.Connection) -> (Peer_Progress,bool) {
    sync.mutex_guard(&x.lock)
    i:=peer_find(x,h,connection)
    if i<0 {return {},false}
    p:=&x.peers[i]
    return {receive_rate=p.receive_rate,send_rate=p.send_rate,received=p.received,sent=p.sent,lies=p.lies,refused=p.refused,bad=p.bad},true
}

@(private)
peer_find :: proc(x:^Exchange,h:^wire.Host,connection:wire.Connection) -> int {
    for p,i in x.peers {
        if p.used && !p.draining && p.host==h && p.connection==connection {return i}
    }
    return -1
}

// A slot free again, its buffers kept.
@(private)
peer_reset :: proc(p:^Peer) {
    keep:=Peer{exchange=p.exchange,flights=p.flights,serve=p.serve,send=p.send,node=p.node,control=p.control,assembly=p.assembly,epoch=p.epoch+1}
    p^=keep
}

@(private)
peer_drop :: proc(x:^Exchange,i:int) {
    p:=&x.peers[i]
    flights_release(x,i)
    for &q in x.queries {
        if q.used && q.kind==.Names && q.peer==i {q.peer=-1}
    }
    clear_peer_bits(x,i)
    if sync.atomic_load(&p.serving) {
        // Its serve job still holds the slot: it frees once the job ends.
        sync.atomic_store(&p.stop,true)
        p.draining=true
        p.epoch+=1
    } else {
        peer_reset(p)
    }
    x.dirty=true
}

// What a peer was marked for leaves with it, and never passes to the next peer in its slot.
@(private)
clear_peer_bits :: proc(x:^Exchange,i:int) {
    mask:=~(u64(1)<<uint(i))
    for &w in x.wants {
        w.wrong&=mask
        w.lack&=mask
        if w.alias_peer==i {w.alias_peer=-1}
    }
    for &n in x.needs {n.lack&=mask}
    for &q in x.queries {q.asked&=mask;q.answered&=mask}
}

// A peer that sent what no peer sends: neither asked nor served any more.
@(private)
peer_bad :: proc(x:^Exchange,i:int) {
    p:=&x.peers[i]
    p.refused+=1
    if p.bad {return}
    flights_release(x,i)
    p.bad=true
    sync.atomic_store(&p.stop,true)
    x.dirty=true
}

// Hands a command of h to the exchange: true when it was a message on its channels.
receive :: proc(x:^Exchange,h:^wire.Host,command:wire.Command) -> bool {
    if command.kind!=.Message {return false}
    lane:=int(command.channel)-x.desc.channel
    if lane<0 || lane>=CHANNELS {return false}
    sync.mutex_guard(&x.lock)
    i:=peer_find(x,h,command.connection)
    if i<0 {return true}
    p:=&x.peers[i]
    if p.bad {return true}
    if p.assembled[lane]==0 && !p.overflow[lane] && !command.more {
        message(x,i,lane,command.data)
    } else {
        buffer:=p.assembly[lane]
        if !p.overflow[lane] && p.assembled[lane]+len(command.data)<=len(buffer) {
            copy(buffer[p.assembled[lane]:],command.data)
            p.assembled[lane]+=len(command.data)
        } else {
            p.overflow[lane]=true
        }
        if !command.more {
            whole:=buffer[:p.assembled[lane]]
            if p.overflow[lane] {peer_bad(x,i)} else {message(x,i,lane,whole)}
            p.assembled[lane],p.overflow[lane]=0,false
        }
    }
    signal(x)
    return true
}

// Sends what is due: answers, pieces served and the next requests. now is in
// seconds and must not go back.
update :: proc(x:^Exchange,now:f64) {
    sync.mutex_guard(&x.lock)
    x.now=max(x.now,now)
    work_collect(x)
    for &p,i in x.peers {
        if !p.used {continue}
        if p.draining {
            if !sync.atomic_load(&p.serving) {peer_reset(&p)}
            continue
        }
        control_flush(x,i)
        if !p.bad {serve_pump(x,i)}
    }
    asking(x)
    settle(x)
    queries_send(x)
    rates(x)
    signal(x)
}

@(private)
rates :: proc(x:^Exchange) {
    dt:=x.now-x.rate_time
    if dt<0.1 {return}
    x.rate_time=x.now
    a:=min(dt/RATE_SECONDS,1)
    for &p in x.peers {
        if !p.used {continue}
        p.receive_rate+=a*(f64(p.received-p.received_mark)/dt-p.receive_rate)
        p.send_rate+=a*(f64(p.sent-p.sent_mark)/dt-p.send_rate)
        p.received_mark,p.sent_mark=p.received,p.sent
    }
}

@(private)
signal :: proc(x:^Exchange) {
    if !x.dirty {return}
    x.dirty=false
    sync.cond_broadcast(&x.changed)
}

// Wants an object by its root, or a blob by its address: asks connected peers
// for what the store lacks of it, most important first. Asking again raises
// its priority. A want stays until forget, also once complete.
want :: proc(x:^Exchange,address:store.Hash,priority:=0) -> Error {
    sync.mutex_guard(&x.lock)
    i,error:=want_add(x,address,priority)
    if error==.None {x.wants[i].wanted=true}
    return error
}

forget :: proc(x:^Exchange,address:store.Hash) {
    sync.mutex_guard(&x.lock)
    if i:=want_find(x,address);i>=0 {
        x.wants[i].wanted=false
        if x.wants[i].waiters==0 {want_release(x,i)}
    }
}

progress :: proc(x:^Exchange,address:store.Hash) -> (Progress,bool) {
    sync.mutex_guard(&x.lock)
    i:=want_find(x,address)
    if i<0 {return {},false}
    w:=&x.wants[i]
    return {state=w.state,here=w.here,total=w.total,error=w.error,store_error=w.store_error},true
}

// Returns once the object or blob is complete in the store, or once no
// connected peer has it (Missing). For job threads: the owner keeps calling update meanwhile.
fetch :: proc(x:^Exchange,address:store.Hash,priority:=0) -> Error {
    sync.mutex_guard(&x.lock)
    address:=address
    return fetch_set(x,{address},priority)
}

// fetch of many objects or blobs: wants them together, so they arrive in few round
// trips, and returns once all are complete, at the first that no connected
// peer has (Missing) or at the first error.
fetch_all :: proc(x:^Exchange,addresses:[]store.Hash,priority:=0) -> Error {
    sync.mutex_guard(&x.lock)
    return fetch_set(x,addresses,priority)
}

// Returns the address peers name with namespace and name once what it names
// is complete in the store, or Missing once no connected peer names it or has it.
fetch_ref :: proc(x:^Exchange,namespace,name:string,priority:=0) -> (store.Hash,Error) {
    names:=[1]string{name}
    addresses:[1]store.Hash
    error:=fetch_refs(x,namespace,names[:],addresses[:],priority)
    return addresses[0],error
}

// fetch_ref of many names, asked together: addresses (as long as names) gets
// the address of each name peers name, {} for one none names, and what they
// name is fetched as with fetch_all. Missing when a name or an object is missing.
fetch_refs :: proc(x:^Exchange,namespace:string,names:[]string,addresses:[]store.Hash,priority:=0) -> Error {
    sync.mutex_guard(&x.lock)
    if len(addresses)!=len(names) {return .Invalid}
    slice.zero(addresses)
    if x.closing {return .Closed}
    Held :: struct {query,name:int}
    held:[FETCH_WINDOW]Held
    count,next:=0,0
    result:Error
    x.waiting+=1
    for {
        for next<len(names) && count<FETCH_WINDOW {
            q,error:=query_add(x,.Ref,namespace,names[next],-1)
            if error==.Full && count>0 {break}
            if error!=.None {result=error;break}
            x.queries[q.index].waiters+=1
            held[count]={int(q.index),next}
            count+=1
            next+=1
        }
        for k:=0;k<count && result==.None; {
            slot:=&x.queries[held[k].query]
            if slot.state==.Waiting {k+=1;continue}
            if slot.state==.Found {addresses[held[k].name]=slot.address} else {result=.Missing}
            slot.waiters-=1
            slot.ended=true
            count-=1
            held[k]=held[count]
        }
        if x.closing || result!=.None || count==0 && next==len(names) {break}
        sync.cond_wait(&x.changed,&x.lock)
    }
    for h in held[:count] {
        x.queries[h.query].waiters-=1
        x.queries[h.query].ended=true
    }
    x.waiting-=1
    if x.closing {
        sync.cond_broadcast(&x.changed)
        return .Closed
    }
    if result!=.None {return result}
    return fetch_set(x,addresses,priority)
}

// Waits on a window of the addresses at once, wanting the next as each completes.
@(private)
fetch_set :: proc(x:^Exchange,addresses:[]store.Hash,priority:int) -> Error {
    if x.closing {return .Closed}
    Held :: struct {want:int,misses:u32}
    held:[FETCH_WINDOW]Held
    count,next:=0,0
    result:Error
    x.waiting+=1
    for {
        for next<len(addresses) && count<FETCH_WINDOW {
            i,error:=want_add(x,addresses[next],priority)
            if error==.Full && count>0 {break}
            if error!=.None {result=error;break}
            x.wants[i].waiters+=1
            held[count]={i,x.wants[i].misses}
            count+=1
            next+=1
        }
        for k:=0;k<count && result==.None; {
            w:=&x.wants[held[k].want]
            switch {
            case w.state==.Complete:
                fetch_let_go(x,held[k].want)
                count-=1
                held[k]=held[count]
                continue
            case w.state==.Failed: result=w.error
            case w.state==.Missing || w.misses!=held[k].misses: result=.Missing
            }
            k+=1
        }
        if x.closing || result!=.None || count==0 && next==len(addresses) {break}
        sync.cond_wait(&x.changed,&x.lock)
    }
    for h in held[:count] {fetch_let_go(x,h.want)}
    x.waiting-=1
    if x.closing {
        sync.cond_broadcast(&x.changed)
        return .Closed
    }
    return result
}

@(private)
fetch_let_go :: proc(x:^Exchange,i:int) {
    w:=&x.wants[i]
    w.waiters-=1
    if !w.wanted && w.waiters==0 {want_release(x,i)}
}

// The addresses of every want, in progress or kept, into buffer (Desc.wants
// long): what the owner's store lease holds alive against a sweep. A want
// whose root is known gives the root, which reaches every chunk it received.
want_addresses :: proc(x:^Exchange,buffer:[]store.Hash) -> []store.Hash {
    sync.mutex_guard(&x.lock)
    n:=min(x.want_count,len(buffer))
    for k in 0..<n {
        w:=&x.wants[x.order[k]]
        buffer[k]=w.root if w.rooted else w.address
    }
    return buffer[:n]
}

// Asks every connected peer for the address namespace and name name.
ref_ask :: proc(x:^Exchange,namespace,name:string) -> (Query,Error) {
    sync.mutex_guard(&x.lock)
    return query_add(x,.Ref,namespace,name,-1)
}

// Asks a peer for the names of a namespace after after, at most NAMES_PER_REPLY.
names_ask :: proc(x:^Exchange,h:^wire.Host,connection:wire.Connection,namespace:string,after:="") -> (Query,Error) {
    sync.mutex_guard(&x.lock)
    i:=peer_find(x,h,connection)
    if i<0 {return {},.Invalid}
    return query_add(x,.Names,namespace,after,i)
}

query_result :: proc(x:^Exchange,q:Query) -> (Query_Result,bool) {
    sync.mutex_guard(&x.lock)
    slot:=query_slot(x,q)
    if slot==nil {return {},false}
    return {state=slot.state,address=slot.address,names=slot.names[:slot.name_count],more=slot.more},true
}

query_end :: proc(x:^Exchange,q:Query) {
    sync.mutex_guard(&x.lock)
    if slot:=query_slot(x,q);slot!=nil && slot.waiters==0 {slot.ended=true}
}

@(private)
query_slot :: proc(x:^Exchange,q:Query) -> ^Query_Slot {
    if int(q.index)>=len(x.queries) {return nil}
    slot:=&x.queries[q.index]
    if !slot.used || slot.ended || slot.generation!=q.generation {return nil}
    return slot
}

@(private)
query_add :: proc(x:^Exchange,kind:Query_Kind,namespace,name:string,peer:int) -> (Query,Error) {
    if !store.name_valid(namespace) || !(store.name_valid(name) || kind==.Names && name=="") {return {},.Invalid}
    for &slot,i in x.queries {
        if slot.used {continue}
        generation:=slot.generation+1
        names,bytes:=slot.names,slot.name_bytes
        slot={used=true,generation=generation,kind=kind,peer=peer,names=names,name_bytes=bytes}
        copy(slot.namespace[:],namespace)
        copy(slot.name[:],name)
        slot.namespace_len,slot.name_len=len(namespace),len(name)
        x.dirty=true
        return {u32(i),generation},.None
    }
    return {},.Full
}

@(private)
connected_mask :: proc(x:^Exchange) -> (mask:u64) {
    for p,i in x.peers {
        if p.used && !p.bad {mask|=1<<uint(i)}
    }
    return
}

@(private)
queries_send :: proc(x:^Exchange) {
    connected:=connected_mask(x)
    for &q in x.queries {
        if q.used && q.ended && q.asked&~q.answered&connected==0 {
            q.used=false
            x.dirty=true // a fetch_refs may wait for the slot
        }
        if !q.used || q.ended || q.state!=.Waiting {continue}
        namespace,name:=string(q.namespace[:q.namespace_len]),string(q.name[:q.name_len])
        targets:=connected
        if q.kind==.Names {targets=q.peer<0?0:connected&(u64(1)<<uint(q.peer))}
        for &p,i in x.peers {
            bit:=u64(1)<<uint(i)
            cost:=q.kind==.Ref?1:NAMES_CREDITS
            if targets&bit==0 || q.asked&bit!=0 || p.queries+cost>QUERY_CREDITS {continue}
            buffer:[MSG_NAMES_GET_MAX]u8
            message:=encode_question(buffer[:],q.kind==.Ref?MSG_REF_GET:MSG_NAMES_GET,namespace,name)
            if !control_append(&p,message) {continue}
            q.asked|=bit
            p.queries+=cost
        }
        if targets&~q.answered==0 {
            q.state=.Not_Found
            x.dirty=true
        }
    }
}

// Queues a message on the control channel of a peer; false when it has no room.
@(private)
control_append :: proc(p:^Peer,message:[]u8) -> bool {
    need:=2+len(message)
    if p.control_end+need>len(p.control) && p.control_start>0 {
        copy(p.control,p.control[p.control_start:p.control_end])
        p.control_end-=p.control_start
        p.control_start=0
    }
    if p.control_end+need>len(p.control) {return false}
    put_u16(p.control[p.control_end:],u16(len(message)))
    copy(p.control[p.control_end+2:],message)
    p.control_end+=need
    return true
}

@(private)
control_flush :: proc(x:^Exchange,i:int) {
    p:=&x.peers[i]
    for p.control_start<p.control_end {
        size:=int(get_u16(p.control[p.control_start:]))
        message:=p.control[p.control_start+2:][:size]
        if wire.message_send(p.host,p.connection,x.desc.channel+LANE_CONTROL,message)!=.None {break}
        p.control_start+=2+size
    }
    if p.control_start==p.control_end {p.control_start,p.control_end=0,0}
}
