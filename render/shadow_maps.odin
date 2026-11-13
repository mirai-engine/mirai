package mirai_render

import "core:math"
import "core:math/linalg"
import "mirai:render/abi"
import "mirai:rhi"

// Shadow maps in place of the rays of the direct light for the lights that
// light much of the view and for the sun. Each frame, from the camera and the
// lights alone, the lights whose sphere covers SHADOW_RASTER_SHARE of the view
// (and keep SHADOW_RASTER_KEEP once they do) take a map for each face of the
// cube around them through which they light what the view sees, and the sun
// one for each cascade of the view; the atlas is shared among them by how
// much of the view each lights. The other lights, small on the screen, trace
// rays (shadow_maps.slang, shadow_maps.comp, shadow_map.vert,
// direct_samples.comp).
//
// The cost follows what changed. A map keeps its square of the atlas while
// the plan wants it the same, and what stays (Shadow_Movers) is kept in the
// cache of the view: a map draws again only where it is new or what stays
// changed in its frustum, in the frame that changed it. What moves is drawn
// every frame over a copy of the cache, so a moving body leaves the cache of
// what stays as it is. What a map draws is chosen by its texels, not by the
// eye: its detail (shadow_map_detail) and the casters too small for a texel
// of it (shadow_map_unseen).
// The side of the atlas of the maps of a view, texels.
SHADOW_ATLAS :: u32(4096)
SHADOW_MAPS_MAX :: 96
SHADOW_MAP_ROWS :: abi.SHADOW_MAP_ROWS
SHADOW_DRAWS :: 3 // the clusters that hide whole, those of masked materials and those of glass (shadow_cull.slang)
SHADOW_GROUP :: u32(256) // the threads of a group of shadow_maps.comp
SHADOW_MAP_SMALLEST :: u32(128)
SHADOW_MAP_LARGEST :: u32(2048)
SHADOW_LIGHT_FACES :: abi.SHADOW_LIGHT_FACES
SHADOW_SPOT_FACE :: abi.SHADOW_SPOT_FACE
// The cosine of the half angle of the widest spot that takes one map along
// its cone instead of the faces of the cube around it.
SHADOW_SPOT_COS_MIN :: f32(0.5)
SHADOW_RASTER_SHARE :: f32(0.02)
SHADOW_RASTER_KEEP :: f32(0.01)
SHADOW_RASTER_LIGHTS :: 32 // the most lights rasterized in a frame, those that light most of the view
// The far end of each cascade of the sun, metres from the eye, and the side
// of its map: the nearest, the sharpest. The far ones hold the ground and the
// mountains out to the horizon of an open scene, whose points, each metres
// wide, average their maps where samples would not agree.
SHADOW_SUN_CASCADES :: [abi.SHADOW_SUN_MAPS]f32{8, 32, 128, 512, 2048, 16384}
SHADOW_SUN_SIDES :: [abi.SHADOW_SUN_MAPS]u32{2048, 2048, 1024, 1024, 1024, 1024}
SHADOW_MAP_ORTHOGRAPHIC :: abi.SHADOW_MAP_ORTHOGRAPHIC
// The most casters Shadow_Movers follows, and the frames after its last
// change an instance keeps moving.
SHADOW_MOVERS_MAX :: 256
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
	rect:    [4]u32, // x, y, side in the atlas; the light (max(u32): the sun)
}
#assert(size_of(Gpu_Shadow_Map) == SHADOW_MAP_ROWS * 16)

// What the direct light reads of the maps of the frame.
Shadow_Maps :: struct {
	on:   u32, // 1 while there are maps
	rows: u32, // of the words of the lights in the buffer of the maps
	maps: u32,
	sun:  u32, // the first map of the sun | the count << 16; max(u32): none
}

// The buffers the maps of a view are drawn from, which each view writes before
// it reads them, as it does the atlas they share: the state of the cull of
// their clusters and of the draws of them, and the words of the lights and
// the maps. The lists of that cull are the scene's (Cull_List.Shadow_Chunks,
// Shadow_Entries), which grow as those of the view do.
Shadow_Buffers :: struct {
	state: rhi.Buffer, // Gpu_Shadow_State
	table: rhi.Buffer, // data copied for the passes to read
}

// What the maps of a view keep: which lights were rasterized the frame before
// (the margin between SHADOW_RASTER_KEEP and SHADOW_RASTER_SHARE keeps a light
// from going back and forth), the cache of what stays and the maps it holds.
Shadow_Raster :: struct {
	raster:   [SHADOW_RASTER_LIGHTS]i32, // the lights rasterized the frame before
	rastered: int,
	data:     rhi.Transient, // of this frame
	cache:    rhi.Texture, // the depth of what stays in the maps held, in their squares of the atlas
	held:     [SHADOW_MAPS_MAX]Shadow_Held,
	held_count: int,
	cut:      f32, // the threshold of the cut the cache was drawn with
	stale:    Occluder_Changes, // what stays and changed since the maps were last drawn
	atlas:    rhi.Texture, // what the passes after the maps read this frame: the cache, or the frame's atlas with what moves
}

