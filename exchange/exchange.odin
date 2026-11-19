package exchange

import "base:runtime"
import "core:mem"
import "core:slice"
import "core:sync"
import wire "mirai:net"
import "mirai:store"

// Blobs and refs between peers over the connections of net hosts that the
// owner runs. Requests are stateless, by address and runs of pieces: any peer
// that has the pieces answers, also from a blob it is still receiving. What is
// asked first is what matters most to the receiver; every piece goes through
// the store's receive path, so nothing unverified reaches a reader.
//
// The owner adds the CHANNELS of channels() to every host, gives each
// connection with peer_add, hands every Message command to receive and calls
// update once per frame, before host_update. Every procedure takes the lock
// of the Exchange, so fetch may wait on a job thread while the owner pumps.

CHANNELS :: 2
MAX_PEERS :: 64
REQUEST_ENTRIES :: 64     // blobs and runs one request asks for
REQUEST_BYTES :: 16<<20   // piece bytes one request asks for
BATCHES :: 2              // requests in flight to a peer
FIRST_PIECES :: 4         // pieces asked with the table of a blob: a blob of at most these comes whole
NAMES_PER_REPLY :: 128
MAX_BLOB_BYTES :: 1<<40   // the largest max_blob_bytes, and what a request may address

@(private) LANE_CONTROL :: 0 // requests, refs and their answers
@(private) LANE_DATA :: 1    // tables, pieces and the end of each request
@(private) CONTROL_BYTES :: 64<<10
@(private) DATA_QUEUE_BYTES :: 4<<20
@(private) NAMES_REPLY_BYTES :: 16<<10
@(private) MIN_BATCH_BYTES :: 1<<20
@(private) QUERY_CREDITS :: 32 // questions a peer keeps waiting: a ref costs one, a listing NAMES_CREDITS, so their answers fit in CONTROL_BYTES
@(private) NAMES_CREDITS :: 10
@(private) FETCH_WINDOW :: 256 // blobs or refs a blocking form waits on at once
@(private) LACK_RETRY :: 2.0    // s a peer that lacked a blob is not asked for it again
@(private) STALL_SECONDS :: 5.0 // s a peer keeps what it was asked of a want without progress on it, before others are asked
@(private) RATE_SECONDS :: 1.0  // time constant of the smoothed rates
@(private) RECEIVERS :: 8       // blobs held open while their pieces arrive
@(private) REQUEST_PIECES :: REQUEST_BYTES/store.PIECE_BYTES
@(private) MAX_PIECES :: MAX_BLOB_BYTES/store.PIECE_BYTES

// Whether peers may read the refs of namespace.
Expose :: #type proc(user:rawptr,namespace:string) -> bool

Desc :: struct {
    store:^store.Store,
    channel:int,        // index of the first of the CHANNELS channels in the channels of every host
    peers:int,          // connections at once, default 8, at most MAX_PEERS
    wants:int,          // blobs asked at once, default 256
    queries:int,        // ref questions at once, default 16
    max_blob_bytes:i64, // the largest blob taken and served, default 1 GiB: a table of its size is held per peer
    expose:Expose,      // nil exposes no namespace
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
    Complete, // in the store
    Missing,  // no connected peer has it now; asked again when a peer joins or after a while
    Failed,   // error
}

Progress :: struct {
    state:State,
    here:i64,   // bytes in the store
    total:i64,  // -1 until the table is known
    error:Error,
    store_error:store.Error,
}

