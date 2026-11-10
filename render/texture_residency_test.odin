package mirai_render

import "core:math"
import "core:math/rand"
import "core:testing"
import "mirai:rhi"

@(private = "file")
square_stream :: proc(side: u32, top: u8, lod: f32, shown := true) -> (stream: Texture_Stream) {
	stream.size, stream.format, stream.top, stream.target = {side, side}, .RGBA8_Unorm, top, top
	stream.width, stream.window = math.log2(f32(side)), max(f32)
	for s := side; ; s /= 2 {
		stream.levels += 1
		if s <= 1 {break}
	}
	texture_chain(&stream)
	stream.lod, stream.shown = lod, shown
	return
}

// A texture comes to the level the frames sample, at once when it needs more
// levels and only TEXTURE_KEEP_LEVELS past it when it needs fewer; between
// the largest max_size takes and the one of side TEXTURE_TAIL. One no frame
// samples keeps the levels it has.
@(test)
a_streamed_texture_follows_what_is_sampled_with_hysteresis_within_its_range :: proc(t: ^testing.T) {
	target :: proc(top: u8, lod: f32, max_size := 4096) -> u8 {
		stream := square_stream(1024, top, lod)
		return texture_target(&stream, max_size, 0)
	}
	testing.expect_value(t, target(0, 3.5), 3)
	testing.expect_value(t, target(3, 3.2), 3)
	testing.expect_value(t, target(3, 2.9), 2)
	testing.expect_value(t, target(2, 3.1), 2) // without the hysteresis it would be 3
	testing.expect_value(t, target(2, 3.4), 3)
	testing.expect_value(t, target(5, -8), 0)
	testing.expect_value(t, target(0, 20), 3) // 1024 >> 3 is TEXTURE_TAIL
	testing.expect_value(t, target(0, -8, 512), 1)
	unseen := square_stream(1024, 1, 9, shown = false)
	testing.expect_value(t, texture_target(&unseen, 4096, 0), 1)
	small := square_stream(64, 0, 9)
	first, last := texture_level_range(&small, 4096)
	testing.expect(t, first == 0 && last == 0, "a texture smaller than the tail keeps every level")
}

// While the levels the frames sample take more than the room of the pool,
// those no frame samples give levels up first, the same share of a level
// each; past their tails the others too, the coarser the farther.
@(test)
past_the_pool_what_no_frame_samples_gives_levels_up_first :: proc(t: ^testing.T) {
	streams := []Texture_Stream{square_stream(1024, 0, 1.5), square_stream(1024, 0, 0.5), square_stream(1024, 0, 0, shown = false)}
	whole := streams[0].chain[0]
	tail := streams[2].chain[3]
	// Room for the two sampled ones as they ask and the tail of the unseen one.
	room := streams[0].chain[1] + streams[1].chain[0] + tail
	reduced, pending := texture_targets(streams, 4096, room)
	testing.expect(t, streams[0].target == 1 && streams[1].target == 0 && streams[2].target == 3, "the unseen one alone gives levels up")
	testing.expect(t, reduced == 0 && pending == 2, "nothing sampled is held coarser")
	// Less room: the sampled ones take the same share of a level more.
	room = u64(f64(whole) * 1.1)
	reduced, pending = texture_targets(streams, 4096, room)
	total := streams[0].chain[streams[0].target] + streams[1].chain[streams[1].target] + streams[2].chain[streams[2].target]
	testing.expectf(t, total <= room, "%d bytes do not fit the room", total)
	testing.expectf(t, streams[0].target > streams[1].target && streams[2].target == 3, "targets %d, %d and %d", streams[0].target, streams[1].target, streams[2].target)
	testing.expect_value(t, reduced, 2)
	testing.expect_value(t, pending, 3)
	// With room, each keeps what is sampled, and the unseen one its levels.
	reduced, _ = texture_targets(streams, 4096, max(u64))
	testing.expect(t, reduced == 0 && streams[0].target == 1 && streams[1].target == 0 && streams[2].target == 0)
}

