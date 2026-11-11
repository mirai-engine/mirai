package history

import "base:runtime"
import "mirai:std/serial"

// Byte ranges of the transient fields of a type: what a copy leaves zero.
transient_ranges :: proc(type:^runtime.Type_Info,allocator:=context.temp_allocator,error:^runtime.Allocator_Error=nil) -> [][2]int {
    return field_ranges(type,false,allocator,error)
}

// Byte ranges of the fields of a type a scene saves, in order: every field
// that is not transient, those of a struct inside it one by one.
saved_fields :: proc(type:^runtime.Type_Info,allocator:=context.temp_allocator,error:^runtime.Allocator_Error=nil) -> [][2]int {
    return field_ranges(type,true,allocator,error)
}

@(private)
field_ranges :: proc(type:^runtime.Type_Info,saved:bool,allocator:runtime.Allocator,error:^runtime.Allocator_Error) -> [][2]int {
    walk :: proc(info:^runtime.Type_Info,at:uintptr,saved:bool,out:[][2]int,index:^int) {
        value,is_struct:=runtime.type_info_base(info).variant.(runtime.Type_Info_Struct)
        if !is_struct {
            if saved && info.size>0 {
                if out!=nil {out[index^]={int(at),info.size}}
                index^+=1
            }
            return
        }
        for field in 0..<int(value.field_count) {
            offset:=at+value.offsets[field]
            if tagged,_:=serial.field_tag(value.tags[field]);.Transient in tagged.flags {
                if !saved {
                    if out!=nil {out[index^]={int(offset),value.types[field].size}}
                    index^+=1
                }
            } else {walk(value.types[field],offset,saved,out,index)}
        }
    }
    count:=0
    walk(type,0,saved,nil,&count)
    ranges,failed:=make([][2]int,count,allocator)
    if error!=nil {error^=failed}
    if failed!=nil {return nil}
    index:=0
    walk(type,0,saved,ranges,&index)
    return ranges
}
