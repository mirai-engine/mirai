package mirai_render

import "core:testing"

@(test)
a_world_that_took_another_scene_keeps_no_light :: proc(t: ^testing.T) {
	r := new(Renderer)
	defer free(r)
	r.kept_count = 2
	r.kept[0] = {used = true, world = 7}
	r.kept[1] = {used = true, world = 9}
	world_light_forget(r, 7)
	testing.expect(t, !r.kept[0].used, "the light of the scene before stays kept")
	testing.expect(t, r.kept[1].used, "the light of another world was forgotten")
}
