package multiplayer_editor

import "core:encoding/endian"
import "core:fmt"
import "core:log"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/history"
import "mirai:host"
import wire "mirai:net"
import "mirai:platform"
import "mirai:std/base"
import "mirai:ui"
import multiplayer "plugins:multiplayer/runtime"

// Play on the network. Each World has its own network session, so the Play
// of the user serves the game itself, with its local players sharing the
// screen, and each online player is a process of the player that joins it
// (editor/player_processes.odin): once the server listens the editor opens
// one per online player on the library it loaded, with the delay that makes
// the ping asked for, on a copy of the scene as it was when Play was pressed.
// Nothing is built: server and clients run one library. Stop ends them
// with the Play. A guest of a shared session joins the game the host serves
// with a player of its own, on the scene that server runs: the presence of
// the host carries the offer of its game.
//
// The runs of agents play on the network inside the editor: their server and
// their clients are runs, which advance together with play.step.

NET_PLAY_PORTS :: 16               // tried from the default port of the player
NET_PLAY_STEPPED_TIMEOUT :: 600.0 // seconds the runs of a turn wait for each other: they advance when the turn asks
NET_PLAY_OFFER :: 13              // bytes of the offer: port, port on the router, game, invitation, whether the router is still asked

Net_Play_Phase :: enum u8 {
    Idle,
    Waiting, // the server of Play to listen; a guest: for the copy of the scene of the host, and for its router when it plays from outside its network
    Running,
}

Net_Play_Role :: enum u8 {
    Server, // the Play of this editor serves the game and opens its online players
    Client, // a guest of the session plays the game of the host
}

// Who plays on the network besides the local players of Play, as the editor
// keeps them between sessions.
Net_Play_Party :: struct {
    online:int, // players besides the local ones, a process each: Play serves the game
    ping:int,   // milliseconds of round trip the online players simulate
}

// What waits for the question about unsaved assets.
Net_Play_Pending :: enum u8 {None,Serve,Join}

@(storage)
Net_Play :: struct {
    party:Net_Play_Party,
    phase:Net_Play_Phase,
    role:Net_Play_Role,
    pending:Net_Play_Pending,
    serial:u32,     // of the game: the offer of the host says which one it serves
    port:int,       // of the server
    invite:u32,     // the token of the invitation of the server
    scene_ready:bool,
    mapping:wire.Port_Mapping, // of the port of the server on the router, while the session is shared
    mapping_on:bool,
    reason:[128]u8, // why the last game ended, when it did not end with Stop
}

@(storage)
Multiplayer_Play :: struct {provider:editor.Play_Provider}

multiplayer_play_default :: proc() -> Multiplayer_Play {
    return {provider={
        start=net_play_start,confirmed=net_play_confirmed,verb=net_play_verb,
        menu=net_play_menu,active=net_play_active,stop=net_play_stop,label=net_play_label,poll=net_play_poll,
        play_begin=net_play_begin,play_end=net_play_served_end,pump=net_play_pump,turn=net_play_turn,
        offer=net_play_offer,game=net_play_game,host_menu=net_play_host_menu,joined=net_play_joined,scene_arrived=net_play_scene_arrived,
    }}
}

@(storage)
Multiplayer_Preferences :: struct {provider:editor.Preferences_Provider}

multiplayer_preferences_default :: proc() -> Multiplayer_Preferences {
    return {provider={name="Net_Play_Players",info=type_info_of(Net_Play_Party),value=net_play_party,default=proc(dst:rawptr) {(^Net_Play_Party)(dst)^={}}}}
}

@(storage)
Multiplayer_Api :: struct {provider:editor.Api_Provider}

MULTIPLAYER_API_DEFAULT :: Multiplayer_Api{provider={register=net_play_api_register}}

@(private)
net_play_of :: proc(s:^editor.Session) -> ^Net_Play {
    if s==nil || s.info==nil || s.editor_world==nil {return nil}
    return core.world_storage_of(core.world_ref(s.editor_world,s.info,.Editor),Net_Play)
}

