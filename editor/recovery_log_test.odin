package editor

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:editor/history"
import "mirai:host"
import "mirai:platform"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/jobs"

@(private) Recovery_Score_Before :: struct {points:i32}
@(private) Recovery_Score_After :: struct {lives:u8,points:i64}

@(private)
@(test_world)
Recovery_Before_World :: struct {
    using world:Test_World,
    using scene_tables:Test_Scene,
    scores:core.Table(Recovery_Score_Before) `mirai:"name=Recovery_Score"`,
}

@(private)
@(test_world)
Recovery_After_World :: struct {
    using world:Test_World,
    using scene_tables:Test_Scene,
    scores:core.Table(Recovery_Score_After) `mirai:"name=Recovery_Score"`,
}

// A step logged by one build and put back by another that lays its component out otherwise
// converts by the names of the fields; a field the old layout lacks keeps what the row has.
@(test)
a_logged_step_converts_to_the_layout_of_a_later_build :: proc(t:^testing.T) {
    root:=base.test_folder(t,"recovery-layout")
    if root=="" {return}
    ID :: base.Entity_Id(77)
    before:Recovery_Before_World
    if !test_world_init(t,&before) {return}
    defer test_world_destroy(&before)
    e:=core.create(&before.entities)
    core.add(&before.ids,e,core.Id{ID})
    core.add(&before.scores,e,Recovery_Score_Before{7})
    test_world_settle(&before)
    logged:=new(Test_Session);defer free(logged)
    test_session_open(logged,test_world_ref(&before))
    defer test_session_close(logged)
    s:=&logged.s
    s.project_root=root
    defer recovery_log_destroy(s)
    recovery_log_begin(s)
    core.edit(&before.scores,e)^=Recovery_Score_Before{42}
    testing.expect(t,history.edits_commit(&logged.edits,edited_world(s),&logged.selection))
    recovery_log_write(s)
    recovery_log_close(s)
    file,read:=recovery_log_read(s,s.recovery.slot,1)
    if !testing.expect(t,read && len(file.records)==1) {return}

    after:Recovery_After_World
    if !test_world_init(t,&after) {return}
    defer test_world_destroy(&after)
    later:=core.create(&after.entities)
    core.add(&after.ids,later,core.Id{ID})
    core.add(&after.scores,later,Recovery_Score_After{lives=3,points=1})
    test_world_settle(&after)
    restored:=new(Test_Session);defer free(restored)
    test_session_open(restored,test_world_ref(&after))
    defer test_session_close(restored)
    applied,lost,_:=recovery_log_replay(&restored.s,{file})
    testing.expect(t,applied==1 && lost==0)
    test_world_settle(&after)
    score,_:=core.get(&after.scores,later)
    testing.expect(t,score.points==42 && score.lives==3,"the value converts")
}

