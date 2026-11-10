#+build linux, windows
package rhi_tests

import "core:fmt"
import "core:testing"
import "mirai:rhi"
import "mirai:rhi/shared_device"
import "mirai:std/base"
import vk "vendor:vulkan"

// Meta-test: proves the validation setup sees hazards on descriptor accesses
// (syncval_shader_accesses_heuristic), so "zero validation errors" in the
// other GPU tests is meaningful. The tracker state is cleared on purpose to
// drop the barrier between a compute write and a dependent compute read.
@(test)
rhi_validation_detects_a_missing_barrier :: proc(t: ^testing.T) {
	d := shared_device.create_or_skip(t, {on_message = rhi.message_print, app_name = "mirai validation meta test", validation = true, upload_bytes_per_frame = 1 << 20})
	if d == nil {return}
	defer rhi.device_destroy(d)
	if !d.info.features.validation {return} // no validation layer installed
	COUNT :: 256
	a := rhi.buffer_create(d, {size = COUNT * 4, usage = {.Storage}, name = "a"})
	b := rhi.buffer_create(d, {size = COUNT * 4, usage = {.Storage}, name = "b"})
	c := rhi.buffer_create(d, {size = COUNT * 4, usage = {.Storage}, name = "c"})
	pipeline := rhi.pipeline_create_compute(d, {shader = rhi.test_shader("fill.comp"), name = "fill"})
	Params :: struct {count: u32, scale, offset: f32, pad: u32}
	params := Params{count = COUNT, scale = 1, offset = 1}
	cmd, ok := rhi.frame_begin(d)
	testing.expect(t, ok)
	if !ok {return}
	rhi.cmd_bind_pipeline(cmd, pipeline)
	rhi.cmd_set_constants(cmd, 0, &params, size_of(params))
	rhi.cmd_bind_buffer(cmd, 1, a)
	rhi.cmd_bind_buffer(cmd, 2, b)
	rhi.cmd_dispatch(cmd, COUNT / 64)
	rhi.pool_get(&d.buffers, base.Handle(b)).write = .None // simulate a tracker bug
	rhi.cmd_bind_buffer(cmd, 1, b)
	rhi.cmd_bind_buffer(cmd, 2, c)
	rhi.cmd_dispatch(cmd, COUNT / 64)
	rhi.frame_end(d, cmd)
	rhi.device_wait_idle(d)
	testing.expect(t, rhi.device_validation_errors(d) > 0, "synchronization validation must report the read-after-write hazard")
	// Expected errors are consumed so the device teardown stays quiet.
	d.validation_errors = 0
	rhi.pipeline_destroy(d, pipeline)
	rhi.buffer_destroy(d, a)
	rhi.buffer_destroy(d, b)
	rhi.buffer_destroy(d, c)
}

