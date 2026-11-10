package editor

import "core:fmt"
import "core:math"
import "core:strings"
import "mirai:editor/ai_store"
import "mirai:std/base"
import "mirai:ui"

// What the main chat shows of its agents: the card each one leaves in the
// thread when it ends a turn, the unit the next message is about, the search
// of the chat and the chat expanded with its column of agents.

AI_REPORT_CACHE :: 16
AI_REPORT_BYTES :: 4096
AI_REPORT_PAD_X :: f32(10)
AI_REPORT_PAD_Y :: f32(9)
AI_REPORT_GAP :: f32(5)
AI_REPORT_HEAD :: f32(18)
AI_REPORT_ROW :: f32(26)
AI_DIVIDER_HEIGHT :: f32(16)
AI_CHAT_HITS :: 24
AI_HIT_LINES :: 12 // lines of the chat around a hit that the thread no longer holds
AI_HIT_BYTES :: 8192
AI_INSPECT_BACK :: f32(30)
AI_INSPECT_TITLE :: f32(22)
AI_INSPECT_HEAD :: AI_INSPECT_BACK+6+AI_INSPECT_TITLE
AI_EXPANDED_CHAT :: f32(720)
AI_EXPANDED_SIDE :: f32(320)
AI_DASH :: f32(4)
AI_DASH_GAP :: f32(3)

// The answer of a subagent that is no longer in tasks, read once from its conversation.
Ai_Report_Text :: struct {
    id:int,
    length:int,
    text:[AI_REPORT_BYTES]u8,
}

Ai_Chat_Hit :: struct {
    sequence:u64,
    snippet:[ai_store.LAST_BYTES]u8,
    length:int,
}

// The messages around a hit older than what the thread holds.
Ai_Hit_View :: struct {
    open:bool,
    text:[AI_HIT_BYTES]u8,
    length:int,
    scroll:f32,
}

// The last answer of a subagent; empty while it works.
ai_report_answer :: proc(m:^Ai,id:int) -> string {
    if task:=ai_task_find(m,id);task!=nil {return ai_task_answer(task)}
    for &entry in m.reports {if entry.id==id {return string(entry.text[:entry.length])}}
    if m.store.db==nil {return ""}
    lines:[AI_HIT_LINES*4]ai_store.Stored_Line
    count,message:=ai_store.page(&m.store,u64(id),-1,lines[:])
    if message!="" {return ""}
    last:=count-1
    for last>=0 && (lines[last].kind!=.Output || strings.trim_space(lines[last].text)=="") {
        if lines[last].kind==.Prompt {last=-1;break}
        last-=1
    }
    b:=strings.builder_make(context.temp_allocator)
    if last>=0 {
        first:=last
        for first>0 && lines[first-1].kind==.Output {first-=1}
        for &line,at in lines[first:last+1] {
            if at>0 {strings.write_byte(&b,'\n')}
            strings.write_string(&b,line.text)
        }
    }
    entry:=&m.reports[m.report_next]
    m.report_next=(m.report_next+1)%len(m.reports)
    entry.id=id
    entry.length=copy(entry.text[:],ai_utf8_cut(strings.to_string(b),AI_REPORT_BYTES))
    return string(entry.text[:entry.length])
}

// Marks the reports of a thread that draw a card: the last one of each
// subagent. The ones before it say that a turn ended and nothing else.
@(private)
ai_reports_live :: proc(t:^Ai_Transcript,live:[]bool) {
    seen:[AI_TASK_CAPACITY]string
    count:=0
    #reverse for &is_live,index in live {
        text,kind:=ai_transcript_line(t,index)
        if kind!=.Report {continue}
        known:=false
        for other in seen[:count] {if other==text {known=true;break}}
        if known {continue}
        is_live=true
        if count<len(seen) {seen[count]=text;count+=1}
    }
}

// The changes a card can still review.
@(private)
ai_report_changes :: proc(task:^Ai_Task) -> int {
    return task!=nil && ai_task_reviewable(task)?ai_review_count(task):0
}

