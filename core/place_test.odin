package core

import "core:strings"
import "core:testing"

@(test)
a_place_writes_a_free_transform_and_asks_the_owner_of_a_locked_one :: proc(t:^testing.T) {
    es:Entities
    entities_init(&es)
    defer entities_destroy(&es)
    transforms:Table(Transform)
    parents:Table(Parent)
    table_init(&transforms,"Transform")
    table_init(&parents,"Parent")
    defer table_destroy(&transforms)
    defer table_destroy(&parents)
    free_one,held,bare:=create(&es),create(&es),create(&es)
    add(&transforms,free_one,TRANSFORM_IDENTITY)
    add(&transforms,held,TRANSFORM_IDENTITY)
    table_settle(&transforms,&es)
    resize(&transforms.owners,entity_index(held)+1)
    transforms.owners[entity_index(held)]=Row_Owner{generation=entity_generation(held),id=1}
    places:Places
    defer delete(places.queue.items)
    jumps:Jumps
    defer delete(jumps.queue.items)
    problems:Problems
    p:=Placer{&transforms,read(&parents),&places,&jumps}

    testing.expect(t,place(p,free_one,{1,2,3},teleport=false))
    value,_:=get(read(&transforms),free_one)
    testing.expect(t,value.position==[3]f32{1,2,3},"a free Transform is written at once")
    testing.expect(t,len(places.queue.items)==0)
    testing.expect(t,len(jumps.queue.items)==0,"a place that is not a teleport is no jump")
    testing.expect(t,place(p,free_one,{1,7,3}))
    testing.expect(t,len(jumps.queue.items)==1 && jumps.queue.items[0].entity==free_one && jumps.queue.items[0].by.position==[3]f32{0,5,0},"a teleport is drawn as coming from where it is put")

    testing.expect(t,place(p,held,{4,5,6}))
    testing.expect(t,len(places.queue.items)==1 && places.queue.items[0].entity==held && !places.queue.items[0].at_rest,"a Transform another component owns is asked of it")
    testing.expect(t,place(p,held,{4,5,6},at_rest=true) && len(places.queue.items)==2 && places.queue.items[1].at_rest)
    testing.expect(t,!place(p,bare,{}),"an entity without Transform has no place")

    places_drop(&places,&problems)
    testing.expect(t,len(places.queue.items)==0)
    testing.expect(t,problems.count==1 && strings.contains(problem_text(&problems.entries[0]),"not taken"),"what nobody took is reported")
}
