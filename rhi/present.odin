package rhi

import "base:runtime"
import "core:sync"
import "core:thread"
import "core:time"

// Paced presentation, for a renderer that generates frames: each frame draws
// two images, the one shown between the frame before and this one and its
// own, into a pair of images of the device instead of the swapchain. A
// thread of the device waits for the GPU to finish the frame, copies each
// image into one of the swapchain and presents them half a frame apart, as
// the interpolation swapchain of AMD FidelityFX does. The algorithm is one
// for both backends; each gives present_backend_start, present_backend_stop,
// present_gpu_wait and present_image.

PRESENT_PAIRS :: 3 // the thread presents one while the frames draw the others
PRESENT_JOBS :: PRESENT_PAIRS // each pair waits in it at most once
// A frame that takes longer than this is a stall, not the rate of the frames.
PRESENT_INTERVAL_MAX_NS :: 250_000_000

Present_Stats :: struct {
	paced:       bool, // the frames go through the thread
	presented:   u64,  // images given to the display
	generated:   u64,  // of them, those generated between two frames
	interval_ms: f32,  // between the last two images given to the display
	// Of every interval between two images given to the display, for their mean and spread.
	intervals:         u64,
	interval_total_ms: f64,
	interval_square:   f64, // the sum of their squares, in ms
	latency_ms:  f32,  // from the start of the last frame shown to its image going to the display, its GPU work done
}

@(private)
Present_Job :: struct {
	pair:      int,
	generated: bool,
	value:     u64,    // Vulkan: the timeline value of the frame
	cmd:       rawptr, // Metal: the command buffer of the frame, retained
	begun_ns:  i64,    // when the frame began recording
	ended_ns:  i64,    // when it was submitted
	waited_ns: i64,    // what it waited for its pair: the pace of the thread, not of the frames
}

@(private)
Present_Pair :: struct {
	textures: [2]Texture, // the generated image and the real one
	released: u64,        // Vulkan: the value of the present timeline once the thread copied both
	busy:     bool,       // handed to the thread and not copied yet
}

@(private)
Presenter :: struct {
	wanted:        bool, // swapchain_set_paced
	active:        bool, // the thread runs and frames draw into the pairs
	refused:       bool, // the swapchain cannot be copied into: asked again only after paced is set off
	worker:        ^thread.Thread,
	mutex:         sync.Mutex,
	work:          sync.Cond, // a job came, or quit
	room:          sync.Cond, // a job was presented
	jobs:          [PRESENT_JOBS]Present_Job,
	head, count:   int,
	busy:          bool, // the thread presents a job
	quit:          bool,
	out_of_date:   bool, // the thread found the swapchain stale: atomic
	pairs:         [PRESENT_PAIRS]Present_Pair,
	width, height: u32,
	format:        Format,
	pair:          int, // of the frame being recorded; -1: none
	wait_value:    u64, // Vulkan: what the frame waits for of the present timeline before it draws into its pair
	begun_ns:      i64,
	waited_ns:     i64, // of the frame being recorded, for its pair
	gpu_end_ns:    i64, // of present_latency
	// The thread's alone.
	interval_ns:   f64, // between frames, smoothed
	last_ended_ns: i64,
	last_shown_ns: i64, // when the last real image went to the display
	// Under mutex.
	stats:         Present_Stats,
	presented_ns:  i64, // when the last image went to the display
}

// Presents through the thread from the next frame on, or stops. A frame that
// draws a generated image (frame_end with generated) shows it half a frame
// before its own.
swapchain_set_paced :: proc(d: ^Device, paced: bool) {
	if !d.has_swapchain {return}
	p := &d.presenter
	if !paced {p.refused = false}
	p.wanted = paced
}

// The image of the frame being recorded shown before its own, while paced; 0 otherwise.
swapchain_generated_texture :: proc(d: ^Device) -> Texture {
	p := &d.presenter
	if !d.in_frame || !p.active || p.pair < 0 {return 0}
	return p.pairs[p.pair].textures[0]
}

present_stats :: proc(d: ^Device) -> Present_Stats {
	p := &d.presenter
	sync.guard(&p.mutex)
	stats := p.stats
	stats.paced = p.active
	return stats
}

@(private)
present_now_ns :: proc() -> i64 {return time.tick_now()._nsec}

