package core

import "base:runtime"
import "core:testing"
import "core:mem"

@(test)
rows_written_take_a_stamp_above_the_version_a_reader_saw :: proc(t:^testing.T) {
    es:Entities
    entities_init(&es)
    defer entities_destroy(&es)
    names:Table(Name)
    table_init(&names,"Name")
    defer table_destroy(&names)
    a,b,c:=create(&es),create(&es),create(&es)
    add(&names,a,name_make("a"));add(&names,b,name_make("b"));add(&names,c,name_make("c"))
    testing.expect(t,table_settle(&names,&es))

    // Reading a table received to write stamps nothing, by entity or by row.
    seen:=names.version
    looked:Seen;shape:Shape
    testing.expect(t,touched(&names,&looked) && reshaped(&names,&shape))
    value,found:=get(&names,a)
    _,missing:=get(&names,NONE)
    testing.expect(t,found && !missing && value==at(&names,0) && has(&names,b) && row_of(&names,c)==2 && name_get(read(&names),a)=="a")
    testing.expect_value(t,names.version,seen)
    testing.expect(t,!touched(&names,&looked) && !reshaped(&names,&shape))

    // A value that differs is written; the one the row has is not.
    Case :: struct {entity:Entity,value:string,written:bool}
    for c in ([?]Case{{b,"b",false},{b,"d",true},{b,"d",false},{NONE,"x",false}}) {
        before:=names.version
        testing.expect_value(t,set(&names,c.entity,name_make(c.value)),c.written)
        testing.expect_value(t,names.version>before,c.written)
        testing.expect_value(t,touched(&names,&looked),c.written)
    }
    testing.expect(t,!set_at(&names,0,at(&names,0)) && names.version==looked.version)
    testing.expect(t,stamp(&names,row_of(&names,a))<=seen)
    testing.expect(t,stamp(&names,row_of(&names,b))>seen)
    testing.expect(t,edit(&names,NONE)==nil && !reshaped(&names,&shape))

    // A row that takes the place of one removed keeps its stamp.
    written:=stamp(&names,row_of(&names,b))
    remove(&names,a)
    table_settle(&names,&es)
    testing.expect(t,reshaped(&names,&shape) && touched(&names,&looked))
    testing.expect_value(t,row_of(&names,c),0)
    testing.expect(t,stamp(&names,0)<=seen)
    testing.expect_value(t,stamp(&names,row_of(&names,b)),written)

    // An add over a row writes it.
    seen=names.version
    add(&names,c,name_make("e"))
    testing.expect(t,!table_settle(&names,&es))
    testing.expect(t,stamp(&names,row_of(&names,c))>seen && names.version>seen)
    testing.expect(t,touched(&names,&looked) && !reshaped(&names,&shape))

    // Copied over, a table only grows its version and layout.
    other:Table(Name)
    table_init(&other,"Name")
    defer table_destroy(&other)
    other.version,other.layout=1000,1000
    table_copy(&other,&names)
    testing.expect(t,other.version>1000 && other.layout>1000)
    for row in 0..<count(&other) {testing.expect(t,stamp(&other,row)<=other.version)}
}

