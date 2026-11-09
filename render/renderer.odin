// Package render is Mirai's GPU renderer. It only talks to the GPU through
// package rhi, so it runs unchanged on Vulkan and Metal.
//
// Frame graph (all GPU work, recorded every frame):
//   upload      dirty instances/materials/lights/TLAS through the frame ring
//   cull        compute frustum culling -> indexed indirect draws + stats
//   gbuffer     indirect raster of the materials: base color + metallic,
//               normal + roughness, emission + occlusion, motion, linear depth
//   lighting    sun + local lights with ray traced shadows (RIS above budget),
//               reflected by the diffuse and GGX specular lobes of each pixel
//   reflect     one ray of the specular lobe of the pixels smoother than the
//               roughness limit, then a filter over space and time
//   ddgi        probe batch: trace -> irradiance/distance blend -> relocate
//   contact     short traced rays that darken the probe volume at contact
//   composite   direct + diffuse and specular indirect + emission, debug views
//   translucent blended surfaces: the nearest ones of each pixel as layers,
//               the ones behind them forward and back to front
//   glass       the layers once per pixel: lights, traced reflection, refraction
//   exposure    histogram of the luminance of the image, then the exposure the view adapts to
//   tonemap     exposure and the display LUT (ACES 2.0, sRGB) into the window-sized LDR target
//   ui          editor overlay (alpha blended)
//   present     LDR -> swapchain
package mirai_render

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:os"
import "core:sync"
import "core:thread"
import "mirai:asset"
import "mirai:std/jobs"
import "mirai:rhi"

Trace_Mode :: enum u8 {Auto, Software, Hardware}

// Every effect has an explicit budget so cost scales with settings, not scene
// size alone.
Settings :: struct {
	gi_enabled:           bool,
	gi_strength:          f32,
	trace_mode:           Trace_Mode,
	render_scale:         f32,    // internal 3D resolution relative to the window
	render_megapixels:    f32,    // the most pixels the views of the window take in all, in millions: it lowers render_scale where they have more (0: no limit)
	taa:                  bool,   // temporal anti-aliasing / upscaling to the window resolution
	occlusion_culling:    bool,   // two-phase depth pyramid occlusion culling
	lod_error_pixels:     f32,    // raster LOD switch threshold (0 = always full detail)
	batch_min_pixels:     f32,    // an instance of a batch whose box is fewer pixels across is not rasterized, and fades out from twice that; rays still meet it. 0: every one is drawn
	probe_spacing:        f32,    // metres between the probes of the first cascade; each next one doubles it
	probe_grid:           u32,    // probes of a cascade along x and z (half that along y), even, 4 to PROBE_GRID_MAX
	probe_cascades:       u32,    // cascades of probes around the camera, 1 to VOLUME_CASCADES_MAX
	probe_rays:           u32,    // rays of a probe (multiple of 32, at most 256)
	probe_budget:         u32,    // probes traced at most per frame
	gi_max_distance:      f32,    // the farthest a traced reflection or glass ray goes, in meters
	light_budget:         u32,    // shadow rays of a point that traces its own (glass, overlays, the other side of a surface that lets light through; probes and reflections take theirs from it), each to a light or to a group of far ones that stands for them (at most LIGHT_CUT_MAX)
	direct_samples:       u32,    // samples of the direct light of a pixel, spread over the lights by what each gives it, one of them traced through the whole scene (1 to DIRECT_SAMPLES_MAX)
	direct_half_resolution: bool, // the samples of the direct light are taken at one pixel of each 2x2 and the filter takes them to the others by their surfaces
	shadow_maps:          bool,   // the direct light takes the shadows of the lights that light much of the view, and of the sun, from maps of depth drawn from them every frame (shadow_maps_pass): the hard shadow of the maps at each point, averaged over the points of its surface within its penumbra (direct_samples.comp, direct_spread.comp); the other lights trace rays
	firefly_clamp:        f32,    // the brightest a ray of a traced reflection or of glass counts, in render units (Scene.light_scale)
	texture_max_size:     u32,    // larger images are loaded at the first mip level that fits
	texture_compression:  bool,   // upload block compressed textures (BC1, BC3, BC5, BC7) as they are where the device samples them; off, they are decoded to RGBA8
	texture_pool_megabytes: u32,  // GPU memory for textures; past it they load without their largest levels (0: no limit)
	page_pool_bytes:      u64,    // the slots of the vertex pool for the pages of streamed meshes out of their root, reserved when the first one loads (pages.odin); 0: they keep their root alone
	reflections:          bool,   // trace the mirror ray of smooth surfaces (else every reflection comes from the probes)
	reflection_roughness: f32,    // surfaces at or above this roughness are not traced
	reflection_half_resolution: bool, // surfaces from REFLECTION_SHARED_ROUGHNESS trace one ray per block of 2x2 pixels
	reflection_light_budget: u32, // shadow rays at a reflected hit, each to a light or a group of them (at most LIGHT_CUT_MAX)
	reflection_detail_roughness: f32, // reflections sharper than this show the glass their rays cross and the gloss of what they find (0: none)
	colored_shadows:       bool, // thin RGB filters along shadow rays through blended surfaces
	glass_layers:          u32,  // nearest blended surfaces of a pixel lit once per pixel with traced reflection and refraction (1 to GLASS_LAYERS_MAX); the ones behind are drawn forward
	sun_radius:           f32, // angular radius of the sun, radians
	reference_lights:     bool, // what the lighting approximates, for tests and comparisons: the direct light of every pixel from DIRECT_REFERENCE_SAMPLES samples
	reference_gi:         bool, // what the diffuse indirect light approximates, for tests and comparisons: paths from every pixel in place of the probe volume, their mean while the scene and the camera stay (Targets.gi_reference)
}

// Outlines drawn after tonemapping around instances with an outline level:
// the editor's levels (Renderer.highlight) or the game's styles
// (Renderer.outlines), each indexed from 1. colors[level - 1]: rgb in display
// (sRGB) space, a = opacity. width is the glow radius in window points; 0
// draws none of the levels of the style. fill[level - 1] above 0 gives that
// level a flat coat of its color over the whole surface, at that opacity,
// instead of an outline. behind[level - 1] is what of the level shows where
// another surface is in front of it.
Highlight_Style :: struct {
	colors: [16]Vec4,
	width:  f32,
	fill:   [16]f32,
	behind: [16]f32,
}

DEFAULT_HIGHLIGHT_STYLE :: Highlight_Style{
	colors = {0={1, 0.71, 0.28, 1}, 1={1, 0.85, 0.63, 0.7}, 2={0.4, 0.88, 1, 1}, 3={0.43, 0.63, 1, 1}},
	width = 3,
	behind = {0 ..< 16 = 0.35},
}

DEFAULT_SETTINGS :: Settings{
	gi_enabled = true, gi_strength = 1, trace_mode = .Auto, render_scale = 1, taa = true, occlusion_culling = true, lod_error_pixels = 1, batch_min_pixels = 1,
	probe_spacing = 1.0, probe_grid = 16, probe_cascades = 5, probe_rays = 128, probe_budget = 512,
	gi_max_distance = 1e4, light_budget = 8, direct_samples = 15, shadow_maps = true,
	firefly_clamp = 20, texture_max_size = 2048,
	texture_compression = true, texture_pool_megabytes = 1024, page_pool_bytes = 256 << 20,
	reflections = true, reflection_roughness = 0.4, reflection_half_resolution = true, reflection_light_budget = 8,
	reflection_detail_roughness = REFLECTION_SHARED_ROUGHNESS, glass_layers = 1,
	sun_radius = SUN_RADIUS,
}

// The sun as seen from the Earth: 0.27 degrees.
SUN_RADIUS :: f32(0.0047)
// The samples of the direct light of a pixel at most, and those of the
// reference (direct_samples.slang).
DIRECT_SAMPLES_MAX :: u32(127)
DIRECT_REFERENCE_SAMPLES :: u32(127)

// SHARED_RAY_ROUGHNESS of the shaders.
REFLECTION_SHARED_ROUGHNESS :: f32(0.15)

// Conservative budgets for software rasterizers (lavapipe, SwiftShader).
CPU_DEVICE_SETTINGS :: Settings{
	gi_enabled = true, gi_strength = 1, trace_mode = .Auto, render_scale = 0.5, taa = true, occlusion_culling = true, lod_error_pixels = 1, batch_min_pixels = 1,
	probe_spacing = 1.5, probe_grid = 12, probe_cascades = 3, probe_rays = 64, probe_budget = 64,
	gi_max_distance = 1e4, light_budget = 4, direct_samples = 7,
	firefly_clamp = 20, texture_max_size = 1024,
	texture_compression = true, texture_pool_megabytes = 256, page_pool_bytes = 128 << 20,
	reflections = false, reflection_roughness = 0.4, reflection_half_resolution = true, reflection_light_budget = 4,
	glass_layers = 1,
	sun_radius = SUN_RADIUS,
}

// How a camera turns what is in front of it into an image.
Projection :: enum u8 {
	Perspective,  // fov_y
	Orthographic, // height
	Custom,       // custom
}

Camera :: struct {
	position, forward, up: Vec3, // forward: where it looks, of any length
	fov_y:                f32, // degrees
	near, far:            f32,  // far 0: none, a perspective sees to infinity (reversed depth in D32 keeps its precision) and an orthographic one to the far side of the scene
	projection:           Projection,
	height:               f32,  // Orthographic: metres the view covers from bottom to top
	shift:                Vec2, // where the center of the projection is, in halves of the view: an off-center frustum
	custom:               Mat4, // Custom: view space (x right, y up, looking down -z) to clip space, depth 1 at the nearest and 0 at the farthest, w a function of the view depth alone
	clip_plane:           Vec4, // world plane (normal, distance) nothing is drawn behind, whatever the projection; zero: none
	layers:               u32,  // it draws the instances that share a layer with these (16 of them); 0: every instance
	own:                  u8,   // 1 + the local slot whose body (INSTANCE_FLAG_OWNED) is its own; 0: none
	fade:                 f32,  // how much of its own body it leaves out: 1 all of it
	own_hidden:           u32,  // the layers of its own body it does not draw
	slot:                 u8,   // 1 + the local view it is, drawn with the effects of renderer_set_view_postprocesses; 0: those of renderer_set_postprocesses
	exposure:             Exposure,
	focus:                f32,  // metres ahead of position along forward to what it looks at (the pivot of an orbit camera): the probe volume of the first view centres there; 0: on position
}

// Where the light the renderer gathers around a camera centres: its focus.
@(private)
camera_focus :: proc "contextless" (c: Camera) -> Vec3 {
	length := math.sqrt(c.forward.x * c.forward.x + c.forward.y * c.forward.y + c.forward.z * c.forward.z)
	if c.focus <= 0 || length < 1e-8 {return c.position}
	return c.position + c.forward * (c.focus / length)
}

Exposure_Mode :: enum u8 {
	Auto,   // meters the image (exposure.comp): the geometric mean of its luminance becomes middle gray
	Manual, // ev100
}

// How Auto comes to the exposure it meters (exposure_adapt.comp).
Exposure_Adaptation :: enum u8 {
	Time,  // exponentially: 95 % of any change in adaptation seconds when the light falls, half of that when it grows
	Speed, // adaptation seconds for each EV the light falls, a third of that for each it grows, and exponentially within 1.5 EV (Unreal, Bevy)
}

// How a camera turns the luminance it sees into the scene-linear values of the
// display transform. At an exposure value EV100, a luminance of
// 2^EV100 * K / 100 nits (what a light meter of K = 12.5 calls average) gives
// middle gray, 0.18. The zero value meters the image and adapts at once.
Exposure :: struct {
	mode:            Exposure_Mode,
	ev100:           f32,    // Manual: the exposure value at ISO 100 (ev100_of)
	compensation:    f32,    // EV added to what the camera gives: +1 doubles the light of the image
	range:           [2]f32, // Auto: the lowest and highest EV100 it takes; {0, 0}: AUTO_EXPOSURE_RANGE
	adaptation:      f32,    // Auto: seconds, as adaptation_mode takes them; 0: at once
	adaptation_mode: Exposure_Adaptation,
	own:             bool,   // the camera has an exposure of its own, which replaces that of the scene (scene_set_exposure)
	tint:            [3]f32, // multiplies the image before the display; zero: none
}

// From starlight to snow under the sun.
AUTO_EXPOSURE_RANGE :: [2]f32{-6, 18}
// The calibration of a reflected-light meter, cd/m^2 at ISO 100 and EV 0 times 100.
LIGHT_METER_K :: f32(12.5)
MIDDLE_GRAY :: f32(0.18)
// EV every view is exposed above what its meter or its camera gives, as Unreal's default exposure
// bias: the display transform (ACES 2.0) shows a middle gray at the meter's value dim on an SDR
// display.
EXPOSURE_BIAS :: f32(1)

// The EV100 of a camera: an f-number, a shutter time in seconds and an ISO.
ev100_of :: proc "contextless" (aperture, shutter, iso: f32) -> f32 {
	return math.log2(aperture * aperture / max(shutter, 1e-9) * 100 / max(iso, 1e-9))
}

// The scene-linear value of one nit at an exposure value, with EXPOSURE_BIAS.
exposure_of_ev100 :: proc "contextless" (ev100: f32) -> f32 {
	return MIDDLE_GRAY * 100 / LIGHT_METER_K * math.pow(2, EXPOSURE_BIAS - ev100)
}

// The manual exposure at which a render unit becomes one scene-linear unit, whatever the image
// holds: the one the tests that read an image take.
UNIT_EXPOSURE :: Exposure{mode = .Manual, ev100 = 0.5260688 + EXPOSURE_BIAS, own = true}

// UI vertex in points of the window, or of its panel (layout shared with the ui package).
Ui_Vertex :: struct {
	position: Vec3,
	color:    Vec4,
	material: u32, // 0 = plain color; 1 = font atlas; UI_MATERIAL_THUMBNAIL = asset previews; UI_MATERIAL_PREVIEW_BIT | material-table row = studio thumbnail; ui_image(texture) = an image
	uv:       Vec2,
}
UI_MATERIAL_PREVIEW_BIT :: u32(1) << 31
UI_MATERIAL_THUMBNAIL :: u32(2)

