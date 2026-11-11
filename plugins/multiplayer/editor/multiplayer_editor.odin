package multiplayer_editor

import "mirai:editor"
import "mirai:editor/api"
import "mirai:std/base"

// What the network gives the editor: Play on the network (network_play.odin),
// its preferences and its methods of the API.

Api_Network_Result :: struct {
    phase:Net_Play_Phase `mirai:"label=Waiting: the server of Play to listen before its online players start (poll play.network.status); a guest for the scene of the host, or for its router to map the port when it plays from outside its network"`,
    role:Net_Play_Role `mirai:"label=Server: this editor serves the game; Client: a guest plays the game of the host"`,
    players,online,ping_ms,port:int,
    game:u32,
    processes:int `mirai:"label=Player processes alive"`,
    invite:[48]u8 `mirai:"text,label=The code of the invitation of the server: players outside the editor join with it"`,
    reason:[128]u8 `mirai:"text,label=Why the last game ended"`,
}

@(private)
net_play_api_register :: proc(s:^editor.Session) {
    editor.api_method_register(s,{result=type_info_of(Api_Network_Result),name="play.join",summary="A guest of the session joins the game its host serves on the network with a player of its own, on the scene the server runs. Outside a turn only.",run=api_play_join})
    editor.api_method_register(s,{name="play.network.status",summary="The state of the game on the network.",result=type_info_of(Api_Network_Result),flags={.Read_Only},run=api_play_network_status})
}

@(private)
api_network_result :: proc(s:^editor.Session,call:^api.Call) {
    r:=api.call_result(call,Api_Network_Result)
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
api_play_network_status :: proc(s:^editor.Session,call:^api.Call) {api_network_result(s,call)}