// What each_changed goes through is what a walk of every stamp finds, and no
// page is below a stamp of its rows, whatever wrote, moved or took the rows.
@(test)
a_reader_goes_through_the_rows_changed_and_skips_the_pages_written_before :: proc(t:^testing.T) {
    Probe :: struct {value:u32}
    ROWS :: 5*STAMP_PAGE+17
    es:Entities
    entities_init(&es)
    defer entities_destroy(&es)
    table,copied:Table(Probe)
    table_init(&table,"Probe");table_init(&copied,"Probe")
    defer {table_destroy(&table);table_destroy(&copied)}
    all:=make([dynamic]Entity);defer delete(all)
    for i in 0..<ROWS {
        append(&all,create(&es))
        add(&table,all[i],Probe{u32(i)})
    }
    testing.expect(t,table_settle(&table,&es))
    entities_settle(&es)

    // The rows a reader is given, against those a walk of every stamp finds since it looked.
    same :: proc(t:^testing.T,table:^Table(Probe),seen:^Seen,off:=false,loc:=#caller_location) -> (rows:int) {
        raw_table:=raw(table)
        testing.expect_value(t,len(table.page_stamps),stamp_pages(len(table.stamps)),loc)
        for stamp,row in table.stamps {
            if !testing.expect(t,table.page_stamps[row>>STAMP_PAGE_BITS]>=stamp,loc=loc) {return}
        }
        since:=seen.version
        c:=raw_changes(raw_table,seen,off)
        limit:=off?len(table.stamps):table.on
        expected:=0
        for row,ok:=raw_each_changed(raw_table,&c);ok;row,ok=raw_each_changed(raw_table,&c) {
            for expected<limit && !(c.all || table.stamps[expected]>since) {expected+=1}
            if !testing.expect_value(t,row,expected,loc) {return}
            testing.expect(t,changed(table,c,row),loc=loc)
            expected+=1
            rows+=1
        }
        for expected<limit && !(c.all || table.stamps[expected]>since) {expected+=1}
        testing.expect_value(t,expected,limit,loc)
        return
    }
    seen:Seen
    testing.expect_value(t,same(t,&table,&seen),ROWS)
    testing.expect_value(t,same(t,&table,&seen),0)

    // One row in a page, the last row, a page whole, and nothing.
    edit_at(&table,STAMP_PAGE+3).value=1
    testing.expect_value(t,same(t,&table,&seen),1)
    edit_at(&table,ROWS-1).value=1
    edit(&table,all[0]).value=1
    testing.expect_value(t,same(t,&table,&seen),2)
    for row in 2*STAMP_PAGE..<3*STAMP_PAGE {set_at(&table,row,Probe{9})}
    testing.expect_value(t,same(t,&table,&seen),STAMP_PAGE)
    for row in 2*STAMP_PAGE..<3*STAMP_PAGE {set_at(&table,row,Probe{9})}
    _,_=get(&table,all[7]);_=at(&table,7)
    testing.expect_value(t,same(t,&table,&seen),0)
    for &value in writable(&table) {value.value+=1}
    testing.expect_value(t,same(t,&table,&seen),ROWS)

    // Rows written, taken, turned off and added in any order: the stamps move with their rows.
    state:=u64(t.seed)|1
    next :: proc(state:^u64,below:int) -> int {
        state^=state^*6364136223846793005+1442695040888963407
        return int((state^>>33)%u64(below))
    }
    for round in 0..<200 {
        for _ in 0..<next(&state,6) {
            e:=all[next(&state,len(all))]
            switch next(&state,6) {
            case 0: remove(&table,e)
            case 1: disable(&table,e)
            case 2: enable(&table,e)
            case 3: add(&table,e,Probe{u32(round)})
            case 4: if row:=row_of(&table,e);row>=0 {edit_at(&table,row).value+=1}
            case 5: set(&table,e,Probe{u32(round%3)})
            }
        }
        if round%40==39 {
            e:=create(&es)
            append(&all,e)
            add(&table,e,Probe{})
        }
        table_settle(&table,&es)
        entities_settle(&es)
        same(t,&table,&seen,round%2==0)
        if round%50==49 {
            testing.expect(t,table_copy(&copied,&table))
            other:Seen
            same(t,&copied,&other,true)
            table_swap(&copied,&table)
            same(t,&table,&seen)
            same(t,&copied,&other)
        }
    }
    // A copy of what changed leaves the pages of the rows it copied as theirs.
    mark:Copy_Mark
    testing.expect(t,table_copy(&copied,&table) && table_copy_changed(&copied,&table,&mark))
    edit_at(&table,1).value+=1
    testing.expect(t,table_copy_changed(&copied,&table,&mark))
    for stamp,page in table.page_stamps {testing.expect_value(t,copied.page_stamps[page],stamp)}
}

