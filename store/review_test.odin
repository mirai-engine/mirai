package store

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import "mirai:std/base"

// An object whose root is above level 0, named by a ref and older than the
// grace, in a pack that is mostly dead: a sweep keeps every chunk under it.
@(test)
a_sweep_keeps_every_chunk_under_a_deep_live_root :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-deep");if folder=="" {return}
    now:=time.now()
    old:=time.time_add(now,-2*GRACE)
    s,ok:=test_store(t,folder);if !ok {return}
    defer close(&s)
    p,_:=put_begin(&s,old)
    p.builder.tree.sink={procedure=put_sink,data=&p}
    tree_group(&p.builder.tree,0,0)
    p.builder.started=true
    LEAVES :: NODE_ENTRIES_MAX+100
    whole:=make([]u8,LEAVES*8,context.temp_allocator)
    for i in 0..<LEAVES {
        leaf:=whole[i*8:][:8]
        (^u64)(raw_data(leaf))^=u64(i)
        address:=address_of_bytes(leaf)
        testing.expect_value(t,put_chunk(&p,address,leaf),Error.None)
        testing.expect_value(t,tree_put_leaf(&p.builder.tree,address,8),Error.None)
    }
    root,_,error:=put_finish(&p)
    testing.expect_value(t,error,Error.None)
    for i in 0..<40 {put(&s,test_bytes(64<<10,u64(1000+i)),old)}
    testing.expect_value(t,commit(&s,old),Error.None)
    testing.expect_value(t,ref_set(&s,"keep","deep",root,old),Error.None)
    swept,sweep_error:=sweep(&s,nil,now)
    testing.expect(t,sweep_error==.None && swept.packs>=1,"the mostly dead pack is compacted")
    fresh,_:=test_store(t,folder)
    defer close(&fresh)
    o,open_error:=object_open(&fresh,root)
    if !testing.expect_value(t,open_error,Error.None) {return}
    testing.expect(t,o.root.level>=1,"the root is above level 0")
    object_close(&o)
    test_object_bytes(t,&fresh,root,whole)
}

// A writer passes its look at the newest generation, a whole sweep retires
// what it found stored meanwhile, and then the writer commits: what it named
// is still read, and after the next sweep too.
@(test)
a_commit_paused_across_a_sweep_keeps_what_it_names :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-paused");if folder=="" {return}
    now:=time.now()
    data:=test_bytes(300<<10,21)
    address:=test_dead_object(t,folder,data,time.time_add(now,-2*GRACE))
    writer,ok:=test_store(t,folder);if !ok {return}
    sweeper,_:=test_store(t,folder)
    defer close(&sweeper)
    testing.expect(t,chunk_has(&writer,address))
    again,_:=put(&writer,data,now)
    testing.expect(t,again==address)
    Paused :: struct {sweeper:^Store,now:time.Time,done:bool}
    paused:=Paused{&sweeper,now,false}
    hooks:=Hooks{data=&paused,step=proc(data:rawptr,step:Sweep_Step) {
        p:=(^Paused)(data)
        if step!=.Verified || p.done {return}
        p.done=true
        sweep(p.sweeper,nil,p.now)
    }}
    writer.state.hooks=&hooks
    error:=ref_set(&writer,"keep","paused",address,now)
    writer.state.hooks=nil
    testing.expect(t,error==.None && paused.done,"the commit runs across a sweep")
    {
        fresh,_:=test_store(t,folder)
        defer close(&fresh)
        test_object_bytes(t,&fresh,address,data)
    }
    close(&writer)
    _,sweep_error:=sweep(&sweeper,nil,now)
    testing.expect_value(t,sweep_error,Error.None)
    fresh,_:=test_store(t,folder)
    defer close(&fresh)
    test_object_bytes(t,&fresh,address,data)
}

