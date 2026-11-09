#+build linux, windows
package rhi

import "core:os"
import "core:path/filepath"
import "core:testing"
import "core:time"

// The cache is saved while the device lives once enough compile time is not
// in its file, so a start cut short keeps the pipelines it made; less than
// that writes nothing.
@(test)
the_pipeline_cache_is_saved_once_enough_compile_time_is_unsaved :: proc(t: ^testing.T) {
	folder, error := os.make_directory_temp("", "mirai-pipeline-cache-*", context.temp_allocator)
	if !testing.expect(t, error == nil) {return}
	defer os.remove_all(folder)
	path, _ := filepath.join({folder, "pipelines.bin"}, context.temp_allocator)
	d, failure := device_create({app_name = "mirai rhi tests", upload_bytes_per_frame = 1 << 20, pipeline_cache_path = path})
	if d == nil {
		if gpu_skip_allowed() {return}
		testing.expectf(t, false, "no GPU device: %s (set MIRAI_ALLOW_GPU_SKIP=1 to skip)", failure)
		return
	}
	defer device_destroy(d)

	vk_pipeline_made(d, PIPELINE_CACHE_SAVE_AFTER / 2)
	testing.expect(t, !os.exists(path), "half of the time leaves the file alone")
	vk_pipeline_made(d, PIPELINE_CACHE_SAVE_AFTER / 2 + time.Millisecond)
	testing.expect(t, os.exists(path), "past it the cache is written while the device lives")
	testing.expect_value(t, d.cache_unsaved_ns, 0)
}
