package share

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import "mirai:asset"
import "mirai:cook/import/sources"
import "mirai:exchange"
import "mirai:project"
import "mirai:std/base"
import "mirai:store"
import wire "mirai:net"

// Peers of one simulated network, each with a store, a node, a server host
// others join and a client host it joins with, stepped together at 1 ms.
@(private="file")
Test_Peer :: struct {
    s:store.Store,
    n:Node,
    server,client:^wire.Host,
    endpoint:int, // of its server
    token:u64,    // of its server
    pumped:bool,
}

@(private="file")
Test_Net :: struct {
    sim:wire.Sim_Network,
    now:f64,
    peers:[3]Test_Peer,
    count:int,
    endpoints:int,
    folder:string,
}

@(private="file")
test_net :: proc(t:^testing.T,w:^Test_Net,name:string,peers:int) -> bool {
    w.folder=base.test_folder(t,name)
    if w.folder=="" {return false}
    wire.sim_network_init(&w.sim,{seed=11,endpoints=8,packets=1<<16})
    w.count=peers
    for k in 0..<peers {
        p:=&w.peers[k]
        error:store.Error
        if p.s,error=store.open(fmt.tprintf("%s/store-%d",w.folder,k));!testing.expect_value(t,error,store.Error.None) {return false}
        if !testing.expect_value(t,node_init(&p.n,&p.s),.None) {return false}
        p.token=u64(1000+k)
        p.server=test_host(w,.Server,p.token,&p.endpoint)
        node_host(&p.n,p.server)
        p.pumped=true
    }
    return true
}

@(private="file")
test_host :: proc(w:^Test_Net,mode:wire.Mode,token:u64,endpoint:^int=nil) -> ^wire.Host {
    h:=new(wire.Host)
    at:=w.endpoints
    w.endpoints+=1
    chans:=channels()
    wire.host_init(h,{mode=mode,transport=wire.sim_endpoint_transport(&w.sim,at),channels=chans[:],protocol_id=PROTOCOL_ID,version=VERSION,invite=token,seed=u64(200+at),max_connections=PEERS-1})
    if endpoint!=nil {endpoint^=at}
    return h
}

// Peer k joins the server of peer from with a client host.
@(private="file")
test_connect :: proc(w:^Test_Net,k,from:int) {
    p:=&w.peers[k]
    p.client=test_host(w,.Client,w.peers[from].token)
    node_host(&p.n,p.client)
    wire.host_connect(p.client,wire.address_memory(w.peers[from].endpoint))
}

@(private="file")
test_net_destroy :: proc(w:^Test_Net) {
    for &p in w.peers[:w.count] {
        node_destroy(&p.n)
        for h in ([2]^wire.Host{p.server,p.client}) {
            if h!=nil {wire.host_destroy(h);free(h)}
        }
        store.close(&p.s)
    }
    wire.sim_network_destroy(&w.sim)
}

@(private="file")
test_step :: proc(w:^Test_Net) {
    w.now+=0.001
    wire.sim_network_advance(&w.sim,w.now)
    for &p in w.peers[:w.count] {
        if !p.pumped {continue}
        node_pump(&p.n,w.now)
        for h in ([2]^wire.Host{p.server,p.client}) {
            if h!=nil {wire.host_update(h,w.now)}
        }
    }
}

@(private="file")
Test_Join :: struct {
    desc:Join_Desc,
    report:Join_Report,
    error:string,
    done:bool,
    allocator:mem.Allocator,
}

// An arena of the heap that lives until the test ends: what a join gives back.
@(private="file")
test_arena :: proc(t:^testing.T) -> mem.Allocator {
    arena:=new(mem.Dynamic_Arena,runtime.heap_allocator())
    mem.dynamic_arena_init(arena,runtime.heap_allocator(),runtime.heap_allocator())
    testing.cleanup(t,proc(data:rawptr) {
        arena:=(^mem.Dynamic_Arena)(data)
        mem.dynamic_arena_destroy(arena)
        free(arena,runtime.heap_allocator())
    },arena)
    return base.dynamic_arena_allocator(arena)
}

