package mirai_render

import "core:os"
import "core:sync"
import si "core:sys/info"
import "core:thread"
import "mirai:rhi"
import "mirai:std/base"

// The pipelines that trace rays by software (Pipeline_Make.rays == .Software)
// are two thirds of what a cold start compiles: the largest take the driver
// minutes each. With Renderer_Desc.rays_later they are not made with the
// others but on threads of the renderer, once its frames trace rays by
// software: on a device without ray queries, after a failed self-test or with
// Trace_Mode.Software. Until all of them are in place every frame draws only
// its UI (Frame_Desc.ui_only), and renderer_rays_pending says how many are
// missing. A device that traces by hardware never makes them.

// Bytes of memory the driver may take to compile a pipeline, per byte of its
// SPIR-V, with some margin: amdvlk took about 2.5 GB for each compile of the
// 1.4 MB of reflect.comp. Pipelines compiled at once past what the system has
// free page it out, and each one then takes longer than all of them one
// after another.
PIPELINE_COMPILE_MEMORY_RATIO :: 2000

@(private)
Ray_Pipelines :: struct {
	r:         ^Renderer, // read for its device and shader codes, which stay until ray_pipelines_stop
	items:     [len(Pipeline_List{}.items)]Pipeline_Make,
	made:      [len(Pipeline_List{}.items)]rhi.Pipeline,
	state:     [len(Pipeline_List{}.items)]Ray_Pipeline_State, // atomic
	order:     [len(Pipeline_List{}.items)]int, // into items, the costliest first
	count:     int,
	next:      int, // atomic, into order
	made_count: int, // atomic: items the threads finished, made or not
	failed_at: int, // atomic: 1 + the item that could not be made first; 0: none. The frames keep drawing their UI alone
	installed: int, // items whose pipeline went in place
	stop:      bool, // atomic: no more is started
	threads:   [PIPELINE_THREADS_MAX]^thread.Thread,
	thread_count: int,
}

@(private)
Ray_Pipeline_State :: enum u8 {Asked, Made, Installed}

// Threads that compile pipelines at once, the largest costliest bytes of
// SPIR-V: a thread a physical core, while the memory free now holds what the
// driver takes for each.
@(private)
pipeline_threads :: proc(costliest: int) -> int {
	physical, _, known := si.cpu_core_count()
	if !known || physical < 1 {physical = max(os.get_processor_core_count() / 2, 1)}
	threads := clamp(physical, 1, PIPELINE_THREADS_MAX)
	if _, available, ok := base.memory_stats(); ok && costliest > 0 {
		threads = clamp(int(available / (i64(costliest) * PIPELINE_COMPILE_MEMORY_RATIO)), 1, threads)
	}
	return threads
}

// Starts making the pipelines of software rays that are missing when the
// frames trace by software. Between frames.
@(private)
ray_pipelines_start :: proc(r: ^Renderer) {
	if !r.rays_later || r.rays != nil || r.hardware_rt {return}
	rays := new(Ray_Pipelines, r.allocator)
	if rays == nil {return}
	rays.r = r
	list: Pipeline_List
	pipelines_list(r, &list)
	info := rhi.device_info(r.device)
	costliest := 0
	for &item in list.items[:list.count] {
		if item.rays != .Software || !pipeline_possible(info, item) || item.target^ != 0 {continue}
		pipeline_cost(r, &item)
		costliest = max(costliest, item.cost)
		at := rays.count
		for at > 0 && rays.items[rays.order[at - 1]].cost < item.cost {
			rays.order[at] = rays.order[at - 1]
			at -= 1
		}
		rays.items[rays.count] = item
		rays.order[at] = rays.count
		rays.count += 1
	}
	r.rays = rays
	if rays.count == 0 {return}
	rays.thread_count = min(pipeline_threads(costliest), rays.count)
	for &t in rays.threads[:rays.thread_count] {
		t = thread.create_and_start_with_poly_data(rays, ray_pipelines_run)
	}
}