@(test)
recovery_log_writes_each_step_over_the_saved_file_and_puts_them_back :: proc(t:^testing.T) {
    info,described:=prefab_test_info(t)
    if !described {return}
    defer test_info_destroy(&info)
    world:Prefab_Test_World
    if !testing.expect(t,core.world_init(&info,.World,&world,context.allocator)) {return}
    defer core.world_destroy(&info,.World,&world)
    root:=base.test_folder(t,"recovery-log")
    if root=="" {return}
    assets:host.Assets
    asset.types_init(&assets.types)
    defer asset.types_destroy(&assets.types)
    asset.registry_init(&assets.registry,root)
    defer asset.registry_destroy(&assets.registry)
    app:=host.App{assets=&assets,info=&info,allocator=context.allocator}
    defer delete(app.worlds)
    testing.expect(t,jobs.system_init(&app.jobs,{threads=1,allocator=context.allocator}))
    defer jobs.system_destroy(&app.jobs)
    selection:history.Selection
    edits:history.Edits
    document:Document
    editor:Prefab_Fixture_Editor
    s:=Session{info=&info,edit_world=&world,editor_world=&editor,assets_root=root,project_root=root,app=&app,selection=&selection,edits=&edits,document=&document}
    defer delete(selection.entities)
    defer history.edits_free(&edits)
    defer document_previous_free(&document)
    defer prefabs_free(&s)
    defer recovery_log_destroy(&s)
    w:=edited_world(&s)
    kept:=entity_create(&s,{name="Kept",transform={position={2,0,0},rotation=1,scale={1,1,1}}})
    core.world_settle(w)
    history.edits_reset(&edits,w)
    // A clean document with a file: the log follows that file.
    scene:=project.path(root,"kept.scene",allocator=context.temp_allocator)
    document_name(&document,"kept.scene",scene)
    document.saved=history.edits_scene_state(&edits)
    recovery_update(&s)
    testing.expect(t,s.recovery.log.following && s.recovery.log.base==.Source && edits.logging)
    testing.expect(t,os.is_file(recovery_log_path(&s,s.recovery.slot,1)))

    testing.expect(t,entity_rename(&s,kept,"Moved"))
    testing.expect(t,history.edits_commit(&edits,w,&selection))
    born:=entity_create(&s,{name="Born",transform={position={0,3,0},rotation=1,scale={1,1,1}}})
    testing.expect(t,history.edits_commit(&edits,w,&selection))
    testing.expect(t,born!=core.NONE)
    born_id:=api_entity_id(w,born)
    recovery_update(&s)
    testing.expect(t,s.recovery.log.records>0 && s.recovery.log.since!=0)
    testing.expect(t,len(edits.changes)==0,"what the log wrote leaves the journal")
    // Undoing in order is a step of the log too.
    testing.expect(t,history.undo(&edits,w,&selection))
    recovery_update(&s)
    testing.expect(t,!entity_alive(w,born))
    testing.expect(t,history.redo(&edits,w,&selection))
    recovery_update(&s)
    testing.expect(t,recovery_log_flush(&s,true))

    // A start after a crash: the chain over the saved file, every record whole.
    chain,records:=recovery_log_chain(&s,s.recovery.slot,0)
    testing.expect(t,len(chain)==1 && chain[0].base==.Source && chain[0].source==scene)
    testing.expect_value(t,records,s.recovery.log.records)
    // A record cut by a crash ends the chain there.
    file,_:=os.open(recovery_log_path(&s,s.recovery.slot,1),{.Write,.Append})
    os.write(file,[]u8{40,0,0,0,1,2,3})
    os.close(file)
    _,records_cut:=recovery_log_chain(&s,s.recovery.slot,0)
    testing.expect_value(t,records_cut,records)

    // Back to the saved state, the log puts the steps back by Id.
    recovery_log_end(&s,false)
    for history.undo(&edits,w,&selection) {}
    core.world_settle(w)
    testing.expect_value(t,entity_name(w,kept),"Kept")
    applied,lost,_:=recovery_log_replay(&s,chain)
    testing.expect(t,applied==records && lost==0)
    core.world_settle(w)
    testing.expect_value(t,entity_name(w,kept),"Moved")
    testing.expect_value(t,entity_name(w,api_entity(w,born_id)),"Born")

    // A copy names the generation after it; the ones before go once it is written.
    recovery_update(&s)
    document.unsaved=true
    s.recovery.deadline=platform.clock_ns()
    recovery_update(&s)
    testing.expect(t,recovery_wait(&s))
    generations:=recovery_log_generations(&s,s.recovery.slot)
    testing.expect(t,len(generations)==1 && generations[0]==s.recovery.log.generation,"the copy leaves only the generation that follows it")
}

