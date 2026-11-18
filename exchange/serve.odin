package exchange

import "core:mem"
import "core:slice"
import "mirai:store"
import wire "mirai:net"

// A request is taken whole or refused whole: a peer keeps at most BATCHES in
// flight, so one with more is not one this end needs to answer.
@(private)
on_request :: proc(x:^Exchange,i:int,data:[]u8) {
    p:=&x.peers[i]
    r:=Reader{data=data[1:],ok=true}
    count:=int(read_u16(&r))
    if count==0 || count>REQUEST_ENTRIES || len(data)!=MSG_REQUEST_HEAD+count*ENTRY_BYTES {peer_bad(x,i);return}
    pieces:=0
    for _ in 0..<count {
        kind:=read_u8(&r)
        read_hash(&r)
        first:=read_u32(&r)
        n:=read_u32(&r)
        if kind>1 || kind==1 && n==0 || u64(first)+u64(n)>u64(x.table_max) || n>REQUEST_PIECES {peer_bad(x,i);return}
        pieces+=int(n)
    }
    if pieces>REQUEST_PIECES {peer_bad(x,i);return}
    if p.serve_count+count+1>len(p.serve) {p.refused+=1;return}
    r=Reader{data=data[MSG_REQUEST_HEAD:],ok=true}
    for _ in 0..<count {
        kind:=read_u8(&r)
        address:=read_hash(&r)
        first:=read_u32(&r)
        n:=read_u32(&r)
        serve_push(p,{kind=kind==0?.Blob:.Run,address=address,first=first,count=n})
    }
    serve_push(p,{kind=.Done})
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
    p.started,p.lack_count=false,0
}

@(private)
exposed :: proc(x:^Exchange,namespace:string) -> bool {
    return x.desc.expose!=nil && x.desc.expose(x.desc.expose_user,namespace)
}

// An answer that finds no room is dropped: a peer keeps at most
// QUERIES_PER_PEER questions waiting, which always fit.
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
// store allocates for: it reads a folder.
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

// Writes the next answer of peer i into its out buffer; false when there is none.
@(private)
serve_build :: proc(x:^Exchange,i:int) -> bool {
    p:=&x.peers[i]
    s:=x.desc.store
    for p.serve_count>0 {
        e:=p.serve[p.serve_head]
        if e.kind==.Done {
            p.out[0]=MSG_DONE
            p.out_len=1
            serve_pop(p)
            return true
        }
        if !p.started {
            p.started,p.cursor,p.lack_count=true,e.first,0
            size,error:=store.blob_size(s,e.address)
            if error!=.None || size>x.desc.max_blob_bytes {
                p.out_len=encode_lack(p.out,e.address,e.first,e.kind==.Blob?0:e.count)
                serve_pop(p)
                return true
            }
            p.entry_size=size
            if e.kind==.Blob {
                arena:mem.Arena
                pieces,table_error:=store.blob_table(s,e.address,scratch_arena(x,&arena))
                if table_error!=.None || len(pieces)!=store.piece_count(size) {
                    p.out_len=encode_lack(p.out,e.address,0,0)
                    serve_pop(p)
                    return true
                }
                address:=e.address
                w:=Writer{data=p.out}
                write_u8(&w,MSG_TABLE)
                write_bytes(&w,address[:])
                write_u64(&w,u64(size))
                write_bytes(&w,slice.to_bytes(pieces))
                p.out_len=w.n
                return true
            }
        }
        end:=u32(min(i64(e.first)+i64(e.count),i64(store.piece_count(p.entry_size))))
        for p.cursor<end {
            index:=p.cursor
            bytes:=store.piece_size(p.entry_size,int(index))
            piece:=p.out[MSG_PIECE_HEAD:][:bytes]
            if store.read(s,e.address,i64(index)*store.PIECE_BYTES,piece)==.None {
                if p.lack_count>0 {
                    // The piece is read again once the lack before it is out.
                    p.out_len=encode_lack(p.out,e.address,p.lack_first,p.lack_count)
                    p.lack_count=0
                    return true
                }
                encode_piece_head(p.out,e.address,index)
                p.out_len=MSG_PIECE_HEAD+bytes
                p.cursor+=1
                p.sent+=u64(bytes)
                return true
            }
            if p.lack_count==0 {p.lack_first=index}
            p.lack_count+=1
            p.cursor+=1
        }
        if p.lack_count>0 {
            p.out_len=encode_lack(p.out,e.address,p.lack_first,p.lack_count)
            p.lack_count=0
            return true
        }
        serve_pop(p)
    }
    return false
}
