package editor

import "core:os"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:editor/ai_store"
import "mirai:editor/api"
import "mirai:editor/history"
import "mirai:host"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"

@(test_world)
Files_Test_World :: struct {
    using world:Test_World,
    ids:core.Table(core.Id),
}

// A session over a world of ids with its project in a folder of its own.
@(private)
Files_Test :: struct {
    world:Files_Test_World,
    using edited:Test_Session,
    ai:^Ai,
    root:string,
}

@(private)
files_test_open :: proc(t:^testing.T,f:^Files_Test,name:string) -> bool {
    f.root=base.test_folder(t,name)
    if f.root=="" || !test_world_init(t,&f.world) {return false}
    f.ai=new(Ai)
    os.make_directory_all(project.path(f.root,"assets",allocator=context.temp_allocator))
    test_session_open(&f.edited,test_world_ref(&f.world))
    f.s.ai,f.s.project_root=f.ai,f.root
    return true
}

@(private)
files_test_close :: proc(f:^Files_Test) {
    for &task in f.ai.tasks {ai_review_free(&task.review)}
    free(f.ai)
    test_session_close(&f.edited)
    test_world_destroy(&f.world)
}

@(private="file")
files_test_read :: proc(path:string) -> string {
    data,error:=os.read_entire_file(path,context.temp_allocator)
    if error!=nil {return "<none>"}
    return string(data)
}

@(private)
files_test_commit :: proc(f:^Files_Test) {
    history.edits_commit(&f.edits,edited_world(&f.s),&f.selection)
}

@(test)
files_of_a_gesture_are_one_step_and_undo_keeps_what_changed_outside :: proc(t:^testing.T) {
    f:Files_Test
    if !files_test_open(t,&f,"files-history") {return}
    defer files_test_close(&f)
    s:=&f.s
    w:=edited_world(s)
    path:=project.path(f.root,"assets/rock.mat",allocator=context.temp_allocator)
    testing.expect(t,os.write_entire_file(path,"one")==nil)

    scene:=history.edits_scene_state(&f.edits)
    testing.expect(t,file_write(s,path,transmute([]u8)string("two"),"Write"))
    files_test_commit(&f)
    testing.expect_value(t,len(f.edits.steps),1)
    testing.expect_value(t,history.edits_scene_state(&f.edits),scene) // the scene did not change: its file is not written
    testing.expect_value(t,len(f.edits.steps[0].files),1)
    testing.expect_value(t,files_test_read(path),"two")

    // Two writes of one gesture are one step: from what was before the first to what the last left.
    history.edits_begin(&f.edits,&f.selection,"Two writes")
    testing.expect(t,file_write(s,path,transmute([]u8)string("three"),"Write"))
    testing.expect(t,file_write(s,path,transmute([]u8)string("four"),"Write"))
    history.edits_end(&f.edits)
    files_test_commit(&f)
    testing.expect_value(t,len(f.edits.steps),2)
    testing.expect_value(t,string(f.edits.steps[1].files[0].other),"two")
    testing.expect_value(t,string(f.edits.steps[1].files[0].held),"four")

    testing.expect(t,history.undo(&f.edits,w,&f.selection))
    testing.expect_value(t,files_test_read(path),"two")
    testing.expect(t,history.undo(&f.edits,w,&f.selection))
    testing.expect_value(t,files_test_read(path),"one")
    testing.expect(t,history.redo(&f.edits,w,&f.selection))
    testing.expect_value(t,files_test_read(path),"two")
    testing.expect_value(t,len(f.edits.touched),1)
    files_settle(s)
    testing.expect_value(t,len(f.edits.touched),0)

    // A file another program changed since keeps its content, and redo goes on.
    testing.expect(t,os.write_entire_file(path,"outside")==nil)
    testing.expect(t,history.redo(&f.edits,w,&f.selection))
    testing.expect_value(t,files_test_read(path),"outside")
    testing.expect_value(t,f.edits.files_kept,1)
    files_settle(s)
    testing.expect_value(t,f.edits.files_kept,0)
    testing.expect(t,history.undo(&f.edits,w,&f.selection))
    testing.expect_value(t,files_test_read(path),"outside")

    // A file an edit creates goes with undo and comes back with redo.
    created:=project.path(f.root,"assets/new.mat",allocator=context.temp_allocator)
    testing.expect(t,file_write(s,created,transmute([]u8)string("made"),"Create"))
    files_test_commit(&f)
    testing.expect(t,history.undo(&f.edits,w,&f.selection))
    testing.expect(t,!os.exists(created))
    testing.expect(t,history.redo(&f.edits,w,&f.selection))
    testing.expect_value(t,files_test_read(created),"made")

    // A cancelled gesture puts its files back.
    history.edits_begin(&f.edits,&f.selection,"Cancelled")
    testing.expect(t,file_write(s,created,transmute([]u8)string("dropped"),"Write"))
    testing.expect(t,file_write(s,created,nil,"Remove",remove=true))
    testing.expect(t,!os.exists(created))
    history.edits_cancel(&f.edits,w)
    testing.expect_value(t,files_test_read(created),"made")
    testing.expect_value(t,len(f.edits.files),0)

    // A write that leaves the file as it was is no step.
    steps:=len(f.edits.steps)
    testing.expect(t,file_write(s,created,transmute([]u8)string("made"),"Same"))
    files_test_commit(&f)
    testing.expect_value(t,len(f.edits.steps),steps)
}

