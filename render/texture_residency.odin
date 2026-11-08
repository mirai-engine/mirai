package mirai_render

import "core:math"
import "core:math/linalg"
import "mirai:asset"
import "mirai:rhi"

// Residency of the levels of a texture by distance. A texture whose levels
// its loader can read again (Texture_Data.source) is streamed: it holds the
// levels of its source from the one the distance of what shows it asks for,
// and its loader reads and gives another range of levels (texture_requests,
// texture_levels_set) when that changes. What shows a texture is every
// instance and batch of the scene whose material rows name it; the distance
// is from the nearest of the views the renderer drew and of the places given
// by texture_sources (where the streaming sources are and where they go),
// to the box of the instance. From that distance, the size of its source,
// the uv the mesh spans per metre (mesh_uv_density), the scale of the
// instance and the transform of the map comes the level whose texel is a
// pixel of the view; the level kept is TEXTURE_FILTER_LEVELS finer. Changes
// keep TEXTURE_KEEP_LEVELS of hysteresis, and while the pool of textures
// has no room every streamed texture takes the same share of a level more
// (texture_targets). The estimate runs between frames and only when the
// views, the sources or the scene changed; giving a range of levels is a
// transaction: a texture of its own replaces the entry, whose handle stays.

// Texels of side of the levels a streamed texture holds whatever its
// distance: what a load brings first (assets of a section) and what a texture
// nothing near shows keeps. A .tex stores them so that they decode alone.
TEXTURE_TAIL :: asset.TEXTURE_TAIL
// log2(1.25): a level stays until every view is 1.25 times farther than where
// it was asked for, as what streams by distance (scene.RESIDENT_KEEP).
TEXTURE_KEEP_LEVELS :: f32(0.32192809)
// Anisotropic filtering takes the level of the longer axis of the footprint of
// a pixel over the samples it spreads along it, as many as the ratio of the
// axes rounded up: the level it reads is up to one finer than the one whose
// texel is a pixel along the shorter axis.
TEXTURE_FILTER_LEVELS :: f32(1)
// Metres a view or a source moves before the levels are looked at again.
TEXTURE_VIEW_MOVE :: f32(0.25)
TEXTURE_SOURCES_MAX :: 128
TEXTURE_VIEWS_MAX :: VIEW_CAPACITY + TEXTURE_VIEW_CAPACITY + 1

// Entries of the materials of a mesh with a density of their own; those past
// it share the last one.
MESH_UV_ENTRIES :: 8
// The share of the surface of a mesh whose uv may be denser than its density:
// slivers and specks do not make the whole mesh ask for more levels.
MESH_UV_DENSER_SHARE :: f32(0.01)
// A density of no triangle: the uv set does not change over the surface.
MESH_UV_NONE :: f32(-1e30)

@(private = "file") UV_BINS :: 160 // quarters of a level of density, from 2^-20 to 2^20 uv per metre
@(private = "file") UV_BIN_LOW :: f32(-20)

// A texture whose levels follow its distance.
Texture_Stream :: struct {
	chain:  [rhi.MAX_TEXTURE_MIPS]u64, // bytes of the levels of its source from each one to its last
	size:   [2]u32,                    // of the level 0 of its source
	format: rhi.Format,
	levels: u8,  // its source has; 0: not streamed, it keeps the levels it was given
	top:    u8,  // the level of its source its first resident level is
	target: u8,  // the one it should have (texture_targets)
	shown:  bool, // an instance or a batch of the scene shows it
	lod:    f32, // the level of its source whose texel is a pixel of its nearest view
	stamp:  u32, // grows with each texture that takes its entry and each range of levels it gets
}

// A place textures are seen from, relative to the origin: log2 of the pixels
// of a view a metre spans one metre away, or anywhere for an orthographic one.
Texture_Viewer :: struct {
	position: Vec3,
	scale:    f32,
	ortho:    bool,
}

// Levels a loader should give a texture: those of its source from `level`.
Texture_Request :: struct {
	handle: Texture_Handle,
	level:  int,
	stamp:  u32, // texture_levels_set refuses a request whose texture changed since
}