// What frame_begin does with paced presentation: starts or stops the thread
// as asked, and takes the pair the frame draws into once the thread let it go.
// pacing: the frame goes through the thread.
@(private)
present_frame_begin :: proc(d: ^Device) -> (pacing, ok: bool) {
	p := &d.presenter
	p.pair = -1
	p.begun_ns = present_now_ns()
	if p.wanted && !p.active && !p.refused {
		if !present_start(d) {p.refused = true}
	} else if !p.wanted && p.active {
		present_stop(d)
	}
	if !p.active {return false, true}
	width, height := swapchain_size(d)
	if sync.atomic_load(&p.out_of_date) || swapchain_stale(d) || width != p.width || height != p.height {
		present_drain(d)
		sync.atomic_store(&p.out_of_date, false)
		if !swapchain_refresh(d) {return true, false}
		width, height = swapchain_size(d)
		if width == 0 || height == 0 {return true, false}
		if width != p.width || height != p.height {
			present_pairs_destroy(d)
			if !present_pairs_create(d, width, height) {present_stop(d); p.refused = true; return false, true}
		}
		if !present_backend_refresh(d) {present_stop(d); p.refused = true; return false, true}
	}
	at := int(d.frame_number % PRESENT_PAIRS)
	waiting := present_now_ns()
	sync.mutex_lock(&p.mutex)
	for p.pairs[at].busy && d.failure == .None {
		if !sync.cond_wait_with_timeout(&p.room, &p.mutex, time.Duration(GPU_WAIT_LIMIT_NS)) {break}
	}
	free := !p.pairs[at].busy
	p.wait_value = p.pairs[at].released
	sync.mutex_unlock(&p.mutex)
	p.waited_ns = present_now_ns() - waiting
	if !free {
		if d.failure == .None {device_fail(d, .Hung, "the presentation thread did not present in %d s", GPU_WAIT_LIMIT_NS / 1_000_000_000)}
		return true, false
	}
	p.pair = at
	return true, true
}

// Hands the pair of the frame submitted to the thread.
@(private)
present_frame_end :: proc(d: ^Device, generated: bool, value: u64, cmd: rawptr) {
	p := &d.presenter
	if p.pair < 0 {return}
	job := Present_Job{pair = p.pair, generated = generated, value = value, cmd = cmd, begun_ns = p.begun_ns, ended_ns = present_now_ns(), waited_ns = p.waited_ns}
	sync.mutex_lock(&p.mutex)
	// frame_begin waited for this pair: the queue has room for it.
	at := (p.head + p.count) % PRESENT_JOBS
	if p.count < PRESENT_JOBS {
		p.jobs[at] = job
		p.count += 1
		p.pairs[p.pair].busy = true
		sync.cond_signal(&p.work)
	}
	sync.mutex_unlock(&p.mutex)
	p.pair = -1
}

@(private)
present_pairs_create :: proc(d: ^Device, width, height: u32) -> bool {
	p := &d.presenter
	p.width, p.height, p.format = width, height, swapchain_format(d)
	for &pair in p.pairs {
		for &texture in pair.textures {
			texture = texture_create(d, {width = width, height = height, format = p.format, usage = {.Color_Target, .Sampled, .Transfer_Src}, name = "presented image"})
			if texture == 0 {return false}
		}
		pair.busy, pair.released = false, 0
	}
	return true
}

@(private)
present_pairs_destroy :: proc(d: ^Device) {
	p := &d.presenter
	for &pair in p.pairs {
		for &texture in pair.textures {
			if texture != 0 {texture_destroy(d, texture)}
			texture = 0
		}
	}
	p.width, p.height = 0, 0
}

@(private)
present_start :: proc(d: ^Device) -> bool {
	p := &d.presenter
	width, height := swapchain_size(d)
	if width == 0 || height == 0 {return false}
	if !present_pairs_create(d, width, height) {present_pairs_destroy(d); return false}
	if !present_backend_start(d) {present_pairs_destroy(d); return false}
	p.head, p.count, p.busy, p.quit = 0, 0, false, false
	p.interval_ns, p.last_ended_ns, p.last_shown_ns = 0, 0, 0
	previous := context.allocator
	context.allocator = d.allocator
	p.worker = thread.create(present_worker, name = "rhi presenter")
	context.allocator = previous
	if p.worker == nil {
		present_backend_stop(d)
		present_pairs_destroy(d)
		set_error(d, "the presentation thread could not start")
		return false
	}
	p.worker.data = d
	p.worker.init_context = runtime.Context{allocator = d.allocator}
	thread.start(p.worker)
	p.active = true
	return true
}

@(private)
present_stop :: proc(d: ^Device) {
	p := &d.presenter
	if !p.active {return}
	present_drain(d)
	sync.mutex_lock(&p.mutex)
	p.quit = true
	sync.cond_broadcast(&p.work)
	sync.mutex_unlock(&p.mutex)
	thread.join(p.worker)
	thread.destroy(p.worker)
	p.worker = nil
	present_backend_stop(d)
	present_pairs_destroy(d)
	p.active = false
}

// Waits until the thread presented every job it was given.
@(private)
present_drain :: proc(d: ^Device) {
	p := &d.presenter
	sync.mutex_lock(&p.mutex)
	for (p.count > 0 || p.busy) && d.failure == .None {
		if !sync.cond_wait_with_timeout(&p.room, &p.mutex, time.Duration(GPU_WAIT_LIMIT_NS)) {break}
	}
	sync.mutex_unlock(&p.mutex)
}

