package rhi

import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

// The watchdog of the GPU work of a process. A submission (a frame or an
// immediate list) is late when it has not finished some time after it was
// submitted. A late submission is written, with its frame, its passes and how
// long it waited, to the record the host names (Device_Desc.late_record),
// flushed to disk at once so that it survives a reset of the machine, and the
// record is removed once the submission finishes: a record that is left names
// the submission a session never saw finish. A process no person watches
// (WATCHDOG_VARIABLE) also writes on stderr what it waited for and ends itself
// at once, before a display driver resets a GPU that may not come back. Two
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
// When a submission is late for its record, ms, unless the device is given
// another: under the time a display driver gives the GPU before it resets it,
// with room to write the record first.
WATCHDOG_LATE_MS :: 1000
// What a process the watchdog ended exits with: that of a command a timeout ended.
WATCHDOG_EXIT_CODE :: 124
// Submissions watched at once; past them the newest takes the place of the one before it.
WATCHDOG_PENDING :: 64
WATCHDOG_REPORT_BYTES :: 4096
WATCHDOG_RECORD_PATH :: 1024 // code units of the path of the record

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
	limit_ns:      i64, // the process ends past it; 0: a person watches
	limit_ms:      int,
	late_ns:       i64, // the record is written past it; 0: no record
	watch_ns:      i64, // the first of both; 0: off
	record:        Watchdog_Path, // the late_record, as the system takes it
	recorded:      u64, // the serial of the submission the record names; 0: none
	mutex:         sync.Mutex,
	changed:       sync.Cond, // work was submitted or finished, or quit
	pending:       [WATCHDOG_PENDING]Watchdog_Work,
	head, count:   int,
	quit:          bool,
	disarmed:      bool, // the device failed: the API reported it, nothing is left to watch
	timer, waiter: ^thread.Thread,
}

// Reads the limits and starts the threads when there is one; false, with the
// error of the device, when the variable does not hold a limit, the record
// cannot be named or a thread cannot start.
@(private)
watchdog_start :: proc(d: ^Device, desc: Device_Desc) -> bool {
	w := &d.watchdog
	if text := strings.trim_space(env_flag(WATCHDOG_VARIABLE)); text != "" {
		ms, valid := strconv.parse_int(text, 10)
		if !valid || ms <= 0 {
			set_error(d, "%s=%s: it is the limit in milliseconds a submission may run on the GPU, a whole number above 0; unset, there is none", WATCHDOG_VARIABLE, text)
			return false
		}
		w.limit_ms, w.limit_ns = ms, i64(ms) * 1_000_000
	}
	if desc.late_record != "" {
		if !watchdog_path_set(&w.record, desc.late_record) {
			set_error(d, "late_record %q: the record of a late GPU submission needs a path under %d characters", desc.late_record, WATCHDOG_RECORD_PATH)
			return false
		}
		late_ms := desc.late_ms if desc.late_ms > 0 else WATCHDOG_LATE_MS
		w.late_ns = i64(late_ms) * 1_000_000
		// An unwatched process records what it ends on.
		if w.limit_ns > 0 {w.late_ns = min(w.late_ns, w.limit_ns)}
	}
	w.watch_ns = w.late_ns if w.late_ns > 0 else w.limit_ns
	if w.watch_ns == 0 {return true}
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

// Ends the threads; nothing is watched afterwards. A record of a submission
// that never finished stays. Called again, it does nothing.
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
	w.limit_ns, w.late_ns, w.watch_ns = 0, 0, 0
}

// Watches a submission that went to the queue.
@(private)
watchdog_sent :: proc(d: ^Device, serial: u64, frame: u64, slot: int) {
	w := &d.watchdog
	if w.watch_ns == 0 {return}
	sync.guard(&w.mutex)
	if w.disarmed || w.quit {return}
	work := Watchdog_Work{serial, time.tick_now()._nsec, frame, slot}
	// Full: the newest submission watches for the one before it, which cannot finish later.
	if w.count == WATCHDOG_PENDING {w.count -= 1}
	w.pending[(w.head + w.count) % WATCHDOG_PENDING] = work
	w.count += 1
	sync.cond_broadcast(&w.changed)
}