Texture_Residency :: struct {
	streams:       [dynamic]Texture_Stream, // by handle - 1, as long as the textures of Texture_State
	views:         [TEXTURE_VIEWS_MAX]Texture_Viewer, // drawn by the last frame, places of the world
	view_count:    int,
	sources:       [TEXTURE_SOURCES_MAX]Vec3,  // places of the world
	source_count:  int,
	seen_views:    [TEXTURE_VIEWS_MAX]Texture_Viewer, // those of the last estimate
	seen_count:    int,
	seen_batches:  u64, // Batch_State.revision of the last estimate
	stale:         bool, // the estimate runs again before the next requests
	pending:       int,  // streamed textures whose levels are not their target
	reduced:       int,  // shown streamed textures held coarser than their distance asks by the pool
	uploads:       [TEXTURE_UPLOADS]Texture_Upload,
}

TEXTURE_UPLOADS :: 8 // streamed textures that take their levels over frames at once

// A streamed texture that takes the levels a request asked for over frames
// (texture_levels_queue): its rows go to the GPU in the list of the frame,
// those of all of them the part of UPLOAD_FRAME_BYTES textures_upload_budget
// gives, and once all of them are there the texture takes its entry of the
// table. The caller keeps the levels until texture_upload_pending says they
// went.
@(private)
Texture_Upload :: struct {
	request: Texture_Request,
	texture: rhi.Texture,
	data:    Texture_Data,
	mip:     int,
	row:     u32, // of rows of blocks, or of texels, of its mip
	bytes:   u64,
	active:  bool,
	done:    bool, // its rows went in a frame: it takes its entry before the next (texture_uploads_install)
}

// What the views of a frame the window shows see textures from: its views,
// or its camera alone, before their places become relative to the origin.
// A view that moved TEXTURE_VIEW_MOVE, or sees at another scale, marks the
// estimate. An offscreen frame (a capture, a preview of another world) does
// not move what the window shows.
@(private)
textures_views_record :: proc(r: ^Renderer, frame: Frame_Desc) {
	if frame.ui_only || frame.offscreen {return}
	t := &r.textures.residency
	count := 0
	add :: proc(t: ^Texture_Residency, count: ^int, camera: Camera, width, height: i32) {
		if count^ == len(t.views) || width <= 0 || height <= 0 {return}
		t.views[count^] = texture_viewer(camera, f32(width), f32(height))
		count^ += 1
	}
	// The views of the window see textures from the camera of the detail while it holds.
	seen :: proc(frame: Frame_Desc, view: Frame_View) -> Camera {return frame.detail.camera if frame.detail.on && view.texture == 0 else view.camera}
	for view in frame.views {if !view.disabled {add(t, &count, seen(frame, view), view.rect.z, view.rect.w)}}
	if len(frame.views) == 0 {add(t, &count, frame.detail.camera if frame.detail.on else frame.camera, i32(r.window_width), i32(r.window_height))}
	if count == 0 {return}
	t.view_count = count
	if count != t.seen_count {t.stale = true;return}
	for view, i in t.views[:count] {
		was := t.seen_views[i]
		if view.ortho != was.ortho || abs(view.scale - was.scale) > 1e-3 || linalg.length2(view.position - was.position) > TEXTURE_VIEW_MOVE * TEXTURE_VIEW_MOVE {t.stale = true;return}
	}
}

// The scale a camera sees textures at, over a view of width by height
// pixels. A perspective takes the corner of the view, where a metre at a
// distance spans the most pixels across the ray: 1/cos of its angle from the
// axis more than at the centre.
texture_viewer :: proc "contextless" (camera: Camera, width, height: f32) -> (viewer: Texture_Viewer) {
	viewer.position = camera.position
	switch camera.projection {
	case .Orthographic:
		viewer.ortho = true
		viewer.scale = math.log2(height / max(camera.height, 1e-6))
	case .Perspective, .Custom:
		tangent := math.tan(clamp(camera.fov_y, 1e-3, 179) * math.PI / 360)
		if camera.projection == .Custom {tangent = 1 / max(abs(camera.custom[1, 1]), 1e-6)}
		aspect := width / max(height, 1)
		corner := math.sqrt(1 + tangent * tangent * (1 + aspect * aspect))
		viewer.scale = math.log2(height * corner / (2 * tangent))
	}
	return
}

// Where the streaming sources of the world drawn are, and where they go:
// places of the world. Their textures are seen as from the nearest view.
// What moved TEXTURE_VIEW_MOVE marks the estimate.
texture_sources :: proc(r: ^Renderer, places: []Vec3) {
	t := &r.textures.residency
	count := min(len(places), len(t.sources))
	changed := count != t.source_count
	for place, i in places[:count] {
		changed ||= linalg.length2(place - t.sources[i]) > TEXTURE_VIEW_MOVE * TEXTURE_VIEW_MOVE
	}
	if !changed {return}
	copy(t.sources[:], places[:count])
	t.source_count = count
	t.stale = true
}

