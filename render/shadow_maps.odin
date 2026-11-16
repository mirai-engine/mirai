package mirai_render

import "core:hash"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "mirai:render/abi"
import "mirai:rhi"
import "mirai:std/base"

// Shadow maps in place of the rays of the direct light for the lights that
// light much of the view and for the sun. Each frame, from the camera and the
// lights alone, the lights whose sphere covers SHADOW_RASTER_SHARE of the view
// (and keep SHADOW_RASTER_KEEP once they do) take a map for each face of the
// cube around them through which they light what the view sees, and the sun
// one for each of its levels around the eye. The other lights, small on the
// screen, trace rays (shadow_maps.slang, shadow_maps.comp, shadow_map.vert,
// direct_samples.comp).
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
SHADOW_DRAWS :: 3 // the clusters that hide whole, those of masked materials and those of glass (shadow_cull.slang)
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
// the one whose texel is about as wide as it (sun_pick of shadow_maps.slang),
// the first serving what lies nearest the eye.
SHADOW_SUN_FIRST :: f32(1)
SHADOW_SUN_LEVELS :: abi.SHADOW_SUN_MAPS
SHADOW_MAP_ORTHOGRAPHIC :: abi.SHADOW_MAP_ORTHOGRAPHIC
// The frames after its last change an instance whose shadow changed twice
// within them keeps moving (shadow_movers_update).
SHADOW_MOVER_FRAMES :: u64(30)

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
// it reads them: the state of the cull of their clusters and of the draws of
// them, and the words of the lights and the slots. The lists of that cull are
// the scene's (Cull_List.Shadow_Chunks, Shadow_Entries), which grow as those
// of the view do.
Shadow_Buffers :: struct {
	state: rhi.Buffer, // Gpu_Shadow_State
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
	held:     [SHADOW_SLOTS]Shadow_Held,
	forget:   bool, // every page is let go of in the next frame
	cut:      f32,  // the threshold of the cut the cache was drawn with
	stale:    Occluder_Changes, // what stays and changed since the maps were last drawn
	moved:    Occluder_Changes, // where what moves was and is since then
	frame:    u32,  // counts the frames the pages were drawn in
	seen:     Shadow_Seen, // what the points marked the pages from
	settle:   u32,  // the frames the points still mark the pages in after the view changed: a cycle of its jitter
	whole:    bool, // a slot drew its pages whole into the atlas alone the frame before: the cache draws them now
	tint:     rhi.Texture, // what the glass in front of the depth of each texel of the atlas lets through of its light
	glass:    rhi.Texture, // the depth of the nearest of that glass
	tinted:   bool, // the frame before drew the tint
	tint_whole: bool, // and drew it whole
	glass_key: u64,  // what the tint was drawn from (shadow_glass_key)
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
// sway, metres of the world (the texel of a map below which it moves there),
// and whether its vertices change this frame; 0 for any other batch.
@(private)
batch_sway :: proc(s: ^Scene_State, record: Batch_Record) -> (fine: f32, swaying: bool) {
	if .Casts_Shadow not_in record.desc.flags || int(record.desc.mesh) >= len(s.meshes) {return}
	skin := s.meshes[record.desc.mesh].skin
	if skin == nil || !skin.external {return}
	fine = skin.sway * record.scale if skin.sway > 0 else max(f32)
	return max(fine, 1e-6), skin.dirty
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
	// A batch of a deformable that casts shadows whose vertices change (the
	// wind) changes as an instance does, in the maps whose texel is narrower
	// than how far it sways alone: the others draw it at rest and keep it.
	b := &s.batch
	for index, k in b.drawn {
		record := &b.records[index]
		fine, swaying := batch_sway(s, record^)
		if fine == 0 {continue}
		box := b.boxes[k]
		if swaying {
			if record.shadow_frame != 0 {
				record.shadow_frame = now
				if record.shadow_moving {
					occluder_add(&moved, OCCLUDERS_MANY, box.min, box.max, fine)
					continue
				}
				record.shadow_moving = true
			} else {
				record.shadow_frame = now
			}
			occluder_add(&stale, OCCLUDERS_MANY, box.min, box.max, fine)
		} else if record.shadow_frame != 0 && now - record.shadow_frame >= SHADOW_MOVER_FRAMES {
			if record.shadow_moving {occluder_add(&stale, OCCLUDERS_MANY, box.min, box.max, fine)}
			record.shadow_frame, record.shadow_moving = 0, false
		}
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

// What the tint of the maps is drawn from besides the pages: the instances
// with glass and the values of the rows of the materials; moving: one of
// them changes its vertices this frame.
@(private)
shadow_glass_key :: proc(s: ^Scene_State) -> (key: u64, moving: bool) {
	key = hash.fnv64a(mem.slice_to_bytes(s.material_versions[:]))
	for entry in s.translucent {
		if int(entry.instance) >= len(s.instances) {continue}
		inst := s.instances[entry.instance]
		key = hash.fnv64a(mem.ptr_to_bytes(&inst), key)
		mesh := inst.meta.x & INSTANCE_MESH_MASK
		if int(mesh) < len(s.meshes) && s.meshes[mesh].skin != nil && s.meshes[mesh].skin.dirty {moving = true}
	}
	return
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
	movers:         u32, // words of the bits of what moves, and after them
	moving_count:   u32, // the ranges of it that reach a map
	moving_threads: u32, // the instances of those ranges
	whole:          bool, // a slot lets go of every page: the round of what moves draws what stays too there
	changed:        bool, // a level of the sun moved, or what stays changed everywhere in a slot
	bits:           rhi.Transient,
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
	// the mip whose texel is about as wide as it (light_pick).
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
	stale, moved := b.stale, b.moved
	b.stale, b.moved = {}, {}
	// The bits of what moves: the instances, then the batches drawn, after
	// those of the scene; then the ranges of instances that reach a map, which
	// the round of what moves culls alone: an instance of the scene, or the
	// slots of a batch, two words each, its first instance and the first
	// thread of the round that takes it.
	scene_count := len(s.instances)
	last, ranges := -1, 0
	for index in s.shadow_followed {
		if int(index) >= len(s.shadow_tracks) || !s.shadow_tracks[index].moving {continue}
		last = max(last, int(index))
		ranges += 1
	}
	for index, k in s.batch.drawn {
		if !s.batch.records[index].shadow_moving {continue}
		last = max(last, scene_count + k)
		ranges += 1
	}
	if last >= 0 {
		plan.movers = u32(last / 32 + 1)
		bits, data := rhi.frame_alloc_typed(r.device, u32, int(plan.movers) + 2 * ranges)
		if bits == nil {set_error(r, "transient ring exhausted with the bits of %d instances", last + 1); return plan, false}
		for &word in bits[:plan.movers] {word = 0}
		take :: proc(bits: []u32, plan: ^Shadow_Plan, first, count: u32) {
			bits[plan.movers + 2 * plan.moving_count] = first
			bits[plan.movers + 2 * plan.moving_count + 1] = plan.moving_threads
			plan.moving_count += 1
			plan.moving_threads += count
		}
		for index in s.shadow_followed {
			if int(index) >= len(s.shadow_tracks) || !s.shadow_tracks[index].moving {continue}
			bits[index / 32] |= 1 << (index % 32)
			inst := s.instances[index]
			if !instance_casts(inst) {continue}
			for w in wants {
				if w.m.rect.z == 0 || !shadow_map_reaches(w.m, inst.bounds_min.xyz, inst.bounds_max.xyz) {continue}
				take(bits, &plan, index, 1)
				break
			}
		}
		for index, k in s.batch.drawn {
			record := s.batch.records[index]
			if !record.shadow_moving {continue}
			bit := u32(scene_count + k)
			bits[bit / 32] |= 1 << (bit % 32)
			fine, _ := batch_sway(s, record)
			box := s.batch.boxes[k]
			change := Occluder_Change{low = box.min, high = box.max, instance = OCCLUDERS_MANY, fine = fine}
			for w in wants {
				if w.m.rect.z == 0 || !shadow_change_reaches(w.m, change) {continue}
				take(bits, &plan, u32(scene_count) + transmute(u32)s.batch.rows[k].world[0].z, record.count)
				break
			}
		}
		plan.bits = data
	}
	// The buffer of this frame: a word for each light of the scene (its first
	// slot + 1, and from bit SHADOW_LIGHT_FACES the faces it has), the map of
	// each slot, the plan of each, and the boxes of what changed.
	all_lights := u32(len(s.lights) + light_region_lights(s.light_region))
	plan.rows = (all_lights + 3) / 4
	plan.plan = plan.rows * 4 + SHADOW_SLOTS * SHADOW_MAP_ROWS * 4
	plan.boxes = plan.plan + SHADOW_SLOTS * size_of(Shadow_Slot_Plan) / 4
	plan.box_count = u32(stale.count + moved.count)
	plan.slots = plan.boxes + plan.box_count * size_of(Shadow_Box) / 4
	for w, slot in wants {if w.m.rect.z != 0 || plans[slot].flags & abi.SHADOW_PLAN_RESET != 0 {plan.slot_count += 1}}
	words, data := rhi.frame_alloc_typed(r.device, u32, int(plan.slots + plan.slot_count))
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
	plan.maps = SHADOW_SLOTS
	plan.on = 1 if any else 0
	b.data = data
	return plan, true
}

// shadow_cull.slang Params_Block.
@(private)
Shadow_Params :: struct {instances, maps, rows, glass, chunk_capacity, entry_capacity, list, moving, movers, listed, ranges, masks, plan, span, pad1, pad2: u32}

// The rounds of the cull: what stays, into the pages the cache draws; what
// moves, into the pages the atlas composes; the glass, into every page ready,
// or into the pages the atlas composes alone (Tint), where the tint of a view
// that keeps it changed.
@(private)
Shadow_Round :: enum u32 {Stays, Moves, Glass, Tint}

// The parameters of a round: its slots are listed in the buffer of the
// pages (SHADOW_WORDS_SLOTS), its pages a bit each. The round of what moves
// culls the ranges of the movers that reach a map alone.
@(private)
shadow_params :: proc(p: ^Pass, plan: Shadow_Plan, round: Shadow_Round) -> Shadow_Params {
	s := &p.r.scene
	masks := [Shadow_Round]u32{.Stays = abi.SHADOW_WORDS_DRAWN, .Moves = abi.SHADOW_WORDS_COMPOSE, .Glass = abi.SHADOW_WORDS_READY, .Tint = abi.SHADOW_WORDS_COMPOSE}
	// The pages of each round lie in the lists of the one of the steps of the pages.
	pages := [Shadow_Round]u32{.Stays = 0, .Moves = 1, .Glass = 2, .Tint = 1}
	params := Shadow_Params{
		instances = p.instance_count + p.batch_slots, maps = SHADOW_SLOTS, rows = plan.rows, glass = 1 if round >= .Glass else 0,
		list = abi.SHADOW_WORDS_SLOTS + pages[round] * SHADOW_SLOTS, masks = masks[round], span = pages[round],
		chunk_capacity = s.cull_capacity[.Shadow_Chunks], entry_capacity = s.cull_capacity[.Shadow_Entries],
		moving = min(u32(round), 2), movers = plan.movers, plan = plan.plan,
	}
	// The round of what moves culls the movers alone, but in a frame a slot
	// draws whole into the atlas.
	if round == .Moves && !plan.whole {params.instances, params.listed, params.ranges = plan.moving_threads, 1, plan.moving_count}
	return params
}

// The cull of a round and what it hands to its draws: by instance and slot,
// as many slots as the pages listed (shadow_pages.comp), then by cluster over
// the chunks, as the cull of the view.
@(private)
shadow_cull :: proc(p: ^Pass, plan: Shadow_Plan, params: Shadow_Params, round: Shadow_Round) {
	r, cmd, t := p.r, p.cmd, p.t
	s := &r.scene
	d := &r.shadow_buffers
	params := params
	start, start_at := rhi.frame_alloc_typed(r.device, Gpu_Shadow_State, 1)
	if start == nil {return}
	start[0] = {draws = {{vertex_count = CLUSTER_DRAW_VERTICES}, {vertex_count = CLUSTER_DRAW_VERTICES}, {vertex_count = CLUSTER_DRAW_VERTICES}}, cluster_dispatch = {0, 0, 1}}
	rhi.cmd_copy_buffer(cmd, start_at.buffer, start_at.offset, d.state, 0, size_of(Gpu_Shadow_State))
	if params.instances == 0 {return}
	for pipeline in ([2]Pipeline_Id{.Shadow_Maps, .Shadow_Clusters}) {
		rhi.cmd_bind_pipeline(cmd, r.pipelines[pipeline])
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
			args := abi.SHADOW_ARGS_TINT if round == .Tint else abi.SHADOW_ARGS_DISPATCH + 3 * u32(round)
			rhi.cmd_dispatch_indirect(cmd, t.shadow_raster.pages, u64(abi.SHADOW_WORDS_ARGS + args) * 4)
		} else {
			rhi.cmd_dispatch_indirect(cmd, d.state, u64(offset_of(Gpu_Shadow_State, cluster_dispatch)))
		}
	}
}

// The depth a round culled into the cache or the atlas: of the cache, first
// the pages it draws, cleared; of the atlas, first the pages it composes,
// from the cache (held).
@(private)
shadow_draw :: proc(p: ^Pass, plan: Shadow_Plan, params: Shadow_Params, atlas: rhi.Texture, name: string, cache := false, held: rhi.Texture = 0) {
	r, cmd, t := p.r, p.cmd, p.t
	s := &r.scene
	d := &r.shadow_buffers
	pages := t.shadow_raster.pages
	params := params
	params.glass = 0
	pass := rhi.Render_Pass_Desc{name = name}
	pass.depth = {texture = atlas, load = .Load, store = .Store}
	rhi.cmd_begin_render_pass(cmd, &pass)
	square :: proc(p: ^Pass, params: Shadow_Params, pipeline: Pipeline_Id, list, kind: u32, held: rhi.Texture) {
		r, cmd := p.r, p.cmd
		square := params
		square.list, square.moving = list, kind
		rhi.cmd_bind_pipeline(cmd, r.pipelines[pipeline])
		set_params(cmd, &square)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS0, r.scene.shadow_entries)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS1, r.shadow_buffers.table)
		rhi.cmd_bind_texture(cmd, SLOT_PASS2, held if held != 0 else r.dummy_texture)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS3, p.t.shadow_raster.pages)
	}
	draws := u64(abi.SHADOW_WORDS_ARGS + abi.SHADOW_ARGS_DRAW) * 4
	if cache {
		square(p, params, .Shadow_Map_Clear, abi.SHADOW_WORDS_JOBS, 0, 0)
		rhi.cmd_draw_indirect(cmd, pages, draws, 1)
	} else {
		square(p, params, .Shadow_Map_Copy, abi.SHADOW_WORDS_JOBS + abi.SHADOW_POOL_PAGES, 0, held)
		rhi.cmd_draw_indirect(cmd, pages, draws + size_of(Gpu_Draw), 1)
	}
	for pipeline, i in ([2]Pipeline_Id{.Shadow_Map, .Shadow_Map_Tested}) {
		rhi.cmd_bind_pipeline(cmd, r.pipelines[pipeline])
		set_params(cmd, &params)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS0, s.shadow_entries)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS1, d.table)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS3, pages)
		rhi.cmd_draw_indirect(cmd, d.state, u64(i) * size_of(Gpu_Draw), 1)
	}
	rhi.cmd_end_render_pass(cmd)
}

