package mirai_render

import "core:testing"

// A texture keeps a level for each halving of its size, but one read texel by
// texel, which no sampler filters: its level 0 alone.
@(test)
a_texture_read_texel_by_texel_keeps_its_level_0_alone :: proc(t: ^testing.T) {
	pixels: [16 * 8 * 4]u8
	cases := [?]struct {texels: bool, levels: int}{{false, 5}, {true, 1}}
	for c in cases {
		data, built := texture_build({pixels = pixels[:], width = 16, height = 8, texels = c.texels, name = "levels"}, 1 << 16)
		defer texture_data_destroy(&data)
		testing.expect(t, built)
		testing.expectf(t, len(data.levels) == c.levels && len(data.levels[0]) == len(pixels), "%v: %d levels", c, len(data.levels))
	}
}
