package store

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:thread"
import "mirai:std/base"
import "mirai:std/jobs"
import "mirai:std/subprocess"

// The test program is also the child of the two-process test: started with
// STORE_CHILD, a root and a seed, it puts CHILD_OBJECTS objects with a ref
// each, commits and ends before the tests run.
@(private) STORE_CHILD :: "mirai-store-child"
@(private) CHILD_OBJECTS :: 40

@(init,private)
store_child :: proc "contextless" () {
    if len(os.args)<4 || os.args[1]!=STORE_CHILD {return}
    context=runtime.default_context()
    seed:=u64(os.args[3][0]-'0')
    s,error:=open(os.args[2])
    if error!=.None {os.exit(2)}
    for i in 0..<CHILD_OBJECTS {
        data:=child_bytes(seed,i)
        address,put_error:=put(&s,data)
        if put_error!=.None {os.exit(3)}
        if ref_set(&s,"child",fmt.tprintf("%d-%d",seed,i),address)!=.None {os.exit(4)}
    }
    close(&s)
    os.exit(0)
}

@(private)
child_bytes :: proc(seed:u64,i:int) -> []u8 {
    return test_bytes(1+(i*7919+int(seed)*104729)%(300<<10),seed*1000+u64(i))
}

@(private)
test_object_bytes :: proc(t:^testing.T,s:^Store,address:Hash,want:[]u8,loc:=#caller_location) -> bool {
    o,error:=object_open(s,address)
    if !testing.expect_value(t,error,Error.None,loc=loc) {return false}
    defer object_close(&o)
    back:=make([]u8,len(want),context.temp_allocator)
    if !testing.expect_value(t,object_read(&o,0,back),Error.None,loc=loc) {return false}
    return testing.expect(t,object_size(&o)==u64(len(want)) && string(back)==string(want),"the object reads back its bytes",loc=loc)
}

// Two processes and two Store values of this one, from several threads, put
// objects and refs into one root; each reads what the others committed.
@(test)
writers_of_several_processes_and_threads_share_one_root :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-writers");if folder=="" {return}
    a,ok:=test_store(t,folder);if !ok {return}
    defer close(&a)
    b,ok_b:=test_store(t,folder);if !ok_b {return}
    defer close(&b)
    program,_:=os.get_executable_path(context.temp_allocator)
    Child :: struct {program,root:string,seed:u64,state:os.Process_State,error:os.Error}
    children:[2]Child
    Writer_Thread :: struct {s:^Store,seed:u64,addresses:[24]Hash,error:Error}
    writers:[4]Writer_Thread
    threads:[len(children)+len(writers)]^thread.Thread
    for &c,i in children {
        c={program=program,root=folder,seed=u64(i+1)}
        threads[i]=thread.create_and_start_with_poly_data(&c,proc(c:^Child) {
            seed:=[1]u8{u8('0'+c.seed)}
            c.state,_,_,c.error=subprocess.exec({command={c.program,STORE_CHILD,c.root,string(seed[:])}},context.allocator)
        })
    }
    for &w,i in writers {
        w={s=&a if i%2==0 else &b,seed=u64(5+i)}
        threads[len(children)+i]=thread.create_and_start_with_poly_data(&w,proc(w:^Writer_Thread) {
            for &address,k in w.addresses {
                address,w.error=put(w.s,child_bytes(w.seed,k))
                if w.error!=.None {return}
                if k%5==4 {
                    if w.error=commit(w.s);w.error!=.None {return}
                }
            }
            w.error=commit(w.s)
        })
    }
    for th in threads {
        if th==nil {continue}
        thread.join(th)
        thread.destroy(th)
    }
    for c in children {testing.expectf(t,c.error==nil && c.state.exited && c.state.exit_code==0,"child %d: %v %v",c.seed,c.error,c.state)}
    for w in writers {
        testing.expect_value(t,w.error,Error.None)
        other:=&b if w.s==&a else &a
        for address,k in w.addresses {test_object_bytes(t,other,address,child_bytes(w.seed,k))}
    }
    for c in children {
        for i in 0..<CHILD_OBJECTS {
            address,error:=ref_get(&b,"child",fmt.tprintf("%d-%d",c.seed,i))
            if !testing.expectf(t,error==.None,"the ref of child %d object %d: %v",c.seed,i,error) {continue}
            test_object_bytes(t,&b,address,child_bytes(c.seed,i))
        }
    }
    testing.expect_value(t,commit(&a),Error.None)
}