Stats :: struct {
	frame:             u64,
	backend:           rhi.Backend,
	device_name:       string,
	device_type:       rhi.Device_Type,
	hardware_rt:       bool,
	render_width:      u32,
	render_height:     u32,
	instances:         u32,
	tlas_instances:    u32, // entries of the structure rays walk: of the native TLAS, or references of the software tree
	visible_instances: u32,
	culled_instances:  u32, // outside the frustum
	occluded_instances: u32, // hidden by the depth pyramid
	visible_triangles: u32,
	visible_clusters:  u32,
	visible_kinds:     [Visible_Kind_Id]Visible_Kind, // of the frame two frames ago, by kind of instance
	visible_late:      Visible_Kind, // of those, what phase 1 of the occlusion drew
	cull_dropped:      [Cull_List]u32, // what passed the capacities of the lists of the cull, which then grow
	meshes:            u32,
	triangles:         u64,
	materials:         u32,
	textures:          u32,
	texture_bytes:     u64,
	geometry_bytes:    u64, // the GPU buffers of the pools of the geometry and of the table of meshes
	geometry_free:     u64, // of the pools: the bytes of the free ranges between their meshes
	geometry_free_largest: u64, // the bytes of the largest of those ranges
	ray_bytes:         u64, // the GPU memory of the acceleration structures
	page_slots:        u32, // of the pages of streamed meshes (pages.odin); 0: no region
	page_region_bytes: u64, // the part of the vertex pool they take
	pages_resident:    u32, // slots that hold a page
	pages_requested:   u32, // of the last frame: the pages the cull and the ray cuts asked for, once each
	pages_loaded:      u32, // the pages it loaded
	pages_evicted:     u32, // the pages that left their slot to others
	page_requests_dropped: u32, // the requests past the capacity of the list and the pages that found no slot
	textures_reduced:  u32, // held without the largest levels their distance asks for, to fit the pool
	textures_pending:  u32, // streamed, whose levels are not yet those their distance asks for
	lights:            u32,
	probes:            u32,
	probes_per_frame:  u32,
	probes_traced:     u32, // in the frame two frames ago
	rays_per_frame:    u64,
	gpu_ms:            f32,
	ev100:             f32, // the main view is exposed at, before its compensation: what its meter took, as read back, or what its camera gives
	timings:           []rhi.Gpu_Timing,
	// Time of the calling thread in the parts of the last frame, in ms.
	cpu_prepare_ms:    f32, // geometry commit, capacities and targets
	cpu_begin_ms:      f32, // rhi.frame_begin: the wait for a frame slot and for the image
	cpu_record_ms:     f32, // uploads and the commands of every pass
	cpu_end_ms:        f32, // rhi.frame_end: submit and present
	generated:         bool, // the frame drew an image the window shows before its own (frame generation)
	ui_vertices_dropped:    u32, // of the last frame: UI vertices beyond the capacity
	ui_shapes_dropped:      u32,
	ui_layers_dropped:      u32,
	debug_vertices_dropped: u32, // of the last frame: debug line vertices beyond the capacity
	counters:               []Extension_Counter, // what the passes of extensions counted two frames ago (pass_counters)
	// What the renderer could not do in the last frame and why, and how to
	// avoid it; empty when nothing failed.
	problem:                string,
}

Pipeline_Id :: enum {
	Postprocess_Copy, Postprocess_Hdr, Postprocess_Ldr, Cull, Cull_Clusters, Cull_Clusters_Candidates, Cull_Programs, Tlas_Batches, Gbuffer, Light_Grid_Count, Light_Grid_Scan, Light_Grid_Fill, Light_Grid_Weights, Direct_Rays, Direct_Rays_Hw, Direct_Samples, Direct_Samples_Hw, Direct_Points, Direct_Spread, Direct_Filter, Direct_Filter_Hw, Ddgi_Trace, Ddgi_Trace_Hw, Ddgi_Irradiance, Ddgi_Distance, Ddgi_Keep,
	Ddgi_Relocate, Ddgi_Select, Ddgi_Touch, Ddgi_Mark, Contact, Contact_Hw, Contact_Light, Contact_Pixels, Composite, Taa, Hiz,
	Exposure_Histogram, Exposure_Adapt, Tonemap, Tonemap_Wide, Ui, Thumbnail, Thumbnail_Values, Impostor, Preview_Backdrop, Blit, Highlight, Highlight_Filter, Shadow_Map, Shadow_Map_Tested, Shadow_Maps, Reflect, Reflect_Hw, Translucent, Translucent_Hw, Reflect_Resolve,
	Ddgi_Trace_Color, Ddgi_Trace_Color_Hw,
	Reflect_Color, Reflect_Color_Hw, Translucent_Color, Translucent_Color_Hw,
	Glass_Layer, Glass_Layer_Layers, Glass_Filter, Glass, Glass_Hw, Glass_Color, Glass_Color_Hw, Reflect_Resolve_Glass, Glass_Mean,
	Glass_Inside, Glass_Inside_Hw, Glass_Inside_Color, Glass_Inside_Color_Hw,
	Gbuffer_Plain, // without the reflectance target: no reflective instance in the frustum
	Gbuffer_Layers, Gbuffer_Layers_Clip, Gbuffer_Nested_Layers, // with the layers target: an instance with layers in the frustum
	Direct_Samples_Color, Direct_Samples_Color_Hw, Direct_Samples_Unlayered_Color, Direct_Samples_Hw_Unlayered_Color, // the glass the light crosses colors it
	Direct_Samples_Unlayered, Direct_Samples_Hw_Unlayered, Direct_Filter_Unlayered, Direct_Filter_Hw_Unlayered, Composite_Unlayered, // without: they read no layers
	Reflect_Unlayered, Reflect_Unlayered_Hw, Reflect_Unlayered_Color, Reflect_Unlayered_Color_Hw, // no instance with layers in the scene
	Ui_World, Ui_Composite, Ui_Blur, Debug_Lines,
	Skin, Skin_Triangles, Skin_Refit,
	Gbuffer_Clip, Gbuffer_Plain_Clip, // of a view with a clip plane
	Gbuffer_Nested, Gbuffer_Nested_Plain, Nested_Prime, Nested_Reflectance, // of the nested views of a view
	Debug_Views,
	Gi_Reference, Gi_Reference_Hw,
	History_Scale,
	Air_Transmittance, Air_Scattering, Air_Sky, Air_Aerial,
	Depth_Probe, Ui_Particles,
	Points,
}

Targets :: struct {
	width, height:           u32, // internal 3D resolution
	half_width, half_height: u32,
	output_width:            u32, // window resolution (LDR + UI)
	output_height:           u32,
	depth:                   rhi.Texture,
	albedo:                  rhi.Texture,
	surface:                 rhi.Texture, // evaluated F0 as sRGB, encoded F90 in alpha; made when the scene first needs it
	layers:                  rhi.Texture, // the layers of the materials (gbuffer.slang); made when the scene first needs it
	instance:                rhi.Texture, // R32 uint: the instance that drew each pixel + 1, while the shaders ask for it (Frame_Layout.instance_ids)
	post_hdr,post_ldr:        [2]rhi.Texture, // made when the PostProcess stack first uses them
	normal:                  rhi.Texture,
	emission:                rhi.Texture,
	motion:                  rhi.Texture,
	linear_depth:            rhi.Texture,
	direct:                  rhi.Texture,
	reflect_raw:             rhi.Texture, // radiance and hit distance of this frame's reflection rays
	reflect_shared:          rhi.Texture, // the same at half resolution: the rays that blocks of 2x2 pixels share
	reflect_history:         [2]rhi.Texture,
	reflect_valid:           bool,
	hdr:                     [2]rhi.Texture,
	display:                 rhi.Texture, // composite output shown by tonemap (debug views)
	taa:                     [2]rhi.Texture, // output-resolution history
	taa_frames:              [2]rhi.Texture, // the frames the history of each of its pixels holds
	taa_valid:               bool,
	hiz:                     [2]rhi.Texture, // depth pyramids: this frame / last frame
	hiz_width, hiz_height:   u32,
	hiz_levels:              u32,
	hiz_valid:               bool, // the previous pyramid holds last frame's depth
	gi_reference_valid:      bool, // gi_reference holds the paths of the frames before
	contact_rays:            rhi.Texture, // at each point, its contact occlusion, linear depth and normal (contact.comp)
	contact_points:          [2]rhi.Texture, // at each point, the irradiance of the probe volume / its light around the specular lobe (contact_light.comp)
	contact:                 rhi.Texture, // both at each pixel, packed (contact_pixels.comp)
	contact_scale:           u32, // the pixels across a point of contact_points
	ldr:                     rhi.Texture,
	generated:               rhi.Texture, // the image shown before ldr, while the pipeline generates frames: made with the first one
	ui_layers:               [UI_LAYER_DEPTH_CAPACITY]rhi.Texture,
	ui_blur:                 [2]rhi.Texture,
	highlight:               rhi.Texture, // editor selection mask: level and depth of highlighted surfaces
	highlight_depth:         rhi.Texture,
	shadow_atlas:            rhi.Texture, // the depth from the lights of the shadow maps of the frame (shadow_maps_pass)
	shadow_buffers:          Shadow_Buffers,
	highlight_filtered:      rhi.Texture, // premultiplied editor coat, window-point resolution
	highlight_width, highlight_height: u32,
	gi_reference:            rhi.Texture, // Settings.reference_gi: the mean of its paths at full resolution, frames in a
	gi_reference_view:       Mat4,        // the unjittered view-projection it was accumulated from
	gi_reference_eye:        Vec3,        // and the eye it takes points from
	needs_clear:             bool,
	glass:                   [GLASS_LAYERS_MAX]Glass_Layer,
	glass_zbuffer:           rhi.Texture,
	glass_scene:             rhi.Texture, // copy of the scene a glass layer is drawn over, for the layer to read
	glass_history:           [2]rhi.Texture, // filtered reflections of the nearest layer
	glass_valid:             bool,
	glass_needs_clear:       bool,
	direct_blockers:         rhi.Texture, // what stopped the ray each pixel traced for its direct light (direct_rays.comp)
	direct_samples:          rhi.Texture, // at each point (direct_points of direct_samples.slang), the light of the local lights with nothing in the way over its reflectance, and the part of it that got there
	direct_sun:              rhi.Texture, // at each point, what the glass on the way leaves of the light of the sun, and how much of the sun gets there
	direct_depth:            rhi.Texture, // at each point, its linear depth (0 for none) and the radii of the penumbrae of the sun and of the local lights
	direct_points:           rhi.Texture, // what the window of the samples gives each point (direct_points.comp), its part spread over its penumbra (direct_spread.comp)
	direct_sun_points:       rhi.Texture, // the same of the part of the sun
	direct_spread:           rhi.Texture, // those parts spread along the rows (direct_spread.comp)
	direct_scale:            u32, // the pixels across a point of the direct targets
	direct_marks:            rhi.Texture, // 1 where a sample of the direct light met what changed, for TAA
	reactive:                rhi.Texture, // the share of each pixel the Blend stage drew over: TAA keeps less of its history there
	reactive_drawn:          bool,        // the Blend stage drew in reactive since it was last cleared
	nested_depth:            rhi.Texture, // the depth buffer of the nested views, which draw only the pixels their mask gave them
	aerial:                  rhi.Texture, // the aerial perspective of an atmosphere (air.odin), made when the sky first is one
	aerial_key:              Air_Aerial_Key, // what it was computed for
}

Renderer_Desc :: struct {
	device:        ^rhi.Device,
	width, height: u32,             // drawable in device pixels
	settings:      Maybe(Settings), // the defaults of the device type when unset
	shaders:       ^Shader_Assets,  // a loaded generation, which the renderer takes; nil: the embedded one
	allocator:     runtime.Allocator, // of the scene tables; context.allocator when unset
	ui_vertex_capacity:    int, // UI vertices of a frame, screen layers and world panels together; 0: UI_VERTEX_CAPACITY
	ui_shape_capacity:     int, // 0: UI_SHAPE_CAPACITY
	ui_layer_depth:        int, // 0: UI_LAYER_DEPTH_CAPACITY; maximum 8
	debug_vertex_capacity: int, // debug line vertices of a frame; 0: DEBUG_VERTEX_CAPACITY
	worlds:                int, // worlds whose light it keeps, the one shown included (world_light.odin), 1 to WORLDS_MAX; 0: WORLDS_DEFAULT
	jobs:                  ^jobs.Job_System, // the pages of streamed meshes decode in its jobs, from the thread of its owner; nil: on the calling thread
	// The pipelines of the stages of Surface programs are made on a thread of
	// the renderer, and the frames draw the materials of a program as their
	// rows until its pipelines are made (pipeline_thread.odin). False: they
	// are made in the frame that first asks for them.
	pipeline_thread:       bool,
}

// What one frame draws besides the scene.
// A camera that chooses, in place of the views of the window, the detail
// they draw: the levels of the meshes, the cuts rays trace and the levels of
// the textures. In a frame no window shows (a capture of what it shows) it
// is that of every view. What a paused game saw keeps its detail while the eye of the
// editor looks at it from elsewhere.
Frame_Detail :: struct {
	camera: Camera,
	on:     bool,
}

Frame_Desc :: struct {
	camera: Camera,
	detail: Frame_Detail,
	camera_cut:bool,
	carried: Mat4, // as Frame_View.carried, for the camera of a frame without views
	inspection: View_Inspection, // as Frame_View.inspection, for the view of a frame without views
	time:   f32, // seconds of the world shown: what programs and the passes of extensions animate with
	views:  []Frame_View,
	ui:     []Ui_Layer,    // screen UI, drawn in order: the game's first, the editor's over it
	panels: []World_Panel, // UI placed in the scene, under the screen UI
	ui_textures:    []Ui_Texture_Draw, // world panels drawn into textures, before the views
	effect_views:   []Effect_View,     // what extensions draw into textures (the Effect stage), before the UI that shows them
	probes:         []Depth_Probe,     // pixels whose depth goes back to the CPU (renderer_depth_probes)
	debug:  []Debug_Lines, // line batches, over the panels and under the screen UI
	// Drawn only into the image renderer_capture reads, for a world that is
	// not shown: nothing reaches the window, and the probe volume keeps the
	// light of the world that is.
	offscreen: bool,
	// A texture the finished image is also copied into, the size of the
	// frame: the shared texture of a player another process shows.
	output: rhi.Texture,
	// Only the screen UI over black: what covers the scene (the editor while
	// its viewport shows the players of a game on the network) saves drawing it.
	ui_only: bool,
}

VIEW_CAPACITY :: 4
// Views drawn into a texture that the renderer keeps targets for, counting
// every size each one is drawn at.
TEXTURE_VIEW_CAPACITY :: 16

Frame_View :: struct {
	camera:Camera,
	camera_cut:bool,
	rect:[4]i32, // where in the drawable; for a view into a texture, z and w are its size
	view_width:i32, // of the whole view rect is the visible part of, for the pixels of the settings; 0: the width of rect
	disabled:bool,
	texture:Texture_Handle, // of view_texture_add: the view is drawn into it, before those of the window
	pipeline:Render_Pipeline_Handle, // 0: the main pipeline of the frame for a view of the window, Full for one drawn into a texture
	carried:Mat4, // the rigid transform that carried the camera since its last frame, keeping what it sees: its histories stay. Zero: none
	inspection:View_Inspection, // what it shows instead of its lit image; changing it keeps its targets and histories
	readback:bool, // of a view into a texture: its image comes back to the CPU without waiting for the GPU (view_texture_pixels)
	wide:View_Wide, // of a view into a texture: its image is also kept at 32-bit float a channel (view_texture_wide)
}

