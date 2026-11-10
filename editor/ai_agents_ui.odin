package editor

import "core:fmt"
import "core:math"
import "core:path/filepath"
import "core:strings"
import "mirai:core"
import "mirai:editor/ai_store"
import "mirai:editor/history"
import erender "mirai:engine/render"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:ui"

AI_AGENT_ICON_COUNT :: 6 // glyphs of agents that come by command: those of Claude and Codex follow
AI_AGENT_GLYPHS :: AI_AGENT_ICON_COUNT+2
AI_GLYPH_CLAUDE :: u8(AI_AGENT_ICON_COUNT)
AI_GLYPH_CODEX :: u8(AI_AGENT_ICON_COUNT+1)
ai_agent_color :: proc "contextless" (task:^Ai_Task) -> ui.Color {return agent_color(int(task.color_index))}

ai_agent_icon :: proc "contextless" (task:^Ai_Task) -> ui.Icon {
    band:=u8(0)
    if task.question!=.None {band=2*AI_AGENT_GLYPHS} else if ai_task_finished(task) && !task.review_finished {band=AI_AGENT_GLYPHS}
    return ui.icon_user(u8(User_Icon.Agent_Star)+task.icon%AI_AGENT_GLYPHS+band)
}

// The glyph alone, as the rows of the chat show it: what the session waits
// for goes beside it.
ai_agent_glyph :: proc "contextless" (task:^Ai_Task) -> ui.Icon {
    return ui.icon_user(u8(User_Icon.Agent_Star)+task.icon%AI_AGENT_GLYPHS)
}

// The glyph and color of a saved conversation that is not loaded: those of
// its agent, the color as a new session takes it.
ai_conversation_glyph :: proc(m:^Ai,c:^ai_store.Conversation) -> (glyph:ui.Icon,color:ui.Color) {
    icon:=u8(c.id%AI_AGENT_ICON_COUNT)
    if glyph,ok:=ai_external_glyph(ai_external_client(string(c.provider[:c.provider_len])));ok {
        icon=glyph
    } else if provider,known:=ai_provider_find(m,string(c.provider[:c.provider_len]));known {
        #partial switch m.connections[provider].agent {
        case .Claude: icon=AI_GLYPH_CLAUDE
        case .Codex:  icon=AI_GLYPH_CODEX
        }
    }
    return ui.icon_user(u8(User_Icon.Agent_Star)+icon),agent_color(int((c.id-1)%u64(len(AGENT_COLORS))))
}

ai_agent_visible :: proc "contextless" (task:^Ai_Task) -> bool {return !ai_task_finished(task) || ai_task_reviewable(task)}

// A unit is listed under the status line while it works or waits for review.
// The main chat is not one: it is what the panel shows.
ai_session_row_shown :: proc(s:^Session,task:^Ai_Task) -> bool {
    return task.id!=s.ai.main && ai_task_current(s,task) && ai_agent_visible(task)
}

// A finished subagent of the main chat, as the clock lists them.
ai_finished_agent :: proc(m:^Ai,task:^Ai_Task) -> bool {
    return ai_task_subagent(task) && task.conversation.parent==u64(m.main) && ai_task_finished(task)
}

// How many units work and how many changes wait for review, and the rows of the list.
@(private)
ai_units_count :: proc(s:^Session) -> (working,changes,rows:int) {
    for &task in s.ai.tasks[:s.ai.task_count] {
        if !ai_session_row_shown(s,&task) {continue}
        rows+=1
        if !ai_task_finished(&task) {working+=1}
        else if ai_task_reviewable(&task) {changes+=ai_review_count(&task)}
    }
    return
}

// The glyph of a turn: the mark of Claude or Codex, or one of the others for
// an agent by command, chosen so the turns that are around tell apart.
ai_task_glyph_set :: proc(m:^Ai,task:^Ai_Task) {
    if glyph,ok:=ai_external_glyph(ai_external_client(base.text_get(task.agent[:])));ok {task.icon=glyph;return}
    provider,known:=ai_provider_find(m,base.text_get(task.agent[:]))
    if known {
        #partial switch m.connections[provider].agent {
        case .Claude: task.icon=AI_GLYPH_CLAUDE;return
        case .Codex:  task.icon=AI_GLYPH_CODEX;return
        }
    }
    if task.icon<AI_AGENT_ICON_COUNT {return}
    task.icon=u8(task.id)%AI_AGENT_ICON_COUNT
}

