package store

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "mirai:std/base"

// An object put long ago and named by nothing, in a sealed pack of a writer
// that ended.
@(private)
test_dead_object :: proc(t:^testing.T,root:string,data:[]u8,at:time.Time) -> (address:Hash) {
    w,ok:=test_store(t,root);if !ok {return}
    defer close(&w)
    error:Error
    address,error=put(&w,data,at)
    testing.expect_value(t,error,Error.None)
    testing.expect_value(t,commit(&w,at),Error.None)
    return
}

// A sweep never runs while a batch is open, of another value or of its own,
// or while another sweep holds the root: it returns busy and drops nothing.
// Once the holder lets go, a sweep runs, and what the batch's commit names of
// what it found stored stays.
@(test)
a_sweep_refuses_while_a_batch_is_open_and_loses_no_commit :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-busy");if folder=="" {return}
    now:=time.now()
    old:=time.time_add(now,-2*GRACE)
    Hold :: enum {Batch_Of_Another_Value,Operation_Of_This_Value,Another_Sweep}
    for hold in Hold {
        root:=fmt.tprintf("%s/%v",folder,hold)
        data:=test_bytes(400<<10,u64(hold)+7)
        address:=test_dead_object(t,root,data,old)
        sweeper,ok:=test_store(t,root);if !ok {return}
        writer,_:=test_store(t,root)
        other:^os.File
        switch hold {
        case .Batch_Of_Another_Value:
            // The writer finds the chunks stored and names them only when it commits.
            again,error:=put(&writer,data,now)
            testing.expect(t,error==.None && again==address && len(writer.state.writer.deduped)>0)
        case .Operation_Of_This_Value:
            // The operation has written and not committed: the sweep must not commit for it.
            testing.expect_value(t,batch_enter(&sweeper),Error.None)
            _,error:=put(&sweeper,test_bytes(1<<10,u64(hold)+99),now)
            testing.expect(t,error==.None && sweeper.state.writer.frames>0)
        case .Another_Sweep:
            other,_=file_open(join_test(root,"lock",0)[:len(root)+5])
            locked,_:=file_lock(other,.Exclusive,false)
            testing.expect(t,locked)
        }
        busy,error:=sweep(&sweeper,nil,now)
        testing.expectf(t,error==.None && busy.busy && busy.packs==0 && chunk_has(&sweeper,address),"%v: the sweep refuses",hold)
        if hold==.Operation_Of_This_Value {
            testing.expect(t,sweeper.state.writer.frames>0,"the sweep leaves the open batch of an operation uncommitted")
        }
        switch hold {
        case .Batch_Of_Another_Value: testing.expect_value(t,ref_set(&writer,"keep","object",address,now),Error.None)
        case .Operation_Of_This_Value: batch_leave(&sweeper)
        case .Another_Sweep: os.close(other)
        }
        swept,again_error:=sweep(&sweeper,nil,now)
        testing.expectf(t,again_error==.None && !swept.busy,"%v: the sweep runs once the holder lets go",hold)
        kept:=hold==.Batch_Of_Another_Value
        fresh,_:=test_store(t,root)
        testing.expectf(t,chunk_has(&fresh,address)==kept,"%v: the object is kept %v",hold,kept)
        if kept {test_object_bytes(t,&fresh,address,data)}
        close(&fresh)
        close(&writer)
        close(&sweeper)
    }
}

