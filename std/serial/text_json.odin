package serial

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