@(private="file")
provenance_task :: proc(t:^testing.T,f:^Files_Test) -> ^Ai_Task {
    m:=f.ai
    testing.expect_value(t,ai_store.open(&m.store,f.root),"")
    task:=&m.tasks[0]
    m.task_count=1
    task.id,task.world=7,&f.world
    c:=&task.conversation
    c.id=7
    base.text_set(task.name[:],"7-0")
    base.text_set(task.title[:],"Wet rock")
    ai_store.conversation_set_text(c.title[:],&c.title_len,"Wet rock")
    ai_store.conversation_set_text(c.model[:],&c.model_len,"gpt-6")
    ai_store.conversation_set_text(c.effort[:],&c.effort_len,"high")
    ai_transcript_add(&task.transcript,"Make the rock wet",.Prompt)
    ai_task_dirty(task)
    testing.expect_value(t,ai_transcript_save(&m.store,c,&task.transcript,task.dirty_sequence),"")
    return task
}

@(test)
a_transaction_of_a_turn_says_who_changed_its_entities_and_assets :: proc(t:^testing.T) {
    f:Files_Test
    if !files_test_open(t,&f,"provenance") {return}
    defer files_test_close(&f)
    m:=f.ai
    task:=provenance_task(t,&f)
    defer ai_store.close(&m.store)
    before:=f.edits.serial
    history.edits_begin(&f.edits,&f.selection,"Agent")
    testing.expect(t,file_write(&f.s,project.path(f.root,"assets/rock.mat",allocator=context.temp_allocator),transmute([]u8)string("wet"),"Write"))
    testing.expect(t,file_write(&f.s,project.path(f.root,"shaders/rock.slang",allocator=context.temp_allocator),transmute([]u8)string("code"),"Write"))
    e:=core.create(&f.world.entities)
    core.add(&f.world.ids,e,core.Id{0x2a})
    core.world_settle(edited_world(&f.s))
    history.edits_end(&f.edits)
    files_test_commit(&f)
    ai_review_record(&f.s,task,before)
    for ref in ([?][2]string{{AI_REF_ASSET,"rock.mat"},{AI_REF_ENTITY,"000000000000002a"}}) {
        provenance,found,message:=ai_store.provenance_get(&m.store,ref[0],ref[1])
        testing.expectf(t,message=="" && found && provenance.conversation==7 && provenance.sequence==0,"%s %s: %v",ref[0],ref[1],provenance)
    }
    _,source,_:=ai_store.provenance_get(&m.store,AI_REF_ASSET,"../shaders/rock.slang")
    testing.expect(t,!source,"what is outside the assets is not an asset")
    testing.expect_value(t,base.text_get(ai_provenance_view(m,.Asset,"rock.mat").title[:]),"Wet rock")
    p:=new(Ai_Provenance_Params,context.temp_allocator)
    p.entity=0x2a
    result:=new(Ai_Provenance_Result,context.temp_allocator)
    method:=new(api.Method,context.temp_allocator)
    method^={name="ai.provenance",params_id=Ai_Provenance_Params,result_id=Ai_Provenance_Result}
    call:=api.Call{method=method,raw="{}",params=p,result=result,allocator=context.temp_allocator}
    ai_method_provenance(&f.s,&call)
    testing.expect(t,!call.failed,call.error.message)
    encoded,_:=serial.text_encode(result^,.Line,context.temp_allocator)
    text:=api.json_compact(string(encoded))
    for fragment in ([?]string{`"found":true`,`"conversation":7`,"Wet rock","Make the rock wet","gpt-6","high"}) {
        testing.expectf(t,strings.contains(text,fragment),"%q is missing from %s",fragment,text)
    }
}