// A map the cache holds, as it was drawn.
@(private)
Shadow_Held :: struct {
	m:     Gpu_Shadow_Map,
	light: int,
	face:  u32,
	grid:  [3]i32,
	end:   f32,
}

// The instances whose shadows changed lately (Occluder_Changes): one that
// changes again within SHADOW_MOVER_FRAMES moves, and is drawn every frame
// apart from what stays until it stays that long.
Shadow_Movers :: struct {
	tracked: [SHADOW_MOVERS_MAX]Shadow_Mover,
	count:   int,
}

@(private)
Shadow_Mover :: struct {
	instance: u32,
	frame:    u64, // that it last changed
	moving:   bool,
}

// A map the plan wants, before it has its square of the atlas.
@(private)
Shadow_Want :: struct {
	m:      Gpu_Shadow_Map,
	light:  int, // -1: the sun
	face:   u32, // of the sun, the cascade
	weight: f32, // how much of the view it serves
	side:   u32,
	placed: bool,
	grid:   [3]i32, // of a cascade, its origin in texels across the light and in steps of its radius along it
	end:    f32, // of a cascade, the far end of its slice, metres from the eye
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
shadow_light_faces :: proc(wants: ^[SHADOW_MAPS_MAX]Shadow_Want, count: ^int, light: Gpu_Light, index: int, share: f32, eye, forward, right, up: Vec3, tan_x, tan_y, near: f32, scene_low, scene_high: Vec3, has_bounds: bool) {
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
		if count^ >= SHADOW_MAPS_MAX {return}
		ff := linalg.normalize(light.direction_cone.xyz)
		reference := Vec3{0, 1, 0} if abs(ff.y) < 0.99 else Vec3{1, 0, 0}
		fr := linalg.normalize(linalg.cross(reference, ff))
		fu := linalg.cross(ff, fr)
		cone := math.acos(clamp(light.direction_cone.w, -1, 1))
		reach := math.tan(min(cone * 1.05 + 0.02, 1.2))
		wants[count^] = {
			m = {origin = c, near = light_near, right = fr, far = range, up = fu, forward = ff, skip = skip, span = {-reach, -reach, reach, reach}},
			light = index, face = SHADOW_SPOT_FACE, weight = share,
		}
		count^ += 1
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
		if weight == 0 || count^ >= SHADOW_MAPS_MAX {continue}
		fr, fu, ff := shadow_face_axes(u32(f))
		wants[count^] = {
			m = {origin = c, near = light_near, right = fr, far = range, up = fu, forward = ff, skip = skip, span = {-1, -1, 1, 1}},
			light = index, face = u32(f), weight = share * weight / total,
		}
		count^ += 1
	}
}