@(test)
transforms_compute_what_was_written_and_what_hangs_from_it :: proc(t:^testing.T) {
    es:Entities
    entities_init(&es)
    defer entities_destroy(&es)
    locals:Table(Transform)
    parents:Table(Parent)
    worlds:Table(World_Transform)
    table_init(&locals,"Transform");table_init(&parents,"Parent");table_init(&worlds,"World_Transform")
    defer {table_destroy(&locals);table_destroy(&parents);table_destroy(&worlds)}
    h:Hierarchy
    defer value_free(&h,type_info_of(Hierarchy))
    p:Propagation
    defer value_free(&p,type_info_of(Propagation))
    pass :: proc(locals:^Table(Transform),parents:^Table(Parent),worlds:^Table(World_Transform),h:^Hierarchy,p:^Propagation,es:^Entities,tick:bool) {
        hierarchy_settle(h,read(parents),es)
        transforms_compute(read(locals),ref(h),worlds,p,tick)
        table_settle(worlds,es)
    }
    at :: proc(worlds:^Table(World_Transform),e:Entity) -> World_Transform {
        value,_:=get(read(worlds),e)
        return value
    }

    root,child,other:=create(&es),create(&es),create(&es)
    add(&locals,root,Transform{{1,0,0},1,{1,1,1}})
    add(&locals,child,Transform{{0,1,0},1,{1,1,1}})
    add(&locals,other,Transform{{5,0,0},1,{1,1,1}})
    add(&parents,child,Parent{root,0})
    table_settle(&locals,&es);table_settle(&parents,&es)
    pass(&locals,&parents,&worlds,&h,&p,&es,true)
    testing.expect_value(t,at(&worlds,child).position,[3]f32{1,1,0})

    seen:=version(&worlds)
    pass(&locals,&parents,&worlds,&h,&p,&es,true)
    testing.expect_value(t,version(&worlds),seen)

    edit(&locals,root).position={2,0,0}
    pass(&locals,&parents,&worlds,&h,&p,&es,false)
    testing.expect_value(t,at(&worlds,child).position,[3]f32{2,1,0})
    testing.expect_value(t,at(&worlds,child).previous.position,[3]f32{1,1,0})
    testing.expect(t,stamp(&worlds,row_of(&worlds,other))<=seen)

    // The next tick without writes stops what moved between two places.
    pass(&locals,&parents,&worlds,&h,&p,&es,true)
    testing.expect_value(t,at(&worlds,child).previous.position,[3]f32{2,1,0})
    testing.expect_value(t,at(&worlds,root).previous.position,[3]f32{2,0,0})
    seen=version(&worlds)
    pass(&locals,&parents,&worlds,&h,&p,&es,true)
    testing.expect_value(t,version(&worlds),seen)

    // A new parent orders them again.
    add(&parents,other,Parent{child,0})
    table_settle(&parents,&es)
    pass(&locals,&parents,&worlds,&h,&p,&es,true)
    testing.expect_value(t,at(&worlds,other).position,[3]f32{7,1,0})
}

@(test)
rows_of_a_component_without_fields_are_found_by_reflection :: proc(t:^testing.T) {
    Tag :: struct {}
    es:Entities
    entities_init(&es)
    defer entities_destroy(&es)
    tags:Table(Tag)
    table_init(&tags,"Tag")
    defer table_destroy(&tags)
    e:=create(&es)
    add(&tags,e,Tag{})
    table_settle(&tags,&es)
    info:^runtime.Type_Info=type_info_of(Tag)
    testing.expect(t,raw_find(raw(&tags),info,e)!=nil)
    testing.expect(t,raw_find(raw(&tags),info,create(&es))==nil)
}

@(test)
reflected_immediate_removal_moves_the_last_row_releases_locks_and_never_allocates :: proc(t:^testing.T) {
    es:Entities;entities_init(&es);defer entities_destroy(&es)
    names:Table(Name);table_init(&names,"Name");defer table_destroy(&names)
    a,b,c:=create(&es),create(&es),create(&es)
    owner:Table(u8);table_init(&owner,"Transform");defer table_destroy(&owner)
    resize(&owner.owners,len(es.generation))
    owners:=&owner.owners
    locks:=[1]Lock{{offset=lock_offset(&names,&owner),id=1,target="Transform",names={"","Test owner"}}}
    names.locks=locks[:]
    add(&names,a,name_make("a"));add(&names,b,name_make("b"));add(&names,c,name_make("c"))
    unowned:=owner.version
    table_settle(&names,&es)
    testing.expect(t,owner.version>unowned,"who owns its rows is part of what a table holds: a copy of what changed takes it")
    owned:=owner.version
    prior_version,prior_layout,last_stamp:=names.version,names.layout,names.stamps[2]
    tracker:mem.Tracking_Allocator
    mem.tracking_allocator_init(&tracker,context.allocator);defer mem.tracking_allocator_destroy(&tracker)
    removed:=false
    {
        context.allocator=mem.tracking_allocator(&tracker)
        removed=raw_drop(raw(&names),type_info_of(Name),b)
    }
    testing.expect(t,removed && !has(&names,b) && row_of(&names,c)==1)
    testing.expect_value(t,tracker.total_allocation_count,i64(0))
    testing.expect_value(t,names.stamps[1],last_stamp)
    testing.expect(t,names.version>prior_version && names.layout>prior_layout)
    testing.expect_value(t,owners[entity_index(b)],Row_Owner{})
    testing.expect_value(t,owners[entity_index(c)].id,u16(1))
    testing.expect(t,owner.version>owned)
    testing.expect(t,!raw_drop(raw(&names),type_info_of(Name),b))
    testing.expect(t,!raw_drop(nil,type_info_of(Name),a) && !raw_drop(raw(&names),nil,a) && !raw_drop(raw(&names),type_info_of(Name),NONE))
    remove(&names,a)
    add(&names,c,name_make("new c"))
    testing.expect(t,raw_drop(raw(&names),type_info_of(Name),c))
    table_settle(&names,&es)
    testing.expect_value(t,count(&names),1)
    testing.expect_value(t,owners[entity_index(a)],Row_Owner{})
    testing.expect_value(t,name_get(read(&names),c),"new c")
}