@(private)
ai_agent_avatar_draw :: proc(ctx:^ui.Context,rect:ui.Rect,index:u8,color:ui.Color) {
    band:=index/AI_AGENT_GLYPHS
    attention:=band>0
    glyph:=index%AI_AGENT_GLYPHS
    side:=min(rect.w,rect.h)
    c:=ui.rect_center(rect)
    unit:=side/29
    ui.draw_rounded(ctx,rect,side*.5,ui.color_alpha(color,35))
    ui.draw_rounded_stroke(ctx,rect,side*.5,unit,ui.color_alpha(color,65))
    s:=side/41
    switch glyph {
    case 0:
        points:[10][2]f32
        for &point,i in points {
            angle:=-f32(math.PI)*.5+f32(i)*f32(math.PI)/5
            radius:=9*s if i%2==0 else 4.1*s
            point=c+[2]f32{math.cos(angle),math.sin(angle)}*radius
        }
        ui.draw_polyline(ctx,points[:],1.2*unit,color,true)
    case 1:
        points:=[6][2]f32{c+{s,-10*s},c+{-7*s,s},c+{-s,s},c+{-2*s,10*s},c+{7*s,-2*s},c+{s,-2*s}}
        ui.draw_polyline(ctx,points[:],1.2*unit,color,true)
    case 2:
        points:=[10][2]f32{c+{-8*s,9*s},c+{-8*s,-3*s},c+{-5*s,-7*s},c+{0,-9*s},c+{5*s,-7*s},c+{8*s,-3*s},c+{8*s,9*s},c+{4*s,7*s},c+{0,9*s},c+{-4*s,7*s}}
        ui.draw_polyline(ctx,points[:],1.2*unit,color,true)
        for x in ([2]f32{-3,3}) {ui.draw_line(ctx,c+{x*s,-2*s},c+{x*s,0},1.2*unit,color)}
    case 3:
        points:=[7][2]f32{c+{0,-9*s},c+{7*s,-6*s},c+{7*s,0},c+{4*s,6*s},c+{0,9*s},c+{-4*s,6*s},c+{-7*s,0}}
        ui.draw_polyline(ctx,points[:],1.2*unit,color,true)
        ui.draw_polyline(ctx,([][2]f32{c+{-3*s,-s},c+{-s,s},c+{3*s,-3*s}}),1.2*unit,color)
    case 4:
        points:=[8][2]f32{c+{7*s,-8*s},c+{-2*s,-9*s},c+{-6*s,-5*s},c+{-7*s,s},c+{-4*s,6*s},c+{s,6*s},c+{4*s,2*s},c+{6*s,-3*s}}
        ui.draw_polyline(ctx,points[:],1.2*unit,color,true)
        ui.draw_line(ctx,c+{-8*s,9*s},c+{2*s,-s},1.2*unit,color)
    case 5:
        left:=[7][2]f32{c+{-6*s,-8*s},c+{-s,-4*s},c+{s,4*s},c+{-4*s,8*s},c+{-10*s,3*s},c+{-6*s,s},c+{-6*s,-8*s}}
        right:=[5][2]f32{c+{-s,-4*s},c+{7*s,-8*s},c+{10*s,-3*s},c+{7*s,3*s},c+{s,4*s}}
        ui.draw_polyline(ctx,left[:],1.2*unit,color)
        ui.draw_polyline(ctx,right[:],1.2*unit,color)
    case AI_GLYPH_CLAUDE:
        // The spark of Claude: rays of two lengths around the middle.
        for k in 0..<12 {
            angle:=f32(k)*f32(math.PI)/6+0.13
            direction:=[2]f32{math.cos(angle),math.sin(angle)}
            outer:=f32(9.5) if k%2==0 else 7
            ui.draw_line(ctx,c+direction*1.8*s,c+direction*outer*s,1.5*unit,color)
        }
    case AI_GLYPH_CODEX:
        // Codex: a terminal with its prompt.
        ui.draw_rounded_stroke(ctx,{c.x-9.5*s,c.y-7.5*s,19*s,15*s},2.5*s,1.2*unit,color)
        ui.draw_polyline(ctx,([][2]f32{c+{-5*s,-3*s},c+{-1.5*s,0},c+{-5*s,3*s}}),1.2*unit,color)
        ui.draw_line(ctx,c+{0.5*s,3.2*s},c+{5.5*s,3.2*s},1.2*unit,color)
    case:
    }
    if attention {
        center:=[2]f32{rect.x+rect.w-2*unit,rect.y+2*unit}
        ui.draw_circle(ctx,center,7*unit,ctx.theme.popup)
        ui.draw_circle(ctx,center,5.5*unit,color)
        ink:=ctx.theme.bar_top
        if band>1 {
            // A question: the hook of a '?' over its dot.
            hook:=[5][2]f32{center+{-1.6*unit,-1.4*unit},center+{0,-2.6*unit},center+{1.6*unit,-1.4*unit},center+{0,-.2*unit},center+{0,.6*unit}}
            ui.draw_polyline(ctx,hook[:],1.1*unit,ink)
        } else {
            ui.draw_line(ctx,center+{0,-2.4*unit},center+{0,.5*unit},1.3*unit,ink)
        }
        ui.draw_circle(ctx,center+{0,2.3*unit},.75*unit,ink)
    }
}

ai_chat_select :: proc(s:^Session,task:^Ai_Task) {
    ai_task_select(s.ai,task)
    s.ai.prompt_length=0
    s.ai.review_open=false
    library_select(s,.Ai)
    s.gui.ctx.edit={}
}

@(private)
ai_chat_settings_button :: proc(s:^Session) {
    g:=s.gui;ctx:=g.ctx
    popup:=shell_id(g,"ai_settings_popup")
    id:=shell_id(g,"library_settings")
    if ui.button(ctx,id,{icon=ui.icon_user(u8(User_Icon.Gear)),icon_color=ctx.theme.text_muted,icon_size=15,style=.Ghost,width=24,height=24,active=ui.popup_is_open(ctx,popup)}).clicked {
        anchor,_:=ui.widget_rect(ctx,id)
        ai_memory_ui_refresh(s)
        ui.popup_open(ctx,popup,anchor)
    }
}