// The cascades of the sun: a slice of the view each, in a square around its
// sphere, moved by whole texels so that the shadows do not crawl as the eye
// moves, and reaching to the scene towards the sun. Its depths go by steps
// of its radius and it keeps the reach the cache holds, so that a cascade the
// eye does not move a texel across stays the same map and keeps what it holds.
@(private)
shadow_sun_cascades :: proc(wants: ^[SHADOW_MAPS_MAX]Shadow_Want, count: ^int, toward: Vec3, eye, forward, right, up: Vec3, tan_x, tan_y, near, camera_far: f32, scene_low, scene_high: Vec3, has_bounds: bool, held: []Shadow_Held) {
	axis := -linalg.normalize(toward)
	reference := Vec3{0, 1, 0} if abs(axis.y) < 0.99 else Vec3{1, 0, 0}
	sr := linalg.normalize(linalg.cross(reference, axis))
	su := linalg.cross(axis, sr)
	ends := SHADOW_SUN_CASCADES
	sides := SHADOW_SUN_SIDES
	// No farther than the farthest the scene reaches from the eye: past it no
	// cascade holds anything.
	extent := f32(math.F32_MAX)
	if has_bounds {
		extent = 0
		for i in 0 ..< 8 {
			corner := Vec3{scene_high.x if i & 1 != 0 else scene_low.x, scene_high.y if i & 2 != 0 else scene_low.y, scene_high.z if i & 4 != 0 else scene_low.z}
			extent = max(extent, linalg.length(corner - eye))
		}
	}
	from := near
	for end, k in ends {
		to := end if camera_far <= 0 else min(end, camera_far)
		// Ended by the reach of the scene, a cascade keeps the end the cache
		// holds while the scene reaches within a hundredth short of it.
		if extent < to {
			last := to
			to = extent
			for h in held {if h.light == -1 && h.face == u32(k) && h.end >= extent && h.end <= min(extent * 1.01, last) {to = h.end}}
		}
		if to <= from || count^ >= SHADOW_MAPS_MAX {break}
		// The sphere of the slice from the eye, its radius by steps of a 4096th
		// of an octave, so that turning the eye leaves it the same.
		corners: [8]Vec3
		for i in 0 ..< 8 {
			z := from if i < 4 else to
			sx := f32(-1) if i & 1 == 0 else 1
			sy := f32(-1) if i & 2 == 0 else 1
			corners[i] = forward * z + right * (sx * tan_x * z) + up * (sy * tan_y * z)
		}
		middle: Vec3
		for p in corners {middle += p / 8}
		radius: f32
		for p in corners {radius = max(radius, linalg.length(p - middle))}
		radius = math.pow(2, math.ceil(math.log2(max(radius, 1e-3)) * 4096) / 4096)
		center := eye + middle
		for &p in corners {p += eye}
		texel := 2 * radius / f32(sides[k])
		grid := [3]i32{i32(math.floor(linalg.dot(center, sr) / texel)), i32(math.floor(linalg.dot(center, su) / texel)), i32(math.floor(linalg.dot(center, axis) / radius))}
		cx, cy := f32(grid.x) * texel, f32(grid.y) * texel
		// From a point of its own along the light, by steps of the radius: the
		// slice, with what lies a radius beyond it, spans from a radius before
		// that point to two after it (CASCADE_FAR radii), and its casters from the
		// scene towards the sun. The point the cache holds stays while the slice
		// does so.
		CASCADE_FAR :: 4
		at := linalg.dot(center, axis)
		for h in held {
			if h.light == -1 && h.face == u32(k) && h.m.far == CASCADE_FAR * radius && at >= f32(h.grid.z - 1) * radius && at <= f32(h.grid.z + 2) * radius {grid.z = h.grid.z}
		}
		along := f32(grid.z) * radius
		lo := -3 * radius
		if has_bounds {
			for i in 0 ..< 8 {
				p := Vec3{scene_high.x if i & 1 != 0 else scene_low.x, scene_high.y if i & 2 != 0 else scene_low.y, scene_high.z if i & 4 != 0 else scene_low.z}
				lo = min(lo, math.floor((linalg.dot(p, axis) - 1 - along) / radius) * radius)
			}
		}
		// A whole texel of the grid of the light across it: what the map
		// measures stays small however far from the origin the view is.
		origin := sr * cx + su * cy + axis * along
		wants[count^] = {
			m = {origin = origin, right = sr, up = su, forward = axis, near = lo, far = CASCADE_FAR * radius, skip = lo, kind = SHADOW_MAP_ORTHOGRAPHIC, span = {-radius, -radius, radius, radius}},
			light = -1, face = u32(k), weight = 1, side = sides[k], grid = grid, end = to,
		}
		count^ += 1
		from = to
	}
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

// What changed for the shadows this frame (Renderer.frame_occluders), given
// to the cache of every view as what it draws again: an instance that changes
// for the first time in a while changes what stays where it was and is; one
// that changes again moves, and leaves what stays once; one that stopped
// moving for SHADOW_MOVER_FRAMES joins it again where it is; and the meshes
// whose pages changed. Once a frame that draws the scene, after its pages.
@(private)
shadow_movers_update :: proc(r: ^Renderer) {
	m := &r.shadow_movers
	o := &r.frame_occluders
	s := &r.scene
	stale := Occluder_Changes{covers = o.covers}
	for box in s.paged.boxes[:s.paged.count] {occluder_add(&stale, OCCLUDERS_MANY, box.low, box.high)}
	s.paged = {}
	for box in o.boxes[:o.count] {
		tracked := -1
		if box.instance != OCCLUDERS_MANY {
			for mover, k in m.tracked[:m.count] {if mover.instance == box.instance {tracked = k;break}}
		}
		if tracked >= 0 {
			mover := &m.tracked[tracked]
			mover.frame = r.frame
			if mover.moving {continue}
			mover.moving = true
		} else if box.instance != OCCLUDERS_MANY && m.count < SHADOW_MOVERS_MAX {
			m.tracked[m.count] = {instance = box.instance, frame = r.frame}
			m.count += 1
		}
		occluder_add(&stale, box.instance, box.low, box.high)
	}
	for k := 0; k < m.count; {
		mover := m.tracked[k]
		if r.frame - mover.frame < SHADOW_MOVER_FRAMES {k += 1;continue}
		if mover.moving && int(mover.instance) < len(s.instances) {
			inst := s.instances[mover.instance]
			if inst.meta.w & (INSTANCE_FLAG_HIDDEN | INSTANCE_FLAG_BLENDED) == 0 {occluder_add(&stale, mover.instance, inst.bounds_min.xyz, inst.bounds_max.xyz)}
		}
		m.tracked[k] = m.tracked[m.count - 1]
		m.count -= 1
	}
	if stale.count == 0 && !stale.covers {return}
	give :: proc "contextless" (to, from: ^Occluder_Changes) {
		to.covers ||= from.covers
		for box in from.boxes[:from.count] {occluder_add(to, box.instance, box.low, box.high)}
	}
	give(&r.main.targets.shadow_raster.stale, &stale)
	for &view in r.views {give(&view.targets.shadow_raster.stale, &stale)}
	for &view in r.texture_views {if view.texture != 0 {give(&view.targets.shadow_raster.stale, &stale)}}
}

// The maps of this frame and what a frame draws of them.
@(private)
Shadow_Plan :: struct {
	using shadow: Shadow_Maps,
	jobs:         u32, // what the cache draws again: windows of maps, two words each from word jobs_list
	jobs_list:    u32,
	all_list:     u32, // a job of each whole map, from this word
	cleared:      u32, // the squares the cache clears, a word each from word squares_list
	shifted:      u32, // and after them those whose texels move with their map
	squares_list: u32,
	moving:       bool, // what moves reaches a map
	movers:       u32, // words of the bits of the instances that move
	bits:         rhi.Transient,
}

// The maps of this frame: which lights, their faces and the sun, the square
// of the atlas of each, kept from the frame before where the cache holds the
// same map, and which of them the cache draws again; written to a buffer of
// this frame. fresh: the cache holds nothing it can keep.
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
	lights := len(s.lights)
	// The lights that light most of the view, the most first.
	chosen: [SHADOW_RASTER_LIGHTS]int
	shares: [SHADOW_RASTER_LIGHTS]f32
	picked := 0
	was :: proc(b: ^Shadow_Raster, light: int) -> bool {
		for k in b.raster[:b.rastered] {if int(k) == light {return true}}
		return false
	}
	for light, i in s.lights {
		if orthographic {break}
		// A light turned off or with no place casts no shadow and takes no room of the atlas.
		if !light_placed(light) || !(light.color_intensity.w > 0) || !(max(light.color_intensity.x, light.color_intensity.y, light.color_intensity.z) > 0) {continue}
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
	b.rastered = 0
	wants: [SHADOW_MAPS_MAX]Shadow_Want
	count := 0
	sun := s.sun
	if sun.enabled && r.settings.sun_shadows && !orthographic {
		shadow_sun_cascades(&wants, &count, sun.direction, eye, forward, right, up, tan_x, tan_y, near, camera.far, s.bounds_min, s.bounds_max, s.has_bounds, nil if fresh else b.held[:b.held_count])
	}
	suns := count
	for k in 0 ..< picked {
		shadow_light_faces(&wants, &count, s.lights[chosen[k]], chosen[k], shares[k], eye, forward, right, up, tan_x, tan_y, near, s.bounds_min, s.bounds_max, s.has_bounds)
	}
	if count == 0 {
		b.held_count = 0
		return plan, true
	}
	// The map the cache holds that a want is: the same light and face (of the
	// sun, cascade).
	held_of :: proc(b: ^Shadow_Raster, w: Shadow_Want) -> ^Shadow_Held {
		for &h in b.held[:b.held_count] {if h.light == w.light && h.face == w.face {return &h}}
		return nil
	}
	// The atlas left after the sun, shared by how much of the view each map
	// serves, no more than its points need; a map keeps the side it was held
	// at while what it would take stays within a quarter of a step of it.
	pixels := f32(t.width * t.height)
	left := f32(SHADOW_ATLAS * SHADOW_ATLAS)
	for w in wants[:suns] {left -= f32(w.side * w.side)}
	weights: f32
	for w in wants[suns:count] {weights += w.weight}
	side_of :: proc(texels: f32) -> u32 {
		side := SHADOW_MAP_SMALLEST
		for side * 2 <= min(u32(math.sqrt(max(texels, 0))), SHADOW_MAP_LARGEST) {side *= 2}
		return side
	}
	for &w in wants[suns:count] {
		texels := min(max(left, 0) * w.weight / max(weights, 1e-6), 2 * w.weight * pixels)
		w.side = side_of(texels)
		if h := held_of(b, w); h != nil && h.m.rect.z >= side_of(texels / 1.5625) && h.m.rect.z <= side_of(texels * 1.5625) {w.side = h.m.rect.z}
	}
	// The sun moved by whole texels of its side.
	snap :: proc(w: ^Shadow_Want) {
		radius := 0.5 * (w.m.span.z - w.m.span.x)
		texel := 2 * radius / f32(w.side)
		w.m.span.x = math.floor(-radius / texel) * texel
		w.m.span.y = math.floor(-radius / texel) * texel
		w.m.span.z = w.m.span.x + texel * f32(w.side)
		w.m.span.w = w.m.span.y + texel * f32(w.side)
	}
	for &w in wants[:suns] {snap(&w)}
	for &w in wants[:count] {w.m.rect = {0, 0, w.side, u32(w.light) if w.light >= 0 else max(u32)}}
	// Squares of whole blocks of the smallest side along a Z order fill the
	// atlas without gaps: a map the cache holds the same keeps its square, the
	// others take free ones, the largest first; a map that does not fit halves
	// until it does, else its points trace rays. A cascade the eye moved by
	// whole texels across the light, less than half its side, keeps its square
	// too: what it held moves with it, and it draws only what came into it.
	BLOCKS :: (SHADOW_ATLAS / SHADOW_MAP_SMALLEST) * (SHADOW_ATLAS / SHADOW_MAP_SMALLEST)
	taken: [BLOCKS]bool
	same: [SHADOW_MAPS_MAX]bool
	moved: [SHADOW_MAPS_MAX][2]i32
	blocks :: proc(side: u32) -> u32 {return (side / SHADOW_MAP_SMALLEST) * (side / SHADOW_MAP_SMALLEST)}
	if !fresh {
		for &w, i in wants[:count] {
			h := held_of(b, w)
			if h == nil {continue}
			wanted := w.m
			wanted.rect.xy = h.m.rect.xy
			shift := [2]i32{w.grid.x - h.grid.x, w.grid.y - h.grid.y}
			if w.light < 0 {
				reach := i32(w.side / 2)
				if w.grid.z != h.grid.z || abs(shift.x) >= reach || abs(shift.y) >= reach {continue}
				wanted.origin = h.m.origin
			}
			if wanted != h.m {continue}
			w.m.rect.xy = h.m.rect.xy
			w.placed, same[i], moved[i] = true, true, shift
			at: u32
			for bit in u32(0) ..< 16 {at |= ((h.m.rect.x / SHADOW_MAP_SMALLEST >> bit) & 1) << (2 * bit) | ((h.m.rect.y / SHADOW_MAP_SMALLEST >> bit) & 1) << (2 * bit + 1)}
			for k in at ..< at + blocks(w.side) {taken[k] = true}
		}
	}
	order: [SHADOW_MAPS_MAX]int
	for i in 0 ..< count {order[i] = i}
	for i in 1 ..< count {
		for j := i; j > 0 && wants[order[j]].side > wants[order[j - 1]].side; j -= 1 {order[j], order[j - 1] = order[j - 1], order[j]}
	}
	for i in 0 ..< count {
		w := &wants[order[i]]
		if w.placed {continue}
		place: for {
			n := blocks(w.side)
			for at := u32(0); at + n <= BLOCKS; at += n {
				free := true
				for k in at ..< at + n {if taken[k] {free = false;break}}
				if !free {continue}
				for k in at ..< at + n {taken[k] = true}
				x, y: u32
				for bit in u32(0) ..< 16 {
					x |= ((at >> (2 * bit)) & 1) << bit
					y |= ((at >> (2 * bit + 1)) & 1) << bit
				}
				w.m.rect.xyz = {x * SHADOW_MAP_SMALLEST, y * SHADOW_MAP_SMALLEST, w.side}
				w.placed = true
				break place
			}
			if w.side <= SHADOW_MAP_SMALLEST {break}
			w.side /= 2
			if w.light < 0 {snap(w)}
		}
	}
	// What the cache holds the same and in which nothing that stays changed
	// it keeps; the others it draws again this frame.
	stale := &b.stale
	redraw: [SHADOW_MAPS_MAX]bool
	for w, i in wants[:count] {
		if !w.placed {continue}
		redraw[i] = !same[i] || stale.covers
		for box in stale.boxes[:stale.count] {
			if redraw[i] {break}
			redraw[i] = shadow_map_reaches(w.m, box.low, box.high)
		}
	}
	b.stale = {}
	// The bits of the instances that move, and whether one reaches a map.
	movers := &r.shadow_movers
	last := -1
	for mover in movers.tracked[:movers.count] {if mover.moving {last = max(last, int(mover.instance))}}
	if last >= 0 {
		plan.movers = u32(last / 32 + 1)
		bits, data := rhi.frame_alloc_typed(r.device, u32, int(plan.movers))
		if bits == nil {set_error(r, "transient ring exhausted with the bits of %d instances", last + 1); return plan, false}
		for &word in bits {word = 0}
		for mover in movers.tracked[:movers.count] {
			if !mover.moving {continue}
			bits[mover.instance / 32] |= 1 << (mover.instance % 32)
			if plan.moving || int(mover.instance) >= len(s.instances) {continue}
			inst := s.instances[mover.instance]
			if inst.meta.w & (INSTANCE_FLAG_HIDDEN | INSTANCE_FLAG_BLENDED) != 0 {continue}
			for w in wants[:count] {
				if w.placed && shadow_map_reaches(w.m, inst.bounds_min.xyz, inst.bounds_max.xyz) {plan.moving = true;break}
			}
		}
		plan.bits = data
	}
	// The buffer of this frame: a word for each light of the scene, then the
	// maps placed, those of a light together in the order of its faces, then
	// the jobs of what stays, a job of each whole map, and the squares the
	// cache clears and those whose texels move.
	all_lights := u32(lights + light_region_lights(s.light_region))
	plan.rows = (all_lights + 3) / 4
	placed := 0
	for w in wants[:count] {if w.placed {placed += 1}}
	tail := (2 * (2 * placed) + 2 * placed + placed + 3) / 4 * 4
	words, data := rhi.frame_alloc_typed(r.device, u32, int(plan.rows) * 4 + placed * SHADOW_MAP_ROWS * 4 + tail)
	if words == nil {set_error(r, "transient ring exhausted with %d shadow maps", placed); return plan, false}
	for &word in words {word = 0}
	plan.jobs_list = plan.rows * 4 + u32(placed * SHADOW_MAP_ROWS * 4)
	plan.all_list = plan.jobs_list + u32(2 * 2 * placed)
	plan.squares_list = plan.all_list + u32(2 * placed)
	job :: proc(words: []u32, list: u32, n: ^u32, map_index, x0, y0, x1, y1: u32) {
		words[list + 2 * n^] = map_index | x0 << 8 | y0 << 20
		words[list + 2 * n^ + 1] = x1 | y1 << 16
		n^ += 1
	}
	square :: proc(map_index: u32, shift: [2]i32) -> u32 {return map_index | u32(shift.x + 2048) << 8 | u32(shift.y + 2048) << 20}
	redraws: u32
	for w, i in wants[:count] {if w.placed && redraw[i] {redraws += 1}}
	b.held_count = 0
	at := u32(0)
	for w, i in wants[:count] {
		if !w.placed {continue}
		if w.light < 0 {
			if plan.sun == max(u32) {plan.sun = at}
			plan.sun += 1 << 16
		} else {
			word := &words[w.light]
			if word^ == 0 {word^ = at + 1}
			if word^ >> SHADOW_LIGHT_FACES == 0 && b.rastered < SHADOW_RASTER_LIGHTS {
				b.raster[b.rastered] = i32(w.light)
				b.rastered += 1
			}
			word^ |= 1 << (SHADOW_LIGHT_FACES + w.face)
		}
		(cast(^Gpu_Shadow_Map)&words[plan.rows * 4 + at * SHADOW_MAP_ROWS * 4])^ = w.m
		side := w.side
		dx, dy := moved[i].x, moved[i].y
		if redraw[i] {
			job(words, plan.jobs_list, &plan.jobs, at, 0, 0, side, side)
			words[plan.squares_list + plan.cleared] = square(at, {})
			plan.cleared += 1
		} else if moved[i] != {} {
			// What came in: the columns past those it held and the rows above or below them.
			if dx > 0 {job(words, plan.jobs_list, &plan.jobs, at, side - u32(dx), 0, side, side)}
			if dx < 0 {job(words, plan.jobs_list, &plan.jobs, at, 0, 0, u32(-dx), side)}
			if dy > 0 {job(words, plan.jobs_list, &plan.jobs, at, 0, 0, side, u32(dy))}
			if dy < 0 {job(words, plan.jobs_list, &plan.jobs, at, 0, side - u32(-dy), side, side)}
			words[plan.squares_list + redraws + plan.shifted] = square(at, moved[i])
			plan.shifted += 1
		}
		all := plan.all_list
		n := at
		job(words, all, &n, at, 0, 0, side, side)
		b.held[b.held_count] = {m = w.m, light = w.light, face = w.face, grid = w.grid, end = w.end}
		b.held_count += 1
		at += 1
	}
	plan.maps = at
	plan.on = 1 if at > 0 else 0
	b.data = data
	return plan, true
}

// shadow_cull.slang Params_Block.
@(private)
Shadow_Params :: struct {instances, maps, rows, glass, chunk_capacity, entry_capacity, list, moving, movers, pad0, pad1, pad2: u32}

// The parameters of a round of the maps: the casters that stay into the jobs
// of a list, or those that move and the glass into all the maps, of which
// the instances of batches are none: they never move, and one of glass casts
// nothing.
@(private)
shadow_params :: proc(p: ^Pass, plan: Shadow_Plan, list, maps: u32, moving, glass: bool) -> Shadow_Params {
	s := &p.r.scene
	return {
		instances = p.instance_count if moving else p.instance_count + p.batch_slots, maps = maps, rows = plan.rows, glass = 1 if glass else 0, list = list,
		chunk_capacity = s.cull_capacity[.Shadow_Chunks], entry_capacity = s.cull_capacity[.Shadow_Entries],
		moving = 1 if moving else 0, movers = plan.movers,
	}
}

// The cull of a round and what it hands to its draws.
@(private)
shadow_cull :: proc(p: ^Pass, plan: Shadow_Plan, params: Shadow_Params) {
	r, cmd := p.r, p.cmd
	s := &r.scene
	d := &r.shadow_buffers
	params := params
	start, start_at := rhi.frame_alloc_typed(r.device, Gpu_Shadow_State, 1)
	if start == nil {return}
	start[0] = {draws = {{vertex_count = CLUSTER_DRAW_VERTICES}, {vertex_count = CLUSTER_DRAW_VERTICES}, {vertex_count = CLUSTER_DRAW_VERTICES}}, cluster_dispatch = {0, 0, 1}}
	rhi.cmd_copy_buffer(cmd, start_at.buffer, start_at.offset, d.state, 0, size_of(Gpu_Shadow_State))
	// By instance and map, then by cluster over the chunks, as the cull of the view.
	for pipeline in ([2]Pipeline_Id{.Shadow_Maps, .Shadow_Clusters}) {
		rhi.cmd_bind_pipeline(cmd, r.pipelines[pipeline])
		set_params(cmd, &params)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS0, d.table)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS1, s.shadow_chunks)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS2, d.state)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS3, r.stats_buffer)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS4, s.shadow_entries)
		if pipeline == .Shadow_Maps {
			if plan.movers > 0 {rhi.cmd_bind_transient(cmd, SLOT_PASS5, plan.bits)} else {rhi.cmd_bind_buffer(cmd, SLOT_PASS5, r.dummy_buffer)}
			rhi.cmd_dispatch(cmd, groups(params.instances, SHADOW_GROUP), params.maps)
		} else {
			rhi.cmd_dispatch_indirect(cmd, d.state, u64(offset_of(Gpu_Shadow_State, cluster_dispatch)))
		}
	}
}

