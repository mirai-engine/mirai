package mirai_render

import "core:os"
import "core:testing"
import "mirai:rhi"
import "mirai:rhi/shared_device"

// The shared device of the GPU tests and a renderer on it.
Fixture :: struct {
	device:   ^rhi.Device,
	renderer: ^Renderer, // on the heap: a Renderer is too big for the stack
}

// The generation with the Surface programs of testdata/ (Grid and Pieces),
// which `mirai test` makes before the tests run: the engine has no
// Surface program of its own.
TEST_GENERATION :: #directory + "/../.mirai/tmp/render-test-shaders"

// False with the test told why: there is no device (shared_device.take_or_skip)
// or the renderer does not start. desc gives what a test sets besides the size
// and the settings. programs: the renderer starts with TEST_GENERATION.
fixture_init :: proc(t: ^testing.T, f: ^Fixture, width, height: u32, settings: Maybe(Settings) = nil, hardware_rt := true, desc: Renderer_Desc = {}, programs := false, loc := #caller_location) -> bool {
	device := shared_device.take_or_skip(t, hardware_rt, loc)
	if device == nil {return false}
	desc := desc
	desc.device, desc.width, desc.height, desc.settings = device, width, height, settings
	assets: Shader_Assets
	if programs {
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