// A writer of another machine whose lease went unrefreshed for the lease age
// is still writing: what it commits after a sweep judged it gone is read.
@(test)
a_live_writer_whose_lease_went_stale_keeps_its_commits :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-stale-writer");if folder=="" {return}
    now:=time.now()
    w,ok:=test_store(t,folder);if !ok {return}
    first,second:=test_bytes(90000,31),test_bytes(90000,32)
    a1,_:=put(&w,first)
    testing.expect_value(t,ref_set(&w,"keep","one",a1),Error.None)
    test_lease_remote_stale(t,&w,now)
    s,_:=test_store(t,folder)
    defer close(&s)
    _,sweep_error:=sweep(&s,nil,now)
    testing.expect_value(t,sweep_error,Error.None)
    a2,_:=put(&w,second)
    testing.expect_value(t,ref_set(&w,"keep","two",a2),Error.None)
    close(&w)
    sweep(&s,nil,now)
    fresh,_:=test_store(t,folder)
    defer close(&fresh)
    for c in ([]struct{name:string,data:[]u8}{{"one",first},{"two",second}}) {
        got,error:=ref_get(&fresh,"keep",c.name)
        if testing.expectf(t,error==.None,"ref %s: %v",c.name,error) {test_object_bytes(t,&fresh,got,c.data)}
    }
}

// Rewrites the lease of w's writer as one of another machine older than the
// lease age.
@(private)
test_lease_remote_stale :: proc(t:^testing.T,w:^Store,now:time.Time) {
    name:[2+32]u8
    copy(name[:],"w-")
    text:[64]u8
    copy(name[2:],writer_text(w.state.writer.id,&text))
    buffer:[PATH_BYTES]u8
    path,_:=join(&buffer,w.root,"leases",string(name[:]))
    elsewhere:=Holder{pid=1,start=1}
    copy(elsewhere.host[:],"another-machine")
    testing.expect_value(t,lease_write(w,path,elsewhere,0,nil,time.time_add(now,-2*LEASE_MAX_AGE)),Error.None)
}

// Two sweeps find the claim of a holder that ended; one takes it while the
// other is past its mark, and what they mark differs (a ref removed
// between). Exactly one publishes the next generation, and every pack the
// newest generation names is there.
@(test)
two_sweeps_taking_a_stale_claim_publish_once :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-claims");if folder=="" {return}
    now:=time.now()
    old:=time.time_add(now,-2*GRACE)
    data:=test_bytes(200<<10,41)
    {
        k,_:=test_store(t,folder)
        big:=make([]u8,(PACK_SMALL)+(1<<20),context.temp_allocator)
        random_fill(42,0,big)
        address,_:=put(&k,big,old)
        commit(&k,old)
        ref_set(&k,"keep","big",address,old)
        kept,_:=put(&k,data)
        ref_set(&k,"keep","data",kept)
        close(&k)
    }
    a,_:=test_store(t,folder)
    defer close(&a)
    b,_:=test_store(t,folder)
    defer close(&b)
    c,_:=test_store(t,folder)
    defer close(&c)
    // The claim of a process that ended.
    buffer:[PATH_BYTES]u8
    owner,_:=join(&buffer,folder,SWEEP_FOLDER,"owner")
    ended:=Sweep_Claim{holder=holder_self()}
    ended.holder.pid=0
    testing.expect(t,os.write_entire_file(owner,mem.ptr_to_bytes(&ended))==nil)
    Pair :: struct {a,b:^Store,now:time.Time,a_judged,go_a,b_marked,go_b:sync.Sema,result_a,result_b:Error}
    pair:=Pair{a=&a,b=&b,now=now}
    hooks_a:=Hooks{data=&pair,step=proc(data:rawptr,step:Sweep_Step) {
        p:=(^Pair)(data)
        if step==.Claimed {
            sync.sema_post(&p.a_judged)
            sync.sema_wait(&p.go_a)
        }
    }}
    hooks_b:=Hooks{data=&pair,step=proc(data:rawptr,step:Sweep_Step) {
        p:=(^Pair)(data)
        if step==.Marked {
            sync.sema_post(&p.b_marked)
            sync.sema_wait(&p.go_b)
        }
    }}
    a.state.hooks=&hooks_a
    b.state.hooks=&hooks_b
    ta:=thread.create_and_start_with_poly_data(&pair,proc(p:^Pair) {_,p.result_a=sweep(p.a,nil,p.now)})
    sync.sema_wait(&pair.a_judged)
    tb:=thread.create_and_start_with_poly_data(&pair,proc(p:^Pair) {_,p.result_b=sweep(p.b,nil,p.now)})
    sync.sema_wait(&pair.b_marked)
    // What b marked live is dead by the time a marks.
    testing.expect_value(t,ref_remove(&c,"keep","big"),Error.None)
    sync.sema_post(&pair.go_a)
    thread.join(ta)
    sync.sema_post(&pair.go_b)
    thread.join(tb)
    thread.destroy(ta)
    thread.destroy(tb)
    testing.expect(t,pair.result_a==.None && pair.result_b==.None)
    fresh,_:=test_store(t,folder)
    defer close(&fresh)
    g:=&fresh.state.generation
    for gp in g.packs {
        name:[PACK_NAME]u8
        path,_:=join(&buffer,folder,"packs",pack_name({gp.writer,gp.seq},&name))
        testing.expectf(t,os.exists(path),"the generation names %s, which is there",path)
    }
    got,error:=ref_get(&fresh,"keep","data")
    if testing.expect_value(t,error,Error.None) {test_object_bytes(t,&fresh,got,data)}
}

