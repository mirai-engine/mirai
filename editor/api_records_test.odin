package editor

import "core:strings"
import "core:testing"
import "mirai:asset"
import importer "mirai:cook/import"
import "mirai:core"
import "mirai:editor/api"
import "mirai:editor/records"
import "mirai:std/base"
import "mirai:std/serial"

@(private="file") Csv_Rarity :: enum u8 {Common,Rare,Epic}
@(private="file") Csv_Tag :: enum u8 {Fire,Ice}
@(private="file") Csv_Ammo :: struct {count:int}
@(private="file") Csv_Stats :: struct {speed,weight:f32}
@(private="file") Csv_Line :: struct {text:core.Text,pause:f32}
@(private="file")
Csv_Weapon :: struct {
    damage:i32,
    rarity:Csv_Rarity,
    stats:Csv_Stats,
    position:[2]f32,
    title:core.Text,
    lines:[2]Csv_Line,
    ammo:core.Record(Csv_Ammo),
    label:[16]u8 `mirai:"text"`,
    tags:bit_set[Csv_Tag;u8],
    sharp:bool,
}

// A table of Csv_Weapon with two tables of Csv_Ammo it can name: pouches
// (small, big) and crates (small).
@(private="file")
Csv_Fixture :: struct {
    schema:serial.Schema,
    refs:[1]Records_Api_Ref_Type,
    pouch_ids:[2]u64,
    pouch_names:[2]asset.Records_Name,
    crate_ids:[1]u64,
    crate_names:[1]asset.Records_Name,
    tables:[2]Records_Api_Rows,
    edit:records.Edit,
    c:Records_Api_Context,
    session:Session,
}

@(private="file")
POUCHES :: base.Asset_Id{1,2}
@(private="file")
CRATES :: base.Asset_Id{3,4}

@(private="file")
csv_fixture :: proc(f:^Csv_Fixture) {
    serial.schema_init(&f.schema,context.temp_allocator)
    type,_:=serial.schema_add(&f.schema,Csv_Weapon)
    f.refs[0]={type=f.schema.lookup[core.Record(Csv_Ammo)],record=0,name="game.Ammo"}
    f.pouch_ids={11,12}
    base.text_set(f.pouch_names[0][:],"small")
    base.text_set(f.pouch_names[1][:],"big")
    f.crate_ids={21}
    base.text_set(f.crate_names[0][:],"small")
    f.tables[0]={record=0,id=POUCHES,path="data/pouches.records",ids=f.pouch_ids[:],names=f.pouch_names[:]}
    f.tables[1]={record=0,id=CRATES,path="data/crates.records",ids=f.crate_ids[:],names=f.crate_names[:]}
    f.edit={id={9,9},info=type_info_of(Csv_Weapon),allocator=context.temp_allocator}
    f.edit.ids=make([dynamic]u64,context.temp_allocator)
    f.edit.names=make([dynamic]asset.Records_Name,context.temp_allocator)
    f.c={schema=&f.schema,type=type,name="game.Weapon",refs=f.refs[:],tables=f.tables[:],edit=&f.edit}
}

@(private="file")
csv_import :: proc(f:^Csv_Fixture,text:string) -> (updated,added:int,rejected:[]Records_Api_Rejected,message:string) {
    records,lines,failure:=importer.csv_records(text,context.temp_allocator)
    if failure!="" {return 0,0,nil,failure}
    leaves:=records_api_leaves(&f.c)
    columns:[]Records_Api_Column
    if columns,message=records_api_header(&f.c,leaves,records[0]);message!="" {return}
    default:=make([]u8,size_of(Csv_Weapon),context.temp_allocator)
    updated,added,rejected=records_api_import_rows(&f.session,&f.c,leaves,columns,records[1:],lines[1:],default)
    return
}

@(private="file")
csv_row :: proc(f:^Csv_Fixture,name:string) -> (value:Csv_Weapon,found:bool) {
    row:=records.row_find(&f.edit,name)
    if row<0 {return}
    return (cast(^Csv_Weapon)raw_data(records.row_bytes(&f.edit,row)))^,true
}

