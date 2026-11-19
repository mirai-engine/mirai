package editor

import "core:fmt"
import "core:sync"
import "mirai:cook/share"
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
    invite:[64]u8 `mirai:"text,label=The code of the invitation of the host (like R2M0-253B-DK5G-0W87-M0MA-3CP3-TKJZ-C1RR-EJT)"`,
    name:[COLLAB_NAME_BYTES]u8 `mirai:"text,optional"`,
    folder:[512]u8 `mirai:"text,optional,label=Where the host's project goes: empty or the open project, updated by three ways; another folder, new or joined before, is opened once it has the files and joins the session from there"`,
}

Api_Collab_Project :: struct {
    peers:int `mirai:"label=Connections the project moves over"`,
    sent,received:u64 `mirai:"label=Chunk bytes sent to and received from the others"`,
    send_rate,receive_rate:f64 `mirai:"label=Bytes per second now"`,
    bad:int `mirai:"label=Peers that sent what no peer sends: neither asked nor served since"`,
    refused:u64 `mirai:"label=Their messages refused"`,
}

Api_Collab_Line :: struct {text:[COLLAB_LINE_BYTES]u8 `mirai:"text"`}

Api_Collab_Join :: struct {
    phase:share.Join_Phase `mirai:"label=Connecting, Snapshot (asking for the project), Files, Packages (their builds from the peers), Done"`,
    folder:[512]u8 `mirai:"text,label=Where the files of the host go"`,
    opening:bool `mirai:"label=The folder is being built to open it: the editor started on it joins the session"`,
    files,files_done:int `mirai:"label=Files to fetch, and fetched"`,
    bytes,bytes_done:i64 `mirai:"label=Bytes of the files to fetch, and here"`,
    received:u64 `mirai:"label=Chunk bytes received in the phase"`,
    rate:f64 `mirai:"label=Bytes received per second lately"`,
    left:f64 `mirai:"label=Seconds the files still need at that rate; -1: unknown"`,
    written,removed:int `mirai:"label=Files written and removed, once the files are done"`,
    kept:[COLLAB_LINES]Api_Collab_Line `mirai:"label=Files left as this editor changed them, each with why; the first of kept_count"`,
    kept_count:int,
    failed:[COLLAB_LINES]Api_Collab_Line `mirai:"label=Files not written or removed, each with why and how to fix it; the first of failed_count"`,
    failed_count:int,
    missing:[COLLAB_LINES]Api_Collab_Line `mirai:"label=Packages no connected peer has a build of and no source here gives, by name; the first of missing_count"`,
    missing_count:int,
    error:[256]u8 `mirai:"text,label=Why the join stopped"`,
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
    port:int,
    reason:[96]u8 `mirai:"text,label=Why the session ended"`,
    peers:[COLLAB_PEERS]Api_Collab_Peer `mirai:"label=The first count are in the session"`,
    count:int,
    unsent:[COLLAB_UNSENT]Api_Collab_Unsent `mirai:"label=The first unsent_count are files changed in the session that the others do not have"`,
    unsent_count:int,
    join:Api_Collab_Join `mirai:"label=A guest: how its folder is brought to the host's snapshot before it enters the scene"`,
    project:Api_Collab_Project `mirai:"label=What the session moved of the project and its builds"`,
    offers:int `mirai:"label=The host: new snapshots of its project offered during the session, each once its files changed and were quiet"`,
    updates:int `mirai:"label=A guest: updates of its folder to a new snapshot of the host done in the session; join says the last"`,
    sent_edits,received_edits,sent_ops,received_ops:u64,
}

