package editor

import "core:fmt"
import "core:strings"
import "mirai:std/base"
import "mirai:ui"

// Watching the run of an agent, which is already in this editor. The viewport
// shows it without stopping any run: the game of the user, if any, goes on
// unseen and without input, and the watched run gets no input of the user and
// is not edited.

// What the editor watches and what it returns to.
Watch :: struct {
    task:int,   // the AI task whose run is shown; 0: none
    from:Mode,  // the mode it returns to
    orbit:Orbit,
}

// What is watched belongs to another: the editor does not edit it.
watching :: proc "contextless" (s:^Session) -> bool {return s.mode==.Watch}

// The World being watched; nil once its run ended.
watch_world :: proc(s:^Session) -> rawptr {
    if s.mode!=.Watch {return nil}
    if r:=run_find(s,s.watch.task);r!=nil && s.watch.task!=0 {return r.world}
    return nil
}

// Shows the run of an agent (task). From Edit the selection of the document
// is kept for the return; from a game of the user, that game goes on,
// released.
watch_start :: proc(s:^Session,task:int) -> bool {
    if task==0 || run_find(s,task)==nil {return false}
    if s.mode==.Watch {
        if s.watch.task==task {return true}
        watch_stop(s)
    }
    asset_document_activate(s,-1)
    tools_release(s)
    if s.mode==.Edit {
        edits_commit(s.edits,edited_world(s),s.selection)
        selection_set(&s.edit_selection,s.selection.entities[:])
    }
    if s.mode==.Play {play_release_input(s)}
    s.watch={task=task,from=s.mode,orbit=s.viewport.orbit}
    selection_clear(s.selection)
    if s.gui.ctx!=nil {s.gui.ctx.edit={};ui.popup_close(s.gui.ctx)}
    s.mode=.Watch
    s.view_cut=true
    return true
}

// Back to what the editor showed before. When the game of the user ended
// meanwhile, back to Edit.
watch_stop :: proc(s:^Session) {
    if s.mode!=.Watch {return}
    w:=s.watch
    tools_release(s)
    selection_clear(s.selection)
    s.watch={}
    s.mode=w.from
    s.viewport.orbit=w.orbit
    viewport_camera(s.viewport)
    s.view_cut=true
    if w.from==.Edit {
        selection_set(s.selection,s.edit_selection.entities[:])
        selection_clear(&s.edit_selection)
        selection_prune(s.selection,edited_world(s))
    } else if run_find(s,0)==nil {
        play_view_restore(s)
    }
}

// Between frames: what is watched may have ended.
watch_update :: proc(s:^Session) {
    if s.mode!=.Watch || run_find(s,s.watch.task)!=nil && s.watch.task!=0 {return}
    watch_stop(s)
    notify(s,"The agent stopped playing")
}

// Who is watched, for the bar.
watch_name :: proc(s:^Session) -> string {
    if s.watch.task==0 {return ""}
    if s.ai!=nil {
        if task:=ai_task_find(s.ai,s.watch.task);task!=nil {return base.text_get(task.title[:])}
    }
    return "an agent"
}

// ---------------------------------------------------------------- the bar

// The round glyph of an agent or an editor in the bar: under the pointer it
// lights up with its color instead of showing the square of a button.
@(private)
presence_glyph :: proc(ctx:^ui.Context,id:ui.Id,color:ui.Color,lit:bool,icon:ui.Icon,initial,tip:string,ring:f32=1.5,working:=false) -> ui.Interaction {
    th:=&ctx.theme
    it:=ui.interact(ctx,id,{.Focusable})
    if it.hot && tip!="" {ui.tooltip(ctx,tip)}
    alpha:=PRESENCE_GLYPH_FILL
    if it.hot {alpha=PRESENCE_GLYPH_HOT}
    if lit {alpha=200}
    stroke:=color
    // Toward white, so the ring brightens.
    if it.hot {for &c,i in stroke[:3] {c=u8(f32(color[i])+(255-f32(color[i]))*0.45)}}
    if ui.box(ctx,{id=id,width=ui.fixed(24),height=ui.fixed(24),align_x=.Center,align_y=.Center,fill=ui.color_alpha(color,alpha),stroke=stroke,stroke_width=ring,radius=12}) {
        switch {
        case icon!=.None:  ui.icon(ctx,icon,th.text,ring>1.5?13:15)
        case initial!="":  ui.label(ctx,initial,th.font_small,th.text)
        case:              pulse_dot(ctx,color,working)
        }
    }
    return it
}