// The steps of shadow_pages.comp, and what each dispatches over.
@(private)
Shadow_Pages_Step :: enum u32 {Gate, Clear, Invalidate, Entries, Rank, Sums, Pool, Allocate, Propagate, Finish}
#assert(len(Shadow_Pages_Step) == abi.SHADOW_STEPS)

// shadow_pages.comp Params_Block.
@(private)
Shadow_Pages_Params :: struct {step, frame, rows, plan, boxes, box_count, sun, pool, groups_stays, groups_moves, groups_glass, fresh, full, slots, slot_count, pad0: u32}

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
	plan, ok := shadow_maps_plan(p, fresh)
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
	state_ok, _ := ensure_buffer(r, &d.state, size_of(Gpu_Shadow_State), {.Storage, .Indirect, .Transfer_Dst}, "shadow map state")
	table_ok, _ := ensure_buffer(r, &d.table, b.data.size, {.Storage, .Transfer_Dst}, "shadow maps")
	if !good || !pages_ok || !state_ok || !table_ok || s.shadow_chunks == 0 || s.shadow_entries == 0 {
		b.forget = true
		return
	}
	b.cut = r.settings.lod_error_pixels
	b.frame += 1
	// While glass colors light: what the glass in front of the depth of each
	// texel lets through, and the depth of the nearest glass (shadow_tint of
	// shadow_maps.slang). The view keeps them: drawn whole where the glass
	// changed, else again only in the pages the atlas composes.
	tinted := r.settings.colored_shadows && len(s.translucent) > 0
	glass_key, glass_moving := shadow_glass_key(s)
	tint_whole := made || !b.tinted || b.tint == 0 || b.glass == 0 || glass_moving || glass_key != b.glass_key
	if tinted {
		tint_ok := target(r, cmd, &b.tint, SHADOW_POOL, SHADOW_POOL, .RGBA8_Unorm, {.Color_Target, .Sampled}, "shadow tint")
		glass_ok := target(r, cmd, &b.glass, SHADOW_POOL, SHADOW_POOL, .D32_Float, {.Depth_Target, .Sampled}, "shadow glass")
		tinted = tint_ok && glass_ok
	}
	b.tinted, b.tint_whole, b.glass_key = tinted, tinted && tint_whole, glass_key
	// What the passes after this one read of the maps (sun_shadow_seen,
	// media.slang) and the marks: the constants of the view are read when the
	// frame runs.
	count := 0
	if plan.sun != max(u32) {
		count = int(plan.sun >> 16)
		rows := ([^][4]u32)(b.data.ptr)[int(plan.rows):][:count * SHADOW_MAP_ROWS]
		copy(p.frame.sun_map_rows[:], rows)
	}
	p.frame.sun_maps = {u32(count), plan.rows, SHADOW_POOL, 1 if tinted else 0}
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
	rhi.cmd_timestamp(cmd, "shadow pages")
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
	// The table is written in the steps of the pages and read after them.
	rhi.cmd_bind_texture(cmd, SLOT_SHADOW_TABLE, r.dummy_uint)
	steps := Shadow_Pages_Params{
		frame = b.frame, rows = plan.rows, plan = plan.plan, boxes = plan.boxes, box_count = plan.box_count, sun = plan.sun >> 16,
		pool = b.pool if b.pool != 0 else abi.SHADOW_POOL_PAGES, fresh = 1 if made else 0, full = 1 if full else 0, slots = plan.slots, slot_count = plan.slot_count,
		groups_stays = groups(p.instance_count + p.batch_slots, SHADOW_GROUP), groups_moves = groups(p.instance_count + p.batch_slots if plan.whole else plan.moving_threads, SHADOW_GROUP),
		groups_glass = groups(p.instance_count + p.batch_slots, SHADOW_GROUP),
	}
	for step in Shadow_Pages_Step {
		// What the passes after the maps marked the frame before is read; after a change this frame's marks start anew.
		if step == .Rank && full {rhi.cmd_fill_buffer(cmd, b.pages, u64(abi.SHADOW_WORDS_LATE) * 4, u64(abi.SHADOW_MASKS) * 4, 0)}
		rhi.cmd_bind_pipeline(cmd, r.pipelines[.Shadow_Pages])
		steps.step = u32(step)
		set_params(cmd, &steps)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS0, d.table)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS2, b.pages)
		rhi.cmd_bind_texture(cmd, SLOT_PASS3, b.table)
		rhi.cmd_bind_texture(cmd, SLOT_PASS4, b.hiz)
		if step == .Gate {rhi.cmd_dispatch(cmd, 1, 1)} else {rhi.cmd_dispatch_indirect(cmd, b.pages, u64(abi.SHADOW_WORDS_STEPS + 3 * u32(step)) * 4)}
	}
	rhi.cmd_bind_texture(cmd, SLOT_SHADOW_TABLE, b.table)
	r.stats.shadow_movers += plan.moving_threads
	// What stays, into the pages of the cache it draws.
	rhi.cmd_timestamp(cmd, "shadow cull")
	params := shadow_params(p, plan, .Stays)
	shadow_cull(p, plan, params, .Stays)
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
	shadow_cull(p, plan, params, .Moves)
	rhi.cmd_timestamp(cmd, "shadow atlas")
	shadow_draw(p, plan, params, b.atlas, "shadow atlas", held = b.cache)
	if tinted {
		rhi.cmd_timestamp(cmd, "shadow cull glass")
		round := Shadow_Round.Glass if tint_whole else .Tint
		params = shadow_params(p, plan, round)
		shadow_cull(p, plan, params, round)
		rhi.cmd_timestamp(cmd, "shadow tint")
		load := rhi.Load_Op.Clear if tint_whole else .Load
		tint := rhi.Render_Pass_Desc{name = "shadow tint", color_count = 1}
		tint.colors[0] = {texture = b.tint, load = load, store = .Store, clear = {1, 1, 1, 1}}
		tint.depth = {texture = b.atlas, load = .Load, store = .Store}
		nearest := rhi.Render_Pass_Desc{name = "shadow glass"}
		nearest.depth = {texture = b.glass, load = load, store = .Store, clear = 0}
		passes := [2]rhi.Render_Pass_Desc{tint, nearest}
		for &desc, i in passes {
			rhi.cmd_begin_render_pass(cmd, &desc)
			if !tint_whole {
				// The pages the atlas composed let all light through and hold no glass, before their glass is drawn.
				square := params
				square.list = abi.SHADOW_WORDS_JOBS + abi.SHADOW_POOL_PAGES
				rhi.cmd_bind_pipeline(cmd, r.pipelines[.Shadow_Map_Blank if i == 0 else .Shadow_Map_Clear])
				set_params(cmd, &square)
				rhi.cmd_bind_buffer(cmd, SLOT_PASS0, s.shadow_entries)
				rhi.cmd_bind_buffer(cmd, SLOT_PASS1, d.table)
				rhi.cmd_bind_texture(cmd, SLOT_PASS2, r.dummy_texture)
				rhi.cmd_bind_buffer(cmd, SLOT_PASS3, b.pages)
				rhi.cmd_draw_indirect(cmd, b.pages, u64(abi.SHADOW_WORDS_ARGS + abi.SHADOW_ARGS_DRAW) * 4 + size_of(Gpu_Draw), 1)
			}
			rhi.cmd_bind_pipeline(cmd, r.pipelines[.Shadow_Map_Tint if i == 0 else .Shadow_Map_Glass])
			set_params(cmd, &params)
			rhi.cmd_bind_buffer(cmd, SLOT_PASS0, s.shadow_entries)
			rhi.cmd_bind_buffer(cmd, SLOT_PASS1, d.table)
			rhi.cmd_bind_buffer(cmd, SLOT_PASS3, b.pages)
			rhi.cmd_draw_indirect(cmd, d.state, 2 * size_of(Gpu_Draw), 1)
			rhi.cmd_end_render_pass(cmd)
		}
	}
	return plan.shadow
}

@(private)
destroy_shadow_maps :: proc(r: ^Renderer, t: ^Targets) {
	if t.shadow_raster.cache != 0 {rhi.texture_destroy(r.device, t.shadow_raster.cache)}
	if t.shadow_raster.atlas != 0 {rhi.texture_destroy(r.device, t.shadow_raster.atlas)}
	if t.shadow_raster.table != 0 {rhi.texture_destroy(r.device, t.shadow_raster.table)}
	if t.shadow_raster.hiz != 0 {rhi.texture_destroy(r.device, t.shadow_raster.hiz)}
	if t.shadow_raster.pages != 0 {rhi.buffer_destroy(r.device, t.shadow_raster.pages)}
	if t.shadow_raster.tint != 0 {rhi.texture_destroy(r.device, t.shadow_raster.tint)}
	if t.shadow_raster.glass != 0 {rhi.texture_destroy(r.device, t.shadow_raster.glass)}
	t.shadow_raster = {}
}