// A ref of one writer to what another committed: the commit flushes the
// other's pack too, so the ref never reaches the disk before what it names.
@(test)
a_ref_flushes_the_packs_of_other_writers_it_names :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-cross-durable");if folder=="" {return}
    a,ok:=test_store(t,folder);if !ok {return}
    defer close(&a)
    b,_:=test_store(t,folder)
    defer close(&b)
    data:=test_bytes(100<<10,51)
    address,_:=put(&a,data)
    testing.expect_value(t,commit(&a),Error.None)
    hooks:Hooks
    b.state.hooks=&hooks
    again,_:=put(&b,data)
    testing.expect(t,again==address)
    testing.expect_value(t,ref_set(&b,"keep","theirs",address),Error.None)
    b.state.hooks=nil
    testing.expect_value(t,hooks.flushes,2)
    // A ref alone to an object of another open pack flushes it too.
    other,_:=put(&a,test_bytes(5000,52))
    testing.expect_value(t,commit(&a),Error.None)
    hooks={}
    b.state.hooks=&hooks
    testing.expect_value(t,ref_set(&b,"keep","other",other),Error.None)
    b.state.hooks=nil
    testing.expect_value(t,hooks.flushes,2)
}

// An address added to a lease after a sweep read the leases, of an object
// outside the grace, is kept by that sweep and the next.
@(test)
an_address_added_to_a_lease_during_a_sweep_is_kept :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-lease-late");if folder=="" {return}
    now:=time.now()
    data:=test_bytes(300<<10,61)
    address:=test_dead_object(t,folder,data,time.time_add(now,-2*GRACE))
    holder,ok:=test_store(t,folder);if !ok {return}
    defer close(&holder)
    sweeper,_:=test_store(t,folder)
    defer close(&sweeper)
    lease,lease_error:=lease_open(&holder,"viewer",{},now)
    if !testing.expect_value(t,lease_error,Error.None) {return}
    defer lease_release(&lease)
    Late :: struct {lease:^Lease,address:Hash,now:time.Time,error:Error,done:bool}
    late:=Late{&lease,address,now,.None,false}
    hooks:=Hooks{data=&late,step=proc(data:rawptr,step:Sweep_Step) {
        l:=(^Late)(data)
        if step!=.Collected || l.done {return}
        l.done=true
        l.error=lease_update(l.lease,{l.address},l.now)
    }}
    sweeper.state.hooks=&hooks
    _,error:=sweep(&sweeper,nil,now)
    sweeper.state.hooks=nil
    testing.expect(t,error==.None && late.done && late.error==.None)
    sweep(&sweeper,nil,now)
    fresh,_:=test_store(t,folder)
    defer close(&fresh)
    test_object_bytes(t,&fresh,address,data)
}

