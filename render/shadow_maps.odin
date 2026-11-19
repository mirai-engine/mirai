package mirai_render

import "base:intrinsics"
import "core:hash"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:slice"
import "core:strings"
import "mirai:render/abi"
import "mirai:rhi"
import "mirai:std/base"

// Shadow maps in place of the rays of the direct light for the lights that
// light much of the view and for the sun. Each frame, from the camera and the
// lights alone, the lights whose sphere covers SHADOW_RASTER_SHARE of the view
// (and keep SHADOW_RASTER_KEEP once they do) take a map for each face of the
// cube around them through which they light what the view sees, and the sun
// one for each of its levels around the eye. The other lights, small on the
// screen, trace rays (shadow_maps.slang, shadow_maps.comp, shadow_clusters.comp,
// direct_samples.comp). The clusters of each page are drawn through the lists
// of the raster of the view (raster_lists.slang): each vertex placed once for
// the page, and only the triangles that cover a texel of it.
//
// A map is a square of pages of SHADOW_PAGE texels at each of its mips. Only
// the pages the points of the view read are drawn (shadow_mark.comp marks
// them, with the taps around each point): each takes a page of the pool of the
// view, its atlas, through the table of the pages (shadow_pages.comp), in the
// frame a point first reads it, in one order every frame, the coarsest first,
// so that where the pool runs out the finest pages are left out, the same
// every frame, and their points read the nearest coarser page drawn. A page keeps its place while it is not needed, until
// another page needs it, and it is drawn again while what stays changes
// under it even then, so that a page a point reads is always that of this
// frame. The cost follows what changed: a page draws again in the cache only
// where it is new or what stays changed in it, and the atlas composes the
// cache and what moves (shadow_movers_update) only in the pages where the
// cache drew or what moves was or is. What a map draws is chosen by its
// texels, not by the eye: its detail (shadow_map_detail) and the casters too
// small for a texel of it (shadow_map_unseen). A still view does none of
// this: while the view, its lights and the casters stay, it keeps the marks and
// the table of the frames before, and the pages are given again only where a
// point asks for one not drawn (shadow_pages.comp).
SHADOW_POOL :: abi.SHADOW_POOL
SHADOW_SLOTS :: abi.SHADOW_SLOTS
SHADOW_MAP_ROWS :: abi.SHADOW_MAP_ROWS
SHADOW_GROUP :: u32(256) // the threads of a group of shadow_maps.comp
SHADOW_PAGE :: abi.SHADOW_PAGE
SHADOW_MAP_PAGES :: abi.SHADOW_MAP_PAGES
SHADOW_MAP_SIDE :: abi.SHADOW_MAP_SIDE
SHADOW_MIPS :: abi.SHADOW_MIPS
SHADOW_LIGHT_FACES :: abi.SHADOW_LIGHT_FACES
SHADOW_SPOT_FACE :: abi.SHADOW_SPOT_FACE
// The cosine of the half angle of the widest spot that takes one map along
// its cone instead of the faces of the cube around it.
SHADOW_SPOT_COS_MIN :: f32(0.5)
SHADOW_RASTER_SHARE :: f32(0.02)
SHADOW_RASTER_KEEP :: f32(0.01)
SHADOW_RASTER_LIGHTS :: abi.SHADOW_RASTER_LIGHTS // the most lights rasterized in a frame, those that light most of the view
// The half width of the first level of the sun, metres: each level after it
// is twice as wide, a texel of its map as many times wider, and a point takes
// the one whose texel is about two of its pixels (sun_pick of shadow_maps.slang),
// the first serving what lies nearest the eye.
SHADOW_SUN_FIRST :: f32(1)
SHADOW_SUN_LEVELS :: abi.SHADOW_SUN_MAPS
SHADOW_MAP_ORTHOGRAPHIC :: abi.SHADOW_MAP_ORTHOGRAPHIC
// The frames after its last change an instance whose shadow changed twice
// within them keeps moving (shadow_movers_update).
SHADOW_MOVER_FRAMES :: u64(30)
// Metres: the side of the cells of the world the maps take the eye from to
// leave out the instances of a batch past its cull distance, as the view
// does; while the eye stays in its cell, no instance comes or goes.
SHADOW_CULL_STEP :: f32(8)
// The units of raster work (abi.SHADOW_UNIT_TEXELS) the draws of the cache
// of a view take in a frame, and those of its atlas, at least: what the least
// GPU the engine runs on draws, masked, in a few milliseconds, a unit taking
// at most some 1.3 ns on an RTX 3070 in the fixtures that cost the most for
// their units, four times that on a GTX 1070. What
// a cluster costs is known before it is drawn, whatever it is, so a frame of
// dense masked foliage draws no more than one of walls. While the picture
// lacks pages the bound grows (shadow_bound_update), up to
// SHADOW_FRAME_UNITS_MOST, while the rounds take less than their share of
// the frame and SHADOW_MAPS_MOST_MS. The pages past it wait for the frames
// after, the coarsest first, and their points read a coarser page drawn or
// trace until then.
SHADOW_FRAME_UNITS :: u32(1 << 20)
SHADOW_FRAME_UNITS_MOST :: abi.SHADOW_COST_UNITS / 2
// The most GPU time the rounds of the maps of a frame take, milliseconds:
// past it the bound shrinks at once by as much as they passed it, so that no
// frame comes near the time a driver gives a submission before it resets the
// device.
SHADOW_MAPS_MOST_MS :: f32(4)
// The most chunks the pass by instance of a round hands to its pass by
// cluster (Cull_List.Shadow_Chunks): a round hands a chunk for each
// SHADOW_CHUNK_UNITS units of the bound at most (shadow_chunk_room), as the
// group of CULL_CHUNK threads that culls a chunk, of which a few clusters,
// takes about what the draws of that many units take; the grant fits the
// chunks its pages are foreseen to hand over in it (shadow_pages.comp); where
// they find no room, the pages of the round wait (shadow_maps.comp), and no
// frame culls more clusters of the maps than these hold.
SHADOW_CHUNKS_MOST :: u32(1 << 20)
SHADOW_CHUNK_UNITS :: u32(16)
// The most clusters the draws of a round take in a frame, once for each page
// they draw into (Cull_List.Shadow_Entries); past them their pages wait.
SHADOW_ENTRIES_MOST :: u32(1 << 21)
// What the rounds of the maps take while their pages wait, of the GPU time of
// the rest of the frame, a refresh of the display at least: a part, so that
// the frame slows by that part at most.
SHADOW_MAPS_SHARE :: f32(0.25)
// How much the bound changes from that of a frame measured, at most.
SHADOW_BOUND_STEP :: f32(1.5)
// The interval the maps of each view measure (rhi.cmd_measure_begin): their
// rounds, what the bound draws, after the steps of the pages, which cost the
// same whatever it is (SHADOW_PAGES_TIMING); in a frame that wants timings,
// the intervals of each of their steps, named alike.
SHADOW_MAPS_TIMING :: "shadow maps"
SHADOW_PAGES_TIMING :: "shadow pages"

// The units each round of the maps of every view draws in a frame: now, and
// in each frame in flight, which the GPU time of that frame measures once it
// comes back; least and most: 0, SHADOW_FRAME_UNITS and
// SHADOW_FRAME_UNITS_MOST.
Shadow_Bound :: struct {
	now:         u32,
	frames:      [rhi.MAX_FRAMES_IN_FLIGHT]u32,
	least, most: u32,
}

// The bound of this frame, from the frame that last used its slot, which has
// come back: the rounds of the maps take time in proportion to the units
// they draw, so it follows the GPU time the rounds of that frame took
// against their share of the rest of that frame, at most
// SHADOW_MAPS_MOST_MS, by SHADOW_BOUND_STEP at most each way, at once down
// to what keeps them within SHADOW_MAPS_MOST_MS, and within its least and
// most: growing while the picture lacks pages, points
// read where no page drawn holds them or a still view waits for pages
// (Shadow_Stats.pages_short), and shrinking when they took more; pages whose
// points read a coarser page drawn refine at the least. Without the time of
// the rounds (a device without timestamps), the frame against a refresh. The
// lists of the cull of the maps grow to hold it, a cluster taking two units
// at least in a page: one of its texels and one of its vertices.
@(private)
shadow_bound_update :: proc(r: ^Renderer, slot: int, refresh_hz: f32) {
	b := &r.shadow_bound
	least := b.least if b.least != 0 else SHADOW_FRAME_UNITS
	most := max(b.most if b.most != 0 else SHADOW_FRAME_UNITS_MOST, least)
	bound := clamp(b.now, least, most)
	then := clamp(b.frames[slot], least, most)
	timings, _, measured := rhi.frame_timings(r.device)
	maps, timed := f32(0), false
	for t in timings {
		if !strings.has_prefix(t.name, "shadow ") || t.name == SHADOW_PAGES_TIMING {continue}
		maps += t.ms
		timed = true
	}
	period := 1000 / (refresh_hz if refresh_hz > 0 else 60)
	frame := r.stats.gpu_ms
	if measured && frame > 0 {
		share := min(max(frame - maps, period) * SHADOW_MAPS_SHARE, SHADOW_MAPS_MOST_MS)
		ratio := clamp(share / max(maps, 1e-3) if timed else period / frame, 1 / SHADOW_BOUND_STEP, SHADOW_BOUND_STEP)
		bound = u32(clamp(f32(then) * ratio, f32(least), f32(most))) if ratio < 1 || r.stats.shadow.pages_short > 0 else least
		if timed && maps > SHADOW_MAPS_MOST_MS {bound = min(bound, u32(max(f32(then) * SHADOW_MAPS_MOST_MS / maps, 1)))}
	}
	b.now, b.frames[slot] = bound, bound
	r.scene.cull_wanted[.Shadow_Entries] = max(r.scene.cull_wanted[.Shadow_Entries], min(bound / 2, SHADOW_ENTRIES_MOST))
	r.scene.cull_wanted[.Shadow_Chunks] = max(r.scene.cull_wanted[.Shadow_Chunks], min(bound / SHADOW_CHUNK_UNITS, SHADOW_CHUNKS_MOST))
}

Gpu_Shadow_Map :: struct {
	origin:  Vec3,
	near:    f32,
	right:   Vec3,
	far:     f32,
	up:      Vec3,
	kind:    u32,
	forward: Vec3,
	skip:    f32, // nearer than this along it lies the body of the light, metres
	span:    Vec4,
	// Its slot; the column and the row of the table its first page lies at
	// (the scroll of a level of the sun, which keeps its pages where they are
	// in the world), a byte each, and the mip it is read at << 16; its side at
	// that mip, texels (0: no map); its light (max(u32): the sun).
	rect:    [4]u32,
}
#assert(size_of(Gpu_Shadow_Map) == SHADOW_MAP_ROWS * 16)

// What the direct light reads of the maps of the frame.
Shadow_Maps :: struct {
	on:   u32, // 1 while there are maps
	rows: u32, // of the words of the lights in the buffer of the maps
	maps: u32, // the slots
	sun:  u32, // the levels of the sun << 16 from slot 0; max(u32): none
}

// The buffers the maps of a view are drawn from, which each view writes before
// it reads them: the state of the cull of their clusters and of the round of
// the raster that draws them, and the words of the lights and the slots. The
// lists of that cull are the scene's (Cull_List.Shadow_Chunks,
// Shadow_Entries), and those of the raster the view's (Raster_Vertices,
// Raster_Triangles), which grow as those of the view do.
Shadow_Buffers :: struct {
	state: rhi.Buffer, // Gpu_Cull_State
	table: rhi.Buffer, // data copied for the passes to read
}

// What the maps of a view keep: the light of each block of slots (the margin
// between SHADOW_RASTER_KEEP and SHADOW_RASTER_SHARE keeps a light from going
// back and forth), the map each slot held, the cache of what stays and the
// atlas of what is read, a page of the pool each, the table of the pages and
// the buffer of the pages.
Shadow_Raster :: struct {
	raster:   [SHADOW_RASTER_LIGHTS]i32, // the light of each block + 1, 0: none
	data:     rhi.Transient, // of this frame
	cache:    rhi.Texture,   // the depth of what stays, by pages of the pool
	atlas:    rhi.Texture,   // the cache with what moves
	table:    rhi.Texture,   // an entry for each page of each slot (abi.SHADOW_PAGE_*)
	hiz:      rhi.Texture,   // the farthest depth of the cache over blocks of each page of the pool (shadow_hiz.comp)
	pages:    rhi.Buffer,    // abi.SHADOW_WORDS_*
	pool:     u32,           // the pages of the pool it gives, 0: all of them
	budget:   u32,           // the units each of its rounds draws in a frame, 0: those of the renderer (Shadow_Bound)
	held:     [SHADOW_SLOTS]Shadow_Held,
	forget:   bool, // every page is let go of in the next frame
	cut:      f32,  // the threshold of the cut the cache was drawn with
	stale:    Occluder_Changes, // what stays and changed since the maps were last drawn
	moved:    Occluder_Changes, // where what moves was and is since then
	frame:    u32,  // counts the frames the pages were drawn in
	seen:     Shadow_Seen, // what the points marked the pages from
	settle:   u32,  // the frames the points still mark the pages in after the view changed: a cycle of its jitter
	whole:    bool, // a slot drew its pages whole into the atlas alone the frame before: the cache draws them now
	reach:    u32, // what the culls of what stays of its slots go over: its place in Scene_State.shadow_views + 1, 0: none
	cull:     [3]i32, // the cell of the world of the eye its maps leave out the batches past their cull distance from (SHADOW_CULL_STEP)
	culled:   bool,   // its maps were drawn from that cell
}

