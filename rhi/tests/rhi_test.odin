package rhi_tests

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:math"
import "core:sync"
import "core:testing"
import "core:time"
import "core:thread"
import "mirai:rhi"
import "mirai:rhi/shared_device"

@(private = "file")
test_device :: proc(t: ^testing.T) -> ^rhi.Device {
	shared_device.hold(t)
	d, err := rhi.device_create({on_message = rhi.message_print, app_name = "mirai rhi tests", validation = true, allow_hardware_ray_tracing = true, upload_bytes_per_frame = 1 << 20})
	if d == nil {
		if rhi.gpu_skip_allowed() {fmt.eprintln("rhi tests skipped:", err); return nil}
		testing.expectf(t, false, "no GPU device: %s (set MIRAI_ALLOW_GPU_SKIP=1 to skip)", err)
		return nil
	}
	return d
}

@(private = "file")
expect_clean :: proc(t: ^testing.T, d: ^rhi.Device) {
	testing.expectf(t, rhi.device_validation_errors(d) == 0, "validation reported %d errors; last: %s", rhi.device_validation_errors(d), rhi.device_validation_message(d))
}

// A fill sets bytes on every backend: a value of 1 in a word of a dispatch
// would be 0x01010101 groups.
@(test)
rhi_fill_buffer_sets_every_byte_of_its_range_only :: proc(t: ^testing.T) {
	d := test_device(t)
	if d == nil {return}
	defer rhi.device_destroy(d)
	buffer := rhi.buffer_create(d, {size = 16, usage = {.Storage}, memory = .GPU, name = "fill"})
	testing.expect(t, buffer != 0, rhi.device_error(d))
	words := [4]u32{1, 2, 3, 4}
	testing.expect(t, rhi.buffer_upload_slice(d, buffer, 0, words[:]), rhi.device_error(d))
	cmd, ok := rhi.frame_begin(d)
	testing.expect(t, ok, rhi.device_error(d))
	if !ok {return}
	rhi.cmd_fill_buffer(cmd, buffer, 4, 8, 0xAB)
	testing.expect(t, rhi.frame_end(d, cmd), rhi.device_error(d))
	rhi.device_wait_idle(d)
	echo: [4]u32
	testing.expect(t, rhi.buffer_read_slice(d, buffer, 0, echo[:]), rhi.device_error(d))
	testing.expect_value(t, echo, [4]u32{1, 0xABABABAB, 0xABABABAB, 4})
	rhi.buffer_destroy(d, buffer)
	expect_clean(t, d)
}

// A loss stops every submission and wait at once, keeps its first cause,
// and the device is still destroyed cleanly.
@(test)
rhi_a_lost_device_fails_every_submission_and_wait_at_once :: proc(t: ^testing.T) {
	d := test_device(t)
	if d == nil {return}
	defer rhi.device_destroy(d)
	buffer := rhi.buffer_create(d, {size = 16, usage = {.Storage}, memory = .GPU, name = "lost"})
	testing.expect(t, buffer != 0, rhi.device_error(d))
	cmd, ok := rhi.frame_begin(d)
	testing.expect(t, ok, rhi.device_error(d))
	if !ok {return}
	rhi.cmd_fill_buffer(cmd, buffer, 0, 16, 1)
	rhi.device_lose(d)
	testing.expect(t, !rhi.frame_end(d, cmd), "the submission of the frame reports the loss")
	failure, text := rhi.device_failure(d)
	testing.expect_value(t, failure, rhi.Device_Failure.Lost)
	testing.expectf(t, text == "vkQueueSubmit2 reported the GPU device lost (provoked by device_lose)" || text == "the frame command buffer failed: the GPU device was lost (provoked by device_lose)", "the cause names the call that found it: %s", text)
	started := time.tick_now()
	_, began := rhi.frame_begin(d)
	testing.expect(t, !began, "no frame begins on a lost device")
	testing.expect(t, !rhi.device_wait_idle(d), "waiting for a lost device fails")
	words := [4]u32{1, 2, 3, 4}
	testing.expect(t, !rhi.buffer_upload_slice(d, buffer, 0, words[:]), "an upload through an immediate list fails")
	echo: [4]u32
	testing.expect(t, !rhi.buffer_read_slice(d, buffer, 0, echo[:]), "a readback fails")
	testing.expect(t, time.tick_since(started) < time.Second, "nothing waits for the GPU")
	rhi.device_lose(d)
	_, again := rhi.device_failure(d)
	testing.expect_value(t, again, text)
	rhi.buffer_destroy(d, buffer)
	expect_clean(t, d)
}

// A loss of an immediate list comes from its submission too.
@(test)
rhi_a_lost_immediate_list_reports_the_loss :: proc(t: ^testing.T) {
	d := test_device(t)
	if d == nil {return}
	defer rhi.device_destroy(d)
	buffer := rhi.buffer_create(d, {size = 16, usage = {.Storage}, memory = .GPU, name = "lost"})
	words := [4]u32{1, 2, 3, 4}
	rhi.device_lose(d)
	testing.expect(t, !rhi.buffer_upload_slice(d, buffer, 0, words[:]), "the upload reports the loss")
	failure, _ := rhi.device_failure(d)
	testing.expect_value(t, failure, rhi.Device_Failure.Lost)
	rhi.buffer_destroy(d, buffer)
	expect_clean(t, d)
}

