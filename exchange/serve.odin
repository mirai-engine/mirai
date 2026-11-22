package exchange

import "core:slice"
import "core:sync"
import "mirai:store"
import wire "mirai:net"

// An ask is taken whole or refused whole: a peer keeps at most BATCHES in
// flight, so one with more is not one this end needs to answer. Nothing is
// verified on serve: the receiver checks every chunk and reports a bad one.
@(private)
on_ask :: proc(x:^Exchange,i:int,data:[]u8) {
    p:=&x.peers[i]
    r:=Reader{data=data[1:],ok=true}
    count:=int(read_u16(&r))
    if count==0 || count>ASK_ENTRIES || len(data)!=MSG_ASK_HEAD+count*ASK_ENTRY_BYTES {peer_bad(x,i);return}
    tail:=p.serve_tail
    if tail-sync.atomic_load(&p.serve_head)+count+1>len(p.serve) {p.refused+=1;return}
    for k in 0..<count {
        address:=read_hash(&r)
        budget:=read_u32(&r)
        p.serve[(tail+k)%len(p.serve)]={kind=.Ask,address=address,budget=budget}
    }
    p.serve[(tail+count)%len(p.serve)]={kind=.Done}
    sync.atomic_store(&p.serve_tail,tail+count+1)
}

// A receiver's report that a chunk this end sent failed its address: the copy
// is checked, and a damaged one is tombstoned, so it is lacked from now on and
// fetched again by whoever wants it.
@(private)
on_bad :: proc(x:^Exchange,i:int,data:[]u8) {
    r:=Reader{data=data[1:],ok=true}
    address:=read_hash(&r)
    if !read_end(&r) {peer_bad(x,i);return}
    for &c in x.checks {
        if c.used {continue}
        c.used,c.address=true,address
        sync.atomic_store(&c.done,false)
        work_run(x,check_job,&c,&c.counter)
        return
    }
    x.peers[i].refused+=1
}

// The serve job passes the first entry.
@(private)
serve_pop :: proc(p:^Peer) {
    sync.atomic_store(&p.serve_head,p.serve_head+1)
    p.started,p.sent_under,p.depth=false,0,0
}

@(private)
exposed :: proc(x:^Exchange,i:int,namespace:string) -> bool {
    return x.desc.expose!=nil && x.desc.expose(x.desc.user,peer_id(&x.peers[i]),namespace)
}

// An answer that finds no room is dropped: a peer keeps at most
// QUERY_CREDITS of questions waiting, whose answers always fit.
@(private)
on_ref_get :: proc(x:^Exchange,i:int,data:[]u8) {
    r:=Reader{data=data[1:],ok=true}
    namespace:=read_name(&r)
    name:=read_name(&r)
    if !read_end(&r) {peer_bad(x,i);return}
    address:store.Hash
    found:=false
    if exposed(x,i,namespace) {
        hash,error:=store.ref_get(x.desc.store,namespace,name)
        address,found=hash,error==.None
    }
    buffer:[MSG_REF_MAX]u8
    w:=Writer{data=buffer[:]}
    write_u8(&w,MSG_REF)
    write_name(&w,namespace)
    write_name(&w,name)
    write_u8(&w,found?1:0)
    write_bytes(&w,address[:])
    if !control_append(&x.peers[i],buffer[:w.n]) {x.peers[i].refused+=1}
}

// The names after after, sorted. Reading a namespace is the one answer the
// store allocates for.
@(private)
on_names_get :: proc(x:^Exchange,i:int,data:[]u8) {
    r:=Reader{data=data[1:],ok=true}
    namespace:=read_name(&r)
    after:=read_name(&r,empty=true)
    if !read_end(&r) {peer_bad(x,i);return}
    refs:[]store.Ref
    if exposed(x,i,namespace) {
        listed,error:=store.ref_list(x.desc.store,namespace,x.allocator)
        if error==.None {refs=listed}
    }
    defer store.ref_list_delete(refs,x.allocator)
    slice.sort_by(refs,proc(a,b:store.Ref) -> bool {return a.name<b.name})
    buffer:[MSG_NAMES_MAX]u8
    w:=Writer{data=buffer[:]}
    write_u8(&w,MSG_NAMES)
    write_name(&w,namespace)
    write_name(&w,after)
    more_at:=w.n
    write_u8(&w,0)
    count_at:=w.n
    write_u16(&w,0)
    count:=0
    body:=w.n
    for &ref in refs {
        if ref.name<=after {continue}
        if count==NAMES_PER_REPLY || w.n-body+1+len(ref.name)+32>NAMES_REPLY_BYTES {
            buffer[more_at]=1
            break
        }
        write_name(&w,ref.name)
        write_bytes(&w,ref.hash[:])
        count+=1
    }
    put_u16(buffer[count_at:],u16(count))
    if !control_append(&x.peers[i],buffer[:w.n]) {x.peers[i].refused+=1}
}

// Sends the answers the serve job of peer i made, in order, while its data
// channel has room, and hands the job more when it is idle.
@(private)
serve_pump :: proc(x:^Exchange,i:int) {
    p:=&x.peers[i]
    for {
        head:=p.send_head
        if head<sync.atomic_load(&p.send_tail) {
            at:=head%SEND_BYTES
            size:=int(u32(p.send[at])|u32(p.send[at+1])<<8|u32(p.send[at+2])<<16|u32(p.send[at+3])<<24)
            if size==0 {
                // The rest of the ring is empty: the next answer is at its start.
                sync.atomic_store(&p.send_head,head+SEND_BYTES-at)
                continue
            }
            message:=p.send[at+4:][:size]
            wire.message_send(p.host,p.connection,x.desc.channel+LANE_DATA,message,&p.out_sent)
            if p.out_sent<len(message) {return}
            if message[0]==MSG_CHUNK {p.sent+=u64(len(message)-MSG_CHUNK_HEAD)}
            p.out_sent=0
            sync.atomic_store(&p.send_head,head+4+(size+3)&~3)
            continue
        }
        if sync.atomic_load(&p.serving) || sync.atomic_load(&p.stop) {return}
        if !p.started && sync.atomic_load(&p.serve_head)==p.serve_tail {return}
        sync.atomic_store(&p.serving,true)
        work_run(x,serve_job,p,&p.serve_counter)
        if sync.atomic_load(&p.serving) {return}
    }
}

