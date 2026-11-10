package host

import "core:mem"
import "core:testing"
import "mirai:core"

@(private) @(storage,copy=false) Replace_Local :: struct {mark:u32}
@(private) Replace_World :: struct {using world:core.Test_World,values:core.Table(u32),state:[dynamic]u32,local:Replace_Local}

@(test)
world_replacement_out_of_memory_keeps_the_destination_and_a_warm_one_does_not_allocate :: proc(t:^testing.T) {
    info,described:=core.test_info(t,Replace_World)
    if !described {return}
    defer core.test_info_destroy(&info)
    source:Replace_World
    if !testing.expect(t,core.world_init(&info,.World,&source,context.allocator)) {return}
    defer core.world_destroy(&info,.World,&source)
    for value in 0..<40 {
        e:=core.create(&source.entities)
        core.add(&source.values,e,u32(value))
        append(&source.state,u32(value*3))
    }
    core.table_settle(&source.values,&source.entities)
    succeeded,failed:=false,false
    for budget in 0..<32 {
        tracking:mem.Tracking_Allocator;mem.tracking_allocator_init(&tracking,context.allocator)
        allocation:=World_Create_Allocation{owner=mem.tracking_allocator(&tracking),remaining=-1}
        app:=App{info=&info,allocator={world_create_allocator,&allocation}}
        app.worlds=make([dynamic]World_Slot,app.allocator)
        live:=cast(^Replace_World)app_world_create(&app)
        if !testing.expect(t,live!=nil) {return}
        kept:=core.create(&live.entities)
        core.add(&live.values,kept,7);core.table_settle(&live.values,&live.entities)
        append(&live.state,9)
        live.local.mark=5
        values,state:=raw_data(live.values.values),raw_data(live.state)
        version:=core.version(&live.values)
        allocation.remaining=budget
        ok:=app_world_replace(&app,live,&source)
        allocation.remaining=-1
        if !ok {
            failed=true
            testing.expect(t,core.has(&live.values,kept) && core.count(&live.values)==1)
            testing.expect(t,raw_data(live.values.values)==values && raw_data(live.state)==state && len(live.state)==1)
            testing.expect_value(t,core.version(&live.values),version)
        } else {
            succeeded=true
            testing.expect_value(t,core.count(&live.values),40)
            testing.expect_value(t,len(live.state),40)
            testing.expect_value(t,live.state[39],u32(117))
            testing.expect(t,raw_data(live.state)!=raw_data(source.state))
            testing.expect(t,core.version(&live.values)>version)
            testing.expect_value(t,live.local.mark,u32(5))
            // The contents it traded are the room of the next ones: once both
            // sides fit the source, a replacement allocates nothing.
            testing.expect(t,app_world_replace(&app,live,&source))
            allocation.remaining=0
            saved:=context
            context.allocator=mem.nil_allocator()
            testing.expect(t,app_world_replace(&app,live,&source))
            context=saved
            testing.expect_value(t,core.count(&live.values),40)
        }
        app_world_free(&app,live)
        app_world_scratch_free(&app)
        delete(app.worlds)
        testing.expect_value(t,len(tracking.allocation_map),0)
        mem.tracking_allocator_destroy(&tracking)
        testing.expect_value(t,core.count(&source.values),40)
        if ok {break}
    }
    testing.expect(t,succeeded && failed)
}

@(private) Restore_Count :: struct {value:u32}
@(private) Restore_World :: struct {using world:core.Test_World,changed,still:core.Table(u32),list:[dynamic]u32,count:Restore_Count}

// A replacement with the marks of the copy it goes back to brings back only
// what the World changed since that copy: the rest stays where it is and its
// readers see nothing, and the copy needs nothing copied again. Without
// memory the World stays as it was.
@(test)
a_replacement_with_marks_brings_back_only_what_changed :: proc(t:^testing.T) {
    info,described:=core.test_info(t,Restore_World)
    if !described {return}
    defer core.test_info_destroy(&info)
    succeeded,failed:=false,false
    for budget in 0..<48 {
        tracking:mem.Tracking_Allocator;mem.tracking_allocator_init(&tracking,context.allocator)
        allocation:=World_Create_Allocation{owner=mem.tracking_allocator(&tracking),remaining=-1}
        app:=App{info=&info,allocator={world_create_allocator,&allocation}}
        app.worlds=make([dynamic]World_Slot,app.allocator)
        live,kept:=cast(^Restore_World)app_world_create(&app),cast(^Restore_World)app_world_create(&app)
        if !testing.expect(t,live!=nil && kept!=nil) {return}
        ref:=core.world_ref(live,&info)
        marks:=make([]core.Copy_Mark,core.copy_marks_count(&info),context.temp_allocator)
        entities:[4]core.Entity
        for &e,i in entities {
            e=core.create(&live.entities)
            core.add(&live.changed,e,u32(i));core.add(&live.still,e,u32(10+i))
        }
        core.settle(&info,live,nil)
        append(cast(^[dynamic]u32)core.world_storage_at(ref,0),1,2,3)
        testing.expect(t,core.world_copy_changed(&info,kept,live,marks))
        seen:core.Seen
        _=core.changes(&live.still,&seen)
        core.edit(&live.changed,entities[1])^=77
        extra:=core.create(&live.entities)
        core.add(&live.changed,extra,5)
        core.settle(&info,live,nil)
        (cast(^Restore_Count)core.world_storage_at(ref,1)).value=9
        changed_version,still_version,list:=core.version(&live.changed),core.version(&live.still),raw_data(live.list)
        allocation.remaining=budget
        ok:=app_world_replace(&app,live,kept,marks)
        allocation.remaining=-1
        if !ok {
            failed=true
            testing.expect(t,core.count(&live.changed)==5 && core.version(&live.changed)==changed_version && live.count.value==9 && core.alive(&live.entities,extra))
        } else {
            succeeded=true
            value,_:=core.get(&live.changed,entities[1])
            testing.expect(t,core.count(&live.changed)==4 && value==1 && live.count.value==0 && !core.alive(&live.entities,extra),"what changed since the copy is what the copy holds")
            c:=core.changes(&live.still,&seen)
            testing.expect(t,core.version(&live.still)==still_version && raw_data(live.list)==list && len(live.list)==3 && !c.all && len(c.gone)==0,"what did not change stays where it is, and its readers see no change")
            core.copy_marks_follow(ref,marks,marks)
            versions,revisions:=[2]u64{kept.changed.version,kept.still.version},kept.storage_revisions
            testing.expect(t,core.world_copy_changed(&info,kept,live,marks))
            testing.expect(t,kept.changed.version==versions[0] && kept.still.version==versions[1] && kept.storage_revisions==revisions,"the copy it came from needs nothing copied again")
        }
        app_world_free(&app,kept);app_world_free(&app,live)
        app_world_scratch_free(&app)
        delete(app.worlds)
        testing.expect_value(t,len(tracking.allocation_map),0)
        mem.tracking_allocator_destroy(&tracking)
        if ok {break}
    }
    testing.expect(t,succeeded && failed)
}
