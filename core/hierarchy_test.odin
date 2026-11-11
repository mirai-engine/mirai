package core

import "core:math"
import "core:math/linalg"
import "core:testing"
import mm "mirai:std/math"

@(private="file")
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

    // A destroyed parent leaves its children as roots, and the entity that reuses its index has none.
    destroy(&w.entities,a)
    tree_settle(t,&w)
    testing.expect(t,parent_of(h,c)==NONE && len(children(h,root))==0)
    reused:=create(&w.entities)
    testing.expect_value(t,entity_index(reused),entity_index(a))
    tree_settle(t,&w)
    testing.expect(t,first_child(h,reused)==NONE)

    // A table copied over is read whole, to the same tree.
    add(&w.parents,b,Parent{root,5});add(&w.parents,c,Parent{root,4})
    tree_settle(t,&w)
    copied:Table(Parent)
    table_init(&copied,"Parent")
    defer table_destroy(&copied)
    testing.expect(t,table_copy(&copied,&w.parents))
    other:Hierarchy
    defer value_free(&other,type_info_of(Hierarchy))
    testing.expect(t,value_copy(&other,&w.hierarchy,type_info_of(Hierarchy)))
    testing.expect(t,hierarchy_settle(&other,&copied,&w.entities))
    testing.expect(t,same(children(ref(&other),root),{c,b}))
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

    destroy_tree(&w.entities,h,a)
    testing.expect(t,!alive(&w.entities,a) && !alive(&w.entities,a1) && !alive(&w.entities,a2))
    testing.expect(t,alive(&w.entities,root) && alive(&w.entities,b) && alive(&w.entities,b1) && alive(&w.entities,outside))
    tree_settle(t,&w)
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
