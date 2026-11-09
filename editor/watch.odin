package editor

import "core:fmt"
import "core:strings"
import "mirai:std/base"
import "mirai:ui"

// Watching the run of another: the run of an agent, which is already in this
// editor, or the Play of the host of the session, which arrives through the
// session (collab_watch.odin). The viewport shows it without stopping any
// run: the game of the user, if any, goes on unseen and without input, and
// the watched run gets no input of the user and is not edited.

// What the editor watches and what it returns to.
Watch :: struct {
    task:int,   // the AI task whose run is shown; 0: none
    host:bool,  // the Play of the host of the session
    from:Mode,  // the mode it returns to
    orbit:Orbit,
}

// What is watched belongs to another: the editor does not edit it.
watching :: proc "contextless" (s:^Session) -> bool {return s.mode==.Watch}

// The World being watched; nil while the Play of the host has not arrived.
watch_world :: proc(s:^Session) -> rawptr {
    if s.mode!=.Watch {return nil}
    if s.watch.task!=0 {
        if r:=run_find(s,s.watch.task);r!=nil {return r.world}
        return nil
    }
    if s.watch.host {return collab_watch_world(s)}
    return nil
}

// Shows the run of an agent (task) or the Play of the host. From Edit the
// selection of the document is kept for the return; from a game of the user,
// that game goes on, released.
watch_start :: proc(s:^Session,task:int,host:bool) -> bool {
    if task==0 && !host {return false}
    if task!=0 && run_find(s,task)==nil {return false}
    if host && !collab_host_playing(s) {return false}
    if s.mode==.Watch {
        if s.watch.task==task && s.watch.host==host {return true}
        watch_stop(s)
    }
    asset_document_activate(s,-1)
    tools_release(s)
    if s.mode==.Edit {
        edits_commit(s.edits,edited_world(s),s.selection)
        selection_set(&s.edit_selection,s.selection.entities[:])
    }
    if s.mode==.Play {play_release_input(s)}
    if host && !collab_watch_request(s,true) {return false}
    s.watch={task=task,host=host,from=s.mode,orbit=s.viewport.orbit}
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
    if w.host {collab_watch_request(s,false)}
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
    if s.mode!=.Watch {return}
    switch {
    case s.watch.task!=0:
        if run_find(s,s.watch.task)==nil {
            watch_stop(s)
            notify(s,"The agent stopped playing")
        }
    case s.watch.host:
        if !collab_host_playing(s) {
            watch_stop(s)
            notify(s,"The host stopped playing")
        }
    case: watch_stop(s)
    }
}

// Who is watched, for the bar.
watch_name :: proc(s:^Session) -> string {
    if s.watch.task!=0 {
        if s.ai!=nil {
            if task:=ai_task_find(s.ai,s.watch.task);task!=nil {return base.text_get(task.title[:])}
        }
        return "an agent"
    }
    if s.watch.host {return collab_peer_name(s,0)}
    return ""
}

// ---------------------------------------------------------------- the bar

// The round glyph of an agent or an editor in the bar: under the pointer it
// lights up with its color instead of showing the square of a button.
@(private)
presence_glyph :: proc(ctx:^ui.Context,id:ui.Id,color:ui.Color,lit:bool,icon:ui.Icon,initial,tip:string) -> ui.Interaction {
    th:=&ctx.theme
    it:=ui.interact(ctx,id,{.Focusable})
    if it.hot && tip!="" {ui.tooltip(ctx,tip)}
    alpha:=PRESENCE_GLYPH_FILL
    if it.hot {alpha=PRESENCE_GLYPH_HOT}
    if lit {alpha=200}
    stroke:=color
    // Toward white, so the ring brightens.
    if it.hot {for &c,i in stroke[:3] {c=u8(f32(color[i])+(255-f32(color[i]))*0.45)}}
    if ui.box(ctx,{id=id,width=ui.fixed(24),height=ui.fixed(24),align_x=.Center,align_y=.Center,fill=ui.color_alpha(color,alpha),stroke=stroke,stroke_width=1.5,radius=12}) {
        if icon!=.None {ui.icon(ctx,icon,th.text,15)} else {ui.label(ctx,initial,th.font_small,th.text)}
    }
    return it
}

// One avatar per agent at work or standing in the scene and per other editor
// of the session. An agent that plays carries the mark of its run; an editor,
// where it plays: a game of its own, the one it serves on the network or the
// one of the host. A click on an agent opens
// its chat and a right click its menu; a click on an editor opens its menu
// (presence_menu.odin).
watch_bar_build :: proc(s:^Session) {
    g:=s.gui
    ctx:=g.ctx
    th:=&ctx.theme
    if s.ai!=nil {
        for &task in s.ai.tasks[:s.ai.task_count] {
            if !ai_task_current(s,&task) || ai_task_finished(&task) && !ai_scene_task_visible(s,shown_world(s),&task) {continue}
            color:=ai_agent_color(&task)
            run:=run_find(s,task.id)
            watched:=s.mode==.Watch && s.watch.task==task.id
            if ui.box(ctx,{width=ui.FIT,height=ui.fixed(26),gap=1,align_y=.Center}) {
                id:=shell_id(g,"watch_agent",task.id)
                title:=base.text_get(task.title[:])
                open:=ui.popup_is_open(ctx,presence_menu_popup(g)) && g.presence_menu.kind==.Agent && g.presence_menu.task==task.id
                it:=presence_glyph(ctx,id,color,watched || open,ai_agent_icon(&task),"",title)
                if it.clicked {ai_chat_select(s,&task)}
                if it.right {
                    anchor,_:=ui.widget_rect(ctx,id)
                    presence_menu_open(s,{kind=.Agent,task=task.id},anchor)
                }
                if run!=nil {ui.icon(ctx,.Play,color,9)}
            }
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
        watched:=i==0 && s.mode==.Watch && s.watch.host
        open:=ui.popup_is_open(ctx,presence_menu_popup(g)) && g.presence_menu.kind==.Peer && g.presence_menu.peer==i
        if ui.box(ctx,{width=ui.FIT,height=ui.fixed(26),gap=1,align_y=.Center}) {
            if presence_glyph(ctx,id,color,watched || open,.None,initial,name).clicked {
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
