package editor

import "core:fmt"
import "core:math"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "mirai:asset"
import "mirai:core"
import "mirai:editor/ai_store"
import "mirai:editor/history"
import "mirai:std/base"
import "mirai:ui"

AI_MESSAGE_GAP :: f32(16)
// The look of the composer and of the chips of its context, as the design has them.
AI_CHIP_HEIGHT :: f32(24)
AI_CHIP_ROOM :: f32(50) // of a chip besides its name: padding, icon, gaps, the x and the border
AI_EFFORTS :: [3]string{"low","medium","high"}
AI_EFFORT_NAMES :: [3]string{"Low","Medium","High"}

@(private)
ai_chat_toggle :: proc(m:^Ai) {m.chat_open=!m.chat_open;m.focus=m.chat_open}

@(private)
ai_build :: proc(s:^Session) {
    ai_connections_build(s)
    if s.ai.details!=0 {ai_details_build(s)}
    ai_hit_view_build(s)
    ai_memory_editor_build(s)
    ai_annotations_build(s)
}

// Everything about one session that the panel does not show: how long it ran,
// what it ran with, what it was given and every tool it called with its result.
@(private)
ai_details_build :: proc(s:^Session) {
    m:=s.ai;ctx:=s.gui.ctx
    task:=ai_task_find(m,m.details)
    if task==nil || ui.escape(ctx) {m.details=0;return}
    id:=shell_id(s.gui,"ai_details")
    closed:=false
    defer if closed {m.details=0}
    if ui.modal(ctx,id,{width=520,scroll=&m.details_scroll,close=&closed,own_cross=true}) {
        ui.id_push(ctx,id)
        defer ui.id_pop(ctx)
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(ui.metric(ctx,"control")),gap=8,align_y=.Center}) {
            ui.icon(ctx,ai_agent_glyph(task),ai_agent_color(task),20)
            ui.label(ctx,base.text_get(task.title[:]),ui.metric(ctx,"font_heading"),ui.tone(ctx,"text"),0,font=ui.FONT_SEMIBOLD)
            ui.spacer(ctx)
            if ui.button(ctx,ui.id(ctx,"close"),{icon=.Cross,icon_color=ui.tone(ctx,"text_muted"),variant="ghost",width=24,height=24}).clicked {m.details=0}
        }
        ai_details_rows(s,task)
    }
}

// The details of a session a row each, and its tool calls with their results:
// the dialog of the panel and the Details of the Agents tab show them.
@(private)
ai_details_rows :: proc(s:^Session,task:^Ai_Task) {
    ctx:=s.gui.ctx
    row :: proc(ctx:^ui.Context,name,value:string) {
        if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=8}) {
            if ui.box(ctx,{width=ui.fixed(ui.metric(ctx,"label_width")),height=ui.FIT}) {ui.label(ctx,name,ui.metric(ctx,"font_small"),ui.tone(ctx,"text_label"))}
            ui.text(ctx,value,ui.prose(ctx,ui.metric(ctx,"font_small"),ui.tone(ctx,"text")))
        }
    }
    buffer:[256]u8
    names:=AI_STATE_NAMES
    row(ctx,"State",names[task.state])
    c:=&task.conversation
    running:=ai_task_finished(task)?0:ai_task_seconds(task)
    row(ctx,"Duration",fmt.bprintf(buffer[:],"%.1f s",c.seconds+running))
    if u:=c.usage;u.total>0 || u.input>0 {
        count :: proc(n:i64) -> string {
            if n<1000 {return fmt.tprintf("%d",n)}
            if n<1_000_000 {return fmt.tprintf("%.1fk",f64(n)/1e3)}
            return fmt.tprintf("%.2fM",f64(n)/1e6)
        }
        row(ctx,"Tokens",fmt.bprintf(buffer[:],"%s in · %s out · %s cached · %s total",count(u.input),count(u.output),count(u.cache_read+u.cache_write),count(u.total)))
    }
    if u:=c.usage;u.context_size>0 {
        row(ctx,"Context window",fmt.bprintf(buffer[:],"%s of %s · %d%%",fmt.tprintf("%d",u.context_used),fmt.tprintf("%d",u.context_size),int(f64(u.context_used)*100/f64(u.context_size))))
    }
    if c.usage.cost>0 {row(ctx,"Cost",fmt.bprintf(buffer[:],"$%.2f",c.usage.cost))}
    row(ctx,"Agent",fmt.bprintf(buffer[:],"%s · %s · %s effort",base.text_get(task.agent[:]),base.text_get(c.model[:]),base.text_get(c.effort[:])))
    row(ctx,"Scene context",fmt.bprintf(buffer[:],"%d of %d entities · %s",task.entities,task.entities_total,task.image?"viewport capture":"no capture"))
    if task.pid!=0 || task.exit_code!=0 {row(ctx,"Process",fmt.bprintf(buffer[:],"pid %d · exit %d",task.pid,task.exit_code))}
    if said:=base.text_get(task.said[:]);said!="" {row(ctx,"Agent printed",said)}
    if task.needs_build || task.files_changed {
        row(ctx,"Sources",task.files_changed?"files it could not keep changed; the turn cannot be reverted":"a build is needed")
    }
    ui.divider(ctx)
    calls:=0
    t:=&task.transcript
    for index in 0..<t.count {
        text,kind:=ai_transcript_line(t,index)
        if !ai_transcript_hidden(text,kind) {continue}
        calls+=1
        failed:=strings.has_prefix(text,"Tool failed: ")
        if ui.box(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column,padding=ui.padding_all(8),fill=ui.tone(ctx,"card"),radius=ui.metric(ctx,"radius_control")}) {
            ui.text(ctx,text,ui.prose(ctx,ui.metric(ctx,"font_small"),failed?ui.tone(ctx,"danger"):ui.tone(ctx,"text_muted")))
        }
    }
    if calls==0 {ui.label(ctx,"No tool calls",ui.metric(ctx,"font_small"),ui.tone(ctx,"text_faint"))}
}

// The agent of the chat shown, or the one the first message starts with.
@(private)
ai_chat_provider :: proc(m:^Ai) -> (provider:Ai_Provider,connected:bool) {
    found:bool
    provider,found=ai_provider_find(m,base.text_get(m.agent[:]))
    if found {return provider,m.connections[provider].configured}
    for &connection,candidate in ai_connections(m) {if connection.configured {return Ai_Provider(candidate),true}}
    return AI_CODEX,false
}

// The chat the selector of the model talks about: the main one also while an
// agent is inspected.
@(private)
ai_chat_target :: proc(m:^Ai) -> ^Ai_Task {
    task:=ai_task_find(m,m.selected)
    if task!=nil && ai_task_inspected(task) {return ai_task_find(m,m.main)}
    return task
}

