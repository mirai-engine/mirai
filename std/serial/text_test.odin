package serial

import "core:mem"
import "core:strings"
import "core:testing"
import "mirai:std/base"

@(private="file") Shape :: enum u8 {Box,Sphere=4,Mesh}
@(private="file") Signed :: enum i8 {Down=-1,None,Up}
@(private="file") Layer :: enum {Static,Dynamic,Debris}
@(private="file") Inner :: struct {offset:[3]f32,shape:Shape}
@(private="file")
Sample :: struct {
    id:base.Entity_Id,
    target:base.Entity,
    mesh:base.Asset_Id,
    name:[12]u8 `mirai:"text"`,
    speed:f32,
    ratio:f64,
    half:f16,
    count:i16,
    big:u64,
    wide:i128,
    on:bool,
    direction:Signed,
    layers:bit_set[Layer;u8],
    many:bit_set[0..<100;u128],
    parts:[2]Inner,
    grid:[2][2]u8,
    cache:u32 `mirai:"transient"`,
}

@(private="file")
bytes_of :: proc(value:^$T) -> []u8 {return ([^]u8)(value)[:size_of(T)]}

@(private="file")
written :: proc(s:^Schema,type:Type_Index,data:[]u8,format:Text_Format,allocator:=context.temp_allocator) -> string {
    w:Writer;writer_init(&w,allocator=allocator)
    text_write(&w,s,type,data,format)
    return string(writer_bytes(&w))
}

@(private="file")
parsed :: proc(s:^Schema,type:Type_Index,text:string,dst:[]u8) -> Text_Error {
    r:Text_Reader;text_reader_init(&r,text,context.temp_allocator)
    if text_read(&r,s,type,dst) {text_end(&r)}
    return r.error
}

@(test)
text_writes_a_value_in_the_order_and_words_of_its_schema :: proc(t:^testing.T) {
    s:Schema;schema_init(&s);defer schema_destroy(&s)
    type,ok:=schema_add(&s,Sample)
    testing.expect(t,ok,s.error)
    value:=Sample{
        id=0x1f,target=base.Entity(0x200000003),mesh={0xa,0xb},name={0='B',1='o',2='x',3=' ',4='"',5='1',6='"'},
        speed=0.1,ratio=-2.5e-9,half=1.5,count=-12,big=max(u64),wide=-2,on=true,direction=.Down,
        layers={.Static,.Debris},many={1,64},parts={{{1,2,3},.Sphere},{{0,-0.5,1e10},.Mesh}},grid={{1,2},{3,4}},cache=7,
    }
    PRETTY :: `{
  "id": "0x000000000000001f",
  "target": "0x0000000200000003",
  "mesh": "000000000000000a000000000000000b",
  "name": "Box \"1\"",
  "speed": 0.1,
  "ratio": -2.5e-09,
  "half": 1.5,
  "count": -12,
  "big": 18446744073709551615,
  "wide": "0xfffffffffffffffffffffffffffffffe",
  "on": true,
  "direction": "Down",
  "layers": ["Static", "Debris"],
  "many": [1, 64],
  "parts": [
    {
      "offset": [1, 2, 3],
      "shape": "Sphere"
    },
    {
      "offset": [0, -0.5, 1e+10],
      "shape": "Mesh"
    }
  ],
  "grid": [
    [1, 2],
    [3, 4]
  ]
}`
    LINE :: `{"id": "0x000000000000001f", "target": "0x0000000200000003", "mesh": "000000000000000a000000000000000b", "name": "Box \"1\"", "speed": 0.1, "ratio": -2.5e-09, "half": 1.5, "count": -12, "big": 18446744073709551615, "wide": "0xfffffffffffffffffffffffffffffffe", "on": true, "direction": "Down", "layers": ["Static", "Debris"], "many": [1, 64], "parts": [{"offset": [1, 2, 3], "shape": "Sphere"}, {"offset": [0, -0.5, 1e+10], "shape": "Mesh"}], "grid": [[1, 2], [3, 4]]}`
    testing.expect_value(t,written(&s,type,bytes_of(&value),.Pretty),PRETTY)
    testing.expect_value(t,written(&s,type,bytes_of(&value),.Line),LINE)
    free_all(context.temp_allocator)
}