// Every value of a row is a column by its serial path: structs and arrays
// open, a core.Record and a text field are one column, a core.Text is the
// column of its key, and a bit set is a column per member.
@(test)
records_csv_columns_are_the_leaf_paths_of_the_row :: proc(t:^testing.T) {
    f:Csv_Fixture
    csv_fixture(&f)
    paths:=make([dynamic]string,context.temp_allocator)
    for leaf in records_api_leaves(&f.c) {append(&paths,leaf.path)}
    testing.expect_value(t,strings.join(paths[:],",",context.temp_allocator),"damage,rarity,stats.speed,stats.weight,position[0],position[1],title.key,lines[0].text.key,lines[0].pause,lines[1].text.key,lines[1].pause,ammo,label,tags.Fire,tags.Ice,sharp")
}

// A field in double quotes holds commas, line breaks and doubled quotes; an
// empty cell leaves its value as it is; a row by its name is updated, a new
// one is added at the end.
@(test)
records_csv_reads_quotes_line_breaks_and_empty_cells :: proc(t:^testing.T) {
    f:Csv_Fixture
    csv_fixture(&f)
    updated,added,rejected,message:=csv_import(&f,"\xef\xbb\xbfname,damage,label,title.key\r\nsword,7,\"a, b\",\"item.\"\"sharp\"\"\nsword\"\r\naxe,,,\n")
    testing.expect_value(t,message,"")
    testing.expect_value(t,updated,0)
    testing.expect_value(t,added,2)
    testing.expect_value(t,len(rejected),0)
    sword,found:=csv_row(&f,"sword")
    if !testing.expect(t,found) {return}
    testing.expect_value(t,sword.damage,7)
    testing.expect_value(t,serial.text_field(sword.label[:]),"a, b")
    testing.expect_value(t,serial.text_field(sword.title.key[:]),"item.\"sharp\"\nsword")
    axe,_:=csv_row(&f,"axe")
    testing.expect_value(t,axe.title,core.Text{})

    updated,added,rejected,message=csv_import(&f,"name,damage,label\nsword,,b\n")
    testing.expect_value(t,updated,1)
    testing.expect_value(t,added,0)
    sword,_=csv_row(&f,"sword")
    testing.expect_value(t,sword.damage,7)
    testing.expect_value(t,serial.text_field(sword.label[:]),"b")
}

// The first row has to name the row and fields of the type; a refusal names
// the column and lists those there are.
@(test)
records_csv_header_names_the_wrong_column :: proc(t:^testing.T) {
    f:Csv_Fixture
    csv_fixture(&f)
    leaves:=records_api_leaves(&f.c)
    header :: proc(f:^Csv_Fixture,leaves:[]Records_Api_Leaf,columns:..string) -> string {
        _,message:=records_api_header(&f.c,leaves,columns)
        return message
    }
    testing.expect_value(t,header(&f,leaves,"name","damage","title.key","lines[1].text.key","tags.Fire","position[1]","ammo"),"")
    unknown:=header(&f,leaves,"name","speed")
    testing.expectf(t,strings.contains(unknown,`column 2 "speed" is not a field of game.Weapon`) && strings.contains(unknown,"stats.speed") && strings.contains(unknown,"title.key"),"%s",unknown)
    missing:=header(&f,leaves,"damage")
    testing.expectf(t,strings.contains(missing,"none is name"),"%s",missing)
    twice:=header(&f,leaves,"name","damage","damage")
    testing.expectf(t,strings.contains(twice,"columns 2 and 3"),"%s",twice)
    _,_,_,refused:=csv_import(&f,"name,colour\nsword,red\n")
    testing.expect(t,refused!="" && len(f.edit.ids)==0,"A wrong header changes nothing")
}

