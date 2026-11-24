package shared_device

import "core:testing"
import "mirai:project"

// The devices of the GPU tests and the applications they create keep their
// pipelines in the store `mirai test` names, else beside the executable; one
// without hardware ray tracing keeps its own beside it.
@(test)
the_pipelines_of_gpu_tests_go_to_one_store :: proc(t: ^testing.T) {
	Case :: struct {named, executable: string, hardware_rt: bool, path: string}
	cases := []Case{
		{"/w/bin/tests/" + project.TEST_PIPELINES_FILE, "/w/bin/tests/rhi", true, "/w/bin/tests/" + project.TEST_PIPELINES_FILE},
		{"/w/bin/tests/" + project.TEST_PIPELINES_FILE, "/w/bin/tests/rhi", false, "/w/bin/tests/gpu-test-pipelines-software.bin"},
		{"", "/w/bin/tests/render", true, "/w/bin/tests/" + project.TEST_PIPELINES_FILE},
		{"", "/w/bin/tests/render", false, "/w/bin/tests/gpu-test-pipelines-software.bin"},
		{"/s/kept", "/w/bin/tests/render", false, "/s/kept-software"},
		{"", "", true, ""},
	}
	for c in cases {
		path := pipeline_store_path(c.named, c.executable, c.hardware_rt, context.temp_allocator)
		testing.expectf(t, path == c.path, "%s, %s, %v: %s, not %s", c.named, c.executable, c.hardware_rt, path, c.path)
	}
}