@(test)
text_reads_back_the_bytes_it_wrote :: proc(t:^testing.T) {
    s:Schema;schema_init(&s);defer schema_destroy(&s)
    type,_:=schema_add(&s,Sample)
    layout:Layout;layout_init(&layout,&s,type);defer layout_destroy(&layout)
    state:=u64(0x5eed)
    texts:=[?]string{"","Box","añil ☃","tab\there","quote\" back\\slash","line\nbreak\r\x01\x1f","exactly12byt"}
    for round in 0..<1200 {
        value:Sample
        raw:=bytes_of(&value)
        for &b in raw {b=u8(fuzz_next(&state))}
        value.on=fuzz_next(&state)&1!=0
        value.many&={0,1,2,50,63,64,65,99}
        switch round%4 {
        case 0: // text, clean after its NUL
            mem.zero_slice(value.name[:])
            copy(value.name[:],texts[fuzz_next(&state)%len(texts)])
        case 1: // bytes that are not text: kept one by one
        case 2: // special floats
            specials:=[?]u64{0x7ff0000000000000,0xfff0000000000000,0x7ff8000000000000,0xfff8000000000000,0x7ff0000000000001,0x8000000000000000,1,0x000fffffffffffff,0x7fefffffffffffff}
            value.ratio=transmute(f64)specials[fuzz_next(&state)%len(specials)]
            narrow:=[?]u32{0x7f800000,0xff800000,0x7fc00000,0xffc00000,0x7f800001,0x80000000,1,0x007fffff,0x7f7fffff}
            value.speed=transmute(f32)narrow[fuzz_next(&state)%len(narrow)]
            halves:=[?]u16{0x7c00,0xfc00,0x7e00,0xfe00,0x7c01,0x8000,1,0x03ff,0x7bff}
            value.half=transmute(f16)halves[fuzz_next(&state)%len(halves)]
        case 3: // members by name
            value.direction=Signed(i8(fuzz_next(&state)%3)-1)
            value.parts[0].shape=.Mesh
        }
        image,back:[size_of(Sample)]u8
        value_write(&layout,image[:],&value,1)
        for format in Text_Format {
            text:=written(&s,type,image[:],format)
            for &b in back {b=0xcc}
            error:=parsed(&s,type,text,back[:])
            if !testing.expect_value(t,error.code,Text_Error_Code.None) {return}
            // What the text does not carry, padding, is whatever back had.
            clean:[size_of(Sample)]u8
            value_write(&layout,clean[:],&back,1)
            if !testing.expect(t,mem.compare(clean[:],image[:])==0,text) {return}
        }
        free_all(context.temp_allocator)
    }
}

@(test)
text_spells_what_json_cannot_say_exactly :: proc(t:^testing.T) {
    Odd :: struct {a,b,c,d:f32,e:f64,shape:Shape,layers:bit_set[Layer;u8],name:[4]u8 `mirai:"text"`,dirty:[4]u8 `mirai:"text"`,full:[3]u8 `mirai:"text"`}
    s:Schema;schema_init(&s);defer schema_destroy(&s)
    type,_:=schema_add(&s,Odd)
    value:=Odd{
        a=transmute(f32)u32(0x7fc00000),b=transmute(f32)u32(0xff800000),c=transmute(f32)u32(0x7fc00001),d=transmute(f32)u32(0x80000000),
        e=transmute(f64)u64(0x7ff0000000000000),shape=Shape(9),layers=transmute(bit_set[Layer;u8])u8(0x85),
        name={0xff,'a',0,0},dirty={'a',0,'b',0},full={'a','b','c'},
    }
    EXPECTED :: `{"a": "nan", "b": "-inf", "c": "bits:0x7fc00001", "d": -0, "e": "inf", "shape": 9, "layers": ["Static", "Debris", 7], "name": [255, 97, 0, 0], "dirty": [97, 0, 98, 0], "full": "abc"}`
    text:=written(&s,type,bytes_of(&value),.Line)
    testing.expect_value(t,text,EXPECTED)
    back:Odd
    testing.expect_value(t,parsed(&s,type,text,bytes_of(&back)).code,Text_Error_Code.None)
    testing.expect(t,mem.compare(bytes_of(&back),bytes_of(&value))==0)
    free_all(context.temp_allocator)
}

