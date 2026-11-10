package editor

import "core:strings"
import "core:time"
import "mirai:editor/ai_store"
import "mirai:editor/api"
import "mirai:editor/history"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:ui"

// Who last changed an entity or an asset, written where the review of a turn
// records a transaction, and the mark of the assets that wait for review.

AI_REF_ENTITY :: "entity"
AI_REF_ASSET :: "asset"
AI_PROVENANCE_ROW :: f32(20) // the row of Details that says it

Ai_Provenance_Kind :: enum u8 {Entity,Asset}

// What a row of Details shows, read when its reference or a review changes.
Ai_Provenance_View :: struct {
    ref:u64,    // the hash of the reference it was read for
    serial:u64, // of Ai.scene_serial
    read,found:bool,
    conversation:u64,
    sequence:u64,
    at:i64,
    title:[96]u8,
}

// A file of the project under the assets folder, as the registry names it.
@(private)
ai_asset_path_of :: proc(s:^Session,path:string) -> (relative:string,ok:bool) {
    if s.project_root=="" {return}
    folder:=history.file_relative(s.project_root,project.folder_path(s.project_root,.Assets,context.temp_allocator))
    if len(path)<=len(folder) || !strings.has_prefix(path,folder) || path[len(folder)]!='/' {return}
    return path[len(folder)+1:],true
}

// A transaction of a turn: every entity it changed and every asset it wrote
// now names that turn.
ai_provenance_record :: proc(s:^Session,task:^Ai_Task,transaction:^history.Change_Set) {
    m:=s.ai
    if m.store.db==nil || task.conversation.id==0 {return}
    sequence:=ai_task_turn_sequence(task)
    if sequence<0 {return}
    refs:=make([dynamic]ai_store.Provenance_Ref,context.temp_allocator)
    seen:=make(map[base.Entity_Id]bool,context.temp_allocator)
    text:[16]u8
    for &row in transaction.rows {
        if row.id==0 || row.id in seen {continue}
        seen[row.id]=true
        append(&refs,ai_store.Provenance_Ref{AI_REF_ENTITY,strings.clone(base.entity_id_format(row.id,text[:]),context.temp_allocator)})
    }
    for &file in transaction.files {
        if path,ok:=ai_asset_path_of(s,file.path);ok {append(&refs,ai_store.Provenance_Ref{AI_REF_ASSET,path})}
    }
    if message:=ai_store.provenance_record(&m.store,refs[:],task.conversation.id,u64(sequence));message!="" {notify(s,message)}
}

@(private)
ai_provenance_view :: proc(m:^Ai,kind:Ai_Provenance_Kind,ref:string) -> ^Ai_Provenance_View {
    view:=&m.provenance_views[kind]
    hash:=base.hash64(transmute([]u8)ref)
    if view.read && view.ref==hash && view.serial==m.scene_serial {return view}
    view^={read=true,ref=hash,serial=m.scene_serial}
    provenance,found,message:=ai_store.provenance_get(&m.store,kind==.Entity?AI_REF_ENTITY:AI_REF_ASSET,ref)
    if message!="" || !found {return view}
    view.found,view.conversation,view.sequence,view.at=true,provenance.conversation,provenance.sequence,provenance.at
    base.text_set(view.title[:],ai_unit_title(m,int(provenance.conversation)))
    return view
}

// Opens the view of the agent that changed something, at the turn that did it.
ai_provenance_open :: proc(s:^Session,conversation,sequence:u64) {
    ai_unit_open(s,int(conversation))
    s.ai.scroll_to=int(sequence)+1
    s.gui.layout.left_open=true
}

// One faint row in Details: the agent that last changed this and how long
// ago; a click opens its view. Gives the height it took.
ai_provenance_row :: proc(s:^Session,kind:Ai_Provenance_Kind,ref:string) -> f32 {
    m:=s.ai
    if m==nil || m.store.db==nil || ref=="" {return 0}
    view:=ai_provenance_view(m,kind,ref)
    if !view.found {return 0}
    ctx:=s.gui.ctx;th:=&ctx.theme
    id:=ui.id(ctx,"ai_provenance")
    it:=ui.interact(ctx,id)
    color:=it.hot?th.text_muted:th.text_faint
    if ui.box(ctx,{id=id,width=ui.GROW,height=ui.fixed(AI_PROVENANCE_ROW),padding={11,0,7,0},gap=6,align_y=.Center}) {
        ui.label(ctx,base.text_get(view.title[:]),th.font_caption,color,0)
        ui.label(ctx,ai_time_ago(time.to_unix_nanoseconds(time.now())/1_000_000-view.at),th.font_caption,color)
    }
    if it.clicked {ai_provenance_open(s,view.conversation,view.sequence)}
    return AI_PROVENANCE_ROW
}

