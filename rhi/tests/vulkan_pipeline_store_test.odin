#+build linux, windows
package rhi_tests

import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"
import "mirai:project"
import "mirai:rhi"
import "mirai:rhi/shared_device"
import "mirai:std/base"

// Runs that create the same pipelines read back what the first compiled and
// leave the file as it was: it does not grow run after run. A file it cannot
// read, such as a driver blob of before, is replaced. Without a file, a device
// keeps them in memory: a pipeline created again finds what it compiled.
@(test)
rhi_kept_pipelines_are_read_back_and_do_not_grow :: proc(t: ^testing.T) {
	{
		d := shared_device.create_or_skip(t, {on_message = rhi.message_print, app_name = "mirai pipeline store test", validation = true, upload_bytes_per_frame = 1 << 20})
		if d == nil {return}
		for _ in 0 ..< 2 {
			p := rhi.pipeline_create_compute(d, {shader = rhi.test_shader("fill.comp"), name = "fill"})
			testing.expect(t, p != 0, rhi.device_error(d))
			rhi.pipeline_destroy(d, p)
		}
		testing.expectf(t, len(d.pipelines_kept.entries) == 1 && d.pipelines_kept.uses >= 2, "without a file the second pipeline finds the first in memory: %d entries, %d uses", len(d.pipelines_kept.entries), d.pipelines_kept.uses)
		rhi.device_destroy(d)
	}
	folder := base.test_folder(t, "pipeline-store")
	if folder == "" {return}
	path := fmt.tprintf("%s/pipelines.bin", folder)
	before := [?]u8{32, 0, 0, 0, 1, 0, 0, 0, 0xde, 0x10, 0, 0}
	testing.expect_value(t, os.write_entire_file(path, before[:]), nil)
	sizes: [3]i64
	for run in 0 ..< len(sizes) {
		d := shared_device.create_or_skip(t, {on_message = rhi.message_print, app_name = "mirai pipeline store test", validation = true, upload_bytes_per_frame = 1 << 20, pipeline_cache_path = path})
		if d == nil {return}
		// As if the run had already compiled for an hour: the next pipeline writes the file.
		if run == 0 {d.pipelines_kept.unsaved = time.Hour}
		compute := rhi.pipeline_create_compute(d, {shader = rhi.test_shader("fill.comp"), name = "fill"})
		if run == 0 {
			// A process that ends here, without device_destroy, leaves the store the next one hits.
			left: rhi.Pipeline_Store
			rhi.pipeline_store_init(&left, d.pipelines_kept.device)
			rhi.pipeline_store_load(&left, path)
			testing.expect(t, len(left.entries) == 1 && left.entries[0].key == d.pipelines_kept.entries[0].key, "the file holds the pipeline before the device is destroyed")
			rhi.pipeline_store_destroy(&left)
		}
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

// The devices of the GPU tests, and the applications they create
// (MIRAI_PIPELINES_PATH, which `mirai test` sets), keep one store
// (shared_device.pipeline_store_path): what the shared device compiled another
// device reads back from it instead of compiling it again.
@(test)
rhi_devices_of_gpu_tests_read_back_what_the_shared_one_compiled :: proc(t: ^testing.T) {
	shared := shared_device.take_or_skip(t)
	if shared == nil {return}
	path := shared_device.pipeline_store_path(os.get_env(project.PIPELINES_PATH_ENV, context.temp_allocator), os.args[0], true, context.temp_allocator)
	if !testing.expect(t, path != "", "the shared device keeps a store") {return}
	compiled := rhi.pipeline_create_compute(shared, {shader = rhi.test_shader("fill.comp"), name = "fill"})
	testing.expect(t, compiled != 0, rhi.device_error(shared))
	rhi.pipeline_destroy(shared, compiled)
	rhi.device_pipelines_keep(shared)
	d := shared_device.create_or_skip(t, {on_message = rhi.message_print, app_name = "mirai pipeline store test", validation = true, upload_bytes_per_frame = 1 << 20, allow_hardware_ray_tracing = true, pipeline_cache_path = path})
	if d == nil {return}
	defer rhi.device_destroy(d)
	kept := len(d.pipelines_kept.entries)
	testing.expectf(t, rhi.device_stats(d).pipeline_store == .Read && kept > 0, "the device reads the store of the shared one: %v, %d entries", rhi.device_stats(d).pipeline_store, kept)
	read := rhi.pipeline_create_compute(d, {shader = rhi.test_shader("fill.comp"), name = "fill"})
	testing.expect(t, read != 0, rhi.device_error(d))
	rhi.pipeline_destroy(d, read)
	testing.expectf(t, len(d.pipelines_kept.entries) == kept, "the pipeline is found in the store, not compiled into it: %d entries, %d before", len(d.pipelines_kept.entries), kept)
}
