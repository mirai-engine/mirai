package store

import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "mirai:std/base"

@(test)
existing_blobs_are_refreshed_only_after_a_quarter_of_grace :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-refresh");if folder=="" {return}
    s,ok:=test_store(t,folder);if !ok {return}
    defer close(&s)
    now:=time.unix(time.time_to_unix(time.now()),0)
    Put :: enum {Bytes,File,Begin,Complete}
    for route,i in Put {
        for age,j in ([2]time.Duration{2*BLOB_GRACE_AGE,BLOB_REFRESH_AGE/2}) {
            data:=test_bytes(PIECE_BYTES+1,u64(100+2*i+j))
            hash:=test_address(data)
            if route==.Complete {test_full_unfinished(t,&s,data)}
            _,put_error:=put_bytes(&s,data,now)
            if !testing.expect_value(t,put_error,Error.None) {return}
            before:=time.time_add(now,-age)
            test_blob_time(t,&s,hash,before)
            error:Error
            switch route {
            case .Bytes: _,error=put_bytes(&s,data,now)
            case .File:
                source:=join_test(folder,"source",0)
                if !testing.expect(t,os.write_entire_file(source,data)==nil) {return}
                _,error=put_file(&s,source,now)
            case .Begin:
                error=receive_begin(&s,hash,i64(len(data)),test_table(data),now)
            case .Complete:
                error=receive_piece(&s,hash,0,test_piece(data,0),now)
            }
            testing.expect_value(t,error,Error.None)
            path:=[PATH_BYTES]u8{}
            name,_:=blob_file(&s,hash,&path)
            changed,time_error:=os.modification_time_by_path(name)
            testing.expect(t,time_error==nil)
            expected:=now if j==0 else before
            testing.expectf(t,changed==expected,"%v with age %v",route,age)
        }
    }
    // A file of another size in the place of the blob is not it: each route replaces it.
    for route,i in Put {
        data:=test_bytes(2*PIECE_BYTES+5,u64(120+i))
        hash:=test_address(data)
        if route==.Complete {test_full_unfinished(t,&s,data)}
        path:=[PATH_BYTES]u8{}
        name,_:=blob_file(&s,hash,&path)
        os.make_directory(os.dir(name))
        if !testing.expect(t,os.write_entire_file(name,data[:PIECE_BYTES])==nil) {return}
        error:Error
        switch route {
        case .Bytes: _,error=put_bytes(&s,data,now)
        case .File:
            source:=join_test(folder,"source",1)
            if !testing.expect(t,os.write_entire_file(source,data)==nil) {return}
            _,error=put_file(&s,source,now)
        case .Begin:
            error=receive_begin(&s,hash,i64(len(data)),test_table(data),now)
            for index in 0..<piece_count(i64(len(data))) {
                if error==.None {error=receive_piece(&s,hash,index,test_piece(data,index),now)}
            }
        case .Complete:
            error=receive_piece(&s,hash,0,test_piece(data,0),now)
        }
        testing.expect_value(t,error,Error.None)
        testing.expectf(t,verify(&s,hash)==.None,"%v replaces a file of the wrong size",route)
    }
    _,sweep_error:=sweep(&s,nil,now)
    testing.expect_value(t,sweep_error,Error.None)
    total,_:=usage(&s)
    testing.expect_value(t,total.blobs,8+len(Put))
}

