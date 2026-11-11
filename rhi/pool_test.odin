package rhi

import "base:runtime"
import "core:fmt"
import "core:testing"
import "mirai:std/base"

@(test)
pool_handle_is_slot_and_generation_and_zero_is_invalid :: proc(t:^testing.T) {
    pool:Pool(int)
    testing.expect(t,pool_init(&pool,4,context.allocator))
    defer pool_destroy(&pool,context.allocator)
    first:=pool_add(&pool,10)
    testing.expect(t,first!=0,"the first handle of a pool is not the zero handle")
    testing.expect_value(t,base.handle_index(first),u32(0))
    testing.expect_value(t,base.handle_generation(first),u32(1))
    testing.expect(t,pool_get(&pool,0)==nil)
    testing.expect_value(t,pool_get(&pool,first)^,10)
    testing.expect_value(t,pool_handle(&pool,0),first)
    testing.expect_value(t,pool.count,1)
}

@(test)
pool_stale_handle_returns_nil_after_its_slot_is_reused :: proc(t:^testing.T) {
    pool:Pool(int)
    testing.expect(t,pool_init(&pool,1,context.allocator))
    defer pool_destroy(&pool,context.allocator)
    old:=pool_add(&pool,1)
    value,removed:=pool_remove(&pool,old)
    testing.expect(t,removed && value==1)
    testing.expect(t,pool_get(&pool,old)==nil,"a destroyed handle is invalid")
    _,again:=pool_remove(&pool,old)
    testing.expect(t,!again,"a handle is removed once")
    new:=pool_add(&pool,2)
    testing.expect_value(t,base.handle_index(new),base.handle_index(old))
    testing.expect(t,new!=old)
    testing.expect(t,pool_get(&pool,old)==nil,"the old handle does not alias the new occupant of its slot")
    testing.expect_value(t,pool_get(&pool,new)^,2)
}

@(test)
pool_full_returns_the_zero_handle_until_a_slot_is_freed :: proc(t:^testing.T) {
    pool:Pool(int)
    testing.expect(t,pool_init(&pool,3,context.allocator))
    defer pool_destroy(&pool,context.allocator)
    handles:[3]base.Handle
    for &handle,i in handles {handle=pool_add(&pool,i);testing.expect(t,handle!=0)}
    testing.expect(t,!pool_has_room(&pool))
    testing.expect_value(t,pool_add(&pool,99),base.Handle(0))
    testing.expect_value(t,pool.count,3)
    pool_remove(&pool,handles[1])
    testing.expect(t,pool_has_room(&pool))
    reused:=pool_add(&pool,7)
    testing.expect_value(t,base.handle_index(reused),u32(1))
    testing.expect_value(t,pool_get(&pool,reused)^,7)
    for i in ([]int{0,2}) {testing.expect_value(t,pool_get(&pool,handles[i])^,i)}
}

@(test)
pool_reuses_freed_slots_in_the_order_they_were_freed :: proc(t:^testing.T) {
    pool:Pool(int)
    testing.expect(t,pool_init(&pool,4,context.allocator))
    defer pool_destroy(&pool,context.allocator)
    handles:[4]base.Handle
    for &handle,i in handles {handle=pool_add(&pool,i)}
    for i in ([]int{2,0,3}) {pool_remove(&pool,handles[i])}
    for expected in ([]u32{2,0,3}) {testing.expect_value(t,base.handle_index(pool_add(&pool,0)),expected)}
    // The ring of free slots wraps around its end.
    for round in 0..<10 {
        handle:=pool_handle(&pool,round%4)
        pool_remove(&pool,handle)
        testing.expect_value(t,base.handle_index(pool_add(&pool,round)),u32(round%4))
    }
    testing.expect_value(t,pool.count,4)
}

@(test)
pool_of_no_capacity_holds_nothing :: proc(t:^testing.T) {
    pool:Pool(int)
    testing.expect(t,pool_init(&pool,0,context.allocator))
    defer pool_destroy(&pool,context.allocator)
    testing.expect(t,!pool_has_room(&pool))
    testing.expect_value(t,pool_add(&pool,1),base.Handle(0))
}

// An allocator that serves `remaining` requests of its owner and refuses the rest.
@(private)
Memory_Limit :: struct {owner:runtime.Allocator,remaining:int}

@(private)
memory_limit_proc :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
    limit:=(^Memory_Limit)(data)
    if mode==.Alloc || mode==.Alloc_Non_Zeroed || mode==.Resize || mode==.Resize_Non_Zeroed {
        if limit.remaining<=0 {return nil,.Out_Of_Memory}
        limit.remaining-=1
    }
    return limit.owner.procedure(limit.owner.data,mode,size,alignment,old_memory,old_size,loc)
}

// What the tables every backend shares ask memory for, with the memory ending
// at each request in turn: the call is refused and the table keeps what it
// had, and with memory enough it goes through.
@(test)
device_tables_without_memory_are_refused_and_keep_what_they_had :: proc(t:^testing.T) {
    limit:=Memory_Limit{owner=context.allocator,remaining=max(int)}
    limited:=runtime.Allocator{memory_limit_proc,&limit}
    Table :: enum {Pool,Changes,Compact,Arena}
    for table in Table {
        pool:Pool(int)
        changes:Table_Changes
        for &copy in changes {copy=make([dynamic]u64,limited)}
        device:=new(Device)
        device.allocator=limited
        arena:=Arena{allocator=limited}
        if table==.Changes {
            if !testing.expect(t,table_changes_reset(&changes,64)) {return}
            table_changed(&changes,5)
        }
        done,refused:=false,false
        for served in 0..<16 {
            limit.remaining=served
            switch table {
            case .Pool:    done=pool_init(&pool,8,limited)
            case .Changes: done=table_changes_reset(&changes,1<<16)
            case .Compact: done=compact_slot_take(device)>0
            case .Arena:
                if _,added:=arena_add(&arena,1<<16);added {_,_,done=arena_take(&arena,256,256)}
            }
            limit.remaining=max(int)
            if done {break}
            refused=true
            switch table {
            case .Pool:
                testing.expectf(t,pool.items==nil && pool.free==nil && !pool_has_room(&pool),"a pool refused with %d requests served holds nothing",served)
            case .Changes:
                for copy in changes {testing.expectf(t,copy[0]==1<<5,"a copy lost the entry it had not taken with %d requests served",served)}
            case .Compact:
                testing.expectf(t,device.compact_free==nil,"the free slots stay unmade with %d requests served",served)
            case .Arena:
                _,used:=arena_bytes(&arena)
                testing.expectf(t,used==0,"an arena refused with %d requests served gave no range",served)
            }
        }
        testing.expectf(t,done && refused,"%v: refused without memory, and with it it goes through",table)
        if table==.Changes {
            for copy in changes {testing.expect(t,copy[0]==0,"a table made again leaves no entry to take")}
        }
        pool_destroy(&pool,limited)
        table_changes_destroy(&changes)
        delete(device.compact_free)
        arena_destroy(&arena)
        free(device)
    }
}