@(test)
text_writes_what_differs_from_a_base_and_reads_back_over_it :: proc(t:^testing.T) {
    Changed :: struct {speed:f32,inner:Inner,name:[8]u8 `mirai:"text"`,cache:u32 `mirai:"transient"`}
    s:Schema;schema_init(&s);defer schema_destroy(&s)
    type,_:=schema_add(&s,Changed)
    base:=Changed{speed=1,inner={{1,2,3},.Box},cache=5}
    value:=base
    value.inner.shape=.Mesh
    value.name={0='A'}
    value.cache=9
    w:Writer;writer_init(&w,allocator=context.temp_allocator)
    text_write_changed(&w,&s,type,bytes_of(&value),bytes_of(&base))
    text:=string(writer_bytes(&w))
    testing.expect_value(t,text,`{"inner": {"shape": "Mesh"}, "name": "A"}`)
    back:=base
    back.cache=value.cache
    testing.expect_value(t,parsed(&s,type,text,bytes_of(&back)).code,Text_Error_Code.None)
    testing.expect(t,mem.compare(bytes_of(&back),bytes_of(&value))==0)
    same:Writer;writer_init(&same,allocator=context.temp_allocator)
    text_write_changed(&same,&s,type,bytes_of(&base),bytes_of(&base))
    testing.expect_value(t,string(writer_bytes(&same)),"{}")
    free_all(context.temp_allocator)
}

@(test)
text_floats_round_trip_bit_for_bit :: proc(t:^testing.T) {
    state:=u64(0xf10a7)
    w:Writer;writer_init(&w);defer writer_destroy(&w)
    r:Text_Reader;text_reader_init(&r,"");defer text_reader_destroy(&r)
    s:Schema;schema_init(&s);defer schema_destroy(&s)
    Floats :: struct {a:f64,b:f32,c:f16}
    type,_:=schema_add(&s,Floats)
    for _ in 0..<40000 {
        value:Floats
        bits:=fuzz_next(&state)
        value.a=transmute(f64)bits
        value.b=transmute(f32)u32(bits>>13)
        value.c=transmute(f16)u16(bits>>40)
        writer_reset(&w)
        text_write(&w,&s,type,bytes_of(&value),.Line)
        back:Floats
        r.text,r.offset,r.error=string(writer_bytes(&w)),0,{}
        if !testing.expect(t,text_read(&r,&s,type,bytes_of(&back)),r.text) {return}
        if !testing.expect(t,mem.compare(bytes_of(&back),bytes_of(&value))==0,r.text) {return}
    }
    // Round numbers stay short.
    value:=Floats{a=0.1,b=0.1,c=0.5}
    writer_reset(&w)
    text_write(&w,&s,type,bytes_of(&value),.Line)
    testing.expect_value(t,string(writer_bytes(&w)),`{"a": 0.1, "b": 0.1, "c": 0.5}`)
}

@(test)
text_reader_reports_the_first_error_and_its_place :: proc(t:^testing.T) {
    s:Schema;schema_init(&s);defer schema_destroy(&s)
    type,_:=schema_add(&s,Sample)
    Case :: struct {text:string,code:Text_Error_Code,offset:int}
    cases:=[?]Case{
        {`[]`,.Expected_Object,0},
        {`{"speed": 1`,.Syntax,11},
        {`{"speed" 1}`,.Syntax,9},
        {`{"speed": 1,}`,.Expected_String,12},
        {`{"nope": 1}`,.Unknown_Field,1},
        {`{"speed": "fast"}`,.Expected_Number,10},
        {`{"speed": 1e999}`,.Out_Of_Range,10},
        {`{"speed": 1.}`,.Syntax,12},
        {`{"count": 1.5}`,.Expected_Integer,10},
        {`{"count": 40000}`,.Out_Of_Range,10},
        {`{"count": -40000}`,.Out_Of_Range,10},
        {`{"big": 18446744073709551616}`,.Out_Of_Range,8},
        {`{"big": -1}`,.Out_Of_Range,8},
        {`{"on": 1}`,.Expected_Bool,7},
        {`{"direction": "Sideways"}`,.Unknown_Member,14},
        {`{"layers": "Static"}`,.Expected_Array,11},
        {`{"layers": ["Static", "Wet"]}`,.Unknown_Member,22},
        {`{"layers": [8]}`,.Out_Of_Range,12},
        {`{"name": "a name too long"}`,.Text_Too_Long,9},
        {`{"name": [1,2,3,4,5,6,7,8,9,10,11,12,13]}`,.Too_Many_Elements,37},
        {`{"id": "xyz"}`,.Invalid_Id,7},
        {`{"id": -1}`,.Out_Of_Range,7},
        {`{"mesh": "0x12"}`,.Invalid_Id,9},
        {`{"mesh": 12}`,.Expected_String,9},
        {`{"parts": [{}, {}, {}]}`,.Too_Many_Elements,19},
        {`{"parts": {}}`,.Expected_Array,10},
        {`{"name": "bad \q escape"}`,.Syntax,14},
        {`{"name": "open`,.Syntax,9},
        {`{"name": "\ud800"}`,.Syntax,16},
        {`{"speed": 1} trailing`,.Syntax,13},
        {`{"wide": "0x12"}`,.Invalid_Id,9},
    }
    for entry in cases {
        value:Sample
        error:=parsed(&s,type,entry.text,bytes_of(&value))
        if error.code!=entry.code || error.offset!=entry.offset {
            testing.expectf(t,false,"%s: %v at %d, expected %v at %d",entry.text,error.code,error.offset,entry.code,entry.offset)
        }
    }
    line,column:=text_position("{\n  \"a\": 1,\n  \"b\": x\n}",19)
    testing.expect(t,line==3 && column==8)
    free_all(context.temp_allocator)
}

