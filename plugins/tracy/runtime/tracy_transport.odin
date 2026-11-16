// TCP transport of the Tracy client.
//
// Direction matters: the profiled application *listens* on the Tracy port and
// the profiler or tracy-capture connects to it. The server sends the
// shibboleth and its protocol version; the client answers with
// HandshakeWelcome, the fixed WelcomeMessage and the on-demand payload, and
// then LZ4-compressed queue frames. The server also sends ServerQueryPacket
// requests (source locations, strings, thread names), which the client
// answers with queue items in the next frame.
//
// Single-threaded and polled: nothing waits for the socket. A frame the
// socket does not take whole stays pending and the next poll sends the rest;
// while it is pending a record that does not fit in the queue is dropped.
package tracy

import "base:runtime"
import "core:hash"
import "core:net"
import "core:os"
import "core:time"

TRACY_THREAD_ID :: u32(1) // the main thread and the GPU zones
TRACY_MAX_SOURCES :: 256
TRACY_SOURCE_SLOTS :: 512 // open-addressed index, twice the sources
TRACY_SOURCE_TEXT_BYTES :: 16 * 1024
TRACY_SOURCE_NAME_BYTES :: 256 // longer names are cut
TRACY_QUERY_BUFFER :: SERVER_QUERY_PACKET_SIZE * 64
TRACY_QUERY_ANSWER_BYTES :: 1 + STRING_TRANSFER_SIZE + 2 + TRACY_SOURCE_NAME_BYTES // the longest answer to one query
TRACY_HANDSHAKE_TIMEOUT :: 2 * time.Second
TRACY_PORTS :: 20 // ports tried from the one asked for, as the Tracy client does
TRACY_OVERFLOW_NAME :: "(more zone names than the client keeps)"

Source_Entry :: struct {
	id:   u64,
	name: string,
}

Tracy_Client :: struct {
	allocator: runtime.Allocator,

	listener:       net.TCP_Socket,
	listener_valid: bool,
	conn:           net.TCP_Socket,
	conn_valid:     bool,
	accepted:       time.Tick, // when conn was taken: the server has TRACY_HANDSHAKE_TIMEOUT to identify itself

	connected:     bool, // the handshake completed
	session_ready: bool, // the records a session starts with are queued
	session:       u32,  // sessions so far
	port:          int,

	broadcast_socket:   net.UDP_Socket,
	broadcast_valid:    bool,
	broadcast_endpoint: net.Endpoint,
	last_broadcast:     time.Tick,
	epoch_unix:         i64,

	handshake_buf: [SERVER_HANDSHAKE_SIZE]u8,
	handshake_len: int,
	queue:         []u8,
	queue_len:     int,
	compressed:    []u8, // the frame being sent: its length and the LZ4 block, or the handshake answer
	pending_from:  int,
	pending_len:   int,  // bytes of compressed the socket has not taken yet
	dropped:       u64,  // batches dropped while a frame was pending
	ref_thread:    i64,
	ref_gpu:       i64,
	active_thread: u32, // thread of the last ThreadContext record

	recv_buf: [TRACY_QUERY_BUFFER]u8,
	recv_len: int,

	sources:          [TRACY_MAX_SOURCES]Source_Entry,
	source_slots:     [TRACY_SOURCE_SLOTS]u16, // 0 empty, else index+1
	source_count:     int,
	source_text:      [TRACY_SOURCE_TEXT_BYTES]u8,
	source_text_used: int,

	frames:     u64, // frame marks since the client started: where an on-demand session begins counting
	init_ticks: i64,
	welcome:    Tracy_Welcome,
}

@(private="file")
tracy_cpu_arch :: proc "contextless" () -> u8 {
	arch := u8(0)
	when ODIN_ARCH == .i386 {arch = 1}
	else when ODIN_ARCH == .amd64 {arch = 2}
	else when ODIN_ARCH == .arm32 {arch = 3}
	else when ODIN_ARCH == .arm64 {arch = 4}
	return arch
}

// Nanoseconds of time.tick_now. The welcome advertises timerMul=1, so the
// server reads every timestamp of the queue in this unit.
tracy_now_ns :: proc "contextless" () -> i64 {
	return time.duration_nanoseconds(time.tick_diff({}, time.tick_now()))
}

