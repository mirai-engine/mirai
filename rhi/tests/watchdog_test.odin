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
WATCHDOG_PROBE_UNRECORDED :: 4 // the late frame left no record while it ran
WATCHDOG_PROBE_UNCLEARED :: 5  // its record stayed after it finished
// When the frame of the probe is late for its record: well under its work.
WATCHDOG_LATE_PROBE_MS :: 60

@(init)
watchdog_probe :: proc "contextless" () {
	if len(os.args) < 2 || os.args[1] != WATCHDOG_PROBE {return}
	context = runtime.default_context()
	os.exit(watchdog_probe_run(os.args[2] if len(os.args) > 2 else ""))
}

// record: the file of the record of a late submission; "": none.
@(private = "file")
watchdog_probe_run :: proc(record: string) -> int {
	d, message := rhi.device_create({app_name = "mirai watchdog probe", on_message = rhi.message_print, upload_bytes_per_frame = 1 << 16, late_record = record, late_ms = WATCHDOG_LATE_PROBE_MS})
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
	ok := spin(d, pipeline, buffer, rounds, WATCHDOG_WORK_MS / WATCHDOG_DISPATCH_MS)
	// The record of the frame while it is late, as a session that froze would leave it.
	recorded := false
	for started := time.tick_now(); ok && record != "" && !recorded && time.tick_since(started) < WATCHDOG_WORK_MS * time.Millisecond; {
		if data, error := os.read_entire_file(record, context.temp_allocator); error == nil && len(data) > 0 {
			fmt.eprintf("probe: record: %s", string(data))
			recorded = true
		} else {
			time.sleep(time.Millisecond)
		}
	}
	ok = ok && rhi.device_wait_idle(d)
	if !ok {fmt.eprintln("probe:", rhi.device_error(d))}
	// The thread that saw the frame finish removes its record.
	for started := time.tick_now(); recorded && os.exists(record) && time.tick_since(started) < time.Second; {time.sleep(time.Millisecond)}
	cleared := !recorded || !os.exists(record)
	rhi.buffer_destroy(d, buffer)
	rhi.pipeline_destroy(d, pipeline)
	rhi.device_destroy(d)
	if !ok {return 1}
	if record != "" && !recorded {return WATCHDOG_PROBE_UNRECORDED}
	return 0 if cleared else WATCHDOG_PROBE_UNCLEARED
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
		limit:  string, // "": unset
		record: bool,   // the probe records its late submissions
		code:   int,
		says:   []string,
	}{
		{"", false, 0, nil},
		{"1500", false, 0, nil},
		{"40", false, rhi.WATCHDOG_EXIT_CODE, {"rhi: GPU watchdog: frame ", "MIRAI_GPU_WATCHDOG_MS=40", fmt.tprintf("exit code %d", rhi.WATCHDOG_EXIT_CODE)}},
		{"soon", false, WATCHDOG_PROBE_NO_DEVICE, {"MIRAI_GPU_WATCHDOG_MS=soon", "a whole number above 0"}},
		// Watched by a person: the late frame is recorded, the process goes on and the record goes once it finished.
		{"", true, 0, {"probe: record: frame ", "had not finished on the GPU", "the frame recorded the passes spin"}},
		{"40", true, rhi.WATCHDOG_EXIT_CODE, {"rhi: GPU watchdog: frame "}},
	}
	for c, i in cases {
		record := fmt.tprintf("%s.late-%d.txt", program, i) if c.record else ""
		if record != "" {os.remove(record)}
		env := make([dynamic]string, context.temp_allocator)
		for entry in environment {
			if !strings.has_prefix(entry, rhi.WATCHDOG_VARIABLE + "=") {append(&env, entry)}
		}
		if c.limit != "" {append(&env, fmt.tprintf("%s=%s", rhi.WATCHDOG_VARIABLE, c.limit))}
		state, _, stderr, error := subprocess.exec({command = {program, WATCHDOG_PROBE, record}, env = env[:]}, context.temp_allocator)
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
		if record == "" {continue}
		// A process the watchdog ended leaves the record of what it ended on, for the next one.
		left, unread := os.read_entire_file(record, context.temp_allocator)
		testing.expectf(t, (unread == nil) == (c.code == rhi.WATCHDOG_EXIT_CODE), "limit %q: a record is left only by a process the watchdog ended", c.limit)
		if c.code == rhi.WATCHDOG_EXIT_CODE {
			testing.expectf(t, strings.has_prefix(string(left), "frame ") && strings.contains(string(left), "the frame recorded the passes spin") && strings.contains(string(left), fmt.tprintf("exit code %d", rhi.WATCHDOG_EXIT_CODE)), "limit %q: the record names the frame, its passes and the end:\n%s", c.limit, string(left))
		}
		os.remove(record)
	}
}
