package editor

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "mirai:asset"
import "mirai:cook/import/sources"
import "mirai:cook/share"
import "mirai:core"
import "mirai:editor/history"
import wire "mirai:net"
import "mirai:std/base"
import "mirai:store"

// An editor of a session over a simulated network: its project at its root,
// its assets under assets/ and a store of its own.
@(private="file")
Share_End :: struct {
    using f:Prefab_Fixture,
    store_root:string,
}

@(private="file")
share_end_init :: proc(t:^testing.T,e:^Share_End,name:string) -> bool {
    if !prefab_fixture_init(t,&e.f,name) {return false}
    assets:=fmt.aprintf("%s/assets",e.root)
    os.make_directory_all(assets)
    asset.registry_destroy(&e.assets.registry)
    asset.registry_init(&e.assets.registry,assets)
    e.s.assets_root=assets
    e.s.project_root=e.root
    e.s.has_project=true
    e.store_root=base.test_folder(t,fmt.tprintf("%s-store",name))
    opened,error:=store.open(e.store_root)
    if !testing.expect_value(t,error,store.Error.None) {return false}
    e.s.store=opened
    w:=edited_world(&e.s)
    core.world_settle(w)
    history.edits_reset(&e.edits,w)
    return true
}

@(private="file")
share_end_destroy :: proc(e:^Share_End) {
    collab_close(&e.s)
    store.close(&e.s.store)
    delete(e.s.assets_root)
    prefab_fixture_destroy(&e.f)
}

// frame: the temporary memory of the editors' frames, freed and written over at the end of each.
@(private="file")
Share_Net :: struct {
    sim:wire.Sim_Network,
    now:f64,
    host,guest:^Share_End,
    frame:mem.Arena,
    frame_bytes:[]u8,
}

// One millisecond of the network: each editor updates its session as a frame
// does between frames, then its host sends, and the frame's temporary memory goes.
@(private="file")
share_step :: proc(n:^Share_Net) {
    context.temp_allocator=mem.arena_allocator(&n.frame)
    n.now+=0.001
    wire.sim_network_advance(&n.sim,n.now)
    for e in ([2]^Share_End{n.host,n.guest}) {
        if st:=collab_state(&e.s);st!=nil {
            st.now=n.now
            collab_update(&e.s)
        }
        if st:=collab_state(&e.s);st!=nil {wire.host_update(&st.host,n.now)}
        prefab_fixture_step(&e.f)
    }
    // As the end of a frame, and the next one writing over that memory: what the thread of a
    // join holds is its own.
    free_all(context.temp_allocator)
    mem.set(raw_data(n.frame_bytes),0xaa,64<<10)
}

// Steps until the guest is in the scene or its session ended, at most 600
// virtual seconds. The clock moves only while its join waits for it, as a
// join of cook/share runs in its tests.
@(private="file")
share_until_joined :: proc(t:^testing.T,n:^Share_Net,updates:=0) -> bool {
    for steps:=0;steps<600_000; {
        st:=collab_state(&n.guest.s)
        if !testing.expect(t,st!=nil) {return false}
        if st.phase==.Joined && st.updates>=updates && (updates==0 || st.join.finished) {return true}
        if st.phase==.Ended {return testing.expectf(t,false,"the session ended: %s",st.reason)}
        if j:=st.join;j!=nil && !j.finished && !sync.atomic_load(&j.done) && !share.node_waiting(st.node) {
            thread.yield()
            continue
        }
        share_step(n)
        steps+=1
    }
    return testing.expect(t,false,"the guest did not join in 600 virtual seconds")
}

// The host shares, the guest joins with the code of its invitation at the host's place on the
// network; each session on endpoints of its own, which nothing of an earlier one reaches.
@(private="file")
share_join :: proc(t:^testing.T,n:^Share_Net,first:=0) -> bool {
    // Called between frames, as the API is.
    context.temp_allocator=mem.arena_allocator(&n.frame)
    if error:=collab_host(&n.host.s,0,"Ana",wire.sim_endpoint_transport(&n.sim,first));!testing.expectf(t,error==.None,"%s",collab_error_say(&n.host.s,error)) {return false}
    code:=wire.invite_encode({lan=wire.address_ip4(127,0,0,1,COLLAB_PORT),token=collab_state(&n.host.s).invite},context.temp_allocator)
    if !testing.expect_value(t,collab_join(&n.guest.s,code,"Ben",at=wire.address_memory(first),transport=wire.sim_endpoint_transport(&n.sim,first+1)),Collab_Error.None) {return false}
    return share_until_joined(t,n)
}

@(private="file")
share_file :: proc(root,path:string,text:string) {
    full:=fmt.tprintf("%s/%s",root,path)
    os.make_directory_all(os.dir(full))
    _=os.write_entire_file(full,transmute([]u8)text)
}

@(private="file")
share_text :: proc(root,path:string) -> string {
    data,error:=os.read_entire_file(fmt.tprintf("%s/%s",root,path),context.temp_allocator)
    return error==nil?string(data):"(none)"
}

