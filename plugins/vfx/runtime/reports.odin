package vfx

import "mirai:core"
import erender "mirai:engine/render"
import "plugins:vfx/runtime/effect"

// What the particles tell the game: a particle of an effect whose report
// names it that died or hit something, written by the GPU and read back
// frames later without waiting for it. It is presentation alone (a decal, a
// sound, another effect): it is not deterministic nor part of the world, so
// no function of fixed reads it (the generator refuses it), and it decides
// nothing of the game. A frame keeps REPORT_CAPACITY of them; the rest are
// lost and counted.

REPORT_CAPACITY :: 1024

Particle_Report :: struct {
    entity:core.Entity,         // the emitter, or the one whose sub effect it is
    kind:effect.Particle_Event, // Death or Collision
    position,velocity,normal:[3]f32, // normal: of what it hit
}

// The reports of the frame the GPU finished last: each comes once, in the
// frame after particles_sync reads it.
@(storage,host,by_world,presentation,free="particle_reports_free")
Particle_Reports :: struct {
    reports:[dynamic]Particle_Report,
    frame:u64, // of the renderer, + 1, the reports are of; 0: none yet
    lost:u32,  // of that frame, beyond REPORT_CAPACITY
}

particle_reports_free :: proc(reports:^Particle_Reports) {
    delete(reports.reports)
    reports^={}
}

// shaders/particles.slang: the reports after the events.
Gpu_Report :: struct {
    position:[3]f32, slot:u32,
    velocity:[3]f32, kind:u32,
    normal:[3]f32, pad:u32,
}
#assert(size_of(Gpu_Report)==48)

// What comes before the reports of a frame: how many the GPU wrote, and the
// origin of the renderer their places are relative to.
Reports_Head :: struct {
    count:u32,
    origin:[3]f32,
}
#assert(size_of(Reports_Head)==16)

REPORTS_AT :: EVENTS_AT+2*EVENT_CAPACITY*size_of(Gpu_Event) // bytes of the events buffer before the reports
REPORTS_BYTES :: size_of(Reports_Head)+REPORT_CAPACITY*size_of(Gpu_Report)

@(private)
reports_readback :: proc "contextless" () -> erender.Buffer_Desc {return {"vfx particle reports",REPORTS_BYTES}}

// The reports the GPU brought back since the last frame, by the entity of
// their emitter.
@(private)
reports_read :: proc(reports:^Particle_Reports,sync:^Particle_Sync,renderer:^erender.Renderer,id:core.World_Id) {
    clear(&reports.reports)
    data,frame,ok:=erender.readback(renderer,id,reports_readback().name)
    if !ok || frame==reports.frame {return}
    reports.frame=frame
    reports_take(reports,&sync.pool,data)
}

// The reports of the bytes the GPU wrote, in the world: their places come
// back from the origin of their frame, but those of an effect view, which are
// of the view.
@(private)
reports_take :: proc(reports:^Particle_Reports,pool:^Pool,data:[]u8) {
    if len(data)<size_of(Reports_Head) {return}
    head:=(cast(^Reports_Head)raw_data(data))^
    count:=min(head.count,REPORT_CAPACITY,u32((len(data)-size_of(Reports_Head))/size_of(Gpu_Report)))
    reports.lost=head.count-count
    rows:=([^]Gpu_Report)(rawptr(uintptr(raw_data(data))+size_of(Reports_Head)))[:count]
    for &row in rows {
        if int(row.slot)>=pool.slot_end || !pool.slots[row.slot].live {continue}
        desc:=&pool.slots[row.slot].desc
        append(&reports.reports,Particle_Report{
            entity=desc.owner,kind=effect.Particle_Event(row.kind),
            position=row.position+(desc.view==0?head.origin:[3]f32{}),velocity=row.velocity,normal=row.normal,
        })
    }
}

// The particles of the emitter the editor watches (Particle_Sync.watch),
// copied back each frame: the slots of its range, at most WATCH_MAX, and the
// Attributes of their program. Debugging alone: nothing of the game reads them.
WATCH_MAX :: 1024

@(private)
watch_readback :: proc "contextless" (attributes:bool,bytes:u64) -> erender.Buffer_Desc {
    return {"vfx watched attributes" if attributes else "vfx watched particles",max(bytes,16)}
}

@(private)
watch_copy :: proc(sync:^Particle_Sync,pass:^erender.Pass) {
    pool:=&sync.pool
    if sync.watch==0 {return}
    at:=pool_slot_find(pool,sync.watch)
    if at<0 {return}
    s:=&pool.slots[at]
    count:=min(s.capacity,WATCH_MAX)
    erender.pass_readback(pass,pool_buffer(pool,.Particles),u64(s.offset)*size_of(Gpu_Particle),watch_readback(false,u64(count)*size_of(Gpu_Particle)))
    if s.stride>0 {erender.pass_readback(pass,pool_buffer(pool,.Data),u64(ATTRIBUTES_AT+s.attributes),watch_readback(true,u64(count)*u64(s.stride)))}
    erender.pass_readback(pass,pool_buffer(pool,.State),u64(at)*size_of(Gpu_State),{"vfx watched state",size_of(Gpu_State)})
}

// A particle of the watched emitter as the GPU had it some frames ago, and the words of its Attributes.
Watched_Particle :: struct {
    slot:u32,
    position,velocity:[3]f32,
    age,lifetime,size:f32,
    seed:u32,
    attributes:[]u32,
}

// The counters of the watched emitter as the GPU had them: free slots, births of a frame and all
// it started, of a program that gives its births.
watched_state :: proc(sync:^Particle_Sync,renderer:^erender.Renderer) -> (state:Gpu_State,ok:bool) {
    data,_,read:=erender.readback(renderer,sync.world_id,"vfx watched state")
    if !read || len(data)<size_of(Gpu_State) {return}
    return (^Gpu_State)(raw_data(data))^,true
}

// The living particles of the watched emitter, from what the GPU copied back.
watched :: proc(sync:^Particle_Sync,renderer:^erender.Renderer,allocator:=context.temp_allocator) -> (list:[]Watched_Particle,frame:u64,ok:bool) {
    at:=pool_slot_find(&sync.pool,sync.watch)
    if sync.watch==0 || at<0 {return}
    data,copied,read:=erender.readback(renderer,sync.world_id,watch_readback(false,0).name)
    if !read || len(data)<size_of(Gpu_Particle) {return}
    words,_,_:=erender.readback(renderer,sync.world_id,watch_readback(true,0).name)
    stride:=int(sync.pool.slots[at].stride)
    // In the world, as the reports: those local to their emitter or of an effect view keep their places.
    desc:=&sync.pool.slots[at].desc
    origin:=desc.local || desc.view!=0?[3]f32{}:sync.pool.origin
    rows:=([^]Gpu_Particle)(raw_data(data))[:len(data)/size_of(Gpu_Particle)]
    out:=make([dynamic]Watched_Particle,allocator)
    for row,slot in rows {
        if !(row.lifetime>0) {continue}
        p:=Watched_Particle{slot=u32(slot),position=row.position+origin,velocity=row.velocity,age=row.age,lifetime=row.lifetime,size=row.size,seed=row.seed}
        if stride>0 && (slot+1)*stride<=len(words) {p.attributes=([^]u32)(raw_data(words[slot*stride:]))[:stride/4]}
        append(&out,p)
    }
    return out[:],copied,true
}
