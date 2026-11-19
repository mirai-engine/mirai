package store

import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import "mirai:std/base"

@(private="file")
Worker :: struct {
    s:^Store,
    shared:[][]u8,
    roots:[]Hash,  // of shared
    source:^Store, // what a receiver copies from
    own:[]u8,
    seed:int,
    error:Error,
}

@(private="file")
Sweep_Worker :: struct {
    s:^Store,
    start:^sync.Wait_Group,
    data:[][]u8,
    now:time.Time,
    sweep:bool,
    error:Error,
}

@(test)
two_stores_put_and_sweep_from_several_threads :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-sweep-threads");if folder=="" {return}
    a,ok:=test_store(t,folder);if !ok {return}
    defer close(&a)
    b,ok_b:=test_store(t,folder);if !ok_b {return}
    defer close(&b)

    now:=time.now()
    old:=time.time_add(now,-2*GRACE)
    data:[24][]u8
    roots:[len(data)]Hash
    for &sample,i in data {
        sample=test_bytes(83,u64(210+i))
        put_error:Error
        roots[i],put_error=test_put(&a,sample,old)
        if !testing.expect_value(t,put_error,Error.None) {return}
    }
    start:sync.Wait_Group
    sync.wait_group_add(&start,1)
    workers:[4]Sweep_Worker
    threads:[len(workers)]^thread.Thread
    for &w,i in workers {
        w=Sweep_Worker{s=&a if i%2==0 else &b,start=&start,data=data[:],now=now,sweep=i<2}
        threads[i]=thread.create_and_start_with_poly_data(&w,proc(w:^Sweep_Worker) {
            sync.wait_group_wait(w.start)
            for sample in w.data {
                if w.sweep {
                    _,w.error=sweep(w.s,nil,w.now)
                } else {
                    _,w.error=test_put(w.s,sample,w.now)
                }
                if w.error!=.None {return}
            }
        })
    }
    sync.wait_group_done(&start)
    for th,i in threads {
        if !testing.expect(t,th!=nil) {continue}
        thread.join(th)
        thread.destroy(th)
        testing.expect_value(t,workers[i].error,Error.None)
    }
    for sample,i in data {testing.expect(t,test_holds(&a,roots[i],sample),"every object stays whole")}
}

// Takes the chunks of an object from the source and commits them, as a
// receiver does.
@(private="file")
worker_receive :: proc(w:^Worker,root:Hash) {
    if error:=test_copy(w.source,w.s,root);error!=.None {w.error=error;return}
    w.error=commit(w.s)
}

@(private="file")
worker_run :: proc(w:^Worker) {
    for data,i in w.shared {
        if (i+w.seed)%2==0 {
            if _,error:=test_put(w.s,data);error!=.None {w.error=error;return}
        } else {
            worker_receive(w,w.roots[i])
        }
        if w.error!=.None {return}
    }
    _,w.error=test_put(w.s,w.own)
}

@(test)
two_stores_on_one_root_put_and_receive_from_several_threads :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-threads");if folder=="" {return}
    a,ok:=test_store(t,strings.concatenate({folder,"/shared"},context.temp_allocator));if !ok {return}
    defer close(&a)
    b,_:=test_store(t,strings.concatenate({folder,"/shared"},context.temp_allocator))
    defer close(&b)
    source,_:=test_store(t,strings.concatenate({folder,"/source"},context.temp_allocator))
    defer close(&source)
    WORKERS :: 4
    shared:=make([][]u8,4,context.temp_allocator)
    roots:=make([]Hash,len(shared),context.temp_allocator)
    for &data,i in shared {
        data=test_bytes(5*CHUNK_MAX+i*1000+7,u64(i)+100)
        roots[i],_=test_put(&source,data)
    }
    workers:[WORKERS]Worker
    threads:[WORKERS]^thread.Thread
    for &w,i in workers {
        w.s=&a if i%2==0 else &b
        w.shared,w.roots,w.source,w.seed=shared,roots,&source,i
        w.own=test_bytes(3*CHUNK_MAX+i,u64(i)+200)
    }
    for &w,i in workers {threads[i]=thread.create_and_start_with_poly_data(&w,worker_run)}
    for th in threads {
        thread.join(th)
        thread.destroy(th)
    }
    for w,i in workers {
        testing.expectf(t,w.error==.None,"worker %d: %v",i,w.error)
        root,_:=put(&source,w.own)
        testing.expect(t,test_holds(&a,root,w.own),"what each worker put is whole")
    }
    for data,i in shared {
        testing.expect(t,test_holds(&a,roots[i],data) && test_holds(&b,roots[i],data),"what was put and received is whole in both")
    }
}