@(test)
the_browser_marks_are_the_assets_of_the_units_that_wait_for_review :: proc(t:^testing.T) {
    f:Files_Test
    if !files_test_open(t,&f,"browser-marks") {return}
    defer files_test_close(&f)
    m:=f.ai
    defer delete(m.asset_marks)
    task:=provenance_task(t,&f)
    defer ai_store.close(&m.store)
    testing.expect(t,ai_asset_mark(&f.s,"rock.mat")==nil)
    before:=f.edits.serial
    testing.expect(t,file_write(&f.s,project.path(f.root,"assets/rock.mat",allocator=context.temp_allocator),transmute([]u8)string("wet"),"Write"))
    files_test_commit(&f)
    ai_review_record(&f.s,task,before)
    task.state=.Done
    testing.expect(t,ai_asset_mark(&f.s,"rock.mat")==task,"it waits for review")
    testing.expect(t,ai_asset_mark(&f.s,"other.mat")==nil)
    task.review.pending=false
    testing.expect(t,ai_asset_mark(&f.s,"rock.mat")==task,"the set is remade only when the review state moves")
    task.review.pending=true
    ai_review_file_accept(&f.s,m,task,"assets/rock.mat")
    testing.expect(t,ai_asset_mark(&f.s,"rock.mat")==nil,"accepted, it no longer waits")
}