// Runs a join of peer k on a thread while the network steps, at most 600
// virtual seconds. stop_bytes: in the step its node has received that many
// piece bytes, peer k leaves (its client disconnects and it is pumped no
// more) and its join is stopped, so nothing arrives after the stop whenever
// the thread of the join notices it.
@(private="file")
test_join :: proc(t:^testing.T,w:^Test_Net,k:int,desc:Join_Desc,stop_bytes:u64=0) -> (report:Join_Report,error:string) {
    run:=Test_Join{desc=desc}
    run.desc.node=&w.peers[k].n
    run.allocator=test_arena(t)
    run.desc.pace=1000
    th:=thread.create_and_start_with_data(&run,proc(data:rawptr) {
        r:=(^Test_Join)(data)
        r.report,r.error=join(r.desc,r.allocator)
        free_all(context.temp_allocator)
        sync.atomic_store(&r.done,true)
    },init_context=context)
    for steps:=0;!sync.atomic_load(&run.done);steps+=1 {
        test_step(w)
        if steps>600_000 {
            testing.expect(t,false,"the join did not end in 600 virtual seconds")
            node_stop(run.desc.node)
        }
        if stop_bytes>0 && w.peers[k].pumped && node_totals(run.desc.node).received>=stop_bytes {
            // As a process that ends: its client says goodbye and nothing more is read.
            w.peers[k].pumped=false
            node_stop(run.desc.node)
            if c:=w.peers[k].client;c!=nil {
                wire.host_disconnect(c,0,.Closed)
                wire.host_poll(c)
                wire.host_update(c,w.now)
            }
        }
    }
    thread.join(th)
    thread.destroy(th)
    return run.report,run.error
}

@(private="file")
file_put :: proc(root,path:string,data:[]u8,executable:=false) {
    full:=fmt.tprintf("%s/%s",root,path)
    os.make_directory_all(os.dir(full))
    _=os.write_entire_file(full,data)
    if executable {os.change_mode(full,os.Permissions_Default_File+os.Permissions_Execute_All)}
}

// Gives the file at path a time an hour ago, as a file written long before it is read.
@(private="file")
settle :: proc(root,path:string) {
    old:=time.time_add(time.now(),-time.Hour)
    os.change_times(fmt.tprintf("%s/%s",root,path),old,old)
}

@(private="file")
read_text :: proc(root,path:string) -> string {
    data,error:=os.read_entire_file(fmt.tprintf("%s/%s",root,path),context.temp_allocator)
    return error==nil?string(data):"(none)"
}

@(private="file")
noise :: proc(size:int,seed:u64) -> []u8 {
    data:=make([]u8,size,context.temp_allocator)
    h:=base.Hostile{state=seed}
    for &b in data {b=u8(base.hostile_next(&h))}
    return data
}

// The files of root that are its own (project.own_path), by path, with their bytes and executable bit.
@(private="file")
own_files :: proc(root:string) -> map[string]string {
    files:=make(map[string]string,context.temp_allocator)
    todo:=make([dynamic]string,context.temp_allocator)
    append(&todo,"")
    for next:=0;next<len(todo);next+=1 {
        listed,_:=os.read_all_directory_by_path(todo[next]==""?root:fmt.tprintf("%s/%s",root,todo[next]),context.temp_allocator)
        for info in listed {
            relative:=todo[next]==""?info.name:fmt.tprintf("%s/%s",todo[next],info.name)
            if !project.own_path(relative) {continue}
            if info.type==.Directory {append(&todo,relative);continue}
            data,_:=os.read_entire_file(fmt.tprintf("%s/%s",root,relative),context.temp_allocator)
            files[relative]=fmt.tprintf("%v%s",info.mode&os.Permissions_Execute_All!={},string(data))
        }
    }
    return files
}

@(private="file")
same_files :: proc(t:^testing.T,a,b:string,loc:=#caller_location) -> bool {
    fa,fb:=own_files(a),own_files(b)
    ok:=testing.expectf(t,len(fa)==len(fb),"%d files and %d",len(fa),len(fb),loc=loc)
    for path,content in fa {
        other,found:=fb[path]
        ok&=testing.expectf(t,found && other==content,"%s is the same in both",path,loc=loc)
    }
    return ok
}

@(private="file")
wav :: proc(samples:int,seed:u64) -> []u8 {
    file:=make([]u8,44+samples*2,context.temp_allocator)
    put :: proc(file:[]u8,at:int,value:u32,size:int) {for i in 0..<size {file[at+i]=u8(value>>uint(8*i))}}
    copy(file,"RIFF");put(file,4,u32(len(file)-8),4);copy(file[8:],"WAVEfmt ")
    put(file,16,16,4);put(file,20,1,2);put(file,22,1,2);put(file,24,48000,4);put(file,28,96000,4)
    put(file,32,2,2);put(file,34,16,2)
    copy(file[36:],"data");put(file,40,u32(samples*2),4)
    copy(file[44:],noise(samples*2,seed))
    return file
}