@(test)
rhi_buffer_round_trip_and_compute :: proc(t: ^testing.T) {
	d := test_device(t)
	if d == nil {return}
	defer rhi.device_destroy(d)
	COUNT :: 1000
	input: [COUNT]f32
	for i in 0 ..< COUNT {input[i] = f32(i)}
	src := rhi.buffer_create(d, {size = size_of(input), usage = {.Storage}, memory = .GPU, name = "input"})
	dst := rhi.buffer_create(d, {size = size_of(input), usage = {.Storage}, memory = .GPU, name = "output"})
	testing.expect(t, src != 0 && dst != 0, rhi.device_error(d))
	testing.expect(t, rhi.buffer_upload_slice(d, src, 0, input[:]), rhi.device_error(d))
	echo: [COUNT]f32
	testing.expect(t, rhi.buffer_read_slice(d, src, 0, echo[:]), rhi.device_error(d))
	testing.expect_value(t, echo[999], f32(999))

	pipeline := rhi.pipeline_create_compute(d, {shader = rhi.test_shader("fill.comp"), name = "fill"})
	testing.expect(t, pipeline != 0, rhi.device_error(d))
	Params :: struct {count: u32, scale, offset: f32, pad: u32}
	// Two frames: the second dispatch reads the first one's output, so the
	// tracker must insert a write-to-read barrier between them.
	for pass in 0 ..< 2 {
		cmd, ok := rhi.frame_begin(d)
		testing.expect(t, ok, rhi.device_error(d))
		if !ok {return}
		params := Params{count = COUNT, scale = 2, offset = 1}
		rhi.cmd_bind_pipeline(cmd, pipeline)
		rhi.cmd_set_constants(cmd, 0, &params, size_of(params))
		rhi.cmd_bind_buffer(cmd, 1, src if pass == 0 else dst)
		rhi.cmd_bind_buffer(cmd, 2, dst if pass == 0 else src)
		rhi.cmd_dispatch(cmd, (COUNT + 63) / 64)
		testing.expect(t, rhi.frame_end(d, cmd), rhi.device_error(d))
	}
	rhi.device_wait_idle(d)
	result: [COUNT]f32
	testing.expect(t, rhi.buffer_read_slice(d, src, 0, result[:]), rhi.device_error(d))
	for i in 0 ..< COUNT {
		expected := (f32(i) * 2 + 1) * 2 + 1
		if result[i] != expected {
			testing.expectf(t, false, "element %d: %f != %f", i, result[i], expected)
			break
		}
	}
	rhi.pipeline_destroy(d, pipeline)
	rhi.buffer_destroy(d, src)
	rhi.buffer_destroy(d, dst)
	expect_clean(t, d)
}

@(test)
rhi_raster_uses_y_up_clip_space :: proc(t: ^testing.T) {
	d := test_device(t)
	if d == nil {return}
	defer rhi.device_destroy(d)
	SIZE :: 64
	target := rhi.texture_create(d, {width = SIZE, height = SIZE, format = .RGBA8_Unorm, usage = {.Color_Target, .Sampled, .Transfer_Src}, name = "target"})
	pipeline := rhi.pipeline_create_graphics(d, {
		vertex = rhi.test_shader("triangle.vert"), fragment = rhi.test_shader("triangle.frag"),
		color_formats = {0 = .RGBA8_Unorm}, color_count = 1, name = "triangle",
	})
	testing.expect(t, pipeline != 0 && target != 0, rhi.device_error(d))
	Vertex :: struct {position, color: [4]f32}
	// Red apex at NDC y=+1 must land on the first image rows.
	vertices := [3]Vertex{
		{{-0.8, -0.8, 0.5, 1}, {0, 0, 1, 1}},
		{{0.8, -0.8, 0.5, 1}, {0, 0, 1, 1}},
		{{0, 0.9, 0.5, 1}, {1, 0, 0, 1}},
	}
	buffer := rhi.buffer_create(d, {size = size_of(vertices), usage = {.Storage}, memory = .GPU, name = "vertices"})
	rhi.buffer_upload_slice(d, buffer, 0, vertices[:])
	cmd, ok := rhi.frame_begin(d)
	testing.expect(t, ok)
	if !ok {return}
	rhi.cmd_barrier_buffer(cmd, buffer, .Shader_Read)
	pass := rhi.Render_Pass_Desc{color_count = 1, name = "triangle"}
	pass.colors[0] = {texture = target, load = .Clear, store = .Store, clear = {0, 0.5, 0, 1}}
	rhi.cmd_begin_render_pass(cmd, &pass)
	rhi.cmd_bind_pipeline(cmd, pipeline)
	rhi.cmd_bind_buffer(cmd, 0, buffer)
	rhi.cmd_draw(cmd, 3)
	rhi.cmd_end_render_pass(cmd)
	testing.expect(t, rhi.frame_end(d, cmd), rhi.device_error(d))
	rhi.device_wait_idle(d)
	pixels: [SIZE * SIZE * 4]u8
	testing.expect(t, rhi.texture_read(d, target, pixels[:]), rhi.device_error(d))
	top := (6 * SIZE + SIZE / 2) * 4
	bottom := ((SIZE - 8) * SIZE + SIZE / 2) * 4
	testing.expectf(t, pixels[top] > 150 && pixels[top + 2] < 120, "apex color near the top row: %v", pixels[top:top + 4])
	testing.expectf(t, pixels[bottom + 2] > 150 && pixels[bottom] < 120, "base color near the bottom row: %v", pixels[bottom:bottom + 4])
	testing.expectf(t, pixels[1] > 100 && pixels[0] < 10, "clear color outside the triangle: %v", pixels[0:4])
	rhi.buffer_destroy(d, buffer)
	rhi.texture_destroy(d, target)
	rhi.pipeline_destroy(d, pipeline)
	expect_clean(t, d)
}

