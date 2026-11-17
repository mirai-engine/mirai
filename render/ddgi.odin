package mirai_render

import "core:math"
import "core:math/linalg"
import "mirai:rhi"
import "mirai:render/abi"

// The probe volume: cascades of probes centered on the focus of the camera of
// the first view (Camera.focus), each twice as far apart as the one before (Settings.probe_spacing the
// first), probe_grid of them along x and z and half that along y. A cell of
// the world keeps its probe while the cascades scroll. Each frame traces at
// most probe_budget probes (ddgi_select.comp): those a new cell took, those a
// change reached and, by turns, the longest untraced against how much the
// pixels use them of those a change everywhere left behind or whose rays met
// what changes with nothing that says so (a program that reads the time). A
// probe traces the same directions every time, whole and without
// hysteresis: one of a scene that did not change gives what it gave, and one
// that did follows at once. One whose light moved
// by more than a hundredth is traced again the next frame, until what its
// rays find (the probes around) settles.
//
// A probe keeps what each of its rays found (Probe_Hits): an update traces a
// ray again only where what it may meet changed and lights its hit again only
// where its lights did, and of the others it reads the bounces again.

IRRADIANCE_TILE :: 8
DISTANCE_TILE   :: abi.DISTANCE_TILE
VOLUME_CASCADES_MAX :: abi.VOLUME_CASCADES_MAX
PROBE_GRID_MAX :: 32
// Buckets of the priority of the probes, and the words of the histogram
// after them (ddgi_select.comp).
PROBE_BUCKETS :: abi.PROBE_BUCKETS
PROBE_HISTOGRAM_WORDS :: PROBE_BUCKETS + 4
// The indirect dispatches of the update passes, in words: the trace, the
// passes per probe and the passes per 32 probes.
PROBE_DISPATCH_WORDS :: 12
// Probes an update traces at most while it gathers the light of a world
// shown anew (gi_warm), several updates in one frame.
PROBE_WARM_BUDGET :: 2048
// Seconds a change keeps the probes it reaches traced.
PROBE_AWAKE :: f32(1)

// Bytes what the probes keep of their rays takes at most: where every probe
// does not fit them, they share the slots (probe_slots.slang).
PROBE_HITS_BYTES :: 128 << 20