@(private)
ai_chat_settings_build :: proc(s:^Session) {
    ctx:=s.gui.ctx;m:=s.ai
    if ui.popup(ctx,shell_id(s.gui,"ai_settings_popup"),{align_right=true,width=AI_POPUP_WIDTH,padding=12,gap=10}) {
        ui.id_push(ctx,shell_id(s.gui,"ai_settings_popup"))
        ai_settings_agents_build(s)
        ui.divider(ctx)
        ai_settings_memory_build(s)
        ui.divider(ctx)
        if ui.menu_item(ctx,ui.id(ctx,"connections"),"Connections",{icon=ui.icon_user(u8(User_Icon.Connection)),disabled=!s.has_project}) {ai_connections_open(s)}
        if ui.menu_item(ctx,ui.id(ctx,"scene_agents"),"Show agents in scene",{icon=.Eye,checked=m.show_agents_in_scene}) {
            m.show_agents_in_scene=!m.show_agents_in_scene
            m.scene_serial+=1
        }
        ui.id_pop(ctx)
    }
}

AI_AGENT_ROW :: f32(32)

AI_STATUS_HEIGHT :: f32(28)
AI_STATUS_DOTS :: 6 // dots of the status line; more agents do not fit beside its text

@(private)
ai_chat_agents_height :: proc(s:^Session,width,height:f32) -> f32 {
    working,changes,rows:=ai_units_count(s)
    if working==0 && changes==0 {return 0}
    if !s.ai.agents_open {return AI_STATUS_HEIGHT}
    return AI_STATUS_HEIGHT+3+min(f32(rows)*(AI_AGENT_ROW+3)-3,max(height-255-AI_STATUS_HEIGHT,AI_AGENT_ROW))
}

// What the agents are doing, on one line, under the bar of the panel:
// the dots of those that work and how many changes wait.
@(private)
ai_chat_status_build :: proc(s:^Session,working,changes:int) {
    m:=s.ai;ctx:=s.gui.ctx;th:=&ctx.theme
    id:=ui.id(ctx,"agent_status")
    it:=ui.interact(ctx,id)
    if it.clicked {m.agents_open=!m.agents_open}
    text:=""
    if working>0 {text=working==1?"1 agent working":fmt.tprintf("%d agents working",working)}
    if changes>0 {
        part:=changes==1?"1 change to review":fmt.tprintf("%d changes to review",changes)
        text=text!=""?fmt.tprintf("%s · %s",text,part):part
    }
    if ui.box(ctx,{id=id,width=ui.GROW,height=ui.fixed(AI_STATUS_HEIGHT),gap=8,padding={6,0,6,0},align_y=.Center,fill=it.hot?ui.color_hover(th):{},radius=th.radius_control}) {
        if working>0 {
            dots:=min(working,AI_STATUS_DOTS)
            if ui.box(ctx,{width=ui.fixed(f32(dots-1)*12+15),height=ui.fixed(15)}) {
                drawn:=0
                for &task in m.tasks[:m.task_count] {
                    if drawn==dots {break}
                    if !ai_session_row_shown(s,&task) || ai_task_finished(&task) {continue}
                    if ui.box(ctx,{width=ui.fixed(15),height=ui.fixed(15),align_x=.Center,align_y=.Center,fill=th.panel,radius=7.5,float={to=.Parent,offset={f32(drawn)*12,0}}}) {pulse_dot(ctx,ai_agent_color(&task),true,11)}
                    drawn+=1
                }
            }
        }
        ui.label(ctx,text,th.font_small,th.text_muted,0)
        ui.icon(ctx,m.agents_open?.Chevron_Up:.Chevron_Down,th.text_muted,11)
    }
}

// What a session waits for from the user, at the right end of its row: an
// answer to a permission (!) or to a question (?), or how many of its changes
// wait for review. Empty while it works or when it waits for nothing.
@(private)
ai_session_badge :: proc(m:^Ai,task:^Ai_Task,buffer:[]u8) -> string {
    if ai_permission_of(m,task)>=0 {return "!"}
    if !ai_task_finished(task) {return ""}
    if task.question!=.None {return "?"}
    if ai_task_reviewable(task) && task.review.pending {
        if count:=ai_review_count(task);count>0 {return fmt.bprintf(buffer,"%d",count)}
    }
    return ""
}

@(private)
ai_session_badge_build :: proc(ctx:^ui.Context,text:string,color:ui.Color) {
    th:=&ctx.theme
    width:=max(ui.text_width(&ctx.font,text,th.font_caption,int(ui.FONT_SEMIBOLD))+8,16)
    if ui.box(ctx,{width=ui.fixed(width),height=ui.fixed(16),align_x=.Center,align_y=.Center,fill=color,radius=8}) {
        ui.label(ctx,text,th.font_caption,th.well,font=ui.FONT_SEMIBOLD)
    }
}