// Listens on the first free port from `port` (0 asks the OS for one), on the
// loopback interface unless any_address, and makes the buffers.
tracy_client_init :: proc(client: ^Tracy_Client, port: int = SERVER_PORT, program_name: string = "Mirai", allocator := context.allocator, any_address := false) -> bool {
	client^ = {}
	client.allocator = allocator
	client.init_ticks = tracy_now_ns()

	name := program_name if program_name != "" else "Mirai"
	epoch_ns := time.time_to_unix_nano(time.now())
	client.epoch_unix = epoch_ns / 1_000_000_000 if epoch_ns > 0 else 0
	flags := WELCOME_FLAG_ON_DEMAND
	when ODIN_OS == .Darwin {flags |= WELCOME_FLAG_IS_APPLE}
	welcome_fill(&client.welcome, Welcome_Info{
		timer_mul = 1.0,
		init_begin = client.init_ticks,
		init_end = client.init_ticks,
		resolution = 1,
		epoch = u64(client.epoch_unix),
		pid = u64(os.get_pid()),
		flags = flags,
		cpu_arch = tracy_cpu_arch(),
		program_name = name,
	})

	queue, queue_error := make([]u8, TARGET_FRAME_SIZE, allocator)
	compressed, compressed_error := make([]u8, LZ4_SIZE + 4, allocator)
	if queue_error != nil || compressed_error != nil {
		delete(queue, allocator)
		delete(compressed, allocator)
		client^ = {}
		return false
	}
	client.queue, client.compressed = queue, compressed

	address := net.Address(net.IP4_Any) if any_address else net.Address(net.IP4_Loopback)
	tries := port == 0 ? 1 : TRACY_PORTS
	for i in 0 ..< tries {
		listener, err := net.listen_tcp({address, port == 0 ? 0 : port + i})
		if err != nil {continue}
		if net.set_blocking(listener, false) != .None {
			net.close(listener)
			continue
		}
		client.listener, client.listener_valid = listener, true
		client.port = port + i
		if endpoint, endpoint_err := net.bound_endpoint(listener); endpoint_err == .None {client.port = endpoint.port}
		break
	}
	if !client.listener_valid {
		delete(client.queue, allocator)
		delete(client.compressed, allocator)
		client^ = {}
		return false
	}

	// UDP discovery for the GUI. Without it the profiler connects by address.
	if broadcast_socket, broadcast_err := net.make_unbound_udp_socket(.IP4); broadcast_err == .None {
		if net.set_option(broadcast_socket, .Broadcast, true) == .None {
			client.broadcast_socket, client.broadcast_valid = broadcast_socket, true
			client.broadcast_endpoint = net.Endpoint{address = net.Address(net.IP4_Address{255, 255, 255, 255}), port = BROADCAST_PORT}
		} else {
			net.close(broadcast_socket)
		}
	}
	_ = tracy_client_register_source(client, TRACY_OVERFLOW_NAME)
	return true
}

tracy_client_shutdown :: proc(client: ^Tracy_Client) {
	allocator := client.allocator
	if client.conn_valid {net.close(client.conn)}
	if client.listener_valid {net.close(client.listener)}
	if client.broadcast_valid {
		_ = tracy_client_broadcast(client, -1)
		net.close(client.broadcast_socket)
	}
	delete(client.queue, allocator)
	delete(client.compressed, allocator)
	client^ = {}
}

@(private="file")
tracy_client_drop_connection :: proc(client: ^Tracy_Client) {
	if client.conn_valid {net.close(client.conn)}
	client.conn_valid = false
	client.connected = false
	client.session_ready = false
	client.handshake_len = 0
	client.recv_len = 0
	client.queue_len = 0
	client.pending_len = 0
	client.ref_thread = 0
	client.ref_gpu = 0
	client.active_thread = 0
}

@(private="file")
tracy_client_program_name :: proc(client: ^Tracy_Client) -> string {
	name := client.welcome.program_name[:]
	for i in 0 ..< len(name) {
		if name[i] == 0 {return string(name[:i])}
	}
	return string(name)
}

