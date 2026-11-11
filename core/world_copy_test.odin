package core

import "base:runtime"
import "core:mem"
import "core:slice"
import "core:testing"

@(private)
Copy_Allocation :: struct {owner:runtime.Allocator,remaining:int,requests:int}

@(private)
copy_allocator :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
    state:=cast(^Copy_Allocation)data
    if size>0 && (mode==.Alloc || mode==.Alloc_Non_Zeroed || mode==.Resize || mode==.Resize_Non_Zeroed) {
        state.requests+=1
        if state.remaining==0 {return nil,.Out_Of_Memory}
        state.remaining-=1
    }
    return state.owner.procedure(state.owner.data,mode,size,alignment,old_memory,old_size,loc)
}

@(private) Copy_Index :: enum {A,B}
@(private) Copy_Item :: struct {slice:[]i32,items:[dynamic]i32}
@(private) Copy_Value :: struct {array:[Copy_Index]Copy_Item,items:[dynamic]Copy_Item,slice:[]Copy_Item}

@(test)
value_copy_survives_every_reservation_failure_without_sharing_owned_memory :: proc(t:^testing.T) {
    source:Copy_Value
    source.array[.A].slice=make([]i32,2);source.array[.A].slice[0]=11
    append(&source.array[.B].items,12)
    resize(&source.items,2);source.items[0].slice=make([]i32,3);source.items[0].slice[1]=21
    append(&source.items[1].items,22)
    source.slice=make([]Copy_Item,2);source.slice[0].slice=make([]i32,4);source.slice[0].slice[2]=31
    append(&source.slice[1].items,32)
    defer value_free(&source,type_info_of(Copy_Value))
    succeeded:=false
    for budget in 0..<16 {
        tracking:mem.Tracking_Allocator
        mem.tracking_allocator_init(&tracking,context.allocator)
        allocation:=Copy_Allocation{owner=mem.tracking_allocator(&tracking),remaining=budget}
        saved:=context
        context.allocator={copy_allocator,&allocation}
        target:Copy_Value
        // Empty destination arrays belong to the destination allocator.
        target.array[.B].items=make([dynamic]i32)
        target.items=make([dynamic]Copy_Item)
        ok:=value_copy(&target,&source,type_info_of(Copy_Value))
        if ok {
            succeeded=true
            testing.expect_value(t,target.array[.A].slice[0],i32(11))
            testing.expect_value(t,target.items[0].slice[1],i32(21))
            testing.expect_value(t,target.slice[0].slice[2],i32(31))
            testing.expect(t,raw_data(target.array[.A].slice)!=raw_data(source.array[.A].slice))
            target.items[0].slice[1]=99
            testing.expect_value(t,source.items[0].slice[1],i32(21))
            // Restore content, then forbid every allocation on a warm copy.
            allocation.remaining=0
            requests:=allocation.requests
            testing.expect(t,value_copy(&target,&source,type_info_of(Copy_Value)))
            testing.expect_value(t,allocation.requests,requests)
        }
        value_free(&target,type_info_of(Copy_Value))
        context=saved
        testing.expect_value(t,len(tracking.allocation_map),0)
        testing.expect_value(t,len(tracking.bad_free_array),0)
        mem.tracking_allocator_destroy(&tracking)
        testing.expect_value(t,source.array[.A].slice[0],i32(11))
        if ok {break}
    }
    testing.expect(t,succeeded)
}