// The depth a round culled into an atlas: the clusters that hide whole and
// those of masked materials. Of the cache, first the squares it clears and
// those whose texels move, from what held holds (a copy of it).
@(private)
shadow_draw :: proc(p: ^Pass, plan: Shadow_Plan, params: Shadow_Params, atlas: rhi.Texture, name: string, cache := false, held: rhi.Texture = 0) {
	r, cmd := p.r, p.cmd
	s := &r.scene
	d := &r.shadow_buffers
	params := params
	params.glass = 0
	pass := rhi.Render_Pass_Desc{name = name}
	pass.depth = {texture = atlas, load = .Load, store = .Store}
	rhi.cmd_begin_render_pass(cmd, &pass)
	squares := [2]struct {pipeline: Pipeline_Id, first, count: u32}{{.Shadow_Map_Clear, 0, plan.cleared}, {.Shadow_Map_Moved, plan.cleared, plan.shifted}}
	for kind in squares {
		if !cache || kind.count == 0 {continue}
		square := params
		square.list, square.maps = plan.squares_list + kind.first, kind.count
		rhi.cmd_bind_pipeline(cmd, r.pipelines[kind.pipeline])
		set_params(cmd, &square)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS0, s.shadow_entries)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS1, d.table)
		rhi.cmd_bind_texture(cmd, SLOT_PASS2, held if held != 0 else r.dummy_texture)
		rhi.cmd_draw(cmd, 6, kind.count)
	}
	for pipeline, i in ([2]Pipeline_Id{.Shadow_Map, .Shadow_Map_Tested}) {
		rhi.cmd_bind_pipeline(cmd, r.pipelines[pipeline])
		set_params(cmd, &params)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS0, s.shadow_entries)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS1, d.table)
		rhi.cmd_draw_indirect(cmd, d.state, u64(i) * size_of(Gpu_Draw), 1)
	}
	rhi.cmd_end_render_pass(cmd)
}