// What the marks of the points of a view depend on besides the maps and the
// casters: its camera, size and parameters, and the lights.
@(private)
Shadow_Seen :: struct {
	view:   Mat4,
	eye:    Vec3,
	size:   [3]u32,
	params: u64,
	lights: u64,
	pool:   u32,
}

// The map a slot holds, as it was drawn; side 0: none.
@(private)
Shadow_Held :: struct {
	m:    Gpu_Shadow_Map,
	grid: [3]i32, // of a level of the sun: its first page across the light, and its depth in steps of its radius along it
}

// A map the plan wants.
@(private)
Shadow_Want :: struct {
	m:      Gpu_Shadow_Map,
	weight: f32, // how much of the view it serves
	grid:   [3]i32,
}

// How much of the view a light lights: the share of the screen its sphere
// covers, 0 outside the frustum.
@(private)
shadow_light_share :: proc(light: Gpu_Light, eye, forward: Vec3, tan_y, aspect: f32, frustum: [6]Vec4) -> f32 {
	c, range := light.position_range.xyz, light.position_range.w
	for plane in frustum {if linalg.dot(plane.xyz, c) + plane.w < -range {return 0}}
	d := linalg.length(c - eye)
	if d <= range {return 1}
	r := range / math.sqrt(d * d - range * range) / max(tan_y, 1e-4)
	return min(math.PI * r * r / (4 * aspect), 1)
}

@(private)
shadow_face_axes :: proc(face: u32) -> (right, up, forward: Vec3) {
	axis := face >> 1
	sign := f32(-1) if face & 1 != 0 else 1
	forward = {sign if axis == 0 else 0, sign if axis == 1 else 0, sign if axis == 2 else 0}
	reference := Vec3{0, 0, 1} if axis == 1 else Vec3{0, 1, 0}
	right = linalg.normalize(linalg.cross(reference, forward))
	up = linalg.cross(forward, right)
	return
}

@(private)
shadow_face_of :: proc(v: Vec3) -> u32 {
	a := Vec3{abs(v.x), abs(v.y), abs(v.z)}
	if a.x >= a.y && a.x >= a.z {return 0 if v.x >= 0 else 1}
	if a.y >= a.z {return 2 if v.y >= 0 else 3}
	return 4 if v.z >= 0 else 5
}

// The faces of the cube of a light through which it lights what the view
// sees, each whole: the part of the view its sphere covers, at the depths it
// spans within the box of the scene (scene_low, scene_high), where its
// surfaces are. A face fitted to a part of what the view sees through it left
// out points the view sees there, which then traced rays; a light that takes
// maps lights much of the view, which it sees through most of each face.
@(private)
shadow_light_faces :: proc(wants: ^[abi.SHADOW_LIGHT_SLOTS]Shadow_Want, light: Gpu_Light, share: f32, eye, forward, right, up: Vec3, tan_x, tan_y, near: f32, scene_low, scene_high: Vec3, has_bounds: bool) {
	SIDE :: 9
	c, range := light.position_range.xyz, light.position_range.w
	light_near := max(f32(0.05), light.size.x * 1.1)
	radius := linalg.length(light.size.yz) if light.direction_cone.w == GPU_LIGHT_RECT else max(light.size.x, 0.01) + light.size.y
	skip := max(light_near, min(3 * radius, radius + 0.3))
	spot := light.direction_cone.w > -1.5
	rect := light.direction_cone.w == GPU_LIGHT_RECT
	// The part of the screen and the depths the sphere covers.
	to := c - eye
	depth := linalg.dot(to, forward)
	low, high := Vec2{-1, -1}, Vec2{1, 1}
	if linalg.length(to) > range && depth > range {
		center := Vec2{linalg.dot(to, right) / depth / tan_x, linalg.dot(to, up) / depth / tan_y}
		radius := range / math.sqrt(max(linalg.dot(to, to) - range * range, 1e-6))
		low = linalg.max(center - Vec2{radius / tan_x, radius / tan_y} * 1.2, Vec2{-1, -1})
		high = linalg.min(center + Vec2{radius / tan_x, radius / tan_y} * 1.2, Vec2{1, 1})
	}
	z0, z1 := max(depth - range, near), depth + range
	if has_bounds {
		nearest, farthest := max(f32), -max(f32)
		for corner in 0 ..< 8 {
			p := Vec3{scene_high.x if corner & 1 != 0 else scene_low.x, scene_high.y if corner & 2 != 0 else scene_low.y, scene_high.z if corner & 4 != 0 else scene_low.z}
			along := linalg.dot(p - eye, forward)
			nearest, farthest = min(nearest, along), max(farthest, along)
		}
		z0, z1 = max(z0, nearest), min(z1, farthest)
	}
	if z1 <= z0 {return}
	// A spot no wider than a face: one map along its axis that holds the
	// whole cone, with no seam between faces where the cone crosses them.
	if spot && light.direction_cone.w >= SHADOW_SPOT_COS_MIN {
		ff := linalg.normalize(light.direction_cone.xyz)
		reference := Vec3{0, 1, 0} if abs(ff.y) < 0.99 else Vec3{1, 0, 0}
		fr := linalg.normalize(linalg.cross(reference, ff))
		fu := linalg.cross(ff, fr)
		cone := math.acos(clamp(light.direction_cone.w, -1, 1))
		reach := math.tan(min(cone * 1.05 + 0.02, 1.2))
		wants[SHADOW_SPOT_FACE] = {
			m = {origin = c, near = light_near, right = fr, far = range, up = fu, forward = ff, skip = skip, span = {-reach, -reach, reach, reach}},
			weight = share,
		}
		return
	}
	// The faces it lights that part through, and the share of the atlas each
	// takes. From inside it, every way from the light: each face it lights
	// through, alike. From outside it, what it holds lies within what its
	// sides show: points over its sides tell the faces, by how many fall on
	// each.
	weights: [6]f32
	lateral := Vec2{linalg.dot(to, right) / (max(depth, 1e-6) * tan_x), linalg.dot(to, up) / (max(depth, 1e-6) * tan_y)}
	if depth >= z0 && depth <= z1 && lateral.x >= low.x && lateral.x <= high.x && lateral.y >= low.y && lateral.y <= high.y {
		for f in 0 ..< 6 {
			fr, fu, ff := shadow_face_axes(u32(f))
			// A spot or a rectangle lights through a face where one of its
			// corners, the middles of its edges or its middle lies in its cone
			// or before its plane.
			for k in 0 ..< 9 {
				d := linalg.normalize(ff + fr * f32(k % 3 - 1) + fu * f32(k / 3 - 1))
				if spot && linalg.dot(d, light.direction_cone.xyz) < light.direction_cone.w - 0.05 {continue}
				if rect && linalg.dot(d, light.direction_cone.xyz) < 0 {continue}
				weights[f] = 1
				break
			}
		}
	} else {
		// Along the depths, as far apart as the view widens.
		ratio := z1 / z0
		for side in 0 ..< 6 {
			for j in 0 ..< SIDE {
				for i in 0 ..< SIDE {
					a, b := f32(i) / f32(SIDE - 1), f32(j) / f32(SIDE - 1)
					z := z0 * math.pow(ratio, b)
					s: Vec2
					switch side {
					case 0: z, s = z0, {low.x + (high.x - low.x) * a, low.y + (high.y - low.y) * b}
					case 1: z, s = z1, {low.x + (high.x - low.x) * a, low.y + (high.y - low.y) * b}
					case 2: s = {low.x, low.y + (high.y - low.y) * a}
					case 3: s = {high.x, low.y + (high.y - low.y) * a}
					case 4: s = {low.x + (high.x - low.x) * a, low.y}
					case:   s = {low.x + (high.x - low.x) * a, high.y}
					}
					v := eye + forward * z + right * (s.x * tan_x * z) + up * (s.y * tan_y * z) - c
					distance := linalg.length(v)
					if distance > range || distance < 1e-4 {continue}
					if spot && linalg.dot(v / distance, light.direction_cone.xyz) < light.direction_cone.w - 0.05 {continue}
					if rect && linalg.dot(v, light.direction_cone.xyz) < 0 {continue}
					weights[shadow_face_of(v)] += 1
				}
			}
		}
	}
	total := weights[0] + weights[1] + weights[2] + weights[3] + weights[4] + weights[5]
	for weight, f in weights {
		if weight == 0 {continue}
		fr, fu, ff := shadow_face_axes(u32(f))
		wants[f] = {
			m = {origin = c, near = light_near, right = fr, far = range, up = fu, forward = ff, skip = skip, span = {-1, -1, 1, 1}},
			weight = share * weight / total,
		}
	}
}

// The levels of the sun around the eye: level k is a square
// 2 SHADOW_SUN_FIRST 2^k metres wide across the light, whose pages lie on a
// grid of the light: it moves by whole pages, and a page keeps its place in
// the table and the pool while it stays in the square, so walking draws only
// the pages that come in. Along the light it reaches from the scene towards
// the sun to two radii past its own point, which goes by steps of the radius
// and stays while the eye does not leave its reach; towards the sun it keeps
// how far it reaches while the scene stays within that, so that the scene
// rising a little or shrinking draws nothing again. As many levels as reach
// as far as the scene from the eye, and the camera. The grid of the pages and
// the texels of every level lies on the world, not on the origin the frame
// draws from (origin): a scene shows the same shadows wherever it lies.
@(private)
shadow_sun_levels :: proc(wants: ^[SHADOW_SLOTS]Shadow_Want, toward: Vec3, eye, origin: Vec3, camera_far: f32, scene_low, scene_high: Vec3, has_bounds: bool, held: []Shadow_Held) -> (levels: int) {
	axis := -linalg.normalize(toward)
	reference := Vec3{0, 1, 0} if abs(axis.y) < 0.99 else Vec3{1, 0, 0}
	sr := linalg.normalize(linalg.cross(reference, axis))
	su := linalg.cross(axis, sr)
	// Where the origin lies on the axes of the light, past a whole number of the
	// pages of the widest level: the pages of each level, which divide it, lie
	// on the world from it.
	WIDEST :: f64(SHADOW_SUN_FIRST) * f64(u32(1) << (SHADOW_SUN_LEVELS - 1)) / f64(SHADOW_MAP_PAGES / 2)
	phase :: proc(origin, along: Vec3) -> f32 {
		at := f64(origin.x) * f64(along.x) + f64(origin.y) * f64(along.y) + f64(origin.z) * f64(along.z)
		return f32(at - math.floor(at / WIDEST) * WIDEST)
	}
	shift := Vec3{phase(origin, sr), phase(origin, su), phase(origin, axis)}
	// The eye on the axes of the light from that grid.
	place := Vec3{linalg.dot(eye, sr), linalg.dot(eye, su), linalg.dot(eye, axis)} + shift
	extent := f32(math.F32_MAX)
	if has_bounds {
		extent = 0
		for i in 0 ..< 8 {
			corner := Vec3{scene_high.x if i & 1 != 0 else scene_low.x, scene_high.y if i & 2 != 0 else scene_low.y, scene_high.z if i & 4 != 0 else scene_low.z}
			extent = max(extent, linalg.length(corner - eye))
		}
	}
	if camera_far > 0 {extent = min(extent, camera_far)}
	HALF :: SHADOW_MAP_PAGES / 2
	// From its own point along the light, its radius, a radius before it to two
	// after it (CASCADE_FAR radii), and its casters from the scene towards the sun.
	CASCADE_FAR :: 4
	for k in 0 ..< SHADOW_SUN_LEVELS {
		radius := SHADOW_SUN_FIRST * f32(u32(1) << u32(k))
		page := radius / HALF
		at := place.z
		grid := [3]i32{i32(math.floor(place.x / page)), i32(math.floor(place.y / page)), i32(math.floor(at / radius))}
		h := held[k]
		if h.m.rect.z != 0 && h.m.far == CASCADE_FAR * radius && at >= f32(h.grid.z - 1) * radius && at <= f32(h.grid.z + 2) * radius {grid.z = h.grid.z}
		along := f32(grid.z) * radius
		lo, top := -3 * radius, -3 * radius
		if has_bounds {
			for i in 0 ..< 8 {
				p := Vec3{scene_high.x if i & 1 != 0 else scene_low.x, scene_high.y if i & 2 != 0 else scene_low.y, scene_high.z if i & 4 != 0 else scene_low.z}
				top = min(top, linalg.dot(p, axis) + shift.z - along)
				lo = min(lo, math.floor((linalg.dot(p, axis) + shift.z - 1 - along) / radius) * radius)
			}
		}
		if h.m.rect.z != 0 && grid.z == h.grid.z && h.m.near <= top {lo = h.m.near}
		x0, y0 := grid.x - HALF, grid.y - HALF
		// The column and row of the table of the first page: its place on the grid, rows down.
		ox, oy := u32(x0) % SHADOW_MAP_PAGES, u32(-(grid.y + HALF)) % SHADOW_MAP_PAGES
		wants[k] = {
			m = {
				origin = axis * (along - shift.z) - sr * shift.x - su * shift.y, right = sr, up = su, forward = axis, near = lo, far = CASCADE_FAR * radius, skip = lo, kind = SHADOW_MAP_ORTHOGRAPHIC,
				span = {f32(x0) * page, f32(y0) * page, f32(x0 + SHADOW_MAP_PAGES) * page, f32(y0 + SHADOW_MAP_PAGES) * page},
				rect = {u32(k), ox | oy << 8, SHADOW_MAP_SIDE, max(u32)},
			},
			weight = 1, grid = grid,
		}
		levels = k + 1
		if radius >= extent {break}
	}
	return
}

