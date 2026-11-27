package editor

import "core:strings"
import "core:testing"
import "mirai:core"
import "mirai:std/serial"

@(private) Wait_Frame :: struct {tick:u64,position:[3]f32}
@(private) Wait_Rewind :: struct {head:i32,frames:[64]Wait_Frame}
@(private) Wait_School :: enum u8 {Fire,Ice}
// Larger than API_STORAGE_BYTES only by its grid.
@(private) @(storage) Wait_Big :: struct {
    spell:i32,
    active:bool,
    school:Wait_School,
    name:[16]u8 `mirai:"text"`,
    grid:[600][600]u8,
    rewind:Wait_Rewind,
    recent:[8]i32 `mirai:"trim"`,
    held:[]i32,
}
@(private)
@(test_world,editor="Wait_Editor")
Wait_World :: struct {
    using world:Test_World,
    big:Wait_Big,
    time:core.Time,
}
@(private) Wait_Editor :: struct {api:Api}

// A condition reads a field of a storage larger than the API writes whole by
// walking to it in place; the whole storage, or a part of it that is itself
// too large, says how large it is and to name a field inside it.
@(test)
a_condition_reads_a_small_field_of_a_large_storage :: proc(t:^testing.T) {
    w:=new(Wait_World)
    defer free(w)
    if !test_world_init(t,w) {return}
    defer test_world_destroy(w)
    state:Api_State
    editor:=Wait_Editor{api={state=&state}}
    s:=Session{info=test_world_info(w),editor_world=&editor}
    api_schema_build(&s,&state)
    defer api_schema_free(&state)
    testing.expect(t,size_of(Wait_Big)>API_STORAGE_BYTES)
    w.big.spell,w.big.active,w.big.school=7,true,.Ice
    copy(w.big.name[:],"Blaze")
    w.big.grid[3][5],w.big.grid[599][599]=9,4
    w.big.rewind.head=2
    w.big.rewind.frames[2]={tick=40,position={1,1.5,2}}
    w.big.recent[0],w.big.recent[1]=3,8
    w.big.held=make([]i32,3)
    copy(w.big.held,[]i32{5,6,7})
    w.time.tick=12
    ref:=test_world_ref(w)
    cases:=[]struct{storage,field:string,compare:Api_Compare,number:f64,value:string,text:string,length,passed:bool,says:string}{
        {storage="Wait_Big",field="spell",compare=.Equal,number=7,passed=true},
        {storage="Wait_Big",field="active",compare=.Equal,value="true",passed=true},
        {storage="Wait_Big",field="school",compare=.Equal,text="Ice",passed=true},
        {storage="Wait_Big",field="name",compare=.Equal,text="Blaze",passed=true},
        {storage="Wait_Big",field="grid.3.5",compare=.Equal,number=9,passed=true},
        {storage="Wait_Big",field="grid[3][5]",compare=.Equal,number=9,passed=true},
        {storage="Wait_Big",field="grid.-1.-1",compare=.Equal,number=4,passed=true},
        {storage="Wait_Big",field="grid.3",length=true,compare=.Equal,number=600,passed=true},
        {storage="Wait_Big",field="rewind.frames[2].position.y",compare=.Equal,number=1.5,passed=true},
        {storage="Wait_Big",field="rewind.frames.2",compare=.Exists,passed=true},
        {storage="Wait_Big",field="recent",length=true,compare=.Equal,number=2,passed=true},
        {storage="Wait_Big",field="recent.2",compare=.Gone,passed=true},
        {storage="Wait_Big",field="held.-1",compare=.Equal,number=7,passed=true},
        {storage="Wait_Big",field="held.3",compare=.Gone,passed=true},
        {storage="Wait_Big",field="grid.600",compare=.Gone,passed=true},
        {storage="Wait_Big",field="grid.600.0",compare=.Exists,passed=false},
        {storage="Time",field="tick",compare=.Equal,number=12,passed=true},
        {storage="Wait_Big",field="",says=`storage "Wait_Big" holds `},
        {storage="Wait_Big",field="grid",says=`storage "Wait_Big" field "grid" holds 360000 bytes, more than the`},
        {storage="Wait_Big",field="nothing",says=`"nothing" is not there; it has spell, active, school, name, grid`},
        {storage="Wait_Big",field="spell.x",says="goes inside a value that has nothing inside"},
        {storage="Wait_Big",field="name.0",says="goes inside a value that has nothing inside"},
        {storage="Wait_Big",field="grid.a",says=`"a" is not an element of a list of 600`},
        {storage="Wait_Big",field="grid..1",says="empty name"},
        {storage="Wait_Big",field="grid[3",says="no ] that closes it"},
        {storage="Wait_Small",field="spell",says="is not a storage of the game"},
    }
    for c in cases {
        condition:=Api_Play_Condition{compare=c.compare,number=c.number,value=serial.Json(c.value),length=c.length}
        copy(condition.storage[:],c.storage)
        copy(condition.field[:],c.field)
        copy(condition.text[:],c.text)
        read,problem:=api_condition_read(&s,ref,&condition)
        if c.says!="" {
            testing.expectf(t,strings.contains(problem,c.says),"%s %q: %q",c.storage,c.field,problem)
            continue
        }
        testing.expectf(t,problem=="" && read.passed==c.passed,"%s %q: %v %q %q",c.storage,c.field,read.passed,read.value,problem)
    }
}

// A value of a type shorter than its type, or of no type of the schema, is refused before it is walked.
@(test)
a_value_shorter_than_its_type_is_not_walked :: proc(t:^testing.T) {
    schema:serial.Schema
    serial.schema_init(&schema,context.temp_allocator)
    defer serial.schema_destroy(&schema)
    type,added:=serial.schema_add(&schema,Wait_Rewind)
    if !testing.expect(t,added) {return}
    there:=true
    _,problem,_:=api_value_select(&schema,type,make([]u8,size_of(Wait_Rewind)-1,context.temp_allocator),"head",&there)
    testing.expect_value(t,problem,"is not of its type")
    _,problem,_=api_value_select(&schema,serial.Type_Index(len(schema.types)),nil,"head",&there)
    testing.expect_value(t,problem,"is not of its type")
}
