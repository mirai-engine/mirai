package mirai_render

import "core:testing"
import "mirai:rhi"
import "mirai:rhi/shared_device"

// The shared device of the GPU tests and a renderer on it.
Fixture :: struct {
	device:   ^rhi.Device,
	renderer: ^Renderer, // on the heap: a Renderer is too big for the stack
}

// False with the test told why: there is no device (shared_device.take_or_skip)
// or the renderer does not start. desc gives what a test sets besides the size
// and the settings.
fixture_init :: proc(t: ^testing.T, f: ^Fixture, width, height: u32, settings: Maybe(Settings) = nil, hardware_rt := true, desc: Renderer_Desc = {}, loc := #caller_location) -> bool {
	device := shared_device.take_or_skip(t, hardware_rt, loc)
	if device == nil {return false}
	desc := desc
	desc.device, desc.width, desc.height, desc.settings = device, width, height, settings
	r := new(Renderer)
	if !testing.expect(t, renderer_init(r, desc), r.error, loc = loc) {
		renderer_destroy(r)
		free(r)
		return false
	}
	f.device, f.renderer = device, r
	return true
}

fixture_destroy :: proc(f: ^Fixture) {
	if f.renderer == nil {return}
	renderer_destroy(f.renderer)
	free(f.renderer)
	f.renderer = nil
}
