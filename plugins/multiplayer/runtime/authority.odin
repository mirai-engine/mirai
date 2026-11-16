package multiplayer

import "mirai:core"

// The role of this end as the session has it. core.Remote is on what
// another end decides: on a server, what a client holds now
// (Simulation.Lent), which server_commands keeps as the holder changes; on a
// client, the replicas it neither predicts nor holds, which
// replica_components keeps as their roles change. What the server simulates
// and a client predicts the server decides. A new role starts it again.
@(private)
authority_follow :: proc(s:^Net_Session,w:core.World_Ref) {
    network:=core.world_storage_of(w,core.Network)
    if network==nil {return}
    role:=!s.host_ready?core.Network_Role.Standalone:s.mode==.Server?.Server:.Client
    if network.role==role {return}
    network.role=role
    if remotes:=core.world_table_of(w,core.Remote);remotes!=nil {
        for row:=core.count(remotes)-1;row>=0;row-=1 {core.remove(remotes,core.entity_at(remotes,row))}
    }
}

@(private)
remote_set :: proc(remotes:^core.Table(core.Remote),e:core.Entity,remote:bool) {
    has:=core.has(remotes,e)
    if remote && !has {core.add(remotes,e,core.Remote{})} else if !remote && has {core.remove(remotes,e)}
}
