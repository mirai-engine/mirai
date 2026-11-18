package rhi

import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

// The watchdog of the GPU work of a process: when a submission (a frame or an
// immediate list) has not finished WATCHDOG_VARIABLE milliseconds after it was
// submitted, the process writes on stderr what it waited for and ends itself at
// once, before a display driver resets a GPU that may not come back. Two
// threads: one waits for the GPU and records what finished, the other fires on
// the CPU clock alone, so a stuck driver call cannot keep it from firing. The
// algorithm is one; each backend gives watchdog_gpu_wait and watchdog_stopped
// and calls watchdog_sent after each submission.

// Off unless set: first frames that build acceleration structures and slow
// devices wait for the GPU long and validly.
WATCHDOG_VARIABLE :: "MIRAI_GPU_WATCHDOG_MS"
// The limit the tools set for a program no person watches, ms: under the time
// a display driver gives the GPU before it resets it.
WATCHDOG_UNWATCHED_MS :: 1500
// What a process the watchdog ended exits with: that of a command a timeout ended.
WATCHDOG_EXIT_CODE :: 124
// Submissions watched at once; past them the newest takes the place of the one before it.
WATCHDOG_PENDING :: 64
WATCHDOG_REPORT_BYTES :: 4096

@(private)
Watchdog_Work :: struct {
	serial:  u64, // what the GPU signals once it finished it (Vulkan: the timeline; Metal: the shared event)
	sent_ns: i64, // when it was submitted, on the clock of time.tick_now
	frame:   u64, // the frame_number of a frame; of an immediate list, that of the next frame
	slot:    int, // the frame slot; -1: an immediate list
}

@(private)
Watchdog_Wait :: enum u8 {Done, Waiting, Failed}

@(private)
Watchdog :: struct {
	limit_ns:      i64, // 0: off
	limit_ms:      int,
	mutex:         sync.Mutex,
	changed:       sync.Cond, // work was submitted or finished, or quit
	pending:       [WATCHDOG_PENDING]Watchdog_Work,
	head, count:   int,
	quit:          bool,
	disarmed:      bool, // the device failed: the API reported it, nothing is left to watch
	timer, waiter: ^thread.Thread,
}

// Reads the limit and starts the threads; false, with the error of the
// device, when the variable does not hold a limit or a thread cannot start.
@(private)
watchdog_start :: proc(d: ^Device) -> bool {
	w := &d.watchdog
	text := strings.trim_space(env_flag(WATCHDOG_VARIABLE))
	if text == "" {return true}
	ms, valid := strconv.parse_int(text, 10)
	if !valid || ms <= 0 {
		set_error(d, "%s=%s: it is the limit in milliseconds a submission may run on the GPU, a whole number above 0; unset, there is none", WATCHDOG_VARIABLE, text)
		return false
	}
	w.limit_ms, w.limit_ns = ms, i64(ms) * 1_000_000
	error: Thread_Create_Error
	w.timer, error = device_thread_create(d, watchdog_timer, d)
	if error == .None {w.waiter, error = device_thread_create(d, watchdog_waiter, d)}
	if error != .None {
		watchdog_stop(d)
		set_error(d, "the threads of the GPU watchdog (%s) could not start: %s", WATCHDOG_VARIABLE, thread_create_text(error))
		return false
	}
	thread.start(w.timer)
	thread.start(w.waiter)
	return true
}

// Ends the threads; nothing is watched afterwards. Called again, it does nothing.
@(private)
watchdog_stop :: proc(d: ^Device) {
	w := &d.watchdog
	sync.mutex_lock(&w.mutex)
	w.quit = true
	sync.cond_broadcast(&w.changed)
	sync.mutex_unlock(&w.mutex)
	// A thread that never started starts, finds quit and returns.
	for &worker in ([]^^thread.Thread{&w.timer, &w.waiter}) {
		if worker^ == nil {continue}
		device_thread_destroy(worker^)
		worker^ = nil
	}
	w.limit_ns = 0
}

// Watches a submission that went to the queue.
@(private)
watchdog_sent :: proc(d: ^Device, serial: u64, frame: u64, slot: int) {
	w := &d.watchdog
	if w.limit_ns == 0 {return}
	sync.guard(&w.mutex)
	if w.disarmed || w.quit {return}
	work := Watchdog_Work{serial, time.tick_now()._nsec, frame, slot}
	// Full: the newest submission watches for the one before it, which cannot finish later.
	if w.count == WATCHDOG_PENDING {w.count -= 1}
	w.pending[(w.head + w.count) % WATCHDOG_PENDING] = work
	w.count += 1
	sync.cond_broadcast(&w.changed)
}

