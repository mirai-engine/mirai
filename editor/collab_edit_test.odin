package editor

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:editor/api"
import "mirai:editor/history"
import "mirai:host"
import wire "mirai:net"
import "mirai:std/base"

@(test)
an_edit_of_another_end_makes_entities_that_its_other_rows_name_by_id :: proc(t:^testing.T) {
    f:=new(Play_Test);defer free(f)
    if !play_test_open(t,f) {return}
    defer play_test_close(f)
    s:=&f.s
    st:=new(Collab_State);defer free(st)
    collab_tables_build(s,st)
    defer collab_tables_free(st)
    // The other end adds a parent and a child that names it.
    other:Play_Test_World
    if !testing.expect(t,play_test_init(&other,context.allocator)) {return}
    defer play_test_free(&other)
    edits:history.Edits;defer history.edits_free(&edits)
    selection:history.Selection;defer delete(selection.entities)
    end:=Session{info=s.info,edit_world=&other,edits=&edits,selection=&selection}
    history.edits_reset(&edits,core.world_ref(&other,s.info))
    sent:=new(Collab_State);defer free(sent)
    sent.role,sent.phase=.Guest,.Joined
    collab_tables_build(&end,sent)
    defer collab_tables_free(sent)
    collab_journal_reset(&end,sent)
    parent,child:=core.create(&other.entities),core.create(&other.entities)
    core.add(&other.ids,parent,core.Id{50});core.add(&other.ids,child,core.Id{51})
    core.add(&other.transforms,parent,core.Transform{{1,0,0},1,{1,1,1}})
    core.add(&other.transforms,child,core.Transform{{0,2,0},1,{1,1,1}})
    core.add(&other.parents,child,core.Parent{entity=parent})
    play_test_settle(&other,nil,nil)
    collab_edits_send(&end,sent)
    for message in sent.peers[0].out {
        collab_edit_apply(s,st,message)
        delete(message)
    }
    delete(sent.peers[0].out)

    world:=cast(^Play_Test_World)f.data
    made,named:=core.entity_of(&world.entities,50),core.entity_of(&world.entities,51)
    if !testing.expect(t,made!=core.NONE && named!=core.NONE && made!=f.original) {return}
    testing.expect_value(t,world.entities.alive,3)
    link,linked:=core.get(core.read(&world.parents),named)
    testing.expect(t,linked && link.entity==made)
    local,_:=core.get(core.read(&world.transforms),named)
    testing.expect_value(t,local.position,[3]f32{0,2,0})
    testing.expect_value(t,core.entity_of(&world.entities,base.Entity_Id(1)),f.original)
}

// The scene of the host replaces the World only when all of it got there: one
// that fails halfway, after its entities were made, leaves the World as it
// was, and one that loads replaces it.
@(test)
a_scene_of_the_host_that_fails_halfway_leaves_the_world_as_it_was :: proc(t:^testing.T) {
    f:=new(Play_Test);defer free(f)
    if !play_test_open(t,f) {return}
    defer play_test_close(f)
    directory,_:=os.temp_directory(context.temp_allocator)
    folder:=fmt.tprintf("%s/mirai-collab-snapshot-%d",directory,os.get_pid())
    os.remove_all(folder)
    if !testing.expect(t,os.make_directory_all(folder)==nil) {return}
    defer os.remove_all(folder)
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=folder,capacity=8})) {return}
    defer host.assets_destroy(&assets)
    f.app.assets=&assets
    outliner:Outliner
    defer delete(outliner.expanded)
    f.s.outliner=&outliner
    st:=new(Collab_State);defer free(st)

    host_scene:asset.Scene
    asset.scene_init(&host_scene,&assets.types,asset.KIND_SCENE,{0x1c,1})
    defer asset.scene_destroy(&host_scene)
    placed:=core.Transform{{0,3,0},1,{1,1,1}}
    for i in 1..=64 {
        asset.scene_entity_add(&host_scene,base.Entity_Id(100+i),0,"Box")
        asset.scene_set(&host_scene,base.Entity_Id(100+i),"Transform",&placed)
    }
    good,error:=asset.scene_bytes(&host_scene,context.temp_allocator)
    if !testing.expect_value(t,error,asset.Error.None) {return}
    // The transforms of the broken copy do not decompress.
    broken:=make([]u8,len(good),context.temp_allocator)
    copy(broken,good)
    file:asset.Asset
    if !testing.expect_value(t,asset.asset_open(&file,broken),asset.Error.None) {return}
    view,_:=asset.scene_view(&file,&assets.types)
    entry:asset.Chunk_Entry
    for &component in view.components {
        if component.name=="Transform" {entry=asset.blob_chunk(&file.blob,component.table.columns[1].chunk)}
    }
    asset.asset_close(&file)
    if !testing.expect_value(t,entry.compression,asset.Compression.LZ) {return}
    mem.set(&broken[entry.offset],0xff,int(entry.size))

    world:=cast(^Play_Test_World)f.data
    testing.expect(t,!collab_snapshot_load(&f.s,st,broken))
    testing.expect_value(t,world.entities.alive,1)
    testing.expect_value(t,core.entity_of(&world.entities,base.Entity_Id(1)),f.original)
    testing.expect_value(t,host.app_world_count(&f.app),1)

    testing.expect(t,collab_snapshot_load(&f.s,st,good))
    testing.expect_value(t,world.entities.alive,64)
    testing.expect(t,!core.alive(&world.entities,f.original))
    box:=core.entity_of(&world.entities,base.Entity_Id(101))
    local,found:=core.get(core.read(&world.transforms),box)
    testing.expect(t,found && local.position==[3]f32{0,3,0})
    document_previous_free(&f.document)
}

