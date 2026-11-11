package mirai_render

import "core:math"
import "core:math/linalg"
import "mirai:render/abi"
import "mirai:rhi"

// Shadow maps in place of the rays of the direct light for the lights that
// light much of the view and for the sun (Settings.shadow_maps), drawn again
// every frame: the cost of a frame is the same whatever moves. Each frame,
// from the camera and the lights alone, the lights whose sphere covers
// SHADOW_RASTER_SHARE of the view (and keep SHADOW_RASTER_KEEP once they do)
// take a map for each face of the cube around them through which they light
// what the view sees, fitted to it, and the sun one for each cascade of the
// view; the atlas is shared among them by how much of the view each lights.
// The other lights, small on the screen, trace rays (shadow_maps.slang,
// shadow_maps.comp, shadow_map.vert, direct_samples.comp).
// The side of the atlas of the maps of a view, texels.
SHADOW_ATLAS :: u32(4096)
SHADOW_MAPS_MAX :: 96
SHADOW_MAP_ROWS :: abi.SHADOW_MAP_ROWS
SHADOW_ENTRIES :: abi.SHADOW_ENTRIES
SHADOW_DRAWS :: 2 // the clusters that hide whole, and those of masked or blended materials
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

// What the maps of a view keep: the buffers they are drawn from, and which
// lights were rasterized the frame before (the margin between SHADOW_RASTER_KEEP
// and SHADOW_RASTER_SHARE keeps a light from going back and forth).
Shadow_Buffers :: struct {
	entries, draw: rhi.Buffer,
	table:         rhi.Buffer, // data copied for the passes to read
	raster:        [SHADOW_RASTER_LIGHTS]i32, // the lights rasterized the frame before
	rastered:      int,
	data:          rhi.Transient, // of this frame
}

// A map the plan wants, before it has its square of the atlas.
@(private)
Shadow_Want :: struct {
	m:      Gpu_Shadow_Map,
	light:  int, // -1: the sun
	face:   u32,
	weight: f32, // how much of the view it serves
	side:   u32,
	placed: bool,
}