// Whether a box of the world reaches into the frustum of a map, as
// shadow_map_reaches of shadow_maps.slang.
@(private)
shadow_map_reaches :: proc "contextless" (m: Gpu_Shadow_Map, low, high: Vec3) -> bool {
	center := 0.5 * (low + high) - m.origin
	half := 0.5 * (high - low)
	c := Vec3{linalg.dot(center, m.right), linalg.dot(center, m.up), linalg.dot(center, m.forward)}
	e := Vec3{linalg.dot(half, linalg.abs(m.right)), linalg.dot(half, linalg.abs(m.up)), linalg.dot(half, linalg.abs(m.forward))}
	lo, hi := c - e, c + e
	if hi.z < m.near || lo.z > m.far {return false}
	if m.kind == SHADOW_MAP_ORTHOGRAPHIC {return hi.x >= m.span.x && lo.x <= m.span.z && hi.y >= m.span.y && lo.y <= m.span.w}
	side :: proc "contextless" (lo, hi, n: Vec3) -> bool {
		return linalg.dot(n, Vec3{hi.x if n.x >= 0 else lo.x, hi.y if n.y >= 0 else lo.y, hi.z if n.z >= 0 else lo.z}) >= 0
	}
	return side(lo, hi, {1, 0, -m.span.x}) && side(lo, hi, {-1, 0, m.span.z}) && side(lo, hi, {0, 1, -m.span.y}) && side(lo, hi, {0, -1, m.span.w})
}

// Of a batch that casts shadows with a deformable: how far its instances
// sway, metres of the world (the texel of a map below which it moves there);
// 0 for any other batch.
@(private)
batch_sway :: proc(s: ^Scene_State, record: ^Batch_Record) -> (fine: f32) {
	if .Casts_Shadow not_in record.desc.flags || int(record.desc.mesh) >= len(s.meshes) {return}
	skin := s.meshes[record.desc.mesh].skin
	if skin == nil || !skin.external {return}
	fine = skin.sway * record.scale if skin.sway > 0 else max(f32)
	return max(fine, 1e-6)
}

// The narrowest texel of a map over a box of the world, metres: where the box
// comes nearest the light of a perspective one.
@(private)
shadow_map_finest :: proc "contextless" (m: Gpu_Shadow_Map, low, high: Vec3) -> f32 {
	across := (m.span.z - m.span.x) / f32(max(m.rect.z, 1))
	if m.kind == SHADOW_MAP_ORTHOGRAPHIC {return across}
	center := 0.5 * (low + high) - m.origin
	half := 0.5 * (high - low)
	nearest := linalg.dot(center, m.forward) - linalg.dot(half, linalg.abs(m.forward))
	return across * max(nearest, m.near)
}

// Whether a change reaches a map: its box reaches the frustum, and the map is
// one it changes (Occluder_Change.fine).
@(private)
shadow_change_reaches :: proc "contextless" (m: Gpu_Shadow_Map, box: Occluder_Change) -> bool {
	return shadow_map_reaches(m, box.low, box.high) && (box.fine == 0 || shadow_map_finest(m, box.low, box.high) < box.fine)
}

// What changed for the shadows this frame (Renderer.frame_occluders), given
// to the cache of every view as what it draws again: an instance that changes
// for the first time in a while changes what stays where it was and is; one
// that changes again moves, and leaves what stays once; one that stopped
// moving for SHADOW_MOVER_FRAMES joins it again where it is; and the meshes
// whose pages changed. Once a frame that draws the scene, after its pages.
@(private)
shadow_movers_update :: proc(r: ^Renderer) {
	s := &r.scene
	now := r.frame + 1 // a frame of a track is never 0
	stale := s.shadow_stale
	s.shadow_stale = {}
	moved: Occluder_Changes
	// A masked row that changed what it covers: the casters that use it, where they are.
	if s.shadow_row_count > 0 && !stale.covers {
		rows := s.shadow_rows[:s.shadow_row_count]
		for inst, index in s.instances {
			if !instance_casts(inst) || int(inst.meta.x & INSTANCE_MESH_MASK) >= len(s.meshes) {continue}
			mesh := s.meshes[inst.meta.x & INSTANCE_MESH_MASK]
			palette := inst.slot_materials
			for packed in s.indices[mesh.slot_word:][:mesh.slot_count] {
				row := instance_row(packed, inst.meta.y, &palette)
				found := false
				for changed in rows {found ||= changed == row}
				if !found {continue}
				occluder_add(&stale, u32(index), inst.bounds_min.xyz, inst.bounds_max.xyz)
				break
			}
		}
		// The batches that cast, wherever they are drawn.
		for index, k in s.batch.drawn {
			if .Casts_Shadow not_in s.batch.records[index].desc.flags {continue}
			box := s.batch.boxes[k]
			occluder_add(&stale, OCCLUDERS_MANY, box.min, box.max)
		}
	}
	s.shadow_row_count = 0
	if len(s.shadow_tracks) > len(s.instances) {base.truncate(&s.shadow_tracks, len(s.instances))}
	for change in s.shadow_changes {
		if int(change.instance) >= len(s.shadow_tracks) {
			occluder_add(&stale, OCCLUDERS_MANY, change.low, change.high)
			continue
		}
		track := &s.shadow_tracks[change.instance]
		track.change = 0
		if track.frame != 0 {
			track.frame = now
			if track.moving {
				occluder_add(&moved, change.instance, change.low, change.high)
				continue
			}
			track.moving = true
		} else {
			track.frame = now
			append(&s.shadow_followed, change.instance)
		}
		occluder_add(&stale, change.instance, change.low, change.high)
	}
	clear(&s.shadow_changes)
	for k := 0; k < len(s.shadow_followed); {
		index := s.shadow_followed[k]
		if int(index) < len(s.shadow_tracks) && now - s.shadow_tracks[index].frame < SHADOW_MOVER_FRAMES {k += 1;continue}
		if int(index) < len(s.shadow_tracks) {
			track := &s.shadow_tracks[index]
			inst := s.instances[index]
			if track.moving && instance_casts(inst) {occluder_add(&stale, index, inst.bounds_min.xyz, inst.bounds_max.xyz)}
			track^ = {}
		}
		unordered_remove(&s.shadow_followed, k)
	}
	// A deformable whose vertices change (the wind) changes the batches of it
	// that cast as an instance does, in the maps whose texel is narrower than
	// how far it sways alone: the others draw it at rest and keep it. It is
	// followed as a whole, so a frame where every batch sways looks at the
	// deformables alone: the batches change where one starts or stops, or the
	// tables were built again (Scene_State.shadow_movers_version). What
	// stays changes where the batches of one that starts or stops lie, all
	// of them in one box, so that a wind that starts everywhere takes few.
	touched := false
	for handle in s.skinned {
		skin := s.meshes[handle].skin
		if skin == nil || !skin.external {continue}
		skin.shadow_touched = false
		skin.shadow_low, skin.shadow_high, skin.shadow_fine = Vec3(max(f32)), Vec3(-max(f32)), 0
		if skin.dirty {
			if skin.shadow_frame == 0 || !skin.shadow_moving {skin.shadow_touched = true}
			skin.shadow_moving = skin.shadow_frame != 0
			skin.shadow_frame = now
		} else if skin.shadow_frame != 0 && now - skin.shadow_frame >= SHADOW_MOVER_FRAMES {
			skin.shadow_touched = skin.shadow_moving
			skin.shadow_frame, skin.shadow_moving = 0, false
		}
		touched ||= skin.shadow_touched
	}
	b := &s.batch
	if touched || s.shadow_sway_tables != b.tables {
		for index, k in b.drawn {
			record := &b.records[index]
			fine := batch_sway(s, record)
			skin := s.meshes[record.desc.mesh].skin if fine != 0 else nil
			moving := skin != nil && skin.shadow_moving
			if skin != nil && skin.shadow_touched {
				skin.shadow_low, skin.shadow_high = linalg.min(skin.shadow_low, b.boxes[k].min), linalg.max(skin.shadow_high, b.boxes[k].max)
				skin.shadow_fine = max(skin.shadow_fine, fine)
			}
			if moving != record.shadow_moving {s.shadow_movers_version += 1}
			record.shadow_moving = moving
		}
		for handle in s.skinned {
			skin := s.meshes[handle].skin
			if skin != nil && skin.shadow_touched {occluder_add(&stale, OCCLUDERS_MANY, skin.shadow_low, skin.shadow_high, skin.shadow_fine)}
		}
		s.shadow_sway_tables = b.tables
	}
	if stale.count == 0 && !stale.covers && moved.count == 0 {return}
	give :: proc "contextless" (to: ^Shadow_Raster, stale, moved: ^Occluder_Changes) {
		to.stale.covers ||= stale.covers
		for box in stale.boxes[:stale.count] {occluder_add(&to.stale, box.instance, box.low, box.high, box.fine)}
		for box in moved.boxes[:moved.count] {occluder_add(&to.moved, box.instance, box.low, box.high, box.fine)}
	}
	give(&r.main.targets.shadow_raster, &stale, &moved)
	for &view in r.views {give(&view.targets.shadow_raster, &stale, &moved)}
	for &view in r.texture_views {if view.texture != 0 {give(&view.targets.shadow_raster, &stale, &moved)}}
}

// The maps of this frame and what a frame draws of them.
@(private)
Shadow_Plan :: struct {
	using shadow:   Shadow_Maps,
	plan:           u32, // the word of the buffer of the maps the plans of the slots start at (Shadow_Slot_Plan)
	boxes:          u32, // and the boxes of what changed (Shadow_Box)
	box_count:      u32,
	slots:          u32, // and the slots in use, those with a map or that let go of their pages, a word each
	slot_count:     u32,
	reach:          u32, // and what the culls by instance of each slot go over (Shadow_Reach)
	ranges:         u32, // and their ranges of instances
	movers:         u32, // words of the bits of what moves
	moving_threads: u32, // the movers that reach a map
	whole:          bool, // a slot lets go of every page: the round of what moves draws what stays too there
	changed:        bool, // a level of the sun moved, or what stays changed everywhere in a slot
	bits:           rhi.Transient,
	cull:           Vec4, // the eye the batches past their cull distance are left out from (shadow_cull_eye)
}

// The cell of SHADOW_CULL_STEP of the world that holds an eye relative to the origin.
@(private)
shadow_cull_cell :: proc "contextless" (eye, origin: Vec3) -> (cell: [3]i32) {
	for axis in 0 ..< 3 {cell[axis] = i32(clamp(math.floor((f64(eye[axis]) + f64(origin[axis])) / f64(SHADOW_CULL_STEP)), -2e9, 2e9))}
	return
}

// The middle of a cell relative to the origin, and how much farther than its
// cull distance an instance of a batch lies from it before the maps leave it
// out: half the diagonal of the cell, so that what the view draws from any
// eye within the cell casts.
@(private)
shadow_cull_eye :: proc "contextless" (cell: [3]i32, origin: Vec3) -> (eye: Vec4) {
	for axis in 0 ..< 3 {eye[axis] = f32((f64(cell[axis]) + 0.5) * f64(SHADOW_CULL_STEP) - f64(origin[axis]))}
	eye.w = 0.5 * SHADOW_CULL_STEP * math.SQRT_THREE
	return
}

