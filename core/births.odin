package core

// Births of effects by channel, for whoever draws them without knowing who
// asks: the library that asks pushes them to the queue, and the one that draws
// effects (vfx) takes them in the next fixed step and starts, at each, the
// particles of the emitters that listen to its channel. A birth to a channel
// nobody listens to is let go.

// A channel of births: an id with a name declared in code (core/names.odin).
// The engine and its plugins declare theirs below CHANNEL_GAME, a game its own
// from it: CHANNEL_IMPACTS :: core.Birth_Channel(16).
@(names="CHANNEL_")
Birth_Channel :: distinct u16
CHANNEL_NONE :: Birth_Channel(0)
CHANNEL_GAME :: 16 // the first value of a channel of a game

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
