package vfx_editor

import "mirai:editor"
import erender "mirai:engine/render"
import "mirai:host"
import vfx "plugins:vfx/runtime"

// The particles of the emitter particle.instance.inspect looks at (Vfx_Editor.watch),
// copied back each frame: the slots of its range, at most WATCH_MAX, the Attributes of
// their program and its counters. Debugging alone: a game binary has none of it.
WATCH_MAX :: 1024

@(private)
watch_ask :: proc(s:^editor.Session,v:^Vfx_Editor) {
    v.watched=nil
    if v.watch==0 || s.app==nil {return}
    v.watched=host.app_world_storage(s.app,s.edit_world,vfx.Particle_Sync)
    if v.watched!=nil {erender.frame_pass(s.app.renderer,.Simulate,watch_copy,v)}
}

@(private)
watch_readback :: proc "contextless" (attributes:bool,bytes:u64) -> erender.Buffer_Desc {
    return {"vfx watched attributes" if attributes else "vfx watched particles",max(bytes,16)}
}

@(private)
watch_copy :: proc(pass:^erender.Pass,user:rawptr) {
    v:=cast(^Vfx_Editor)user
    sync:=v.watched
    if sync==nil || pass.world!=sync.world {return}
    pool:=&sync.pool
    at:=vfx.pool_slot_find(pool,v.watch)
    if at<0 {return}
    s:=&pool.slots[at]
    count:=min(s.capacity,WATCH_MAX)
    erender.pass_readback(pass,vfx.pool_buffer(pool,.Particles),u64(s.offset)*size_of(vfx.Gpu_Particle),watch_readback(false,u64(count)*size_of(vfx.Gpu_Particle)))
    if s.stride>0 {erender.pass_readback(pass,vfx.pool_buffer(pool,.Data),u64(vfx.ATTRIBUTES_AT+s.attributes),watch_readback(true,u64(count)*u64(s.stride)))}
    erender.pass_readback(pass,vfx.pool_buffer(pool,.State),u64(at)*size_of(vfx.Gpu_State),{"vfx watched state",size_of(vfx.Gpu_State)})
}

// A particle of the watched emitter as the GPU had it some frames ago, and the words of its Attributes.
@(private)
Watched_Particle :: struct {
    slot:u32,
    position,velocity:[3]f32,
    age,lifetime,size:f32,
    seed:u32,
    attributes:[]u32,
}

// The counters of the watched emitter as the GPU had them: free slots, births of a frame and all
// it started, of a program that gives its births.
@(private)
watched_state :: proc(sync:^vfx.Particle_Sync,renderer:^erender.Renderer) -> (state:vfx.Gpu_State,ok:bool) {
    data,_,read:=erender.readback(renderer,sync.world_id,"vfx watched state")
    if !read || len(data)<size_of(vfx.Gpu_State) {return}
    return (^vfx.Gpu_State)(raw_data(data))^,true
}

// The living particles of the watched emitter, from what the GPU copied back.
@(private)
watched :: proc(sync:^vfx.Particle_Sync,watch:u64,renderer:^erender.Renderer,allocator:=context.temp_allocator) -> (list:[]Watched_Particle,frame:u64,ok:bool) {
    at:=vfx.pool_slot_find(&sync.pool,watch)
    if watch==0 || at<0 {return}
    data,copied,read:=erender.readback(renderer,sync.world_id,watch_readback(false,0).name)
    if !read || len(data)<size_of(vfx.Gpu_Particle) {return}
    words,_,_:=erender.readback(renderer,sync.world_id,watch_readback(true,0).name)
    stride:=int(sync.pool.slots[at].stride)
    // In the world, as the reports: those local to their emitter or of an effect view keep their places.
    desc:=&sync.pool.slots[at].desc
    origin:=desc.local || desc.view!=0?[3]f32{}:sync.pool.origin
    rows:=([^]vfx.Gpu_Particle)(raw_data(data))[:len(data)/size_of(vfx.Gpu_Particle)]
    out:=make([dynamic]Watched_Particle,allocator)
    for row,slot in rows {
        if !(row.lifetime>0) {continue}
        p:=Watched_Particle{slot=u32(slot),position=row.position+origin,velocity=row.velocity,age=row.age,lifetime=row.lifetime,size=row.size,seed=row.seed}
        if stride>0 && (slot+1)*stride<=len(words) {p.attributes=([^]u32)(raw_data(words[slot*stride:]))[:stride/4]}
        append(&out,p)
    }
    return out[:],copied,true
}