// Looks again, between frames, at the levels each streamed texture should
// have, if the views, the sources or the scene changed since. The streamed
// textures whose levels are not their target.
textures_update :: proc(r: ^Renderer) -> int {
	t := &r.textures.residency
	if len(t.streams) == 0 {return 0}
	if r.scene.batch.revision != t.seen_batches {t.stale = true}
	if !t.stale {return t.pending}
	t.stale = false
	t.seen_batches = r.scene.batch.revision
	t.seen_views, t.seen_count = t.views, t.view_count
	viewers: [TEXTURE_VIEWS_MAX + TEXTURE_SOURCES_MAX]Texture_Viewer
	count, widest := 0, f32(-1e30)
	for view in t.views[:t.view_count] {
		viewers[count] = view
		viewers[count].position = origin_point(view.position, r.origin)
		if !view.ortho {widest = max(widest, view.scale)}
		count += 1
	}
	// A source is seen as from the view that sees the most of the world.
	if widest > -1e30 {
		for place in t.sources[:t.source_count] {
			viewers[count] = {position = origin_point(place, r.origin), scale = widest}
			count += 1
		}
	}
	streams := t.streams[:r.textures.count]
	textures_estimate(streams, &r.scene, renderer_programs(r), viewers[:count])
	streamed: u64
	for &stream, index in streams {if stream.levels > 0 {streamed += r.textures.stored[index]}}
	room := max(u64)
	if pool := u64(r.settings.texture_pool_megabytes) * 1024 * 1024; pool > 0 {
		fixed := r.textures.bytes - min(streamed, r.textures.bytes)
		room = pool - min(fixed, pool)
	}
	_, t.reduced, t.pending = texture_targets(streams, texture_limits(r).max_size, room)
	return t.pending
}

// The level of its source each streamed texture should start at:
// - the one its distance asks for, `lod` less TEXTURE_FILTER_LEVELS, from
//   the largest max_size allows down to the one of side TEXTURE_TAIL;
// - with TEXTURE_KEEP_LEVELS of hysteresis: a texture that has more levels
//   keeps them until its distance asks for that much less;
// - one nothing shows keeps the levels it has;
// - and, while the levels of all of them take more than room bytes, every one
//   the same share of a level coarser: bias, the least that fits.
// reduced: those shown held coarser than their distance asks; pending: those
// whose levels are not their target.
texture_targets :: proc(streams: []Texture_Stream, max_size: int, room: u64) -> (bias: f32, reduced, pending: int) {
	total :: proc(streams: []Texture_Stream, max_size: int, bias: f32) -> (bytes: u64) {
		for &stream in streams {
			if stream.levels > 0 {bytes += stream.chain[texture_target(&stream, max_size, bias)]}
		}
		return
	}
	if total(streams, max_size, 0) > room {
		// Bytes fall as the bias grows: the least bias that fits, to a fraction of a level.
		low, high := f32(0), f32(rhi.MAX_TEXTURE_MIPS)
		for _ in 0 ..< 16 {
			middle := (low + high) * 0.5
			if total(streams, max_size, middle) > room {low = middle} else {high = middle}
		}
		bias = high
	}
	for &stream in streams {
		if stream.levels == 0 {continue}
		stream.target = texture_target(&stream, max_size, bias)
		if stream.target != stream.top {pending += 1}
		if stream.shown && bias > 0 && stream.target > texture_target(&stream, max_size, 0) {reduced += 1}
	}
	return
}

// The first level a streamed texture should have, with a bias of levels.
texture_target :: proc "contextless" (stream: ^Texture_Stream, max_size: int, bias: f32) -> u8 {
	first, last := texture_level_range(stream, max_size)
	asked := clamp(stream.lod - TEXTURE_FILTER_LEVELS, -1, 64) if stream.shown else f32(stream.top)
	level := int(stream.top)
	if grow := int(math.floor(asked + bias)); grow < level {
		level = grow
	} else if shrink := int(math.floor(asked + bias - TEXTURE_KEEP_LEVELS)); shrink > level {
		level = shrink
	}
	return u8(clamp(level, first, last))
}

