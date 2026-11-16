package api

import "mirai:std/base"
import "mirai:std/serial"

// The pieces of JSON that methods write by hand into their results: those of
// std/serial (text_json.odin) and what only the API writes.

write_key :: proc(w:^serial.Writer,key:string,first:=false) {serial.json_key(w,key,first)}
write_text :: proc(w:^serial.Writer,key,text:string,first:=false) {serial.json_text(w,key,text,first)}
write_int :: proc(w:^serial.Writer,key:string,value:i64,first:=false) {write_key(w,key,first);serial.text_write_int(w,value)}
write_uint :: proc(w:^serial.Writer,key:string,value:u64,first:=false) {write_key(w,key,first);serial.text_write_uint(w,value)}
write_bool :: proc(w:^serial.Writer,key:string,value:bool,first:=false) {serial.json_bool(w,key,value,first)}
write_flag :: proc(w:^serial.Writer,value:bool) {serial.json_flag(w,value)}
write_number :: proc(w:^serial.Writer,value:f32) {serial.json_number(w,value)}
write_list :: proc(w:^serial.Writer,values:[]f32) {serial.json_list(w,values)}

write_numbers :: proc{write_numbers_list,write_numbers_vector}
write_numbers_list :: proc(w:^serial.Writer,key:string,values:[]f32,first:=false) {write_key(w,key,first);write_list(w,values)}
write_numbers_vector :: proc(w:^serial.Writer,key:string,value:[3]f32,first:=false) {
    value:=value
    write_numbers_list(w,key,value[:],first)
}

// An id of the document, as a quoted hexadecimal string.
write_id :: proc(w:^serial.Writer,id:base.Entity_Id) {
    serial.write_u8(w,'"')
    serial.text_write_hex(w,u64(id))
    serial.write_u8(w,'"')
}