// What a frame samples of each texture (texture_feedback in scene.slang) is
// a level of its width: a finer one is taken at once, a coarser one at the
// end of the window of TEXTURE_FEEDBACK_FRAMES, and a texture no frame of a
// window sampled is unseen and keeps its levels. Codes out of range or
// random never give a level outside the texture.
@(test)
the_feedback_of_the_frames_sets_the_level_of_each_texture :: proc(t: ^testing.T) {
	residency: Texture_Residency
	defer delete(residency.streams)
	append(&residency.streams, square_stream(1024, 0, 0, shown = false), square_stream(1024, 0, 0, shown = false), Texture_Stream{})
	code :: proc(level: f32) -> u32 {return u32((level - TEXTURE_FEEDBACK_LOW) * TEXTURE_FEEDBACK_STEPS)}
	// The same feedback until the window under way ends.
	window :: proc(residency: ^Texture_Residency, codes: []u32) {
		for {
			textures_feedback_take(residency, codes)
			if residency.frames == 0 {break}
		}
	}
	// A texel across the width of a pixel at level 3 of 1024: log2(8 / 1024).
	at3 := code(3 - 10)
	textures_feedback_take(&residency, {at3, TEXTURE_FEEDBACK_NONE, at3})
	streams := residency.streams[:]
	testing.expect(t, streams[0].shown && abs(streams[0].lod - 3) < 1e-3 && residency.retarget, "the first frame that samples it gives its level")
	testing.expect(t, !streams[1].shown && !streams[2].shown, "nothing is asked of a texture no pass sampled, nor of one not streamed")
	residency.retarget = false
	// Coarser within the window: kept; finer: at once.
	textures_feedback_take(&residency, {code(5 - 10), TEXTURE_FEEDBACK_NONE})
	testing.expect(t, abs(streams[0].lod - 3) < 1e-3 && !residency.retarget)
	textures_feedback_take(&residency, {code(1 - 10)})
	testing.expect(t, abs(streams[0].lod - 1) < 1e-3 && residency.retarget)
	window(&residency, {code(4 - 10), code(6 - 10)})
	testing.expectf(t, abs(streams[0].lod - 1) < 1e-3, "the window that ends took a finer one: %v", streams[0].lod)
	testing.expect(t, streams[1].shown && abs(streams[1].lod - 6) < 1e-3, "the second one was sampled from the start of the window")
	window(&residency, {code(4 - 10), code(6 - 10)})
	testing.expectf(t, abs(streams[0].lod - 4) < 1e-3, "a window sampled coarser lets levels go: %v", streams[0].lod)
	window(&residency, {code(4 - 10), TEXTURE_FEEDBACK_NONE})
	testing.expect(t, !streams[1].shown && texture_target(&streams[1], 4096, 0) == streams[1].top, "a window that never sampled it leaves it unseen with its levels")
	// Every level for a program, and hostile codes.
	textures_feedback_take(&residency, {0, max(u32) - 1, 7, 1, 2, 3})
	testing.expect_value(t, texture_target(&streams[0], 4096, 0), 0)
	for _ in 0 ..< 3 * TEXTURE_FEEDBACK_FRAMES {
		codes: [2]u32
		for &c in codes {c = rand.uint32()}
		textures_feedback_take(&residency, codes[:])
		for &stream in streams[:2] {
			first, last := texture_level_range(&stream, 4096)
			level := int(texture_target(&stream, 4096, 0))
			testing.expectf(t, !math.is_nan(stream.lod) && level >= first && level <= last, "level %d of %v", level, stream.lod)
		}
	}
}

// Only textures that need more levels are read, the farthest from their
// target first, none while the textures take more than the pool; those being
// read are left out. One that needs fewer gives them up alone.
@(test)
texture_requests_put_what_is_most_blurred_first :: proc(t: ^testing.T) {
	r := new(Renderer)
	defer free(r)
	resize(&r.textures.residency.streams, 3)
	defer delete(r.textures.residency.streams)
	streams := r.textures.residency.streams
	streams[0] = square_stream(1024, 0, 0);streams[0].target = 3
	streams[1] = square_stream(1024, 5, 0);streams[1].target = 2
	streams[2] = square_stream(1024, 4, 0);streams[2].target = 3
	r.textures.count, r.textures.residency.pending = 3, 3
	out: [4]Texture_Request
	count := texture_requests(r, out[:], nil)
	testing.expect(t, count == 2 && out[0].handle == 2 && out[1].handle == 3, "what grows, the most first; not what shrinks")
	testing.expect(t, out[0].level == 2 && out[0].stamp == streams[1].stamp)
	count = texture_requests(r, out[:1], {2})
	testing.expect(t, count == 1 && out[0].handle == 3, "what is being read is left out")
	r.settings.texture_pool_megabytes, r.textures.bytes = 1, 2 << 20
	testing.expect_value(t, texture_requests(r, out[:], nil), 0)
}

// A request is answered only while the texture is the one it asked about.
@(test)
a_stream_forgets_its_texture_with_a_new_stamp :: proc(t: ^testing.T) {
	state: Texture_State
	resize(&state.residency.streams, 2)
	defer delete(state.residency.streams)
	data := Texture_Data{format = .RGBA8_Unorm, width = 256, height = 256, level = 2, source = {1024, 1024}}
	for _ in 0 ..< 9 {append(&data.levels, nil)}
	defer delete(data.levels)
	texture_stream_set(&state.residency.streams[0], data, 1)
	stream := state.residency.streams[0]
	testing.expect(t, stream.levels == 11 && stream.top == 3 && stream.target == 3, "levels of the source, and the first it holds")
	testing.expect(t, !stream.shown && stream.window == max(f32), "no frame sampled it yet")
	row, rows := rhi.format_rows(.RGBA8_Unorm, 1024, 1024)
	testing.expect_value(t, stream.chain[0] - stream.chain[1], row * rows)
	stamp := stream.stamp
	texture_stream_forget(&state, 0)
	testing.expect(t, state.residency.streams[0].levels == 0 && state.residency.streams[0].stamp == stamp + 1)
	testing.expect(t, state.residency.retarget)
}
