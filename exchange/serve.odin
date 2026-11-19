package exchange

import "core:slice"
import "mirai:store"
import wire "mirai:net"

// An ask is taken whole or refused whole: a peer keeps at most BATCHES in
// flight, so one with more is not one this end needs to answer. Nothing is
// checked on serve: the receiver checks every chunk and reports a bad one.
@(private)
on_ask :: proc(x:^Exchange,i:int,data:[]u8) {
    p:=&x.peers[i]
    r:=Reader{data=data[1:],ok=true}
    count:=int(read_u16(&r))
    if count==0 || count>ASK_ENTRIES || len(data)!=MSG_ASK_HEAD+count*ASK_ENTRY_BYTES {peer_bad(x,i);return}
    if p.serve_count+count+1>len(p.serve) {p.refused+=1;return}
    for _ in 0..<count {
        address:=read_hash(&r)
        budget:=read_u32(&r)
        serve_push(p,{kind=.Ask,address=address,budget=budget})
    }
    serve_push(p,{kind=.Done})
}

// A receiver's report that a chunk this end sent failed its address: the copy
// is checked, and a damaged one is tombstoned, so it is lacked from now on and
// fetched again by whoever wants it.
@(private)
on_bad :: proc(x:^Exchange,i:int,data:[]u8) {
    r:=Reader{data=data[1:],ok=true}
    address:=read_hash(&r)
    if !read_end(&r) {peer_bad(x,i);return}
    store.chunk_check(x.desc.store,address)
    p:=&x.peers[i]
    if p.node_held && p.node_address==address {p.node_held=false}
}

@(private)
serve_push :: proc(p:^Peer,s:Serve) {
    p.serve[(p.serve_head+p.serve_count)%len(p.serve)]=s
    p.serve_count+=1
}

@(private)
serve_pop :: proc(p:^Peer) {
    p.serve_head=(p.serve_head+1)%len(p.serve)
    p.serve_count-=1
    p.started,p.aliased,p.sent_under,p.depth=false,false,0,0
}

@(private)
exposed :: proc(x:^Exchange,namespace:string) -> bool {
    return x.desc.expose!=nil && x.desc.expose(x.desc.expose_user,namespace)
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
    if exposed(x,namespace) {
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
    if exposed(x,namespace) {
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

// Streams the answers of peer i on its data channel while its queue has room.
@(private)
serve_pump :: proc(x:^Exchange,i:int) {
    p:=&x.peers[i]
    for {
        if p.out_len>0 {
            wire.message_send(p.host,p.connection,x.desc.channel+LANE_DATA,p.out[:p.out_len],&p.out_sent)
            if p.out_sent<p.out_len {return}
            p.out_len,p.out_sent=0,0
        }
        if !serve_build(x,i) {return}
    }
}

// The chunk at address read into the out buffer of p after a Chunk head, or why not.
@(private)
serve_read :: proc(x:^Exchange,p:^Peer,address:store.Hash) -> (size:int,error:store.Error) {
    room:=p.out[MSG_CHUNK_HEAD:]
    bytes:=store.chunk_read(x.desc.store,address,room) or_return
    if raw_data(bytes)!=raw_data(room) {copy(room,bytes)}
    return len(bytes),.None
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

// Writes the next answer of peer i into its out buffer; false when there is
// none. Each entry is its chunk, or the alias of a blob and then its root,
// or a Lack; then, while their bytes fit its budget, the descendants of that
// chunk depth first, until one is missing.
@(private)
serve_build :: proc(x:^Exchange,i:int) -> bool {
    p:=&x.peers[i]
    for p.serve_count>0 {
        e:=&p.serve[p.serve_head]
        if e.kind==.Done {
            p.out[0]=MSG_DONE
            p.out_len=1
            serve_pop(p)
            return true
        }
        if !p.started {
            size,error:=serve_read(x,p,e.address)
            if error==.Missing && !p.aliased {
                // A blob of several chunks: its alias, then its root. A blob of
                // one chunk is that chunk, whose address is the blob's.
                if root,found:=store.blob_root(x.desc.store,e.address);found {
                    p.out_len=MSG_ALIAS_BYTES
                    p.out[0]=MSG_ALIAS
                    copy(p.out[1:],e.address[:])
                    copy(p.out[33:],root[:])
                    e.address=root
                    p.aliased=true
                    return true
                }
            }
            p.started=true
            if error!=.None {
                p.out_len=encode_address(p.out,MSG_LACK,e.address)
                serve_pop(p)
                return true
            }
            encode_chunk_head(p.out,e.address,size)
            p.out_len=MSG_CHUNK_HEAD+size
            p.sent+=u64(size)
            if e.budget>0 {
                if _,parse_error:=store.node_parse(p.out[MSG_CHUNK_HEAD:][:size]);parse_error==.None {
                    p.stack[0]={address=e.address}
                    p.depth=1
                }
            }
            if p.depth==0 {serve_pop(p)}
            return true
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
            size,read_error:=serve_read(x,p,child.address)
            if read_error!=.None || p.sent_under+i64(size)>i64(e.budget) {
                p.depth=0
                break
            }
            p.sent_under+=i64(size)
            encode_chunk_head(p.out,child.address,size)
            p.out_len=MSG_CHUNK_HEAD+size
            p.sent+=u64(size)
            if n.level>0 && p.depth<WALK_DEPTH {
                if c,parse_error:=store.node_parse(p.out[MSG_CHUNK_HEAD:][:size]);parse_error==.None && c.level==n.level-1 {
                    p.stack[p.depth]={address=child.address}
                    p.depth+=1
                }
            }
            return true
        }
        serve_pop(p)
    }
    return false
}