// Whether the maps leave out every instance within a box of a batch whose
// cull distance is `cull` (0: never) from that eye (shadow_cull_eye).
@(private)
shadow_culled :: proc "contextless" (low, high: Vec3, cull: f32, eye: Vec4) -> bool {
	return cull > 0 && linalg.length(eye.xyz - linalg.clamp(eye.xyz, low, high)) > cull + eye.w
}

// What stays changed where the eye the maps cull from moved from `was` to
// `now`: of each batch drawn that casts with a cull distance, one whose
// instances may lie within it from one eye and past it from the other, the
// part of its box within reach of either.
@(private)
shadow_cull_changes :: proc(s: ^Scene_State, stale: ^Occluder_Changes, was, now: Vec4) {
	farthest :: proc "contextless" (eye, low, high: Vec3) -> f32 {return linalg.length(linalg.max(linalg.abs(eye - low), linalg.abs(eye - high)))}
	for index, k in s.batch.drawn {
		cull := s.batch.records[index].desc.cull_distance
		low, high, casts := shadow_batch_box(s, k)
		if !casts || cull <= 0 {continue}
		reach := cull + now.w
		if farthest(was.xyz, low, high) <= reach && farthest(now.xyz, low, high) <= reach {continue}
		if shadow_culled(low, high, cull, was) && shadow_culled(low, high, cull, now) {continue}
		low = linalg.max(low, linalg.min(was.xyz, now.xyz) - reach)
		high = linalg.min(high, linalg.max(was.xyz, now.xyz) + reach)
		occluder_add(stale, OCCLUDERS_MANY, low, high)
	}
}

// What the plan tells the pages of a slot this frame (shadow_pages.comp):
// abi.SHADOW_PLAN_*; of a level of the sun, by how many pages it moved since
// the frame before, the columns and rows that came in letting go of what they
// held; and the pages of its safety net, the 2x2 nearest the eye, their first
// and last column and row a byte each.
@(private)
Shadow_Slot_Plan :: struct {
	flags: u32,
	shift: [2]i32,
	net:   u32,
}

// A box of what changed for the maps (Occluder_Change), as the pages read it:
// fine, then whether what moves changed there rather than what stays.
@(private)
Shadow_Box :: struct {
	low:   Vec3,
	fine:  f32,
	high:  Vec3,
	moved: u32,
}

// The maps of this frame: which lights, their faces and the levels of the
// sun, each in its slot; what of the pages each held the frame before it
// lets go of, and where what stays and what moves changed in them; written
// to a buffer of this frame. fresh: the cache holds nothing it can keep.
@(private)
shadow_maps_plan :: proc(p: ^Pass, fresh: bool) -> (plan: Shadow_Plan, ok: bool) {
	r, t := p.r, p.t
	s := &r.scene
	b := &t.shadow_raster
	plan.sun = max(u32)
	camera := p.camera
	eye := p.frame.camera_position.xyz
	forward := linalg.normalize(camera.forward)
	right := linalg.normalize(linalg.cross(forward, camera.up))
	up := linalg.cross(right, forward)
	aspect := f32(t.width) / f32(max(t.height, 1))
	orthographic := camera.projection == .Orthographic
	tan_y := math.tan(math.to_radians(camera.fov_y) * 0.5) if !orthographic else 0.5 * camera.height
	tan_x := tan_y * aspect
	near := max(camera.near, 0.001)
	forget := fresh || b.forget
	b.forget = false
	if forget {b.held = {}}
	wants: [SHADOW_SLOTS]Shadow_Want
	sun := s.sun
	levels := 0
	if sun.enabled && r.settings.sun_shadows && !sun.shadowless && !orthographic {
		levels = shadow_sun_levels(&wants, sun.direction, eye, r.origin, camera.far, s.bounds_min, s.bounds_max, s.has_bounds, b.held[:SHADOW_SUN_LEVELS])
		plan.sun = u32(levels) << 16
	}
	// The lights that light most of the view, the most first; a light keeps
	// its block of slots while it is chosen, and the others take free ones.
	chosen: [SHADOW_RASTER_LIGHTS]int
	shares: [SHADOW_RASTER_LIGHTS]f32
	picked := 0
	was :: proc(b: ^Shadow_Raster, light: int) -> bool {
		for k in b.raster {if int(k) - 1 == light {return true}}
		return false
	}
	for light, i in s.lights {
		if orthographic {break}
		// A light turned off, with no place or without shadows casts none.
		if s.light_shadowless[i] || !light_placed(light) || !(light.color_intensity.w > 0) || !(max(light.color_intensity.x, light.color_intensity.y, light.color_intensity.z) > 0) {continue}
		share := shadow_light_share(light, eye, forward, tan_y, aspect, p.frame.frustum)
		keep := SHADOW_RASTER_KEEP if was(b, i) else SHADOW_RASTER_SHARE
		if share < keep {continue}
		at := picked
		for at > 0 && shares[at - 1] < share {at -= 1}
		if at >= SHADOW_RASTER_LIGHTS {continue}
		for k := min(picked, SHADOW_RASTER_LIGHTS - 1); k > at; k -= 1 {chosen[k], shares[k] = chosen[k - 1], shares[k - 1]}
		chosen[at], shares[at] = i, share
		picked = min(picked + 1, SHADOW_RASTER_LIGHTS)
	}
	blocks: [SHADOW_RASTER_LIGHTS]i32
	for k in 0 ..< picked {
		for light, j in b.raster {if int(light) - 1 == chosen[k] {blocks[j] = light}}
	}
	for k in 0 ..< picked {
		taken := false
		for light in blocks {if int(light) - 1 == chosen[k] {taken = true}}
		for j in 0 ..< SHADOW_RASTER_LIGHTS {
			if taken {break}
			if blocks[j] == 0 {blocks[j], taken = i32(chosen[k]) + 1, true}
		}
	}
	b.raster = blocks
	// The faces of each light, whole at their finest mip: each point reads
	// the mip whose texel is about two of its pixels (light_pick).
	for held_light, block in b.raster {
		if held_light == 0 {continue}
		light := int(held_light) - 1
		faces: [abi.SHADOW_LIGHT_SLOTS]Shadow_Want
		share := f32(0)
		for k in 0 ..< picked {if chosen[k] == light {share = shares[k]}}
		shadow_light_faces(&faces, s.lights[light], share, eye, forward, right, up, tan_x, tan_y, near, s.bounds_min, s.bounds_max, s.has_bounds)
		for &w, face in faces {
			if w.weight <= 0 {continue}
			slot := SHADOW_SUN_LEVELS + block * abi.SHADOW_LIGHT_SLOTS + face
			w.m.rect = {u32(slot), 0, SHADOW_MAP_SIDE, u32(light)}
			wants[slot] = w
		}
	}
	// What each slot lets go of and the pages of the safety net of each; where
	// what stays and what moves changed, the boxes do (shadow_pages.comp).
	plans: [SHADOW_SLOTS]Shadow_Slot_Plan
	for &w, slot in wants {
		h := &b.held[slot]
		sp := &plans[slot]
		// Forgotten, every page lets go of what it held.
		if forget {sp.flags |= abi.SHADOW_PLAN_RESET}
		if w.m.rect.z == 0 {
			if h.m.rect.z != 0 {sp.flags |= abi.SHADOW_PLAN_RESET}
			h^ = {}
			continue
		}
		kept := h.m.rect.z != 0
		if kept && slot < SHADOW_SUN_LEVELS {
			// A level that moved by whole pages keeps those that stay in it.
			was, now := h.m, w.m
			was.span, now.span, was.rect.y, now.rect.y = {}, {}, 0, 0
			sp.shift = {w.grid.x - h.grid.x, w.grid.y - h.grid.y}
			kept = was == now && w.grid.z == h.grid.z && abs(sp.shift.x) < SHADOW_MAP_PAGES && abs(sp.shift.y) < SHADOW_MAP_PAGES
		} else if kept {
			kept = h.m == w.m
		}
		// A map new or changed whole (a light that turned or moved) draws its
		// pages whole into the atlas alone this frame, and the cache the next.
		if !kept {sp.flags |= abi.SHADOW_PLAN_RESET}
		if sp.flags & abi.SHADOW_PLAN_RESET != 0 {plan.whole = true}
		if b.stale.covers {sp.flags |= abi.SHADOW_PLAN_STALE}
		if b.stale.covers || sp.shift != {} {plan.changed = true}
		sp.flags |= abi.SHADOW_PLAN_NET
		if slot < SHADOW_SUN_LEVELS {
			// The 2x2 pages nearest the point of the eye, in pages of the level.
			page := (w.m.span.z - w.m.span.x) / SHADOW_MAP_PAGES
			at := Vec2{(linalg.dot(eye - w.m.origin, w.m.right) - w.m.span.x) / page, (w.m.span.w - linalg.dot(eye - w.m.origin, w.m.up)) / page} - 0.5
			low := linalg.clamp(linalg.floor(at), 0, SHADOW_MAP_PAGES - 1)
			high := linalg.clamp(linalg.ceil(at), 0, SHADOW_MAP_PAGES - 1)
			sp.net = u32(low.x) | u32(low.y) << 8 | u32(high.x) << 16 | u32(high.y) << 24
		}
		h^ = {m = w.m, grid = w.grid}
	}
	reach: [SHADOW_SLOTS]Shadow_Reach
	stale, moved: Occluder_Changes
	if !shadow_plan_casters(r, b, eye, forget, wants[:], plans[:], &plan, reach[:], &stale, &moved) {return plan, false}
	if plan.movers > 0 {
		bits, data := rhi.frame_alloc_typed(r.device, u32, int(plan.movers))
		if bits == nil {set_error(r, "transient ring exhausted with the bits of %d words", plan.movers); return plan, false}
		copy(bits, s.shadow_mover_bits[:plan.movers])
		plan.bits = data
	}
	// The buffer of this frame: a word for each light of the scene (its first
	// slot + 1, and from bit SHADOW_LIGHT_FACES the faces it has), the map of
	// each slot, the plan of each, the boxes of what changed, the slots in
	// use, and what the culls by instance of each slot go over and their
	// ranges.
	plan.rows = (u32(len(s.lights)) + 3) / 4
	plan.plan = plan.rows * 4 + SHADOW_SLOTS * SHADOW_MAP_ROWS * 4
	plan.boxes = plan.plan + SHADOW_SLOTS * size_of(Shadow_Slot_Plan) / 4
	plan.box_count = u32(stale.count + moved.count)
	plan.slots = plan.boxes + plan.box_count * size_of(Shadow_Box) / 4
	for w, slot in wants {if w.m.rect.z != 0 || plans[slot].flags & abi.SHADOW_PLAN_RESET != 0 {plan.slot_count += 1}}
	plan.reach = plan.slots + plan.slot_count
	plan.ranges = plan.reach + SHADOW_SLOTS * abi.SHADOW_REACH_WORDS
	words, data := rhi.frame_alloc_typed(r.device, u32, int(plan.ranges) + 2 * len(s.shadow_ranges))
	if words == nil {set_error(r, "transient ring exhausted with the shadow maps"); return plan, false}
	for &word in words[:plan.rows * 4] {word = 0}
	any := false
	for w, slot in wants {
		(cast(^Gpu_Shadow_Map)&words[plan.rows * 4 + u32(slot) * SHADOW_MAP_ROWS * 4])^ = w.m
		(cast(^Shadow_Slot_Plan)&words[plan.plan + u32(slot) * size_of(Shadow_Slot_Plan) / 4])^ = plans[slot]
		if w.m.rect.z == 0 {continue}
		any = true
		if slot < SHADOW_SUN_LEVELS {continue}
		light := w.m.rect.w
		block := (u32(slot) - SHADOW_SUN_LEVELS) / abi.SHADOW_LIGHT_SLOTS
		words[light] |= (SHADOW_SUN_LEVELS + block * abi.SHADOW_LIGHT_SLOTS + 1) | 1 << (SHADOW_LIGHT_FACES + (u32(slot) - SHADOW_SUN_LEVELS) % abi.SHADOW_LIGHT_SLOTS)
	}
	boxes := ([^]Shadow_Box)(raw_data(words[plan.boxes:]))[:plan.box_count]
	for box, i in stale.boxes[:stale.count] {boxes[i] = {low = box.low, fine = box.fine, high = box.high}}
	for box, i in moved.boxes[:moved.count] {boxes[stale.count + i] = {low = box.low, fine = box.fine, high = box.high, moved = 1}}
	used := plan.slots
	for w, slot in wants {
		if w.m.rect.z == 0 && plans[slot].flags & abi.SHADOW_PLAN_RESET == 0 {continue}
		words[used] = u32(slot)
		used += 1
	}
	copy(([^]Shadow_Reach)(raw_data(words[plan.reach:]))[:SHADOW_SLOTS], reach[:])
	copy(([^][2]u32)(raw_data(words[plan.ranges:]))[:len(s.shadow_ranges)], s.shadow_ranges[:])
	plan.maps = SHADOW_SLOTS
	plan.on = 1 if any else 0
	b.data = data
	return plan, true
}

