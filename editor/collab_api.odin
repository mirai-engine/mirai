package editor

import "core:fmt"
import "mirai:editor/api"
import "mirai:platform"
import "mirai:std/base"
import "mirai:ui"

// The collab.* methods of the API and the Share popup of the bar.

Api_Collab_Host_Params :: struct {
    port:int `mirai:"optional,min=0,max=65535,label=0: the default port"`,
    name:[COLLAB_NAME_BYTES]u8 `mirai:"text,optional"`,
}

Api_Collab_Join_Params :: struct {
    invite:[64]u8 `mirai:"text,label=The code of the invitation of the host (like K7Q2-9XMA-PL3F-0B2C)"`,
    name:[COLLAB_NAME_BYTES]u8 `mirai:"text,optional"`,
    discard:bool `mirai:"optional,label=Replace the scene even with unsaved changes"`,
}

Api_Collab_Peer :: struct {
    id:u8,
    name:[COLLAB_NAME_BYTES]u8 `mirai:"text"`,
    joined,self:bool,
    playing:bool `mirai:"label=Inside a Play or Simulate"`,
    serving:bool `mirai:"label=Serving a game on the network"`,
    in_game:bool `mirai:"label=A guest playing the game the host serves"`,
}

Api_Collab_Unsent :: struct {
    path:[COLLAB_UNSENT_PATH]u8 `mirai:"text,label=The asset file, too large to travel: whoever changed it saves it and shares it through the repository of the project"`,
    peer:u8 `mirai:"label=The id of the editor that changed it"`,
    bytes:u64,
}

Api_Collab_Status :: struct {
    role:Collab_Role,
    phase:Collab_Phase,
    invite:[48]u8 `mirai:"text,label=The host: the code to give others to join with"`,
    lan_invite:[48]u8 `mirai:"text,label=The host: the code its network joins with"`,
    port:int,
    reason:[96]u8 `mirai:"text,label=Why the session ended"`,
    peers:[COLLAB_PEERS]Api_Collab_Peer `mirai:"label=The first count are in the session"`,
    count:int,
    unsent:[COLLAB_UNSENT]Api_Collab_Unsent `mirai:"label=The first unsent_count are files changed in the session that the others do not have"`,
    unsent_count:int,
    sent_edits,received_edits,sent_ops,received_ops:u64,
}

@(private)
collab_api_register :: proc(s:^Session,st:^Api_State) {
    api_register(s,st,{name="collab.host",summary="Shares the scene: other editors connect to this one with the code of the invitation it gives.",params=Api_Collab_Host_Params,result=Api_Collab_Status,run=api_collab_host})
    api_register(s,st,{name="collab.join",summary="Enters the session of another editor; the scene is replaced by its scene. Returns before the scene arrives: poll collab.status until phase is Joined.",params=Api_Collab_Join_Params,result=Api_Collab_Status,flags={.Destructive},run=api_collab_join})
    api_register(s,st,{name="collab.leave",summary="Ends the session; the scene stays as it is.",result=Api_Collab_Status,flags={.Idempotent},run=api_collab_leave})
    api_register(s,st,{name="collab.status",summary="The session this editor shares or joined: who is in it and how others join it.",result=Api_Collab_Status,flags={.Read_Only},run=api_collab_status})
}

@(private)
api_collab_result :: proc(s:^Session,call:^api.Call) {
    r:=api.call_result(call,Api_Collab_Status)
    st:=collab_state(s)
    if st==nil {return}
    r.role,r.phase=st.role,st.phase
    base.text_set(r.invite[:],string(st.code[:st.code_length]))
    base.text_set(r.lan_invite[:],string(st.lan_code[:st.lan_length]))
    base.text_set(r.reason[:],st.reason)
    r.port=st.port
    for &peer,i in st.peers {
        if !peer.used {continue}
        r.peers[r.count]={id=u8(i),joined=peer.joined || i==0,self=i==int(st.self),playing=peer.playing,serving=peer.serving,in_game=peer.in_game}
        if i==int(st.self) {
            r.peers[r.count].playing=run_find(s,0)!=nil
            r.peers[r.count].in_game=collab_in_game(s)
            offer:[COLLAB_OFFER_BYTES]u8
            r.peers[r.count].serving=collab_offer(s,offer[:])>0
        }
        base.text_set(r.peers[r.count].name[:],string(peer.name[:peer.name_length]))
        r.count+=1
    }
    for unsent in st.unsent[:st.unsent_count] {
        r.unsent[r.unsent_count]={path=unsent.path,peer=unsent.peer,bytes=unsent.bytes}
        r.unsent_count+=1
    }
    r.sent_edits,r.received_edits,r.sent_ops,r.received_ops=st.sent_edits,st.received_edits,st.sent_ops,st.received_ops
}