@(test)
sweep_and_put_resolve_both_claim_interleavings :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-claim-put");if folder=="" {return}
    s,ok:=test_store(t,folder);if !ok {return}
    defer close(&s)
    other,ok_other:=test_store(t,folder);if !ok_other {return}
    defer close(&other)
    now:=time.now()
    old:=time.time_add(now,-2*BLOB_GRACE_AGE)
    for put_first,i in ([2]bool{true,false}) {
        data:=test_bytes(123,u64(160+i))
        hash,error:=put_bytes(&s,data,now)
        if !testing.expect_value(t,error,Error.None) {return}
        test_blob_time(t,&s,hash,old)
        path,claim_buffer:[PATH_BYTES]u8
        blob,_:=blob_file(&s,hash,&path)
        entry,stat_error:=os.stat(blob,s.allocator)
        if !testing.expect(t,stat_error==nil) {return}
        defer os.file_info_delete(entry,s.allocator)
        testing.expect(t,older_than(entry.modification_time,now,BLOB_GRACE_AGE))
        if put_first {
            _,error=put_bytes(&other,data,now)
            testing.expect_value(t,error,Error.None)
            state:=Sweep{s=&s,now=now}
            sweep_entry(&state,entry,hash)
            testing.expect_value(t,state.result.blobs,0)
            testing.expect_value(t,state.result.skipped,0)
        } else {
            name:[64]u8
            claimed,claim_error:=sweep_claim(&s,blob,.Blob,hex(hash,&name),&claim_buffer)
            if !testing.expect_value(t,claim_error,Error.None) {return}
            testing.expect(t,!has(&other,hash))
            refreshed:=blob_touch(&other,blob,now)
            testing.expect_value(t,refreshed,Error.Missing)
            error=put_bytes_after_refresh(&other,data,test_table(data),hash,refreshed,now)
            testing.expect_value(t,error,Error.None)
            removed,finish_error:=sweep_finish(&s,blob,claimed,now)
            testing.expect_value(t,finish_error,Error.None)
            testing.expect(t,removed)
        }
        testing.expect_value(t,verify(&s,hash),Error.None)
    }
}

@(test)
fresh_leases_keep_their_current_addresses :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-leases");if folder=="" {return}
    s,ok:=test_store(t,folder);if !ok {return}
    defer close(&s)
    other,ok_other:=test_store(t,folder);if !ok_other {return}
    defer close(&other)
    now:=time.now()
    old:=time.time_add(now,-2*BLOB_GRACE_AGE)
    stale:=time.time_add(now,-2*LEASE_MAX_AGE)
    hashes:[4]Hash
    for &hash,i in hashes {
        hash,_=put_bytes(&s,test_bytes(123,u64(180+i)),now)
        test_blob_time(t,&s,hash,old)
    }
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
    modified,_,time_error:=regular_info(&other,fresh_path)
    testing.expect_value(t,time_error,Error.None)
    testing.expect(t,older_than(modified,now,LEASE_MAX_AGE),"the replacement stays in place")
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
    holding:=0
    for c,k in cases {
        if c.holds {holding+=1}
        held:=test_bytes(200,u64(300+k))
        hash,_:=put_bytes(&s,held,now)
        test_blob_time(t,&s,hash,old)
        buffer:[PATH_BYTES]u8
        path:=join(&buffer,folder,"leases",c.name) or_continue
        testing.expect_value(t,lease_write(folder,path,c.holder,{hash},c.at),Error.None)
        defer file_remove(path)
        swept,sweep_error:=sweep(&other,kept[:],now)
        append(&kept,hash)
        testing.expect_value(t,sweep_error,Error.None)
        testing.expectf(t,has(&s,hash)==c.holds && os.exists(path)==c.holds,"%s: the lease holds %v",c.name,c.holds)
        testing.expect_value(t,swept.blobs,0 if c.holds else 1)
    }

    swept,sweep_error:=sweep(&other,nil,now)
    testing.expect_value(t,sweep_error,Error.None)
    testing.expect_value(t,swept.blobs,3+holding)
    for hash,i in hashes {testing.expectf(t,has(&s,hash)==(i==1),"blob %d",i)}
}

