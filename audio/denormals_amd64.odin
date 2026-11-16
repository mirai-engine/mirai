#+build amd64
package mirai_audio

import "core:simd/x86"

// MXCSR: DAZ (bit 6) reads a subnormal input as zero, FTZ (bit 15) writes one as zero.
@(private) MXCSR_FLUSH :: u32(1<<6|1<<15)

// Subnormal floats count as zero on this thread until denormals_restore: a delay
// line or a filter that rings down to silence passes through them, and x86 takes
// on the order of a hundred cycles per operation on one.
@(private,enable_target_feature="sse")
denormals_flush :: proc "contextless" () -> (previous:u64) {
    mode:=x86._mm_getcsr()
    x86._mm_setcsr(mode|MXCSR_FLUSH)
    return u64(mode)
}
@(private,enable_target_feature="sse")
denormals_restore :: proc "contextless" (previous:u64) {x86._mm_setcsr(u32(previous))}