// The image of a view kept wide, besides its 8-bit one: what a recording of
// the view writes to a file.
View_Wide :: enum u8 {
	None,
	Display, // after the tonemap: the display encoding of the window, without its dither or the outline of the editor
	Scene,   // before the tonemap: linear Rec.709, exposed and tinted as the tonemap receives it, unclipped
}

// What a view keeps from one frame to the next: its targets, with their
// histories, and the camera it was last drawn from.
View_State :: struct {
	targets:Targets,
	pipeline:Render_Pipeline_Handle, // the one it was last drawn with
	resources:[CUSTOM_RESOURCE_CAPACITY]View_Resource, // of that pipeline
	resources_size:[4]u32, // the sizes of the targets the resources were made for
	resources_made:bool, // some resource of that pipeline was made in this frame: those with history hold nothing of the frame before
	resources_frames:u32, // the frames drawn since its resources hold a history
	extension_textures:[EXTENSION_TEXTURE_CAPACITY]Extension_Texture, // of pass_texture
	prev_view_proj:Mat4, // from prev_eye, as Gpu_Frame.prev_view_proj
	prev_eye:Vec3,
	prev_jitter:Vec2,
	has_previous:bool,
	generated:bool, // the frame being recorded generated the image shown before its own (Targets.generated)
	frames:u64, // it was drawn: the turn of its histories, of its jitter and of the pixels that share a ray
	glass_dispatch,glass_seen:rhi.Buffer, // Gpu_Glass_Dispatch of the frame being recorded, and whether the glass passes ran in the one before
	dispatch_start:rhi.Buffer, // {0,1,1,0}: copied over an indirect dispatch whose groups in x the GPU counts, to start it each frame
	prev_depth_plane:Vec4,
	texture:Texture_Handle, // of a view drawn into a texture
	copy:rhi.Buffer,        // what carries its image to that texture
	wide:rhi.Texture,       // RGBA32 float: its image as the last frame that asked for it kept it (Frame_View.wide)
	last_frame:u64,         // of the renderer, when it was last drawn
	exposure:rhi.Buffer,    // Gpu_Exposure the view adapts, which its tonemap reads
	exposure_histogram:rhi.Buffer, // EXPOSURE_BINS counts of the luminance of its last image, and of its pixels of sky
	exposure_readback:[rhi.MAX_FRAMES_IN_FLIGHT]rhi.Buffer, // Gpu_Exposure of the frame of each slot, for the CPU
	ev100:f32,              // read back from a frame before: what the view was exposed at
	ev100_known:bool,
	exposure_generation:u32, // counts its discontinuities (view_camera_cut): the first image after one takes the metered exposure at once
	exposure_adapted:Exposure_Adapted, // what its last exposure pass adapted with
}

renderer_camera_cut :: proc(r:^Renderer) {
    view_camera_cut(&r.main)
    for &view in r.views {view_camera_cut(&view)}
    for &view in r.texture_views {view_camera_cut(&view)}
}

@(private)
view_camera_cut :: proc(v:^View_State) {
    v.has_previous=false
    v.exposure_generation+=1
    v.prev_jitter={}
    t:=&v.targets
    t.taa_valid,t.reflect_valid,t.gi_reference_valid=false,false,false
    t.glass_valid,t.hiz_valid=false,false
}

Renderer :: struct {
	device:          ^rhi.Device,
	allocator:       runtime.Allocator,
	settings:        Settings,
	highlight:       Highlight_Style, // the editor's outline levels
	outlines:        Highlight_Style, // the game's outline styles: none drawn until it sets them
	pipelines:       [Pipeline_Id]rhi.Pipeline,
	shader_codes:    [Shader_Id]rhi.Shader_Code,
	shader_assets:   Shader_Assets,
	embedded:        []u8, // the code of the shaders the executable embeds, decoded when it runs them
	embedded_programs:[len(PROGRAM_SHADERS)]rhi.Shader_Code, // PROGRAM_SHADERS with their code in embedded
	postprocesses:   Postprocess_List, // of the views that are no local view (Camera.slot 0)
	view_postprocesses:[VIEW_CAPACITY]Postprocess_List, // of each local view, by Camera.slot - 1
	programs:        Program_Catalog, // of the shaders in use, read when first asked for
	time,previous_time,delta_time:f32,
	overlay_pipelines:[asset.Overlay_Blend]rhi.Pipeline,
	overlay_hw_pipelines:[asset.Overlay_Blend]rhi.Pipeline,
	blit_format:     rhi.Format,
	linear_sampler:  rhi.Sampler,
	point_sampler:   rhi.Sampler,
	material_sampler: rhi.Sampler,
	dummy_buffer:    rhi.Buffer,
	dummy_texture:   rhi.Texture,
	dummy_layers:    rhi.Texture, // in place of the layers target (RGBA32 uint) while there is none
	dfg:             rhi.Texture, // the split-sum table of the specular lobe, in the entry DFG_TEXTURE of the texture table
	air:             Air_State,   // the tables of the air of an atmosphere (air.odin)
	display_lut:     rhi.Texture, // the display transform (display.odin)
	font:            rhi.Texture,
	font_size:       [2]int,
	font_pending:    rhi.Texture_Region, // texels of the atlas the next frame copies; zero: none
	font_pixels:     []u8,               // the atlas they come from, borrowed until that frame records
	font_staging:    [rhi.MAX_FRAMES_IN_FLIGHT]rhi.Buffer,
	thumbnails:      rhi.Texture, // cached GPU previews of editor assets; 0 until it has one
	impostor:        Impostor_GPU, // what impostor_capture keeps from one capture to the next
	previews:        [PREVIEW_CAPACITY]Preview_Request, // images the next frame draws before its UI
	preview_count:   int,
	backdrop:        Vec3, // linear; shown behind the scene instead of the environment's background
	has_backdrop:    bool,
	ui_buffers:      [rhi.MAX_FRAMES_IN_FLIGHT]rhi.Buffer,
	ui_capacity:     int,
	ui_shape_buffers:[rhi.MAX_FRAMES_IN_FLIGHT]rhi.Buffer,
	ui_shape_capacity,ui_layer_depth:int,
	ui_shape_written,ui_shape_cache_count:int,
	ui_shape_cache:[256]Ui_Shape_Upload,
	ui_vertex_cache_count:int,
	ui_vertex_cache:[64]Ui_Shape_Upload, // vertices uploaded in this frame: drawn again over a generated image, they are not copied twice
	debug_buffers:   [rhi.MAX_FRAMES_IN_FLIGHT]rhi.Buffer,
	debug_capacity:  int,
	stats_buffer:    rhi.Buffer,
	scratch_buffer:  rhi.Buffer, // what a pass writes and nobody reads
	light_changes:        rhi.Buffer, // Scene_State.changes of the frame, for the probes
	frame_changes:        Light_Changes, // those of this frame, for the views after the first
	frame_occluders:      Occluder_Changes, // Scene_State.occluders of this frame, for every view
	gi_warm_spread:       u32, // frames left of the warm updates of a blackout (blackout.odin)
	light_frame:          u64,  // counts the updates of the probes: several in the frame of gi_warm
	gi_warm:              bool, // the next frame gathers the light of the world shown from nothing, GI_WARM_UPDATES times
	light_rescale:        f32,  // what the histories of the views and the probes hold, by it, is in the light scale of the scene (0: they are)
	world_key:            u64,  // the world the light of ddgi is of (scene_world)
	origin:               Vec3, // what every place the renderer keeps is relative to (origin.odin), a multiple of ORIGIN_STEP
	frame_views:          [VIEW_CAPACITY + TEXTURE_VIEW_CAPACITY]Frame_View, // those of the frame being recorded, relative to the origin
	frame_detail:         Frame_Detail, // of the frame being recorded, relative to the origin
	world_known:          bool, // scene_world named one
	world_kept:           bool, // the world shown is shown again with its light: the scene_set that follows changes none of it
	world_switched:       bool, // the next frame follows another world: it keeps the delta time of the one before
	kept:                 [WORLDS_MAX - 1]World_Light, // the light of the worlds not shown
	kept_count:           int,
	scene_uploads_change: bool, // the frame uploads a change of the instances, materials or lights: Settings.reference_gi starts over
	glass_stale:          bool, // Gpu_Instance.glass waits for glass_mean.comp: instances, materials or geometry went up since it last ran
	points:               Material_Points, // where the passes of a frame need a material program evaluated (points.odin)
	vertex_stages:        Program_Computes, // of surface_vertices__<program>.comp, which move the vertices of instances (displace.odin)
	program_graphics:     [PROGRAM_GRAPHICS_CAPACITY]Program_Graphics, // the raster stages of Surface programs (program_stages.odin)
	pipeline_thread:      ^Pipeline_Thread, // makes the pipelines of programs; nil: they are made where they are asked for
	stats_readback:  [rhi.MAX_FRAMES_IN_FLIGHT]rhi.Buffer,
	ui_offscreen:    Ui_Offscreen_State,
	using main:      View_State, // the view of a frame that has one
	views:           [VIEW_CAPACITY]View_State, // those of a frame that has several
	view_count:      int,
	texture_views:   [TEXTURE_VIEW_CAPACITY]View_State, // those drawn into a texture, at each size they were
	passes:          [FRAME_PASS_CAPACITY]Frame_Pass, // what extensions record in the next frame
	pass_count:      int,
	plans:           [RENDER_PIPELINE_CAPACITY]Render_Plan, // of the pipelines asked for
	standard_pipelines: [Standard_Pipeline]Render_Pipeline_Handle,
	main_pipeline:   Render_Pipeline_Handle, // of the views of the window in the next frame; 0: Full
	antialiasing:    [ANTIALIASING_CAPACITY]Antialiasing_Desc, // the techniques extensions offer for the next frame
	antialiasing_count: int,
	antialiasing_offered: [ANTIALIASING_CAPACITY]Antialiasing_Desc, // those they offered for the last frame
	antialiasing_offered_count: int,
	view_textures_made: u64,
	frame_layout:    Frame_Layout, // of the constants of a view in the shaders in use
	stage_pipelines: [STAGE_PIPELINE_CAPACITY]Stage_Pipeline, // of the stages of extensions, from the shaders in use
	extension_buffers: [EXTENSION_BUFFER_CAPACITY]Extension_Buffer, // of pass_buffer, by world
	counters:        Extension_Counters, // of pass_counters
	readbacks:       [EXTENSION_READBACK_CAPACITY]Extension_Readback, // of pass_readback, by world
	lights_asked:    u32, // of lights_ask since the last frame began, that cast shadows
	gbuffer_asked:   bit_set[Gbuffer_Target], // of frame_gbuffer_mesh for the next frame
	shadowless_asked: u32, // and that do not
	table_textures:  [EXTENSION_TABLE_TEXTURE_CAPACITY]Extension_Table_Texture, // of pass_table_texture, by world
	quad_indices:    rhi.Buffer, // the six of a quad, for the draws of pass_indices
	scene:           Scene_State,
	textures:        Texture_State,
	ddgi:            Ddgi_State,
	hardware_rt:     bool,
	hardware_rt_verified: bool,   // the startup self-test passed
	hardware_rt_note:     string, // why hardware ray tracing is off (points into note_buffer)
	note_buffer:          [256]u8,
	window_width:    u32, // drawable in device pixels
	window_height:   u32,
	ui_scale:        f32, // device pixels per window point; the UI is authored in points
	pixel_density:   f32, // device pixels per native window coordinate
	frame:           u64,
	stats:           Stats,
	error_buffer:    [512]u8,
	error:           string,
	problem_buffer:  [1024]u8, // of Stats.problem
	tlas_buffer:     [512]u8,  // of tlas_problem
	tlas_problem:    string,   // the native TLAS that was not built; "" when it was
	reload_stop:     ^bool, // a candidate of a reload makes no more pipelines once it is set (renderer_shader_reload_begin)
}

@(private)
set_error :: proc(r: ^Renderer, format: string, args: ..any) {
	r.error = fmt.bprintf(r.error_buffer[:], format, ..args)
}

UI_VERTEX_CAPACITY :: 524288
DEBUG_VERTEX_CAPACITY :: 131072
MATERIAL_ANISOTROPY :: 8

// ---------------------------------------------------------------- lifecycle