@(test)
rhi_storage_image_after_upload_and_frames :: proc(t: ^testing.T) {
	d := test_device(t)
	if d == nil {return}
	defer rhi.device_destroy(d)
	SIZE :: 16
	source := rhi.texture_create(d, {width = SIZE, height = SIZE, format = .RGBA8_Unorm, usage = {.Sampled}, name = "source"})
	target := rhi.texture_create(d, {width = SIZE, height = SIZE, format = .RGBA16_Float, usage = {.Storage, .Sampled, .Transfer_Src}, name = "target"})
	sampler := rhi.sampler_create(d, {filter = .Nearest, name = "point"})
	pixels: [SIZE * SIZE * 4]u8
	for i in 0 ..< SIZE * SIZE {pixels[i * 4] = 100; pixels[i * 4 + 1] = 50; pixels[i * 4 + 3] = 255}
	testing.expect(t, rhi.texture_upload(d, source, pixels[:], SIZE * 4), rhi.device_error(d))
	pipeline := rhi.pipeline_create_compute(d, {shader = rhi.test_shader("image.comp"), name = "image"})
	// Several frames in flight reuse ring memory and the same image.
	for _ in 0 ..< 5 {
		cmd, ok := rhi.frame_begin(d)
		testing.expect(t, ok)
		if !ok {return}
		rhi.cmd_timestamp(cmd, "image")
		rhi.cmd_bind_pipeline(cmd, pipeline)
		rhi.cmd_bind_texture(cmd, 0, source)
		rhi.cmd_bind_sampler(cmd, 1, sampler)
		rhi.cmd_bind_texture(cmd, 2, target)
		rhi.cmd_dispatch(cmd, SIZE / 8, SIZE / 8)
		rhi.cmd_timestamp(cmd, "end")
		testing.expect(t, rhi.frame_end(d, cmd))
	}
	rhi.device_wait_idle(d)
	out: [SIZE * SIZE * 8]u8
	testing.expect(t, rhi.texture_read(d, target, out[:]), rhi.device_error(d))
	halves := transmute([SIZE * SIZE * 4]u16)out
	red := half_to_f32(halves[0])
	testing.expectf(t, math.abs(red - 200.0 / 255.0) < 0.01, "storage image result %f", red)
	rhi.pipeline_destroy(d, pipeline)
	rhi.sampler_destroy(d, sampler)
	rhi.texture_destroy(d, source)
	rhi.texture_destroy(d, target)
	expect_clean(t, d)
}

@(private = "file")
half_to_f32 :: proc(h: u16) -> f32 {
	return f32(transmute(f16)h)
}