// Whether an agent has its avatar in the bar: a subagent while it works, waits
// for an answer or has changes to review; another agent while it works or
// stands in the scene.
@(private)
ai_task_on_bar :: proc(s:^Session,task:^Ai_Task) -> bool {
    if !ai_task_current(s,task) {return false}
    if !ai_task_finished(task) {return true}
    if !ai_task_subagent(task) {return ai_scene_task_visible(s,shown_world(s),task)}
    return task.question!=.None || ai_permission_of(s.ai,task)>=0 || ai_task_reviewable(task) && ai_review_count(task)>0
}

// The main agent first, once it exists, then one avatar per agent ai_task_on_bar
// keeps and per other editor of the session. An agent that plays carries the
// mark of its run; an editor, where it plays: a game of its own, the one it
// serves on the network or the one of the host. A click on an agent opens its
// chat and a right click its menu; a click on an editor opens its menu
// (presence_menu.odin).
watch_bar_build :: proc(s:^Session) {
    g:=s.gui
    ctx:=g.ctx
    th:=&ctx.theme
    if s.ai!=nil {
        m:=s.ai
        agent :: proc(s:^Session,g:^Editor_Ui,task:^Ai_Task) {
            ctx:=g.ctx
            th:=&ctx.theme
            m:=s.ai
            main:=task.id==m.main
            subagent:=ai_task_subagent(task)
            color:=main?th.accent:ai_agent_color(task)
            watched:=s.mode==.Watch && s.watch.task==task.id
            if ui.box(ctx,{width=ui.FIT,height=ui.fixed(26),gap=1,align_y=.Center}) {
                id:=shell_id(g,"watch_agent",task.id)
                title:=base.text_get(task.title[:])
                open:=ui.popup_is_open(ctx,presence_menu_popup(g)) && g.presence_menu.kind==.Agent && g.presence_menu.task==task.id
                it:ui.Interaction
                working:=!ai_task_finished(task)
                switch {
                case main:     it=presence_glyph(ctx,id,color,watched || open,ui.icon_user(u8(User_Icon.Mirai_Shape)),"",title,2)
                case subagent: it=presence_glyph(ctx,id,color,watched || open,.None,"",title,2,working)
                case:          it=presence_glyph(ctx,id,color,watched || open,ai_agent_icon(task),"",title)
                }
                if it.clicked {ai_chat_select(s,task)}
                if it.right {
                    anchor,_:=ui.widget_rect(ctx,id)
                    presence_menu_open(s,{kind=.Agent,task=task.id},anchor)
                }
                if main && working {
                    if ui.box(ctx,{width=ui.fixed(7),height=ui.fixed(7),float={to=.Parent,anchor=.Bottom_Right,pivot=.Bottom_Right}}) {pulse_dot(ctx,color,true)}
                }
                if subagent {
                    buffer:[16]u8
                    if badge:=ai_session_badge(m,task,buffer[:]);badge!="" {
                        if ui.box(ctx,{width=ui.FIT,height=ui.FIT,float={to=.Parent,anchor=.Top_Right,pivot=.Top_Right,offset={6,-5}}}) {ai_session_badge_build(ctx,badge,color)}
                    }
                }
                if run_find(s,task.id)!=nil {ui.icon(ctx,.Play,color,9)}
            }
        }
        if main:=ai_task_find(m,m.main);main!=nil {agent(s,g,main)}
        for &task in m.tasks[:m.task_count] {
            if task.id!=m.main && ai_task_on_bar(s,&task) {agent(s,g,&task)}
        }
    }
    st:=collab_state(s)
    if st==nil || st.phase!=.Joined {return}
    for &peer,i in st.peers {
        if i==int(st.self) || !peer.used || i!=0 && !peer.joined {continue}
        color:=collab_color(i)
        name:=string(peer.name[:peer.name_length])
        initial:=strings.to_upper(name[:min(len(name),1)] if name!="" else "?",context.temp_allocator)
        id:=shell_id(g,"watch_peer",i)
        open:=ui.popup_is_open(ctx,presence_menu_popup(g)) && g.presence_menu.kind==.Peer && g.presence_menu.peer==i
        if ui.box(ctx,{width=ui.FIT,height=ui.fixed(26),gap=1,align_y=.Center}) {
            if presence_glyph(ctx,id,color,open,.None,initial,name).clicked {
                anchor,_:=ui.widget_rect(ctx,id)
                presence_menu_open(s,{kind=.Peer,peer=i},anchor)
            }
            // Where it plays: the game it serves, the one of the host (in its color) or one of its own.
            if peer.serving {ui.icon(ctx,ui.icon_user(u8(User_Icon.Connection)),color,10)}
            else if peer.in_game {ui.icon(ctx,ui.icon_user(u8(User_Icon.Connection)),collab_color(0),10)}
            else if peer.playing {ui.icon(ctx,.Play,color,9)}
        }
    }
}
