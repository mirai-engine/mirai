#+build linux, windows
package rhi

import "core:fmt"
import "core:strings"
import "mirai:std/base"
import vk "vendor:vulkan"

// Where the GPU stopped when the device is lost or hangs. Each label pushed
// or popped, each cmd_timestamp, pipeline bound and draw of a frame is a mark: the GPU
// writes the serial of the frame into the word of the mark once the work
// recorded before it completed (VK_AMD_buffer_marker at the bottom of the
// pipe), each into a word of its own, in a buffer of the frame slot the CPU
// can read after a loss. The first word without it is where the GPU stopped.

MAX_FRAME_MARKS :: 4096 // marks a frame records at most; past them the rest of the frame has none
FRAME_MARK_NAME_BYTES :: 32768

@(private)
Vk_Mark_Kind :: enum u8 {Push, Pop, Section, Pipeline, Draw, End}

@(private)
Vk_Mark :: struct {
	kind:   Vk_Mark_Kind,
	length: u8,
	at:     u16, // of its name in Vk_Marks.names
}

@(private)
Vk_Marks :: struct {
	buffer: Buffer, // MAX_FRAME_MARKS words, Readback; 0 without VK_AMD_buffer_marker
	words:  [^]u32,
	serial: u32, // what the GPU writes in this frame
	sent:   bool, // the submission of the frame went to the queue
	count:  int,
	marks:  [MAX_FRAME_MARKS]Vk_Mark,
	named:  int,
	names:  [FRAME_MARK_NAME_BYTES]u8,
}

// A mark of the frame being recorded, which the GPU passes once what was
// recorded before it completed.
@(private)
vk_mark :: proc(c: ^Command_List, kind: Vk_Mark_Kind, name: string = "") {
	d := c.device
	if c.immediate {return}
	m := &d.frames[d.slot].marks
	if m.buffer == 0 || m.count >= MAX_FRAME_MARKS - (0 if kind == .End else 1) {return}
	length := min(len(name), 255, FRAME_MARK_NAME_BYTES - m.named)
	copy(m.names[m.named:], name[:length])
	m.marks[m.count] = {kind = kind, length = u8(length), at = u16(m.named)}
	m.named += length
	b := pool_get(&d.buffers, base.Handle(m.buffer))
	d.dvk.CmdWriteBufferMarkerAMD(c.cmd, {.BOTTOM_OF_PIPE}, b.handle, vk.DeviceSize(4 * m.count), m.serial)
	m.count += 1
}

// Where the frames on the GPU stopped: the open labels and the section at the
// first mark of the oldest frame the GPU did not pass; with every frame
// passed, the labels the last one left open. "" without marks or with
// nothing open.
@(private)
vk_stopped :: proc(d: ^Device, out: []u8) -> string {
	frame, newest: ^Vk_Marks
	stop := 0
	for &f in d.frames {
		m := &f.marks
		if !m.sent || m.count == 0 {continue}
		if newest == nil || m.serial > newest.serial {newest = m}
		for i in 0 ..< m.count {
			if m.words[i] == m.serial {continue}
			if frame == nil || m.serial < frame.serial {frame, stop = m, i}
			break
		}
	}
	if frame == nil {
		if newest == nil {return ""}
		frame, stop = newest, newest.count
	}
	labels: [MAX_LABEL_DEPTH]string
	section: [MAX_LABEL_DEPTH + 1]string
	depth, draws := 0, 0
	pipeline := ""
	for mark in frame.marks[:stop] {
		name := string(frame.names[mark.at:][:mark.length])
		switch mark.kind {
		case .Push:
			if depth < MAX_LABEL_DEPTH {labels[depth], section[depth + 1] = name, ""}
			depth += 1
			draws = 0
		case .Pop:
			depth = max(depth - 1, 0)
			draws = 0
		case .Section:
			section[min(depth, MAX_LABEL_DEPTH)] = name
			draws = 0
		case .Pipeline:
			pipeline, draws = name, 0
		case .Draw:
			draws += 1
		case .End:
		}
	}
	text := strings.builder_from_bytes(out)
	for level in 0 ..= min(depth, MAX_LABEL_DEPTH) {
		if level > 0 {fmt.sbprintf(&text, "%s%s", " > " if strings.builder_len(text) > 0 else "", labels[level - 1])}
		if section[level] != "" {fmt.sbprintf(&text, "%s%s", " > " if strings.builder_len(text) > 0 else "", section[level])}
	}
	if strings.builder_len(text) == 0 {return ""}
	if pipeline != "" {fmt.sbprintf(&text, ", with the pipeline %s", pipeline)}
	if draws > 0 {fmt.sbprintf(&text, ", after its draw %d", draws)}
	if stop == frame.count {fmt.sbprintf(&text, ", where its frame ended")}
	return strings.to_string(text)
}