@(private)
ai_report_height :: proc(s:^Session,text:string,width,size:f32) -> f32 {
    m:=s.ai;ctx:=s.gui.ctx
    id:=ai_report_id(text)
    height:=2*AI_REPORT_PAD_Y+AI_REPORT_HEAD+AI_REPORT_GAP+AI_REPORT_ROW
    if answer:=ai_report_answer(m,id);answer!="" {height+=AI_REPORT_GAP+ui.markdown_height(ctx,answer,width-2*AI_REPORT_PAD_X,ai_markdown_style(s,size))}
    if count:=ai_report_changes(ai_task_find(m,id));count>0 && m.report_open==id {
        visible:=min(count,AI_CHANGE_ROWS)
        height+=AI_REPORT_GAP+f32(visible)*AI_CHANGE_ROW+f32(visible-1)
    }
    return height
}

// Opens the view of a unit, which may no longer be in memory.
@(private)
ai_unit_open :: proc(s:^Session,id:int) {
    m:=s.ai
    if task:=ai_task_find(m,id);task!=nil {ai_chat_select(s,task);return}
    if saved:=ai_store.find(&m.store,u64(id));saved!=nil {
        conversation:=saved^
        ai_history_select(s,&conversation)
    }
}

// Puts back all that a unit changed, and says what could not be.
@(private)
ai_review_revert_all :: proc(s:^Session,task:^Ai_Task) {
    if message:=ai_task_revert(s,s.ai,task);message!="" {notify(s,message)}
    else if task.review.skipped>0 {notify(s,fmt.tprintf("%d newer edits were kept",task.review.skipped))}
}

// Revert and accept of a unit whose scope is open, as two icons.
@(private)
ai_review_buttons :: proc(s:^Session,task:^Ai_Task) -> (acted:bool) {
    ctx:=s.gui.ctx;th:=&ctx.theme
    if ui.button(ctx,ui.id(ctx,"revert"),{icon=.Revert,icon_color=th.text_muted,icon_size=14,style=.Ghost,width=24,height=24,disabled=task.files_changed || !ai_review_revertible(s,&task.review)}).clicked {
        ai_review_revert_all(s,task)
        return true
    }
    if ui.button(ctx,ui.id(ctx,"finish"),{icon=.Check,icon_size=13,style=.Accent,width=24,height=24}).clicked {
        ai_task_finish(s,s.ai,task)
        return true
    }
    return false
}

