package serial

import "base:runtime"

// The pieces of JSON written by hand around the values of a schema.

// A key of an object, after a comma unless it is the first.
json_key :: proc(w:^Writer,key:string,first:=false) {
    if !first {write_u8(w,',')}
    text_write_string(w,key)
    write_u8(w,':')
}

json_text :: proc(w:^Writer,key,text:string,first:=false) {json_key(w,key,first);text_write_string(w,text)}
json_bool :: proc(w:^Writer,key:string,value:bool,first:=false) {json_key(w,key,first);json_flag(w,value)}
json_flag :: proc(w:^Writer,value:bool) {text_write_raw(w,value?"true":"false")}

// A number as the engine writes an f32: the shortest text that reads back the same value.
json_number :: proc(w:^Writer,value:f32) {text_write_float(w,u64(transmute(u32)value),4)}

json_list :: proc(w:^Writer,values:[]f32) {
    write_u8(w,'[')
    for value,i in values {
        if i>0 {write_u8(w,',')}
        json_number(w,value)
    }
    write_u8(w,']')
}

// The JSON text indented two spaces per level, with its objects in the order it has them.
json_pretty :: proc(text:string,allocator:runtime.Allocator) -> string {
    w:Writer
    writer_init(&w,len(text)*2+64,allocator)
    depth,i:=0,0
    for i<len(text) {
        c:=text[i]
        switch c {
        case ' ','\t','\n','\r':
        case '"':
            end:=i+1
            for end<len(text) && text[end]!='"' {end+=text[end]=='\\'?2:1}
            end=min(end+1,len(text))
            write_bytes(&w,transmute([]u8)text[i:end])
            i=end-1
        case '{','[':
            close:=u8(c=='{'?'}':']')
            next:=i+1
            for next<len(text) && (text[next]==' ' || text[next]=='\n' || text[next]=='\r' || text[next]=='\t') {next+=1}
            if next<len(text) && text[next]==close {
                write_u8(&w,c);write_u8(&w,close)
                i=next
            } else {
                write_u8(&w,c)
                depth+=1
                text_write_break(&w,depth)
            }
        case '}',']':
            depth=max(depth-1,0)
            text_write_break(&w,depth)
            write_u8(&w,c)
        case ',':
            write_u8(&w,',')
            text_write_break(&w,depth)
        case ':':
            text_write_raw(&w,": ")
        case:
            write_u8(&w,c)
        }
        i+=1
    }
    return string(writer_bytes(&w))
}
