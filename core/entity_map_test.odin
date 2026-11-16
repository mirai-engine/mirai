package core

import "base:runtime"
import "core:testing"

@(test)
an_entity_map_finds_each_generation_and_fills_a_hole_with_the_last_value :: proc(t:^testing.T) {
    m:Entity_Map(int);defer entity_map_destroy(&m)
    a,b,c:=entity_make(3,1),entity_make(7,1),entity_make(1,1)
    for e,i in ([3]Entity{a,b,c}) {
        _,ok:=entity_map_put(&m,e,10*(i+1))
        testing.expect(t,ok)
    }
    testing.expect(t,entity_map_get(&m,a)^==10 && entity_map_get(&m,b)^==20 && entity_map_get(&m,c)^==30)
    testing.expect_value(t,entity_map_index(&m,c),2)
    testing.expect(t,entity_map_get(&m,entity_make(3,2))==nil && entity_map_get(&m,entity_make(9,1))==nil)

    // A copy finds the same values of its own, and with room for them allocates nothing.
    copied:Entity_Map(int);defer entity_map_destroy(&copied)
    testing.expect(t,entity_map_copy(&copied,&m))
    entity_map_get(&copied,b)^=21
    testing.expect(t,entity_map_get(&m,b)^==20 && entity_map_get(&copied,a)^==10 && entity_map_index(&copied,c)==2)
    {
        context.allocator=runtime.nil_allocator()
        testing.expect(t,entity_map_copy(&copied,&m) && entity_map_get(&copied,b)^==20)
    }

    // A newer generation of an index takes the place of the older one.
    newer:=entity_make(3,2)
    testing.expect(t,entity_map_held(&m,newer)==a && entity_map_held(&m,a)==a && entity_map_held(&m,entity_make(9,1))==NONE)
    value,ok:=entity_map_put(&m,newer,11)
    testing.expect(t,ok && value^==11 && entity_map_get(&m,a)==nil && entity_map_index(&m,newer)==0)
    testing.expect_value(t,len(m.values),3)

    testing.expect(t,entity_map_remove(&m,b) && !entity_map_remove(&m,b))
    testing.expect(t,entity_map_index(&m,c)==1 && entity_map_get(&m,c)^==30 && entity_map_get(&m,newer)^==11)
    testing.expect_value(t,len(m.entities),2)
    _,ok=entity_map_put(&m,NONE,1)
    testing.expect(t,!ok)

    entity_map_clear(&m)
    testing.expect(t,len(m.values)==0 && entity_map_get(&m,c)==nil && entity_map_get(&m,newer)==nil)
}

@(test)
an_entity_map_without_memory_stays_as_it_was_and_a_steady_frame_does_not_allocate :: proc(t:^testing.T) {
    allocation:=Copy_Allocation{owner=context.allocator}
    context.allocator={copy_allocator,&allocation}
    m:Entity_Map(int);defer entity_map_destroy(&m)
    a,b:=entity_make(1,1),entity_make(40,1)
    _,ok:=entity_map_put(&m,a,1)
    testing.expect(t,!ok && len(m.values)==0 && entity_map_get(&m,a)==nil)

    // Room for the value but not for its entity, then not for its index.
    for budget in 1..<4 {
        allocation.remaining=budget
        _,ok=entity_map_put(&m,a,1)
        if ok {break}
        testing.expect(t,len(m.values)==0 && len(m.entities)==0 && entity_map_get(&m,a)==nil)
    }
    testing.expect(t,ok && entity_map_get(&m,a)^==1)
    allocation.remaining=0
    _,ok=entity_map_put(&m,b,2)
    testing.expect(t,!ok && len(m.values)==1 && entity_map_get(&m,b)==nil && entity_map_get(&m,a)^==1)

    allocation.remaining=8
    testing.expect(t,entity_map_reserve(&m,8,64))
    allocation.remaining=0
    requests:=allocation.requests
    for round in 0..<3 {
        for i in 2..<9 {
            _,ok=entity_map_put(&m,entity_make(i*7,u32(round+1)),i)
            testing.expect(t,ok)
        }
        for i in 2..<9 {testing.expect(t,entity_map_remove(&m,entity_make(i*7,u32(round+1))))}
        _,ok=entity_map_put(&m,a,round)
        testing.expect(t,ok)
    }
    testing.expect_value(t,allocation.requests,requests)
    testing.expect(t,len(m.values)==1 && entity_map_get(&m,a)^==2)
}

@(test)
an_entity_map_drops_what_left_its_table_from_the_changes :: proc(t:^testing.T) {
    es:Entities;entities_init(&es);defer entities_destroy(&es)
    table:Table(int);table_init(&table,"Probe");defer table_destroy(&table)
    m:Entity_Map(int);defer entity_map_destroy(&m)
    settle :: proc(table:^Table(int),es:^Entities) {
        table_settle(table,es)
        entities_settle(es)
    }
    removed,destroyed,off,back,kept:=create(&es),create(&es),create(&es),create(&es),create(&es)
    for e,i in ([5]Entity{removed,destroyed,off,back,kept}) {
        add(&table,e,i)
        entity_map_put(&m,e,i)
    }
    settle(&table,&es)
    seen:Seen
    _=changes(&table,&seen)

    remove(&table,removed)
    destroy(&es,destroyed)
    disable(&table,off)
    remove(&table,back)
    settle(&table,&es)
    add(&table,back,30)
    settle(&table,&es)

    c:=changes(&table,&seen)
    testing.expect(t,!c.all && len(c.gone)==4)
    left:[dynamic]Entity;defer delete(left)
    at,value:=0,0
    for e in entity_map_left(&m,&table,c,&at,&value) {
        testing.expect(t,entity_index(e)==value+1)
        append(&left,e)
    }
    // The settle writes what was asked first and the destroyed after.
    testing.expect(t,len(left)==3 && left[0]==removed && left[1]==off && left[2]==destroyed)
    testing.expect(t,len(m.values)==2 && entity_map_get(&m,back)^==3 && entity_map_get(&m,kept)^==4)
    testing.expect_value(t,entity_map_prune(&m,&table,changes(&table,&seen)),0)

    // A table the reader did not see: every value without a row on goes.
    lost:=[3]Entity{create(&es),create(&es),create(&es)}
    for e in lost {entity_map_put(&m,e,0)}
    entity_map_remove(&m,back)
    entity_map_put(&m,back,3)
    table_clear(&table)
    add(&table,kept,4);add(&table,back,3)
    settle(&table,&es)
    c=changes(&table,&seen)
    testing.expect(t,c.all)
    testing.expect_value(t,entity_map_prune(&m,&table,c),3)
    testing.expect(t,len(m.values)==2 && entity_map_get(&m,back)^==3 && entity_map_get(&m,kept)^==4)
    for e in lost {testing.expect(t,entity_map_get(&m,e)==nil)}
}
