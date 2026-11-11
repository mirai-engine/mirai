package vfx

import "mirai:core"
import "plugins:vfx/runtime/effect"

// What the particles tell the game: a particle of an effect whose report
// names it that died or hit something. The simulate pass appends it to the
// data channel REPORTS_CHANNEL, read back as the channels a game watches are:
// frames later, without waiting for the GPU. It is presentation alone (a
// decal, a sound, another effect): it is not deterministic nor part of the
// world, so no function of fixed reads it (the generator refuses it), and it
// decides nothing of the game. A frame keeps DATA_ENTRIES of them; the rest
// are lost and counted.

REPORTS_CHANNEL :: u64(0) // the name of the data channel of the reports, which no name hashes to
REPORT_WORDS :: 11        // of an entry: its emitter's slot, Particle_Event, position, velocity, normal

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
    lost:u32,  // of that frame, beyond DATA_ENTRIES
}

particle_reports_free :: proc(reports:^Particle_Reports) {
    delete(reports.reports)
    reports^={}
}

// The reports of the copy of the channel a frame wrote, in the world: their
// places come back from the origin of that frame (data_frame), but those of an
// effect view, which are of the view.
@(private)
reports_take :: proc(reports:^Particle_Reports,pool:^Pool,data:[]u8,frame:u64) {
    if frame==reports.frame || len(data)<16 {return}
    reports.frame=frame
    head:=([^]u32)(raw_data(data))
    count:=min(head[0],DATA_ENTRIES,u32((len(data)-16)/(REPORT_WORDS*4)))
    reports.lost=head[0]-count
    origin:=transmute([3]f32)[3]u32{head[1],head[2],head[3]}
    for row in ([^][REPORT_WORDS]u32)(raw_data(data[16:]))[:count] {
        if int(row[0])>=pool.slot_end || !pool.slots[row[0]].live {continue}
        desc:=&pool.slots[row[0]].desc
        position:=transmute([3]f32)[3]u32{row[2],row[3],row[4]}
        append(&reports.reports,Particle_Report{
            entity=desc.owner,kind=effect.Particle_Event(row[1]),
            position=position+(desc.view==0?origin:[3]f32{}),
            velocity=transmute([3]f32)[3]u32{row[5],row[6],row[7]},normal=transmute([3]f32)[3]u32{row[8],row[9],row[10]},
        })
    }
}
