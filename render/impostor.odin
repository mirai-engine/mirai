package mirai_render

import "core:math"
import "core:math/linalg"
import "core:mem"
import "mirai:asset"
import "mirai:rhi"
import mm "mirai:std/math"

@(private = "file")
Mat3 :: matrix[3, 3]f32

// Octahedral impostors (Ryan Brucks, shaderbits 2018): images of a mesh seen
// from the directions of a grid that unfolds the upper hemisphere on a
// square, each frame a parallel view of the sphere that holds the mesh. A
// shader that draws one far away blends the three frames nearest the
// direction it is seen from, each moved by the depth it keeps.
//
// The frame (x, y) of a grid of n is seen from impostor_direction; its image
// has impostor_axes as right and up, and spans the diameter of the sphere
// across and up. A point p of the space of the mesh is at
// u = dot(p - center, right) / (2 radius) + 0.5 and
// v = 0.5 - dot(p - center, up) / (2 radius) of its frame, rows from the top,
// at depth 0.5 - dot(p - center, direction) / (2 radius): 0 where the sphere
// faces the view, 1 behind it. Frame (x, y) is the cell of column x and row y
// of the atlas.

IMPOSTOR_GRID_MAX :: 32
IMPOSTOR_SIDE_MAX :: 4096 // pixels a side of an atlas

// A mesh drawn into an impostor, where the space of the impostor puts it,
// with the materials an instance would give it.
Impostor_Part :: struct {
	mesh:           Mesh_Handle,
	placement:      Mat4,            // from the space of the mesh into that of the impostor
	material:       Material_Handle, // replaces the materials of its vertices; 0 keeps them
	slot_materials: [32]u32,         // row+1 per source slot; zero inherits
}

// The frames of an impostor: grid by grid of them, frame pixels a side each.
// color: base color in sRGB and coverage (0 or 255); normal: the normal of
// the space of the impostor as xyz * 0.5 + 0.5, and the depth along the frame.
Impostor_Images :: struct {
	grid, frame:   u32,
	center:        Vec3, // of the sphere every frame sees, in the space of the impostor
	radius:        f32,
	color, normal: []u8, // RGBA8, (grid * frame) pixels a side, rows from the top
}

// What the captures keep on the GPU from one to the next, which the renderer holds.
@(private)
Impostor_GPU :: struct {
	vertices, materials, frames: rhi.Buffer,
	color, normal, depth:        rhi.Texture,
	side:                        u32,
}

@(private)
impostor_gpu_destroy :: proc(device: ^rhi.Device, state: ^Impostor_GPU) {
	if device != nil {
		for buffer in ([]rhi.Buffer{state.vertices, state.materials, state.frames}) {if buffer != 0 {rhi.buffer_destroy(device, buffer)}}
		for texture in ([]rhi.Texture{state.color, state.normal, state.depth}) {if texture != 0 {rhi.texture_destroy(device, texture)}}
	}
	state^ = {}
}

impostor_images_destroy :: proc(images: ^Impostor_Images, allocator := context.allocator) {
	delete(images.color, allocator)
	delete(images.normal, allocator)
	images^ = {}
}

// The direction frame (x, y) of a grid of n sees the mesh from, out of its
// centre: the square of the grid, corner to corner from -1 to 1, folded on
// the upper hemisphere (y up) as an octahedron. The frames of the border look
// along the horizon.
impostor_direction :: proc "contextless" (n, x, y: u32) -> Vec3 {
	steps := f32(max(n, 2) - 1)
	e := Vec2{f32(x) / steps * 2 - 1, f32(y) / steps * 2 - 1}
	return impostor_unfold(e)
}

// A point of the square of the grid, from -1 to 1, as a direction of the
// upper hemisphere, and back.
impostor_unfold :: proc "contextless" (e: Vec2) -> Vec3 {
	p := Vec2{e.x + e.y, e.x - e.y} * 0.5
	return linalg.normalize(Vec3{p.x, 1 - abs(p.x) - abs(p.y), p.y})
}

impostor_fold :: proc "contextless" (d: Vec3) -> Vec2 {
	d := Vec3{d.x, max(d.y, 0), d.z}
	sum := abs(d.x) + d.y + abs(d.z)
	if sum < 1e-12 {return {}}
	p := Vec2{d.x, d.z} / sum
	return {p.x + p.y, p.x - p.y}
}

