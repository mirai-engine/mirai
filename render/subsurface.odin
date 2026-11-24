package mirai_render

import "mirai:rhi"

// The subsurface of the opaque scene (subsurface.comp): while an instance
// with a subsurface is in sight, the direct light and the composite leave the
// light a white Lambert reflector takes at each of its pixels in
// t.subsurface[0], spread across the view into t.subsurface[1] and down it
// into the image. While none is, no pass of it runs and its targets are not
// made.
@(private)
subsurface_targets :: proc(r: ^Renderer, t: ^Targets) -> bool {
	ok := target(r, nil, &t.subsurface[0], t.width, t.height, .RGBA16_Float, {.Sampled, .Storage}, "subsurface light", shared = true)
	ok &&= target(r, nil, &t.subsurface[1], t.width, t.height, .RGBA16_Float, {.Sampled, .Storage}, "subsurface spread", shared = true)
	return ok
}

@(private)
pass_subsurface :: proc(p: ^Pass) {
	r, cmd, t := p.r, p.cmd, p.t
	Params :: struct {vertical, pad0, pad1, pad2: u32}
	rhi.cmd_timestamp(cmd, "subsurface")
	rhi.cmd_bind_pipeline(cmd, r.pipelines[.Subsurface])
	for vertical in u32(0) ..= 1 {
		params := Params{vertical = vertical}
		set_params(cmd, &params)
		rhi.cmd_bind_texture(cmd, SLOT_PASS0, t.albedo)
		rhi.cmd_bind_texture(cmd, SLOT_PASS1, t.normal)
		rhi.cmd_bind_texture(cmd, SLOT_PASS2, t.linear_depth)
		rhi.cmd_bind_texture(cmd, SLOT_PASS3, t.subsurface[vertical])
		rhi.cmd_bind_texture(cmd, SLOT_PASS4, t.subsurface[1] if vertical == 0 else t.display)
		rhi.cmd_dispatch(cmd, groups(t.width, 8), groups(t.height, 8))
	}
}