// A short sound in a WAV file.
@(private="file")
share_wav :: proc(samples:int) -> []u8 {
    file:=make([]u8,44+samples*2,context.temp_allocator)
    put :: proc(file:[]u8,at:int,value:u32,size:int) {for i in 0..<size {file[at+i]=u8(value>>uint(8*i))}}
    copy(file,"RIFF");put(file,4,u32(len(file)-8),4);copy(file[8:],"WAVEfmt ")
    put(file,16,16,4);put(file,20,1,2);put(file,22,1,2);put(file,24,48000,4);put(file,28,96000,4)
    put(file,32,2,2);put(file,34,16,2)
    copy(file[36:],"data");put(file,40,u32(samples*2),4)
    for i in 0..<samples*2 {file[44+i]=u8(i*31+i>>7)}
    return file
}

// The host's project: files of its own and a package whose source then leaves
// the machine, so a guest gets its build from the host alone; and a crate in its scene.
@(private="file")
share_host_project :: proc(t:^testing.T,n:^Share_Net) -> (crate:base.Entity_Id,ok:bool) {
    root:=n.host.root
    share_file(root,"project.mirai","{\n  \"name\": \"Game\"\n}\n")
    share_file(root,"game/game.odin","package game\n")
    share_file(root,"assets/notes.txt","host 1\n")
    source_folder:=base.test_folder(t,"collab-share-sources")
    _=os.write_entire_file(fmt.tprintf("%s/beep.wav",source_folder),share_wav(4800))
    options:=sources.Library_Options{store=&n.host.s.store,root=root}
    report,error:=sources.ingest(fmt.tprintf("%s/beep.wav",source_folder),options,allocator=context.temp_allocator)
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
    added:=sources.project_add(root,report.manifest,"assets/sounds",nil,options,context.temp_allocator)
    if !testing.expectf(t,len(added.failures)==0 && len(added.missing)==0,"%v",added) {return}
    testing.expect(t,os.remove(fmt.tprintf("%s/beep.wav",source_folder))==nil)
    s:=&n.host.s
    w:=edited_world(s)
    made:=entity_create(s,{name="Crate",named=true})
    core.world_settle(w)
    history.edits_reset(&n.host.edits,w)
    return api_entity_id(w,made),true
}

@(private="file")
share_net_init :: proc(t:^testing.T,n:^Share_Net,host,guest:^Share_End,name:string) -> bool {
    if !testing.expect(t,wire.sim_network_init(&n.sim,{seed=5,endpoints=4,packets=1<<16})) {return false}
    n.frame_bytes=make([]u8,16<<20)
    mem.arena_init(&n.frame,n.frame_bytes)
    n.host,n.guest=host,guest
    return share_end_init(t,host,fmt.tprintf("%s-host",name)) && share_end_init(t,guest,fmt.tprintf("%s-guest",name))
}

// A guest with an empty folder enters the session with the host's files, its
// packages listed and built from the host's store, and then its scene.
@(test)
a_guest_with_an_empty_folder_joins_with_the_hosts_files_and_packages_then_its_scene :: proc(t:^testing.T) {
    n:=new(Share_Net);defer free(n)
    host,guest:=new(Share_End),new(Share_End)
    defer {free(host);free(guest)}
    ok:=share_net_init(t,n,host,guest,"collab-share-empty")
    defer {share_end_destroy(guest);share_end_destroy(host);wire.sim_network_destroy(&n.sim);delete(n.frame_bytes)}
    if !ok {return}
    crate,made:=share_host_project(t,n)
    if !made || !share_join(t,n) {return}

    testing.expect_value(t,share_text(guest.root,"assets/notes.txt"),"host 1\n")
    testing.expect_value(t,share_text(guest.root,"game/game.odin"),"package game\n")
    testing.expect_value(t,share_text(guest.root,asset.PACKAGES_FILE),share_text(host.root,asset.PACKAGES_FILE))
    st:=collab_state(&guest.s)
    testing.expectf(t,len(st.join.report.kept)==0 && len(st.join.report.failed)==0 && len(st.join.report.packages.missing)==0,"%v",st.join.report)
    testing.expect_value(t,st.join.report.packages.fetched,1)
    listed,listed_error:=asset.root_packages(guest.root,guest.store_root,context.temp_allocator)
    testing.expect_value(t,listed_error,asset.Error.None)
    testing.expectf(t,len(listed.problems)==0 && len(listed.listed)>0,"%v",listed)
    for l in listed.listed {
        a:asset.Asset
        if testing.expectf(t,asset.asset_open_object(&a,&guest.s.store,l.object,context.temp_allocator)==.None,"%s is built on the guest",l.path) {asset.asset_close(&a)}
    }
    testing.expect(t,api_entity(edited_world(&guest.s),crate)!=core.NONE,"the guest has the host's scene")
    state:=share.join_progress_read(&st.join.progress)
    testing.expect_value(t,state.phase,share.Join_Phase.Done)
}

