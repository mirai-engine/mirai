package core

import "core:testing"

@(private="file")
Probe :: struct {value:i32}

@(private="file")
Probe_Tag :: struct {}

@(private="file")
World_Of_Probes :: struct {
    using world:Test_World,
    disabled:Table(Disabled),
    parents:Table(Parent),
    names:Table(Name),
    probes:Table(Probe),
    tags:Table(Probe_Tag),
    hierarchy:Hierarchy,
}

// The settle of a World comes to the tables with something pending and to
// those that hold an entity destroyed or turned, and to no other.
@(test)
the_settle_of_a_world_comes_only_to_the_tables_that_wait :: proc(t:^testing.T) {
    w:World_Of_Probes
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    root,child,other:=create(&w.entities),create(&w.entities),create(&w.entities)
    add(&w.parents,child,Parent{root,0})
    for e in ([]Entity{root,child,other}) {add(&w.names,e,name_make("e"))}
    add(&w.probes,child,Probe{1});add(&w.probes,other,Probe{2});add(&w.tags,other,Probe_Tag{})
    testing.expect_value(t,test_world_settle(&w),4)
    Case :: struct {
        what:string,
        act:proc(w:^World_Of_Probes,root,child,other:Entity),
        tables:int,
        check:proc(w:^World_Of_Probes,root,child,other:Entity) -> bool,
    }
    cases:=[]Case{
        {"nothing waits",proc(w:^World_Of_Probes,root,child,other:Entity) {},0,nil},
        {"a row written in place",proc(w:^World_Of_Probes,root,child,other:Entity) {get(&w.probes,child).value=5},0,nil},
        {"an add to one table",proc(w:^World_Of_Probes,root,child,other:Entity) {add(&w.probes,root,Probe{3})},1,
            proc(w:^World_Of_Probes,root,child,other:Entity) -> bool {return has(&w.probes,root)}},
        {"a remove by reflection",proc(w:^World_Of_Probes,root,child,other:Entity) {raw_remove(raw(&w.probes),root)},1,
            proc(w:^World_Of_Probes,root,child,other:Entity) -> bool {return !has(&w.probes,root)}},
        {"a component turned off",proc(w:^World_Of_Probes,root,child,other:Entity) {disable(&w.tags,other)},1,
            proc(w:^World_Of_Probes,root,child,other:Entity) -> bool {return !has(&w.tags,other)}},
        {"a component turned on",proc(w:^World_Of_Probes,root,child,other:Entity) {enable(&w.tags,other)},1,
            proc(w:^World_Of_Probes,root,child,other:Entity) -> bool {return has(&w.tags,other)}},
        // Disabled itself, and the one table that holds a row of what turned and is not of its base.
        {"an entity turned off",proc(w:^World_Of_Probes,root,child,other:Entity) {add(&w.disabled,root,Disabled{})},2,
            proc(w:^World_Of_Probes,root,child,other:Entity) -> bool {return !has(&w.probes,child) && has(&w.probes,other) && has(&w.names,child)}},
        {"an entity turned on",proc(w:^World_Of_Probes,root,child,other:Entity) {remove(&w.disabled,root)},2,
            proc(w:^World_Of_Probes,root,child,other:Entity) -> bool {return has(&w.probes,child)}},
        // Name, Probe and Probe_Tag hold it; Disabled and Parent do not.
        {"an entity destroyed",proc(w:^World_Of_Probes,root,child,other:Entity) {destroy(&w.entities,other)},3,
            proc(w:^World_Of_Probes,root,child,other:Entity) -> bool {
                return raw_row(raw(&w.names),other)<0 && raw_row(raw(&w.probes),other)<0 && raw_row(raw(&w.tags),other)<0 && raw_count(raw(&w.names))==2
            }},
        {"an add to an entity destroyed in the same function",proc(w:^World_Of_Probes,root,child,other:Entity) {
            e:=create(&w.entities)
            add(&w.tags,e,Probe_Tag{})
            destroy(&w.entities,e)
        },1,proc(w:^World_Of_Probes,root,child,other:Entity) -> bool {return raw_count(raw(&w.tags))==0}},
    }
    for c in cases {
        c.act(&w,root,child,other)
        versions:=[5]u64{w.disabled.version,w.parents.version,w.names.version,w.probes.version,w.tags.version}
        testing.expectf(t,test_world_settle(&w)==c.tables,"%s: the settle came to other tables than the %d that wait",c.what,c.tables)
        if c.check!=nil {testing.expectf(t,c.check(&w,root,child,other),"%s: the settle did not apply it",c.what)}
        if c.tables==0 {testing.expectf(t,versions==[5]u64{w.disabled.version,w.parents.version,w.names.version,w.probes.version,w.tags.version},"%s: a table changed",c.what)}
        testing.expectf(t,test_world_settle(&w)==0,"%s: a table still waits after its settle",c.what)
    }

    // A World whose tables do not say what waits: its settle looks at every table, once.
    plain:World_Of_Probes
    if !test_world_init(t,&plain) {return}
    defer test_world_destroy(&plain)
    clear(&plain.entities.pending)
    for &table in test_world_info(&plain).tables {world_table_at(test_world_ref(&plain),&table).waits={}}
    e:=create(&plain.entities)
    add(&plain.probes,e,Probe{9})
    testing.expect_value(t,test_world_settle(&plain),len(test_world_info(&plain).tables))
    testing.expect(t,has(&plain.probes,e))
}