// The status line and, unfolded, one row per unit that works or waits for the
// user: the color of its agent, its glyph, its title and what it waits for, or
// the dot while it works. A click inspects it.
@(private)
ai_chat_agents_build :: proc(s:^Session,width,panel_height:f32) {
    m:=s.ai;ctx:=s.gui.ctx;th:=&ctx.theme
    working,changes,_:=ai_units_count(s)
    if working==0 && changes==0 {m.agents_open=false;return}
    ai_chat_status_build(s,working,changes)
    if !m.agents_open {return}
    height:=ai_chat_agents_height(s,width,panel_height)-AI_STATUS_HEIGHT-3
    if ui.scroll_area(ctx,ui.id(ctx,"agent_tasks"),&m.list_scroll,{width=ui.GROW,height=ui.fixed(height),gap=3}) {
        for &task in m.tasks[:m.task_count] {
            if !ai_session_row_shown(s,&task) {continue}
            color:=ai_agent_color(&task)
            current:=m.selected==task.id
            // The whole row is what the pointer lights and a click opens.
            row:=ui.id(ctx,"agent_task",task.id)
            it:=ui.interact(ctx,row)
            if it.clicked {ai_chat_select(s,&task)}
            buffer:[16]u8
            badge:=ai_session_badge(m,&task,buffer[:])
            working:=!ai_task_finished(&task) && badge==""
            full:=base.text_get(task.title[:])
            // The title takes the row but its color, its glyph and what it waits for.
            finishable:=ai_task_finished(&task) && !task.review_finished
            room:=width-2-7-18-7-8-(24 if badge!="" || working else 0)-(20 if run_find(s,task.id)!=nil else 0)-(29 if current else 0)-(29 if finishable else 0)
            label:=ai_chat_menu_label(ctx,full,max(room,1),th.font_small)
            if it.hot && label!=full {ui.tooltip(ctx,full)}
            fill:=th.toggle_on if current else (th.raised if it.hot else th.card)
            stroke:=th.toggle_on_stroke if current else th.border
            if ui.box(ctx,{id=row,width=ui.GROW,height=ui.fixed(AI_AGENT_ROW),gap=7,align_y=.Center,padding={0,0,8,0},fill=fill,stroke=stroke,stroke_width=1,radius=th.radius_control}) {
                if ui.box(ctx,{width=ui.fixed(2),height=ui.fixed(AI_AGENT_ROW-2),fill=color}) {}
                ui.icon(ctx,ai_agent_glyph(&task),color,18)
                ui.label(ctx,label,th.font_small,th.text,0)
                if run_find(s,task.id)!=nil {ui.icon(ctx,.Play,color,13)}
                if working {pulse_dot(ctx,color,true)}
                if badge!="" {ai_session_badge_build(ctx,badge,color)}
                if current && ui.button(ctx,ui.id(ctx,"agent_details",task.id),{icon=ui.icon_user(u8(User_Icon.List)),icon_color=th.text_muted,icon_size=14,tip="Details",style=.Ghost,width=22,height=22,active=m.details==task.id}).clicked {
                    m.details=0 if m.details==task.id else task.id
                }
                // Done with it: what it changed is kept and the session leaves the rows.
                if finishable && ui.button(ctx,ui.id(ctx,"agent_finish",task.id),{icon=.Check,icon_color=th.accent,icon_size=13,tip="Finish",style=.Ghost,width=22,height=22}).clicked {
                    ai_task_finish(s,m,&task)
                }
            }
        }
    }
}

// The changes a turn waiting for review made, walked one at a time: the
// entities first, then the files.
@(private)
ai_review_count :: proc "contextless" (task:^Ai_Task) -> int {
    return len(task.review.changed_ids)+len(task.review.changed_files)
}

// The height the review of a session takes over the composer: the head of
// its changes, a row each up to AI_CHANGE_ROWS while it is unfolded, and the
// row of Build.
@(private)
ai_chat_task_actions_height :: proc(s:^Session,task:^Ai_Task) -> f32 {
    if task==nil {return 0}
    height:=f32(0)
    if count:=ai_review_count(task);ai_task_reviewable(task) && count>0 {height=ai_review_card_height(count,s.ai.review_open)}
    if task.needs_build {height+=(height>0?6:0)+AI_ACTION_ROW}
    return height
}

AI_ACTION_ROW :: f32(30)
AI_CHANGE_ROW :: f32(28)
AI_CHANGE_ROWS :: 5 // rows of changes the review shows; the rest scroll
PULSE_SECONDS :: 1.6 // a dot of something that works fades out and in again in this time

@(private)
ai_review_card_height :: proc(count:int,open:bool) -> f32 {
    height:=2*4+AI_ACTION_ROW
    if open {
        rows:=min(count,AI_CHANGE_ROWS)
        height+=2+f32(rows)*AI_CHANGE_ROW+f32(rows-1)
    }
    return height
}

// A dot that fades out and in while what it stands for works, lit otherwise.
pulse_dot :: proc(ctx:^ui.Context,color:ui.Color,working:bool,side:f32=7) {
    alpha:=u8(255)
    if working {
        phase:=math.sin(f32(ctx.time)*2*math.PI/PULSE_SECONDS)
        alpha=u8(70+185*(0.5+0.5*phase))
    }
    if ui.box(ctx,{width=ui.fixed(side),height=ui.fixed(side),fill=ui.color_alpha(color,alpha),radius=side*.5}) {}
}