@(test)
rhi_texture_table_is_indexed_per_invocation :: proc(t: ^testing.T) {
	d := test_device(t)
	if d == nil {return}
	defer rhi.device_destroy(d)
	red := rhi.texture_create(d, {width = 2, height = 2, mip_levels = 2, format = .RGBA8_Unorm, usage = {.Sampled}, name = "red"})
	gray := rhi.texture_create(d, {width = 1, height = 1, format = .RGBA8_Srgb, usage = {.Sampled}, name = "srgb gray"})
	testing.expect(t, red != 0 && gray != 0, rhi.device_error(d))
	red_pixels := [16]u8{255, 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255}
	blue_pixel := [4]u8{0, 0, 255, 255}
	gray_pixel := [4]u8{128, 128, 128, 255}
	testing.expect(t, rhi.texture_upload(d, red, red_pixels[:], 8), rhi.device_error(d))
	testing.expect(t, rhi.texture_upload(d, red, blue_pixel[:], 4, 1), rhi.device_error(d))
	testing.expect(t, rhi.texture_upload(d, gray, gray_pixel[:], 4), rhi.device_error(d))
	testing.expect(t, rhi.texture_table_set(d, 3, red), rhi.device_error(d))
	testing.expect(t, rhi.texture_table_set(d, rhi.TEXTURE_TABLE_FIRST - 1, gray), rhi.device_error(d))
	testing.expect(t, !rhi.texture_table_set(d, u32(rhi.texture_table_limit(d)), gray), "an index past what the table grows to is rejected")
	target := rhi.texture_create(d, {width = 1, height = 1, format = .RGBA8_Unorm, usage = {.Sampled, .Color_Target}, name = "target"})
	testing.expect(t, !rhi.texture_table_set(d, 4, target), "a render target cannot enter the table")

	sampler := rhi.sampler_create(d, {filter = .Linear, mip_filter = .Linear, address = .Repeat, anisotropy = 8, name = "table"})
	pipeline := rhi.pipeline_create_compute(d, {shader = rhi.test_shader("table.comp"), name = "table"})
	queries := rhi.buffer_create(d, {size = 8 * size_of([4]f32), usage = {.Storage}, name = "queries"})
	results := rhi.buffer_create(d, {size = 8 * size_of([4]f32), usage = {.Storage}, name = "results"})
	testing.expect(t, sampler != 0 && pipeline != 0 && queries != 0 && results != 0, rhi.device_error(d))
	// uv, table index, lod
	last :: f32(rhi.TEXTURE_TABLE_FIRST - 1)
	input := [8][4]f32{{0.5, 0.5, 3, 0}, {0.5, 0.5, 3, 1}, {0.5, 0.5, last, 0}, {0.5, 0.5, 0, 0}, {0.5, 0.5, 3, 0}, {0.5, 0.5, last, 0}, {0.5, 0.5, 50, 0}, {7.5, -3.5, 3, 0}}
	testing.expect(t, rhi.buffer_upload_slice(d, queries, 0, input[:]), rhi.device_error(d))
	run :: proc(t: ^testing.T, d: ^rhi.Device, pipeline: rhi.Pipeline, sampler: rhi.Sampler, queries, results: rhi.Buffer) -> (output: [8][4]f32) {
		cmd, ok := rhi.frame_begin(d)
		testing.expect(t, ok, rhi.device_error(d))
		if !ok {return}
		rhi.cmd_bind_pipeline(cmd, pipeline)
		rhi.cmd_bind_sampler(cmd, 2, sampler)
		rhi.cmd_bind_buffer(cmd, 3, queries)
		rhi.cmd_bind_buffer(cmd, 4, results)
		rhi.cmd_dispatch(cmd, 1)
		testing.expect(t, rhi.frame_end(d, cmd), rhi.device_error(d))
		rhi.device_wait_idle(d)
		testing.expect(t, rhi.buffer_read_slice(d, results, 0, output[:]), rhi.device_error(d))
		return
	}
	near :: proc(a, b: [4]f32) -> bool {
		for i in 0 ..< 4 {if abs(a[i] - b[i]) > 0.01 {return false}}
		return true
	}
	output := run(t, d, pipeline, sampler, queries, results)
	testing.expectf(t, near(output[0], {1, 0, 0, 1}), "entry 3, mip 0: %v", output[0])
	testing.expectf(t, near(output[1], {0, 0, 1, 1}), "entry 3, mip 1: %v", output[1])
	testing.expectf(t, near(output[2], {0.2158, 0.2158, 0.2158, 1}), "an sRGB texture is decoded to linear: %v", output[2])
	testing.expectf(t, near(output[3], {1, 1, 1, 1}), "an entry never set is white: %v", output[3])
	testing.expectf(t, near(output[4], {1, 0, 0, 1}) && near(output[5], output[2]), "neighbouring invocations keep their own entries: %v %v", output[4], output[5])
	testing.expectf(t, near(output[7], {1, 0, 0, 1}), "coordinates outside 0..1 repeat: %v", output[7])

	// An entry past the table, after frames read it, grows it twice; the
	// entries it had keep their textures and the new ones start white.
	far :: rhi.TEXTURE_TABLE_FIRST * 3 + 1
	testing.expect(t, rhi.texture_table_set(d, far, red), rhi.device_error(d))
	input[6] = {0.5, 0.5, f32(far), 0}
	input[3] = {0.5, 0.5, f32(far - 1), 0}
	testing.expect(t, rhi.buffer_upload_slice(d, queries, 0, input[:]), rhi.device_error(d))
	output = run(t, d, pipeline, sampler, queries, results)
	testing.expectf(t, near(output[6], {1, 0, 0, 1}), "an entry the table grew to: %v", output[6])
	testing.expectf(t, near(output[0], {1, 0, 0, 1}) && near(output[2], {0.2158, 0.2158, 0.2158, 1}), "the entries before it stay: %v %v", output[0], output[2])
	testing.expectf(t, near(output[3], {1, 1, 1, 1}), "an entry the table grew without setting is white: %v", output[3])

	// A destroyed texture leaves its entries white instead of dangling.
	rhi.texture_destroy(d, red)
	output = run(t, d, pipeline, sampler, queries, results)
	testing.expectf(t, near(output[0], {1, 1, 1, 1}) && near(output[6], {1, 1, 1, 1}), "entries 3 and far after their texture was destroyed: %v %v", output[0], output[6])
	testing.expectf(t, near(output[2], {0.2158, 0.2158, 0.2158, 1}), "the other entries stay: %v", output[2])
	expect_clean(t, d)
}