// The levels a streamed texture can start at: from the largest whose side
// max_size takes to the one of side TEXTURE_TAIL, or its last.
texture_level_range :: proc "contextless" (stream: ^Texture_Stream, max_size: int) -> (first, last: int) {
	if stream.levels == 0 {return}
	side := max(int(stream.size.x), int(stream.size.y))
	for first + 1 < int(stream.levels) && side >> uint(first) > max(max_size, 1) {first += 1}
	last = first
	for last + 1 < int(stream.levels) && side >> uint(last) > TEXTURE_TAIL {last += 1}
	return
}

// The level of its source each streamed texture shows at its nearest
// viewer, over the instances and the batches of the scene; a texture of a
// Surface program, whose uv its source decides, asks for its largest.
textures_estimate :: proc(streams: []Texture_Stream, s: ^Scene_State, programs: []Program, viewers: []Texture_Viewer) {
	for &stream in streams {stream.lod, stream.shown = max(f32), false}
	if len(viewers) == 0 {return}
	for &inst, i in s.instances {
		if inst.meta.w & (INSTANCE_FLAG_HIDDEN | INSTANCE_FLAG_COLLAPSED) != 0 || int(inst.meta.x & INSTANCE_MESH_MASK) >= len(s.meshes) {continue}
		mesh := &s.meshes[inst.meta.x & INSTANCE_MESH_MASK]
		if mesh.vertex_count == 0 {continue}
		near := viewers_near(viewers, inst.bounds_min.xyz, inst.bounds_max.xyz) - math.log2(max(rows_scale(inst.world), 1e-12))
		overlays := s.overlays[i] if i < len(s.overlays) else Instance_Overlays{}
		mesh_lods(streams, s, programs, mesh, inst.meta.y, &inst.slot_materials, overlays, near)
	}
	b := &s.batch
	for row, i in b.rows {
		if i >= len(b.drawn) || int(row.meta.x & INSTANCE_MESH_MASK) >= len(s.meshes) {continue}
		mesh := &s.meshes[row.meta.x & INSTANCE_MESH_MASK]
		if mesh.vertex_count == 0 {continue}
		near := viewers_near(viewers, row.bounds_min.xyz, row.bounds_max.xyz) - math.log2(max(b.records[b.drawn[i]].scale, 1e-12))
		slots := row.slot_materials
		mesh_lods(streams, s, programs, mesh, row.meta.y, &slots, {}, near)
	}
	for &stream in streams {
		if stream.shown && stream.lod < max(f32) {stream.lod += math.log2(f32(max(stream.size.x, stream.size.y, 1)))}
	}
	// What the materials of a mesh ask of their textures at `near`: log2 of
	// the metres a pixel spans at the instance, less the log2 of its scale.
	mesh_lods :: proc(streams: []Texture_Stream, s: ^Scene_State, programs: []Program, mesh: ^Mesh_Record, material: u32, palette: ^[32]u32, overlays: Instance_Overlays, near: f32) {
		densest := [2]f32{MESH_UV_NONE, MESH_UV_NONE}
		for e in 0 ..< mesh.slot_count {
			density := mesh.uv_density[min(int(e), MESH_UV_ENTRIES - 1)]
			densest = linalg.max(densest, density)
			row := instance_row(s.indices[mesh.slot_word + e], material, palette)
			if int(row) < len(s.materials) {row_lods(streams, programs, &s.materials[row], density, near)}
		}
		// A layer covers the same triangles as any of the entries.
		for at in 0 ..< min(int(overlays.count), OVERLAY_CAPACITY) {
			layer := overlays.entries[at]
			if layer.enabled && int(layer.material) < len(s.materials) {row_lods(streams, programs, &s.materials[layer.material], densest, near)}
		}
	}
	// The texture of an entry of the table a material names (texture_index), by handle - 1.
	texture_of_entry :: proc(entry: u32, count: int) -> (index: int, held: bool) {
		index = int(entry) - TEXTURE_RESERVED
		return index, entry != GPU_NONE && index >= 0 && index < count
	}
	row_lods :: proc(streams: []Texture_Stream, programs: []Program, row: ^Gpu_Material_Row, density: [2]f32, near: f32) {
		for entry, kind in row.textures {
			index, held := texture_of_entry(entry, len(streams))
			if !held {continue}
			transform := row.map_transforms[kind]
			set := min(int(transform.uv_set), 1)
			stream := &streams[index]
			stream.shown = true
			if density[set] <= MESH_UV_NONE {continue}
			// The longer axis of the map transform: how many of its uv one of the mesh spans.
			l := transform.linear
			scale := 0.5 * math.log2(max(l.x * l.x + l.z * l.z, l.y * l.y + l.w * l.w, 1e-24))
			stream.lod = min(stream.lod, near + density[set] + scale)
		}
		if row.program_id == 0 {return}
		words := transmute([PROGRAM_PARAMETER_BYTES / 4]u32)row.custom_params
		for &program in programs {
			if program.id != row.program_id || program.domain != .Surface {continue}
			for parameter in program.parameters {
				if parameter.kind != .Texture {continue}
				if index, held := texture_of_entry(words[parameter.offset / 4], len(streams)); held {
					streams[index].shown = true
					streams[index].lod = -max(f32)
				}
			}
			break
		}
	}
}

