package editor

import "core:fmt"
import "core:strings"
import "mirai:core"
import "mirai:editor/ai_store"
import "mirai:editor/api"
import "mirai:editor/history"
import "mirai:platform"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:ui"

// The pins a user drops on the scene for the agent: a tool of the viewport
// that writes them in chat.db, never in the scene, drawn over the viewport and
// given to the agent one line each in the delta of every turn.

AI_ANNOTATE_TOOL :: "annotate"
AI_ANNOTATIONS :: 128            // pins of a document
AI_ANNOTATION_TEXT_BYTES :: 512
AI_ANNOTATION_GROUP_BYTES :: 24  // short: a group name goes on a chip
AI_ANNOTATION_GROUPS :: 8        // groups a message takes as chips
AI_ANNOTATION_PIN :: f32(18)     // side of its disc on the screen
AI_ANNOTATION_WIDTH :: f32(260)  // of the field of its note

Ai_Annotation_Row :: struct {
    id:i64,
    entity:u64,
    position:[3]f32,
    group:[AI_ANNOTATION_GROUP_BYTES]u8,
    text:[AI_ANNOTATION_TEXT_BYTES]u8,
}

// The pins of the open document as the database holds them, read when the
// document or the database changes and not per frame.
Ai_Annotations :: struct {
    rows:[AI_ANNOTATIONS]Ai_Annotation_Row,
    count:int,
    document:[1024]u8, // of rows
    loaded:bool,
    stale:bool,        // the database changed; rows are read again
    editing:i64,       // the pin whose note is open; 0: none
    opening:bool,      // its popup opens with the next build
    anchor:ui.Rect,    // where the popup hangs: the pin on the window
    number:int,        // what the editing pin shows
    group:[AI_ANNOTATION_GROUP_BYTES]u8,
    group_length:int,
    draft:[AI_ANNOTATION_TEXT_BYTES]u8,
    draft_length:int,
    focus:bool,
    groups:[AI_ANNOTATION_GROUPS][AI_ANNOTATION_GROUP_BYTES]u8, // the chips of the next message
    group_count:int,
}

@(private)
ai_annotations_document :: proc(s:^Session) -> string {return s.document!=nil?document_path(s.document):""}

// Reads the pins of the document when it changed or a write made them stale.
ai_annotations_sync :: proc(s:^Session) {
    m:=s.ai
    if m==nil || m.store.db==nil {return}
    a:=&m.annotations
    document:=ai_annotations_document(s)
    if a.loaded && !a.stale && base.text_get(a.document[:])==document {return}
    a.loaded,a.stale=true,false
    base.text_set(a.document[:],document)
    a.count=0
    notes,message:=ai_store.annotations(&m.store,document)
    if message!="" {notify(s,message);return}
    for &note in notes[:min(len(notes),AI_ANNOTATIONS)] {
        row:=&a.rows[a.count]
        row^={id=note.id,entity=note.entity,position={f32(note.x),f32(note.y),f32(note.z)}}
        base.text_set(row.group[:],note.group_name)
        base.text_set(row.text[:],note.text)
        a.count+=1
    }
    if a.editing!=0 && ai_annotation_at(a,a.editing)<0 {a.editing=0}
}

@(private)
ai_annotation_at :: proc(a:^Ai_Annotations,id:i64) -> int {
    for &row,i in a.rows[:a.count] {if row.id==id {return i}}
    return -1
}

// The name of the entity a pin is on while its document is open; empty otherwise.
@(private)
ai_annotation_entity_name :: proc(s:^Session,document:string,entity:u64) -> string {
    if entity==0 || s.edit_world==nil || document!=ai_annotations_document(s) {return ""}
    w:=edited_world(s)
    e:=history.change_entity(w,base.Entity_Id(entity))
    return e!=core.NONE?entity_name(w,e):""
}