// What the plan of a frame finds of the casters, on the CPU alone: the cell
// of the eye the batches with a cull distance are left out from, what stays
// and what moves changed since the maps were last drawn, the bits of what
// moves (Scene_State.shadow_mover_bits, plan.movers words) and what the culls
// by instance of each slot go over (Scene_State.shadow_ranges). False without
// memory.
@(private)
shadow_plan_casters :: proc(r: ^Renderer, b: ^Shadow_Raster, eye: Vec3, forget: bool, wants: []Shadow_Want, plans: []Shadow_Slot_Plan, plan: ^Shadow_Plan, reach: []Shadow_Reach, stale, moved: ^Occluder_Changes) -> bool {
	s := &r.scene
	// The cell of the eye the batches with a cull distance are left out from;
	// where it changed, what stays changed where their instances came or went.
	cell := shadow_cull_cell(eye, r.origin)
	plan.cull = shadow_cull_eye(cell, r.origin)
	if b.culled && !forget && cell != b.cull {shadow_cull_changes(s, &b.stale, shadow_cull_eye(b.cull, r.origin), plan.cull)}
	b.cull, b.culled = cell, true
	stale^, moved^ = b.stale, b.moved
	b.stale, b.moved = {}, {}
	zone := render_zone_begin(r, "shadow reach")
	reached := shadow_reach(r, b, wants, plans, reach)
	base.profile_end(zone)
	if !reached {set_error(r, "out of memory for the instances the culls of the shadow maps go over"); return false}
	// The bits of what moves: the instances, then the batches drawn, after
	// those of the scene (those of the batches found with them,
	// Scene_State.shadow_batch_bits); and the movers that reach a map, which
	// the round of what moves draws.
	scene_count := len(s.instances)
	last := int(s.shadow_movers_last) - 1
	for index in s.shadow_followed {
		if int(index) < len(s.shadow_tracks) && s.shadow_tracks[index].moving {last = max(last, int(index))}
	}
	plan.moving_threads = shadow_view_reach(r, b).mover_threads
	if last < 0 {return true}
	plan.movers = u32(last / 32 + 1)
	if resize(&s.shadow_mover_bits, int(plan.movers)) != nil {set_error(r, "out of memory for the bits of %d instances", last + 1); return false}
	bits := s.shadow_mover_bits[:]
	batch_words := min(len(s.shadow_batch_bits), len(bits))
	copy(bits, s.shadow_batch_bits[:batch_words])
	for &word in bits[batch_words:] {word = 0}
	for &word in bits[:min(scene_count / 32, batch_words)] {word = 0}
	if scene_count % 32 != 0 && scene_count / 32 < batch_words {bits[scene_count / 32] &= ~u32(0) << u32(scene_count % 32)}
	for index in s.shadow_followed {
		if int(index) >= len(s.shadow_tracks) || !s.shadow_tracks[index].moving {continue}
		bits[index / 32] |= 1 << (index % 32)
		inst := s.instances[index]
		if !instance_casts(inst) {continue}
		for w in wants {
			if w.m.rect.z == 0 || !shadow_map_reaches(w.m, inst.bounds_min.xyz, inst.bounds_max.xyz) {continue}
			plan.moving_threads += 1
			break
		}
	}
	return true
}

// What the culls by instance of a slot go over, each a list of ranges of
// instances (Scene_State.shadow_ranges): its first, how many and the threads
// of them in all; the cull of what stays, then of what moves.
@(private)
Shadow_Reach_List :: struct {first, count, threads: u32}
@(private)
Shadow_Reach :: [abi.SHADOW_REACH_LISTS]Shadow_Reach_List
#assert(size_of(Shadow_Reach) == abi.SHADOW_REACH_WORDS * 4)

// The rank of a slot in the culls by instance of a frame: the levels of the
// sun from the coarsest, then the faces of the lights.
@(private)
shadow_slot_rank :: proc "contextless" (slot: int) -> int {return SHADOW_SUN_LEVELS - 1 - slot if slot < SHADOW_SUN_LEVELS else slot}

// The box of a batch drawn, grown by how far its vertex hook moves its
// instances, and whether it casts shadows in the maps.
@(private)
shadow_batch_box :: proc(s: ^Scene_State, k: int) -> (low, high: Vec3, casts: bool) {
	record := &s.batch.records[s.batch.drawn[k]]
	box := s.batch.boxes[k]
	reach := record.desc.reach
	casts = .Casts_Shadow in record.desc.flags && transmute(u32)s.batch.rows[k].world[2].w != 0
	return box.min - reach, box.max + reach, casts
}

// A batch drawn as a change of the maps: its box, and how far it sways.
@(private)
shadow_batch_change :: proc(s: ^Scene_State, k: int) -> Occluder_Change {
	low, high, _ := shadow_batch_box(s, k)
	fine := batch_sway(s, &s.batch.records[s.batch.drawn[k]])
	return {low = low, high = high, instance = OCCLUDERS_MANY, fine = fine}
}

// The instances of a batch drawn: the first, after those of the scene, and how many.
@(private)
shadow_batch_instances :: proc(s: ^Scene_State, k: int) -> (first, count: u32) {
	row := s.batch.rows[k].world[0]
	return u32(len(s.instances)) + transmute(u32)row.z, transmute(u32)row.y
}

// A batch drawn as the culls of the maps find it: its box
// (shadow_batch_box), its instances and whether it casts shadows.
@(private)
Shadow_Caster :: struct {
	low, high:    Vec3,
	first, count: u32,
	key:          f32, // twice the middle of its box along x
	cull:         f32, // its cull distance, 0: none
	casts:        bool,
}

// A batch drawn by the key its caster is sorted by (Shadow_Caster.key).
@(private)
Shadow_Key :: struct {
	key:    f32,
	record: u32, // its batch drawn
}

// The casters of the tables of the batches built last (Scene_State.shadow_casters):
// each batch drawn as a caster, those that cast in a box, by their record
// in the order of the middle of their box along x, and all of them as the
// ranges of a slot that holds them all. The order keeps that of the tables
// before: the batches that stay are sorted again from it, those that came
// alone anew, and both merged. False without memory.
@(private)
shadow_casters_update :: proc(s: ^Scene_State) -> bool {
	batch := &s.batch
	scene_count := u32(len(s.instances))
	if resize(&s.shadow_casters, len(batch.drawn)) != nil || resize(&s.shadow_marks, (len(batch.drawn) + 63) / 64) != nil || resize(&s.shadow_merge, len(batch.drawn)) != nil {return false}
	s.shadow_casters_low, s.shadow_casters_high = Vec3(max(f32)), Vec3(-max(f32))
	s.shadow_casters_half = 0
	s.shadow_casters_cull = false
	for &c, k in s.shadow_casters {
		c.low, c.high, c.casts = shadow_batch_box(s, k)
		c.first, c.count = shadow_batch_instances(s, k)
		c.key = c.low.x + c.high.x
		c.cull = batch.records[batch.drawn[k]].desc.cull_distance
		if !c.casts {continue}
		s.shadow_casters_cull ||= c.cull > 0
		s.shadow_casters_low, s.shadow_casters_high = linalg.min(s.shadow_casters_low, c.low), linalg.max(s.shadow_casters_high, c.high)
		s.shadow_casters_half = max(s.shadow_casters_half, 0.5 * (c.high.x - c.low.x))
	}
	for &word in s.shadow_marks {word = 0}
	// The batches drawn of the records still drawn that cast, in the order
	// they had, each once; then those that came.
	band := &s.shadow_band
	if resize(band, len(s.shadow_order)) != nil {return false}
	kept := 0
	for record in s.shadow_order {
		if int(record) >= len(batch.records) || batch.records[record].drawn < 0 {continue}
		k := batch.records[record].drawn
		if !s.shadow_casters[k].casts || s.shadow_marks[k >> 6] & (1 << (u32(k) & 63)) != 0 {continue}
		s.shadow_marks[k >> 6] |= 1 << (u32(k) & 63)
		band[kept] = u32(k)
		kept += 1
	}
	base.truncate(band, kept)
	for c, k in s.shadow_casters {
		if !c.casts || s.shadow_marks[k >> 6] & (1 << (u32(k) & 63)) != 0 {continue}
		if _, err := append(band, u32(k)); err != nil {return false}
	}
	for &word in s.shadow_marks {word = 0}
	// Those that stayed, nearly in order; those that came; both merged.
	casters := s.shadow_casters[:]
	for i in 1 ..< kept {
		k := band[i]
		j := i
		for ; j > 0 && casters[band[j - 1]].key > casters[k].key; j -= 1 {band[j] = band[j - 1]}
		band[j] = k
	}
	came := band[kept:]
	if resize(&s.shadow_keys, len(came)) != nil {return false}
	for k, i in came {s.shadow_keys[i] = {casters[k].key, k}}
	slice.sort_by(s.shadow_keys[:], proc(a, b: Shadow_Key) -> bool {return a.key < b.key})
	for key, i in s.shadow_keys {came[i] = key.record}
	if kept > 0 && len(came) > 0 {
		merged := s.shadow_merge[:len(band)]
		i, j := 0, kept
		for &out in merged {
			if j >= len(band) || i < kept && casters[band[i]].key <= casters[band[j]].key {
				out = band[i]
				i += 1
			} else {
				out = band[j]
				j += 1
			}
		}
		copy(band[:], merged)
	}
	// Their keys, and their records, which the next tables start from.
	if resize(&s.shadow_band_keys, len(band)) != nil || resize(&s.shadow_order, len(band)) != nil {return false}
	for k, i in band {s.shadow_band_keys[i], s.shadow_order[i] = casters[k].key, batch.drawn[k]}
	// Every caster as the ranges of a slot.
	clear(&s.shadow_all)
	list: Shadow_Reach_List
	end: u32
	if scene_count > 0 && !shadow_range_add(&s.shadow_all, &list, &end, 0, scene_count, scene_count) {return false}
	for c in s.shadow_casters {
		if c.casts && !shadow_range_add(&s.shadow_all, &list, &end, c.first, c.count, scene_count) {return false}
	}
	s.shadow_all_threads = list.threads
	s.shadow_casters_tables = batch.tables
	return true
}

// The boxes of the casters on the axes of the levels of the sun, those of
// a map of a level (Scene_State.shadow_sun_boxes). False without memory.
@(private)
shadow_sun_boxes_update :: proc(s: ^Scene_State, m: Gpu_Shadow_Map) -> bool {
	if resize(&s.shadow_sun_boxes, len(s.shadow_casters)) != nil {return false}
	for c, k in s.shadow_casters {
		center, half := 0.5 * (c.low + c.high), 0.5 * (c.high - c.low)
		middle := Vec3{linalg.dot(center, m.right), linalg.dot(center, m.up), linalg.dot(center, m.forward)}
		e := Vec3{linalg.dot(half, linalg.abs(m.right)), linalg.dot(half, linalg.abs(m.up)), linalg.dot(half, linalg.abs(m.forward))}
		s.shadow_sun_boxes[k] = {middle - e, middle + e}
	}
	s.shadow_sun_tables, s.shadow_sun_axes = s.batch.tables, {m.right, m.up, m.forward}
	return true
}

// The casters that cast whose box may overlap a span of x, by their batch
// drawn: those whose middle lies within it grown by the widest half of
// theirs (Scene_State.shadow_band).
@(private)
shadow_casters_band :: proc(s: ^Scene_State, low, high: f32) -> []u32 {
	keys := s.shadow_band_keys[:]
	from, past := 2 * (low - s.shadow_casters_half), 2 * (high + s.shadow_casters_half)
	at, top := 0, len(keys)
	for at < top {
		middle := (at + top) / 2
		if keys[middle] < from {at = middle + 1} else {top = middle}
	}
	first := at
	top = len(keys)
	for at < top {
		middle := (at + top) / 2
		if keys[middle] <= past {at = middle + 1} else {top = middle}
	}
	return s.shadow_band[first:at]
}

// Whether a box of the world lies whole within a map of a level of the sun;
// false for a perspective one.
@(private)
shadow_map_holds :: proc "contextless" (m: Gpu_Shadow_Map, low, high: Vec3) -> bool {
	if m.kind != SHADOW_MAP_ORTHOGRAPHIC || low.x > high.x {return false}
	center := 0.5 * (low + high) - m.origin
	half := 0.5 * (high - low)
	c := Vec3{linalg.dot(center, m.right), linalg.dot(center, m.up), linalg.dot(center, m.forward)}
	e := Vec3{linalg.dot(half, linalg.abs(m.right)), linalg.dot(half, linalg.abs(m.up)), linalg.dot(half, linalg.abs(m.forward))}
	lo, hi := c - e, c + e
	return lo.z >= m.near && hi.z <= m.far && lo.x >= m.span.x && hi.x <= m.span.z && lo.y >= m.span.y && hi.y <= m.span.w
}