@(test)
text_errors_say_where_in_the_value_and_the_names_the_type_has :: proc(t:^testing.T) {
    s:Schema;schema_init(&s);defer schema_destroy(&s)
    type,_:=schema_add(&s,Sample)
    Case :: struct {text,prefix,message:string}
    cases:=[?]Case{
        {`{"direction": "Sideways"}`,"",`direction: "Sideways" is not one of Down, None, Up`},
        {`{"layers": ["Static", "Wet"]}`,"",`layers: "Wet" is not one of Static, Dynamic, Debris`},
        {`{"parts": [{}, {"shape": "Cone"}]}`,"",`parts[1].shape: "Cone" is not one of Box, Sphere, Mesh`},
        {`{"parts": [{"offset": [0, "x", 0]}]}`,"value",`value.parts[0].offset[1]: expected a number`},
        {`{"grid": [[1, 2], [3, 300]]}`,"",`grid[1][1]: number out of range`},
        {`{"parts": [{"size": 1}]}`,"",`parts[0]: "size" is not a field: the fields are offset, shape`},
        {`{"speed": 1`,"value","value: malformed JSON"},
    }
    for entry in cases {
        value:Sample
        r:Text_Reader;text_reader_init(&r,entry.text,context.temp_allocator)
        if text_read(&r,&s,type,bytes_of(&value)) {text_end(&r)}
        message:=text_error_message(&r,entry.prefix,context.temp_allocator)
        testing.expectf(t,message==entry.message,"%s: %q, expected %q",entry.text,message,entry.message)
    }
    // The names stay with the reader after the schema goes.
    other:Schema;schema_init(&other)
    inner,_:=schema_add(&other,Inner)
    r:Text_Reader;text_reader_init(&r,`{"shape": "Cone"}`,context.temp_allocator)
    value:Inner
    testing.expect(t,!text_read(&r,&other,inner,bytes_of(&value)))
    schema_destroy(&other)
    testing.expect_value(t,text_error_message(&r,allocator=context.temp_allocator),`shape: "Cone" is not one of Box, Sphere, Mesh`)
    free_all(context.temp_allocator)
}

@(test)
text_reader_keeps_what_the_text_does_not_mention :: proc(t:^testing.T) {
    s:Schema;schema_init(&s);defer schema_destroy(&s)
    type,_:=schema_add(&s,Sample)
    value:=Sample{speed=3,count=5,parts={{{1,2,3},.Sphere},{{4,5,6},.Mesh}},name={0='o',1='l',2='d'},layers={.Dynamic}}
    text:=` { "count" : 9 , "parts" : [ { "offset" : [ 7 ] } ] , "name" : "é😀\n" , "layers" : [ ] , "id" : 31 , "wide" : -3 , "many" : [ 99 ] } `
    testing.expect_value(t,parsed(&s,type,text,bytes_of(&value)).code,Text_Error_Code.None)
    testing.expect_value(t,value.speed,f32(3))
    testing.expect_value(t,value.count,i16(9))
    testing.expect_value(t,value.parts[0].offset,[3]f32{7,2,3})
    testing.expect_value(t,value.parts[0].shape,Shape.Sphere)
    testing.expect_value(t,value.parts[1].offset,[3]f32{4,5,6})
    testing.expect_value(t,text_field(value.name[:]),"é😀\n")
    testing.expect(t,value.layers=={})
    testing.expect_value(t,value.id,base.Entity_Id(31))
    testing.expect_value(t,value.wide,i128(-3))
    testing.expect(t,value.many==bit_set[0..<100;u128]{99})
    free_all(context.temp_allocator)
}

