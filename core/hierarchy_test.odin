package core

import "core:math"
import "core:math/linalg"
import "core:testing"
import mm "mirai:std/math"

@(private)
@(test_world)
Tree_World :: struct {
    using world:Test_World,
    disabled:Table(Disabled),
    parents:Table(Parent),
    locals:Table(Transform),
    hierarchy:Hierarchy,
}

@(private="file")
tree_settle :: proc(t:^testing.T,w:^Tree_World) {
    test_world_settle(w)
    testing.expect(t,hierarchy_settle(&w.hierarchy,&w.parents,&w.entities))
}

@(private="file")
same :: proc(a,b:[]Entity) -> bool {
    if len(a)!=len(b) {return false}
    for e,i in a {if e!=b[i] {return false}}
    return true
}

@(test)
children_follow_their_parent_rows_in_order :: proc(t:^testing.T) {
    w:Tree_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    h:=ref(&w.hierarchy)
    root,a,b,c:=create(&w.entities),create(&w.entities),create(&w.entities),create(&w.entities)
    add(&w.parents,a,Parent{root,2});add(&w.parents,b,Parent{root,0});add(&w.parents,c,Parent{root,1})
    tree_settle(t,&w)
    testing.expect(t,same(children(h,root),{b,c,a}))
    testing.expect(t,parent_of(h,a)==root && parent_of(h,root)==NONE && last_child(h,root)==a)

    // A write of the order moves it among its siblings; one that changes nothing keeps the tree.
    seen:=w.hierarchy.version
    edit(&w.parents,c)^=Parent{root,1}
    tree_settle(t,&w)
    testing.expect_value(t,w.hierarchy.version,seen)
    edit(&w.parents,a).order=-1
    tree_settle(t,&w)
    testing.expect(t,same(children(h,root),{a,b,c}))
    testing.expect(t,w.hierarchy.version>seen)

    // Under another parent, and without one.
    add(&w.parents,c,Parent{a,0})
    remove(&w.parents,b)
    tree_settle(t,&w)
    testing.expect(t,same(children(h,root),{a}) && same(children(h,a),{c}) && parent_of(h,b)==NONE)

    // A destroyed parent takes its children, and the entity that reuses its index has none.
    destroy(&w.entities,a)
    tree_settle(t,&w)
    testing.expect(t,!alive(&w.entities,c) && len(children(h,root))==0)
    reused,again:=create(&w.entities),create(&w.entities)
    testing.expect(t,entity_index(reused)==entity_index(c) && entity_index(again)==entity_index(a))
    tree_settle(t,&w)
    testing.expect(t,first_child(h,again)==NONE)

    // A table copied over is read whole, to the same tree.
    add(&w.parents,b,Parent{root,5});add(&w.parents,reused,Parent{root,4})
    tree_settle(t,&w)
    copied:Table(Parent)
    table_init(&copied,"Parent")
    defer table_destroy(&copied)
    testing.expect(t,table_copy(&copied,&w.parents))
    other:Hierarchy
    defer value_free(&other,type_info_of(Hierarchy))
    testing.expect(t,value_copy(&other,&w.hierarchy,type_info_of(Hierarchy)))
    testing.expect(t,hierarchy_settle(&other,&copied,&w.entities))
    testing.expect(t,same(children(ref(&other),root),{reused,b}))
}

// What hangs from an entity destroyed goes at the settle, also what a Parent
// of the same function hangs from it and from those; one taken out first stays.
@(test)
what_hangs_from_a_destroyed_entity_goes_with_it :: proc(t:^testing.T) {
    w:Tree_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    root,kept,old,outside:=create(&w.entities),create(&w.entities),create(&w.entities),create(&w.entities)
    add(&w.parents,kept,Parent{root,0});add(&w.parents,old,Parent{root,1})
    tree_settle(t,&w)
    born,deeper:=create(&w.entities),create(&w.entities)
    add(&w.parents,deeper,Parent{born,0});add(&w.parents,born,Parent{root,2})
    remove(&w.parents,kept)
    destroy(&w.entities,root)
    tree_settle(t,&w)
    testing.expect(t,!alive(&w.entities,old) && !alive(&w.entities,born) && !alive(&w.entities,deeper))
    testing.expect(t,alive(&w.entities,kept) && alive(&w.entities,outside))
    testing.expect_value(t,count(&w.parents),0)
}

