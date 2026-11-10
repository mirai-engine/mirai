package asset

import "core:mem"
import "core:testing"
import "mirai:std/base"
import "mirai:std/serial"

@(private="file")
Weapon_V1 :: struct {damage:f32,rarity:u8,prefab:base.Asset_Id}

// The same struct after the code changed: a field gone, one added, the rest moved.
@(private="file")
Weapon_V2 :: struct {weight:f32,prefab:base.Asset_Id,damage:f32}

@(private="file")
records_name :: proc(text:string) -> (name:Records_Name) {
    base.text_set(name[:],text)
    return
}

// A table keeps its rows, names and ids, depends on the assets its
// rows name, and reads into the struct of the code by field names when the
// struct changed: a field the file lacks takes the default.
@(test)
records_keep_their_rows_and_migrate_by_field_names :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    schema:serial.Schema
    serial.schema_init(&schema,context.temp_allocator)
    defer serial.schema_destroy(&schema)
    v1,_:=serial.schema_add_type_info(&schema,type_info_of(Weapon_V1))
    values:=[]Weapon_V1{{damage=10,rarity=2,prefab={5,6}},{damage=25,rarity=1}}
    desc:=Records_Desc{
        id={7,8},type="game.Weapon",
        ids={11,12},names={records_name("iron_sword"),records_name("bow")},
        schema=&schema,value_type=v1,images=mem.slice_to_bytes(values),
    }
    bytes,error:=records_bytes(&types,desc,context.temp_allocator)
    if !testing.expect_value(t,error,Error.None) {return}
    a:Asset
    if !testing.expect_value(t,asset_open(&a,bytes),Error.None) {return}
    defer asset_close(&a)
    view,viewed:=records_view(&a,&types)
    if !testing.expect_value(t,viewed,Error.None) {return}
    testing.expect_value(t,records_type(view),"game.Weapon")
    testing.expect(t,len(view.ids)==2 && view.ids[1]==12)
    testing.expect_value(t,serial.text_field(view.names[0][:]),"iron_sword")
    testing.expect(t,len(a.dependencies)==1 && a.dependencies[0]==base.Asset_Id{5,6})
    // The rows table merges by id.
    rows,_:=asset_table(&a,TABLE_ROWS)
    testing.expect_value(t,rows.key,0)

    v2,_:=serial.schema_add_type_info(&schema,type_info_of(Weapon_V2))
    read:=make([]Weapon_V2,2,context.temp_allocator)
    default:=Weapon_V2{weight=1.5}
    testing.expect_value(t,records_values(&a,view,&schema,v2,mem.slice_to_bytes(read),mem.ptr_to_bytes(&default)),Error.None)
    testing.expect(t,read[0]==Weapon_V2{weight=1.5,prefab={5,6},damage=10})
    testing.expect(t,read[1]==Weapon_V2{weight=1.5,damage=25})
}

// Ids are not 0 and once each and names are words once each: a table that
// breaks one is not written, and records_problem says which row and how to
// fix it.
@(test)
records_refuse_repeated_or_empty_ids_and_names :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    schema:serial.Schema
    serial.schema_init(&schema,context.temp_allocator)
    defer serial.schema_destroy(&schema)
    v1,_:=serial.schema_add_type_info(&schema,type_info_of(Weapon_V1))
    values:=[]Weapon_V1{{},{}}
    cases:=[]struct {ids:[]u64,names:[]Records_Name,row:int}{
        {{1,1},{records_name("a"),records_name("b")},1},
        {{0,2},{records_name("a"),records_name("b")},0},
        {{1,2},{records_name("a"),records_name("a")},1},
        {{1,2},{records_name("a"),records_name("has space")},1},
        {{1,2},{records_name("a"),records_name("")},1},
    }
    info:Records_Info
    base.text_set(info.type[:],"game.Weapon")
    for c in cases {
        row,message:=records_problem({info=&info,ids=c.ids,names=c.names})
        testing.expect(t,row==c.row && message!="")
        _,error:=records_bytes(&types,{id={1,1},type="game.Weapon",ids=c.ids,names=c.names,schema=&schema,value_type=v1,images=mem.slice_to_bytes(values)},context.temp_allocator)
        testing.expect_value(t,error,Error.Invalid)
    }
    _,message:=records_problem({info=&info})
    testing.expect_value(t,message,"")
}
