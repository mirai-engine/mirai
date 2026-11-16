package tracy

import "core:testing"

// The server reads the program name as a C string: a long one is cut so the
// last byte stays zero.
@(test)
the_welcome_keeps_the_program_name_a_c_string :: proc(t: ^testing.T) {
	long: [100]u8
	for &c in long {c = 'x'}
	welcome: Tracy_Welcome
	welcome_fill(&welcome, Welcome_Info{program_name = string(long[:]), host_info = string(long[:])})
	for i in 0 ..< 63 {testing.expect_value(t, welcome.program_name[i], u8('x'))}
	testing.expect_value(t, welcome.program_name[63], u8(0))
	testing.expect_value(t, welcome.host_info[1023], u8(0))
	testing.expect_value(t, size_of(Tracy_Welcome), 1170)
}

// The wire layouts, written out as the bytes the server expects.
@(test)
records_have_the_layout_of_the_server :: proc(t: ^testing.T) {
	out: [32]u8
	n, ok := write_on_demand_payload(out[:], 0x0102, 0x0a0b)
	testing.expect(t, ok)
	testing.expect(t, bytes_equal(out[:n], {2, 1, 0, 0, 0, 0, 0, 0, 0x0b, 0x0a, 0, 0, 0, 0, 0, 0}))
	n, ok = write_frame_mark(out[:], Frame_Mark{time = 0x10, name = 0})
	testing.expect(t, ok)
	testing.expect(t, bytes_equal(out[:n], {83, 0x10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}))
	n, ok = write_thread_context(out[:], Thread_Context{thread = 7})
	testing.expect(t, ok)
	testing.expect(t, bytes_equal(out[:n], {75, 7, 0, 0, 0}))
	handshake := [12]u8{'T', 'r', 'a', 'c', 'y', 'P', 'r', 'f', 83, 0, 0, 0}
	version, matches := parse_server_handshake(handshake[:])
	testing.expect(t, matches)
	testing.expect_value(t, version, u32(83))
	handshake[8] = 82
	_, matches = parse_server_handshake(handshake[:])
	testing.expect(t, !matches, "another protocol version is refused")
}

@(private="file")
bytes_equal :: proc(a: []u8, b: []u8) -> bool {return string(a) == string(b)}