@(test)
ai_review_reverts_restores_and_resolves_the_files_of_a_turn :: proc(t:^testing.T) {
    f:Files_Test
    if !files_test_open(t,&f,"files-review") {return}
    defer files_test_close(&f)
    s:=&f.s
    m:=f.ai
    rock:=project.path(f.root,"assets/rock.mat",allocator=context.temp_allocator)
    program:=project.path(f.root,"shaders/rock.slang",allocator=context.temp_allocator)
    other:=project.path(f.root,"assets/other.mat",allocator=context.temp_allocator)
    testing.expect(t,os.write_entire_file(rock,"rock")==nil)
    a,b:=&m.tasks[0],&m.tasks[1]
    m.task_count=2
    a.id,b.id=1,2
    a.world,b.world=&f.world,&f.world
    a.conversation.id=7

    before:=f.edits.serial
    history.edits_begin(&f.edits,&f.selection,"Agent A")
    testing.expect(t,file_write(s,rock,transmute([]u8)string("rock by a"),"Write"))
    testing.expect(t,file_write(s,program,transmute([]u8)string("program by a"),"Write"))
    history.edits_end(&f.edits)
    files_test_commit(&f)
    ai_review_record(s,a,before)
    before=f.edits.serial
    testing.expect(t,file_write(s,other,transmute([]u8)string("other by b"),"Write"))
    files_test_commit(&f)
    ai_review_record(s,b,before)
    testing.expect_value(t,len(a.review.changed_files),2)
    testing.expect_value(t,a.review.changed_files[0],"assets/rock.mat")
    testing.expect_value(t,a.review.changed_files[1],"shaders/rock.slang")
    testing.expect_value(t,len(b.review.changed_files),1)
    testing.expect(t,a.review.pending && b.review.pending)

    // The record of a turn survives the editor closing.
    testing.expect_value(t,ai_review_save(s,a),"")
    ai_review_free(&a.review)
    testing.expect_value(t,ai_review_load(s,a),"")
    testing.expect_value(t,len(a.review.changed_files),2)
    testing.expect_value(t,string(a.review.transactions[0].files[0].before),"rock")

    // Revert puts back what the turn changed and keeps the turn of the other agent;
    // a file the user wrote since keeps what they wrote.
    testing.expect(t,os.write_entire_file(program,"program by the user")==nil)
    a.state,b.state=.Done,.Done
    steps:=len(f.edits.steps)
    testing.expect_value(t,ai_task_revert(s,m,a),"")
    testing.expect_value(t,len(f.edits.steps),steps+1)
    testing.expect_value(t,files_test_read(rock),"rock")
    testing.expect_value(t,files_test_read(program),"program by the user")
    testing.expect_value(t,files_test_read(other),"other by b")
    testing.expect_value(t,a.review.skipped,1)
    testing.expect(t,a.declined)

    // Restore takes the changes back for review where the files are as the revert left them.
    testing.expect_value(t,ai_task_restore(s,m,a),"")
    testing.expect_value(t,files_test_read(rock),"rock by a")
    testing.expect_value(t,files_test_read(program),"program by the user")
    testing.expect(t,a.review.pending)

    // One file is kept and the other put back; with none left the turn stops waiting.
    ai_review_file_accept(s,m,a,"assets/rock.mat")
    testing.expect_value(t,len(a.review.changed_files),1)
    testing.expect_value(t,files_test_read(rock),"rock by a")
    testing.expect(t,os.write_entire_file(program,"program by a")==nil)
    testing.expect_value(t,ai_review_file_revert(s,m,a,"shaders/rock.slang"),"")
    files_test_commit(&f)
    testing.expect(t,!os.exists(program))
    testing.expect_value(t,len(a.review.changed_files),0)
    testing.expect(t,!a.review.pending)
}