@(test)
text_reader_walks_any_json :: proc(t:^testing.T) {
    r:Text_Reader
    text_reader_init(&r,` {"a": [1, 2.5e3, {"b": null, "c": [true, false, "x\"y"]}], "d": {}, "e": [], "f": -7} tail`)
    defer text_reader_destroy(&r)
    testing.expect(t,text_skip(&r))
    testing.expect_value(t,r.text[r.offset:]," tail")
    testing.expect(t,!text_end(&r))
    testing.expect_value(t,r.error.code,Text_Error_Code.Syntax)

    keys:Text_Reader
    text_reader_init(&keys,`{"first": "plain", "sec\tond": "a\\b", "third": 12, "fourth": -4}`)
    defer text_reader_destroy(&keys)
    testing.expect(t,text_expect(&keys,'{'))
    key,_:=text_string(&keys);testing.expect_value(t,key,"first")
    testing.expect(t,text_expect(&keys,':'))
    value,_:=text_string(&keys);testing.expect_value(t,value,"plain")
    testing.expect(t,text_accept(&keys,','))
    key,_=text_string(&keys);testing.expect_value(t,key,"sec\tond")
    testing.expect(t,text_expect(&keys,':'))
    value,_=text_string(&keys);testing.expect_value(t,value,`a\b`)
    testing.expect(t,text_accept(&keys,','))
    text_string(&keys);text_expect(&keys,':')
    negative,magnitude,ok:=text_integer(&keys)
    testing.expect(t,ok && !negative && magnitude==12)
    text_accept(&keys,',');text_string(&keys);text_expect(&keys,':')
    negative,magnitude,ok=text_integer(&keys)
    testing.expect(t,ok && negative && magnitude==4)
    testing.expect(t,text_expect(&keys,'}') && text_end(&keys))

    deep:Text_Reader
    nested:=make([]u8,TEXT_MAX_DEPTH*2+8,context.temp_allocator)
    for &b in nested {b='['}
    text_reader_init(&deep,string(nested))
    defer text_reader_destroy(&deep)
    testing.expect(t,!text_skip(&deep))
    testing.expect_value(t,deep.error.code,Text_Error_Code.Too_Deep)

    // A reader with assets takes a name where an id goes, and says why not.
    Holder :: struct {mesh:base.Asset_Id `mirai:"kind=.mesh"`}
    schema:Schema;schema_init(&schema);defer schema_destroy(&schema)
    holder_type,_:=schema_add_type_info(&schema,type_info_of(Holder))
    resolve :: proc(user:rawptr,name,kinds:string) -> (id:base.Asset_Id,problem:string) {
        if name=="cube" && kinds==".mesh" {return {1,2},""}
        return {},"no such mesh"
    }
    found:Holder
    named:Text_Reader;text_reader_init(&named,`{"mesh": "cube"}`,context.temp_allocator);named.assets={nil,resolve}
    testing.expect(t,text_read(&named,&schema,holder_type,mem.ptr_to_bytes(&found)) && found.mesh==base.Asset_Id{1,2})
    missing:Text_Reader;text_reader_init(&missing,`{"mesh": "sphere"}`,context.temp_allocator);missing.assets={nil,resolve}
    testing.expect(t,!text_read(&missing,&schema,holder_type,mem.ptr_to_bytes(&found)) && missing.error.code==.Unknown_Asset)
    testing.expect_value(t,text_error_message(&missing,allocator=context.temp_allocator),"mesh: no such mesh")

    id,id_ok:=text_parse_asset_id("000000000000000a000000000000000b")
    testing.expect(t,id_ok && id==base.Asset_Id{0xa,0xb})
    _,short:=text_parse_asset_id("abc")
    testing.expect(t,!short)
    hex,hex_ok:=text_parse_hex("0xFf")
    testing.expect(t,hex_ok && hex==255)
    _,empty:=text_parse_hex("0x")
    testing.expect(t,!empty)
    free_all(context.temp_allocator)
}

