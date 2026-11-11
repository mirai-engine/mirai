package core

import "base:runtime"
import "core:testing"

@(test)
clearing_entities_invalidates_every_previous_handle_before_and_after_reuse :: proc(t:^testing.T) {
    es,copy:Entities
    entities_init(&es);entities_init(&copy)
    defer entities_destroy(&es);defer entities_destroy(&copy)
    old:[8]Entity
    for &entity in old {entity=create(&es)}
    destroy(&es,old[3]);entities_settle(&es)
    old[3]=create(&es)
    destroy(&es,old[6])
    for _ in 0..<3 {
        entities_clear(&es)
        testing.expect_value(t,es.alive,0)
        testing.expect_value(t,len(es.doomed),0)
        testing.expect_value(t,entities_capacity(&es),len(old)+1)
        for entity in old {testing.expect(t,!alive(&es,entity))}
        entities_copy(&copy,&es)
        for &entity,index in old {
            previous:=entity
            entity=create(&es)
            cloned:=create(&copy)
            testing.expect_value(t,cloned,entity)
            testing.expect_value(t,entity_index(entity),index+1)
            testing.expect(t,entity!=previous && !alive(&es,previous) && alive(&es,entity))
        }
        destroy(&es,old[0]);entities_settle(&es)
        old[0]=create(&es)
    }
}

@(test)
clearing_entities_skips_generation_zero_and_resets_an_empty_pool :: proc(t:^testing.T) {
    es:Entities
    entities_init(&es);defer entities_destroy(&es)
    entities_clear(&es)
    first:=create(&es)
    es.generation[entity_index(first)]=max(u32)
    wrapped:=entity_make(entity_index(first),max(u32))
    entities_clear(&es)
    testing.expect(t,!alive(&es,wrapped))
    replacement:=create(&es)
    testing.expect_value(t,entity_generation(replacement),u32(1))
    testing.expect(t,alive(&es,replacement))
}

// Without memory an add, a create and a destroy say so and change nothing: no
// add turns into a remove or gives another add's value, no create gives an
// entity that lives, and an entity destroyed keeps living with its rows.
@(test)
without_memory_add_create_and_destroy_fail_and_change_nothing :: proc(t:^testing.T) {
    w:Tree_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    failing :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
        return nil,mode==.Free || mode==.Free_All?.None:.Out_Of_Memory
    }
    none:=runtime.Allocator{procedure=failing}
    kept:=create(&w.entities)
    add(&w.locals,kept,Transform{{1,0,0},1,{1,1,1}})
    test_world_settle(&w)
    delete(w.locals.added)
    w.locals.added=make([dynamic]Transform,none)
    testing.expect(t,!add(&w.locals,kept,Transform{{2,0,0},1,{1,1,1}}))
    w.locals.added=make([dynamic]Transform)
    pending:=w.locals.pending
    w.locals.pending=make([dynamic]Pending,none)
    testing.expect(t,!add(&w.locals,kept,Transform{{3,0,0},1,{1,1,1}}))
    w.locals.pending=pending
    test_world_settle(&w)
    value,found:=get(&w.locals,kept)
    testing.expect(t,found && value.position==[3]f32{1,0,0})

    for len(w.entities.generation)<cap(w.entities.generation) {create(&w.entities)}
    alive_before:=w.entities.alive
    generation:=w.entities.generation.allocator
    w.entities.generation.allocator=none
    testing.expect_value(t,create(&w.entities),NONE)
    w.entities.generation.allocator=generation
    testing.expect_value(t,w.entities.alive,alive_before)

    delete(w.entities.doomed)
    w.entities.doomed=make([dynamic]Entity,none)
    testing.expect(t,!destroy(&w.entities,kept) && alive(&w.entities,kept))
    w.entities.doomed=make([dynamic]Entity)
    test_world_settle(&w)
    testing.expect(t,has(&w.locals,kept))
}
