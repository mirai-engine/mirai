package base

import "core:hash/xxhash"

// Hash of a block of bytes (XXH3). The value depends only on the bytes and the
// seed, never on the platform, so it can be stored. Names keep using name_hash.
hash64 :: proc(data:[]byte,seed:u64=0) -> u64 {
    none:[1]byte
    return xxhash.XXH3_64_with_seed(data if data!=nil else none[:0],seed)
}
hash128 :: proc(data:[]byte,seed:u64=0) -> [2]u64 {
    none:[1]byte
    hash:=xxhash.XXH3_128_with_seed(data if data!=nil else none[:0],seed)
    return {u64(hash),u64(hash>>64)}
}
// Mixes the bits of an integer (the SplitMix64 finalizer). It is a bijection: distinct inputs give distinct outputs.
hash_u64 :: #force_inline proc "contextless" (value:u64) -> u64 {
    x:=value
    x=(x~(x>>30))*0xbf58476d1ce4e5b9
    x=(x~(x>>27))*0x94d049bb133111eb
    return x~(x>>31)
}

// Identity of an asset derived from its bytes: equal contents, equal identity.
asset_id_from_content :: proc(data:[]byte) -> Asset_Id {
    id:=Asset_Id(hash128(data))
    if id=={} {id[0]=1}
    return id
}
// The identity a generator gives what it makes from a name: the same name
// gives the same id every time it runs. Not for what an import writes, whose
// ids are random and live in the assets.
asset_id_named :: proc(name:string) -> Asset_Id {
    id:=Asset_Id(hash128(transmute([]byte)name,0x6d69726169))
    if id=={} {id[0]=1}
    return id
}
// The SplitMix64 sequence: each call moves state on and gives its next value.
// The same state gives the same values, and a state does not repeat one in
// 2^64 calls. For what keeps one word of state; Rng is the generator.
splitmix_next :: #force_inline proc "contextless" (state:^u64) -> u64 {
    state^+=0x9e3779b97f4a7c15
    return hash_u64(state^)
}
// The one sequence new entity Ids come from: each call gives the next Id of
// splitmix_next, never the zero that means none. A World takes them through
// core.id_new, a document through asset.scene_new_id.
entity_id_next :: proc "contextless" (state:^u64) -> Entity_Id {
    for {
        if id:=Entity_Id(splitmix_next(state));id!=0 {return id}
    }
}
// A random identity; never the zero that means none.
asset_id_random :: proc "contextless" (rng:^Rng) -> Asset_Id {
    for {
        id:=Asset_Id{rng_u64(rng),rng_u64(rng)}
        if id!={} {return id}
    }
}

ENTITY_ID_TEXT :: 16 // hex digits of an Entity_Id
ASSET_ID_TEXT :: 32  // hex digits of an Asset_Id: those of its first word, then those of the second

@(private) HEX_DIGITS :: "0123456789abcdef"

// Writes 16 lowercase hex digits and returns them; "" when the buffer is shorter.
hex_format_u64 :: proc "contextless" (value:u64,buffer:[]u8) -> string {
    if len(buffer)<16 {return ""}
    digits:=HEX_DIGITS
    for i in 0..<16 {buffer[i]=digits[(value>>uint(60-i*4))&15]}
    return string(buffer[:16])
}
// Reads exactly 16 hex digits of either case.
hex_parse_u64 :: proc "contextless" (text:string) -> (value:u64,ok:bool) {
    if len(text)!=16 {return 0,false}
    for i in 0..<16 {
        digit:u64
        switch c:=text[i];c {
        case '0'..='9': digit=u64(c-'0')
        case 'a'..='f': digit=u64(c-'a')+10
        case 'A'..='F': digit=u64(c-'A')+10
        case: return 0,false
        }
        value=value<<4|digit
    }
    return value,true
}
entity_id_format :: proc "contextless" (id:Entity_Id,buffer:[]u8) -> string {return hex_format_u64(u64(id),buffer)}
entity_id_parse :: proc "contextless" (text:string) -> (id:Entity_Id,ok:bool) {
    value:=hex_parse_u64(text) or_return
    return Entity_Id(value),true
}
asset_id_format :: proc "contextless" (id:Asset_Id,buffer:[]u8) -> string {
    if len(buffer)<ASSET_ID_TEXT {return ""}
    hex_format_u64(id[0],buffer[:16])
    hex_format_u64(id[1],buffer[16:32])
    return string(buffer[:ASSET_ID_TEXT])
}
asset_id_parse :: proc "contextless" (text:string) -> (id:Asset_Id,ok:bool) {
    if len(text)!=ASSET_ID_TEXT {return {},false}
    id[0]=hex_parse_u64(text[:16]) or_return
    id[1]=hex_parse_u64(text[16:]) or_return
    return id,true
}
