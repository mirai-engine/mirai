package rhi

import "base:runtime"
import "core:thread"

@(private)
Thread_Create_Error :: enum u8 {
	None,
	Out_Of_Memory, // the allocator of the device refused the memory of the thread
	Not_Started, // the system did not create it
}

@(private)
Thread_Memory :: struct {
	owner:   runtime.Allocator,
	refused: bool,
}

// A thread of the device, not started yet, whose memory and context allocator
// are those of the device. thread.create answers nil alone, so the requests it
// makes go through the allocator here, which tells a refusal of the device's
// allocator apart from one of the system. thread_name_buffer: unnamed, since a
// new Odin thread makes the buffer of its name from its context allocator and
// goes out of bounds when that allocator refuses it (docs/ODIN_WORKAROUNDS.md).
@(private)
device_thread_create :: proc(d: ^Device, procedure: thread.Thread_Proc, data: rawptr) -> (^thread.Thread, Thread_Create_Error) {
	memory := Thread_Memory{owner = d.allocator}
	previous := context.allocator
	context.allocator = runtime.Allocator{thread_memory_proc, &memory}
	worker := thread.create(procedure)
	context.allocator = previous
	if worker == nil {return nil, .Out_Of_Memory if memory.refused else .Not_Started}
	worker.creation_allocator = d.allocator
	worker.data = data
	worker.init_context = runtime.Context{allocator = d.allocator}
	return worker, .None
}

@(private)
thread_memory_proc :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, runtime.Allocator_Error) {
	memory := cast(^Thread_Memory)data
	bytes, error := memory.owner.procedure(memory.owner.data, mode, size, alignment, old_memory, old_size, loc)
	if error == .Out_Of_Memory {memory.refused = true}
	return bytes, error
}

// What the error of the device says after the start of what failed.
@(private)
thread_create_text :: proc(error: Thread_Create_Error) -> string {
	return "out of memory" if error == .Out_Of_Memory else "the system refused it"
}