// Pipelines made on other threads while the render thread records frames
// with another one, as a reload of the shaders does: every one is made, and
// the device holds them as if one thread had made them.
@(test)
rhi_pipelines_are_made_on_other_threads_while_frames_are_recorded :: proc(t: ^testing.T) {
	d := test_device(t)
	if d == nil {return}
	defer rhi.device_destroy(d)
	THREADS :: 3
	EACH :: 8
	Maker :: struct {d: ^rhi.Device, pipelines: [2 * EACH]rhi.Pipeline}
	make_pipelines :: proc(m: ^Maker) {
		defer free_all(context.temp_allocator)
		for i in 0 ..< EACH {
			m.pipelines[2 * i] = rhi.pipeline_create_compute(m.d, {shader = rhi.test_shader("fill.comp"), name = "fill on a thread"})
			m.pipelines[2 * i + 1] = rhi.pipeline_create_graphics(m.d, {
				vertex = rhi.test_shader("triangle.vert"), fragment = rhi.test_shader("triangle.frag"),
				color_formats = {0 = .RGBA8_Unorm}, color_count = 1, name = "triangle on a thread",
			})
		}
	}
	fill := rhi.pipeline_create_compute(d, {shader = rhi.test_shader("fill.comp"), name = "fill"})
	values := [64]f32{}
	buffer := rhi.buffer_create(d, {size = size_of(values), usage = {.Storage}, memory = .GPU, name = "values"})
	testing.expect(t, fill != 0 && buffer != 0, rhi.device_error(d))
	makers: [THREADS]Maker
	threads: [THREADS]^thread.Thread
	for &maker, i in makers {
		maker.d = d
		threads[i] = thread.create_and_start_with_poly_data(&maker, make_pipelines)
	}
	Params :: struct {count: u32, scale, offset: f32, pad: u32}
	for _ in 0 ..< 16 {
		cmd, ok := rhi.frame_begin(d)
		testing.expect(t, ok, rhi.device_error(d))
		if !ok {break}
		params := Params{count = len(values), scale = 1, offset = 1}
		rhi.cmd_bind_pipeline(cmd, fill)
		rhi.cmd_set_constants(cmd, 0, &params, size_of(params))
		rhi.cmd_bind_buffer(cmd, 1, buffer)
		rhi.cmd_bind_buffer(cmd, 2, buffer)
		rhi.cmd_dispatch(cmd, 1)
		testing.expect(t, rhi.frame_end(d, cmd), rhi.device_error(d))
	}
	for worker in threads {
		thread.join(worker)
		thread.destroy(worker)
	}
	seen := make(map[rhi.Pipeline]bool, context.temp_allocator)
	for maker in makers {
		for pipeline in maker.pipelines {
			testing.expect(t, pipeline != 0 && !seen[pipeline], "every pipeline is made, each with a handle of its own")
			seen[pipeline] = true
		}
	}
	testing.expect_value(t, rhi.device_stats(d).pipelines, 1 + THREADS * 2 * EACH)
	for maker in makers {for pipeline in maker.pipelines {rhi.pipeline_destroy(d, pipeline)}}
	rhi.pipeline_destroy(d, fill)
	rhi.buffer_destroy(d, buffer)
	rhi.device_wait_idle(d)
	testing.expect_value(t, rhi.device_stats(d).pipelines, 0)
	expect_clean(t, d)
}

// Devices made and destroyed at the same time by several threads, as the
// tests of a package or the sessions of a tool do: the loader lock of the
// application keeps the Vulkan loader to one of them at a time.
@(test)
rhi_devices_are_created_and_destroyed_on_several_threads_with_one_loader_lock :: proc(t: ^testing.T) {
	THREADS :: 4
	ROUNDS :: 3
	Shared :: struct {
		lock:                               sync.Mutex,
		created, refused, wrong, complaints: i64,
	}
	work :: proc(shared: ^Shared) {
		defer free_all(context.temp_allocator)
		for round in 0 ..< ROUNDS {
			d, _ := rhi.device_create({app_name = "mirai rhi threads", validation = true, upload_bytes_per_frame = 1 << 20, loader_lock = &shared.lock})
			if d == nil {
				intrinsics.atomic_add(&shared.refused, 1)
				continue
			}
			values, echo: [256]u32
			for &value, at in values {value = u32(at * (round + 3))}
			buffer := rhi.buffer_create(d, {size = size_of(values), usage = {.Storage}, memory = .GPU, name = "threads"})
			if buffer == 0 || !rhi.buffer_upload_slice(d, buffer, 0, values[:]) || !rhi.buffer_read_slice(d, buffer, 0, echo[:]) || echo != values {
				intrinsics.atomic_add(&shared.wrong, 1)
			}
			intrinsics.atomic_add(&shared.complaints, i64(rhi.device_validation_errors(d)))
			rhi.device_destroy(d)
			intrinsics.atomic_add(&shared.created, 1)
		}
	}
	// One device first: without a GPU the test has nothing to say.
	first := test_device(t)
	if first == nil {return}
	rhi.device_destroy(first)
	shared: Shared
	threads: [THREADS]^thread.Thread
	for &worker in threads {worker = thread.create_and_start_with_poly_data(&shared, work)}
	for worker in threads {
		thread.join(worker)
		thread.destroy(worker)
	}
	testing.expect_value(t, shared.created, THREADS * ROUNDS)
	testing.expect_value(t, shared.refused, 0)
	testing.expect_value(t, shared.wrong, 0)
	testing.expect_value(t, shared.complaints, 0)
}