// All the pins of a document, one line each, as the delta of a turn gives them.
ai_annotations_delta_write :: proc(s:^Session,document:string,b:^strings.Builder) {
    m:=s.ai
    notes,message:=ai_store.annotations(&m.store,document)
    if message!="" {notify(s,message);return}
    if len(notes)==0 {return}
    fmt.sbprintf(b,"- The user left these annotations on this document, one per pin, number | group | world position | entity | note. Use `annotation.list` for their ids and `annotation.remove` when you are done with them (both through the tool `call`):\n")
    id_text:[16]u8
    for &note,index in notes {
        group:=note.group_name!=""?note.group_name:"-"
        entity:="-"
        if note.entity!=0 {
            entity=base.entity_id_format(base.Entity_Id(note.entity),id_text[:])
            if name:=ai_annotation_entity_name(s,document,note.entity);name!="" {entity=fmt.tprintf("%s %s",entity,name)}
        }
        text,_:=strings.replace_all(note.text,"\n"," ",context.temp_allocator)
        fmt.sbprintf(b,"  - %d | %s | %.3f %.3f %.3f | %s | %s\n",index+1,group,note.x,note.y,note.z,entity,text)
    }
}

// The pin the click of the tool dropped: its note opens at once.
@(private)
ai_annotation_drop :: proc(s:^Session,w:core.World_Ref,hit:Pick) {
    m:=s.ai
    a:=&m.annotations
    ai_annotations_sync(s)
    if a.count>=AI_ANNOTATIONS {notify(s,fmt.tprintf("A document takes at most %d annotations",AI_ANNOTATIONS));return}
    entity:=u64(api_entity_id(w,entity_author(w,hit.entity)))
    id,message:=ai_store.annotation_add(&m.store,"",ai_annotations_document(s),entity,f64(hit.position.x),f64(hit.position.y),f64(hit.position.z),"")
    if message!="" {notify(s,message);return}
    a.stale=true
    ai_annotation_edit(s,id)
}

// Opens the note of a pin, closing the one that was open.
@(private)
ai_annotation_edit :: proc(s:^Session,id:i64) {
    a:=&s.ai.annotations
    if a.editing!=0 && a.editing!=id {ai_annotation_close(s)}
    ai_annotations_sync(s)
    at:=ai_annotation_at(a,id)
    if at<0 {return}
    row:=&a.rows[at]
    a.editing,a.opening,a.focus=id,true,true
    a.number=at+1
    a.group_length=copy(a.group[:],base.text_get(row.group[:]))
    a.draft_length=copy(a.draft[:],base.text_get(row.text[:]))
    p,_:=viewport_screen(s.viewport,row.position)
    a.anchor={p.x-AI_ANNOTATION_PIN*0.5,p.y-AI_ANNOTATION_PIN*0.5,AI_ANNOTATION_PIN,AI_ANNOTATION_PIN}
}

// Saves the open note. A pin left without a note is taken out.
@(private)
ai_annotation_close :: proc(s:^Session) {
    m:=s.ai
    a:=&m.annotations
    id:=a.editing
    a.editing=0
    if id==0 {return}
    text:=strings.trim_space(string(a.draft[:a.draft_length]))
    if text=="" {ai_annotation_remove(s,id);return}
    group:=strings.trim_space(string(a.group[:a.group_length]))
    message:=ai_store.annotation_set_text(&m.store,id,text)
    if message=="" {message=ai_store.annotation_set_group(&m.store,id,group)}
    a.stale=true
    if message!="" {notify(s,message);return}
    if group!="" {ai_annotation_group_attach(m,group)}
}

@(private)
ai_annotation_remove :: proc(s:^Session,id:i64) {
    m:=s.ai
    if message:=ai_store.annotation_remove(&m.store,id);message!="" {notify(s,message)}
    m.annotations.stale=true
}

// The group of a pin goes with the next message as a chip.
@(private)
ai_annotation_group_attach :: proc(m:^Ai,group:string) {
    a:=&m.annotations
    for i in 0..<a.group_count {if base.text_get(a.groups[i][:])==group {return}}
    if a.group_count>=len(a.groups) {return}
    base.text_set(a.groups[a.group_count][:],group)
    a.group_count+=1
}

// A click of the tool on a surface or an entity drops a pin; on the nothing, none.
@(private)
ai_annotation_pointer :: proc(s:^Session,w:core.World_Ref) {
    v:=s.viewport
    if s.ai==nil || s.mode!=.Edit || !tool_on(s,AI_ANNOTATE_TOOL) || !v.hovered || v.pick.active {return}
    if .Left not_in platform.input_frame(s.app.platform).mouse_pressed {return}
    hit:=pick_point(s,w,v.pointer)
    if hit.entity!=core.NONE {ai_annotation_drop(s,w,hit)}
}

