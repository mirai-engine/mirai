package asset

import "core:mem"
import "core:strings"
import "core:testing"
import "mirai:std/base"
import "mirai:std/serial"

@(private="file") KIND_TOOL :: Fourcc(u32('T')|u32('O')<<8|u32('O')<<16|u32('L')<<24)
@(private="file") Tool_Shade :: enum u8 {Flat,Smooth}
@(private="file") Tool_Tag :: enum u8 {Hot,Cold,Wet}
@(private="file") Tool_Info :: struct {count:u32,shade:Tool_Shade,material:base.Asset_Id}
@(private="file") Tool_Item :: struct {weight:f32 `mirai:"min=0,max=10,unit=kg"`,tags:bit_set[Tool_Tag;u8],offset:[2]f32}
@(private="file") Tool_Name :: [8]u8

@(private="file")
tool_document :: proc(doc:^Document,types:^Types) {
    document_init(doc,KIND_TOOL,{0x11,0x22})
    doc.kind_version=2
    doc.flags={.Cooked}
    info:=Tool_Info{count=2,shade=.Smooth,material={5,6}}
    document_put_row(doc,types,"info",&info)
    table,_:=document_table_add(doc,"items")
    document_resize(doc,table,2)
    ids:=[2]base.Entity_Id{0x1f,0x20}
    names:=[2]Tool_Name{{0='a',1='x',2='e'},{0='s',1='a',2='w'}}
    items:=[2]Tool_Item{{1.5,{.Hot},{0,1}},{0.25,{.Cold,.Wet},{2,3}}}
    document_column_put(doc,types,table,"id",ids[:])
    document_column_put(doc,types,table,"name",names[:],{.Text})
    document_column_put(doc,types,table,"value",items[:])
    doc.tables[table].key=0
    uses,_:=document_table_add(doc,"uses")
    document_resize(doc,uses,2)
    rows:=[2]u32{1,0}
    counts:=[2]u16{7,9}
    ref,_:=document_column_put(doc,types,uses,"item",rows[:])
    document_column_put(doc,types,uses,"count",counts[:])
    doc.tables[uses].columns[ref].ref=table
    blob:=[5]u8{1,2,3,4,5}
    document_put(doc,types,"blob",blob[:],{.Bulk},.None,16)
}

