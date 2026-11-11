#+build arm64
package mirai_audio

// FPCR.FZ (bit 24): a subnormal input or result is zero.
@(private) FPCR_FZ :: u64(1<<24)

@(private,default_calling_convention="none")
foreign _ {
    @(link_name="llvm.aarch64.get.fpcr") fpcr_get :: proc() -> u64 ---
    @(link_name="llvm.aarch64.set.fpcr") fpcr_set :: proc(value:u64) ---
}

// Subnormal floats count as zero on this thread until denormals_restore: a delay
// line or a filter that rings down to silence passes through them.
@(private)
denormals_flush :: proc "contextless" () -> (previous:u64) {
    previous=fpcr_get()
    fpcr_set(previous|FPCR_FZ)
    return
}
@(private)
denormals_restore :: proc "contextless" (previous:u64) {fpcr_set(previous)}