// A project at <folder>/host with files of its own, some that are not, and a
// package whose source then leaves the machine; its snapshot offered by peer 0.
@(private="file")
host_project :: proc(t:^testing.T,w:^Test_Net) -> (root:string,ok:bool) {
    root=fmt.tprintf("%s/host",w.folder)
    file_put(root,"project.mirai",transmute([]u8)string("{}\n"))
    file_put(root,"game/game.odin",transmute([]u8)string("package game\n"))
    file_put(root,"tools/run.sh",transmute([]u8)string("#!/bin/sh\n"),executable=true)
    file_put(root,"assets/big.bin",noise(300<<10,1))
    file_put(root,"assets/empty.txt",nil)
    file_put(root,"assets/deep/a/b/c.txt",transmute([]u8)string("c"))
    file_put(root,".gitignore",transmute([]u8)string(".mirai/\n"))
    file_put(root,".mirai/cache/registry/x",transmute([]u8)string("machine"))
    file_put(root,".git/HEAD",transmute([]u8)string("ref: main"))
    sources_folder:=fmt.tprintf("%s/sources",w.folder)
    file_put(sources_folder,"beep.wav",wav(4800,2))
    options:=sources.Library_Options{store=&w.peers[0].s,root=root}
    report,error:=sources.ingest(fmt.tprintf("%s/beep.wav",sources_folder),options,allocator=context.temp_allocator)
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
    added:=sources.project_add(root,report.manifest,"sounds",nil,options,context.temp_allocator)
    if !testing.expectf(t,len(added.failures)==0 && len(added.missing)==0,"%v",added) {return}
    // Its source is on no peer from now on.
    testing.expect(t,os.rename(sources_folder,fmt.tprintf("%s/gone",w.folder))==nil)
    return root,host_offer(t,w,root)
}

@(private="file")
host_offer :: proc(t:^testing.T,w:^Test_Net,root:string) -> bool {
    s:=&w.peers[0].s
    snap,address,_,error:=snapshot_take(s,root,"game",context.temp_allocator)
    if !testing.expectf(t,error=="","%s",error) {return false}
    digits:[64]u8
    offer_set(s,root,offer_name(w.peers[0].token,&digits),address)
    node_serve(&w.peers[0].n,address)
    for e in snap.entries {node_serve(&w.peers[0].n,e.address)}
    return true
}

@(private="file")
join_desc :: proc(w:^Test_Net,from:int,folder:string) -> Join_Desc {
    digits:=new([64]u8,context.temp_allocator)
    return {offer=offer_name(w.peers[from].token,digits),folder=folder,parent=w.folder}
}

@(test)
the_snapshot_leaves_out_what_the_layout_says_and_round_trips :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"share-snapshot")
    if folder=="" {return}
    root:=fmt.tprintf("%s/game",folder)
    file_put(root,"project.mirai",transmute([]u8)string("{}\n"))
    file_put(root,"tools/run.sh",transmute([]u8)string("#!/bin/sh\n"),executable=true)
    file_put(root,"assets/b.txt",transmute([]u8)string("b"))
    file_put(root,"assets/empty.txt",nil)
    file_put(root,".gitignore",transmute([]u8)string(".mirai/\n"))
    file_put(root,".mirai/build/out.o",transmute([]u8)string("built"))
    file_put(root,".git/HEAD",transmute([]u8)string("ref: main"))
    for path in ([]string{"project.mirai","tools/run.sh","assets/b.txt","assets/empty.txt",".gitignore"}) {settle(root,path)}
    s,open_error:=store.open(fmt.tprintf("%s/store",folder))
    if !testing.expect_value(t,open_error,store.Error.None) {return}
    defer store.close(&s)
    snap,address,report,error:=snapshot_take(&s,root,"game",context.temp_allocator)
    if !testing.expectf(t,error=="","%s",error) {return}
    paths:=make([dynamic]string,context.temp_allocator)
    for e in snap.entries {append(&paths,e.path)}
    testing.expectf(t,fmt.tprint(paths[:])==`[".gitignore", "assets/b.txt", "assets/empty.txt", "project.mirai", "tools/run.sh"]`,"the files of its own, sorted: %v",paths[:])
    run,_:=snapshot_find(&snap,"tools/run.sh")
    b,_:=snapshot_find(&snap,"assets/b.txt")
    testing.expect(t,run.executable && !b.executable && b.size==1 && store.has(&s,b.address))
    testing.expect_value(t,report.put,5)

    bytes:=make([]u8,SNAPSHOT_MAX_BYTES,context.temp_allocator)
    size,_:=store.blob_size(&s,address)
    store.read(&s,address,0,bytes[:size])
    again,decode_error:=snapshot_decode(bytes[:size],context.temp_allocator)
    testing.expect_value(t,decode_error,Snapshot_Error.None)
    testing.expect(t,again.name=="game" && len(again.entries)==len(snap.entries))
    for e,at in again.entries {testing.expectf(t,e==snap.entries[at],"%s round-trips",e.path)}

    // Taken again with nothing changed, nothing is read into the store and the blob is the same.
    _,second,second_report,_:=snapshot_take(&s,root,"game",context.temp_allocator)
    testing.expect(t,second==address && second_report.put==0,"the index knows every file")

    // A file read just after it was written is not learned: a change of the same size within the same time is read.
    // A time in whole seconds, which every system keeps exactly.
    moment:=time.from_nanoseconds(time.to_unix_nanoseconds(time.now())/1e9*1e9)
    file_put(root,"assets/fresh.txt",transmute([]u8)string("one"))
    os.change_times(fmt.tprintf("%s/assets/fresh.txt",root),moment,moment)
    snapshot_take(&s,root,"game",context.temp_allocator)
    file_put(root,"assets/fresh.txt",transmute([]u8)string("two"))
    os.change_times(fmt.tprintf("%s/assets/fresh.txt",root),moment,moment)
    later,_,_,_:=snapshot_take(&s,root,"game",context.temp_allocator)
    fresh,_:=snapshot_find(&later,"assets/fresh.txt")
    testing.expect(t,fresh.address==store.address_of_bytes(transmute([]u8)string("two")),"the second bytes are shared")

    // A file that changed after it was listed: its entry has the size of what was put, which the joiner checks, and the index does not learn it.
    file_put(root,"assets/growing.txt",transmute([]u8)string("abc"))
    settle(root,"assets/growing.txt")
    listed,_:=os.stat(fmt.tprintf("%s/assets/growing.txt",root),context.temp_allocator)
    file_put(root,"assets/growing.txt",transmute([]u8)string("abcdef"))
    index:=make(Index,context.temp_allocator)
    e,put,put_error:=entry_take(&s,&index,root,"assets/growing.txt",listed,context.temp_allocator)
    testing.expect(t,put_error==.None && put && e.size==6 && e.address==store.address_of_bytes(transmute([]u8)string("abcdef")))
    testing.expect(t,"assets/growing.txt" not_in index,"what changed while it was read is read again next time")
}

