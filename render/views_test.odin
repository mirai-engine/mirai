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

// The targets of a view drawn into a texture go with its texture, and when
// no frame drew it for a while unless this one does.
@(test)
a_texture_view_no_frame_draws_gives_up_its_targets :: proc(t: ^testing.T) {
	r := new(Renderer)
	defer free(r)
	resize(&r.textures.textures, 4)
	defer delete(r.textures.textures)
	for &texture in r.textures.textures[:3] {texture = 1}
	r.textures.count = 4
	r.frame = 10 * TEXTURE_VIEW_IDLE_FRAMES
	Case :: struct {
		name:       string,
		last_frame: u64,
		kept:       bool,
	}
	cases := [4]Case {
		{"drawn in the frame before", r.frame - 1, true},
		{"idle, and drawn by this frame", 0, true},
		{"idle", 0, false},
		{"without its texture", r.frame - 1, false},
	}
	for c, i in cases {
		r.texture_views[i].texture, r.texture_views[i].last_frame = Texture_Handle(i + 1), c.last_frame
	}
	texture_views_evict(r, {{texture = 2}, {texture = 3, disabled = true}})
	for c, i in cases {testing.expectf(t, (r.texture_views[i].texture != 0) == c.kept, "a view %s", c.name)}
}

// What the targets of the views drawn into textures hold comes out of the
// pool of the textures, which then loads a texture without its largest
// levels; a pool they fill is a full one, not one without a limit.
@(test)
the_targets_of_texture_views_take_room_from_the_texture_pool :: proc(t: ^testing.T) {
	r := new(Renderer)
	defer free(r)
	_, limited := texture_pool_room(r)
	testing.expect(t, !limited, "a pool of 0 megabytes is no limit")
	r.settings.texture_pool_megabytes = 1
	texels := make([]u8, 256 * 256 * 4)
	defer delete(texels)
	data := Texture_Data{format = .RGBA8_Unorm, width = 256, height = 256}
	defer delete(data.levels)
	for side := 256; side >= 1; side /= 2 {append(&data.levels, texels[:side * side * 4])}
	whole, _ := texture_pool_first(r, data)
	r.texture_view_bytes = 900 << 10
	room, _ := texture_pool_room(r)
	reduced, _ := texture_pool_first(r, data)
	testing.expect(t, whole == 0 && reduced > 0 && room == (1 << 20) - (900 << 10), "a texture leaves levels out for the targets of the views")
	r.texture_view_bytes = 64 << 20
	room, limited = texture_pool_room(r)
	testing.expect(t, limited && room == 0, "targets past the pool leave it full")
}