// What a swap brings waits in the table it came to.
@(test)
tables_swapped_and_copied_keep_saying_what_waits :: proc(t:^testing.T) {
    a,b:World_Of_Probes
    if !test_world_init(t,&a) || !test_world_init(t,&b) {return}
    defer test_world_destroy(&a)
    defer test_world_destroy(&b)
    e:=create(&a.entities)
    create(&b.entities)
    add(&a.probes,e,Probe{4})
    table_swap(&a.probes,&b.probes)
    testing.expect_value(t,test_world_settle(&a),0)
    testing.expect_value(t,test_world_settle(&b),1)
    testing.expect(t,has(&b.probes,e))
    // A copy leaves nothing waiting in the destination, whatever the source says.
    add(&a.tags,e,Probe_Tag{})
    testing.expect(t,entities_copy(&b.entities,&a.entities) && table_copy(&b.tags,&a.tags))
    test_world_settle(&b)
    testing.expect(t,!has(&b.tags,e))
    testing.expect_value(t,test_world_settle(&a),1)
    testing.expect(t,has(&a.tags,e))
}

@(test)
a_component_turned_off_keeps_its_value_out_of_sight :: proc(t:^testing.T) {
    w:World_Of_Probes
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    a,b,c:=create(&w.entities),create(&w.entities),create(&w.entities)
    add(&w.probes,a,Probe{1});add(&w.probes,b,Probe{2});add(&w.probes,c,Probe{3})
    test_world_settle(&w)
    seen:Seen
    _=changes(&w.probes,&seen)

    disable(&w.probes,a)
    testing.expect(t,has(&w.probes,a)) // it turns off when the function ends
    shape:=layout(&w.probes)
    test_world_settle(&w)
    testing.expect_value(t,count(&w.probes),2)
    testing.expect(t,!has(&w.probes,a) && get(&w.probes,a)==nil && row_of(&w.probes,a)==-1)
    testing.expect(t,layout(&w.probes)>shape)
    for row in 0..<count(&w.probes) {testing.expect(t,entity_at(&w.probes,row)!=a)}
    on,turned_off,found:=raw_state(raw(&w.probes),a)
    testing.expect(t,found && !on && turned_off)
    testing.expect_value(t,(cast(^Probe)raw_find(raw(&w.probes),type_info_of(Probe),a))^,Probe{1})
    testing.expect_value(t,raw_count(raw(&w.probes)),3)
    c1:=changes(&w.probes,&seen)
    testing.expect(t,!c1.all && len(c1.gone)==1 && c1.gone[0]==a)

    // A new value of a component off keeps it off.
    add(&w.probes,a,Probe{10})
    test_world_settle(&w)
    testing.expect(t,!has(&w.probes,a))

    enable(&w.probes,a)
    test_world_settle(&w)
    testing.expect_value(t,count(&w.probes),3)
    value,ok:=get(read(&w.probes),a)
    testing.expect(t,ok && value==Probe{10})
    c2:=changes(&w.probes,&seen)
    testing.expect(t,!c2.all && len(c2.gone)==0)
    testing.expect(t,changed(&w.probes,c2,row_of(&w.probes,a)))
    testing.expect(t,!changed(&w.probes,c2,row_of(&w.probes,b)))

    // Removing a row off and one on keeps every row where its entity says;
    // gone has b when it turned off and again when its row went.
    disable(&w.probes,b)
    test_world_settle(&w)
    remove(&w.probes,b);remove(&w.probes,c)
    test_world_settle(&w)
    testing.expect_value(t,count(&w.probes),1)
    testing.expect_value(t,raw_count(raw(&w.probes)),1)
    testing.expect_value(t,row_of(&w.probes,a),0)
    c3:=changes(&w.probes,&seen)
    testing.expect(t,len(c3.gone)==3 && c3.gone[0]==b && c3.gone[1]==b && c3.gone[2]==c)
}