@(test)
text_trims_a_tagged_array_after_its_last_element_with_a_byte_set :: proc(t:^testing.T) {
    Entry :: struct {id:u32,weight:f32}
    Trimmed :: struct {
        entries:[4]Entry `mirai:"trim"`,
        whole:[3]u8,
    }
    s:Schema;schema_init(&s);defer schema_destroy(&s)
    type,ok:=schema_add(&s,Trimmed)
    testing.expect(t,ok,s.error)
    value:=Trimmed{entries={{1,0.5},{},{3,0},{}}}
    testing.expect_value(t,written(&s,type,bytes_of(&value),.Line),`{"entries": [{"id": 1, "weight": 0.5}, {"id": 0, "weight": 0}, {"id": 3, "weight": 0}], "whole": [0, 0, 0]}`)
    empty:Trimmed
    testing.expect_value(t,written(&s,type,bytes_of(&empty),.Line),`{"entries": [], "whole": [0, 0, 0]}`)
}

@(private="file") Mode :: distinct u16
@(private="file") Mode_Mask :: distinct u32
@(private="file") Moving :: struct {mode:Mode,allowed:Mode_Mask}

@(private="file") Loose_Mode :: enum u8 {Walk,Run_Fast}
@(private="file") Loose_Flag :: enum u8 {Fire,Ice_Cold}
@(private="file") Loose :: struct {mode:Loose_Mode,flags:bit_set[Loose_Flag;u8],last:u8}

@(test)
a_reader_of_loose_names_takes_members_as_a_person_writes_them_and_no_other_does :: proc(t:^testing.T) {
    s:Schema;schema_init(&s);defer schema_destroy(&s)
    type,ok:=schema_add(&s,Loose)
    if !testing.expect(t,ok,s.error) {return}
    cases:=[]struct{text:string,loose:bool,code:Text_Error_Code,says:string,mode:Loose_Mode,flags:bit_set[Loose_Flag;u8]}{
        {`{"mode":"Run_Fast"}`,false,.None,"",.Run_Fast,{}},
        {`{"mode":"run fast","flags":["ICE-COLD"]}`,true,.None,"",.Run_Fast,{.Ice_Cold}},
        {`{"mode":"runfast"}`,false,.Unknown_Member,`mode: "runfast" is not one of Walk, Run_Fast`,.Walk,{}},
        {`{"mode":"swim"}`,true,.Unknown_Member,`mode: "swim" is not one of its names`,.Walk,{}},
        {`{"flags":["Rain"]}`,true,.Unknown_Member,`flags: "Rain" is not one of its names`,.Walk,{}},
    }
    for c in cases {
        value:Loose
        r:Text_Reader;text_reader_init(&r,c.text,context.temp_allocator)
        r.loose_names=c.loose
        if text_read(&r,&s,type,bytes_of(&value)) {text_end(&r)}
        testing.expectf(t,r.error.code==c.code,"%s: %v",c.text,r.error.code)
        if c.code!=.None {
            message:=text_error_message(&r,allocator=context.temp_allocator)
            testing.expectf(t,strings.has_prefix(message,c.says),"%s: %s",c.text,message)
            continue
        }
        testing.expect(t,value.mode==c.mode && value.flags==c.flags,c.text)
    }
}

@(private="file") Listed_Part :: struct {name:string,weights:[]f32,at:[2]i32}
@(private="file") Listed :: struct {
    title:string,
    parts:[]Listed_Part,
    names:[][8]u8 `mirai:"text"`,
    lines:[]string,
    free:Json,
    count:u8,
}
@(private="file") Nested :: struct {inner:struct {child:[]Nested}}