@(test)
a_parent_that_closes_a_cycle_waits_out_of_the_tree :: proc(t:^testing.T) {
    w:Tree_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    h:=ref(&w.hierarchy)
    a,b,c:=create(&w.entities),create(&w.entities),create(&w.entities)
    add(&w.parents,b,Parent{a,0});add(&w.parents,c,Parent{b,0})
    tree_settle(t,&w)
    add(&w.parents,a,Parent{c,0})
    tree_settle(t,&w)
    testing.expect(t,parent_of(h,a)==NONE && parent_of(h,b)==a && parent_of(h,c)==b)
    walked:=0
    for at:=a;at!=NONE;at=subtree_next(h,a,at) {walked+=1}
    testing.expect_value(t,walked,3)
    self:=create(&w.entities)
    add(&w.parents,self,Parent{self,0})
    tree_settle(t,&w)
    testing.expect(t,parent_of(h,self)==NONE && first_child(h,self)==NONE)

    // When b leaves a, a goes under c.
    remove(&w.parents,b)
    tree_settle(t,&w)
    testing.expect(t,parent_of(h,b)==NONE && parent_of(h,a)==c && parent_of(h,c)==b)
    testing.expect_value(t,len(w.hierarchy.cut),1)
}

@(test)
a_subtree_is_walked_parents_first_and_destroyed_whole :: proc(t:^testing.T) {
    w:Tree_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    h:=ref(&w.hierarchy)
    root,a,a1,a2,b,b1,outside:=create(&w.entities),create(&w.entities),create(&w.entities),create(&w.entities),create(&w.entities),create(&w.entities),create(&w.entities)
    add(&w.parents,a,Parent{root,0});add(&w.parents,b,Parent{root,1})
    add(&w.parents,a1,Parent{a,0});add(&w.parents,a2,Parent{a,1});add(&w.parents,b1,Parent{b,0})
    tree_settle(t,&w)
    walk:[dynamic]Entity
    defer delete(walk)
    for at:=root;at!=NONE;at=subtree_next(h,root,at) {append(&walk,at)}
    testing.expect(t,same(walk[:],{root,a,a1,a2,b,b1}))
    clear(&walk)
    for at:=root;at!=NONE;at=subtree_next(h,root,at,at!=a) {append(&walk,at)}
    testing.expect(t,same(walk[:],{root,a,b,b1}))
    clear(&walk)
    for at:=a;at!=NONE;at=subtree_next(h,a,at) {append(&walk,at)}
    testing.expect(t,same(walk[:],{a,a1,a2}))

    destroy(&w.entities,a)
    tree_settle(t,&w)
    testing.expect(t,!alive(&w.entities,a) && !alive(&w.entities,a1) && !alive(&w.entities,a2))
    testing.expect(t,alive(&w.entities,root) && alive(&w.entities,b) && alive(&w.entities,b1) && alive(&w.entities,outside))
    testing.expect(t,same(children(h,root),{b}))
}

@(test)
ancestors_are_found_through_parent :: proc(t:^testing.T) {
    w:Tree_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    root,mid,leaf,loose:=create(&w.entities),create(&w.entities),create(&w.entities),create(&w.entities)
    add(&w.parents,mid,Parent{root,0});add(&w.parents,leaf,Parent{mid,0})
    marked:Table(Name)
    table_init(&marked,"Name")
    defer table_destroy(&marked)
    add(&marked,root,{})
    tree_settle(t,&w)
    table_settle(&marked,&w.entities)
    parents:=&w.parents
    testing.expect(t,ancestor_with(parents,&marked,leaf)==root && ancestor_with(parents,&marked,root)==root)
    testing.expect(t,ancestor_with(parents,&marked,loose)==NONE)
    testing.expect(t,is_under(parents,leaf,root) && is_under(parents,leaf,leaf) && !is_under(parents,root,leaf) && !is_under(parents,loose,root))

    // A cycle in the rows ends the walk.
    add(&w.parents,root,Parent{leaf,0})
    tree_settle(t,&w)
    unmarked:Table(Name)
    table_init(&unmarked,"Name")
    defer table_destroy(&unmarked)
    testing.expect(t,!is_under(parents,leaf,loose) && ancestor_with(parents,&unmarked,leaf)==NONE)
}