@(test)
hostile_snapshots_are_refused_without_a_crash :: proc(t:^testing.T) {
    empty:=store.address_of_bytes(nil)
    some:=store.address_of_bytes(transmute([]u8)string("x"))
    Case :: struct {entries:[]Entry,error:Snapshot_Error}
    cases:=[?]Case{
        {{{path="../x",address=some,size=1}},.Path},
        {{{path="a/../b",address=some,size=1}},.Path},
        {{{path="/etc/passwd",address=some,size=1}},.Path},
        {{{path="C:/x",address=some,size=1}},.Path},
        {{{path="a\\b",address=some,size=1}},.Path},
        {{{path="a//b",address=some,size=1}},.Path},
        {{{path="a/",address=some,size=1}},.Path},
        {{{path="nul",address=some,size=1}},.Path},
        {{{path="x/Com1.txt",address=some,size=1}},.Path},
        {{{path="x/name.",address=some,size=1}},.Path},
        {{{path=".mirai/share/snapshot",address=some,size=1}},.Path},
        {{{path=".git/config",address=some,size=1}},.Path},
        {{{path="",address=some,size=1}},.Path},
        {{{path="a",address=some,size=1},{path="a",address=some,size=1}},.Duplicate},
        {{{path="A.txt",address=some,size=1},{path="a.txt",address=some,size=1}},.Duplicate},
        {{{path="a",address=some,size=1},{path="a/b",address=some,size=1}},.Duplicate},
        {{{path="b",address=some,size=1},{path="a",address=some,size=1}},.Duplicate},
        {{{path="a",address=some,size=FILE_MAX_BYTES+1}},.Size},
        {{{path="a",address=some,size=-1}},.Size},
        {{{path="a",address=some,size=0}},.Size},
        {{{path="a",address=empty,size=0},{path="b",address=some,size=1}},.None},
    }
    for c in cases {
        bytes,_:=snapshot_encode({name="game",entries=c.entries},context.temp_allocator)
        _,error:=snapshot_decode(bytes,context.temp_allocator)
        testing.expectf(t,error==c.error,"%v: %v, not %v",c.entries,error,c.error)
    }
    good,_:=snapshot_encode({name="game",entries={{path="a",address=some,size=1},{path="b/c",address=some,size=1}}},context.temp_allocator)
    for cut in 0..<len(good) {
        _,error:=snapshot_decode(good[:cut],context.temp_allocator)
        testing.expectf(t,error!=.None,"a snapshot cut at %d is refused",cut)
    }
    // A count of entries the bytes cannot hold, a name that is not a folder, bytes after the end.
    lying:=make([]u8,len(good),context.temp_allocator)
    copy(lying,good)
    lying[len(SNAPSHOT_MAGIC)+2+4+3]=0x7f
    _,lie:=snapshot_decode(lying,context.temp_allocator)
    testing.expect(t,lie!=.None)
    badly,_:=snapshot_encode({name="..",entries={}},context.temp_allocator)
    _,named:=snapshot_decode(badly,context.temp_allocator)
    testing.expect_value(t,named,Snapshot_Error.Name)
    longer:=make([]u8,len(good)+1,context.temp_allocator)
    copy(longer,good)
    _,trailing:=snapshot_decode(longer,context.temp_allocator)
    testing.expect_value(t,trailing,Snapshot_Error.Not_Snapshot)
    oversized:=make([]u8,SNAPSHOT_MAX_BYTES+1,context.temp_allocator)
    copy(oversized,good)
    _,large:=snapshot_decode(oversized,context.temp_allocator)
    testing.expect_value(t,large,Snapshot_Error.Too_Large)
    for seed in 0..<64 {
        random:=noise(int(seed)*37,u64(seed))
        if seed%2==0 && len(random)>len(SNAPSHOT_MAGIC) {copy(random,SNAPSHOT_MAGIC)}
        snapshot_decode(random,context.temp_allocator)
    }
}