@(private)
net_play_party :: proc(s:^editor.Session) -> rawptr {
    n:=net_play_of(s)
    return n!=nil?&n.party:nil
}

@(private)
net_play_active :: proc(s:^editor.Session) -> bool {
    n:=net_play_of(s)
    return n!=nil && n.phase!=.Idle
}

// The Play of this editor serves a game on the network.
@(private)
net_play_serving :: proc(n:^Net_Play) -> bool {return n!=nil && n.phase!=.Idle && n.role==.Server}

@(private)
local_players :: proc(s:^editor.Session) -> int {return s.play_players!=nil?s.play_players.players:editor.PLAY_PLAYERS_DEFAULT.players}

// Play serves the game when it has online players or guests in the session
// it shares. From the bar (online -1) unsaved assets are asked about; from
// the API they are refused, unless saved_only.
@(private)
net_play_start :: proc(s:^editor.Session,online,ping:int,saved_only:bool) -> (taken:bool,error:string) {
    n:=net_play_of(s)
    if n==nil {return}
    if online>=0 {n.party.online=online}
    if ping>=0 {n.party.ping=ping}
    if n.party.online<=0 && !editor.collab_hosting(s) {return}
    if !saved_only {
        if unsaved:=editor.assets_unsaved_paths(s);len(unsaved)>0 {
            if online>=0 {return true,editor.play_unsaved(s)}
            n.pending=.Serve
            editor.confirm_open(s,.Play_Plugin,unsaved)
            return true,""
        }
    }
    return true,serve(s,n)
}

@(private)
net_play_confirmed :: proc(s:^editor.Session) {
    n:=net_play_of(s)
    if n==nil {return}
    pending:=n.pending
    n.pending=.None
    error:=""
    #partial switch pending {
    case .Serve: error=serve(s,n)
    case .Join:  error=join(s,n)
    }
    if error!="" {editor.notify(s,error)}
}

@(private)
net_play_verb :: proc(s:^editor.Session) -> string {
    n:=net_play_of(s)
    return n!=nil && n.pending==.Join?"Join":"Play"
}

// Starts Play serving the game on the network, with its online players. Returns why it could not.
@(private)
serve :: proc(s:^editor.Session,n:^Net_Play) -> string {
    switch {
    case n.phase!=.Idle:              return "A network game is running; stop it first"
    case s.mode!=.Edit:               return "A network game starts from Edit"
    case !s.has_project:              return "A network game needs a project"
    case s.build.phase==.Running:     return "A build is running; wait for it"
    }
    editor.tools_release(s)
    history.edits_commit(s.edits,editor.edited_world(s),s.selection)
    if error:=editor.document_write(s,editor.play_copy_file(s,editor.PLAY_SCENE),false);error!=.None {
        return fmt.tprintf("The scene could not be copied: %s",editor.document_error_text(error))
    }
    port,refused:=net_play_port(s)
    if port==0 {return refused}
    invite,made:=wire.invite_token()
    if !made {return "The game could not start: this system gives no secure random bytes to seal the network with"}
    players:=clamp(local_players(s),1,editor.PLAYER_PROCESSES)
    if s.play_players!=nil {s.play_players.players=players}
    n.party.online=clamp(n.party.online,0,editor.PLAYER_PROCESSES-players)
    n.party.ping=clamp(n.party.ping,0,1000)
    n.role,n.port,n.serial,n.invite=.Server,port,u32(platform.clock_ns()>>10)|1,invite
    n.scene_ready=true
    n.reason={}
    n.phase=n.party.online>0?.Waiting:.Running
    editor.player_processes_reserve(s,players,n.party.online)
    // The run of Play opens the server before its first tick (net_play_begin).
    if !editor.play_start(s) {
        net_play_end(s,n,"")
        return "The game could not start"
    }
    // Guests of the session reach the server through the router, as the session.
    if editor.collab_hosting(s) {n.mapping_on=wire.mapping_start(&n.mapping,u16(n.port))}
    // Guests copy the scene they share now: the one the server runs.
    editor.collab_play_mark(s,n.serial)
    log.infof("network game: Play serves on port %d with %d local and %d online players",n.port,players,n.party.online)
    return ""
}

