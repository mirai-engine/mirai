package tracy

import "core:net"
import "core:testing"
import "core:time"

// A server that speaks to the client over loopback, written with the wire
// values instead of the package's constants. The client is polled in the same
// thread between the server's reads.
@(private="file")
Fake_Server :: struct {
	sock: net.TCP_Socket,
	p:    ^Profiler,
}

@(private="file")
server_connect :: proc(t: ^testing.T, p: ^Profiler) -> (s: Fake_Server, ok: bool) {
	sock, err := net.dial_tcp(net.Endpoint{net.IP4_Loopback, profiler_port(p)})
	if !testing.expect(t, err == nil) {return}
	testing.expect(t, net.set_blocking(sock, false) == .None)
	return {sock = sock, p = p}, true
}

// Reads exactly len(out) bytes, polling the client meanwhile; false after a second.
@(private="file")
server_read :: proc(s: ^Fake_Server, out: []u8) -> bool {
	got := 0
	start := time.tick_now()
	for got < len(out) {
		profiler_poll(s.p)
		n, err := net.recv_tcp(s.sock, out[got:])
		if n > 0 {got += n; continue}
		if err != .Would_Block && err != nil {return false}
		if time.tick_since(start) > time.Second {return false}
		time.sleep(time.Millisecond)
	}
	return true
}

@(private="file")
server_handshake :: proc(t: ^testing.T, s: ^Fake_Server) -> (welcome: [1170]u8, payload: [16]u8, ok: bool) {
	hello := [12]u8{'T', 'r', 'a', 'c', 'y', 'P', 'r', 'f', 83, 0, 0, 0}
	if _, err := net.send_tcp(s.sock, hello[:]); !testing.expect(t, err == nil) {return}
	status: [1]u8
	if !testing.expect(t, server_read(s, status[:])) {return}
	testing.expect_value(t, status[0], u8(1))
	if !testing.expect(t, server_read(s, welcome[:])) || !testing.expect(t, server_read(s, payload[:])) {return}
	return welcome, payload, true
}

// The welcome asks for an on-demand session and the payload says how many
// frames went before it; then the frames carry the records.
@(test)
a_late_server_gets_an_on_demand_session :: proc(t: ^testing.T) {
	p: Profiler
	if !testing.expect(t, profiler_init(&p, 0, "Mirai")) {return}
	defer profiler_shutdown(&p, 0)
	for _ in 0 ..< 3 {profiler_frame_mark(&p)}
	s, ok := server_connect(t, &p)
	if !ok {return}
	defer net.close(s.sock)
	welcome, payload, shook := server_handshake(t, &s)
	if !shook {return}
	flags := welcome[8 * 8]
	testing.expect(t, flags & 1 == 1, "the welcome has WelcomeFlag::OnDemand")
	testing.expect_value(t, string(welcome[82:87]), "Mirai") // after eight 8-byte fields, flags, arch, the manufacturer and the cpu id
	testing.expect_value(t, payload[0], u8(3))
	profiler_poll(&p)
	testing.expect(t, profiler_session_ready(&p))
	profiler_frame_mark(&p)
	header: [4]u8
	if !testing.expect(t, server_read(&s, header[:])) {return}
	length := int(header[0]) | int(header[1]) << 8 | int(header[2]) << 16 | int(header[3]) << 24
	block := make([]u8, length, context.temp_allocator)
	testing.expect(t, server_read(&s, block))
}

// A server that stops reading does not hold the frame: polls return at once
// and the client stays connected, dropping what does not fit.
@(test)
a_server_that_stops_reading_does_not_block_the_frame :: proc(t: ^testing.T) {
	p: Profiler
	if !testing.expect(t, profiler_init(&p, 0, "Mirai")) {return}
	defer profiler_shutdown(&p, 0)
	s, ok := server_connect(t, &p)
	if !ok {return}
	defer net.close(s.sock)
	if _, _, shook := server_handshake(t, &s); !shook {return}
	profiler_poll(&p)
	// The system's socket buffers: on Windows, a socket with SO_SNDBUF or
	// SO_RCVBUF set queues loopback data without bound and never fills.
	slowest: time.Duration
	waited := false
	state := u32(0x2545f491)
	at := i64(0)
	// More than the socket buffers of the system hold.
	for _ in 0 ..< 2000 {
		start := time.tick_now()
		for _ in 0 ..< 2000 {
			state ~= state << 13; state ~= state >> 17; state ~= state << 5
			at += i64(state & 0xffffff) // gaps that do not compress away
			if profiler_reserve(&p, CPU_ZONE_BEGIN_BYTES + CPU_ZONE_END_BYTES) {
				_ = profiler_cpu_zone_begin(&p, 1, "zone", at)
				_ = profiler_cpu_zone_end(&p, 1, at + i64(state >> 24))
			}
		}
		profiler_frame_mark(&p)
		slowest = max(slowest, time.tick_since(start))
		waited ||= p.client.pending_len > 0
	}
	testing.expect(t, profiler_session_ready(&p), "the client keeps the session")
	testing.expect(t, waited, "the socket stopped taking frames")
	testing.expectf(t, slowest < 50 * time.Millisecond, "the slowest frame took %v", slowest)
}

// A connection that never identifies itself is dropped, and the next server
// can connect.
@(test)
a_silent_connection_is_dropped :: proc(t: ^testing.T) {
	p: Profiler
	if !testing.expect(t, profiler_init(&p, 0, "Mirai")) {return}
	defer profiler_shutdown(&p, 0)
	silent, ok := server_connect(t, &p)
	if !ok {return}
	defer net.close(silent.sock)
	start := time.tick_now()
	for p.client.conn_valid || time.tick_since(start) < 10 * time.Millisecond {
		profiler_poll(&p)
		if time.tick_since(start) > TRACY_HANDSHAKE_TIMEOUT + time.Second {break}
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, !p.client.conn_valid, "the silent connection was dropped")
	s, connected := server_connect(t, &p)
	if !connected {return}
	defer net.close(s.sock)
	_, _, shook := server_handshake(t, &s)
	testing.expect(t, shook, "the next server connects")
}