// A batch drawn that moves in the maps: where and how far it sways, its
// instances, and its batch drawn.
@(private)
Shadow_Mover :: struct {
	change:       Occluder_Change,
	first, count: u32,
	caster:       u32,
}

// What the culls by instance of a slot go over, kept while its map and the
// tables of the batches stay: of what stays, its ranges of instances (the
// first instance, and the thread of the list it takes from) and their
// threads, and the casters they hold (all of them, or those listed); of the
// batches that move, kept while the movers stay too, their ranges and
// threads, and which movers they are.
@(private)
Shadow_Reached :: struct {
	m:            Gpu_Shadow_Map, // the map they were found for; rect.z 0: none
	tables:       u64,            // the tables of the batches they were found in (Batch_State.tables)
	cull:         [3]i32,         // the cell of the eye they were found from, where a batch has a cull distance (Shadow_Raster.cull)
	ranges:       [dynamic][2]u32,
	threads:      u32,
	all:          bool,
	casters:      [dynamic]u32,
	movers:       u64, // the movers the moves were found among (Scene_State.shadow_movers_found); 0: not found
	moves:        [dynamic][2]u32,
	move_threads: u32,
	moving:       [dynamic]u32, // of Scene_State.shadow_movers
}

// What the culls of the slots of a view go over, kept, and whether a view
// holds it; of each mover, how many of its slots draw it as what moves, and
// the instances of the movers some slot draws (Shadow_Plan.moving_threads).
@(private)
Shadow_View_Reach :: struct {
	used:          bool,
	slots:         [SHADOW_SLOTS]Shadow_Reached,
	movers:        u64, // the movers counted (Scene_State.shadow_movers_found)
	mover_slots:   [dynamic]u16,
	mover_threads: u32,
}

// Lets go of what the culls of the maps of a view kept, for another view.
@(private)
shadow_reach_release :: proc(r: ^Renderer, b: ^Shadow_Raster) {
	views := &r.scene.shadow_views
	if b.reach != 0 && int(b.reach) <= len(views) {
		view := &views[b.reach - 1]
		for &kept in view.slots {
			clear(&kept.ranges)
			clear(&kept.casters)
			clear(&kept.moves)
			clear(&kept.moving)
			kept.m, kept.tables, kept.cull, kept.threads, kept.all, kept.movers, kept.move_threads = {}, 0, {}, 0, false, 0, 0
		}
		clear(&view.mover_slots)
		view.used, view.movers, view.mover_threads = false, 0, 0
	}
	b.reach = 0
}

// What the culls of the maps of a view keep, taken for it where it has none;
// nil without memory.
@(private)
shadow_view_reach :: proc(r: ^Renderer, b: ^Shadow_Raster) -> ^Shadow_View_Reach {
	s := &r.scene
	if b.reach == 0 || int(b.reach) > len(s.shadow_views) {
		b.reach = 0
		for view, k in s.shadow_views {if !view.used {b.reach = u32(k + 1);break}}
		if b.reach == 0 {
			if _, err := append(&s.shadow_views, Shadow_View_Reach{}); err != nil {return nil}
			b.reach = u32(len(s.shadow_views))
		}
		s.shadow_views[b.reach - 1].used = true
	}
	return &s.shadow_views[b.reach - 1]
}

// The box of the world a map reaches: its frustum, from the light for a
// perspective one.
@(private)
shadow_map_box :: proc "contextless" (m: Gpu_Shadow_Map) -> (low, high: Vec3) {
	orthographic := m.kind == SHADOW_MAP_ORTHOGRAPHIC
	low, high = m.origin, m.origin
	for i in 0 ..< 8 {
		x, y := m.span.z if i & 1 != 0 else m.span.x, m.span.w if i & 2 != 0 else m.span.y
		d := m.far if i & 4 != 0 else m.near
		p := m.origin + m.right * x + m.up * y + m.forward * d if orthographic else m.origin + (m.right * x + m.up * y + m.forward) * d
		low, high = linalg.min(low, p), linalg.max(high, p)
	}
	if orthographic {low, high = linalg.min(low, high), linalg.max(low, high)}
	return
}

// A range of instances added to a list (Shadow_Reach_List) whose ranges go
// to `ranges`: one that starts within the last group of the batch before it
// goes on with that one. end: past the last instance of the list.
@(private)
shadow_range_add :: proc(ranges: ^[dynamic][2]u32, list: ^Shadow_Reach_List, end: ^u32, first, count, scene_count: u32) -> bool {
	if list.count > 0 && (first == end^ || end^ > scene_count && first > end^ && first - end^ < BATCH_GROUP) {
		list.threads += first + count - end^
		end^ = first + count
		return true
	}
	if _, err := append(ranges, [2]u32{first, list.threads}); err != nil {return false}
	list.count += 1
	list.threads += count
	end^ = first + count
	return true
}

// The batches drawn that move in the maps (Scene_State.shadow_movers), their
// bits (Scene_State.shadow_batch_bits) and the widest sway of them, found
// again only where one starts or stops moving or the tables or the instances
// of the scene changed. False without memory.
@(private)
shadow_movers_find :: proc(s: ^Scene_State) -> bool {
	scene_count := u32(len(s.instances))
	key := [3]u64{s.shadow_movers_version, s.batch.tables, u64(scene_count)}
	if key == s.shadow_movers_key && s.shadow_movers_found != 0 {return true}
	clear(&s.shadow_movers)
	clear(&s.shadow_batch_bits)
	if resize(&s.shadow_mover_of, len(s.batch.drawn)) != nil {return false}
	s.shadow_movers_fine, s.shadow_movers_last = 0, 0
	for index, k in s.batch.drawn {
		s.shadow_mover_of[k] = -1
		c := &s.shadow_casters[k]
		if !s.batch.records[index].shadow_moving || !c.casts {continue}
		bit := scene_count + u32(k)
		if resize(&s.shadow_batch_bits, int(bit / 32 + 1)) != nil {return false}
		s.shadow_batch_bits[bit / 32] |= 1 << (bit % 32)
		s.shadow_movers_last = bit + 1
		change := shadow_batch_change(s, k)
		s.shadow_mover_of[k] = i32(len(s.shadow_movers))
		if _, err := append(&s.shadow_movers, Shadow_Mover{change, c.first, c.count, u32(k)}); err != nil {return false}
		s.shadow_movers_fine = max(s.shadow_movers_fine, change.fine if change.fine > 0 else max(f32))
	}
	s.shadow_movers_key = key
	s.shadow_movers_found += 1
	return true
}

// What the culls by instance of each slot with a map go over, into
// Scene_State.shadow_ranges: of what stays, the instances of the scene and
// the batches that cast whose box reaches the map, found again only where the
// map or the tables of the batches changed (Shadow_View_Reach), among the
// casters near its box along x; of what moves, the batches that move and
// change it, found again only where those or the casters it holds changed,
// and the instances that move and reach it, or what stays where the slot lets
// go of every page. A batch whose box misses a map, or lies past its cull
// distance from the cell of the eye (shadow_culled), costs no thread there,
// and a frame whose maps and movers stay looks at no batch. False without
// memory.
@(private)
shadow_reach :: proc(r: ^Renderer, b: ^Shadow_Raster, wants: []Shadow_Want, plans: []Shadow_Slot_Plan, reach: []Shadow_Reach) -> bool {
	s := &r.scene
	batch := &s.batch
	scene_count := u32(len(s.instances))
	clear(&s.shadow_ranges)
	if (s.shadow_casters_tables != batch.tables || !batch.built) && !shadow_casters_update(s) {return false}
	if !shadow_movers_find(s) {return false}
	eye := shadow_cull_eye(b.cull, r.origin)
	key := b.cull if s.shadow_casters_cull else {}
	view := shadow_view_reach(r, b)
	if view == nil {return false}
	// The movers each slot holds are counted anew for movers found anew.
	if view.movers != s.shadow_movers_found {
		if view.mover_slots.allocator.procedure == nil {view.mover_slots = make([dynamic]u16, r.allocator)}
		if resize(&view.mover_slots, len(s.shadow_movers)) != nil {return false}
		for &count in view.mover_slots {count = 0}
		for &kept in view.slots {
			clear(&kept.moving)
			clear(&kept.moves)
			kept.movers, kept.move_threads = 0, 0
		}
		view.movers, view.mover_threads = s.shadow_movers_found, 0
	}
	// The movers a slot held leave the counts of the view.
	forget :: proc(s: ^Scene_State, view: ^Shadow_View_Reach, kept: ^Shadow_Reached) {
		for k in kept.moving {
			view.mover_slots[k] -= 1
			if view.mover_slots[k] == 0 {view.mover_threads -= s.shadow_movers[k].count}
		}
		clear(&kept.moving)
		clear(&kept.moves)
		kept.movers, kept.move_threads = 0, 0
	}
	casters := s.shadow_casters[:]
	near_block := -1
	out := -1 // whether the cull distance leaves out a caster; -1: not known yet
	for w, slot in wants {
		m := w.m
		kept := &view.slots[slot]
		if m.rect.z == 0 {
			kept.m = {}
			if kept.movers != 0 {forget(s, view, kept)}
			continue
		}
		if kept.m != m || kept.tables != batch.tables || kept.cull != key {
			if kept.ranges.allocator.procedure == nil {
				kept.ranges = make([dynamic][2]u32, r.allocator)
				kept.casters = make([dynamic]u32, r.allocator)
				kept.moves = make([dynamic][2]u32, r.allocator)
				kept.moving = make([dynamic]u32, r.allocator)
			}
			clear(&kept.ranges)
			clear(&kept.casters)
			kept.all = false
			if kept.movers != 0 {forget(s, view, kept)}
			list: Shadow_Reach_List
			end: u32
			holds := shadow_map_holds(m, s.shadow_casters_low, s.shadow_casters_high)
			if holds && out < 0 {
				out = 0
				if s.shadow_casters_cull {
					for &c in casters {if c.casts && shadow_culled(c.low, c.high, c.cull, eye) {out = 1;break}}
				}
			}
			if holds && out == 0 {
				// Every caster lies in the map.
				if _, err := append(&kept.ranges, ..s.shadow_all[:]); err != nil {return false}
				list.threads = s.shadow_all_threads
				kept.all = true
			} else {
				// Of the casters whose middle may lie within the box of the map
				// along x, those that reach it, marked, then in the order of
				// their instances.
				// Of a face of a light, among the casters within the box of its
				// range, found once for its faces.
				near := slot >= SHADOW_SUN_LEVELS
				if near && near_block != (slot - SHADOW_SUN_LEVELS) / abi.SHADOW_LIGHT_SLOTS {
					near_block = (slot - SHADOW_SUN_LEVELS) / abi.SHADOW_LIGHT_SLOTS
					clear(&s.shadow_near)
					for k in shadow_casters_band(s, m.origin.x - m.far, m.origin.x + m.far) {
						c := &casters[k]
						if c.high.y < m.origin.y - m.far || c.low.y > m.origin.y + m.far || c.high.z < m.origin.z - m.far || c.low.z > m.origin.z + m.far || shadow_culled(c.low, c.high, c.cull, eye) {continue}
						if _, err := append(&s.shadow_near, k); err != nil {return false}
					}
				}
				low, high := shadow_map_box(m)
				if near {
					for k in s.shadow_near {
						c := &casters[k]
						if c.high.x < low.x || c.low.x > high.x || c.high.y < low.y || c.low.y > high.y || c.high.z < low.z || c.low.z > high.z || !shadow_map_reaches(m, c.low, c.high) {continue}
						s.shadow_marks[k >> 6] |= 1 << (k & 63)
					}
				} else {
					// A level of the sun: the boxes of the casters on the axes of the
					// sun, which every level shares, against the square and the depths
					// of the level from its origin, a little wide.
					if (s.shadow_sun_tables != batch.tables || s.shadow_sun_axes != {m.right, m.up, m.forward}) && !shadow_sun_boxes_update(s, m) {return false}
					at := Vec3{linalg.dot(m.origin, m.right), linalg.dot(m.origin, m.up), linalg.dot(m.origin, m.forward)}
					margin := 1e-4 * (linalg.abs(at) + 1)
					lo := Vec3{m.span.x, m.span.y, m.near} + at - margin
					hi := Vec3{m.span.z, m.span.w, m.far} + at + margin
					for k in shadow_casters_band(s, low.x, high.x) {
						box := s.shadow_sun_boxes[k]
						if box[1].x < lo.x || box[0].x > hi.x || box[1].y < lo.y || box[0].y > hi.y || box[1].z < lo.z || box[0].z > hi.z {continue}
						if c := &casters[k]; shadow_culled(c.low, c.high, c.cull, eye) {continue}
						s.shadow_marks[k >> 6] |= 1 << (k & 63)
					}
				}
				if scene_count > 0 && !shadow_range_add(&kept.ranges, &list, &end, 0, scene_count, scene_count) {return false}
				if non_zero_resize(&kept.casters, len(casters)) != nil {return false}
				held := 0
				for &word, i in s.shadow_marks {
					for ; word != 0; word &= word - 1 {
						k := i * 64 + int(intrinsics.count_trailing_zeros(word))
						c := &casters[k]
						if !shadow_range_add(&kept.ranges, &list, &end, c.first, c.count, scene_count) {return false}
						kept.casters[held] = u32(k)
						held += 1
					}
				}
				base.truncate(&kept.casters, held)
			}
			kept.m, kept.tables, kept.cull, kept.threads = m, batch.tables, key, list.threads
		}
		// The batches that move and change the map: of the casters it holds,
		// which reach it, those that move, where their sway is wider than its
		// texel.
		if kept.movers != s.shadow_movers_found {
			if kept.movers != 0 {forget(s, view, kept)}
			list: Shadow_Reach_List
			end: u32
			// A level of the sun, whose texel is the same over it, holds none
			// where it is no narrower than any sway.
			orthographic := m.kind == SHADOW_MAP_ORTHOGRAPHIC
			texel := (m.span.z - m.span.x) / f32(max(m.rect.z, 1))
			found := 0
			if non_zero_resize(&kept.moving, len(s.shadow_movers)) != nil {return false}
			if !orthographic || texel < s.shadow_movers_fine {
				count := len(s.shadow_movers) if kept.all else len(kept.casters)
				for i in 0 ..< count {
					k := i32(i) if kept.all else s.shadow_mover_of[kept.casters[i]]
					if k < 0 {continue}
					mover := &s.shadow_movers[k]
					fine := mover.change.fine
					if fine > 0 && !((texel if orthographic else shadow_map_finest(m, mover.change.low, mover.change.high)) < fine) {continue}
					if !shadow_range_add(&kept.moves, &list, &end, mover.first, mover.count, scene_count) {return false}
					kept.moving[found] = u32(k)
					found += 1
					if view.mover_slots[k] == 0 {view.mover_threads += mover.count}
					view.mover_slots[k] += 1
				}
			}
			base.truncate(&kept.moving, found)
			kept.movers, kept.move_threads = s.shadow_movers_found, list.threads
		}
		stays := &reach[slot][Shadow_Round.Stays]
		stays^ = {first = u32(len(s.shadow_ranges)), count = u32(len(kept.ranges)), threads = kept.threads}
		if _, err := append(&s.shadow_ranges, ..kept.ranges[:]); err != nil {return false}
		moves := &reach[slot][Shadow_Round.Moves]
		if plans[slot].flags & abi.SHADOW_PLAN_RESET != 0 {
			moves^ = stays^
			continue
		}
		moves^ = {first = u32(len(s.shadow_ranges)), count = u32(len(kept.moves)), threads = kept.move_threads}
		if _, err := append(&s.shadow_ranges, ..kept.moves[:]); err != nil {return false}
		end: u32
		for index in s.shadow_followed {
			if int(index) >= len(s.shadow_tracks) || !s.shadow_tracks[index].moving {continue}
			inst := &s.instances[index]
			if !instance_casts(inst^) || !shadow_map_reaches(m, inst.bounds_min.xyz, inst.bounds_max.xyz) {continue}
			if !shadow_range_add(&s.shadow_ranges, moves, &end, index, 1, scene_count) {return false}
		}
	}
	return true
}

