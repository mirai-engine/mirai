package mirai_render

import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:testing"
import "mirai:asset"
import "mirai:rhi"
import "mirai:std/geom"
import mm "mirai:std/math"

// No temporal jitter, so a pixel center always shows the same surface point.
// Shadows are checked ray by ray, at single pixels of small images: the
// fixtures draw with the reference of the lights, whose every pixel traces
// its own rays.
@(private = "file")
material_settings :: proc() -> Settings {
	s := DEFAULT_SETTINGS
	s.gi_enabled = false
	s.taa = false
	s.reflections = .Detailed
	return s
}

// A unit square on the ground facing up. u grows with +X and v with +Z, so a
// camera above it with -Z as its up shows the image upright.
@(private = "file")
ground_quad :: proc(r: ^Renderer, material: Material_Handle = 0) -> Mesh_Handle {
	corners := [4]Vec3{{-0.5, 0, -0.5}, {0.5, 0, -0.5}, {0.5, 0, 0.5}, {-0.5, 0, 0.5}}
	vertices: [4]Mesh_Vertex
	for c, i in corners {vertices[i] = {position = c, normal = {0, 1, 0}, tangent = {1, 0, 0, 1}, uv = {c.x + 0.5, c.z + 0.5}, color = {1, 1, 1}, material = material}}
	indices := [6]u32{0, 2, 1, 0, 3, 2}
	mesh, _ := mesh_add(r, vertices[:], indices[:])
	return mesh
}

@(private = "file")
OVERHEAD :: Camera{position = {0, 2, 0}, forward = {0, -2, 0}, up = {0, 0, -1}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}

// Real UI draws exercise the material buffer and the indexed texture table in
// the UI pipeline, including materials not assigned to scene geometry.
@(test)
material_selector_thumbnails_sample_the_material_table :: proc(t: ^testing.T) {
    f: Fixture
    if !fixture_init(t, &f, 128, 64, material_settings(), reference = {.Lights}) {return}
    defer fixture_destroy(&f)
    r:=f.renderer
    pixels:=make([]u8,32*32*4,context.temp_allocator)
    for y in 0..<32 {
        for x in 0..<32 {
            at:=(y*32+x)*4
            pixels[at]=255 if x<16 else 0
            pixels[at+2]=0 if x<16 else 255
            pixels[at+3]=255
        }
    }
    texture,added:=texture_add(r,{pixels=pixels,width=32,height=32,srgb=true,name="thumbnail halves"})
    testing.expect(t,added,r.error)
    textured,glow:=DEFAULT_MATERIAL,DEFAULT_MATERIAL
    textured.textures[.Base_Color]=texture
    // Nits: as bright as a screen in the studio of previews.
    glow.base_color={0,0,0};glow.emission={0,500,0}
    materials_set(r,{textured,glow})
    ui:[18]Ui_Vertex
    backdrop:=Ui_Vertex{position={0,0,0},color={0.11,0.23,0.37,1}}
    backdrop_right:=backdrop;backdrop_right.position={128,0,0}
    backdrop_corner:=backdrop;backdrop_corner.position={128,64,0}
    backdrop_bottom:=backdrop;backdrop_bottom.position={0,64,0}
    copy(ui[:6],([]Ui_Vertex{backdrop,backdrop_right,backdrop_corner,backdrop,backdrop_corner,backdrop_bottom}))
    for id in 0..<2 {
        x:=f32(4+id*60)
        a:=Ui_Vertex{position={x,4,0},color={1,1,1,1},material=UI_MATERIAL_PREVIEW_BIT|u32(id+1),uv={0,0}}
        b:=a;b.position={x+48,4,0};b.uv={1,0}
        c:=a;c.position={x+48,52,0};c.uv={1,1}
        d:=a;d.position={x,52,0};d.uv={0,1}
        copy(ui[6+id*6:][0:6],([]Ui_Vertex{a,b,c,a,c,d}))
    }
    testing.expect(t,fixture_frame(&f, {camera=OVERHEAD,ui={{vertices=ui[:]}}}),r.error)
    shown,width,_,ok:=golden_capture(r)
    testing.expect(t,ok,r.error)
    if !ok {return}
    defer delete(shown)
    color_at :: proc(pixels:[]u8,width,x,y:int) -> [4]u8 {
        at:=(y*width+x)*4
        return {pixels[at],pixels[at+1],pixels[at+2],pixels[at+3]}
    }
    left,right,emitter:=color_at(shown,width,20,28),color_at(shown,width,36,28),color_at(shown,width,88,28)
    background:=color_at(shown,width,60,4)
    testing.expect(t,color_at(shown,width,5,5)==background,"the material preview corner leaves the surrounding UI visible")
    testing.expect(t,color_at(shown,width,65,5)==background,"material previews have no opaque checker background")
    testing.expectf(t,int(left.r)>int(left.b)+30 && int(right.b)>int(right.r)+30,"thumbnail texture is sampled by UV: %v and %v",left,right)
    testing.expectf(t,int(emitter.g)>int(emitter.r)+50 && int(emitter.g)>int(emitter.b)+50,"thumbnail uses the second material's emission: %v",emitter)
    // Editing the existing row updates its thumbnail without a preview resource.
    glow.emission={0,0,500};materials_set(r,{textured,glow})
    testing.expect(t,fixture_frame(&f, {camera=OVERHEAD,ui={{vertices=ui[:]}}}),r.error)
    updated,_,_,updated_ok:=golden_capture(r)
    testing.expect(t,updated_ok,r.error)
    if updated_ok {
        emitter=color_at(updated,width,88,28)
        testing.expectf(t,int(emitter.b)>int(emitter.g)+50,"thumbnail follows edits to its material: %v",emitter)
        delete(updated)
    }
    testing.expectf(t,rhi.device_validation_errors(f.device)==0,"validation: %s",rhi.device_validation_message(f.device))
}

@(private = "file")
scale_matrix :: proc(scale: f32) -> Mat4 {
	m := Mat4(1)
	m[0, 0], m[1, 1], m[2, 2] = scale, scale, scale
	return m
}

@(private = "file")
target_pixel :: proc(r: ^Renderer, camera: Camera, world: Vec3, output: bool = false) -> [2]int {
	view, proj, _ := camera_matrices(camera, f32(r.targets.width) / f32(r.targets.height))
	clip := (proj * view) * Vec4{world.x, world.y, world.z, 1}
	ndc := clip.xy / clip.w
	width := r.targets.output_width if output else r.targets.width
    height := r.targets.output_height if output else r.targets.height
    return {int((ndc.x * 0.5 + 0.5) * f32(width)), int((0.5 - ndc.y * 0.5) * f32(height))}
}

// G-buffer base color (sRGB bytes) and metallic (alpha) at a world position.
@(private = "file")
read_albedo :: proc(t: ^testing.T, f: ^Fixture, camera: Camera, world: Vec3) -> [4]int {
	r := f.renderer
	rhi.device_wait_idle(f.device)
	pixels := make([]u8, int(r.targets.width * r.targets.height) * 4, context.temp_allocator)
	testing.expect(t, golden_read_texture(f.device, r.targets.albedo, pixels), rhi.device_error(f.device))
	p := target_pixel(r, camera, world)
	i := (p.y * int(r.targets.width) + p.x) * 4
	return {int(pixels[i]), int(pixels[i + 1]), int(pixels[i + 2]), int(pixels[i + 3])}
}

// G-buffer shading normal and roughness (w) at a world position.
@(private = "file")
read_normal :: proc(t: ^testing.T, f: ^Fixture, camera: Camera, world: Vec3) -> Vec4 {
	r := f.renderer
	rhi.device_wait_idle(f.device)
	halves := make([]f16, int(r.targets.width * r.targets.height) * 4, context.temp_allocator)
	testing.expect(t, golden_read_texture(f.device, r.targets.normal, mem.slice_data_cast([]u8, halves)), rhi.device_error(f.device))
	p := target_pixel(r, camera, world)
	i := (p.y * int(r.targets.width) + p.x) * 4
	normal, roughness, _ := gbuffer_normal_decode({f32(halves[i]), f32(halves[i + 1]), f32(halves[i + 2]), f32(halves[i + 3])})
	return {normal.x, normal.y, normal.z, roughness}
}

@(private = "file")
near_bytes :: proc(a, b: [4]int, tolerance: int) -> bool {
	for i in 0 ..< 4 {if abs(a[i] - b[i]) > tolerance {return false}}
	return true
}

@(private = "file")
frames :: proc(t: ^testing.T, f: ^Fixture, camera: Camera, count: int, mode := Debug_View.None) {
	for _ in 0 ..< count {testing.expect(t, fixture_frame(f, {camera = camera, inspection = {mode = mode}}), f.renderer.error)}
}