// What a subagent left in the thread: its title, its answer as answers are
// drawn, its changes to unfold, keep or put back, and what to say about it.
@(private)
ai_report_build :: proc(s:^Session,text:string,width,size:f32) {
    m:=s.ai;ctx:=s.gui.ctx;th:=&ctx.theme
    id:=ai_report_id(text)
    task:=ai_task_find(m,id)
    color:=task!=nil?ai_agent_color(task):agent_color(int((id-1)%%len(AGENT_COLORS)))
    count:=ai_report_changes(task)
    inner:=width-2*AI_REPORT_PAD_X
    ui.id_push(ctx,ui.id(ctx,"report",id))
    defer ui.id_pop(ctx)
    if ui.box(ctx,{width=ui.GROW,height=ui.GROW,direction=.Column,gap=AI_REPORT_GAP,padding={AI_REPORT_PAD_X,AI_REPORT_PAD_Y,AI_REPORT_PAD_X,AI_REPORT_PAD_Y},fill=th.card,stroke=th.border,stroke_width=1,radius=th.radius_popup}) {
        head:=ui.id(ctx,"head")
        it:=ui.interact(ctx,head)
        if it.clicked {ai_unit_open(s,id)}
        if ui.box(ctx,{id=head,width=ui.GROW,height=ui.fixed(AI_REPORT_HEAD),gap=7,align_y=.Center}) {
            if ui.box(ctx,{width=ui.fixed(18),height=ui.fixed(18),align_x=.Center,align_y=.Center,fill=ui.color_alpha(color,46),stroke=color,stroke_width=1,radius=9}) {pulse_dot(ctx,color,false,6)}
            ui.label(ctx,ai_chat_menu_label(ctx,ai_report_label(m,text),max(inner-25,1),size),size,th.text,0,font=ui.FONT_MEDIUM)
        }
        if answer:=ai_report_answer(m,id);answer!="" {
            if target:=ui.markdown(ctx,ui.id(ctx,"answer"),answer,inner,ai_markdown_style(s,size));target!="" {ai_markdown_follow(s,target)}
        }
        acted:=false
        open:=count>0 && m.report_open==id
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(AI_REPORT_ROW),gap=4,align_y=.Center}) {
            if count>0 {
                fold:=ui.id(ctx,"changes")
                fold_it:=ui.interact(ctx,fold)
                if ui.box(ctx,{id=fold,width=ui.FIT,height=ui.fixed(24),gap=4,padding={0,0,6,0},align_y=.Center}) {
                    ui.icon(ctx,open?.Chevron_Down:.Chevron_Right,th.text,10)
                    ui.label(ctx,count==1?"1 change":fmt.tprintf("%d changes",count),th.font_small,th.text,font=ui.FONT_MEDIUM)
                }
                if fold_it.clicked {
                    m.report_open=open?0:id
                    m.report_scroll={}
                }
            }
            ui.spacer(ctx)
            if ui.button(ctx,ui.id(ctx,"reply"),{label="Reply",style=.Ghost,height=24,size=th.font_small,padding=6}).clicked {ai_about_set(s,id)}
            if count>0 {acted=ai_review_buttons(s,task)}
        }
        if open && !acted {
            visible:=min(count,AI_CHANGE_ROWS)
            if ui.scroll_area(ctx,ui.id(ctx,"changes_list"),&m.report_scroll,{width=ui.GROW,height=ui.fixed(f32(visible)*AI_CHANGE_ROW+f32(visible-1)),gap=1}) {
                for i in 0..<count {
                    if ai_review_change_row(s,task,i) {break}
                }
            }
        }
    }
}

// Attaches a unit to the next message of the main chat.
ai_about_set :: proc(s:^Session,id:int) {
    m:=s.ai
    m.about,m.focus=id,true
}

// What the agent is told about the unit a message answers.
ai_about_note :: proc(m:^Ai,id:int) -> string {
    return fmt.tprintf("This message replies to the work of subagent %d, %q: agent.message gives it a correction, agent.list shows it and ai.history reads its conversation.",id,ai_unit_title(m,id))
}

@(private)
ai_about_rows :: proc(m:^Ai) -> int {return m!=nil && m.about!=0?1:0}

// The unit the next message is about, as a chip; taking it out detaches it.
@(private)
ai_about_build :: proc(s:^Session,width:f32,rows:int) {
    m:=s.ai
    if rows<=0 || ai_about_rows(m)==0 {return}
    ctx:=s.gui.ctx;th:=&ctx.theme
    title:=ai_unit_title(m,m.about)
    label:=title
    size:=ai_chip_width(ctx,label,width)
    color:=th.text_muted
    if task:=ai_task_find(m,m.about);task!=nil {color=ai_agent_color(task)}
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(AI_CHIP_HEIGHT),gap=5,align_y=.Center}) {
        if ui.box(ctx,{width=ui.fixed(size),height=ui.fixed(AI_CHIP_HEIGHT),padding={5,0,5,0},gap=4,align_y=.Center,fill=th.field,radius=th.radius_control}) {
            pulse_dot(ctx,color,false)
            ui.label(ctx,ai_chat_menu_label(ctx,label,max(size-AI_CHIP_ROOM-AI_CHIP_PIN_ROOM+4,1),th.font_small),th.font_small,th.text_muted,size-40-AI_CHIP_PIN_ROOM)
            ai_chip_pin(s,ui.id(ctx,"pin_about"),AI_PIN_AGENT,fmt.tprintf("%d",m.about),title)
            if ui.button(ctx,ui.id(ctx,"remove_about"),{icon=.Cross,icon_color=th.text_muted,icon_size=10,padding=-1,style=.Ghost,width=12,height=12}).clicked {m.about=0}
        }
    }
}