@(test)
a_row_put_back_at_once_takes_its_place_its_lock_and_no_memory :: proc(t:^testing.T) {
    es:Entities;entities_init(&es);defer entities_destroy(&es)
    names:Table(Name);table_init(&names,"Name");defer table_destroy(&names)
    owner:Table(u8);table_init(&owner,"Transform");defer table_destroy(&owner)
    a,b,c:=create(&es),create(&es),create(&es)
    resize(&owner.owners,len(es.generation))
    locks:=[1]Lock{{offset=lock_offset(&names,&owner),id=1,target="Transform",names={"","Test owner"}}}
    names.locks=locks[:]
    add(&names,a,name_make("a"));add(&names,b,name_make("b"));add(&names,c,name_make("c"))
    table_settle(&names,&es)
    disable(&names,c)
    table_settle(&names,&es)
    value:=name_make("b")
    testing.expect(t,raw_drop(raw(&names),type_info_of(Name),b))
    seen:Seen
    _=changes(&names,&seen)
    tracker:mem.Tracking_Allocator
    mem.tracking_allocator_init(&tracker,context.allocator);defer mem.tracking_allocator_destroy(&tracker)
    put,again:bool
    {
        context.allocator=mem.tracking_allocator(&tracker)
        put=raw_put(raw(&names),type_info_of(Name),&es,b,&value,false)
        again=raw_put(raw(&names),type_info_of(Name),&es,b,&value,false)
    }
    testing.expect(t,put && !again)
    testing.expect_value(t,tracker.total_allocation_count,i64(0))
    testing.expect(t,has(&names,b) && name_get(read(&names),b)=="b" && count(&names)==2)
    testing.expect_value(t,owner.owners[entity_index(b)].id,u16(1))
    c1:=changes(&names,&seen)
    testing.expect(t,changed(&names,c1,row_of(&names,b)) && !changed(&names,c1,row_of(&names,a)))
    // Off by itself it waits among the rows off, without the lock; a row that
    // went while off is among the entities gone.
    testing.expect(t,raw_drop(raw(&names),type_info_of(Name),c))
    c2:=changes(&names,&seen)
    testing.expect(t,len(c2.gone)==1 && c2.gone[0]==c)
    testing.expect(t,raw_put(raw(&names),type_info_of(Name),&es,c,&value,true))
    on,turned_off,found:=raw_state(raw(&names),c)
    testing.expect(t,found && !on && turned_off && count(&names)==2)
    testing.expect_value(t,owner.owners[entity_index(c)],Row_Owner{})
    // Not for an entity gone, nor past the room of the table.
    destroy(&es,a)
    testing.expect(t,!raw_put(raw(&names),type_info_of(Name),&es,a,&value,false))
    shrink(&names.entities)
    d:=create(&es)
    testing.expect(t,!raw_put(raw(&names),type_info_of(Name),&es,d,&value,false))
}