// The model and effort of the chat: its own once it has turns, the ones of its
// agent for a new one.
@(private)
ai_chat_model :: proc(m:^Ai) -> (model,effort:string) {
    provider,_:=ai_chat_provider(m)
    connection:=&m.connections[provider]
    model,effort=base.text_get(connection.model[:]),base.text_get(connection.effort[:])
    if task:=ai_chat_target(m);task!=nil && string(task.conversation.provider[:task.conversation.provider_len])==ai_connection_id(m,provider) {
        c:=&task.conversation
        if c.model_len>0 {model=string(c.model[:c.model_len])}
        if c.effort_len>0 {effort=string(c.effort[:c.effort_len])}
    }
    return
}

// The name of a model as the composer shows it: short, since the mark of its
// agent says whose it is.
@(private)
ai_model_name :: proc(m:^Ai,provider:Ai_Provider,value:string) -> string {
    if value=="" {return "Default model"}
    if m.connections[provider].agent==.Codex {
        names:=AI_CODEX_MODEL_NAMES
        for model,index in AI_CODEX_MODELS {if model==value {return names[index]}}
        return value
    }
    for &choice in m.models[provider][:m.model_counts[provider]] {
        if base.text_get(choice.value[:])!=value {continue}
        name:=base.text_get(choice.name[:])
        if name=="" {return value}
        return strings.trim_prefix(name,"Claude ")
    }
    return value
}

// Chooses the model or the effort of the chat shown, and of what its agent
// starts with. Another agent takes the chat with its next turn.
@(private)
ai_chat_choose :: proc(s:^Session,provider:Ai_Provider,model,effort:string) {
    m:=s.ai
    previous,_:=ai_chat_provider(m)
    if message:=ai_connection_configure(s,provider,model,effort);message!="" {notify(s,message);return}
    base.text_set(m.agent[:],ai_connection_id(m,provider))
    if previous!=provider {return}
    task:=ai_chat_target(m)
    if task==nil || task.conversation.id==0 {return}
    c:=&task.conversation
    if model!="" {ai_store.conversation_set_text(c.model[:],&c.model_len,model)}
    if effort!="" {ai_store.conversation_set_text(c.effort[:],&c.effort_len,effort)}
    ai_task_dirty(task)
    ai_task_persist(s,task)
}

@(private)
ai_chat_submit :: proc(s:^Session) {
    m:=s.ai
    if m.pending || m.prompt_length==0 || ai_task_busy(m,m.selected) || m.login || m.installer.pid!=0 || !s.has_project {return}
    provider,connected:=ai_chat_provider(m)
    if !connected {return}
    base.text_set(m.agent[:],ai_connection_id(m,provider))
    m.pending,m.submit_frame=true,s.frame
    m.pending_model,m.pending_effort={},{}
}

// Sends what is written. To an agent that works it joins the turn without
// interrupting it; Stop is the only way to cut one. A chat of an agent outside
// the editor is not written to: the message goes to the main chat.
@(private)
ai_chat_send :: proc(s:^Session) -> bool {
    m:=s.ai
    if m.prompt_length==0 {return false}
    if shown:=ai_task_find(m,m.selected);shown!=nil && ai_task_external(shown) {m.selected=m.main}
    task:=ai_task_find(m,m.selected)
    if task==nil || ai_task_finished(task) {
        ai_chat_submit(s)
        return m.pending
    }
    note:=m.about!=0?ai_about_note(m,m.about):""
    if message:=ai_task_steer(s,m,task,string(m.prompt[:m.prompt_length]),note);message!="" {notify(s,message);return false}
    m.prompt_length=0
    m.about=0
    m.focus,m.stick=true,true
    return true
}

// Ask agent of a menu: the main chat in the left panel with its composer
// focused. The selection goes with the message as its chips; assets, as
// attachments.
ai_ask :: proc(s:^Session,assets:[]base.Asset_Id={}) {
    m:=s.ai
    if m==nil || !s.has_project {return}
    if m.main!=0 {m.selected=m.main}
    for id in assets {ai_attachment_add(s,id)}
    m.chat_open,m.focus=true,true
    s.gui.layout.left_open=true
}

// The title of a group of models: the mark of its agent and its name.
@(private)
ai_chat_models_header :: proc(ctx:^ui.Context,agent:Ai_Agent,name:string) {
    if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=6,padding={8,6,8,3},align_y=.Center}) {
        ai_connections_logo(ctx,agent,12)
        ui.label(ctx,name,ui.metric(ctx,"font_caption"),ui.tone(ctx,"text_faint"),0)
    }
}

// The models of the connected agents, each group under the mark and the name
// of its agent; the search keeps those whose name has it. Gives the one taken.
@(private)
ai_models_items :: proc(s:^Session,needle:string,current:Ai_Provider,chosen:string) -> (taken:Ai_Provider,model:string,picked:bool) {
    m:=s.ai;ctx:=s.gui.ctx
    any_model:=false
    for &connection,index in ai_connections(m) {
        if !connection.configured {continue}
        provider:=Ai_Provider(index)
        group:=base.text_get(connection.name[:])
        values:[64]string
        count:=0
        if connection.agent==.Codex {
            for value in AI_CODEX_MODELS {values[count]=value;count+=1}
        } else if m.model_counts[provider]==0 {
            values[0]=base.text_get(connection.model[:]);count=1
        } else {
            for &choice in m.models[provider][:min(m.model_counts[provider],len(values))] {values[count]=base.text_get(choice.value[:]);count+=1}
        }
        shown:=0
        for value in values[:count] {
            if base.contains_fold(group,needle) || base.contains_fold(ai_model_name(m,provider,value),needle) || base.contains_fold(value,needle) {shown+=1}
        }
        if shown==0 {continue}
        any_model=true
        ui.id_push(ctx,ui.id(ctx,"provider_models",index+1))
        defer ui.id_pop(ctx)
        ai_chat_models_header(ctx,connection.agent,group)
        for value,at in values[:count] {
            name:=ai_model_name(m,provider,value)
            if !base.contains_fold(group,needle) && !base.contains_fold(name,needle) && !base.contains_fold(value,needle) {continue}
            if ui.menu_item(ctx,ui.id(ctx,"model",at+1),name,{checked=current==provider && chosen==value}) {taken,model,picked=provider,value,true}
        }
    }
    if !any_model {ui.menu_header(ctx,needle!=""?"No models match":"No connected agents")}
    return
}