// A tab at the back keeps the chain of its changes and writes nothing while
// it does not change; a start after a crash puts back every document that
// had changes, each in its tab.
@(test)
every_tab_with_changes_keeps_its_chain_and_a_start_recovers_them_all :: proc(t:^testing.T) {
    f:=new(Prefab_Fixture);defer free(f)
    if !prefab_fixture_init(t,f,"recovery-tabs") {return}
    defer prefab_fixture_destroy(f)
    s:=&f.s
    s.project_root=f.root
    testing.expect(t,jobs.system_init(&f.app.jobs,{threads=1,allocator=context.allocator}))
    defer jobs.system_destroy(&f.app.jobs)
    defer recovery_log_destroy(s)
    w:=edited_world(s)
    root:=entity_create(s,{name="Root",named=true})
    plain:=entity_create(s,{name="Plain",named=true})
    core.world_settle(w)
    history.edits_reset(&f.edits,w)

    plain_id,linked_id:=api_entity_id(w,plain),api_entity_id(w,root)
    _,created:=prefab_create(s,root,"kept")
    if !testing.expect_value(t,created,Prefab_Error.None) {return}
    prefab_fixture_step(f)
    if !testing.expect_value(t,scene_save(s,"main.scene"),Document_Error.None) {return}
    recovery_update(s)
    scene_slot:=s.recovery.slot
    entity_rename(s,api_entity(w,plain_id),"Changed in the scene")
    prefab_fixture_step(f)
    recovery_update(s)

    if !testing.expect_value(t,document_open_tab(s,"kept.scene"),Document_Error.None) {return}
    defer documents_free(s)
    recovery_update(s)
    prefab_slot:=s.recovery.slot
    testing.expect(t,prefab_slot!=0 && prefab_slot!=scene_slot)
    prefab_world:=edited_world(s)
    prefab_root:=test_only_root(prefab_world)
    root_id:=api_entity_id(prefab_world,prefab_root)
    entity_rename(s,prefab_root,"Changed in the prefab")
    prefab_fixture_step(f)
    recovery_update(s)

    // Back to the scene: the prefab keeps its chain and writes nothing more.
    testing.expect(t,document_activate(s,0))
    prefab_log:=recovery_log_path(s,prefab_slot,1)
    before,_:=os.stat(prefab_log,context.temp_allocator)
    entity_rename(s,api_entity(w,plain_id),"Changed again")
    prefab_fixture_step(f)
    recovery_update(s)
    after,_:=os.stat(prefab_log,context.temp_allocator)
    testing.expect(t,before.size>0 && after.size==before.size && after.modification_time==before.modification_time)

    // A crash: the chains stay; the next start finds a document in each.
    recovery_chains_close(s,false)
    documents_free(s)
    s.active_document=0
    s.recovery.chain={}
    scene_new(s)
    recovery_open(s)
    testing.expect(t,s.recovery.pending)
    if !testing.expect_value(t,len(s.recovery.found),2) {return}
    resolved,reason:=recovery_resolve(s,false)
    testing.expect(t,resolved && reason=="" && !s.recovery.pending,reason)
    if !testing.expect_value(t,len(s.documents),2) {return}
    testing.expect(t,document_activate(s,0))
    testing.expect(t,document_dirty(s) && !document_is_prefab(s))
    testing.expect_value(t,entity_name(edited_world(s),api_entity(edited_world(s),plain_id)),"Changed again")
    recovered,linked:=prefab_link_of(edited_world(s),api_entity(edited_world(s),linked_id))
    testing.expect(t,linked && recovered.root,"the instance comes back with the rows of its entities")
    testing.expect(t,document_activate(s,1))
    testing.expect(t,document_dirty(s) && document_is_prefab(s))
    testing.expect_value(t,entity_name(edited_world(s),api_entity(edited_world(s),root_id)),"Changed in the prefab")
    testing.expect(t,document_activate(s,0))
}

// What an editor left waits for the user whatever happens: this editor edits
// and saves under other files and a recovery opens beside its changes.
@(test)
a_pending_recovery_stays_aside_while_the_document_is_edited_and_saved :: proc(t:^testing.T) {
    f:=new(Prefab_Fixture);defer free(f)
    if !prefab_fixture_init(t,f,"recovery-aside") {return}
    defer prefab_fixture_destroy(f)
    s:=&f.s
    s.project_root=f.root
    testing.expect(t,jobs.system_init(&f.app.jobs,{threads=1,allocator=context.allocator}))
    defer jobs.system_destroy(&f.app.jobs)
    defer recovery_log_destroy(s)
    defer documents_free(s)
    defer recovery_wait(s)
    w:=edited_world(s)
    plain:=entity_create(s,{name="Plain",named=true})
    core.world_settle(w)
    history.edits_reset(&f.edits,w)

    plain_id:=api_entity_id(w,plain)
    if !testing.expect_value(t,scene_save(s,"crashed.scene"),Document_Error.None) {return}
    recovery_update(s)
    crashed_slot:=s.recovery.slot
    entity_rename(s,api_entity(w,plain_id),"Lost in the crash")
    prefab_fixture_step(f)
    recovery_update(s)
    testing.expect(t,recovery_log_flush(s,true))
    crash :: proc(s:^Session) {
        recovery_chains_close(s,false)
        documents_free(s)
        s.active_document=0
        s.recovery.chain={}
        scene_new(s)
        recovery_open(s)
    }

    // The next editor: an unsaved asset of an earlier editor and the chain above are offered.
    kept:=recovery_assets_folder(s,1)
    os.make_directory_all(kept)
    testing.expect(t,os.write_entire_file(fmt.tprintf("%s/%s",kept,UNSAVED_MANIFEST),transmute([]u8)string(`{"assets":[],"removed":[]}`))==nil)
    crash(s)
    testing.expect(t,s.recovery.pending && len(s.recovery.found)==1 && len(s.recovery.assets)==1,"the chain and the assets are offered")
    crashed_log:=recovery_log_path(s,crashed_slot,1)
    crashed_bytes,_:=os.read_entire_file(crashed_log,context.temp_allocator)
    testing.expect(t,len(crashed_bytes)>0)

    // Loading, editing and saving go on: another slot and another folder, the offer intact.
    w=edited_world(s)
    later:=entity_create(s,{name="Later",named=true})
    core.world_settle(w)
    history.edits_reset(&f.edits,w)

    entity_rename(s,later,"Edited meanwhile")
    prefab_fixture_step(f)
    testing.expect_value(t,scene_save(s,"later.scene"),Document_Error.None)
    entity_rename(s,later,"Still unsaved")
    prefab_fixture_step(f)
    recovery_update(s)
    live_slot:=s.recovery.slot
    testing.expect(t,live_slot!=0 && live_slot!=crashed_slot,"this editor writes under a slot of its own")
    testing.expect(t,recovery_assets_own(s)!=kept,"and under a folder of its own")
    now,_:=os.read_entire_file(crashed_log,context.temp_allocator)
    testing.expect(t,string(now)==string(crashed_bytes),"what is offered is not touched")
    testing.expect(t,s.recovery.pending && document_dirty(s))

    // Recovering opens it beside a tab with changes.
    resolved,reason:=recovery_resolve(s,false)
    testing.expect(t,resolved && reason=="" && !s.recovery.pending,reason)
    if !testing.expect_value(t,len(s.documents),2) {return}
    testing.expect_value(t,entity_name(edited_world(s),api_entity(edited_world(s),plain_id)),"Lost in the crash")
    testing.expect(t,document_activate(s,0))
    testing.expect_value(t,entity_name(edited_world(s),later),"Still unsaved")
    testing.expect(t,s.recovery.slot==live_slot && len(recovery_log_generations(s,live_slot))>0,"the chain of the tab with changes goes on")

    // Discarding what is offered leaves the chains of this editor.
    crash(s)
    testing.expect(t,s.recovery.pending && len(s.recovery.found)>0)
    offered:=s.recovery.found[0].slot
    w=edited_world(s)
    other:=entity_create(s,{name="Other",named=true})
    core.world_settle(w)
    history.edits_reset(&f.edits,w)

    entity_rename(s,other,"Mine")
    prefab_fixture_step(f)
    recovery_update(s)
    mine:=s.recovery.slot
    resolved,reason=recovery_resolve(s,true)
    testing.expect(t,resolved && reason=="" && !s.recovery.pending,reason)
    testing.expect(t,len(recovery_log_generations(s,offered))==0,"what was offered is gone")
    testing.expect(t,len(recovery_log_generations(s,mine))>0,"the chain of this editor stays")
    resolved,reason=recovery_resolve(s,false)
    testing.expect(t,!resolved && reason=="","with nothing offered there is nothing to resolve, and no error")
}

