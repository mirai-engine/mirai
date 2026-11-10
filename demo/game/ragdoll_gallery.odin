package game

import "mirai:core"
import rag "plugins:ragdoll/runtime"

@(component)
Ragdoll_Gallery :: struct {auto_cycle:bool,age:f32 `mirai:"transient"`,phase:u8 `mirai:"transient"`}
@(storage,queue)
Ragdoll_Gallery_Requests :: struct {queue:core.Queue(core.Entity)}

ragdoll_gallery_cycle :: proc(requests:^Ragdoll_Gallery_Requests,rig:core.Entity) {
    if requests==nil || rig==core.NONE {return}
    if cap(requests.queue.items)==0 && reserve(&requests.queue.items,32)!=nil {return}
    if len(requests.queue.items)<cap(requests.queue.items) {core.push(&requests.queue,rig)}
}

@(step="fixed")
ragdoll_gallery_update :: proc(gallery:^core.Table(Ragdoll_Gallery),configs:^core.Table(rag.Ragdoll),requests:^Ragdoll_Gallery_Requests,time:core.Time,problems:^core.Problems) {
    modes:=[3]rag.Ragdoll_Mode{.Animated,.Driven,.Simulated}
    if core.count(gallery)>0 && reserve(&requests.queue.items,32)!=nil {
        core.report(problems,core.NONE,"demo.ragdoll_requests","out of memory for room for the ragdoll gallery requests; free memory")
    }
    for rig in core.take(&requests.queue) {
        state:=core.edit(gallery,rig);config:=core.edit(configs,rig)
        if state==nil || config==nil {continue}
        state.auto_cycle=false;state.phase=(state.phase+1)%3;config.mode=modes[state.phase]
    }
    for row in 0..<core.count(gallery) {
        rig:=core.entity_at(gallery,row);state:=core.edit_at(gallery,row)
        if !state.auto_cycle || time.dt<=0 || !time.playing {continue}
        state.age+=time.dt
        phase:=u8(int(state.age/3)%3)
        if phase==state.phase {continue}
        state.phase=phase
        if config:=core.edit(configs,rig);config!=nil {config.mode=modes[phase]}
    }
}