// A single table keeps one row on: the one turned on last. Turning one on
// turns off the one that was on, which keeps its value and comes back when
// the one on goes off or away, in the order they were turned on. One added
// while another is on comes off and is on only once turned on; with none on,
// the first one added is on.
@(test)
a_single_table_keeps_on_the_row_turned_on_last :: proc(t:^testing.T) {
    es:Entities
    entities_init(&es);defer entities_destroy(&es)
    table:Table(i32)
    table_init(&table,"Sky");defer table_destroy(&table)
    table.single=true
    on :: proc(table:^Table(i32)) -> Entity {return count(table)==1?entity_at(read(table),0):NONE}
    a,b,c:=create(&es),create(&es),create(&es)
    add(&table,a,1)
    add(&table,b,2)
    table_settle(&table,&es)
    testing.expect_value(t,on(&table),a)
    _,off,_:=raw_state(raw(&table),b)
    testing.expect(t,off,"what comes while one is on comes off")

    enable(&table,b)
    table_settle(&table,&es)
    testing.expect_value(t,on(&table),b)
    testing.expect_value(t,table.values[rows_at(raw(&table),entity_index(a))-1],1)
    disable(&table,b)
    table_settle(&table,&es)
    testing.expect(t,on(&table)==a,"turning off the one on turns on the one before")

    add(&table,c,3)
    enable(&table,b)
    table_settle(&table,&es)
    testing.expect_value(t,on(&table),b)
    remove(&table,b)
    table_settle(&table,&es)
    testing.expect(t,on(&table)==a,"c was never turned on: it does not come back")
    disable(&table,a)
    table_settle(&table,&es)
    testing.expect_value(t,count(&table),0)
    enable(&table,c)
    table_settle(&table,&es)
    testing.expect_value(t,on(&table),c)

    // One added while the one on goes away in the same function is not on.
    d:=create(&es)
    add(&table,d,4)
    remove(&table,c)
    table_settle(&table,&es)
    testing.expect_value(t,count(&table),0)
    destroy(&es,d)
    table_settle(&table,&es)
    entities_settle(&es)
    e:=create(&es)
    add(&table,e,5)
    table_settle(&table,&es)
    testing.expect_value(t,on(&table),e)
}

// Nothing of a single table is searched while nothing changed, and a table
// that is not single has no turns.
@(test)
a_settle_without_changes_leaves_a_single_table_as_it_was :: proc(t:^testing.T) {
    es:Entities
    entities_init(&es);defer entities_destroy(&es)
    skies,plain:Table(i32)
    table_init(&skies,"Sky");defer table_destroy(&skies)
    table_init(&plain,"Plain");defer table_destroy(&plain)
    skies.single=true
    a,b:=create(&es),create(&es)
    add(&skies,a,1);add(&skies,b,2);add(&plain,a,1);add(&plain,b,2)
    table_settle(&skies,&es);table_settle(&plain,&es)
    testing.expect_value(t,count(&plain),2)
    testing.expect_value(t,len(plain.turns),0)
    version,shape:=skies.version,skies.layout
    testing.expect(t,!table_settle(&skies,&es))
    testing.expect(t,skies.version==version && skies.layout==shape)
    // Turning on the one that is on changes nothing.
    enable(&skies,a)
    table_settle(&skies,&es)
    testing.expect(t,skies.layout==shape && entity_at(read(&skies),0)==a)
}

// What a function asked waits for the settle: staged_has answers as has will after it.
@(test)
staged_has_says_what_has_will_say_when_the_function_ends :: proc(t:^testing.T) {
    es:Entities
    entities_init(&es)
    defer entities_destroy(&es)
    marks:Table(Name)
    table_init(&marks,"Name")
    defer table_destroy(&marks)
    kept,gone,turned,fresh:=create(&es),create(&es),create(&es),create(&es)
    add(&marks,kept,{});add(&marks,gone,{});add(&marks,turned,{})
    table_settle(&marks,&es)

    remove(&marks,gone)
    set_on(&marks,turned,false)
    add(&marks,fresh,{})
    testing.expect(t,staged_has(&marks,kept) && !staged_has(&marks,gone) && !staged_has(&marks,turned) && staged_has(&marks,fresh))
    testing.expect(t,has(&marks,gone) && has(&marks,turned) && !has(&marks,fresh),"has keeps the rows of before the settle")
    table_settle(&marks,&es)
    testing.expect(t,has(&marks,kept) && !has(&marks,gone) && !has(&marks,turned) && has(&marks,fresh))

    set_on(&marks,turned,true)
    testing.expect(t,staged_has(&marks,turned) && !has(&marks,turned))
    set_on(&marks,turned,false)
    testing.expect(t,!staged_has(&marks,turned),"the last turn counts")
}

