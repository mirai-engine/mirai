package core

import "core:testing"

@(private="file")
Made :: struct {value:i32}

@(private="file")
Made_World :: struct {
    es:Entities,
    transforms:Table(Transform),
    made:Table(Made),
    tables:[2]Table_Info,
    info:World_Info,
}

@(private="file")
made_init :: proc(w:^Made_World) {
    entities_init(&w.es)
    table_init(&w.transforms,"Transform");table_init(&w.made,"Made")
    w.tables={
        {name="Transform",type=Transform,info=type_info_of(Transform),offset=offset_of(Made_World,transforms)},
        {name="Made",type=Made,info=type_info_of(Made),offset=offset_of(Made_World,made)},
    }
    w.info={entities=offset_of(Made_World,es),tables=w.tables[:]}
}

@(private="file")
made_settle :: proc(w:^Made_World) {
    table_settle(&w.transforms,&w.es);table_settle(&w.made,&w.es)
    entities_settle(&w.es)
}

@(private="file")
made_destroy :: proc(w:^Made_World) {
    table_destroy(&w.transforms);table_destroy(&w.made)
    entities_destroy(&w.es)
}

// A function makes an entity with rows of tables it does not write, finishes
// them where they wait, and they appear when it ends.
@(test)
commands_make_an_entity_and_the_function_finishes_what_waits :: proc(t:^testing.T) {
    w:Made_World
    made_init(&w)
    defer made_destroy(&w)
    c:=commands(&w,&w.info)
    e:=commands_create(c)
    commands_add(c,e,TRANSFORM_IDENTITY)
    commands_add(c,e,Made{1})
    testing.expect(t,!has(&w.made,e) && get(&w.made,e)==nil)
    waiting:=commands_added(c,e,Made)
    testing.expect(t,waiting!=nil && waiting.value==1)
    waiting.value=2
    staged(&w.transforms,e).position={1,2,3}
    made_settle(&w)
    value,found:=get(read(&w.made),e)
    testing.expect(t,found && value.value==2)
    placed,_:=get(read(&w.transforms),e)
    testing.expect_value(t,placed.position,[3]f32{1,2,3})
    testing.expect(t,commands_added(c,e,Made)==nil)

    // A row that waits for a remove is not there to write; a row on is.
    commands_remove(c,e,Made)
    testing.expect(t,commands_added(c,e,Made)==nil && staged(&w.made,e)!=nil)
    add(&w.made,e,Made{3})
    remove(&w.made,e)
    testing.expect(t,added(&w.made,e)==nil)
    made_settle(&w)
    testing.expect(t,!has(&w.made,e))
    testing.expect(t,commands_destroy(c,e) && !alive(&w.es,e))
}

// What commands add at its default is what the table of the World starts its rows with.
@(test)
commands_add_a_row_at_the_default_of_its_table :: proc(t:^testing.T) {
    w:Made_World
    made_init(&w)
    defer made_destroy(&w)
    w.tables[1].default=proc(dst:rawptr) {(cast(^Made)dst)^={9}}
    c:=commands(&w,&w.info)
    testing.expect_value(t,default(c,Made).value,i32(9))
    e:=commands_create(c)
    commands_add_default(c,e,Made)
    made_settle(&w)
    value,_:=get(read(&w.made),e)
    testing.expect_value(t,value.value,i32(9))
}
