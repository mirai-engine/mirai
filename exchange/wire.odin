package exchange

import "mirai:store"

// Messages, little endian, a kind byte first. Names are a length byte and
// their bytes.
//
// Control channel:
//   Request   count u16, entries of kind u8 (0 blob, 1 run), address, first u32, count u32
//   Ref_Get   namespace, name
//   Ref       namespace, name, found u8, address
//   Names_Get namespace, after
//   Names     namespace, after, more u8, count u16, entries of name and address
// Data channel, the answers to requests in the order asked:
//   Table     address, size u64, piece hashes
//   Piece     address, index u32, bytes
//   Lack      address, first u32, count u32: pieces it does not have; count 0: the blob
//   Done      the end of the answer to a request

@(private) MSG_REQUEST :: 1
@(private) MSG_REF_GET :: 2
@(private) MSG_REF :: 3
@(private) MSG_NAMES_GET :: 4
@(private) MSG_NAMES :: 5

@(private) MSG_TABLE :: 1
@(private) MSG_PIECE :: 2
@(private) MSG_LACK :: 3
@(private) MSG_DONE :: 4

@(private) ENTRY_BYTES :: 1+32+4+4
@(private) MSG_REQUEST_HEAD :: 1+2
@(private) MSG_REQUEST_MAX :: MSG_REQUEST_HEAD+REQUEST_ENTRIES*ENTRY_BYTES
@(private) MSG_TABLE_HEAD :: 1+32+8
@(private) MSG_PIECE_HEAD :: 1+32+4
@(private) MSG_LACK_BYTES :: 1+32+4+4
@(private) MSG_NAMES_GET_MAX :: 1+2*(1+store.NAME_MAX)
@(private) MSG_REF_MAX :: MSG_NAMES_GET_MAX+1+32
@(private) MSG_NAMES_MAX :: MSG_NAMES_GET_MAX+3+NAMES_REPLY_BYTES

@(private)
put_u16 :: proc(b:[]u8,v:u16) {b[0],b[1]=u8(v),u8(v>>8)}
@(private)
put_u32 :: proc(b:[]u8,v:u32) {for i in 0..<4 {b[i]=u8(v>>(8*uint(i)))}}
@(private)
put_u64 :: proc(b:[]u8,v:u64) {for i in 0..<8 {b[i]=u8(v>>(8*uint(i)))}}
@(private)
get_u16 :: proc(b:[]u8) -> u16 {return u16(b[0])|u16(b[1])<<8}

@(private)
Writer :: struct {data:[]u8,n:int}

@(private)
write_u8 :: proc(w:^Writer,v:u8) {w.data[w.n]=v;w.n+=1}
@(private)
write_u16 :: proc(w:^Writer,v:u16) {put_u16(w.data[w.n:],v);w.n+=2}
@(private)
write_u32 :: proc(w:^Writer,v:u32) {put_u32(w.data[w.n:],v);w.n+=4}
@(private)
write_u64 :: proc(w:^Writer,v:u64) {put_u64(w.data[w.n:],v);w.n+=8}
@(private)
write_bytes :: proc(w:^Writer,v:[]u8) {copy(w.data[w.n:],v);w.n+=len(v)}
@(private)
write_name :: proc(w:^Writer,v:string) {write_u8(w,u8(len(v)));write_bytes(w,transmute([]u8)v)}

// Reads fields of a message; any read past its end leaves ok false and gives zeros.
@(private)
Reader :: struct {data:[]u8,at:int,ok:bool}

@(private)
read_bytes :: proc(r:^Reader,n:int) -> []u8 {
    if !r.ok || n<0 || n>len(r.data)-r.at {r.ok=false;return nil}
    b:=r.data[r.at:][:n]
    r.at+=n
    return b
}
@(private)
read_u8 :: proc(r:^Reader) -> u8 {
    b:=read_bytes(r,1)
    return r.ok?b[0]:0
}
@(private)
read_u16 :: proc(r:^Reader) -> u16 {
    b:=read_bytes(r,2)
    return r.ok?get_u16(b):0
}
@(private)
read_u32 :: proc(r:^Reader) -> (v:u32) {
    b:=read_bytes(r,4)
    if r.ok {for i in 0..<4 {v|=u32(b[i])<<(8*uint(i))}}
    return
}
@(private)
read_u64 :: proc(r:^Reader) -> (v:u64) {
    b:=read_bytes(r,8)
    if r.ok {for i in 0..<8 {v|=u64(b[i])<<(8*uint(i))}}
    return
}
@(private)
read_hash :: proc(r:^Reader) -> (h:store.Hash) {
    b:=read_bytes(r,32)
    if r.ok {copy(h[:],b)}
    return
}
// A ref name, or with empty an empty one too; anything else leaves ok false.
@(private)
read_name :: proc(r:^Reader,empty:=false) -> string {
    n:=int(read_u8(r))
    b:=read_bytes(r,n)
    if !r.ok {return ""}
    s:=string(b)
    if !(empty && n==0) && !store.name_valid(s) {r.ok=false;return ""}
    return s
}
// Whether the whole message was read and nothing else is left.
@(private)
read_end :: proc(r:^Reader) -> bool {return r.ok && r.at==len(r.data)}

@(private)
encode_question :: proc(buffer:[]u8,kind:u8,namespace,name:string) -> []u8 {
    w:=Writer{data=buffer}
    write_u8(&w,kind)
    write_name(&w,namespace)
    write_name(&w,name)
    return buffer[:w.n]
}

@(private)
encode_lack :: proc(buffer:[]u8,address:store.Hash,first,count:u32) -> int {
    address:=address
    w:=Writer{data=buffer}
    write_u8(&w,MSG_LACK)
    write_bytes(&w,address[:])
    write_u32(&w,first)
    write_u32(&w,count)
    return w.n
}

@(private)
encode_piece_head :: proc(buffer:[]u8,address:store.Hash,index:u32) {
    address:=address
    w:=Writer{data=buffer}
    write_u8(&w,MSG_PIECE)
    write_bytes(&w,address[:])
    write_u32(&w,index)
}

// One whole message from peer i on a lane.
@(private)
message :: proc(x:^Exchange,i:int,lane:int,data:[]u8) {
    if len(data)==0 {peer_bad(x,i);return}
    if lane==LANE_DATA {
        switch data[0] {
        case MSG_TABLE: on_table(x,i,data)
        case MSG_PIECE: on_piece(x,i,data)
        case MSG_LACK: on_lack(x,i,data)
        case MSG_DONE: on_done(x,i,data)
        case: peer_bad(x,i)
        }
        return
    }
    switch data[0] {
    case MSG_REQUEST: on_request(x,i,data)
    case MSG_REF_GET: on_ref_get(x,i,data)
    case MSG_NAMES_GET: on_names_get(x,i,data)
    case MSG_REF: on_ref(x,i,data)
    case MSG_NAMES: on_names(x,i,data)
    case: peer_bad(x,i)
    }
}

// A message larger than this end holds: a table asked of that peer fails the
// peer for that blob, never the want; one nobody asked for counts against the
// peer; anything else is from a bad peer.
@(private)
oversized :: proc(x:^Exchange,i:int,lane:int,head:[]u8) {
    if lane==LANE_DATA && len(head)>=MSG_TABLE_HEAD && head[0]==MSG_TABLE {
        r:=Reader{data=head[1:],ok=true}
        address:=read_hash(&r)
        if w:=want_find(x,address);w>=0 && flight_of(x,i,w,FLIGHT_TABLE) {lie(x,w,i)} else {x.peers[i].refused+=1}
        return
    }
    peer_bad(x,i)
}