renderer_init :: proc(r: ^Renderer, desc: Renderer_Desc) -> bool {
	device, width, height, settings, assets := desc.device, desc.width, desc.height, desc.settings, desc.shaders
	r.device = device
	r.allocator = desc.allocator if desc.allocator.procedure != nil else context.allocator
	scene_init(r)
	r.scene.pages.jobs = desc.jobs
	if desc.pipeline_thread {pipeline_thread_start(r)}
	textures_init(r)
	if assets!=nil && assets.owned {
		r.shader_assets=assets^;r.shader_codes=assets.codes;assets^={}
	} else {
		embedded,problem:=embedded_shaders_decode(&r.shader_codes,&r.embedded_programs,r.allocator)
		if problem!="" {set_error(r,"%s",problem);return false}
		r.embedded=embedded
	}
	info := rhi.device_info(device)
	if s, ok := settings.?; ok {r.settings = s} else {r.settings = CPU_DEVICE_SETTINGS if info.type == .CPU else DEFAULT_SETTINGS}
	r.highlight = DEFAULT_HIGHLIGHT_STYLE
	r.linear_sampler = rhi.sampler_create(device, {filter = .Linear, mip_filter = .Linear, name = "linear clamp"})
	r.point_sampler = rhi.sampler_create(device, {filter = .Nearest, mip_filter = .Nearest, name = "point clamp"})
	r.material_sampler = rhi.sampler_create(device, {filter = .Linear, mip_filter = .Linear, address = .Repeat, anisotropy = MATERIAL_ANISOTROPY, name = "material"})
	r.dummy_buffer = rhi.buffer_create(device, {size = 256, usage = {.Storage}, name = "dummy"})
	r.frame_layout = frame_layout_of(&r.shader_assets)
	r.dummy_texture = rhi.texture_create(device, {width = 1, height = 1, format = .RGBA16_Float, usage = {.Sampled, .Storage, .Color_Target}, name = "dummy"})
	r.dummy_layers = rhi.texture_create(device, {width = 1, height = 1, format = .RGBA32_Uint, usage = {.Sampled, .Color_Target}, name = "dummy layers"})
	r.stats_buffer = rhi.buffer_create(device, {size = size_of(Gpu_Cull_Stats), usage = {.Storage}, name = "cull stats"})
	r.scratch_buffer = rhi.buffer_create(device, {size = 256, usage = {.Storage}, name = "scratch"})
	r.glass_dispatch = rhi.buffer_create(device, {size = size_of(Gpu_Glass_Dispatch), usage = {.Storage, .Indirect}, name = "glass dispatch"})
	r.glass_seen = rhi.buffer_create(device, {size = 16, usage = {.Storage}, name = "glass seen"})
	r.dispatch_start = rhi.buffer_create(device, {size = 16, usage = {.Storage}, name = "dispatch start"})
	r.light_changes = rhi.buffer_create(device, {size = LIGHT_CHANGES_MAX * size_of(Vec4), usage = {.Storage}, name = "light changes"})
	r.kept_count = clamp(desc.worlds if desc.worlds > 0 else WORLDS_DEFAULT, 1, WORLDS_MAX) - 1
	r.gi_warm = true
	for &b in r.stats_readback {b = rhi.buffer_create(device, {size = size_of(Gpu_Cull_Stats), memory = .Readback, name = "stats readback"})}
	r.ui_capacity = desc.ui_vertex_capacity if desc.ui_vertex_capacity > 0 else UI_VERTEX_CAPACITY
	for &b in r.ui_buffers {b = rhi.buffer_create(device, {size = u64(r.ui_capacity * size_of(Ui_Vertex)), usage = {.Storage}, memory = .Upload, name = "ui vertices"})}
	r.ui_shape_capacity=desc.ui_shape_capacity if desc.ui_shape_capacity>0 else UI_SHAPE_CAPACITY
	r.ui_layer_depth=clamp(desc.ui_layer_depth,1,UI_LAYER_DEPTH_CAPACITY) if desc.ui_layer_depth>0 else UI_LAYER_DEPTH_CAPACITY
	for &b in r.ui_shape_buffers {b=rhi.buffer_create(device,{size=u64(r.ui_shape_capacity*size_of(Ui_Shape)),usage={.Storage},memory=.Upload,name="ui shapes"})}
	r.debug_capacity = desc.debug_vertex_capacity if desc.debug_vertex_capacity > 0 else DEBUG_VERTEX_CAPACITY
	for &b in r.debug_buffers {b = rhi.buffer_create(device, {size = u64(r.debug_capacity * size_of(Debug_Vertex)), usage = {.Storage}, memory = .Upload, name = "debug lines"})}
	if r.ui_shape_buffers[0]==0 || r.ui_shape_buffers[1]==0 || r.ui_buffers[0] == 0 || r.ui_buffers[1] == 0 || r.debug_buffers[0] == 0 || r.debug_buffers[1] == 0 || r.linear_sampler == 0 || r.point_sampler == 0 || r.material_sampler == 0 || r.dummy_buffer == 0 || r.dummy_texture == 0 || r.dummy_layers == 0 || r.stats_buffer == 0 || r.scratch_buffer == 0 || r.glass_dispatch == 0 || r.glass_seen == 0 || r.dispatch_start == 0 || r.light_changes == 0 {
		set_error(r, "renderer resources: %s", rhi.device_error(device))
		return false
	}
	dispatch_start := [4]u32{0, 1, 1, 0}
	if !rhi.buffer_upload_slice(device, r.dispatch_start, 0, dispatch_start[:]) {
		set_error(r, "dispatch start: %s", rhi.device_error(device))
		return false
	}
	white := [4]u8{255, 255, 255, 255}
	if !renderer_set_font(r, white[:], 1, 1) {return false}
	if !extension_counters_init(r) || !ui_offscreen_init(r) {return false}
	if !create_pipelines(r) || !pipelines_init(r) || !dfg_build(r) || !display_build(r, DISPLAY_SDR) {return false}
	r.hardware_rt = info.features.ray_query && r.settings.trace_mode != .Software && hardware_pipelines_ready(r)
	if info.features.ray_query {
		verified, note := hardware_rt_self_test(r)
		r.hardware_rt_verified = verified
		r.hardware_rt_note = string(r.note_buffer[:copy(r.note_buffer[:], note)])
		if !r.hardware_rt_verified {r.hardware_rt = false}
	}
	r.scene.tlas_off = r.hardware_rt
	r.window_width = max(width, 1)
	r.window_height = max(height, 1)
	if !create_targets(r, &r.main, r.window_width, r.window_height, window_render_scale(r, f32(r.window_width) * f32(r.window_height)), true) {return false}
	r.scene.instances_dirty = true
	r.scene.lights_dirty = true
	r.scene.tlas_dirty = true
	return true
}

renderer_destroy :: proc(r: ^Renderer) {
	d := r.device
	if d == nil {return}
	rhi.device_wait_idle(d)
	pipeline_thread_destroy(r)
	scene_destroy(r)
	extension_buffers_destroy(r)
	extension_table_textures_destroy(r)
	extension_counters_destroy(r)
	extension_readbacks_destroy(r)
	points_destroy(r)
	ui_offscreen_destroy(r)
	impostor_gpu_destroy(d, &r.impostor)
	textures_clear(r)
	textures_destroy(r)
	ddgi_release(r)
	world_light_destroy(r)
	destroy_view_targets(r)
	for &view in r.texture_views {view_state_destroy(r, &view)}
	destroy_targets(r, &r.main.targets)
	view_resources_free(r, &r.main)
	extension_textures_release(r, &r.main, all = true)
	view_exposure_release(r, &r.main)
	for p in r.pipelines {if p != 0 {rhi.pipeline_destroy(d, p)}}
	program_graphics_destroy(r)
	stage_pipelines_destroy(r)
	for p in r.overlay_pipelines {if p!=0 {rhi.pipeline_destroy(d,p)}}
	for p in r.overlay_hw_pipelines {if p!=0 {rhi.pipeline_destroy(d,p)}}
	for b in r.ui_buffers {if b != 0 {rhi.buffer_destroy(d, b)}}
	for b in r.ui_shape_buffers {if b!=0 {rhi.buffer_destroy(d,b)}}
	for b in r.debug_buffers {if b != 0 {rhi.buffer_destroy(d, b)}}
	for b in r.font_staging {if b != 0 {rhi.buffer_destroy(d, b)}}
	for b in r.stats_readback {if b != 0 {rhi.buffer_destroy(d, b)}}
	for b in ([]rhi.Buffer{r.stats_buffer, r.scratch_buffer, r.glass_dispatch, r.glass_seen, r.dispatch_start, r.dummy_buffer}) {if b != 0 {rhi.buffer_destroy(d, b)}}
	if r.light_changes != 0 {rhi.buffer_destroy(d, r.light_changes)}
	for t in ([]rhi.Texture{r.dummy_texture, r.dummy_layers, r.dfg, r.display_lut, r.font, r.thumbnails}) {if t != 0 {rhi.texture_destroy(d, t)}}
	air_destroy(r)
	if r.linear_sampler != 0 {rhi.sampler_destroy(d, r.linear_sampler)}
	if r.point_sampler != 0 {rhi.sampler_destroy(d, r.point_sampler)}
	if r.material_sampler != 0 {rhi.sampler_destroy(d, r.material_sampler)}
	program_catalog_destroy(&r.programs)
	shader_assets_destroy(&r.shader_assets)
	delete(r.embedded,r.allocator)
	r^ = {}
}

// DFG_SIZE and DFG_TEXTURE of brdf.slang.
DFG_SIZE :: 64
DFG_TEXTURE :: 0

// The split-sum table of the specular lobe (dfg.comp), built once into the
// last entry of the texture table, which materials leave free.
@(private)
dfg_build :: proc(r: ^Renderer) -> bool {
	d := r.device
	pipeline := rhi.pipeline_create_compute(d, {shader = &r.shader_codes[.Dfg_Comp], name = "dfg"})
	defer if pipeline != 0 {rhi.pipeline_destroy(d, pipeline)}
	table := rhi.buffer_create(d, {size = DFG_SIZE * DFG_SIZE * 4, usage = {.Storage, .Transfer_Src}, name = "dfg table"})
	defer if table != 0 {rhi.buffer_destroy(d, table)}
	r.dfg = rhi.texture_create(d, {width = DFG_SIZE, height = DFG_SIZE, format = .RG16_Float, usage = {.Sampled}, name = "dfg"})
	if pipeline == 0 || table == 0 || r.dfg == 0 {
		set_error(r, "dfg table: %s", rhi.device_error(d))
		return false
	}
	cmd := rhi.immediate_begin(d)
	rhi.cmd_bind_pipeline(cmd, pipeline)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS0, table)
	rhi.cmd_dispatch(cmd, groups(DFG_SIZE, 8), groups(DFG_SIZE, 8))
	rhi.cmd_copy_buffer_to_texture(cmd, table, 0, r.dfg)
	rhi.cmd_barrier_texture(cmd, r.dfg, .Shader_Read)
	if !rhi.immediate_end(d, cmd) || !rhi.texture_table_set(d, DFG_TEXTURE, r.dfg) {
		set_error(r, "dfg table: %s", rhi.device_error(d))
		return false
	}
	return true
}

// Which rays a pipeline traces: the frames run those of one way only.
@(private)
Pipeline_Rays :: enum u8 {Any, Software, Hardware}

// A pipeline of create_pipelines, made into target: a compute one of
// shaders[0], or a graphics one of desc.
@(private)
Pipeline_Make :: struct {
	target:   ^rhi.Pipeline,
	shaders:  [2]Shader_Id,
	rays:     Pipeline_Rays,
	clip:     bool, // it needs a device that clips by a plane
	required: bool, // the renderer fails without it
	graphics: bool,
	desc:     rhi.Graphics_Pipeline_Desc,
	cost:     int, // bytes of its code: the driver takes longer with more
}

@(private)
Pipeline_List :: struct {
	items: [len(Pipeline_Id) + 2 * len(asset.Overlay_Blend)]Pipeline_Make,
	count: int,
}

