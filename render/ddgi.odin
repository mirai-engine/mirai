package mirai_render

import "core:math"
import "mirai:rhi"

// The probe volume: cascades of probes centered on the focus of the camera of
// the first view (Camera.focus), each twice as far apart as the one before (Settings.probe_spacing the
// first), probe_grid of them along x and z and half that along y. A cell of
// the world keeps its probe while the cascades scroll. Each frame traces at
// most probe_budget probes (ddgi_select.comp): those a new cell took, those a
// change reached and, after a change everywhere, the longest untraced against
// how much the pixels use them. A probe traces the same directions every
// time, whole and without hysteresis: one of a scene that did not change
// gives what it gave, and one that did follows at once. One whose light moved
// by more than a hundredth is traced again the next frame, until what its
// rays find (the probes around) settles.

IRRADIANCE_TILE :: 8
DISTANCE_TILE   :: 16
// Must match VOLUME_CASCADES_MAX of common.slang.
VOLUME_CASCADES_MAX :: 6
PROBE_GRID_MAX :: 32
// Buckets of the priority of the probes, and the words of the histogram
// after them (ddgi_select.comp).
PROBE_BUCKETS :: 22
PROBE_HISTOGRAM_WORDS :: PROBE_BUCKETS + 4
// The indirect dispatches of the update passes, in words: the trace, the
// passes per probe and the passes per 32 probes.
PROBE_DISPATCH_WORDS :: 12
// Probes an update traces at most while it gathers the light of a world
// shown anew (gi_warm), several updates in one frame.
PROBE_WARM_BUDGET :: 2048
// Seconds a change keeps the probes it reaches traced.
PROBE_AWAKE :: f32(1)

Ddgi_State :: struct {
	counts:             [3]u32, // probes of a cascade along each axis
	cascades:           u32,
	spacing:            f32,    // of the first cascade
	total:              u32,
	per_row:            u32,    // probes per row of the atlases
	rays_per_probe:     u32,
	budget:             u32,
	corners:            [VOLUME_CASCADES_MAX]Vec4, // of this frame: the place of the lowest probe of each cascade, relative to the origin, w its spacing
	cells:              [VOLUME_CASCADES_MAX][4]i32, // and its cell of the world
	center:             Vec3,   // of this frame: where the cascades centre, relative to the origin, off their corners by up to half a cell
	changed_everywhere: u32,    // frame of the last change everywhere
	probes:             rhi.Buffer,
	buckets:            rhi.Buffer,
	histogram:          rhi.Buffer,
	chosen:             rhi.Buffer, // count, then slots
	dispatch:           rhi.Buffer,
	irradiance:         rhi.Texture,
	kept:               rhi.Texture, // the irradiance of each probe after its last trace, which the filter reads its neighbors from
	distance:           rhi.Texture,
	rays:               rhi.Texture,
	needs_clear:        bool,
	valid:              bool,
}

@(private)
ddgi_release :: proc(r: ^Renderer) {
	g := &r.ddgi
	d := r.device
	for b in ([]rhi.Buffer{g.probes, g.buckets, g.histogram, g.chosen, g.dispatch}) {if b != 0 {rhi.buffer_destroy(d, b)}}
	for t in ([]rhi.Texture{g.irradiance, g.kept, g.distance, g.rays}) {if t != 0 {rhi.texture_destroy(d, t)}}
	g^ = {}
}