// A cell reads by the type of its field; a cell that does not read rejects
// its row with its line and the column, and the other rows go in. A cell
// that starts with = is no formula.
@(test)
records_csv_cells_read_by_the_type_of_their_field :: proc(t:^testing.T) {
    f:Csv_Fixture
    csv_fixture(&f)
    text:=`name,damage,rarity,stats.speed,position[1],sharp,tags.Ice,ammo,label
sword,12,Rare,2.5,-1.25,TRUE,true,big,=1+2
bow,3x,,,,,,,
staff,=1+2,,,,,,,
wand,,Legendary,,,,,,
club,,,,,maybe,,,
mace,,,,,,,small,
spear,,,,,,,data/pouches/small,
pike,,,,,,,data/crates.records/small,
whip,,,,,,,nothing,
`
    updated,added,rejected,message:=csv_import(&f,text)
    testing.expect_value(t,message,"")
    testing.expect_value(t,updated,0)
    testing.expect_value(t,added,3)
    sword,_:=csv_row(&f,"sword")
    testing.expect_value(t,sword.damage,12)
    testing.expect_value(t,sword.rarity,Csv_Rarity.Rare)
    testing.expect_value(t,sword.stats.speed,2.5)
    testing.expect_value(t,sword.position[1],-1.25)
    testing.expect(t,sword.sharp && sword.tags=={.Ice})
    testing.expect_value(t,sword.ammo,core.Record(Csv_Ammo){POUCHES,12})
    testing.expect_value(t,serial.text_field(sword.label[:]),"=1+2")
    spear,_:=csv_row(&f,"spear")
    pike,_:=csv_row(&f,"pike")
    testing.expect_value(t,spear.ammo,core.Record(Csv_Ammo){POUCHES,11})
    testing.expect_value(t,pike.ammo,core.Record(Csv_Ammo){CRATES,21})
    reasons:=[?]struct{line:int,part:string}{{3,"column damage"},{4,"column damage"},{5,"Legendary"},{6,"column sharp"},{7,"2 tables"},{10,"no table of game.Ammo"}}
    testing.expect_value(t,len(rejected),len(reasons))
    for each,i in rejected[:min(len(rejected),len(reasons))] {
        testing.expectf(t,each.line==reasons[i].line && strings.contains(each.reason,reasons[i].part),"line %d: %s",each.line,each.reason)
        testing.expect(t,records.row_find(&f.edit,each.name)<0,"A rejected row is not added")
    }
}

// What records.export writes, records.import reads back: the same values.
@(test)
records_csv_export_reads_back :: proc(t:^testing.T) {
    f:Csv_Fixture
    csv_fixture(&f)
    _,_,_,message:=csv_import(&f,"name,damage,rarity,stats.weight,lines[1].pause,ammo,label,tags.Fire,title.key,lines[0].text.key\nsword,7,Epic,0.1,3,data/crates/small,\"x,y\",true,item.sword,lines.hi\naxe,1,,,,,,,,\n")
    testing.expect_value(t,message,"")
    leaves:=records_api_leaves(&f.c)
    text,columns:=records_api_csv(&f.c,leaves)
    testing.expect_value(t,columns,len(leaves)+1)
    testing.expectf(t,strings.has_prefix(text,"name,damage,rarity,stats.speed,stats.weight,position[0],position[1],title.key,lines[0].text.key,"),"%s",text)
    testing.expectf(t,strings.contains(text,"sword,7,Epic,0,0.1,0,0,item.sword,lines.hi,0,,3,data/crates/small,\"x,y\",true,false,false"),"%s",text)
    sword,_:=csv_row(&f,"sword")

    g:Csv_Fixture
    csv_fixture(&g)
    updated,added,rejected,again:=csv_import(&g,text)
    testing.expect_value(t,again,"")
    testing.expect(t,updated==0 && added==2 && len(rejected)==0)
    copied,_:=csv_row(&g,"sword")
    testing.expect_value(t,copied.damage,sword.damage)
    testing.expect_value(t,copied.rarity,sword.rarity)
    testing.expect_value(t,copied.stats,sword.stats)
    testing.expect_value(t,copied.lines[1].pause,sword.lines[1].pause)
    testing.expect_value(t,copied.ammo,sword.ammo)
    testing.expect_value(t,copied.label,sword.label)
    testing.expect_value(t,copied.tags,sword.tags)
    testing.expect_value(t,copied.title,sword.title)
    testing.expect_value(t,serial.text_field(copied.lines[0].text.key[:]),"lines.hi")
    testing.expect_value(t,records.row_name(&g.edit,1),"axe")
}

// A core.Record is named by a row: its name alone when one table of the type
// has it, else its table and name; the serial form reads too.
@(test)
records_ref_names_a_row_by_name_or_table_and_name :: proc(t:^testing.T) {
    f:Csv_Fixture
    csv_fixture(&f)
    big,message:=records_api_ref_parse(&f.c,0,"big")
    testing.expect(t,message=="" && big==Records_Api_Ref{POUCHES,12})
    crate,_:=records_api_ref_parse(&f.c,0,"data/crates/small")
    testing.expect_value(t,crate,Records_Api_Ref{CRATES,21})
    _,ambiguous:=records_api_ref_parse(&f.c,0,"small")
    testing.expectf(t,strings.contains(ambiguous,"2 tables") && strings.contains(ambiguous,"data/pouches/small"),"%s",ambiguous)
    _,missing:=records_api_ref_parse(&f.c,0,"data/crates/big")
    testing.expectf(t,strings.contains(missing,"has no row big") && strings.contains(missing,"records.inspect"),"%s",missing)
    _,table:=records_api_ref_parse(&f.c,0,"boxes/big")
    testing.expectf(t,strings.contains(table,"data/pouches, data/crates"),"%s",table)
    testing.expect_value(t,records_api_ref_text(&f.c,0,big),"big")
    testing.expect_value(t,records_api_ref_text(&f.c,0,crate),"data/crates/small")
    testing.expect_value(t,records_api_ref_text(&f.c,0,{}),"")
    lost:=records_api_ref_text(&f.c,0,{POUCHES,99})
    back,unread:=records_api_ref_parse(&f.c,0,lost)
    testing.expectf(t,unread=="" && back==Records_Api_Ref{POUCHES,99},"A row no table has keeps its serial form: %s %v %s",lost,back,unread)
}

