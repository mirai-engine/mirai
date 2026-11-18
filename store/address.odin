package store

import "core:crypto/blake2b"
import "core:os"

// An address is a pure function of a blob's bytes. Only piece_value and
// address_value know the hash primitive, so it can be replaced in one place.
Hash :: distinct [32]u8

// A blob is cut in pieces of PIECE_BYTES, the last one shorter; an empty blob has none.
PIECE_BYTES :: 64<<10

// BLAKE2b-256 keyed apart for pieces and addresses, so a piece hash, a piece
// table and an address can never be taken for one another.
@(private)
KEY_PIECE :: "mirai store piece"
@(private)
KEY_ADDRESS :: "mirai store address"

// Gives the piece hash at index of a table, called for every index in order.
@(private)
Piece_Source :: proc(user:rawptr,index:int) -> (Hash,Error)

piece_count :: proc "contextless" (size:i64) -> int {
    if size<=0 {return 0}
    return int((size-1)/PIECE_BYTES+1)
}

// The bytes of piece index of a blob of size; 0 for an index out of range.
piece_size :: proc "contextless" (size:i64,index:int) -> int {
    if index<0 || index>=piece_count(size) {return 0}
    return int(min(size-i64(index)*PIECE_BYTES,PIECE_BYTES))
}

address_of_bytes :: proc(data:[]u8) -> Hash {
    data:=data
    hash,_:=address_value(i64(len(data)),proc(user:rawptr,index:int) -> (Hash,Error) {
        data:=(^[]u8)(user)^
        return piece_value(data[index*PIECE_BYTES:][:piece_size(i64(len(data)),index)],index),.None
    },&data)
    return hash
}

// The address of the file at path, read piece by piece.
address_of_file :: proc(path:string) -> (hash:Hash,size:i64,error:Error) {
    file,open_error:=os.open(path)
    if open_error!=nil {return {},0,os_error(open_error)}
    defer os.close(file)
    file_size,size_error:=os.file_size(file)
    if size_error!=nil {return {},0,os_error(size_error)}
    hash,error=file_hash(file,file_size,nil,nil)
    if error==.Corrupt {error=.Io}
    return hash,file_size,error
}

// Lowercase hexadecimal of hash, in buffer.
hex :: proc(hash:Hash,buffer:^[64]u8) -> string {
    digits:="0123456789abcdef"
    for b,i in hash {
        buffer[2*i]=digits[b>>4]
        buffer[2*i+1]=digits[b&15]
    }
    return string(buffer[:])
}

// The hash whose hex is text: exactly 64 lowercase hexadecimal digits.
parse_hex :: proc(text:string) -> (hash:Hash,ok:bool) {
    if len(text)!=64 {return}
    for i in 0..<32 {
        high,high_ok:=hex_digit(text[2*i])
        low,low_ok:=hex_digit(text[2*i+1])
        if !high_ok || !low_ok {return {},false}
        hash[i]=high<<4|low
    }
    return hash,true
}

@(private)
hex_digit :: proc "contextless" (c:u8) -> (u8,bool) {
    switch c {
    case '0'..='9': return c-'0',true
    case 'a'..='f': return c-'a'+10,true
    }
    return 0,false
}

// The hash of the piece at index of a blob, from its bytes.
@(private)
piece_value :: proc(piece:[]u8,index:int) -> Hash {
    ctx:blake2b.Context
    key:=KEY_PIECE
    blake2b.init_mac(&ctx,transmute([]u8)key,size_of(Hash))
    blake2b.update(&ctx,piece)
    hash:Hash
    blake2b.final(&ctx,hash[:])
    return hash
}

// The address of a blob of size bytes, from its piece table, which pieces
// gives one entry at a time so a table is never held whole.
@(private)
address_value :: proc(size:i64,pieces:Piece_Source,user:rawptr) -> (Hash,Error) {
    ctx:blake2b.Context
    key:=KEY_ADDRESS
    blake2b.init_mac(&ctx,transmute([]u8)key,size_of(Hash))
    length:[8]u8
    for i in 0..<8 {length[i]=u8(u64(size)>>(8*uint(i)))}
    blake2b.update(&ctx,length[:])
    for index in 0..<piece_count(size) {
        piece,error:=pieces(user,index)
        if error!=.None {
            hash:Hash
            blake2b.final(&ctx,hash[:])
            return {},error
        }
        blake2b.update(&ctx,piece[:])
    }
    hash:Hash
    blake2b.final(&ctx,hash[:])
    return hash,.None
}

// The address of a table held in memory.
@(private)
table_address :: proc(size:i64,pieces:[]Hash) -> Hash {
    pieces:=pieces
    hash,_:=address_value(size,proc(user:rawptr,index:int) -> (Hash,Error) {
        return (^[]Hash)(user)[index],.None
    },&pieces)
    return hash
}

// Reads size bytes of file piece by piece: their address. Each piece is also
// written to copy_to and its hash to table, when given. A file shorter than
// size, or longer, is Corrupt.
@(private)
file_hash :: proc(file:^os.File,size:i64,copy_to:^os.File,table:[]Hash) -> (hash:Hash,error:Error) {
    if table!=nil && len(table)!=piece_count(size) {return {},.Invalid_Argument}
    Reading :: struct {
        buffer:[PIECE_BYTES]u8,
        file,copy_to:^os.File,
        size:i64,
        table:[]Hash,
    }
    reading:=Reading{file=file,copy_to=copy_to,size=size,table=table}
    hash=address_value(size,proc(user:rawptr,index:int) -> (Hash,Error) {
        r:=(^Reading)(user)
        offset:=i64(index)*PIECE_BYTES
        piece:=r.buffer[:piece_size(r.size,index)]
        if error:=read_exact(r.file,piece,offset);error!=.None {return {},error}
        if r.copy_to!=nil {
            if _,write_error:=os.write_at(r.copy_to,piece,offset);write_error!=nil {return {},os_error(write_error)}
        }
        hash:=piece_value(piece,index)
        if r.table!=nil {r.table[index]=hash}
        return hash,.None
    },&reading) or_return
    after:[1]u8
    if n,_:=os.read_at(file,after[:],size);n>0 {return {},.Corrupt}
    return hash,.None
}

// Fills buffer from file at offset; Corrupt when the file ends first.
@(private)
read_exact :: proc(file:^os.File,buffer:[]u8,offset:i64) -> Error {
    done:=0
    for done<len(buffer) {
        n,read_error:=os.read_at(file,buffer[done:],offset+i64(done))
        done+=max(n,0)
        if done>=len(buffer) {break}
        if n<=0 {
            if read_error==nil || read_error==.EOF {return .Corrupt}
            return os_error(read_error)
        }
    }
    return .None
}
