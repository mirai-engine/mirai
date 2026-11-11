package core

import "core:testing"
import "mirai:std/base"

@(private="file")
Id_World :: struct {
    using world:Test_World,
    ids:Table(Id),
    names:Table(Name),
}

@(private="file")
id_world_add :: proc(w:^Id_World,id:base.Entity_Id) -> Entity {
    e:=create(&w.entities)
    add(&w.ids,e,Id{id})
    return e
}

@(test)
an_entity_is_found_by_its_id_from_the_settle_that_adds_it :: proc(t:^testing.T) {
    w:Id_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    a,b:=id_world_add(&w,7),id_world_add(&w,9)
    plain:=create(&w.entities)
    add(&w.names,plain,name_make("No id"))
    testing.expect_value(t,entity_of(&w.entities,7),NONE)
    test_world_settle(&w)
    testing.expect_value(t,entity_of(&w.entities,7),a)
    testing.expect_value(t,entity_of(&w.entities,9),b)
    testing.expect_value(t,entity_of(&w.entities,0),NONE)
    testing.expect_value(t,entity_of(&w.entities,8),NONE)
    testing.expect_value(t,id_of(&w.ids,a),base.Entity_Id(7))
    testing.expect_value(t,id_of(&w.ids,plain),base.Entity_Id(0))
    testing.expect_value(t,id_of((^Table(Id))(nil),a),base.Entity_Id(0))
    version:=w.ids.version
    _=id_of(&w.ids,b)
    testing.expect_value(t,w.ids.version,version)
    testing.expect(t,ids_synced(&w.entities,&w.ids))
    // A settle with nothing new leaves it as it was.
    seen:=w.entities.ids.seen
    test_world_settle(&w)
    testing.expect_value(t,w.entities.ids.seen,seen)
}

@(test)
the_index_follows_writes_removals_destruction_and_undo :: proc(t:^testing.T) {
    w:Id_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    a,b,c:=id_world_add(&w,7),id_world_add(&w,9),id_world_add(&w,13)
    test_world_settle(&w)

    edit(&w.ids,a).value=11
    test_world_settle(&w)
    testing.expect_value(t,entity_of(&w.entities,7),NONE)
    testing.expect_value(t,entity_of(&w.entities,11),a)

    add(&w.ids,b,Id{15})
    remove(&w.ids,c)
    test_world_settle(&w)
    testing.expect_value(t,entity_of(&w.entities,9),NONE)
    testing.expect_value(t,entity_of(&w.entities,15),b)
    testing.expect_value(t,entity_of(&w.entities,13),NONE)

    destroy(&w.entities,a)
    testing.expect_value(t,entity_of(&w.entities,11),NONE)
    test_world_settle(&w)
    testing.expect_value(t,w.entities.ids.count,1)

    // The index of a destroyed entity comes back for another one.
    d:=id_world_add(&w,11)
    testing.expect_value(t,entity_index(d),entity_index(a))
    test_world_settle(&w)
    testing.expect_value(t,entity_of(&w.entities,11),d)

    // An undo takes a row between functions.
    testing.expect(t,raw_drop(raw(&w.ids),type_info_of(Id),d))
    test_world_settle(&w)
    testing.expect_value(t,entity_of(&w.entities,11),NONE)
    testing.expect_value(t,entity_of(&w.entities,15),b)
}

@(test)
an_id_two_entities_share_goes_to_the_other_when_its_holder_leaves :: proc(t:^testing.T) {
    w:Id_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    first,second:=id_world_add(&w,5),id_world_add(&w,5)
    test_world_settle(&w)
    testing.expect_value(t,entity_of(&w.entities,5),first)
    testing.expect_value(t,w.entities.ids.shared,1)
    destroy(&w.entities,first)
    test_world_settle(&w)
    testing.expect_value(t,entity_of(&w.entities,5),second)
    testing.expect_value(t,w.entities.ids.shared,0)
    // The one that does not hold it leaves without taking the Id along.
    third:=id_world_add(&w,5)
    test_world_settle(&w)
    remove(&w.ids,third)
    test_world_settle(&w)
    testing.expect_value(t,entity_of(&w.entities,5),second)
    remove(&w.ids,second)
    test_world_settle(&w)
    testing.expect_value(t,entity_of(&w.entities,5),NONE)
    testing.expect_value(t,w.entities.ids.count,0)
}