@(private)
collab_api_register :: proc(s:^Session,st:^Api_State) {
    api_register(s,st,{name="collab.host",summary="Shares the scene: other editors connect to this one with the code of the invitation it gives.",params=type_info_of(Api_Collab_Host_Params),result=type_info_of(Api_Collab_Status),run=api_collab_host})
    api_register(s,st,{name="collab.join",summary="Enters the session of another editor: first a folder is brought to the host's project (its files, then the builds of its packages from the peers), then the scene is replaced by its scene. Returns at once: poll collab.status until phase is Joined; its join says how far the folder is.",params=type_info_of(Api_Collab_Join_Params),result=type_info_of(Api_Collab_Status),flags={.Destructive},run=api_collab_join})
    api_register(s,st,{name="collab.leave",summary="Ends the session; the scene stays as it is.",result=type_info_of(Api_Collab_Status),flags={.Idempotent},run=api_collab_leave})
    api_register(s,st,{name="collab.status",summary="The session this editor shares or joined: who is in it and how others join it.",result=type_info_of(Api_Collab_Status),flags={.Read_Only},run=api_collab_status})
}

@(private)
api_collab_result :: proc(s:^Session,call:^api.Call) {
    r:=api.call_result(call,Api_Collab_Status)
    st:=collab_state(s)
    if st==nil {return}
    r.role,r.phase=st.role,st.phase
    base.text_set(r.invite[:],string(st.code[:st.code_length]))
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
    if j:=st.join;j!=nil {api_collab_join_result(j,&r.join)}
    r.offers,r.updates=st.offers,st.updates
    if st.node!=nil {
        t:=share.node_totals(st.node)
        r.project={peers=t.connected,sent=t.sent,received=t.received,send_rate=t.send_rate,receive_rate=t.receive_rate,bad=t.bad,refused=t.refused}
    }
}

@(private)
api_collab_join_result :: proc(j:^Collab_Join,r:^Api_Collab_Join) {
    state:=share.join_progress_read(&j.progress)
    r.phase,r.opening=state.phase,j.opening
    base.text_set(r.folder[:],j.folder)
    r.files,r.files_done,r.bytes,r.bytes_done=state.files,state.files_done,state.bytes,state.bytes_done
    r.received,r.rate,r.left=state.received,state.rate,state.left
    r.kept_count=state.kept
    // The report is the thread's until it is done.
    if !sync.atomic_load(&j.done) {return}
    lines :: proc(into:[]Api_Collab_Line,count:^int,from:[]string) {
        count^=len(from)
        for line,k in from[:min(len(from),len(into))] {base.text_set(into[k].text[:],line)}
    }
    r.written,r.removed=j.report.written,j.report.removed
    lines(r.kept[:],&r.kept_count,j.report.kept[:])
    lines(r.failed[:],&r.failed_count,j.report.failed[:])
    lines(r.missing[:],&r.missing_count,j.report.packages.missing[:])
    base.text_set(r.error[:],j.error)
}

// The text of an error of collab.host or collab.join, with the problem of the project.
@(private)
collab_error_say :: proc(s:^Session,error:Collab_Error) -> string {
    if error==.Project {
        c:=collab_of(s)
        return fmt.tprintf("%s: %s",collab_error_text(error),base.text_get(c.problem[:]))
    }
    return collab_error_text(error)
}

@(private)
api_collab_host :: proc(s:^Session,call:^api.Call) {
    params:=api.call_params(call,Api_Collab_Host_Params)
    if error:=collab_host(s,params.port,base.text_get(params.name[:]));error!=.None {
        api.call_fail(call,api.SERVER_ERROR,collab_error_say(s,error))
        return
    }
    api_collab_result(s,call)
}

@(private)
api_collab_join :: proc(s:^Session,call:^api.Call) {
    params:=api.call_params(call,Api_Collab_Join_Params)
    if error:=collab_join(s,base.text_get(params.invite[:]),base.text_get(params.name[:]),base.text_get(params.folder[:]));error!=.None {
        api.call_fail(call,error==.Invite?api.INVALID_PARAMS:api.SERVER_ERROR,collab_error_say(s,error))
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
        if ui.button(ctx,id,{icon=ui.icon_user(u8(User_Icon.Users)),icon_size=15,icon_color=active?ui.tone(ctx,"success"):{},tip=tip,variant="ghost",width=28,height=height,active=ui.popup_is_open(ctx,share_popup(g))}).clicked {
            anchor,_:=ui.widget_rect(ctx,id)
            ui.popup_open(ctx,share_popup(g),anchor)
        }
        if active {
            if ui.box(ctx,{width=ui.fixed(6),height=ui.fixed(6),fill=ui.tone(ctx,"success"),radius=3,float={to=.Parent,anchor=.Top_Right,pivot=.Top_Right,offset={-4,4}}}) {}
        }
    }
}