// The one review of a session, over the composer: how many changes wait,
// putting all of them back and keeping all of them; unfolded, a row per
// change that walks to it, puts it back or keeps it.
ai_chat_task_actions :: proc(s:^Session,task:^Ai_Task,width:f32) {
    ctx:=s.gui.ctx;m:=s.ai;th:=&ctx.theme
    if !ai_task_reviewable(task) && !task.needs_build {return}
    count:=ai_review_count(task)
    // A walk through the changes of another unit, from its card, is left alone.
    walked:=ai_task_find(m,m.review_task)
    if m.review_task!=task.id && (walked==nil || !ai_task_reviewable(walked) || m.review_at<0) {m.review_task=task.id;m.review_at=-1}
    if m.review_task==task.id && m.review_at>=count {m.review_at=-1}
    if ai_task_reviewable(task) && count>0 {
        buffer:[64]u8
        card:=ui.id(ctx,"review_card")
        if ui.box(ctx,{id=card,width=ui.GROW,height=ui.fixed(ai_review_card_height(count,m.review_open)),direction=.Column,gap=2,padding=ui.padding_all(4),fill=th.popup,stroke=th.divider,stroke_width=1,radius=th.radius_popup}) {
            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(AI_ACTION_ROW),gap=3,align_y=.Center}) {
                fold:=ui.id(ctx,"review_header")
                it:=ui.interact(ctx,fold)
                label:=count==1?"1 change":fmt.bprintf(buffer[:],"%d changes",count)
                if ui.box(ctx,{id=fold,width=ui.FIT,height=ui.fixed(24),gap=6,padding={6,0,6,0},align_y=.Center,fill=it.hot?ui.color_hover(th):{},radius=th.radius_control}) {
                    ui.icon(ctx,m.review_open?.Chevron_Down:.Chevron_Right,th.text_faint,9)
                    ui.label(ctx,label,th.font_small,th.text,font=ui.FONT_SEMIBOLD)
                }
                if it.clicked {m.review_open=!m.review_open}
                ui.spacer(ctx)
                if ui.button(ctx,ui.id(ctx,"revert"),{icon=.Revert,icon_color=th.text_muted,style=.Ghost,width=22,height=22,icon_size=12,disabled=task.files_changed || !ai_review_revertible(s,&task.review)}).clicked {
                    ai_review_revert_all(s,task)
                    return
                }
                if ui.button(ctx,ui.id(ctx,"finish"),{label="Accept all",style=.Accent,height=22,size=th.font_small,padding=10}).clicked {
                    ai_task_finish(s,m,task)
                    return
                }
            }
            if m.review_open {
                visible:=min(count,AI_CHANGE_ROWS)
                if ui.scroll_area(ctx,ui.id(ctx,"review_changes"),&m.review_scroll,{width=ui.GROW,height=ui.fixed(f32(visible)*AI_CHANGE_ROW+f32(visible-1)),gap=1}) {
                    for i in 0..<count {
                        if ai_review_change_row(s,task,i) {break}
                    }
                }
            }
        }
    }
    if task.needs_build {
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(AI_ACTION_ROW),align_y=.Center}) {
            ui.spacer(ctx)
            if ui.button(ctx,ui.id(ctx,"build"),{label="Build",icon=ui.icon_user(u8(User_Icon.Component)),style=.Accent,height=24}).clicked {action_run(s,.Build)}
        }
    }
}

// Whether the pointer is on what id drew in the last frame.
@(private)
ai_pointer_on :: proc(ctx:^ui.Context,id:ui.Id) -> bool {
    rect,found:=ui.widget_rect(ctx,id)
    p:=ctx.pointer
    return found && p.x>=rect.x && p.x<rect.x+rect.w && p.y>=rect.y && p.y<rect.y+rect.h
}

// One change of the turn, as git says it (A created, M changed, D deleted),
// and its name, which walks to it; putting it back and keeping it show while
// the pointer is on the row or the walk is on it. True when the list changed
// under it.
@(private)
ai_review_change_row :: proc(s:^Session,task:^Ai_Task,index:int) -> (changed:bool) {
    m:=s.ai;ctx:=s.gui.ctx;th:=&ctx.theme
    w:=edited_world(s)
    ids:=len(task.review.changed_ids)
    name,status:="",u8('M')
    switch {
    case index<ids:
        id:=task.review.changed_ids[index]
        if ai_review_deleted(w,task,id) {
            name,status=ai_review_deleted_name(w,task,id),'D'
        } else {
            name=entity_name(w,history.change_entity(w,id))
            added,kept:=false,false
            for &transaction in task.review.transactions {
                for &row in transaction.rows {
                    if row.id!=id {continue}
                    if row.before_present {kept=true} else {added=true}
                }
            }
            if added && !kept {status='A'}
        }
    case: name=filepath.base(task.review.changed_files[index-ids])
    }
    id:=ui.id(ctx,"review_change",index)
    it:=ui.interact(ctx,id)
    walked:=m.review_task==task.id && m.review_at==index
    fill:=th.chip_on if walked || it.hot else ui.Color{}
    actions:=walked || ai_pointer_on(ctx,id)
    if ui.box(ctx,{id=id,width=ui.GROW,height=ui.fixed(AI_CHANGE_ROW),gap=7,align_y=.Center,padding={8,0,3,0},fill=fill,stroke=walked?th.text:{},stroke_width=1.5,radius=th.radius_control}) {
        letter:=[1]u8{status}
        color:=status=='A'?th.success:status=='D'?th.danger:th.text_muted
        if ui.box(ctx,{width=ui.fixed(9),height=ui.FIT}) {ui.label(ctx,string(letter[:]),th.font_small,color,font=ui.FONT_SEMIBOLD)}
        ui.label(ctx,name,th.font_small,th.text_label,0)
        if actions {
            message:string
            resolved:=false
            if ui.button(ctx,ui.id(ctx,"review_change_revert",index),{icon=.Revert,icon_color=th.text_muted,style=.Ghost,width=20,height=20,icon_size=12}).clicked {
                resolved=true
                switch {
                case index<ids:
                    entity:=task.review.changed_ids[index]
                    message=ai_review_entity_revert(s,m,task,entity)
                    if message=="" {ai_review_resolved(s,task,entity,walked)}
                case:          message=ai_review_file_revert(s,m,task,task.review.changed_files[index-ids])
                }
            }
            if !resolved && ui.button(ctx,ui.id(ctx,"review_change_keep",index),{icon=.Check,icon_color=th.accent,style=.Ghost,width=20,height=20,icon_size=12}).clicked {
                resolved=true
                switch {
                case index<ids:
                    entity:=task.review.changed_ids[index]
                    ai_review_entity_accept(s,m,task,entity)
                    ai_review_resolved(s,task,entity,walked)
                case:          ai_review_file_accept(s,m,task,task.review.changed_files[index-ids])
                }
            }
            if resolved {
                if message!="" {notify(s,message)}
                if m.review_at>=ai_review_count(task) {m.review_at=-1}
                return true
            }
        }
    }
    if it.clicked {
        m.review_task,m.review_at=task.id,index-1
        ai_review_walk(s,task)
        if index>=ids {
            file:=task.review.changed_files[index-ids]
            if asset_document_file_opens(s,file) {asset_document_open_file(s,file)}
        }
    }
    return
}