// log2 of the metres a pixel of the nearest viewer spans at a box: the
// distance over the pixels a metre spans one metre away.
@(private)
viewers_near :: proc "contextless" (viewers: []Texture_Viewer, low, high: Vec3) -> f32 {
	nearest := max(f32)
	for viewer in viewers {
		p := viewer.position
		outside := Vec3{max(low.x - p.x, 0, p.x - high.x), max(low.y - p.y, 0, p.y - high.y), max(low.z - p.z, 0, p.z - high.z)}
		at := -viewer.scale if viewer.ortho else 0.5 * math.log2(max(linalg.length2(outside), 1e-6)) - viewer.scale
		nearest = min(nearest, at)
	}
	return nearest
}

// The largest scale of the axes of a transform, given by its rows.
@(private)
rows_scale :: proc "contextless" (rows: [3]Vec4) -> f32 {
	scale: f32
	for axis in 0 ..< 3 {scale = max(scale, rows[0][axis] * rows[0][axis] + rows[1][axis] * rows[1][axis] + rows[2][axis] * rows[2][axis])}
	return math.sqrt(scale)
}

// log2 of the uv each set of a mesh spans per metre of its surface, for each
// slot of level 0 (the first MESH_UV_ENTRIES; those past it share the
// last): over its triangles weighted by area, the density only
// MESH_UV_DENSER_SHARE of the surface exceeds. MESH_UV_NONE for an entry
// whose uv do not change.
mesh_uv_density :: proc(g: asset.Mesh_Geometry) -> (density: [MESH_UV_ENTRIES][2]f32) {
	bins: [MESH_UV_ENTRIES][2][UV_BINS]f32
	if len(g.levels) == 0 {return}
	for c in g.clusters[:g.levels[0].cluster_count] {
		entry := min(int(asset.cluster_slot(c)), MESH_UV_ENTRIES - 1)
		for t in 0 ..< asset.cluster_triangle_count(c) {
			corners := asset.cluster_triangle(g.triangles, c, t)
			va, vb, vc := asset.cluster_vertex(g, c, corners[0]), asset.cluster_vertex(g, c, corners[1]), asset.cluster_vertex(g, c, corners[2])
			area := linalg.length(linalg.cross(vb.position - va.position, vc.position - va.position))
			if !(area > 1e-12) {continue}
			for set in 0 ..< 2 {
				ab, ac := vb.uv - va.uv, vc.uv - va.uv
				if set == 1 {ab, ac = vb.uv1 - va.uv1, vc.uv1 - va.uv1}
				uv_area := abs(ab.x * ac.y - ab.y * ac.x)
				if !(uv_area > 1e-12 * area) {continue}
				bin := int((0.5 * math.log2(uv_area / area) - UV_BIN_LOW) * 4)
				bins[entry][set][clamp(bin, 0, UV_BINS - 1)] += area
			}
		}
	}
	for &entry, e in bins {
		for &set, k in entry {
			whole: f32
			for weight in set {whole += weight}
			density[e][k] = MESH_UV_NONE
			if whole <= 0 {continue}
			denser: f32
			for bin := UV_BINS - 1; bin >= 0; bin -= 1 {
				denser += set[bin]
				if denser > whole * MESH_UV_DENSER_SHARE {
					density[e][k] = UV_BIN_LOW + f32(bin + 1) / 4
					break
				}
			}
		}
	}
	return
}