// A pack cut at any offset of its tail, as a crash leaves it, reads up to its
// last whole commit, and nothing written after it.
@(test)
a_pack_cut_anywhere_in_its_tail_opens_to_its_last_commit :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-torn");if folder=="" {return}
    source,ok:=test_store(t,strings.concatenate({folder,"/source"},context.temp_allocator));if !ok {return}
    first:=test_bytes(5000,1)
    last:=test_bytes(700,2)
    first_address,_:=put(&source,first)
    testing.expect_value(t,ref_set(&source,"torn","first",first_address),Error.None)
    committed:=source.state.writer.committed
    last_address,_:=put(&source,last)
    testing.expect_value(t,ref_set(&source,"torn","last",last_address),Error.None)
    end:=source.state.writer.committed
    pack_buffer:[PATH_BYTES]u8
    pack:=pack_path(&source,"packs",source.state.packs[source.state.writer.pack].id,&pack_buffer) or_else ""
    bytes,read_error:=os.read_entire_file(pack,context.temp_allocator)
    close(&source)
    if !testing.expect(t,read_error==nil && i64(len(bytes))>=end) {return}
    bytes=bytes[:end]
    root:=strings.concatenate({folder,"/cut"},context.temp_allocator)
    name:[PACK_NAME]u8
    target:=strings.concatenate({root,"/packs/",pack_name(source_id(bytes),&name)},context.temp_allocator)
    for cut:=committed;cut<=end;cut+=1 {
        base.remove_all(root)
        s,open_ok:=test_store(t,root);if !open_ok {return}
        testing.expect(t,os.write_entire_file(target,bytes[:cut])==nil)
        got,first_error:=ref_get(&s,"torn","first")
        testing.expectf(t,first_error==.None && got==first_address,"cut at %d: the first commit reads",cut)
        _,last_error:=ref_get(&s,"torn","last")
        whole:=cut==end
        testing.expectf(t,(last_error==.None)==whole,"cut at %d: the last ref reads only whole",cut)
        testing.expectf(t,chunk_has(&s,last_address)==whole,"cut at %d: the last object is found only whole",cut)
        if cut==committed || whole {test_object_bytes(t,&s,first_address,first)}
        close(&s)
        if t.error_count>0 {return}
    }
    // Garbage after the last commit is never read either.
    base.remove_all(root)
    s,_:=test_store(t,root)
    defer close(&s)
    torn:=make([]u8,end+4096,context.temp_allocator)
    copy(torn,bytes)
    h:=base.Hostile{state=9}
    for &b in torn[end:] {b=u8(base.hostile_next(&h))}
    testing.expect(t,os.write_entire_file(target,torn)==nil)
    got,error:=ref_get(&s,"torn","last")
    testing.expect(t,error==.None && got==last_address,"what follows the last commit is ignored")
}

@(private)
source_id :: proc(bytes:[]u8) -> Pack_Id {
    head:=(^Pack_Head)(raw_data(bytes))^
    return {writer=head.writer}
}

// While a batch's frames reach the disk no other value sees its ref; once
// commit returns, every value does.
@(test)
a_ref_is_never_visible_before_what_it_names_is_durable :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-durable");if folder=="" {return}
    writer,ok:=test_store(t,folder);if !ok {return}
    defer close(&writer)
    reader,_:=test_store(t,folder)
    defer close(&reader)
    data:=test_bytes(200<<10,3)
    address,put_error:=put(&writer,data)
    testing.expect_value(t,put_error,Error.None)
    Seen :: struct {t:^testing.T,reader:^Store,address:Hash,flushes:int}
    seen:=Seen{t,&reader,address,0}
    hooks:=Hooks{data=&seen,flushing=proc(data:rawptr) {
        seen:=(^Seen)(data)
        seen.flushes+=1
        _,error:=ref_get(seen.reader,"durable","object")
        testing.expect_value(seen.t,error,Error.Missing)
        testing.expect(seen.t,!chunk_has(seen.reader,seen.address),"the object is not seen while it is flushed")
    }}
    writer.state.hooks=&hooks
    testing.expect_value(t,ref_set(&writer,"durable","object",address),Error.None)
    writer.state.hooks=nil
    testing.expect_value(t,seen.flushes,1)
    got,error:=ref_get(&reader,"durable","object")
    testing.expect(t,error==.None && got==address,"once committed the ref is seen")
    test_object_bytes(t,&reader,address,data)
}

