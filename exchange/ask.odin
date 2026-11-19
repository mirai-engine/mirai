package exchange

import "base:intrinsics"
import "core:mem"
import "core:slice"
import "mirai:store"
import wire "mirai:net"

@(private)
want_find :: proc(x:^Exchange,address:store.Hash) -> int {
    for k in 0..<x.want_count {
        if x.wants[x.order[k]].address==address {return x.order[k]}
    }
    return -1
}

@(private)
want_add :: proc(x:^Exchange,address:store.Hash,priority:int) -> (int,Error) {
    if i:=want_find(x,address);i>=0 {
        w:=&x.wants[i]
        if priority>w.priority {
            w.priority=priority
            order_sort(x)
        }
        // A blob kept complete may have been swept since: success is what the store says now.
        if w.state==.Complete && !store.has(x.desc.store,w.address) {
            want_begin(x,i)
            x.dirty=true
        }
        return i,.None
    }
    for &w,i in x.wants {
        if w.used {continue}
        generation:=w.generation+1
        have,asked:=w.have,w.asked
        w={used=true,generation=generation,address=address,priority=priority,order=x.sequence,table_peer=-1,have=have,asked=asked}
        x.sequence+=1
        x.order[x.want_count]=i
        x.want_count+=1
        order_sort(x)
        x.dirty=true
        want_begin(x,i)
        return i,.None
    }
    return -1,.Full
}

// From what the store has now: complete, being received, or nothing.
@(private)
want_begin :: proc(x:^Exchange,i:int) {
    w:=&x.wants[i]
    if store.has(x.desc.store,w.address) {
        want_complete(x,i)
        return
    }
    want_unknown(x,i)
    w.state=.Asking
    // A blob already being received resumes from the pieces it has.
    size,size_error:=store.blob_size(x.desc.store,w.address)
    if size_error==.None && size<=x.desc.max_blob_bytes {
        arena:mem.Arena
        if _,table_error:=store.blob_table(x.desc.store,w.address,scratch_arena(x,&arena));table_error==.None {table_known(x,i,-1,size)}
    }
}

@(private)
want_release :: proc(x:^Exchange,i:int) {
    receiver_stop(x,i)
    x.wants[i].used=false
    for k in 0..<x.want_count {
        if x.order[k]!=i {continue}
        copy(x.order[k:x.want_count-1],x.order[k+1:x.want_count])
        x.want_count-=1
        break
    }
}

// Most important first: higher priority, then asked earlier.
@(private)
order_sort :: proc(x:^Exchange) {
    order:=x.order[:x.want_count]
    for k in 1..<len(order) {
        for j:=k;j>0 && want_before(x,order[j],order[j-1]);j-=1 {
            order[j],order[j-1]=order[j-1],order[j]
        }
    }
}

@(private)
want_before :: proc(x:^Exchange,a,b:int) -> bool {
    wa,wb:=&x.wants[a],&x.wants[b]
    return wa.priority>wb.priority || wa.priority==wb.priority && wa.order<wb.order
}

@(private)
want_complete :: proc(x:^Exchange,i:int) {
    receiver_stop(x,i)
    w:=&x.wants[i]
    w.state=.Complete
    if size,error:=store.blob_size(x.desc.store,w.address);error==.None {w.size,w.here=size,size}
    w.known=true
    x.dirty=true
}

@(private)
want_fail :: proc(x:^Exchange,i:int,error:Error,store_error:store.Error) {
    receiver_stop(x,i)
    w:=&x.wants[i]
    w.state,w.error,w.store_error=.Failed,error,store_error
    x.dirty=true
}

// Back to asking for the table, with nothing of the blob kept.
@(private)
want_unknown :: proc(x:^Exchange,i:int) {
    receiver_stop(x,i)
    w:=&x.wants[i]
    w.known,w.size,w.count,w.had,w.here,w.table_peer=false,0,0,0,0,-1
    slice.zero(w.have)
    slice.zero(w.asked)
}