// Choices side by side as one control, the chosen one lit: gives the one
// clicked, or -1.
@(private)
ai_segments :: proc(ctx:^ui.Context,id:ui.Id,names:[]string,chosen:int,disabled:=false,height:ui.Size=ui.GROW) -> int {
    clicked:=-1
    if ui.box(ctx,{width=ui.GROW,height=height,gap=2,padding=ui.padding_all(2),fill=ui.tone(ctx,"well"),radius=ui.metric(ctx,"radius_popup")}) {
        for name,index in names {
            item:=ui.id_derive(ctx,id,"segment",index+1)
            it:=ui.interact(ctx,item,{.Passive} if disabled else {})
            on:=index==chosen
            fill:=ui.tone(ctx,"toggle_on") if on else (ui.tone(ctx,"field_hover") if it.hot && !disabled else ui.Color{})
            if ui.box(ctx,{id=item,width=ui.GROW,height=ui.GROW,align_x=.Center,align_y=.Center,fill=fill,stroke=on?ui.tone(ctx,"toggle_on_stroke"):{},stroke_width=1,radius=ui.metric(ctx,"radius_control")}) {
                ui.label(ctx,name,ui.metric(ctx,"font_small"),on?ui.tone(ctx,"text"):ui.tone(ctx,"text_muted"))
            }
            if it.clicked && !disabled && !on {clicked=index}
        }
    }
    return clicked
}

// Which of AI_EFFORTS a level is, or -1.
@(private)
ai_effort_index :: proc(effort:string) -> int {
    for value,index in AI_EFFORTS {if value==effort {return index}}
    return -1
}

// The name of a level of effort; empty if it is not one of AI_EFFORTS.
@(private)
ai_effort_name :: proc(effort:string) -> string {
    names:=AI_EFFORT_NAMES
    index:=ai_effort_index(effort)
    return index>=0?names[index]:""
}

// Low, Medium and High as one segmented row; the one of the chat lit.
@(private)
ai_chat_effort_build :: proc(s:^Session,disabled:bool) {
    m:=s.ai;ctx:=s.gui.ctx
    provider,_:=ai_chat_provider(m)
    _,effort:=ai_chat_model(m)
    values,names:=AI_EFFORTS,AI_EFFORT_NAMES
    ui.menu_header(ctx,"Effort")
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(26),padding={4,2,4,2},align_y=.Center}) {
        if picked:=ai_segments(ctx,ui.id(ctx,"effort"),names[:],ai_effort_index(effort),disabled);picked>=0 {ai_chat_choose(s,provider,"",values[picked])}
    }
}

// The menu of the model and the effort of the chat.
@(private)
ai_chat_models_menu :: proc(s:^Session,list:ui.Id,side:ui.Popup_Side) {
    m:=s.ai;ctx:=s.gui.ctx
    if ui.popup(ctx,list,{side=side,width=210,search="Search models"}) {
        current,connected:=ai_chat_provider(m)
        chosen,_:=ai_chat_model(m)
        needle,_:=ui.popup_search(ctx,list)
        if provider,model,picked:=ai_models_items(s,needle,current,chosen);picked {ai_chat_choose(s,provider,model,"")}
        ai_chat_effort_build(s,!connected)
        ui.menu_separator(ctx)
        if ui.menu_item(ctx,ui.id(ctx,"connections"),"AI connections...") {ai_connections_open(s)}
    }
}

// The model of the chat and its effort, quiet in the row of the composer, as
// one button that opens the menu of both.
@(private)
ai_chat_model_picker :: proc(s:^Session,busy:bool) {
    m:=s.ai;ctx:=s.gui.ctx
    provider,connected:=ai_chat_provider(m)
    model,effort:=ai_chat_model(m)
    id:=ui.id(ctx,"agent")
    list:=ui.id_derive(ctx,id,"menu")
    open:=ui.popup_is_open(ctx,list)
    it:=ui.interact(ctx,id,{.Passive} if busy else {})
    label:=ai_model_name(m,provider,model) if connected else "Select model"
    effort_label:=ai_effort_name(effort)
    color:=open || it.hot && !busy?ui.tone(ctx,"text"):ui.tone(ctx,"text_muted")
    if ui.box(ctx,{id=id,width=ui.FIT,height=ui.fixed(24),gap=6,align_y=.Center}) {
        if connected {ui.icon(ctx,ai_connection_mark(m.connections[provider].agent),color,13)}
        ui.label(ctx,ai_chat_menu_label(ctx,label,120,ui.metric(ctx,"font_small")),ui.metric(ctx,"font_small"),color)
        if effort_label!="" {
            if ui.box(ctx,{width=ui.FIT,height=ui.FIT,padding={4,0,0,0}}) {ui.label(ctx,effort_label,ui.metric(ctx,"font_small"),ui.tone(ctx,"text_faint"))}
        }
    }
    if it.clicked && !busy && !open {
        anchor,_:=ui.widget_rect(ctx,id)
        ui.popup_open(ctx,list,anchor)
    }
    // It opens over the composer: under it there is no room.
    ai_chat_models_menu(s,list,.Above)
}

// The clock and the expansion of the chat, in the bar of the panel beside its settings.
@(private)
ai_chat_bar_buttons :: proc(s:^Session) {
    g:=s.gui;ctx:=g.ctx;m:=s.ai
    popup:=shell_id(g,"ai_history_menu")
    history:=shell_id(g,"ai_history")
    if ui.button(ctx,history,{icon=.History,icon_color=ui.tone(ctx,"text_muted"),icon_size=15,variant="ghost",width=24,height=24,active=ui.popup_is_open(ctx,popup)}).clicked {
        m.history_scroll=0
        m.chat_hit_count=0
        if m.store.folder!="" {if message:=ai_history_refresh(m);message!="" {notify(s,message)}}
        anchor,_:=ui.widget_rect(ctx,history)
        ui.popup_open(ctx,popup,anchor)
    }
    corners:=m.chat_expanded?User_Icon.Corners_In:User_Icon.Corners_Out
    if ui.button(ctx,shell_id(g,"ai_expand"),{icon=ui.icon_user(u8(corners)),icon_color=m.chat_expanded?ui.tone(ctx,"text"):ui.tone(ctx,"text_muted"),icon_size=14,variant="ghost",width=24,height=24,active=m.chat_expanded}).clicked {m.chat_expanded=!m.chat_expanded}
}

AI_HISTORY_HEIGHT :: f32(320) // the most the list of History takes before it scrolls
AI_HISTORY_ROW :: f32(48)