Peer_Progress :: struct {
    receive_rate,send_rate:f64, // piece bytes per second, smoothed
    received,sent:u64,          // piece bytes
    lies:int,                   // blobs it gave a table, a piece or a size for that did not match
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
Want :: struct {
    address:store.Hash,
    used,wanted:bool,
    waiters:int,
    generation:u32,
    priority:int,
    order:u64,
    state:State,
    error:Error,
    store_error:store.Error,
    known:bool,
    size:i64,
    count,had:int,
    table_peer:int, // the peer asked for the table, or that gave it; -1
    wrong,lack:u64, // peers that lied about it, and that lack it
    lack_since:f64,
    misses:u32,     // times it went Missing
    have,asked:[]u64,
    here:i64,
    receiver:store.Receiver, // open while its pieces arrive
    receiving:bool,
    written:u64, // x.sequence when it last took a piece
}

@(private)
Flight :: struct {
    want:int,
    generation:u32,
    first,count:u32,
    blob:bool,
    released:bool, // what it reserved went back to be asked of others
    heard:f64,     // when it was sent or the peer last made progress on its want
}

@(private)
Serve_Kind :: enum u8 {Blob,Run,Done}

@(private)
Serve :: struct {kind:Serve_Kind,address:store.Hash,first,count:u32}

@(private)
Peer :: struct {
    used,bad:bool,
    host:^wire.Host,
    connection:wire.Connection,
    // Asking: the entries of the requests in flight, oldest first.
    flights:[]Flight,
    flight_head,flight_count:int,
    batch_sizes:[BATCHES]int,
    batch_head,batches:int,
    queries:int, // credits of the questions asked of it and not answered
    // Serving: the entries of the requests received, oldest first.
    serve:[]Serve,
    serve_head,serve_count:int,
    started:bool,
    cursor:u32,
    entry_size:i64,
    lack_first,lack_count:u32,
    out:[]u8,
    out_len,out_sent:int,
    reader:store.Reader, // the blob being served, while there is one
    reading:bool,
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
    receivers:int, // wants with their receiver open
    sequence:u64,
    peers:[]Peer,
    queries:[]Query_Slot,
    scratch:[]u8, // what the store hands back: a table, the missing pieces
    table_max:int, // pieces of the largest blob
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
    if d.max_blob_bytes<=0 {d.max_blob_bytes=1<<30}
    if d.peers>MAX_PEERS || d.max_blob_bytes>MAX_BLOB_BYTES {return .Invalid}
    x.table_max=store.piece_count(d.max_blob_bytes)
    words:=(x.table_max+63)/64
    failed:=false
    make_into :: proc(x:^Exchange,slot:^$T/[]$E,count:int,failed:^bool) {
        made,error:=make(T,count,x.allocator)
        if error!=nil {failed^=true;return}
        slot^=made
    }
    make_into(x,&x.wants,d.wants,&failed)
    make_into(x,&x.order,d.wants,&failed)
    make_into(x,&x.peers,d.peers,&failed)
    make_into(x,&x.queries,d.queries,&failed)
    make_into(x,&x.scratch,x.table_max*size_of(store.Hash)+64,&failed)
    if failed {destroy(x);return .Out_Of_Memory}
    for &w in x.wants {
        make_into(x,&w.have,words,&failed)
        make_into(x,&w.asked,words,&failed)
    }
    data_bytes:=max(MSG_TABLE_HEAD+x.table_max*size_of(store.Hash),MSG_WHOLE_HEAD+FIRST_PIECES*store.PIECE_BYTES)
    for &p in x.peers {
        make_into(x,&p.flights,BATCHES*REQUEST_ENTRIES,&failed)
        make_into(x,&p.serve,BATCHES*(REQUEST_ENTRIES+1),&failed)
        make_into(x,&p.out,data_bytes,&failed)
        make_into(x,&p.control,CONTROL_BYTES,&failed)
        make_into(x,&p.assembly[LANE_CONTROL],CONTROL_BYTES,&failed)
        make_into(x,&p.assembly[LANE_DATA],data_bytes,&failed)
    }
    for &q in x.queries {
        make_into(x,&q.names,NAMES_PER_REPLY,&failed)
        make_into(x,&q.name_bytes,NAMES_PER_REPLY*store.NAME_MAX,&failed)
    }
    if failed {destroy(x);return .Out_Of_Memory}
    return .None
}

// Wakes every fetch with Closed and frees once none waits; the owner stops
// calling the exchange first.
destroy :: proc(x:^Exchange) {
    sync.mutex_lock(&x.lock)
    x.closing=true
    sync.cond_broadcast(&x.changed)
    for x.waiting>0 {sync.cond_wait(&x.changed,&x.lock)}
    sync.mutex_unlock(&x.lock)
    for &w in x.wants {
        if w.receiving {store.receiver_close(&w.receiver)}
        delete(w.have,x.allocator);delete(w.asked,x.allocator)
    }
    for &p in x.peers {
        if p.reading {store.reader_close(&p.reader)}
        delete(p.flights,x.allocator);delete(p.serve,x.allocator);delete(p.out,x.allocator);delete(p.control,x.allocator)
        for a in p.assembly {delete(a,x.allocator)}
    }
    for q in x.queries {delete(q.names,x.allocator);delete(q.name_bytes,x.allocator)}
    delete(x.wants,x.allocator);delete(x.order,x.allocator);delete(x.peers,x.allocator)
    delete(x.queries,x.allocator);delete(x.scratch,x.allocator)
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
        x.dirty=true
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
        if p.used && p.host==h && p.connection==connection {return i}
    }
    return -1
}