// A sealed trailer whose check holds and whose extra's offset is near the
// largest is refused without a crash.
@(test)
a_trailer_extra_at_the_largest_offset_is_refused :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-extra");if folder=="" {return}
    pack:string
    {
        s,ok:=test_store(t,folder);if !ok {return}
        address,_:=put(&s,test_bytes(5000,71))
        ref_set(&s,"keep","x",address)
        buffer:[PATH_BYTES]u8
        pack,_=pack_path(&s,"packs",s.state.packs[s.state.writer.pack].id,&buffer)
        pack=strings.clone(pack,context.temp_allocator)
        close(&s)
    }
    bytes,_:=os.read_entire_file(pack,context.temp_allocator)
    footer:=(^Footer)(raw_data(bytes[len(bytes)-size_of(Footer):]))
    if !testing.expect(t,footer.extras>=1) {return}
    trailer:=bytes[footer.trailer:len(bytes)-size_of(Footer)]
    extras_at:=int(footer.chunks)*(size_of(Hash)+size_of(Location))+256*4
    extra:=(^Extra)(raw_data(trailer[extras_at:]))
    extra.offset=max(u64)-16
    footer.check=footer_check(trailer,footer)
    testing.expect(t,os.write_entire_file(pack,bytes)==nil)
    s,_:=test_store(t,folder)
    defer close(&s)
    ref_get(&s,"keep","x")
}

// A pack cut below a chunk the index names reads as an error, never beyond
// the end of the file.
@(test)
a_pack_cut_below_a_chunk_reads_as_an_error :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-cut-sealed");if folder=="" {return}
    data:=test_bytes(300<<10,81)
    address:Hash
    pack:string
    {
        s,ok:=test_store(t,folder);if !ok {return}
        defer close(&s)
        address,_=put(&s,data)
        _,sweep_error:=sweep(&s,nil)
        if !testing.expect_value(t,sweep_error,Error.None) {return}
        indexed,_,found:=lookup_locked(&s,address)
        if !testing.expect(t,found && s.state.packs[indexed].indexed) {return}
        buffer:[PATH_BYTES]u8
        pack,_=pack_path(&s,"packs",s.state.packs[indexed].id,&buffer)
        pack=strings.clone(pack,context.temp_allocator)
    }
    reader,ok:=test_store(t,folder);if !ok {return}
    defer close(&reader)
    if !testing.expect(t,chunk_here(&reader,address)) {return}
    file,open_error:=os.open(pack,{.Read,.Write})
    if !testing.expect(t,open_error==nil) {return}
    truncate_error:=os.truncate(file,size_of(Pack_Head))
    os.close(file)
    if !testing.expect_value(t,truncate_error,os.Error(nil)) {return}
    object,error:=object_open(&reader,address)
    if error==.None {object_close(&object)}
    testing.expect_value(t,error,Error.Corrupt)
}

// A generation published while namespaces are listed leaves the names
// listed whole.
@(test)
listing_namespaces_across_a_new_generation_keeps_the_names :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-names");if folder=="" {return}
    s,ok:=test_store(t,folder);if !ok {return}
    defer close(&s)
    a,_:=put(&s,test_bytes(100,91))
    for ns in ([]string{"alpha","beta","gamma"}) {ref_set(&s,ns,"x",a)}
    sweep(&s,nil)
    other,_:=test_store(t,folder)
    defer close(&other)
    put(&other,test_bytes(100,92))
    commit(&other)
    hooks:=Hooks{data=&other,step=proc(data:rawptr,step:Sweep_Step) {
        if step==.Names {sweep((^Store)(data),nil)}
    }}
    s.state.hooks=&hooks
    names,error:=ref_namespaces(&s,context.temp_allocator)
    s.state.hooks=nil
    testing.expect_value(t,error,Error.None)
    testing.expect(t,len(names)==3 && names[0]=="alpha" && names[1]=="beta" && names[2]=="gamma",fmt.tprint(names))
}

