package game

import "mirai:core"
import rag "plugins:ragdoll/runtime"

@(component)
Ragdoll_Gallery :: struct {auto_cycle:bool}

@(component,derived)
Ragdoll_Gallery_State :: struct {phase:u8,manual:bool}

@(storage,queue)
Ragdoll_Gallery_Requests :: struct {queue:core.Queue(core.Entity)}

ragdoll_gallery_cycle :: proc(requests:^Ragdoll_Gallery_Requests,rig:core.Entity) {
    if requests==nil || rig==core.NONE {return}
    if cap(requests.queue.items)==0 && reserve(&requests.queue.items,32)!=nil {return}
    if len(requests.queue.items)<cap(requests.queue.items) {core.push(&requests.queue,rig)}
}

@(step="fixed")
ragdoll_gallery_update :: proc(gallery:^core.Table(Ragdoll_Gallery,.Read),states:^core.Table(Ragdoll_Gallery_State),configs:^core.Table(rag.Ragdoll),requests:^Ragdoll_Gallery_Requests,time:core.Time,problems:^core.Problems) {
    modes:=[3]rag.Ragdoll_Mode{.Animated,.Driven,.Simulated}
    if core.count(gallery)>0 && reserve(&requests.queue.items,32)!=nil {
        core.report(problems,core.NONE,"demo.ragdoll_requests","out of memory for room for the ragdoll gallery requests; free memory")
    }
    for rig in core.take(&requests.queue) {
        if !core.has(gallery,rig) || !core.has(configs,rig) {continue}
        state:=demo_state(states,rig,Ragdoll_Gallery_State{},problems)
        if state==nil {continue}
        state.manual=true
        state.phase=(state.phase+1)%3
        core.edit(configs,rig).mode=modes[state.phase]
    }
    phase:=u8(int(time.seconds/3)%3)
    for row in 0..<core.count(gallery) {
        if !core.at(gallery,row).auto_cycle || time.dt<=0 || !time.playing {continue}
        e:=core.entity_at(gallery,row)
        state:=core.staged(states,e)
        if state!=nil && state.manual {continue}
        if state==nil {
            if phase==0 {continue}
            state=demo_state(states,e,Ragdoll_Gallery_State{},problems)
        }
        if state==nil || phase==state.phase {continue}
        state.phase=phase
        if config:=core.edit(configs,e);config!=nil {config.mode=modes[phase]}
    }
}