// A small put writes once and creates, renames and flushes nothing; a batch
// flushes once, whatever it holds.
@(test)
a_small_put_writes_once_and_a_batch_flushes_once :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-calls");if folder=="" {return}
    s,ok:=test_store(t,folder);if !ok {return}
    defer close(&s)
    put(&s,test_bytes(100,1))
    testing.expect_value(t,commit(&s),Error.None)
    hooks:Hooks
    s.state.hooks=&hooks
    defer s.state.hooks=nil
    PUTS :: 50
    for i in 0..<PUTS {
        _,error:=put(&s,test_bytes(1024+i*1300,u64(10+i)))
        testing.expect_value(t,error,Error.None)
    }
    testing.expect_value(t,hooks.writes,PUTS)
    testing.expect(t,hooks.creates==0 && hooks.renames==0 && hooks.flushes==0 && hooks.opens==0,"a small put creates, renames, opens and flushes nothing")
    testing.expect_value(t,commit(&s),Error.None)
    testing.expect_value(t,hooks.flushes,1)
    testing.expect_value(t,hooks.writes,PUTS+1)
    address,_:=put(&s,test_bytes(5000,99))
    testing.expect_value(t,ref_set(&s,"calls","one",address),Error.None)
    testing.expect_value(t,hooks.flushes,2)
    testing.expect_value(t,hooks.writes,PUTS+4)
    testing.expect(t,hooks.creates==0 && hooks.renames==0,"a ref creates and renames nothing")
    // A large object goes in writes of a stage each, and one flush.
    big:=make([]u8,3<<20,context.temp_allocator)
    random_fill(5,0,big)
    before:=hooks.flushes
    _,big_error:=put(&s,big)
    testing.expect_value(t,big_error,Error.None)
    testing.expect_value(t,commit(&s),Error.None)
    testing.expect_value(t,hooks.flushes-before,1)
}

// An object of several groups reads by group and offset across the chunks
// that cut it, from the open pack and from the sealed one, mapped.
@(test)
an_object_of_several_groups_reads_by_group_and_offset :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-groups");if folder=="" {return}
    sizes:=[3]int{700<<10,10,300<<10}
    groups:[3][]u8
    for &g,i in groups {
        g=make([]u8,sizes[i],context.temp_allocator)
        random_fill(u64(40+i),0,g)
    }
    cuts:=[]int{100<<10,350<<10,360<<10}
    address:Hash
    meta:="header and directory"
    {
        s,ok:=test_store(t,folder);if !ok {return}
        defer close(&s)
        p,begin_error:=put_begin(&s)
        if !testing.expect_value(t,begin_error,Error.None) {return}
        for g,i in groups {
            testing.expect_value(t,put_native(&p,u32(i)+7,u32(i),0,g,cuts if i==0 else nil),Error.None)
        }
        total:u64
        error:Error
        address,total,error=put_finish(&p,transmute([]u8)meta)
        testing.expect(t,error==.None && total==u64(sizes[0]+sizes[1]+sizes[2]))
        testing.expect_value(t,commit(&s),Error.None)
        test_groups_read(t,&s,address,groups[:],meta)
    }
    s,ok:=test_store(t,folder);if !ok {return}
    defer close(&s)
    test_groups_read(t,&s,address,groups[:],meta)
    o,_:=object_open(&s,address)
    defer object_close(&o)
    chunk,at,error:=group_chunk(&o,0,(100<<10)+5)
    testing.expect(t,error==.None && at==5 && string(chunk[at:][:16])==string(groups[0][(100<<10)+5:][:16]),"a chunk of a group is found where its offset falls")
    file,view,_,locate_error:=chunk_locate(&s,address_of_bytes(chunk))
    testing.expect(t,locate_error==.None && view!=nil && file!=nil,"a chunk of a sealed pack is read mapped")
}