// A guest joins the game the host serves. Returns why it could not.
@(private)
join :: proc(s:^editor.Session,n:^Net_Play) -> string {
    switch {
    case n.phase!=.Idle:          return "A network game is running; stop it first"
    case s.mode!=.Edit:           return "A network game starts from Edit"
    case !s.has_project:          return "A network game needs a project"
    case s.build.phase==.Running: return "A build is running; wait for it"
    }
    code,game,serves,_:=host_game(s)
    if !serves {return "The host does not serve a game"}
    n.role,n.serial=.Client,game
    n.reason={}
    n.phase=.Waiting
    n.scene_ready=editor.collab_play_scene(s,game)
    editor.player_processes_reserve(s,0,1)
    log.infof("network game: joining %s",code)
    return ""
}

// The game the host serves on the network, as a guest reaches it: at the
// addresses of the invitation of the session, with the port of the server
// and the one the router of the host mapped for it. Not reachable yet while
// that router is still asked for the port.
@(private)
host_game :: proc(s:^editor.Session) -> (code:string,game:u32,ok,reachable:bool) {
    offer,invitation,offered:=editor.collab_host_offer(s)
    if !offered || len(offer)<NET_PLAY_OFFER {return}
    port,_:=endian.get_u16(offer[0:2],.Little)
    external,_:=endian.get_u16(offer[2:4],.Little)
    game,_=endian.get_u32(offer[4:8],.Little)
    invitation.token,_=endian.get_u32(offer[8:12],.Little)
    invitation.lan.port,invitation.public.port=port,external
    if external==0 {invitation.public={}}
    code=wire.invite_encode(invitation,context.temp_allocator)
    return code,game,code!="",offer[12]==0
}

// What the session tells its guests of the game this editor serves.
@(private)
net_play_offer :: proc(s:^editor.Session,out:[]u8) -> int {
    n:=net_play_of(s)
    if !net_play_serving(n) || len(out)<NET_PLAY_OFFER {return 0}
    external,mapping:=u16(0),false
    if n.mapping_on {
        status:=wire.mapping_poll(&n.mapping)
        if status.phase==.Mapped {external=status.external.port}
        mapping=status.phase==.Pending
    }
    endian.put_u16(out[0:2],.Little,u16(n.port))
    endian.put_u16(out[2:4],.Little,external)
    endian.put_u32(out[4:8],.Little,n.serial)
    endian.put_u32(out[8:12],.Little,n.invite)
    out[12]=u8(mapping)
    return NET_PLAY_OFFER
}

@(private)
net_play_joined :: proc(s:^editor.Session) -> bool {
    n:=net_play_of(s)
    return n!=nil && n.phase!=.Idle && n.role==.Client
}

@(private)
net_play_game :: proc(s:^editor.Session) -> u32 {
    n:=net_play_of(s)
    return net_play_serving(n)?n.serial:0
}

// The copy of the scene of the game of the host arrived.
@(private)
net_play_scene_arrived :: proc(s:^editor.Session,game:u32) {
    n:=net_play_of(s)
    if n==nil || n.phase==.Idle || n.role!=.Client || n.serial!=game {return}
    n.scene_ready=true
}

// Ends the network game: the Play that serves it, or the client of a guest.
@(private)
net_play_stop :: proc(s:^editor.Session) {
    n:=net_play_of(s)
    if n==nil || n.phase==.Idle {return}
    if net_play_serving(n) {
        editor.play_stop(s,true)
        return
    }
    net_play_end(s,n,"")
    log.info("network game stopped")
}