// The first line of the user that has not reached its agent, or -1.
@(private)
ai_held_first :: proc(task:^Ai_Task) -> int {
    t:=&task.transcript
    lines:=ai_task_held(task)>0?task.held_lines:0
    first:=-1
    for index:=t.count-1;index>=0 && lines>0;index-=1 {
        if t.lines[index].kind!=.Prompt {continue}
        first=index
        lines-=1
    }
    return first
}

// The outline of a message that waits: dashes along its sides and its corners round.
@(private)
ai_dashed_box_draw :: proc(ctx:^ui.Context,rect:ui.Rect,color:ui.Color) {
    run :: proc(ctx:^ui.Context,from,to:[2]f32,color:ui.Color) {
        length:=max(abs(to.x-from.x),abs(to.y-from.y))
        if length<=0 {return}
        direction:=(to-from)/length
        for at:=f32(0);at<length;at+=AI_DASH+AI_DASH_GAP {
            ui.draw_line(ctx,from+direction*at,from+direction*min(at+AI_DASH,length),1,color)
        }
    }
    r:=ctx.theme.radius_popup
    x0,y0,x1,y1:=rect.x+.5,rect.y+.5,rect.x+rect.w-.5,rect.y+rect.h-.5
    run(ctx,{x0+r,y0},{x1-r,y0},color)
    run(ctx,{x0+r,y1},{x1-r,y1},color)
    run(ctx,{x0,y0+r},{x0,y1-r},color)
    run(ctx,{x1,y0+r},{x1,y1-r},color)
    corners:=[4][3]f32{{x0+r,y0+r,math.PI},{x1-r,y0+r,math.PI*1.5},{x1-r,y1-r,0},{x0+r,y1-r,math.PI*.5}}
    for corner in corners {
        arc:[5][2]f32
        for &point,i in arc {
            angle:=corner[2]+f32(i)*math.PI/8
            point={corner[0]+math.cos(angle)*r,corner[1]+math.sin(angle)*r}
        }
        ui.draw_polyline(ctx,arc[:],1,color)
    }
}

// What the search of the clock finds in the main chat, as text for its rows.
@(private)
ai_chat_hits_refresh :: proc(s:^Session,needle:string) {
    m:=s.ai
    m.chat_hit_count=0
    if needle=="" || m.main==0 || m.store.db==nil || ai_store.index_match(needle,true)=="" {return}
    hits:[AI_CHAT_HITS]ai_store.Search_Hit
    count,message:=ai_store.search(&m.store,needle,hits[:],u64(m.main),true)
    if message!="" {notify(s,message);return}
    plain:[ai_store.LAST_BYTES*2]u8
    for &hit in hits[:count] {
        if hit.kind!=.Prompt && hit.kind!=.Output {continue}
        entry:=&m.chat_hits[m.chat_hit_count]
        entry.sequence=hit.sequence
        entry.length=copy(entry.snippet[:],ai_utf8_cut(ai_entity_marks_plain(hit.snippet,plain[:]),ai_store.LAST_BYTES))
        m.chat_hit_count+=1
    }
}

// Goes to a line of the main chat: the thread brings it into sight while it
// holds it; an older one opens with the messages around it.
@(private)
ai_chat_hit_open :: proc(s:^Session,sequence:u64) {
    m:=s.ai
    main:=ai_task_find(m,m.main)
    if main==nil {return}
    if m.selected!=m.main {ai_chat_select(s,main)}
    t:=&main.transcript
    if int(sequence)>=t.dropped && int(sequence)<t.dropped+t.count {
        m.scroll_to=int(sequence)+1
        return
    }
    lines:[AI_HIT_LINES]ai_store.Stored_Line
    count,message:=ai_store.page(&m.store,u64(m.main),i64(sequence)+AI_HIT_LINES/2,lines[:])
    if message!="" {notify(s,message);return}
    view:=&m.hit_view
    used:=0
    for &line,index in lines[:count] {
        if line.kind!=.Prompt && line.kind!=.Output {continue}
        if index>0 {used+=copy(view.text[used:],"\n\n")}
        if line.kind==.Prompt {used+=copy(view.text[used:],"> ")}
        used+=copy(view.text[used:],line.text)
    }
    view.length=len(ai_utf8_cut(string(view.text[:used]),used))
    view.open,view.scroll=true,0
}

