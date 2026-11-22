package hub

import "core:encoding/base64"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"
import "mirai:store"

// A JSON writer for answers: values separate themselves, and texts are
// escaped so that no byte of a repository can close a string or a page.

JSON_DEPTH :: 32
HEX_DIGITS :: [16]u8{'0','1','2','3','4','5','6','7','8','9','a','b','c','d','e','f'}

Json :: struct {
    b:strings.Builder,
    more:[JSON_DEPTH]bool, // the container at each depth holds a value already
    depth:int,
    after_key:bool,
}

json_make :: proc(allocator:=context.temp_allocator) -> Json {
    return {b=strings.builder_make(allocator)}
}

@(private)
json_separate :: proc(j:^Json) {
    if j.after_key {
        j.after_key=false
        return
    }
    if j.depth>0 {
        if j.more[j.depth-1] {strings.write_byte(&j.b,',')}
        j.more[j.depth-1]=true
    }
}

json_object :: proc(j:^Json) {
    json_separate(j)
    strings.write_byte(&j.b,'{')
    if j.depth<JSON_DEPTH {j.more[j.depth]=false}
    j.depth+=1
}

json_array :: proc(j:^Json) {
    json_separate(j)
    strings.write_byte(&j.b,'[')
    if j.depth<JSON_DEPTH {j.more[j.depth]=false}
    j.depth+=1
}

json_end_object :: proc(j:^Json) {
    j.depth-=1
    strings.write_byte(&j.b,'}')
}

json_end_array :: proc(j:^Json) {
    j.depth-=1
    strings.write_byte(&j.b,']')
}

// The key of the next member; the value written next goes with it.
json_key :: proc(j:^Json,key:string) {
    json_separate(j)
    json_quoted(j,key)
    strings.write_byte(&j.b,':')
    j.after_key=true
}

@(private)
json_quoted :: proc(j:^Json,text:string) {
    strings.write_byte(&j.b,'"')
    for r in text {
        switch r {
        case '"': strings.write_string(&j.b,`\"`)
        case '\\': strings.write_string(&j.b,`\\`)
        case '\n': strings.write_string(&j.b,`\n`)
        case '\r': strings.write_string(&j.b,`\r`)
        case '\t': strings.write_string(&j.b,`\t`)
        case '<','>','&',0x2028,0x2029,utf8.RUNE_ERROR:
            buffer:[8]u8
            strings.write_string(&j.b,`\u`)
            hex:=strconv.write_bits(buffer[:],u64(r==utf8.RUNE_ERROR?0xfffd:r),16,false,64,"0123456789abcdef",{})
            for _ in len(hex)..<4 {strings.write_byte(&j.b,'0')}
            strings.write_string(&j.b,hex)
        case:
            if r<0x20 {
                digits:=HEX_DIGITS
                strings.write_string(&j.b,`\u00`)
                strings.write_byte(&j.b,digits[r>>4])
                strings.write_byte(&j.b,digits[r&15])
            } else {
                strings.write_rune(&j.b,r)
            }
        }
    }
    strings.write_byte(&j.b,'"')
}

json_string :: proc(j:^Json,text:string) {
    json_separate(j)
    json_quoted(j,text)
}

json_int :: proc(j:^Json,value:i64) {
    json_separate(j)
    strings.write_i64(&j.b,value)
}

json_bool :: proc(j:^Json,value:bool) {
    json_separate(j)
    strings.write_string(&j.b,value?"true":"false")
}

json_null :: proc(j:^Json) {
    json_separate(j)
    strings.write_string(&j.b,"null")
}

json_hex :: proc(j:^Json,bytes:[]u8) {
    json_separate(j)
    strings.write_byte(&j.b,'"')
    digits:=HEX_DIGITS
    for c in bytes {
        strings.write_byte(&j.b,digits[c>>4])
        strings.write_byte(&j.b,digits[c&15])
    }
    strings.write_byte(&j.b,'"')
}

json_hash :: proc(j:^Json,h:store.Hash) {
    x:=h
    json_hex(j,x[:])
}

json_base64 :: proc(j:^Json,bytes:[]u8) {
    encoded,_:=base64.encode(bytes,base64.ENC_URL_TABLE,context.temp_allocator,{.No_Padding})
    json_string(j,encoded)
}

// Members with their values in one call each.
json_member_string :: proc(j:^Json,key,value:string) {json_key(j,key);json_string(j,value)}
json_member_int :: proc(j:^Json,key:string,value:i64) {json_key(j,key);json_int(j,value)}
json_member_bool :: proc(j:^Json,key:string,value:bool) {json_key(j,key);json_bool(j,value)}
json_member_hash :: proc(j:^Json,key:string,value:store.Hash) {json_key(j,key);json_hash(j,value)}
json_member_hex :: proc(j:^Json,key:string,value:[]u8) {json_key(j,key);json_hex(j,value)}

json_text :: proc(j:^Json) -> string {return strings.to_string(j.b)}
