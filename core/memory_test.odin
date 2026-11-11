package core

import "base:runtime"
import "core:mem"
import "core:testing"

// A World and the next version of it: a table changes its type, one goes and one comes.
@(private="file")
Memory_From :: struct {
    using world:Test_World,
    kept:Table(i32) `mirai:"name=Kept"`,
    gone:Table(u8) `mirai:"name=Gone"`,
    score:i32 `mirai:"name=Score"`,
}

@(private="file")
Memory_To :: struct {
    using world:Test_World,
    kept:Table(i64) `mirai:"name=Kept"`,
    added:Table(u8) `mirai:"name=Added"`,
    score:i32 `mirai:"name=Score"`,
}

// What tables, entities, maps, queues and a migration ask their allocator
// for, with the memory ending at each request in turn: the call answers
// false, or the queue counts what it dropped, with what it had as it was and
// nothing left allocated; with memory enough it goes through.
@(test)
core_calls_without_memory_fail_whole :: proc(t:^testing.T) {
    from,from_made:=test_info(t,Memory_From)
    if !from_made {return}
    defer test_info_destroy(&from)
    to,to_made:=test_info(t,Memory_To)
    if !to_made {return}
    defer test_info_destroy(&to)
    Call :: enum {Table_Settle,Entities_Clear,Map_Reserve,Offer,Migration}
    for call in Call {
        done,refused:=false,false
        for served in 0..<64 {
            tracking:mem.Tracking_Allocator
            mem.tracking_allocator_init(&tracking,context.allocator)
            allocation:=Copy_Allocation{owner=mem.tracking_allocator(&tracking),remaining=max(int)}
            limited:=runtime.Allocator{copy_allocator,&allocation}
            ok:bool
            switch call {
            case .Table_Settle:
                es:Entities
                if !testing.expect(t,entities_init(&es,limited)) {return}
                table:Table(i32)
                allocation.remaining=0
                table_init(&table,"Low",limited)
                allocation.remaining=max(int)
                // An entity of a far page of the rows by entity.
                e:Entity
                for _ in 0..<ROWS_PAGE+1 {e=create(&es)}
                add(&table,e,7)
                allocation.remaining=served
                table_settle(&table,&es)
                ok=has(&table,e)
                testing.expectf(t,ok?len(table.pending)==0:len(table.pending)==1 && count(&table)==0,"%d requests served: an add without room waits whole for the next settle",served)
                if ok {
                    // The first entity that goes makes the room of those gone: without it, readers read the table whole.
                    seen:Seen
                    _=changes(&table,&seen)
                    allocation.remaining=max(int)
                    remove(&table,e)
                    allocation.remaining=0
                    table_settle(&table,&es)
                    c:=changes(&table,&seen)
                    testing.expect(t,!has(&table,e) && c.all && cap(table.gone.items)==0)
                }
                allocation.remaining=max(int)
                table_destroy(&table)
                entities_destroy(&es)
            case .Entities_Clear:
                es:Entities
                if !testing.expect(t,entities_init(&es,limited)) {return}
                first:=create(&es)
                for _ in 0..<7 {create(&es)}
                allocation.remaining=served
                ok=entities_clear(&es)
                allocation.remaining=max(int)
                testing.expectf(t,alive(&es,first)==!ok && es.alive==(ok?0:8),"%d requests served: cleared whole or not at all",served)
                entities_destroy(&es)
            case .Map_Reserve:
                saved:=context.allocator
                context.allocator=limited
                m:Entity_Map(int)
                allocation.remaining=served
                ok=entity_map_reserve(&m,4,16)
                allocation.remaining=0
                _,put:=entity_map_put(&m,entity_make(3,1),7)
                testing.expectf(t,put==ok,"%d requests served: with its room a value is put without asking for more",served)
                allocation.remaining=max(int)
                entity_map_destroy(&m)
                context.allocator=saved
            case .Offer:
                q:Queue(int)
                q.items=make([dynamic]int,limited)
                allocation.remaining=served
                offer(&q,1)
                ok=len(q.items)==1
                testing.expectf(t,q.dropped==(ok?0:1),"%d requests served: what does not go in is counted",served)
                delete(q.items)
            case .Migration:
                m:World_Migration
                allocation.remaining=served
                ok=world_migration_make(&m,&from,&to,limited)
                allocation.remaining=max(int)
                if ok {testing.expect(t,m.tables[0]==.Convert && m.tables[1]==.New && m.table_map[0]==0 && m.table_map[1]==-1)}
                world_migration_destroy(&m)
            }
            testing.expectf(t,len(tracking.allocation_map)==0 && len(tracking.bad_free_array)==0,"%v with %d requests served: %d left allocated",call,served,len(tracking.allocation_map))
            mem.tracking_allocator_destroy(&tracking)
            if done=ok;done {break}
            refused=true
        }
        testing.expectf(t,done && refused,"%v: refused without memory, and with it it goes through",call)
    }
}