// One UDP discovery datagram. active_time is seconds since the client
// started, or -1 to remove it from the GUI list.
@(private="file")
tracy_client_broadcast :: proc(client: ^Tracy_Client, active_time: i32) -> bool {
	if !client.broadcast_valid {return false}
	buffer: [BROADCAST_MESSAGE_SIZE]u8
	written, ok := write_broadcast_message(buffer[:], u16(client.port), u64(os.get_pid()), active_time, tracy_client_program_name(client))
	if !ok {return false}
	_, send_err := net.send_udp(client.broadcast_socket, buffer[:written], client.broadcast_endpoint)
	return send_err == .None
}

// Sends what the socket takes of the pending frame. False when the
// connection is lost.
@(private="file")
tracy_client_send_pending :: proc(client: ^Tracy_Client) -> bool {
	for client.pending_len > 0 {
		written, err := net.send_tcp(client.conn, client.compressed[client.pending_from:][:client.pending_len])
		if written > 0 {
			client.pending_from += written
			client.pending_len -= written
			continue
		}
		if err == .None || err == .Would_Block {return true}
		return false
	}
	return true
}

@(private="file")
tracy_client_accept :: proc(client: ^Tracy_Client) {
	if !client.listener_valid || client.conn_valid {return}
	conn, _, err := net.accept_tcp(client.listener)
	if err != .None {return}
	if net.set_blocking(conn, false) != .None {
		net.close(conn)
		return
	}
	client.conn, client.conn_valid = conn, true
	client.accepted = time.tick_now()
	client.handshake_len = 0
}

// Reads the server's shibboleth and version and, when they match, sends the
// welcome as the first pending bytes. True exactly on the poll that completes
// a handshake; a server that stays silent is dropped.
@(private="file")
tracy_client_handshake :: proc(client: ^Tracy_Client) -> bool {
	for client.handshake_len < SERVER_HANDSHAKE_SIZE {
		read, err := net.recv_tcp(client.conn, client.handshake_buf[client.handshake_len:])
		if read > 0 {
			client.handshake_len += read
			continue
		}
		if err == .Would_Block {
			if time.tick_since(client.accepted) > TRACY_HANDSHAKE_TIMEOUT {tracy_client_drop_connection(client)}
			return false
		}
		tracy_client_drop_connection(client)
		return false
	}
	if _, ok := parse_server_handshake(client.handshake_buf[:]); !ok {
		status := [1]u8{u8(Handshake_Status.ProtocolMismatch)}
		_, _ = net.send_tcp(client.conn, status[:])
		tracy_client_drop_connection(client)
		return false
	}
	out := client.compressed
	out[0] = u8(Handshake_Status.Welcome)
	welcome := transmute([WELCOME_SIZE]u8)client.welcome
	copy(out[1:], welcome[:])
	payload_written, _ := write_on_demand_payload(out[1 + WELCOME_SIZE:], client.frames, tracy_now_ns())
	client.pending_from, client.pending_len = 0, 1 + WELCOME_SIZE + payload_written
	if !tracy_client_send_pending(client) {
		tracy_client_drop_connection(client)
		return false
	}
	client.connected = true
	client.session_ready = false
	client.session += 1
	client.recv_len = 0
	client.queue_len = 0
	client.ref_thread = 0
	client.ref_gpu = 0
	client.active_thread = 0
	return true
}

// Moves the queue into one frame and starts sending it. Only without a
// pending frame.
@(private="file")
tracy_client_send_frame :: proc(client: ^Tracy_Client) -> bool {
	if client.queue_len == 0 {return true}
	lz4_len, ok := lz4_compress(client.queue[:client.queue_len], client.compressed[4:])
	client.queue_len = 0
	if !ok {return false}
	value := u32(lz4_len)
	client.compressed[0] = u8(value)
	client.compressed[1] = u8(value >> 8)
	client.compressed[2] = u8(value >> 16)
	client.compressed[3] = u8(value >> 24)
	client.pending_from, client.pending_len = 0, 4 + lz4_len
	return tracy_client_send_pending(client)
}

// Whether a batch of `bytes` will go into the queue whole: when it does not
// fit and no frame is pending, the queue becomes a frame first.
tracy_client_reserve :: proc(client: ^Tracy_Client, bytes: int) -> bool {
	if !client.connected || bytes > len(client.queue) {return false}
	if client.queue_len + bytes <= len(client.queue) {return true}
	if client.pending_len > 0 {
		client.dropped += 1
		return false
	}
	if !tracy_client_send_frame(client) {
		tracy_client_drop_connection(client)
		return false
	}
	return client.queue_len + bytes <= len(client.queue)
}