// Partial blobs that no lease names and that took no piece for a day go,
// and so does what a sweep that stopped left claimed, as it would have.
@(test)
sweep_removes_old_partials_and_settles_what_a_stopped_sweep_claimed :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-partials");if folder=="" {return}
    s,ok:=test_store(t,folder);if !ok {return}
    defer close(&s)
    now:=time.now()
    old:=time.time_add(now,-2*PARTIAL_GRACE_AGE)
    Case :: struct {live,old,claimed,kept:bool}
    cases:=[]Case{
        {old=true,kept=false},
        {old=false,kept=true},
        {live=true,old=true,kept=true},
        {old=true,claimed=true,kept=false}, // a completion that ended without finishing
    }
    live:[dynamic]Hash
    live.allocator=context.temp_allocator
    hashes:=make([]Hash,len(cases),context.temp_allocator)
    for c,k in cases {
        data:=test_bytes(2*PIECE_BYTES+k,u64(400+k))
        hashes[k]=test_address(data)
        testing.expect_value(t,receive_begin(&s,hashes[k],i64(len(data)),test_table(data)),Error.None)
        testing.expect_value(t,receive_piece(&s,hashes[k],1,test_piece(data,1)),Error.None)
        buffer:[PATH_BYTES]u8
        partial,_:=partial_folder(&s,hashes[k],&buffer)
        if c.old {test_set_time(t,strings.concatenate({partial,"/have"},context.temp_allocator),old)}
        if c.claimed {
            claimed_buffer:[PATH_BYTES]u8
            claimed,_:=claimed_folder(&s,hashes[k],&claimed_buffer)
            testing.expect(t,os.rename(partial,claimed)==nil)
            test_set_time(t,claimed,time.time_add(now,-2*TMP_STALE))
        }
        if c.live {append(&live,hashes[k])}
    }
    // Left by a sweep that stopped: an old blob it was about to remove, a young one and a lease.
    stopped:[2]Hash
    for &hash,k in stopped {
        hash,_=put_bytes(&s,test_bytes(500,u64(450+k)),now)
        path,claim_buffer:[PATH_BYTES]u8
        blob,_:=blob_file(&s,hash,&path)
        if k==0 {test_set_time(t,blob,time.time_add(now,-2*BLOB_GRACE_AGE))}
        name:[64]u8
        _,claim_error:=sweep_claim(&s,blob,.Blob,hex(hash,&name),&claim_buffer)
        testing.expect_value(t,claim_error,Error.None)
        testing.expect(t,!has(&s,hash))
    }
    lease,lease_error:=lease_open(&s,"holder",{},now)
    if !testing.expect_value(t,lease_error,Error.None) {return}
    defer lease_release(&lease)
    lease_buffer,claim_buffer:[PATH_BYTES]u8
    lease_file,_:=lease_path(&lease,&lease_buffer)
    sweep_claim(&s,lease_file,.Lease,"holder",&claim_buffer)

    swept,error:=sweep(&s,live[:],now)
    testing.expect_value(t,error,Error.None)
    testing.expect_value(t,swept.partials,2)
    for c,k in cases {
        _,missing_error:=receive_missing(&s,hashes[k],context.temp_allocator)
        testing.expectf(t,(missing_error==.None)==c.kept,"partial %d is kept %v",k,c.kept)
    }
    testing.expect(t,!has(&s,stopped[0]) && has(&s,stopped[1]),"an old claimed blob goes and a young one comes back")
    testing.expect(t,os.is_file(lease_file),"a claimed lease comes back")
    claims,_:=os.read_all_directory_by_path(strings.concatenate({folder,"/tmp/sweep"},context.temp_allocator),context.temp_allocator)
    testing.expect_value(t,len(claims),0)
}

// A sweep claims into a folder made with the root, so it frees space where
// nothing new can be created, as on a full volume.
@(test)
a_sweep_frees_blobs_where_nothing_new_can_be_created :: proc(t:^testing.T) {
    when ODIN_OS==.Windows {return}
    folder:=base.test_folder(t,"store-full");if folder=="" {return}
    s,ok:=test_store(t,folder);if !ok {return}
    defer close(&s)
    now:=time.now()
    hashes:[3]Hash
    for &hash,k in hashes {
        hash,_=put_bytes(&s,test_bytes(PIECE_BYTES+k,u64(470+k)),now)
        test_blob_time(t,&s,hash,time.time_add(now,-2*BLOB_GRACE_AGE))
    }
    tmp:=strings.concatenate({folder,"/tmp"},context.temp_allocator)
    if !testing.expect(t,os.change_mode(tmp,os.perm_number(0o555))==nil) {return}
    defer os.change_mode(tmp,os.perm_number(0o755))
    swept,error:=sweep(&s,nil,now)
    testing.expect_value(t,error,Error.None)
    testing.expect_value(t,swept.blobs,len(hashes))
    testing.expect_value(t,swept.skipped,0)
    _,put_error:=put_bytes(&s,test_bytes(10,480),now)
    testing.expect(t,put_error!=.None,"nothing new is created there")
}