// A finished agent: its color, its title with what the search found in it,
// how long ago it moved and how it ended.
@(private)
ai_history_row :: proc(s:^Session,id:ui.Id,color:ui.Color,title,last,needle:string,ago:i64,open:bool) -> bool {
    ctx:=s.gui.ctx
    it:=ui.popup_row(ctx,id)
    fill:=ui.tone(ctx,"toggle_on") if open else (ui.color_hover(ctx) if it.hot else ui.Color{})
    width:=AI_HISTORY_WIDTH
    if r,found:=ui.widget_rect(ctx,id);found {width=r.w}
    small:=ui.metric(ctx,"font_caption")
    if ui.box(ctx,{id=id,width=ui.GROW,height=ui.fixed(AI_HISTORY_ROW),padding={8,0,8,0},align_y=.Center,fill=fill,stroke=open?ui.tone(ctx,"toggle_on_stroke"):{},stroke_width=1,radius=ui.metric(ctx,"radius_control")}) {
        if ui.box(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column,gap=2}) {
            when_:=ai_time_ago(ago)
            room:=max(width-16-9-7-ui.text_width(&ctx.font,when_,small)-10,1)
            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(17),gap=7,align_y=.Center}) {
                pulse_dot(ctx,color,false,9)
                shown:=ai_chat_menu_label(ctx,title,room,ui.metric(ctx,"font_small"))
                at:=ai_index_fold(shown,needle) if needle!="" else -1
                if at>=0 && (shown==title || at+len(needle)<=len(shown)-len(ui.ELLIPSIS)) {
                    // What the search found, lit, in the run of the title.
                    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(17),align_y=.Center}) {
                        ui.label(ctx,shown[:at],ui.metric(ctx,"font_small"),ui.tone(ctx,"text"))
                        if ui.box(ctx,{width=ui.FIT,height=ui.fixed(15),align_y=.Center,fill=ui.color_alpha(ui.tone(ctx,"accent"),71),radius=2}) {
                            ui.label(ctx,shown[at:][:len(needle)],ui.metric(ctx,"font_small"),ui.tone(ctx,"text"),font=ui.FONT_SEMIBOLD)
                        }
                        ui.label(ctx,shown[at+len(needle):],ui.metric(ctx,"font_small"),ui.tone(ctx,"text"),0)
                    }
                } else {
                    ui.label(ctx,shown,ui.metric(ctx,"font_small"),ui.tone(ctx,"text"),0)
                }
                ui.label(ctx,when_,small,ui.tone(ctx,"text_muted"))
            }
            if last!="" {ui.label(ctx,ai_chat_menu_label(ctx,last,max(width-16,1),ui.metric(ctx,"font_small")),ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted"),0)}
        }
    }
    return it.clicked
}

AI_HISTORY_WIDTH :: f32(260)
AI_POPUP_WIDTH :: f32(304) // of the popups of the chat

// Where a search starts in text, whatever the case; -1: nowhere.
@(private)
ai_index_fold :: proc(text,needle:string) -> int {
    if needle=="" || len(needle)>len(text) {return -1}
    for i in 0..=len(text)-len(needle) {
        if strings.equal_fold(text[i:][:len(needle)],needle) {return i}
    }
    return -1
}

// How a finished agent ended, for its row: the state that is not a plain end,
// or the last thing it said.
@(private)
ai_finished_text :: proc(task:^Ai_Task,plain:[]u8) -> string {
    #partial switch task.state {
    case .Failed:      return "Failed"
    case .Cancelled:   return "Stopped"
    case .Interrupted: return "Interrupted"
    }
    return ai_entity_marks_plain(ai_transcript_last_answer(&task.transcript),plain)
}

// The clock: a search over the main chat, and the agents that finished, the
// latest first, each with how long ago it moved and how it ended. In the panel
// it is as wide as the panel; expanded, it hangs from its button.
@(private)
ai_chat_history_build :: proc(s:^Session,width:f32) {
    m:=s.ai;ctx:=s.gui.ctx
    popup:=shell_id(s.gui,"ai_history_menu")
    ui.id_push(ctx,popup)
    defer ui.id_pop(ctx)
    panel,_:=ui.widget_rect(ctx,shell_id(s.gui,"left"))
    within:=ui.Rect{panel.x+PANEL_PADDING,panel.y,panel.w-2*PANEL_PADDING,panel.h} if panel.w>0 && !m.chat_expanded else ui.Rect{}
    desc:=ui.Popup{width=min(within.w>0?within.w:width,AI_POPUP_WIDTH),within=within,side=.Below,search="Search this chat",align_right=m.chat_expanded}
    if ui.popup(ctx,popup,desc) {
        needle,changed:=ui.popup_search(ctx,popup)
        if changed {
            m.history_scroll=0
            ai_chat_hits_refresh(s,needle)
            if m.store.folder!="" {if message:=ai_history_refresh(m,0,needle);message!="" {notify(s,message)}}
        }
        now:=time.to_unix_nanoseconds(time.now())/1_000_000
        plain:[AI_LINE_BYTES]u8
        if ui.scroll_area(ctx,ui.id(ctx,"history_list"),&m.history_scroll,{height=ui.FIT,max_height=AI_HISTORY_HEIGHT}) {
            for &hit,index in m.chat_hits[:m.chat_hit_count] {
                text:=ai_chat_menu_label(ctx,string(hit.snippet[:hit.length]),max(desc.width-40,1))
                if ui.menu_item(ctx,ui.id(ctx,"hit",index+1),text) {
                    ai_chat_hit_open(s,hit.sequence)
                    ui.popup_close(ctx)
                }
            }
            ui.menu_header(ctx,"Finished agents")
            // Finished turns not saved yet, then the saved ones.
            #reverse for &task in m.tasks[:m.task_count] {
                if !ai_finished_agent(m,&task) || !base.contains_fold(base.text_get(task.title[:]),needle) {continue}
                saved:=false
                for conversation in m.history[:m.history_count] {if int(conversation.id)==task.id {saved=true;break}}
                if saved {continue}
                if ai_history_row(s,ui.id(ctx,"task",task.id),ai_agent_color(&task),ai_chat_title(base.text_get(task.title[:])),ai_finished_text(&task,plain[:]),needle,now-task.conversation.updated_at,task.id==m.selected) {
                    ai_chat_select(s,&task)
                    ui.popup_close(ctx)
                }
            }
            for &conversation in m.history[:m.history_count] {
                task:=ai_task_find(m,int(conversation.id))
                if task!=nil && !ai_task_finished(task) {continue}
                _,color:=ai_conversation_glyph(m,&conversation)
                last:=string(conversation.last[:conversation.last_len])
                if task!=nil {
                    color=ai_agent_color(task)
                    if needle=="" {last=ai_finished_text(task,plain[:])}
                }
                if ai_history_row(s,ui.id(ctx,"conversation",int(conversation.id)),color,ai_chat_title(string(conversation.title[:conversation.title_len])),last,needle,now-conversation.updated_at,int(conversation.id)==m.selected) {
                    ai_history_select(s,&conversation)
                    ui.popup_close(ctx)
                }
            }
        }
    }
}