// The Play that served the game ended: its online players go with it.
@(private)
net_play_served_end :: proc(s:^editor.Session) {
    if n:=net_play_of(s);net_play_serving(n) {net_play_end(s,n,"")}
}

// The run of Play serves the game it was started for.
@(private)
net_play_begin :: proc(s:^editor.Session,r:^editor.Run) {
    n:=net_play_of(s)
    if !net_play_serving(n) {return}
    session_open(editor.run_ref(s,r),{server=true,port=n.port,invite=true,invite_token=n.invite})
}

// Between frames: what the players wait for, then the processes and what they print.
@(private)
net_play_poll :: proc(s:^editor.Session) {
    n:=net_play_of(s)
    if n==nil || n.phase==.Idle {return}
    if n.role==.Client {
        // A host not heard for a while (busy, or its presence lost) still serves; only
        // its presence or the end of the session says it does not.
        _,game,serves,_:=host_game(s)
        joined,heard:=editor.collab_host_heard(s)
        if !joined || heard && (!serves || game!=n.serial) {
            net_play_end(s,n,"The host ended its game")
            return
        }
    } else if r:=editor.run_find(s,0);r!=nil {
        if why,failed:=session_failure(editor.run_ref(s,r),s.app);failed {
            reason:=fmt.tprintf("The server could not open the network: %s",why)
            editor.play_stop(s,true)
            net_play_reason(s,n,reason)
            return
        }
    }
    switch n.phase {
    case .Idle:
    case .Waiting:
        if net_play_ready(s,n) {launch(s,n)}
    case .Running:
        exits,count:=editor.player_processes_poll(s)
        failure:=""
        for exit in exits[:count] {
            if exit.code==multiplayer.PLAYER_NET {
                failure=n.role==.Client?"The game of the host could not be joined":"An online player could not join the server"
                editor.notify(s,failure)
            }
        }
        // A guest whose player ended is out of the game.
        if n.role==.Client && count>0 {net_play_end(s,n,failure)}
    }
}

// What the players wait for is there: the server of Play listens; a guest has
// the scene of the host and reaches its server, through its router once it
// mapped the port.
@(private)
net_play_ready :: proc(s:^editor.Session,n:^Net_Play) -> bool {
    if n.role==.Server {
        r:=editor.run_find(s,0)
        if r==nil {return false}
        session:=host.app_world_storage(s.app,r.world,multiplayer.Net_Session)
        return session!=nil && session.status==.Connected
    }
    _,_,_,reachable:=host_game(s)
    return n.scene_ready && reachable
}

// The online players of the Play of this editor, or the player of a guest.
@(private)
launch :: proc(s:^editor.Session,n:^Net_Play) {
    file:=editor.play_copy_file(s,n.role==.Server?editor.PLAY_SCENE:editor.PLAY_HOST_SCENE)
    count:=n.role==.Server?n.party.online:1
    commands:=make([][]string,count,context.temp_allocator)
    for &command in commands {
        args:=make([dynamic]string,context.temp_allocator)
        connect:=wire.invite_encode({lan=wire.address_loopback(n.port),token=n.invite},context.temp_allocator)
        if n.role==.Client {connect,_,_,_=host_game(s)}
        append(&args,"--project",s.project_root,"--scene",file,"--connect",connect)
        // Each way of a datagram is delayed: the ping is twice the latency.
        if n.role==.Server && n.party.ping>0 {append(&args,"--latency",fmt.tprintf("%.1f",f64(n.party.ping)/2))}
        // Each client is one player on its machine, whatever the scene asks for; the
        // online players of this Play are players of their run, not of the profile.
        append(&args,"--players","1")
        if n.role==.Server {append(&args,"--new-player")}
        command=args[:]
    }
    if error:=editor.player_processes_open(s,commands,n.role==.Client);error!="" {
        if n.role==.Server {editor.play_stop(s,true)} else {net_play_end(s,n,"")}
        net_play_reason(s,n,error)
        return
    }
    n.phase=.Running
}

