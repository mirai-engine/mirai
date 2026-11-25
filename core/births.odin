package core

import "mirai:std/base"

// Births of effects by channel, for whoever shows them without knowing who
// asks: any function that writes Births pushes to its log with birth, and
// what shows effects (vfx) reads what came since it last ran and reports
// those that found no room. A birth nobody reads ages out with the log.

// A channel of births is a name (birth_channel): whoever pushes and whoever
// listens say the same text, as the data channels of vfx are named, and
// nobody hands out ids. 0: none.
Birth_Channel :: distinct u64
CHANNEL_NAME_BYTES :: 32 // of a name a component keeps

birth_channel :: proc "contextless" (name:string) -> Birth_Channel {
    return name=="" ? 0 : Birth_Channel(base.name_hash(name))
}

// count particles at position, with velocity besides the one their effect
// gives them, color and size multiplying theirs, and values its programs read
// (Mirai_Vfx_Context.values). by: the entity that causes it, which tells it
// apart from another birth of its tick when a rollback runs the tick again;
// NONE for an effect of the world, told apart by its place.
Birth :: struct {
    channel:Birth_Channel,
    by:Entity,
    position:[3]f32 `mirai:"unit=m"`,
    normal:[3]f32, // zero: no surface alignment
    velocity:[3]f32 `mirai:"unit=m/s"`,
    color:[4]f32 `mirai:"color"`, // zero: white
    size:f32,                     // 0: 1
    count:u32,                    // 0: one
    values:[4]f32,
}

// Births the log holds: those of the frame before and of every tick of this
// one, until the end of the frame ages them.
BIRTHS_CAPACITY :: 4096

@(storage,shared)
Births :: struct {
    log:Events(Birth),
}

// Pushes b, in a fixed step so a rollback repeats it (the reader does not draw
// it twice). False when the log is full or without memory: b is counted in
// log.lost, which the reader reports.
birth :: proc(births:^Births,b:Birth) -> bool {
    if cap(births.log.items)<BIRTHS_CAPACITY && reserve(&births.log.items,BIRTHS_CAPACITY)!=nil {
        births.log.lost+=1
        return false
    }
    return events_push(&births.log,b,BIRTHS_CAPACITY)
}