// The title of a conversation as a menu shows it.
@(private)
ai_chat_title :: proc(title:string) -> string {return title if title!="" else "Untitled"}

// How long ago, in milliseconds, as the history says it: now, 5m, 2h, 3d, 4w.
@(private)
ai_time_ago :: proc(ms:i64) -> string {
    minutes:=max(ms,0)/60_000
    switch {
    case minutes<1:       return "now"
    case minutes<60:      return fmt.tprintf("%dm",minutes)
    case minutes<24*60:   return fmt.tprintf("%dh",minutes/60)
    case minutes<7*24*60: return fmt.tprintf("%dd",minutes/(24*60))
    }
    return fmt.tprintf("%dw",minutes/(7*24*60))
}

@(private)
ai_chat_menu_label :: proc(ctx:^ui.Context,text:string,width:f32,size:f32=0) -> string {
    size:=size if size>0 else ui.metric(ctx,"font_small")
    if ui.text_width(&ctx.font,text,size)<=width {return text}
    prefix:=ui.text_cut(&ctx.font,text,size,max(width,0))
    bytes:=ui.text_reserve(ctx,len(prefix)+len(ui.ELLIPSIS))
    if bytes==nil {return ""}
    used:=copy(bytes,prefix);used+=copy(bytes[used:],ui.ELLIPSIS)
    return ui.text_commit(ctx,string(bytes[:used]))
}

AI_COMPOSER_HEIGHT :: f32(84) // the composer without chips: its text, its row of buttons and its padding
AI_PROMPT_HEIGHT :: f32(42)   // the field of the message, of AI_COMPOSER_HEIGHT, while two lines hold it
AI_PROMPT_MAX :: f32(168)     // the most it grows to with what is written: past it, it scrolls

// The height of the field of the message in a composer width wide: it grows
// with the lines of what is written, as the text wraps.
ai_prompt_height :: proc(s:^Session,width,size:f32) -> f32 {
    m:=s.ai
    text:=string(m.prompt[:m.prompt_length])
    if text=="" {return AI_PROMPT_HEIGHT}
    return clamp(ui.text_height(s.gui.ctx,text,ui.prose(s.gui.ctx,size),max(width-AI_PROMPT_ROOM,1))+6,AI_PROMPT_HEIGHT,AI_PROMPT_MAX)
}
@(private) AI_PROMPT_ROOM :: f32(22) // of a composer, what its field does not take of its width

// The chat in width by height. size: of its text; nonzero, the chat is expanded
// and the right column says what its status line would.
ai_chat_content_build :: proc(s:^Session,width,height:f32,size:f32=0) {
    m:=s.ai
    ctx:=s.gui.ctx
    expanded:=size>0
    size:=expanded?size:ui.metric(ctx,"font_small")
    id:=shell_id(s.gui,"ai_chat")
    ui.id_push(ctx,id)
    defer ui.id_pop(ctx)
    if rect,found:=ui.widget_rect(ctx,id);found {m.chat_rect=rect}
    if ui.box(ctx,{id=id,width=ui.fixed(width),height=ui.fixed(max(height,140)),direction=.Column,gap=6,track=true}) {
        task:=ai_task_find(m,m.selected)
        inspected:=task!=nil && ai_task_inspected(task)
        agents_height:=AI_INSPECT_HEAD if inspected else (0 if expanded else ai_chat_agents_height(s,width,height))
        if inspected {ai_chat_inspect_build(s,task,width)}
        else if !expanded {ai_chat_agents_build(s,width,height)}
        all_context_rows:=ai_composer_context_rows(s,width)
        context_rows:=min(all_context_rows,min(4,max(int((height-258-agents_height)/(AI_CHIP_HEIGHT+5)),0)))
        context_height:=f32(context_rows)*(AI_CHIP_HEIGHT+5)
        if all_context_rows>context_rows {context_height+=18}
        current:=task!=nil && ai_task_current(s,task)
        // Under the thread, over the composer: the review of the session.
        under:=f32(0)
        if current {
            if part:=ai_chat_task_actions_height(s,task);part>0 {under=part+6}
        }
        composer:=AI_COMPOSER_HEIGHT-AI_PROMPT_HEIGHT+ai_prompt_height(s,width,size)
        transcript_height:=max(height-composer-6-agents_height-(6 if agents_height>0 else 0)-context_height-under,8)
        switch {
        case task!=nil:
            // The first message takes the composer from the middle down to its place.
            rise:=f32(0)
            if m.composer_drop_at>0 {
                t:=clamp(f32((ctx.time-m.composer_drop_at)/AI_COMPOSER_DROP),0,1)
                if t>=1 {m.composer_drop_at=0} else {
                    rest:=m.chat_rect.y+height-composer-context_height
                    rise=clamp((rest-m.composer_drop_from)*(1-t)*(1-t)*(1-t),0,max(transcript_height-8,0))
                }
            }
            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(transcript_height-rise),padding={AI_THREAD_MARGIN,0,0,0}}) {
                ai_transcript_draw(s,m,task,transcript_height-rise,width-2*AI_THREAD_MARGIN,expanded?size:0)
            }
            if current {ai_chat_task_actions(s,task,width)}
            ai_composer_build(s,width,context_rows,ui.tone(ctx,"well"),ui.tone(ctx,"well_stroke"),size)
            if rise>0 {if ui.box(ctx,{width=ui.GROW,height=ui.fixed(rise)}) {}}
            m.composer_empty_y=0
        case agents_height==0:
            m.composer_empty_y=m.chat_rect.y+ai_chat_empty_top(transcript_height)
            ai_chat_empty_build(s,width,transcript_height,context_rows)
        case:
            m.composer_empty_y=0
            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(transcript_height)}) {}
            ai_composer_build(s,width,context_rows,ui.tone(ctx,"well"),ui.tone(ctx,"well_stroke"),size)
        }
    }
    // An asset dropped on the chat goes with the next message, and an entity
    // joins the selection, which goes too.
    g:=s.gui
    if g.drag.kind!=.Asset && g.drag.kind!=.Entity {return}
    area:=m.chat_rect
    if drag_over(g,area) {
        if ui.box(ctx,{width=ui.fixed(area.w),height=ui.fixed(area.h),float={to=.Surface,offset={area.x,area.y},layer=ui.LAYER_PANEL},fill=ui.color_alpha(ui.tone(ctx,"accent"),18),stroke=ui.color_alpha(ui.tone(ctx,"accent"),140),stroke_width=1.5,radius=ui.metric(ctx,"radius_popup")}) {}
    }
    if drag_dropped(g,area) {
        switch g.drag.kind {
        case .Asset:  ai_attachment_add(s,g.drag.asset_id)
        case .Entity: if g.drag.entity!=core.NONE {history.selection_add(s.selection,g.drag.entity);m.focus=true}
        case .None,.Preset:
        }
        g.drag={}
    }
}