// shadow_cull.slang Params_Block.
@(private)
Shadow_Params :: struct {
	reach, ranges, rows, chunk_capacity, entry_capacity, list, moving, movers, masks, plan, part, bound, foresee: u32,
	round, last, vertex_capacity, triangle_capacity: u32,
	margin: f32,
	_:      [2]u32,
	cull:   Vec4, // shadow_cull_eye
}

// The rounds of the cull: what stays, into the pages the cache draws; what
// moves, into the pages the atlas composes.
@(private)
Shadow_Round :: enum u32 {Stays, Moves}

// The parameters of a round: the slots its culls by instance go over lie in
// the buffer of the pages (SHADOW_WORDS_SLOTS), its pages a bit each.
@(private)
shadow_params :: proc(p: ^Pass, plan: Shadow_Plan, round: Shadow_Round) -> Shadow_Params {
	s := &p.r.scene
	masks := [Shadow_Round]u32{.Stays = abi.SHADOW_WORDS_DRAWN, .Moves = abi.SHADOW_WORDS_COMPOSE}
	return {
		reach = plan.reach, ranges = plan.ranges, rows = plan.rows,
		list = abi.SHADOW_WORDS_SLOTS + u32(round) * (SHADOW_SLOTS + 1), masks = masks[round],
		chunk_capacity = shadow_chunk_room(p.r, &p.t.shadow_raster), entry_capacity = s.cull_capacity[.Shadow_Entries],
		moving = u32(round), movers = plan.movers, plan = plan.plan, part = 1 if round == .Stays else 0,
		bound = shadow_frame_units(p.r, &p.t.shadow_raster), cull = plan.cull,
	}
}

// The chunks a round of a view hands to its cull by cluster in a frame: what
// their list holds, within the bound (SHADOW_CHUNK_UNITS).
@(private)
shadow_chunk_room :: proc(r: ^Renderer, b: ^Shadow_Raster) -> u32 {
	return min(r.scene.cull_capacity[.Shadow_Chunks], max(shadow_frame_units(r, b) / SHADOW_CHUNK_UNITS, 1))
}

// The cull of a round and what it hands to its draws: by instance and slot,
// over the instances that reach each slot with pages listed and within the
// bound of the frame (shadow_pages.comp), then by cluster over the chunks,
// as the cull of the view. A pass by instance first foresees what
// each page takes, of the cache only the pages not foreseen yet, which keep
// it until they are drawn; the steps of the pages grant the pages the
// clusters of the frame and narrow the slots and the spans of the round to
// theirs, the culls hand over the clusters of those alone, a round of the
// lists of the raster places their vertices and keeps the triangles that
// cover a texel of their pages, and the steps settle the pages not drawn
// whole.
@(private)
shadow_cull :: proc(p: ^Pass, plan: Shadow_Plan, params: Shadow_Params, round: Shadow_Round, steps: ^Shadow_Pages_Params) {
	r, cmd, t := p.r, p.cmd, p.t
	s := &r.scene
	d := &r.shadow_buffers
	params := params
	masks, list := params.masks, params.list
	// No chunk, no cluster, and draws of no triangle: the round of the
	// raster takes the entries from the first.
	start, start_at := rhi.frame_alloc_typed(r.device, Gpu_Cull_State, 1)
	if start == nil {return}
	start[0] = {chunk_dispatch = {0, 0, 1}, raster_dispatch = {0, 0, 1}}
	rhi.cmd_copy_buffer(cmd, start_at.buffer, start_at.offset, d.state, 0, size_of(Gpu_Cull_State))
	if round == .Moves && !plan.whole && plan.moving_threads == 0 {return}
	passes := [3]Pipeline_Id{.Shadow_Maps, .Shadow_Maps, .Shadow_Clusters}
	for pipeline, k in passes {
		if k == 1 {shadow_pages_step(p, steps, .Grant, u32(round))}
		params.foresee = 1 if k == 0 else 0
		// Of the cache, the foresight goes over the pages not foreseen yet alone.
		dispatch := u32(round)
		params.masks, params.list = masks, list
		if k == 0 && round == .Stays {
			dispatch = 2
			params.masks, params.list = abi.SHADOW_WORDS_FORESEE, abi.SHADOW_WORDS_SLOTS + 2 * (SHADOW_SLOTS + 1)
		}
		rhi.cmd_bind_pipeline(cmd, r.pipelines[.Shadow_Clusters_Cost if pipeline == .Shadow_Clusters && p.cost != 0 else pipeline])
		set_params(cmd, &params)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS0, d.table)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS1, s.shadow_chunks)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS2, d.state)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS3, r.stats_buffer)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS4, s.shadow_entries)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS6, t.shadow_raster.pages)
		rhi.cmd_bind_texture(cmd, SLOT_PASS7, t.shadow_raster.hiz)
		if pipeline == .Shadow_Maps {
			if plan.movers > 0 {rhi.cmd_bind_transient(cmd, SLOT_PASS5, plan.bits)} else {rhi.cmd_bind_buffer(cmd, SLOT_PASS5, r.dummy_buffer)}
			rhi.cmd_dispatch_indirect(cmd, t.shadow_raster.pages, u64(abi.SHADOW_WORDS_ARGS + abi.SHADOW_ARGS_DISPATCH + 3 * dispatch) * 4)
		} else {
			rhi.cmd_bind_buffer(cmd, SLOT_PASS5, s.shadow_raster_entries)
			if p.cost != 0 {rhi.cmd_bind_buffer(cmd, SLOT_PASS8, p.cost)}
			rhi.cmd_dispatch_indirect(cmd, d.state, u64(offset_of(Gpu_Cull_State, chunk_dispatch)))
		}
	}
	// The only round of the raster of the cull: what finds no room waits with its page.
	lists := Raster_Round_Lists{state = d.state, visible = s.shadow_entries, entries = s.shadow_raster_entries, shadow = &params, pages = t.shadow_raster.pages, maps = d.table}
	raster_round_record(r, cmd, 0, true, r.stats_buffer, &lists, p.cost)
	shadow_pages_step(p, steps, .Settle, u32(round))
}

// A step of the pages (shadow_pages.comp), which writes the table the culls
// and the draws read; round: of Grant and Settle.
@(private)
shadow_pages_step :: proc(p: ^Pass, steps: ^Shadow_Pages_Params, step: Shadow_Pages_Step, round: u32 = 0) {
	r, cmd, b := p.r, p.cmd, &p.t.shadow_raster
	steps.step, steps.round = u32(step), round
	rhi.cmd_bind_texture(cmd, SLOT_SHADOW_TABLE, r.dummy_uint)
	rhi.cmd_bind_pipeline(cmd, r.pipelines[.Shadow_Pages])
	set_params(cmd, steps)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS0, r.shadow_buffers.table)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS2, b.pages)
	rhi.cmd_bind_texture(cmd, SLOT_PASS3, b.table)
	rhi.cmd_bind_texture(cmd, SLOT_PASS4, b.hiz)
	if step == .Gate {rhi.cmd_dispatch(cmd, 1, 1)} else {rhi.cmd_dispatch_indirect(cmd, b.pages, u64(abi.SHADOW_WORDS_STEPS + 3 * u32(step)) * 4)}
	rhi.cmd_bind_texture(cmd, SLOT_SHADOW_TABLE, b.table)
}

// The depth a round culled into the cache or the atlas: of the cache, first
// the pages it draws, cleared; of the atlas, first the pages it composes,
// from the cache (held); then the triangles the lists of the raster hold, a
// draw of each raster bin the cull lists into (shadow_clusters.comp).
@(private)
shadow_draw :: proc(p: ^Pass, plan: Shadow_Plan, params: Shadow_Params, atlas: rhi.Texture, name: string, cache := false, held: rhi.Texture = 0) {
	r, cmd, t := p.r, p.cmd, p.t
	s := &r.scene
	d := &r.shadow_buffers
	pages := t.shadow_raster.pages
	params := params
	pass := rhi.Render_Pass_Desc{name = name}
	pass.depth = {texture = atlas, load = .Load, store = .Store}
	rhi.cmd_begin_render_pass(cmd, &pass)
	square :: proc(p: ^Pass, params: Shadow_Params, pipeline: Pipeline_Id, list, kind: u32, held: rhi.Texture) {
		r, cmd := p.r, p.cmd
		square := params
		square.list, square.moving = list, kind
		rhi.cmd_bind_pipeline(cmd, r.pipelines[pipeline])
		set_params(cmd, &square)
		rhi.cmd_bind_texture(cmd, SLOT_PASS2, held if held != 0 else r.dummy_texture)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS3, p.t.shadow_raster.pages)
	}
	draws := u64(abi.SHADOW_WORDS_ARGS + abi.SHADOW_ARGS_DRAW) * 4
	if cache {
		square(p, params, .Shadow_Map_Clear, abi.SHADOW_WORDS_JOBS, 0, 0)
		rhi.cmd_draw_indirect(cmd, pages, draws, 1)
	} else {
		square(p, params, .Shadow_Map_Copy, abi.SHADOW_WORDS_JOBS + abi.SHADOW_POOL_PAGES, 1, held)
		rhi.cmd_draw_indirect(cmd, pages, draws + size_of(Gpu_Draw), 1)
	}
	bins := [2]u32{RASTER_BIN_TWO_SIDED, RASTER_BIN_TWO_SIDED | RASTER_BIN_TESTED}
	for pipeline, i in ([2]Pipeline_Id{.Shadow_Map, .Shadow_Map_Tested}) {
		rhi.cmd_bind_pipeline(cmd, r.pipelines[pipeline])
		set_params(cmd, &params)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS0, s.shadow_entries)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS1, s.raster_vertices)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS3, pages)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS4, d.table)
		rhi.cmd_bind_index_buffer(cmd, s.raster_indices)
		rhi.cmd_draw_indexed_indirect(cmd, d.state, u64(offset_of(Gpu_Cull_State, draws)) + u64(bins[i]) * size_of(rhi.Draw_Indexed_Indirect), 1)
	}
	rhi.cmd_end_render_pass(cmd)
}