// A schema that is unsized takes slices, strings and any JSON: text reads
// them into the allocator of its reader and writes them back the same.
@(test)
an_unsized_schema_reads_and_writes_slices_strings_and_any_json :: proc(t:^testing.T) {
    plain:Schema;schema_init(&plain);defer schema_destroy(&plain)
    _,taken:=schema_add(&plain,Listed)
    testing.expect(t,!taken && plain.error=="title: string is not plain data",plain.error)
    s:Schema;schema_init(&s);defer schema_destroy(&s)
    s.unsized=true
    type,ok:=schema_add(&s,Listed)
    if !testing.expect(t,ok,s.error) {return}
    testing.expect_value(t,schema_type(&s,schema_fields(&s,type)[1].type).kind,Type_Kind.Slice)
    testing.expect(t,schema_validate(&s)==.Invalid_Type,"an unsized type has no binary schema")
    _,recursive:=schema_add(&s,Nested)
    testing.expect(t,!recursive && strings.contains(s.error,"inner.child"),s.error)

    text:=`{"title": "a \"b\"", "parts": [{"name": "x", "weights": [1, 2.5], "at": [3, 4]}, {"name": "", "weights": [], "at": [0, 0]}], "names": ["ab", ""], "lines": ["one", "two"], "free": {"k":[true,null, 1e3]}, "count": 7}`
    value:Listed
    r:Text_Reader;text_reader_init(&r,text,context.temp_allocator)
    if !testing.expect(t,text_read(&r,&s,type,bytes_of(&value)) && text_end(&r),text_error_message(&r,allocator=context.temp_allocator)) {return}
    testing.expect(t,value.title==`a "b"` && len(value.parts)==2 && value.parts[0].name=="x" && len(value.parts[0].weights)==2 && value.parts[0].weights[1]==2.5 && value.parts[0].at=={3,4})
    testing.expect(t,len(value.names)==2 && base.text_get(value.names[0][:])=="ab" && len(value.lines)==2 && value.lines[1]=="two")
    testing.expect_value(t,string(value.free),`{"k":[true,null, 1e3]}`)
    testing.expect_value(t,value.count,7)
    w:Writer;writer_init(&w,allocator=context.temp_allocator)
    text_write(&w,&s,type,bytes_of(&value),.Line)
    testing.expect_value(t,string(writer_bytes(&w)),text)
    // Nothing held writes as empty lists, an empty string and null.
    empty:Listed
    w.count=0
    text_write(&w,&s,type,bytes_of(&empty),.Line)
    testing.expect_value(t,string(writer_bytes(&w)),`{"title": "", "parts": [], "names": [], "lines": [], "free": null, "count": 0}`)

    refused:=[]struct{text:string,code:Text_Error_Code,path:string}{
        {`{"parts": {}}`,.Expected_Array,"parts"},
        {`{"parts": [{"weights": [1, "x"]}]}`,.Expected_Number,"parts[0].weights[1]"},
        {`{"parts": [{}, {"nope": 1}]}`,.Unknown_Field,"parts[1]"},
        {`{"names": ["123456789"]}`,.Text_Too_Long,"names[0]"},
        {`{"lines": ["a", 2]}`,.Expected_String,"lines[1]"},
        {`{"title": 4}`,.Expected_String,"title"},
        {`{"free": [1,}`,.Expected_Number,""},
        {`{"parts": [`,.Expected_Number,""},
    }
    for c in refused {
        into:Listed
        reader:Text_Reader;text_reader_init(&reader,c.text,context.temp_allocator)
        testing.expectf(t,!text_read(&reader,&s,type,bytes_of(&into)) && reader.error.code==c.code,"%s: %v",c.text,reader.error.code)
        if c.path!="" {testing.expectf(t,string(reader.error.path[:reader.error.path_length])==c.path,"%s: %s",c.text,string(reader.error.path[:reader.error.path_length]))}
    }
    // The same through the schema a call makes for one value: what a file of Mirai is read and written with.
    decoded:struct {title:string,lines:[dynamic]string,count:u8}
    testing.expect_value(t,text_decode(`{"title":"a","lines":["x","y"],"count":2}`,&decoded,context.temp_allocator),"")
    append(&decoded.lines,"z")
    encoded,encoded_ok:=text_encode(decoded,.Line,context.temp_allocator)
    testing.expect(t,encoded_ok && string(encoded)==`{"title": "a", "lines": ["x", "y", "z"], "count": 2}`,string(encoded))
    testing.expect_value(t,text_decode("{\n \"title\":\"a\",\n \"more\":1}",&decoded,context.temp_allocator),`"more" is not a field: the fields are title, lines, count at line 3 column 2`)
    testing.expect_value(t,text_decode(`{"more":{"deep":[1]},"count":9}`,&decoded,context.temp_allocator,skip_unknown=true),"")
    testing.expect_value(t,decoded.count,9)
    pointer:struct {p:^int}
    testing.expect(t,text_decode(`{}`,&pointer)!="","a type no schema takes is a problem, not a crash")
    // Without memory for what a slice or a string holds it says so and reads no further.
    for limit in ([]int{0,8,40,64}) {
        buffer:[64]u8
        arena:mem.Arena
        mem.arena_init(&arena,buffer[:limit])
        into:Listed
        reader:Text_Reader;text_reader_init(&reader,text,context.temp_allocator)
        reader.values=mem.arena_allocator(&arena)
        testing.expect(t,!text_read(&reader,&s,type,bytes_of(&into)) && reader.error.code==.Out_Of_Memory)
    }
    // Any bytes: it reads or it fails, inside its text.
    h:=base.Hostile{31}
    for _ in 0..<3000 {
        bytes:=make([]u8,len(text),context.temp_allocator)
        copy(bytes,text)
        for _ in 0..<1+base.hostile_int(&h,4) {bytes[base.hostile_int(&h,len(bytes))]=u8(base.hostile_int(&h,128))}
        into:Listed
        reader:Text_Reader;text_reader_init(&reader,string(bytes[:base.hostile_int(&h,len(bytes))+1]),context.temp_allocator)
        if text_read(&reader,&s,type,bytes_of(&into)) {
            out:Writer;writer_init(&out,allocator=context.temp_allocator)
            text_write(&out,&s,type,bytes_of(&into),.Line)
        }
        free_all(context.temp_allocator)
    }
}

