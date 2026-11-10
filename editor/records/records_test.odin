package records

import "core:testing"
import "mirai:core"

@(private="file")
Test_Item :: struct {damage:int,title:core.Text}

// A row keeps its id, its name and its value wherever it goes; a copy gets
// an id of its own and texts of its own; a name is of one row.
@(test)
rows_keep_their_ids_and_a_copy_has_its_own_texts :: proc(t:^testing.T) {
    declared:=[1]core.Record_Info{{name="Item",library="game",type=Test_Item,info=type_info_of(Test_Item),default=proc(dst:rawptr) {(^Test_Item)(dst).damage=7}}}
    info:=core.World_Info{records=declared[:]}
    ids:=u64(1)
    e:Edit
    create(&info,0,{1,2},"items.records",&e,context.temp_allocator)
    defer destroy(&e)
    item :: proc(e:^Edit,row:int) -> ^Test_Item {return (^Test_Item)(raw_data(row_bytes(e,row)))}

    sword,_:=row_add(&e,&ids,"sword",default=declared[0].default)
    bow,_:=row_add(&e,&ids,"bow")
    testing.expect(t,item(&e,sword).damage==7 && item(&e,bow).damage==0)
    _,taken:=row_add(&e,&ids,"sword")
    testing.expect(t,taken!="" && row_count(&e)==2,"a second row of a name is refused")
    testing.expect(t,row_rename(&e,bow,"sword")!="" && row_rename(&e,bow,"long bow")!="" && row_rename(&e,bow,"longbow")=="")

    offset:=int(offset_of(Test_Item,title))
    testing.expect_value(t,text_set(&e,&ids,sword,offset,"","Sword"),"")
    testing.expect_value(t,text_set(&e,&ids,sword,offset,"es","Espada"),"")
    item(&e,sword).damage=9
    copied,problem:=row_duplicate(&e,&ids,sword,"sabre")
    testing.expect(t,problem=="" && copied==sword+1 && row_find(&e,"longbow")==2,"a copy goes after its row")
    testing.expect(t,item(&e,copied).damage==9 && item(&e,copied).title.id!=item(&e,sword).title.id)
    text_put(&e,item(&e,copied).title.id,"es","Sable")
    spanish,_:=text_get(&e,item(&e,sword).title.id,"es")
    own,_:=text_get(&e,item(&e,copied).title.id,"")
    testing.expect(t,spanish=="Espada" && own=="Sword","the texts of a copy are its own")

    for id,row in e.ids {
        testing.expect(t,id!=0 && id<1<<ID_BITS)
        for other in e.ids[:row] {testing.expect(t,other!=id)}
    }
    id:=e.ids[sword]
    row_move(&e,sword,2)
    testing.expect(t,row_find(&e,"sword")==2 && e.ids[2]==id && item(&e,2).damage==9,"a row that moves keeps its id and its value")
    row_remove(&e,row_find(&e,"sabre"))
    testing.expect(t,row_count(&e)==2 && row_find(&e,"sabre")<0 && row_name(&e,row_find(&e,"sword"))=="sword")
}