// Streamed textures to read the levels of, the most urgent first: those
// that need more levels before those that have too many, unless the pool is
// past its room; the ones farthest from their target first. busy: textures
// whose levels are being read. Between frames, after textures_update.
texture_requests :: proc(r: ^Renderer, out: []Texture_Request, busy: []Texture_Handle) -> int {
	t := &r.textures.residency
	if t.pending == 0 || len(out) == 0 {return 0}
	shrink_first := false
	if pool := u64(r.settings.texture_pool_megabytes) * 1024 * 1024; pool > 0 {shrink_first = r.textures.bytes > pool}
	urgency :: proc "contextless" (stream: ^Texture_Stream, shrink_first: bool) -> int {
		grow := stream.target < stream.top
		steps := abs(int(stream.top) - int(stream.target))
		return steps + (rhi.MAX_TEXTURE_MIPS if grow != shrink_first else 0)
	}
	count := 0
	each: for &stream, index in t.streams[:r.textures.count] {
		if stream.levels == 0 || stream.target == stream.top {continue}
		handle := Texture_Handle(index + 1)
		for held in busy {if held == handle {continue each}}
		at := count
		weight := urgency(&stream, shrink_first)
		for at > 0 && urgency(&t.streams[out[at - 1].handle - 1], shrink_first) < weight {at -= 1}
		if at >= len(out) {continue}
		if count < len(out) {count += 1}
		copy(out[at + 1:count], out[at:count - 1])
		out[at] = {handle = handle, level = int(stream.target), stamp = stream.stamp}
	}
	return count
}

Texture_Levels_Result :: enum u8 {
	Set,
	Stale,    // the texture changed since the request: it was removed, replaced or given other levels
	Mismatch, // the data is not the levels of its source the request asked for
	Failed,   // the device did not take them: Renderer.error says why
	Busy,     // TEXTURE_UPLOADS textures take levels already: ask again later
}

// What a request may become: the texture with those levels, or why not.
@(private = "file")
texture_levels_check :: proc(r: ^Renderer, request: Texture_Request, data: Texture_Data) -> (texture: rhi.Texture, result: Texture_Levels_Result) {
	state := &r.textures
	index := int(request.handle) - 1
	if index < 0 || index >= state.count || state.textures[index] == 0 {return 0, .Stale}
	stream := &state.residency.streams[index]
	if stream.levels == 0 || stream.stamp != request.stamp {return 0, .Stale}
	if data.level != request.level || data.source != {int(stream.size.x), int(stream.size.y)} || len(data.levels) == 0 || data.level + len(data.levels) != int(stream.levels) {return 0, .Mismatch}
	texture = rhi.texture_create(r.device, {width = u32(data.width), height = u32(data.height), mip_levels = u32(len(data.levels)), format = data.format, usage = {.Sampled}, name = "streamed texture"})
	if texture == 0 {set_error(r, "texture levels: %s", rhi.device_error(r.device));return 0, .Failed}
	return texture, .Set
}

// The texture with the levels of a request takes its entry of the table.
@(private = "file")
texture_levels_install :: proc(r: ^Renderer, request: Texture_Request, data: Texture_Data, texture: rhi.Texture, bytes: u64) -> Texture_Levels_Result {
	state := &r.textures
	index := int(request.handle) - 1
	if index < 0 || index >= state.count || state.textures[index] == 0 || state.residency.streams[index].stamp != request.stamp {
		rhi.texture_destroy(r.device, texture)
		return .Stale
	}
	stream := &state.residency.streams[index]
	if !rhi.texture_table_set(r.device, texture_entry(index), texture) {
		set_error(r, "texture levels: %s", rhi.device_error(r.device))
		rhi.texture_destroy(r.device, texture)
		return .Failed
	}
	rhi.texture_destroy(r.device, state.textures[index])
	state.textures[index] = texture
	state.bytes = state.bytes - state.stored[index] + bytes
	state.stored[index] = bytes
	was := stream.target != stream.top
	stream.top, stream.format = u8(data.level), data.format
	texture_chain(stream)
	stream.stamp += 1
	state.residency.pending = max(state.residency.pending + int(stream.target != stream.top) - int(was), 0)
	return .Set
}

// Gives a streamed texture the levels of its source a request asked for over
// the frames that follow (texture_uploads_record): Set when they will go,
// and data is to stay as it is until texture_upload_pending is false.
texture_levels_queue :: proc(r: ^Renderer, request: Texture_Request, data: Texture_Data) -> Texture_Levels_Result {
	t := &r.textures.residency
	slot := -1
	for &upload, i in t.uploads {
		if upload.active && upload.request.handle == request.handle {return .Busy}
		if !upload.active && slot < 0 {slot = i}
	}
	if slot < 0 {return .Busy}
	texture, result := texture_levels_check(r, request, data)
	if result != .Set {return result}
	t.uploads[slot] = {request = request, texture = texture, data = data, active = true}
	return .Set
}