// The pipelines of a renderer, or of the candidate of a reload, the same for
// every device: pipeline_possible says which this one makes.
@(private)
pipelines_list :: proc(r: ^Renderer, list: ^Pipeline_List) {
	list.count = 0
	compute :: proc(list: ^Pipeline_List, r: ^Renderer, id: Pipeline_Id, shader: Shader_Id) {
		pipeline_listed(list, {target = &r.pipelines[id], shaders = {shader, shader}, rays = pipeline_rays(id), clip = pipeline_uses_clip_distance(id),
			required = pipeline_required(id)})
	}
	graphics :: proc(list: ^Pipeline_List, r: ^Renderer, id: Pipeline_Id, desc: rhi.Graphics_Pipeline_Desc) {
		pipeline_listed(list, {target = &r.pipelines[id], shaders = {shader_of(r, desc.vertex), shader_of(r, desc.fragment)}, rays = pipeline_rays(id),
			clip = pipeline_uses_clip_distance(id), required = pipeline_required(id), graphics = true, desc = desc})
	}
	compute(list, r, .Cull, .Cull_Comp)
	compute(list, r, .Cull_Clusters, .Cull_Clusters_Comp)
	compute(list, r, .Cull_Clusters_Candidates, .Cull_Clusters_Candidates_Comp)
	compute(list, r, .Cull_Programs, .Cull_Programs_Comp)
	compute(list, r, .Tlas_Batches, .Tlas_Batches_Comp)
	compute(list, r, .Light_Grid_Count, .Light_Grid_Comp)
	compute(list, r, .Light_Grid_Scan, .Light_Grid_Scan_Comp)
	compute(list, r, .Light_Grid_Fill, .Light_Grid_Fill_Comp)
	compute(list, r, .Light_Grid_Weights, .Light_Grid_Weights_Comp)
	compute(list, r, .Direct_Rays, .Direct_Rays_Comp)
	compute(list, r, .Direct_Samples, .Direct_Samples_Comp)
	compute(list, r, .Direct_Samples_Unlayered, .Direct_Samples_Unlayered_Comp)
	compute(list, r, .Direct_Samples_Color, .Direct_Samples_Color_Comp)
	compute(list, r, .Direct_Samples_Unlayered_Color, .Direct_Samples_Unlayered_Color_Comp)
	compute(list, r, .Direct_Points, .Direct_Points_Comp)
	compute(list, r, .Direct_Spread, .Direct_Spread_Comp)
	compute(list, r, .Direct_Filter, .Direct_Filter_Comp)
	compute(list, r, .Direct_Filter_Unlayered, .Direct_Filter_Unlayered_Comp)
	compute(list, r, .Ddgi_Trace, .Ddgi_Trace_Comp)
	compute(list, r, .Ddgi_Trace_Color, .Ddgi_Trace_Color_Comp)
	compute(list, r, .Ddgi_Irradiance, .Ddgi_Irradiance_Comp)
	compute(list, r, .Ddgi_Keep, .Ddgi_Keep_Comp)
	compute(list, r, .Ddgi_Distance, .Ddgi_Distance_Comp)
	compute(list, r, .Ddgi_Relocate, .Ddgi_Relocate_Comp)
	compute(list, r, .Ddgi_Select, .Ddgi_Select_Comp)
	compute(list, r, .Ddgi_Touch, .Ddgi_Touch_Comp)
	compute(list, r, .Ddgi_Mark, .Ddgi_Mark_Comp)
	compute(list, r, .Contact, .Contact_Comp)
	compute(list, r, .Contact_Light, .Contact_Light_Comp)
	compute(list, r, .Contact_Pixels, .Contact_Pixels_Comp)
	compute(list, r, .Composite, .Composite_Comp)
	compute(list, r, .Composite_Unlayered, .Composite_Unlayered_Comp)
	compute(list, r, .Taa, .Taa_Comp)
	compute(list, r, .Hiz, .Hiz_Comp)
	compute(list, r, .Exposure_Histogram, .Exposure_Histogram_Comp)
	compute(list, r, .Exposure_Adapt, .Exposure_Adapt_Comp)
	compute(list, r, .Reflect, .Reflect_Comp)
	compute(list, r, .Reflect_Color, .Reflect_Color_Comp)
	compute(list, r, .Reflect_Unlayered, .Reflect_Unlayered_Comp)
	compute(list, r, .Reflect_Unlayered_Color, .Reflect_Unlayered_Color_Comp)
	compute(list, r, .Reflect_Resolve, .Reflect_Resolve_Comp)
	compute(list, r, .History_Scale, .History_Scale_Comp)
	compute(list, r, .Air_Transmittance, .Air_Transmittance_Comp)
	compute(list, r, .Air_Scattering, .Air_Scattering_Comp)
	compute(list, r, .Air_Sky, .Air_Sky_Comp)
	compute(list, r, .Air_Aerial, .Air_Aerial_Comp)
	compute(list, r, .Reflect_Resolve_Glass, .Reflect_Resolve_Glass_Comp)
	compute(list, r, .Glass_Mean, .Glass_Mean_Comp)
	compute(list, r, .Points, .Points_Comp)
	compute(list, r, .Skin, .Skin_Comp)
	compute(list, r, .Skin_Triangles, .Skin_Triangles_Comp)
	compute(list, r, .Skin_Refit, .Skin_Refit_Comp)
	compute(list, r, .Direct_Rays_Hw, .Direct_Rays_Hw_Comp)
	compute(list, r, .Direct_Samples_Hw, .Direct_Samples_Hw_Comp)
	compute(list, r, .Direct_Samples_Hw_Unlayered, .Direct_Samples_Hw_Unlayered_Comp)
	compute(list, r, .Direct_Samples_Color_Hw, .Direct_Samples_Color_Hw_Comp)
	compute(list, r, .Direct_Samples_Hw_Unlayered_Color, .Direct_Samples_Hw_Unlayered_Color_Comp)
	compute(list, r, .Direct_Filter_Hw, .Direct_Filter_Hw_Comp)
	compute(list, r, .Direct_Filter_Hw_Unlayered, .Direct_Filter_Hw_Unlayered_Comp)
	compute(list, r, .Ddgi_Trace_Hw, .Ddgi_Trace_Hw_Comp)
	compute(list, r, .Ddgi_Trace_Color_Hw, .Ddgi_Trace_Color_Hw_Comp)
	compute(list, r, .Contact_Hw, .Contact_Hw_Comp)
	compute(list, r, .Reflect_Hw, .Reflect_Hw_Comp)
	compute(list, r, .Reflect_Color_Hw, .Reflect_Color_Hw_Comp)
	compute(list, r, .Reflect_Unlayered_Hw, .Reflect_Unlayered_Hw_Comp)
	compute(list, r, .Reflect_Unlayered_Color_Hw, .Reflect_Unlayered_Color_Hw_Comp)
	ids := r.frame_layout.instance_ids
	gbuffer := rhi.Graphics_Pipeline_Desc{
		vertex = &r.shader_codes[.Gbuffer_Batches_Vert], fragment = &r.shader_codes[.Gbuffer_Frag],
		color_formats = {0 = .RGBA8_Srgb, 1 = .RGBA16_Float, 2 = .RGBA16_Float, 3 = .RGBA16_Float, 4 = .R32_Float, 5 = .RGBA8_Srgb}, color_count = 6,
		depth_format = .D32_Float, depth_test = true, depth_write = true, depth_compare = .Greater, cull = .None,
		name = "gbuffer",
	}
	graphics(list, r, .Gbuffer, gbuffer_ids(gbuffer, ids))
	plain := gbuffer
	plain.fragment = &r.shader_codes[.Gbuffer_Plain_Frag]
	plain.color_count = 5
	plain.name = "gbuffer without reflectance"
	graphics(list, r, .Gbuffer_Plain, gbuffer_ids(plain, ids))
	layered := gbuffer
	layered.fragment = &r.shader_codes[.Gbuffer_Layers_Frag]
	layered.color_formats[6], layered.color_count = .RGBA32_Uint, 7
	layered.name = "gbuffer with layers"
	graphics(list, r, .Gbuffer_Layers, gbuffer_ids(layered, ids))
	clipped, clipped_plain := gbuffer, plain
	clipped.vertex, clipped_plain.vertex = &r.shader_codes[.Gbuffer_Clip_Vert], &r.shader_codes[.Gbuffer_Clip_Vert]
	clipped.name, clipped_plain.name = "gbuffer with a clip plane", "gbuffer with a clip plane, without reflectance"
	graphics(list, r, .Gbuffer_Clip, gbuffer_ids(clipped, ids))
	graphics(list, r, .Gbuffer_Plain_Clip, gbuffer_ids(clipped_plain, ids))
	clipped.fragment, clipped_plain.fragment = &r.shader_codes[.Gbuffer_Nested_Frag], &r.shader_codes[.Gbuffer_Nested_Plain_Frag]
	clipped.name, clipped_plain.name = "gbuffer of a nested view", "gbuffer of a nested view, without reflectance"
	graphics(list, r, .Gbuffer_Nested, gbuffer_ids(clipped, ids))
	graphics(list, r, .Gbuffer_Nested_Plain, gbuffer_ids(clipped_plain, ids))
	clipped_layered := layered
	clipped_layered.vertex = &r.shader_codes[.Gbuffer_Clip_Vert]
	clipped_layered.name = "gbuffer with a clip plane, with layers"
	graphics(list, r, .Gbuffer_Layers_Clip, gbuffer_ids(clipped_layered, ids))
	clipped_layered.fragment = &r.shader_codes[.Gbuffer_Nested_Layers_Frag]
	clipped_layered.name = "gbuffer of a nested view, with layers"
	graphics(list, r, .Gbuffer_Nested_Layers, gbuffer_ids(clipped_layered, ids))
	graphics(list, r, .Nested_Prime, {
		vertex = &r.shader_codes[.Fullscreen_Vert], fragment = &r.shader_codes[.Nested_Prime_Frag],
		depth_format = .D32_Float, depth_test = true, depth_write = true, depth_compare = .Always, name = "nested view pixels",
	})
	graphics(list, r, .Nested_Reflectance, {
		vertex = &r.shader_codes[.Fullscreen_Vert], fragment = &r.shader_codes[.Nested_Reflectance_Frag],
		color_formats = {0 = .RGBA8_Srgb}, color_count = 1, name = "reflectance of a view before its nested views",
	})
	compute(list, r, .Glass, .Glass_Comp)
	compute(list, r, .Glass_Color, .Glass_Color_Comp)
	compute(list, r, .Glass_Inside, .Glass_Inside_Comp)
	compute(list, r, .Glass_Inside_Color, .Glass_Inside_Color_Comp)
	compute(list, r, .Glass_Hw, .Glass_Hw_Comp)
	compute(list, r, .Glass_Color_Hw, .Glass_Color_Hw_Comp)
	compute(list, r, .Glass_Inside_Hw, .Glass_Inside_Hw_Comp)
	compute(list, r, .Glass_Inside_Color_Hw, .Glass_Inside_Color_Hw_Comp)
	graphics(list, r, .Glass_Layer, {
		vertex = &r.shader_codes[.Gbuffer_Vert], fragment = &r.shader_codes[.Glass_Layer_Frag],
		color_formats = {0 = .RGBA8_Srgb, 1 = .RGBA16_Float, 2 = .RGBA16_Float, 3 = .RG32_Uint, 4 = .R32_Float, 5 = .RGBA8_Srgb}, color_count = 6,
		depth_format = .D32_Float, depth_test = true, depth_write = true, depth_compare = .Greater, cull = .None,
		name = "glass layer",
	})
	graphics(list, r, .Glass_Layer_Layers, {
		vertex = &r.shader_codes[.Gbuffer_Vert], fragment = &r.shader_codes[.Glass_Layer_Layers_Frag],
		color_formats = {0 = .RGBA8_Srgb, 1 = .RGBA16_Float, 2 = .RGBA16_Float, 3 = .RG32_Uint, 4 = .R32_Float, 5 = .RGBA8_Srgb, 6 = .RGBA32_Uint}, color_count = 7,
		depth_format = .D32_Float, depth_test = true, depth_write = true, depth_compare = .Greater, cull = .None,
		name = "glass layer with layers",
	})
	translucent := rhi.Graphics_Pipeline_Desc{
		vertex = &r.shader_codes[.Gbuffer_Vert], fragment = &r.shader_codes[.Glass_Filter_Frag],
		color_formats = {0 = .RGBA16_Float}, color_count = 1, blend = {0 = .Multiply},
		depth_format = .D32_Float, depth_test = true, depth_write = false, depth_compare = .Less, cull = .None,
		name = "translucent",
	}
	graphics(list, r, .Glass_Filter, translucent)
	translucent.fragment = &r.shader_codes[.Translucent_Frag]
	translucent.blend = {0 = .Additive}
	graphics(list, r, .Translucent, translucent)
	translucent.fragment = &r.shader_codes[.Translucent_Color_Frag]
	graphics(list, r, .Translucent_Color, translucent)
	translucent.fragment = &r.shader_codes[.Translucent_Hw_Frag]
	graphics(list, r, .Translucent_Hw, translucent)
	translucent.fragment = &r.shader_codes[.Translucent_Color_Hw_Frag]
	graphics(list, r, .Translucent_Color_Hw, translucent)
	highlight := gbuffer
	highlight.vertex = &r.shader_codes[.Gbuffer_Highlight_Vert]
	highlight.fragment = &r.shader_codes[.Highlight_Frag]
	highlight.color_formats = {0 = .RG32_Float}
	highlight.color_count = 1
	highlight.name = "highlight mask"
	graphics(list, r, .Highlight, highlight)
	compute(list, r, .Highlight_Filter, .Highlight_Filter_Comp)
	graphics(list, r, .Shadow_Map, {
		vertex = &r.shader_codes[.Shadow_Map_Vert], fragment = &r.shader_codes[.Shadow_Map_Frag],
		depth_format = .D32_Float, depth_test = true, depth_write = true, depth_compare = .Greater, cull = .None, name = "shadow maps",
	})
	graphics(list, r, .Shadow_Map_Tested, {
		vertex = &r.shader_codes[.Shadow_Map_Tested_Vert], fragment = &r.shader_codes[.Shadow_Map_Tested_Frag],
		depth_format = .D32_Float, depth_test = true, depth_write = true, depth_compare = .Greater, cull = .None, name = "shadow maps of masked materials",
	})
	compute(list, r, .Shadow_Maps, .Shadow_Maps_Comp)
	graphics(list, r, .Tonemap, {
		vertex = &r.shader_codes[.Fullscreen_Vert], fragment = &r.shader_codes[.Tonemap_Frag],
		color_formats = {0 = .RGBA8_Unorm}, color_count = 1, name = "tonemap",
	})
	graphics(list, r, .Tonemap_Wide, {
		vertex = &r.shader_codes[.Fullscreen_Vert], fragment = &r.shader_codes[.Tonemap_Frag],
		color_formats = {0 = .RGBA32_Float}, color_count = 1, name = "tonemap wide",
	})
	graphics(list, r, .Postprocess_Copy, {vertex=&r.shader_codes[.Fullscreen_Vert],fragment=&r.shader_codes[.Blit_Frag],color_formats={0=.RGBA8_Unorm},color_count=1,name="postprocess copy"})
	for id in ([]Pipeline_Id{.Postprocess_Hdr,.Postprocess_Ldr}) {
		graphics(list,r,id,{vertex=&r.shader_codes[.Fullscreen_Vert],fragment=&r.shader_codes[.Postprocess_Frag],color_formats={0=.RGBA8_Unorm if id==.Postprocess_Ldr else .RGBA16_Float},color_count=1,name="postprocess"})
	}
	graphics(list, r, .Ui, {
		vertex = &r.shader_codes[.Ui_Vert], fragment = &r.shader_codes[.Ui_Frag],
		color_formats = {0 = .RGBA8_Unorm}, color_count = 1, blend = {0 = .Alpha}, name = "ui",
	})
	graphics(list, r, .Ui_Composite, {vertex=&r.shader_codes[.Fullscreen_Vert],fragment=&r.shader_codes[.Ui_Composite_Frag],color_formats={0=.RGBA8_Unorm},color_count=1,blend={0=.Premultiplied},name="ui layer composite"})
	graphics(list, r, .Ui_Blur, {vertex=&r.shader_codes[.Fullscreen_Vert],fragment=&r.shader_codes[.Ui_Blur_Frag],color_formats={0=.RGBA8_Unorm},color_count=1,name="ui backdrop blur"})
	graphics(list, r, .Ui_Particles, {vertex=&r.shader_codes[.Fullscreen_Vert],fragment=&r.shader_codes[.Ui_Particles_Frag],color_formats={0=.RGBA8_Unorm},color_count=1,name="particle view resolve"})
	compute(list, r, .Depth_Probe, .Depth_Probe_Comp)
    graphics(list, r, .Thumbnail, {
        vertex = &r.shader_codes[.Thumbnail_Vert], fragment = &r.shader_codes[.Thumbnail_Frag],
        color_formats = {0 = .RGBA8_Unorm}, color_count = 1, blend = {0 = .Premultiplied},
        depth_format = .D32_Float, depth_test = true, depth_write = true, depth_compare = .Greater, cull = .None,
        name = "thumbnail studio",
    })
    graphics(list, r, .Thumbnail_Values, {
        vertex = &r.shader_codes[.Thumbnail_Vert], fragment = &r.shader_codes[.Thumbnail_Values_Frag],
        color_formats = {0 = .RGBA8_Unorm, 1 = .RGBA32_Float, 2 = .RGBA32_Float, 3 = .RGBA32_Float, 4 = .RGBA32_Float, 5 = .RGBA32_Float},
        color_count = 1 + len(Thumbnail_Target), blend = {0 = .Premultiplied},
        depth_format = .D32_Float, depth_test = true, depth_write = true, depth_compare = .Greater, cull = .None,
        name = "material capture",
    })
    graphics(list, r, .Impostor, {
        vertex = &r.shader_codes[.Thumbnail_Vert], fragment = &r.shader_codes[.Thumbnail_Impostor_Frag],
        color_formats = {0 = .RGBA8_Srgb, 1 = .RGBA8_Unorm}, color_count = 2,
        depth_format = .D32_Float, depth_test = true, depth_write = true, depth_compare = .Greater, cull = .None,
        name = "impostor capture",
    })
    graphics(list, r, .Preview_Backdrop, {
        vertex = &r.shader_codes[.Fullscreen_Vert], fragment = &r.shader_codes[.Preview_Backdrop_Frag],
        color_formats = {0 = .RGBA8_Unorm}, color_count = 1, depth_format = .D32_Float, name = "preview backdrop",
    })
	graphics(list, r, .Ui_World, {
		vertex = &r.shader_codes[.Ui_World_Vert], fragment = &r.shader_codes[.Ui_World_Frag],
		color_formats = {0 = .RGBA8_Unorm}, color_count = 1, blend = {0 = .Alpha}, name = "world ui",
	})
	graphics(list, r, .Debug_Lines, {
		vertex = &r.shader_codes[.Debug_Vert], fragment = &r.shader_codes[.Debug_Frag],
		color_formats = {0 = .RGBA8_Unorm}, color_count = 1, blend = {0 = .Alpha}, topology = .Lines, name = "debug lines",
	})
	overlay_pipelines_list(r, list)
}

@(private)
pipeline_listed :: proc(list: ^Pipeline_List, item: Pipeline_Make) {
	list.items[list.count] = item
	list.count += 1
}

// The index of a code of r.shader_codes.
@(private)
shader_of :: proc(r: ^Renderer, code: ^rhi.Shader_Code) -> Shader_Id {
	return Shader_Id(int(min(Shader_Id)) + int((uintptr(code) - uintptr(&r.shader_codes[min(Shader_Id)])) / size_of(rhi.Shader_Code)))
}

@(private)
pipeline_rays :: proc(id: Pipeline_Id) -> Pipeline_Rays {
	if pipeline_uses_hardware(id) {return .Hardware}
	if pipeline_uses_software(id) {return .Software}
	return .Any
}

// The renderer fails without these; without one of rays traced by hardware
// it traces them by software.
@(private)
pipeline_required :: proc(id: Pipeline_Id) -> bool {
	return id != .Blit && id not_in LAZY_PIPELINES && !pipeline_uses_hardware(id) && !pipeline_uses_clip_distance(id)
}

@(private)
pipeline_possible :: proc(info: ^rhi.Device_Info, item: Pipeline_Make) -> bool {
	return (item.rays != .Hardware || info.features.ray_query) && (!item.clip || info.features.clip_distance)
}