// A view that fades out the body of its player leaves out as many of its
// pixels as the fade, all of them at 1; the view of another player and a
// view that hides nothing draw it whole.
@(test)
a_view_fades_out_the_body_of_its_player_by_a_share_of_its_pixels :: proc(t: ^testing.T) {
	f: Fixture
	if !fixture_init(t, &f, 64, 64, material_settings(), reference = {.Lights}) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	red := DEFAULT_MATERIAL
	red.base_color = {1, 0, 0}
	materials_set(r, {red})
	quad := ground_quad(r, 1)
	wide := Mat4{4, 0, 0, 0, 0, 1, 0, 0, 0, 0, 4, 0, 0, 0, 0, 1}
	scene_given(r, {{object_id = 1, mesh = quad, transform = wide, tint = {1, 1, 1}, owner = 1}}, nil, {}, {})
	Case :: struct {own: u8, fade: f32, drawn: int}
	ALL :: 64 * 64
	cases := [?]Case{{0, 0, ALL}, {1, 0, ALL}, {1, 0.25, ALL * 3 / 4}, {1, 0.5, ALL / 2}, {1, 1, 0}, {2, 1, ALL}}
	pixels := make([]u8, ALL * 4, context.temp_allocator)
	for c in cases {
		camera := OVERHEAD
		camera.own, camera.fade = c.own, c.fade
		frames(t, &f, camera, 2)
		rhi.device_wait_idle(f.device)
		testing.expect(t, golden_read_texture(f.device, r.targets.albedo, pixels), rhi.device_error(f.device))
		drawn := 0
		for i in 0 ..< ALL {if pixels[i * 4] > 200 {drawn += 1}}
		testing.expectf(t, drawn == c.drawn, "own %d, fade %v: %d pixels of the body, not %d", c.own, c.fade, drawn, c.drawn)
	}
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

// A view leaves out the layers it does not draw of its own body only: the
// head of another body in the same view, and the own head in a view that
// leaves out nothing, are drawn; the layers it does not draw at all it does
// not draw of any body.
@(test)
a_view_hides_the_head_of_its_own_body_and_no_other :: proc(t: ^testing.T) {
	f: Fixture
	if !fixture_init(t, &f, 64, 64, material_settings(), reference = {.Lights}) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	red := DEFAULT_MATERIAL
	red.base_color = {1, 0, 0}
	materials_set(r, {red})
	quad := ground_quad(r, 1)
	wide := Mat4{4, 0, 0, 0, 0, 1, 0, 0, 0, 0, 4, 0, 0, 0, 0, 1}
	HEAD_LAYER :: u32(1) << 15
	scene_given(r, {{object_id = 1, mesh = quad, transform = wide, tint = {1, 1, 1}, layers = HEAD_LAYER, owner = 1}}, nil, {}, {})
	ALL :: 64 * 64
	Case :: struct {own: u8, own_hidden, layers: u32, drawn: int}
	cases := [?]Case{
		{1, HEAD_LAYER, 0, 0},     // the own head, seen from the eyes
		{2, HEAD_LAYER, 0, ALL},   // another body's head in the same view
		{1, 0, 0, ALL},            // a view that leaves out nothing of its body
		{0, HEAD_LAYER, 0, ALL},   // no local body: no head to leave out
		{2, 0, 1, 0},              // a view that does not draw the layer at all
	}
	pixels := make([]u8, ALL * 4, context.temp_allocator)
	for c in cases {
		camera := OVERHEAD
		camera.own, camera.own_hidden, camera.layers = c.own, c.own_hidden, c.layers
		frames(t, &f, camera, 2)
		rhi.device_wait_idle(f.device)
		testing.expect(t, golden_read_texture(f.device, r.targets.albedo, pixels), rhi.device_error(f.device))
		drawn := 0
		for i in 0 ..< ALL {if pixels[i * 4] > 200 {drawn += 1}}
		testing.expectf(t, drawn == c.drawn, "own %d, own_hidden %#x, layers %#x: %d pixels of the head, not %d", c.own, c.own_hidden, c.layers, drawn, c.drawn)
	}
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

@(test)
material_texture_is_upright_and_keeps_its_colors :: proc(t: ^testing.T) {
	f: Fixture
	if !fixture_init(t, &f, 64, 64, material_settings(), reference = {.Lights}) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	// Four quadrants, from the top: red, green / blue, gray. Their centers are
	// far from any other color, whatever the filter.
	SIZE :: 8
	quadrants := [4][4]u8{{255, 0, 0, 255}, {0, 255, 0, 255}, {0, 0, 255, 255}, {128, 128, 128, 255}}
	image: [SIZE * SIZE * 4]u8
	for y in 0 ..< SIZE {
		for x in 0 ..< SIZE {
			color := quadrants[(y / (SIZE / 2)) * 2 + x / (SIZE / 2)]
			for channel, c in color {image[(y * SIZE + x) * 4 + c] = channel}
		}
	}
	texture, added := texture_add(r, {pixels = image[:], width = SIZE, height = SIZE, srgb = true, name = "quadrants"})
	testing.expect(t, added, r.error)
	material := DEFAULT_MATERIAL
	material.metallic = 0.25
	material.textures[.Base_Color] = texture
	materials_set(r, {material})
	quad := ground_quad(r, 1)
	scene_given(r, {{object_id = 1, mesh = quad, transform = Mat4(1), tint = {1, 1, 1}}}, nil, {}, {})
	frames(t, &f, OVERHEAD, 2)
	metallic := 64
	testing.expectf(t, near_bytes(read_albedo(t, &f, OVERHEAD, {-0.25, 0, -0.25}), {255, 0, 0, metallic}, 3), "top left is the first texel: %v", read_albedo(t, &f, OVERHEAD, {-0.25, 0, -0.25}))
	testing.expectf(t, near_bytes(read_albedo(t, &f, OVERHEAD, {0.25, 0, -0.25}), {0, 255, 0, metallic}, 3), "top right: %v", read_albedo(t, &f, OVERHEAD, {0.25, 0, -0.25}))
	testing.expectf(t, near_bytes(read_albedo(t, &f, OVERHEAD, {-0.25, 0, 0.25}), {0, 0, 255, metallic}, 3), "bottom left: %v", read_albedo(t, &f, OVERHEAD, {-0.25, 0, 0.25}))
	// A compressed color has 5, 6 and 5 bits per channel.
	testing.expectf(t, near_bytes(read_albedo(t, &f, OVERHEAD, {0.25, 0, 0.25}), {128, 128, 128, metallic}, 6), "an sRGB texel keeps its value: %v", read_albedo(t, &f, OVERHEAD, {0.25, 0, 0.25}))

	// The tint and the factor multiply the texture; scale and offset move it.
	material.base_color = {1, 0.5, 1}
	material.maps.base_color.scale = {0.5, 0.5}
	material.maps.base_color.offset = {0.5, 0}
	materials_set(r, {material})
	scene_given(r, {{object_id = 1, mesh = quad, transform = Mat4(1), tint = {1, 1, 0}}}, nil, {}, {})
	frames(t, &f, OVERHEAD, 2)
	// The whole quad now shows the top right quadrant: green.
	testing.expectf(t, near_bytes(read_albedo(t, &f, OVERHEAD, {-0.25, 0, 0.25}), {0, 188, 0, metallic}, 3), "half of green: %v", read_albedo(t, &f, OVERHEAD, {-0.25, 0, 0.25}))
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

@(test)
material_instance_overrides_the_mesh_materials :: proc(t: ^testing.T) {
	f: Fixture
	if !fixture_init(t, &f, 64, 64, material_settings(), reference = {.Lights}) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	red, blue := DEFAULT_MATERIAL, DEFAULT_MATERIAL
	red.base_color = {1, 0, 0}
	blue.base_color = {0, 0, 1}
	blue.roughness = 0.5
	materials_set(r, {red, blue})
	quad := ground_quad(r, 1)
	scene_given(r, {{object_id = 1, mesh = quad, transform = Mat4(1), tint = {1, 1, 1}}}, nil, {}, {})
	frames(t, &f, OVERHEAD, 2)
	testing.expectf(t, near_bytes(read_albedo(t, &f, OVERHEAD, {}), {255, 0, 0, 0}, 2), "the mesh's own material: %v", read_albedo(t, &f, OVERHEAD, {}))
	testing.expectf(t, abs(read_normal(t, &f, OVERHEAD, {}).w - 1) < 0.01, "roughness of the default: %v", read_normal(t, &f, OVERHEAD, {}))
	scene_given(r, {{object_id = 1, mesh = quad, transform = Mat4(1), material = 2, tint = {1, 1, 1}}}, nil, {}, {})
	frames(t, &f, OVERHEAD, 2)
	testing.expectf(t, near_bytes(read_albedo(t, &f, OVERHEAD, {}), {0, 0, 255, 0}, 2), "the material of the instance: %v", read_albedo(t, &f, OVERHEAD, {}))
	testing.expectf(t, abs(read_normal(t, &f, OVERHEAD, {}).w - 0.5) < 0.01, "its roughness: %v", read_normal(t, &f, OVERHEAD, {}))
	// A row past the table is ignored instead of read out of bounds.
	scene_given(r, {{object_id = 1, mesh = quad, transform = Mat4(1), material = 40, tint = {1, 1, 1}}}, nil, {}, {})
	frames(t, &f, OVERHEAD, 2)
	testing.expectf(t, near_bytes(read_albedo(t, &f, OVERHEAD, {}), {255, 0, 0, 0}, 2), "an unknown row keeps the mesh's material: %v", read_albedo(t, &f, OVERHEAD, {}))
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

@(test)
material_mips_average_light_and_follow_distance :: proc(t: ^testing.T) {
	f: Fixture
	if !fixture_init(t, &f, 64, 64, material_settings(), reference = {.Lights}) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	SIZE :: 64
	image := make([]u8, SIZE * SIZE * 4)
	defer delete(image)
	for y in 0 ..< SIZE {
		for x in 0 ..< SIZE {
			value: u8 = 255 if (x + y) % 2 == 0 else 0
			at := (y * SIZE + x) * 4
			image[at], image[at + 1], image[at + 2], image[at + 3] = value, value, value, 255
		}
	}
	texture, added := texture_add(r, {pixels = image, width = SIZE, height = SIZE, srgb = true, name = "checker"})
	testing.expect(t, added, r.error)
	testing.expect_value(t, rhi.texture_desc(f.device, r.textures.textures[0]).mip_levels, u32(7))
	material := DEFAULT_MATERIAL
	material.textures[.Base_Color] = texture
	materials_set(r, {material})
	quad := ground_quad(r, 1)
	scene_given(r, {{object_id = 1, mesh = quad, transform = Mat4(1), tint = {1, 1, 1}}}, nil, {}, {})
	// The quad covers about 8 pixels: each one spans several texels.
	far := OVERHEAD
	far.position = {0, 7, 0}
	frames(t, &f, far, 2)
	// Half of the light is sRGB 188; averaging the encoded bytes would give 128,
	// and reading the full-size level would give black or white.
	center := read_albedo(t, &f, far, {})
	testing.expectf(t, abs(center.r - 188) <= 6 && abs(center.g - 188) <= 6 && abs(center.b - 188) <= 6, "a distant checker is its average light: %v", center)
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

@(test)
material_normal_map_tilts_towards_its_axes :: proc(t: ^testing.T) {
	f: Fixture
	if !fixture_init(t, &f, 64, 64, material_settings(), reference = {.Lights}) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	// 30 degrees towards +X of the image, and towards its top (+Y).
	right := [4]u8{191, 128, 238, 255}
	up := [4]u8{128, 191, 238, 255}
	right_texture, ok1 := texture_add(r, {pixels = right[:], width = 1, height = 1, normal_map = true, name = "tilt right"})
	up_texture, ok2 := texture_add(r, {pixels = up[:], width = 1, height = 1, normal_map = true, name = "tilt up"})
	testing.expect(t, ok1 && ok2, r.error)
	tilt_right, tilt_up, flat := DEFAULT_MATERIAL, DEFAULT_MATERIAL, DEFAULT_MATERIAL
	tilt_right.textures[.Normal] = right_texture
	tilt_up.textures[.Normal] = up_texture
	flat.textures[.Normal] = right_texture
	flat.normal_scale = 0
	materials_set(r, {tilt_right, tilt_up, flat})
	quad := ground_quad(r)
	expected := [3]Vec3{{0.5, 0.866, 0}, {0, 0.866, -0.5}, {0, 1, 0}}
	for want, i in expected {
		scene_given(r, {{object_id = 1, mesh = quad, transform = Mat4(1), material = Material_Handle(i + 1), tint = {1, 1, 1}}}, nil, {}, {})
		frames(t, &f, OVERHEAD, 2)
		n := read_normal(t, &f, OVERHEAD, {0.2, 0, 0.1})
		testing.expectf(t, abs(n.x - want.x) < 0.03 && abs(n.y - want.y) < 0.03 && abs(n.z - want.z) < 0.03, "material %d: normal %v, expected %v", i + 1, n.xyz, want)
	}
	// Seen from below, the sheet is the same surface: its normal is the opposite of the front one.
	below := Camera{position = {0, -2, 0}, forward = {0, 2, 0}, up = {0, 0, -1}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	scene_given(r, {{object_id = 1, mesh = quad, transform = Mat4(1), material = 1, tint = {1, 1, 1}}}, nil, {}, {})
	frames(t, &f, below, 2)
	n := read_normal(t, &f, below, {0.2, 0, 0.1})
	testing.expectf(t, abs(n.x + 0.5) < 0.03 && abs(n.y + 0.866) < 0.03 && abs(n.z) < 0.03, "back face: normal %v", n.xyz)
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

@(test)
material_gloss_adds_a_highlight_and_metal_tints_it :: proc(t: ^testing.T) {
	f: Fixture
	if !fixture_init(t, &f, 96, 64, material_settings(), reference = {.Lights}) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	matte, glossy, metal := DEFAULT_MATERIAL, DEFAULT_MATERIAL, DEFAULT_MATERIAL
	matte.base_color = {0.5, 0.5, 0.5}
	glossy.base_color = {0.5, 0.5, 0.5}
	glossy.roughness = 0.5
	metal.base_color = {1, 0.6, 0.1}
	metal.roughness = 0.5
	metal.metallic = 1
	materials_set(r, {matte, glossy, metal})
	quad := ground_quad(r)
	// The light, the camera and the floor point between them form a mirror path.
	camera := Camera{position = {0, 2, 4}, forward = {0, -2, -2}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	lights := []Light_Desc{{position = {0, 2, 0}, color = {1, 1, 1}, intensity = 4 * math.PI, range = 30}}
	shot :: proc(t: ^testing.T, f: ^Fixture, quad: Mesh_Handle, lights: []Light_Desc, camera: Camera, material: Material_Handle, world: Vec3) -> [3]f32 {
		r := f.renderer
		scene_given(r, {{object_id = 1, mesh = quad, transform = scale_matrix(20), material = material, tint = {1, 1, 1}}}, lights, {}, {})
		for _ in 0 ..< 3 {testing.expect(t, fixture_frame(f, {camera = camera}), r.error)}
		rhi.device_wait_idle(f.device)
		pixels, w, _, ok := golden_capture(r)
		testing.expect(t, ok, r.error)
		if !ok {return {}}
		defer delete(pixels)
		p := target_pixel(r, camera, world)
		i := (p.y * w + p.x) * 4
		return {f32(pixels[i]), f32(pixels[i + 1]), f32(pixels[i + 2])}
	}
	mirror := Vec3{0, 0, 2}
	aside := Vec3{2.5, 0, 0.5}
	matte_mirror := shot(t, &f, quad, lights, camera, 1, mirror)
	glossy_mirror := shot(t, &f, quad, lights, camera, 2, mirror)
	matte_aside := shot(t, &f, quad, lights, camera, 1, aside)
	glossy_aside := shot(t, &f, quad, lights, camera, 2, aside)
	metal_mirror := shot(t, &f, quad, lights, camera, 3, mirror)
	metal_aside := shot(t, &f, quad, lights, camera, 3, aside)
	testing.expectf(t, glossy_mirror.g > matte_mirror.g + 20, "a glossy floor mirrors the light: %v against %v", glossy_mirror, matte_mirror)
	testing.expectf(t, abs(glossy_aside.g - matte_aside.g) < 12, "away from the mirror path gloss changes little: %v against %v", glossy_aside, matte_aside)
	testing.expectf(t, abs(glossy_mirror.r - glossy_mirror.b) < 8, "the highlight of a dielectric has the color of the light: %v", glossy_mirror)
	testing.expectf(t, metal_mirror.r > metal_mirror.b + 60, "the highlight of a metal has its color: %v", metal_mirror)
	testing.expectf(t, metal_aside.g < matte_aside.g / 2, "a metal has no diffuse reflection: %v against %v", metal_aside, matte_aside)
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

@(test)
material_textures_color_the_bounced_light :: proc(t: ^testing.T) {
	f: Fixture
	settings := DEFAULT_SETTINGS
	// The indirect light itself: the lit floor of a room this bright goes white
	// through the display transform.
	settings.taa = false
	settings.probe_budget = 4096
	settings.probe_rays = 64
	settings.probe_grid, settings.probe_cascades = 8, 2
	settings.probe_spacing = 1.5
	if !fixture_init(t, &f, 96, 64, settings, programs = true) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	red := [4]u8{255, 0, 0, 255}
	texture, added := texture_add(r, {pixels = red[:], width = 1, height = 1, srgb = true, name = "red"})
	testing.expect(t, added, r.error)
	// A white emitter whose emission texture leaves only red.
	lamp := DEFAULT_MATERIAL
	lamp.emission = {3, 3, 3}
	lamp.textures[.Emission] = texture
	materials_set(r, {lamp})
	cube_corners := [8]Vec3{{-1, -1, -1}, {1, -1, -1}, {1, 1, -1}, {-1, 1, -1}, {-1, -1, 1}, {1, -1, 1}, {1, 1, 1}, {-1, 1, 1}}
	faces := [6][4]int{{0, 3, 2, 1}, {4, 5, 6, 7}, {0, 4, 7, 3}, {1, 2, 6, 5}, {0, 1, 5, 4}, {3, 7, 6, 2}}
	normals := [6]Vec3{{0, 0, -1}, {0, 0, 1}, {-1, 0, 0}, {1, 0, 0}, {0, -1, 0}, {0, 1, 0}}
	uvs := [4]Vec2{{0, 0}, {1, 0}, {1, 1}, {0, 1}}
	vertices: [24]Mesh_Vertex
	indices: [36]u32
	for face, i in faces {
		for corner, k in face {vertices[i * 4 + k] = {position = cube_corners[corner] * 0.5, normal = normals[i], uv = uvs[k], color = {1, 1, 1}}}
		base := u32(i * 4)
		for q, k in ([6]u32{base, base + 1, base + 2, base, base + 2, base + 3}) {indices[i * 6 + k] = q}
	}
	cube, ok := mesh_add(r, vertices[:], indices[:])
	testing.expect(t, ok)
	// The second emitter selects blue with UV1 while UV0 always reads red.
	// A missing UV1 interpolation would therefore keep the bounced light red.
	for &v in vertices {v.uv = {0.25, 0.5}; v.uv1 = {0.75, 0.5}}
	secondary, secondary_ok := mesh_add(r, vertices[:], indices[:])
	testing.expect(t, secondary_ok, r.error)
	image: [16 * 16 * 4]u8
	for y in 0 ..< 16 {for x in 0 ..< 16 {
		i := (y * 16 + x) * 4
		image[i] = 255 if x < 8 else 0
		image[i + 2] = 0 if x < 8 else 255
		image[i + 3] = 255
	}}
	secondary_texture, texture_ok := texture_add(r, {pixels = image[:], width = 16, height = 16, srgb = true, name = "bounce UV halves"})
	testing.expect(t, texture_ok, r.error)
	box :: proc(position, scale: Vec3) -> Mat4 {
		m := Mat4(1)
		m[0, 0], m[1, 1], m[2, 2] = scale.x, scale.y, scale.z
		m[0, 3], m[1, 3], m[2, 3] = position.x, position.y, position.z
		return m
	}
	white := Vec3{0.9, 0.9, 0.9}
	instances := []Instance_Desc{
		{object_id = 1, mesh = cube, transform = box({0, -0.1, 0}, {6, 0.2, 6}), tint = white},
		{object_id = 2, mesh = cube, transform = box({0, 3.1, 0}, {6, 0.2, 6}), material = 1, tint = {1, 1, 1}},
		{object_id = 3, mesh = cube, transform = box({-3.1, 1.5, 0}, {0.2, 3.4, 6}), tint = white},
		{object_id = 4, mesh = cube, transform = box({3.1, 1.5, 0}, {0.2, 3.4, 6}), tint = white},
		{object_id = 5, mesh = cube, transform = box({0, 1.5, -3.1}, {6, 3.4, 0.2}), tint = white},
		{object_id = 6, mesh = cube, transform = box({0, 1.5, 3.1}, {6, 3.4, 0.2}), tint = white},
	}
	camera := Camera{position = {0, 2.5, 2.5}, forward = {0, -2.5, -2.5}, up = {0, 1, 0}, fov_y = 70, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	for provider in ([]Trace_Mode{.Software, .Hardware}) {
		if provider == .Hardware && !r.hardware_rt_verified {continue}
		settings.trace_mode = provider
		testing.expect(t, renderer_apply_settings(r, settings), r.error)
		for mesh, uv_set in ([2]Mesh_Handle{cube, secondary}) {
			lamp.textures[.Emission] = texture if uv_set == 0 else secondary_texture
			lamp.maps.emission.uv_set = u32(uv_set)
			materials_set(r, {lamp})
			instances[1].mesh = mesh
			scene_given(r, instances, nil, {}, {sky = {0, 0, 0}})
			renderer_reset_history(r)
			frames(t, &f, camera, 16, .Indirect)
			rhi.device_wait_idle(f.device)
			pixels, w, _, captured := golden_capture(r)
			testing.expect(t, captured, r.error)
			if !captured {return}
			p := target_pixel(r, camera, {0, 0.001, 0})
			i := (p.y * w + p.x) * 4
			floor := [3]f32{f32(pixels[i]), f32(pixels[i + 1]), f32(pixels[i + 2])}
			selected, other := floor.r, floor.b
			if uv_set == 1 {selected, other = floor.b, floor.r}
			testing.expectf(t, selected > 40 && selected > floor.g * 2 && selected > other * 2, "%v UV%d colors the bounced light with its emission texture: %v", provider, uv_set, floor)
			delete(pixels)
		}
		// Under a black ceiling, the white light of a lamp comes back to the floor
		// from the walls: from walls a program paints red over a blue row as from
		// a red row.
		grid := program_find(r, "Grid", .Surface)
		if !testing.expect(t, grid != nil, "the tests have the Grid program") {return}
		black, row, painted := DEFAULT_MATERIAL, DEFAULT_MATERIAL, DEFAULT_MATERIAL
		black.base_color = {0, 0, 0}
		row.base_color = {1, 0, 0}
		painted.base_color = {0, 0, 1}
		painted.program_id = grid.id
		painted.custom_params = program_defaults(grid)
		for name in ([]string{"color", "line_color"}) {testing.expect(t, program_parameter_set(&painted.custom_params, program_parameter(grid, name), {1, 0, 0, 0}))}
		materials_set(r, {black, row, painted})
		lamp_light := []Light_Desc{{position = {0, 1.5, 0}, color = {1, 1, 1}, intensity = 16 * math.PI, range = 30}}
		floors: [2][3]f32
		for &floor, k in floors {
			room: [6]Instance_Desc
			copy(room[:], instances)
			room[1].mesh = cube
			for &wall in room[2:] {
				wall.material = Material_Handle(2 + k)
				wall.tint = {1, 1, 1}
			}
			scene_given(r, room[:], lamp_light, {}, {sky = {0, 0, 0}})
			renderer_reset_history(r)
			frames(t, &f, camera, 16, .Indirect)
			rhi.device_wait_idle(f.device)
			pixels, w, _, captured := golden_capture(r)
			testing.expect(t, captured, r.error)
			if !captured {return}
			p := target_pixel(r, camera, {0, 0.001, 0})
			i := (p.y * w + p.x) * 4
			floor = {f32(pixels[i]), f32(pixels[i + 1]), f32(pixels[i + 2])}
			delete(pixels)
		}
		red, programmed := floors[0], floors[1]
		testing.expectf(t, red.r > red.b + 12 && abs(programmed.r - red.r) < 8 && abs(programmed.b - red.b) < 8, "%v walls of the program color the bounced light as the row does: %v against %v", provider, programmed, red)
	}
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

@(test)
texture_table_has_a_budget :: proc(t: ^testing.T) {
	f: Fixture
	settings := material_settings()
	settings.texture_max_size = 4
	if !fixture_init(t, &f, 32, 32, settings) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	image: [16 * 16 * 4]u8
	for &b in image {b = 200}
	_, ok := texture_add(r, {pixels = image[:], width = 16, height = 16, name = "large"})
	testing.expect(t, ok, r.error)
	desc := rhi.texture_desc(f.device, r.textures.textures[0])
	testing.expect(t, desc.width == 4 && desc.height == 4 && desc.mip_levels == 3, "an image over the size limit starts at the level that fits")
	testing.expect_value(t, r.textures.bytes, u64((16 + 4 + 1) * 4))
	_, ok = texture_add(r, {pixels = image[:5 * 3 * 4], width = 5, height = 3, srgb = true, name = "odd"})
	testing.expect(t, ok, r.error)
	desc = rhi.texture_desc(f.device, r.textures.textures[1])
	testing.expect(t, desc.width == 2 && desc.height == 1 && desc.mip_levels == 2, "sizes that are not powers of two are reduced like the rest")
	_, ok = texture_add(r, {pixels = image[:8], width = 2, height = 2, name = "short"})
	testing.expect(t, !ok, "pixels that do not cover the image are rejected")
	// The table grows past the entries it starts with.
	for texture_count(r) < rhi.TEXTURE_TABLE_FIRST + 1 {
		_, ok = texture_add(r, {pixels = image[:4], width = 1, height = 1, name = "filler"})
		testing.expect(t, ok, r.error)
		if !ok {return}
	}
	last := Texture_Handle(texture_count(r))
	testing.expect_value(t, texture_index(r, last), u32(TEXTURE_RESERVED + rhi.TEXTURE_TABLE_FIRST))
	testing.expect(t, texture_capacity(r) == rhi.texture_table_limit(f.device) - TEXTURE_RESERVED && texture_capacity(r) > rhi.TEXTURE_TABLE_FIRST)
	// A material that names a texture that does not exist renders without it.
	material := DEFAULT_MATERIAL
	material.textures[.Base_Color] = last + 5
	materials_set(r, {material})
	testing.expect_value(t, r.scene.materials[1].textures[.Base_Color], GPU_NONE)
	textures_clear(r)
	testing.expect_value(t, texture_count(r), 0)
	_, ok = texture_add(r, {pixels = image[:4], width = 1, height = 1, name = "after clear"})
	testing.expect(t, ok, r.error)
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

@(test)
material_changes_keep_frames_allocation_free :: proc(t: ^testing.T) {
	f: Fixture
	if !fixture_init(t, &f, 64, 64, material_settings(), reference = {.Lights}) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	texel := [4]u8{90, 160, 220, 255}
	texture, added := texture_add(r, {pixels = texel[:], width = 1, height = 1, srgb = true, name = "texel"})
	testing.expect(t, added, r.error)
	material := DEFAULT_MATERIAL
	material.textures[.Base_Color] = texture
	materials_set(r, {material})
	quad := ground_quad(r, 1)
	scene_given(r, {{object_id = 1, mesh = quad, transform = Mat4(1), tint = {1, 1, 1}}}, nil, {}, {})
	frames(t, &f, OVERHEAD, 4)
	tlas_nodes := len(r.scene.tlas_nodes)
	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, context.allocator)
	defer mem.tracking_allocator_destroy(&tracker)
	{
		context.allocator = mem.tracking_allocator(&tracker)
		for i in 0 ..< 4 {
			material.roughness = 0.2 + 0.2 * f32(i)
			materials_set(r, {material})
			testing.expect(t, !r.scene.instances_dirty && !r.scene.lights_dirty, "a change of values leaves the instances, the TLAS and the lights alone")
			testing.expect(t, fixture_frame(&f, {camera = OVERHEAD}), r.error)
		}
	}
	testing.expect_value(t, tracker.total_allocation_count, i64(0))
	testing.expect_value(t, len(r.scene.tlas_nodes), tlas_nodes)
	testing.expectf(t, abs(read_normal(t, &f, OVERHEAD, {}).w - 0.8) < 0.01, "the last roughness is on screen: %v", read_normal(t, &f, OVERHEAD, {}))
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

@(test)
material_smooth_surfaces_reflect_the_scene :: proc(t: ^testing.T) {
	f: Fixture
	if !fixture_init(t, &f, 96, 64, material_settings(), reference = {.Lights}) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	mirror, lamp := DEFAULT_MATERIAL, DEFAULT_MATERIAL
	mirror.base_color = {0.9, 0.9, 0.9}
	mirror.metallic = 1
	mirror.roughness = 0.05
	lamp.base_color = {0, 0, 0}
	lamp.emission = {4, 0, 0}
	materials_set(r, {mirror, lamp})
	quad := ground_quad(r)
	// A red emitter hangs over a mirror floor; the camera looks at the floor
	// point that mirrors it.
	emitter := scale_matrix(1.5)
	emitter[1, 3] = 2
	emitter[2, 3] = -2
	instances := []Instance_Desc{
		{object_id = 1, mesh = quad, transform = scale_matrix(20), material = 1, tint = {1, 1, 1}},
		{object_id = 2, mesh = quad, transform = emitter, material = 2, tint = {1, 1, 1}},
	}
	scene_given(r, instances, nil, {}, {sky = {0, 0, 0.2}})
	camera := Camera{position = {0, 2, 2}, forward = {0, -2, -2}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	floor_point :: proc(t: ^testing.T, f: ^Fixture, camera: Camera, world: Vec3) -> [3]f32 {
		r := f.renderer
		for _ in 0 ..< 3 {testing.expect(t, fixture_frame(f, {camera = camera}), r.error)}
		rhi.device_wait_idle(f.device)
		pixels, w, _, ok := golden_capture(r)
		testing.expect(t, ok, r.error)
		if !ok {return {}}
		defer delete(pixels)
		p := target_pixel(r, camera, world)
		i := (p.y * w + p.x) * 4
		return {f32(pixels[i]), f32(pixels[i + 1]), f32(pixels[i + 2])}
	}
	mirrored := floor_point(t, &f, camera, {0, 0, 0})
	beside := floor_point(t, &f, camera, {3, 0, 0})
	testing.expectf(t, mirrored.r > 150 && mirrored.r > mirrored.b * 3, "the mirror shows the red emitter: %v", mirrored)
	testing.expectf(t, beside.b > beside.r + 20, "next to it the mirror shows the sky: %v", beside)
	testing.expect_value(t, r.stats.rays_per_frame, u64(r.targets.half_width * r.targets.half_height) + u64(r.targets.width * r.targets.height)) // a mirror ray per pixel, and the sun ray of each block the statistics count of the Direct stage

	settings := r.settings
	settings.reflections = .Off
	testing.expect(t, renderer_apply_settings(r, settings))
	untraced := floor_point(t, &f, camera, {0, 0, 0})
	testing.expectf(t, untraced.r < 40, "without traced reflections the mirror only has the probe volume: %v", untraced)

	// A rough floor never traces: the pass is skipped altogether.
	settings.reflections = .Detailed
	testing.expect(t, renderer_apply_settings(r, settings))
	mirror.roughness = 0.9
	materials_set(r, {mirror, lamp})
	rough := floor_point(t, &f, camera, {0, 0, 0})
	testing.expectf(t, rough.r < 60, "a rough metal does not mirror: %v", rough)
	settings.reflection_roughness = 2
	testing.expect(t, !renderer_apply_settings(r, settings), "a limit outside 0 to 1 is rejected")
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

// Without traced reflections a mirror reads the probe volume, which holds the
// sky blurred over a hemisphere: under an open sky it shows the sky as sharp
// as without the volume, and under a roof the roof, not the sky.
@(test)
material_mirror_reads_the_sky_sharp_from_the_probes_and_not_under_a_roof :: proc(t: ^testing.T) {
	f: Fixture
	settings := material_settings()
	settings.gi_enabled = true
	settings.reflections = .Off
	if !fixture_init(t, &f, 64, 64, settings) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	// A sky lit only within 22.5 degrees of the zenith: blurred over a hemisphere, a sixth of it
	// reaches straight up.
	WIDE, TALL :: 32, 16
	image: [WIDE * TALL * 4]u8
	for i in 0 ..< WIDE * 2 * 4 {image[i] = 255}
	sky, added := texture_add(r, {pixels = image[:], width = WIDE, height = TALL, name = "zenith"})
	testing.expect(t, added, r.error)
	mirror, roof := DEFAULT_MATERIAL, DEFAULT_MATERIAL
	mirror.base_color = {0.9, 0.9, 0.9}
	mirror.metallic = 1
	mirror.roughness = 0.05
	roof.base_color = {0.2, 0.2, 0.2}
	materials_set(r, {mirror, roof})
	quad := ground_quad(r)
	floor := Instance_Desc{object_id = 1, mesh = quad, transform = scale_matrix(20), material = 1, tint = {1, 1, 1}}
	environment := Environment{sky = {1, 1, 1}, sky_texture = sky}
	scene_given(r, {floor}, nil, {}, environment)
	settled :: proc(t: ^testing.T, f: ^Fixture, camera: Camera) -> [3]f32 {
		frames(t, f, camera, 48)
		return screen_color(t, f, camera, {0, 0, 0})
	}
	// Looking straight down, the floor mirrors the zenith.
	probed := settled(t, &f, OVERHEAD)
	settings.gi_enabled = false
	testing.expect(t, renderer_apply_settings(r, settings))
	sky_only := settled(t, &f, OVERHEAD)
	testing.expectf(t, sky_only.r > 100, "without the volume the mirror shows the lit zenith: %v", sky_only)
	testing.expectf(t, abs(probed.r - sky_only.r) < 12, "with the volume the mirror shows the zenith as sharp: %v against %v", probed, sky_only)

	// A roof facing down over the floor, the eye under it.
	settings.gi_enabled = true
	testing.expect(t, renderer_apply_settings(r, settings))
	over := scale_matrix(4)
	over[1, 1], over[2, 2], over[1, 3] = -4, -4, 1.2
	scene_given(r, {floor, {object_id = 2, mesh = quad, transform = over, material = 2, tint = {1, 1, 1}}}, nil, {}, environment)
	under := OVERHEAD
	under.position = {0, 0.8, 0}
	roofed := settled(t, &f, under)
	testing.expectf(t, roofed.r < sky_only.r * 0.5, "under a roof the mirror does not show the sky: %v against %v", roofed, sky_only)
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

// A ray that finds a surface with a program shows what the program gives
// there (points.odin), not the values of its row: no stage of rays runs it.
// With the program alone in the scene its stage takes the whole window of
// points; with another one the points are binned by program.
@(test)
material_program_shows_in_what_a_reflection_finds :: proc(t: ^testing.T) {
	f: Fixture
	if !fixture_init(t, &f, 96, 64, material_settings(), programs = true, reference = {.Lights}) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	grid, pieces := program_find(r, "Grid", .Surface), program_find(r, "Pieces", .Surface)
	testing.expect(t, grid != nil && pieces != nil, "the tests have the Grid and Pieces programs")
	if grid == nil || pieces == nil {return}
	mirror, wall, other := DEFAULT_MATERIAL, DEFAULT_MATERIAL, DEFAULT_MATERIAL
	other.program_id = pieces.id
	other.custom_params = program_defaults(pieces)
	mirror.base_color = {0.9, 0.9, 0.9}
	mirror.metallic = 1
	mirror.roughness = 0.05
	// Its row is blue; its program paints it red.
	wall.base_color = {0, 0, 1}
	wall.program_id = grid.id
	wall.custom_params = program_defaults(grid)
	testing.expect(t, program_parameter_set(&wall.custom_params, program_parameter(grid, "color"), {1, 0, 0, 0}))
	testing.expect(t, program_parameter_set(&wall.custom_params, program_parameter(grid, "line_color"), {1, 0, 0, 0}))
	quad := ground_quad(r)
	// A wall stands beyond a mirror floor, turned about x to face +z, lit from the side of the camera.
	standing := scale_matrix(10)
	standing[1, 1], standing[1, 2], standing[2, 1], standing[2, 2] = 0, -10, 10, 0
	standing[2, 3] = -3
	instances := []Instance_Desc{
		{object_id = 1, mesh = quad, transform = scale_matrix(20), material = 1, tint = {1, 1, 1}},
		{object_id = 2, mesh = quad, transform = standing, material = 2, tint = {1, 1, 1}},
	}
	sun := Sun_Desc{direction = linalg.normalize(Vec3{0, 0.5, 1}), color = {1, 1, 1}, illuminance = math.PI, enabled = true}
	camera := Camera{position = {0, 2, 2}, forward = {0, -2, -2}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	for binned in ([]bool{false, true}) {
		// The other program is in a row of the table that no instance takes.
		materials_set(r, {mirror, wall, other if binned else DEFAULT_MATERIAL})
		scene_given(r, instances, nil, sun, {sky = {0, 0, 0.05}})
		testing.expect_value(t, r.scene.programs_used, u32(2 if binned else 1))
		mirrored := screen_color(t, &f, camera, {0, 0, 0})
		testing.expectf(t, mirrored.r > 100 && mirrored.r > 3 * mirrored.b, "binned %v: the mirror shows the wall as its program paints it: %v", binned, mirrored)
	}
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

// With the pipeline thread a frame does not wait for the driver to make the
// pipelines of a program it meets (pipeline_thread.odin): it draws its
// materials as their rows, on the camera as on the rays, and the frames after
// they are made draw the program. A thumbnail, read back at once, waits for
// them.
@(test)
material_program_draws_as_its_rows_until_its_pipelines_are_made :: proc(t: ^testing.T) {
	f: Fixture
	if !fixture_init(t, &f, 96, 64, material_settings(), desc = {pipeline_thread = true}, programs = true, reference = {.Lights}) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	grid := program_find(r, "Grid", .Surface)
	if !testing.expect(t, grid != nil, "the tests have the Grid program") {return}
	mirror, wall := DEFAULT_MATERIAL, DEFAULT_MATERIAL
	mirror.base_color, mirror.metallic, mirror.roughness = {0.9, 0.9, 0.9}, 1, 0.05
	// Its row is blue; its program paints it red.
	wall.base_color = {0, 0, 1}
	wall.program_id = grid.id
	wall.custom_params = program_defaults(grid)
	for name in ([]string{"color", "line_color"}) {testing.expect(t, program_parameter_set(&wall.custom_params, program_parameter(grid, name), {1, 0, 0, 0}))}
	state: Thumbnail_GPU
	defer thumbnail_destroy(f.device, &state)
	positions := [6]Vec3{{-1, 0, -1}, {1, 0, 1}, {1, 0, -1}, {-1, 0, -1}, {-1, 0, 1}, {1, 0, 1}}
	vertices: [6]Thumbnail_Vertex
	for position, i in positions {vertices[i] = {position = position, normal = {0, 1, 0}, tint = {1, 1, 1}}}
	pixels := make([]u8, 64 * 64 * 4)
	defer delete(pixels)
	if testing.expect(t, renderer_thumbnail(r, &state, vertices[:], {wall}, 64, 64, pixels), r.error) {
		center := (32 * 64 + 32) * 4
		testing.expectf(t, pixels[center] > pixels[center + 2] + 70, "a thumbnail draws the program at once: %v", pixels[center:center + 4])
	}
	materials_set(r, {mirror, wall})
	quad := ground_quad(r)
	standing := scale_matrix(10)
	standing[1, 1], standing[1, 2], standing[2, 1], standing[2, 2] = 0, -10, 10, 0
	standing[2, 3] = -3
	scene_given(r, {
		{object_id = 1, mesh = quad, transform = scale_matrix(20), material = 1, tint = {1, 1, 1}},
		{object_id = 2, mesh = quad, transform = standing, material = 2, tint = {1, 1, 1}},
	}, nil, {direction = linalg.normalize(Vec3{0, 0.5, 1}), color = {1, 1, 1}, illuminance = math.PI, enabled = true}, {sky = {0, 0, 0.05}})
	camera := Camera{position = {0, 2, 2}, forward = {0, -2, -2}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	look :: proc(t: ^testing.T, f: ^Fixture, camera: Camera) -> (seen, mirrored: [3]f32) {
		rhi.device_wait_idle(f.device)
		pixels, w, _, ok := golden_capture(f.renderer)
		testing.expect(t, ok, f.renderer.error)
		if !ok {return}
		defer delete(pixels)
		at :: proc(r: ^Renderer, pixels: []u8, w: int, camera: Camera, world: Vec3) -> [3]f32 {
			p := target_pixel(r, camera, world, true)
			i := (p.y * w + p.x) * 4
			return {f32(pixels[i]), f32(pixels[i + 1]), f32(pixels[i + 2])}
		}
		return at(f.renderer, pixels, w, camera, {0, 0.3, -3}), at(f.renderer, pixels, w, camera, {0, 0, 0})
	}
	testing.expect(t, fixture_frame(&f, {camera = camera}), r.error)
	testing.expect(t, renderer_pipelines_pending(r), "the frame asked the thread for the pipelines of the program")
	seen, mirrored := look(t, &f, camera)
	testing.expectf(t, seen.b > seen.r + 40 && mirrored.b > mirrored.r + 40, "until they are made the wall is its row: %v, in the mirror %v", seen, mirrored)
	for renderer_pipelines_pending(r) {
		renderer_pipelines_wait(r)
		renderer_reset_history(r)
		frames(t, &f, camera, 3)
	}
	seen, mirrored = look(t, &f, camera)
	testing.expectf(t, seen.r > 3 * seen.b && mirrored.r > 3 * mirrored.b, "then it is what its program paints: %v, in the mirror %v", seen, mirrored)
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

// When programs get rows the pipelines of every stage those rows are drawn
// with are asked for (programs_ask), before a frame draws with them: a camera
// that turns to a mirror, or to layers, finds them made.
@(test)
material_program_pipelines_are_made_before_a_frame_draws_with_them :: proc(t: ^testing.T) {
	f: Fixture
	if !fixture_init(t, &f, 64, 48, material_settings(), desc = {pipeline_thread = true}, programs = true) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	programs := [2]^Program{program_find(r, "Grid", .Surface), program_find(r, "Pieces", .Surface)}
	if !testing.expect(t, programs[0] != nil && programs[1] != nil, "the tests have the Grid and Pieces programs") {return}
	rows: [2]Material_Desc
	for &row, i in rows {
		row = DEFAULT_MATERIAL
		row.program_id, row.custom_params = programs[i].id, program_defaults(programs[i])
	}
	materials_set(r, rows[:])
	camera := Camera{position = {0, 2, 2}, forward = {0, -2, -2}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	testing.expect(t, fixture_frame(&f, {camera = camera}), r.error)
	renderer_pipelines_wait(r, all = true)
	for program in programs {
		for id in ([]Pipeline_Id{.Gbuffer, .Gbuffer_Plain, .Gbuffer_Layers}) {
			testing.expectf(t, program_graphics(r, &r.pipelines[id], program.id) != r.pipelines[id], "the pipeline of %s for %v is made before a frame draws with it", program.name, id)
		}
		testing.expectf(t, r.points.stages.pipelines[program.id] != 0, "and that of its points")
	}
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

// The surfaces the camera sees show what their programs give
// (program_stages.odin), those of the G-buffer and those of the layers of
// glass, not the values of their rows.
@(test)
material_program_shows_on_what_the_camera_sees :: proc(t: ^testing.T) {
	f: Fixture
	if !fixture_init(t, &f, 64, 64, material_settings(), programs = true, reference = {.Lights}) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	grid := program_find(r, "Grid", .Surface)
	if !testing.expect(t, grid != nil, "the tests have the Grid program") {return}
	// Their rows are blue; their program paints them red.
	painted := DEFAULT_MATERIAL
	painted.base_color = {0, 0, 1}
	painted.program_id = grid.id
	painted.custom_params = program_defaults(grid)
	for name in ([]string{"color", "line_color"}) {testing.expect(t, program_parameter_set(&painted.custom_params, program_parameter(grid, name), {1, 0, 0, 0}))}
	glass := painted
	glass.alpha_mode, glass.opacity = .Blend, 0.6
	materials_set(r, {painted, glass})
	quad := ground_quad(r)
	sun := Sun_Desc{direction = {0, 1, 0}, color = {1, 1, 1}, illuminance = math.PI, enabled = true}
	camera := OVERHEAD
	camera.position.y = 5
	scene_given(r, {{object_id = 1, mesh = quad, transform = scale_matrix(20), material = 1, tint = {1, 1, 1}}}, nil, sun, {})
	floor := screen_color(t, &f, camera, {})
	testing.expectf(t, floor.r > 100 && floor.r > 3 * floor.b, "the floor shows its program: %v", floor)
	// A white floor under a sheet of the glass.
	scene_given(r, {
		{object_id = 1, mesh = quad, transform = scale_matrix(20), tint = {1, 1, 1}},
		{object_id = 2, mesh = quad, transform = placed(4, 1), material = 2, tint = {1, 1, 1}},
	}, nil, sun, {})
	through := screen_color(t, &f, camera, {})
	testing.expectf(t, through.r > 2 * through.b, "the glass shows its program: %v", through)
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

// The parameters of the Pieces program that send its one red piece distance
// metres along +X at progress 0, without turning it.
@(private = "file")
pieces_material :: proc(t: ^testing.T, pieces: ^Program, progress: f64) -> Material_Desc {
	m := DEFAULT_MATERIAL
	m.base_color = {1, 0, 0}
	m.program_id = pieces.id
	m.custom_params = program_defaults(pieces)
	Value :: struct {name: string, value: [4]f64}
	for v in ([]Value{{"progress", {progress, 0, 0, 0}}, {"spread", {}}, {"turn", {}}, {"direction", {1, 0, 0, 0}}, {"distance", {3, 0, 0, 0}}, {"reach", {3, 0, 0, 0}}, {"color", {1, 0, 0, 0}}}) {
		testing.expectf(t, program_parameter_set(&m.custom_params, program_parameter(pieces, v.name), v.value), "Pieces takes %s", v.name)
	}
	return m
}

// A program that moves vertices (Pieces) moves what the camera sees, what
// casts the shadow a ray finds, with both tracers, and draws the motion of
// the frame its parameters move it in, and none in the next.
@(test)
material_program_moves_the_vertices_the_camera_the_rays_and_the_motion_see :: proc(t: ^testing.T) {
	f: Fixture
	if !fixture_init(t, &f, 64, 64, material_settings(), programs = true, reference = {.Lights}) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	pieces := program_find(r, "Pieces", .Surface)
	if !testing.expect(t, pieces != nil && pieces.vertex.declared, "the tests have the Pieces program, which moves vertices") {return}
	materials_set(r, {pieces_material(t, pieces, 0)})
	// One piece (uv1.x 0) whose pivot is the centre of its bounds (a grey color).
	corners := [4]Vec3{{-0.5, 0, -0.5}, {0.5, 0, -0.5}, {0.5, 0, 0.5}, {-0.5, 0, 0.5}}
	vertices: [4]Mesh_Vertex
	for c, i in corners {vertices[i] = {position = c, normal = {0, 1, 0}, tangent = {1, 0, 0, 1}, uv = {c.x + 0.5, c.z + 0.5}, color = {0.5, 0.5, 0.5}}}
	piece, added := mesh_add(r, vertices[:], []u32{0, 2, 1, 0, 3, 2})
	if !testing.expect(t, added, r.error) {return}
	floor := ground_quad(r)
	sun := Sun_Desc{direction = {0, 1, 0}, color = {1, 1, 1}, illuminance = math.PI, enabled = true}
	instances := []Instance_Desc{
		{object_id = 1, mesh = floor, transform = scale_matrix(20), tint = {1, 1, 1}},
		{object_id = 2, mesh = piece, transform = placed(1, 1), material = 1, tint = {1, 1, 1}},
	}
	above := Camera{position = {1.5, 6, 0}, forward = {0, -1, 0}, up = {0, 0, -1}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	side := Camera{position = {0, 3, 6}, forward = {0, -3, -6}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	for provider in ([]Trace_Mode{.Software, .Hardware}) {
		if provider == .Hardware && !r.hardware_rt_verified {continue}
		settings := r.settings; settings.trace_mode = provider
		testing.expect(t, renderer_apply_settings(r, settings), r.error)
		for progress in ([]f64{0, 1}) {
			materials_set(r, {pieces_material(t, pieces, progress)})
			scene_given(r, instances, nil, sun, {})
			there, away := Vec3{3, 1, 0}, Vec3{0, 1, 0}
			if progress == 1 {there, away = away, there}
			frames(t, &f, above, 2)
			seen, left := read_albedo(t, &f, above, there), read_albedo(t, &f, above, away)
			// The pivot in its vertex color (grey) tints its red.
			testing.expectf(t, seen.r > 100 && seen.g < 30 && seen.b < 30, "%v progress %v: the camera sees the piece where its program put it: %v", provider, progress, seen)
			testing.expectf(t, near_bytes(left, {255, 255, 255, 0}, 3), "%v progress %v: and the floor where it is not: %v", provider, progress, left)
			shaded := screen_color(t, &f, side, {there.x, 0, 0})
			lit := screen_color(t, &f, side, {away.x, 0, 0})
			testing.expectf(t, lit.g > shaded.g + 40, "%v progress %v: the shadow falls under the moved piece: %v vs %v", provider, progress, lit, shaded)
		}
	}
	// Half way the piece is at 3 * 0.5^3 along X: the frame it moves in draws
	// it coming from 3, the next one at rest.
	materials_set(r, {pieces_material(t, pieces, 0)})
	scene_given(r, instances, nil, sun, {})
	frames(t, &f, above, 3)
	materials_update(r, {pieces_material(t, pieces, 0.5)}, {1})
	frames(t, &f, above, 1)
	now := Vec3{3 * 0.125, 1, 0}
	half := read_albedo(t, &f, above, now)
	testing.expectf(t, half.r > 100 && half.g < 30 && half.b < 30, "the piece is half way: %v", half)
	moving := target_at(t, &f, r.targets.motion, above, now)
	// From 3 to 0.375 m along X, 5 m under a camera of 60 degrees: 0.45 of the image.
	testing.expectf(t, moving.x > 0.3 && moving.x < 0.6 && abs(moving.y) < 0.02, "the pixel comes from where the piece was: %v", moving)
	frames(t, &f, above, 1)
	still := target_at(t, &f, r.targets.motion, above, now)
	testing.expectf(t, abs(still.x) < 0.01 && abs(still.y) < 0.01, "a piece that stopped draws no motion: %v", still)
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

// Color on screen at a world position, after a few frames.
@(private = "file")
screen_color :: proc(t: ^testing.T, f: ^Fixture, camera: Camera, world: Vec3) -> [3]f32 {
	r := f.renderer
	frames(t, f, camera, 3)
	rhi.device_wait_idle(f.device)
	pixels, w, _, ok := golden_capture(r)
	testing.expect(t, ok, r.error)
	if !ok {return {}}
	defer delete(pixels)
	p := target_pixel(r, camera, world, true)
	i := (p.y * w + p.x) * 4
	return {f32(pixels[i]), f32(pixels[i + 1]), f32(pixels[i + 2])}
}

@(private = "file")
placed :: proc(scale: f32, height: f32) -> Mat4 {
	m := scale_matrix(scale)
	m[1, 3] = height
	return m
}

@(test)
material_mask_cuts_holes_for_the_camera_and_for_rays :: proc(t: ^testing.T) {
	f: Fixture
	if !fixture_init(t, &f, 96, 64, material_settings(), reference = {.Lights}) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	// The left half of the image is solid and the right half is a hole.
	SIZE :: 8
	image: [SIZE * SIZE * 4]u8
	for y in 0 ..< SIZE {
		for x in 0 ..< SIZE {
			at := (y * SIZE + x) * 4
			image[at], image[at + 1], image[at + 2] = 255, 255, 255
			image[at + 3] = 255 if x < SIZE / 2 else 0
		}
	}
	texture, added := texture_add(r, {pixels = image[:], width = SIZE, height = SIZE, srgb = true, alpha_coverage = 0.5, name = "half"})
	testing.expect(t, added, r.error)
	cutout := DEFAULT_MATERIAL
	cutout.base_color = {1, 0, 0}
	cutout.alpha_mode = .Mask
	cutout.textures[.Base_Color] = texture
	quad := ground_quad(r)
	// UV1 varies across the triangle while UV0 always selects the solid half.
	corners := [4]Vec3{{-0.5, 0, -0.5}, {0.5, 0, -0.5}, {0.5, 0, 0.5}, {-0.5, 0, 0.5}}
	vertices: [4]Mesh_Vertex
	for c, i in corners {vertices[i] = {position = c, normal = {0, 1, 0}, uv = {0.25, 0.25}, uv1 = {c.x + 0.5, c.z + 0.5}, color = {1, 1, 1}}}
	secondary, added_mesh := mesh_add(r, vertices[:], []u32{0, 2, 1, 0, 3, 2})
	testing.expect(t, added_mesh, r.error)
	sun := Sun_Desc{direction = {0, 1, 0}, color = {1, 1, 1}, illuminance = 1 * math.PI, enabled = true}
	instances := []Instance_Desc{
		{object_id = 1, mesh = quad, transform = scale_matrix(20), tint = {1, 1, 1}},
		{object_id = 2, mesh = quad, transform = placed(2, 1), material = 1, tint = {1, 1, 1}},
	}
	above := Camera{position = {0, 4, 0}, forward = {0, -4, 0}, up = {0, 0, -1}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	// From the side: the solid half shades the floor and the hole lets the sun through.
	side := Camera{position = {0, 3, 6}, forward = {0, -3, -6}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	for provider in ([]Trace_Mode{.Software, .Hardware}) {
		if provider == .Hardware && !r.hardware_rt_verified {continue}
		settings := r.settings; settings.trace_mode = provider
		testing.expect(t, renderer_apply_settings(r, settings), r.error)
		cutout.alpha_mode, cutout.opacity = .Mask, 1
		cutout.textures[.Base_Color] = texture
		for mesh, uv_set in ([2]Mesh_Handle{quad, secondary}) {
			cutout.maps.base_color.uv_set = u32(uv_set)
			materials_set(r, {cutout})
			instances[1].mesh = mesh
			scene_given(r, instances, nil, sun, {})
			frames(t, &f, above, 2)
			testing.expectf(t, near_bytes(read_albedo(t, &f, above, {-0.5, 1, 0}), {255, 0, 0, 0}, 3), "%v UV%d solid half is drawn", provider, uv_set)
			testing.expectf(t, near_bytes(read_albedo(t, &f, above, {0.5, 1, 0}), {255, 255, 255, 0}, 3), "%v UV%d floor shows through the hole", provider, uv_set)
			testing.expect(t, r.scene.instances[1].meta.w & INSTANCE_FLAG_ALPHA_TESTED != 0 && r.scene.instances[0].meta.w & INSTANCE_FLAG_ALPHA_TESTED == 0, "only the masked instance asks its material")
			shaded := screen_color(t, &f, side, {-0.5, 0, 0.8})
			lit := screen_color(t, &f, side, {0.5, 0, 0.8})
			testing.expectf(t, lit.g > shaded.g + 40, "%v UV%d ray shadow follows the cutout: %v vs %v", provider, uv_set, lit, shaded)
		}
		// A masked material without a base map reads only its uniform opacity.
		cutout.textures[.Base_Color] = 0
		cutout.opacity = 1
		materials_set(r, {cutout})
		covered := screen_color(t, &f, side, {0.5, 0, 0.8})
		frames(t, &f, above, 2)
		testing.expectf(t, near_bytes(read_albedo(t, &f, above, {0.5, 1, 0}), {255, 0, 0, 0}, 3), "%v uniform mask covers the camera", provider)
		cutout.opacity = 0
		materials_set(r, {cutout})
		open := screen_color(t, &f, side, {0.5, 0, 0.8})
		frames(t, &f, above, 2)
		testing.expectf(t, near_bytes(read_albedo(t, &f, above, {0.5, 1, 0}), {255, 255, 255, 0}, 3), "%v uniform mask opens for the camera", provider)
		testing.expectf(t, open.g > covered.g + 40, "%v uniform mask opens for rays: %v vs %v", provider, open, covered)
		// A material that turns opaque fills its holes and stops asking.
		cutout.alpha_mode = .Opaque
		materials_set(r, {cutout})
		frames(t, &f, above, 2)
		testing.expectf(t, near_bytes(read_albedo(t, &f, above, {0.5, 1, 0}), {255, 0, 0, 0}, 3), "an opaque material has no holes: %v", read_albedo(t, &f, above, {0.5, 1, 0}))
		testing.expect(t, r.scene.instances[1].meta.w & INSTANCE_FLAG_ALPHA_TESTED == 0)
	}
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

@(test)
material_selection_mask_respects_surface_alpha :: proc(t:^testing.T) {
    f:Fixture
    settings:=material_settings();settings.gi_enabled=false
    if !fixture_init(t,&f,96,64,settings) {return}
    defer fixture_destroy(&f)
    r:=f.renderer
    image:[8*8*4]u8
    for y in 0..<8 {for x in 0..<8 {
        at:=(y*8+x)*4
        image[at]=255;image[at+1]=255;image[at+2]=255;image[at+3]=255 if x<4 else 0
    }}
    texture,added:=texture_add(r,{pixels=image[:],width=8,height=8,srgb=true,alpha_coverage=0.5,name="selection cutout"})
    testing.expect(t,added,r.error)
    cutout:=DEFAULT_MATERIAL;cutout.base_color={0.1,0.1,0.1};cutout.alpha_mode=.Mask;cutout.textures[.Base_Color]=texture
    materials_set(r,{cutout})
    mesh:=ground_quad(r)
    scene_given(r,{{object_id=1,mesh=mesh,transform=Mat4(1),material=1,tint={1,1,1},highlight=1}},nil,{},{background={0,0,0},use_background=true})
    testing.expect(t,renderer_set_highlight_style(r,{colors={0={0,1,0,1}},fill={0=1},width=2}))
    camera:=Camera{position={0,4,0},forward={0,-4,0},up={0,0,-1},fov_y=60,near=0.05,far=100,exposure=UNIT_EXPOSURE}
    // Probe inside each texture half, away from the quad silhouette where
    // bilinear Retina reconstruction intentionally softens partial coverage.
    solid:=screen_color(t,&f,camera,{-0.25,0,0});hole:=screen_color(t,&f,camera,{0.25,0,0})
    testing.expectf(t,solid.g>200 && hole.g<20,"Selection follows the visible cutout: solid%v hole%v",solid,hole)
    reference_mask:[96*64*2]f32
    testing.expect(t,golden_read_texture(f.device,r.targets.highlight,mem.slice_data_cast([]u8,reference_mask[:])))
    // Preserve the same 96x64 logical-point mask while TAA reconstructs a
    // Retina drawable from both internal resolutions. Compare mask coverage,
    // independently of the scene lighting/history beneath the editor coat.
    renderer_resize(r,192,128,2,2)
    for lines in ([]u32{32,64}) {
        settings.resolution=lines;settings.taa=true
        testing.expect(t,renderer_apply_settings(r,settings),r.error)
        solid_scaled:=screen_color(t,&f,camera,{-0.25,0,0})
        hole_scaled:=screen_color(t,&f,camera,{0.25,0,0})
        testing.expectf(t,solid_scaled.g>200 && hole_scaled.g<20,"Cutout remains covered/open under TAA and %v lines: solid%v hole%v",lines,solid_scaled,hole_scaled)
        testing.expect_value(t,r.targets.highlight_width,u32(96))
        testing.expect_value(t,r.targets.highlight_height,u32(64))
        mask:[96*64*2]f32
        testing.expect(t,golden_read_texture(f.device,r.targets.highlight,mem.slice_data_cast([]u8,mask[:])))
        changed:=0
        for pixel in 0..<96*64 {if mask[pixel*2]!=reference_mask[pixel*2] {changed+=1}}
        testing.expectf(t,changed==0,"Logical-point alpha coverage is identical across Retina/TAA/downscale: %d changed texels at %v lines",changed,lines)
    }
    cutout.alpha_mode=.Opaque;materials_set(r,{cutout})
    filled:=screen_color(t,&f,camera,{0.25,0,0})
    testing.expect(t,filled.g>200,"Opaque surfaces ignore texture alpha")
    cutout.alpha_mode=.Blend;cutout.opacity=0;materials_set(r,{cutout})
    empty:=screen_color(t,&f,camera,{-0.25,0,0})
    testing.expect(t,empty.g<20,"Fully transparent surfaces add no selection silhouette")
    testing.expectf(t,rhi.device_validation_errors(f.device)==0,"validation: %s",rhi.device_validation_message(f.device))
}

@(test)
material_mask_keeps_its_coverage_far_away :: proc(t: ^testing.T) {
	f: Fixture
	if !fixture_init(t, &f, 64, 64, material_settings(), reference = {.Lights}) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	// Leaves: the alpha of every texel is random, and 40% of them reach the
	// cutoff. Averages of a few texels gather around one half, below it.
	SIZE :: 64
	image := make([]u8, SIZE * SIZE * 4)
	defer delete(image)
	for y in 0 ..< SIZE {
		for x in 0 ..< SIZE {
			at := (y * SIZE + x) * 4
			image[at], image[at + 1], image[at + 2] = 255, 255, 255
			h := u32(x) * 374761393 + u32(y) * 668265263
			h = (h ~ (h >> 13)) * 1274126177
			image[at + 3] = u8(h >> 24)
		}
	}
	plain, ok1 := texture_add(r, {pixels = image, width = SIZE, height = SIZE, srgb = true, name = "fence"})
	kept, ok2 := texture_add(r, {pixels = image, width = SIZE, height = SIZE, srgb = true, alpha_coverage = 0.6, name = "fence with coverage"})
	testing.expect(t, ok1 && ok2, r.error)
	fence := DEFAULT_MATERIAL
	fence.base_color = {1, 0, 0}
	fence.alpha_mode = .Mask
	fence.alpha_cutoff = 0.6
	fence.textures[.Base_Color] = plain
	with_coverage := fence
	with_coverage.textures[.Base_Color] = kept
	materials_set(r, {fence, with_coverage})
	quad := ground_quad(r)
	far := Camera{position = {0, 6, 0}, forward = {0, -6, 0}, up = {0, 0, -1}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	covered :: proc(t: ^testing.T, f: ^Fixture, quad: Mesh_Handle, camera: Camera, material: Material_Handle) -> int {
		r := f.renderer
		instances := []Instance_Desc{
			{object_id = 1, mesh = quad, transform = scale_matrix(20), tint = {1, 1, 1}},
			{object_id = 2, mesh = quad, transform = placed(2, 1), material = material, tint = {1, 1, 1}},
		}
		scene_given(r, instances, nil, {}, {})
		frames(t, f, camera, 2)
		rhi.device_wait_idle(f.device)
		pixels := make([]u8, int(r.targets.width * r.targets.height) * 4, context.temp_allocator)
		testing.expect(t, golden_read_texture(f.device, r.targets.albedo, pixels), rhi.device_error(f.device))
		red := 0
		for i := 0; i < len(pixels); i += 4 {if pixels[i] > 200 && pixels[i + 1] < 60 {red += 1}}
		return red
	}
	// The quad is about 22 pixels across, so each pixel reads a level of a few texels.
	without := covered(t, &f, quad, far, 1)
	with := covered(t, &f, quad, far, 2)
	testing.expectf(t, without < 60, "averaged leaves fall below their cutoff and thin out: %d of 484 pixels", without)
	testing.expectf(t, with > 2 * without && with > 110 && with < 300, "with their coverage kept about 40%% of them stay: %d of 484 pixels", with)
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

@(test)
material_blend_shows_the_scene_through_and_casts_no_shadow :: proc(t: ^testing.T) {
	f: Fixture
	if !fixture_init(t, &f, 96, 64, material_settings(), reference = {.Lights}) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	red, blue := DEFAULT_MATERIAL, DEFAULT_MATERIAL
	red.base_color = {1, 0, 0}
	red.opacity = 0.6
	red.alpha_mode = .Blend
	blue.base_color = {0, 0, 1}
	blue.opacity = 0.6
	blue.alpha_mode = .Blend
	materials_set(r, {red, blue})
	quad := ground_quad(r)
	sun := Sun_Desc{direction = {0, 1, 0}, color = {1, 1, 1}, illuminance = 1 * math.PI, enabled = true}
	floor := Instance_Desc{object_id = 1, mesh = quad, transform = scale_matrix(20), tint = {1, 1, 1}}
	glass := Instance_Desc{object_id = 2, mesh = quad, transform = placed(2, 1), material = 1, tint = {1, 1, 1}}
	scene_given(r, {floor, glass}, nil, sun, {})
	above := Camera{position = {0, 5, 0}, forward = {0, -5, 0}, up = {0, 0, -1}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	through := screen_color(t, &f, above, {0, 1, 0})
	testing.expectf(t, through.r > through.g + 30 && through.g > 40, "the floor shows through the red sheet: %v", through)
	testing.expectf(t, near_bytes(read_albedo(t, &f, above, {0, 1, 0}), {255, 255, 255, 0}, 3), "a blended surface is not in the G-buffer: %v", read_albedo(t, &f, above, {0, 1, 0}))
	testing.expect_value(t, len(r.scene.translucent), 1)
	side := Camera{position = {0, 3, 6}, forward = {0, -3, -6}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	under := screen_color(t, &f, side, {0, 0, 0.8})
	open := screen_color(t, &f, side, {3, 0, 0.8})
	testing.expectf(t, abs(under.g - open.g) < 15, "the sheet casts no shadow: %v under it, %v beside it", under, open)

	// Two sheets are drawn back to front whatever the order they were given in.
	lower := Instance_Desc{object_id = 3, mesh = quad, transform = placed(2, 0.5), material = 2, tint = {1, 1, 1}}
	scene_given(r, {floor, glass, lower}, nil, sun, {})
	first := screen_color(t, &f, above, {0, 1, 0})
	scene_given(r, {floor, lower, glass}, nil, sun, {})
	second := screen_color(t, &f, above, {0, 1, 0})
	testing.expectf(t, first.r > first.b + 30, "the red sheet, nearer the camera, is drawn over the blue one: %v", first)
	testing.expectf(t, abs(first.r - second.r) < 4 && abs(first.b - second.b) < 4, "the order of the instances does not matter: %v and %v", first, second)
	from_below := Camera{position = {0, -5, 0}, forward = {0, 5, 0}, up = {0, 0, -1}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	sun.direction = {0, -1, 0}
	scene_given(r, {glass, lower}, nil, sun, {})
	below := screen_color(t, &f, from_below, {0, 0.5, 0})
	testing.expectf(t, below.b > below.r + 30, "from the other side the blue sheet is the near one: %v", below)

	// Opaque again: it is back in the G-buffer and off the list.
	red.alpha_mode = .Opaque
	blue.alpha_mode = .Opaque
	materials_set(r, {red, blue})
	frames(t, &f, from_below, 2)
	testing.expect_value(t, len(r.scene.translucent), 0)
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

// Read linear light before translucency and tone mapping; the camera can look
// through the filter without confusing its visible color with its shadow.
@(private="file")
read_light :: proc(t:^testing.T,f:^Fixture,camera:Camera,world:Vec3,target:rhi.Texture)->Vec3 {
    rhi.device_wait_idle(f.device)
    r:=f.renderer
    pixels:=make([]f16,int(r.targets.width*r.targets.height)*4,context.temp_allocator)
    testing.expect(t,golden_read_texture(f.device,target,mem.slice_data_cast([]u8,pixels)))
    p:=target_pixel(r,camera,world);i:=(p.y*int(r.targets.width)+p.x)*4
    return {f32(pixels[i]),f32(pixels[i+1]),f32(pixels[i+2])}
}

@(test)
material_colored_shadows_filter_textures_and_respect_blockers :: proc(t:^testing.T) {
    f:Fixture
    if !fixture_init(t,&f,64,64,material_settings(), programs = true, reference = {.Lights}) {return}
    defer fixture_destroy(&f)
    r:=f.renderer
    image:[16*16*4]u8
    for y in 0..<16 {for x in 0..<16 {
        i:=(y*16+x)*4
        image[i]=255 if x<8 else 0;image[i+2]=0 if x<8 else 255
        image[i+3]=255 if y<8 else 0
    }}
    texture,ok:=texture_add(r,{pixels=image[:],width=16,height=16,srgb=true,name="shadow red blue clear"})
    testing.expect(t,ok,r.error)
    glass:=DEFAULT_MATERIAL;glass.alpha_mode=.Blend;glass.textures[.Base_Color]=texture
    materials_set(r,{glass})
    quad:=ground_quad(r)
    // UV0 is always the opaque red texel; only UV1 spans blue and clear.
    corners:=[4]Vec3{{-0.5,0,-0.5},{0.5,0,-0.5},{0.5,0,0.5},{-0.5,0,0.5}}
    vertices:[4]Mesh_Vertex
    for c,i in corners {vertices[i]={position=c,normal={0,1,0},uv={0.25,0.25},uv1={c.x+0.5,c.z+0.5},color={1,1,1}}}
    secondary,secondary_ok:=mesh_add(r,vertices[:],[]u32{0,2,1,0,3,2})
    testing.expect(t,secondary_ok,r.error)
    floor:=Instance_Desc{object_id=1,mesh=quad,transform=scale_matrix(20),tint={1,1,1}}
    filter:=Instance_Desc{object_id=2,mesh=quad,transform=placed(2,1),material=1,tint={1,1,1}}
    opaque:=Instance_Desc{object_id=3,mesh=quad,transform=placed(2,2),tint={1,1,1}}
    camera:=OVERHEAD;camera.position.y=5
    sun:=Sun_Desc{direction={0,1,0},color={1,1,1},illuminance=1 * math.PI,enabled=true}
    spot:=Light_Desc{position={0,4,0},color={1,1,1},intensity=16 * math.PI,range=10,direction={0,-1,0},cone=0.7}
    grid:=program_find(r,"Grid",.Surface)
    if !testing.expect(t,grid!=nil,"the tests have the Grid program") {return}
    for provider in ([]Trace_Mode{.Software,.Hardware}) {
        if provider==.Hardware && !r.hardware_rt_verified {continue}
        for mesh,uv_set in ([2]Mesh_Handle{quad,secondary}) {
            glass.maps.base_color.uv_set=u32(uv_set)
            materials_set(r,{glass})
            filter.mesh=mesh
            settings:=r.settings;settings.trace_mode=provider;settings.colored_shadows=false
            testing.expect(t,renderer_apply_settings(r,settings))
            scene_given(r,{floor,filter},nil,sun,{})
            frames(t, &f,camera,2)
            white:=read_light(t,&f,camera,{-0.4,0,-0.4},r.targets.direct)
            testing.expectf(t,abs(white.r-white.b)<0.01,"%v UV%d disabled filter passes white: %v",provider,uv_set,white)
            settings.colored_shadows=true;testing.expect(t,renderer_apply_settings(r,settings))
            for source in 0..<3 {
                settings.light_budget=0 if source==2 else 8 // source 2 exercises the shadow ray of a sampled light.
                testing.expect(t,renderer_apply_settings(r,settings))
                scene_given(r,{floor,filter},nil if source==0 else ([]Light_Desc{spot}),sun if source==0 else Sun_Desc{},{})
                frames(t, &f,camera,4)
                // The spot gives the scene another light scale: in nits.
                red:=read_light(t,&f,camera,{-0.4,0,-0.4},r.targets.direct)/r.scene.light_scale
                blue:=read_light(t,&f,camera,{0.4,0,-0.4},r.targets.direct)/r.scene.light_scale
                clear:=read_light(t,&f,camera,{0,0,0.4},r.targets.direct)/r.scene.light_scale
                testing.expectf(t,red.r>0.2 && red.r>4*red.b && blue.b>0.2 && blue.b>4*blue.r,"%v UV%d source %d projects the texture: %v and %v",provider,uv_set,source,red,blue)
                testing.expectf(t,clear.r>0.2 && abs(clear.r-clear.b)<0.02,"%v UV%d alpha zero passes white: %v",provider,uv_set,clear)
            }
            // A blocker behind the glass must still stop light; layer traversal
            // must not return as soon as it finds a transmitting surface.
            // Look from the side so the opaque blocker is not the visible pixel.
            camera.position={0,3,6};camera.forward={0,-3,-6};camera.up={0,1,0}
            scene_given(r,{floor,filter,opaque},nil,sun,{})
            frames(t, &f,camera,2)
            blocked:=read_light(t,&f,camera,{-0.4,0,-0.4},r.targets.direct)
            testing.expectf(t,blocked.r+blocked.g+blocked.b<0.01,"%v UV%d opaque geometry behind the filter blocks: %v",provider,uv_set,blocked)
            glass.alpha_mode=.Mask;materials_set(r,{glass})
            scene_given(r,{floor,filter},nil,sun,{})
            frames(t, &f,camera,2)
            masked:=read_light(t,&f,camera,{-0.4,0,-0.4},r.targets.direct)
            hole:=read_light(t,&f,camera,{0,0,0.4},r.targets.direct)
            testing.expectf(t,masked.r+masked.g+masked.b<0.01 && hole.r>0.2,"%v UV%d Mask keeps opaque coverage and transparent holes: %v and %v",provider,uv_set,masked,hole)
            glass.alpha_mode=.Blend;materials_set(r,{glass})
            camera=OVERHEAD;camera.position.y=5
        }
    }
    // Glass whose program paints a cross of blue lines over red cells, on a
    // green row: its shadow shows what the program gives where each ray
    // crosses it, not the mean of the glass, in the blocks of soft shadows
    // and in the rays every pixel of the reference traces. Cells of 20 m:
    // the lines of every ten cross the origin, 0.8 m wide to each side.
    painted:=DEFAULT_MATERIAL;painted.alpha_mode=.Blend;painted.base_color={0,1,0}
    painted.program_id=grid.id;painted.custom_params=program_defaults(grid)
    testing.expect(t,program_parameter_set(&painted.custom_params,program_parameter(grid,"color"),{1,0,0,0}))
    testing.expect(t,program_parameter_set(&painted.custom_params,program_parameter(grid,"line_color"),{0,0,1,0}))
    testing.expect(t,program_parameter_set(&painted.custom_params,program_parameter(grid,"cell"),{20,0,0,0}))
    materials_set(r,{painted})
    wide:=Instance_Desc{object_id=2,mesh=quad,transform=placed(8,1),material=1,tint={1,1,1}}
    for provider in ([]Trace_Mode{.Software,.Hardware}) {
        if provider==.Hardware && !r.hardware_rt_verified || provider==.Software && !SOFTWARE_TRACER {continue}
        for reference in ([2]bool{false,true}) {
            f.reference=Reference_Set{.Lights} if reference else {}
            settings:=r.settings;settings.trace_mode=provider;settings.colored_shadows=true;settings.light_budget=8
            testing.expect(t,renderer_apply_settings(r,settings))
            scene_given(r,{floor,wide},nil,sun,{})
            frames(t, &f,camera,4)
            line:=read_light(t,&f,camera,{},r.targets.direct)
            cell:=read_light(t,&f,camera,{2,0,2},r.targets.direct)
            testing.expectf(t,line.b>0.2 && line.b>4*line.r && cell.r>0.2 && cell.r>4*cell.b && line.g+cell.g<0.05,"%v reference %v: the shadow of the glass shows its program where each ray crosses it: line %v, cell %v",provider,reference,line,cell)
        }
    }
    testing.expectf(t,rhi.device_validation_errors(f.device)==0,"validation: %s",rhi.device_validation_message(f.device))
}

@(test)
uniform_instance_color_overrides_vertex_colors_in_raster_and_shadow_rays :: proc(t:^testing.T) {
    f:Fixture
    if !fixture_init(t,&f,64,64,material_settings(), reference = {.Lights}) {return}
    defer fixture_destroy(&f)
    r:=f.renderer
    vertices:=[4]Mesh_Vertex{
        {position={-0.5,0,-0.5},normal={0,1,0},color={1,0,0}},
        {position={0.5,0,-0.5},normal={0,1,0},color={1,0,0}},
        {position={0.5,0,0.5},normal={0,1,0},color={1,0,0}},
        {position={-0.5,0,0.5},normal={0,1,0},color={1,0,0}},
    }
    mesh,ok:=mesh_add(r,vertices[:],[]u32{0,2,1,0,3,2})
    testing.expect(t,ok);if !ok {return}
    source:=Instance_Desc{object_id=11,mesh=mesh,transform=Mat4(1),tint={1,1,1}}
    scene_given(r,{source},nil,{}, {})
    frames(t, &f,OVERHEAD,2)
    testing.expect(t,near_bytes(read_albedo(t,&f,OVERHEAD,{}),{255,0,0,0},2),"The source retains its authored vertex color")
    source.uniform_color=true
    scene_given(r,{source},nil,{}, {})
    frames(t, &f,OVERHEAD,2)
    testing.expect(t,near_bytes(read_albedo(t,&f,OVERHEAD,{}),{255,255,255,0},2),"Uniform white overrides red mesh vertices")
    source.tint={0,1,0}
    scene_given(r,{source},nil,{}, {})
    frames(t, &f,OVERHEAD,2)
    testing.expect(t,near_bytes(read_albedo(t,&f,OVERHEAD,{}),{0,255,0,0},2),"Uniform appearance keeps the instance tint")

    glass:=DEFAULT_MATERIAL;glass.alpha_mode=.Blend;glass.opacity=0.5
    materials_set(r,{glass})
    floor:=Instance_Desc{object_id=12,mesh=ground_quad(r),transform=scale_matrix(20),tint={1,1,1}}
    source.transform=placed(2,1);source.material=1;source.tint={1,1,1}
    camera:=OVERHEAD;camera.position.y=5
    sun:=Sun_Desc{direction={0,1,0},color={1,1,1},illuminance=1 * math.PI,enabled=true}
    for provider in ([]Trace_Mode{.Software,.Hardware}) {
        if provider==.Hardware && !r.hardware_rt_verified {continue}
        settings:=r.settings;settings.trace_mode=provider;settings.colored_shadows=true
        testing.expect(t,renderer_apply_settings(r,settings))
        source.uniform_color=false
        scene_given(r,{floor,source},nil,sun,{})
        frames(t, &f,camera,2)
        colored:=read_light(t,&f,camera,{},r.targets.direct)
        testing.expectf(t,colored.r>colored.g*1.5 && colored.r>colored.b*1.5,"%v shadows retain ordinary red vertex colors: %v",provider,colored)
        source.uniform_color=true
        scene_given(r,{floor,source},nil,sun,{})
        frames(t, &f,camera,2)
        white:=read_light(t,&f,camera,{},r.targets.direct)
        visible:=screen_color(t,&f,camera,{0,1,0})
        testing.expectf(t,white.r>0.2 && abs(white.r-white.g)<0.01 && abs(white.r-white.b)<0.01,"%v uniform white passes light without coloring it: %v",provider,white)
        testing.expectf(t,abs(visible.r-visible.g)<2 && abs(visible.r-visible.b)<2,"Blended raster uses the same uniform white appearance: %v",visible)
    }
    testing.expectf(t,rhi.device_validation_errors(f.device)==0,"validation: %s",rhi.device_validation_message(f.device))
}

@(test)
material_mirror_lighting_is_exact_with_four_local_lights :: proc(t:^testing.T) {
    f:Fixture
    if !fixture_init(t,&f,64,64,material_settings(), reference = {.Lights}) {return}
    defer fixture_destroy(&f)
    r:=f.renderer
    mirror:=DEFAULT_MATERIAL;mirror.metallic=1;mirror.roughness=0.03
    materials_set(r,{mirror})
    quad:=ground_quad(r)
    patch:=placed(1.5,2);patch[2,3]=-2
    instances:=[]Instance_Desc{
        {object_id=1,mesh=quad,transform=scale_matrix(20),material=1,tint={1,1,1}},
        {object_id=2,mesh=quad,transform=patch,tint={1,1,1}},
    }
    lights:=[]Light_Desc{
        {position={0,1,-2},color={1,1,1},intensity=6 * math.PI,range=6,direction={0,1,0},cone=0.7},
        {position={0,3,-2},color={1,1,1},intensity=6 * math.PI,range=6},
        {position={10,1,-2},color={1,1,1},intensity=6 * math.PI,range=6},
        {position={-10,1,-2},color={1,1,1},intensity=6 * math.PI,range=6},
    }
    scene_given(r,instances,lights,{},{})
    camera:=Camera{position={0,2,2},forward={0,-2,-2},up={0,1,0},fov_y=60,near=0.05,far=100,exposure=UNIT_EXPOSURE}
    for provider in ([]Trace_Mode{.Software,.Hardware}) {
        if provider==.Hardware && !r.hardware_rt_verified {continue}
        settings:=r.settings;settings.trace_mode=provider;settings.reflection_light_budget=8
        testing.expect(t,renderer_apply_settings(r,settings))
        low,high:=f32(1e6),f32(0)
        for _ in 0..<12 {
            frames(t, &f,camera,1)
            lit:=read_light(t,&f,camera,{},r.targets.reflect_raw).r
            low=min(low,lit);high=max(high,lit)
        }
        testing.expectf(t,low>0.5 && high-low<0.005,"%v exact reflected spotlight is stable: %v..%v",provider,low,high)
        // More lights around the patch than a reflected point traces rays
        // to: groups stand for the far ones, the same every frame, so the
        // reflection holds still and shows about the light of them all.
        crowd:[8]Light_Desc
        crowd[0]=lights[0]
        for &light,i in crowd[1:] {light={position={f32(i%3)-1,3+0.2*f32(i),-2},color={1,1,1},intensity=6 * math.PI,range=6}}
        scene_lights_given(r,crowd[:],{},{})
        frames(t, &f,camera,4)
        every:=read_light(t,&f,camera,{},r.targets.reflect_raw).r
        settings.reflection_light_budget=2;testing.expect(t,renderer_apply_settings(r,settings))
        low,high=1e6,0
        for _ in 0..<16 {
            frames(t, &f,camera,1)
            raw:=read_light(t,&f,camera,{},r.targets.reflect_raw).r
            low=min(low,raw);high=max(high,raw)
        }
        testing.expectf(t,high-low<0.005 && abs(low-every)<0.25*every,"%v grouped lighting holds still near that of every light: %v..%v, every light %v",provider,low,high,every)
        scene_lights_given(r,lights,{},{})
    }
    testing.expectf(t,rhi.device_validation_errors(f.device)==0,"validation: %s",rhi.device_validation_message(f.device))
}

@(test)
material_rough_reflections_are_blurred_and_steady :: proc(t: ^testing.T) {
	f: Fixture
	settings := material_settings()
	settings.reflections = .Traced
	if !fixture_init(t, &f, 96, 64, settings, reference = {.Lights}) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	floor, lamp := DEFAULT_MATERIAL, DEFAULT_MATERIAL
	floor.base_color = {0.9, 0.9, 0.9}
	floor.metallic = 1
	lamp.base_color = {0, 0, 0}
	lamp.emission = {4, 0, 0}
	quad := ground_quad(r)
	emitter := scale_matrix(1.5)
	emitter[1, 3] = 2
	emitter[2, 3] = -2
	instances := []Instance_Desc{
		{object_id = 1, mesh = quad, transform = scale_matrix(20), material = 1, tint = {1, 1, 1}},
		{object_id = 2, mesh = quad, transform = emitter, material = 2, tint = {1, 1, 1}},
	}
	camera := Camera{position = {0, 2, 2}, forward = {0, -2, -2}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	// The mirror image of the emitter covers the floor from x = -0.375 to 0.375.
	inside := Vec3{0, 0, 0}
	beside := Vec3{0.6, 0, 0}
	settled :: proc(t: ^testing.T, f: ^Fixture, camera: Camera, world: Vec3) -> [3]f32 {
		frames(t, f, camera, 24)
		return screen_color(t, f, camera, world)
	}
	floor.roughness = 0.05
	materials_set(r, {floor, lamp})
	scene_given(r, instances, nil, {}, {})
	mirror_inside := settled(t, &f, camera, inside)
	mirror_beside := settled(t, &f, camera, beside)
	floor.roughness = 0.3
	materials_set(r, {floor, lamp})
	rough_inside := settled(t, &f, camera, inside)
	rough_beside := settled(t, &f, camera, beside)
	testing.expectf(t, mirror_beside.r < 12, "a mirror keeps the image sharp: %v beside it", mirror_beside)
	testing.expectf(t, rough_beside.r > mirror_beside.r + 15, "a rough surface spreads the image past its edge: %v against %v", rough_beside, mirror_beside)
	testing.expectf(t, rough_inside.r > 40 && rough_inside.r < mirror_inside.r, "and dims it where the mirror showed it: %v against %v", rough_inside, mirror_inside)
	// One ray per pixel, filtered: the image stays put from frame to frame.
	low, high := f32(255), f32(0)
	for _ in 0 ..< 6 {
		sample := screen_color(t, &f, camera, beside).r
		low, high = min(low, sample), max(high, sample)
	}
	testing.expectf(t, high - low < 12, "the filtered reflection flickers between %v and %v", low, high)
	// The rays above were one per block of 2x2 pixels. A ray per pixel shows the same image.
	// The statistics count the sun rays of the Direct stage, one per block, not those of the reference.
	pixels, blocks := u64(r.targets.width * r.targets.height), u64(r.targets.half_width * r.targets.half_height)
	testing.expect_value(t, r.stats.rays_per_frame, 2 * blocks)
	settings.reflections = .Detailed
	testing.expect(t, renderer_apply_settings(r, settings))
	full_inside := settled(t, &f, camera, inside)
	full_beside := settled(t, &f, camera, beside)
	testing.expect_value(t, r.stats.rays_per_frame, blocks + pixels)
	testing.expectf(t, abs(full_inside.r - rough_inside.r) < 14 && abs(full_beside.r - rough_beside.r) < 14, "shared rays change the image: %v and %v against %v and %v", rough_inside, rough_beside, full_inside, full_beside)
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

// Every level of a square BC1 texture of one color, the way a cooked
// texture arrives: 200,100,50 in 5:6:5 on both endpoints.
@(private = "file")
flat_blocks :: proc(size: int) -> (data: Texture_Data) {
	data.format, data.width, data.height = .BC1_Srgb, size, size
	for side := size; ; side = max(side / 2, 1) {
		blocks := (side + 3) / 4
		level := make([]u8, blocks * blocks * 8)
		for i := 0; i < len(level); i += 8 {level[i], level[i + 1], level[i + 2], level[i + 3] = 0x26, 0xc3, 0x26, 0xc3}
		append(&data.levels, level)
		if side == 1 {break}
	}
	return
}

@(test)
block_textures_and_the_pool_bound_memory :: proc(t: ^testing.T) {
	f: Fixture
	settings := material_settings()
	settings.texture_pool_megabytes = 1
	if !fixture_init(t, &f, 64, 64, settings) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	if !rhi.device_info(f.device).features.texture_bc {return}
	testing.expect(t, texture_limits(r).blocks, "the device samples blocks and the setting is on")
	SIZE :: 256
	data := flat_blocks(SIZE)
	defer texture_data_destroy(&data)
	texture, added := texture_add_data(r, data, "compressed")
	testing.expect(t, added, r.error)
	testing.expect_value(t, rhi.texture_desc(f.device, r.textures.textures[0]).format, rhi.Format.BC1_Srgb)
	// An eighth of the 349,524 bytes the levels take as RGBA8, plus the
	// blocks the levels smaller than four texels still fill.
	testing.expect_value(t, r.textures.bytes, u64(43704))
	material := DEFAULT_MATERIAL
	material.textures[.Base_Color] = texture
	materials_set(r, {material})
	quad := ground_quad(r, 1)
	scene_given(r, {{object_id = 1, mesh = quad, transform = Mat4(1), tint = {1, 1, 1}}}, nil, {}, {})
	frames(t, &f, OVERHEAD, 2)
	// What is drawn is the color of the blocks: 24, 25 and 6 widened to 8 bits.
	for point in ([]Vec3{{-0.2, 0, -0.05}, {0.3, 0, 0.45}}) {
		shown := read_albedo(t, &f, OVERHEAD, point)
		testing.expectf(t, abs(shown.r - 198) <= 2 && abs(shown.g - 101) <= 2 && abs(shown.b - 49) <= 2, "at %v the compressed texture shows %v", point, shown)
	}

	// A megabyte of pool: each texture loads with the levels that still fit.
	big := flat_blocks(1024)
	defer texture_data_destroy(&big)
	widths := [3]u32{1024, 512, 256}
	for i in 0 ..< 3 {
		_, ok := texture_add_data(r, big, "big")
		testing.expect(t, ok, r.error)
		desc := rhi.texture_desc(f.device, r.textures.textures[i + 1])
		testing.expectf(t, desc.width == widths[i], "texture %d of the pool is %d wide", i, desc.width)
	}
	testing.expect(t, r.textures.bytes <= 1024 * 1024 + 4096 && r.textures.reduced == 2, "the pool holds what the setting allows")
	// An image made while running is never compressed here.
	image: [8 * 8 * 4]u8
	_, ok := texture_add(r, {pixels = image[:], width = 8, height = 8, srgb = true, name = "plain"})
	testing.expect(t, ok, r.error)
	testing.expect_value(t, rhi.texture_desc(f.device, r.textures.textures[4]).format, rhi.Format.RGBA8_Srgb)
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

@(test)
material_slots_instance_palette_preserves_triangle_partition_and_geometry :: proc(t:^testing.T) {
    f:Fixture
    if !fixture_init(t,&f,128,128,material_settings(), reference = {.Lights}) {return}
    defer fixture_destroy(&f)
    r:=f.renderer
    red,green,blue:=DEFAULT_MATERIAL,DEFAULT_MATERIAL,DEFAULT_MATERIAL
    red.base_color={1,0,0};green.base_color={0,1,0};blue.base_color={0,0,1}
    materials_set(r,{red,green,blue})
    points:=[6]Vec3{{-.5,0,-.5},{.5,0,.5},{.5,0,-.5},{-.5,0,-.5},{-.5,0,.5},{.5,0,.5}}
    vertices:[6]Mesh_Vertex
    for p,i in points {vertices[i]={position=p,normal={0,1,0},color={1,1,1},material=Material_Handle(1 if i<3 else 2),slot=u32(1 if i<3 else 2)}}
    indices:=[6]u32{0,1,2,3,4,5}
    mesh,ok:=mesh_add(r,vertices[:],indices[:]);testing.expect(t,ok)
    desc:=Instance_Desc{object_id=1,mesh=mesh,transform=Mat4(1),tint={1,1,1}}
    desc.slot_materials[1]=4 // row 3, blue; source slot 1 stays red
    scene_given(r,{desc},nil,{},{})
    testing.expect(t,fixture_frame(&f, {camera = OVERHEAD}),r.error)
    a:=read_albedo(t,&f,OVERHEAD,{.25,0,-.25})
    b:=read_albedo(t,&f,OVERHEAD,{-.25,0,.25})
    testing.expect(t,a[0]>230 && a[1]<10 && a[2]<10,"Unassigned triangles retain source material")
    testing.expect(t,b[2]>230 && b[0]<10 && b[1]<10,"Only triangles belonging to the assigned source slot change")
    geometry_vertices,geometry_meshes:=len(r.scene.vertices),len(r.scene.meshes)
    desc.slot_materials={};desc.material=3
    scene_given(r,{desc},nil,{},{})
    testing.expect(t,fixture_frame(&f, {camera = OVERHEAD}),r.error)
    a=read_albedo(t,&f,OVERHEAD,{.25,0,-.25});b=read_albedo(t,&f,OVERHEAD,{-.25,0,.25})
    testing.expect(t,a[2]>230 && b[2]>230,"A global assignment preserves the previous whole mesh behavior")
    testing.expect(t,len(r.scene.vertices)==geometry_vertices && len(r.scene.meshes)==geometry_meshes,"Palette changes reuse the registered geometry and BLAS")
    testing.expectf(t,rhi.device_validation_errors(f.device)==0,"validation: %s",rhi.device_validation_message(f.device))
}

// This checks map binding interpretation on the GPU, rather than only the JSON catalog.
@(test)
material_independent_uv1_bindings_rotation_and_specular_reach_gbuffer :: proc(t:^testing.T) {
    f:Fixture
    if !fixture_init(t,&f,64,64,material_settings(), reference = {.Lights}) {return}
    defer fixture_destroy(&f)
    r:=f.renderer
    SIZE :: 32
    pixels:[SIZE*SIZE*4]u8
    for y in 0..<SIZE do for x in 0..<SIZE {
        at:=(y*SIZE+x)*4
        pixels[at]=255 if x<SIZE/2 else 0
        pixels[at+2]=0 if x<SIZE/2 else 255
        pixels[at+3]=255
    }
    texture,added:=texture_add(r,{pixels=pixels[:],width=SIZE,height=SIZE,srgb=true,name="per-map halves"})
    testing.expect(t,added,r.error)
    material:=DEFAULT_MATERIAL
    material.textures[.Base_Color]=texture
    material.textures[.Emission]=texture
    material.emission={1,1,1}
    material.maps.base_color.uv_set=1
    material.specular_factor=0.5
    material.specular_color={0.5,1,0.25}
    materials_set(r,{material})
    corners:=[4]Vec3{{-0.5,0,-0.5},{0.5,0,-0.5},{0.5,0,0.5},{-0.5,0,0.5}}
    vertices:[4]Mesh_Vertex
    for p,i in corners {vertices[i]={position=p,normal={0,1,0},uv={0.25,0.5},uv1={p.x+0.5,p.z+0.5},color={1,1,1},material=1}}
    mesh,ok:=mesh_add(r,vertices[:],[]u32{0,2,1,0,3,2})
    testing.expect(t,ok,r.error)
    scene_given(r,{{object_id=1,mesh=mesh,transform=Mat4(1),tint={1,1,1}}},nil,{},{})
    frames(t, &f,OVERHEAD,2)
    at:=Vec3{0.25,0,-0.25}
    testing.expectf(t,near_bytes(read_albedo(t,&f,OVERHEAD,at),{0,0,255,0},4),"Base color selects UV1: %v",read_albedo(t,&f,OVERHEAD,at))
    read_half_target :: proc(t:^testing.T,f:^Fixture,target:rhi.Texture,world:Vec3)->Vec4 {
        rhi.device_wait_idle(f.device)
        values:=make([]f16,int(f.renderer.targets.width*f.renderer.targets.height)*4,context.temp_allocator)
        testing.expect(t,golden_read_texture(f.device,target,mem.slice_data_cast([]u8,values)),rhi.device_error(f.device))
        p:=target_pixel(f.renderer,OVERHEAD,world)
        offset:=(p.y*int(f.renderer.targets.width)+p.x)*4
        return {f32(values[offset]),f32(values[offset+1]),f32(values[offset+2]),f32(values[offset+3])}
    }
    emission:=read_half_target(t,&f,r.targets.emission,at)
    testing.expectf(t,emission.x>0.95 && emission.z<0.01,"Emission uses its independent UV0, not the base color map's UV1: %v",emission)
    specular:=read_reflectance(t,f.device,r,r.targets.surface,target_pixel(r,OVERHEAD,at))
    testing.expectf(t,abs(specular.x-0.01)<0.001 && abs(specular.y-0.02)<0.001 && abs(specular.z-0.005)<0.001,"IOR, dielectric specular factor and color reach deferred lighting: %v",specular)
    material.maps.base_color.rotation=3.14159265359
    material.maps.base_color.offset={1,1}
    materials_set(r,{material})
    frames(t, &f,OVERHEAD,2)
    testing.expectf(t,near_bytes(read_albedo(t,&f,OVERHEAD,at),{255,0,0,0},4),"Only the base map rotates by pi: %v",read_albedo(t,&f,OVERHEAD,at))
    emission=read_half_target(t,&f,r.targets.emission,at)
    testing.expect(t,emission.x>0.95 && emission.z<0.01,"Other map transforms remain unchanged")
    testing.expectf(t,rhi.device_validation_errors(f.device)==0,"validation: %s",rhi.device_validation_message(f.device))
}

@(test)
material_without_specular_keeps_the_whole_diffuse_lobe :: proc(t:^testing.T) {
    f:Fixture
    settings:=material_settings();settings.reflections=.Traced
    if !fixture_init(t,&f,64,64,settings) {return}
    defer fixture_destroy(&f)
    r:=f.renderer
    material:=DEFAULT_MATERIAL
    material.base_color={1,1,1};material.roughness=1;material.specular_factor=0
    materials_set(r,{material})
    mesh:=ground_quad(r)
    scene_given(r,{{object_id=1,mesh=mesh,transform=scale_matrix(12),material=1,tint={1,1,1}}},nil,{direction={0,1,0},color={1,1,1},illuminance=1 * math.PI,enabled=true},{})
    direct_at_origin :: proc(t:^testing.T,f:^Fixture,camera:Camera)->Vec3 {
        frames(t,f,camera,2)
        rhi.device_wait_idle(f.device)
        values:=make([]f16,int(f.renderer.targets.width*f.renderer.targets.height)*4,context.temp_allocator)
        testing.expect(t,golden_read_texture(f.device,f.renderer.targets.direct,mem.slice_data_cast([]u8,values)),rhi.device_error(f.device))
        p:=target_pixel(f.renderer,camera,{})
        at:=(p.y*int(f.renderer.targets.width)+p.x)*4
        return {f32(values[at]),f32(values[at+1]),f32(values[at+2])}
    }
    diffuse:=direct_at_origin(t,&f,OVERHEAD)
    testing.expectf(t,abs(diffuse.x-1)<0.015 && abs(diffuse.y-1)<0.015 && abs(diffuse.z-1)<0.015,"Specular factor zero leaves full Lambert diffuse: %v",diffuse)
    testing.expectf(t,rhi.device_validation_errors(f.device)==0,"validation: %s",rhi.device_validation_message(f.device))
}

@(test)
material_reflectance_target_follows_frustum_and_preserves_plain_shading :: proc(t:^testing.T) {
    f:Fixture
    settings:=material_settings()
    if !fixture_init(t,&f,32,32,settings) {return}
    defer fixture_destroy(&f)
    r:=f.renderer
    plain,reflective:=DEFAULT_MATERIAL,DEFAULT_MATERIAL
    plain.roughness=.2
    reflective.specular_color={.2,.8,.4}
    materials_set(r,{plain,reflective})
    mesh:=ground_quad(r)
    offscreen:=scale_matrix(4);offscreen[0,3]=20
    floor:=Instance_Desc{object_id=1,mesh=mesh,transform=scale_matrix(4),material=1,tint={1,1,1}}
    other:=Instance_Desc{object_id=2,mesh=mesh,transform=offscreen,material=2,tint={1,1,1}}
    scene_given(r,{floor,other},nil,{direction={0,1,0},color={1,1,1},illuminance=1 * math.PI,enabled=true},{})
    testing.expect_value(t,len(r.scene.reflective),1)
    camera_needs_reflectance :: proc(r:^Renderer,camera:Camera)->bool {
        view,proj,_:=camera_matrices(camera,1)
        reflectance,_:=reflectance_in_frustum(r,transmute([6]Vec4)mm.frustum_from_matrix(proj*view))
        return reflectance
    }
    testing.expect(t,!camera_needs_reflectance(r,OVERHEAD),"An off-camera reflective surface uses the plain G-buffer")
    frames(t, &f,OVERHEAD,2)
    testing.expect(t,r.targets.surface==0,"Stored reflectance is allocated only when its surface enters the frustum")
    baseline,returned:[32*32*4]f16
    testing.expect(t,golden_read_texture(f.device,r.targets.display,mem.slice_data_cast([]u8,baseline[:])),rhi.device_error(f.device))
    visible:=OVERHEAD;visible.position.x=20
    testing.expect(t,camera_needs_reflectance(r,visible),"The same cached surface requires stored reflectance when the camera sees it")
    frames(t, &f,visible,2)
    testing.expect(t,r.targets.surface!=0,"The stored reflectance target is allocated lazily")
    if r.targets.surface!=0 {
        value:=read_reflectance(t,f.device,r,r.targets.surface,{16,16})
        testing.expectf(t,abs(value.x-.008)<.004 && abs(value.y-.032)<.004 && abs(value.z-.016)<.004 && value.w>.99,"The visible surface retains its authored F0 and F90: %v",value)
    }
    testing.expect(t,!camera_needs_reflectance(r,OVERHEAD),"Leaving the frustum restores the plain path while the target stays allocated")
    frames(t, &f,OVERHEAD,2)
    testing.expect(t,golden_read_texture(f.device,r.targets.display,mem.slice_data_cast([]u8,returned[:])),rhi.device_error(f.device))
    max_error:f32
    for value,i in returned {max_error=max(max_error,abs(f32(value)-f32(baseline[i])))}
    testing.expectf(t,max_error<.001,"Returning to the plain path preserves every output channel: maximum error %g",max_error)
    materials_set(r,{plain,DEFAULT_MATERIAL})
    testing.expect(t,len(r.scene.reflective)==0,"A material edit updates the cached classification")
    materials_set(r,{plain,reflective});other.hidden=true
    scene_given(r,{floor,other},nil,{},{})
    testing.expect(t,len(r.scene.reflective)==0,"Hidden instances never require stored reflectance")
    meshes_clear(r)
    testing.expect(t,len(r.scene.reflective)==0,"Scene geometry reset clears the cached references")
    testing.expectf(t,rhi.device_validation_errors(f.device)==0,"validation: %s",rhi.device_validation_message(f.device))
}

// An extension that draws in the Gbuffer stage says which mesh and material
// it draws: the views of the frame take the targets they need, wherever its
// surfaces are, for that frame alone.
@(test)
material_gbuffer_stage_surfaces_ask_for_their_targets :: proc(t:^testing.T) {
    f:Fixture
    if !fixture_init(t,&f,32,32,material_settings(), reference = {.Lights}) {return}
    defer fixture_destroy(&f)
    r:=f.renderer
    plain,reflective,coated:=DEFAULT_MATERIAL,DEFAULT_MATERIAL,DEFAULT_MATERIAL
    reflective.specular_color={.2,.8,.4}
    coated.coat.weight=1
    materials_set(r,{plain,reflective,coated})
    mesh:=ground_quad(r)
    scene_given(r,{{object_id=1,mesh=mesh,transform=scale_matrix(4),material=1,tint={1,1,1}}},nil,{direction={0,1,0},color={1,1,1},illuminance=math.PI,enabled=true},{})
    Seen :: struct {reflectance,layered:bool}
    record :: proc(s:^Stage_Pass,user:rawptr) {(^Seen)(user)^={s.pass.reflectance,s.pass.layered}}
    drawn :: proc(t:^testing.T,f:^Fixture,mesh:Mesh_Handle,material:Material_Handle) -> (seen:Seen) {
        r:=f.renderer
        testing.expect(t,frame_pass(r,.Gbuffer,record,rawptr(&seen)))
        if material!=0 {frame_gbuffer_mesh(r,mesh,material)}
        frames(t,f,OVERHEAD,1)
        return
    }
    testing.expect_value(t,drawn(t,&f,mesh,0),Seen{false,false})
    testing.expect_value(t,drawn(t,&f,mesh,1),Seen{false,false})
    testing.expect_value(t,drawn(t,&f,mesh,2),Seen{true,false})
    testing.expect_value(t,drawn(t,&f,mesh,3),Seen{true,true})
    testing.expect(t,r.targets.surface!=0 && r.targets.layers!=0,"The targets the surfaces asked for are made")
    testing.expect_value(t,drawn(t,&f,mesh,0),Seen{false,false})
    testing.expectf(t,rhi.device_validation_errors(f.device)==0,"validation: %s",rhi.device_validation_message(f.device))
}

// F0 and the encoded F90 of a pixel as the lighting passes read them from a
// reflectance target (specular_pack in brdf.slang).
read_reflectance :: proc(t:^testing.T,device:^rhi.Device,r:^Renderer,target:rhi.Texture,p:[2]int)->Vec4 {
    bytes:=make([]u8,int(r.targets.width*r.targets.height)*4,context.temp_allocator)
    testing.expect(t,golden_read_texture(device,target,bytes),rhi.device_error(device))
    at:=(p.y*int(r.targets.width)+p.x)*4
    linear :: proc(b:u8)->f32 {
        v:=f32(b)/255
        return v/12.92 if v<=0.04045 else math.pow((v+0.055)/1.055,2.4)
    }
    return {linear(bytes[at]),linear(bytes[at+1]),linear(bytes[at+2]),f32(bytes[at+3])/255}
}

// ---------------------------------------------------------------- layers

// Light reaches a pixel from the sky alone: no traced reflections, so the
// specular lobes read the sky as the deferred passes do.
@(private = "file")
layer_settings :: proc() -> Settings {
    s:=material_settings()
    s.reflections=.Off
    return s
}

@(private = "file")
OBLIQUE :: Camera{position = {0, 2, 2}, forward = {0, -2, -2}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}

// A half-float target at the pixel that shows a world point.
@(private = "file")
target_at :: proc(t:^testing.T,f:^Fixture,target:rhi.Texture,camera:Camera,world:Vec3) -> Vec3 {
    r:=f.renderer
    rhi.device_wait_idle(f.device)
    values:=make([]f16,int(r.targets.width*r.targets.height)*4,context.temp_allocator)
    testing.expect(t,golden_read_texture(f.device,target,mem.slice_data_cast([]u8,values)),rhi.device_error(f.device))
    p:=target_pixel(r,camera,world)
    at:=(p.y*int(r.targets.width)+p.x)*4
    return {f32(values[at]),f32(values[at+1]),f32(values[at+2])}
}

// The split-sum table the renderer built (dfg.comp), DFG_SIZE texels a side.
@(private = "file")
dfg_table :: proc(t:^testing.T,f:^Fixture) -> []f16 {
    table:=make([]f16,DFG_SIZE*DFG_SIZE*2,context.temp_allocator)
    testing.expect(t,golden_read_texture(f.device,f.renderer.dfg,mem.slice_data_cast([]u8,table)),rhi.device_error(f.device))
    return table
}

// The split sum of the lobe at the cosine of the view and a roughness, between
// the texels of the table as dfg_lookup samples it.
@(private = "file")
dfg_sum :: proc(table:[]f16,nov,roughness:f32) -> [2]f32 {
    texel :: proc(table:[]f16,x,y:int) -> [2]f32 {at:=(y*DFG_SIZE+x)*2;return {f32(table[at]),f32(table[at+1])}}
    x,y:=clamp(nov,0,1)*(DFG_SIZE-1),clamp(roughness,0,1)*(DFG_SIZE-1)
    x0,y0:=min(int(x),DFG_SIZE-2),min(int(y),DFG_SIZE-2)
    fx,fy:=x-f32(x0),y-f32(y0)
    low:=texel(table,x0,y0)*(1-fx)+texel(table,x0+1,y0)*fx
    high:=texel(table,x0,y0+1)*(1-fx)+texel(table,x0+1,y0+1)*fx
    return low*(1-fy)+high*fy
}

// What the specular lobe of a dielectric of `f0` reflects of light from
// everywhere, the light between its microfacets included
// (environment_reflectance): what it leaves to the diffuse lobe is the rest.
@(private = "file")
dielectric_albedo :: proc(table:[]f16,nov,roughness,f0:f32) -> f32 {
    sum:=dfg_sum(table,nov,roughness)
    return (f0*sum.x+sum.y)*(1+f0*(1/max(sum.x+sum.y,1e-3)-1))
}

@(private = "file")
Layered_Case :: struct {name:string,material:Material_Desc}

// One base under each layer alone and under all of them. The lobes are rough
// enough for a few hundred light directions to integrate them.
@(private = "file")
layered_cases :: proc(base:Vec3) -> [5]Layered_Case {
    plain:=DEFAULT_MATERIAL
    plain.base_color=base
    plain.roughness=0.5
    coat,fuzz,turned,all:=plain,plain,plain,plain
    coat.coat.weight=1
    coat.coat.roughness=0.5
    fuzz.fuzz.weight=1
    turned.anisotropy.amount=0.8
    all.coat.weight=0.6
    all.coat.roughness=0.5
    all.fuzz.weight=0.5
    all.anisotropy.amount=0.5
    return {{"plain",plain},{"coat",coat},{"fuzz",fuzz},{"anisotropy",turned},{"all layers",all}}
}

// What the camera sees of a surface under a white sky, over the sky's luminance.
@(private = "file")
sky_albedo :: proc(t:^testing.T,f:^Fixture,mesh:Mesh_Handle,material:Material_Handle,camera:Camera) -> Vec3 {
    r:=f.renderer
    scene_given(r,{{object_id=1,mesh=mesh,transform=scale_matrix(12),material=material,tint={1,1,1}}},nil,{},{sky={1,1,1}})
    frames(t, f,camera,2)
    return target_at(t,f,r.targets.display,camera,{})
}

// The same from lights alone: the integral over the hemisphere of the BSDF
// times the cosine, from suns whose directions are spread as their cosine (a
// stratified disk lifted to the hemisphere). π lux show π·f·cos, and the
// density of a direction is cos/π.
@(private = "file")
light_albedo :: proc(t:^testing.T,f:^Fixture,mesh:Mesh_Handle,material:Material_Handle,camera:Camera) -> Vec3 {
    r:=f.renderer
    SIDE :: 12
    sum:Vec3
    for i in 0..<SIDE*SIDE {
        u:=(f32(i%SIDE)+0.5)/SIDE
        angle:=2*math.PI*(f32(i/SIDE)+0.5)/SIDE
        up:=math.sqrt(1-u)
        direction:=Vec3{math.sqrt(u)*math.cos(angle),up,math.sqrt(u)*math.sin(angle)}
        scene_given(r,{{object_id=1,mesh=mesh,transform=scale_matrix(12),material=material,tint={1,1,1}}},nil,{direction=direction,color={1,1,1},illuminance=math.PI,enabled=true},{})
        frames(t, f,camera,2)
        sum+=target_at(t,f,r.targets.direct,camera,{})/up
    }
    return sum/(SIDE*SIDE)
}

// A white surface under a white sky sends back all of it, whatever lies over
// its base: every layer takes from what is below what it reflects itself.
@(test)
material_layers_keep_a_white_furnace :: proc(t:^testing.T) {
    f:Fixture
    if !fixture_init(t,&f,32,32,layer_settings()) {return}
    defer fixture_destroy(&f)
    r:=f.renderer
    cases:=layered_cases({1,1,1})
    materials:[len(cases)]Material_Desc
    for c,i in cases {materials[i]=c.material}
    materials_set(r,materials[:])
    quad:=ground_quad(r)
    for c,i in cases {
        for camera in ([2]Camera{OVERHEAD,OBLIQUE}) {
            seen:=sky_albedo(t,&f,quad,Material_Handle(i+1),camera)
            testing.expectf(t,abs(seen.x-1)<0.02 && abs(seen.y-1)<0.02 && abs(seen.z-1)<0.02,"%s from %v: %v",c.name,camera.position,seen)
        }
    }
    // From lights the lobes lose what GGX does not scatter again, and never gain.
    white:=light_albedo(t,&f,quad,len(cases),OVERHEAD)
    testing.expectf(t,white.x<1.01 && white.x>0.9,"all layers under suns: %v",white)
    testing.expectf(t,rhi.device_validation_errors(f.device)==0,"validation: %s",rhi.device_validation_message(f.device))
}

// A thin surface lets through the share of the light it scatters that its
// diffuse transmission says, filtered by its color: a sun below lights it
// seen from above, by what the specular lobe leaves at the view, and none
// goes through without it. Under a sky, what it lets through of the sky
// behind takes the place of what it does not reflect.
@(test)
diffuse_transmission_lets_the_light_of_the_other_side_through :: proc(t:^testing.T) {
    f:Fixture
    if !fixture_init(t,&f,32,32,layer_settings()) {return}
    defer fixture_destroy(&f)
    r:=f.renderer
    leaf:=DEFAULT_MATERIAL
    leaf.base_color={1,1,1}
    leaf.roughness=0.5
    leaf.diffuse_transmission={weight=0.5,color={1,0.5,0.25}}
    opaque:=leaf
    opaque.diffuse_transmission.weight=0
    materials_set(r,{leaf,opaque})
    quad:=ground_quad(r)
    below:=proc(t:^testing.T,f:^Fixture,quad:Mesh_Handle,material:Material_Handle) -> Vec3 {
        r:=f.renderer
        scene_given(r,{{object_id=1,mesh=quad,transform=scale_matrix(12),material=material,tint={1,1,1}}},nil,{direction={0,-1,0},color={1,1,1},illuminance=math.PI,enabled=true},{})
        frames(t, f,OVERHEAD,2)
        return target_at(t,f,r.targets.direct,OVERHEAD,{})
    }
    through:=below(t,&f,quad,1)
    // weight·color·(1 − E), E the directional albedo of the lobe at the view,
    // F0 0.04 at the default IOR: π lux show π·f.
    table:=dfg_table(t,&f)
    left :: proc(table:[]f16,camera:Camera) -> f32 {return 1-dielectric_albedo(table,-linalg.normalize(camera.forward).y,0.5,0.04)}
    expected:=Vec3{0.5,0.25,0.125}*left(table,OVERHEAD)
    testing.expectf(t,abs(through.x-expected.x)<0.02 && abs(through.y-expected.y)<0.02 && abs(through.z-expected.z)<0.02,"the sun below through the leaf: %v, expected %v",through,expected)
    none:=below(t,&f,quad,2)
    testing.expectf(t,max(none.x,none.y,none.z)<1e-3,"an opaque surface lets nothing through: %v",none)
    white:=leaf
    white.diffuse_transmission.color={1,1,1}
    white_opaque:=white
    white_opaque.diffuse_transmission.weight=0
    materials_set(r,{white,white_opaque})
    // The sky gradient below the horizon: 0.35 of the sky (sky_gradient).
    SKY_BELOW :: 0.35
    for camera in ([2]Camera{OVERHEAD,OBLIQUE}) {
        seen:=sky_albedo(t,&f,quad,1,camera)
        reflected:=sky_albedo(t,&f,quad,2,camera)
        expected:=reflected.x+0.5*left(table,camera)*(SKY_BELOW-1)
        testing.expectf(t,abs(seen.x-expected)<0.02,"a white leaf under a white sky from %v: %v, expected %v",camera.position,seen,expected)
    }
    testing.expectf(t,rhi.device_validation_errors(f.device)==0,"validation: %s",rhi.device_validation_message(f.device))
}

// Lights and the sky go through the same layers: a coat darkens and tints
// what is under it, a fuzz takes what it scatters, by the same amounts.
@(test)
material_layers_light_alike_from_lights_and_from_the_sky :: proc(t:^testing.T) {
    f:Fixture
    if !fixture_init(t,&f,32,32,layer_settings()) {return}
    defer fixture_destroy(&f)
    r:=f.renderer
    base:=layered_cases({0.5,0.5,0.5})
    tinted:=base[1]
    tinted.name="tinted coat"
    tinted.material.coat.color={0.9,0.6,0.3}
    cases:=[?]Layered_Case{base[0],base[1],base[2],base[3],tinted}
    materials:[len(cases)]Material_Desc
    for c,i in cases {materials[i]=c.material}
    materials_set(r,materials[:])
    quad:=ground_quad(r)
    for c,i in cases {
        handle:=Material_Handle(i+1)
        for camera in ([2]Camera{OVERHEAD,OBLIQUE}) {
            sky,lights:=sky_albedo(t,&f,quad,handle,camera),light_albedo(t,&f,quad,handle,camera)
            testing.expectf(t,abs(sky.x-lights.x)<0.03 && abs(sky.y-lights.y)<0.03 && abs(sky.z-lights.z)<0.03,"%s from %v: sky %v, lights %v",c.name,camera.position,sky,lights)
        }
    }
    testing.expectf(t,rhi.device_validation_errors(f.device)==0,"validation: %s",rhi.device_validation_message(f.device))
}

// A white fuzz over black is a sheen: it scatters a little light, more
// towards grazing views, and does not turn the surface into the sky.
@(test)
material_fuzz_is_a_sheen_and_not_a_mirror :: proc(t:^testing.T) {
    f:Fixture
    if !fixture_init(t,&f,32,32,layer_settings()) {return}
    defer fixture_destroy(&f)
    r:=f.renderer
    velvet:=DEFAULT_MATERIAL
    velvet.base_color={0,0,0}
    velvet.specular_factor=0
    velvet.fuzz={weight=1,color={1,1,1},roughness=0.5}
    materials_set(r,{velvet})
    quad:=ground_quad(r)
    facing,oblique:=sky_albedo(t,&f,quad,1,OVERHEAD),sky_albedo(t,&f,quad,1,OBLIQUE)
    // Zeltner's fit at roughness 0.5: an albedo of 0.025 facing the view and 0.063 at 45 degrees.
    testing.expectf(t,abs(facing.x-0.025)<0.01 && abs(oblique.x-0.063)<0.015,"facing %v, at 45 degrees %v",facing,oblique)
    testing.expectf(t,rhi.device_validation_errors(f.device)==0,"validation: %s",rhi.device_validation_message(f.device))
}

// The highlight of an anisotropic metal follows the tangent of its mesh: it
// turns when the object spins on its normal and not when the object, the
// light and the camera turn together.
@(test)
material_anisotropy_turns_with_its_object :: proc(t:^testing.T) {
    f:Fixture
    if !fixture_init(t,&f,32,32,layer_settings()) {return}
    defer fixture_destroy(&f)
    r:=f.renderer
    brushed:=DEFAULT_MATERIAL
    brushed.base_color={1,1,1}
    brushed.metallic=1
    brushed.roughness=0.4
    brushed.anisotropy.amount=0.8
    materials_set(r,{brushed})
    quad:=ground_quad(r)
    // Near the mirror direction of the view, off it along the tangent: the stretched lobe keeps it.
    sun:=Vec3{0.4,1,-1}
    seen :: proc(t:^testing.T,f:^Fixture,quad:Mesh_Handle,turn:mm.Quat,spin:f32,camera:Camera,sun:Vec3) -> f32 {
        transform:=mm.transform_matrix({rotation=turn*mm.quat_axis_angle({0,1,0},spin),scale={12,12,12}})
        direction:=mm.quat_rotate(turn,sun)
        scene_given(f.renderer,{{object_id=1,mesh=quad,transform=transform,material=1,tint={1,1,1}}},nil,{direction=direction,color={1,1,1},illuminance=math.PI,enabled=true},{})
        frames(t,f,camera,2)
        return target_at(t,f,f.renderer.targets.direct,camera,{}).x
    }
    identity:=mm.Quat(1)
    still:=seen(t,&f,quad,identity,0,OBLIQUE,sun)
    spun:=seen(t,&f,quad,identity,math.PI/2,OBLIQUE,sun)
    testing.expectf(t,abs(spun-still)>0.1*still,"the highlight turns with the tangent: %f and %f",still,spun)
    turn:=mm.quat_axis_angle(linalg.normalize(Vec3{1,2,3}),0.9)
    camera:=OBLIQUE
    camera.position,camera.forward,camera.up=mm.quat_rotate(turn,camera.position),mm.quat_rotate(turn,camera.forward),mm.quat_rotate(turn,camera.up)
    turned:=seen(t,&f,quad,turn,0,camera,sun)
    testing.expectf(t,abs(turned-still)<0.02*still,"turning everything together leaves the highlight: %f and %f",still,turned)
    testing.expectf(t,rhi.device_validation_errors(f.device)==0,"validation: %s",rhi.device_validation_message(f.device))
}

// Two halves of a quad share their uvs mirrored across x = 0, as a baker lays
// out a symmetric model. With MikkTSpace tangents a map that tilts up the
// image tilts both halves alike, and one that tilts along u mirrors.
@(test)
material_mirrored_uvs_share_their_bitangent :: proc(t:^testing.T) {
    f:Fixture
    if !fixture_init(t,&f,64,64,material_settings(), reference = {.Lights}) {return}
    defer fixture_destroy(&f)
    r:=f.renderer
    right:=[4]u8{191,128,238,255}
    up:=[4]u8{128,191,238,255}
    right_texture,ok1:=texture_add(r,{pixels=right[:],width=1,height=1,normal_map=true,name="tilt right"})
    up_texture,ok2:=texture_add(r,{pixels=up[:],width=1,height=1,normal_map=true,name="tilt up"})
    testing.expect(t,ok1 && ok2,r.error)
    tilt_right,tilt_up:=DEFAULT_MATERIAL,DEFAULT_MATERIAL
    tilt_right.textures[.Normal]=right_texture
    tilt_up.textures[.Normal]=up_texture
    materials_set(r,{tilt_right,tilt_up})
    // u grows away from the seam on both halves; v grows with +Z.
    positions:=[?]Vec3{{-1,0,-0.5},{0,0,-0.5},{0,0,0.5},{-1,0,0.5},{1,0,-0.5},{1,0,0.5}}
    uvs:=[?]Vec2{{0,0},{1,0},{1,1},{0,1},{0,0},{0,1}}
    indices:=[?]u32{0,2,1,0,3,2,1,2,5,1,5,4}
    normals:[len(positions)]Vec3
    for &n in normals {n={0,1,0}}
    tangents:[len(indices)]Vec4
    testing.expect(t,geom.corner_tangents(positions[:],normals[:],uvs[:],indices[:],tangents[:]),"MikkTSpace makes the tangents")
    vertices:[len(indices)]Mesh_Vertex
    corners:[len(indices)]u32
    for index,at in indices {
        vertices[at]={position=positions[index],normal={0,1,0},uv=uvs[index],uv1=uvs[index],color={1,1,1},tangent=tangents[at]}
        corners[at]=u32(at)
    }
    mesh,added:=mesh_add(r,vertices[:],corners[:])
    testing.expect(t,added,r.error)
    // Scaled: the tangent in the world keeps the length of the normal.
    left_half,right_half:=Vec3{-0.8,0,0.2},Vec3{0.8,0,0.2}
    scene_given(r,{{object_id=1,mesh=mesh,transform=scale_matrix(2),material=2,tint={1,1,1}}},nil,{},{})
    frames(t, &f,OVERHEAD,2)
    for at in ([2]Vec3{left_half,right_half}) {
        n:=read_normal(t,&f,OVERHEAD,at)
        testing.expectf(t,abs(n.x)<0.03 && abs(n.y-0.866)<0.03 && abs(n.z+0.5)<0.03,"+Y of the map is up the image on both halves, at %v: %v",at,n.xyz)
    }
    scene_given(r,{{object_id=1,mesh=mesh,transform=scale_matrix(2),material=1,tint={1,1,1}}},nil,{},{})
    frames(t, &f,OVERHEAD,2)
    left,mirrored:=read_normal(t,&f,OVERHEAD,left_half),read_normal(t,&f,OVERHEAD,right_half)
    testing.expectf(t,abs(left.x-0.5)<0.03 && abs(mirrored.x+0.5)<0.03 && abs(left.z)<0.03 && abs(mirrored.z)<0.03,"+X of the map follows u: %v and %v",left.xyz,mirrored.xyz)
    testing.expectf(t,rhi.device_validation_errors(f.device)==0,"validation: %s",rhi.device_validation_message(f.device))
}


// The colors two instances of one mesh are given are drawn over it at every
// level of detail the view chooses, each instance with its own.
@(test)
gpu_instances_of_one_mesh_draw_their_own_colors_at_every_level :: proc(t: ^testing.T) {
	f: Fixture
	if !fixture_init(t, &f, 64, 64, material_settings()) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	CELLS :: 48
	vertices := make([dynamic]asset.Vertex, context.temp_allocator)
	indices := make([dynamic]u32, context.temp_allocator)
	for z in 0 ..= CELLS {for x in 0 ..= CELLS {
		u, v := f32(x) / CELLS, f32(z) / CELLS
		p := Vec3{(u - 0.5) * 0.8, 0.05 * math.sin(f32(x) * 0.7) * math.cos(f32(z) * 0.5), (v - 0.5) * 0.8}
		append(&vertices, asset.Vertex{position = p, normal = mm.normal_pack({0, 1, 0}), uv = {u, v}, color = 0xffffffff, tangent = mm.tangent_pack({1, 0, 0}, 1)})
	}}
	for z in 0 ..< u32(CELLS) {for x in 0 ..< u32(CELLS) {
		a := z * (CELLS + 1) + x
		append(&indices, a, a + CELLS + 1, a + 1, a + 1, a + CELLS + 1, a + CELLS + 2)
	}}
	g: asset.Mesh_Geometry
	if !testing.expect(t, asset.mesh_build_dag({vertices = vertices[:]}, indices[:], &g, context.temp_allocator)) {return}
	materials_set(r, {DEFAULT_MATERIAL})
	mesh, added := mesh_add_geometry(r, g, {1})
	if !testing.expect(t, added && r.scene.meshes[mesh].level_count > 1, "a mesh of levels") {return}
	count := r.scene.meshes[mesh].vertex_count
	red := make([]u32, count, context.temp_allocator)
	blue := make([]u32, count, context.temp_allocator)
	for &color in red {color = 0xff0000ff}
	for &color in blue {color = 0xffff0000}
	reds, made_red := colors_load(r, red)
	blues, made_blue := colors_load(r, blue)
	if !testing.expect(t, made_red && made_blue) {return}
	left, right := Mat4(1), Mat4(1)
	left[0, 3], right[0, 3] = -0.5, 0.5
	scene_given(r, {{object_id = 1, mesh = mesh, transform = left, tint = 1}, {object_id = 2, mesh = mesh, transform = right, tint = 1}}, nil, {}, {})
	testing.expect(t, scene_set_instance_colors(r, 0, reds) && scene_set_instance_colors(r, 1, blues))
	clusters: [2]u32
	// Every level at 0 pixels of error, the coarsest at 100.
	for error, at in ([2]f32{0, 100}) {
		settings := r.settings
		settings.lod_error_pixels = error
		testing.expect(t, renderer_apply_settings(r, settings))
		frames(t, &f, OVERHEAD, 4)
		clusters[at] = r.stats.visible_kinds[.Levels].clusters
		testing.expectf(t, near_bytes(read_albedo(t, &f, OVERHEAD, {-0.5, 0, 0}), {255, 0, 0, 0}, 3), "the left instance shows its red at %v pixels: %v", error, read_albedo(t, &f, OVERHEAD, {-0.5, 0, 0}))
		testing.expectf(t, near_bytes(read_albedo(t, &f, OVERHEAD, {0.5, 0, 0}), {0, 0, 255, 0}, 3), "the right instance shows its blue at %v pixels: %v", error, read_albedo(t, &f, OVERHEAD, {0.5, 0, 0}))
	}
	testing.expectf(t, clusters[1] < clusters[0], "a coarser level is drawn: %d clusters, %d at level 0", clusters[1], clusters[0])
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}