// Whether texture_levels_queue has room for another texture now.
texture_upload_room :: proc(r: ^Renderer) -> bool {
	for upload in r.textures.residency.uploads {if !upload.active {return true}}
	return false
}

// The first of the levels of data a texture added over frames
// (texture_add_over_frames) gets at once: the largest of side TEXTURE_TAIL
// or less. 0 when no level is larger, or when its loader cannot read the
// levels again (no source): then it goes whole.
texture_tail_first :: proc "contextless" (data: Texture_Data) -> int {
	if data.source.x <= 0 || data.source.y <= 0 || data.layers > 1 || data.cube {return 0}
	for level in 0 ..< len(data.levels) {
		if max(data.width >> uint(level), data.height >> uint(level)) <= TEXTURE_TAIL {return level}
	}
	return 0
}

// Adds a streamed texture with the levels of data from texture_tail_first
// on, at once, and gives it the larger ones over the frames that follow, as
// texture_levels_queue does: until every row of them went it is sampled with
// its small levels, never with a level half there. The levels are borrowed;
// first the largest ones the pool has no room for are left out of data.
// - Set: the larger levels go; data stays as it is while
//   texture_upload_pending(request).
// - Busy: TEXTURE_UPLOADS textures take levels already; nothing was added.
// - Mismatch: data has no larger level to give later; nothing was added.
// - Failed with no handle: the texture was not added (Renderer.error).
// Any other result with a handle leaves the texture with its small levels,
// which its distance can widen.
texture_add_over_frames :: proc(r: ^Renderer, data: ^Texture_Data, name: string) -> (handle: Texture_Handle, request: Texture_Request, result: Texture_Levels_Result) {
	if !texture_upload_room(r) {return 0, {}, .Busy}
	skip, _ := texture_pool_first(r, data^)
	if skip > 0 {
		remove_range(&data.levels, 0, skip)
		data.width, data.height, data.level = max(data.width >> uint(skip), 1), max(data.height >> uint(skip), 1), data.level + skip
	}
	now := texture_tail_first(data^)
	if now == 0 {return 0, {}, .Mismatch}
	small := Texture_Data{format = data.format, width = max(data.width >> uint(now), 1), height = max(data.height >> uint(now), 1), level = data.level + now, source = data.source}
	small.levels = make([dynamic][]u8, 0, len(data.levels) - now, context.temp_allocator)
	append(&small.levels, ..data.levels[now:])
	added: bool
	if handle, added = texture_add_data(r, small, name); !added {return 0, {}, .Failed}
	index := int(handle) - 1
	if index >= len(r.textures.residency.streams) {return handle, {}, .Stale}
	request = {handle = handle, level = data.level, stamp = r.textures.residency.streams[index].stamp}
	return handle, request, texture_levels_queue(r, request, data^)
}

// Whether the levels of a request still go to the GPU, which reads them from
// the data texture_levels_queue was given.
texture_upload_pending :: proc(r: ^Renderer, request: Texture_Request) -> bool {
	for upload in r.textures.residency.uploads {if upload.active && upload.request == request {return true}}
	return false
}

// Drops the levels that still go: before what they are read from goes.
texture_uploads_cancel :: proc(r: ^Renderer) {
	for &upload in r.textures.residency.uploads {
		if upload.active {rhi.texture_destroy(r.device, upload.texture)}
		upload = {}
	}
}

// Rows of the levels that go, their part of UPLOAD_FRAME_BYTES
// (textures_upload_budget), through the ring of the frame into the list of
// the frame; a texture whose rows all went takes its entry of the table
// before the next frame. One whose request is stale goes.
@(private)
texture_uploads_record :: proc(r: ^Renderer, cmd: ^rhi.Command_List) {
	state := &r.textures
	share := textures_upload_budget(&r.scene)
	budget := share
	defer r.scene.uploads.textures_spent = share - budget
	for &upload in state.residency.uploads {
		if !upload.active || upload.done {continue}
		index := int(upload.request.handle) - 1
		if index < 0 || index >= state.count || state.textures[index] == 0 || state.residency.streams[index].stamp != upload.request.stamp {
			rhi.texture_destroy(r.device, upload.texture)
			upload = {}
			continue
		}
		for upload.mip < len(upload.data.levels) && budget > 0 {
			width, height := u32(max(upload.data.width >> uint(upload.mip), 1)), u32(max(upload.data.height >> uint(upload.mip), 1))
			row, rows := rhi.format_rows(upload.data.format, width, height)
			block := u32(4) if rhi.format_block_size(upload.data.format) > 0 else 1
			count := u32(min(u64(rows) - u64(upload.row), max(budget / row, 1)))
			bytes := u64(count) * row
			ring := rhi.frame_alloc(r.device, bytes, 16)
			if ring.ptr == nil {budget = 0;break}
			level := upload.data.levels[upload.mip]
			copy(([^]u8)(ring.ptr)[:bytes], level[u64(upload.row) * row:][:bytes])
			y := upload.row * block
			rhi.cmd_copy_buffer_to_texture(cmd, ring.buffer, ring.offset, upload.texture, u32(upload.mip), {0, y, width, min(count * block, height - y)})
			budget -= min(bytes, budget)
			upload.bytes += bytes
			upload.row += count
			if u64(upload.row) >= u64(rows) {upload.mip, upload.row = upload.mip + 1, 0}
		}
		if upload.mip < len(upload.data.levels) {continue}
		rhi.cmd_barrier_texture(cmd, upload.texture, .Shader_Read)
		upload.done = true
	}
}