// Makes the pipelines of r that the device can, the costliest first, on a
// thread a core (half the logical processors): the driver compiles each one
// for up to seconds. Once r.reload_stop is set, from any thread, none more is
// made. False when one the renderer needs is not there.
@(private)
create_pipelines :: proc(r: ^Renderer) -> bool {
	list: Pipeline_List
	pipelines_list(r, &list)
	info := rhi.device_info(r.device)
	Work :: struct {
		r:     ^Renderer,
		list:  ^Pipeline_List,
		order: [len(Pipeline_List{}.items)]int,
		count: int,
		next:  int, // atomic, into order
	}
	work := Work{r = r, list = &list}
	for &item, i in list.items[:list.count] {
		if !pipeline_possible(info, item) {continue}
		for id in item.shaders[:2 if item.graphics else 1] {
			item.cost += len(r.shader_codes[id].msl) when ODIN_OS == .Darwin else len(r.shader_codes[id].spirv)
		}
		at := work.count
		for at > 0 && list.items[work.order[at - 1]].cost < item.cost {
			work.order[at] = work.order[at - 1]
			at -= 1
		}
		work.order[at] = i
		work.count += 1
	}
	run :: proc(work: ^Work) {
		for {
			at := sync.atomic_add(&work.next, 1)
			if at >= work.count {return}
			r, item := work.r, &work.list.items[work.order[at]]
			if r.reload_stop != nil && sync.atomic_load(r.reload_stop) {return}
			if item.graphics {
				item.target^ = rhi.pipeline_create_graphics(r.device, item.desc)
			} else {
				code := &r.shader_codes[item.shaders[0]]
				item.target^ = rhi.pipeline_create_compute(r.device, {shader = code, name = code.name})
			}
		}
	}
	threads: [PIPELINE_THREADS_MAX]^thread.Thread
	helpers := clamp(os.get_processor_core_count() / 2, 1, min(PIPELINE_THREADS_MAX, max(work.count, 1))) - 1
	for &t in threads[:helpers] {
		t = thread.create_and_start_with_poly_data(&work, proc(work: ^Work) {
			defer free_all(context.temp_allocator)
			run(work)
		})
	}
	run(&work)
	for t in threads[:helpers] {
		if t == nil {continue}
		thread.join(t)
		thread.destroy(t)
	}
	for item in list.items[:list.count] {
		if !item.required || !pipeline_possible(info, item) || item.target^ != 0 {continue}
		set_error(r, "pipeline %s: %s", item.desc.name if item.graphics else r.shader_codes[item.shaders[0]].name, rhi.device_error(r.device))
		return false
	}
	return true
}

// Threads that make the pipelines of a renderer at most, with the one that asks.
@(private)
PIPELINE_THREADS_MAX :: 16

// The stages of r that none of the pipelines its frames run now is made of:
// those of the rays it does not trace, of pipelines the device does not make
// and of lazy ones no frame asked for. A generation that changes only these
// leaves the image as it is.
renderer_shaders_idle :: proc(r: ^Renderer) -> (idle: [Shader_Id]bool) {
	list: Pipeline_List
	pipelines_list(r, &list)
	busy: [Shader_Id]bool
	running :: proc(r: ^Renderer, pipeline: rhi.Pipeline, rays: Pipeline_Rays) -> bool {
		return pipeline != 0 && !(rays == .Software && r.hardware_rt) && !(rays == .Hardware && !r.hardware_rt)
	}
	for item in list.items[:list.count] {
		used := running(r, item.target^, item.rays)
		for id in item.shaders {
			if used {busy[id] = true} else {idle[id] = true}
		}
	}
	for lazy in LAZY_SHADERS {
		if running(r, r.pipelines[lazy.pipeline], pipeline_rays(lazy.pipeline)) {busy[lazy.shader] = true} else {idle[lazy.shader] = true}
	}
	for id in Shader_Id {idle[id] &&= !busy[id]}
	return
}

// Variants are compiled from one Slang source. Optional transport does not
// increase register pressure in the ordinary terminating shadow query.
@(private)
pipeline_uses_hardware :: proc(id:Pipeline_Id)->bool {
    #partial switch id {
    case .Direct_Rays_Hw,.Direct_Samples_Hw,.Direct_Samples_Hw_Unlayered,.Direct_Samples_Color_Hw,.Direct_Samples_Hw_Unlayered_Color,.Direct_Filter_Hw,.Direct_Filter_Hw_Unlayered,.Ddgi_Trace_Hw,.Contact_Hw,.Reflect_Hw,.Translucent_Hw,.Glass_Hw,
         .Ddgi_Trace_Color_Hw,.Reflect_Color_Hw,.Translucent_Color_Hw,.Glass_Color_Hw,.Gi_Reference_Hw,.Glass_Inside_Hw,.Glass_Inside_Color_Hw,
         .Reflect_Unlayered_Hw,.Reflect_Unlayered_Color_Hw:
        return true
    }
    return false
}

// Their frames trace rays by software.
@(private)
pipeline_uses_software :: proc(id:Pipeline_Id)->bool {
    #partial switch id {
    case .Direct_Rays,.Direct_Samples,.Direct_Samples_Unlayered,.Direct_Samples_Color,.Direct_Samples_Unlayered_Color,.Direct_Filter,.Direct_Filter_Unlayered,.Ddgi_Trace,.Ddgi_Trace_Color,.Contact,.Reflect,.Reflect_Color,.Reflect_Unlayered,.Reflect_Unlayered_Color,
         .Translucent,.Translucent_Color,.Glass,.Glass_Color,.Glass_Inside,.Glass_Inside_Color,.Gi_Reference:
        return true
    }
    return false
}

// Whether every pipeline of ray queries made with the others is there; one of
// LAZY_PIPELINES that cannot be made fails the frame that asks for it. Rays
// traced by hardware never fall back to the software BVH: it is not kept.
@(private)
hardware_pipelines_ready :: proc(r: ^Renderer) -> bool {
	for p, id in r.pipelines {
		if pipeline_uses_hardware(id) && id not_in LAZY_PIPELINES && p == 0 {return false}
	}
	return true
}

// These need a device that clips by a plane a vertex shader writes.
@(private)
pipeline_uses_clip_distance :: proc(id:Pipeline_Id)->bool {
    #partial switch id {
    case .Gbuffer_Clip,.Gbuffer_Plain_Clip,.Gbuffer_Layers_Clip,.Gbuffer_Nested,.Gbuffer_Nested_Plain,.Gbuffer_Nested_Layers,.Nested_Prime,.Nested_Reflectance: return true
    }
    return false
}

// Pipelines only some frames use, made the first time one asks for them: the
// driver keeps the code of each one it compiles. Those of ray queries are
// made only where the device has them.
@(private)
LAZY_SHADERS :: [?]struct {pipeline: Pipeline_Id, shader: Shader_Id}{
	{.Debug_Views, .Debug_Views_Comp},
	{.Gi_Reference, .Gi_Reference_Comp},
	{.Gi_Reference_Hw, .Gi_Reference_Hw_Comp},
}
@(private)
LAZY_PIPELINES :: bit_set[Pipeline_Id]{.Debug_Views, .Gi_Reference, .Gi_Reference_Hw}

@(private)
ensure_pipelines :: proc(r: ^Renderer, wanted: bit_set[Pipeline_Id]) -> bool {
	ray_query := rhi.device_info(r.device).features.ray_query
	for lazy in LAZY_SHADERS {
		if lazy.pipeline not_in wanted || r.pipelines[lazy.pipeline] != 0 || (pipeline_uses_hardware(lazy.pipeline) && !ray_query) {continue}
		r.pipelines[lazy.pipeline] = rhi.pipeline_create_compute(r.device, {shader = &r.shader_codes[lazy.shader], name = r.shader_codes[lazy.shader].name})
		if r.pipelines[lazy.pipeline] == 0 {
			set_error(r, "pipeline %v: %s", lazy.pipeline, rhi.device_error(r.device))
			return false
		}
	}
	return true
}

@(private)
ensure_blit_pipeline :: proc(r: ^Renderer, format: rhi.Format) -> bool {
	if r.pipelines[.Blit] != 0 && r.blit_format == format {return true}
	if r.pipelines[.Blit] != 0 {rhi.pipeline_destroy(r.device, r.pipelines[.Blit])}
	r.pipelines[.Blit] = rhi.pipeline_create_graphics(r.device, {
		vertex = &r.shader_codes[.Fullscreen_Vert], fragment = &r.shader_codes[.Blit_Frag],
		color_formats = {0 = format}, color_count = 1, name = "present blit",
	})
	r.blit_format = format
	return r.pipelines[.Blit] != 0
}

renderer_set_font :: proc(r: ^Renderer, pixels: []u8, width, height: int, changed := rhi.Texture_Region{}) -> bool {
	d := r.device
	// An atlas of the same size has the texels that changed copied by the
	// frame that records next, without waiting for the GPU: pixels must stay
	// valid until then.
	if r.font != 0 && r.font_size == {width, height} && len(pixels) >= width * height {
		region, inside := rhi.texture_region_resolve({width = u32(width), height = u32(height), format = .R8_Unorm}, 0, changed)
		if !inside {set_error(r, "font atlas: the region %v is not inside it", changed); return false}
		if p := r.font_pending; p.width > 0 && p.height > 0 {
			x0, y0 := min(p.x, region.x), min(p.y, region.y)
			x1, y1 := max(p.x + p.width, region.x + region.width), max(p.y + p.height, region.y + region.height)
			region = {x0, y0, x1 - x0, y1 - y0}
		}
		r.font_pending, r.font_pixels = region, pixels
		return true
	}
	r.font_pending, r.font_pixels = {}, nil
	texture := rhi.texture_create(d, {width = u32(width), height = u32(height), format = .R8_Unorm, usage = {.Sampled}, name = "font atlas"})
	if texture == 0 || !rhi.texture_upload(d, texture, pixels, u32(width)) {
		set_error(r, "font atlas: %s", rhi.device_error(d))
		if texture != 0 {rhi.texture_destroy(d, texture)}
		return false
	}
	if r.font != 0 {rhi.texture_destroy(d, r.font)}
	r.font, r.font_size = texture, {width, height}
	return true
}

// Copies the texels renderer_set_font left for this frame into the atlas,
// before anything samples it.
@(private)
font_record :: proc(r: ^Renderer, cmd: ^rhi.Command_List, slot: int) -> bool {
	region := r.font_pending
	if region.width == 0 || region.height == 0 || r.font == 0 {return true}
	r.font_pending = {}
	width := r.font_size.x
	if ok, _ := ensure_buffer(r, &r.font_staging[slot], u64(region.width * region.height), {.Transfer_Src}, "font staging", .Upload); !ok {
		set_error(r, "font staging: %s", rhi.device_error(r.device))
		return false
	}
	staging := cast([^]u8)rhi.buffer_mapped(r.device, r.font_staging[slot])
	if staging == nil {set_error(r, "font staging is not mapped"); return false}
	for row in 0 ..< int(region.height) {
		copy(staging[row * int(region.width):][:region.width], r.font_pixels[(int(region.y) + row) * width + int(region.x):][:region.width])
	}
	rhi.cmd_copy_buffer_to_texture(cmd, r.font_staging[slot], 0, r.font, 0, region)
	rhi.cmd_barrier_texture(cmd, r.font, .Shader_Read)
	return true
}

// The previews of assets the UI draws with UI_MATERIAL_THUMBNAIL: RGBA with
// premultiplied alpha, always of the same size. changed: the pixels that
// changed since the last call, all of them when zero or on the first one.
// Between frames.
renderer_set_thumbnails :: proc(r: ^Renderer, pixels: []u8, width, height: int, changed := rhi.Texture_Region{}) -> bool {
	d := r.device
	changed := changed
	if r.thumbnails == 0 {
		r.thumbnails = rhi.texture_create(d, {width = u32(width), height = u32(height), format = .RGBA8_Unorm, usage = {.Sampled}, name = "asset previews"})
		changed = {}
	}
	stride := width * 4
	first := int(changed.y) * stride + int(changed.x) * 4
	if r.thumbnails == 0 || first >= len(pixels) || !rhi.texture_upload(d, r.thumbnails, pixels[first:], u32(stride), 0, changed) {
		set_error(r, "asset previews: %s", rhi.device_error(d))
		return false
	}
	return true
}

// Changes settings between frames. Returns false (and keeps the old settings)
// when the request is invalid.
renderer_apply_settings :: proc(r: ^Renderer, settings: Settings) -> bool {
	if settings.render_scale < 0.25 || settings.render_scale > 2 || !(settings.render_megapixels >= 0) || settings.gi_strength < 0 || settings.probe_spacing <= 0 {return false}
	if settings.probe_grid < 4 || settings.probe_grid > PROBE_GRID_MAX || settings.probe_grid % 2 != 0 || settings.probe_cascades < 1 || settings.probe_cascades > VOLUME_CASCADES_MAX {return false}
	if !(settings.reflection_roughness >= 0 && settings.reflection_roughness <= 1) {return false}
	if !(settings.reflection_detail_roughness >= 0 && settings.reflection_detail_roughness <= 1) {return false}
	if settings.light_budget > LIGHT_CUT_MAX || settings.reflection_light_budget > LIGHT_CUT_MAX || settings.glass_layers < 1 || settings.glass_layers > GLASS_LAYERS_MAX {return false}
	old := r.settings
	if old != settings {
		destroy_view_targets(r)
		for &view in r.texture_views {view_state_destroy(r, &view)}
		scene_changed(&r.scene)
		// What the worlds not shown kept was gathered with the settings before.
		rhi.device_wait_idle(r.device)
		world_light_destroy(r)
	}
	r.settings = settings
	r.textures.residency.stale = true
	if old.reference_gi != settings.reference_gi {r.targets.gi_reference_valid = false}
	if old.colored_shadows != settings.colored_shadows || old.reflection_light_budget != settings.reflection_light_budget || old.reflection_detail_roughness != settings.reflection_detail_roughness {
		r.targets.reflect_valid, r.targets.gi_reference_valid, r.targets.taa_valid = false, false, false
		r.targets.glass_valid = false
		if old.colored_shadows != settings.colored_shadows {ddgi_release(r)}
	}
	if old.glass_layers != settings.glass_layers {
		rhi.device_wait_idle(r.device)
		destroy_glass_targets(r, &r.main.targets)
	}
	info := rhi.device_info(r.device)
	was_hardware := r.hardware_rt
	r.hardware_rt = info.features.ray_query && r.hardware_rt_verified && settings.trace_mode != .Software && hardware_pipelines_ready(r)
	// The poses refit only the structures the rays use: those of the others are as old as the switch.
	// The tables of the batches list the instances of a native TLAS only while rays are traced by hardware.
	if r.hardware_rt != was_hardware {
		for handle in r.scene.skinned {if skin := r.scene.meshes[handle].skin; skin != nil {skin.dirty = true}}
		r.scene.batch.built = false
		r.scene.tlas_off, r.scene.tlas_stale = r.hardware_rt, true
		r.scene.instances_dirty = true
	}
	// A mesh registered while rays were traced by hardware has no software trees yet.
	if !r.hardware_rt {
		for m, index in r.scene.meshes {
			if m.rays[0].bvh_node_count == 0 && m.vertex_count > 0 && !mesh_rays_complete(r, u32(index)) {
				set_error(r, "the software BVH of mesh %d", index)
				return false
			}
		}
		r.scene.geometry_dirty = true
		batches_trees_build(r)
	}
	// Software rays walk the tree of instances, which goes to the GPU only for them.
	if !r.hardware_rt && was_hardware {r.scene.instances_dirty = true}
	// A mesh registered while rays were traced by software has no native structure yet: the next publication builds it.
	if r.hardware_rt {r.scene.geometry_dirty = true}
	if r.hardware_rt {r.scene.tlas_dirty = true; r.scene.instance_capacity = 0}
	if old.render_scale != settings.render_scale || old.render_megapixels != settings.render_megapixels {
		destroy_targets(r, &r.main.targets)
		if !create_targets(r, &r.main, r.window_width, r.window_height, window_render_scale(r, f32(r.window_width) * f32(r.window_height)), true) {return false}
	}
	if old.probe_spacing != settings.probe_spacing || old.probe_grid != settings.probe_grid || old.probe_cascades != settings.probe_cascades || old.probe_rays != settings.probe_rays || old.probe_budget != settings.probe_budget {
		ddgi_release(r)
	}
	return true
}

