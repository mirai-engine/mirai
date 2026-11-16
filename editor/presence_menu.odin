package editor

import "core:fmt"
import "core:math"
import "mirai:core"
import wire "mirai:net"
import "mirai:std/base"
import "mirai:ui"

// The menu of the glyph of a figure, in the scene or in the bar: go to it,
// follow the camera of another editor, watch the run or open the chat of an
// agent of this end, and what the plugin that plays offers of the game the
// host serves.

Presence_Menu_Kind :: enum u8 {None,Agent,Peer,Remote_Agent}

Presence_Menu :: struct {
    kind:Presence_Menu_Kind,
    task:int,  // Agent: its id
    peer:int,  // Peer and Remote_Agent: the place of the editor in the session
    agent:int, // Remote_Agent: among those of its editor
}

PRESENCE_GO_TO_DISTANCE :: f32(2.4)
PRESENCE_GO_TO_PITCH :: f32(0.25)

@(private)
presence_menu_popup :: proc(g:^Editor_Ui) -> ui.Id {return shell_id(g,"presence_menu")}

presence_menu_open :: proc(s:^Session,menu:Presence_Menu,anchor:ui.Rect) {
    g:=s.gui
    g.presence_menu=menu
    ui.popup_open(g.ctx,presence_menu_popup(g),anchor)
}

// The camera of the editor in front of a figure, looking at its face. facing:
// the turn of the figure about +Y from -Z.
presence_go_to :: proc(s:^Session,eyes:[3]f32,facing:f32) {
    if s.mode==.Watch {watch_stop(s)}
    v:=s.viewport
    v.follow=0
    v.orbit.target=eyes
    v.orbit.yaw=facing+math.PI
    v.orbit.pitch=PRESENCE_GO_TO_PITCH
    v.orbit.distance=PRESENCE_GO_TO_DISTANCE
    orbit_sanitize(&v.orbit)
    viewport_camera(v)
}

// A click on a glyph in the scene: that of an agent opens its chat, that of
// an editor its menu.
presence_hit :: proc(s:^Session,w:core.World_Ref) -> bool {
    g:=s.gui
    if g.ctx.popup.count>0 || g.modal!=.None {return false}
    point:=s.viewport.pointer
    for &task in ai_tasks(s.ai) {
        if !ai_scene_figure_shown(s,w,&task) {continue}
        glyph,on_glyph:=ai_scene_screen(s,w,&task)
        body,on_body:=ai_scene_body_screen(s,w,&task)
        if on_glyph && ui.rect_contains(glyph,point) || on_body && ui.rect_contains(body,point) {
            ai_chat_select(s,&task)
            return true
        }
    }
    if peer,rect,found:=collab_peer_at(s,point);found {
        presence_menu_open(s,{kind=.Peer,peer=peer},rect)
        return true
    }
    if peer,agent,rect,found:=collab_agent_at(s,point);found {
        presence_menu_open(s,{kind=.Remote_Agent,peer=peer,agent=agent},rect)
        return true
    }
    return false
}

presence_menu_build :: proc(s:^Session) {
    g:=s.gui
    ctx:=g.ctx
    popup:=presence_menu_popup(g)
    if !ui.popup_is_open(ctx,popup) {return}
    if ui.popup(ctx,popup,{align_right=true}) {
        ui.id_push(ctx,popup)
        presence_menu_items(s,g.presence_menu)
        ui.id_pop(ctx)
    }
}

