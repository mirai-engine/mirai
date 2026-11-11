#+build linux, windows
package rhi_tests

import "core:fmt"
import "core:os"
import "core:testing"
import "mirai:rhi"
import "mirai:rhi/shared_device"
import "mirai:std/base"

// Runs that create the same pipelines read back what the first compiled and
// leave the file as it was: it does not grow run after run. A file it cannot
// read, such as a driver blob of before, is replaced.
@(test)
rhi_kept_pipelines_are_read_back_and_do_not_grow :: proc(t: ^testing.T) {
	folder := base.test_folder(t, "pipeline-store")
	if folder == "" {return}
	path := fmt.tprintf("%s/pipelines.bin", folder)
	before := [?]u8{32, 0, 0, 0, 1, 0, 0, 0, 0xde, 0x10, 0, 0}
	testing.expect_value(t, os.write_entire_file(path, before[:]), nil)
	sizes: [3]i64
	for run in 0 ..< len(sizes) {
		d := shared_device.create_or_skip(t, {on_message = rhi.message_print, app_name = "mirai pipeline store test", validation = true, upload_bytes_per_frame = 1 << 20, pipeline_cache_path = path})
		if d == nil {return}
		compute := rhi.pipeline_create_compute(d, {shader = rhi.test_shader("fill.comp"), name = "fill"})
		graphics := rhi.pipeline_create_graphics(d, {
			vertex = rhi.test_shader("triangle.vert"), fragment = rhi.test_shader("triangle.frag"),
			color_formats = {0 = .RGBA8_Unorm}, color_count = 1, name = "triangle",
		})
		testing.expect(t, compute != 0 && graphics != 0, rhi.device_error(d))
		testing.expectf(t, len(d.pipelines_kept.entries) == 2, "run %d keeps one entry per pipeline", run)
		testing.expectf(t, (d.pipelines_kept.file != nil) == (run > 0), "run %d reads the file of the run before", run)
		rhi.pipeline_destroy(d, compute)
		rhi.pipeline_destroy(d, graphics)
		rhi.device_destroy(d)
		info, error := os.stat(path, context.temp_allocator)
		if !testing.expect(t, error == nil) {return}
		sizes[run] = info.size
	}
	testing.expectf(t, sizes[0] > i64(len(before)) && sizes[1] == sizes[0] && sizes[2] == sizes[0], "the file stays as the first run wrote it: %v", sizes)
}