// What each turn waiting for review changed on the entity shown in Details:
// keeping it whole or putting it back is one click, and its fields carry the
// color of their agent until then.
@(private)
ai_review_entity_bar :: proc(s:^Session,w:core.World_Ref,e:core.Entity,width:f32) {
    m:=s.ai
    if m==nil {return}
    id:=api_entity_id(w,e)
    owners:[AI_TASK_CAPACITY]int
    for owner in owners[:ai_review_tasks_of(s,m,w,e,owners[:])] {
        if task:=ai_task_find(m,owner);task!=nil {ai_review_bar(s,task,id,width)}
    }
}

// The bar of one turn over an entity: put back what it did to it, or keep it.
// The walk goes on from the change that was in sight.
@(private)
ai_review_bar :: proc(s:^Session,task:^Ai_Task,id:base.Entity_Id,width:f32) {
    m:=s.ai;ctx:=s.gui.ctx;th:=&ctx.theme
    color:=ai_agent_color(task)
    ui.id_push(ctx,ui.id(ctx,"agent_bar",task.id))
    defer ui.id_pop(ctx)
    ids:=task.review.changed_ids[:]
    walked:=m.review_task==task.id && m.review_at>=0 && m.review_at<len(ids) && ids[m.review_at]==id
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(28),gap=4,align_y=.Center,padding={5,0,4,0},fill=ui.color_alpha(color,22),stroke=ui.color_alpha(color,80),radius=th.radius_popup}) {
        ui.icon(ctx,ai_agent_icon(task),color,18)
        ui.label(ctx,ai_chat_menu_label(ctx,base.text_get(task.title[:]),max(width-116,1)),th.font_small,th.text,0)
        ui.spacer(ctx)
        if ui.button(ctx,ui.id(ctx,"revert_entity"),{icon=.Revert,icon_color=th.text_muted,style=.Ghost,width=24,height=24}).clicked {
            if message:=ai_review_entity_revert(s,m,task,id);message!="" {notify(s,message);return}
            ai_review_resolved(s,task,id,walked)
        }
        if ui.button(ctx,ui.id(ctx,"accept_entity"),{icon=.Check,icon_color=color,style=.Ghost,width=24,height=24,use_appearance=true,appearance={fill=ui.color_alpha(color,32),stroke=ui.color_alpha(color,65),radius=th.radius_control}}).clicked {
            ai_review_entity_accept(s,m,task,id)
            ai_review_resolved(s,task,id,walked)
        }
    }
}

// Brings the next change of a turn into sight: its entity selected for
// Details, the outline of a deletion with Details showing what it was, or
// the row of a file under the review.
@(private)
ai_review_walk :: proc(s:^Session,task:^Ai_Task,step:=1) {
    m:=s.ai
    ids:=task.review.changed_ids[:]
    count:=ai_review_count(task)
    if count==0 {return}
    if m.review_task!=task.id {m.review_task,m.review_at=task.id,-1}
    if m.review_at<0 {m.review_at=step>0?0:count-1} else {m.review_at=(m.review_at+step+count)%count}
    m.review_shown=0
    if m.review_at>=len(ids) {return}
    w:=edited_world(s)
    if e:=history.change_entity(w,ids[m.review_at]);e!=core.NONE {
        history.selection_set(s.selection,{e})
        library_select(s,.Ai)
    } else if place,deleted:=ai_review_deleted_world(w,task,ids[m.review_at],0);deleted {
        history.selection_clear(s.selection)
        m.review_shown,m.review_selection=ids[m.review_at],s.selection.serial
        s.viewport.orbit.target=place.position
        viewport_camera(s.viewport)
    }
}