@(test)
value_copy_shrink_releases_nested_ownership_and_reuses_remaining_elements :: proc(t:^testing.T) {
    tracking:mem.Tracking_Allocator
    mem.tracking_allocator_init(&tracking,context.allocator)
    defer mem.tracking_allocator_destroy(&tracking)
    saved:=context
    context.allocator=mem.tracking_allocator(&tracking)
    defer {context=saved}
    source,target:Copy_Value
    source.items=make([dynamic]Copy_Item,1)
    append(&source.items[0].items,7)
    source.slice=make([]Copy_Item,1);source.slice[0].slice=make([]i32,1)
    target.items=make([dynamic]Copy_Item,3)
    target.slice=make([]Copy_Item,3)
    for &item in target.items {item.slice=make([]i32,2);append(&item.items,1)}
    for &item in target.slice {item.slice=make([]i32,2);append(&item.items,1)}
    testing.expect(t,value_copy(&target,&source,type_info_of(Copy_Value)))
    testing.expect_value(t,len(target.items),1)
    testing.expect_value(t,target.items[0].items[0],i32(7))
    testing.expect_value(t,len(target.slice),1)
    empty:Copy_Value
    testing.expect(t,value_copy(&target,&empty,type_info_of(Copy_Value)))
    value_free(&target,type_info_of(Copy_Value))
    value_free(&source,type_info_of(Copy_Value))
    testing.expect_value(t,len(tracking.allocation_map),0)
}

@(test)
table_swap_keeps_lock_addresses_and_invalidates_readers_without_allocating :: proc(t:^testing.T) {
    a,b:Table(i32)
    table_init(&a,"a");table_init(&b,"b")
    defer table_destroy(&a);defer table_destroy(&b)
    es:Entities;testing.expect(t,entities_init(&es));defer entities_destroy(&es)
    entity:=create(&es)
    add(&a,entity,10);table_settle(&a,&es)
    add(&b,entity,20);table_settle(&b,&es)
    locks_a:=[1]Lock{{offset=0,id=1}}
    locks_b:=[1]Lock{{offset=0,id=2}}
    a.locks,b.locks=locks_a[:],locks_b[:]
    a.version,a.layout=900,800
    saved:=context
    context.allocator=runtime.nil_allocator()
    table_swap(&a,&b)
    context=saved
    testing.expect_value(t,a.values[0],i32(20))
    testing.expect_value(t,b.values[0],i32(10))
    testing.expect(t,lock_owners(raw(&a),a.locks[0])==&a.owners && lock_owners(raw(&b),b.locks[0])==&b.owners)
    testing.expect(t,a.version>900 && a.layout>800 && b.version==a.version && b.layout==a.layout)
    testing.expect_value(t,a.name,"a")
    testing.expect_value(t,b.name,"b")
}

@(test)
entity_initialization_and_each_table_copy_reservation_fail_without_invalid_ownership :: proc(t:^testing.T) {
    empty:Entities
    testing.expect(t,!entities_init(&empty,mem.nil_allocator()))
    entities_destroy(&empty)
    source:Table(i32);table_init(&source,"source");defer table_destroy(&source)
    entities:Entities;testing.expect(t,entities_init(&entities));defer entities_destroy(&entities)
    e:=create(&entities);add(&source,e,44);table_settle(&source,&entities)
    resize(&source.owners,2);source.owners[1]={entity_generation(e),3}
    succeeded:=false
    for budget in 0..<16 {
        tracking:mem.Tracking_Allocator
        mem.tracking_allocator_init(&tracking,context.allocator)
        allocation:=Copy_Allocation{owner=mem.tracking_allocator(&tracking),remaining=budget}
        target:Table(i32);table_init(&target,"target",{copy_allocator,&allocation})
        ok:=table_copy(&target,&source)
        if ok {
            succeeded=true
            testing.expect_value(t,target.values[0],i32(44))
            testing.expect_value(t,target.owners[1],Row_Owner{entity_generation(e),3})
        }
        table_destroy(&target)
        testing.expect_value(t,len(tracking.allocation_map),0)
        mem.tracking_allocator_destroy(&tracking)
        testing.expect_value(t,source.values[0],i32(44))
        if ok {break}
    }
    testing.expect(t,succeeded)
}