// The pins show while the chat is open or the tool is on, over the scene.
@(private)
ai_annotations_visible :: proc(s:^Session) -> bool {
    m:=s.ai
    if s.mode!=.Edit || scene_covered(s) || m.chat_expanded {return false}
    return m.chat_open && s.gui.layout.left_open || tool_on(s,AI_ANNOTATE_TOOL)
}

// The tool, the pins over the viewport and the note of the one that is open.
@(private)
ai_annotations_build :: proc(s:^Session) {
    m:=s.ai
    if m==nil || !s.has_project {return}
    g:=s.gui;ctx:=g.ctx
    a:=&m.annotations
    annotating:=tool_on(s,AI_ANNOTATE_TOOL)
    ai_annotations_sync(s)
    if ai_annotations_visible(s) {
        v:=s.viewport
        area:=viewport_rect(v)
        for &row,index in a.rows[:a.count] {
            p,front:=viewport_screen(v,row.position)
            if !front || !ui.rect_contains(area,p) {continue}
            id:=ui.id(ctx,"ai_annotation",int(row.id))
            it:=ui.interact(ctx,id)
            open:=a.editing==row.id
            fill:=open?ui.tone(ctx,"text"):ui.tone(ctx,"accent")
            ink:=open?ui.tone(ctx,"panel"):ui.tone(ctx,"on_accent")
            if ui.box(ctx,{id=id,width=ui.fixed(AI_ANNOTATION_PIN),height=ui.fixed(AI_ANNOTATION_PIN),align_x=.Center,align_y=.Center,float={to=.Surface,offset=p,pivot=.Center},fill=fill,stroke=ui.tone(ctx,"panel"),stroke_width=1.5,radius=AI_ANNOTATION_PIN*0.5}) {
                ui.label(ctx,ui.text_store(ctx,fmt.tprintf("%d",index+1)),ui.metric(ctx,"font_caption"),ink,font=ui.FONT_SEMIBOLD)
            }
            if it.clicked {ai_annotation_edit(s,row.id)}
            if it.hot {
                group:=base.text_get(row.group[:])
                text:=base.text_get(row.text[:])
                ui.tooltip(ctx,group!=""?fmt.tprintf("%s: %s",group,text):text)
            }
        }
    }
    popup:=shell_id(g,"ai_annotation_note")
    if a.opening {
        a.opening=false
        ui.popup_open(ctx,popup,a.anchor)
    }
    if a.editing!=0 && !ui.popup_is_open(ctx,popup) {ai_annotation_close(s)}
    else if a.editing==0 && ui.popup_is_open(ctx,popup) {ui.popup_close(ctx,popup)}
    if a.editing==0 {return}
    if ui.popup(ctx,popup,{width=AI_ANNOTATION_WIDTH,padding=12,gap=6}) {
        ui.id_push(ctx,popup)
        defer ui.id_pop(ctx)
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(24),gap=6,align_y=.Center}) {
            ui.label(ctx,ui.text_store(ctx,fmt.tprintf("%d",a.number)),ui.metric(ctx,"font_small"),ui.tone(ctx,"text"),font=ui.FONT_SEMIBOLD)
            if ui.text_field(ctx,ui.id(ctx,"group"),a.group[:len(a.group)-1],&a.group_length,{live=true,keep_caret=true,placeholder="Group",height=24}).committed && .Enter in ctx.input.keys_pressed {ui.popup_close(ctx,popup)}
            if ui.button(ctx,ui.id(ctx,"remove"),{icon=ui.icon_user(u8(User_Icon.Trash)),icon_color=ui.tone(ctx,"text_muted"),icon_size=13,variant="ghost",width=24,height=24}).clicked {
                ai_annotation_remove(s,a.editing)
                a.editing=0
                ui.popup_close(ctx,popup)
            }
        }
        field:=ui.id(ctx,"note")
        if a.focus {ui.edit_request(ctx,field);a.focus=false}
        if ui.text_field(ctx,field,a.draft[:len(a.draft)-1],&a.draft_length,{live=true,keep_caret=true,placeholder="Note",multiline=true,rows=3}).committed && .Enter in ctx.input.keys_pressed {ui.popup_close(ctx,popup)}
    }
}