// Fires on the CPU clock: the oldest submission that did not finish is
// recorded once it is late, and ends an unwatched process past its limit.
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
		failed := intrinsics.atomic_load(&d.failure) != .None
		if !failed && w.limit_ns > 0 && waited >= w.limit_ns {watchdog_fire(d, work, waited, w.count - 1)}
		if !failed && w.late_ns > 0 && waited >= w.late_ns && w.recorded != work.serial {
			watchdog_record(d, work, waited, w.count - 1, "")
			w.recorded = work.serial
		}
		next := max(i64)
		if w.late_ns > waited && w.recorded != work.serial {next = w.late_ns}
		if w.limit_ns > waited {next = min(next, w.limit_ns)}
		if next == max(i64) {sync.cond_wait(&w.changed, &w.mutex); continue}
		sync.cond_wait_with_timeout(&w.changed, &w.mutex, time.Duration(next - waited))
	}
}

// Waits for the GPU to finish the oldest submission and records it; the
// record of a late one goes once it finished, or once the API reported the
// failure of the device, which is the host's.
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
		result := watchdog_gpu_wait(d, serial, w.watch_ns)
		sync.mutex_lock(&w.mutex)
		if result == .Waiting && intrinsics.atomic_load(&d.failure) != .None {result = .Failed}
		switch result {
		case .Done:
			for w.count > 0 && w.pending[w.head].serial <= serial {
				w.head = (w.head + 1) % WATCHDOG_PENDING
				w.count -= 1
			}
			if w.recorded != 0 && w.recorded <= serial {
				watchdog_record_remove(&w.record)
				w.recorded = 0
			}
			sync.cond_broadcast(&w.changed)
		case .Waiting:
		case .Failed:
			if w.recorded != 0 {watchdog_record_remove(&w.record)}
			w.disarmed, w.count, w.recorded = true, 0, 0
			sync.cond_broadcast(&w.changed)
			return
		}
	}
}

// What the GPU did not finish: the submission, how long it waited, where it
// stopped and the passes of its frame.
@(private)
watchdog_describe :: proc(d: ^Device, work: Watchdog_Work, waited_ns: i64, behind: int, b: ^strings.Builder) {
	if work.slot >= 0 {
		fmt.sbprintf(b, "frame %d", work.frame)
	} else if work.frame > 0 {
		fmt.sbprintf(b, "an immediate list (a load, a build or a read) sent after frame %d", work.frame - 1)
	} else {
		fmt.sbprintf(b, "an immediate list (a load, a build or a read) sent before the first frame")
	}
	fmt.sbprintf(b, " had not finished on the GPU %d ms after it was submitted", waited_ns / 1_000_000)
	if work.slot >= 0 {watchdog_frame_text(d, work.slot, b)}
	if behind > 0 {fmt.sbprintf(b, "; %d more submissions waited behind it", behind)}
}

// Writes the record of a late submission and flushes it to disk; ending: what
// the process did about it.
@(private)
watchdog_record :: proc(d: ^Device, work: Watchdog_Work, waited_ns: i64, behind: int, ending: string) {
	buffer: [WATCHDOG_REPORT_BYTES]u8
	b := strings.builder_from_bytes(buffer[:len(buffer) - 1])
	watchdog_describe(d, work, waited_ns, behind, &b)
	strings.write_string(&b, ending)
	n := strings.builder_len(b)
	buffer[n] = '\n'
	watchdog_record_write(&d.watchdog.record, buffer[:n + 1])
}

// Writes the record and on stderr what the GPU did not finish and ends the
// process at once: no destructor, no wait for the device, no call that could
// wait for the GPU.
@(private)
watchdog_fire :: proc(d: ^Device, work: Watchdog_Work, waited_ns: i64, behind: int) -> ! {
	ending_buffer: [128]u8
	ending := fmt.bprintf(ending_buffer[:], "; %s=%d ended the process with exit code %d before the display driver reset the GPU", WATCHDOG_VARIABLE, d.watchdog.limit_ms, WATCHDOG_EXIT_CODE)
	if d.watchdog.late_ns > 0 {watchdog_record(d, work, waited_ns, behind, ending)}
	buffer: [WATCHDOG_REPORT_BYTES]u8
	b := strings.builder_from_bytes(buffer[:len(buffer) - 1])
	strings.write_string(&b, "rhi: GPU watchdog: ")
	watchdog_describe(d, work, waited_ns, behind, &b)
	strings.write_string(&b, ending)
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