// Fires on the CPU clock: the oldest submission that did not finish within
// the limit ends the process.
@(private)
watchdog_timer :: proc(worker: ^thread.Thread) {
	d := cast(^Device)worker.data
	w := &d.watchdog
	sync.mutex_lock(&w.mutex)
	defer sync.mutex_unlock(&w.mutex)
	for !w.quit {
		if w.count == 0 {sync.cond_wait(&w.changed, &w.mutex); continue}
		work := w.pending[w.head]
		waited := time.tick_now()._nsec - work.sent_ns
		// A failure the API reported is the host's to handle.
		if waited >= w.limit_ns && intrinsics.atomic_load(&d.failure) == .None {watchdog_fire(d, work, waited, w.count - 1)}
		if waited >= w.limit_ns {sync.cond_wait(&w.changed, &w.mutex); continue}
		sync.cond_wait_with_timeout(&w.changed, &w.mutex, time.Duration(w.limit_ns - waited))
	}
}

// Waits for the GPU to finish the oldest submission and records it.
@(private)
watchdog_waiter :: proc(worker: ^thread.Thread) {
	d := cast(^Device)worker.data
	w := &d.watchdog
	sync.mutex_lock(&w.mutex)
	defer sync.mutex_unlock(&w.mutex)
	for !w.quit {
		if w.count == 0 {sync.cond_wait(&w.changed, &w.mutex); continue}
		serial := w.pending[w.head].serial
		sync.mutex_unlock(&w.mutex)
		result := watchdog_gpu_wait(d, serial, w.limit_ns)
		sync.mutex_lock(&w.mutex)
		if result == .Waiting && intrinsics.atomic_load(&d.failure) != .None {result = .Failed}
		switch result {
		case .Done:
			for w.count > 0 && w.pending[w.head].serial <= serial {
				w.head = (w.head + 1) % WATCHDOG_PENDING
				w.count -= 1
			}
			sync.cond_broadcast(&w.changed)
		case .Waiting:
		case .Failed:
			w.disarmed, w.count = true, 0
			sync.cond_broadcast(&w.changed)
			return
		}
	}
}

// Writes on stderr what the GPU did not finish and ends the process at once:
// no destructor, no wait for the device, no call that could wait for the GPU.
@(private)
watchdog_fire :: proc(d: ^Device, work: Watchdog_Work, waited_ns: i64, behind: int) -> ! {
	buffer: [WATCHDOG_REPORT_BYTES]u8
	b := strings.builder_from_bytes(buffer[:len(buffer) - 1])
	if work.slot >= 0 {
		fmt.sbprintf(&b, "rhi: GPU watchdog: frame %d", work.frame)
	} else if work.frame > 0 {
		fmt.sbprintf(&b, "rhi: GPU watchdog: an immediate list (a load, a build or a read) sent after frame %d", work.frame - 1)
	} else {
		fmt.sbprintf(&b, "rhi: GPU watchdog: an immediate list (a load, a build or a read) sent before the first frame")
	}
	fmt.sbprintf(&b, " has not finished on the GPU %d ms after it was submitted (%s=%d)", waited_ns / 1_000_000, WATCHDOG_VARIABLE, d.watchdog.limit_ms)
	if work.slot >= 0 {watchdog_frame_text(d, work.slot, &b)}
	if behind > 0 {fmt.sbprintf(&b, "; %d more submissions wait behind it", behind)}
	fmt.sbprintf(&b, "; the process ends with exit code %d before the display driver resets the GPU", WATCHDOG_EXIT_CODE)
	n := strings.builder_len(b)
	buffer[n] = '\n'
	os.write(os.stderr, buffer[:n + 1])
	watchdog_exit(WATCHDOG_EXIT_CODE)
}

// Where the GPU stopped in the frame of a slot, when the device marks it,
// and the passes the CPU recorded in it, which every device knows.
@(private)
watchdog_frame_text :: proc(d: ^Device, slot: int, b: ^strings.Builder) {
	if d.info.features.stop_place {
		stopped_buffer: [256]u8
		if stopped := watchdog_stopped(d, slot, stopped_buffer[:]); stopped != "" {fmt.sbprintf(b, "; it stopped in %s", stopped)}
	} else {
		strings.write_string(b, "; where it stopped is not known: the device marks no progress")
	}
	passes := &d.frames[slot].recorded
	if passes.count == 0 {
		strings.write_string(b, "; the frame recorded no passes (cmd_timestamp)")
		return
	}
	strings.write_string(b, "; the frame recorded the passes ")
	for name, i in passes.names[:passes.count] {
		if i > 0 {strings.write_string(b, ", ")}
		strings.write_string(b, name)
	}
}
