package base

// Random generator with explicit state: PCG32 (XSH-RR 64/32). 16 bytes of
// plain data, integer arithmetic only: the same sequence for a seed on every
// platform. A zeroed Rng runs, but its first two outputs are 0: seed with
// rng_make. Ranges and distributions are in std/math.
Rng :: struct {
    state:u64,
    stream:u64, // increment of the generator; generators with different streams never share a sequence
}

rng_make :: proc "contextless" (seed:u64,stream:u64=0) -> Rng {
    r:=Rng{0,stream<<1|1}
    rng_u32(&r)
    r.state+=seed
    rng_u32(&r)
    return r
}
rng_u32 :: #force_inline proc "contextless" (r:^Rng) -> u32 {
    old:=r.state
    r.state=old*6364136223846793005+(r.stream|1)
    shifted:=u32(((old>>18)~old)>>27)
    rotation:=u32(old>>59)
    return shifted>>rotation|shifted<<((32-rotation)&31)
}
rng_u64 :: #force_inline proc "contextless" (r:^Rng) -> u64 {
    high:=u64(rng_u32(r))
    return high<<32|u64(rng_u32(r))
}