// What the probes of the volume shown keep of their rays between updates
// (probe_hits.slang): PROBE_HIT_WORDS a ray of the probe that holds each slot,
// and the changes of the scene a probe checks it against when it is updated,
// the newest first, each with the update, plus one, that listed it. A probe
// last updated before a change that left the list (`lost`) traces all its rays.
Probe_Hits :: struct {
	records: rhi.Buffer,
	slots:   rhi.Buffer, // a Probe_Slot each
	changes: rhi.Buffer,
	count:   u32,        // slots
	rays:    u32,        // of each
	clear:   bool,       // the slots were made: no probe holds one
	listed:  [abi.PROBE_CHANGES_MAX]Probe_Change,
	listed_count: int,
	lost:    u32,  // the update, plus one, of the newest change that left the list
	dirty:   bool, // the list is not the one the GPU has
}
// A change as the shaders read it: a box, low then high, with its kind
// (abi.PROBE_CHANGE_*) and the update that listed it, plus one; and the light
// of a shadow, or the sphere of a light that changed (xyz, w its reach).
Probe_Change :: struct {
	low:   Vec3,
	kind:  u32,
	high:  Vec3,
	stamp: u32,
	light: Vec4,
}
#assert(size_of(Probe_Change) == 48)
// A slot as the shaders read it (probe_slots.slang).
Probe_Slot :: struct {
	owner:      u32, // the probe that holds it, plus one; 0: none
	kept_until: u32, // the update until which a probe that is chosen leaves it to it
}
// Changes of one frame the list takes: with more, it changed everywhere.
PROBE_CHANGES_FRAME :: abi.PROBE_CHANGES_MAX / 4

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
	// The update, plus one, in which what rays meet last changed everywhere
	// and the one in which the lights did: what a probe keeps of its rays
	// from before is traced or lit again (probe_hits.slang).
	seen_everywhere:    u32,
	lit_everywhere:     u32,
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
	// After the count and the probes: whether each traced a ray, then the rays the update traced and the hits it lit.
	g.chosen = rhi.buffer_create(d, {size = u64(1 + 2 * room + 2) * 4, usage = {.Storage}, name = "chosen probes"})
	g.dispatch = rhi.buffer_create(d, {size = PROBE_DISPATCH_WORDS * 4, usage = {.Storage, .Indirect}, name = "probe dispatch"})
	// Under the tiles of the irradiance, those of the light around the narrow lobes, in the same rows and columns.
	g.irradiance = rhi.texture_create(d, {width = g.per_row * max(IRRADIANCE_TILE, abi.PROBE_GLOSS_TILE), height = rows * (IRRADIANCE_TILE + abi.PROBE_GLOSS_TILE), format = .RGBA16_Float, usage = {.Sampled, .Storage, .Color_Target}, name = "probe irradiance"})
	g.kept = rhi.texture_create(d, {width = g.per_row * IRRADIANCE_TILE, height = rows * IRRADIANCE_TILE, format = .RGBA16_Float, usage = {.Sampled, .Storage, .Color_Target}, name = "probe irradiance kept"})
	g.distance = rhi.texture_create(d, {width = g.per_row * DISTANCE_TILE, height = rows * DISTANCE_TILE, format = .RGBA16_Float, usage = {.Sampled, .Storage, .Color_Target}, name = "probe distance"})
	g.rays = rhi.texture_create(d, {width = g.rays_per_probe, height = room, format = .RGBA16_Float, usage = {.Sampled, .Storage}, name = "probe rays"})
	// No probe holds light: every slot stands for a cell it was not traced for.
	initial := make([]Gpu_Probe, g.total, context.temp_allocator)
	for &p in initial {p.cell = {min(i32), min(i32), min(i32), 0}}
	ok := g.probes != 0 && g.buckets != 0 && g.histogram != 0 && g.chosen != 0 && g.dispatch != 0 && g.irradiance != 0 && g.kept != 0 && g.distance != 0 && g.rays != 0
	if !ok || !rhi.buffer_upload(d, g.probes, 0, slice_bytes(initial)) || !probe_hits_ensure(r) {
		set_error(r, "probe volume: %s", rhi.device_error(d))
		ddgi_release(r)
		return false
	}
	g.needs_clear = true
	g.valid = true
	return true
}

// Probes the list of the chosen has room for.
@(private)
ddgi_room :: proc "contextless" (g: ^Ddgi_State) -> u32 {return max(g.budget, min(PROBE_WARM_BUDGET, g.total))}

// Where the list of the chosen counts the rays an update traced and the hits it lit, in bytes.
@(private)
ddgi_counts_offset :: proc "contextless" (g: ^Ddgi_State) -> u64 {return u64(1 + 2 * ddgi_room(g)) * 4}

// Room for what the probes of the volume keep of their rays: a slot for each
// while they fit PROBE_HITS_BYTES. It is made again only for a volume of
// other rays or another number of slots: what it holds of another volume, no
// probe counts on (Ddgi_State.seen_everywhere).
@(private)
probe_hits_ensure :: proc(r: ^Renderer) -> bool {
	g, h := &r.ddgi, &r.probe_hits
	bytes := u64(g.rays_per_probe) * abi.PROBE_HIT_WORDS * 4
	count := u32(min(u64(g.total), PROBE_HITS_BYTES / bytes))
	if h.records != 0 && h.count == count && h.rays == g.rays_per_probe {return true}
	probe_hits_release(r)
	d := r.device
	h.records = rhi.buffer_create(d, {size = u64(count) * bytes, usage = {.Storage}, name = "probe hits"})
	h.slots = rhi.buffer_create(d, {size = u64(count) * size_of(Probe_Slot), usage = {.Storage}, name = "probe hit slots"})
	h.changes = rhi.buffer_create(d, {size = abi.PROBE_CHANGES_MAX * size_of(Probe_Change), usage = {.Storage}, name = "probe changes"})
	if h.records == 0 || h.slots == 0 || h.changes == 0 {
		probe_hits_release(r)
		return false
	}
	h.count, h.rays, h.clear = count, g.rays_per_probe, true
	return true
}