// The right and the up of the image of a frame seen from direction d.
impostor_axes :: proc "contextless" (d: Vec3) -> (right, up: Vec3) {
	reference := Vec3{0, 0, -1} if abs(d.y) > 0.999 else Vec3{0, 1, 0}
	right = linalg.normalize(linalg.cross(reference, d))
	up = linalg.cross(d, right)
	return
}

// The triangles of the first level of a mesh, as the copies of the CPU keep
// them: the place of each vertex in the space of the mesh, appended to
// positions, and three indices a triangle into them, appended to indices.
// False for a mesh the renderer does not have.
mesh_triangles :: proc(r: ^Renderer, handle: Mesh_Handle, positions: ^[dynamic]Vec3, indices: ^[dynamic]u32) -> bool {
	s := &r.scene
	if int(handle) >= len(s.meshes) || s.meshes[handle].vertex_count == 0 {return false}
	mesh_filled(s, u32(handle))
	mesh := s.meshes[handle]
	p := record_pooled(s, mesh)
	_, level0 := record_level(s, mesh, 0)
	for ordinal in 0 ..< level0 {
		g, c, resident := pooled_cluster(p, ordinal)
		if !resident {continue}
		first := u32(len(positions))
		for local in 0 ..< asset.cluster_vertex_count(c) {append(positions, asset.cluster_position(g, c, local))}
		for t in 0 ..< asset.cluster_triangle_count(c) {
			corners := asset.cluster_triangle(g.triangles, c, t)
			append(indices, first + corners[0], first + corners[1], first + corners[2])
		}
	}
	return true
}

// The whole vertices of the triangles of level 0 of a mesh, three a triangle,
// each with the material word of its slot.
@(private)
mesh_level0_corners :: proc(s: ^Scene_State, mesh: Mesh_Record, out: []Gpu_Vertex) -> int {
	p := record_pooled(s, mesh)
	_, level0 := record_level(s, mesh, 0)
	at := 0
	for ordinal in 0 ..< level0 {
		g, c, resident := pooled_cluster(p, ordinal)
		if !resident {continue}
		word := s.indices[mesh.slot_word + asset.cluster_slot(c)] if asset.cluster_slot(c) < mesh.slot_count else 0
		for t in 0 ..< asset.cluster_triangle_count(c) {
			for corner in asset.cluster_triangle(g.triangles, c, t) {
				if at == len(out) {return at}
				v := asset.cluster_vertex(g, c, corner)
				out[at] = {position = v.position, normal = v.normal, uv = v.uv, color = v.color, material = word, uv1 = v.uv1, tangent = v.tangent}
				at += 1
			}
		}
	}
	return at
}

// The material row a vertex of a part is drawn with, as material_of does.
@(private = "file")
part_material :: proc "contextless" (part: Impostor_Part, word: u32) -> u32 {
	slot := word >> 24
	if slot > 0 && slot <= 32 && part.slot_materials[slot - 1] != 0 {return part.slot_materials[slot - 1] - 1}
	return u32(part.material) if part.material != 0 else word & 0xffffff
}