// Appends one record, dropped when it does not fit.
tracy_client_append :: proc(client: ^Tracy_Client, data: []u8) -> bool {
	if !tracy_client_reserve(client, len(data)) {return false}
	copy(client.queue[client.queue_len:], data)
	client.queue_len += len(data)
	return true
}

tracy_client_append_single_string :: proc(client: ^Tracy_Client, text: string) -> bool {
	if !tracy_client_reserve(client, 3 + min(len(text), 256 + 65535)) {return false}
	written, ok := write_single_string(client.queue[client.queue_len:], text)
	if !ok {return false}
	client.queue_len += written
	return true
}

@(private="file")
tracy_client_emit_string :: proc(client: ^Tracy_Client, type: Queue_Type, ptr: u64, text: string) {
	if client.queue_len + 1 + STRING_TRANSFER_SIZE + 2 + len(text) > len(client.queue) {return}
	written, ok := write_string_transfer(client.queue[client.queue_len:], type, ptr, text)
	if ok {client.queue_len += written}
}

tracy_client_find_source :: proc(client: ^Tracy_Client, id: u64) -> (Source_Entry, bool) {
	if id == 0 || id > u64(client.source_count) {return {}, false}
	return client.sources[id - 1], true
}

@(private="file")
tracy_client_handle_query :: proc(client: ^Tracy_Client, query_type: u8, ptr: u64) {
	#partial switch Server_Query(query_type) {
	case .String:
		entry, _ := tracy_client_find_source(client, ptr)
		tracy_client_emit_string(client, .String_Data, ptr, entry.name)
	case .Source_Location:
		_, found := tracy_client_find_source(client, ptr)
		buffer: [1 + SOURCE_LOCATION_SIZE]u8
		written, ok := write_source_location(buffer[:], Source_Location{name = found ? ptr : 0})
		if ok && client.queue_len + written <= len(client.queue) {
			copy(client.queue[client.queue_len:], buffer[:written])
			client.queue_len += written
		}
	case .Thread_String:
		tracy_client_emit_string(client, .Thread_Name, ptr, ptr == u64(TRACY_THREAD_ID) ? "main" : "worker")
	case .Frame_Name:
		tracy_client_emit_string(client, .Frame_Name, ptr, "")
	case .Plot_Name:
		tracy_client_emit_string(client, .Plot_Name, ptr, "")
	case .Terminate, .Disconnect:
		tracy_client_drop_connection(client)
	case:
		// The client only sends records that cause the queries above.
	}
}

// Answers the queries the server sent, into the queue: as many as leave room
// for their answers; the rest wait in the socket.
@(private="file")
tracy_client_read_queries :: proc(client: ^Tracy_Client) {
	for client.connected {
		for client.connected && client.recv_len >= SERVER_QUERY_PACKET_SIZE {
			if client.queue_len + TRACY_QUERY_ANSWER_BYTES > len(client.queue) {return}
			b := client.recv_buf[:]
			ptr := u64(0)
			for i in 0 ..< 8 {ptr |= u64(b[1 + i]) << (uint(i) * 8)}
			query_type := b[0]
			client.recv_len -= SERVER_QUERY_PACKET_SIZE
			copy(client.recv_buf[:client.recv_len], client.recv_buf[SERVER_QUERY_PACKET_SIZE:][:client.recv_len])
			tracy_client_handle_query(client, query_type, ptr)
		}
		if !client.connected || client.recv_len >= len(client.recv_buf) {return}
		read, err := net.recv_tcp(client.conn, client.recv_buf[client.recv_len:])
		if read > 0 {
			client.recv_len += read
			continue
		}
		if err == .Would_Block {return}
		tracy_client_drop_connection(client)
		return
	}
}

// Sends what is pending, turns the queue into the next frame and answers
// the queries. False when the session was lost.
tracy_client_flush :: proc(client: ^Tracy_Client) -> bool {
	if !client.connected {return false}
	if !tracy_client_send_pending(client) {
		tracy_client_drop_connection(client)
		return false
	}
	if client.pending_len == 0 && !tracy_client_send_frame(client) {
		tracy_client_drop_connection(client)
		return false
	}
	tracy_client_read_queries(client)
	return client.connected
}