// A row of the popup: its name in the column of names, then what follows.
@(private,deferred_in=share_row_end)
share_row :: proc(ctx:^ui.Context,name:string,height:f32=26) -> bool {
    ui.box_begin(ctx,{width=ui.GROW,height=ui.fixed(height),gap=8,align_y=.Center})
    ui.label(ctx,name,10.5,ui.tone(ctx,"text_muted"),SESSION_LABEL)
    return true
}
@(private)
share_row_end :: proc(ctx:^ui.Context,name:string,height:f32) {ui.box_end(ctx,{})}

// A code of the invitation with its own Copy, then in its box across the popup, which a code of
// two addresses needs; without a code, why there is none.
@(private)
share_code :: proc(s:^Session,id,name,code,missing:string) {
    g:=s.gui
    ctx:=g.ctx
    if share_row(ctx,name) {
        ui.spacer(ctx,-1,0)
        if ui.button(ctx,shell_id(g,id),{label="Copy",variant="field",width=0,height=24,size=10.5,padding=8,center=true,disabled=code==""}).clicked {
            platform.clipboard_set(s.app.platform,code)
            notify(s,"Copied the code")
        }
    }
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(24),padding={6,0,6,0},align_y=.Center,fill=ui.tone(ctx,"well"),stroke=ui.tone(ctx,"well_stroke"),radius=ui.metric(ctx,"radius_control"),clip_x=true}) {
        ui.label(ctx,code!=""?code:missing,code!=""?10.5:ui.metric(ctx,"font_label"),code!=""?ui.tone(ctx,"text"):ui.tone(ctx,"text_muted"),0)
    }
}