@(test)
first_sole_and_entity_named_find_the_entity_a_function_asks_for :: proc(t:^testing.T) {
    es:Entities
    entities_init(&es)
    defer entities_destroy(&es)
    names:Table(Name)
    table_init(&names,"Name")
    defer table_destroy(&names)
    _,any:=first(&names)
    _,one:=sole(read(&names))
    testing.expect(t,!any && !one && entity_named(read(&names),"lift")==NONE)

    a,b:=create(&es),create(&es)
    add(&names,a,name_make("lift"))
    table_settle(&names,&es)
    e,found:=sole(&names)
    testing.expect(t,found && e==a)

    add(&names,b,name_make("door"))
    table_settle(&names,&es)
    e,found=first(read(&names))
    testing.expect(t,found && e==a)
    _,found=sole(&names)
    testing.expect(t,!found,"sole is the only one")
    testing.expect_value(t,entity_named(read(&names),"door"),b)
}

@(test)
a_component_added_without_a_value_is_zeroed_whatever_its_size :: proc(t:^testing.T) {
    Empty :: struct {}
    Small :: struct {value:u64}
    Large :: struct {bytes:[8192]u8,tail:u64}
    check :: proc(t:^testing.T,$T:typeid,name:string) {
        es:Entities
        entities_init(&es)
        defer entities_destroy(&es)
        table:Table(T)
        table_init(&table,name)
        defer table_destroy(&table)
        info:=type_info_of(T)
        // The memory the adds wait in holds what the last ones left.
        filled:T
        mem.set(&filled,0xff,size_of(T))
        first,second:=create(&es),create(&es)
        raw_add(raw(&table),info,first,&filled)
        testing.expect(t,table_settle(&table,&es))
        raw_add(raw(&table),info,second,nil)
        testing.expectf(t,table_settle(&table,&es) && has(&table,second),"%s: added",name)
        if size_of(T)==0 {return}
        zero:T
        testing.expectf(t,mem.compare_ptrs(raw_edit(raw(&table),info,second),&zero,size_of(T))==0,"%s: zeroed",name)
        testing.expectf(t,mem.compare_ptrs(raw_edit(raw(&table),info,first),&filled,size_of(T))==0,"%s: the value given stays",name)
    }
    check(t,Empty,"Empty")
    check(t,Small,"Small")
    check(t,Large,"Large")
}

// The rows by entity of a table come in pages made for the entities it has
// rows of: an entity far from the others costs a page, not room for every
// entity before it. A copy brings every row and forgets those it had, and
// the room of the entities gone is made when the first one goes.
@(test)
a_table_holds_rows_by_entity_only_where_it_has_rows :: proc(t:^testing.T) {
    es:Entities
    entities_init(&es);defer entities_destroy(&es)
    names,copied:Table(i32)
    table_init(&names,"Name");defer table_destroy(&names)
    table_init(&copied,"Name");defer table_destroy(&copied)
    near:=create(&es)
    far:Entity
    for _ in 0..<5*ROWS_PAGE {far=create(&es)}
    add(&names,near,1);add(&names,far,2)
    table_settle(&names,&es)
    pages:=0
    for page in names.rows {if len(page)>0 {pages+=1}}
    testing.expect_value(t,pages,2)
    testing.expect(t,cap(names.gone)==0,"no entity went: there is no room for them yet")
    value,found:=get(read(&names),far)
    testing.expect(t,found && value==2 && !has(&names,entity_make(2*ROWS_PAGE,1)))
    testing.expect(t,table_copy(&copied,&names))
    value,found=get(read(&copied),far)
    testing.expect(t,found && value==2 && has(&copied,near))
    // A table a storage holds is copied and freed as any value is.
    held:Table(i32)
    testing.expect(t,value_copy(&held,&names,type_info_of(Table(i32))))
    value,found=get(read(&held),far)
    testing.expect(t,found && value==2 && raw_data(held.rows[0])!=raw_data(names.rows[0]))
    value_free(&held,type_info_of(Table(i32)))
    seen:Seen
    _=changes(&names,&seen)
    remove(&names,far)
    table_settle(&names,&es)
    c:=changes(&names,&seen)
    testing.expect(t,!has(&names,far) && has(&names,near) && !c.all && len(c.gone)==1 && c.gone[0]==far)
    testing.expect(t,table_copy(&copied,&names))
    testing.expect(t,!has(&copied,far) && has(&copied,near) && raw_row(raw(&copied),far)<0)
}
