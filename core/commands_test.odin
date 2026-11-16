package core

import "core:testing"

@(private)
Made :: struct {value:i32}

@(private)
@(test_world)
Made_World :: struct {
    using world:Test_World,
    transforms:Table(Transform),
    made:Table(Made),
}

// A function makes an entity with rows of tables it does not write, finishes
// them where they wait, and they appear when it ends.
@(test)
commands_make_an_entity_and_the_function_finishes_what_waits :: proc(t:^testing.T) {
    w:Made_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    c:=commands(&w,test_world_info(&w))
    e:=commands_create(c)
    commands_add(c,e,TRANSFORM_IDENTITY)
    commands_add(c,e,Made{1})
    testing.expect(t,!has(&w.made,e) && !has(&w.made,e))
    waiting:=commands_added(c,e,Made)
    testing.expect(t,waiting!=nil && waiting.value==1)
    waiting.value=2
    staged(&w.transforms,e).position={1,2,3}
    test_world_settle(&w)
    value,found:=get(&w.made,e)
    testing.expect(t,found && value.value==2)
    placed,_:=get(&w.transforms,e)
    testing.expect_value(t,placed.position,[3]f32{1,2,3})
    testing.expect(t,commands_added(c,e,Made)==nil)

    // A row that waits for a remove is not there to write; a row on is.
    commands_remove(c,e,Made)
    testing.expect(t,commands_added(c,e,Made)==nil && staged(&w.made,e)!=nil)
    add(&w.made,e,Made{3})
    remove(&w.made,e)
    testing.expect(t,commands_added(c,e,Made)==nil)
    test_world_settle(&w)
    testing.expect(t,!has(&w.made,e))
    testing.expect(t,commands_destroy(c,e) && !alive(&w.entities,e))
}

// What commands add at its default is what the table of the World starts its rows with.
@(test)
commands_add_a_row_at_the_default_of_its_table :: proc(t:^testing.T) {
    w:Made_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    test_world_info(&w).tables[1].default=proc(dst:rawptr) {(cast(^Made)dst)^={9}}
    c:=commands(&w,test_world_info(&w))
    testing.expect_value(t,default(c,Made).value,i32(9))
    e:=commands_create(c)
    commands_add_default(c,e,Made)
    test_world_settle(&w)
    value,_:=get(&w.made,e)
    testing.expect_value(t,value.value,i32(9))
}