@(test)
a_disabled_entity_turns_off_what_hangs_from_it_and_keeps_what_was_off :: proc(t:^testing.T) {
    w:World_Of_Probes
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    root,child,grandchild,other:=create(&w.entities),create(&w.entities),create(&w.entities),create(&w.entities)
    add(&w.parents,child,Parent{root,0});add(&w.parents,grandchild,Parent{child,0})
    for e in ([]Entity{root,child,grandchild,other}) {
        add(&w.probes,e,Probe{i32(entity_index(e))})
        add(&w.names,e,name_make("e"))
    }
    test_world_settle(&w)
    disable(&w.probes,grandchild)
    test_world_settle(&w)

    add(&w.disabled,root,Disabled{})
    test_world_settle(&w)
    testing.expect(t,entity_off(&w.entities,root) && entity_off(&w.entities,child) && entity_off(&w.entities,grandchild) && !entity_off(&w.entities,other))
    testing.expect_value(t,count(&w.probes),1)
    testing.expect(t,has(&w.probes,other))
    // The base stays on.
    testing.expect(t,has(&w.names,root) && has(&w.names,grandchild) && has(&w.parents,child))

    // Turning off a row already off with its entity is a change its stamp tells.
    seen:Seen
    _=changes(&w.probes,&seen)
    disable(&w.probes,child)
    test_world_settle(&w)
    c:=changes(&w.probes,&seen)
    turned:=raw_row(raw(&w.probes),child)
    testing.expect(t,version(&w.probes)>c.since && turned>=0 && w.probes.stamps[turned]>c.since && w.probes.off[turned])
    enable(&w.probes,child)
    test_world_settle(&w)
    c=changes(&w.probes,&seen)
    turned=raw_row(raw(&w.probes),child)
    testing.expect(t,turned>=0 && w.probes.stamps[turned]>c.since && !w.probes.off[turned])

    // What comes into a disabled tree comes off.
    late:=create(&w.entities)
    add(&w.parents,late,Parent{child,0})
    add(&w.probes,late,Probe{7})
    test_world_settle(&w)
    testing.expect(t,entity_off(&w.entities,late) && !has(&w.probes,late))
    testing.expect_value(t,raw_count(raw(&w.probes)),5)

    // Out of it, it is on again.
    remove(&w.parents,late)
    test_world_settle(&w)
    testing.expect(t,!entity_off(&w.entities,late) && has(&w.probes,late))

    remove(&w.disabled,root)
    test_world_settle(&w)
    testing.expect(t,has(&w.probes,root) && has(&w.probes,child))
    testing.expect(t,!has(&w.probes,grandchild)) // off by itself before
    testing.expect_value(t,w.entities.disabled,0)

    // A child under an entity destroyed while disabled is on.
    add(&w.disabled,child,Disabled{})
    test_world_settle(&w)
    testing.expect(t,entity_off(&w.entities,grandchild))
    destroy(&w.entities,child)
    test_world_settle(&w)
    testing.expect(t,!entity_off(&w.entities,grandchild))
    reused:=create(&w.entities)
    testing.expect(t,!entity_off(&w.entities,reused))
}

@(test)
a_component_on_owns_what_its_locks_take_and_one_off_lets_it_go :: proc(t:^testing.T) {
    es:Entities;entities_init(&es);defer entities_destroy(&es)
    bodies:Table(Probe);table_init(&bodies,"Body");defer table_destroy(&bodies)
    owner:Table(u8);table_init(&owner,"Transform");defer table_destroy(&owner)
    locks:=[1]Lock{{offset=lock_offset(&bodies,&owner),id=1,target="Transform",names={"","Body"}}}
    bodies.locks=locks[:]
    e:=create(&es)
    add(&bodies,e,Probe{1})
    table_settle(&bodies,&es)
    testing.expect_value(t,owner.owners[entity_index(e)].id,u16(1))
    disable(&bodies,e)
    table_settle(&bodies,&es)
    testing.expect_value(t,owner.owners[entity_index(e)],Row_Owner{})
    enable(&bodies,e)
    table_settle(&bodies,&es)
    testing.expect_value(t,owner.owners[entity_index(e)].id,u16(1))
}