// After one entity of a turn is kept or put back: a walk that had it in
// sight goes on to the next change, which now takes its place in the list.
// A deletion put back with nothing left to walk is selected, so Details shows it as it is now.
@(private)
ai_review_resolved :: proc(s:^Session,task:^Ai_Task,id:base.Entity_Id,walked:bool) {
    m:=s.ai
    if m.review_shown==id {m.review_shown=0}
    if walked {
        m.review_at-=1
        if ai_task_reviewable(task) && task.review.pending {ai_review_walk(s,task);return}
    }
    if e:=history.change_entity(edited_world(s),id);e!=core.NONE && len(s.selection.entities)==0 {history.selection_set(s.selection,{e})}
}

// The deletion Details shows: the one the walk brought into sight, while the
// selection is as the walk left it.
@(private)
ai_review_shown :: proc(s:^Session) -> (task:^Ai_Task,id:base.Entity_Id,ok:bool) {
    m:=s.ai
    if m==nil || m.review_shown==0 || s.mode!=.Edit || s.selection.serial!=m.review_selection {return}
    task=ai_task_find(m,m.review_task)
    if task==nil || !ai_task_reviewable(task) || !ai_task_current(s,task) || !ai_review_deleted(edited_world(s),task,m.review_shown) {return}
    return task,m.review_shown,true
}

// Details of an entity a turn deleted, as it was before: its name, the bar
// that keeps the deletion or puts it back, and its components, read only.
@(private)
ai_review_deleted_details :: proc(s:^Session,w:core.World_Ref,task:^Ai_Task,id:base.Entity_Id,width,max_height:f32) {
    ctx:=s.gui.ctx;th:=&ctx.theme
    transaction:=ai_review_deletion(w,task,id)
    if transaction==nil {return}
    before:=make([]^history.Change_Row,len(w.info.tables),context.temp_allocator)
    for &row in transaction.rows {
        if row.id==id && row.before_present && !row.after_present && row.table>=0 && row.table<len(before) {before[row.table]=&row}
    }
    if ui.scroll_area(ctx,ui.id(ctx,"inspector_scroll"),&s.inspector.scroll,{height=ui.FIT,max_height=max_height,gap=6}) {
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(30),gap=3,align_y=.Center}) {
            icon,color:=ui.Icon.Group,GROUP_COLOR
            if mesh,shown:=ai_review_deleted_value(w,task,id,erender.Mesh_Renderer);shown {icons:=SHAPE_ICONS;icon,color=mesh.mesh!={}?.Mesh:icons[mesh.shape],MESH_COLOR}
            if ui.box(ctx,{width=ui.fixed(27),height=ui.fixed(27),fill=th.field,radius=th.radius_control,align_x=.Center,align_y=.Center}) {ui.icon(ctx,icon,ui.color_alpha(color,140),18)}
            ui.label(ctx,ai_review_deleted_name(w,task,id),th.font,th.text_muted,0)
            ui.spacer(ctx)
            ui.label(ctx,"Deleted",th.font_small,th.text_faint)
        }
        ai_review_bar(s,task,id,width)
        ui.disabled_begin(ctx)
        defer ui.disabled_end(ctx)
        if local,placed:=ai_review_deleted_value(w,task,id,core.Transform);placed {
            if card(s) {
                if section(s,"Transform",icon=.Move) {
                    card_body(s)
                    place:=core.to_math(local)
                    rows:=[3][3]f32{place.position,mm.quat_to_euler(place.rotation)*mm.DEG_PER_RAD,place.scale}
                    labels:=[3]string{"Position","Rotation","Scale"}
                    decimals:=[3]int{3,1,3}
                    for row,i in rows {
                        if ui.property(ctx,labels[i]) {
                            values:=[3]f64{f64(row.x),f64(row.y),f64(row.z)}
                            ui.vector_field(ctx,ui.id(ctx,"deleted_transform",i+1),values[:],{number={decimals=decimals[i],unit=i==1?"°":""}})
                            ui.spacer(ctx,16,1)
                        }
                    }
                }
            }
        }
        for pass in 0..<2 {
            for &t,index in w.info.tables {
                row:=before[index]
                if row==nil || t.place!=.World || !inspector_visible(s,&t) || inspector_primary(&t)!=(pass==0) {continue}
                value:=history.change_materialize(w,t.info,row.before)
                c:=Inspect{s=s,w=w,t=&t,index=index,table=core.world_table_at(w,&t),name=t.name,type=t.type,value=raw_data(value),size=t.info.size}
                component_section(&c,width)
            }
        }
    }
}

// The height of the choices of a question, laid out in rows as
// ai_chat_question_build lays them.
@(private)
ai_chat_question_height :: proc(ctx:^ui.Context,task:^Ai_Task,width:f32) -> f32 {
    if task==nil || task.question==.None || !ai_task_finished(task) {return 0}
    th:=&ctx.theme
    options:[AI_QUESTION_OPTIONS][]u8
    count:=min(ai_question_options(task,options[:]),len(options))
    rows,used:=0,f32(0)
    place :: proc(rows:^int,used:^f32,width,size:f32) {
        if rows^==0 || used^+size>width {rows^+=1;used^=0}
        used^+=size+5
    }
    switch task.question {
    case .None,.Text:
    case .Confirm:
        for label in ([2]string{"Yes","No"}) {place(&rows,&used,width,ui.text_width(&ctx.font,label,th.font_small)+22)}
    case .Single:
        for index in 0..<count {place(&rows,&used,width,min(ui.text_width(&ctx.font,string(options[index]),th.font_small)+22,width))}
    case .Multi:
        for index in 0..<count {place(&rows,&used,width,min(ui.text_width(&ctx.font,string(options[index]),th.font_small)+34,width))}
        place(&rows,&used,width,ui.text_width(&ctx.font,"Send",th.font_small)+22)
    }
    place(&rows,&used,width,ui.text_width(&ctx.font,"Other...",th.font_small)+22)
    return f32(rows)*26+f32(rows-1)*6
}