// A saved file that changed between the crash and the start (a checkout, a write from outside)
// is not what the log followed: its steps go over it in a copy under .mirai/tmp, and the file
// stays as it is.
@(test)
a_log_over_a_saved_file_that_changed_goes_back_in_a_copy :: proc(t:^testing.T) {
    f:=new(Prefab_Fixture);defer free(f)
    if !prefab_fixture_init(t,f,"recovery-changed") {return}
    defer prefab_fixture_destroy(f)
    s:=&f.s
    s.project_root=f.root
    testing.expect(t,jobs.system_init(&f.app.jobs,{threads=1,allocator=context.allocator}))
    defer jobs.system_destroy(&f.app.jobs)
    defer recovery_log_destroy(s)
    defer documents_free(s)
    w:=edited_world(s)
    plain:=entity_create(s,{name="Plain",named=true})
    core.world_settle(w)
    history.edits_reset(&f.edits,w)
    plain_id:=api_entity_id(w,plain)
    if !testing.expect_value(t,scene_save(s,"other.scene"),Document_Error.None) {return}
    entity_rename(s,plain,"Saved")
    prefab_fixture_step(f)
    if !testing.expect_value(t,scene_save(s,"crashed.scene"),Document_Error.None) {return}
    recovery_update(s)
    entity_rename(s,plain,"Lost in the crash")
    prefab_fixture_step(f)
    recovery_update(s)
    testing.expect(t,recovery_log_flush(s,true))

    crashed:=scene_file(s,"crashed.scene")
    other,_:=os.read_entire_file(scene_file(s,"other.scene"),context.temp_allocator)
    testing.expect(t,os.write_entire_file(crashed,other)==nil)
    recovery_chains_close(s,false)
    documents_free(s)
    s.active_document=0
    s.recovery.chain={}
    scene_new(s)
    recovery_open(s)
    resolved,reason:=recovery_resolve(s,false)
    testing.expectf(t,resolved && strings.contains(reason,"changed since"),"%s",reason)
    testing.expectf(t,strings.contains(document_file(s.document),".mirai/tmp/recovered-crashed.scene"),"%s",document_file(s.document))
    testing.expect_value(t,entity_name(edited_world(s),api_entity(edited_world(s),plain_id)),"Lost in the crash")
    now,_:=os.read_entire_file(crashed,context.temp_allocator)
    testing.expect(t,string(now)==string(other),"the file stays as it is")
}