@(private)
presence_menu_items :: proc(s:^Session,menu:Presence_Menu) {
    ctx:=s.gui.ctx
    header :: proc(ctx:^ui.Context,text:string) {
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(24),padding={6,0,6,0},align_y=.Center}) {ui.label(ctx,text,ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted"))}
    }
    editing:=s.mode==.Edit || s.mode==.Watch
    switch menu.kind {
    case .None:
        ui.popup_close(ctx)
    case .Agent:
        task:=s.ai!=nil?ai_task_find(s.ai,menu.task):nil
        if task==nil {ui.popup_close(ctx);return}
        header(ctx,ai_chat_menu_label(ctx,base.text_get(task.title[:]),180,ui.metric(ctx,"font_small")))
        if ui.menu_item(ctx,ui.id(ctx,"chat"),"Open chat",{icon=.Sparkle}) {
            ai_chat_select(s,task)
            ai_chat_show(s.ai,true)
        }
        eyes,_,shown:=ai_scene_eyes(s,task)
        if ui.menu_item(ctx,ui.id(ctx,"go"),"Go to",{icon=.Target,disabled=!shown || !editing || !ai_scene_task_visible(s,shown_world(s),task)}) {presence_go_to(s,eyes,presence_yaw(task.look-eyes))}
        watched:=s.mode==.Watch && s.watch.task==task.id
        if watched {
            if ui.menu_item(ctx,ui.id(ctx,"unwatch"),"Stop watching",{icon=.Stop}) {watch_stop(s)}
        } else if ui.menu_item(ctx,ui.id(ctx,"watch"),"Watch",{icon=.Play,disabled=run_find(s,task.id)==nil}) {
            if !watch_start(s,task.id) {notify(s,"The run of the agent cannot be shown now")}
        }
    case .Peer:
        st:=collab_state(s)
        if st==nil || st.phase!=.Joined || menu.peer<0 || menu.peer>=COLLAB_PEERS || !st.peers[menu.peer].used {ui.popup_close(ctx);return}
        peer:=&st.peers[menu.peer]
        name:=string(peer.name[:peer.name_length])
        state:=""
        switch {
        case peer.serving: state=" serves a game"
        case peer.in_game: state=fmt.tprintf(" plays the game of %s",collab_peer_name(s,0))
        case peer.playing: state=" plays alone"
        }
        header(ctx,fmt.tprintf("%s%s",name,state))
        posed:=peer.has_pose && wire.host_time(&st.host)-peer.seen<=COLLAB_PRESENCE_SEEN
        if ui.menu_item(ctx,ui.id(ctx,"go"),"Go to",{icon=.Target,disabled=!posed || !editing}) {
            forward,_,_:=orbit_basis(peer.orbit)
            presence_go_to(s,orbit_position(peer.orbit),presence_yaw(forward))
        }
        following:=s.viewport.follow==menu.peer+1
        if ui.menu_item(ctx,ui.id(ctx,"follow"),following?"Stop following":"Follow",{icon=.Eye,checked=following,disabled=!posed || s.mode!=.Edit && !following}) {
            if following {s.viewport.follow=0} else {collab_follow_start(s,menu.peer)}
        }
        // Only the game of the host is joined: its address is the one of the session.
        if menu.peer==0 && st.role==.Guest {
            if p:=providers(s);p.plays && p.play.host_menu!=nil {p.play.host_menu(s,peer.serving)}
        }
    case .Remote_Agent:
        st:=collab_state(s)
        if st==nil || st.phase!=.Joined {ui.popup_close(ctx);return}
        agents:=collab_remote_agents(s.ai,st,menu.peer,wire.host_time(&st.host))
        if menu.agent>=len(agents) {ui.popup_close(ctx);return}
        agent:=agents[menu.agent]
        header(ctx,fmt.tprintf("%s of %s",string(agent.name[:agent.name_length]),collab_peer_name(s,menu.peer)))
        _,low,_,loaded:=presence_mesh(s.app.assets)
        if ui.menu_item(ctx,ui.id(ctx,"go"),"Go to",{icon=.Target,disabled=!loaded || !editing}) {presence_go_to(s,agent.anchor+{0,-low.y,0},presence_yaw(agent.look-agent.anchor))}
    }
}

// The camera follows the one of another editor until it moves by itself.
@(private)
collab_follow_start :: proc(s:^Session,peer:int) {
    v:=s.viewport
    v.follow=peer+1
    collab_follow(s)
}

// Before the camera of the frame is made: the one of the editor followed,
// unless the camera of this end moved since it was put there.
@(private)
collab_follow :: proc(s:^Session) {
    v:=s.viewport
    if v.follow==0 {return}
    st:=collab_state(s)
    i:=v.follow-1
    if st==nil || st.phase!=.Joined || s.mode!=.Edit || i>=COLLAB_PEERS || !st.peers[i].used || !st.peers[i].has_pose || v.orbit!=v.followed && v.followed!={} {
        v.follow,v.followed=0,{}
        return
    }
    orbit:=st.peers[i].orbit
    orbit.fov=v.orbit.fov
    v.orbit,v.followed=orbit,orbit
}

// The editor followed, for the bar; empty when none.
presence_followed_name :: proc(s:^Session) -> string {
    if s.viewport.follow==0 {return ""}
    return collab_peer_name(s,s.viewport.follow-1)
}

// The other editor whose glyph is at a point of the viewport.
@(private)
collab_peer_at :: proc(s:^Session,point:[2]f32) -> (peer:int,rect:ui.Rect,found:bool) {
    st:=collab_state(s)
    if st==nil || st.phase!=.Joined || s.mode!=.Edit {return}
    _,_,high,loaded:=presence_mesh(s.app.assets)
    if !loaded {return}
    now:=wire.host_time(&st.host)
    for &other,i in st.peers {
        if i==int(st.self) || !other.used || !other.has_pose || now-other.seen>COLLAB_PRESENCE_SEEN {continue}
        r,shown:=presence_glyph_rect(s,presence_shown(&st.figures[i],orbit_position(other.orbit))+{0,high.y,0},s.viewport.view_projection)
        if shown && ui.rect_contains(r,point) {return i,r,true}
    }
    return
}