// How much of the view a light lights: the share of the screen its sphere
// covers, 0 outside the frustum.
@(private)
shadow_light_share :: proc(light: Gpu_Light, eye, forward: Vec3, tan_y, aspect: f32, frustum: [6]Vec4, orthographic: bool, height: f32) -> f32 {
	c, range := light.position_range.xyz, light.position_range.w
	if range <= 0 {return 0}
	for plane in frustum {if linalg.dot(plane.xyz, c) + plane.w < -range {return 0}}
	if orthographic {
		r := range / max(0.5 * height, 1e-3)
		return min(math.PI * r * r / (4 * aspect), 1)
	}
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
// sees, each fitted to the points of the view it lights: points spread over
// the part of the view its sphere covers, at the depths it spans.
@(private)
shadow_light_faces :: proc(wants: ^[SHADOW_MAPS_MAX]Shadow_Want, count: ^int, light: Gpu_Light, index: int, share: f32, eye, forward, right, up: Vec3, tan_x, tan_y, near: f32) {
	ACROSS :: 7
	DEPTHS :: 5
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
	bounds: [6]Vec4 // low x, low y, high x, high y of x / z, y / z
	far: [6]f32
	hits: [6]int
	for f in 0 ..< 6 {bounds[f] = {1, 1, -1, -1}}
	total := 0
	for k in 0 ..< DEPTHS {
		z := z0 + (z1 - z0) * f32(k) / f32(DEPTHS - 1)
		for j in 0 ..< ACROSS {
			for i in 0 ..< ACROSS {
				s := Vec2{low.x + (high.x - low.x) * f32(i) / f32(ACROSS - 1), low.y + (high.y - low.y) * f32(j) / f32(ACROSS - 1)}
				point := eye + forward * z + right * (s.x * tan_x * z) + up * (s.y * tan_y * z)
				v := point - c
				distance := linalg.length(v)
				if distance > range || distance < 1e-4 {continue}
				if spot && linalg.dot(v / distance, light.direction_cone.xyz) < light.direction_cone.w - 0.05 {continue}
				if rect && linalg.dot(v, light.direction_cone.xyz) < 0 {continue}
				f := shadow_face_of(v)
				fr, fu, ff := shadow_face_axes(f)
				lz := max(linalg.dot(v, ff), light_near)
				at := Vec2{clamp(linalg.dot(v, fr) / lz, -1, 1), clamp(linalg.dot(v, fu) / lz, -1, 1)}
				bounds[f] = {min(bounds[f].x, at.x), min(bounds[f].y, at.y), max(bounds[f].z, at.x), max(bounds[f].w, at.y)}
				far[f] = max(far[f], lz)
				hits[f] += 1
				total += 1
			}
		}
	}
	if total == 0 {return}
	for f in 0 ..< 6 {
		if hits[f] == 0 || count^ >= SHADOW_MAPS_MAX {continue}
		// A step of the grid of points around those that fell on it: what lies
		// between them, and the taps of the soft shadows past the last.
		b := bounds[f]
		grow := max(0.25 * max(b.z - b.x, b.w - b.y), 0.1)
		span := Vec4{max(b.x - grow, -1), max(b.y - grow, -1), min(b.z + grow, 1), min(b.w + grow, 1)}
		fr, fu, ff := shadow_face_axes(u32(f))
		wants[count^] = {
			m = {origin = c, near = light_near, right = fr, far = min(range, far[f] * 1.25 + 0.1), up = fu, forward = ff, skip = skip, span = span},
			light = index, face = u32(f), weight = share * f32(hits[f]) / f32(total),
		}
		count^ += 1
	}
}

// The cascades of the sun: a slice of the view each, in a square around its
// sphere, moved by whole texels so that the shadows do not crawl as the eye
// moves, and reaching to the scene towards the sun.
@(private)
shadow_sun_cascades :: proc(wants: ^[SHADOW_MAPS_MAX]Shadow_Want, count: ^int, toward: Vec3, eye, forward, right, up: Vec3, tan_x, tan_y, near, camera_far: f32, scene_low, scene_high: Vec3, has_bounds: bool) {
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
		to = min(to, extent)
		if to <= from || count^ >= SHADOW_MAPS_MAX {break}
		corners: [8]Vec3
		for i in 0 ..< 8 {
			z := from if i < 4 else to
			sx := f32(-1) if i & 1 == 0 else 1
			sy := f32(-1) if i & 2 == 0 else 1
			corners[i] = eye + forward * z + right * (sx * tan_x * z) + up * (sy * tan_y * z)
		}
		center: Vec3
		for p in corners {center += p / 8}
		radius: f32
		for p in corners {radius = max(radius, linalg.length(p - center))}
		texel := 2 * radius / f32(sides[k])
		cx := math.floor(linalg.dot(center, sr) / texel) * texel
		cy := math.floor(linalg.dot(center, su) / texel) * texel
		lo, hi := f32(math.F32_MAX), f32(-math.F32_MAX)
		for p in corners {
			z := linalg.dot(p, axis)
			lo, hi = min(lo, z - radius), max(hi, z + radius)
		}
		if has_bounds {
			for i in 0 ..< 8 {
				p := Vec3{scene_high.x if i & 1 != 0 else scene_low.x, scene_high.y if i & 2 != 0 else scene_low.y, scene_high.z if i & 4 != 0 else scene_low.z}
				lo = min(lo, linalg.dot(p, axis) - 1)
			}
		}
		// From a point of its own, a whole texel of the grid of the light: what the map
		// measures stays small however far from the origin the view is.
		origin := sr * cx + su * cy + axis * linalg.dot(center, axis)
		along := linalg.dot(origin, axis)
		wants[count^] = {
			m = {origin = origin, right = sr, up = su, forward = axis, near = lo - along, far = hi - along, skip = lo - along, kind = SHADOW_MAP_ORTHOGRAPHIC, span = {-radius, -radius, radius, radius}},
			light = -1, weight = 1, side = sides[k],
		}
		count^ += 1
		from = to
	}
}

