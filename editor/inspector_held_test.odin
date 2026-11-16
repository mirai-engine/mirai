package editor

import "core:mem"
import "core:testing"
import "mirai:std/serial"

@(test)
curves_show_as_keys_and_held_values_take_what_a_popup_chose :: proc(t:^testing.T) {
    keys :: proc(type:typeid) -> int {
        s:serial.Schema
        serial.schema_init(&s,context.temp_allocator)
        index,_:=serial.schema_add_type_info(&s,type_info_of(type))
        return keys_count(&s,index)
    }
    Curve :: struct {values:[8]f32,times:[8]f32}
    Gradient :: struct {colors:[8][4]f32 `mirai:"color"`,times:[8]f32}
    Burst :: struct {time:f32,count:u32,cycles:u32,interval:f32}
    Short :: struct {values:[4]f32,times:[4]f32}
    Uneven :: struct {values:[8]f32,times:[6]f32}
    Uncolored :: struct {colors:[8][4]f32,times:[8]f32}
    testing.expect_value(t,keys(Curve),8)
    testing.expect_value(t,keys(Gradient),8)
    testing.expect_value(t,keys(Burst),0)
    testing.expect_value(t,keys(Short),0)
    testing.expect_value(t,keys(Uneven),0)
    testing.expect_value(t,keys(Uncolored),0)

    // A color chosen for one panel is taken by the rows of its values alone.
    Values :: struct {rate:f32,colors:[2][4]f32 `mirai:"color"`}
    DEFAULTS :: Values{rate=20,colors={{1,1,1,1},{1,1,1,1}}}
    s:=new(Session)
    defer free(s)
    ins:Inspector
    s.inspector=&ins
    info:=DEFAULTS
    c:=Inspect{s=s,index=HELD_INDEX,held=7,value=cast([^]u8)&info,size=size_of(info)}
    color:=[4]f32{0.25,0.5,1,1}
    held_put(&ins,8,int(offset_of(Values,colors)),mem.ptr_to_bytes(&color))
    held_take(&c)
    testing.expect(t,!c.changed && info.colors[0]==DEFAULTS.colors[0])
    held_put(&ins,7,int(offset_of(Values,colors)),mem.ptr_to_bytes(&color))
    held_take(&c)
    testing.expect(t,c.changed && info.colors[0]==color && ins.held.key==0)
    // Values a panel holds go back to its defaults with no step of the document.
    defaults:=DEFAULTS
    c.defaults=cast([^]u8)&defaults
    inspect_reset(&c,int(offset_of(Values,colors)),size_of(info.colors))
    testing.expect_value(t,info.colors,defaults.colors)
    // With a writer, what the rows write goes to it instead, at its offset.
    Written :: struct {offset,size:int}
    written:Written
    c.write=proc(s:^Session,user:rawptr,offset:int,bytes:[]u8) {(^Written)(user)^={offset,len(bytes)}}
    c.user=&written
    c.changed=false
    rate:=f32(5)
    inspect_write(&c,int(offset_of(Values,rate)),mem.ptr_to_bytes(&rate))
    testing.expect(t,c.changed && written==Written{int(offset_of(Values,rate)),size_of(f32)} && info.rate==DEFAULTS.rate)
    testing.expect(t,inspect_stepped(&c))
}
