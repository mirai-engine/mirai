package mirai_render

import "core:testing"

// A reset of the history leaves none in any view: the main one, those of a
// frame with several and those drawn into a texture.
@(test)
a_reset_of_the_history_reaches_every_view :: proc(t: ^testing.T) {
	r := new(Renderer)
	defer free(r)
	for view in views_all(r) {
		v := &view.targets
		v.gi_reference_valid, v.taa_valid, v.glass_valid = true, true, true
		v.hiz_valid, view.has_previous = true, true
	}
	renderer_reset_history(r, reset_camera = true)
	for view, i in views_all(r) {
		v := view.targets
		kept := v.gi_reference_valid || v.taa_valid || v.glass_valid || v.hiz_valid || view.has_previous
		testing.expectf(t, !kept, "view %d keeps a history after the reset", i)
	}
}