@(test)
asset_files_of_a_step_reach_the_disk_when_it_is_flushed :: proc(t:^testing.T) {
    f:Files_Test
    if !files_test_open(t,&f,"files-flush") {return}
    defer files_test_close(&f)
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=project.path(f.root,"assets",allocator=context.temp_allocator),capacity=8})) {return}
    defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets}
    s:=&f.s
    s.app=&app
    w:=edited_world(s)
    rock:=project.path(f.root,"assets/rock.mat",allocator=context.temp_allocator)
    testing.expect(t,os.write_entire_file(rock,"one")==nil)

    // Until the step is flushed the registry holds the file and answers for it.
    testing.expect(t,file_write(s,rock,transmute([]u8)string("two"),"Write"))
    files_test_commit(&f)
    testing.expect_value(t,files_test_read(rock),"one")
    held,found:=asset.registry_memory_find(&assets.registry,"rock.mat")
    testing.expect(t,found && string(held.data)=="two")
    testing.expect(t,history.file_holds(&assets.registry,rock,true,transmute([]u8)string("two")))
    testing.expect(t,files_flush(s,true))
    testing.expect_value(t,files_test_read(rock),"two")
    testing.expect_value(t,len(assets.registry.memory),0)

    // Undo and redo are steps: their flush rewrites the file.
    testing.expect(t,history.undo(&f.edits,w,&f.selection))
    testing.expect(t,files_flush(s,true))
    testing.expect_value(t,files_test_read(rock),"one")
    testing.expect(t,history.redo(&f.edits,w,&f.selection))
    testing.expect(t,files_flush(s,true))
    testing.expect_value(t,files_test_read(rock),"two")

    // Nothing is written while a gesture is open, nor while a game plays.
    history.edits_begin(&f.edits,&f.selection,"Drag")
    testing.expect(t,file_write(s,rock,transmute([]u8)string("three"),"Write"))
    testing.expect(t,!files_flush(s,true))
    testing.expect_value(t,files_test_read(rock),"two")
    history.edits_end(&f.edits)
    files_test_commit(&f)
    s.mode=.Play
    testing.expect(t,!files_flush(s,true))
    testing.expect_value(t,files_test_read(rock),"two")
    s.mode=.Edit
    testing.expect(t,files_flush(s,true))
    testing.expect_value(t,files_test_read(rock),"three")

    // A file an edit creates reaches the disk with its step, and its undo takes it away.
    created:=project.path(f.root,"assets/new.mat",allocator=context.temp_allocator)
    testing.expect(t,file_write(s,created,transmute([]u8)string("made"),"Create"))
    files_test_commit(&f)
    testing.expect(t,!os.exists(created) && file_exists(s,created))
    testing.expect(t,files_flush(s,true) && os.exists(created))
    testing.expect(t,history.undo(&f.edits,w,&f.selection))
    testing.expect(t,!file_exists(s,created))
    testing.expect(t,files_flush(s,true) && !os.exists(created))

    // Removing a file of the disk is a change of the step too.
    testing.expect(t,file_write(s,rock,nil,"Remove",remove=true))
    files_test_commit(&f)
    testing.expect(t,os.exists(rock) && !file_exists(s,rock))
    testing.expect(t,files_flush(s,true) && !os.exists(rock))
    testing.expect(t,history.undo(&f.edits,w,&f.selection))
    testing.expect(t,files_flush(s,true))
    testing.expect_value(t,files_test_read(rock),"three")

    // The review of a turn reverts and restores what it wrote.
    m:=f.ai
    task:=&m.tasks[0]
    m.task_count=1
    task.id,task.world=1,&f.world
    before:=f.edits.serial
    testing.expect(t,file_write(s,rock,transmute([]u8)string("by an agent"),"Write"))
    files_test_commit(&f)
    ai_review_record(s,task,before)
    testing.expect_value(t,len(task.review.changed_files),1)
    task.state=.Done
    testing.expect_value(t,ai_task_revert(s,m,task),"")
    testing.expect(t,files_flush(s,true))
    testing.expect_value(t,files_test_read(rock),"three")
    testing.expect_value(t,ai_task_restore(s,m,task),"")
    testing.expect(t,files_flush(s,true))
    testing.expect_value(t,files_test_read(rock),"by an agent")

    // An animation asset is held like the rest, and file_read gives it before its flush.
    clip:=project.path(f.root,"assets/walk.anim",allocator=context.temp_allocator)
    testing.expect(t,file_write(s,clip,transmute([]u8)string("walk"),"Write"))
    files_test_commit(&f)
    data,read:=file_read(s,clip)
    testing.expect(t,read && string(data)=="walk")
    testing.expect(t,files_flush(s,true))
    testing.expect_value(t,files_test_read(clip),"walk")
}

