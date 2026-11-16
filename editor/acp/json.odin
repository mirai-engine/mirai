package acp

import "mirai:std/serial"

// A message written in place at the end of the send queue, opened with its
// "jsonrpc" member; message_end closes it and queues it when it fit.
@(private)
message_begin :: proc(c:^Client) -> (w:serial.Writer) {
    compact(c)
    serial.writer_init_fixed(&w,c.tx)
    w.count=c.queued
    serial.text_write_raw(&w,`{"jsonrpc":"2.0"`)
    return
}

@(private)
message_end :: proc(c:^Client,w:^serial.Writer) -> Error {
    serial.text_write_raw(w,"}\n")
    if w.overflow>0 {return .Capacity}
    c.queued=w.count
    return .None
}

// An object of the temporary allocator, as the params of a message.
@(private)
object_begin :: proc() -> (w:serial.Writer) {
    serial.writer_init(&w,256,context.temp_allocator)
    serial.text_write_raw(&w,"{")
    return
}

@(private)
object_end :: proc(w:^serial.Writer) -> string {
    serial.text_write_raw(w,"}")
    return string(serial.writer_bytes(w))
}

// The name of a member, after a comma unless it opens its object.
@(private)
member :: proc(w:^serial.Writer,name:string) {
    if w.count>0 && w.data[w.count-1]!='{' {serial.text_write_raw(w,",")}
    serial.text_write_string(w,name)
    serial.text_write_raw(w,":")
}

@(private)
member_string :: proc(w:^serial.Writer,name,value:string) {
    member(w,name)
    serial.text_write_string(w,value)
}

// A member whose value is JSON already.
@(private)
member_raw :: proc(w:^serial.Writer,name,value:string) {
    member(w,name)
    serial.text_write_raw(w,value)
}
