package mirai_render

import "core:os"
import "core:sync"
import "core:thread"
import "core:time"
import "mirai:rhi"

// The variants of the stages (pipeline_of, pipeline_variants_ask) and, with
// Renderer_Desc.pipeline_thread, the pipelines of the stages of Surface
// programs (program_stages.odin), made on threads of the renderer: a frame
// that asks for one does not wait for the driver, and draws without it until
// a later frame finds it made. Those a frame asks for go before those asked
// ahead of time (the variants the settings do not select, the stages of the
// programs of the scene). Without pipelines_async the pipelines of programs
// are made where they are asked for, and a frame waits for a variant.

PIPELINE_JOBS :: 256 // pipelines asked for and not yet in place; past them one is asked for again later

@(private)
Pipeline_Job :: struct {
	owner:    ^rhi.Pipeline, // where the frames find it once it is in place
	graphics: rhi.Graphics_Pipeline_Desc,
	compute:  rhi.Compute_Pipeline_Desc, // made instead when it has a shader
	made:     rhi.Pipeline,
	state:    Pipeline_Job_State,
	urgent:   bool, // a frame needs it: made before those asked ahead of time
	speculative: bool, // background variants, made cheapest first
	cost:     int,  // bytes of its shaders: what orders the speculative ones
}
@(private)
Pipeline_Job_State :: enum u8 {Free, Asked, Making, Made}

@(private)
Pipeline_Thread :: struct {
	device: ^rhi.Device,
	mutex:  sync.Mutex,
	asked:  sync.Cond, // the thread waits for a job
	made:   sync.Cond, // and who waits for jobs, for the one it makes
	jobs:   [PIPELINE_JOBS]Pipeline_Job,
	busy:   int, // jobs that are not free (atomic): a frame without one takes no lock
	installed: u64, // times pipelines went in place
	quit:   bool,
	late_frames: u64,  // submitted frames that still had a requested pipeline pending
	waited_ns:   i64,  // what frames waited for pipelines with Settings.pipelines_first
	threads: [PIPELINE_THREADS_MAX]^thread.Thread,
	thread_count: int,
}

@(private)
pipeline_thread_start :: proc(r: ^Renderer) {
	t, t_error := new(Pipeline_Thread, r.allocator)
	if t_error != nil {return}
	t.device = r.device
	for i in 0 ..< clamp(os.get_processor_core_count() / 2, 2, PIPELINE_THREADS_MAX) {
		// Start a worker that can take every job before reserving another for urgent work.
		t.threads[t.thread_count] = thread.create_and_start_with_poly_data2(t, i == 1, pipeline_thread_run)
		if t.threads[t.thread_count] == nil {break}
		t.thread_count += 1
	}
	if t.thread_count == 0 {free(t, r.allocator); return}
	r.pipeline_thread = t
}

@(private = "file")
pipeline_thread_run :: proc(t: ^Pipeline_Thread, reserved: bool) {
	for {
		sync.mutex_lock(&t.mutex)
		job: ^Pipeline_Job
		for job == nil && !t.quit {
			if next := pipeline_job_next(t.jobs[:], reserved); next >= 0 {job = &t.jobs[next]}
			if job == nil && !t.quit {sync.cond_wait(&t.asked, &t.mutex)}
		}
		if t.quit {sync.mutex_unlock(&t.mutex); return}
		job.state = .Making
		graphics, compute := job.graphics, job.compute
		sync.mutex_unlock(&t.mutex)
		made := rhi.pipeline_create_compute(t.device, compute) if compute.shader != nil else rhi.pipeline_create_graphics(t.device, graphics)
		free_all(context.temp_allocator)
		sync.mutex_lock(&t.mutex)
		job.made, job.state = made, .Made
		sync.cond_broadcast(&t.made)
		sync.mutex_unlock(&t.mutex)
	}
}

// The job a thread takes next, -1 for none: one a frame needs, else one asked
// ahead of time that is not speculative, else the speculative one of the
// cheapest shaders, so a short session still ends some. The reserved thread
// takes no speculative job unless a frame needs it.
@(private)
pipeline_job_next :: proc(jobs: []Pipeline_Job, reserved: bool) -> int {
	next := -1
	for candidate, i in jobs {
		if candidate.state != .Asked || reserved && candidate.speculative && !candidate.urgent {continue}
		if candidate.urgent {return i}
		if next < 0 {next = i; continue}
		held := jobs[next]
		if held.speculative && (!candidate.speculative || candidate.cost < held.cost) {next = i}
	}
	return next
}