// Creates the volume the settings ask for, once: a frame that already has it
// creates nothing.
@(private)
ddgi_ensure :: proc(r: ^Renderer) -> bool {
	g := &r.ddgi
	settings := &r.settings
	if g.valid {return true}
	grid := clamp(settings.probe_grid / 2 * 2, 4, PROBE_GRID_MAX)
	g.counts = {grid, grid / 2, grid}
	g.cascades = clamp(settings.probe_cascades, 1, VOLUME_CASCADES_MAX)
	g.spacing = max(settings.probe_spacing, 0.1)
	g.total = g.counts[0] * g.counts[1] * g.counts[2] * g.cascades
	g.per_row = u32(math.ceil(math.sqrt(f32(g.total))))
	rows := (g.total + g.per_row - 1) / g.per_row
	g.rays_per_probe = clamp(settings.probe_rays / 32 * 32, 32, 256)
	g.budget = clamp(settings.probe_budget, 1, g.total)
	room := max(g.budget, min(PROBE_WARM_BUDGET, g.total))
	d := r.device
	g.probes = rhi.buffer_create(d, {size = u64(g.total) * size_of(Gpu_Probe), usage = {.Storage}, name = "probes"})
	g.buckets = rhi.buffer_create(d, {size = u64(g.total) * 4, usage = {.Storage}, name = "probe buckets"})
	g.histogram = rhi.buffer_create(d, {size = PROBE_HISTOGRAM_WORDS * 4, usage = {.Storage}, name = "probe histogram"})
	g.chosen = rhi.buffer_create(d, {size = u64(1 + room) * 4, usage = {.Storage}, name = "chosen probes"})
	g.dispatch = rhi.buffer_create(d, {size = PROBE_DISPATCH_WORDS * 4, usage = {.Storage, .Indirect}, name = "probe dispatch"})
	g.irradiance = rhi.texture_create(d, {width = g.per_row * IRRADIANCE_TILE, height = rows * IRRADIANCE_TILE, format = .RGBA16_Float, usage = {.Sampled, .Storage, .Color_Target}, name = "probe irradiance"})
	g.kept = rhi.texture_create(d, {width = g.per_row * IRRADIANCE_TILE, height = rows * IRRADIANCE_TILE, format = .RGBA16_Float, usage = {.Sampled, .Storage, .Color_Target}, name = "probe irradiance kept"})
	g.distance = rhi.texture_create(d, {width = g.per_row * DISTANCE_TILE, height = rows * DISTANCE_TILE, format = .RGBA16_Float, usage = {.Sampled, .Storage, .Color_Target}, name = "probe distance"})
	g.rays = rhi.texture_create(d, {width = g.rays_per_probe, height = room, format = .RGBA16_Float, usage = {.Sampled, .Storage}, name = "probe rays"})
	// No probe holds light: every slot stands for a cell it was not traced for.
	initial := make([]Gpu_Probe, g.total, context.temp_allocator)
	for &p in initial {p.cell = {min(i32), min(i32), min(i32), 0}}
	ok := g.probes != 0 && g.buckets != 0 && g.histogram != 0 && g.chosen != 0 && g.dispatch != 0 && g.irradiance != 0 && g.kept != 0 && g.distance != 0 && g.rays != 0
	if !ok || !rhi.buffer_upload(d, g.probes, 0, slice_bytes(initial)) {
		set_error(r, "probe volume: %s", rhi.device_error(d))
		ddgi_release(r)
		return false
	}
	g.changed_everywhere = u32(r.light_frame)
	g.needs_clear = true
	g.valid = true
	return true
}

// The cascades of this frame around center, one spacing of the first cascade
// below it: an eye sees mostly what is under it, and with probe_grid 16 (8
// probes high) the floor 2.5 m under it fell to the next cascade, whose probes
// see past the walls. Each corner on the grid of the world, which keeps the
// slots of its cells wherever the origin is, and its place relative to the
// origin. center: relative to the origin.
@(private)
ddgi_place :: proc(r: ^Renderer, center: Vec3) {
	g := &r.ddgi
	center := center - {0, g.spacing, 0}
	g.center = center
	for c in 0 ..< g.cascades {
		spacing := f64(g.spacing) * f64(u32(1) << c)
		cell: [4]i32
		for axis in 0 ..< 3 {
			cell[axis] = i32(math.round((f64(center[axis]) + f64(r.origin[axis])) / spacing)) - i32(g.counts[axis] / 2)
		}
		corner := origin_cell(cell.xyz, spacing, r.origin)
		g.corners[c], g.cells[c] = {corner.x, corner.y, corner.z, f32(spacing)}, cell
	}
}

@(private)
ddgi_frame_constants :: proc(r: ^Renderer, f: ^Gpu_Frame) {
	g := &r.ddgi
	if !g.valid {return}
	f.volume_cascades = g.corners
	f.volume_cells = g.cells
	f.volume_center = {g.center.x, g.center.y, g.center.z, 0}
	f.volume_counts = {g.counts[0], g.counts[1], g.counts[2], g.cascades}
	f.volume_atlas = {g.per_row, IRRADIANCE_TILE, DISTANCE_TILE, 1}
}

