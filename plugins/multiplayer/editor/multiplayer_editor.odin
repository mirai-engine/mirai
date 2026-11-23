package multiplayer_editor

import "core:fmt"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:host"
import wire "mirai:net"
import "mirai:std/base"
import multiplayer "plugins:multiplayer/runtime"

// What the network gives the editor: Play on the network (network_play.odin),
// its preferences and its methods of the API.

Api_Network_Result :: struct {
    phase:Net_Play_Phase `mirai:"label=Waiting: the server of Play to listen before its online players start (poll play.network.status); a guest for the scene of the host, or for its router to map the port when it plays from outside its network"`,
    role:Net_Play_Role `mirai:"label=Server: this editor serves the game; Client: a guest plays the game of the host"`,
    players,online,ping_ms,port:int,
    game:u32,
    processes:int `mirai:"label=Player processes alive"`,
    invite:[wire.INVITE_TEXT_BYTES+1]u8 `mirai:"text,label=The code of the invitation of the server: players outside the editor join with it"`,
    reason:[128]u8 `mirai:"text,label=Why the last game ended"`,
    run:Api_Network_Run `mirai:"label=The network of the run the call reads: what it predicts and corrects"`,
}

Api_Network_Status_Params :: struct {
    player:int `mirai:"optional,min=0,max=3,label=0: the run of the call (that of its turn, or the Play of the user); more: that online player of the network game of the turn, a client that predicts"`,
}

Api_Network_Role :: enum u8 {
    Local, // no network: Play alone, or no run
    Server,
    Client,
}

// The network of a run as it stands now.
Api_Network_Run :: struct {
    run:u64 `mirai:"label=The run read, as play.history takes it; 0 without one"`,
    tick:u64,
    role:Api_Network_Role `mirai:"label=Local: the run plays without a network, or there is no run"`,
    status:multiplayer.Status,
    connections:int,
    links:[]Api_Network_Link `mirai:"label=A server: each connection; a client: the one to its server"`,
    confirmed:u64 `mirai:"label=Client: comparisons in which every state of the server matched the prediction"`,
    corrections:u64 `mirai:"label=Client: states of the server that differed from the prediction of their tick"`,
    rollbacks:u64 `mirai:"label=Client: times the world went back and ran again"`,
    resimulated:u64 `mirai:"label=Client: ticks simulated again by them"`,
    largest_resimulation:int `mirai:"label=Client: most ticks one rollback ran again"`,
    placed:u64 `mirai:"label=Client: replicas put where the server had them, for the world could not go back"`,
    deferred:u64 `mirai:"label=Client: corrections out of the history, the frame or the budget"`,
    recent_resimulations:[]Api_Network_Resimulation `mirai:"label=The newest rollbacks, newest first"`,
    recent_corrections:[]Api_Network_Correction `mirai:"label=The newest states that differed, newest first"`,
}

Api_Network_Link :: struct {
    connection:u64,
    rtt_ms,jitter_ms:f32,
    loss:f32 `mirai:"label=Share of the datagrams sent found lost, smoothed"`,
}

Api_Network_Resimulation :: struct {
    from:u32 `mirai:"label=The first tick run again"`,
    to:u32 `mirai:"label=The present then"`,
    ticks:int,
}

Api_Network_Correction :: struct {
    tick:u32 `mirai:"label=Server tick of the state that differed"`,
    entity:core.Entity,
    name:string `mirai:"label=Its path of names; empty once it is gone"`,
    field:string `mirai:"label=Position, Rotation, Scale, Linear, Angular, or the replicated component that differed"`,
    magnitude:f32 `mirai:"label=m, rad, m/s or rad/s apart; for a component, the quantized words that differ"`,
    placed:bool `mirai:"label=The world could not go back for it: the replica took the state in the present"`,
}

@(private)
net_play_api_register :: proc(s:^editor.Session) {
    editor.api_method_register(s,{result=type_info_of(Api_Network_Result),name="play.join",summary="A guest of the session joins the game its host serves on the network with a player of its own, on the scene the server runs. Outside a turn only.",run=api_play_join})
    editor.api_method_register(s,{name="play.network.status",summary="The state of the game on the network, also inside a turn: the network game of the editor, and the links, rollbacks and recent corrections of the prediction of the run of the call or of one of its online players.",params=type_info_of(Api_Network_Status_Params),result=type_info_of(Api_Network_Result),flags={.Read_Only},run=api_play_network_status})
}