// One poll: broadcast while waiting, accept a server, complete its handshake,
// send and answer. True when a session just started.
tracy_client_poll :: proc(client: ^Tracy_Client) -> bool {
	if !client.listener_valid {return false}
	if client.broadcast_valid && !client.connected && time.tick_since(client.last_broadcast) >= 3 * time.Second {
		now_unix := time.time_to_unix_nano(time.now()) / 1_000_000_000
		_ = tracy_client_broadcast(client, i32(now_unix - client.epoch_unix))
		client.last_broadcast = time.tick_now()
	}
	if !client.conn_valid {
		tracy_client_accept(client)
		if !client.conn_valid {return false}
	}
	if !client.connected {return tracy_client_handshake(client)}
	_ = tracy_client_flush(client)
	return false
}

// The id of a zone name, copied into a fixed pool: callers may pass a name
// that lives only during the call. Names are deduplicated by content and cut
// at TRACY_SOURCE_NAME_BYTES; when the pool is full they share the id of
// TRACY_OVERFLOW_NAME. The id is the source location the server asks about.
tracy_client_register_source :: proc(client: ^Tracy_Client, name: string) -> u64 {
	name_len := min(len(name), TRACY_SOURCE_NAME_BYTES)
	data := transmute([]byte)name
	slot := int(hash.fnv32a(data[:name_len])) & (TRACY_SOURCE_SLOTS - 1)
	empty := -1
	for _ in 0 ..< TRACY_SOURCE_SLOTS {
		entry := client.source_slots[slot]
		if entry == 0 {
			empty = slot
			break
		}
		source := client.sources[entry - 1]
		if len(source.name) == name_len && source.name == name[:name_len] {return source.id}
		slot = (slot + 1) & (TRACY_SOURCE_SLOTS - 1)
	}
	if empty < 0 || client.source_count >= TRACY_MAX_SOURCES || client.source_text_used + name_len > len(client.source_text) {
		return client.source_count > 0 ? 1 : 0
	}
	offset := client.source_text_used
	copy(client.source_text[offset:offset + name_len], name[:name_len])
	client.source_text_used += name_len
	id := u64(client.source_count + 1)
	client.sources[client.source_count] = Source_Entry{id = id, name = string(client.source_text[offset:offset + name_len])}
	client.source_slots[empty] = u16(client.source_count + 1)
	client.source_count += 1
	return id
}

// Switches the server's thread stream. The server resets its time reference
// with every ThreadContext; so does the client, so the next delta is absolute.
tracy_client_force_thread :: proc(client: ^Tracy_Client, thread: u32) -> bool {
	if thread == 0 {return false}
	buffer: [1 + THREAD_CONTEXT_SIZE]u8
	written, ok := write_thread_context(buffer[:], Thread_Context{thread = thread})
	if !ok || !tracy_client_append(client, buffer[:written]) {return false}
	client.active_thread = thread
	client.ref_thread = 0
	return true
}

tracy_client_use_thread :: proc(client: ^Tracy_Client, thread: u32) -> bool {
	if thread == 0 {return false}
	if client.active_thread == thread {return true}
	return tracy_client_force_thread(client, thread)
}

// GpuNewContext and, when it has one, the context's name. The GPU times the
// client sends are nanoseconds on the CPU's clock (rhi.Gpu_Timing), so the
// context starts with both clocks equal and period 1.
tracy_client_emit_context :: proc(client: ^Tracy_Client, ctx: ^Gpu_Context) -> bool {
	buffer: [1 + GPU_NEW_CONTEXT_SIZE]u8
	written, ok := write_gpu_new_context(buffer[:], Gpu_New_Context{
		cpu_time = ctx.created_ns,
		gpu_time = ctx.created_ns,
		thread = 0, // Vulkan and Metal contexts are not bound to a thread
		period = 1.0,
		ctx = ctx.ctx,
		type = ctx.type,
	})
	if !ok || !tracy_client_append(client, buffer[:written]) {return false}
	if ctx.name == "" {return true}
	if !tracy_client_append_single_string(client, ctx.name) {return false}
	name_buffer: [1 + GPU_CONTEXT_NAME_SIZE]u8
	name_written, name_ok := write_context_name(name_buffer[:], Gpu_Context_Name{ctx = ctx.ctx})
	return name_ok && tracy_client_append(client, name_buffer[:name_written])
}
