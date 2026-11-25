package records

import "core:mem"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:std/base"
import "mirai:std/serial"

@(private="file")
column :: proc(name:string,kind:asset.Records_Kind) -> (c:asset.Records_Column) {
    base.text_set(c.name[:],name)
    c.kind=kind
    if kind==.String {c.length=16}
    return
}

@(private="file")
cell :: proc(e:^Edit,row:int,name:string) -> []u8 {
    field,_:=column_field(e,column_find(e,name))
    value:=e.defaults if row<0 else row_bytes(e,row)
    return value[field.offset:][:e.schema.types[field.type].size]
}

@(private="file")
number :: proc(e:^Edit,row:int,name:string) -> i32 {return (^i32)(raw_data(cell(e,row,name)))^}

// A row keeps its id, its name and its value wherever it goes; a copy gets
// an id of its own and shows the same key; a name is of one row; a new row
// starts at the defaults of the columns.
@(test)
rows_keep_their_ids_and_a_copy_shows_the_same_text :: proc(t:^testing.T) {
    e:Edit
    if !testing.expect_value(t,create({1,2},"items.records","","Item",&e,context.temp_allocator),"") {return}
    defer destroy(&e)
    testing.expect_value(t,column_add(&e,nil,column("damage",.Int)),"")
    testing.expect_value(t,column_add(&e,nil,column("title",.Text)),"")
    (^i32)(raw_data(cell(&e,-1,"damage")))^=7
    ids:=u64(1)
    sword,_:=row_add(&e,&ids,"sword")
    bow,_:=row_add(&e,&ids,"bow")
    testing.expect(t,number(&e,sword,"damage")==7 && number(&e,bow,"damage")==7)
    _,taken:=row_add(&e,&ids,"sword")
    testing.expect(t,taken!="" && row_count(&e)==2,"a second row of a name is refused")
    testing.expect(t,row_rename(&e,bow,"sword")!="" && row_rename(&e,bow,"long bow")!="" && row_rename(&e,bow,"longbow")=="")

    base.text_set(cell(&e,sword,"title"),"item.sword")
    (^i32)(raw_data(cell(&e,sword,"damage")))^=9
    copied,problem:=row_duplicate(&e,&ids,sword,"sabre")
    testing.expect(t,problem=="" && copied==sword+1 && row_find(&e,"longbow")==2,"a copy goes after its row")
    testing.expect(t,number(&e,copied,"damage")==9 && serial.text_field(cell(&e,copied,"title"))=="item.sword")

    for id,row in e.ids {
        testing.expect(t,id!=0 && id<1<<ID_BITS)
        for other in e.ids[:row] {testing.expect(t,other!=id)}
    }
    id:=e.ids[sword]
    row_move(&e,sword,2)
    testing.expect(t,row_find(&e,"sword")==2 && e.ids[2]==id && number(&e,2,"damage")==9,"a row that moves keeps its id and its value")
    row_remove(&e,row_find(&e,"sabre"))
    testing.expect(t,row_count(&e)==2 && row_find(&e,"sabre")<0 && row_name(&e,row_find(&e,"sword"))=="sword")
}

// A renamed column keeps the values of its rows and the name it had; a new
// column starts at its default in the rows there were; another kind converts
// what it can; the file keeps the columns, the defaults and the rows, and a
// layout of the columns is the one Odin gives the struct of the build.
@(test)
columns_change_and_the_rows_keep_their_values :: proc(t:^testing.T) {
    e:Edit
    if !testing.expect_value(t,create({1,2},"waves.records","","Wave",&e,context.temp_allocator),"") {return}
    defer destroy(&e)
    testing.expect_value(t,column_add(&e,nil,column("count",.Int)),"")
    ids:=u64(1)
    first,_:=row_add(&e,&ids,"first")
    (^i32)(raw_data(cell(&e,first,"count")))^=12

    renamed:=e.columns[0]
    base.text_set(renamed.name[:],"zombies")
    testing.expect_value(t,column_change(&e,nil,0,renamed),"")
    testing.expect_value(t,number(&e,first,"zombies"),12)
    testing.expect_value(t,serial.text_field(e.columns[0].was[:]),"count")
    testing.expect(t,column_add(&e,nil,column("count",.Int))!="","a name a column had is not another's")

    delay:=column("delay",.Float)
    testing.expect_value(t,column_add(&e,nil,delay,0),"")
    testing.expect_value(t,(^f32)(raw_data(cell(&e,first,"delay")))^,0)
    flag:=column("boss",.Bool)
    testing.expect_value(t,column_add(&e,nil,flag),"")
    testing.expect(t,column_find(&e,"delay")==0 && column_find(&e,"boss")==2)
    testing.expect_value(t,number(&e,first,"zombies"),12)

    as_float:=e.columns[1]
    kind_set(&e,&as_float,.Float)
    testing.expect_value(t,column_change(&e,nil,1,as_float),"")
    testing.expect_value(t,(^f32)(raw_data(cell(&e,first,"zombies")))^,12)

    Odin_Wave :: struct {delay:f32,zombies:f32,boss:bool}
    testing.expect_value(t,row_size(&e),size_of(Odin_Wave))
    testing.expect_value(t,column_remove(&e,nil,0),"")
    testing.expect(t,len(e.columns)==2 && column_find(&e,"delay")<0)

    bad:=column("label",.Enum)
    testing.expect(t,column_add(&e,nil,bad)!="","an enum without values is refused")
    kind_set(&e,&bad,.Enum)
    testing.expect_value(t,column_add(&e,nil,bad),"")

    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    bytes,message:=file_bytes(&e,&types)
    if !testing.expect_value(t,message,"") {return}
    a:asset.Asset
    if !testing.expect_value(t,asset.asset_open(&a,bytes),asset.Error.None) {return}
    defer asset.asset_close(&a)
    view,error:=asset.records_view(&a,&types)
    if !testing.expect_value(t,error,asset.Error.None) {return}
    testing.expect(t,asset.records_type(view)=="Wave" && view.info.declares && len(view.columns)==3)
    read:=make([]u8,row_size(&e),context.temp_allocator)
    testing.expect_value(t,asset.records_values(&a,view,&e.schema,e.type,read),asset.Error.None)
    testing.expect(t,mem.compare(read,row_bytes(&e,0))==0)
    testing.expect_value(t,asset.records_defaults(&a,view,&e.schema,e.type,read),asset.Error.None)
}

// A table's type takes its name from its file; a column of kind Type takes
// the type the build declares in its package.
@(test)
names_and_types_of_the_code :: proc(t:^testing.T) {
    testing.expect_value(t,type_of_file("data/horde_waves.records"),"Horde_Waves")
    testing.expect_value(t,type_of_file("items.records"),"Items")
    testing.expect_value(t,type_of_file("2d.records"),"T_2d")
    Stats :: struct {speed:f32,armor:i32}
    codes:=[1]core.Record_Code{{name="Stats",folder="",info=type_info_of(Stats)}}
    info:=core.World_Info{record_codes=codes[:]}
    e:Edit
    if !testing.expect_value(t,create({1,2},"units.records","","Unit",&e,context.temp_allocator),"") {return}
    defer destroy(&e)
    stats:=column("stats",.Type)
    base.text_set(stats.type[:],"Stats")
    stats.count=2
    testing.expect_value(t,column_add(&e,&info,stats),"")
    testing.expect_value(t,row_size(&e),2*size_of(Stats))
    testing.expect(t,column_add(&e,nil,column("other",.Type))!="","a type the code does not declare is refused")
}