@(test)
a_world_pose_is_written_under_the_parent :: proc(t:^testing.T) {
    w:Tree_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    holder,held:=create(&w.entities),create(&w.entities)
    add(&w.locals,holder,Transform{{3,0,0},mm.quat_axis_angle({0,1,0},math.PI/2),{2,1,1}})
    add(&w.locals,held,Transform{{0,0,0},1,{1,3,1}})
    add(&w.parents,held,Parent{holder,0})
    tree_settle(t,&w)
    rotation:=mm.quat_axis_angle({1,0,0},0.5)
    testing.expect(t,world_set(edit(&w.locals,held),&w.locals,&w.parents,held,{1,2,3},rotation))
    world,placed:=world_of(&w.locals,&w.parents,held)
    testing.expect(t,placed && linalg.length(world.position-[3]f32{1,2,3})<1e-4)
    testing.expect(t,linalg.length(mm.quat_rotate(world.rotation,{1,0,0})-mm.quat_rotate(rotation,{1,0,0}))<1e-4)
    local,_:=get(&w.locals,held)
    testing.expect_value(t,local.scale,[3]f32{1,3,1})

    // A parent without size cannot hold it anywhere.
    edit(&w.locals,holder).scale={0,1,1}
    testing.expect(t,!world_set(edit(&w.locals,held),&w.locals,&w.parents,held,{1,2,3},rotation))
    under_root,ok:=local_under(&w.locals,&w.parents,NONE,mm.Transform{{1,2,3},rotation,{1,1,1}})
    testing.expect(t,ok && under_root.position==[3]f32{1,2,3})
}

@(test)
the_world_of_a_deep_chain_composes_every_link :: proc(t:^testing.T) {
    w:Tree_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    above:=NONE
    leaf:Entity
    for _ in 0..<150 {
        leaf=create(&w.entities)
        add(&w.locals,leaf,Transform{{1,0,0},1,{1,1,1}})
        if above!=NONE {add(&w.parents,leaf,Parent{above,0})}
        above=leaf
    }
    tree_settle(t,&w)
    world,placed:=world_of(&w.locals,&w.parents,leaf)
    testing.expect(t,placed && abs(world.position.x-150)<1e-3)
    testing.expect_value(t,depth_of(&w.parents,leaf),149)
}

// Off follows Disabled and the hierarchy from what changed alone: on random
// changes it is what the Parent rows above each entity say, and a settle that
// hangs one child somewhere looks at the off of nothing elsewhere.
@(test)
off_follows_disabled_and_the_tree_from_what_changed :: proc(t:^testing.T) {
    w:Tree_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    random:=u64(0x9e3779b97f4a7c15)
    next :: proc(random:^u64,n:int) -> int {
        random^~=random^<<13;random^~=random^>>7;random^~=random^<<17
        return int(random^%u64(n))
    }
    live:[dynamic]Entity
    defer delete(live)
    for _ in 0..<64 {append(&live,create(&w.entities))}
    for round in 0..<200 {
        for _ in 0..<4 {
            switch next(&random,6) {
            case 0: append(&live,create(&w.entities))
            case 1:
                child,parent:=live[next(&random,len(live))],live[next(&random,len(live))]
                if entity_index(parent)<entity_index(child) {add(&w.parents,child,Parent{parent,0})}
            case 2: remove(&w.parents,live[next(&random,len(live))])
            case 3: add(&w.disabled,live[next(&random,len(live))],Disabled{})
            case 4: remove(&w.disabled,live[next(&random,len(live))])
            case 5: if round%8==0 {destroy(&w.entities,live[next(&random,len(live))])}
            }
        }
        tree_settle(t,&w)
        kept:=0
        for e in live {if alive(&w.entities,e) {live[kept]=e;kept+=1}}
        resize(&live,kept)
        for e in live {
            off:=false
            for at:=e;at!=NONE && !off; {
                off=has(&w.disabled,at)
                parent,_:=get(&w.parents,at)
                at=parent.entity
            }
            if entity_off(&w.entities,e)!=off {
                testing.expectf(t,false,"round %d: entity %d is off %v, and the rows above it say %v",round,entity_index(e),entity_off(&w.entities,e),off)
                return
            }
        }
    }
    // With something off, an off nobody set stays where nothing changed.
    holder:=live[len(live)-1]
    add(&w.disabled,holder,Disabled{})
    tree_settle(t,&w)
    far:=live[0]
    i:=entity_index(far)
    was:=w.entities.off[i]
    w.entities.off[i]=!was
    add(&w.parents,create(&w.entities),Parent{holder,0})
    tree_settle(t,&w)
    testing.expect(t,w.entities.off[i]==!was,"a settle that hung one child walked other entities")
    w.entities.off[i]=was
}