@(test)
changes_read_the_table_whole_when_a_reader_falls_behind_or_it_is_replaced :: proc(t:^testing.T) {
    es:Entities;entities_init(&es);defer entities_destroy(&es)
    probes:Table(Probe);table_init(&probes,"Probe");defer table_destroy(&probes)
    first:Seen
    testing.expect(t,!changes(&probes,&first).all) // an empty table has nothing to read
    made:=make([dynamic]Entity,context.temp_allocator)
    for i in 0..<GONE_CAPACITY+2 {
        e:=create(&es)
        append(&made,e)
        add(&probes,e,Probe{i32(i)})
    }
    table_settle(&probes,&es)
    seen:Seen
    _=changes(&probes,&seen)
    behind:=seen
    for e in made[:GONE_CAPACITY/2] {remove(&probes,e)}
    table_settle(&probes,&es)
    c:=changes(&probes,&seen)
    testing.expect(t,!c.all && len(c.gone)==GONE_CAPACITY/2)
    // Dropping what every reader read leaves them their part; one that read
    // none of it reads the table whole.
    for e in made[GONE_CAPACITY/2:] {remove(&probes,e)}
    table_settle(&probes,&es)
    c=changes(&probes,&seen)
    testing.expect(t,!c.all && len(c.gone)==GONE_CAPACITY/2+2)
    // More rows than GONE_CAPACITY go at once without a reader that reads
    // each settle reading the table whole; one that falls behind more than
    // the room does.
    pushed:=0
    for pushed<=cap(probes.gone) {
        clear(&made)
        for i in 0..<GONE_CAPACITY+2 {
            e:=create(&es)
            append(&made,e)
            add(&probes,e,Probe{i32(i)})
        }
        table_settle(&probes,&es)
        testing.expect(t,!changes(&probes,&seen).all)
        for e in made {remove(&probes,e)}
        table_settle(&probes,&es)
        c=changes(&probes,&seen)
        testing.expect(t,!c.all && len(c.gone)==len(made))
        pushed+=len(made)
    }
    testing.expect(t,changes(&probes,&behind).all)

    // Copied over, the rows are others for whoever read the table before.
    add(&probes,create(&es),Probe{1})
    table_settle(&probes,&es)
    _=changes(&probes,&seen)
    other:Table(Probe);table_init(&other,"Probe");defer table_destroy(&other)
    shown,hidden:=create(&es),create(&es)
    add(&other,shown,Probe{2});add(&other,hidden,Probe{3})
    table_settle(&other,&es)
    disable(&other,hidden)
    table_settle(&other,&es)
    testing.expect(t,table_copy(&probes,&other))
    testing.expect(t,changes(&probes,&seen).all)
    testing.expect(t,count(&probes)==1 && has(&probes,shown) && !has(&probes,hidden))
    testing.expect_value(t,raw_count(raw(&probes)),2)
}

// In a single table the one on goes off with its entity and the one turned
// on before it is on until that entity is on again; one turned on while its
// entity is off is on once its entity is.
@(test)
a_single_component_follows_the_entities_turned_off_and_on :: proc(t:^testing.T) {
    w:World_Of_Probes
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    w.probes.single=true
    root,section:=create(&w.entities),create(&w.entities)
    add(&w.probes,root,Probe{1});add(&w.probes,section,Probe{2})
    test_world_settle(&w)
    enable(&w.probes,section)
    test_world_settle(&w)
    testing.expect(t,count(&w.probes)==1 && has(&w.probes,section))

    add(&w.disabled,section,Disabled{})
    test_world_settle(&w)
    testing.expect(t,count(&w.probes)==1 && has(&w.probes,root))
    remove(&w.disabled,section)
    test_world_settle(&w)
    testing.expect(t,count(&w.probes)==1 && has(&w.probes,section),"it was turned on last")

    add(&w.disabled,section,Disabled{})
    test_world_settle(&w)
    disable(&w.probes,root)
    enable(&w.probes,root)
    test_world_settle(&w)
    remove(&w.disabled,section)
    test_world_settle(&w)
    testing.expect(t,count(&w.probes)==1 && has(&w.probes,root),"turned on after the section went off")
    _,waits,_:=raw_state(raw(&w.probes),section)
    testing.expect(t,waits)
}