// The steps of shadow_pages.comp, and what each dispatches over.
@(private)
Shadow_Pages_Step :: enum u32 {Gate, Clear, Invalidate, Ancestors, Entries, Rank, Sums, Pool, Allocate, Propagate, Finish, Grant, Settle}
#assert(len(Shadow_Pages_Step) == abi.SHADOW_STEPS)

// shadow_pages.comp Params_Block.
@(private)
Shadow_Pages_Params :: struct {step, frame, rows, plan, boxes, box_count, sun, pool, reach, threads, fresh, full, slots, slot_count, keep, budget, round, chunks, moves, pad: u32}

// The units each round of the maps of a view draws in a frame.
@(private)
shadow_frame_units :: proc(r: ^Renderer, b: ^Shadow_Raster) -> u32 {
	if b.budget != 0 {return b.budget}
	least := r.shadow_bound.least if r.shadow_bound.least != 0 else SHADOW_FRAME_UNITS
	// The first frame of a view draws at the least, whatever another drew at:
	// what a unit costs it is not measured yet.
	if b.frame <= 1 || r.shadow_bound.now == 0 {return least}
	return r.shadow_bound.now
}

// The maps of the view this frame, drawn where its points read them. mark:
// the parameters of the direct light (direct_maps.comp), which the marks of
// the points take; grid: the light grid.
@(private)
shadow_maps_pass :: proc(p: ^Pass, mark: ^$T, scale: u32, grid: rhi.Buffer) -> (maps: Shadow_Maps) {
	r, cmd, t := p.r, p.cmd, p.t
	s := &r.scene
	maps.sun = max(u32)
	if !p.draw {return}
	b, d := &t.shadow_raster, &r.shadow_buffers
	// The cache holds nothing it can keep when it is new or the cut changed.
	fresh := b.cache == 0 || b.cut != r.settings.lod_error_pixels
	zone := render_zone_begin(r, "shadow plan")
	plan, ok := shadow_maps_plan(p, fresh)
	base.profile_end(zone)
	if !ok || plan.on == 0 {return}
	made := b.pages == 0 || b.table == 0 || b.hiz == 0
	if b.hiz == 0 {
		b.hiz = rhi.texture_create(r.device, {width = SHADOW_POOL / abi.SHADOW_HIZ_BLOCK, height = SHADOW_POOL / abi.SHADOW_HIZ_BLOCK, mip_levels = abi.SHADOW_HIZ_MIPS, format = .R32_Float, usage = {.Storage, .Sampled}, name = "shadow hiz"})
		if b.hiz == 0 {set_error(r, "shadow hiz: %s", rhi.device_error(r.device)); b.forget = true; return}
	}
	good := target(r, cmd, &b.cache, SHADOW_POOL, SHADOW_POOL, .D32_Float, {.Depth_Target, .Sampled}, "shadow cache") &&
	        target(r, cmd, &b.atlas, SHADOW_POOL, SHADOW_POOL, .D32_Float, {.Depth_Target, .Sampled}, "shadow atlas") &&
	        target(r, cmd, &b.table, abi.SHADOW_SLOT_ENTRIES, SHADOW_SLOTS, .R32_Uint, {.Storage, .Sampled}, "shadow table")
	pages_ok, _ := ensure_buffer(r, &b.pages, u64(abi.SHADOW_WORDS) * 4, {.Storage, .Indirect, .Transfer_Dst, .Transfer_Src}, "shadow pages")
	state_ok, _ := ensure_buffer(r, &d.state, size_of(Gpu_Cull_State), {.Storage, .Indirect, .Transfer_Dst}, "shadow map state")
	table_ok, _ := ensure_buffer(r, &d.table, b.data.size, {.Storage, .Transfer_Dst}, "shadow maps")
	if !good || !pages_ok || !state_ok || !table_ok || s.shadow_chunks == 0 || s.shadow_entries == 0 || s.shadow_raster_entries == 0 || s.raster_vertices == 0 || s.raster_indices == 0 {
		b.forget = true
		return
	}
	b.cut = r.settings.lod_error_pixels
	b.frame += 1
	// What the passes after this one read of the maps (sun_shadow_seen,
	// media.slang) and the marks: the constants of the view are read when the
	// frame runs.
	count := 0
	if plan.sun != max(u32) {
		count = int(plan.sun >> 16)
		rows := ([^][4]u32)(b.data.ptr)[int(plan.rows):][:count * SHADOW_MAP_ROWS]
		copy(p.frame.sun_map_rows[:], rows)
	}
	p.frame.sun_maps = {u32(count), plan.rows, SHADOW_POOL, 0}
	constants := (^Gpu_Frame)(p.constants.ptr)
	constants.sun_maps, constants.sun_map_rows = p.frame.sun_maps, p.frame.sun_map_rows
	rhi.cmd_copy_buffer(cmd, b.data.buffer, b.data.offset, d.table, 0, b.data.size)
	// The pages the points read: marked, then each in the pool. Where the
	// view, a light or a caster changed, the marks start anew and the points
	// mark the pages they read for a cycle of the jitter of the view; a still
	// view keeps them, and the steps run only where a point asked for a page
	// not drawn (shadow_pages.comp).
	seen := Shadow_Seen{view = p.unjittered, eye = p.frame.camera_position.xyz, size = {t.width, t.height, scale}, params = hash.fnv64a(([^]u8)(mark)[:size_of(T)]), lights = s.light_grid_placed, pool = b.pool}
	full := made || plan.whole || b.whole || plan.changed || plan.box_count > 0 || seen != b.seen
	b.seen, b.whole = seen, plan.whole
	if full {b.settle = max(p.jitter_phases, 1)}
	marking := b.settle > 0
	if marking {b.settle -= 1}
	rhi.cmd_timestamp(cmd, SHADOW_PAGES_TIMING)
	if made {rhi.cmd_fill_buffer(cmd, b.pages, 0, u64(abi.SHADOW_WORDS) * 4, 0)}
	if full {rhi.cmd_fill_buffer(cmd, b.pages, u64(abi.SHADOW_WORDS_NEEDED) * 4, u64(abi.SHADOW_WORDS_SLOTS - abi.SHADOW_WORDS_NEEDED) * 4, 0)}
	if marking {
		r.stats.shadow_marked += 1
		points := [2]u32{(t.width + scale - 1) / scale, (t.height + scale - 1) / scale}
		rhi.cmd_bind_texture(cmd, SLOT_SHADOW_TABLE, b.table)
		rhi.cmd_bind_pipeline(cmd, r.pipelines[.Shadow_Mark])
		set_params(cmd, mark)
		rhi.cmd_bind_texture(cmd, SLOT_PASS0, t.normal)
		rhi.cmd_bind_texture(cmd, SLOT_PASS1, t.linear_depth)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS2, b.pages)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS6, grid)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS9, d.table)
		rhi.cmd_dispatch(cmd, groups(points.x, 8), groups(points.y, 8))
	}
	// The table is written in the steps of the pages and read after them;
	// where its pages wait, the nearest coarser page drawn is found once the
	// rounds have drawn (Propagate).
	steps := Shadow_Pages_Params{
		frame = b.frame, rows = plan.rows, plan = plan.plan, boxes = plan.boxes, box_count = plan.box_count, sun = plan.sun >> 16,
		pool = b.pool if b.pool != 0 else abi.SHADOW_POOL_PAGES, fresh = 1 if made else 0, full = 1 if full else 0, slots = plan.slots, slot_count = plan.slot_count,
		reach = plan.reach, threads = shadow_frame_units(r, b),
		keep = max(p.jitter_phases, 1),
		budget = shadow_frame_units(r, b),
		chunks = shadow_chunk_room(r, b),
		moves = 1 if plan.whole || plan.moving_threads > 0 else 0,
	}
	for step in Shadow_Pages_Step {
		if step == .Propagate || step >= .Grant {continue}
		shadow_pages_step(p, &steps, step)
	}
	r.stats.shadow_movers += plan.moving_threads
	// What stays, into the pages of the cache it draws.
	rhi.cmd_measure_begin(cmd, SHADOW_MAPS_TIMING)
	rhi.cmd_timestamp(cmd, "shadow cull")
	params := shadow_params(p, plan, .Stays)
	shadow_cull(p, plan, params, .Stays, &steps)
	rhi.cmd_timestamp(cmd, "shadow cache")
	shadow_draw(p, plan, params, b.cache, "shadow cache", cache = true)
	// The farthest depth of the pages the cache drew, which what moves is culled against.
	rhi.cmd_timestamp(cmd, "shadow hiz")
	rhi.cmd_bind_pipeline(cmd, r.pipelines[.Shadow_Hiz])
	rhi.cmd_bind_texture(cmd, SLOT_PASS0, b.cache)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS1, b.pages)
	for mip in 0 ..< abi.SHADOW_HIZ_MIPS {rhi.cmd_bind_texture(cmd, SLOT_PASS2 + u32(mip), b.hiz, i32(mip))}
	rhi.cmd_dispatch_indirect(cmd, b.pages, u64(abi.SHADOW_WORDS_ARGS + abi.SHADOW_ARGS_HIZ) * 4)
	// The pages of the atlas where the cache drew or what moves changed: the
	// cache, then what moves over it.
	rhi.cmd_timestamp(cmd, "shadow cull moving")
	params = shadow_params(p, plan, .Moves)
	shadow_cull(p, plan, params, .Moves, &steps)
	rhi.cmd_timestamp(cmd, "shadow atlas")
	shadow_draw(p, plan, params, b.atlas, "shadow atlas", held = b.cache)
	shadow_pages_step(p, &steps, .Propagate)
	rhi.cmd_measure_end(cmd)
	// What the passes after the maps marked the frame before has been read;
	// after a change their marks of this frame start anew.
	if full {rhi.cmd_fill_buffer(cmd, b.pages, u64(abi.SHADOW_WORDS_LATE) * 4, u64(abi.SHADOW_MASKS) * 4, 0)}
	rhi.cmd_copy_buffer(cmd, b.pages, u64(abi.SHADOW_WORDS_COUNTS + abi.SHADOW_COUNT_DRAWN) * 4, r.stats_buffer, u64(offset_of(Gpu_Cull_Stats, shadow) + offset_of(Shadow_Stats, pages_drawn)), 12)
	rhi.cmd_copy_buffer(cmd, b.pages, u64(abi.SHADOW_WORDS_COUNTS + abi.SHADOW_COUNT_LEFT) * 4, r.stats_buffer, u64(offset_of(Gpu_Cull_Stats, shadow) + offset_of(Shadow_Stats, pages_left)), 4)
	rhi.cmd_copy_buffer(cmd, b.pages, u64(abi.SHADOW_WORDS_COUNTS + abi.SHADOW_COUNT_WAITING) * 4, r.stats_buffer, u64(offset_of(Gpu_Cull_Stats, shadow) + offset_of(Shadow_Stats, pages_waiting)), 4)
	rhi.cmd_copy_buffer(cmd, b.pages, u64(abi.SHADOW_WORDS_COUNTS + abi.SHADOW_COUNT_SHORT) * 4, r.stats_buffer, u64(offset_of(Gpu_Cull_Stats, shadow) + offset_of(Shadow_Stats, pages_short)), 4)
	rhi.cmd_copy_buffer(cmd, b.pages, u64(abi.SHADOW_WORDS_COUNTS + abi.SHADOW_COUNT_THREADS) * 4, r.stats_buffer, u64(offset_of(Gpu_Cull_Stats, shadow) + offset_of(Shadow_Stats, cull_threads)), 4)
	return plan.shadow
}

@(private)
destroy_shadow_maps :: proc(r: ^Renderer, t: ^Targets) {
	if t.shadow_raster.cache != 0 {rhi.texture_destroy(r.device, t.shadow_raster.cache)}
	if t.shadow_raster.atlas != 0 {rhi.texture_destroy(r.device, t.shadow_raster.atlas)}
	if t.shadow_raster.table != 0 {rhi.texture_destroy(r.device, t.shadow_raster.table)}
	if t.shadow_raster.hiz != 0 {rhi.texture_destroy(r.device, t.shadow_raster.hiz)}
	if t.shadow_raster.pages != 0 {rhi.buffer_destroy(r.device, t.shadow_raster.pages)}
	shadow_reach_release(r, &t.shadow_raster)
	t.shadow_raster = {}
}
