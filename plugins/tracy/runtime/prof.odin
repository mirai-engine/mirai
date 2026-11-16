// A client of the Tracy profiler, in Odin: the application listens on a port
// and the profiler (tracy-profiler, tracy-capture) connects to it to receive
// frame marks, CPU zones and GPU zones over the LZ4-framed queue of the Tracy
// protocol 0.14 (tracy_protocol.odin, tracy_transport.odin). It is polled
// once per frame and never waits for the network.
package tracy

import "core:time"

MAX_GPU_CONTEXTS :: 16

// What one record takes in the queue, for profiler_reserve.
CPU_ZONE_BEGIN_BYTES :: 1 + ZONE_BEGIN_SIZE
CPU_ZONE_END_BYTES :: 1 + ZONE_END_SIZE
THREAD_CONTEXT_BYTES :: 1 + THREAD_CONTEXT_SIZE
GPU_TIMING_BYTES :: 2 * (1 + GPU_TIME_SIZE) + 1 + GPU_ZONE_BEGIN_SIZE + 1 + GPU_ZONE_END_SIZE

// A GPU queue or device. `ctx` is the id Tracy uses in its records. `name`
// must outlive the profiler, as a literal does.
Gpu_Context :: struct {
	type:       Gpu_Context_Type,
	ctx:        u8,
	name:       string,
	created_ns: i64,
}

Profiler :: struct {
	contexts:       [MAX_GPU_CONTEXTS]Gpu_Context,
	context_count:  int,
	gpu_query_next: [MAX_GPU_CONTEXTS]u16,
	client:         Tracy_Client,
}

// Listens for a profiler on the first free port from `port` (0: one the OS
// picks), on the loopback interface unless any_address.
profiler_init :: proc(p: ^Profiler, port: int = SERVER_PORT, program_name: string = "Mirai", any_address := false, allocator := context.allocator) -> bool {
	p^ = {}
	return tracy_client_init(&p.client, port, program_name, allocator, any_address)
}

// Ends the session: Terminate, then the answers the server still asks for
// while it finishes the trace, for at most answer_ms or until it hangs up.
profiler_shutdown :: proc(p: ^Profiler, answer_ms := 200) {
	if p == nil {return}
	c := &p.client
	if c.connected {
		terminate: [1]u8
		if written, ok := write_terminate(terminate[:]); ok {_ = tracy_client_append(c, terminate[:written])}
		for _ in 0 ..< answer_ms {
			if !tracy_client_flush(c) {break}
			time.sleep(time.Millisecond)
		}
	}
	tracy_client_shutdown(c)
	p^ = {}
}

// Pumps the transport: accepts a profiler, completes the handshake, sends and
// answers. A new session starts with a ThreadContext and every context.
profiler_poll :: proc(p: ^Profiler) {
	if p == nil || !p.client.listener_valid {return}
	if tracy_client_poll(&p.client) {
		ready := tracy_client_force_thread(&p.client, TRACY_THREAD_ID)
		for i in 0 ..< p.context_count {
			if !ready {break}
			ready = tracy_client_emit_context(&p.client, &p.contexts[i])
		}
		for &next in p.gpu_query_next {next = 0}
		p.client.session_ready = ready
	}
}

// Registers a GPU context, sent now in a live session and at the start of
// every later one. False when the table is full.
profiler_gpu_context :: proc(p: ^Profiler, type: Gpu_Context_Type, name: string = "") -> (Gpu_Context, bool) {
	if p == nil || p.context_count >= MAX_GPU_CONTEXTS {return {}, false}
	gpu_ctx := Gpu_Context{type = type, ctx = u8(p.context_count), name = name, created_ns = tracy_now_ns()}
	p.contexts[p.context_count] = gpu_ctx
	p.context_count += 1
	if p.client.session_ready {_ = tracy_client_emit_context(&p.client, &p.contexts[p.context_count - 1])}
	return gpu_ctx, true
}

// Whether `bytes` of records will be sent whole; a batch that has to arrive
// together (a tree of zones) asks first and is skipped when false.
profiler_reserve :: proc(p: ^Profiler, bytes: int) -> bool {
	return p != nil && p.client.session_ready && tracy_client_reserve(&p.client, bytes)
}