@(test)
value_copy_preserves_zero_sized_owned_container_lengths_without_allocating :: proc(t:^testing.T) {
    Empty :: struct {}
    source_slice:=make([]Empty,3)
    source_array:=make([dynamic]Empty,4)
    target_slice:[]Empty
    target_array:[dynamic]Empty
    saved:=context
    context.allocator=mem.nil_allocator()
    testing.expect(t,value_copy(&target_slice,&source_slice,type_info_of([]Empty)))
    testing.expect(t,value_copy(&target_array,&source_array,type_info_of([dynamic]Empty)))
    context=saved
    testing.expect_value(t,len(target_slice),3)
    testing.expect_value(t,len(target_array),4)
    value_free(&source_slice,type_info_of([]Empty));value_free(&source_array,type_info_of([dynamic]Empty))
    value_free(&target_slice,type_info_of([]Empty));value_free(&target_array,type_info_of([dynamic]Empty))
}

@(private) Copy_Row :: struct {value:f32,items:[dynamic]i32}

@(private)
copy_rows_equal :: proc(a,b:^Table(Copy_Row)) -> bool {
    if a.on!=b.on || len(a.entities)!=len(b.entities) {return false}
    for e,row in a.entities {
        if b.entities[row]!=e || b.stamps[row]!=a.stamps[row] || b.off[row]!=a.off[row] || b.values[row].value!=a.values[row].value {return false}
        if len(a.values[row].items)!=len(b.values[row].items) {return false}
        if len(a.values[row].items)>0 && raw_data(a.values[row].items)==raw_data(b.values[row].items) {return false}
        for item,i in a.values[row].items {if b.values[row].items[i]!=item {return false}}
        if row<a.on && row_of(b,e)!=row {return false}
    }
    return true
}

@(test)
a_copy_of_what_changed_equals_a_whole_copy_after_writes_layout_changes_and_a_swap :: proc(t:^testing.T) {
    es:Entities
    testing.expect(t,entities_init(&es))
    defer entities_destroy(&es)
    source,copied,older:Table(Copy_Row)
    defer {
        for table in ([]^Table(Copy_Row){&source,&copied,&older}) {
            for &v in table.values {delete(v.items)}
            table_destroy(table)
        }
    }
    mark:Copy_Mark
    entities:[8]Entity
    for &e,i in entities {
        e=create(&es)
        row:=Copy_Row{value=f32(i)}
        append(&row.items,i32(i))
        add(&source,e,row)
    }
    table_settle(&source,&es);entities_settle(&es)
    testing.expect(t,table_copy_changed(&copied,&source,&mark) && mark.valid)
    testing.expect(t,copy_rows_equal(&source,&copied))
    // Unchanged: nothing is looked at, not even the rows of the copy.
    version:=copied.version
    testing.expect(t,table_copy_changed(&copied,&source,&mark))
    testing.expect_value(t,copied.version,version)
    testing.expect(t,table_copy(&older,&source))
    edit(&source,entities[3]).value=30
    append(&edit(&source,entities[5]).items,55)
    testing.expect(t,table_copy_changed(&copied,&source,&mark))
    testing.expect(t,copy_rows_equal(&source,&copied))
    delete(at(&source,row_of(&source,entities[1])).items)
    remove(&source,entities[1])
    disable(&source,entities[6])
    table_settle(&source,&es)
    testing.expect(t,table_copy_changed(&copied,&source,&mark))
    testing.expect(t,copy_rows_equal(&source,&copied))
    // A correction brings back an older copy: what the copy took since goes back too.
    table_swap(&source,&older)
    testing.expect(t,table_copy_changed(&copied,&source,&mark))
    testing.expect(t,copy_rows_equal(&source,&copied))
    edit(&source,entities[2]).value=20
    testing.expect(t,table_copy_changed(&copied,&source,&mark))
    testing.expect(t,copy_rows_equal(&source,&copied))
}

@(private) Rev_List :: struct {items:[dynamic]i32}
@(private) Rev_Count :: struct {value:i32}