// A sweep copies the live chunks of packs that are mostly dead into its own
// pack and drops the dead ones; what is young, named or leased stays.
@(test)
compaction_keeps_every_live_chunk_and_drops_the_dead :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-compact");if folder=="" {return}
    now:=time.now()
    old:=time.time_add(now,-2*GRACE)
    s,ok:=test_store(t,folder);if !ok {return}
    defer close(&s)
    COUNT :: 24
    addresses:[COUNT]Hash
    datas:[COUNT][]u8
    for &a,i in addresses {
        datas[i]=test_bytes(20000+i*3000,u64(500+i))
        a,_=put(&s,datas[i],old)
    }
    testing.expect_value(t,commit(&s,old),Error.None)
    young:=test_bytes(70000,600)
    young_address,_:=put(&s,young,now)
    testing.expect_value(t,commit(&s,now),Error.None)
    // Named: a ref; leased; given; the rest is dead.
    testing.expect_value(t,ref_set(&s,"keep","zero",addresses[0],old),Error.None)
    lease,lease_error:=lease_open(&s,{addresses[1]})
    testing.expect_value(t,lease_error,Error.None)
    defer lease_release(&lease)
    before,_:=usage(&s)
    swept,error:=sweep(&s,{addresses[2]},now)
    testing.expect_value(t,error,Error.None)
    testing.expect(t,swept.chunks>=COUNT-3,"the dead chunks are dropped")
    testing.expect(t,swept.packs>=1 && swept.bytes>0,"the mostly dead pack is retired and deleted")
    after,_:=usage(&s)
    testing.expect(t,after.bytes<before.bytes,"the store is smaller")
    fresh,_:=test_store(t,folder)
    defer close(&fresh)
    for a,i in addresses {
        live:=i<3
        testing.expectf(t,chunk_has(&fresh,a)==live,"object %d is kept %v",i,live)
        if live {test_object_bytes(t,&fresh,a,datas[i])}
    }
    test_object_bytes(t,&fresh,young_address,young)
    got,_:=ref_get(&fresh,"keep","zero")
    testing.expect(t,got==addresses[0],"refs are folded into the generation")
    // A sweep with nothing to do keeps everything.
    again,again_error:=sweep(&s,{addresses[2]},now)
    testing.expect(t,again_error==.None && again.chunks==0,"nothing more is dropped")
    for a in addresses[:3] {testing.expect(t,chunk_has(&fresh,a))}

    // With reclaim, what this value wrote and no root reaches goes however
    // fresh, also from a pack mostly live; another writer's fresh chunks stay.
    other,_:=test_store(t,folder)
    theirs:=test_bytes(30000,700)
    theirs_address,_:=put(&other,theirs,now)
    testing.expect_value(t,commit(&other,now),Error.None)
    close(&other)
    kept:=test_bytes(90000,701)
    kept_address,_:=put(&s,kept,now)
    dropped:=test_bytes(30000,702)
    dropped_address,_:=put(&s,dropped,now)
    testing.expect_value(t,commit(&s,now),Error.None)
    before_reclaim,_:=usage(&s)
    reclaimed,reclaim_error:=sweep(&s,{addresses[2],kept_address},now,reclaim=true)
    testing.expect_value(t,reclaim_error,Error.None)
    after_reclaim,_:=usage(&s)
    testing.expect(t,reclaimed.chunks>0 && after_reclaim.bytes<before_reclaim.bytes,"the dead chunks of a pack mostly live leave the disk")
    reread,_:=test_store(t,folder)
    defer close(&reread)
    testing.expect(t,!chunk_has(&reread,dropped_address),"what this value wrote and nothing reaches goes")
    test_object_bytes(t,&reread,kept_address,kept)
    test_object_bytes(t,&reread,theirs_address,theirs)
    for a,i in addresses[:3] {test_object_bytes(t,&reread,a,datas[i])}
}

// A pack that will not delete (one a process maps on Windows) leaves packs/,
// is skipped and counted, and deleted by the next sweep, which also removes
// what writes that stopped left in tmp/.
@(test)
a_pack_that_will_not_delete_is_skipped_and_counted :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-undeletable");if folder=="" {return}
    now:=time.now()
    test_dead_object(t,folder,test_bytes(300<<10,1),time.time_add(now,-2*GRACE))
    s,ok:=test_store(t,folder);if !ok {return}
    defer close(&s)
    hooks:=Hooks{undeletable=true}
    s.state.hooks=&hooks
    swept,error:=sweep(&s,nil,now)
    s.state.hooks=nil
    testing.expect_value(t,error,Error.None)
    testing.expect(t,swept.packs==1 && swept.skipped==1,"the pack is skipped")
    packs,_:=usage(&s)
    testing.expect_value(t,packs.packs,0)
    stale,fresh:=join_test(folder,"tmp/stale",0),join_test(folder,"tmp/fresh",0)
    testing.expect(t,os.write_entire_file(stale,[]u8{1})==nil && os.write_entire_file(fresh,[]u8{1})==nil)
    test_set_time(t,stale,time.time_add(now,-2*TMP_STALE))
    again,_:=sweep(&s,nil,now)
    testing.expect(t,again.skipped==0 && again.bytes>=300<<10,"and deleted later")
    left,_:=os.read_all_directory_by_path(strings.concatenate({folder,"/tmp"},context.temp_allocator),context.temp_allocator)
    for e in left {testing.expectf(t,!strings.has_prefix(e.name,GONE_PREFIX),"%s is deleted",e.name)}
    testing.expect(t,!os.exists(stale) && os.exists(fresh),"sweep removes only stale temporary files")
}