// The maps of this frame: which lights, their faces and the sun, and the
// square of the atlas of each; written to a buffer of this frame.
@(private)
shadow_maps_plan :: proc(p: ^Pass) -> (maps: Shadow_Maps, ok: bool) {
	r, t := p.r, p.t
	s := &r.scene
	b := &t.shadow_buffers
	maps.sun = max(u32)
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
	was :: proc(b: ^Shadow_Buffers, light: int) -> bool {
		for k in b.raster[:b.rastered] {if int(k) == light {return true}}
		return false
	}
	for light, i in s.lights {
		// A light turned off casts no shadow and takes no room of the atlas.
		if !(light.color_intensity.w > 0) || !(max(light.color_intensity.x, light.color_intensity.y, light.color_intensity.z) > 0) {continue}
		share := shadow_light_share(light, eye, forward, tan_y, aspect, p.frame.frustum, orthographic, camera.height)
		keep := SHADOW_RASTER_KEEP if was(b, i) else SHADOW_RASTER_SHARE
		if orthographic || share < keep {continue}
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
		shadow_sun_cascades(&wants, &count, sun.direction, eye, forward, right, up, tan_x, tan_y, near, camera.far, s.bounds_min, s.bounds_max, s.has_bounds)
	}
	suns := count
	for k in 0 ..< picked {
		shadow_light_faces(&wants, &count, s.lights[chosen[k]], chosen[k], shares[k], eye, forward, right, up, tan_x, tan_y, near)
	}
	if count == 0 {return maps, true}
	// The atlas left after the sun, shared by how much of the view each map
	// serves, no more than its points need.
	pixels := f32(t.width * t.height)
	left := f32(SHADOW_ATLAS * SHADOW_ATLAS)
	for w in wants[:suns] {left -= f32(w.side * w.side)}
	weights: f32
	for w in wants[suns:count] {weights += w.weight}
	for &w in wants[suns:count] {
		texels := max(left, 0) * w.weight / max(weights, 1e-6)
		needed := 2 * w.weight * pixels
		side := u32(math.sqrt(min(texels, needed)))
		w.side = SHADOW_MAP_SMALLEST
		for w.side * 2 <= min(side, SHADOW_MAP_LARGEST) {w.side *= 2}
	}
	// Squares of whole blocks of the smallest side along a Z order, the
	// largest first, fill the atlas without gaps; a map that does not fit
	// halves until it does, else its points trace rays.
	order: [SHADOW_MAPS_MAX]int
	for i in 0 ..< count {order[i] = i}
	for i in 1 ..< count {
		for j := i; j > 0 && wants[order[j]].side > wants[order[j - 1]].side; j -= 1 {order[j], order[j - 1] = order[j - 1], order[j]}
	}
	BLOCKS :: (SHADOW_ATLAS / SHADOW_MAP_SMALLEST) * (SHADOW_ATLAS / SHADOW_MAP_SMALLEST)
	cursor := u32(0)
	for i in 0 ..< count {
		w := &wants[order[i]]
		for {
			n := (w.side / SHADOW_MAP_SMALLEST) * (w.side / SHADOW_MAP_SMALLEST)
			at := (cursor + n - 1) / n * n
			if at + n <= BLOCKS {
				x, y: u32
				for bit in u32(0) ..< 16 {
					x |= ((at >> (2 * bit)) & 1) << bit
					y |= ((at >> (2 * bit + 1)) & 1) << bit
				}
				w.m.rect = {x * SHADOW_MAP_SMALLEST, y * SHADOW_MAP_SMALLEST, w.side, u32(w.light) if w.light >= 0 else max(u32)}
				w.placed = true
				cursor = at + n
				break
			}
			if w.side <= SHADOW_MAP_SMALLEST {break}
			w.side /= 2
		}
	}
	// The sun moved by whole texels of the side it got.
	for &w in wants[:suns] {
		if !w.placed {continue}
		texel := (w.m.span.z - w.m.span.x) / f32(w.side)
		w.m.span.x = math.floor(w.m.span.x / texel) * texel
		w.m.span.y = math.floor(w.m.span.y / texel) * texel
		w.m.span.z = w.m.span.x + texel * f32(w.side)
		w.m.span.w = w.m.span.y + texel * f32(w.side)
	}
	// The buffer of this frame: a word for each light of the scene, then the
	// maps placed, those of a light together in the order of its faces.
	all_lights := u32(lights + light_region_lights(s.light_region))
	maps.rows = (all_lights + 3) / 4
	placed := 0
	for w in wants[:count] {if w.placed {placed += 1}}
	words, data := rhi.frame_alloc_typed(r.device, u32, int(maps.rows) * 4 + placed * SHADOW_MAP_ROWS * 4)
	if words == nil {set_error(r, "transient ring exhausted with %d shadow maps", placed); return maps, false}
	for &word in words[:maps.rows * 4] {word = 0}
	at := 0
	for w in wants[:count] {
		if !w.placed {continue}
		if w.light < 0 {
			if maps.sun == max(u32) {maps.sun = u32(at)}
			maps.sun += 1 << 16
		} else {
			word := &words[w.light]
			if word^ == 0 {word^ = u32(at) + 1}
			if word^ >> SHADOW_LIGHT_FACES == 0 && b.rastered < SHADOW_RASTER_LIGHTS {
				b.raster[b.rastered] = i32(w.light)
				b.rastered += 1
			}
			word^ |= 1 << (SHADOW_LIGHT_FACES + w.face)
		}
		(cast(^Gpu_Shadow_Map)&words[int(maps.rows) * 4 + at * SHADOW_MAP_ROWS * 4])^ = w.m
		at += 1
	}
	maps.maps = u32(placed)
	maps.on = 1 if placed > 0 else 0
	b.data = data
	return maps, true
}