@(private="file")
GOLDEN :: `{
  "mirai_asset": 1,
  "kind": "TOOL",
  "kind_version": 2,
  "id": "00000000000000110000000000000022",
  "flags": ["Cooked"],
  "dependencies": [
    "00000000000000050000000000000006"
  ],
  "schema": [
    {"kind": "Uint", "size": 4, "align": 4},
    {"kind": "Enum", "name": "Tool_Shade", "size": 1, "align": 1, "choices": [{"name": "Flat", "value": 0}, {"name": "Smooth", "value": 1}]},
    {"kind": "Asset", "size": 16, "align": 8},
    {"kind": "Struct", "name": "Tool_Info", "size": 24, "align": 8, "fields": [
      {"name": "count", "type": 0, "offset": 0},
      {"name": "shade", "type": 1, "offset": 4},
      {"name": "material", "type": 2, "offset": 8}
    ]},
    {"kind": "Entity_Id", "size": 8, "align": 8},
    {"kind": "Uint", "size": 1, "align": 1},
    {"kind": "Array", "size": 8, "align": 1, "elem": 5, "count": 8},
    {"kind": "Float", "size": 4, "align": 4},
    {"kind": "Bit_Set", "size": 1, "align": 1, "choices": [{"name": "Hot", "value": 0}, {"name": "Cold", "value": 1}, {"name": "Wet", "value": 2}]},
    {"kind": "Array", "size": 8, "align": 4, "elem": 7, "count": 2},
    {"kind": "Struct", "name": "Tool_Item", "size": 16, "align": 4, "fields": [
      {"name": "weight", "type": 7, "offset": 0, "min": 0, "max": 10, "unit": "kg"},
      {"name": "tags", "type": 8, "offset": 4},
      {"name": "offset", "type": 9, "offset": 8}
    ]},
    {"kind": "Uint", "size": 2, "align": 2}
  ],
  "tables": [
    {
      "name": "info",
      "flags": ["Single"],
      "rows": 1,
      "key": -1,
      "columns": [
        {"name": "", "type": 3, "type_name": "Tool_Info", "size": 24, "alignment": 8, "compression": "None", "flags": [], "ref": ""}
      ],
      "data": [
        {"count": 2, "shade": "Smooth", "material": "00000000000000050000000000000006"}
      ]
    },
    {
      "name": "items",
      "flags": [],
      "rows": 2,
      "key": 0,
      "columns": [
        {"name": "id", "type": 4, "size": 8, "alignment": 8, "compression": "None", "flags": [], "ref": ""},
        {"name": "name", "type": 6, "size": 8, "alignment": 1, "compression": "None", "flags": ["Text"], "ref": ""},
        {"name": "value", "type": 10, "type_name": "Tool_Item", "size": 16, "alignment": 4, "compression": "None", "flags": [], "ref": ""}
      ],
      "data": [
        {"id": "0x000000000000001f", "name": "axe", "value": {"weight": 1.5, "tags": ["Hot"], "offset": [0, 1]}},
        {"id": "0x0000000000000020", "name": "saw", "value": {"weight": 0.25, "tags": ["Cold", "Wet"], "offset": [2, 3]}}
      ]
    },
    {
      "name": "uses",
      "flags": [],
      "rows": 2,
      "key": -1,
      "columns": [
        {"name": "item", "type": 0, "size": 4, "alignment": 4, "compression": "None", "flags": [], "ref": "items"},
        {"name": "count", "type": 11, "size": 2, "alignment": 2, "compression": "None", "flags": [], "ref": ""}
      ],
      "data": [
        {"item": 1, "count": 7},
        {"item": 0, "count": 9}
      ]
    },
    {
      "name": "blob",
      "flags": ["Bulk"],
      "rows": 5,
      "key": -1,
      "columns": [
        {"name": "", "type": 5, "size": 1, "alignment": 16, "compression": "None", "flags": [], "ref": "", "file": "blob.bin"}
      ]
    }
  ]
}
`

// Gives a bulk file the bytes of the column it names in another document.
@(private)
test_bulk_loader :: proc(source:^Document) -> Bulk_Loader {
    return {proc(user:rawptr,name:string,allocator:mem.Allocator) -> ([]u8,bool) {
        doc:=(^Document)(user)
        for table in doc.tables {
            for column in table.columns {
                if .Bulk in table.flags && bulk_file_name(table.name,column.name)==name {
                    data:=make([]u8,len(column.data),allocator)
                    copy(data,column.data)
                    return data,true
                }
            }
        }
        return nil,false
    },source}
}

@(private="file") Test_Channel_Name :: distinct u16
@(private="file") Test_Channel_Mode :: enum u8 {Off,On}
@(private="file") Test_Channel :: struct {mode:Test_Channel_Mode,name:Test_Channel_Name}

@(private="file")
bytes_through_text :: proc(t:^testing.T,doc:^Document,loc:=#caller_location) {
    original,text,again:serial.Writer
    serial.writer_init(&original);defer serial.writer_destroy(&original)
    serial.writer_init(&text);defer serial.writer_destroy(&text)
    serial.writer_init(&again);defer serial.writer_destroy(&again)
    testing.expect_value(t,document_write(doc,&original),Error.None,loc)
    testing.expect_value(t,document_text_write(doc,&text,{schema=true,bulk=.Files}),Error.None,loc)
    back:Document
    problem,ok:=document_text_read(&back,string(serial.writer_bytes(&text)),test_bulk_loader(doc))
    if !testing.expectf(t,ok,"%v %v at %d",problem.code,problem.rule,problem.offset,loc=loc) {return}
    defer document_destroy(&back)
    testing.expect_value(t,document_write(&back,&again),Error.None,loc)
    testing.expect(t,mem.compare(serial.writer_bytes(&again),serial.writer_bytes(&original))==0,"the text gives the same file back",loc=loc)
    free_all(context.temp_allocator)
}