@(test)
a_join_reproduces_the_files_and_loads_the_packages_without_sources :: proc(t:^testing.T) {
    w:Test_Net
    if !test_net(t,&w,"share-join",2) {return}
    defer test_net_destroy(&w)
    root,ok:=host_project(t,&w)
    if !ok {return}
    test_connect(&w,1,0)
    report,error:=test_join(t,&w,1,join_desc(&w,0,""))
    if !testing.expectf(t,error=="","%s",error) {return}
    joined:=fmt.tprintf("%s/game",w.folder)
    testing.expect_value(t,report.folder,joined)
    testing.expect(t,len(report.kept)==0 && report.written==report.files)
    same_files(t,root,joined)
    testing.expect(t,!os.exists(fmt.tprintf("%s/.mirai/cache",joined)) && !os.exists(fmt.tprintf("%s/.git",joined)),"what is not the project's stays home")
    testing.expectf(t,len(report.packages.failures)==0 && len(report.packages.missing)==0 && report.packages.fetched==1,"%v",report.packages)
    listed,listed_error:=asset.root_packages(joined,w.peers[1].s.root,context.temp_allocator)
    testing.expect_value(t,listed_error,asset.Error.None)
    testing.expectf(t,len(listed.problems)==0 && len(listed.listed)>0,"%v",listed)
    for l in listed.listed {
        a:asset.Asset
        if testing.expectf(t,asset.asset_open_object(&a,&w.peers[1].s,l.object,context.temp_allocator)==.None,"%s loads on the joiner",l.path) {
            testing.expect_value(t,a.blob.header.id,l.id)
            asset.asset_close(&a)
        }
    }
}

