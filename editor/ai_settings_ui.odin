package editor

import "core:fmt"
import "core:strings"
import "mirai:project"
import "mirai:std/base"
import "mirai:ui"

// The sections of the gear of the chat: what the agents run with and what
// they remember.

AI_MEMORY_TOPICS_SHOWN :: 32
AI_SETTINGS_MEMORY_HEIGHT :: f32(240) // the most the memory takes of the popup before it scrolls

Ai_Memory_Ui :: struct {
    project:[AI_MEMORY_INDEX_BYTES]u8, // what AGENTS.md held when the gear opened
    project_length:int,
    user:[AI_MEMORY_USER_BYTES]u8,     // and USER.md
    user_length:int,
    topics:[AI_MEMORY_TOPICS_SHOWN][AI_MEMORY_TOPIC_NAME]u8,
    topic_count:int,
    scroll:[2]f32,
    // The file being edited.
    editing:bool,
    scope:[8]u8,
    topic:[AI_MEMORY_TOPIC_NAME]u8,
    text:[AI_MESSAGE_BYTES]u8,
    length:int,
}

// Reads what the memory section shows. Only when the gear opens: it touches files.
ai_memory_ui_refresh :: proc(s:^Session) {
    m:=s.ai;e:=&m.memory_ui
    e.project_length,e.user_length,e.topic_count=0,0,0
    if !s.has_project {return}
    index,_:=ai_memory_load(project.path(s.project_root,AI_PROJECT_MEMORY,allocator=context.temp_allocator),len(e.project))
    e.project_length=copy(e.project[:],index)
    if path:=ai_memory_user_path(m);path!="" {
        user,_:=ai_memory_load(path,len(e.user))
        e.user_length=copy(e.user[:],user)
    }
    if m.store.db==nil {return}
    ai_memory_scan(s)
    docs,message:=ai_store_memory_list(&m.store)
    if message!="" {notify(s,message);return}
    for &doc in docs {
        if e.topic_count==len(e.topics) {break}
        name:=strings.trim_suffix(strings.trim_prefix(doc.path,AI_MEMORY_FOLDER+"/"),".md")
        base.text_set(e.topics[e.topic_count][:],name)
        e.topic_count+=1
    }
}

// Saves what a subagent runs with, by the code path of ai.configure.
@(private)
ai_subagent_save :: proc(s:^Session,mode,connection,model,effort:string) {
    p:=new(Ai_Configure_Params,context.temp_allocator)
    base.text_set(p.subagent_mode[:],mode)
    base.text_set(p.subagent_connection[:],connection)
    base.text_set(p.subagent_model[:],model)
    base.text_set(p.subagent_effort[:],effort)
    if message:=ai_subagent_configure(s,p);message!="" {notify(s,message)}
}

// A model as a field: the mark of its agent, its name and its effort. Opens the
// popup it gives.
@(private)
ai_model_field :: proc(ctx:^ui.Context,id:ui.Id,agent:Ai_Agent,known:bool,label,effort:string) -> ui.Id {
    th:=&ctx.theme
    list:=ui.id_derive(ctx,id,"menu")
    open:=ui.popup_is_open(ctx,list)
    it:=ui.interact(ctx,id,{.Focusable})
    if ui.box(ctx,{id=id,width=ui.GROW,height=ui.fixed(th.control),gap=7,padding={8,0,8,0},align_y=.Center,fill=th.well,stroke=open?th.accent:(it.hot?th.well_stroke_hover:th.well_stroke),stroke_width=1,radius=th.radius_control}) {
        if known {ui.icon(ctx,ai_connection_mark(agent),th.text_muted,13)}
        ui.label(ctx,label,th.font_small,th.text,0)
        if effort!="" {ui.label(ctx,effort,th.font_small,th.text_muted)}
    }
    if it.clicked && !open {
        anchor,_:=ui.widget_rect(ctx,id)
        ui.popup_open(ctx,list,anchor)
    }
    return list
}