@(private)
net_play_end :: proc(s:^editor.Session,n:^Net_Play,reason:string) {
    editor.player_processes_close(s)
    if n.mapping_on {wire.mapping_close(&n.mapping)}
    n.mapping_on=false
    n.phase,n.scene_ready,n.serial,n.port,n.invite,n.pending=.Idle,false,0,0,0,.None
    base.text_set(n.reason[:],reason)
    if reason!="" {
        log.warn(reason)
        editor.notify(s,reason)
    }
}

@(private)
net_play_reason :: proc(s:^editor.Session,n:^Net_Play,reason:string) {
    base.text_set(n.reason[:],reason)
    log.warn(reason)
    editor.notify(s,reason)
}

// The phase as the bar says it.
@(private)
net_play_label :: proc(s:^editor.Session) -> string {
    n:=net_play_of(s)
    if n==nil {return ""}
    switch n.phase {
    case .Idle:     return ""
    case .Waiting:
        if n.role==.Server {return "Serving; opening the network..."}
        return n.scene_ready?"Waiting for the router of the host...":"Waiting for the scene..."
    case .Running:
        if n.role==.Client {return "Playing on the network"}
        if n.party.online==0 {return "Serving the session"}
        return fmt.tprintf("Serving %d online %s",n.party.online,n.party.online==1?"player":"players")
    }
    return ""
}

// The players of Play and how they share it: the screen of this editor, or
// the network, where this editor has one and each other is a process that
// joins its game with the ping it simulates.
@(private)
net_play_menu :: proc(s:^editor.Session) {
    n:=net_play_of(s)
    ctx:=s.gui.ctx
    if n==nil || ctx==nil || s.play_players==nil {return}
    n.party.online=clamp(n.party.online,0,editor.PLAYER_PROCESSES-local_players(s))
    network:=n.party.online>0
    total:=local_players(s)+n.party.online
    labels:=[editor.PLAYER_PROCESSES]string{"1","2","3","4"}
    if chosen:=editor.menu_choices(s,ui.id(ctx,"multiplayer.run_players"),"Players",labels[:],total-1);chosen>=0 {
        if network && chosen>0 {n.party.online=chosen} else {s.play_players.players,n.party.online=chosen+1,0}
    }
    shares:=[2]string{"Split screen","Network"}
    if chosen:=editor.menu_choices(s,ui.id(ctx,"multiplayer.run_share"),"Players share",shares[:],network?1:0);chosen>=0 && (chosen==1)!=network {
        // On the network this editor plays one of them; alone, it plays with one more.
        if chosen==1 {s.play_players.players,n.party.online=1,max(total-1,1)} else {s.play_players.players,n.party.online=total,0}
    }
    ping:=f64(n.party.ping)
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(30),padding={6,2,6,2},gap=8,align_y=.Center}) {
        ui.label(ctx,"Ping ms",ui.metric(ctx,"font_small"),network?ui.tone(ctx,"text"):ui.tone(ctx,"text_faint"),0)
        if ui.number_field(ctx,ui.id(ctx,"multiplayer.run_ping"),&ping,{width=ui.fixed(98),min=0,max=1000,has_min=true,has_max=true,decimals=0,speed=1,disabled=!network}).changed {n.party.ping=int(ping)}
    }
}

// A guest: join the game the host offers, or leave the one it plays.
@(private)
net_play_host_menu :: proc(s:^editor.Session,offered:bool) {
    n:=net_play_of(s)
    ctx:=s.gui.ctx
    if n==nil || ctx==nil {return}
    if n.phase!=.Idle && n.role==.Client {
        if ui.menu_item(ctx,ui.id(ctx,"leave"),"Leave game",{icon=.Stop}) {net_play_stop(s)}
    } else if ui.menu_item(ctx,ui.id(ctx,"join"),"Join game",{icon=ui.icon_user(u8(editor.User_Icon.Connection)),disabled=!offered || n.phase!=.Idle}) {
        // Its player reads the saved files.
        if unsaved:=editor.assets_unsaved_paths(s);len(unsaved)>0 {
            n.pending=.Join
            editor.confirm_open(s,.Play_Plugin,unsaved)
        } else if error:=join(s,n);error!="" {editor.notify(s,error)}
    }
}

