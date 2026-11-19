package exchange

import "mirai:store"

// Messages of exchange protocol 4, little endian, a kind byte first. Names are
// a length byte and their bytes.
//
// Control channel:
//   Ask       count u16, entries of address and budget u32: send each chunk,
//             then its descendants in tree order while their bytes fit budget
//   Bad       address: the chunk this end received does not hash to it
//   Ref_Get   namespace, name
//   Ref       namespace, name, found u8, address
//   Names_Get namespace, after
//   Names     namespace, after, more u8, count u16, entries of name and address
// Data channel, the answers to asks in the order asked:
//   Chunk     address, codec u8, raw u32, bytes as stored
//   Lack      address: a chunk asked that this end does not have
//   Done      the end of the answer to an ask

@(private) MSG_ASK :: 1
@(private) MSG_REF_GET :: 2
@(private) MSG_REF :: 3
@(private) MSG_NAMES_GET :: 4
@(private) MSG_NAMES :: 5
@(private) MSG_BAD :: 6

@(private) MSG_CHUNK :: 1
@(private) MSG_LACK :: 2
@(private) MSG_DONE :: 3

@(private) ASK_ENTRY_BYTES :: 32+4
@(private) MSG_ASK_HEAD :: 1+2
@(private) MSG_ASK_MAX :: MSG_ASK_HEAD+ASK_ENTRIES*ASK_ENTRY_BYTES
@(private) MSG_CHUNK_HEAD :: 1+32+1+4
@(private) MSG_CHUNK_MAX :: MSG_CHUNK_HEAD+store.CHUNK_MAX
@(private) MSG_ADDRESS_BYTES :: 1+32 // Lack and Bad
@(private) MSG_NAMES_GET_MAX :: 1+2*(1+store.NAME_MAX)
@(private) MSG_REF_MAX :: MSG_NAMES_GET_MAX+1+32
@(private) MSG_NAMES_MAX :: MSG_NAMES_GET_MAX+3+NAMES_REPLY_BYTES

@(private)
put_u16 :: proc(b:[]u8,v:u16) {b[0],b[1]=u8(v),u8(v>>8)}
@(private)
put_u32 :: proc(b:[]u8,v:u32) {for i in 0..<4 {b[i]=u8(v>>(8*uint(i)))}}
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

// A Lack or a Bad.
@(private)
encode_address :: proc(buffer:[]u8,kind:u8,address:store.Hash) -> int {
    address:=address
    buffer[0]=kind
    copy(buffer[1:],address[:])
    return MSG_ADDRESS_BYTES
}

// The head of a Chunk whose bytes follow it in buffer.
@(private)
encode_chunk_head :: proc(buffer:[]u8,address:store.Hash,size:int) {
    address:=address
    w:=Writer{data=buffer}
    write_u8(&w,MSG_CHUNK)
    write_bytes(&w,address[:])
    write_u8(&w,0)
    write_u32(&w,u32(size))
}

// One whole message from peer i on a lane.
@(private)
message :: proc(x:^Exchange,i:int,lane:int,data:[]u8) {
    if len(data)==0 {peer_bad(x,i);return}
    if lane==LANE_DATA {
        switch data[0] {
        case MSG_CHUNK: on_chunk(x,i,data)
        case MSG_LACK: on_lack(x,i,data)
        case MSG_DONE: on_done(x,i,data)
        case: peer_bad(x,i)
        }
        return
    }
    switch data[0] {
    case MSG_ASK: on_ask(x,i,data)
    case MSG_BAD: on_bad(x,i,data)
    case MSG_REF_GET: on_ref_get(x,i,data)
    case MSG_NAMES_GET: on_names_get(x,i,data)
    case MSG_REF: on_ref(x,i,data)
    case MSG_NAMES: on_names(x,i,data)
    case: peer_bad(x,i)
    }
}
