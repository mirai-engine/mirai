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

// A writer that runs keeps its open pack locked: a sweep leaves the pack and
// what it committed alone. Once its writer ends, which lets the lock go, a
// sweep folds the pack up to its last commit and removes it, and what a ref
// names in it stays.
@(test)
a_pack_whose_writer_ended_is_folded_and_a_live_one_kept :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-ended-writer");if folder=="" {return}
    now:=time.now()
    old:=time.time_add(now,-2*GRACE)
    w,ok:=test_store(t,folder);if !ok {return}
    defer close(&w)
    named,dead:=test_bytes(90000,31),test_bytes(90000,32)
    named_address,_:=put(&w,named,old)
    dead_address,_:=put(&w,dead,old)
    testing.expect_value(t,ref_set(&w,"keep","named",named_address,old),Error.None)
    pack:=w.state.writer.pack
    path_buffer:[PATH_BYTES]u8
    path,_:=pack_path(&w,"packs",w.state.packs[pack].id,&path_buffer)
    s,_:=test_store(t,folder)
    defer close(&s)
    Case :: struct {name:string,ended:bool}
    for c in ([]Case{{"running",false},{"ended",true}}) {
        if c.ended {
            // As the system does when the process ends: the writer's lock goes, its pack stays unsealed.
            file_unlock(w.state.writer.file)
        }
        swept,error:=sweep(&s,nil,now)
        testing.expectf(t,error==.None && !swept.busy,"%s: %v",c.name,error)
        testing.expectf(t,os.exists(path)!=c.ended,"%s: the pack is removed %v",c.name,c.ended)
        fresh,_:=test_store(t,folder)
        test_object_bytes(t,&fresh,named_address,named)
        testing.expectf(t,chunk_has(&fresh,dead_address)!=c.ended,"%s: the unnamed object is dropped %v",c.name,c.ended)
        close(&fresh)
    }
}

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
    testing.expect(t,chunk_has(&b,address),"b reads what a committed, so its put finds it")
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

// A generation another value published leaves the names listed whole.
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
    sweep(&other,nil)
    names,error:=ref_namespaces(&s,context.temp_allocator)
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