@(test)
document_text_is_stable_and_says_everything :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    doc:Document;tool_document(&doc,&types);defer document_destroy(&doc)
    w:serial.Writer;serial.writer_init(&w);defer serial.writer_destroy(&w)
    testing.expect_value(t,document_text_write(&doc,&w,{schema=true,bulk=.Files}),Error.None)
    text:=string(serial.writer_bytes(&w))
    if text!=GOLDEN {
        // The first line that differs says more than two whole texts.
        got,want:=strings.split_lines(text,context.temp_allocator),strings.split_lines(GOLDEN,context.temp_allocator)
        for line,at in got {
            if at>=len(want) || line!=want[at] {
                testing.expectf(t,false,"line %d: got\n%s\nexpected\n%s",at+1,line,at<len(want)?want[at]:"<nothing>")
                break
            }
        }
        testing.expect_value(t,len(got),len(want))
    }
    // Without the schema and the files: what `dump` prints.
    serial.writer_reset(&w)
    document_text_write(&doc,&w)
    brief:=string(serial.writer_bytes(&w))
    testing.expect(t,!strings.contains(brief,`"schema"`) && !strings.contains(brief,`"file"`) && strings.contains(brief,`"type_name": "Tool_Item"`))
    serial.writer_reset(&w)
    document_row_write(&doc,&w,1,1)
    testing.expect_value(t,string(serial.writer_bytes(&w)),`{"id": "0x0000000000000020", "name": "saw", "value": {"weight": 0.25, "tags": ["Cold", "Wet"], "offset": [2, 3]}}`)
    // For a diff: what a row or a type added before would change is left out.
    serial.writer_reset(&w)
    document_text_write(&doc,&w,{diff=true})
    diffed:=string(serial.writer_bytes(&w))
    testing.expect(t,strings.contains(diffed,`{"item": "0x0000000000000020", "count": 7}`) && !strings.contains(diffed,`"type": `),"rows refer to rows by key and columns do not tell the index of their type")
    free_all(context.temp_allocator)
}

