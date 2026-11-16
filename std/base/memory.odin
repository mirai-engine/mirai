package base

// The memory of the machine, as the system counts it now: its physical
// memory and how much of it can be taken without making others page out,
// in bytes. ok is false when the system does not say.
memory_stats :: proc "contextless" () -> (total,available:i64,ok:bool) {
    return _memory_stats()
}
