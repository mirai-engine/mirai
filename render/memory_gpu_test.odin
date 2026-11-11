package mirai_render

import "base:runtime"
import "core:strings"
import "core:testing"
import "mirai:rhi"

// What the renderer asks its allocator for beside a resource of the device,
// with the memory ending at each request in turn: the call is refused, says
// so and leaves what it had; with memory enough it goes through.
@(test)
gpu_renderer_tables_without_memory_are_refused_and_keep_what_they_had :: proc(t: ^testing.T) {
	limit := Memory_Limit{owner = context.allocator, remaining = max(int)}
	limited := runtime.Allocator{memory_limit_proc, &limit}
	f: Fixture
	if !skin_fixture(t, &f, false, limited) {return}
	defer fixture_destroy(&f)
	r, device := f.renderer, f.device
	Call :: enum {Textures, Readback}
	for call in Call {
		state := &r.textures
		held := len(state.textures)
		// The first handle past the room the table has: taking it grows every list of the textures.
		index := cap(state.textures)
		done, refused := false, false
		for served in 0 ..< 16 {
			r.error = ""
			limit.remaining = served
			switch call {
			case .Textures:
				done = textures_room(r, index, "probe")
			case .Readback:
				done = extension_readback(r, 1, {name = "probe", size = 64}) != nil
			}
			limit.remaining = max(int)
			if done {break}
			refused = true
			testing.expectf(t, strings.contains(r.error, "out of memory"), "%v with %d requests served says: %s", call, served, r.error)
			testing.expectf(t, held == len(state.textures) && held == len(state.keys) && held == len(state.sizes) && held == len(state.stored) && held == len(state.partial) && held == len(state.residency.streams),
				"%v with %d requests served leaves the lists of the textures as long as they were", call, served)
		}
		testing.expectf(t, done && refused, "%v: refused without memory, and with it it goes through", call)
		if call == .Textures {
			testing.expect(t, len(state.textures) == index + 1 && len(state.residency.streams) == index + 1, "every list holds the handle that was made room for")
		}
	}
	testing.expectf(t, rhi.device_validation_errors(device) == 0, "validation: %s", rhi.device_validation_message(device))
}