@(test)
program_sources_are_written_at_once :: proc(t:^testing.T) {
    f:Files_Test
    if !files_test_open(t,&f,"files-programs") {return}
    defer files_test_close(&f)
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=project.path(f.root,"assets",allocator=context.temp_allocator),capacity=8})) {return}
    defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets}
    s:=&f.s
    s.app=&app
    w:=edited_world(s)
    program:=project.path(f.root,"shaders/rock.slang",allocator=context.temp_allocator)
    os.make_directory_all(project.path(f.root,"shaders",allocator=context.temp_allocator))
    testing.expect(t,os.write_entire_file(program,"first")==nil)

    // An edit writes the source where the generation of the shaders reads it.
    testing.expect(t,file_write(s,program,transmute([]u8)string("edited"),"Edit program"))
    files_test_commit(&f)
    testing.expect_value(t,files_test_read(program),"edited")
    testing.expect_value(t,len(assets.registry.memory),0)
    text,read:=program_text(s,program)
    testing.expect(t,read && text=="edited")
    testing.expect_value(t,file_name(s,program),"shaders/rock.slang")
    testing.expect(t,len(assets.registry.files)==0,"it is no asset")

    // Undo and redo write it too.
    testing.expect(t,history.undo(&f.edits,w,&f.selection))
    testing.expect_value(t,files_test_read(program),"first")
    testing.expect(t,history.redo(&f.edits,w,&f.selection))
    testing.expect_value(t,files_test_read(program),"edited")

    // The review of a turn reverts and restores it.
    m:=f.ai
    task:=&m.tasks[0]
    m.task_count=1
    task.id,task.world=1,&f.world
    before:=f.edits.serial
    testing.expect(t,file_write(s,program,transmute([]u8)string("by an agent"),"Edit program"))
    files_test_commit(&f)
    ai_review_record(s,task,before)
    testing.expect(t,len(task.review.changed_files)==1 && task.review.changed_files[0]=="shaders/rock.slang")
    task.state=.Done
    testing.expect_value(t,ai_task_revert(s,m,task),"")
    testing.expect_value(t,files_test_read(program),"edited")
    testing.expect_value(t,ai_task_restore(s,m,task),"")
    testing.expect_value(t,files_test_read(program),"by an agent")
}

@(test)
another_asset_of_the_kind_in_front_takes_its_tab_while_it_has_no_history :: proc(t:^testing.T) {
    f:Files_Test
    if !files_test_open(t,&f,"files-asset-reuse") {return}
    defer files_test_close(&f)
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=project.path(f.root,"assets",allocator=context.temp_allocator),capacity=8})) {return}
    defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets}
    s:=&f.s
    s.app=&app
    defer asset_documents_free(s)
    ids:=[3]base.Asset_Id{{1,2},{3,4},{5,6}}
    paths:=[3]string{}
    for name,i in ([3]string{"stone.mat","clay.mat","sand.mat"}) {
        data,error:=asset.material_bytes(&assets.types,{id=ids[i],info=asset.MATERIAL_DEFAULTS},context.temp_allocator)
        paths[i]=project.path(f.root,"assets",name,allocator=context.temp_allocator)
        testing.expect(t,error==.None && os.write_entire_file(paths[i],data)==nil)
    }
    testing.expect(t,host.assets_scan(&assets))
    testing.expect(t,asset_document_show(s,ids[0]))
    testing.expect(t,asset_document_open(s,ids[1]))
    testing.expect_value(t,len(s.asset_documents),1)
    testing.expect(t,asset_document_active(s).id==ids[1],"the one without changes gives its tab")

    // With a step of its own it keeps its tab.
    rough:=asset.MATERIAL_DEFAULTS
    rough.roughness=0.25
    data,_:=asset.material_bytes(&assets.types,{id=ids[1],info=rough},context.temp_allocator)
    testing.expect(t,file_write(s,paths[1],data,"Value"))
    testing.expect(t,asset_document_open(s,ids[2]))
    testing.expect_value(t,len(s.asset_documents),2)
}