@(private)
bit_has :: #force_inline proc(bits:[]u64,i:int) -> bool {return bits[i>>6]&(u64(1)<<uint(i&63))!=0}
@(private)
bit_on :: #force_inline proc(bits:[]u64,i:int) {bits[i>>6]|=u64(1)<<uint(i&63)}
@(private)
bit_off :: #force_inline proc(bits:[]u64,i:int) {bits[i>>6]&=~(u64(1)<<uint(i&63))}

// The first piece from from on that is neither here nor asked; count when none.
@(private)
next_free :: proc(w:^Want,from:int) -> int {
    for word:=from>>6;word*64<w.count;word+=1 {
        free:=~(w.have[word]|w.asked[word])
        if word==from>>6 {free&=~u64(0)<<uint(from&63)}
        if free!=0 {return min(word*64+int(intrinsics.count_trailing_zeros(free)),w.count)}
    }
    return w.count
}

// The table of the want is in the store, from peer p (-1: found there):
// which pieces are here comes from the store.
@(private)
table_known :: proc(x:^Exchange,i:int,p:int,size:i64) {
    w:=&x.wants[i]
    w.known,w.size,w.count,w.table_peer=true,size,store.piece_count(size),p
    slice.zero(w.have)
    slice.zero(w.asked)
    if store.has(x.desc.store,w.address) || w.count==0 {
        want_complete(x,i)
        return
    }
    arena:mem.Arena
    missing,error:=store.receive_missing(x.desc.store,w.address,scratch_arena(x,&arena))
    if error!=.None {
        if store.has(x.desc.store,w.address) {want_complete(x,i)} else {want_fail(x,i,.Store,error)}
        return
    }
    words:=(w.count+63)/64
    for k in 0..<words {w.have[k]=~u64(0)}
    if w.count%64!=0 {w.have[words-1]=(u64(1)<<uint(w.count%64))-1}
    w.had,w.here=w.count,size
    for m in missing {
        if m<0 || m>=w.count || !bit_has(w.have,m) {continue}
        bit_off(w.have,m)
        w.had-=1
        w.here-=i64(store.piece_size(size,m))
    }
    if p>=0 {
        // The first pieces asked with the table come in the same answer.
        peer:=&x.peers[p]
        for k in 0..<peer.flight_count {
            f:=&peer.flights[(peer.flight_head+k)%len(peer.flights)]
            if f.want!=i || f.generation!=w.generation || !f.blob {continue}
            for n in int(f.first)..<min(int(f.first)+int(f.count),w.count) {bit_on(w.asked,n)}
        }
    }
    x.dirty=true
}

// Peer p gave a table, a piece or a size of the want that did not match: what
// it gave is gone and the want is asked of others.
@(private)
lie :: proc(x:^Exchange,i:int,p:int) {
    if p<0 {return}
    w:=&x.wants[i]
    bit:=u64(1)<<uint(p)
    if w.wrong&bit==0 {x.peers[p].lies+=1}
    w.wrong|=bit
    if !w.known && w.table_peer==p {w.table_peer=-1}
    peer:=&x.peers[p]
    for k in 0..<peer.flight_count {
        f:=&peer.flights[(peer.flight_head+k)%len(peer.flights)]
        if f.want==i {flight_release(x,p,f);f.want=-1}
    }
    x.dirty=true
}

// Gives back what a flight reserved, once: a late answer of a peer whose
// flight timed out does not release what another peer was asked since.
@(private)
flight_release :: proc(x:^Exchange,p:int,f:^Flight) {
    if f.want<0 || f.released {return}
    f.released=true
    w:=&x.wants[f.want]
    if !w.used || w.generation!=f.generation {return}
    if !w.known {
        if f.blob && w.table_peer==p {w.table_peer=-1}
        return
    }
    for n in int(f.first)..<min(int(f.first)+int(f.count),w.count) {
        if !bit_has(w.have,n) {bit_off(w.asked,n)}
    }
}

// What peer i was asked goes back to be asked of others; its requests stay counted.
@(private)
flights_release :: proc(x:^Exchange,i:int) {
    p:=&x.peers[i]
    for k in 0..<p.flight_count {flight_release(x,i,&p.flights[(p.flight_head+k)%len(p.flights)])}
}