// With the renderer: the threads end and what they made and nobody took goes.
@(private)
pipeline_thread_destroy :: proc(r: ^Renderer) {
	t := r.pipeline_thread
	if t == nil {return}
	pipelines_drop(r)
	sync.mutex_lock(&t.mutex)
	t.quit = true
	sync.cond_broadcast(&t.asked)
	sync.mutex_unlock(&t.mutex)
	for worker in t.threads[:t.thread_count] {
		thread.join(worker)
		thread.destroy(worker)
	}
	free(t, r.allocator)
	r.pipeline_thread = nil
}

// The pipeline of graphics, or of compute when it has a shader, into owner^:
// made now without the threads, when `now` or, unless `early`, without
// pipelines_async; else asked of the threads, and owner^ stays 0 until the
// frame that finds it made. owner must stay where it is until then. early:
// asked ahead of time, behind what frames ask for (pipeline_urgent);
// speculative: early, for settings not in use. False when no job is free: the
// caller asks again later.
@(private)
pipeline_make :: proc(r: ^Renderer, owner: ^rhi.Pipeline, graphics: rhi.Graphics_Pipeline_Desc = {}, compute: rhi.Compute_Pipeline_Desc = {}, now := false, early := false, speculative := false) -> bool {
	t := r.pipeline_thread
	if t == nil || now || !r.pipelines_async && !early {
		owner^ = rhi.pipeline_create_compute(r.device, compute) if compute.shader != nil else rhi.pipeline_create_graphics(r.device, graphics)
		return true
	}
	sync.mutex_lock(&t.mutex)
	defer sync.mutex_unlock(&t.mutex)
	for &job in t.jobs {
		if job.state != .Free {continue}
		cost := len(rhi.shader_code_bytes(compute.shader^)) if compute.shader != nil else 0
		if compute.shader == nil && graphics.vertex != nil && graphics.fragment != nil {
			cost = len(rhi.shader_code_bytes(graphics.vertex^)) + len(rhi.shader_code_bytes(graphics.fragment^))
		}
		job = {owner = owner, graphics = graphics, compute = compute, state = .Asked, urgent = !early, speculative = early && speculative, cost = cost}
		sync.atomic_add(&t.busy, 1)
		sync.cond_broadcast(&t.asked)
		return true
	}
	return false
}

// Between frames: the pipelines the thread made go where they were asked for.
@(private)
pipelines_install :: proc(r: ^Renderer) {
	t := r.pipeline_thread
	if t == nil || sync.atomic_load(&t.busy) == 0 {return}
	sync.mutex_lock(&t.mutex)
	defer sync.mutex_unlock(&t.mutex)
	for &job in t.jobs {
		if job.state != .Made {continue}
		job.owner^ = job.made
		job = {}
		sync.atomic_sub(&t.busy, 1)
		t.installed += 1
	}
}

// Before the shaders the jobs are made from go, or with the owners: what is
// asked is forgotten and what is made and not in place goes. An owner left
// at 0 asks again.
@(private)
pipelines_drop :: proc(r: ^Renderer) {
	// The variants of the stages are asked for again, of the shaders in use
	// then: a refused one too, since the shaders change.
	r.variants_wanted = true
	for &v in r.variants[:r.variant_count] {if v.pipeline == 0 {v.state = .None}}
	t := r.pipeline_thread
	if t == nil {return}
	sync.mutex_lock(&t.mutex)
	defer sync.mutex_unlock(&t.mutex)
	for {
		making := false
		for &job in t.jobs {
			switch job.state {
			case .Free:
			case .Making: making = true
			case .Asked, .Made:
				if job.made != 0 {rhi.pipeline_destroy(r.device, job.made)}
				job = {}
				sync.atomic_sub(&t.busy, 1)
			}
		}
		if !making {return}
		sync.cond_wait(&t.made, &t.mutex)
	}
}

// Whether the thread was asked for the pipeline of owner and has not put it in place.
@(private)
pipeline_asked :: proc(r: ^Renderer, owner: ^rhi.Pipeline) -> bool {
	t := r.pipeline_thread
	if t == nil || sync.atomic_load(&t.busy) == 0 {return false}
	sync.mutex_lock(&t.mutex)
	defer sync.mutex_unlock(&t.mutex)
	for job in t.jobs {if job.state != .Free && job.owner == owner {return true}}
	return false
}