// A turn that ended with a question offers its choices under the chat. Any
// kind can also be answered with text: Other moves to the message field.
@(private)
ai_chat_question_build :: proc(s:^Session,task:^Ai_Task,width:f32) {
    if task.question==.None || !ai_task_finished(task) {return}
    m:=s.ai;ctx:=s.gui.ctx;th:=&ctx.theme
    color:=ai_agent_color(task)
    if m.picked_task!=task.id {m.picked_task=task.id;m.picked={}}
    // The answer is the next message of the conversation; the question goes
    // when that turn starts, so a send that cannot happen keeps it.
    answer :: proc(s:^Session,task:^Ai_Task,text:string) {
        m:=s.ai
        if text=="" {return}
        m.prompt_length=copy(m.prompt[:AI_MESSAGE_BYTES-1],text)
        ai_chat_submit(s)
        if m.pending {m.picked={}}
    }
    options:[AI_QUESTION_OPTIONS][]u8
    count:=min(ai_question_options(task,options[:]),len(options))
    ui.id_push(ctx,ui.id(ctx,"question",task.id))
    defer ui.id_pop(ctx)
    used:=f32(0)
    open:=false
    row :: proc(ctx:^ui.Context,open:^bool,used:^f32) {
        if open^ {ui.box_end(ctx,{})}
        ui.box_begin(ctx,{width=ui.GROW,height=ui.fixed(26),gap=5,align_y=.Center})
        open^=true;used^=0
    }
    place :: proc(ctx:^ui.Context,open:^bool,used:^f32,width,size:f32) {
        if !open^ || used^+size>width {row(ctx,open,used)}
        used^+=size+5
    }
    defer if open {ui.box_end(ctx,{})}
    // The text of a choice is part of its look: without it the label does not show.
    appearance:=ui.Node_Style{fill=ui.color_alpha(color,26),stroke=ui.color_alpha(color,80),radius=13,text={size=th.font_small,color=th.text}}
    switch task.question {
    case .None:
    case .Text:
    case .Confirm:
        for label,index in ([2]string{"Yes","No"}) {
            size:=ui.text_width(&ctx.font,label,th.font_small)+22
            place(ctx,&open,&used,width,size)
            if ui.button(ctx,ui.id(ctx,"confirm",index+1),{label=label,width=size,height=ctx.theme.control,size=th.font_small,center=true,use_appearance=true,appearance=appearance}).clicked {answer(s,task,label)}
        }
    case .Single:
        for index in 0..<count {
            label:=string(options[index])
            size:=min(ui.text_width(&ctx.font,label,th.font_small)+22,width)
            place(ctx,&open,&used,width,size)
            if ui.button(ctx,ui.id(ctx,"choice",index+1),{label=ai_chat_menu_label(ctx,label,size-22),width=size,height=ctx.theme.control,size=th.font_small,center=true,use_appearance=true,appearance=appearance}).clicked {answer(s,task,label)}
        }
    case .Multi:
        for index in 0..<count {
            label:=string(options[index])
            size:=min(ui.text_width(&ctx.font,label,th.font_small)+34,width)
            place(ctx,&open,&used,width,size)
            picked:=&m.picked[index]
            style:=appearance
            if !picked^ {style={fill=ui.color_alpha(color,8),stroke=ui.color_alpha(color,40),radius=13,text=appearance.text}}
            if ui.button(ctx,ui.id(ctx,"choice",index+1),{label=ai_chat_menu_label(ctx,label,size-34),icon=picked^?.Checkbox_Checked:.Checkbox,icon_color=color,icon_size=12,width=size,height=ctx.theme.control,size=th.font_small,use_appearance=true,appearance=style}).clicked {picked^=!picked^}
        }
        chosen:[AI_QUESTION_BYTES]u8
        length:=0
        for index in 0..<count {
            if !m.picked[index] {continue}
            if length>0 {length+=copy(chosen[length:],", ")}
            length+=copy(chosen[length:],options[index])
        }
        size:=ui.text_width(&ctx.font,"Send",th.font_small)+22
        place(ctx,&open,&used,width,size)
        if ui.button(ctx,ui.id(ctx,"send_choices"),{label="Send",style=.Accent,width=size,height=ctx.theme.control,size=th.font_small,center=true,disabled=length==0}).clicked {
            answer(s,task,string(chosen[:length]))
        }
    }
    size:=ui.text_width(&ctx.font,"Other...",th.font_small)+22
    place(ctx,&open,&used,width,size)
    if ui.button(ctx,ui.id(ctx,"other"),{label="Other...",style=.Ghost,width=size,height=ctx.theme.control,size=th.font_small,center=true}).clicked {m.focus=true}
}