@(private) FLIGHT_TABLE :: -1 // flight_of: the table of the want
@(private) FLIGHT_ANY :: -2   // flight_of: anything of the want

// Whether peer i was asked for piece index of want wi, or its table, or anything of it.
@(private)
flight_of :: proc(x:^Exchange,i,wi,index:int) -> bool {
    p:=&x.peers[i]
    w:=&x.wants[wi]
    for k in 0..<p.flight_count {
        f:=&p.flights[(p.flight_head+k)%len(p.flights)]
        if f.want!=wi || f.generation!=w.generation {continue}
        switch {
        case index==FLIGHT_ANY: return true
        case index==FLIGHT_TABLE: if f.blob {return true}
        case index>=int(f.first) && index<int(f.first)+int(f.count): return true
        }
    }
    return false
}

// Peer i made progress on want wi: what it was asked of it stays reserved.
@(private)
flights_heard :: proc(x:^Exchange,i,wi:int) {
    p:=&x.peers[i]
    for k in 0..<p.flight_count {
        f:=&p.flights[(p.flight_head+k)%len(p.flights)]
        if f.want==wi {f.heard=x.now}
    }
}

@(private)
batch_bytes :: proc(x:^Exchange,i:int) -> int {
    p:=&x.peers[i]
    rtt:=f64(0)
    if stats,ok:=wire.connection_stats(p.host,p.connection);ok {rtt=f64(stats.rtt)}
    return int(clamp(p.receive_rate*rtt,MIN_BATCH_BYTES,REQUEST_BYTES))
}

@(private)
asking :: proc(x:^Exchange) {
    connected:=connected_mask(x)
    for k in 0..<x.want_count {
        w:=&x.wants[x.order[k]]
        if w.state!=.Asking && w.state!=.Missing {continue}
        if w.lack!=0 && x.now-w.lack_since>=LACK_RETRY {w.lack=0}
        if connected&~(w.wrong|w.lack)==0 {
            if w.state==.Asking {
                w.state=.Missing
                w.misses+=1
                x.dirty=true
            }
        } else if w.state==.Missing {
            w.state=.Asking
        }
    }
    for &p,i in x.peers {
        if !p.used || p.bad {continue}
        for k in 0..<p.flight_count {
            f:=&p.flights[(p.flight_head+k)%len(p.flights)]
            if f.released || f.want<0 || x.now-f.heard<=STALL_SECONDS {continue}
            // No progress on the want: others are asked, and this peer not for a while.
            w:=&x.wants[f.want]
            if w.used && w.generation==f.generation {
                if w.lack==0 {w.lack_since=x.now}
                w.lack|=u64(1)<<uint(i)
            }
            flight_release(x,i,f)
        }
        if p.batches<BATCHES {batch_send(x,i)}
    }
}