// Before the first message, with no agent at work: the composer in the
// middle of the panel, a little above its center, under the mark in gray.
@(private)
ai_chat_empty_build :: proc(s:^Session,width,room:f32,context_rows:int) {
    ctx:=s.gui.ctx
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(max(ai_chat_empty_top(room)-AI_EMPTY_MARK-AI_EMPTY_GAP,0))}) {}
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(AI_EMPTY_MARK),align_x=.Center,align_y=.Center}) {
        ui.icon(ctx,ui.icon_user(u8(User_Icon.Mirai_Shape)),ui.tone(ctx,"well_stroke"),AI_EMPTY_MARK)
    }
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(AI_EMPTY_GAP)}) {}
    ai_composer_build(s,width,context_rows,ui.tone(ctx,"popup"),ui.tone(ctx,"well_stroke"),ui.metric(ctx,"font"))
}
@(private) AI_EMPTY_RISE :: f32(20) // what the composer of an empty chat stands above the middle
@(private) AI_THREAD_MARGIN :: f32(8) // of the thread from the sides of the panel, beyond its padding
@(private) AI_COMPOSER_DROP :: 0.22  // seconds the composer takes from the middle down on the first message

// Where the composer of an empty chat starts, from the top of the chat.
@(private)
ai_chat_empty_top :: proc(room:f32) -> f32 {return max(room*0.5-AI_EMPTY_RISE,AI_EMPTY_MARK+AI_EMPTY_GAP)}
@(private) AI_EMPTY_MARK :: f32(88) // side of the mark over it
@(private) AI_EMPTY_GAP :: f32(20)

// The rows of chips the context of the next message takes at width: the
// selection, the values of a material, the reference images, the assets and
// the ticks of the Play.
@(private)
ai_composer_context_rows :: proc(s:^Session,width:f32) -> int {
    rows:=ai_selection_context_rows(s,width-16)+ai_material_chip_rows(s,width-22)
    rows+=ai_reference_rows(s,width-22)+ai_attachment_rows(s,width-22)+ai_annotation_group_rows(s,width-22)+ai_pin_rows(s,width-22)
    return rows+ai_range_rows(s.ai)+ai_about_rows(s.ai)
}

// The message and what goes with it: over the field, up to context_rows of
// chips of what it takes; under it, the model and its effort, an image to
// attach, the context window used, and send or stop.
@(private)
ai_composer_build :: proc(s:^Session,width:f32,context_rows:int,fill,stroke:ui.Color,size:f32=0) {
    m:=s.ai
    ctx:=s.gui.ctx
    size:=size>0?size:ui.metric(ctx,"font_small")
    field:=ui.id(ctx,"prompt")
    shown:=ai_task_find(m,m.selected)
    subagent:=shown!=nil && ai_task_subagent(shown)
    placeholder:="Message..."
    if subagent {placeholder=ui.text_store(ctx,fmt.tprintf("Message %s...",ai_chat_menu_label(ctx,ai_chat_title(base.text_get(shown.title[:])),max(width-90,1),size)))}
    if ui.box(ctx,{id=ui.id(ctx,"composer"),width=ui.GROW,height=ui.FIT,direction=.Column,padding={9,7,9,6},gap=5,fill=fill,stroke=ctx.edit.id==field?ui.tone(ctx,"accent"):stroke,radius=ui.metric(ctx,"radius_popup"),track=true}) {
        pin_rows:=min(ai_pin_rows(s,width-22),context_rows)
        ai_pins_build(s,width-22,pin_rows)
        about_rows:=min(ai_about_rows(m),context_rows-pin_rows)
        ai_about_build(s,width-22,about_rows)
        context_rows:=context_rows-pin_rows-about_rows
        entity_rows:=min(ai_selection_context_rows(s,width-16),context_rows)
        ai_selection_context_build(s,width-22,entity_rows)
        material_rows:=min(ai_material_chip_rows(s,width-22),context_rows-entity_rows)
        ai_material_chips_build(s,width-22,material_rows)
        reference_rows:=min(ai_reference_rows(s,width-22),context_rows-entity_rows-material_rows)
        ai_references_build(s,width-22,reference_rows)
        left:=context_rows-entity_rows-material_rows-reference_rows
        attachment_rows:=min(ai_attachment_rows(s,width-22),left)
        ai_attachments_build(s,width-22,attachment_rows)
        left-=attachment_rows
        group_rows:=min(ai_annotation_group_rows(s,width-22),left)
        ai_annotation_groups_build(s,width-22,group_rows)
        ai_range_build(s,width-22,left-group_rows)
        if m.focus {ui.edit_request(ctx,field);m.focus=false}
        result:=ui.text_field(ctx,field,m.prompt[:AI_MESSAGE_BYTES-1],&m.prompt_length,{live=true,keep_caret=true,placeholder=placeholder,height=ai_prompt_height(s,width,size),size=size,bare=true,multiline=true})
        // Enter sends, Shift+Enter adds a line, and Enter with nothing
        // written keeps the result of the turn that waits for review.
        if result.committed && .Enter in ctx.input.keys_pressed {
            if m.prompt_length>0 {ai_chat_send(s)}
            else if task:=ai_task_find(m,m.selected);task!=nil && ai_task_reviewable(task) && task.question==.None {
                ai_task_finish(s,m,task)
            }
        }
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(24),gap=2,align_y=.Center}) {
            busy:=ai_task_busy(m,m.selected)
            _,connected:=ai_chat_provider(m)
            if !subagent {ai_chat_model_picker(s,busy)}
            ui.spacer(ctx)
            if !subagent {
                ai_context_window_build(s,width)
                ai_annotate_button(s)
                if ui.button(ctx,ui.id(ctx,"attach"),{icon=.Texture,icon_color=ui.tone(ctx,"text_muted"),icon_size=14,variant="ghost",width=24,height=24,disabled=m.reference_count>=AI_REFERENCES}).clicked {ai_reference_ask(s)}
            }
            // While the agent works the button stops it; something written is sent instead.
            if busy && m.prompt_length==0 {
                if ui.button(ctx,ui.id(ctx,"stop"),{icon=.Stop,icon_size=11,variant="accent",width=24,height=24}).clicked {
                    if task:=ai_task_find(m,m.selected);task!=nil {ai_task_cancel(s,m,task)}
                }
            } else if ui.button(ctx,ui.id(ctx,"send"),{icon=ui.icon_user(u8(User_Icon.Up)),icon_size=15,variant="accent",width=24,height=24,disabled=m.pending || m.prompt_length==0 || !connected || m.login || m.installer.pid!=0 || !s.has_project}).clicked {ai_chat_send(s)}
        }
    }
}