// A pack a sweep deletes that the sweeping value lent to a caller stays mapped
// and is reported held, not freed; one it never lent is closed and freed, and
// another value that never lent it closes it when it reads the new generation.
@(test)
a_deleted_pack_this_value_lent_is_held_not_freed :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-held");if folder=="" {return}
    now:=time.now()
    SIZE :: 300<<10
    for lent in ([]bool{false,true}) {
        root:=fmt.tprintf("%s/%v",folder,lent)
        data:=test_bytes(SIZE,2)
        address:=test_dead_object(t,root,data,time.time_add(now,-2*GRACE))
        s,ok:=test_store(t,root);if !ok {return}
        defer close(&s)
        watcher,_:=test_store(t,root)
        defer close(&watcher)
        if lent {test_object_bytes(t,&s,address,data)}
        swept,error:=sweep(&s,nil,now)
        testing.expect_value(t,error,Error.None)
        testing.expectf(t,swept.packs==1 && swept.skipped==0,"lent %v: the pack is retired and deleted",lent)
        p:=&s.state.packs[0]
        if lent {
            testing.expect(t,swept.held>=SIZE && swept.bytes<SIZE,"a lent pack is held")
            testing.expect(t,p.view!=nil,"and stays mapped")
        } else {
            testing.expect(t,swept.bytes>=SIZE && swept.held==0,"a pack never lent is freed")
            testing.expect(t,p.view==nil && p.file==nil,"and closed")
        }
        testing.expect(t,!chunk_has(&watcher,address),"the watcher reads the new generation")
        for &q in watcher.state.packs {
            testing.expectf(t,!q.gone || (q.view==nil && q.file==nil),"lent %v: the watcher closes what is gone",lent)
        }
    }
}

// A full volume is No_Space, and a sweep still frees it: a pack of the
// generation that holds nothing live goes before anything is written.
@(test)
a_full_volume_is_no_space_and_a_sweep_frees_it :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-space");if folder=="" {return}
    now:=time.now()
    dead:=test_dead_object(t,folder,test_bytes(2<<20,3),time.time_add(now,-2*GRACE))
    s,ok:=test_store(t,folder);if !ok {return}
    defer close(&s)
    // Kept once, the pack joins the generation.
    first,_:=sweep(&s,{dead},now)
    testing.expect(t,first.packs==0 && s.state.generation.number==1,"the pack is in the generation")
    hooks:=Hooks{limited=true}
    s.state.hooks=&hooks
    defer s.state.hooks=nil
    _,error:=put(&s,test_bytes(5000,5))
    if error==.None {error=commit(&s)}
    testing.expect_value(t,error,Error.No_Space)
    swept,sweep_error:=sweep(&s,nil,now)
    testing.expect_value(t,sweep_error,Error.None)
    testing.expect(t,swept.bytes>=2<<20,"the sweep frees the dead pack")
    address,put_error:=put(&s,test_bytes(5000,5))
    testing.expect_value(t,put_error,Error.None)
    testing.expect_value(t,commit(&s),Error.None)
    test_object_bytes(t,&s,address,test_bytes(5000,5))
}

// A scrub finds a chunk whose bytes no longer match, tombstones it so no
// value reads it, and a sweep drops it.
@(test)
a_scrub_tombstones_a_damaged_chunk :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-scrub");if folder=="" {return}
    datas:=[3][]u8{test_bytes(9000,10),test_bytes(9000,11),test_bytes(9000,12)}
    addresses:[3]Hash
    {
        s,ok:=test_store(t,folder);if !ok {return}
        defer close(&s)
        for d,i in datas {
            addresses[i],_=put(&s,d)
            testing.expect_value(t,ref_set(&s,"keep",fmt.tprintf("%d",i),addresses[i]),Error.None)
        }
    }
    s,ok:=test_store(t,folder);if !ok {return}
    defer close(&s)
    other,_:=test_store(t,folder)
    defer close(&other)
    testing.expect(t,test_damage(&s,datas[1],4000),"the damage lands in a pack")
    result,error:=scrub(&s,1<<30)
    testing.expect_value(t,error,Error.None)
    testing.expect(t,result.damaged==1 && result.finished && result.chunks>=6,"the damaged chunk is found")
    damaged:=address_of_bytes(datas[1])
    testing.expect(t,!chunk_has(&s,damaged) && !chunk_has(&other,damaged),"no value reads it")
    _,open_error:=object_open(&other,addresses[0])
    testing.expect_value(t,open_error,Error.None)
    test_object_bytes(t,&other,addresses[2],datas[2])
    // Budgets go a part at a time and begin again at the end.
    parts:=0
    for {
        part,part_error:=scrub(&s,1)
        if part_error!=.None || part.damaged>0 {break}
        parts+=1
        if part.finished || parts>100 {break}
    }
    testing.expect(t,parts>1 && parts<100,"a small budget scrubs part by part")
    swept,_:=sweep(&s,nil)
    _=swept
    put(&s,datas[1])
    testing.expect_value(t,commit(&s),Error.None)
    test_object_bytes(t,&other,addresses[1],datas[1])
}