// Asks peer i for the most important pieces nobody was asked for, up to what
// it carries in a round trip. A blob whose size is unknown counts only
// against the limits of a request, since most blobs are small: a batch
// carries as many as fit.
@(private)
batch_send :: proc(x:^Exchange,i:int) {
    p:=&x.peers[i]
    bit:=u64(1)<<uint(i)
    budget:=batch_bytes(x,i)/store.PIECE_BYTES
    pieces:=0 // what the request addresses, at most REQUEST_PIECES
    entries:[REQUEST_ENTRIES]Flight
    n:=0
    wants: for k in 0..<x.want_count {
        wi:=x.order[k]
        w:=&x.wants[wi]
        if w.state!=.Asking || (w.wrong|w.lack)&bit!=0 {continue}
        if !w.known {
            if w.table_peer>=0 || pieces+FIRST_PIECES>REQUEST_PIECES {continue}
            entries[n]={want=wi,generation=w.generation,first=0,count=FIRST_PIECES,blob=true,heard=x.now}
            n+=1
            pieces+=FIRST_PIECES
        } else {
            at:=0
            for n<REQUEST_ENTRIES && budget>0 && pieces<REQUEST_PIECES {
                start:=next_free(w,at)
                if start>=w.count {break}
                end:=start+1
                for end<w.count && end-start<min(budget,REQUEST_PIECES-pieces) && !bit_has(w.have,end) && !bit_has(w.asked,end) {end+=1}
                entries[n]={want=wi,generation=w.generation,first=u32(start),count=u32(end-start),heard=x.now}
                n+=1
                budget-=end-start
                pieces+=end-start
                at=end
            }
        }
        if n==REQUEST_ENTRIES || budget<=0 || pieces>=REQUEST_PIECES {break wants}
    }
    if n==0 {return}
    buffer:[MSG_REQUEST_MAX]u8
    out:=Writer{data=buffer[:]}
    write_u8(&out,MSG_REQUEST)
    write_u16(&out,u16(n))
    for e in entries[:n] {
        address:=x.wants[e.want].address
        write_u8(&out,e.blob?0:1)
        write_bytes(&out,address[:])
        write_u32(&out,e.first)
        write_u32(&out,e.count)
    }
    if !control_append(p,buffer[:out.n]) {return}
    for e in entries[:n] {
        w:=&x.wants[e.want]
        if e.blob {
            w.table_peer=i
        } else {
            for m in int(e.first)..<int(e.first+e.count) {bit_on(w.asked,m)}
        }
        p.flights[(p.flight_head+p.flight_count)%len(p.flights)]=e
        p.flight_count+=1
    }
    p.batch_sizes[(p.batch_head+p.batches)%BATCHES]=n
    p.batches+=1
}

@(private)
on_table :: proc(x:^Exchange,i:int,data:[]u8) {
    r:=Reader{data=data[1:],ok=true}
    address:=read_hash(&r)
    size:=i64(read_u64(&r))
    if !r.ok {peer_bad(x,i);return}
    wi:=want_find(x,address)
    if wi<0 || !flight_of(x,i,wi,FLIGHT_TABLE) {x.peers[i].refused+=1;return}
    w:=&x.wants[wi]
    if w.state!=.Asking && w.state!=.Missing || w.known || w.wrong&(u64(1)<<uint(i))!=0 {return}
    flights_heard(x,i,wi)
    if size<0 || size>x.desc.max_blob_bytes || len(data)!=MSG_TABLE_HEAD+store.piece_count(size)*size_of(store.Hash) {lie(x,wi,i);return}
    // A blob of FIRST_PIECES pieces or fewer comes whole, never with a table.
    if store.piece_count(size)<=FIRST_PIECES {lie(x,wi,i);return}
    pieces:=slice.reinterpret([]store.Hash,data[MSG_TABLE_HEAD:])
    switch error:=store.receive_begin(x.desc.store,address,size,pieces);error {
    case .None: table_known(x,wi,i,size)
    case .Corrupt,.Invalid_Argument: lie(x,wi,i)
    case .Missing,.Not_Here_Yet,.Wrong_Size,.Out_Of_Memory,.Io,.No_Space,.Unsupported_Layout: want_fail(x,wi,.Store,error)
    }
}

@(private)
on_piece :: proc(x:^Exchange,i:int,data:[]u8) {
    r:=Reader{data=data[1:],ok=true}
    address:=read_hash(&r)
    index:=int(read_u32(&r))
    piece:=data[min(MSG_PIECE_HEAD,len(data)):]
    if !r.ok || len(piece)==0 || len(piece)>store.PIECE_BYTES {peer_bad(x,i);return}
    wi:=want_find(x,address)
    if wi<0 || !flight_of(x,i,wi,index) {x.peers[i].refused+=1;return}
    w:=&x.wants[wi]
    if w.state!=.Asking && w.state!=.Missing || w.wrong&(u64(1)<<uint(i))!=0 {return}
    if !w.known || index>=w.count || bit_has(w.have,index) {return}
    flights_heard(x,i,wi)
    switch error:=want_piece(x,wi,index,piece);error {
    case .None:
        bit_on(w.have,index)
        bit_on(w.asked,index)
        w.had+=1
        w.here+=i64(len(piece))
        x.peers[i].received+=u64(len(piece))
        x.dirty=true
        if w.had==w.count {
            if store.has(x.desc.store,address) {want_complete(x,wi)} else {table_known(x,wi,w.table_peer,w.size)}
        }
    case .Corrupt,.Invalid_Argument:
        lie(x,wi,i)
    case .Wrong_Size:
        // The piece proves the size the table came with was wrong; the store
        // dropped that partial blob, and keeps a complete one published meanwhile.
        lie(x,wi,w.table_peer)
        if store.has(x.desc.store,address) {want_complete(x,wi)} else {want_unknown(x,wi)}
        x.dirty=true
    case .Missing:
        if store.has(x.desc.store,address) {want_complete(x,wi)} else {want_unknown(x,wi)}
    case .Not_Here_Yet,.Out_Of_Memory,.Io,.No_Space,.Unsupported_Layout:
        want_fail(x,wi,.Store,error)
    }
}