@(test)
document_text_reads_back_the_same_bytes_for_every_kind :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    tool:Document;tool_document(&tool,&types);defer document_destroy(&tool)
    bytes_through_text(t,&tool)

    vertices,indices:=test_grid(3);defer delete(vertices);defer delete(indices)
    slots:=[1]Material_Slot{{id=1,material={5,5}}}
    text_set(slots[0].label[:],"a \"quoted\" label\n")
    skin:=make([]Skin_Vertex,len(vertices));defer delete(skin)
    for &influence in skin {influence.weights[0]=255}
    joints:=[1]Rig_Joint{{0,1}}
    mesh:Document
    testing.expect_value(t,mesh_document(&mesh,&types,{id={1,2},geometry=test_geometry(vertices,indices,skin),slots=slots[:],skeleton={7,7},joints=joints[:]}),Error.None)
    defer document_destroy(&mesh)
    bytes_through_text(t,&mesh)

    pixels:=make([]u8,64+16);defer delete(pixels)
    for &b,i in pixels {b=u8(i*7)}
    texture:Document
    testing.expect_value(t,texture_document(&texture,&types,{id={3,4},width=4,height=4,format=.RGBA8,flags={.Srgb},mips={pixels[:64],pixels[64:]}}),Error.None)
    defer document_destroy(&texture)
    bytes_through_text(t,&texture)

    info:=MATERIAL_DEFAULTS
    info.maps.normal.texture,info.maps.normal.rotation,info.emission={7,8},0.1,{1e-7,3.5e9,0.333333343}
    parameters:[1]Material_Parameter
    parameters[0]={kind=.Float,components=2,value={0.1,-2.5,0,0}}
    text_set(parameters[0].name[:],"speed")
    material:Document
    testing.expect_value(t,material_document(&material,&types,{id={9,9},info=info,parameters=parameters[:]}),Error.None)
    defer document_destroy(&material)
    bytes_through_text(t,&material)

    // A named integer keeps its names, and that it moves by them, through the text.
    types.schema.named=make(map[typeid]serial.Named,context.temp_allocator)
    types.schema.named[Test_Channel_Name]={choices={{"impacts",16}},by_name=true}
    scene:Scene;scene_init(&scene,&types,KIND_SCENE,{6,6});defer scene_destroy(&scene)
    for i in 1..=40 {
        id:=base.Entity_Id(i*3)
        scene_entity_add(&scene,id,i>1?base.Entity_Id(3):0,i%2==0?"even":"ödd ☃")
        value:=Test_Transform{{f32(i)*0.1,0,-1},1,{1,1,1}}
        scene_set(&scene,id,"Transform",&value)
        if i%3==0 {
            follow:=Test_Follow{target=base.Entity(3),anchor=id}
            scene_set(&scene,id,"Follow",&follow)
        }
        if i%5==0 {
            tag:Test_Tag
            scene_set(&scene,id,"Tag",&tag)
        }
        if i%7==0 {
            channel:=Test_Channel{mode=.On,name=Test_Channel_Name(i==7?16:i)}
            scene_set(&scene,id,"Channel",&channel)
        }
    }
    w:serial.Writer;serial.writer_init(&w);defer serial.writer_destroy(&w)
    scene_write(&scene,&w)
    bytes_through_text(t,&scene.doc)
}