@(private)
ai_annotate_icon :: proc() -> ui.Icon {return ui.icon_user(u8(User_Icon.Annotate))}

// The tool from the composer, beside the button that attaches an image.
@(private)
ai_annotate_button :: proc(s:^Session) {
    ctx:=s.gui.ctx
    on:=s.viewport!=nil && tool_on(s,AI_ANNOTATE_TOOL)
    if ui.button(ctx,ui.id(ctx,"annotate"),{icon=ai_annotate_icon(),icon_color=ui.tone(ctx,"text_muted"),icon_size=14,variant="ghost",width=24,height=24,active=on,disabled=s.mode!=.Edit || scene_covered(s)}).clicked {tool_set(s,AI_ANNOTATE_TOOL,!on)}
}

@(private)
ai_annotation_group_rows :: proc(s:^Session,width:f32) -> int {
    a:=&s.ai.annotations
    if a.group_count==0 {return 0}
    ctx:=s.gui.ctx
    used:=f32(0);rows:=1
    for i in 0..<a.group_count {
        size:=ai_chip_width(ctx,base.text_get(a.groups[i][:]),width)
        if used>0 && used+size>width {rows+=1;used=0}
        used+=size+5
    }
    return rows
}

// The groups of pins the next message is about, as chips that can be pinned.
@(private)
ai_annotation_groups_build :: proc(s:^Session,width:f32,rows:int) {
    if rows<=0 {return}
    m:=s.ai;ctx:=s.gui.ctx
    a:=&m.annotations
    remove:=-1
    used:=f32(0);row:=0
    for i in 0..<a.group_count {
        group:=base.text_get(a.groups[i][:])
        size:=ai_chip_width(ctx,group,width)
        if used>0 && used+size>width {ui.box_end(ctx,{});row+=1;used=0}
        if row>=rows {break}
        if used==0 {ui.box_begin(ctx,{width=ui.GROW,height=ui.fixed(AI_CHIP_HEIGHT),gap=5,align_y=.Center})}
        if ui.box(ctx,{width=ui.fixed(size),height=ui.fixed(AI_CHIP_HEIGHT),padding={5,0,5,0},gap=4,align_y=.Center,fill=ui.tone(ctx,"field"),radius=ui.metric(ctx,"radius_control")}) {
            ui.icon(ctx,ai_annotate_icon(),ui.tone(ctx,"text_muted"),12)
            ui.label(ctx,ai_chat_menu_label(ctx,group,max(size-AI_CHIP_ROOM-AI_CHIP_PIN_ROOM,1),ui.metric(ctx,"font_small")),ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted"),size-40-AI_CHIP_PIN_ROOM)
            ai_chip_pin(s,ui.id(ctx,"pin_annotation_group",i+1),AI_PIN_GROUP,group,group)
            if ui.button(ctx,ui.id(ctx,"remove_annotation_group",i+1),{icon=.Cross,icon_color=ui.tone(ctx,"text_muted"),icon_size=10,padding=-1,variant="ghost",width=12,height=12}).clicked {remove=i}
        }
        used+=size+5
    }
    if used>0 {ui.box_end(ctx,{})}
    if remove>=0 {
        copy(a.groups[remove:a.group_count-1],a.groups[remove+1:a.group_count])
        a.group_count-=1
    }
}

// The groups of the next message, as its instructions name them.
@(private)
ai_annotation_groups_prompt :: proc(m:^Ai,b:^strings.Builder) {
    a:=&m.annotations
    if a.group_count==0 {return}
    fmt.sbprintf(b,"- This message is about the annotation group%s",a.group_count>1?"s":"")
    for i in 0..<a.group_count {fmt.sbprintf(b,"%s %s",i==0?":":",",base.text_get(a.groups[i][:]))}
    strings.write_string(b,".\n")
}

// ---------------------------------------------------------------- API

Ai_Annotation_List_Params :: struct {
    document:[1024]u8 `mirai:"optional,text,label=A document by its path; empty lists the open one"`,
}
Ai_Annotation_Result :: struct {
    id:int `mirai:"label=What annotation.remove takes"`,
    number:int `mirai:"label=The number the pin shows"`,
    group:[AI_ANNOTATION_GROUP_BYTES]u8 `mirai:"text,label=Its group; empty without one"`,
    document:[1024]u8 `mirai:"text"`,
    entity:base.Entity_Id `mirai:"optional,label=The entity it is on; absent on another surface"`,
    entity_name:[256]u8 `mirai:"text,label=Its name; empty on another surface or when its document is closed"`,
    position:[3]f32 `mirai:"label=In the world"`,
    note:[AI_ANNOTATION_TEXT_BYTES]u8 `mirai:"text"`,
}
Ai_Annotation_List_Result :: struct {
    annotations:[1]Ai_Annotation_Result `mirai:"list,label=The pins of the document in the order of their numbers"`,
}
Ai_Annotation_Remove_Params :: struct {
    id:int `mirai:"optional,min=0,label=One annotation by the id annotation.list gives; give id or group"`,
    group:[AI_ANNOTATION_GROUP_BYTES]u8 `mirai:"optional,text,label=Every annotation of this group of the open document; give id or group"`,
}
Ai_Annotation_Remove_Result :: struct {
    removed:int `mirai:"label=How many were taken out"`,
}

@(private)
ai_annotations_api_register :: proc(s:^Session,st:^Api_State) {
    api_register(s,st,{name="annotation.list",summary="The pins the user dropped on a document for the agent, with their numbers, groups, positions, entities and notes.",params=Ai_Annotation_List_Params,result=Ai_Annotation_List_Result,writes_result=true,flags={.Read_Only,.Idempotent},run=ai_method_annotation_list})
    api_register(s,st,{name="annotation.remove",summary="Takes out one annotation of the open document, or every annotation of one of its groups, when the agent is done with them.",params=Ai_Annotation_Remove_Params,result=Ai_Annotation_Remove_Result,run=ai_method_annotation_remove})
}

@(private)
ai_method_annotation_list :: proc(s:^Session,call:^api.Call) {
    ai_initialize(s)
    m:=s.ai
    document:=base.text_get(api.call_params(call,Ai_Annotation_List_Params).document[:])
    if document=="" {document=ai_annotations_document(s)}
    notes,message:=ai_store.annotations(&m.store,document)
    if message!="" {api.call_fail(call,api.SERVER_ERROR,message);return}
    w:=call.out
    serial.text_write_raw(w,`{"annotations":[`)
    for &note,index in notes {
        if index>0 {serial.write_u8(w,',')}
        serial.write_u8(w,'{')
        api.write_int(w,"id",note.id,true)
        api.write_int(w,"number",i64(index+1))
        api.write_text(w,"group",note.group_name)
        api.write_text(w,"document",note.document)
        if note.entity!=0 {api.write_key(w,"entity");api.write_id(w,base.Entity_Id(note.entity))}
        api.write_text(w,"entity_name",ai_annotation_entity_name(s,document,note.entity))
        position:=[3]f32{f32(note.x),f32(note.y),f32(note.z)}
        api.write_numbers(w,"position",position[:])
        api.write_text(w,"note",note.text)
        serial.write_u8(w,'}')
    }
    serial.text_write_raw(w,"]}")
}

@(private)
ai_method_annotation_remove :: proc(s:^Session,call:^api.Call) {
    ai_initialize(s)
    m:=s.ai
    p:=api.call_params(call,Ai_Annotation_Remove_Params)
    group:=base.text_get(p.group[:])
    if (p.id==0)==(group=="") {api.call_fail(call,api.INVALID_PARAMS,"give the id of an annotation or the name of a group of them: annotation.list has both");return}
    notes,message:=ai_store.annotations(&m.store,ai_annotations_document(s))
    if message!="" {api.call_fail(call,api.SERVER_ERROR,message);return}
    removed:=0
    for &note in notes {
        if p.id!=0?note.id!=i64(p.id):note.group_name!=group {continue}
        if failed:=ai_store.annotation_remove(&m.store,note.id);failed!="" {api.call_fail(call,api.SERVER_ERROR,failed);return}
        removed+=1
    }
    if p.id!=0 && removed==0 {api.call_failf(call,api.INVALID_PARAMS,"there is no annotation %d in the open document: annotation.list names them",p.id);return}
    m.annotations.stale=true
    api.call_result(call,Ai_Annotation_Remove_Result).removed=removed
}