// Keeps a piece of want wi through its receiver, which it opens, closing the
// one that took no piece for longest when RECEIVERS are open.
@(private)
want_piece :: proc(x:^Exchange,wi,index:int,piece:[]u8) -> store.Error {
    w:=&x.wants[wi]
    if !w.receiving {
        if x.receivers>=RECEIVERS {
            oldest:=-1
            for &v,k in x.wants {
                if v.used && v.receiving && (oldest<0 || v.written<x.wants[oldest].written) {oldest=k}
            }
            if oldest>=0 {receiver_stop(x,oldest)}
        }
        // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
        receiver,error:=store.receiver_open(x.desc.store,w.address)
        w.receiver=receiver
        if error!=.None {return error}
        w.receiving=true
        x.receivers+=1
    }
    w.written=x.sequence
    x.sequence+=1
    return store.receiver_piece(&w.receiver,index,piece)
}

@(private)
receiver_stop :: proc(x:^Exchange,i:int) {
    w:=&x.wants[i]
    if !w.receiving {return}
    store.receiver_close(&w.receiver)
    w.receiver={}
    w.receiving=false
    x.receivers-=1
}

// A blob asked with its table, whole: taken when its bytes hash to its address.
@(private)
on_whole :: proc(x:^Exchange,i:int,data:[]u8) {
    r:=Reader{data=data[1:],ok=true}
    address:=read_hash(&r)
    if !r.ok {peer_bad(x,i);return}
    bytes:=data[MSG_WHOLE_HEAD:]
    wi:=want_find(x,address)
    if wi<0 || !flight_of(x,i,wi,FLIGHT_TABLE) {x.peers[i].refused+=1;return}
    w:=&x.wants[wi]
    if w.state!=.Asking && w.state!=.Missing || w.known || w.wrong&(u64(1)<<uint(i))!=0 {return}
    flights_heard(x,i,wi)
    if len(bytes)>FIRST_PIECES*store.PIECE_BYTES || i64(len(bytes))>x.desc.max_blob_bytes || store.address_of_bytes(bytes)!=address {lie(x,wi,i);return}
    if _,error:=store.put_bytes(x.desc.store,bytes);error!=.None {want_fail(x,wi,.Store,error);return}
    x.peers[i].received+=u64(len(bytes))
    want_complete(x,wi)
}

@(private)
on_lack :: proc(x:^Exchange,i:int,data:[]u8) {
    r:=Reader{data=data[1:],ok=true}
    address:=read_hash(&r)
    read_u32(&r)
    read_u32(&r)
    if !read_end(&r) {peer_bad(x,i);return}
    wi:=want_find(x,address)
    if wi<0 || !flight_of(x,i,wi,FLIGHT_ANY) {x.peers[i].refused+=1;return}
    w:=&x.wants[wi]
    if w.lack==0 {w.lack_since=x.now}
    w.lack|=u64(1)<<uint(i)
    if !w.known && w.table_peer==i {w.table_peer=-1}
    x.dirty=true
}

@(private)
on_done :: proc(x:^Exchange,i:int,data:[]u8) {
    p:=&x.peers[i]
    if len(data)!=1 || p.batches==0 {peer_bad(x,i);return}
    n:=p.batch_sizes[p.batch_head]
    p.batch_head=(p.batch_head+1)%BATCHES
    p.batches-=1
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
