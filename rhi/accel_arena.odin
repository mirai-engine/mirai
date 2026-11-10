package rhi

// Acceleration structures live in ranges of large blocks of GPU memory (a
// buffer on Vulkan, a placement heap on Metal), not in an object of their own
// each: a world of thousands of BLASes would otherwise take as many buffers.
// A block holds ACCEL_BLOCK_BYTES, or one structure larger than that. A range
// freed goes back to its block once the GPU finished the frames that could
// use it (the deferred deletions of the backend); a block left empty goes.
ACCEL_BLOCK_BYTES :: u64(64) << 20
// Every range starts on this many bytes, which both backends take.
ACCEL_ALIGNMENT :: u64(256)

// The size of the block that takes a structure of size bytes.
@(private)
accel_block_size :: proc "contextless" (size: u64) -> u64 {return max(ACCEL_BLOCK_BYTES, align_up(size, ACCEL_ALIGNMENT))}

// The GPU memory of the acceleration structures of a device: the blocks it
// holds and what its structures take of them, in bytes.
accel_memory :: proc(d: ^Device) -> (held, used: u64) {return arena_bytes(&d.accel_arena)}