@(test)
a_shared_texture_shows_on_another_device_what_its_owner_wrote :: proc(t: ^testing.T) {
	owner := test_device(t)
	if owner == nil {return}
	defer rhi.device_destroy(owner)
	other := test_device(t)
	if other == nil {return}
	defer rhi.device_destroy(other)
	if !rhi.device_shares_textures(owner) {fmt.eprintln("shared textures skipped: the device cannot share them"); return}
	SIDE :: 8
	desc := rhi.Texture_Desc{width = SIDE, height = SIDE, format = .BGRA8_Srgb, usage = {.Color_Target, .Sampled}, name = "shared"}
	texture, shared := rhi.texture_create_shared(owner, desc)
	testing.expect(t, texture != 0 && shared != 0, rhi.device_error(owner))
	pixels: [SIDE * SIDE * 4]u8
	for &p, i in pixels {p = u8(i * 7)}
	testing.expect(t, rhi.texture_upload(owner, texture, pixels[:], SIDE * 4), rhi.device_error(owner))
	// Its owner leaves it ready to be sampled, as the renderer does with its output.
	cmd := rhi.immediate_begin(owner)
	rhi.cmd_barrier_texture(cmd, texture, .Shader_Read)
	testing.expect(t, rhi.immediate_end(owner, cmd))
	opened := rhi.texture_open_shared(other, {width = SIDE, height = SIDE, format = .BGRA8_Srgb, usage = {.Sampled}, name = "opened"}, shared)
	testing.expect(t, opened != 0, rhi.device_error(other))
	seen: [SIDE * SIDE * 4]u8
	testing.expect(t, rhi.texture_read(other, opened, seen[:]), rhi.device_error(other))
	testing.expect(t, seen == pixels, "the opened texture holds what its owner wrote")
	testing.expect(t, rhi.texture_open_shared(other, {width = SIDE * 2, height = SIDE, format = .BGRA8_Srgb, usage = {.Sampled}, name = "wrong"}, shared) == 0, "another size is refused")
	testing.expect(t, rhi.texture_open_shared(other, {width = SIDE, height = SIDE, format = .RGBA8_Unorm, usage = {.Sampled}, name = "wrong"}, shared) == 0, "another format is refused")
	rhi.texture_destroy(other, opened)
	rhi.texture_destroy(owner, texture)
	expect_clean(t, owner)
	expect_clean(t, other)
}

// A region of a texture takes the texels given and leaves the rest as it was;
// one outside the mip, or across the blocks of a compressed format, is refused.
@(test)
rhi_texture_upload_writes_a_region_alone :: proc(t: ^testing.T) {
	d := test_device(t)
	if d == nil {return}
	defer rhi.device_destroy(d)
	SIZE :: 8
	texture := rhi.texture_create(d, {width = SIZE, height = SIZE, format = .RGBA8_Unorm, usage = {.Sampled, .Transfer_Src}, name = "regions"})
	testing.expect(t, texture != 0, rhi.device_error(d))
	gray: [SIZE * SIZE * 4]u8
	for &b in gray {b = 40}
	testing.expect(t, rhi.texture_upload(d, texture, gray[:], SIZE * 4), rhi.device_error(d))
	// The texels of the region in an image of the whole texture, rows SIZE*4 apart.
	whole: [SIZE * SIZE * 4]u8
	for y in 2 ..< 5 {for x in 3 ..< 7 {whole[(y * SIZE + x) * 4] = 200; whole[(y * SIZE + x) * 4 + 3] = 255}}
	region := rhi.Texture_Region{3, 2, 4, 3}
	testing.expect(t, rhi.texture_upload(d, texture, whole[(2 * SIZE + 3) * 4:], SIZE * 4, 0, region), rhi.device_error(d))
	out: [SIZE * SIZE * 4]u8
	testing.expect(t, rhi.texture_read(d, texture, out[:]), rhi.device_error(d))
	for y in 0 ..< SIZE {
		for x in 0 ..< SIZE {
			inside := x >= 3 && x < 7 && y >= 2 && y < 5
			testing.expectf(t, out[(y * SIZE + x) * 4] == (200 if inside else 40), "texel %d,%d is %d", x, y, out[(y * SIZE + x) * 4])
		}
	}
	testing.expect(t, !rhi.texture_upload(d, texture, whole[:], SIZE * 4, 0, {6, 0, 4, 1}), "a region past the edge")
	desc := rhi.Texture_Desc{width = 16, height = 16, format = .BC1_Unorm}
	_, whole_blocks := rhi.texture_region_resolve(desc, 0, {4, 8, 8, 4})
	_, cut := rhi.texture_region_resolve(desc, 0, {2, 0, 4, 4})
	testing.expect(t, whole_blocks && !cut, "a compressed region keeps whole blocks")
	resolved, _ := rhi.texture_region_resolve(desc, 1, {})
	testing.expect_value(t, resolved, rhi.Texture_Region{0, 0, 8, 8})
	rhi.texture_destroy(d, texture)
	expect_clean(t, d)
}