@(private)
ai_settings_heading :: proc(ctx:^ui.Context,text:string) {
    ui.label(ctx,text,ctx.theme.font,ctx.theme.text,font=ui.FONT_MEDIUM)
}

@(private)
ai_settings_caption :: proc(ctx:^ui.Context,text:string) {
    ui.label(ctx,text,ctx.theme.font_caption,ctx.theme.text_muted,font=ui.FONT_MEDIUM)
}

// The model of the main chat, and what the subagents run with.
@(private)
ai_settings_agents_build :: proc(s:^Session) {
    m:=s.ai;ctx:=s.gui.ctx
    ai_settings_heading(ctx,"Agents")
    ai_settings_caption(ctx,"Main chat")
    provider,connected:=ai_chat_provider(m)
    model,effort:=ai_chat_model(m)
    label:=connected?ai_model_name(m,provider,model):"Select model"
    list:=ai_model_field(ctx,ui.id(ctx,"main_model"),m.connections[provider].agent,connected,label,ai_effort_name(effort))
    ai_chat_models_menu(s,list,.Auto)

    ai_settings_caption(ctx,"Subagents")
    names:=[3]string{"Same","Fixed","Agent picks"}
    values:=AI_SUBAGENT_MODES
    mode_names:=[3]string{values[.Same],values[.Fixed],values[.Pick]}
    defaults:=&m.subagent
    if picked:=ai_segments(ctx,ui.id(ctx,"subagent_mode"),names[:],int(defaults.mode),!s.has_project,ui.fixed(ctx.theme.control));picked>=0 {
        // Fixed starts as the main chat runs, when it has nothing of its own yet.
        connection,chosen,level:="","",""
        if Ai_Subagent_Mode(picked)==.Fixed && base.text_get(defaults.connection[:])=="" {connection,chosen,level=ai_connection_id(m,provider),model,effort}
        ai_subagent_save(s,mode_names[picked],connection,chosen,level)
    }
    if defaults.mode!=.Fixed {return}
    fixed,known:=ai_provider_find(m,base.text_get(defaults.connection[:]))
    fixed_model:=base.text_get(defaults.model[:])
    fixed_label:=fixed_model
    agent:=m.connections[provider].agent
    if known {
        agent=m.connections[fixed].agent
        fixed_label=ai_model_name(m,fixed,fixed_model)
    }
    fixed_list:=ai_model_field(ctx,ui.id(ctx,"subagent_model"),agent,known,fixed_label,"")
    if ui.popup(ctx,fixed_list,{width=210,search="Search models"}) {
        needle,_:=ui.popup_search(ctx,fixed_list)
        if taken,value,picked:=ai_models_items(s,needle,fixed,fixed_model);picked {ai_subagent_save(s,"",ai_connection_id(m,taken),value,"")}
    }
    efforts,effort_names:=AI_EFFORTS,AI_EFFORT_NAMES
    if picked:=ai_segments(ctx,ui.id(ctx,"subagent_effort"),effort_names[:],ai_effort_index(base.text_get(defaults.effort[:])),false,ui.fixed(ctx.theme.control));picked>=0 {
        ai_subagent_save(s,"","","",efforts[picked])
    }
}