// Selecting holds nothing: what another editor of the session has selected
// is edited like the rest, by the user and by an agent through the API, and
// it stays outlined in the color of whoever selected it.
@(test)
what_another_editor_selected_is_edited_and_stays_outlined :: proc(t:^testing.T) {
    f:=new(Prefab_Fixture);defer free(f)
    if !testing.expect(t,prefab_fixture_init(f,"collab-selected")) {return}
    defer prefab_fixture_destroy(f)
    for &storage in f.storages {
        if storage.info==nil {storage.info=type_info_of(storage.type)}
    }
    state:Api_State
    f.api.state=&state
    api_schema_build(&f.s,&state)
    defer api_schema_free(&state)
    s:=&f.s
    w:=edited_world(s)
    e:=entity_create(s,{name="Box",named=true})
    core.world_settle(w)
    history.edits_reset(&f.edits,w)
    id:=api_entity_id(w,e)
    st:=new(Collab_State)
    st.role,st.phase=.Host,.Joined
    st.peers[0]={used=true,joined=true}
    st.peers[1]={used=true,joined=true,has_pose=true,seen=wire.host_time(&st.host),selection_count=1}
    st.peers[1].selection[0]=id
    collab_tables_build(s,st)
    collab_journal_reset(s,st)
    f.collab.state=st
    defer {
        for message in st.peers[1].out {delete(message)}
        delete(st.peers[1].out)
        collab_tables_free(st)
        history.journal_reading(&f.edits,false)
        free(st)
        f.collab.state=nil
    }
    history.selection_set(&f.selection,{e})
    Edit :: enum u8 {Move,Scale,Rename,Write,Turn_Off}
    agent:=history.Edit_Author(7)
    cases:=[?]struct{edit:Edit,author:history.Edit_Author}{{.Move,history.EDIT_AUTHOR_USER},{.Scale,history.EDIT_AUTHOR_USER},{.Rename,history.EDIT_AUTHOR_USER},{.Write,agent},{.Move,agent},{.Turn_Off,history.EDIT_AUTHOR_USER}}
    for c,at in cases {
        steps,told:=len(f.edits.steps),st.sent_ops
        f.edits.author=c.author
        done:=true
        switch c.edit {
        case .Move: done=transform_set(s,e,{position={f32(at+1),0,0},rotation=1,scale=1})
        case .Scale:
            scale:=[3]f32{2,2,2}
            done=field_write(s,component_table(s,"Transform"),{e},int(offset_of(core.Transform,scale)),mem.ptr_to_bytes(&scale))
        case .Rename: done=entity_rename(s,e,"Crate")
        case .Write:
            method:=api.Method{result_id=Api_Write_Result}
            result:Api_Write_Result
            call:=api.Call{method=&method,result=&result,raw=fmt.tprintf(`{{"root":"0x%016x","entities":[{{"name":"Crate","position":[0,9,0]}}]}}`,u64(id)),allocator=context.temp_allocator}
            api_scene_write(s,&call)
            done=!call.failed
            testing.expect(t,done,call.error.message)
        case .Turn_Off: entity_enabled_set(s,e,false)
        }
        history.edits_commit(&f.edits,w,&f.selection)
        f.edits.author=history.EDIT_AUTHOR_USER
        if !testing.expectf(t,done && len(f.edits.steps)==steps+1,"%v by %d was not done",c.edit,c.author) {continue}
        testing.expect_value(t,f.edits.steps[steps].author,c.author)
        collab_edits_send(s,st)
        testing.expectf(t,st.sent_ops>told,"%v by %d was not told",c.edit,c.author)
    }
    testing.expect_value(t,entity_name(w,e),"Crate")
    testing.expect(t,core.has(&f.world.disabled,e))
    levels:=make([]u8,len(core.world_entities(w).generation),context.temp_allocator)
    levels[core.entity_index(e)]=HIGHLIGHT_SELECTED
    collab_highlights(s,w,levels)
    testing.expect_value(t,levels[core.entity_index(e)],agent_level(1))
}