// Draws the frames of an impostor of the first levels of the meshes of
// parts, in their materials and without light, and reads them back: a
// blocking transaction between frames. What the frames do not cover stays
// cleared until impostor_dilate fills it, which a job may do. grid: frames a side, from 2 to
// IMPOSTOR_GRID_MAX; frame: pixels a side of each. False for parts the
// renderer does not have or that span nothing, or when the GPU fails.
impostor_capture :: proc(r: ^Renderer, parts: []Impostor_Part, grid, frame: u32, allocator := context.allocator) -> (images: Impostor_Images, ok: bool) {
	if r == nil || r.device == nil || r.pipelines[.Impostor] == 0 || len(parts) == 0 {return}
	s := &r.scene
	state := &r.impostor
	side := grid * frame
	if grid < 2 || grid > IMPOSTOR_GRID_MAX || frame < 4 || side > IMPOSTOR_SIDE_MAX {return}
	count := 0
	for part in parts {
		if int(part.mesh) >= len(s.meshes) || s.meshes[part.mesh].vertex_count == 0 {return}
		mesh_filled(s, u32(part.mesh))
		count += 3 * int(s.meshes[part.mesh].triangle_count)
	}
	if count == 0 {return}
	vertices := make([]Gpu_Thumbnail_Vertex, count, context.temp_allocator)
	low, high := Vec3{max(f32), max(f32), max(f32)}, Vec3{min(f32), min(f32), min(f32)}
	at := 0
	for part in parts {
		mesh := s.meshes[part.mesh]
		normals := linalg.transpose(linalg.inverse(Mat3(part.placement)))
		mirrored := linalg.determinant(Mat3(part.placement)) < 0
		corners := make([]Gpu_Vertex, 3 * int(mesh.triangle_count), context.temp_allocator)
		corners = corners[:mesh_level0_corners(s, mesh, corners)]
		for corner in corners {
			v := corner
			v.position = (part.placement * Vec4{v.position.x, v.position.y, v.position.z, 1}).xyz
			if part.placement != 1 {
				v.normal = mm.normal_pack(linalg.normalize0(normals * mm.normal_unpack(v.normal)))
				tangent, sign := mm.tangent_unpack(v.tangent)
				v.tangent = mm.tangent_pack(linalg.normalize0(Mat3(part.placement) * tangent), -sign if mirrored else sign)
			}
			v.material = part_material(part, v.material)
			if int(v.material) >= len(s.materials) {v.material = 0}
			low, high = linalg.min(low, v.position), linalg.max(high, v.position)
			vertices[at] = {vertex = v}
			at += 1
		}
	}
	vertices = vertices[:at]
	center := (low + high) * 0.5
	radius: f32
	for v in vertices {radius = max(radius, linalg.length(v.vertex.position - center))}
	if !(radius > 1e-6) || math.is_inf(radius) {return}
	// One block of constants a frame, at offsets a uniform binding takes.
	stride := int(rhi.align_up(u64(max(r.frame_layout.size, size_of(Gpu_Frame))), 256))
	frames := make([]u8, stride * int(grid * grid), context.temp_allocator)
	for y in 0 ..< grid {
		for x in 0 ..< grid {
			d := impostor_direction(grid, x, y)
			_, up := impostor_axes(d)
			camera := Camera{forward = -d, up = up, projection = .Orthographic, height = 2 * radius, position = center + d * 2 * radius, near = radius, far = 3 * radius}
			world_view, projection, forward := camera_matrices(camera, 1)
			world_view = matrix_from_eye(world_view)
			view_projection := projection * world_view
			constants := Gpu_Frame{
				view = world_view, proj = projection, view_proj = view_projection, view_proj_unjittered = view_projection, prev_view_proj = view_projection, inv_view_proj = linalg.inverse(view_projection),
				camera_position = {camera.position.x, camera.position.y, camera.position.z, camera.near}, camera_forward = {forward.x, forward.y, forward.z, camera.far},
				prev_eye = {camera.position.x, camera.position.y, camera.position.z, 0},
				resolution = {f32(frame), f32(frame)}, inv_resolution = {1 / f32(frame), 1 / f32(frame)},
			}
			frame_view_constants(&constants, camera, world_view, projection, projection, forward, f32(frame))
			preview_lighting(&constants, {})
			mem.copy(&frames[int(y * grid + x) * stride], &constants, size_of(Gpu_Frame))
		}
	}
	device := r.device
	for target in ([]struct {buffer: ^rhi.Buffer, size: u64, usage: rhi.Buffer_Usage, name: string}{
		{&state.vertices, u64(len(vertices) * size_of(Gpu_Thumbnail_Vertex)), {.Storage, .Transfer_Dst}, "impostor vertices"},
		{&state.materials, u64(max(len(s.materials), 1) * size_of(Gpu_Material_Row)), {.Storage, .Transfer_Dst}, "impostor materials"},
		{&state.frames, u64(len(frames)), {.Uniform, .Transfer_Dst}, "impostor frames"},
	}) {
		if good, _ := ensure_buffer(r, target.buffer, target.size, target.usage, target.name); !good {return}
	}
	if state.side != side || state.color == 0 || state.normal == 0 || state.depth == 0 {
		for texture in ([]rhi.Texture{state.color, state.normal, state.depth}) {if texture != 0 {rhi.texture_destroy(device, texture)}}
		state.color = rhi.texture_create(device, {width = side, height = side, format = .RGBA8_Srgb, usage = {.Color_Target, .Transfer_Src}, name = "impostor color"})
		state.normal = rhi.texture_create(device, {width = side, height = side, format = .RGBA8_Unorm, usage = {.Color_Target, .Transfer_Src}, name = "impostor normal"})
		state.depth = rhi.texture_create(device, {width = side, height = side, format = .D32_Float, usage = {.Depth_Target}, name = "impostor depth"})
		state.side = side
	}
	if state.color == 0 || state.normal == 0 || state.depth == 0 {return}
	rows := s.materials[:] if len(s.materials) > 0 else []Gpu_Material_Row{{}}
	if !rhi.buffer_upload(device, state.vertices, 0, slice_bytes(vertices)) || !rhi.buffer_upload(device, state.materials, 0, slice_bytes(rows)) || !rhi.buffer_upload(device, state.frames, 0, frames) {return}
	cmd := rhi.immediate_begin(device)
	if cmd == nil {return}
	rhi.cmd_bind_buffer(cmd, SLOT_PASS0, state.vertices)
	rhi.cmd_bind_buffer(cmd, SLOT_MATERIALS, state.materials)
	rhi.cmd_bind_sampler(cmd, SLOT_MATERIAL_SAMPLER, r.material_sampler)
	rhi.cmd_bind_sampler(cmd, SLOT_LINEAR_SAMPLER, r.linear_sampler)
	pass := rhi.Render_Pass_Desc{color_count = 2, name = "impostor capture"}
	pass.colors[0] = {texture = state.color, load = .Clear, store = .Store}
	pass.colors[1] = {texture = state.normal, load = .Clear, store = .Store}
	pass.depth = {texture = state.depth, load = .Clear, store = .Dont_Care, clear = 0}
	rhi.cmd_begin_render_pass(cmd, &pass)
	rhi.cmd_bind_texture(cmd, SLOT_PASS5, r.display_lut)
	for y in 0 ..< grid {
		for x in 0 ..< grid {
			rhi.cmd_set_viewport(cmd, f32(x * frame), f32(y * frame), f32(frame), f32(frame))
			rhi.cmd_set_scissor(cmd, i32(x * frame), i32(y * frame), frame, frame)
			rhi.cmd_bind_buffer(cmd, SLOT_FRAME, state.frames, u64(int(y * grid + x) * stride), u64(stride))
			rows_programs_draw(r, cmd, &r.pipelines[.Impostor], rows, u32(len(vertices)), now = true)
		}
	}
	rhi.cmd_end_render_pass(cmd)
	if !rhi.immediate_end(device, cmd) {return}
	images = {grid = grid, frame = frame, center = center, radius = radius}
	color_error, normal_error: mem.Allocator_Error
	images.color, color_error = make([]u8, int(side) * int(side) * 4, allocator)
	images.normal, normal_error = make([]u8, int(side) * int(side) * 4, allocator)
	if color_error != nil || normal_error != nil {
		set_error(r, "impostor capture: out of memory for %dx%d images", side, side)
		impostor_images_destroy(&images, allocator)
		return {}, false
	}
	if !rhi.texture_read(device, state.color, images.color) || !rhi.texture_read(device, state.normal, images.normal) {
		impostor_images_destroy(&images, allocator)
		return {}, false
	}
	return images, true
}