@(private)
@(test_world)
Rev_World :: struct {
    using world:Test_World,
    disabled:Table(Disabled),
    parents:Table(Parent),
    hierarchy:Hierarchy,
    list:Rev_List,
    count:Rev_Count,
}

@(private="file") REV_TABLES :: 2

// A copy of what changed takes a storage again when a function received it
// to write, when code outside the loop asked for it, when the settle moved
// the Hierarchy or when the World was copied over, and no other: after each,
// the copy holds what a whole copy does. A function that reads a storage by
// change (core.Stamp, core.touched) is told by the same stamp, as of a table.
@(test)
a_copy_of_what_changed_takes_the_storages_written_and_equals_a_whole_copy :: proc(t:^testing.T) {
    info,described:=test_info(t,Rev_World)
    if !described {return}
    defer test_info_destroy(&info)
    w,kept,older,whole:Rev_World
    for world in ([]^Rev_World{&w,&kept,&older,&whole}) {testing.expect(t,world_init(&info,.World,world,context.allocator))}
    defer for world in ([]^Rev_World{&w,&kept,&older,&whole}) {world_destroy(&info,.World,world)}
    marks,older_marks:[REV_TABLES+3]Copy_Mark
    testing.expect_value(t,copy_marks_count(&info),len(marks))
    ref:=world_ref(&w,&info)
    root,child:=create(&w.entities),create(&w.entities)
    append(&w.list.items,1,2,3)
    settle(&info,&w,nil)
    testing.expect(t,world_copy_changed(&info,&kept,&w,marks[:]))
    Case :: struct {
        what:string,
        act:proc(w:^Rev_World,ref:World_Ref,root,child:Entity),
        copied:[3]bool, // Hierarchy, Rev_List, Rev_Count
    }
    cases:=[]Case{
        {"nothing was written",proc(w:^Rev_World,ref:World_Ref,root,child:Entity) {},{}},
        {"a storage was read where it is",proc(w:^Rev_World,ref:World_Ref,root,child:Entity) {_=w.count.value+i32(len(w.list.items))},{}},
        {"a function received a storage to write",proc(w:^Rev_World,ref:World_Ref,root,child:Entity) {
            w.storage_revisions[1]+=1 // as its call_ does before it runs
            append(&w.list.items,4)
        },{false,true,false}},
        {"code outside the loop asked for a storage",proc(w:^Rev_World,ref:World_Ref,root,child:Entity) {world_storage_of(ref,Rev_Count).value=7},{false,false,true}},
        {"it asked for it by its index",proc(w:^Rev_World,ref:World_Ref,root,child:Entity) {(cast(^Rev_List)world_storage_at(ref,1)).items[0]=9},{false,true,false}},
        {"a settle with nothing pending",proc(w:^Rev_World,ref:World_Ref,root,child:Entity) {settle(ref.info,w,nil)},{}},
        {"a settle that links an entity",proc(w:^Rev_World,ref:World_Ref,root,child:Entity) {
            add(&w.parents,child,Parent{root,0})
            settle(ref.info,w,nil)
        },{true,false,false}},
        {"the World was cleared",proc(w:^Rev_World,ref:World_Ref,root,child:Entity) {
            w.count.value=0
            revisions_moved(w.storage_revisions[:3])
        },{true,true,true}},
    }
    read:[3]Seen
    reads :: proc(w:^Rev_World,read:^[3]Seen) -> (changed:[3]bool) {
        for &seen,k in read {changed[k]=touched(Stamp(Rev_Count){&w.storage_revisions[k]},&seen)}
        return
    }
    testing.expect_value(t,reads(&w,&read),[3]bool{true,true,true})
    for c,at in cases {
        // Half way, another copy is kept as the World is: a correction goes back to it below.
        if at==4 {testing.expect(t,world_copy_changed(&info,&older,&w,older_marks[:]))}
        c.act(&w,ref,root,child)
        testing.expectf(t,reads(&w,&read)==c.copied,"%s: who reads the storages by change was told otherwise",c.what)
        before:=kept.storage_revisions
        testing.expect(t,world_copy_changed(&info,&kept,&w,marks[:]))
        for &storage,k in info.storages {
            testing.expectf(t,(kept.storage_revisions[k]!=before[k])==c.copied[k],"%s: %s was %s",c.what,storage.name,c.copied[k]?"not copied":"copied")
        }
        testing.expect(t,world_copy(&info,&whole,&w))
        for &storage in info.storages {
            testing.expectf(t,value_equal(rawptr(uintptr(&kept)+storage.offset),rawptr(uintptr(&whole)+storage.offset),storage.info),"%s: the copy of %s is not what a whole copy holds",c.what,storage.name)
        }
    }
    // A correction: the World is the older copy again. The copy it came from keeps its marks,
    // and the next copy into it takes nothing; the other takes what differs.
    testing.expect(t,world_copy(&info,&w,&older))
    testing.expect_value(t,reads(&w,&read),[3]bool{true,true,true})
    testing.expect(t,touched(Stamp(Rev_Count){},&read[0]),"a Stamp of no World always says it changed")
    copy_marks_follow(ref,older_marks[:],marks[:])
    copy_marks_follow(ref,older_marks[:],older_marks[:])
    before:=older.storage_revisions
    testing.expect(t,world_copy_changed(&info,&older,&w,older_marks[:]))
    testing.expect_value(t,older.storage_revisions,before)
    testing.expect(t,world_copy_changed(&info,&kept,&w,marks[:]) && world_copy(&info,&whole,&w))
    for &storage in info.storages {
        testing.expectf(t,value_equal(rawptr(uintptr(&kept)+storage.offset),rawptr(uintptr(&whole)+storage.offset),storage.info),"after a correction the copy of %s is not what a whole copy holds",storage.name)
    }
    // What the World writes after it is none of what the copies of before it hold.
    world_storage_of(ref,Rev_Count).value=3
    testing.expect(t,world_copy_changed(&info,&older,&w,older_marks[:]))
    testing.expect_value(t,older.count.value,i32(3))
    // Two Worlds swapped are both others.
    swapped:=[2]type_of(w.storage_revisions){w.storage_revisions,kept.storage_revisions}
    revisions_swapped(w.storage_revisions[:3],kept.storage_revisions[:3])
    for k in 0..<3 {testing.expect(t,w.storage_revisions[k]>max(swapped[0][k],swapped[1][k]) && kept.storage_revisions[k]==w.storage_revisions[k])}
    // A World made by hand has no revisions: asking for a storage moves none.
    plain:=info
    plain.revisions=0
    revisions:=w.storage_revisions
    world_storage_of(world_ref(&w,&plain),Rev_Count).value=1
    testing.expect(t,w.storage_revisions==revisions && world_revisions(world_ref(&w,&plain))==nil)
}