// A cube and an array take every layer of each level in one upload, as
// HDR or 16-bit texels and as BC6H where the device samples blocks; the
// table of 2D textures refuses them, and a cube needs square faces.
@(test)
rhi_cubes_and_arrays_take_every_layer_of_each_level :: proc(t: ^testing.T) {
	d := test_device(t)
	if d == nil {return}
	defer rhi.device_destroy(d)
	SIDE :: 4
	cube := rhi.texture_create(d, {width = SIDE, height = SIDE, layers = 6, cube = true, mip_levels = 2, format = .RGBA16_Float, usage = {.Sampled, .Transfer_Src}, name = "cube"})
	testing.expect(t, cube != 0, rhi.device_error(d))
	faces: [SIDE * SIDE * 8 * 6]u8
	for face in 0 ..< 6 {for at in 0 ..< SIDE * SIDE {faces[(face * SIDE * SIDE + at) * 8 + 1] = u8(0x3c + face)}}
	testing.expect(t, rhi.texture_upload(d, cube, faces[:], SIDE * 8), rhi.device_error(d))
	testing.expect(t, rhi.texture_upload(d, cube, faces[:2 * 2 * 8 * 6], 2 * 8, 1), rhi.device_error(d))
	testing.expect(t, !rhi.texture_upload(d, cube, faces[:SIDE * SIDE * 8 * 5], SIDE * 8), "the data of five faces does not fill a cube")
	out: [SIDE * SIDE * 8]u8
	testing.expect(t, rhi.texture_read(d, cube, out[:]), rhi.device_error(d))
	testing.expect_value(t, out[1], u8(0x3c))
	testing.expect(t, !rhi.texture_table_set(d, 0, cube), "the table holds 2D textures of one layer")
	rhi.texture_destroy(d, cube)

	array := rhi.texture_create(d, {width = SIDE, height = 2, layers = 3, format = .RGBA16_Unorm, usage = {.Sampled}, name = "array"})
	testing.expect(t, array != 0, rhi.device_error(d))
	layers: [SIDE * 2 * 8 * 3]u8
	testing.expect(t, rhi.texture_upload(d, array, layers[:], SIDE * 8), rhi.device_error(d))
	rhi.texture_destroy(d, array)
	testing.expect(t, rhi.texture_create(d, {width = SIDE, height = 2, layers = 6, cube = true, format = .RGBA8_Unorm, usage = {.Sampled}, name = "flat cube"}) == 0, "a cube has square faces")

	if rhi.device_info(d).features.texture_bc {
		hdr := rhi.texture_create(d, {width = SIDE, height = SIDE, layers = 6, cube = true, format = .BC6H_Ufloat, usage = {.Sampled}, name = "hdr cube"})
		testing.expect(t, hdr != 0, rhi.device_error(d))
		blocks: [16 * 6]u8
		for face in 0 ..< 6 {blocks[face * 16] = 0b00011}
		testing.expect(t, rhi.texture_upload(d, hdr, blocks[:], 16), rhi.device_error(d))
		rhi.texture_destroy(d, hdr)
	}
	expect_clean(t, d)
}