@(test)
files_an_asset_document_writes_are_steps_of_its_own_history :: proc(t:^testing.T) {
    f:Files_Test
    if !files_test_open(t,&f,"files-asset-document") {return}
    defer files_test_close(&f)
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=project.path(f.root,"assets",allocator=context.temp_allocator),capacity=8})) {return}
    defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets}
    s:=&f.s
    s.app=&app
    defer asset_documents_free(s)
    rock:=project.path(f.root,"assets/rock.mat",allocator=context.temp_allocator)
    testing.expect(t,os.write_entire_file(rock,"one")==nil)
    holds :: proc(r:^asset.Registry,path,data:string) -> bool {return history.file_holds(r,path,true,transmute([]u8)data)}
    append(&s.asset_documents,Asset_Document{kind=asset.KIND_MATERIAL},Asset_Document{kind=asset.KIND_MATERIAL})
    asset_document_activate(s,1)
    testing.expect(t,asset_document_active(s)==&s.asset_documents[1])
    h:=&s.asset_documents[1].history

    // A write with the document in front is a step of the document, not of the scene.
    testing.expect(t,file_write(s,rock,transmute([]u8)string("two"),"Value"))
    files_test_commit(&f)
    testing.expect_value(t,h.cursor,1)
    testing.expect_value(t,len(f.edits.steps),0)
    testing.expect(t,holds(&assets.registry,rock,"two"))
    testing.expect_value(t,files_test_read(rock),"one")

    // A gesture of the scene that is open (the API, a tool) keeps what it writes.
    testing.expect(t,history.edits_begin(&f.edits,&f.selection,"Agent"))
    testing.expect(t,file_write(s,rock,transmute([]u8)string("three"),"Value"))
    history.edits_end(&f.edits)
    files_test_commit(&f)
    testing.expect_value(t,len(f.edits.steps),1)
    testing.expect_value(t,h.cursor,1)

    // A gesture of the document is one step from what was before it to what it left.
    testing.expect(t,asset_history_begin(h,"Drag"))
    testing.expect(t,file_write(s,rock,transmute([]u8)string("four"),"Value"))
    testing.expect(t,file_write(s,rock,transmute([]u8)string("five"),"Value"))
    asset_history_end(h)
    testing.expect_value(t,len(h.steps),2)
    testing.expect_value(t,asset_history_undo_label(h),"Drag")
    testing.expect(t,asset_history_undo(h))
    testing.expect(t,holds(&assets.registry,rock,"three"))
    testing.expect_value(t,len(h.touched),1)

    // Undo of a step the scene changed since keeps what the scene left.
    testing.expect(t,asset_history_undo(h))
    testing.expect_value(t,h.files_kept,1)
    testing.expect(t,holds(&assets.registry,rock,"three"))
    testing.expect(t,asset_history_redo(h))
    testing.expect(t,asset_history_redo(h))
    testing.expect(t,holds(&assets.registry,rock,"five"))

    // A new step drops what redo had; a cancelled gesture puts back what it changed.
    testing.expect(t,asset_history_undo(h))
    testing.expect(t,file_write(s,rock,transmute([]u8)string("six"),"Value"))
    testing.expect_value(t,len(h.steps),2)
    testing.expect_value(t,asset_history_redo_label(h),"")
    testing.expect(t,asset_history_begin(h,"Drag"))
    testing.expect(t,file_write(s,rock,transmute([]u8)string("seven"),"Value"))
    asset_history_cancel(h)
    testing.expect(t,holds(&assets.registry,rock,"six"))
    testing.expect_value(t,len(h.steps),2)

    // With the scene in front, writes are steps of the scene again.
    asset_document_activate(s,-1)
    testing.expect(t,asset_document_active(s)==nil)
    testing.expect(t,file_write(s,rock,transmute([]u8)string("eight"),"Value"))
    files_test_commit(&f)
    testing.expect_value(t,len(f.edits.steps),2)

    // Closing the one in front brings the one before it; closing another keeps the one in front.
    asset_document_activate(s,1)
    asset_document_close(s,1)
    testing.expect_value(t,s.asset_shown,1)
    append(&s.asset_documents,Asset_Document{kind=asset.KIND_MATERIAL})
    asset_document_activate(s,1)
    asset_document_close(s,0)
    testing.expect_value(t,s.asset_shown,1)
    testing.expect_value(t,len(s.asset_documents),1)
    asset_document_close(s,0)
    testing.expect(t,asset_document_active(s)==nil && s.asset_documents==nil)
}