@(test)
document_text_says_what_is_wrong_and_where :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    doc:Document;tool_document(&doc,&types);defer document_destroy(&doc)
    refuse :: proc(t:^testing.T,doc:^Document,from,to:string,code:serial.Text_Error_Code,rule:Text_Rule,loc:=#caller_location) {
        text,replaced:=strings.replace(GOLDEN,from,to,1,context.temp_allocator)
        testing.expect(t,replaced,"the text to change is there",loc=loc)
        back:Document
        problem,ok:=document_text_read(&back,text,test_bulk_loader(doc))
        testing.expect(t,!ok && back.tables==nil,"the text is refused",loc=loc)
        testing.expect_value(t,problem.code,code,loc)
        testing.expect_value(t,problem.rule,rule,loc)
        if at:=strings.index(text,to);to!="" && code!=.None {testing.expect(t,problem.offset>=at && problem.offset<=at+len(to),"the problem is where the change is",loc=loc)}
    }
    back:Document
    _,ok:=document_text_read(&back,GOLDEN,test_bulk_loader(&doc))
    testing.expect(t,ok)
    document_destroy(&back)
    refuse(t,&doc,`"mirai_asset": 1,`,``,.None,.Not_An_Asset)
    refuse(t,&doc,`"mirai_asset": 1,`,`"mirai_asset": 2,`,.None,.Version)
    refuse(t,&doc,`"kind": "TOOL"`,`"kind": "TOOLS"`,.None,.Kind)
    refuse(t,&doc,`"id": "00000000000000110000000000000022"`,`"id": "11"`,.None,.Id)
    refuse(t,&doc,`"flags": ["Cooked"]`,`"flags": ["Raw"]`,.None,.Unknown_Flag)
    refuse(t,&doc,`"schema": [`,`"tables": [], "schema": [`,.None,.Schema_First)
    refuse(t,&doc,`{"kind": "Float", "size": 4, "align": 4}`,`{"kind": "Double", "size": 4, "align": 4}`,.None,.Unknown_Type_Kind)
    refuse(t,&doc,`{"kind": "Float", "size": 4, "align": 4}`,`{"kind": "Float", "size": 3, "align": 4}`,.None,.Schema_Invalid)
    refuse(t,&doc,`"shade": "Smooth"`,`"shade": "Shiny"`,.Unknown_Member,.None)
    refuse(t,&doc,`"weight": 1.5`,`"wait": 1.5`,.Unknown_Field,.None)
    refuse(t,&doc,`"count": 7}`,`"count": 70000}`,.Out_Of_Range,.None)
    refuse(t,&doc,`{"item": 1, "count": 7}`,`{"thing": 1}`,.None,.Unknown_Column)
    refuse(t,&doc,`"rows": 2,`,`"rows": 3,`,.None,.Rows)
    refuse(t,&doc,`"name": "uses"`,`"name": "items"`,.None,.Table_Name)
    refuse(t,&doc,`"ref": "items"`,`"ref": "nothing"`,.None,.Unknown_Ref)
    refuse(t,&doc,`"type": 11,`,`"type": 99,`,.None,.Column)
    refuse(t,&doc,`"compression": "None", "flags": ["Text"]`,`"compression": "Zip", "flags": ["Text"]`,.None,.Unknown_Compression)
    refuse(t,&doc,`"file": "blob.bin"`,`"file": "other.bin"`,.None,.Bulk_File)
    refuse(t,&doc,`"rows": 5,`,`"rows": 4,`,.None,.Bulk_File)
    refuse(t,&doc,`, "file": "blob.bin"`,``,.None,.Bulk_File)
    refuse(t,&doc,`"key": 0,`,`"key": 7,`,.None,.Key)
    refuse(t,&doc,`"tables": [`,`"tables": {`,.Syntax,.None)
    refuse(t,&doc,"  ]\n}\n","  ]\n}\n trailing",.Syntax,.None)
    // Without a loader, a text that names files cannot be read.
    _,loaded:=document_text_read(&back,GOLDEN)
    testing.expect(t,!loaded)
    free_all(context.temp_allocator)
}

