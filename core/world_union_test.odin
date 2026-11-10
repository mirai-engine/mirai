package core

import "base:runtime"
import "core:mem"
import "core:testing"

@(private="file") Union_Link :: struct {target:Entity,weight:f32}
@(private="file") @(component,single) Union_Sky :: struct {light:f32}

@(private="file")
Union_World :: struct {
    using world:Test_World,
    parents:Table(Parent),
    links:Table(Union_Link),
    skies:Table(Union_Sky),
}

// A World made apart joins the live one: its entities are new ones, their
// Entity fields name the new ones, what was off stays off and its roots go
// under the parent asked for.
@(test)
a_world_joins_another_with_its_entities_named_anew :: proc(t:^testing.T) {
    live,apart:Union_World
    if !test_world_init(t,&live) {return}
    defer test_world_destroy(&live)
    info:=test_world_info(&live)
    if !test_world_init(t,&apart) {return}
    defer test_world_destroy(&apart)
    anchor:=create(&live.entities)
    test_world_settle(&live)
    // apart: a root that names its child, and the child, off by itself.
    root,child:=create(&apart.entities),create(&apart.entities)
    add(&apart.links,root,Union_Link{child,2})
    add(&apart.parents,child,Parent{root,0})
    add(&apart.links,child,Union_Link{root,3})
    test_world_settle(&apart)
    disable(&apart.links,child)
    test_world_settle(&apart)

    made:[dynamic]Entity
    defer delete(made)
    testing.expect(t,world_union(world_ref(&live,info),world_ref(&apart,info),anchor,&made))
    test_world_settle(&live)
    new_root,new_child:=made[entity_index(root)],made[entity_index(child)]
    testing.expect(t,alive(&live.entities,new_root) && alive(&live.entities,new_child))
    link,_:=get(&live.links,new_root)
    testing.expect_value(t,link.target,new_child)
    testing.expect(t,!has(&live.links,new_child),"what was off stays off")
    off_row:=raw_row(raw(&live.links),new_child)
    testing.expect(t,off_row>=0 && live.links.values[off_row].target==new_root)
    up,_:=get(&live.parents,new_child)
    testing.expect_value(t,up.entity,new_root)
    top,_:=get(&live.parents,new_root)
    testing.expect_value(t,top.entity,anchor)
    testing.expect_value(t,live.entities.alive,3)
    testing.expect_value(t,count(&live.parents),2)
}

// Only the roots asked for join, with what hangs from them, as roots; what
// they name outside them names none.
@(test)
only_what_hangs_from_the_roots_asked_for_joins :: proc(t:^testing.T) {
    live,next:Union_World
    if !test_world_init(t,&live) {return}
    defer test_world_destroy(&live)
    info:=test_world_info(&live)
    if !test_world_init(t,&next) {return}
    defer test_world_destroy(&next)
    level,seat,body:=create(&live.entities),create(&live.entities),create(&live.entities)
    add(&live.parents,seat,Parent{level,0})
    add(&live.parents,body,Parent{seat,0})
    add(&live.links,body,Union_Link{level,1})
    test_world_settle(&live)
    made:[dynamic]Entity
    defer delete(made)
    kept:=[1]Entity{seat}
    testing.expect(t,world_union(world_ref(&next,info),world_ref(&live,info),NONE,&made,kept[:]))
    test_world_settle(&next)
    testing.expect_value(t,next.entities.alive,2)
    new_seat,new_body:=made[entity_index(seat)],made[entity_index(body)]
    testing.expect(t,!has(&next.parents,new_seat),"it is a root")
    up,_:=get(&next.parents,new_body)
    testing.expect_value(t,up.entity,new_seat)
    link,_:=get(&next.links,new_body)
    testing.expect_value(t,link.target,NONE)
}

