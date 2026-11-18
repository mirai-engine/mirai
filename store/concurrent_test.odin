package store

import "core:os"
import "core:strings"
import "core:testing"
import "core:thread"
import "mirai:std/base"

@(private="file")
Worker :: struct {
    s:^Store,
    shared:[][]u8,
    tables:[][]Hash,
    own:[]u8,
    own_table:[]Hash,
    seed:int,
    error:Error,
}

@(private="file")
worker_receive :: proc(w:^Worker,data:[]u8,pieces:[]Hash) {
    hash:=address_of_bytes(data)
    if error:=receive_begin(w.s,hash,i64(len(data)),pieces);error!=.None {w.error=error;return}
    for i in 0..<len(pieces) {
        index:=(i+w.seed)%len(pieces)
        if error:=receive_piece(w.s,hash,index,test_piece(data,index));error!=.None {w.error=error;return}
    }
}

@(private="file")
worker_run :: proc(w:^Worker) {
    for data,i in w.shared {
        if (i+w.seed)%2==0 {
            if _,error:=put_bytes(w.s,data);error!=.None {w.error=error;return}
        } else {
            worker_receive(w,data,w.tables[i])
        }
        if w.error!=.None {return}
    }
    worker_receive(w,w.own,w.own_table)
}

@(test)
two_stores_on_one_root_put_and_receive_from_several_threads :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-threads");if folder=="" {return}
    a,ok:=test_store(t,folder);if !ok {return}
    defer close(&a)
    b,_:=test_store(t,folder)
    defer close(&b)
    WORKERS :: 4
    shared:=make([][]u8,4,context.temp_allocator)
    tables:=make([][]Hash,len(shared),context.temp_allocator)
    for &data,i in shared {
        data=test_bytes(5*PIECE_BYTES+i*1000+7,u64(i)+100)
        tables[i]=test_table(data)
    }
    workers:[WORKERS]Worker
    threads:[WORKERS]^thread.Thread
    for &w,i in workers {
        w.s=&a if i%2==0 else &b
        w.shared,w.tables,w.seed=shared,tables,i
        w.own=test_bytes(3*PIECE_BYTES+i,u64(i)+200)
        w.own_table=test_table(w.own)
    }
    for &w,i in workers {threads[i]=thread.create_and_start_with_poly_data(&w,worker_run)}
    for th in threads {
        thread.join(th)
        thread.destroy(th)
    }
    for w,i in workers {
        testing.expectf(t,w.error==.None,"worker %d: %v",i,w.error)
        testing.expect_value(t,verify(&a,address_of_bytes(w.own)),Error.None)
    }
    for data in shared {
        hash:=address_of_bytes(data)
        testing.expect_value(t,verify(&a,hash),Error.None)
        testing.expect_value(t,verify(&b,hash),Error.None)
        missing,error:=receive_missing(&b,hash,context.temp_allocator)
        testing.expect(t,error==.None && len(missing)==0)
    }
    total,_:=usage(&a)
    testing.expect_value(t,total.blobs,len(shared)+WORKERS)
    partials,_:=os.read_all_directory_by_path(strings.concatenate({folder,"/partial"},context.temp_allocator),context.temp_allocator)
    testing.expect_value(t,len(partials),0)
}
