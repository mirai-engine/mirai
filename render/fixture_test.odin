package mirai_render

import "core:fmt"
import "core:os"
import "core:testing"
import "mirai:rhi"
import "mirai:rhi/shared_device"

// The shared device of the GPU tests and a renderer on it.
Fixture :: struct {
	device:    ^rhi.Device,
	renderer:  ^Renderer, // on the heap: a Renderer is too big for the stack
	reference: Reference_Set, // what fixture_frame draws with the references (reference_test.odin)
	gi:        Reference_Gi,
}

// The generation with the Surface programs of testdata/ (Grid and Pieces) and
// the stages of the references, which `mirai test` makes before the tests run:
// the engine has neither.
TEST_GENERATION :: #directory + "/../.mirai/tmp/render-test-shaders"

// False with the test told why: there is no device (shared_device.take_or_skip)
// or the renderer does not start. desc gives what a test sets besides the size
// and the settings. programs: the renderer starts with TEST_GENERATION.
fixture_init :: proc(t: ^testing.T, f: ^Fixture, width, height: u32, settings: Maybe(Settings) = nil, hardware_rt := true, desc: Renderer_Desc = {}, programs := false, reference := Reference_Set{}, loc := #caller_location) -> bool {
	if s, given := settings.?; given && s.trace_mode == .Software && !SOFTWARE_TRACER {
		fmt.println("skipped: rays are traced by software only on Vulkan")
		return false
	}
	device := shared_device.take_or_skip(t, hardware_rt, loc)
	if device == nil {return false}
	desc := desc
	desc.device, desc.width, desc.height, desc.settings = device, width, height, settings
	assets: Shader_Assets
	f.reference = reference
	if programs || reference != {} {
		problem: string
		assets, problem = shader_assets_load(TEST_GENERATION)
		if !testing.expectf(t, problem == "", "%s in %s: `mirai test render` generates it", problem, TEST_GENERATION, loc = loc) {return false}
		desc.shaders = &assets
	}
	r := new(Renderer)
	if !testing.expect(t, renderer_init(r, desc), r.error, loc = loc) {
		renderer_destroy(r)
		free(r)
		shader_assets_destroy(&assets)
		return false
	}
	f.device, f.renderer = device, r
	return true
}

// A frame of the renderer of f, with the references f asks for.
fixture_frame :: proc(f: ^Fixture, frame: Frame_Desc) -> bool {
	if f.reference == {} {return renderer_frame(f.renderer, frame)}
	return reference_frame(f.renderer, frame, f.reference, &f.gi)
}

// The catalog of TEST_GENERATION for a renderer without a device, which the
// test destroys with it (program_catalog_destroy).
fixture_catalog :: proc(t: ^testing.T, r: ^Renderer, loc := #caller_location) -> bool {
	bytes, read_error := os.read_entire_file(TEST_GENERATION + "/catalog.json", context.temp_allocator)
	if !testing.expectf(t, read_error == nil, "%s has no catalog: `mirai test render` generates it", TEST_GENERATION, loc = loc) {return false}
	catalog, valid := program_catalog_parse(bytes, r.allocator)
	if !testing.expect(t, valid, "the catalog of the programs of testdata/ is read", loc = loc) {return false}
	r.programs = catalog
	r.programs.loaded = true
	return true
}

fixture_destroy :: proc(f: ^Fixture) {
	if f.renderer == nil {return}
	renderer_destroy(f.renderer)
	free(f.renderer)
	f.renderer = nil
}

// The lights, the sun and the sky in place of those the scene has, through
// what a frame does with them: the lights that give light take the first
// indices, those past them go, and the lights settle.
scene_lights_given :: proc(r: ^Renderer, lights: []Light_Desc, sun: Sun_Desc, environment: Environment) -> bool {
	count := 0
	for l in lights {
		if !light_gives(l) {continue}
		if !scene_light_update(r, u32(count), l) {return false}
		count += 1
	}
	for i := len(r.scene.lights) - 1; i >= count; i -= 1 {scene_light_remove(r, u32(i))}
	scene_set_environment(r, sun, environment)
	return scene_lights_settle(r)
}

// The instances, the lights, the sun and the sky in place of those the scene
// has, as the sync of a world gives them and a frame settles them.
scene_given :: proc(r: ^Renderer, instances: []Instance_Desc, lights: []Light_Desc, sun: Sun_Desc, environment: Environment) -> bool {
	if !scene_update(r, 0, instances, true) {return false}
	tlas_settle(&r.scene)
	return scene_lights_given(r, lights, sun, environment)
}
