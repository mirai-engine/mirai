package host

import "core:fmt"
import "core:mem"
import "core:os"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:std/base"
import "mirai:std/serial"

@(private="file")
Weapon :: struct {damage:f32,title:core.Text,weight:f32}

// The struct as an older build wrote it: no weight, and damage after title.
@(private="file")
Weapon_Before :: struct {title:core.Text,damage:f32}

@(private="file")
WEAPON_DEFAULT :: Weapon{weight=2}

@(private="file")
records_save :: proc(t:^testing.T,path:string,id:base.Asset_Id,type:string,ids:[]u64,names:[]string,values:[]$T) -> bool {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    schema:serial.Schema
    serial.schema_init(&schema,context.temp_allocator)
    defer serial.schema_destroy(&schema)
    value_type,_:=serial.schema_add_type_info(&schema,type_info_of(T))
    named:=make([]asset.Records_Name,len(names),context.temp_allocator)
    for name,i in names {base.text_set(named[i][:],name)}
    info:asset.Records_Info
    base.text_set(info.type[:],type)
    bytes,error:=asset.records_bytes(&types,{id=id,info=info,ids=ids,names=named,schema=&schema,value_type=value_type,images=mem.slice_to_bytes(values)},context.temp_allocator)
    testing.expect_value(t,error,asset.Error.None) or_return
    return testing.expect(t,os.write_entire_file(path,bytes)==nil)
}

// Every table of a type is read into one set with the layout of the
// program, the tables of other types left out; a file that changes is read
// again, and one that goes takes its rows with it.
@(test)
the_rows_of_a_type_load_from_every_table_and_follow_their_files :: proc(t:^testing.T) {
    root:=base.test_folder(t,"host-records")
    if root=="" {return}
    swords,bows,ammo:=base.Asset_Id{0x51,1},base.Asset_Id{0x52,1},base.Asset_Id{0x53,1}
    if !records_save(t,fmt.tprintf("%s/swords.records",root),swords,"Weapon",{10,11},{"iron","steel"},[]Weapon{{damage=5,weight=3},{damage=8,weight=4}}) {return}
    if !records_save(t,fmt.tprintf("%s/bows.records",root),bows,"Weapon",{10},{"long"},[]Weapon_Before{{damage=6}}) {return}
    if !records_save(t,fmt.tprintf("%s/ammo.records",root),ammo,"Ammo",{1},{"arrow"},[]Weapon_Before{{}}) {return}

    info:core.World_Info
    records:=[]core.Record_Info{{name="Weapon",library="game",type=Weapon,info=type_info_of(Weapon),ref=typeid_of(core.Record(Weapon)),default=proc(dst:rawptr) {(cast(^Weapon)dst)^=WEAPON_DEFAULT}}}
    info.records=records
    info.schema=core.world_schema_make(&info)
    defer core.world_schema_destroy(info.schema)
    assets:Assets
    if !testing.expect(t,assets_init(&assets,{root=root,capacity=8})) {return}
    defer assets_destroy(&assets)
    assets_scan(&assets)
    app:=App{assets=&assets,allocator=context.allocator,info=&info}
    defer app_records_destroy(&app)

    rows:=core.Records(Weapon){app_record_set(&app,0)}
    testing.expect_value(t,core.records_count(rows),3)
    value,found:=core.record_get(rows,{swords,11})
    testing.expect(t,found && value==Weapon{damage=8,weight=4})
    // The other layout migrates by field names: weight takes the default.
    value,found=core.record_get(rows,{bows,10})
    testing.expect(t,found && value==Weapon{damage=6,weight=2})
    testing.expect_value(t,core.record_name(rows,{bows,10}),"long")
    _,found=core.record_get(rows,{ammo,1})
    testing.expect(t,!found,"A table of another type is not one of these")
    testing.expect(t,app_record_set(&app,1)==nil && app_record_set(&app,-1)==nil)

    // Asking again without changes keeps the set.
    generation:=rows.set.generation
    testing.expect(t,app_record_set(&app,0)==rows.set && rows.set.generation==generation)

    if !records_save(t,fmt.tprintf("%s/swords.records",root),swords,"Weapon",{10,11},{"iron","steel"},[]Weapon{{damage=50},{damage=80}}) {return}
    testing.expect(t,assets_refresh(&assets,{"swords.records"}))
    app_record_set(&app,0)
    testing.expect(t,rows.set.generation!=generation)
    value,found=core.record_get(rows,{swords,11})
    testing.expect(t,found && value.damage==80)

    testing.expect(t,os.remove(fmt.tprintf("%s/bows.records",root))==nil)
    assets_scan(&assets)
    app_record_set(&app,0)
    testing.expect_value(t,core.records_count(rows),2)
    _,found=core.record_get(rows,{bows,10})
    testing.expect(t,!found)
}