@(private)
shadow_maps_pass :: proc(p: ^Pass) -> (maps: Shadow_Maps) {
	r, cmd, t := p.r, p.cmd, p.t
	s := &r.scene
	maps.sun = max(u32)
	if !p.draw {return}
	b, d := &t.shadow_raster, &r.shadow_buffers
	// The cache holds nothing it can keep when it is new or the cut changed.
	fresh := b.cache == 0 || b.cut != r.settings.lod_error_pixels
	plan, ok := shadow_maps_plan(p, fresh)
	if !ok || plan.on == 0 {return}
	good := target(r, cmd, &b.cache, SHADOW_ATLAS, SHADOW_ATLAS, .D32_Float, {.Depth_Target, .Sampled, .Transfer_Src}, "shadow cache")
	state_ok, _ := ensure_buffer(r, &d.state, size_of(Gpu_Shadow_State), {.Storage, .Indirect, .Transfer_Dst}, "shadow map state")
	table_ok, _ := ensure_buffer(r, &d.table, b.data.size, {.Storage, .Transfer_Dst}, "shadow maps")
	if !good || !state_ok || !table_ok || s.shadow_chunks == 0 || s.shadow_entries == 0 {
		b.held_count = 0
		return
	}
	b.cut = r.settings.lod_error_pixels
	// While glass colors light: what the glass in front of the depth of each texel lets through, and the
	// depth of the nearest glass (shadow_tint of shadow_maps.slang).
	tinted := r.settings.colored_shadows && len(s.translucent) > 0
	if tinted {
		tint_ok := target(r, cmd, &t.shadow_tint, SHADOW_ATLAS, SHADOW_ATLAS, .RGBA8_Unorm, {.Color_Target, .Sampled}, "shadow tint", shared = true)
		glass_ok := target(r, cmd, &t.shadow_glass, SHADOW_ATLAS, SHADOW_ATLAS, .D32_Float, {.Depth_Target, .Sampled}, "shadow glass", shared = true)
		tinted = tint_ok && glass_ok
	}
	if (plan.moving || plan.shifted > 0) && !target(r, cmd, &t.shadow_atlas, SHADOW_ATLAS, SHADOW_ATLAS, .D32_Float, {.Depth_Target, .Sampled, .Transfer_Dst}, "shadow atlas", shared = true) {
		b.held_count = 0
		return
	}
	rhi.cmd_copy_buffer(cmd, b.data.buffer, b.data.offset, d.table, 0, b.data.size)
	// What stays, into the windows of the maps the cache draws again; the
	// atlas of the frame holds what the cache held while its texels move.
	if plan.jobs > 0 {
		params := shadow_params(p, plan, plan.jobs_list, plan.jobs, false, false)
		rhi.cmd_timestamp(cmd, "shadow cull")
		shadow_cull(p, plan, params)
		rhi.cmd_timestamp(cmd, "shadow cache")
		if plan.shifted > 0 {rhi.cmd_copy_texture(cmd, b.cache, t.shadow_atlas)}
		shadow_draw(p, plan, params, b.cache, "shadow cache", cache = true, held = t.shadow_atlas if plan.shifted > 0 else 0)
	}
	// What moves, over a copy of the cache, and the glass.
	b.atlas = b.cache
	params := shadow_params(p, plan, plan.all_list, plan.maps, true, tinted)
	if plan.moving || tinted {
		rhi.cmd_timestamp(cmd, "shadow cull moving")
		shadow_cull(p, plan, params)
	}
	if plan.moving {
		rhi.cmd_timestamp(cmd, "shadow atlas")
		rhi.cmd_copy_texture(cmd, b.cache, t.shadow_atlas)
		shadow_draw(p, plan, params, t.shadow_atlas, "shadow atlas")
		b.atlas = t.shadow_atlas
	}
	if tinted {
		rhi.cmd_timestamp(cmd, "shadow tint")
		tint := rhi.Render_Pass_Desc{name = "shadow tint", color_count = 1}
		tint.colors[0] = {texture = t.shadow_tint, load = .Clear, store = .Store, clear = {1, 1, 1, 1}}
		tint.depth = {texture = b.atlas, load = .Load, store = .Store}
		nearest := rhi.Render_Pass_Desc{name = "shadow glass"}
		nearest.depth = {texture = t.shadow_glass, load = .Clear, store = .Store, clear = 0}
		passes := [2]rhi.Render_Pass_Desc{tint, nearest}
		for &desc, i in passes {
			rhi.cmd_begin_render_pass(cmd, &desc)
			rhi.cmd_bind_pipeline(cmd, r.pipelines[.Shadow_Map_Tint if i == 0 else .Shadow_Map_Glass])
			set_params(cmd, &params)
			rhi.cmd_bind_buffer(cmd, SLOT_PASS0, s.shadow_entries)
			rhi.cmd_bind_buffer(cmd, SLOT_PASS1, d.table)
			rhi.cmd_draw_indirect(cmd, d.state, 2 * size_of(Gpu_Draw), 1)
			rhi.cmd_end_render_pass(cmd)
		}
	}
	// What the passes after this one read of the maps (sun_shadow_seen, media.slang): the constants of
	// the view are read when the frame runs.
	count := 0
	if plan.sun != max(u32) {
		first := int(plan.sun & 0xFFFF)
		count = min(int(plan.sun >> 16), len(SHADOW_SUN_CASCADES))
		rows := ([^][4]u32)(b.data.ptr)[int(plan.rows) + first * SHADOW_MAP_ROWS:][:count * SHADOW_MAP_ROWS]
		copy(p.frame.sun_map_rows[:], rows)
	}
	p.frame.sun_maps = {u32(count), plan.rows, SHADOW_ATLAS, 1 if tinted else 0}
	constants := (^Gpu_Frame)(p.constants.ptr)
	constants.sun_maps, constants.sun_map_rows = p.frame.sun_maps, p.frame.sun_map_rows
	return plan.shadow
}

@(private)
destroy_shadow_maps :: proc(r: ^Renderer, t: ^Targets) {
	shared_targets_release(r, targets_frame(&t.shadow_targets))
	if t.shadow_raster.cache != 0 {rhi.texture_destroy(r.device, t.shadow_raster.cache)}
	t.shadow_raster = {}
}