// A file the guest changed and the host changed too stays the guest's, and
// the guest is told; the rest comes from the host.
@(test)
a_guest_that_joins_again_keeps_its_own_edit_and_is_told :: proc(t:^testing.T) {
    n:=new(Share_Net);defer free(n)
    host,guest:=new(Share_End),new(Share_End)
    defer {free(host);free(guest)}
    ok:=share_net_init(t,n,host,guest,"collab-share-kept")
    defer {share_end_destroy(guest);share_end_destroy(host);wire.sim_network_destroy(&n.sim);delete(n.frame_bytes)}
    if !ok {return}
    if _,made:=share_host_project(t,n);!made || !share_join(t,n) {return}
    collab_leave(&guest.s)
    collab_leave(&host.s)

    share_file(host.root,"assets/notes.txt","host 2, longer\n")
    share_file(host.root,"game/game.odin","package game // 2\n")
    share_file(guest.root,"assets/notes.txt","mine\n")
    if !share_join(t,n,2) {return}
    testing.expect_value(t,share_text(guest.root,"assets/notes.txt"),"mine\n")
    testing.expect_value(t,share_text(guest.root,"game/game.odin"),"package game // 2\n")
    st:=collab_state(&guest.s)
    status:Api_Collab_Join
    api_collab_join_result(st.join,&status)
    testing.expect_value(t,status.kept_count,1)
    testing.expect(t,strings.contains(base.text_get(status.kept[0].text[:]),"assets/notes.txt"),base.text_get(status.kept[0].text[:]))
}

// What the host changes in its folder during the session reaches the guest
// without leaving it: a change, a new file, a removal and a move are the
// host's; a file both changed and one only the guest changed stay the
// guest's, the first listed. Only what differs travels, and a scene edit the
// session carries live arrives once.
@(test)
what_the_host_changes_in_the_session_reaches_the_guest_by_three_ways :: proc(t:^testing.T) {
    n:=new(Share_Net);defer free(n)
    host,guest:=new(Share_End),new(Share_End)
    defer {free(host);free(guest)}
    ok:=share_net_init(t,n,host,guest,"collab-share-update")
    defer {share_end_destroy(guest);share_end_destroy(host);wire.sim_network_destroy(&n.sim);delete(n.frame_bytes)}
    if !ok {return}
    if _,made:=share_host_project(t,n);!made {return}
    Case :: struct {path,host,guest,then:string,kept:bool}
    cases:=[?]Case{
        {path="assets/change.txt",host="host 2, changed\n",then="host 2, changed\n"},
        {path="assets/added/new.txt",host="new\n",then="new\n"},
        {path="assets/delete.txt",host="(none)",then="(none)"},
        {path="assets/move.txt",host="(none)",then="(none)"},
        {path="assets/moved/move.txt",host="moved\n",then="moved\n"},
        {path="assets/both.txt",host="host 2, both\n",guest="guest 2\n",then="guest 2\n",kept=true},
        {path="assets/mine.txt",guest="guest only\n",then="guest only\n"},
    }
    for c in cases {
        if c.path!="assets/added/new.txt" && c.path!="assets/moved/move.txt" {share_file(host.root,c.path,c.path=="assets/move.txt"?"moved\n":"1\n")}
    }
    if !share_join(t,n) {return}
    gst:=collab_state(&guest.s)
    first:=share.node_totals(gst.node).received
    for c in cases {
        switch c.host {
        case "":
        case "(none)": os.remove(fmt.tprintf("%s/%s",host.root,c.path))
        case: share_file(host.root,c.path,c.host)
        }
        if c.guest!="" {share_file(guest.root,c.path,c.guest)}
    }
    // A scene edit of the host travels live as ever, while the update runs.
    hw:=edited_world(&host.s)
    made:=entity_create(&host.s,{name="Lamp",named=true})
    core.world_settle(hw)
    lamp:=api_entity_id(hw,made)
    collab_project_touched(&host.s)
    if !share_until_joined(t,n,updates=1) {return}

    for c in cases {testing.expectf(t,share_text(guest.root,c.path)==c.then,"%s: %q",c.path,share_text(guest.root,c.path))}
    kept:=strings.join(gst.join.report.kept[:],"\n",context.temp_allocator)
    testing.expectf(t,len(gst.join.report.kept)==1 && strings.contains(kept,"assets/both.txt"),"what both changed is listed: %s",kept)
    testing.expect_value(t,collab_state(&host.s).offers,1)
    update:=share.node_totals(gst.node).received-first
    testing.expectf(t,update>0 && update<first/2,"only what differs travels: %d bytes after %d",update,first)
    testing.expect(t,api_entity(edited_world(&guest.s),lamp)!=core.NONE,"the live edit arrived")
    testing.expect_value(t,guest.world.entities.alive,host.world.entities.alive)
}