@(private)
api_network_result :: proc(s:^editor.Session,call:^api.Call,player:=0) {
    r:=api.call_result(call,Api_Network_Result)
    if run,_:=editor.api_play_run(s,call,player);run!=nil {
        w:=editor.run_ref(s,run)
        api_network_run(&r.run,w,host.app_world_storage(s.app,run.world,multiplayer.Net_Session),call.allocator)
        r.run.run=run.id
    }
    n:=net_play_of(s)
    if n==nil {return}
    r.phase,r.role,r.players,r.online,r.ping_ms,r.port,r.game=n.phase,n.role,local_players(s),n.party.online,n.party.ping,n.port,n.serial
    r.processes=editor.player_processes_alive(s)
    if n.phase!=.Idle {
        invite:=net_play_invite(n)
        if n.role==.Client {invite,_,_,_=host_game(s)}
        base.text_set(r.invite[:],invite)
    }
    base.text_set(r.reason[:],base.text_get(n.reason[:]))
}

@(private)
api_play_join :: proc(s:^editor.Session,call:^api.Call) {
    if editor.ai_task_of_call(s,call)!=0 {
        api.call_fail(call,api.SERVER_ERROR,"A turn plays its own run with play.start; a network game opens windows for the user")
        return
    }
    n:=net_play_of(s)
    if n==nil {return}
    if error:=join(s,n);error!="" {
        api.call_fail(call,api.SERVER_ERROR,error)
        return
    }
    api_network_result(s,call)
}

@(private)
api_play_network_status :: proc(s:^editor.Session,call:^api.Call) {
    api_network_result(s,call,api.call_params(call,Api_Network_Status_Params).player)
}

// What the session of a world says of its links and its prediction; a world
// without one plays locally.
@(private)
api_network_run :: proc(r:^Api_Network_Run,w:core.World_Ref,session:^multiplayer.Net_Session,allocator:=context.allocator) {
    if w.data!=nil {
        if t:=core.world_storage_of(w,core.Time);t!=nil {r.tick=t.tick}
    }
    if session==nil {return}
    r.status=session.status
    if session.status!=.Offline {r.role=session.mode==.Server?.Server:.Client}
    r.connections=session.connections
    stats:=&session.stats
    d:=&session.diagnostics
    r.confirmed,r.corrections,r.rollbacks,r.resimulated=stats.confirmed,d.correction_count,stats.corrected,stats.resimulated
    r.largest_resimulation,r.placed,r.deferred=stats.largest_resimulation,stats.placed,stats.deferred
    held:[16]multiplayer.Link_Stats
    seen:=multiplayer.links(session,held[:])
    r.links=make([]Api_Network_Link,len(seen),allocator)
    for link,k in seen {r.links[k]={connection=u64(link.connection),rtt_ms=link.rtt*1000,jitter_ms=link.jitter*1000,loss=link.loss}}
    ran:[multiplayer.RESIMULATIONS_KEPT]multiplayer.Resimulation
    resimulations:=multiplayer.resimulations_recent(d,ran[:])
    r.recent_resimulations=make([]Api_Network_Resimulation,len(resimulations),allocator)
    for x,k in resimulations {r.recent_resimulations[k]={from=x.from,to=x.to,ticks=x.ticks}}
    kept:[multiplayer.CORRECTIONS_KEPT]multiplayer.Correction
    corrections:=multiplayer.corrections_recent(d,kept[:])
    r.recent_corrections=make([]Api_Network_Correction,len(corrections),allocator)
    for c,k in corrections {
        out:=&r.recent_corrections[k]
        out^={tick=c.tick,entity=c.entity,magnitude=c.magnitude,placed=c.placed}
        if w.data!=nil && core.alive(core.world_entities(w),c.entity) {out.name=editor.api_entity_path(w,c.entity,allocator)}
        out.field=fmt.aprint(c.field,allocator=allocator)
        if c.field==.Component && w.info!=nil && c.table>=0 && int(c.table)<len(w.info.tables) {out.field=w.info.tables[c.table].name}
    }
}