@(test)
a_second_join_updates_the_folder_by_three_ways :: proc(t:^testing.T) {
    w:Test_Net
    if !test_net(t,&w,"share-update",2) {return}
    defer test_net_destroy(&w)
    root:=fmt.tprintf("%s/host",w.folder)
    for name in ([?]string{"host_changes","host_removes","both_change","host_removes_joiner_changes","joiner_removes_host_changes","joiner_changes","same","Case_only","Case_changed"}) {
        file_put(root,fmt.tprintf("files/%s.txt",name),transmute([]u8)fmt.tprintf("%s 1",name))
    }
    file_put(root,"Folder/inside.txt",transmute([]u8)string("inside 1"))
    if !host_offer(t,&w,root) {return}
    test_connect(&w,1,0)
    joined:=fmt.tprintf("%s/joined",w.folder)
    if _,error:=test_join(t,&w,1,join_desc(&w,0,joined));!testing.expectf(t,error=="","%s",error) {return}

    file_put(root,"files/host_changes.txt",transmute([]u8)string("host 2"))
    os.remove(fmt.tprintf("%s/files/host_removes.txt",root))
    file_put(root,"files/added/new.txt",transmute([]u8)string("new"))
    file_put(root,"files/both_change.txt",transmute([]u8)string("host 2"))
    os.remove(fmt.tprintf("%s/files/host_removes_joiner_changes.txt",root))
    file_put(root,"files/joiner_removes_host_changes.txt",transmute([]u8)string("host 2"))
    file_put(joined,"files/both_change.txt",transmute([]u8)string("joiner 2"))
    file_put(joined,"files/host_removes_joiner_changes.txt",transmute([]u8)string("joiner 2"))
    os.remove(fmt.tprintf("%s/files/joiner_removes_host_changes.txt",joined))
    file_put(joined,"files/joiner_changes.txt",transmute([]u8)string("joiner 2"))
    // Renames that change only the case: of a file, of a file with its bytes, of a folder.
    os.rename(fmt.tprintf("%s/files/Case_only.txt",root),fmt.tprintf("%s/files/case_only.txt",root))
    os.rename(fmt.tprintf("%s/files/Case_changed.txt",root),fmt.tprintf("%s/files/case_changed.txt",root))
    file_put(root,"files/case_changed.txt",transmute([]u8)string("changed 2"))
    os.rename(fmt.tprintf("%s/Folder",root),fmt.tprintf("%s/folder",root))
    if !host_offer(t,&w,root) {return}
    report,error:=test_join(t,&w,1,join_desc(&w,0,joined))
    if !testing.expectf(t,error=="","%s",error) {return}
    read :: proc(root,name:string) -> string {
        data,error:=os.read_entire_file(fmt.tprintf("%s/files/%s",root,name),context.temp_allocator)
        return error==nil?string(data):"(none)"
    }
    testing.expect_value(t,read(joined,"host_changes.txt"),"host 2")
    testing.expect_value(t,read(joined,"host_removes.txt"),"(none)")
    testing.expect_value(t,read(joined,"added/new.txt"),"new")
    testing.expect_value(t,read(joined,"both_change.txt"),"joiner 2")
    testing.expect_value(t,read(joined,"host_removes_joiner_changes.txt"),"joiner 2")
    testing.expect_value(t,read(joined,"joiner_removes_host_changes.txt"),"(none)")
    testing.expect_value(t,read(joined,"joiner_changes.txt"),"joiner 2")
    testing.expect_value(t,read(joined,"same.txt"),"same 1")
    // Where case folds, a rename by case is one file renamed in place; elsewhere one removed and one written.
    folds:=folds_case(joined)
    testing.expectf(t,report.written==(folds?3:5) && report.removed==(folds?1:4),"the host's changes and its new file are written, its removals applied: %d, %d",report.written,report.removed)
    names :: proc(folder:string) -> string {
        listed,_:=os.read_all_directory_by_path(folder,context.temp_allocator)
        list:=make([dynamic]string,context.temp_allocator)
        for info in listed {append(&list,info.name)}
        return strings.join(list[:]," ",context.temp_allocator)
    }
    renamed :: proc(t:^testing.T,joined:string) {
        testing.expect_value(t,read_text(joined,"files/case_only.txt"),"Case_only 1")
        testing.expect_value(t,read_text(joined,"files/case_changed.txt"),"changed 2")
        testing.expect_value(t,read_text(joined,"folder/inside.txt"),"inside 1")
        listed:=fmt.tprintf("%s %s",names(fmt.tprintf("%s/files",joined)),names(joined))
        testing.expectf(t,strings.contains(listed,"case_only.txt") && strings.contains(listed,"case_changed.txt") && strings.contains(listed,"folder") && !strings.contains(listed,"Case_") && !strings.contains(listed,"Folder"),"the names are the host's: %s",listed)
    }
    renamed(t,joined)
    kept:=strings.join(report.kept[:],"\n",context.temp_allocator)
    testing.expectf(t,len(report.kept)==3 && strings.contains(kept,"both_change") && strings.contains(kept,"host_removes_joiner_changes") && strings.contains(kept,"joiner_removes_host_changes"),"what both changed is reported: %s",kept)

    // Once more with nothing changed on either side: nothing is written, and what was kept stays kept.
    again,again_error:=test_join(t,&w,1,join_desc(&w,0,joined))
    testing.expect(t,again_error=="" && again.written==0 && again.removed==0)
    renamed(t,joined)
}

// A join does not overwrite what the joiner changes after its plan: a file
// made where the host adds one, a file changed that the host changed too.
@(test)
a_join_keeps_what_the_joiner_changes_while_it_runs :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"share-meanwhile")
    if folder=="" {return}
    s,open_error:=store.open(fmt.tprintf("%s/store",folder))
    if !testing.expect_value(t,open_error,store.Error.None) {return}
    defer store.close(&s)
    n:Node
    n.s=&s
    d:=Join_Desc{node=&n}
    joined:=fmt.tprintf("%s/joined",folder)
    bytes :: proc(text:string) -> []u8 {return transmute([]u8)text}
    entries:=make([]Entry,3,context.temp_allocator)
    for name,k in ([3]string{"a","b","c"}) {
        address,_:=store.put_bytes(&s,bytes(fmt.tprintf("host %s",name)))
        entries[k]={path=fmt.tprintf("%s.txt",name),address=address,size=6}
    }
    snap:=Snapshot{name="game",entries=entries}
    file_put(joined,"b.txt",bytes("base b"))
    file_put(joined,"c.txt",bytes("base c"))
    plan:Plan
    plan.write=make([dynamic]Write,context.temp_allocator)
    append(&plan.write,Write{at=0},Write{at=1,present=true,base=store.address_of_bytes(bytes("base b"))},Write{at=2,present=true,base=store.address_of_bytes(bytes("base c"))})
    // After the plan, before the blobs arrive.
    file_put(joined,"a.txt",bytes("mine a"))
    file_put(joined,"b.txt",bytes("mine b"))
    index:=make(Index,context.temp_allocator)
    report:=Join_Report{kept=make([dynamic]string,context.temp_allocator),failed=make([dynamic]string,context.temp_allocator)}
    join_write(&d,&snap,&plan,{0,1,2},&index,joined,&report)
    testing.expect_value(t,read_text(joined,"a.txt"),"mine a")
    testing.expect_value(t,read_text(joined,"b.txt"),"mine b")
    testing.expect_value(t,read_text(joined,"c.txt"),"host c")
    testing.expectf(t,report.written==1 && len(report.kept)==2 && len(report.failed)==0,"%v",report)
    for w in plan.write {testing.expect(t,w.done,"what is kept on purpose is done")}
}