@(private)
api_collab_host :: proc(s:^Session,call:^api.Call) {
    params:=api.call_params(call,Api_Collab_Host_Params)
    if error:=collab_host(s,params.port,base.text_get(params.name[:]));error!=.None {
        api.call_fail(call,api.SERVER_ERROR,collab_error_text(error))
        return
    }
    api_collab_result(s,call)
}

@(private)
api_collab_join :: proc(s:^Session,call:^api.Call) {
    params:=api.call_params(call,Api_Collab_Join_Params)
    if error:=collab_join(s,base.text_get(params.invite[:]),base.text_get(params.name[:]),params.discard);error!=.None {
        api.call_fail(call,error==.Invite?api.INVALID_PARAMS:api.SERVER_ERROR,collab_error_text(error))
        return
    }
    api_collab_result(s,call)
}

@(private)
api_collab_leave :: proc(s:^Session,call:^api.Call) {
    collab_leave(s)
    api_collab_result(s,call)
}

@(private)
api_collab_status :: proc(s:^Session,call:^api.Call) {api_collab_result(s,call)}

// ---------------------------------------------------------------- the Share popup

@(private)
share_popup :: proc(g:^Editor_Ui) -> ui.Id {return shell_id(g,"share_popup")}

SESSION_WIDTH :: f32(284)
SESSION_LABEL :: f32(74) // the column of the names of the rows

// The button of the bar: the editors of a session, with a green dot while one is open.
@(private)
share_button :: proc(s:^Session,height:f32) {
    g:=s.gui
    ctx:=g.ctx
    id:=shell_id(g,"share")
    named_add(g,id)
    st:=collab_state(s)
    active:=st!=nil && st.role!=.None && st.phase!=.Ended
    tip:="Session"
    if active {
        count:=0
        for peer in st.peers {
            if peer.used {count+=1}
        }
        tip=fmt.tprintf("Session, %d editors",count)
    }
    if ui.box(ctx,{width=ui.fixed(28),height=ui.fixed(height)}) {
        if ui.button(ctx,id,{icon=ui.icon_user(u8(User_Icon.Users)),icon_size=15,icon_color=active?ctx.theme.success:{},tip=tip,style=.Ghost,width=28,height=height,active=ui.popup_is_open(ctx,share_popup(g))}).clicked {
            anchor,_:=ui.widget_rect(ctx,id)
            ui.popup_open(ctx,share_popup(g),anchor)
        }
        if active {
            if ui.box(ctx,{width=ui.fixed(6),height=ui.fixed(6),fill=ctx.theme.success,radius=3,float={to=.Parent,anchor=.Top_Right,pivot=.Top_Right,offset={-4,4}}}) {}
        }
    }
}

// A row of the popup: its name in the column of names, then what follows.
@(private,deferred_in=share_row_end)
share_row :: proc(ctx:^ui.Context,name:string,height:f32=26) -> bool {
    th:=&ctx.theme
    ui.box_begin(ctx,{width=ui.GROW,height=ui.fixed(height),gap=8,align_y=.Center})
    ui.label(ctx,name,10.5,th.text_muted,SESSION_LABEL)
    return true
}
@(private)
share_row_end :: proc(ctx:^ui.Context,name:string,height:f32) {ui.box_end(ctx,{})}

// A code of the invitation in its box, with its own Copy; without a code, why there is none.
@(private)
share_code :: proc(s:^Session,id,name,code,missing:string) {
    g:=s.gui
    ctx:=g.ctx
    th:=&ctx.theme
    if share_row(ctx,name) {
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(24),padding={6,0,6,0},align_y=.Center,fill=th.well,stroke=th.well_stroke,radius=th.radius_control,clip_x=true}) {
            ui.label(ctx,code!=""?code:missing,code!=""?10.5:th.font_label,code!=""?th.text:th.text_muted,0)
        }
        if ui.button(ctx,shell_id(g,id),{label="Copy",style=.Field,width=0,height=24,size=10.5,padding=8,center=true,disabled=code==""}).clicked {
            platform.clipboard_set(s.app.platform,code)
            notify(s,fmt.tprintf("Copied the code for %s",name=="Internet"?"the internet":"the same network"))
        }
    }
}