// The textures whose rows all went take their entries of the table, between
// frames: the frame after them reads them.
@(private)
texture_uploads_install :: proc(r: ^Renderer) {
	for &upload in r.textures.residency.uploads {
		if !upload.active || !upload.done {continue}
		texture_levels_install(r, upload.request, upload.data, upload.texture, upload.bytes)
		upload = {}
	}
}

// Gives a streamed texture the levels of its source a request asked for,
// as a transaction between frames: a texture with those levels takes its
// entry of the table, and its handle stays. Anything but Set changes nothing.
texture_levels_set :: proc(r: ^Renderer, request: Texture_Request, data: Texture_Data) -> Texture_Levels_Result {
	texture, result := texture_levels_check(r, request, data)
	if result != .Set {return result}
	bytes: u64
	uploaded := true
	for level, mip in data.levels {
		row, _ := rhi.format_rows(data.format, u32(max(data.width >> uint(mip), 1)), u32(max(data.height >> uint(mip), 1)))
		bytes += u64(len(level))
		uploaded &&= rhi.texture_upload(r.device, texture, level, u32(row), u32(mip))
	}
	if !uploaded {
		set_error(r, "texture levels: %s", rhi.device_error(r.device))
		rhi.texture_destroy(r.device, texture)
		return .Failed
	}
	return texture_levels_install(r, request, data, texture, bytes)
}

// The texture of a request keeps the levels it has from now on: its loader
// cannot read other levels of its source. Nothing when it changed since.
texture_stream_stop :: proc(r: ^Renderer, request: Texture_Request) {
	index := int(request.handle) - 1
	if index < 0 || index >= len(r.textures.residency.streams) || r.textures.residency.streams[index].stamp != request.stamp {return}
	texture_stream_forget(&r.textures, index)
}

// The stream of a texture given data, of which it holds the levels from
// `dropped` on: none for one not streamed, as an array or a cube. What shows it is not known yet.
@(private)
texture_stream_set :: proc(stream: ^Texture_Stream, data: Texture_Data, dropped: int) {
	stream^ = {stamp = stream.stamp + 1}
	if data.source.x <= 0 || data.source.y <= 0 || data.layers > 1 || data.cube || data.level + len(data.levels) > rhi.MAX_TEXTURE_MIPS {return}
	stream.size = {u32(data.source.x), u32(data.source.y)}
	stream.format = data.format
	stream.levels = u8(data.level + len(data.levels))
	stream.top = u8(data.level + dropped)
	stream.target = stream.top
	texture_chain(stream)
}

// The bytes of the levels of the source of a stream from each one on, in its format.
@(private)
texture_chain :: proc "contextless" (stream: ^Texture_Stream) {
	below: u64
	for level := int(stream.levels) - 1; level >= 0; level -= 1 {
		row, rows := rhi.format_rows(stream.format, max(stream.size.x >> uint(level), 1), max(stream.size.y >> uint(level), 1))
		below += row * rows
		stream.chain[level] = below
	}
}

// The entry of the table holds no streamed texture any more.
@(private)
texture_stream_forget :: proc "contextless" (state: ^Texture_State, index: int) {
	t := &state.residency
	if index < 0 || index >= len(t.streams) {return}
	stream := &t.streams[index]
	if stream.levels > 0 && stream.target != stream.top {t.pending = max(t.pending - 1, 0)}
	stream^ = {stamp = stream.stamp + 1}
	t.stale = true
}