@(private)
shadow_maps_pass :: proc(p: ^Pass) -> (maps: Shadow_Maps) {
	r, cmd, t := p.r, p.cmd, p.t
	s := &r.scene
	maps.sun = max(u32)
	if !r.settings.shadow_maps || !p.draw {return}
	planned, ok := shadow_maps_plan(p)
	if !ok || planned.on == 0 {return}
	b := &t.shadow_buffers
	good := target(r, cmd, &t.shadow_atlas, SHADOW_ATLAS, SHADOW_ATLAS, .D32_Float, {.Depth_Target, .Sampled}, "shadow atlas")
	entries_ok, _ := ensure_buffer(r, &b.entries, u64(SHADOW_ENTRIES) * 16, {.Storage}, "shadow map clusters")
	draw_ok, _ := ensure_buffer(r, &b.draw, SHADOW_DRAWS * size_of(rhi.Draw_Indirect), {.Storage, .Indirect, .Transfer_Dst}, "shadow map draw")
	table_ok, _ := ensure_buffer(r, &b.table, b.data.size, {.Storage, .Transfer_Dst}, "shadow maps")
	if !good || !entries_ok || !draw_ok || !table_ok {return}
	// While glass colors light: what the glass in front of the depth of each texel lets through, and the
	// depth of the nearest glass (shadow_tint of shadow_maps.slang).
	tinted := r.settings.colored_shadows && len(s.translucent) > 0
	if tinted {
		tint_ok := target(r, cmd, &t.shadow_tint, SHADOW_ATLAS, SHADOW_ATLAS, .RGBA8_Unorm, {.Color_Target, .Sampled}, "shadow tint")
		glass_ok := target(r, cmd, &t.shadow_glass, SHADOW_ATLAS, SHADOW_ATLAS, .D32_Float, {.Depth_Target, .Sampled}, "shadow glass")
		tinted = tint_ok && glass_ok
	}
	Params :: struct {instances, maps, rows, glass: u32}
	params := Params{instances = p.instance_count + p.batch_slots, maps = planned.maps, rows = planned.rows, glass = 1 if tinted else 0}
	rhi.cmd_timestamp(cmd, "shadow cull")
	for x in ([]rhi.Buffer{s.instance_buffer, s.vertex_buffer, s.index_buffer}) {rhi.cmd_barrier_buffer(cmd, x, .Shader_Read)}
	start, start_at := rhi.frame_alloc_typed(r.device, rhi.Draw_Indirect, SHADOW_DRAWS)
	if start == nil {return}
	for &draw in start {draw = {vertex_count = CLUSTER_DRAW_VERTICES}}
	rhi.cmd_copy_buffer(cmd, start_at.buffer, start_at.offset, b.draw, 0, SHADOW_DRAWS * size_of(rhi.Draw_Indirect))
	rhi.cmd_copy_buffer(cmd, b.data.buffer, b.data.offset, b.table, 0, b.data.size)
	rhi.cmd_barrier_buffer(cmd, b.table, .Shader_Read)
	rhi.cmd_barrier_buffer(cmd, b.draw, .Shader_Write)
	rhi.cmd_barrier_buffer(cmd, b.entries, .Shader_Write)
	rhi.cmd_bind_pipeline(cmd, r.pipelines[.Shadow_Maps])
	set_params(cmd, &params)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS0, b.table)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS1, b.entries)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS2, b.draw)
	rhi.cmd_dispatch(cmd, groups(params.instances, SHADOW_GROUP), params.maps)
	rhi.cmd_timestamp(cmd, "shadow atlas")
	rhi.cmd_barrier_buffer(cmd, b.draw, .Indirect_Read)
	rhi.cmd_barrier_buffer(cmd, b.entries, .Shader_Read)
	params.glass = 0
	pass := rhi.Render_Pass_Desc{name = "shadow atlas"}
	pass.depth = {texture = t.shadow_atlas, load = .Clear, store = .Store, clear = 0}
	rhi.cmd_begin_render_pass(cmd, &pass)
	for pipeline, i in ([SHADOW_DRAWS]Pipeline_Id{.Shadow_Map, .Shadow_Map_Tested}) {
		rhi.cmd_bind_pipeline(cmd, r.pipelines[pipeline])
		set_params(cmd, &params)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS0, b.entries)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS1, b.table)
		rhi.cmd_draw_indirect(cmd, b.draw, u64(i) * size_of(rhi.Draw_Indirect), 1)
	}
	rhi.cmd_end_render_pass(cmd)
	if tinted {
		rhi.cmd_timestamp(cmd, "shadow tint")
		params.glass = 1
		tint := rhi.Render_Pass_Desc{name = "shadow tint", color_count = 1}
		tint.colors[0] = {texture = t.shadow_tint, load = .Clear, store = .Store, clear = {1, 1, 1, 1}}
		tint.depth = {texture = t.shadow_atlas, load = .Load, store = .Store}
		nearest := rhi.Render_Pass_Desc{name = "shadow glass"}
		nearest.depth = {texture = t.shadow_glass, load = .Clear, store = .Store, clear = 0}
		passes := [2]rhi.Render_Pass_Desc{tint, nearest}
		for &desc, i in passes {
			rhi.cmd_begin_render_pass(cmd, &desc)
			rhi.cmd_bind_pipeline(cmd, r.pipelines[.Shadow_Map_Tint if i == 0 else .Shadow_Map_Glass])
			set_params(cmd, &params)
			rhi.cmd_bind_buffer(cmd, SLOT_PASS0, b.entries)
			rhi.cmd_bind_buffer(cmd, SLOT_PASS1, b.table)
			rhi.cmd_draw_indirect(cmd, b.draw, size_of(rhi.Draw_Indirect), 1)
			rhi.cmd_end_render_pass(cmd)
		}
		rhi.cmd_barrier_texture(cmd, t.shadow_tint, .Shader_Read)
		rhi.cmd_barrier_texture(cmd, t.shadow_glass, .Depth_Read)
	}
	rhi.cmd_barrier_texture(cmd, t.shadow_atlas, .Depth_Read)
	// What the passes after this one read of the maps (sun_shadow_seen, media.slang): the constants of
	// the view are read when the frame runs.
	count := 0
	if planned.sun != max(u32) {
		first := int(planned.sun & 0xFFFF)
		count = min(int(planned.sun >> 16), len(SHADOW_SUN_CASCADES))
		rows := ([^][4]u32)(b.data.ptr)[int(planned.rows) + first * SHADOW_MAP_ROWS:][:count * SHADOW_MAP_ROWS]
		copy(p.frame.sun_map_rows[:], rows)
	}
	p.frame.sun_maps = {u32(count), planned.rows, SHADOW_ATLAS, 1 if tinted else 0}
	constants := (^Gpu_Frame)(p.constants.ptr)
	constants.sun_maps, constants.sun_map_rows = p.frame.sun_maps, p.frame.sun_map_rows
	return planned
}

@(private)
destroy_shadow_maps :: proc(r: ^Renderer, t: ^Targets) {
	for texture in ([3]rhi.Texture{t.shadow_atlas, t.shadow_tint, t.shadow_glass}) {if texture != 0 {rhi.texture_destroy(r.device, texture)}}
	b := &t.shadow_buffers
	for x in ([]rhi.Buffer{b.entries, b.draw, b.table}) {if x != 0 {rhi.buffer_destroy(r.device, x)}}
	t.shadow_atlas, t.shadow_tint, t.shadow_glass, t.shadow_buffers = 0, 0, 0, {}
}