@(private)
test_groups_read :: proc(t:^testing.T,s:^Store,address:Hash,groups:[][]u8,meta:string) {
    o,error:=object_open(s,address)
    if !testing.expect_value(t,error,Error.None) {return}
    defer object_close(&o)
    testing.expect(t,len(object_groups(&o))==len(groups) && string(object_meta(&o))==meta,"the root carries the groups and the meta")
    for g,i in groups {
        Range :: struct {offset,count:int}
        ranges:=[]Range{{0,len(g)},{len(g)-1,1},{0,1}}
        if i==0 {ranges=[]Range{{0,len(g)},{(100<<10)-3,6},{(350<<10)-1,(10<<10)+2},{CHUNK_MAX-7,CHUNK_MAX+14},{len(g)-1,1}}}
        for r in ranges {
            back:=make([]u8,r.count,context.temp_allocator)
            testing.expectf(t,group_read(&o,i,u64(r.offset),back)==.None && string(back)==string(g[r.offset:][:r.count]),"group %d from %d, %d bytes",i,r.offset,r.count)
        }
        testing.expect_value(t,group_read(&o,i,u64(len(g)),make([]u8,1,context.temp_allocator)),Error.Invalid_Argument)
    }
    testing.expect_value(t,group_read(&o,len(groups),0,nil),Error.Invalid_Argument)
}

// A root written by another layout is refused, with how to go on.
@(test)
a_root_of_another_layout_is_refused_with_how_to_go_on :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-layout");if folder=="" {return}
    for layout,i in ([]string{"mirai store 2\n","mirai store 9\n"}) {
        root:=fmt.tprintf("%s/%d",folder,i)
        testing.expect(t,os.make_directory(root)==nil)
        name:="layout" if i==0 else "LAYOUT"
        testing.expect(t,os.write_entire_file(fmt.tprintf("%s/%s",root,name),transmute([]u8)layout)==nil)
        _,error:=open(root)
        testing.expect_value(t,error,Error.Unsupported_Layout)
    }
    testing.expect(t,strings.contains(error_text(.Unsupported_Layout),"remove that folder"),"the text says how to go on")
}


// A large stream put on the workers of a job system is the same object, the
// same chunks and the same tree, as one put on one thread.
@(test)
a_stream_put_on_workers_is_the_same_object :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-workers");if folder=="" {return}
    js:jobs.Job_System
    if !testing.expect(t,jobs.system_init(&js,{threads=3,allocator=runtime.heap_allocator()})) {return}
    defer jobs.system_destroy(&js)
    data:=make([]u8,(20<<20)+12345,context.temp_allocator)
    random_fill(77,0,data)
    one,ok:=test_store(t,strings.concatenate({folder,"/one"},context.temp_allocator));if !ok {return}
    defer close(&one)
    many,_:=test_store(t,strings.concatenate({folder,"/many"},context.temp_allocator))
    defer close(&many)
    alone,alone_error:=put(&one,data)
    p,_:=put_begin(&many,nil,{system=&js,worker=jobs.OWNER})
    for at:=0;at<len(data);at+=(1<<20)+7 {
        testing.expect_value(t,put_write(&p,data[at:min(at+(1<<20)+7,len(data))]),Error.None)
    }
    shared,total,shared_error:=put_finish(&p)
    testing.expect(t,alone_error==.None && shared_error==.None && total==u64(len(data)),"both puts end")
    testing.expect(t,alone==shared,"the same object")
    testing.expect_value(t,commit(&many),Error.None)
    test_object_bytes(t,&many,shared,data)
    again,_:=put(&many,data,nil,{system=&js,worker=jobs.OWNER})
    testing.expect(t,again==shared,"put again on the workers finds every chunk")
}