hardware_ray_tracing_active :: proc(r: ^Renderer) -> bool {return r.hardware_rt}

// The color a view shows behind the scene whatever the environment of the
// scene says, as an editor does; the sky keeps lighting the scene.
renderer_set_backdrop :: proc(r: ^Renderer, color: Vec3, enabled: bool = true) {
	r.backdrop, r.has_backdrop = color, enabled
}

// The outline of the editor's levels. Rejects non-finite or out of range values.
renderer_set_highlight_style :: proc(r: ^Renderer, style: Highlight_Style) -> bool {
	if !highlight_style_valid(style) {return false}
	r.highlight = style
	return true
}

// The outline of the game's styles. Rejects non-finite or out of range values.
renderer_set_outline_style :: proc(r: ^Renderer, style: Highlight_Style) -> bool {
	if !highlight_style_valid(style) {return false}
	r.outlines = style
	return true
}

@(private)
highlight_style_valid :: proc(style: Highlight_Style) -> bool {
	if !(style.width >= 0 && style.width <= 16) {return false}
	for c in style.colors {for v in c {if !(v >= 0 && v <= 1) {return false}}}
	for v in style.fill {if !(v >= 0 && v <= 1) {return false}}
	for v in style.behind {if !(v >= 0 && v <= 1) {return false}}
	return true
}

// ---------------------------------------------------------------- targets

@(private)
destroy_targets :: proc(r: ^Renderer, t: ^Targets) {
	d := r.device
	textures := []rhi.Texture{
		t.depth, t.albedo, t.surface, t.layers, t.instance, t.post_hdr[0],t.post_hdr[1],t.post_ldr[0],t.post_ldr[1],t.normal, t.emission, t.motion, t.linear_depth, t.direct, t.reflect_raw, t.reflect_shared, t.reflect_history[0], t.reflect_history[1], t.hdr[0], t.hdr[1], t.display, t.taa[0], t.taa[1], t.taa_frames[0], t.taa_frames[1], t.hiz[0], t.hiz[1], t.ldr, t.generated,
		t.highlight, t.highlight_depth, t.highlight_filtered, t.gi_reference,
		t.reactive, t.nested_depth, t.aerial,
	}
	for tex in textures {if tex != 0 {rhi.texture_destroy(d, tex)}}
	destroy_direct_targets(r, t)
	for tex in t.ui_layers {if tex!=0 {rhi.texture_destroy(d,tex)}}
	for tex in t.ui_blur {if tex!=0 {rhi.texture_destroy(d,tex)}}
	destroy_gi_targets(r, t)
	destroy_glass_targets(r, t)
	out_w, out_h := t.output_width, t.output_height
	t^ = {}
	t.output_width, t.output_height = out_w, out_h
}

// A target a view makes the first time it needs it. clear: a history, which
// its first temporal read must not find uninitialized (NaNs would persist).
@(private)
target :: proc(r: ^Renderer, cmd: ^rhi.Command_List, texture: ^rhi.Texture, width, height: u32, format: rhi.Format, usage: rhi.Texture_Usage, name: string, clear := false) -> bool {
	if texture^ != 0 {return true}
	texture^ = rhi.texture_create(r.device, {width = width, height = height, format = format, usage = usage, name = name})
	if texture^ == 0 {set_error(r, "%s: %s", name, rhi.device_error(r.device)); return false}
	if clear {clear_textures(cmd, texture^)}
	return true
}

@(private)
HISTORY_USAGE :: rhi.Texture_Usage{.Sampled, .Storage, .Color_Target}

// The image a view shows before its own while its pipeline generates frames.
@(private)
ensure_generated_target :: proc(r: ^Renderer, t: ^Targets) -> bool {
	return target(r, nil, &t.generated, t.output_width, t.output_height, .RGBA8_Unorm, {.Color_Target, .Sampled, .Storage, .Transfer_Src}, "generated")
}

// The sixth target of the G-buffer: F0 as a color and the grazing reflectance
// (specular_pack in brdf.slang). It exists while a surface needs it.
@(private)
ensure_surface_target :: proc(r: ^Renderer, t: ^Targets) -> bool {
	return target(r, nil, &t.surface, t.width, t.height, .RGBA8_Srgb, {.Color_Target, .Sampled}, "surface reflectance")
}

// The seventh target of the G-buffer: the layers of the materials of each
// pixel (gbuffer_layers_pack). It exists while a surface needs it.
@(private)
ensure_layers_target :: proc(r: ^Renderer, t: ^Targets) -> bool {
	return target(r, nil, &t.layers, t.width, t.height, .RGBA32_Uint, {.Color_Target, .Sampled}, "material layers")
}

// A pipeline of the G-buffer with the target of the instance ids after its
// others, while the shaders ask for it.
@(private)
gbuffer_ids :: proc(desc: rhi.Graphics_Pipeline_Desc, ids: bool) -> rhi.Graphics_Pipeline_Desc {
	desc := desc
	if ids {desc.color_formats[desc.color_count] = .R32_Uint; desc.color_count += 1}
	return desc
}

@(private)
ensure_instance_target :: proc(r: ^Renderer, t: ^Targets) -> bool {
	return target(r, nil, &t.instance, t.width, t.height, .R32_Uint, {.Color_Target, .Sampled}, "instance ids")
}

@(private)
destroy_direct_targets :: proc(r: ^Renderer, t: ^Targets) {
	for tex in ([]rhi.Texture{t.direct_blockers, t.direct_samples, t.direct_sun, t.direct_depth, t.direct_points, t.direct_sun_points, t.direct_spread, t.direct_marks}) {if tex != 0 {rhi.texture_destroy(r.device, tex)}}
	t.direct_blockers, t.direct_samples, t.direct_sun, t.direct_depth, t.direct_points, t.direct_sun_points, t.direct_spread, t.direct_marks, t.direct_scale = 0, 0, 0, 0, 0, 0, 0, 0, 0
	destroy_shadow_maps(r, t)
}

// The targets of the direct light of a view from samples (direct_samples.slang),
// made again when the pixels across a point change.
@(private)
ensure_direct_targets :: proc(r: ^Renderer, cmd: ^rhi.Command_List, t: ^Targets, scale: u32) -> bool {
	if t.direct_samples != 0 && t.direct_scale == scale {return true}
	if t.direct_samples != 0 {
		rhi.device_wait_idle(r.device)
		destroy_direct_targets(r, t)
	}
	t.direct_scale = scale
	width, height := (t.width + scale - 1) / scale, (t.height + scale - 1) / scale
	ok := target(r, cmd, &t.direct_blockers, width, height, .R32_Uint, {.Sampled, .Storage}, "direct blockers")
	ok &&= target(r, cmd, &t.direct_samples, width, height, .RGBA16_Float, {.Sampled, .Storage}, "direct samples")
	ok &&= target(r, cmd, &t.direct_sun, width, height, .RGBA16_Float, {.Sampled, .Storage}, "direct sun")
	ok &&= target(r, cmd, &t.direct_depth, width, height, .RGBA16_Float, {.Sampled, .Storage}, "direct depth")
	ok &&= target(r, cmd, &t.direct_points, width, height, .RGBA16_Float, {.Sampled, .Storage}, "direct points")
	ok &&= target(r, cmd, &t.direct_sun_points, width, height, .R16_Float, {.Sampled, .Storage}, "direct sun points")
	ok &&= target(r, cmd, &t.direct_spread, width, height, .RG16_Float, {.Sampled, .Storage}, "direct spread")
	ok &&= target(r, cmd, &t.direct_marks, t.width, t.height, .R8_Unorm, HISTORY_USAGE, "direct marks", true)
	return ok
}

// The targets of the contact occlusion, which the next frame that needs them
// makes again.
@(private)
destroy_gi_targets :: proc(r: ^Renderer, t: ^Targets) {
	for tex in ([]rhi.Texture{t.contact_rays, t.contact_points[0], t.contact_points[1], t.contact}) {if tex != 0 {rhi.texture_destroy(r.device, tex)}}
	t.contact_rays, t.contact_points, t.contact, t.contact_scale = 0, {}, 0, 0
}

// Traced reflections: the rays of the frame, per pixel and per block of 2x2,
// and their filtered history.
@(private)
ensure_reflect_targets :: proc(r: ^Renderer, cmd: ^rhi.Command_List, t: ^Targets) -> bool {
	if t.reflect_raw != 0 {return true}
	ok := target(r, cmd, &t.reflect_raw, t.width, t.height, .RGBA16_Float, {.Sampled, .Storage}, "reflection rays")
	ok &&= target(r, cmd, &t.reflect_shared, t.half_width, t.half_height, .RGBA16_Float, HISTORY_USAGE, "shared reflection rays")
	for i in 0 ..< 2 {ok &&= target(r, cmd, &t.reflect_history[i], t.width, t.height, .RGBA16_Float, HISTORY_USAGE, "reflection history", true)}
	t.reflect_valid = false
	return ok
}

// The mask of the highlighted instances and its filtered coat, in window
// points: independent of scene downscaling and of TAA.
@(private)
ensure_highlight_targets :: proc(r: ^Renderer, t: ^Targets) -> bool {
	if t.highlight != 0 {return true}
	t.highlight_width = max(u32(f32(t.output_width) / ui_scale(r) + 0.5), 8)
	t.highlight_height = max(u32(f32(t.output_height) / ui_scale(r) + 0.5), 8)
	w, h := t.highlight_width, t.highlight_height
	ok := target(r, nil, &t.highlight, w, h, .RG32_Float, {.Color_Target, .Sampled}, "highlight mask")
	ok &&= target(r, nil, &t.highlight_depth, w, h, .D32_Float, {.Depth_Target}, "highlight depth")
	ok &&= target(r, nil, &t.highlight_filtered, w, h, .RGBA8_Unorm, {.Sampled, .Storage}, "highlight filtered")
	return ok
}

// The isolated layers of UI and the scratch of its backdrop blur, of the size
// of what it is drawn into: made with the window, and for a UI texture the
// first time its UI composes a layer.
@(private)
ui_layer_targets :: proc(r: ^Renderer, layers, blur: []rhi.Texture, width, height: u32) -> bool {
	if layers[0] != 0 {return true}
	d := r.device
	attachment := rhi.Texture_Usage{.Color_Target, .Sampled}
	for &tex in layers[:r.ui_layer_depth] {tex = rhi.texture_create(d, {width = width, height = height, format = .RGBA8_Unorm, usage = attachment, name = "ui isolated layer"})}
	for &tex in blur {tex = rhi.texture_create(d, {width = width, height = height, format = .RGBA8_Unorm, usage = attachment, name = "ui blur scratch"})}
	made := true
	for tex in layers[:r.ui_layer_depth] {made &&= tex != 0}
	for tex in blur {made &&= tex != 0}
	if made {return true}
	// None or all: a pass composes layers only while the first one is there.
	set_error(r, "UI layer targets: %s", rhi.device_error(d))
	for &tex in layers {if tex != 0 {rhi.texture_destroy(d, tex)}; tex = 0}
	for &tex in blur {if tex != 0 {rhi.texture_destroy(d, tex)}; tex = 0}
	return false
}

// Of the device pixels of the window, what its views are drawn at: the render
// scale, relative to window points, lowered so that the views, which show
// that many pixels in all, take at most render_megapixels; never below the
// least render scale.
@(private)
window_render_scale :: proc(r: ^Renderer, pixels: f32) -> f32 {
	density := pixel_density(r)
	scale := clamp(r.settings.render_scale, 0.25, 2) / density
	if r.settings.render_megapixels > 0 && pixels > 0 {
		scale = min(scale, max(math.sqrt(r.settings.render_megapixels * 1e6 / pixels), 0.25 / density))
	}
	return scale
}

@(private)
render_extent :: proc "contextless" (output: u32, scale: f32) -> u32 {return max(u32(f32(output) * scale + 0.5), 8)}