@(test)
many_ids_stay_found_while_the_index_grows_and_loses_them_in_any_order :: proc(t:^testing.T) {
    w:Id_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    COUNT :: 2000
    entities:=make([]Entity,COUNT,context.temp_allocator)
    ids:=make([]base.Entity_Id,COUNT,context.temp_allocator)
    state:=u64(42)
    for i in 0..<COUNT {
        // Half random, half consecutive: these crowd the same slots.
        ids[i]=i%2==0?base.entity_id_next(&state):base.Entity_Id(i+1)
        entities[i]=id_world_add(&w,ids[i])
        if i%300==299 {test_world_settle(&w)}
    }
    test_world_settle(&w)
    for i in 0..<COUNT {testing.expect_value(t,entity_of(&w.entities,ids[i]),entities[i])}
    rng:=base.rng_make(7)
    gone:=make([]bool,COUNT,context.temp_allocator)
    for _ in 0..<COUNT/2 {
        i:=int(base.rng_u32(&rng)%COUNT)
        if gone[i] {continue}
        gone[i]=true
        destroy(&w.entities,entities[i])
    }
    test_world_settle(&w)
    left:=0
    for i in 0..<COUNT {
        testing.expect_value(t,entity_of(&w.entities,ids[i]),gone[i]?NONE:entities[i])
        if !gone[i] {left+=1}
    }
    testing.expect_value(t,w.entities.ids.count,left)
}

@(test)
the_index_travels_with_copied_and_swapped_worlds :: proc(t:^testing.T) {
    a,b:Id_World
    if !test_world_init(t,&a) {return}
    defer test_world_destroy(&a)
    if !test_world_init(t,&b) {return}
    defer test_world_destroy(&b)
    first:=id_world_add(&a,21)
    test_world_settle(&a)
    other:=id_world_add(&b,31)
    test_world_settle(&b)

    play:Id_World
    if !test_world_init(t,&play) {return}
    defer test_world_destroy(&play)
    testing.expect(t,test_world_copy(&play,&a))
    testing.expect(t,ids_synced(&play.entities,&play.ids))
    testing.expect_value(t,entity_of(&play.entities,21),first)
    late:=id_world_add(&play,22)
    test_world_settle(&play)
    testing.expect_value(t,entity_of(&play.entities,22),late)
    testing.expect_value(t,entity_of(&a.entities,22),NONE)

    test_world_swap(&a,&b)
    testing.expect(t,ids_synced(&a.entities,&a.ids) && ids_synced(&b.entities,&b.ids))
    testing.expect_value(t,entity_of(&a.entities,31),other)
    testing.expect_value(t,entity_of(&b.entities,21),first)
    testing.expect_value(t,entity_of(&a.entities,21),NONE)
    remove(&a.ids,other)
    test_world_settle(&a)
    testing.expect_value(t,entity_of(&a.entities,31),NONE)

    // A copy that does not move the index reads the table whole at the next settle.
    plain:Id_World
    if !test_world_init(t,&plain) {return}
    defer test_world_destroy(&plain)
    testing.expect(t,entities_copy(&plain.entities,&b.entities) && table_copy(&plain.ids,&b.ids) && table_copy(&plain.names,&b.names))
    testing.expect(t,!ids_synced(&plain.entities,&plain.ids))
    test_world_settle(&plain)
    testing.expect(t,ids_synced(&plain.entities,&plain.ids))
    testing.expect_value(t,entity_of(&plain.entities,21),first)
}

@(test)
a_cleared_world_has_no_ids :: proc(t:^testing.T) {
    w:Id_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    old:=id_world_add(&w,3)
    test_world_settle(&w)
    testing.expect(t,test_world_clear(&w))
    testing.expect_value(t,entity_of(&w.entities,3),NONE)
    again:=id_world_add(&w,3)
    test_world_settle(&w)
    testing.expect(t,again!=old)
    testing.expect_value(t,entity_of(&w.entities,3),again)
    testing.expect_value(t,w.entities.ids.count,1)
}

@(test)
a_new_id_skips_those_a_live_entity_has_and_repeats_for_a_state :: proc(t:^testing.T) {
    w:Id_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    state:=u64(99)
    copy_of:=state
    first:=id_new(&w.entities,&copy_of)
    testing.expect_value(t,base.entity_id_next(&state),first)
    taken:=id_world_add(&w,first)
    test_world_settle(&w)
    again:=u64(99)
    second:=id_new(&w.entities,&again)
    testing.expect(t,second!=first && second!=0)
    testing.expect_value(t,again,state+0x9e3779b97f4a7c15)
    // A holder that is no longer alive does not keep it.
    destroy(&w.entities,taken)
    fresh:=u64(99)
    testing.expect_value(t,id_new(&w.entities,&fresh),first)
}

@(test)
an_index_without_memory_reads_its_table_whole_once_there_is :: proc(t:^testing.T) {
    allocation:=Copy_Allocation{owner=context.allocator,remaining=1<<30}
    w:Id_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    // The index alone is without memory: the tables keep theirs.
    w.entities.ids.slots.allocator={copy_allocator,&allocation}
    w.entities.ids.of.allocator={copy_allocator,&allocation}
    e:=id_world_add(&w,17)
    allocation.remaining=0
    test_world_settle(&w)
    testing.expect_value(t,entity_of(&w.entities,17),NONE)
    testing.expect(t,w.entities.ids.whole && !ids_synced(&w.entities,&w.ids))
    allocation.remaining=1<<30
    test_world_settle(&w)
    testing.expect_value(t,entity_of(&w.entities,17),e)
    testing.expect(t,ids_synced(&w.entities,&w.ids))
}
