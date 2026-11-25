package hub

import "core:encoding/base64"
import "mirai:kai"
import "mirai:std/serial"
import "mirai:store"

// A JSON writer for answers: values separate themselves, and texts are
// embeddable (serial.text_write_string), so that no byte of a repository can
// close a string or a page.

JSON_DEPTH :: 32

Json :: struct {
    w:serial.Writer,
    more:[JSON_DEPTH]bool, // the container at each depth holds a value already
    depth:int,
    after_key:bool,
}

json_make :: proc(allocator:=context.temp_allocator) -> (j:Json) {
    serial.writer_init(&j.w,0,allocator)
    return
}

@(private)
json_separate :: proc(j:^Json) {
    if j.after_key {
        j.after_key=false
        return
    }
    if j.depth>0 {
        if j.more[j.depth-1] {serial.write_u8(&j.w,',')}
        j.more[j.depth-1]=true
    }
}

json_object :: proc(j:^Json) {
    json_separate(j)
    serial.write_u8(&j.w,'{')
    if j.depth<JSON_DEPTH {j.more[j.depth]=false}
    j.depth+=1
}

json_array :: proc(j:^Json) {
    json_separate(j)
    serial.write_u8(&j.w,'[')
    if j.depth<JSON_DEPTH {j.more[j.depth]=false}
    j.depth+=1
}

json_end_object :: proc(j:^Json) {
    j.depth-=1
    serial.write_u8(&j.w,'}')
}

json_end_array :: proc(j:^Json) {
    j.depth-=1
    serial.write_u8(&j.w,']')
}

// The key of the next member; the value written next goes with it.
json_key :: proc(j:^Json,key:string) {
    json_separate(j)
    serial.text_write_string(&j.w,key,embeddable=true)
    serial.write_u8(&j.w,':')
    j.after_key=true
}

json_string :: proc(j:^Json,text:string) {
    json_separate(j)
    serial.text_write_string(&j.w,text,embeddable=true)
}

json_int :: proc(j:^Json,value:i64) {
    json_separate(j)
    serial.text_write_int(&j.w,value)
}

json_bool :: proc(j:^Json,value:bool) {
    json_separate(j)
    serial.text_write_raw(&j.w,value?"true":"false")
}

json_null :: proc(j:^Json) {
    json_separate(j)
    serial.text_write_raw(&j.w,"null")
}

json_hex :: proc(j:^Json,bytes:[]u8) {
    buffer,_:=make([]u8,2*len(bytes),context.temp_allocator)
    json_string(j,kai.hex_text(bytes,buffer))
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

json_text :: proc(j:^Json) -> string {return string(serial.writer_bytes(&j.w))}