// A file too large to travel stays where it was edited, and every editor of
// the session is told which, by whom and what makes it the same for all;
// once it travels, nobody is told of it any more.
@(test)
a_file_too_large_to_travel_is_told_to_every_editor :: proc(t:^testing.T) {
    host_end,guest_end:=new(Prefab_Fixture),new(Prefab_Fixture)
    defer {free(host_end);free(guest_end)}
    if !testing.expect(t,prefab_fixture_init(host_end,"collab-file-host")) {return}
    defer prefab_fixture_destroy(host_end)
    if !testing.expect(t,prefab_fixture_init(guest_end,"collab-file-guest")) {return}
    defer prefab_fixture_destroy(guest_end)
    for f,i in ([2]^Prefab_Fixture{host_end,guest_end}) {
        st:=new(Collab_State)
        st.role,st.phase,st.self=i==0?.Host:.Guest,.Joined,u8(i)
        st.peers[0]={used=true,joined=true}
        st.peers[1]={used=true,joined=true}
        st.peers[2]={used=i==0,joined=i==0} // another guest, for what the host passes on
        st.peers[1].name_length=copy(st.peers[1].name[:],"Ana")
        f.collab.state=st
    }
    defer for f in ([2]^Prefab_Fixture{host_end,guest_end}) {
        st:=f.collab.state
        for &peer in st.peers {
            for message in peer.out {delete(message)}
            delete(peer.out);delete(peer.file_bytes)
        }
        for path in st.files_out {delete(path)}
        delete(st.files_out)
        free(st)
        f.collab.state=nil
    }
    // What the guest changed goes to the host, which passes it on; how many messages the other guest got.
    send :: proc(guest,host:^Prefab_Fixture) -> (passed:int) {
        collab_files_send(&guest.s,guest.collab.state)
        out:=&guest.collab.state.peers[0].out
        for message in out {
            collab_receive(&host.s,host.collab.state,1,message,0)
            delete(message)
        }
        clear(out)
        other:=&host.collab.state.peers[2].out
        passed=len(other)
        for message in other {delete(message)}
        clear(other)
        return
    }
    status :: proc(f:^Prefab_Fixture) -> (result:Api_Collab_Status) {
        method:=api.Method{result_id=Api_Collab_Status}
        call:=api.Call{method=&method,result=&result,allocator=context.temp_allocator}
        api_collab_status(&f.s,&call)
        return
    }
    file:=fmt.tprintf("%s/paint.bin",guest_end.root)
    large:=make([]u8,COLLAB_FILE_BYTES+1);defer delete(large)
    cases:=[?]struct{bytes:[]u8,travels:bool}{{large[:64],true},{large,false},{large,false},{large[:32],true}}
    for c,at in cases {
        guest_end.s.toast_length,host_end.s.toast_length=0,0
        if !testing.expect(t,file_set(&guest_end.s,file,c.bytes)) {return}
        passed:=send(guest_end,host_end)
        held,found:=asset.registry_memory_find(&host_end.assets.registry,"paint.bin")
        told:=at>0 && cases[at-1].travels!=c.travels && !c.travels
        for f,i in ([2]^Prefab_Fixture{host_end,guest_end}) {
            toast:=string(f.s.toast[:f.s.toast_length])
            testing.expectf(t,told==(strings.contains(toast,"paint.bin") && strings.contains(toast,"repository")),"case %d, end %d: %s",at,i,toast)
            if i==0 && told {testing.expect(t,strings.contains(toast,"Ana"),toast)}
            result:=status(f)
            if !testing.expectf(t,result.unsent_count==(c.travels?0:1),"case %d, end %d: %d files unsent",at,i,result.unsent_count) || c.travels {continue}
            testing.expect(t,base.text_get(result.unsent[0].path[:])=="paint.bin" && result.unsent[0].peer==1 && result.unsent[0].bytes==u64(len(large)))
        }
        if c.travels {
            testing.expectf(t,found && len(held.data)==len(c.bytes) && passed>0,"case %d: the file reached the host and went on",at)
        } else {
            testing.expectf(t,(!found || len(held.data)!=len(c.bytes)) && passed==(told?1:0),"case %d: %d messages passed on",at,passed)
        }
    }
}