// Tokens as the context says them: 840, 124k, 1.2M.
@(private)
ai_tokens_short :: proc(n:i64) -> string {
    if n<1000 {return fmt.tprintf("%d",n)}
    if n<1_000_000 {return fmt.tprintf("%dk",n/1000)}
    return fmt.tprintf("%.1fM",f64(n)/1e6)
}

// How much of its context window the chat has used, as its agent reports it:
// the percent, which opens how many tokens that is and Compact now.
@(private)
ai_context_window_build :: proc(s:^Session,width:f32) {
    m:=s.ai;ctx:=s.gui.ctx
    task:=ai_task_find(m,m.selected)
    if task==nil {return}
    u:=task.conversation.usage
    if u.context_size<=0 {return}
    fraction:=clamp(f64(u.context_used)/f64(u.context_size),0,1)
    percent:=int(f64(u.context_used)*100/f64(u.context_size))
    id:=ui.id(ctx,"context_window")
    popup:=ui.id_derive(ctx,id,"popup")
    open:=ui.popup_is_open(ctx,popup)
    it:=ui.interact(ctx,id,{.Focusable})
    if ui.box(ctx,{id=id,width=ui.FIT,height=ui.fixed(24),padding={5,0,5,0},align_y=.Center,fill=open?ui.tone(ctx,"raised"):(it.hot?ui.color_hover(ctx):{}),radius=ui.metric(ctx,"radius_control")}) {
        ui.label(ctx,fmt.tprintf("%d%%",percent),ui.metric(ctx,"font_caption"),open?ui.tone(ctx,"text"):(percent>=80?ui.tone(ctx,"danger"):ui.tone(ctx,"text_faint")))
    }
    if it.clicked && !open {
        // Over the composer, not over the percent inside it.
        anchor,_:=ui.widget_rect(ctx,ui.id(ctx,"composer"))
        ui.popup_open(ctx,popup,anchor)
    }
    popup_width:=min(width,AI_POPUP_WIDTH)
    if ui.popup(ctx,popup,{side=.Above,width=popup_width,within=m.chat_rect,align_right=true,padding=12,gap=10}) {
        if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=8,align_y=.Center}) {
            ui.label(ctx,"Context",ui.metric(ctx,"font"),ui.tone(ctx,"text"),0,font=ui.FONT_MEDIUM)
            ui.label(ctx,fmt.tprintf("%s of %s tokens",ai_tokens_short(u.context_used),ai_tokens_short(u.context_size)),ui.metric(ctx,"font_caption"),ui.tone(ctx,"text_muted"))
        }
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(4),fill=ui.tone(ctx,"well"),radius=2}) {
            if ui.box(ctx,{width=ui.fixed(f32(fraction)*(popup_width-24)),height=ui.fixed(4),fill=ui.tone(ctx,"accent"),radius=2}) {}
        }
        if ui.button(ctx,ui.id(ctx,"compact"),{label="Compact now",variant="accent",width=-1,height=28,size=ui.metric(ctx,"font_small"),center=true}).clicked {
            if message:=ai_chat_compact(s,task);message!="" {notify(s,message)}
            ui.popup_close(ctx,popup)
        }
    }
}

@(private)
ai_selection_context_width :: proc(ctx:^ui.Context,w:core.World_Ref,e:core.Entity,width:f32) -> f32 {
    return min(width,math.ceil(ui.text_width(&ctx.font,entity_name(w,e),ui.metric(ctx,"font_small")))+AI_CHIP_ROOM+AI_CHIP_PIN_ROOM)
}

@(private)
ai_selection_context_rows :: proc(s:^Session,width:f32) -> int {
    // A document in front talks about what is picked in it, not about the scene.
    if front:=asset_document_in_front(s);front!=nil {
        if front.kind==asset.KIND_MATERIAL || front.picked_count==0 {return 0}
        used:=f32(0);rows:=1
        for i in 0..<front.picked_count {
            size:=min(width,math.ceil(ui.text_width(&s.gui.ctx.font,base.text_get(front.picked[i][:]),ui.metric(s.gui.ctx,"font_small")))+AI_CHIP_ROOM)
            if used>0 && used+size>width {rows+=1;used=0}
            used+=size+5
        }
        return rows
    }
    if s.selection==nil || len(s.selection.entities)==0 {return 0}
    used:=f32(0);rows:=1
    w:=shown_world(s)
    for e in s.selection.entities {
        size:=ai_selection_context_width(s.gui.ctx,w,e,width)
        if used>0 && used+size>width {rows+=1;used=0}
        used+=size+5
    }
    return rows
}