// The values of records.set and records.add take a core.Record by the name of
// its row and a core.Text by its key. A field given as an object or a
// list is given whole (what it leaves out goes back to the default); a path
// changes only its part; the fields not named keep theirs.
@(test)
records_values_take_row_names_and_text_keys :: proc(t:^testing.T) {
    f:Csv_Fixture
    csv_fixture(&f)
    row:=Csv_Weapon{damage=1,stats={speed=4,weight=5}}
    default:=Csv_Weapon{stats={weight=9}}
    f.c.default=([^]u8)(&default)[:size_of(default)]
    row.lines[1].pause=3
    message:=records_api_values_put(&f.c,([^]u8)(&row)[:size_of(row)],`{"damage": 7, "ammo": "data/crates/small", "title": {"key": "item.sword"}, "stats": {"speed": 2}, "lines": [{"pause": 1.5}, {"text": {"key": "lines.bye"}}]}`)
    testing.expect_value(t,message,"")
    testing.expect_value(t,row.damage,7)
    testing.expect_value(t,row.stats,Csv_Stats{2,9})
    testing.expect_value(t,row.lines[1].pause,0)
    testing.expect_value(t,row.lines[0].pause,1.5)
    testing.expect_value(t,row.ammo,core.Record(Csv_Ammo){CRATES,21})
    testing.expect(t,serial.text_field(row.title.key[:])=="item.sword" && serial.text_field(row.lines[1].text.key[:])=="lines.bye")
    unknown:=records_api_values_put(&f.c,([^]u8)(&row)[:size_of(row)],`{"dmg": 3}`)
    testing.expectf(t,strings.contains(unknown,"dmg") && strings.contains(unknown,"damage"),"%s",unknown)
    named:=records_api_values_put(&f.c,([^]u8)(&row)[:size_of(row)],`{"ammo": "small"}`)
    testing.expectf(t,strings.has_prefix(named,"values.ammo: small is a row of 2 tables"),"%s",named)
    testing.expect_value(t,row.damage,7)
    // A path changes only its part.
    testing.expect_value(t,records_api_values_put(&f.c,([^]u8)(&row)[:size_of(row)],`{"stats.weight": 4, "lines[1].pause": 2}`),"")
    testing.expect_value(t,row.stats,Csv_Stats{2,4})
    testing.expect_value(t,row.lines[1].pause,2)
    testing.expect_value(t,row.lines[0].pause,1.5)
    nested:=records_api_values_put(&f.c,([^]u8)(&row)[:size_of(row)],`{"stats.wait": 1}`)
    testing.expectf(t,strings.contains(nested,"stats.wait") && strings.contains(nested,"speed, weight"),"%s",nested)
}

// records.move puts a row right after another: the place it ends at is that
// row's, counted once it left its own place.
@(test)
records_move_places_a_row_right_after_another :: proc(t:^testing.T) {
    cases:=[?]struct{row,after,to:int}{{3,1,2},{1,3,3},{0,1,1},{2,0,1}}
    for c in cases {
        testing.expectf(t,records_move_place(c.row,c.after)==c.to,"%v",c)
    }
}

// A row as inspect gives it holds the key of its texts in its values.
@(test)
records_api_rows_give_their_values :: proc(t:^testing.T) {
    f:Csv_Fixture
    csv_fixture(&f)
    _,_,_,message:=csv_import(&f,"name,damage,title.key\nsword,7,item.sword\naxe,1,\n")
    testing.expect_value(t,message,"")
    sword:=records_api_row(&f.c,0)
    testing.expectf(t,sword.name=="sword" && strings.contains(string(sword.values),`"title": {"key": "item.sword"}`),"%v",sword)
}