@(private) Roll_Value :: struct {x:f32,n:u32}
@(private) Roll_Ref :: struct {at:^u32,n:u32} // a pointer: its table is restored by copy and swap
@(private) Roll_Log :: struct {log:Events(u32)}

@(private)
@(test_world)
Roll_World :: struct {
    using world:Test_World,
    disabled:Table(Disabled),
    parents:Table(Parent),
    values:Table(Roll_Value),
    refs:Table(Roll_Ref),
    hierarchy:Hierarchy,
    log:Roll_Log,
}

@(private="file") ROLL_FRAMES :: 6

// Whether a table holds what another does, row by row: entities, on and off,
// values and whether each row is added.
@(private="file")
roll_rows_equal :: proc(a,b:^Raw_Table,size:int) -> bool {
    if a.on!=b.on || len(a.stamps)!=len(b.stamps) || !slice.equal(a.entities[:],b.entities[:]) || !slice.equal(a.off[:],b.off[:]) {return false}
    for row in 0..<len(a.stamps) {
        if (a.stamps[row]~b.stamps[row])&1==1 {return false}
        if size>0 && mem.compare_ptrs(raw_at(a,size,row),raw_at(b,size,row),size)!=0 {return false}
    }
    return true
}

// A rollback brings the World back to a copy the history keeps, after random
// writes, creates, destroys, turns, reparents and events: the World is then
// what the copy holds, as a whole restore would leave it, and whether each
// row is added with it. A table of flat values that kept its rows gives its
// readers exactly the rows that differed, and one that did not, or whose
// values hold a pointer, is read whole. After several rollbacks in a row the
// history still copies only what changed.
@(test)
a_rollback_gives_the_readers_of_each_table_the_rows_it_brought_back :: proc(t:^testing.T) {
    info,described:=test_info(t,Roll_World)
    if !described {return}
    defer test_info_destroy(&info)
    w,stage:Roll_World
    frames:[ROLL_FRAMES]Roll_World
    marks:[ROLL_FRAMES][]Copy_Mark
    taken:[ROLL_FRAMES]int // the tick each frame holds, -1: none
    testing.expect(t,world_init(&info,.World,&w,context.allocator) && world_init(&info,.World,&stage,context.allocator))
    for &frame,k in frames {
        testing.expect(t,world_init(&info,.World,&frame,context.allocator))
        marks[k]=make([]Copy_Mark,copy_marks_count(&info))
        taken[k]=-1
    }
    defer {
        world_destroy(&info,.World,&w);world_destroy(&info,.World,&stage)
        for &frame,k in frames {world_destroy(&info,.World,&frame);delete(marks[k])}
    }
    ref:=world_ref(&w,&info)
    random:=t.seed|1
    next :: proc(random:^u64,n:int) -> int {
        random^~=random^<<13;random^~=random^>>7;random^~=random^<<17
        return int(random^%u64(n))
    }
    pointed:u32
    made:[dynamic]Entity
    defer delete(made)
    seen:=make([]Seen,len(info.tables))
    defer delete(seen)
    expected:=make([]int,len(info.tables)) // rows each reader sees after a rollback, -1: the whole table
    defer delete(expected)
    log:=-1
    for &s,k in info.storages {if s.info.id==Roll_Log {log=k}}
    rollbacks,read_whole,rows_back,added_back:=0,0,0,0
    tick:=0
    for step in 0..<400 {
        slot:=tick%ROLL_FRAMES
        testing.expect(t,world_copy_changed(&info,&frames[slot],&w,marks[slot]))
        taken[slot]=tick
        // A rollback to a tick still kept: one in five ticks, and several in a row now and then.
        if step%5==4 || step%37<3 && step>10 {
            back:=1+next(&random,ROLL_FRAMES-1)
            from:=(tick-back)%%ROLL_FRAMES
            if tick-back<0 || taken[from]!=tick-back {continue}
            src:=&frames[from]
            for &table,k in info.tables {
                live,kept:=world_table_at(ref,&table),world_table_at(world_ref(src,&info),&table)
                _=raw_changes(live,&seen[k])
                expected[k]=0
                mark:=marks[from][k]
                if mark.valid && mark.version==live.version && mark.layout==live.layout && len(live.pending)==0 {continue}
                if !table.flat || live.on!=kept.on || !slice.equal(live.entities[:],kept.entities[:]) || !slice.equal(live.off[:],kept.off[:]) || !slice.equal(live.owners[:],kept.owners[:]) {
                    expected[k]=-1
                    continue
                }
                size:=table.info.size
                for row in 0..<len(live.stamps) {
                    parity:=(live.stamps[row]~kept.stamps[row])&1==1
                    if parity || size>0 && mem.compare_ptrs(raw_at(live,size,row),raw_at(kept,size,row),size)!=0 {
                        expected[k]+=1
                        if parity {added_back+=1}
                    }
                }
            }
            ok,_:=world_restore(&info,&w,src,&stage,marks[from])
            testing.expect(t,ok)
            rollbacks+=1
            for &table,k in info.tables {
                live:=world_table_at(ref,&table)
                testing.expectf(t,roll_rows_equal(live,world_table_at(world_ref(src,&info),&table),table.info.size),"%s is not what the copy holds after a rollback",table.name)
                c:=raw_changes(live,&seen[k],true)
                rows:=0
                for _ in raw_each_changed(live,&c) {rows+=1}
                if expected[k]<0 {
                    testing.expectf(t,c.all,"%s did not keep its rows, and its readers are not told to read it whole",table.name)
                    read_whole+=1
                } else {
                    testing.expectf(t,!c.all && len(c.gone)==0 && rows==expected[k],"the readers of %s see %d rows, and %d went back",table.name,rows,expected[k])
                    rows_back+=rows
                }
            }
            for &s in info.storages {
                if s.place!=.World {continue}
                testing.expectf(t,value_equal(rawptr(uintptr(&w)+s.offset),rawptr(uintptr(src)+s.offset),s.info),"%s is not what the copy holds after a rollback",s.name)
            }
            for e in made {testing.expect(t,alive(&w.entities,e)==alive(&src.entities,e))}
            for &other,k in marks {if k!=from {copy_marks_follow(ref,marks[from],other)}}
            copy_marks_follow(ref,marks[from],marks[from])
            // The copy it came from holds what the World does: copying it again copies nothing.
            versions:=make([]u64,len(info.tables),context.temp_allocator)
            for &table,k in info.tables {versions[k]=world_table_at(world_ref(src,&info),&table).version}
            revisions:=src.storage_revisions
            testing.expect(t,world_copy_changed(&info,src,&w,marks[from]))
            for &table,k in info.tables {testing.expectf(t,world_table_at(world_ref(src,&info),&table).version==versions[k],"%s was copied again into the copy the World came from",table.name)}
            testing.expect(t,src.storage_revisions==revisions)
            tick-=back
            for &other in taken {if other>tick {other=-1}}
            continue
        }
        // What a tick does.
        for _ in 0..<1+next(&random,6) {
            switch next(&random,9) {
            case 0,1:
                e:=create(&w.entities)
                append(&made,e)
                add(&w.values,e,Roll_Value{f32(next(&random,100)),0})
                if next(&random,2)==0 {add(&w.refs,e,Roll_Ref{&pointed,1})}
            case 2:
                if count(&w.values)>0 {destroy(&w.entities,entity_at(&w.values,next(&random,count(&w.values))))}
            case 3,4:
                if count(&w.values)>0 {edit_at(&w.values,next(&random,count(&w.values))).x+=1}
            case 5:
                if count(&w.values)>0 {row:=next(&random,count(&w.values));edit_at(&w.values,row)^=at(&w.values,row)}
            case 6:
                if count(&w.values)>1 {
                    child,parent:=entity_at(&w.values,next(&random,count(&w.values))),entity_at(&w.values,next(&random,count(&w.values)))
                    if entity_index(parent)<entity_index(child) {add(&w.parents,child,Parent{parent,i32(next(&random,3))})}
                }
            case 7:
                if raw_count(raw(&w.values))>0 {
                    e:=w.values.entities[next(&random,raw_count(raw(&w.values)))]
                    set_on(&w.values,e,next(&random,2)==0)
                }
            case 8:
                w.storage_revisions[log]+=1
                push(&w.log.log,u32(tick))
            }
        }
        settle(&info,&w,nil)
        tick+=1
    }
    testing.expect(t,rollbacks>20 && read_whole>0 && rows_back>0 && added_back>0,"the sequence did not cover a rollback by rows, one read whole and one that brings back added rows")
}
