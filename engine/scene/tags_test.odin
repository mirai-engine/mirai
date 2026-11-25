package scene

import "core:strings"
import "core:testing"
import "mirai:core"
import "mirai:std/serial"

@(private="file") TAG_PLAYER :: Tag(0)
@(private="file") TAG_STRUCTURE :: Tag(3)
@(private="file") TAG_LAST :: Tag(63)

@(test)
tags_match_masks_and_reject_tags_outside_the_set :: proc(t:^testing.T) {
    tags:Tags
    testing.expect(t,tag_set(&tags,TAG_PLAYER) && tag_set(&tags,TAG_LAST))
    testing.expect(t,tag_has(tags,TAG_LAST) && tag_has_all(tags,{bits=1}))
    testing.expect(t,tag_has_any(tags,{bits=3}) && !tag_has_all(tags,{bits=3}))
    testing.expect(t,!tag_set(&tags,Tag(64)) && !tag_clear(&tags,Tag(255)) && !tag_has(tags,Tag(64)))
    testing.expect(t,!tag_set(nil,TAG_PLAYER) && !tag_clear(nil,TAG_PLAYER))
    testing.expect(t,tag_clear(&tags,TAG_LAST) && tags.bits==1)
}

@(private) @(test_world) Tags_World :: struct {
    using world:Test_World,
    tags:core.Table(Tags),
}

// The tags of an entity are written and read by the names the code gives its
// tags, and the inspector finds those names from the type of its field.
@(test)
tags_take_the_names_the_code_declares_in_data_and_the_inspector :: proc(t:^testing.T) {
    info,described:=test_info(t,Tags_World)
    if !described {return}
    defer test_info_destroy(&info)
    names:=[]core.Name_Info{
        {type=Tag,value=i64(TAG_PLAYER),name="player",project=true},
        {type=Tag,value=i64(TAG_STRUCTURE),name="structure",project=true},
    }
    types:=[]core.Named_Type_Info{{type=Tag,name="Tag",path="mirai:engine/scene",prefix="TAG_",limit=TAG_LIMIT}}
    bits:=[]core.Name_Bits_Info{{type=Tag_Bits,of=Tag}}
    info.names,info.named_types,info.name_bits=names,types,bits
    ws:=core.world_schema_make(&info,context.temp_allocator)
    if !testing.expect(t,ws!=nil) {return}
    defer core.world_schema_destroy(ws)
    testing.expect_value(t,core.name_bits_of(&info,type_of(Tags{}.bits)),typeid_of(Tag))
    Case :: struct {text:string,bits:Tag_Bits}
    for c in ([]Case{
        {`{"bits":["player"]}`,1},
        {`{"bits":["player","structure"]}`,0b1001},
        {`{"bits":[]}`,0},
    }) {
        tags:Tags
        r:serial.Text_Reader
        serial.text_reader_init(&r,c.text,context.temp_allocator)
        if !testing.expectf(t,serial.text_read(&r,&ws.schema,ws.tables[0].type,([^]u8)(&tags)[:size_of(tags)]),"%s: %v",c.text,r.error) {continue}
        testing.expectf(t,tags.bits==c.bits,"%s read %v",c.text,tags.bits)
        w:serial.Writer
        serial.writer_init(&w,allocator=context.temp_allocator)
        serial.text_write(&w,&ws.schema,ws.tables[0].type,([^]u8)(&tags)[:size_of(tags)],.Line)
        written,_:=strings.replace_all(string(serial.writer_bytes(&w))," ","",context.temp_allocator)
        testing.expectf(t,written==c.text,"%s was written %s",c.text,written)
    }
}