@(test)
document_paths_reach_tables_rows_columns_and_values :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    doc:Document;tool_document(&doc,&types);defer document_destroy(&doc)
    w:serial.Writer;serial.writer_init(&w);defer serial.writer_destroy(&w)
    read :: proc(t:^testing.T,doc:^Document,w:^serial.Writer,path:string,expected:string,loc:=#caller_location) {
        location,error:=document_locate(doc,path)
        if !testing.expect_value(t,error,Locate_Error.None,loc) {return}
        serial.writer_reset(w)
        serial.text_write(w,&doc.schema,location.type,location.bytes,.Line,0,location.is_text)
        testing.expect_value(t,string(serial.writer_bytes(w)),expected,loc)
    }
    read(t,&doc,&w,"info.count","2")
    read(t,&doc,&w,"info.shade",`"Smooth"`)
    read(t,&doc,&w,"info",`{"count": 2, "shade": "Smooth", "material": "00000000000000050000000000000006"}`)
    read(t,&doc,&w,"items[1].name",`"saw"`)
    read(t,&doc,&w,"items[1].name[0]","115")
    read(t,&doc,&w,"items[@0x1f].value.weight","1.5")
    read(t,&doc,&w,"items[@000000000000001F].value.offset[1]","1")
    read(t,&doc,&w,"items[0].value",`{"weight": 1.5, "tags": ["Hot"], "offset": [0, 1]}`)
    read(t,&doc,&w,"items[1].id",`"0x0000000000000020"`)
    read(t,&doc,&w,"uses[@0x1f].count","9")
    read(t,&doc,&w,"uses[0].item","1")
    read(t,&doc,&w,"blob[4]","5")
    bit,bit_error:=document_locate(&doc,"items[1].value.tags.Wet")
    testing.expect(t,bit_error==.None && bit.bit==2 && bit.bytes[0]==6)
    whole,_:=document_locate(&doc,"items")
    testing.expect(t,whole.table==1 && whole.row==-1 && whole.column==-1)
    row,_:=document_locate(&doc,"items[@0x20]")
    testing.expect(t,row.table==1 && row.row==1 && row.column==-1 && row.bytes==nil)

    refuse :: proc(t:^testing.T,doc:^Document,path:string,expected:Locate_Error,at:int,value:=serial.Path_Error.None,loc:=#caller_location) {
        location,error:=document_locate(doc,path)
        testing.expect_value(t,error,expected,loc)
        testing.expect_value(t,location.at,at,loc)
        testing.expect_value(t,location.value_error,value,loc)
    }
    refuse(t,&doc,"nothing",.Unknown_Table,0)
    refuse(t,&doc,"",.Unknown_Table,0)
    refuse(t,&doc,"items.name",.Missing_Row,5)
    refuse(t,&doc,"items[2]",.Row_Out_Of_Range,5)
    refuse(t,&doc,"items[x]",.Syntax,6)
    refuse(t,&doc,"items[",.Syntax,6)
    refuse(t,&doc,"items[]",.Syntax,6)
    refuse(t,&doc,"items[@0x99]",.Unknown_Key,7)
    refuse(t,&doc,"items[@zz]",.Invalid_Key,7)
    refuse(t,&doc,"blob[@1]",.Invalid_Key,4)
    refuse(t,&doc,"items[0].nope",.Unknown_Column,9)
    refuse(t,&doc,"items[0]value",.Syntax,8)
    refuse(t,&doc,"items[0].value.nope",.Value,15,.Unknown_Field)
    refuse(t,&doc,"items[0].value.offset[2]",.Value,21,.Out_Of_Range)
    refuse(t,&doc,"info.nope",.Value,5,.Unknown_Field)
    refuse(t,&doc,"info.count.x",.Value,11,.Not_A_Struct)
}

