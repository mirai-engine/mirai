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

// A writer that found the chunks of a dead object already stored names them
// with a ref, committed at each point of a sweep: before it, after the mark,
// after the generation is published and after the recheck. No committed put
// is lost: the object reads, then and after the next sweep.
@(test)
a_sweep_beside_writers_loses_no_committed_put :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-beside");if folder=="" {return}
    now:=time.now()
    old:=time.time_add(now,-2*GRACE)
    When :: enum {Before,Marked,Published,Rechecked}
    for point in When {
        root:=fmt.tprintf("%s/%v",folder,point)
        data:=test_bytes(400<<10,u64(point)+7)
        address:=test_dead_object(t,root,data,old)
        sweeper,ok:=test_store(t,root);if !ok {return}
        writer,_:=test_store(t,root)
        Work :: struct {t:^testing.T,writer:^Store,data:[]u8,address:Hash,step:Sweep_Step,point:When,now:time.Time,done:bool}
        work:=Work{t=t,writer=&writer,data=data,address=address,point=point,now=now}
        run :: proc(w:^Work) {
            if w.done {return}
            w.done=true
            again,error:=put(w.writer,w.data,w.now)
            testing.expectf(w.t,error==.None && again==w.address,"%v: the put finds the object",w.point)
            testing.expectf(w.t,w.writer.state.writer.frames>0 || len(w.writer.state.writer.deduped)>0,"%v: the writer named stored chunks",w.point)
            testing.expect_value(w.t,ref_set(w.writer,"keep","object",w.address,w.now),Error.None)
        }
        hooks:=Hooks{data=&work,step=proc(data:rawptr,step:Sweep_Step) {
            w:=(^Work)(data)
            if (step==.Marked && w.point==.Marked) || (step==.Published && w.point==.Published) || (step==.Rechecked && w.point==.Rechecked) {run(w)}
        }}
        // The writer's view is read before the sweep, so its lookups find the old copy.
        testing.expect(t,chunk_has(&writer,address),"the writer sees the object")
        if point==.Before {run(&work)}
        sweeper.state.hooks=&hooks
        _,error:=sweep(&sweeper,nil,now)
        sweeper.state.hooks=nil
        testing.expectf(t,error==.None && work.done,"%v: %v",point,error)
        close(&writer)
        fresh,_:=test_store(t,root)
        named,ref_error:=ref_get(&fresh,"keep","object")
        testing.expectf(t,ref_error==.None && named==address,"%v: the ref reads",point)
        test_object_bytes(t,&fresh,address,data)
        _,again_error:=sweep(&sweeper,nil,now)
        testing.expect_value(t,again_error,Error.None)
        test_object_bytes(t,&fresh,address,data)
        close(&fresh)
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
    lease,lease_error:=lease_open(&s,"holder",{addresses[1]},now)
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
}

// A retired pack that will not delete (one a process maps on Windows) is
// skipped, counted, and deleted by a later sweep.
@(test)
a_pack_that_will_not_delete_is_skipped_and_counted :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-undeletable");if folder=="" {return}
    now:=time.now()
    test_dead_object(t,folder,test_bytes(300<<10,1),time.time_add(now,-2*GRACE))
    s,ok:=test_store(t,folder);if !ok {return}
    defer close(&s)
    retired:=strings.concatenate({folder,"/retired"},context.temp_allocator)
    hooks:=Hooks{undeletable=true}
    s.state.hooks=&hooks
    swept,error:=sweep(&s,nil,now)
    s.state.hooks=nil
    testing.expect_value(t,error,Error.None)
    testing.expect(t,swept.packs==1 && swept.skipped==1,"the retired pack is skipped")
    again,_:=sweep(&s,nil,now)
    testing.expect(t,again.skipped==0 && again.bytes>=300<<10,"and deleted later")
    left,_:=os.read_all_directory_by_path(retired,context.temp_allocator)
    testing.expect_value(t,len(left),0)
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

// A full volume is No_Space, and a sweep still frees it: what an earlier
// sweep retired goes before anything is written.
@(test)
a_full_volume_is_no_space_and_a_sweep_frees_it :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-space");if folder=="" {return}
    now:=time.now()
    test_dead_object(t,folder,test_bytes(2<<20,3),time.time_add(now,-2*GRACE))
    s,ok:=test_store(t,folder);if !ok {return}
    defer close(&s)
    // Another writer runs, so the first sweep leaves what it retires.
    other,_:=test_store(t,folder)
    put(&other,test_bytes(10,4))
    testing.expect_value(t,commit(&other),Error.None)
    first,_:=sweep(&s,nil,now)
    testing.expect(t,first.packs==1 && first.bytes==0,"the retired pack waits while another writer runs")
    close(&other)
    hooks:=Hooks{limited=true}
    s.state.hooks=&hooks
    defer s.state.hooks=nil
    _,error:=put(&s,test_bytes(5000,5))
    if error==.None {error=commit(&s)}
    testing.expect_value(t,error,Error.No_Space)
    swept,sweep_error:=sweep(&s,nil,now)
    testing.expect_value(t,sweep_error,Error.None)
    testing.expect(t,swept.bytes>=2<<20,"the sweep frees what was retired")
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

