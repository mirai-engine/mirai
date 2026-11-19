package store

import "core:os"
import "mirai:std/blake3"

// An address is the standard BLAKE3 hash of a chunk's bytes; an object's is
// its root node's.
Hash :: distinct [32]u8

// The address of bytes in memory.
address_of_bytes :: proc "contextless" (data:[]u8) -> Hash {
    return Hash(blake3.hash(data))
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

// The address of parts given one after another, as if they were one run of bytes.
@(private)
address_of_parts :: proc "contextless" (parts:[]([]u8)) -> Hash {
    hasher:blake3.Hasher
    for part in parts {blake3.update(&hasher,part)}
    return Hash(blake3.final(&hasher))
}