// A pack read before its writer wrote its head is read again on the next miss.
@(test)
a_pack_seen_before_its_head_is_read_once_it_has_one :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-early");if folder=="" {return}
    data:=test_bytes(5000,101)
    address:Hash
    bytes:[]u8
    name:string
    {
        w,ok:=test_store(t,strings.concatenate({folder,"/w"},context.temp_allocator));if !ok {return}
        address,_=put(&w,data)
        commit(&w)
        buffer:[PATH_BYTES]u8
        path,_:=pack_path(&w,"packs",w.state.packs[w.state.writer.pack].id,&buffer)
        bytes,_=os.read_entire_file(path,context.temp_allocator)
        name=strings.clone(path[strings.last_index_byte(path,'/')+1:],context.temp_allocator)
        close(&w)
    }
    root:=strings.concatenate({folder,"/r"},context.temp_allocator)
    r,ok:=test_store(t,root);if !ok {return}
    defer close(&r)
    target:=strings.concatenate({root,"/packs/",name},context.temp_allocator)
    testing.expect(t,os.write_entire_file(target,nil)==nil)
    testing.expect(t,!chunk_has(&r,address),"an empty pack holds nothing yet")
    testing.expect(t,os.write_entire_file(target,bytes[:20])==nil)
    testing.expect(t,!chunk_has(&r,address),"nor one with half a head")
    testing.expect(t,os.write_entire_file(target,bytes)==nil)
    testing.expect(t,chunk_has(&r,address),"once whole it is read")
}

// A root of level 1 whose second group begins inside its first leaf is refused.
@(test)
groups_off_leaf_boundaries_are_refused :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-groups-off");if folder=="" {return}
    s,ok:=test_store(t,folder);if !ok {return}
    defer close(&s)
    st,_:=stage_take(&s)
    defer stage_give(&s,st)
    p:=Put{s=&s,stage=st,now=time.now()._nsec}
    leaves:=[2][2]u8{{1,2},{3,4}}
    entries:[2]Entry
    for &l,i in leaves {
        entries[i]={address=address_of_bytes(l[:]),size=2}
        put_chunk(&p,entries[i].address,l[:])
    }
    buffer:[CHUNK_MAX]u8
    leaf_node,_:=node_encode(buffer[:],0,entries[:])
    leaf_address:=address_of_bytes(leaf_node)
    put_chunk(&p,leaf_address,leaf_node)
    groups:=[2]Group{{count=1,offset=0},{first=1,count=1,offset=1}}
    root_buffer:[CHUNK_MAX]u8
    root,encode_error:=node_encode(root_buffer[:],1,{{address=leaf_address,size=4}},groups[:])
    testing.expect_value(t,encode_error,Error.None)
    root_address:=address_of_bytes(root)
    put_chunk(&p,root_address,root)
    testing.expect_value(t,stage_write(&s,st,p.now),Error.None)
    testing.expect_value(t,commit(&s),Error.None)
    _,error:=object_open(&s,root_address)
    testing.expect_value(t,error,Error.Corrupt)
}

// Threads that write against a limited volume never take more than it holds.
@(test)
the_limited_volume_of_the_hooks_is_shared_by_threads :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-space-threads");if folder=="" {return}
    s,ok:=test_store(t,folder);if !ok {return}
    defer close(&s)
    put(&s,test_bytes(10,1))
    commit(&s)
    SPACE :: 2<<20
    hooks:=Hooks{limited=true,space=SPACE}
    s.state.hooks=&hooks
    Worker :: struct {s:^Store,seed:u64}
    workers:[8]Worker
    threads:[8]^thread.Thread
    for &w,i in workers {
        w={&s,u64(200+i*100)}
        threads[i]=thread.create_and_start_with_poly_data(&w,proc(w:^Worker) {
            for k in 0..<40 {put(w.s,test_bytes(20000,w.seed+u64(k)))}
        })
    }
    for th in threads {
        thread.join(th)
        thread.destroy(th)
    }
    s.state.hooks=nil
    used,_:=usage(&s)
    testing.expect(t,hooks.space>=0 && used.bytes<=SPACE+(64<<10),"the volume is never overdrawn")
}