// One complete GPU zone with its two timestamps, in nanoseconds of the CPU
// clock (rhi.Gpu_Timing), queued whole or not at all.
profiler_gpu_timing :: proc(p: ^Profiler, ctx: Gpu_Context, name: string, start_ns, end_ns: i64) -> bool {
	if p == nil || !p.client.session_ready || int(ctx.ctx) >= p.context_count || end_ns < start_ns {return false}
	c := &p.client
	if !tracy_client_reserve(c, GPU_TIMING_BYTES + THREAD_CONTEXT_BYTES) || !tracy_client_use_thread(c, TRACY_THREAD_ID) {return false}
	// The server takes the first time of a query as the start of its zone and the second as the end.
	query := p.gpu_query_next[ctx.ctx]
	p.gpu_query_next[ctx.ctx] = query + 1
	source := tracy_client_register_source(c, name)
	now := tracy_now_ns()
	buffer: [GPU_TIMING_BYTES]u8
	n := 0
	written, ok := write_gpu_zone_begin(buffer[n:], Gpu_Zone_Begin{cpu_time = now - c.ref_thread, thread = TRACY_THREAD_ID, query_id = query, ctx = ctx.ctx, source_location = source})
	n += written
	time_written, time_ok := write_gpu_time(buffer[n:], Gpu_Time{gpu_time = start_ns - c.ref_gpu, query_id = query, ctx = ctx.ctx})
	n += time_written
	end_written, end_ok := write_gpu_zone_end(buffer[n:], Gpu_Zone_End{cpu_time = 0, thread = TRACY_THREAD_ID, query_id = query, ctx = ctx.ctx})
	n += end_written
	last_written, last_ok := write_gpu_time(buffer[n:], Gpu_Time{gpu_time = end_ns - start_ns, query_id = query, ctx = ctx.ctx})
	n += last_written
	if !ok || !time_ok || !end_ok || !last_ok || !tracy_client_append(c, buffer[:n]) {return false}
	c.ref_thread, c.ref_gpu = now, end_ns
	return true
}

// Starts a thread's batch: a ThreadContext, after which the next delta is absolute.
profiler_thread_context :: proc(p: ^Profiler, thread: u32) -> bool {
	if p == nil || !p.client.session_ready || thread == 0 {return false}
	return tracy_client_force_thread(&p.client, thread)
}

// A CPU zone begin on a non-zero thread, at nanoseconds of the CPU clock.
// The server asks for the name by its source location.
profiler_cpu_zone_begin :: proc(p: ^Profiler, thread: u32, name: string, start_ns: i64) -> bool {
	if p == nil || !p.client.session_ready || thread == 0 {return false}
	c := &p.client
	if !tracy_client_use_thread(c, thread) {return false}
	buffer: [CPU_ZONE_BEGIN_BYTES]u8
	written, ok := write_zone_begin_delta(buffer[:], start_ns - c.ref_thread, tracy_client_register_source(c, name))
	if !ok || !tracy_client_append(c, buffer[:written]) {return false}
	c.ref_thread = start_ns
	return true
}

// A CPU zone end. The server closes the last zone open on the thread, so the
// ends of a thread follow its begins as a stack.
profiler_cpu_zone_end :: proc(p: ^Profiler, thread: u32, end_ns: i64) -> bool {
	if p == nil || !p.client.session_ready || thread == 0 {return false}
	c := &p.client
	if !tracy_client_use_thread(c, thread) {return false}
	buffer: [CPU_ZONE_END_BYTES]u8
	written, ok := write_zone_end_delta(buffer[:], end_ns - c.ref_thread)
	if !ok || !tracy_client_append(c, buffer[:written]) {return false}
	c.ref_thread = end_ns
	return true
}

// Counts a frame, sends its mark in a session and pumps the transport.
profiler_frame_mark :: proc(p: ^Profiler) {
	if p == nil {return}
	p.client.frames += 1
	if p.client.session_ready {
		buffer: [1 + FRAME_MARK_SIZE]u8
		if written, ok := write_frame_mark(buffer[:], Frame_Mark{time = tracy_now_ns()}); ok {_ = tracy_client_append(&p.client, buffer[:written])}
	}
	profiler_poll(p)
}

profiler_session_ready :: proc "contextless" (p: ^Profiler) -> bool {return p != nil && p.client.session_ready}

// The port it listens on, which may be after the one asked for.
profiler_port :: proc "contextless" (p: ^Profiler) -> int {return p.client.port if p != nil else 0}