@(private)
present_worker :: proc(worker: ^thread.Thread) {
	d := cast(^Device)worker.data
	p := &d.presenter
	for {
		sync.mutex_lock(&p.mutex)
		for p.count == 0 && !p.quit {sync.cond_wait(&p.work, &p.mutex)}
		if p.count == 0 {
			sync.mutex_unlock(&p.mutex)
			return
		}
		job := p.jobs[p.head]
		p.busy = true
		sync.mutex_unlock(&p.mutex)
		released := present_job(d, &job)
		sync.mutex_lock(&p.mutex)
		p.head = (p.head + 1) % PRESENT_JOBS
		p.count -= 1
		p.pairs[job.pair].busy = false
		if released > 0 {p.pairs[job.pair].released = released}
		p.busy = false
		sync.cond_broadcast(&p.room)
		sync.mutex_unlock(&p.mutex)
	}
}

// Presents the images of a frame once its GPU work is done: the generated one
// half the interval of the frames after the real one before it, and the real
// one half the interval after that. The interval leaves out what the frames
// waited for their pairs: counted, the thread would set the pace it measures
// and slow down by its own work each frame. Returns what present_image
// returned for the last image, which the pair waits for before a frame draws
// into it.
@(private)
present_job :: proc(d: ^Device, job: ^Present_Job) -> u64 {
	p := &d.presenter
	if !present_gpu_wait(d, job) {return 0}
	p.interval_ns = present_interval(p.interval_ns, p.last_ended_ns, job^)
	p.last_ended_ns = job.ended_ns
	half := i64(p.interval_ns * 0.5)
	released: u64
	if job.generated {
		if p.last_shown_ns > 0 {present_sleep_until(p.last_shown_ns + half)}
		shown_ns := present_now_ns()
		if value, shown := present_image(d, job, 0); shown {
			released = value
			present_count(p, true, shown_ns, -1)
		}
		present_sleep_until(shown_ns + half)
	}
	// Each image is timed from when it was given, not after: what presenting
	// takes does not add up from one to the next.
	shown_ns := present_now_ns()
	value, shown := present_image(d, job, 1)
	if shown {
		released = value
		p.last_shown_ns = shown_ns
		present_count(p, false, shown_ns, present_now_ns() - job.begun_ns)
	}
	return released
}

// The interval of the frames, smoothed, once the job after the one that ended
// at last_ended_ns came: without what it waited for its pair, nor a stall.
@(private)
present_interval :: proc(interval_ns: f64, last_ended_ns: i64, job: Present_Job) -> f64 {
	if last_ended_ns <= 0 {return interval_ns}
	step := f64(job.ended_ns - last_ended_ns - job.waited_ns)
	if step <= 0 || step >= PRESENT_INTERVAL_MAX_NS {return interval_ns}
	return step if interval_ns == 0 else interval_ns * 0.9 + step * 0.1
}

// latency_ns: of a real image, negative while unknown.
@(private)
present_count :: proc(p: ^Presenter, generated: bool, now: i64, latency_ns: i64) {
	sync.guard(&p.mutex)
	if p.presented_ns > 0 {
		interval := f64(now - p.presented_ns) / 1e6
		p.stats.interval_ms = f32(interval)
		p.stats.intervals += 1
		p.stats.interval_total_ms += interval
		p.stats.interval_square += interval * interval
	}
	p.presented_ns = now
	p.stats.presented += 1
	if generated {p.stats.generated += 1}
	if latency_ns >= 0 {p.stats.latency_ms = f32(f64(latency_ns) / 1e6)}
}

// Sleeps most of the way and spins the rest, so an image goes within
// microseconds of its time.
@(private)
present_sleep_until :: proc(target: i64) {
	PRESENT_SPIN_NS :: 1_000_000
	for {
		left := target - present_now_ns()
		if left <= 0 {return}
		if left > PRESENT_SPIN_NS {time.sleep(time.Duration(left - PRESENT_SPIN_NS))} else {time.sleep(0)}
	}
}

// Counts an image a frame presented without the thread; its latency comes
// with the timestamps of the frame (present_latency).
@(private)
present_count_direct :: proc(d: ^Device) {
	present_count(&d.presenter, false, present_now_ns(), -1)
}

// The latency of a frame presented without the thread: from its start to
// the end of its GPU work, when the display takes its image. The GPU starts
// it once it is submitted and the frame before is done.
@(private)
present_latency :: proc(d: ^Device, begun_ns, submitted_ns, gpu_ns: i64) {
	p := &d.presenter
	if begun_ns <= 0 || submitted_ns < begun_ns || gpu_ns <= 0 {return}
	end := max(submitted_ns, p.gpu_end_ns) + gpu_ns
	p.gpu_end_ns = end
	if p.active {return}
	sync.guard(&p.mutex)
	p.stats.latency_ms = f32(f64(end - begun_ns) / 1e6)
}