// Gives each uncovered texel of a frame the color, normal and depth of the
// covered texel of the frame nearest it, its coverage still 0: what filtering
// and the levels of the textures blend at the edges of the leaves is their
// own color and not the cleared black. A frame without a covered texel stays
// cleared.
impostor_dilate :: proc(images: ^Impostor_Images) {
	side := int(images.grid * images.frame)
	frame := int(images.frame)
	if side == 0 || len(images.color) < side * side * 4 || len(images.normal) < side * side * 4 {return}
	filled := make([]bool, side * side, context.temp_allocator)
	queue := make([]u32, side * side, context.temp_allocator)
	head, tail := 0, 0
	for i in 0 ..< side * side {
		if images.color[i * 4 + 3] == 0 {continue}
		filled[i] = true
		queue[tail] = u32(i)
		tail += 1
	}
	// Breadth first from every covered texel, within its frame.
	for head < tail {
		at := int(queue[head])
		head += 1
		x, y := at % side, at / side
		for step in ([4][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) {
			nx, ny := x + step.x, y + step.y
			if nx < 0 || ny < 0 || nx >= side || ny >= side || nx / frame != x / frame || ny / frame != y / frame {continue}
			next := ny * side + nx
			if filled[next] {continue}
			filled[next] = true
			for c in 0 ..< 3 {images.color[next * 4 + c] = images.color[at * 4 + c]}
			for c in 0 ..< 4 {images.normal[next * 4 + c] = images.normal[at * 4 + c]}
			queue[tail] = u32(next)
			tail += 1
		}
	}
}
