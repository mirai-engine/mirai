package mirai_render

import "core:fmt"
import "core:strings"
import "mirai:rhi"
import "mirai:std/base"

// The GPU buffers of the pools of the scene. A pool asks for room before it
// grows: its buffer grows then, by half again up to POOL_SLACK_BYTES, and
// the next publication copies the old one into it on the GPU, so growing
// uploads nothing again. When the GPU has no memory for it, what asked is
// not taken (a mesh, a batch, the inputs of a BLAS) and the rest is drawn;
// stats.problem says what is missing. The same size is not asked for again
// until geometry or textures of as many bytes as it would add went
// (Scene_State.released).

POOL_SLACK_BYTES :: u64(256) << 20
// The least that has to go before a size the GPU refused is asked for again.
POOL_RETRY_BYTES :: u64(16) << 20

@(private)
Pool_Refusal :: struct {
	bytes:    u64, // what a growth asked for and did not get; 0: none
	more:     u64, // what it would have added to what the buffer held
	released: u64, // Scene_State.released then
}

// The buffer a pool left when it grew, whose bytes the next publication copies into the new one.
@(private)
Pool_Move :: struct {
	from:  rhi.Buffer,
	bytes: u64,
}

// What was not taken for lack of GPU memory since the last time everything fit.
@(private)
Geometry_Refused :: struct {
	meshes, batches, blases: int, // blases: the cuts without their native BLAS, counted when shown
	values:                  int, // times an instance was not given what it gives over its rows
	triangles:               u64,
	pool:                    Mesh_Pool, // the last one that could not grow
	bytes, held:             u64, // what it asked for and what it holds
}

@(private)
pool_gpu :: proc(s: ^Scene_State, pool: Mesh_Pool) -> (buffer: ^rhi.Buffer, count, element: int, usage: rhi.Buffer_Usage, name: string) {
	switch pool {
	case .Vertex:   return &s.vertex_buffer, len(s.vertices), size_of(u32), {.Storage, .Accel_Input}, "vertex pool"
	case .Index:    return &s.index_buffer, len(s.indices), size_of(u32), {.Storage, .Accel_Input}, "index pool"
	case .Node:     return &s.blas_node_buffer, len(s.blas_nodes), size_of(Gpu_Bvh_Node), {.Storage}, "blas nodes"
	case .Triangle: return &s.blas_triangle_buffer, len(s.blas_triangles), size_of(Gpu_Bvh_Triangle), {.Storage}, "blas triangles"
	}
	return
}

// Room in the GPU buffer of a pool for more elements past its end. False
// when the GPU has no memory for it; then nothing is added.
@(private)
pool_room :: proc(r: ^Renderer, pool: Mesh_Pool, more: int) -> bool {
	s := &r.scene
	// A renderer without a device keeps its pools on the CPU alone.
	if r.device == nil {return true}
	buffer, count, element, usage, name := pool_gpu(s, pool)
	needed := u64(max(count + more, 1)) * u64(element)
	held := rhi.buffer_size(r.device, buffer^) if buffer^ != 0 else 0
	if needed <= held {return true}
	refusal := &s.pool_refused[pool]
	if refusal.bytes != 0 && needed >= refusal.bytes && s.released - refusal.released < max(refusal.more, POOL_RETRY_BYTES) {return false}
	grown: rhi.Buffer
	if s.pool_bytes_max == 0 || needed <= s.pool_bytes_max {
		capacity := needed + min(needed / 2, POOL_SLACK_BYTES)
		capacity = (capacity + 3) &~ u64(3)
		grown = rhi.buffer_create(r.device, {size = capacity, usage = usage, name = name})
		if grown == 0 {grown = rhi.buffer_create(r.device, {size = needed, usage = usage, name = name})}
	}
	if grown == 0 {
		refusal^ = {needed, needed - held, s.released}
		s.refused.pool, s.refused.bytes, s.refused.held = pool, needed, held
		return false
	}
	refusal^ = {}
	// Room again for the pool that could not grow: what it refused may come back.
	if s.refused.bytes != 0 && s.refused.pool == pool {s.refused = {}}
	move := &s.pool_moves[pool]
	if move.from != 0 {
		// The buffer of the growth before no publication used yet.
		rhi.buffer_destroy(r.device, buffer^)
	} else if buffer^ != 0 {
		move^ = {buffer^, held}
	} else {
		clear(&s.pool_dirty[pool])
		range_add(&s.pool_dirty[pool], {0, u32(count)})
	}
	buffer^ = grown
	s.pools_grown += {pool}
	if pool == .Vertex {s.vertices_made += 1}
	s.geometry_dirty = true
	return true
}