// A run whose game is paused keeps its connections.
@(private)
net_play_pump :: proc(w:core.World_Ref,app:^host.App) {
    if session:=host.app_world_storage(app,w.data,multiplayer.Net_Session);session!=nil {multiplayer.pump(session,w,app)}
}

// A turn plays on the network inside the editor: its run serves the game and
// a run per online player joins it, each a World with its own session, which
// advance together with play.step. They wait long for each other: a turn
// advances them only when it asks.
@(private)
net_play_turn :: proc(s:^editor.Session,owner,players,online,ping:int) -> string {
    r:=editor.run_find(s,owner)
    if r==nil {return "The game could not start"}
    port,refused:=net_play_port(s)
    if port==0 {return refused}
    token,made:=wire.invite_token()
    if !made {return "The game could not start: this system gives no secure random bytes to seal the network with"}
    session_open(editor.run_ref(s,r),{server=true,port=port,invite=true,invite_token=token,timeout=NET_PLAY_STEPPED_TIMEOUT})
    code:=wire.invite_encode({lan=wire.address_loopback(port),token=token},context.temp_allocator)
    for player in 1..=online {
        client:=editor.run_create(s,owner,player)
        if client==nil {return "There is no room for another run"}
        editor.run_configure(s,client,1)
        open:=multiplayer.Open_Request{latency=f64(ping)/2000,timeout=NET_PLAY_STEPPED_TIMEOUT,new_player=true}
        base.text_set(open.connect[:],code)
        session_open(editor.run_ref(s,client),open)
    }
    log.infof("network game of an agent: a run serves on port %d with %d online",port,online)
    return ""
}

// What a run opens on the network before its first frame.
@(private)
session_open :: proc(w:core.World_Ref,request:multiplayer.Open_Request) {
    if wanted:=core.world_storage_of(w,multiplayer.Session_Request);wanted!=nil {wanted^={open=request}}
}

// The session of a run ended or did not open, and why.
@(private)
session_failure :: proc(w:core.World_Ref,app:^host.App) -> (reason:string,failed:bool) {
    session:=host.app_world_storage(app,w.data,multiplayer.Net_Session)
    if session==nil || session.status!=.Disconnected {return}
    return session.reason_text,true
}

// The first port, from that of the game (Net_Settings.port), that nothing
// holds; 0 and why without one.
@(private)
net_play_port :: proc(s:^editor.Session) -> (port:int,refused:string) {
    settings:multiplayer.Net_Settings
    if s.app.shared!=nil {
        if stored:=core.world_storage_of(core.world_ref(s.app.shared,s.info,.Shared),multiplayer.Net_Settings);stored!=nil {settings=stored^}
    }
    first,valid:=multiplayer.settings_port(settings)
    if !valid {return 0,fmt.tprintf("Net_Settings.port %d is not a UDP port; give it one from 1 to 65535, or 0 for %d",settings.port,multiplayer.DEFAULT_PORT)}
    for candidate in first..<min(first+NET_PLAY_PORTS,65536) {
        u:wire.Udp
        if wire.udp_open(&u,wire.address_any6(candidate)) {
            wire.udp_close(&u)
            return candidate,""
        }
    }
    return 0,"No port is free for the server"
}

// The code players outside the editor join the game this editor serves with.
@(private)
net_play_invite :: proc(n:^Net_Play) -> string {
    return wire.invite_encode(wire.invite_make(n.invite,n.port,n.mapping_on?&n.mapping:nil),context.temp_allocator)
}