@(private)
probe_hits_release :: proc(r: ^Renderer) {
	h := &r.probe_hits
	for b in ([]rhi.Buffer{h.records, h.slots, h.changes}) {if b != 0 {rhi.buffer_destroy(r.device, b)}}
	h.records, h.slots, h.changes, h.count, h.rays = 0, 0, 0, 0, 0
}

// Lists what changed since the last update for what the probes keep of their
// rays, with `stamp`: the boxes in which what a ray may meet changed and the
// spheres of the lights that did (Light_Changes), and what casts shadows and
// changed (Occluder_Changes), with the shadow the sun gives it and the one
// each light that reaches it does. The boxes go first: `seen` false when they
// are more than the list takes of a frame, and what rays meet changed
// everywhere; `lit` false when the lights and the shadows are, and the lights
// changed everywhere.
@(private)
probe_changes_list :: proc(r: ^Renderer, changes: ^Light_Changes, moved: ^Occluder_Changes, stamp: u32) -> (seen, lit: bool) {
	h := &r.probe_hits
	s := &r.scene
	fresh: [PROBE_CHANGES_FRAME]Probe_Change
	count := 0
	add :: proc(fresh: ^[PROBE_CHANGES_FRAME]Probe_Change, count: ^int, change: Probe_Change) -> bool {
		if count^ == len(fresh) {return false}
		fresh[count^] = change
		count^ += 1
		return true
	}
	seen, lit = true, true
	for box in moved.boxes[:moved.count] {
		seen &&= add(&fresh, &count, {low = box.low, high = box.high, kind = abi.PROBE_CHANGE_CASTER, stamp = stamp})
	}
	each: for i in 0 ..< changes.count {
		low, high := changes.boxes[i][0].xyz, changes.boxes[i][1].xyz
		if !(low.x <= high.x && low.y <= high.y && low.z <= high.z) {continue}
		// What casts shadows and changed is listed with its shadows.
		for caster in moved.boxes[:moved.count] {
			if low.x >= caster.low.x && low.y >= caster.low.y && low.z >= caster.low.z && high.x <= caster.high.x && high.y <= caster.high.y && high.z <= caster.high.z {continue each}
		}
		seen &&= add(&fresh, &count, {low = low, high = high, kind = abi.PROBE_CHANGE_SEEN, stamp = stamp})
	}
	if !seen {return false, false}
	boxes := count
	for sphere, i in changes.spheres[:changes.count] {
		low, high := changes.boxes[i][0].xyz, changes.boxes[i][1].xyz
		if !changes.all && !(low.x <= high.x && low.y <= high.y && low.z <= high.z) {
			lit &&= add(&fresh, &count, {kind = abi.PROBE_CHANGE_LIGHT, stamp = stamp, light = sphere})
		}
	}
	shadows: for box in moved.boxes[:moved.count] {
		for light in s.lights {
			// The box is within the reach of the light: the rays to it of what it lights may cross the box.
			reach := light.position_range.w
			nearest := linalg.clamp(light.position_range.xyz, box.low, box.high)
			if linalg.length2(nearest - light.position_range.xyz) >= reach * reach {continue}
			// A ray to a point of a light that has a size passes that far from its center.
			size := max(light.size.x, light.size.y, light.size.z if light_rect(light) else 0)
			lit &&= add(&fresh, &count, {low = box.low - size, high = box.high + size, kind = abi.PROBE_CHANGE_SHADOW, stamp = stamp, light = light.position_range})
			if !lit {break shadows}
		}
	}
	if !lit {count = boxes}
	if count == 0 {return}
	kept := min(h.listed_count, len(h.listed) - count)
	if kept < h.listed_count {h.lost = h.listed[kept].stamp}
	copy(h.listed[count:count + kept], h.listed[:kept])
	copy(h.listed[:count], fresh[:count])
	h.listed_count = count + kept
	h.dirty = true
	return
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
// `first`: the first update of the frame, which takes what changed since the
// last one.
@(private)
ddgi_update :: proc(p: ^Pass, warm := false, first := true) -> bool {
	r, cmd, t := p.r, p.cmd, p.t
	g := &r.ddgi
	h := &r.probe_hits
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
	budget := min(PROBE_WARM_BUDGET, g.total) if warm else g.budget
	room := ddgi_room(g)
	if h.clear {
		rhi.cmd_fill_buffer(cmd, h.slots, 0, u64(h.count) * size_of(Probe_Slot), 0)
		h.clear = false
	}
	if first {
		stamp := frame_number + 1
		// The sun that turned gives every caster another shadow.
		if changes.all || r.frame_occluders.sun {g.lit_everywhere = stamp}
		if changes.all && changes.seen {
			g.seen_everywhere = stamp
		} else {
			seen, lit := probe_changes_list(r, changes, &r.frame_occluders, stamp)
			if !seen {g.seen_everywhere = stamp}
			if !lit {g.lit_everywhere = stamp}
		}
		if h.dirty {
			if !upload_transient(r, cmd, h.listed[:h.listed_count], h.changes) {return false}
			h.dirty = false
		}
	}
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
	Select :: struct {mode, budget, frame_number, rays_per_probe, total, awake, whole, room, slots, seen_everywhere, lit_everywhere, pad0: u32}
	select := Select{budget = budget, frame_number = frame_number, rays_per_probe = g.rays_per_probe, total = g.total, awake = awake, whole = 1 if warm else 0, room = room, slots = h.count, seen_everywhere = g.seen_everywhere, lit_everywhere = g.lit_everywhere}
	for mode in u32(0) ..< 4 {
		select.mode = mode
		rhi.cmd_bind_pipeline(cmd, r.pipelines[.Ddgi_Select])
		set_params(cmd, &select)
		rhi.cmd_bind_buffer(cmd, SLOT_PROBES, g.probes)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS0, g.buckets)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS1, g.histogram)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS2, g.chosen)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS3, g.dispatch)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS4, h.slots)
		rhi.cmd_dispatch(cmd, groups(g.total, 64) if mode % 2 == 0 else 1)
	}
	Update :: struct {rays_per_probe, light_budget: u32, max_distance: f32, frame_number, resume, room, changes, changes_lost, seen_everywhere, lit_everywhere, slots, pad0: u32}
	update := Update{
		rays_per_probe = g.rays_per_probe, light_budget = min(settings.light_budget, PROBE_LIGHT_BUDGET), max_distance = 1e4, frame_number = frame_number,
		room = room, changes = u32(h.listed_count), changes_lost = h.lost, seen_everywhere = g.seen_everywhere, lit_everywhere = g.lit_everywhere, slots = h.count,
	}
	// The rays, then what waits for the programs of what they hit.
	batch := points_begin(p)
	trace := pipeline_of(r, .Ddgi_Trace, {DDGI_TRACE_COMP_COLOR} if shadows_colored(r) else {}, {DDGI_TRACE_COMP_COLOR})^
	rhi.cmd_bind_pipeline(cmd, trace)
	set_params(cmd, &update)
	rhi.cmd_bind_texture(cmd, SLOT_PASS0, g.rays)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS1, h.records)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS2, g.chosen)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS3, h.changes)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS4, h.slots)
	rhi.cmd_bind_buffer(cmd, SLOT_PROBES, g.probes)
	points_bind(p)
	textures_feedback_bind(r, cmd)
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
	rhi.cmd_bind_buffer(cmd, SLOT_PASS4, h.slots)
	rhi.cmd_bind_buffer(cmd, SLOT_PROBES, g.probes)
	rhi.cmd_dispatch_indirect(cmd, g.dispatch, 24)
	return true
}