// An old part of the chat, read only.
@(private)
ai_hit_view_build :: proc(s:^Session) {
    m:=s.ai;ctx:=s.gui.ctx
    view:=&m.hit_view
    if !view.open {return}
    if ui.escape(ctx) {view.open=false;return}
    closed:=false
    defer if closed {view.open=false}
    width:=f32(560)
    if ui.modal(ctx,shell_id(s.gui,"ai_hit_view"),{width=width,scroll=&view.scroll,close=&closed}) {
        if target:=ui.markdown(ctx,ui.id(ctx,"ai_hit_text"),string(view.text[:view.length]),width-36,ai_markdown_style(s,ctx.theme.font_small));target!="" {ai_markdown_follow(s,target)}
    }
}

// The way back to the main chat and what is being looked at instead: its
// model and effort, its title and its state, which opens its details.
@(private)
ai_chat_inspect_build :: proc(s:^Session,task:^Ai_Task,width:f32) {
    m:=s.ai;ctx:=s.gui.ctx;th:=&ctx.theme
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(AI_INSPECT_BACK),gap=6,align_y=.Center}) {
        back:=ui.id(ctx,"back_main")
        it:=ui.interact(ctx,back)
        if ui.box(ctx,{id=back,width=ui.FIT,height=ui.fixed(AI_INSPECT_BACK),gap=6,padding={6,0,6,0},align_y=.Center,fill=it.hot?ui.color_hover(th):{},radius=th.radius_control}) {
            ui.icon(ctx,ui.icon_user(u8(User_Icon.Back)),th.text_muted,12)
            ui.label(ctx,"Main chat",th.font_small,th.text_muted)
        }
        if it.clicked {
            if main:=ai_task_find(m,m.main);main!=nil {ai_chat_select(s,main)} else {m.selected=0}
            return
        }
        ui.spacer(ctx)
        if text:=ai_task_model_text(m,task);text!="" {ui.label(ctx,text,th.font_caption,th.text_faint)}
    }
    state:=ai_task_state_text(m,task)
    details:=ui.id(ctx,"state")
    it:=ui.interact(ctx,details)
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(AI_INSPECT_TITLE),gap=8,padding={6,0,6,0},align_y=.Center}) {
        pulse_dot(ctx,ai_agent_color(task),!ai_task_finished(task),9)
        room:=max(width-12-9-16-ui.text_width(&ctx.font,state,th.font_caption)-12,1)
        ui.label(ctx,ai_chat_menu_label(ctx,ai_chat_title(base.text_get(task.title[:])),room,th.font_heading),th.font_heading,th.text,0,font=ui.FONT_SEMIBOLD)
        if ui.box(ctx,{id=details,width=ui.FIT,height=ui.fixed(18),padding={4,0,4,0},align_y=.Center,fill=it.hot?ui.color_hover(th):{},radius=th.radius_control}) {
            ui.label(ctx,state,th.font_caption,th.text_muted)
        }
    }
    if it.clicked {m.details=m.details==task.id?0:task.id}
}

// The model and the effort of an agent, as the back row shows them.
@(private)
ai_task_model_text :: proc(m:^Ai,task:^Ai_Task) -> string {
    c:=&task.conversation
    name:=string(c.model[:c.model_len])
    if provider,known:=ai_provider_find(m,base.text_get(task.agent[:]));known {name=ai_model_name(m,provider,name)}
    else if name=="" {return ""}
    effort:=ai_effort_name(string(c.effort[:c.effort_len]))
    return effort!=""?fmt.tprintf("%s · %s",name,effort):name
}

// The state of a unit, in a word.
@(private)
ai_task_state_text :: proc(m:^Ai,task:^Ai_Task) -> string {
    if ai_permission_of(m,task)>=0 || task.question!=.None {return "Waiting"}
    switch task.state {
    case .Queued:      return "Queued"
    case .Running:     return "Working"
    case .Done:        return "Finished"
    case .Failed:      return "Failed"
    case .Cancelled:   return "Stopped"
    case .Interrupted: return "Interrupted"
    }
    return ""
}

