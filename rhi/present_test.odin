package rhi

import "core:testing"

// Frames that wait for their pairs go at the pace of the thread: counted, the
// interval would grow each frame by what the thread adds to it.
@(test)
present_interval_follows_the_frames_and_not_the_thread :: proc(t: ^testing.T) {
	FRAME :: 4_000_000
	OVERHEAD :: 200_000 // what the thread takes past the interval for each frame
	interval: f64
	ended: i64
	for _ in 0 ..< 300 {
		waited := max(i64(interval) + OVERHEAD - FRAME, 0)
		job := Present_Job{ended_ns = ended + FRAME + waited, waited_ns = waited}
		interval = present_interval(interval, ended, job)
		ended = job.ended_ns
	}
	testing.expectf(t, abs(interval - FRAME) < FRAME * 0.01, "interval %v ns for frames of %v ns", interval, FRAME)
	testing.expect_value(t, present_interval(interval, ended, {ended_ns = ended + PRESENT_INTERVAL_MAX_NS}), interval)
}