// The row of the details of the asset document in front.
ai_provenance_asset_row :: proc(s:^Session) -> f32 {
    d:=asset_document_active(s)
    if d==nil {return 0}
    return ai_provenance_row(s,.Asset,asset_document_path(s,d))
}

// The set of the assets changed by a unit that waits for review, by the hash
// of their path in the registry, remade only when a review changes.
@(private)
ai_asset_marks_sync :: proc(s:^Session) {
    m:=s.ai
    if m.asset_marks_serial==m.scene_serial {return}
    m.asset_marks_serial=m.scene_serial
    clear(&m.asset_marks)
    for &task in m.tasks[:m.task_count] {
        if !ai_task_reviewable(&task) || !task.review.pending {continue}
        for path in task.review.changed_files {
            if relative,ok:=ai_asset_path_of(s,path);ok {m.asset_marks[base.hash64(transmute([]u8)relative)]=task.id}
        }
    }
}

// The unit an asset of the browser waits for; nil without one. A lookup of the set.
ai_asset_mark :: proc(s:^Session,path:string) -> ^Ai_Task {
    m:=s.ai
    if m==nil {return nil}
    ai_asset_marks_sync(s)
    if len(m.asset_marks)==0 {return nil}
    if id,marked:=m.asset_marks[base.hash64(transmute([]u8)path)];marked {return ai_task_find(m,id)}
    return nil
}

// ---------------------------------------------------------------- API

Ai_Provenance_Params :: struct {
    entity:base.Entity_Id `mirai:"optional,label=An entity of the scene; give entity or asset"`,
    asset:[AI_PATH_BYTES]u8 `mirai:"optional,text,label=An asset by its path under the assets folder; give entity or asset"`,
}
Ai_Provenance_Result :: struct {
    found:bool `mirai:"label=An agent changed it; the other fields are empty otherwise"`,
    conversation:int `mirai:"label=The chat or subagent that changed it last; ai.history takes it as id"`,
    title:string,
    prompt:string `mirai:"label=What the user asked in that turn"`,
    model:string,
    effort:string,
    date:int `mirai:"label=When it changed it; Unix time in milliseconds"`,
}

@(private)
ai_provenance_api_register :: proc(s:^Session,st:^Api_State) {
    api_register(s,st,{name="ai.provenance",summary="Who last changed an entity or an asset through a turn of an agent: the conversation, its title, the prompt of that turn, the model, the effort and the date.",params=Ai_Provenance_Params,result=Ai_Provenance_Result,flags={.Read_Only,.Idempotent},run=ai_method_provenance})
}

@(private)
ai_method_provenance :: proc(s:^Session,call:^api.Call) {
    ai_initialize(s)
    m:=s.ai
    p:=api.call_params(call,Ai_Provenance_Params)
    path:=base.text_get(p.asset[:])
    if (p.entity==0)==(path=="") {api.call_fail(call,api.INVALID_PARAMS,"give the id of an entity or the path of an asset under the assets folder");return}
    text:[16]u8
    kind,ref:=AI_REF_ASSET,path
    if p.entity!=0 {kind,ref=AI_REF_ENTITY,base.entity_id_format(p.entity,text[:])}
    provenance,found,message:=ai_store.provenance_get(&m.store,kind,ref)
    if message!="" {api.call_fail(call,api.SERVER_ERROR,message);return}
    title,prompt,model,effort:="","","",""
    if found {
        if saved:=ai_store.find(&m.store,provenance.conversation);saved!=nil {
            title,model,effort=string(saved.title[:saved.title_len]),string(saved.model[:saved.model_len]),string(saved.effort[:saved.effort_len])
        }
        line:[1]ai_store.Stored_Line
        if count,_:=ai_store.page(&m.store,provenance.conversation,i64(provenance.sequence)+1,line[:]);count==1 && line[0].sequence==provenance.sequence && line[0].kind==.Prompt {prompt=line[0].text}
    }
    api.call_result(call,Ai_Provenance_Result)^={found,int(provenance.conversation),title,prompt,model,effort,int(provenance.at)}
}