// The chat over the whole area below the bars, in a column in the middle, and
// at its right what works and what waits for review.
@(private)
ai_chat_expanded_build :: proc(s:^Session,width,height:f32) {
    ctx:=s.gui.ctx;th:=&ctx.theme
    if ui.box(ctx,{width=ui.GROW,height=ui.GROW}) {
        if ui.box(ctx,{width=ui.GROW,height=ui.GROW,direction=.Column,align_x=.Center,gap=8,padding=ui.padding_all(8)}) {
            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(PANEL_HEADER),gap=2,align_x=.End,align_y=.Center}) {
                ai_chat_bar_buttons(s)
                ai_chat_settings_button(s)
            }
            room:=height-2*8-PANEL_HEADER-8
            ai_chat_content_build(s,min(AI_EXPANDED_CHAT,width-AI_EXPANDED_SIDE-1-2*8),room,th.font)
        }
        if ui.box(ctx,{width=ui.fixed(1),height=ui.GROW,fill=th.divider}) {}
        ai_chat_side_build(s,height)
    }
}

// The column of the expanded chat: the units that work, which a click
// inspects, and those that wait for review, kept or put back from here.
@(private)
ai_chat_side_build :: proc(s:^Session,height:f32) {
    m:=s.ai;ctx:=s.gui.ctx;th:=&ctx.theme
    working,changes,_:=ai_units_count(s)
    title :: proc(ctx:^ui.Context,text:string) {
        th:=&ctx.theme
        if ui.box(ctx,{width=ui.GROW,height=ui.FIT,padding={0,0,0,4}}) {ui.label(ctx,text,th.font_caption,th.text_muted,font=ui.FONT_MEDIUM)}
    }
    if ui.scroll_area(ctx,ui.id(ctx,"ai_side"),&m.list_scroll,{width=ui.fixed(AI_EXPANDED_SIDE),height=ui.fixed(height),direction=.Column,padding={14,40,14,14},gap=18}) {
        if working>0 {
            if ui.box(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column,gap=4}) {
                title(ctx,"Working")
                for &task in m.tasks[:m.task_count] {
                    if !ai_session_row_shown(s,&task) || ai_task_finished(&task) {continue}
                    row:=ui.id(ctx,"side_working",task.id)
                    it:=ui.interact(ctx,row)
                    if it.clicked {ai_chat_select(s,&task)}
                    if ui.box(ctx,{id=row,width=ui.GROW,height=ui.fixed(30),gap=8,padding={6,0,6,0},align_y=.Center,fill=it.hot?ui.color_hover(th):{},radius=th.radius_control}) {
                        pulse_dot(ctx,ai_agent_color(&task),true,9)
                        ui.label(ctx,ai_chat_title(base.text_get(task.title[:])),th.font_small,th.text,0)
                        ui.label(ctx,ai_elapsed(ai_task_seconds(&task)),th.font_caption,th.text_muted)
                    }
                }
            }
        }
        if working>0 && changes>0 {
            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(1),fill=th.divider}) {}
        }
        if changes>0 {
            if ui.box(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column,gap=6}) {
                title(ctx,"To review")
                for &task in m.tasks[:m.task_count] {
                    count:=ai_report_changes(&task)
                    if !ai_session_row_shown(s,&task) || count==0 {continue}
                    ui.id_push(ctx,ui.id(ctx,"side_review",task.id))
                    defer ui.id_pop(ctx)
                    if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=6,padding={10,6,6,6},align_y=.Center,fill=th.card,radius=th.radius_popup}) {
                        pulse_dot(ctx,ai_agent_color(&task),false,9)
                        if ui.box(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column}) {
                            ui.label(ctx,ai_chat_title(base.text_get(task.title[:])),th.font_small,th.text,0)
                            ui.label(ctx,count==1?"1 change":fmt.tprintf("%d changes",count),th.font_small,th.text_muted)
                        }
                        ai_review_buttons(s,&task)
                    }
                }
            }
        }
    }
}
