package rhi

// Compaction of BLASes. A BLAS made with Blas_Desc.compact has its compacted
// size written by the GPU right after its build, in a slot of a table of
// COMPACT_SLOTS; cmd_compact_blases reads it once the frame that built it is
// done and, when it saves enough, copies the structure into a range of that
// size and lets the old one go. The handle and the id stay; the address
// changes, so a TLAS that names the BLAS is to be built again in the same
// list. Every backend does the same with the same calls.
COMPACT_SLOTS :: 4096
// What a compacted copy has to save of a structure to be made.
COMPACT_SAVING :: 0.9

// A slot of the table of compacted sizes + 1; 0 when they are all waiting or
// there is no memory for the list of the free ones.
@(private)
compact_slot_take :: proc(d: ^Device) -> i32 {
	if d.compact_free == nil {
		free, error := make([dynamic]u32, 0, COMPACT_SLOTS, d.allocator)
		if error != nil {return 0}
		d.compact_free = free
		for i := COMPACT_SLOTS - 1; i >= 0; i -= 1 {append(&d.compact_free, u32(i))}
	}
	if len(d.compact_free) == 0 {return 0}
	return i32(pop(&d.compact_free)) + 1
}

@(private)
compact_slot_give :: proc(d: ^Device, slot: i32) {
	if slot > 0 {append(&d.compact_free, u32(slot - 1))}
}

// Whether the size a list wrote at frame can be read: the list ran alone and
// was waited for (immediate), or MAX_FRAMES_IN_FLIGHT frames went by since.
@(private)
compact_ready :: proc "contextless" (d: ^Device, frame: u64, immediate: bool) -> bool {
	return immediate || d.frame_number >= frame + MAX_FRAMES_IN_FLIGHT
}