// Fills the ring of a peer with its next answers while it has room for the largest.
@(private)
serve_job :: proc(data:rawptr,worker:int) {
    p:=(^Peer)(data)
    defer sync.atomic_store(&p.serving,false)
    // A chunk tombstoned since is read again, not served from what was held.
    p.node_held=false
    NEED :: 4+(MSG_CHUNK_MAX+3)&~3
    for !sync.atomic_load(&p.stop) {
        tail:=p.send_tail
        free:=SEND_BYTES-(tail-sync.atomic_load(&p.send_head))
        at:=tail%SEND_BYTES
        if SEND_BYTES-at<NEED {
            // Too little before the end: the answer goes at the start.
            if free<SEND_BYTES-at+NEED {break}
            p.send[at],p.send[at+1],p.send[at+2],p.send[at+3]=0,0,0,0
            sync.atomic_store(&p.send_tail,tail+SEND_BYTES-at)
            continue
        }
        if free<NEED {break}
        n:=serve_build(p.exchange,p,p.send[at+4:][:MSG_CHUNK_MAX])
        if n==0 {break}
        p.send[at],p.send[at+1],p.send[at+2],p.send[at+3]=u8(n),u8(n>>8),u8(n>>16),u8(n>>24)
        sync.atomic_store(&p.send_tail,tail+4+(n+3)&~3)
    }
}

// Reads a chunk's stored frame into the message. One a restricted peer may not
// get is missing, before the store is read, so its answer tells nothing of it.
@(private)
serve_read :: proc(x:^Exchange,p:^Peer,out:[]u8,address:store.Hash) -> (size:int,error:store.Error) {
    if p.restricted && (x.desc.serve==nil || !x.desc.serve(x.desc.user,peer_id(p),address)) {return 0,.Missing}
    room:=out[MSG_CHUNK_HEAD:]
    bytes,codec,raw:=store.chunk_read_frame(x.desc.store,address,room) or_return
    if raw_data(bytes)!=raw_data(room) {copy(room,bytes)}
    encode_chunk_head(out,address,codec,raw)
    return MSG_CHUNK_HEAD+len(bytes),.None
}

// The bytes of a Chunk out holds, when they are a node as they are.
@(private)
chunk_node :: proc(out:[]u8,size:int) -> (n:store.Node_View,ok:bool) {
    if out[1+32]!=store.CODEC_NONE {return}
    parsed,error:=store.node_parse(out[MSG_CHUNK_HEAD:size])
    return parsed,error==.None
}

// The node at address of a stream, held until another is read.
@(private)
serve_node :: proc(x:^Exchange,p:^Peer,address:store.Hash) -> (n:store.Node_View,error:store.Error) {
    if p.node_held && p.node_address==address {return p.node_view,.None}
    p.node_held=false
    bytes:=store.chunk_read(x.desc.store,address,p.node) or_return
    if raw_data(bytes)!=raw_data(p.node) {copy(p.node,bytes)}
    n=store.node_parse(p.node[:len(bytes)]) or_return
    p.node_address,p.node_view,p.node_held=address,n,true
    return n,.None
}

// Writes the next answer of a peer into out: its size, 0 when there is none.
// Each entry is its chunk or a Lack; then, while their bytes fit its budget, the descendants of that chunk
// depth first, until one is missing.
@(private)
serve_build :: proc(x:^Exchange,p:^Peer,out:[]u8) -> int {
    for p.serve_head<sync.atomic_load(&p.serve_tail) {
        e:=&p.serve[p.serve_head%len(p.serve)]
        if e.kind==.Done {
            out[0]=MSG_DONE
            serve_pop(p)
            return 1
        }
        if !p.started {
            size,error:=serve_read(x,p,out,e.address)
            p.started=true
            if error!=.None {
                n:=encode_address(out,MSG_LACK,e.address)
                serve_pop(p)
                return n
            }
            if e.budget>0 {
                if _,node:=chunk_node(out,size);node {
                    p.stack[0]={address=e.address}
                    p.depth=1
                }
            }
            if p.depth==0 {serve_pop(p)}
            return size
        }
        for p.depth>0 {
            f:=&p.stack[p.depth-1]
            n,error:=serve_node(x,p,f.address)
            if error!=.None || f.index>=len(n.entries) {
                p.depth-=1
                continue
            }
            child:=n.entries[f.index]
            f.index+=1
            size,read_error:=serve_read(x,p,out,child.address)
            if read_error!=.None || p.sent_under+i64(size-MSG_CHUNK_HEAD)>i64(e.budget) {
                p.depth=0
                break
            }
            p.sent_under+=i64(size-MSG_CHUNK_HEAD)
            if n.level>0 && p.depth<WALK_DEPTH {
                if c,node:=chunk_node(out,size);node && c.level==n.level-1 {
                    p.stack[p.depth]={address=child.address}
                    p.depth+=1
                }
            }
            return size
        }
        serve_pop(p)
    }
    return 0
}