@(test)
document_diff_matches_rows_by_key_and_fields_by_name :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    a:Document;tool_document(&a,&types);defer document_destroy(&a)
    b:Document;tool_document(&b,&types);defer document_destroy(&b)
    w:serial.Writer;serial.writer_init(&w);defer serial.writer_destroy(&w)
    same,diff_error:=document_diff(&a,&b,&w)
    testing.expect(t,same==0 && diff_error==.None)
    testing.expect_value(t,w.count,0)

    // The same rows in another order are the same document.
    items,_:=document_table(&b,"items")
    for &column in b.tables[items].columns {
        size:=column.size
        swap:[32]u8
        copy(swap[:size],column.data[:size])
        copy(column.data[:size],column.data[size:])
        copy(column.data[size:],swap[:size])
    }
    uses,_:=document_table(&b,"uses")
    refs:=mem.slice_data_cast([]u32,b.tables[uses].columns[0].data)
    refs[0],refs[1]=0,1
    same,diff_error=document_diff(&a,&b,&w)
    testing.expect(t,same==0 && diff_error==.None)

    b.kind_version=3
    b.id={0x11,0x23}
    set :: proc(t:^testing.T,doc:^Document,path:string,value:serial.Value,loc:=#caller_location) {
        _,error:=document_set(doc,path,value)
        testing.expect_value(t,error,Locate_Error.None,loc)
    }
    set(t,&b,"info.count",u64(3))
    set(t,&b,"items[@0x1f].value.weight",f64(2))
    set(t,&b,"items[@0x1f].value.tags.Wet",true)
    set(t,&b,"items[@0x20].value.offset[1]",f64(-3))
    set(t,&b,"items[@0x20].name","bow")
    set(t,&b,"uses[@0x20].count",u64(8))
    document_resize(&b,items,3)
    set(t,&b,"items[2].id",base.Entity_Id(0x30))
    got_value,_,get_error:=document_get(&b,"items[@0x20].name")
    testing.expect(t,get_error==.None && got_value.(string)=="bow")
    got_value,_,get_error=document_get(&b,"uses[@0x20].count")
    testing.expect(t,get_error==.None && got_value.(u64)==8)
    _,_,get_error=document_get(&b,"items[0]")
    testing.expect_value(t,get_error,Locate_Error.Value)
    wrong,set_error:=document_set(&b,"items[@0x20].name","a name too long")
    testing.expect(t,set_error==.Value && wrong.value_error==.Too_Long)
    wrong,set_error=document_set(&b,"info.count",f64(1.5))
    testing.expect(t,set_error==.Value && wrong.value_error==.Out_Of_Range)
    blob,_:=document_table(&b,"blob")
    b.tables[blob].columns[0].data[2]=9
    document_table_remove(&a,uses)
    extra,_:=document_table_add(&a,"extra")
    _=extra
    serial.writer_reset(&w)
    count,_:=document_diff(&a,&b,&w)
    EXPECTED :: `~ kind_version: 2 -> 3
~ id: 00000000000000110000000000000022 -> 00000000000000110000000000000023
~ info.count: 2 -> 3
~ items[@0x000000000000001f].value.weight: 1.5 -> 2
~ items[@0x000000000000001f].value.tags: ["Hot"] -> ["Hot", "Wet"]
~ items[@0x0000000000000020].name: "saw" -> "bow"
~ items[@0x0000000000000020].value.offset[1]: 3 -> -3
+ items[@0x0000000000000030]
~ blob: 5 rows, 5 bytes, hash 53a5d6e6cb7c17ae -> 5 rows, 5 bytes, hash 2f42b8f0ea4a6e0c
- extra
+ uses
`
    got:=string(serial.writer_bytes(&w))
    // The hashes of the blob are whatever XXH3 gives: compare around them.
    testing.expect_value(t,count,11)
    got_lines,want_lines:=strings.split_lines(got,context.temp_allocator),strings.split_lines(EXPECTED,context.temp_allocator)
    testing.expect_value(t,len(got_lines),len(want_lines))
    for line,at in got_lines {
        if at>=len(want_lines) {break}
        if strings.has_prefix(line,"~ blob: 5 rows, 5 bytes, hash ") {
            testing.expect(t,len(line)==len(want_lines[at]) && strings.contains(line," -> 5 rows, 5 bytes, hash "))
            continue
        }
        testing.expect_value(t,line,want_lines[at])
    }
    free_all(context.temp_allocator)
}

@(test)
document_diff_follows_fields_that_moved_or_left :: proc(t:^testing.T) {
    Old :: struct {speed:f32,name:[8]u8 `mirai:"text"`,gone:u8,points:[3]u16}
    New :: struct {points:[2]u16,name:[16]u8 `mirai:"text"`,speed:f64,added:bool}
    types:Types;types_init(&types);defer types_destroy(&types)
    a:Document;document_init(&a,KIND_TOOL,{});defer document_destroy(&a)
    b:Document;document_init(&b,KIND_TOOL,{});defer document_destroy(&b)
    old:=Old{speed=1.5,name={0='c',1='a',2='r'},gone=4,points={1,2,3}}
    new:=New{points={1,5},name={0='c',1='a',2='r'},speed=1.5,added=true}
    document_put_row(&a,&types,"thing",&old)
    document_put_row(&b,&types,"thing",&new)
    w:serial.Writer;serial.writer_init(&w);defer serial.writer_destroy(&w)
    count,_:=document_diff(&a,&b,&w)
    EXPECTED :: `- thing.gone: 4
~ thing.points[1]: 2 -> 5
- thing.points[2]: 3
+ thing.added: true
`
    testing.expect_value(t,string(serial.writer_bytes(&w)),EXPECTED)
    testing.expect_value(t,count,4)
}