@(private)
ai_selection_context_build :: proc(s:^Session,width:f32,rows:int) {
    ctx:=s.gui.ctx
    if front:=asset_document_in_front(s);front!=nil {
        if front.kind==asset.KIND_MATERIAL {return}
        used:=f32(0);row:=0
        for i in 0..<front.picked_count {
            label:=base.text_get(front.picked[i][:])
            size:=min(width,math.ceil(ui.text_width(&ctx.font,label,ui.metric(ctx,"font_small")))+AI_CHIP_ROOM)
            if used>0 && used+size>width {ui.box_end(ctx,{});row+=1;used=0}
            if row>=rows {break}
            if used==0 {ui.box_begin(ctx,{width=ui.GROW,height=ui.fixed(AI_CHIP_HEIGHT),gap=5,align_y=.Center})}
            if ui.box(ctx,{width=ui.fixed(size),height=ui.fixed(AI_CHIP_HEIGHT),padding={5,0,5,0},gap=4,align_y=.Center,fill=ui.tone(ctx,"field"),radius=ui.metric(ctx,"radius_control")}) {
                ui.icon(ctx,asset_document_icon(s,front),ui.tone(ctx,"text_muted"),12)
                ui.label(ctx,ai_chat_menu_label(ctx,label,max(size-AI_CHIP_ROOM+12,1),ui.metric(ctx,"font_small")),ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted"),size-28)
            }
            used+=size+5
        }
        if used>0 {ui.box_end(ctx,{})}
        return
    }
    if s.selection==nil {return}
    w:=shown_world(s)
    remove:=core.NONE
    used:=f32(0);row:=0;shown:=0
    for e,index in s.selection.entities {
        size:=ai_selection_context_width(ctx,w,e,width)
        if used>0 && used+size>width {ui.box_end(ctx,{});row+=1;used=0}
        if row>=rows {break}
        if used==0 {ui.box_begin(ctx,{width=ui.GROW,height=ui.fixed(AI_CHIP_HEIGHT),gap=5,align_y=.Center})}
        if ui.box(ctx,{width=ui.fixed(size),height=ui.fixed(AI_CHIP_HEIGHT),padding={5,0,5,0},gap=4,align_y=.Center,fill=ui.tone(ctx,"field"),radius=ui.metric(ctx,"radius_control")}) {
            icon,_:=entity_icon(s,w,e)
            name:=entity_name(w,e)
            label:=ai_chat_menu_label(ctx,name,max(size-AI_CHIP_ROOM-AI_CHIP_PIN_ROOM,1),ui.metric(ctx,"font_small"))
            look:=ui.Node_Style{radius=2,text={size=ui.metric(ctx,"font_small"),color=ui.tone(ctx,"text_muted")}}
            if ui.button(ctx,ui.id(ctx,"context",index+1),{label=label,icon=icon,icon_color=ui.tone(ctx,"text_muted"),icon_size=12,padding=-1,variant="ghost",width=size-28-AI_CHIP_PIN_ROOM,height=AI_CHIP_HEIGHT-2,size=ui.metric(ctx,"font_small"),look=&look}).clicked {focus_selection(s,w)}
            ai_chip_pin(s,ui.id(ctx,"pin_context",index+1),AI_PIN_ENTITY,ai_entity_id_text(w,entity_author(w,e)),name)
            if ui.button(ctx,ui.id(ctx,"remove_context",index+1),{icon=.Cross,icon_color=ui.tone(ctx,"text_muted"),icon_size=10,padding=-1,variant="ghost",width=12,height=12,look=&look}).clicked {remove=e}
        }
        used+=size+5;shown+=1
    }
    if used>0 {ui.box_end(ctx,{})}
    if len(s.selection.entities)>shown {
        text:=ui.text_commit(ctx,fmt.bprintf(ui.text_reserve(ctx,32),"+%d selected",len(s.selection.entities)-shown))
        ui.label(ctx,text,ui.metric(ctx,"font_small"),ui.tone(ctx,"text_faint"))
    }
    if remove!=core.NONE {history.selection_toggle(s.selection,remove)}
}

// What the next message takes of the document of a material, as chips: the
// values picked, the channel the preview shows and the variant set last.
// Taking one out unpicks it, shows the lit sphere or forgets the variant.
@(private)
Ai_Material_Chip :: struct {label:string,pick:int} // pick: of Ai_Material_Context.picks; -1: the channel; -2: the variant

@(private)
ai_material_chips :: proc(s:^Session) -> []Ai_Material_Chip {
    if !material_document_shown(s) {return nil}
    m:=&s.ai.material
    chips:=make([dynamic]Ai_Material_Chip,0,m.pick_count+2,context.temp_allocator)
    for i in 0..<m.pick_count {append(&chips,Ai_Material_Chip{readable(base.text_get(m.picks[i][:])),i})}
    if channel:=base.text_get(m.channel[:]);channel!="" {append(&chips,Ai_Material_Chip{fmt.tprintf("%s channel",readable(channel)),-1})}
    if variant:=base.text_get(m.variant[:]);variant!="" {append(&chips,Ai_Material_Chip{fmt.tprintf("Variant %s",variant),-2})}
    return chips[:]
}

@(private)
ai_material_chip_rows :: proc(s:^Session,width:f32) -> int {
    chips:=ai_material_chips(s)
    if len(chips)==0 {return 0}
    ctx:=s.gui.ctx
    used:=f32(0);rows:=1
    for chip in chips {
        size:=min(width,math.ceil(ui.text_width(&ctx.font,chip.label,ui.metric(ctx,"font_small")))+AI_CHIP_ROOM)
        if used>0 && used+size>width {rows+=1;used=0}
        used+=size+5
    }
    return rows
}

@(private)
ai_material_chips_build :: proc(s:^Session,width:f32,rows:int) {
    if rows<=0 {return}
    ctx:=s.gui.ctx
    chips:=ai_material_chips(s)
    remove:=-3
    used:=f32(0);row:=0
    for chip,i in chips {
        size:=min(width,math.ceil(ui.text_width(&ctx.font,chip.label,ui.metric(ctx,"font_small")))+AI_CHIP_ROOM)
        if used>0 && used+size>width {ui.box_end(ctx,{});row+=1;used=0}
        if row>=rows {break}
        if used==0 {ui.box_begin(ctx,{width=ui.GROW,height=ui.fixed(AI_CHIP_HEIGHT),gap=5,align_y=.Center})}
        if ui.box(ctx,{width=ui.fixed(size),height=ui.fixed(AI_CHIP_HEIGHT),padding={5,0,5,0},gap=4,align_y=.Center,fill=ui.tone(ctx,"field"),radius=ui.metric(ctx,"radius_control")}) {
            look:=ui.Node_Style{radius=2,text={size=ui.metric(ctx,"font_small"),color=ui.tone(ctx,"text_muted")}}
            ui.icon(ctx,.Material,ui.tone(ctx,"text_muted"),12)
            ui.label(ctx,ai_chat_menu_label(ctx,chip.label,max(size-AI_CHIP_ROOM,1),ui.metric(ctx,"font_small")),ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted"),size-40)
            if ui.button(ctx,ui.id(ctx,"remove_material",i+1),{icon=.Cross,icon_color=ui.tone(ctx,"text_muted"),icon_size=10,padding=-1,variant="ghost",width=12,height=12,look=&look}).clicked {remove=chip.pick}
        }
        used+=size+5
    }
    if used>0 {ui.box_end(ctx,{})}
    w:=&s.materials.document
    switch {
    case remove>=0: material_pick_toggle(w,base.text_get(s.ai.material.picks[remove][:]),true)
    case remove==-1: w.channel=.Lit
    case remove==-2: w.chosen,w.applied=0,{}
    }
}

// The text of a message with a line break inside each word longer than a
// line of width at size, so that it wraps instead of overflowing; in the
// temporary allocator when it breaks one.
@(private)
ai_chat_paragraph_text :: proc(ctx:^ui.Context,text:string,width,size:f32) -> string {
    if text=="" {return " "}
    buffer:[]u8
    used:=0
    word:=f32(0)
    for rune,index in text {
        end:=index+1
        for end<len(text) && (u8(text[end])&0xc0)==0x80 {end+=1}
        if rune==' ' || rune=='\t' || rune=='\n' {word=0}
        else {
            step:=ui.text_width(&ctx.font,text[index:end],size)
            if word>0 && word+step>width {
                if buffer==nil {
                    buffer=make([]u8,2*len(text),context.temp_allocator)
                    used=copy(buffer,text[:index])
                }
                buffer[used]='\n';used+=1;word=0
            }
            word+=step
        }
        if buffer!=nil {used+=copy(buffer[used:],text[index:end])}
    }
    return buffer==nil?text:string(buffer[:used])
}
