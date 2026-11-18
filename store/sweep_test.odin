package store

import "core:os"
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
    _,sweep_error:=sweep(&s,nil,now)
    testing.expect_value(t,sweep_error,Error.None)
    total,_:=usage(&s)
    testing.expect_value(t,total.blobs,8)
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
            claimed,claim_error:=sweep_claim(&s,blob,&claim_buffer)
            if !testing.expect_value(t,claim_error,Error.None) {return}
            defer os.remove(os.dir(claimed))
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
    claimed,claim_error:=sweep_claim(&other,fresh_path,&claim_buffer)
    if !testing.expect_value(t,claim_error,Error.None) {return}
    defer os.remove(os.dir(claimed))
    testing.expect_value(t,lease_update(&fresh,updated[:],stale),Error.None)
    testing.expect_value(t,sweep_restore(fresh_path,claimed),Error.None)
    modified,time_error:=regular_time(&other,fresh_path)
    testing.expect_value(t,time_error,Error.None)
    testing.expect(t,older_than(modified,now,LEASE_MAX_AGE),"the replacement stays in place")
    updated[0]=hashes[0]
    testing.expect_value(t,lease_refresh(&fresh,now),Error.None)
    collected,make_error:=make(Live_Set,1,s.allocator)
    if !testing.expect(t,make_error==nil) {return}
    defer delete(collected)
    testing.expect_value(t,lease_collect_stale(&other,&collected,fresh_path,now),Error.None)
    testing.expect(t,hashes[1] in collected && !(hashes[0] in collected))
    expired,expired_error:=lease_open(&s,"expired",{hashes[2]},stale)
    if !testing.expect_value(t,expired_error,Error.None) {return}
    defer lease_release(&expired)
    released,released_error:=lease_open(&s,"released",{hashes[3]},now)
    if !testing.expect_value(t,released_error,Error.None) {return}
    testing.expect_value(t,lease_release(&released),Error.None)

    swept,sweep_error:=sweep(&other,nil,now)
    testing.expect_value(t,sweep_error,Error.None)
    testing.expect_value(t,swept.blobs,3)
    for hash,i in hashes {testing.expectf(t,has(&s,hash)==(i==1),"blob %d",i)}

    buffer:[PATH_BYTES]u8
    path,_:=lease_path(&expired,&buffer)
    testing.expect(t,!os.exists(path))
    testing.expect_value(t,lease_refresh(&expired,now),Error.None)
    testing.expect(t,os.is_file(path))
}
