package history

import "base:runtime"
import "core:slice"
import "mirai:core"
import "mirai:std/serial"

// Byte ranges of the transient fields of a value of a world: what a copy leaves zero.
transient_ranges :: proc(world:^core.World_Info,type:^runtime.Type_Info,allocator:=context.temp_allocator,error:^runtime.Allocator_Error=nil) -> [][2]int {
    return field_ranges(world,type,false,allocator,error)
}

// Byte ranges of the fields of a value of a world a scene saves, in order:
// every field that is not transient, those of a struct inside it one by one.
saved_fields :: proc(world:^core.World_Info,type:^runtime.Type_Info,allocator:=context.temp_allocator,error:^runtime.Allocator_Error=nil) -> [][2]int {
    return field_ranges(world,type,true,allocator,error)
}

// By the schema of the world; a value it does not describe is saved whole.
@(private)
field_ranges :: proc(world:^core.World_Info,info:^runtime.Type_Info,saved:bool,allocator:runtime.Allocator,error:^runtime.Allocator_Error) -> [][2]int {
    walk :: proc(s:^serial.Schema,type:serial.Type_Index,at:int,saved:bool,out:[][2]int,index:^int) {
        if s.types[type].kind!=.Struct {
            if saved && s.types[type].size>0 {
                if out!=nil {out[index^]={at,int(s.types[type].size)}}
                index^+=1
            }
            return
        }
        for field in serial.schema_fields(s,type) {
            offset:=at+int(field.offset)
            if .Transient not_in field.flags {
                walk(s,field.type,offset,saved,out,index)
            } else if !saved {
                if out!=nil {out[index^]={offset,int(s.types[field.type].size)}}
                index^+=1
            }
        }
    }
    s,type,typed:=core.world_value_type(world,info.id)
    if !typed {
        whole:=[][2]int{{0,info.size}} if saved && info.size>0 else nil
        ranges,failed:=slice.clone(whole,allocator)
        if error!=nil {error^=failed}
        return ranges
    }
    count:=0
    walk(s,type,0,saved,nil,&count)
    ranges,failed:=make([][2]int,count,allocator)
    if error!=nil {error^=failed}
    if failed!=nil {return nil}
    index:=0
    walk(s,type,0,saved,ranges,&index)
    return ranges
}