// A file that cannot be written does not stop the join: a read-only file, a
// read-only file the host removed and a file in a read-only folder are listed
// with how to fix them, the rest is written, and once fixed the same join
// completes them.
@(test)
a_join_writes_what_it_can_and_running_it_again_completes_it :: proc(t:^testing.T) {
    w:Test_Net
    if !test_net(t,&w,"share-incomplete",2) {return}
    defer test_net_destroy(&w)
    root:=fmt.tprintf("%s/host",w.folder)
    for name in ([?]string{"files/a.txt","files/locked.txt","files/gone.txt","shut/x.txt"}) {file_put(root,name,transmute([]u8)fmt.tprintf("%s 1",name))}
    if !host_offer(t,&w,root) {return}
    test_connect(&w,1,0)
    joined:=fmt.tprintf("%s/joined",w.folder)
    if _,error:=test_join(t,&w,1,join_desc(&w,0,joined));!testing.expectf(t,error=="","%s",error) {return}

    file_put(root,"files/a.txt",transmute([]u8)string("a 2"))
    file_put(root,"files/locked.txt",transmute([]u8)string("locked 2"))
    os.remove(fmt.tprintf("%s/files/gone.txt",root))
    file_put(root,"shut/new.txt",transmute([]u8)string("new"))
    if !host_offer(t,&w,root) {return}
    read_only:=os.Permissions_Read_All
    os.change_mode(fmt.tprintf("%s/files/locked.txt",joined),read_only)
    os.change_mode(fmt.tprintf("%s/files/gone.txt",joined),read_only)
    os.change_mode(fmt.tprintf("%s/shut",joined),read_only+os.Permissions_Execute_All)
    fix :: proc(joined:string) {
        os.change_mode(fmt.tprintf("%s/files/locked.txt",joined),os.Permissions_Default_File)
        os.change_mode(fmt.tprintf("%s/files/gone.txt",joined),os.Permissions_Default_File)
        os.change_mode(fmt.tprintf("%s/shut",joined),os.Permissions_Default_Directory)
    }
    defer fix(joined)
    report,error:=test_join(t,&w,1,join_desc(&w,0,joined))
    if !testing.expectf(t,error=="","%s",error) {return}
    testing.expect_value(t,read_text(joined,"files/a.txt"),"a 2")
    testing.expect_value(t,read_text(joined,"files/locked.txt"),"files/locked.txt 1")
    testing.expect_value(t,read_text(joined,"files/gone.txt"),"files/gone.txt 1")
    testing.expect_value(t,read_text(joined,"shut/new.txt"),"(none)")
    listed:=strings.join(report.failed[:],"\n",context.temp_allocator)
    testing.expectf(t,len(report.failed)==3 && strings.contains(listed,"locked.txt is read-only") && strings.contains(listed,"gone.txt is read-only") && strings.contains(listed,"shut is read-only"),"each failure by path, with how to fix it: %s",listed)
    testing.expect(t,report.written==1 && report.removed==0)

    fix(joined)
    again,again_error:=test_join(t,&w,1,join_desc(&w,0,joined))
    if !testing.expectf(t,again_error=="","%s",again_error) {return}
    testing.expectf(t,len(again.failed)==0 && len(again.kept)==0 && again.written==2 && again.removed==1,"%v",again)
    same_files(t,root,joined)
}

