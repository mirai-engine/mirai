package core

import "mirai:std/base"

// Births of effects by channel, for whoever draws them without knowing who
// asks: the library that asks pushes them to the queue, and the one that draws
// effects (vfx) takes them in the next fixed step and starts, at each, the
// particles of the emitters that listen to its channel. A birth to a channel
// nobody listens to is let go.

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
// (Mirai_Vfx_Context.values).
Birth :: struct {
    channel:Birth_Channel,
    position:[3]f32 `mirai:"unit=m"`,
    velocity:[3]f32 `mirai:"unit=m/s"`,
    color:[4]f32 `mirai:"color"`, // zero: white
    size:f32,                     // 0: 1
    count:u32,                    // 0: one
    values:[4]f32,
}

@(storage,queue)
Births :: struct {
    queue:Queue(Birth),
}