// The probes of the frame: marked by the changes the scene lists and the
// pixels of the view, chosen by priority, traced, and their atlases and
// places updated. `warm`: one of the updates that gather the light of a world
// shown anew in one frame, with a larger budget, as after a change everywhere.
@(private)
ddgi_update :: proc(p: ^Pass, warm := false) -> bool {
	r, cmd, t := p.r, p.cmd, p.t
	g := &r.ddgi
	settings := &r.settings
	if g.needs_clear {
		clear_textures(cmd, g.irradiance, g.kept, g.distance)
		g.needs_clear = false
	}
	frame_number := u32(r.light_frame)
	// Frames a change keeps the probes it reaches traced: until the bounces
	// their rays read from the volume around have settled.
	awake := u32(math.ceil(PROBE_AWAKE / max(r.delta_time, 1.0 / 240)))
	changes := &r.scene.changes
	if changes.all || warm {g.changed_everywhere = frame_number}
	budget := min(PROBE_WARM_BUDGET, g.total) if warm else g.budget
	if changes.count > 0 && !changes.all {
		Params :: struct {count, frame_number, total, awake: u32}
		params := Params{count = u32(changes.count), frame_number = frame_number, total = g.total, awake = awake}
		rhi.cmd_bind_pipeline(cmd, r.pipelines[.Ddgi_Touch])
		set_params(cmd, &params)
		rhi.cmd_bind_buffer(cmd, SLOT_PROBES, g.probes)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS0, r.light_changes)
		rhi.cmd_dispatch(cmd, groups(g.total, 64))
	}
	{
		Params :: struct {frame_number, pad0, pad1, pad2: u32}
		params := Params{frame_number = frame_number}
		rhi.cmd_bind_pipeline(cmd, r.pipelines[.Ddgi_Mark])
		set_params(cmd, &params)
		rhi.cmd_bind_buffer(cmd, SLOT_PROBES, g.probes)
		rhi.cmd_bind_texture(cmd, SLOT_PASS0, t.normal)
		rhi.cmd_bind_texture(cmd, SLOT_PASS1, t.linear_depth)
		rhi.cmd_dispatch(cmd, groups(groups(t.width, 8), 8), groups(groups(t.height, 8), 8))
	}
	rhi.cmd_fill_buffer(cmd, g.histogram, 0, PROBE_HISTOGRAM_WORDS * 4, 0)
	Select :: struct {mode, budget, changed_everywhere, frame_number, rays_per_probe, total, awake, whole: u32}
	select := Select{budget = budget, changed_everywhere = g.changed_everywhere, frame_number = frame_number, rays_per_probe = g.rays_per_probe, total = g.total, awake = awake, whole = 1 if warm else 0}
	for mode in u32(0) ..< 4 {
		select.mode = mode
		rhi.cmd_bind_pipeline(cmd, r.pipelines[.Ddgi_Select])
		set_params(cmd, &select)
		rhi.cmd_bind_buffer(cmd, SLOT_PROBES, g.probes)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS0, g.buckets)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS1, g.histogram)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS2, g.chosen)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS3, g.dispatch)
		rhi.cmd_dispatch(cmd, groups(g.total, 64) if mode % 2 == 0 else 1)
	}
	Update :: struct {rays_per_probe, light_budget: u32, max_distance: f32, frame_number, resume, pad0, pad1, pad2: u32}
	update := Update{rays_per_probe = g.rays_per_probe, light_budget = min(settings.light_budget, PROBE_LIGHT_BUDGET), max_distance = 1e4, frame_number = frame_number}
	// The rays, then what waits for the programs of what they hit.
	batch := points_begin(p)
	trace := shadow_pipeline(r, .Ddgi_Trace, .Ddgi_Trace_Hw, .Ddgi_Trace_Color, .Ddgi_Trace_Color_Hw)
	rhi.cmd_bind_pipeline(cmd, trace)
	set_params(cmd, &update)
	rhi.cmd_bind_texture(cmd, SLOT_PASS0, g.rays)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS2, g.chosen)
	rhi.cmd_bind_buffer(cmd, SLOT_PROBES, g.probes)
	points_bind(p)
	rhi.cmd_dispatch_indirect(cmd, g.dispatch, 0)
	points_rounds(p, batch, trace, &update, 1)
	for pipeline, i in ([2]Pipeline_Id{.Ddgi_Irradiance, .Ddgi_Distance}) {
		rhi.cmd_bind_pipeline(cmd, r.pipelines[pipeline])
		set_params(cmd, &update)
		rhi.cmd_bind_texture(cmd, SLOT_PASS0, g.rays)
		rhi.cmd_bind_texture(cmd, SLOT_PASS1, g.irradiance if i == 0 else g.distance)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS2, g.chosen)
		rhi.cmd_bind_texture(cmd, SLOT_PASS3, g.kept)
		rhi.cmd_bind_buffer(cmd, SLOT_PROBES, g.probes)
		rhi.cmd_dispatch_indirect(cmd, g.dispatch, 12)
	}
	rhi.cmd_bind_pipeline(cmd, r.pipelines[.Ddgi_Keep])
	set_params(cmd, &update)
	rhi.cmd_bind_texture(cmd, SLOT_PASS1, g.irradiance)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS2, g.chosen)
	rhi.cmd_bind_texture(cmd, SLOT_PASS3, g.kept)
	rhi.cmd_dispatch_indirect(cmd, g.dispatch, 12)
	rhi.cmd_bind_pipeline(cmd, r.pipelines[.Ddgi_Relocate])
	set_params(cmd, &update)
	rhi.cmd_bind_texture(cmd, SLOT_PASS0, g.rays)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS2, g.chosen)
	rhi.cmd_bind_buffer(cmd, SLOT_PROBES, g.probes)
	rhi.cmd_dispatch_indirect(cmd, g.dispatch, 24)
	return true
}