// A frame needs the pipeline of owner: when the threads have not begun it,
// they make it before those asked ahead of time; until it is in place it
// counts in renderer_pipelines_pending even when they had begun it.
@(private)
pipeline_urgent :: proc(r: ^Renderer, owner: ^rhi.Pipeline) {
	t := r.pipeline_thread
	if t == nil || sync.atomic_load(&t.busy) == 0 {return}
	sync.mutex_lock(&t.mutex)
	defer sync.mutex_unlock(&t.mutex)
	for &job in t.jobs {
		if job.state == .Free || job.owner != owner || job.urgent {continue}
		job.urgent = true
		if job.state == .Asked {sync.cond_broadcast(&t.asked)}
		break
	}
}

// Stops accepting work and reports a driver call that destruction would wait for.
renderer_pipelines_stop :: proc(r: ^Renderer) -> bool {
	t := r.pipeline_thread if r != nil else nil
	if t == nil {return false}
	sync.mutex_lock(&t.mutex)
	defer sync.mutex_unlock(&t.mutex)
	t.quit = true
	sync.cond_broadcast(&t.asked)
	for job in t.jobs {if job.state == .Making {return true}}
	return false
}

// The pipelines frames asked for that are not in place: the frames draw the
// materials of their programs as their rows, or their passes without them,
// meanwhile. Those asked ahead of time do not count.
renderer_pipelines_pending :: proc(r: ^Renderer) -> (pending: int) {
	t := r.pipeline_thread if r != nil else nil
	if t == nil || sync.atomic_load(&t.busy) == 0 {return}
	sync.mutex_lock(&t.mutex)
	defer sync.mutex_unlock(&t.mutex)
	for job in t.jobs {if job.state != .Free && job.urgent {pending += 1}}
	return
}

// With Settings.pipelines_first, wait for non-speculative work before recording.
@(private)
pipelines_before_frame :: proc(r: ^Renderer, frame: Frame_Desc) -> bool {
	t := r.pipeline_thread
	if !r.settings.pipelines_first || t == nil || sync.atomic_load(&t.busy) == 0 {return true}
	started := time.tick_now()
	ready := renderer_pipelines_wait(r, wanted = true, poll = frame.pipeline_wait, user = frame.pipeline_wait_user)
	t.waited_ns += time.duration_nanoseconds(time.tick_since(started))
	return ready
}

// Frames that submitted with requested pipelines pending and time spent waiting.
renderer_pipelines_report :: proc(r: ^Renderer) -> (late_frames: u64, waited: time.Duration) {
	t := r.pipeline_thread if r != nil else nil
	if t == nil {return}
	return t.late_frames, time.Duration(t.waited_ns)
}

// Counts the times pipelines of programs went in place: what drew a program
// as its rows (an image of the editor) draws again when it changes.
renderer_pipelines_made :: proc(r: ^Renderer) -> u64 {
	return r.pipeline_thread.installed if r != nil && r.pipeline_thread != nil else 0
}

// Waits for the pipelines frames asked for (wanted: those that are not
// speculative, asked ahead of time or not, and not a speculative one a frame
// asked for since; all: every one), or for that of owner, and puts them in
// place: the next frame draws with them. What reads an image back
// (a capture) draws again after it when renderer_pipelines_pending said so.
renderer_pipelines_wait :: proc(r: ^Renderer, owner: ^rhi.Pipeline = nil, all := false, wanted := false, poll: proc(rawptr) -> bool = nil, user: rawptr = nil) -> bool {
	t := r.pipeline_thread if r != nil else nil
	if t == nil {return true}
	sync.mutex_lock(&t.mutex)
	for {
		waiting := false
		for job in t.jobs {waiting ||= ((all || (!job.speculative if wanted else job.urgent)) if owner == nil else job.owner == owner) && (job.state == .Asked || job.state == .Making)}
		if !waiting {break}
		if poll == nil {
			sync.cond_wait(&t.made, &t.mutex)
		} else if !sync.cond_wait_with_timeout(&t.made, &t.mutex, PIPELINE_POLL_INTERVAL) {
			sync.mutex_unlock(&t.mutex)
			if !poll(user) {return false}
			sync.mutex_lock(&t.mutex)
		}
	}
	sync.mutex_unlock(&t.mutex)
	pipelines_install(r)
	return true
}