@(test)
fresh_leases_keep_their_current_addresses :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-leases");if folder=="" {return}
    s,ok:=test_store(t,folder);if !ok {return}
    defer close(&s)
    other,ok_other:=test_store(t,folder);if !ok_other {return}
    defer close(&other)
    now:=time.now()
    old:=time.time_add(now,-2*GRACE)
    stale:=time.time_add(now,-2*LEASE_MAX_AGE)
    hashes:[4]Hash
    for &hash,i in hashes {hash,_=test_put(&s,test_bytes(123,u64(180+i)),old)}
    fresh,open_error:=lease_open(&s,"editor",{hashes[0]},now)
    if !testing.expect_value(t,open_error,Error.None) {return}
    defer lease_release(&fresh)
    updated:=[1]Hash{hashes[1]}
    fresh_buffer,claim_buffer:[PATH_BYTES]u8
    fresh_path,_:=lease_path(&fresh,&fresh_buffer)
    claimed,claim_error:=sweep_claim(&other,fresh_path,.Lease,"editor",&claim_buffer)
    if !testing.expect_value(t,claim_error,Error.None) {return}
    testing.expect_value(t,lease_update(&fresh,updated[:],stale),Error.None)
    testing.expect_value(t,sweep_restore(fresh_path,claimed),Error.None)
    modified,time_error:=os.modification_time_by_path(fresh_path)
    testing.expect(t,time_error==nil && older_than(modified,now,LEASE_MAX_AGE),"the replacement stays in place")
    collected,make_error:=make(Live_Set,1,s.allocator)
    if !testing.expect(t,make_error==nil) {return}
    defer delete(collected)
    holds,collect_error:=lease_collect(&other,&collected,fresh_path,now,holder_self())
    testing.expect(t,collect_error==.None && holds,"the lease of a holder that runs here holds however old its time")
    testing.expect(t,hashes[1] in collected && !(hashes[0] in collected))
    released,released_error:=lease_open(&s,"released",{hashes[3]},now)
    if !testing.expect_value(t,released_error,Error.None) {return}
    testing.expect_value(t,lease_release(&released),Error.None)

    // Leases this process did not open: who holds them decides, else their time.
    // The value that wrote the objects sweeps, so that its own pack is folded.
    self:=holder_self()
    ended:=self
    ended.start+=1
    elsewhere:=Holder{pid=self.pid,start=self.start}
    copy(elsewhere.host[:],"another-machine")
    Case :: struct {name:string,holder:Holder,at:time.Time,holds:bool}
    cases:=[]Case{
        {"asleep",self,time.time_add(now,-24*time.Hour),true},  // suspended, or a clock that jumped forward
        {"crashed",ended,now,false},                             // a pid given again to another process
        {"gone",{host=self.host},now,false},                     // pid 0: no process
        {"remote-fresh",elsewhere,now,true},
        {"remote-stale",elsewhere,stale,false},
    }
    kept:=make([dynamic]Hash,context.temp_allocator)
    append(&kept,..hashes[:])
    for c,k in cases {
        hash,_:=test_put(&s,test_bytes(200,u64(300+k)),old)
        buffer:[PATH_BYTES]u8
        path:=join(&buffer,folder,"leases",c.name) or_continue
        testing.expect_value(t,lease_write(&s,path,c.holder,0,{hash},c.at),Error.None)
        defer file_remove(path)
        _,sweep_error:=sweep(&s,kept[:],now)
        append(&kept,hash)
        testing.expect_value(t,sweep_error,Error.None)
        testing.expectf(t,chunk_has(&s,hash)==c.holds && os.exists(path)==c.holds,"%s: the lease holds %v",c.name,c.holds)
    }
    _,sweep_error:=sweep(&s,nil,now)
    testing.expect_value(t,sweep_error,Error.None)
    for hash,i in hashes {testing.expectf(t,chunk_has(&s,hash)==(i==1),"object %d",i)}
}

// What a sweep that stopped left claimed comes back, and stale temporary
// files go.
@(test)
sweep_settles_what_a_stopped_sweep_claimed :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-claims");if folder=="" {return}
    s,ok:=test_store(t,folder);if !ok {return}
    defer close(&s)
    now:=time.now()
    lease,lease_error:=lease_open(&s,"holder",{},now)
    if !testing.expect_value(t,lease_error,Error.None) {return}
    defer lease_release(&lease)
    lease_buffer,claim_buffer:[PATH_BYTES]u8
    lease_file,_:=lease_path(&lease,&lease_buffer)
    sweep_claim(&s,lease_file,.Lease,"holder",&claim_buffer)
    stale,fresh:=join_test(folder,"tmp/stale",0),join_test(folder,"tmp/fresh",0)
    testing.expect(t,os.write_entire_file(stale,[]u8{1})==nil && os.write_entire_file(fresh,[]u8{1})==nil)
    test_set_time(t,stale,time.time_add(now,-2*TMP_STALE))
    _,error:=sweep(&s,nil,now)
    testing.expect_value(t,error,Error.None)
    testing.expect(t,os.is_file(lease_file),"a claimed lease comes back")
    claims,_:=os.read_all_directory_by_path(strings.concatenate({folder,"/tmp/sweep"},context.temp_allocator),context.temp_allocator)
    testing.expect_value(t,len(claims),0)
    testing.expect(t,!os.exists(stale) && os.exists(fresh),"sweep removes only stale temporary files")
}
