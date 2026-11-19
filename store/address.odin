package store

import "core:mem"
import "core:os"
import "mirai:std/blake3"

// An address is the standard BLAKE3 hash of a blob's bytes. Only piece_value
// and address_value know the hash primitive, so it can be replaced in one place.
Hash :: distinct [32]u8

// A blob is cut in pieces of PIECE_BYTES, the last one shorter; an empty blob
// has none. A piece is a BLAKE3 group, so the address is the root of the table.
PIECE_BYTES :: 64<<10
#assert(PIECE_BYTES==blake3.GROUP_BYTES)

piece_count :: proc "contextless" (size:i64) -> int {
    if size<=0 {return 0}
    return int((size-1)/PIECE_BYTES+1)
}

// The bytes of piece index of a blob of size; 0 for an index out of range.
piece_size :: proc "contextless" (size:i64,index:int) -> int {
    if index<0 || index>=piece_count(size) {return 0}
    return int(min(size-i64(index)*PIECE_BYTES,PIECE_BYTES))
}

// The address of bytes in memory.
address_of_bytes :: proc "contextless" (data:[]u8) -> Hash {
    return Hash(blake3.hash(data))
}

// The address of the file at path, read once piece by piece; its piece table
// is held with allocator.
address_of_file :: proc(path:string,allocator:=context.allocator) -> (hash:Hash,size:i64,error:Error) {
    file,open_error:=file_open(path)
    if open_error!=nil {return {},0,os_error(open_error)}
    defer os.close(file)
    file_size,size_error:=os.file_size(file)
    if size_error!=nil {return {},0,os_error(size_error)}
    pieces,make_error:=make([]Hash,piece_count(file_size),allocator)
    if make_error!=nil {return {},0,.Out_Of_Memory}
    defer delete(pieces,allocator)
    hash,error=file_hash(file,file_size,nil,pieces)
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

// The value of piece index of a blob of size, from its bytes: the BLAKE3
// hash of a blob of one piece, otherwise its BLAKE3 group value. Out-of-range
// input gives a value no table holds.
@(private)
piece_value :: proc(piece:[]u8,index:int,size:i64) -> Hash {
    if size<=PIECE_BYTES {return Hash(blake3.hash(piece))}
    value,_:=blake3.group_value(piece,u64(max(index,0)))
    return Hash(value)
}

// The address of a blob of size, from its piece table: the BLAKE3 hash of
// nothing for an empty blob, the single value of a blob of one piece,
// otherwise the BLAKE3 root of the table. A table that does not fit size
// gives a value no blob has.
@(private)
address_value :: proc(size:i64,pieces:[]Hash) -> Hash {
    if size<0 || len(pieces)!=piece_count(size) {return {}}
    if size==0 {return Hash(blake3.hash(nil))}
    if len(pieces)==1 {return pieces[0]}
    root,_:=blake3.root(transmute([]blake3.Hash)pieces,u64(size))
    return Hash(root)
}

// The piece table of bytes in memory.
@(private)
bytes_table :: proc(data:[]u8,allocator:=context.allocator) -> ([]Hash,Error) {
    size:=i64(len(data))
    pieces,make_error:=make([]Hash,piece_count(size),allocator)
    if make_error!=nil {return nil,.Out_Of_Memory}
    for &piece,index in pieces {piece=piece_value(data[index*PIECE_BYTES:][:piece_size(size,index)],index,size)}
    return pieces,.None
}

// Reads size bytes of file piece by piece into table: their address. Each
// piece is also written to copy_to, when given. A file shorter than size, or
// longer, is Corrupt.
@(private)
file_hash :: proc(file:^os.File,size:i64,copy_to:^os.File,table:[]Hash) -> (hash:Hash,error:Error) {
    if len(table)!=piece_count(size) {return {},.Invalid_Argument}
    buffer:[PIECE_BYTES]u8=---
    for index in 0..<len(table) {
        offset:=i64(index)*PIECE_BYTES
        piece:=buffer[:piece_size(size,index)]
        read_exact(file,piece,offset) or_return
        if copy_to!=nil {
            if _,write_error:=os.write_at(copy_to,piece,offset);write_error!=nil {return {},os_error(write_error)}
        }
        table[index]=piece_value(piece,index,size)
    }
    after:[1]u8
    if n,_:=os.read_at(file,after[:],size);n>0 {return {},.Corrupt}
    return address_value(size,table),.None
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

// Corrupt unless file holds, after its size header, the piece table of a blob
// of size whose address is hash; read in runs, never whole.
@(private)
table_check :: proc(file:^os.File,size:i64,hash:Hash) -> Error {
    count:=piece_count(size)
    table_size,size_error:=os.file_size(file)
    if size_error!=nil {return os_error(size_error)}
    if count<2 || table_size!=TABLE_HEADER+i64(count)*size_of(Hash) {return .Corrupt}
    header:[TABLE_HEADER]u8
    read_exact(file,header[:],0) or_return
    if header!=table_header(size) {return .Corrupt}
    root:blake3.Root
    run:[TABLE_RUN]Hash=---
    for at:=0;at<count;at+=TABLE_RUN {
        entries:=run[:min(TABLE_RUN,count-at)]
        read_exact(file,mem.slice_to_bytes(entries),TABLE_HEADER+i64(at)*size_of(Hash)) or_return
        for entry in entries {blake3.root_push(&root,blake3.Hash(entry))}
    }
    address,ok:=blake3.root_final(&root,u64(size))
    return .None if ok && Hash(address)==hash else .Corrupt
}

// Hashes the size bytes of data piece by piece and appends each piece value
// to table, a run at a time; Corrupt when they do not make hash.
@(private)
table_hash :: proc(data:^os.File,size:i64,table:^os.File,hash:Hash) -> Error {
    count:=piece_count(size)
    if count<2 {return .Invalid_Argument}
    root:blake3.Root
    run:[TABLE_RUN]Hash=---
    buffer:[PIECE_BYTES]u8=---
    for at:=0;at<count;at+=TABLE_RUN {
        entries:=run[:min(TABLE_RUN,count-at)]
        for &entry,k in entries {
            index:=at+k
            piece:=buffer[:piece_size(size,index)]
            read_exact(data,piece,i64(index)*PIECE_BYTES) or_return
            entry=piece_value(piece,index,size)
            blake3.root_push(&root,blake3.Hash(entry))
        }
        file_append(table,{mem.slice_to_bytes(entries)}) or_return
    }
    after:[1]u8
    if n,_:=os.read_at(data,after[:],size);n>0 {return .Corrupt}
    address,ok:=blake3.root_final(&root,u64(size))
    return .None if ok && Hash(address)==hash else .Corrupt
}

@(private)
TABLE_RUN :: 2048 // entries of a table read or written at once

// The address of parts given one after another, as if they were one run of bytes.
@(private)
address_of_parts :: proc "contextless" (parts:[]([]u8)) -> Hash {
    hasher:blake3.Hasher
    for part in parts {blake3.update(&hasher,part)}
    return Hash(blake3.final(&hasher))
}