@(private = "file")
ray_pipelines_run :: proc(rays: ^Ray_Pipelines) {
	defer free_all(context.temp_allocator)
	for !sync.atomic_load(&rays.stop) {
		at := sync.atomic_add(&rays.next, 1)
		if at >= rays.count {return}
		i := rays.order[at]
		item := &rays.items[i]
		if item.graphics {
			rays.made[i] = rhi.pipeline_create_graphics(rays.r.device, item.desc)
		} else {
			code := &rays.r.shader_codes[item.shaders[0]]
			rays.made[i] = rhi.pipeline_create_compute(rays.r.device, {shader = code, name = code.name})
		}
		if rays.made[i] == 0 {_, _ = sync.atomic_compare_exchange_strong(&rays.failed_at, 0, i + 1)}
		sync.atomic_store(&rays.state[i], .Made)
		sync.atomic_add(&rays.made_count, 1)
		free_all(context.temp_allocator)
	}
}

// Between frames: what the threads made goes where the frames find it.
@(private)
ray_pipelines_install :: proc(r: ^Renderer) {
	rays := r.rays
	if rays == nil || rays.installed == rays.count {return}
	for &item, i in rays.items[:rays.count] {
		if sync.atomic_load(&rays.state[i]) != .Made {continue}
		rays.state[i] = .Installed
		rays.installed += 1
		if rays.made[i] == 0 {
			set_error(r, "pipeline %s: %s", ray_pipeline_name(r, item), rhi.device_error(r.device))
			continue
		}
		item.target^ = rays.made[i]
	}
	if rays.installed == rays.count {ray_pipelines_join(rays)}
}

@(private = "file")
ray_pipelines_join :: proc(rays: ^Ray_Pipelines) {
	for t in rays.threads[:rays.thread_count] {
		thread.join(t)
		thread.destroy(t)
	}
	rays.thread_count = 0
}

// With the renderer, or before its pipelines are replaced: no more is
// started, the compiles under way finish (a driver call cannot be cut) and
// what was made and not in place goes.
@(private)
ray_pipelines_stop :: proc(r: ^Renderer) {
	rays := r.rays
	if rays == nil {return}
	sync.atomic_store(&rays.stop, true)
	ray_pipelines_join(rays)
	for i in 0 ..< rays.count {
		if rays.state[i] == .Made && rays.made[i] != 0 {rhi.pipeline_destroy(r.device, rays.made[i])}
	}
	free(rays, r.allocator)
	r.rays = nil
}

@(private = "file")
ray_pipeline_name :: proc(r: ^Renderer, item: Pipeline_Make) -> string {
	return item.desc.name if item.graphics else r.shader_codes[item.shaders[0]].name
}

// The pipelines of software rays the frames need and the driver has not made
// yet, from any thread: while it is above 0 every frame draws only its UI,
// and a frame puts in place those made before it begins. 0 on a device that
// traces rays by hardware, and once they are all made.
renderer_rays_pending :: proc(r: ^Renderer) -> int {
	if r == nil || r.hardware_rt || r.rays == nil {return 0}
	rays := r.rays
	return rays.count - sync.atomic_load(&rays.made_count) + (1 if sync.atomic_load(&rays.failed_at) != 0 else 0)
}

// The first of them the driver could not make, if any: the frames never draw
// the scene. The next frame puts its reason in the error of the renderer.
renderer_rays_failed :: proc(r: ^Renderer) -> (failed: bool, pipeline: string) {
	if r == nil || r.rays == nil || r.hardware_rt {return}
	at := sync.atomic_load(&r.rays.failed_at)
	if at == 0 {return}
	return true, ray_pipeline_name(r, r.rays.items[at - 1])
}

// How many pipelines of software rays the renderer makes in all, 0 when it
// makes none later: with renderer_rays_pending, the progress.
renderer_rays_total :: proc(r: ^Renderer) -> int {
	return r.rays.count if r != nil && r.rays != nil && !r.hardware_rt else 0
}

// Waits for the pipelines of software rays and puts them in place: the next
// frame draws the scene. Blocks for as long as the driver compiles them.
renderer_rays_wait :: proc(r: ^Renderer) {
	rays := r.rays if r != nil else nil
	if rays == nil {return}
	ray_pipelines_join(rays)
	ray_pipelines_install(r)
}