// A World of one entity joins under an anchor as one entity with one Parent,
// after the children the anchor has; with room for it, the join and the
// settle that follows allocate nothing.
@(test)
a_join_makes_an_entity_for_each_one_and_allocates_nothing_with_room :: proc(t:^testing.T) {
    tracker:mem.Tracking_Allocator
    mem.tracking_allocator_init(&tracker,context.allocator);defer mem.tracking_allocator_destroy(&tracker)
    live,apart:Union_World
    if !test_world_init(t,&live,allocator=mem.tracking_allocator(&tracker)) {return}
    defer test_world_destroy(&live)
    info:=test_world_info(&live)
    if !test_world_init(t,&apart) {return}
    defer test_world_destroy(&apart)
    anchor,first,second:=create(&live.entities),create(&live.entities),create(&live.entities)
    add(&live.parents,first,Parent{anchor,0})
    add(&live.parents,second,Parent{anchor,4})
    test_world_settle(&live)
    lone:=create(&apart.entities)
    add(&apart.links,lone,Union_Link{lone,1})
    test_world_settle(&apart)

    made:[dynamic]Entity
    defer delete(made)
    reserve(&made,len(apart.entities.generation))
    testing.expect(t,world_union(world_ref(&live,info),world_ref(&apart,info),anchor,&made))
    test_world_settle(&live)
    testing.expect_value(t,live.entities.alive,4)
    testing.expect_value(t,count(&live.parents),3)
    joined:=made[entity_index(lone)]
    up,_:=get(&live.parents,joined)
    testing.expect_value(t,up,Parent{anchor,5})
    link,_:=get(&live.links,joined)
    testing.expect_value(t,link.target,joined)

    // Gone again, the room it took stays for the next join.
    destroy(&live.entities,joined)
    test_world_settle(&live)
    before:=tracker.total_allocation_count
    testing.expect(t,world_union(world_ref(&live,info),world_ref(&apart,info),anchor,&made))
    test_world_settle(&live)
    testing.expect_value(t,tracker.total_allocation_count,before)
    testing.expect_value(t,live.entities.alive,4)
}

// Without memory for what joins nothing joins: dst stays as it was.
@(test)
a_join_without_memory_leaves_the_world_as_it_was :: proc(t:^testing.T) {
    live,apart:Union_World
    if !test_world_init(t,&live) {return}
    defer test_world_destroy(&live)
    info:=test_world_info(&live)
    if !test_world_init(t,&apart) {return}
    defer test_world_destroy(&apart)
    anchor:=create(&live.entities)
    test_world_settle(&live)
    a,b:=create(&apart.entities),create(&apart.entities)
    add(&apart.parents,b,Parent{a,0})
    add(&apart.links,b,Union_Link{a,1})
    test_world_settle(&apart)

    failing :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
        return nil,mode==.Free || mode==.Free_All?.None:.Out_Of_Memory
    }
    kept:=live.links.pending.allocator
    live.links.pending.allocator={procedure=failing}
    made:[dynamic]Entity
    defer delete(made)
    testing.expect(t,!world_union(world_ref(&live,info),world_ref(&apart,info),anchor,&made))
    live.links.pending.allocator=kept
    testing.expect_value(t,len(made),0)
    testing.expect_value(t,live.entities.alive,1)
    testing.expect(t,len(live.parents.pending)==0 && len(live.links.pending)==0)
    test_world_settle(&live)
    testing.expect_value(t,count(&live.parents),0)
}

// What a single table of what joins has comes off, whatever dst has on: it
// does not take the place of the one on, does not come back when that one
// goes, and in a root without one (a cave) leaves none on. Turned on, it is.
@(test)
a_world_that_joins_with_its_own_single_brings_it_off :: proc(t:^testing.T) {
    live,cave,apart:Union_World
    if !test_world_init(t,&live) {return}
    defer test_world_destroy(&live)
    info:=test_world_info(&live)
    if !test_world_init(t,&cave) {return}
    defer test_world_destroy(&cave)
    if !test_world_init(t,&apart) {return}
    defer test_world_destroy(&apart)
    sky:=create(&live.entities)
    add(&live.skies,sky,Union_Sky{1})
    test_world_settle(&live)
    test_world_settle(&cave)
    other:=create(&apart.entities)
    add(&apart.skies,other,Union_Sky{2})
    test_world_settle(&apart)
    testing.expect(t,has(&apart.skies,other),"alone, a scene uses its own")

    made:[dynamic]Entity
    defer delete(made)
    testing.expect(t,world_union(world_ref(&live,info),world_ref(&apart,info),NONE,&made))
    test_world_settle(&live)
    joined:=made[entity_index(other)]
    testing.expect(t,count(&live.skies)==1 && has(&live.skies,sky))
    _,off,found:=raw_state(raw(&live.skies),joined)
    testing.expect(t,found && off)
    disable(&live.skies,sky)
    test_world_settle(&live)
    testing.expect_value(t,count(&live.skies),0)

    testing.expect(t,world_union(world_ref(&cave,info),world_ref(&apart,info),NONE,&made))
    test_world_settle(&cave)
    testing.expect_value(t,count(&cave.skies),0)
    enable(&cave.skies,made[entity_index(other)])
    test_world_settle(&cave)
    testing.expect(t,count(&cave.skies)==1 && has(&cave.skies,made[entity_index(other)]))
}