@(private)
share_build :: proc(s:^Session) {
    g:=s.gui
    ctx:=g.ctx
    popup:=share_popup(g)
    if !ui.popup_is_open(ctx,popup) {return}
    c:=collab_of(s)
    if c.name_length==0 {collab_name_set(c,"Editor")}
    st:=collab_state(s)
    if ui.popup(ctx,popup,{width=SESSION_WIDTH,align_right=true,padding=12,gap=6}) {
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(22),align_y=.Center}) {
            ui.label(ctx,"Session",13,ui.tone(ctx,"text"),0,font=ui.FONT_SEMIBOLD)
            if ui.button(ctx,shell_id(g,"share_close"),{icon=.Cross,icon_size=12,icon_color=ui.tone(ctx,"text_muted"),variant="ghost",width=22,height=22}).clicked {ui.popup_close(ctx,popup)}
        }
        ui.spacer(ctx,-1,2)
        switch {
        case st==nil || st.role==.None:
            if share_row(ctx,"Name") {ui.text_field(ctx,shell_id(g,"share_name"),c.name[:],&c.name_length,{height=24,size=11,live=true,keep_caret=true})}
            if c.joining {
                if share_row(ctx,"Invitation") {ui.text_field(ctx,shell_id(g,"share_address"),c.join[:],&c.join_length,{height=24,size=11,placeholder="R2M0-253B-DK5G-0W87-M0MA-3CP3-TKJZ-C1RR-EJT",live=true,keep_caret=true})}
            }
            if c.error!=.None {
                if share_row(ctx,"Error") {ui.text(ctx,collab_error_say(s,c.error),ui.prose(ctx,ui.metric(ctx,"font_label"),ui.tone(ctx,"danger_soft")))}
            }
            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(26),gap=8,align_y=.Center}) {
                busy:=s.mode!=.Edit
                if ui.button(ctx,shell_id(g,"share_join"),{label="Join",variant="field",width=-1,height=ui.metric(ctx,"control"),size=11,center=true,disabled=busy || c.joining && c.join_length==0}).clicked {
                    if c.joining {c.error=collab_join(s,string(c.join[:c.join_length]),string(c.name[:c.name_length]))} else {c.joining=true;ui.edit_request(ctx,shell_id(g,"share_address"))}
                }
                if ui.button(ctx,shell_id(g,"share_host"),{label="Host",variant="accent",width=-1,height=ui.metric(ctx,"control"),size=11,center=true,disabled=busy}).clicked {
                    c.error=collab_host(s,0,string(c.name[:c.name_length]))
                }
            }
        case:
            c.error=.None
            #partial switch st.phase {
            case .Connecting: ui.label(ctx,"Connecting...",10.5,ui.tone(ctx,"text_muted"),0)
            case .Updating:   ui.label(ctx,collab_join_text(st.join),10.5,ui.tone(ctx,"text_muted"),0)
            case .Syncing:    ui.label(ctx,"Receiving the scene...",10.5,ui.tone(ctx,"text_muted"),0)
            case .Ended:
                if share_row(ctx,"Reason") {ui.text(ctx,st.reason,ui.prose(ctx,10.5,ui.tone(ctx,"text")))}
            }
            // A guest updating its folder to a new snapshot of the host.
            if st.phase==.Joined && st.join!=nil && st.join.update && !st.join.finished {ui.label(ctx,collab_join_text(st.join),10.5,ui.tone(ctx,"text_muted"),0)}
            share_join_lines(s,st)
            if st.role==.Host {
                // One code joins from anywhere: a guest asks at both of its addresses.
                share_code(s,"share_copy","Code",string(st.code[:st.code_length]),"Opening the port on the router...")
            }
            // A guest knows who is in the session from the roster, which comes after its Hello.
            for &peer,i in st.peers {
                if !peer.used || st.role==.Guest && st.phase<.Syncing {continue}
                if ui.box(ctx,{width=ui.GROW,height=ui.fixed(28),gap=9,align_y=.Center}) {
                    if ui.box(ctx,{width=ui.fixed(9),height=ui.fixed(9),fill=collab_color(i),radius=4.5}) {}
                    name:=string(peer.name[:peer.name_length])
                    if i==int(st.self) {name=fmt.tprintf("%s (you)",name)}
                    ui.label(ctx,name,12,ui.tone(ctx,"text"),0)
                    ui.label(ctx,i==0?"Host":"Guest",ui.metric(ctx,"font_label"),ui.tone(ctx,"text_muted"))
                }
            }
            for &unsent in st.unsent[:st.unsent_count] {ui.text(ctx,collab_unsent_text(st,&unsent),ui.prose(ctx,ui.metric(ctx,"font_label"),ui.tone(ctx,"danger_soft")))}
            label:=st.role==.Host?"Stop":"Leave"
            if st.phase==.Ended {label="Close"}
            if ui.button(ctx,shell_id(g,"share_leave"),{label=label,variant="accent",width=-1,height=ui.metric(ctx,"control"),size=11,center=true}).clicked {collab_leave(s)}
        }
    }
}

// What a guest's join left as it was and could not do: the files it kept, those it could
// not write and the packages no peer has a build of.
@(private)
share_join_lines :: proc(s:^Session,st:^Collab_State) {
    j:=st.join
    if j==nil || !j.finished {return}
    ctx:=s.gui.ctx
    muted:=ui.prose(ctx,ui.metric(ctx,"font_label"),ui.tone(ctx,"text_muted"))
    danger:=ui.prose(ctx,ui.metric(ctx,"font_label"),ui.tone(ctx,"danger_soft"))
    for line in j.report.kept[:min(len(j.report.kept),COLLAB_LINES)] {ui.text(ctx,line,muted)}
    if len(j.report.kept)>COLLAB_LINES {ui.text(ctx,fmt.tprintf("%d more kept",len(j.report.kept)-COLLAB_LINES),muted)}
    for line in j.report.failed[:min(len(j.report.failed),COLLAB_LINES)] {ui.text(ctx,line,danger)}
    for line in j.report.packages.missing[:min(len(j.report.packages.missing),COLLAB_LINES)] {ui.text(ctx,line,danger)}
}