// An integer with names is read and written by them, a number that has none
// stays a number, a mask names its bits, and the names are not its layout.
@(test)
named_integers_take_their_names_in_text_and_not_in_their_layout :: proc(t:^testing.T) {
    plain:Schema;schema_init(&plain);defer schema_destroy(&plain)
    plain_index,_:=schema_add(&plain,Moving)
    s:Schema;schema_init(&s);defer schema_destroy(&s)
    s.named=make(map[typeid]Named,context.temp_allocator)
    s.named[Mode]={choices={{"walking",1},{"swim",16}}}
    s.named[Mode_Mask]={choices={{"walking",1},{"swim",16}},bits=true}
    index,ok:=schema_add(&s,Moving)
    if !testing.expect(t,ok) {return}
    testing.expect_value(t,schema_layout_hash(&s,index),schema_layout_hash(&plain,plain_index))
    value:=Moving{mode=16,allowed=Mode_Mask(1<<1|1<<16)}
    text:=written(&s,index,bytes_of(&value),.Line)
    testing.expectf(t,text==`{"mode": "swim", "allowed": ["walking", "swim"]}`,"%s",text)
    value.mode=7
    testing.expectf(t,written(&s,index,bytes_of(&value),.Line)==`{"mode": 7, "allowed": ["walking", "swim"]}`,"%s",written(&s,index,bytes_of(&value),.Line))
    back:Moving
    r:Text_Reader;text_reader_init(&r,`{"mode":"walking","allowed":["swim",3]}`,context.temp_allocator)
    testing.expect(t,text_read(&r,&s,index,bytes_of(&back)))
    testing.expect_value(t,back,Moving{mode=1,allowed=Mode_Mask(1<<16|1<<3)})
    // A file keeps the names, and its schema read back writes the same bytes.
    w:Writer;writer_init(&w);defer writer_destroy(&w)
    schema_write(&w,&s)
    file:Schema
    reader:=reader_init(writer_bytes(&w))
    if !testing.expect_value(t,schema_read(&reader,&file),Schema_Error.None) {return}
    defer schema_destroy(&file)
    value.mode=16
    testing.expectf(t,written(&file,index,bytes_of(&value),.Line)==`{"mode": "swim", "allowed": ["walking", "swim"]}`,"%s",written(&file,index,bytes_of(&value),.Line))
    again:Writer;writer_init(&again);defer writer_destroy(&again)
    schema_write(&again,&file)
    testing.expect(t,string(writer_bytes(&again))==string(writer_bytes(&w)))
}