// Copies the buffers the pools left into the new ones, first in list: what
// the publication uploads goes over them.
@(private)
pool_moves_record :: proc(r: ^Renderer, list: ^rhi.Command_List) {
	s := &r.scene
	for &move, pool in s.pool_moves {
		if move.from == 0 {continue}
		buffer, _, _, _, _ := pool_gpu(s, pool)
		rhi.cmd_copy_buffer(list, move.from, 0, buffer^, 0, move.bytes)
		rhi.buffer_destroy(r.device, move.from)
		move = {}
	}
}

// Whether a pool left a buffer the next publication copies.
@(private)
pool_moves_pending :: proc(s: ^Scene_State) -> bool {
	for move in s.pool_moves {if move.from != 0 {return true}}
	return false
}

// About what the native BLAS of a triangle takes, to tell when one the GPU
// refused may fit.
BLAS_TRIANGLE_BYTES :: 48

// Bytes left the GPU: what it refused may fit now.
@(private)
geometry_released :: proc(s: ^Scene_State, bytes: u64) {s.released += bytes}

// What the geometry could not take for lack of GPU memory, and how to avoid
// it; "" when everything fit.
@(private)
geometry_refused_problem :: proc(r: ^Renderer, buffer: []u8) -> string {
	s := &r.scene
	refused := s.refused
	if s.blas_refused.bytes != 0 {
		for &m in s.meshes {
			for ray, k in m.rays[:m.ray_count] {if m.vertex_count > 0 && ray.blas == 0 && ray_cut_wanted(r, m, k) {refused.blases += 1}}
		}
	}
	if refused.meshes == 0 && refused.batches == 0 && refused.blases == 0 && refused.values == 0 {return ""}
	MB :: f64(1 << 20)
	missing: [5]string
	count := 0
	if refused.meshes > 0 {missing[count] = fmt.tprintf("%d meshes of %d triangles are not drawn", refused.meshes, refused.triangles);count += 1}
	if refused.batches > 0 {missing[count] = fmt.tprintf("%d batches are not drawn", refused.batches);count += 1}
	if refused.values > 0 {missing[count] = "instances show their materials without what their entities give them";count += 1}
	if refused.blases > 0 {missing[count] = fmt.tprintf("%d cuts that rays trace have no native BLAS, and rays miss them", refused.blases);count += 1}
	_, _, _, _, name := pool_gpu(s, refused.pool)
	if refused.bytes != 0 {missing[count] = fmt.tprintf("the %s asked for %.0f MB and holds %.0f MB", name, f64(refused.bytes) / MB, f64(refused.held) / MB);count += 1}
	held, _ := rhi.accel_memory(r.device)
	return fmt.bprintf(buffer, "the GPU has no memory for more geometry: %s (the pools hold %.0f MB, ray structures %.0f MB, textures %.0f MB). Fewer sections loaded at once (Streaming_Settings), meshes imported with fewer triangles (max_triangles) or rays traced by software (Settings.trace_mode = .Software) avoid it",
		strings.join(missing[:count], "; ", context.temp_allocator), f64(geometry_pool_bytes(r)) / MB, f64(held) / MB, f64(r.textures.bytes) / MB)
}

// The bytes of the GPU buffers of the pools and of the table of meshes.
@(private)
geometry_pool_bytes :: proc(r: ^Renderer) -> (bytes: u64) {
	s := &r.scene
	for buffer in ([]rhi.Buffer{s.vertex_buffer, s.index_buffer, s.blas_node_buffer, s.blas_triangle_buffer, s.mesh_buffer}) {
		if buffer != 0 {bytes += rhi.buffer_size(r.device, buffer)}
	}
	return
}

// The bytes of the free ranges of the pools, which a mesh of their size or
// less takes, and those of the largest.
@(private)
geometry_pool_free :: proc(s: ^Scene_State) -> (free, largest: u64) {
	for pool in Mesh_Pool {
		_, _, element, _, _ := pool_gpu(s, pool)
		for range in s.pool_free[pool] {
			bytes := u64(range.count) * u64(element)
			free += bytes
			largest = max(largest, bytes)
		}
	}
	return
}

// Keeps of dirty ranges the parts at or past held, which the buffer does not reach.
@(private)
pool_ranges_keep_past :: proc(ranges: ^[dynamic]Pool_Range, held: u32) {
	kept := 0
	for range in ranges {
		end := range.first + range.count
		if end <= held {continue}
		first := max(range.first, held)
		ranges[kept] = {first, end - first}
		kept += 1
	}
	base.truncate(ranges, kept)
}