// The targets every frame of a view writes; those of an effect are made when
// the view first runs it. width and height: what the view shows, in device
// pixels, and scale what the scene is drawn at of them: window_render_scale
// for a view of the window, 1 for one drawn into a texture. main: the view
// the UI of the screen is composed on, which holds its isolated layers.
@(private)
create_targets :: proc(r: ^Renderer, v: ^View_State, width, height: u32, scale: f32, main := false) -> bool {
	t := &v.targets
	d := r.device
	t.output_width = width
	t.output_height = height
	t.width = render_extent(width, scale)
	t.height = render_extent(height, scale)
	t.half_width = max((t.width + 1) / 2, 1)
	t.half_height = max((t.height + 1) / 2, 1)
	full :: proc(d: ^rhi.Device, t: ^Targets, format: rhi.Format, usage: rhi.Texture_Usage, name: string) -> rhi.Texture {
		return rhi.texture_create(d, {width = t.width, height = t.height, format = format, usage = usage, name = name})
	}
	attachment := rhi.Texture_Usage{.Color_Target, .Sampled}
	t.depth = full(d, t, .D32_Float, {.Depth_Target, .Sampled}, "depth") // sampled: a custom pass of a pipeline reads it
	// sRGB keeps dark base colors free of banding in 8 bits; its alpha (metallic) stays linear.
	t.albedo = full(d, t, .RGBA8_Srgb, attachment, "gbuffer albedo")
	t.normal = full(d, t, .RGBA16_Float, attachment, "gbuffer normal")
	t.emission = full(d, t, .RGBA16_Float, attachment, "gbuffer emission")
	t.motion = full(d, t, .RGBA16_Float, attachment, "gbuffer motion")
	t.linear_depth = full(d, t, .R32_Float, attachment, "gbuffer depth")
	t.direct = full(d, t, .RGBA16_Float, {.Sampled, .Storage}, "direct light")
	for i in 0 ..< 2 {t.hdr[i] = full(d, t, .RGBA16_Float, HISTORY_USAGE, "hdr")}
	t.display = full(d, t, .RGBA16_Float, HISTORY_USAGE, "display")
	for i in 0 ..< 2 {t.taa[i] = rhi.texture_create(d, {width = t.output_width, height = t.output_height, format = .RGBA16_Float, usage = HISTORY_USAGE, name = "taa history"})}
	for i in 0 ..< 2 {t.taa_frames[i] = rhi.texture_create(d, {width = t.output_width, height = t.output_height, format = .R16_Float, usage = HISTORY_USAGE, name = "taa frames"})}
	t.taa_valid = false
	t.hiz_width = max(t.width / 2, 1)
	t.hiz_height = max(t.height / 2, 1)
	levels: u32 = 1
	for (max(t.hiz_width, t.hiz_height) >> levels) > 0 && levels < rhi.MAX_TEXTURE_MIPS {levels += 1}
	t.hiz_levels = levels
	for i in 0 ..< 2 {t.hiz[i] = rhi.texture_create(d, {width = t.hiz_width, height = t.hiz_height, mip_levels = levels, format = .R32_Float, usage = {.Sampled, .Storage}, name = "depth pyramid"})}
	t.hiz_valid = false
	t.ldr = rhi.texture_create(d, {width = t.output_width, height = t.output_height, format = .RGBA8_Unorm, usage = {.Color_Target, .Sampled, .Transfer_Src}, name = "ldr"})
	if main && !ui_layer_targets(r, t.ui_layers[:], t.ui_blur[:], t.output_width, t.output_height) {return false}
	t.reactive = full(d, t, .R8_Unorm, attachment, "blended coverage")
	t.needs_clear = true
	v.has_previous = false
	all := []rhi.Texture{t.depth, t.albedo, t.normal, t.emission, t.motion, t.linear_depth, t.direct, t.hdr[0], t.hdr[1], t.display, t.taa[0], t.taa[1], t.taa_frames[0], t.taa_frames[1], t.hiz[0], t.hiz[1], t.ldr, t.reactive}
	for tex in all {if tex == 0 {set_error(r, "render targets: %s", rhi.device_error(d)); return false}}
	return true
}

@(private)
ui_scale :: proc "contextless" (r: ^Renderer) -> f32 {return r.ui_scale if r.ui_scale > 0 else 1}
@(private)
pixel_density :: proc "contextless" (r: ^Renderer) -> f32 {return r.pixel_density if r.pixel_density > 0 else 1}

// The drawable is in device pixels; the two scales refer to UI points and native window coordinates.
renderer_resize :: proc(r: ^Renderer, requested_width, requested_height: u32, ui_scale: f32 = 1, pixel_density: f32 = 1) {
	width, height := max(requested_width, 1), max(requested_height, 1)
	scale := clamp(ui_scale, 0.5, 4)
	density := clamp(pixel_density, 0.5, 4) if pixel_density>0 else f32(1)
	if width == r.window_width && height == r.window_height && scale == r.ui_scale && density == r.pixel_density {return}
	r.window_width = width
	r.window_height = height
	r.ui_scale = scale
	r.pixel_density = density
	rhi.device_wait_idle(r.device)
	destroy_view_targets(r)
	destroy_targets(r, &r.main.targets)
	create_targets(r, &r.main, width, height, window_render_scale(r, f32(width) * f32(height)), true)
	rhi.swapchain_resize(r.device, width, height)
}

// Clears history-like textures with an empty render pass so the first
// temporal reads never see uninitialized memory (NaNs would persist).
@(private)
clear_textures :: proc(cmd: ^rhi.Command_List, textures: ..rhi.Texture) {
	for tex in textures {
		if tex == 0 {continue}
		pass := rhi.Render_Pass_Desc{color_count = 1, name = "clear"}
		pass.colors[0] = {texture = tex, load = .Clear, store = .Store}
		rhi.cmd_begin_render_pass(cmd, &pass)
		rhi.cmd_end_render_pass(cmd)
	}
}

// ---------------------------------------------------------------- camera

@(private)
// reach: how far an orthographic camera without a far plane sees (camera_reach).
camera_matrices :: proc(c: Camera, aspect: f32, reach: f32 = 0) -> (view, proj: Mat4, forward: Vec3) {
	// Degenerate cameras (target on the eye, forward parallel to up) would
	// produce NaN matrices that poison every temporal history.
	forward = linalg.normalize(c.forward) if linalg.length(c.forward) > 1e-6 else Vec3{0, 0, -1}
	up_hint := c.up if linalg.length(c.up) > 1e-6 else Vec3{0, 1, 0}
	right := linalg.cross(forward, up_hint)
	if linalg.length(right) < 1e-5 {right = linalg.cross(forward, Vec3{0, 0, 1} if abs(forward.y) > 0.9 else Vec3{0, 1, 0})}
	right = linalg.normalize(right)
	up := linalg.cross(right, forward)
	view = Mat4(1)
	for i in 0 ..< 3 {
		view[0, i] = right[i]
		view[1, i] = up[i]
		view[2, i] = -forward[i]
	}
	view[0, 3] = -linalg.dot(right, c.position)
	view[1, 3] = -linalg.dot(up, c.position)
	view[2, 3] = linalg.dot(forward, c.position)
	near := max(c.near, 0.001)
	far := max(c.far if c.far > 0 else reach, near + 1)
	proj = Mat4{}
	// A matrix of its own serves while the rays of its pixels can be told from it.
	custom := c.projection == .Custom && c.custom[3, 0] == 0 && c.custom[3, 1] == 0 && abs(c.custom[0, 0] * c.custom[1, 1] - c.custom[0, 1] * c.custom[1, 0]) > 1e-12
	switch {
	case custom:
		proj = c.custom
	case c.projection == .Orthographic && c.height > 0:
		// Reversed-Z: near maps to depth 1, far to 0.
		proj[0, 0] = 2 / (c.height * aspect)
		proj[1, 1] = 2 / c.height
		proj[0, 3] = c.shift.x
		proj[1, 3] = c.shift.y
		proj[2, 2] = 1 / (far - near)
		proj[2, 3] = far / (far - near)
		proj[3, 3] = 1
	case:
		// Reversed-Z perspective: near maps to depth 1, far to 0, and without a far plane infinity does.
		f := 1 / math.tan(c.fov_y * math.PI / 360)
		proj[0, 0] = f / aspect
		proj[1, 1] = f
		if c.shift != {} {
			proj[0, 2] = -c.shift.x
			proj[1, 2] = -c.shift.y
		}
		proj[2, 2] = near / (far - near) if c.far > 0 else 0
		proj[2, 3] = far * near / (far - near) if c.far > 0 else near
		proj[3, 2] = -1
	}
	return
}

// How far from the eye of a camera what it shows goes: its far plane, or
// without one the farthest corner of the box of the scene (low above high:
// none), and at least a metre past its near plane. What the shaders take as
// its far plane (camera_forward.w), and an orthographic one sees to.
@(private)
camera_reach :: proc "contextless" (c: Camera, low, high: Vec3) -> f32 {
	near := max(c.near, 0.001)
	if c.far > 0 {return max(c.far, near + 1)}
	reach: f32
	if low.x <= high.x && low.y <= high.y && low.z <= high.z {
		for corner in 0 ..< 8 {
			p := Vec3{high.x if corner & 1 != 0 else low.x, high.y if corner & 2 != 0 else low.y, high.z if corner & 4 != 0 else low.z}
			reach = max(reach, linalg.length(p - c.position))
		}
	}
	return max(reach, near + 1)
}

// What the constants of a view say of how its pixels look at the world: the
// ray of each pixel, the eye, the plane that gives a linear depth, the size of
// a pixel and what the view draws. view: world to view space; proj: with the
// jitter of the frame, and unjittered without it.
@(private)
frame_view_constants :: proc(f: ^Gpu_Frame, c: Camera, view, proj, unjittered: Mat4, forward: Vec3, height: f32) {
	right := Vec3{view[0, 0], view[0, 1], view[0, 2]}
	up := Vec3{view[1, 0], view[1, 1], view[1, 2]}
	// With clip w = a z + b, the view-space xy of the point at linear depth d
	// that projects to ndc solve M xy = (b ndc - c3) + d (c2 - a ndc): affine
	// in ndc, for a perspective, a parallel or an off-center projection alike.
	det := proj[0, 0] * proj[1, 1] - proj[0, 1] * proj[1, 0]
	g0 := (right * proj[1, 1] - up * proj[1, 0]) / det
	g1 := (up * proj[0, 0] - right * proj[0, 1]) / det
	a, b := proj[3, 2], proj[3, 3]
	c2 := g0 * proj[0, 2] + g1 * proj[1, 2]
	c3 := g0 * proj[0, 3] + g1 * proj[1, 3]
	v4 :: proc "contextless" (v: Vec3, w: f32) -> Vec4 {return {v.x, v.y, v.z, w}}
	f.eye_origin = v4(c.position - c3 - g0 * b + g1 * b, 0)
	f.eye_du = v4(g0 * (2 * b), 0)
	f.eye_dv = v4(g1 * (-2 * b), 0)
	f.ray_origin = v4(forward + c2 + g0 * a - g1 * a, 0)
	f.ray_du = v4(g0 * (-2 * a), 0)
	f.ray_dv = v4(g1 * (2 * a), 0)
	f.eye = v4(-forward, 0) if a == 0 else v4(c.position, 1)
	f.depth_plane = v4(forward, -linalg.dot(forward, c.position))
	pixel := 2 / (abs(unjittered[1, 1]) * height)
	f.footprint = {pixel * b, -pixel * a}
	f.detail_eye = {c.position.x, c.position.y, c.position.z, max(c.near, 0.001)}
	f.detail_footprint = {f.footprint.x, f.footprint.y, 0, 0}
	f.clip_plane = c.clip_plane
	f.layers = c.layers & LAYERS_ALL if c.layers & LAYERS_ALL != 0 else LAYERS_ALL
	if c.own != 0 {
		f.layers |= (c.own_hidden & LAYERS_ALL) << 16
		f.own = u32(c.own) | u32(clamp(c.fade, 0, 1) * 65535 + 0.5) << 16
	} else {f.own = 0}
}

// A transform without its translation: a view matrix, or what carries one,
// for points taken from the eye.
@(private)
matrix_from_eye :: proc "contextless" (m: Mat4) -> Mat4 {
	m := m
	m[0, 3], m[1, 3], m[2, 3] = 0, 0, 0
	return m
}

// The planes of the frustum of a view-projection matrix that takes a point
// from the eye, as planes of the places relative to the origin.
@(private)
frustum_from_eye :: proc(view_projection: Mat4, eye: Vec3) -> [6]Vec4 {
	planes := frustum_planes(view_projection)
	for &plane in planes {plane = origin_plane(plane, -eye)}
	return planes
}

// A plane (normal, distance) of a space, in the one `to` carries it to: inverse is that of `to`.
@(private)
plane_carried :: proc "contextless" (plane: Vec4, inverse: Mat4) -> Vec4 {
	return linalg.transpose(inverse) * plane
}

@(private)
point_carried :: proc "contextless" (m: Mat4, p: Vec3) -> Vec3 {
	v := m * Vec4{p.x, p.y, p.z, 1}
	return v.xyz
}

@(private)
vector_carried :: proc "contextless" (m: Mat4, p: Vec3) -> Vec3 {
	v := m * Vec4{p.x, p.y, p.z, 0}
	return v.xyz
}

// Low-discrepancy sub-pixel offsets for TAA (Halton bases 2 and 3).
@(private)
halton :: proc "contextless" (index, base: u32) -> f32 {
	f: f32 = 1
	r: f32 = 0
	i := index
	for i > 0 {
		f /= f32(base)
		r += f * f32(i % base)
		i /= base
	}
	return r
}

@(private)
TAA_JITTER_PHASES :: u32(16)

// The offset of a frame in a sequence of phases, in pixels: Halton (2, 3).
taa_jitter :: proc "contextless" (frame: u64, phases: u32) -> Vec2 {
	i := u32(frame % u64(max(phases, 1))) + 1
	return {halton(i, 2) - 0.5, halton(i, 3) - 0.5}
}

// The phases of the jitter of a temporal upscaler: 8 at the output size,
// times the square of how much smaller the view is drawn.
upscale_jitter_phases :: proc "contextless" (width, output_width: u32) -> u32 {
	if width == 0 {return 1}
	ratio := f32(output_width) / f32(width)
	return max(u32(8 * ratio * ratio), 1)
}

@(private)
bounds_in_frustum :: proc "contextless" (bmin, bmax: Vec3, planes: [6]Vec4) -> bool {
	for p in planes {
		corner := Vec3{bmax.x if p.x >= 0 else bmin.x, bmax.y if p.y >= 0 else bmin.y, bmax.z if p.z >= 0 else bmin.z}
		if p.x * corner.x + p.y * corner.y + p.z * corner.z + p.w < 0 {return false}
	}
	return true
}

// Whether some instance of the scene has a material with layers: a ray may
// hit it wherever it is.
@(private)
scene_layered :: proc(s: ^Scene_State) -> bool {
	for entry in s.reflective {if entry.layered {return true}}
	for entry in s.batch.reflective {if entry.layered {return true}}
	return false
}

@(private)
// Whether some instance in the frustum needs the reflectance target, and
// whether one needs the layers target too.
reflectance_in_frustum :: proc(r: ^Renderer, planes: [6]Vec4) -> (reflectance, layered: bool) {
	for entry in r.scene.reflective {
		if reflectance && (layered || !entry.layered) {continue}
		inst := &r.scene.instances[entry.instance]
		if bounds_in_frustum(inst.bounds_min.xyz, inst.bounds_max.xyz, planes) {
			reflectance = true
			layered ||= entry.layered
		}
	}
	for entry in r.scene.batch.reflective {
		if reflectance && (layered || !entry.layered) {continue}
		box := &r.scene.batch.boxes[entry.instance]
		if bounds_in_frustum(box.bounds_min, box.bounds_max, planes) {
			reflectance = true
			layered ||= entry.layered
		}
	}
	return
}

@(private)
frustum_planes :: proc(m: Mat4) -> [6]Vec4 {
	row :: proc(m: Mat4, i: int) -> Vec4 {return {m[i, 0], m[i, 1], m[i, 2], m[i, 3]}}
	r0, r1, r2, r3 := row(m, 0), row(m, 1), row(m, 2), row(m, 3)
	planes := [6]Vec4{r3 + r0, r3 - r0, r3 + r1, r3 - r1, r2, r3 - r2}
	for &p in planes {
		length := math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z)
		if length > 1e-8 {p /= length}
	}
	return planes
}