@(test)
rhi_timestamps_report_ordered_nanoseconds :: proc(t: ^testing.T) {
	d := test_device(t)
	if d == nil {return}
	defer rhi.device_destroy(d)
	buffer := rhi.buffer_create(d, {size = 1 << 20, usage = {.Storage, .Transfer_Dst}, name = "timestamps"})
	defer rhi.buffer_destroy(d, buffer)
	// Records frames until one collects the timings of a frame recorded with the wish asked.
	timings_of :: proc(t: ^testing.T, d: ^rhi.Device, buffer: rhi.Buffer, wanted: bool, idle: ^i64 = nil) -> []rhi.Gpu_Timing {
		rhi.timestamps_want(d, wanted)
		for _ in 0 ..< rhi.MAX_FRAMES_IN_FLIGHT + 1 {
			cmd, ok := rhi.frame_begin(d, false)
			if !testing.expect(t, ok) {return nil}
			rhi.cmd_timestamp(cmd, "fill")
			rhi.cmd_fill_buffer(cmd, buffer, 0, 1 << 20, 7)
			rhi.cmd_timestamp(cmd, "again")
			rhi.cmd_fill_buffer(cmd, buffer, 0, 1 << 20, 9)
			rhi.cmd_timestamp(cmd, "end")
			testing.expect(t, rhi.frame_end(d, cmd))
		}
		rhi.device_wait_idle(d)
		if idle != nil {idle^ = time.duration_nanoseconds(time.tick_diff({}, time.tick_now()))}
		cmd, ok := rhi.frame_begin(d, false)
		if !testing.expect(t, ok) {return nil}
		testing.expect(t, rhi.frame_end(d, cmd))
		return rhi.frame_timings(d)
	}
	now := time.duration_nanoseconds(time.tick_diff({}, time.tick_now()))
	frame := timings_of(t, d, buffer, false)
	if testing.expect_value(t, len(frame), 1) {
		testing.expect_value(t, frame[0].name, "frame")
		testing.expect(t, frame[0].end_ns >= frame[0].start_ns && frame[0].start_ns > now - i64(time.Second), "the frame is on the clock of time.tick_now")
	}
	if !d.info.features.timestamps {
		fmt.eprintln("rhi pass timestamps skipped: the device does not support them")
		expect_clean(t, d)
		return
	}
	idle: i64
	passes := timings_of(t, d, buffer, true, &idle)
	if testing.expect_value(t, len(passes), 2) {
		testing.expect_value(t, passes[0].name, "fill")
		testing.expect_value(t, passes[1].name, "again")
	}
	previous: i64
	for timing in passes {
		testing.expectf(t, timing.end_ns >= timing.start_ns, "%s: %d..%d", timing.name, timing.start_ns, timing.end_ns)
		testing.expectf(t, timing.start_ns >= previous, "%s starts at %d before the previous end %d", timing.name, timing.start_ns, previous)
		testing.expectf(t, timing.start_ns > now - i64(time.Second), "%s is on the clock of time.tick_now", timing.name)
		previous = timing.end_ns
		// Placed by when they were collected, they would end after the GPU went idle.
		if rhi.device_timestamps_calibrated(d) {testing.expectf(t, timing.end_ns <= idle, "%s ends at %d, after the GPU went idle at %d", timing.name, timing.end_ns, idle)}
	}
	rhi.timestamps_want(d, false)
	expect_clean(t, d)
}

// An allocator that serves `remaining` requests of its owner and refuses the rest.
@(private="file")
Memory_Limit :: struct {owner:runtime.Allocator,remaining:int}

@(private="file")
memory_limit_proc :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
    limit:=(^Memory_Limit)(data)
    if mode==.Alloc || mode==.Alloc_Non_Zeroed || mode==.Resize || mode==.Resize_Non_Zeroed {
        if limit.remaining<=0 {return nil,.Out_Of_Memory}
        limit.remaining-=1
    }
    return limit.owner.procedure(limit.owner.data,mode,size,alignment,old_memory,old_size,loc)
}

// What a device asks its allocator for, to be created and to grow its texture
// table, with the memory ending at each request in turn: the call is refused
// with a message that says so and leaves a device that works, and with memory
// enough it goes through.
@(test)
rhi_device_without_memory_is_refused_and_keeps_its_texture_table :: proc(t:^testing.T) {
    shared_device.hold(t)
    limit:=Memory_Limit{owner=context.allocator,remaining=max(int)}
    limited:=runtime.Allocator{memory_limit_proc,&limit}
    desc:=rhi.Device_Desc{app_name="mirai rhi memory tests",validation=true,upload_bytes_per_frame=1<<20,capacities={buffers=16,textures=16,samplers=4,pipelines=4,accels=4,deletions=16},allocator=limited}
    d:^rhi.Device
    defer if d!=nil {rhi.device_destroy(d)}
    texture:rhi.Texture
    Step :: enum {Create,Table}
    for step in Step {
        done,refused:=false,false
        for served in 0..<96 {
            message:string
            limit.remaining=served
            switch step {
            case .Create:
                d,message=rhi.device_create(desc)
                done=d!=nil
            case .Table:
                done=rhi.texture_table_set(d,rhi.TEXTURE_TABLE_FIRST,texture)
                message=rhi.device_error(d)
            }
            limit.remaining=max(int)
            if done {break}
            if !strings.contains(message,"out of memory") {
                // Another refusal than the one of the allocator: there is no device to test with.
                if step==.Create && rhi.gpu_skip_allowed() {fmt.eprintln("rhi tests skipped:",message)} else {testing.expectf(t,false,"%v with %d requests served: %s",step,served,message)}
                return
            }
            refused=true
            if step==.Table {testing.expectf(t,rhi.texture_table_set(d,0,texture),"the table of before takes an entry with %d requests served: %s",served,rhi.device_error(d))}
        }
        if !testing.expectf(t,done && refused,"%v: refused without memory, and with it it goes through",step) {return}
        if step==.Create {
            texture=rhi.texture_create(d,{width=1,height=1,format=.RGBA8_Unorm,usage={.Sampled},name="entry"})
            white:=[4]u8{255,255,255,255}
            if !testing.expect(t,texture!=0 && rhi.texture_upload(d,texture,white[:],4),rhi.device_error(d)) {return}
            if !testing.expect(t,rhi.texture_table_limit(d)>rhi.TEXTURE_TABLE_FIRST,"the device holds a table that grows") {return}
        }
    }
    testing.expect_value(t,rhi.device_validation_errors(d),0)
}