@(private)
peer_reset :: proc(p:^Peer) {
    serve_stop(p)
    keep:=Peer{flights=p.flights,serve=p.serve,out=p.out,control=p.control,assembly=p.assembly}
    p^=keep
}

@(private)
peer_drop :: proc(x:^Exchange,i:int) {
    p:=&x.peers[i]
    flights_release(x,i)
    for &w in x.wants {
        if w.used && w.table_peer==i {w.table_peer=-1}
    }
    for &q in x.queries {
        if q.used && q.kind==.Names && q.peer==i {q.peer=-1}
    }
    clear_peer_bits(x,i)
    peer_reset(p)
    x.dirty=true
}

@(private)
clear_peer_bits :: proc(x:^Exchange,i:int) {
    mask:=~(u64(1)<<uint(i))
    for &w in x.wants {w.wrong&=mask;w.lack&=mask}
    for &q in x.queries {q.asked&=mask;q.answered&=mask}
}

// A peer that sent what no peer sends: neither asked nor served any more.
@(private)
peer_bad :: proc(x:^Exchange,i:int) {
    p:=&x.peers[i]
    p.refused+=1
    if p.bad {return}
    flights_release(x,i)
    for &w in x.wants {
        if w.used && w.table_peer==i && !w.known {w.table_peer=-1}
    }
    p.bad=true
    p.serve_count,p.out_len,p.out_sent,p.started=0,0,0,false
    serve_stop(p)
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
            if p.overflow[lane] {oversized(x,i,lane,whole)} else {message(x,i,lane,whole)}
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
    for &p,i in x.peers {
        if !p.used {continue}
        control_flush(x,i)
        if !p.bad {serve_pump(x,i)}
    }
    asking(x)
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

// Wants a blob: asks connected peers for it, most important first. Asking
// again raises its priority. A want stays until forget, also once complete.
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
    return {state=w.state,here=w.here,total=w.known?w.size:-1,error=w.error,store_error=w.store_error},true
}

// Returns once the blob is complete in the store, or once no connected peer
// has it (Missing). For job threads: the owner keeps calling update meanwhile.
fetch :: proc(x:^Exchange,address:store.Hash,priority:=0) -> Error {
    sync.mutex_guard(&x.lock)
    address:=address
    return fetch_set(x,{address},priority)
}

// fetch of many blobs: wants them together, so they arrive in few round
// trips, and returns once all are complete, at the first that no connected
// peer has (Missing) or at the first error.
fetch_all :: proc(x:^Exchange,addresses:[]store.Hash,priority:=0) -> Error {
    sync.mutex_guard(&x.lock)
    return fetch_set(x,addresses,priority)
}

// Returns the address peers name with namespace and name once its blob is
// complete in the store, or Missing once no connected peer names it or has it.
fetch_ref :: proc(x:^Exchange,namespace,name:string,priority:=0) -> (store.Hash,Error) {
    names:=[1]string{name}
    addresses:[1]store.Hash
    error:=fetch_refs(x,namespace,names[:],addresses[:],priority)
    return addresses[0],error
}

// fetch_ref of many names, asked together: addresses (as long as names) gets
// the address of each name peers name, {} for one none names, and the blobs
// are fetched as with fetch_all. Missing when a name or a blob is missing.
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
// long): what the owner's store lease holds alive against a sweep.
want_addresses :: proc(x:^Exchange,buffer:[]store.Hash) -> []store.Hash {
    sync.mutex_guard(&x.lock)
    n:=min(x.want_count,len(buffer))
    for k in 0..<n {buffer[k]=x.wants[x.order[k]].address}
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

// An arena over the scratch buffer, for one answer of the store.
@(private)
scratch_arena :: proc(x:^Exchange,arena:^mem.Arena) -> runtime.Allocator {
    mem.arena_init(arena,x.scratch)
    return mem.arena_allocator(arena)
}
