package rhi_tests

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "mirai:rhi"
import "mirai:rhi/shared_device"
import "mirai:std/subprocess"

// The test program is also the child of the watchdog test: started with
// WATCHDOG_PROBE as its first argument it submits one frame of about
// WATCHDOG_WORK_MS of GPU work, in dispatches of about WATCHDOG_DISPATCH_MS,
// far from the seconds after which a display driver resets the GPU, and ends
// before the tests run.
WATCHDOG_PROBE :: "mirai-rhi-watchdog-probe"
WATCHDOG_WORK_MS :: 250
WATCHDOG_DISPATCH_MS :: 8
WATCHDOG_PROBE_NO_DEVICE :: 3

@(init)
watchdog_probe :: proc "contextless" () {
	if len(os.args) < 2 || os.args[1] != WATCHDOG_PROBE {return}
	context = runtime.default_context()
	os.exit(watchdog_probe_run())
}

@(private = "file")
watchdog_probe_run :: proc() -> int {
	d, message := rhi.device_create({app_name = "mirai watchdog probe", on_message = rhi.message_print, upload_bytes_per_frame = 1 << 16})
	if d == nil {
		fmt.eprintln("probe: no device:", message)
		return WATCHDOG_PROBE_NO_DEVICE
	}
	COUNT :: 64 * 256
	pipeline := rhi.pipeline_create_compute(d, {shader = rhi.test_shader("spin.comp"), name = "spin"})
	buffer := rhi.buffer_create(d, {size = 4 * COUNT, usage = {.Storage}, memory = .GPU, name = "spin"})
	if pipeline == 0 || buffer == 0 {
		fmt.eprintln("probe:", rhi.device_error(d))
		return 1
	}
	Params :: struct {count, rounds, pad0, pad1: u32}
	spin :: proc(d: ^rhi.Device, pipeline: rhi.Pipeline, buffer: rhi.Buffer, rounds: u32, dispatches: int) -> bool {
		cmd, ok := rhi.frame_begin(d, present = false)
		if !ok {return false}
		rhi.cmd_timestamp(cmd, "spin")
		params := Params{count = COUNT, rounds = rounds}
		for _ in 0 ..< dispatches {
			rhi.cmd_bind_pipeline(cmd, pipeline)
			rhi.cmd_set_constants(cmd, 0, &params, size_of(params))
			rhi.cmd_bind_buffer(cmd, 1, buffer)
			rhi.cmd_dispatch(cmd, COUNT / 64)
		}
		rhi.cmd_timestamp(cmd, "end")
		return rhi.frame_end(d, cmd)
	}
	// The rounds of a dispatch of WATCHDOG_DISPATCH_MS, from one dispatch measured
	// alone on the CPU clock, which is never shorter than what the GPU took:
	// the work is at most what it asks for.
	rounds := u32(1 << 10)
	for {
		started := time.tick_now()
		if !spin(d, pipeline, buffer, rounds, 1) || !rhi.device_wait_idle(d) {
			fmt.eprintln("probe:", rhi.device_error(d))
			return 1
		}
		ms := time.duration_milliseconds(time.tick_since(started))
		if ms >= WATCHDOG_DISPATCH_MS || rounds >= 1 << 26 {
			rounds = u32(min(f64(rounds) * WATCHDOG_DISPATCH_MS / ms, f64(rounds)))
			break
		}
		rounds *= 2
	}
	ok := spin(d, pipeline, buffer, rounds, WATCHDOG_WORK_MS / WATCHDOG_DISPATCH_MS) && rhi.device_wait_idle(d)
	if !ok {fmt.eprintln("probe:", rhi.device_error(d))}
	rhi.buffer_destroy(d, buffer)
	rhi.pipeline_destroy(d, pipeline)
	rhi.device_destroy(d)
	return 0 if ok else 1
}

// A submission that runs past MIRAI_GPU_WATCHDOG_MS ends its process with
// WATCHDOG_EXIT_CODE and a report of the frame and its passes; without the
// variable, or with a limit above the work, the same work ends normally; a
// value that is no limit refuses the device and says why.
@(test)
rhi_the_watchdog_ends_a_process_whose_gpu_work_runs_past_its_limit :: proc(t: ^testing.T) {
	d := shared_device.take_or_skip(t)
	if d == nil {return}
	// The passes the CPU recorded are always named; where the GPU stopped, only
	// by a device that marks where it goes.
	marked := rhi.device_info(d).features.stop_place
	program, _ := os.get_executable_path(context.temp_allocator)
	environment, _ := os.environ(context.temp_allocator)
	cases := [?]struct {
		limit: string, // "": unset
		code:  int,
		says:  []string,
	}{
		{"", 0, nil},
		{"1500", 0, nil},
		{"40", rhi.WATCHDOG_EXIT_CODE, {"rhi: GPU watchdog: frame ", "MIRAI_GPU_WATCHDOG_MS=40", fmt.tprintf("exit code %d", rhi.WATCHDOG_EXIT_CODE)}},
		{"soon", WATCHDOG_PROBE_NO_DEVICE, {"MIRAI_GPU_WATCHDOG_MS=soon", "a whole number above 0"}},
	}
	for c in cases {
		env := make([dynamic]string, context.temp_allocator)
		for entry in environment {
			if !strings.has_prefix(entry, rhi.WATCHDOG_VARIABLE + "=") {append(&env, entry)}
		}
		if c.limit != "" {append(&env, fmt.tprintf("%s=%s", rhi.WATCHDOG_VARIABLE, c.limit))}
		state, _, stderr, error := subprocess.exec({command = {program, WATCHDOG_PROBE}, env = env[:]}, context.temp_allocator)
		testing.expectf(t, error == nil, "limit %q: the probe did not run: %v", c.limit, error)
		testing.expectf(t, state.exited && state.exit_code == c.code, "limit %q: exit code %d, not %d; stderr:\n%s", c.limit, state.exit_code, c.code, string(stderr))
		for text in c.says {
			testing.expectf(t, strings.contains(string(stderr), text), "limit %q: %q is not in:\n%s", c.limit, text, string(stderr))
		}
		if c.code == rhi.WATCHDOG_EXIT_CODE {
			testing.expectf(t, strings.contains(string(stderr), "the frame recorded the passes spin"), "limit %q: the report names the passes:\n%s", c.limit, string(stderr))
			testing.expectf(t, strings.contains(string(stderr), "it stopped in spin") == marked, "limit %q: the report says where the GPU stopped only when the device marks it (stop_place %v):\n%s", c.limit, marked, string(stderr))
		}
		testing.expectf(t, c.code == rhi.WATCHDOG_EXIT_CODE || !strings.contains(string(stderr), "GPU watchdog: frame"), "limit %q: the watchdog fired:\n%s", c.limit, string(stderr))
	}
}