// What the agents remember: the index of the project, its topics and the file
// of the user, each with what edits it.
@(private)
ai_settings_memory_build :: proc(s:^Session) {
    m:=s.ai;ctx:=s.gui.ctx;th:=&ctx.theme
    e:=&m.memory_ui
    inner:=AI_POPUP_WIDTH-24-10
    head :: proc(s:^Session,id:ui.Id,title,scope,topic:string) {
        ctx:=s.gui.ctx
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(24),gap=6,align_y=.Center}) {
            ui.label(ctx,title,ctx.theme.font_small,ctx.theme.text_muted,0)
            if ui.button(ctx,id,{label="Edit",style=.Ghost,height=22,size=ctx.theme.font_small,padding=6,disabled=!s.has_project}).clicked {ai_memory_edit(s,scope,topic)}
        }
    }
    ai_settings_heading(ctx,"Memory")
    if ui.scroll_area(ctx,ui.id(ctx,"memory"),&e.scroll,{height=ui.FIT,max_height=AI_SETTINGS_MEMORY_HEIGHT,gap=6}) {
        head(s,ui.id(ctx,"edit_project"),"This project","project","")
        if text:=string(e.project[:e.project_length]);text!="" {ui.markdown(ctx,ui.id(ctx,"project_text"),text,inner,ai_markdown_style(s,th.font_small))}
        for index in 0..<e.topic_count {
            topic:=base.text_get(e.topics[index][:])
            head(s,ui.id(ctx,"edit_topic",index+1),topic,"project",topic)
        }
        head(s,ui.id(ctx,"edit_user"),"You, in every project","user","")
        if text:=string(e.user[:e.user_length]);text!="" {ui.markdown(ctx,ui.id(ctx,"user_text"),text,inner,ai_markdown_style(s,th.font_small))}
    }
}

// Opens a memory file in the dialog that edits it: the editor has no other
// editor of Markdown.
@(private)
ai_memory_edit :: proc(s:^Session,scope,topic:string) {
    m:=s.ai;e:=&m.memory_ui
    path:string
    switch {
    case scope=="user":
        path=ai_memory_user_path(m)
        if path=="" {notify(s,"This editor has no folder for the agents");return}
    case topic=="": path=project.path(s.project_root,AI_PROJECT_MEMORY,allocator=context.temp_allocator)
    case:           path=project.path(s.project_root,AI_MEMORY_FOLDER,fmt.tprintf("%s.md",topic),allocator=context.temp_allocator)
    }
    text,cut:=ai_memory_load(path,len(e.text)-1)
    if cut {notify(s,"The file is too long to edit here: edit it outside the editor");return}
    e.length=copy(e.text[:],text)
    base.text_set(e.scope[:],scope)
    base.text_set(e.topic[:],topic)
    e.editing=true
    ui.popup_close(s.gui.ctx)
    s.gui.ctx.edit={}
}

// The dialog of a memory file: what it shows replaces the file when saved.
@(private)
ai_memory_editor_build :: proc(s:^Session) {
    m:=s.ai;ctx:=s.gui.ctx;th:=&ctx.theme
    e:=&m.memory_ui
    if !e.editing {return}
    if ui.escape(ctx) {e.editing=false;return}
    closed:=false
    defer if closed {e.editing=false}
    id:=shell_id(s.gui,"ai_memory_editor")
    if ui.modal(ctx,id,{width=560,close=&closed,own_cross=true}) {
        ui.id_push(ctx,id)
        defer ui.id_pop(ctx)
        scope,topic:=base.text_get(e.scope[:]),base.text_get(e.topic[:])
        title:=topic
        if topic=="" {title=scope=="user"?"Your memory":"Project memory"}
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(th.control),align_y=.Center}) {
            ui.label(ctx,title,th.font_title,th.text,font=ui.FONT_SEMIBOLD)
            ui.spacer(ctx)
            if ui.icon_button(ctx,ui.id(ctx,"close"),.Cross,26).clicked {e.editing=false}
        }
        ui.text_field(ctx,ui.id(ctx,"text"),e.text[:AI_MESSAGE_BYTES-1],&e.length,{live=true,multiline=true,enter_inserts=true,keep_caret=true,height=360})
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(th.control),gap=8,align_x=.End,align_y=.Center}) {
            if ui.button(ctx,ui.id(ctx,"cancel"),{label="Cancel",style=.Field,height=th.control,center=true,padding=14}).clicked {e.editing=false}
            if ui.button(ctx,ui.id(ctx,"save"),{label="Save",style=.Accent,height=th.control,center=true,padding=14}).clicked {
                if _,message:=ai_memory_save(s,scope,topic,string(e.text[:e.length]));message!="" {notify(s,message)}
                else {
                    e.editing=false
                    ai_memory_ui_refresh(s)
                }
            }
        }
    }
}
