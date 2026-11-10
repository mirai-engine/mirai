package core

import "core:testing"
import "mirai:std/base"

@(private="file")
Weapon :: struct {damage:f32,title:Text}

@(private="file")
weapons_set :: proc(set:^Record_Set,rows:[]Record_Row,values:[]Weapon,index:[]u32) {
    set^={size=size_of(Weapon),rows=rows,index=index,values=([^]u8)(raw_data(values))[:len(values)*size_of(Weapon)]}
}

// A reference finds its row by table and id whatever the order of the rows;
// the zero reference and an unknown row find nothing, and only the unknown
// row is a problem of the entity that names it.
@(test)
records_are_found_by_table_and_row_and_a_missing_one_is_a_problem :: proc(t:^testing.T) {
    swords,bows:=base.Asset_Id{1,2},base.Asset_Id{3,4}
    rows:=[]Record_Row{{table=swords,row=900},{table=swords,row=7},{table=bows,row=7}}
    base.text_set(rows[0].name[:],"iron")
    values:=[]Weapon{{damage=10},{damage=20},{damage=30}}
    // By table, then by row.
    index:=[]u32{1,0,2}
    tables:=[]Record_Table{{id=swords}}
    base.text_set(tables[0].name[:],"data/swords.records")
    set:Record_Set
    weapons_set(&set,rows,values,index)
    set.tables=tables
    weapons:=Records(Weapon){&set}
    for row,i in rows {
        value,found:=record_get(weapons,Record(Weapon){row.table,row.row})
        testing.expect(t,found && value.damage==values[i].damage)
    }
    testing.expect_value(t,record_name(weapons,{swords,900}),"iron")
    _,found:=record_get(weapons,{})
    testing.expect(t,!found)
    problems:Problems
    entity:=Entity(3)
    _,found=record(weapons,{},&problems,entity)
    testing.expect(t,!found && problems.count==0)
    _,found=record(weapons,{swords,8},&problems,entity)
    testing.expect(t,!found && problems.count==1)
    if problem:=problem_find(&problems,entity,"records.missing");testing.expect(t,problem!=nil) {
        testing.expect(t,base.text_get(problem.text[:])!="")
    }
    _,found=record(weapons,{base.Asset_Id{9,9},1},&problems,entity)
    testing.expect(t,!found && problems.entries[0].count==2)
    // A set of rows of another size has none for T.
    testing.expect_value(t,records_count(Records(Text){&set}),0)
    testing.expect_value(t,records_count(weapons),3)
    value,ref:=records_at(weapons,1)
    testing.expect(t,value.damage==20 && ref==Record(Weapon){swords,7})
    // The generation of a set, and 0 before there is one.
    set.generation=3
    testing.expect_value(t,records_generation(weapons),3)
    testing.expect_value(t,records_generation(Records(Weapon){}),0)
}

// The text of a row is read by its key, as the code reads one by name; no
// text and no texts find nothing.
@(test)
a_text_of_a_row_is_read_by_its_key :: proc(t:^testing.T) {
    slots:[4]base.Text_Slot
    key:=base.name_hash("item.sword")
    slots[base.text_slot(0,key)&3]={language=0,key=key,offset=0,length=5}
    texts:=Texts{slots=slots[:],text=transmute([]u8)string("Sword")}
    title:Text
    base.text_set(title.key[:],"item.sword")
    value,found:=text(&texts,title,base.name_hash("es"))
    testing.expect(t,found && value=="Sword")
    value,found=text(&texts,"item.sword",0)
    testing.expect(t,found && value=="Sword")
    _,found=text(&texts,Text{},0)
    testing.expect(t,!found)
    _,found=text(nil,title,0)
    testing.expect(t,!found)
}