@(test)
a_stopped_join_resumes_without_fetching_again_what_it_has :: proc(t:^testing.T) {
    w:Test_Net
    if !test_net(t,&w,"share-resume",2) {return}
    defer test_net_destroy(&w)
    root:=fmt.tprintf("%s/host",w.folder)
    for k in 0..<8 {file_put(root,fmt.tprintf("data/%d.bin",k),noise(512<<10,u64(10+k)))}
    if !host_offer(t,&w,root) {return}
    test_connect(&w,1,0)
    joined:=fmt.tprintf("%s/joined",w.folder)
    TOTAL :: 8*(512<<10)
    _,stopped:=test_join(t,&w,1,join_desc(&w,0,joined),TOTAL/2)
    testing.expect(t,strings.contains(stopped,"stopped"),"the join was stopped")
    first:=node_totals(&w.peers[1].n).received
    testing.expectf(t,first>=TOTAL/2 && first<TOTAL,"it stopped in the middle: %d bytes",first)

    // Run again: a new node over the same store.
    node_destroy(&w.peers[1].n)
    if !testing.expect_value(t,node_init(&w.peers[1].n,&w.peers[1].s),.None) {return}
    node_host(&w.peers[1].n,w.peers[1].server)
    w.peers[1].pumped=true
    wire.host_destroy(w.peers[1].client)
    free(w.peers[1].client)
    w.peers[1].client=nil
    test_connect(&w,1,0)
    report,error:=test_join(t,&w,1,join_desc(&w,0,joined))
    if !testing.expectf(t,error=="","%s",error) {return}
    again:=node_totals(&w.peers[1].n).received
    // What arrived before the stop is in the store, whole blobs and chunks of others: it is not asked again.
    testing.expectf(t,first+again<=TOTAL+store.CHUNK_MAX+exchange.ROOT_BUDGET,"%d bytes received again after %d",again,first)
    testing.expect(t,report.fetched>0,"the resume fetched the rest")
    same_files(t,root,joined)
}

@(test)
a_third_peer_joins_from_the_second :: proc(t:^testing.T) {
    w:Test_Net
    if !test_net(t,&w,"share-third",3) {return}
    defer test_net_destroy(&w)
    root,ok:=host_project(t,&w)
    if !ok {return}
    test_connect(&w,1,0)
    second:=fmt.tprintf("%s/second",w.folder)
    desc:=join_desc(&w,0,second)
    digits:[64]u8
    desc.own_offer=offer_name(w.peers[1].token,&digits)
    if _,error:=test_join(t,&w,1,desc);!testing.expectf(t,error=="","%s",error) {return}
    // The host is gone: all comes from the second.
    w.peers[0].pumped=false
    test_connect(&w,2,1)
    third:=fmt.tprintf("%s/third",w.folder)
    report,error:=test_join(t,&w,2,join_desc(&w,1,third))
    if !testing.expectf(t,error=="","%s",error) {return}
    same_files(t,root,third)
    testing.expectf(t,len(report.packages.missing)==0 && report.packages.fetched==1,"%v",report.packages)
}

// A host whose snapshot lies about a size, and a blob above the limit asked
// for, are refused without writing anything.
@(test)
a_lying_size_and_an_oversized_blob_are_refused :: proc(t:^testing.T) {
    w:Test_Net
    if !test_net(t,&w,"share-lies",2) {return}
    defer test_net_destroy(&w)
    s:=&w.peers[0].s
    data:=noise(200<<10,5)
    address,_:=store.put_bytes(s,data)
    bytes,_:=snapshot_encode({name="game",entries={{path="a.bin",address=address,size=100}}},context.temp_allocator)
    snapshot,_:=store.put_bytes(s,bytes)
    digits:[64]u8
    store.ref_set(s,NAMESPACE,offer_name(w.peers[0].token,&digits),snapshot)
    test_connect(&w,1,0)
    joined:=fmt.tprintf("%s/joined",w.folder)
    lied,error:=test_join(t,&w,1,join_desc(&w,0,joined))
    testing.expectf(t,error=="" && len(lied.failed)==1 && strings.contains(lied.failed[0],"not honest"),"%s %v",error,lied.failed)
    testing.expect(t,!os.exists(fmt.tprintf("%s/a.bin",joined)))

    run:=Test_Join{desc=join_desc(&w,0,joined),allocator=test_arena(t)}
    run.desc.node=&w.peers[1].n
    big:=address
    context.user_ptr=&big
    th:=thread.create_and_start_with_data(&run,proc(data:rawptr) {
        r:=(^Test_Join)(data)
        _,r.error=join_blob(&r.desc,(^store.Hash)(context.user_ptr)^,1000,"a blob",r.allocator)
        free_all(context.temp_allocator)
        sync.atomic_store(&r.done,true)
    },init_context=context)
    for !sync.atomic_load(&run.done) {test_step(&w)}
    thread.join(th)
    thread.destroy(th)
    testing.expectf(t,strings.contains(run.error,"more than"),"%s",run.error)
}