@(private)
share_build :: proc(s:^Session) {
    g:=s.gui
    ctx:=g.ctx
    th:=&ctx.theme
    popup:=share_popup(g)
    if !ui.popup_is_open(ctx,popup) {return}
    c:=collab_of(s)
    if c.name_length==0 {collab_name_set(c,"Editor")}
    st:=collab_state(s)
    if ui.popup(ctx,popup,{width=SESSION_WIDTH,align_right=true,padding=12,gap=6}) {
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(22),align_y=.Center}) {
            ui.label(ctx,"Session",13,th.text,0,font=ui.FONT_SEMIBOLD)
            if ui.button(ctx,shell_id(g,"share_close"),{icon=.Cross,icon_size=12,icon_color=th.text_muted,style=.Ghost,width=22,height=22}).clicked {ui.popup_close(ctx,popup)}
        }
        ui.spacer(ctx,-1,2)
        switch {
        case st==nil || st.role==.None:
            if share_row(ctx,"Name") {ui.text_field(ctx,shell_id(g,"share_name"),c.name[:],&c.name_length,{height=24,size=11,live=true,keep_caret=true})}
            if c.joining {
                if share_row(ctx,"Invitation") {ui.text_field(ctx,shell_id(g,"share_address"),c.join[:],&c.join_length,{height=24,size=11,placeholder="K7Q2-9XMA-PL3F-0B2C",live=true,keep_caret=true})}
            }
            if c.error!=.None {
                if share_row(ctx,"Error") {ui.label(ctx,collab_error_text(c.error),th.font_label,th.danger_soft,0)}
            }
            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(26),gap=8,align_y=.Center}) {
                busy:=s.mode!=.Edit
                if ui.button(ctx,shell_id(g,"share_join"),{label="Join",style=.Field,width=-1,height=ctx.theme.control,size=11,center=true,disabled=busy || c.joining && c.join_length==0}).clicked {
                    if c.joining {c.error=collab_join(s,string(c.join[:c.join_length]),string(c.name[:c.name_length]),false)} else {c.joining=true;ui.edit_request(ctx,shell_id(g,"share_address"))}
                }
                if ui.button(ctx,shell_id(g,"share_host"),{label="Host",style=.Accent,width=-1,height=ctx.theme.control,size=11,center=true,disabled=busy}).clicked {
                    c.error=collab_host(s,0,string(c.name[:c.name_length]))
                }
            }
        case:
            c.error=.None
            #partial switch st.phase {
            case .Connecting: ui.label(ctx,"Connecting...",10.5,th.text_muted,0)
            case .Syncing:    ui.label(ctx,"Receiving the scene...",10.5,th.text_muted,0)
            case .Ended:
                if share_row(ctx,"Reason") {ui.label(ctx,st.reason,10.5,th.text,0)}
            }
            if st.role==.Host {
                // Who is on the network of the host joins by its address there;
                // who is not, by the one the router opened, once it did.
                share_code(s,"share_copy_lan","Same network",string(st.lan_code[:st.lan_length]),"")
                internet,waiting:=collab_internet_code(st)
                share_code(s,"share_copy_internet","Internet",internet,waiting)
            }
            for &peer,i in st.peers {
                if !peer.used {continue}
                if ui.box(ctx,{width=ui.GROW,height=ui.fixed(28),gap=9,align_y=.Center}) {
                    if ui.box(ctx,{width=ui.fixed(9),height=ui.fixed(9),fill=collab_color(i),radius=4.5}) {}
                    name:=string(peer.name[:peer.name_length])
                    if i==int(st.self) {name=fmt.tprintf("%s (you)",name)}
                    ui.label(ctx,name,12,th.text,0)
                    ui.label(ctx,i==0?"Host":"Guest",th.font_label,th.text_muted)
                }
            }
            for &unsent in st.unsent[:st.unsent_count] {ui.text(ctx,collab_unsent_text(st,&unsent),ui.prose(ctx,th.font_label,th.danger_soft))}
            label:=st.role==.Host?"Stop":"Leave"
            if st.phase==.Ended {label="Close"}
            if ui.button(ctx,shell_id(g,"share_leave"),{label=label,style=.Accent,width=-1,height=ctx.theme.control,size=11,center=true}).clicked {collab_leave(s)}
        }
    }
}