// A chunk found again is refreshed only once it is
// older than a quarter of GRACE, so a sweep keeps it.
@(test)
what_is_put_again_is_refreshed_after_a_quarter_of_grace :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-refresh");if folder=="" {return}
    s,ok:=test_store(t,folder);if !ok {return}
    defer close(&s)
    start:=time.now()
    at :: proc(start:time.Time,part:f64) -> time.Time {return time.time_add(start,time.Duration(part*f64(GRACE)))}
    object:=test_bytes(30000,101)
    address,_:=put(&s,object,start)
    testing.expect_value(t,commit(&s,start),Error.None)
    hooks:Hooks
    s.state.hooks=&hooks
    put(&s,object,at(start,0.125))
    testing.expect_value(t,commit(&s,at(start,0.125)),Error.None)
    testing.expect_value(t,hooks.writes,0)
    put(&s,object,at(start,0.5))
    testing.expect_value(t,commit(&s,at(start,0.5)),Error.None)
    testing.expect(t,hooks.writes>=1,"a chunk older than a quarter of grace is refreshed")
    s.state.hooks=nil
    swept,error:=sweep(&s,nil,at(start,1.25))
    testing.expect_value(t,error,Error.None)
    testing.expect(t,chunk_has(&s,address),"what was refreshed is kept")
    _,error=sweep(&s,nil,at(start,2))
    testing.expect(t,error==.None && !chunk_has(&s,address),"and goes once nothing refreshes it")
}

// A lease keeps what it names now while its holder runs, of any value of
// the process; a lease released, and one whose holder ended (its lock free),
// keeps nothing and goes.
@(test)
a_lease_holds_while_its_holder_runs :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-leases");if folder=="" {return}
    s,ok:=test_store(t,folder);if !ok {return}
    defer close(&s)
    other,ok_other:=test_store(t,folder);if !ok_other {return}
    defer close(&other)
    now:=time.now()
    old:=time.time_add(now,-2*GRACE)
    hashes:[5]Hash
    for &hash,i in hashes {hash,_=test_put(&s,test_bytes(123,u64(180+i)),old)}
    held,held_error:=lease_open(&s,{hashes[0]})
    if !testing.expect_value(t,held_error,Error.None) {return}
    defer lease_release(&held)
    testing.expect_value(t,lease_update(&held,{hashes[1]}),Error.None)
    theirs,theirs_error:=lease_open(&other,{hashes[2]})
    if !testing.expect_value(t,theirs_error,Error.None) {return}
    defer lease_release(&theirs)
    released,released_error:=lease_open(&other,{hashes[3]})
    if !testing.expect_value(t,released_error,Error.None) {return}
    testing.expect_value(t,lease_release(&released),Error.None)
    // A lease whose holder ended: the system let its lock go.
    ended:=path_in(folder,"leases","ended")
    payload:=make([]u8,len(LEASE_MAGIC)+size_of(Hash),context.temp_allocator)
    copy(payload,LEASE_MAGIC)
    copy(payload[len(LEASE_MAGIC):],hashes[4][:])
    testing.expect(t,os.write_entire_file(ended,payload)==nil)
    swept,error:=sweep(&s,nil,now)
    testing.expect(t,error==.None && !swept.busy)
    kept:=[len(hashes)]bool{false,true,true,false,false}
    for hash,i in hashes {testing.expectf(t,chunk_has(&s,hash)==kept[i],"object %d is kept %v",i,kept[i])}
    testing.expect(t,!os.exists(ended),"the lease of a holder that ended goes")
    buffer:[PATH_BYTES]u8
    held_path,_:=lease_path(&held,&buffer)
    testing.expect(t,os.exists(held_path),"a held lease stays")
}
