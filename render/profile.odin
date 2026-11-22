package mirai_render

import "mirai:std/base"
import "mirai:std/jobs"

// A zone of the profile of the application (Renderer_Desc.profile) around a
// stage of the CPU work of a frame, on the ring of the thread that owns the
// jobs, which draws: a branch while nothing records.
@(private, deferred_out = base.profile_end)
render_zone :: #force_inline proc "contextless" (r: ^Renderer, name: string) -> base.Profile_Scope {
	return base.profile_begin(r.profile, jobs.OWNER, name)
}

// The zone of each stage of a view, which records its passes.
@(private)
STAGE_ZONES :: [Render_Stage]string {
	.Custom       = "custom pass",
	.Geometry     = "geometry",
	.Nested       = "nested views",
	.Surface      = "surface",
	.Direct       = "direct",
	.World        = "probe volume",
	.Indirect     = "indirect",
	.Composite    = "composite",
	.Lit          = "lit",
	.Transparency = "transparency",
	.Resolve      = "resolve",
	.Output       = "output",
}

// The same zone ended by the caller, for a stage that is not a whole block.
@(private)
render_zone_begin :: #force_inline proc "contextless" (r: ^Renderer, name: string) -> base.Profile_Scope {
	return base.profile_begin(r.profile, jobs.OWNER, name)
}
