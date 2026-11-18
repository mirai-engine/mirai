package mirai_render

import "core:math"
import "core:math/linalg"

// A blackout: a change of most of the light the probe volume holds at once
// (the lights of a house turned off, the sun put out). A light whose range
// reaches no probe changes none of it. It is a change everywhere, and the
// probe volume is warmed as for a world shown anew, with GI_BLACKOUT_UPDATES
// over GI_BLACKOUT_FRAMES, so that the light of the scene after it shows from
// the frames it happens in.

// The share of the light of the scene whose change is a blackout.
GI_BLACKOUT_SHARE :: f32(0.5)
// The warm updates of a blackout and the frames they are spread over.
GI_BLACKOUT_UPDATES :: 16
GI_BLACKOUT_FRAMES :: 4
// The area around the eye the sun and the sky are weighed over against the local lights, square metres.
GI_BLACKOUT_AREA :: f32(200)

// The light a local light gives, in lumens of render units: the same measure for every kind.
@(private)
light_flux :: proc "contextless" (l: Gpu_Light) -> f32 {
	solid: f32 = 4 * math.PI
	switch {
	case l.direction_cone.w == GPU_LIGHT_RECT: solid = math.PI
	case l.direction_cone.w > -1: solid = 2 * math.PI * (1 - l.direction_cone.w)
	}
	return luminance_of(l.color_intensity.xyz) * l.color_intensity.w * math.PI * solid
}

// Whether the range of a light reaches the cascades of the last frame; every
// light does while there are none.
@(private)
light_in_volume :: proc "contextless" (g: ^Ddgi_State, l: Gpu_Light) -> bool {
	if !g.valid {return true}
	corner := g.corners[g.cascades - 1]
	low := corner.xyz
	high := low + Vec3{f32(g.counts[0]), f32(g.counts[1]), f32(g.counts[2])} * corner.w
	away := linalg.clamp(l.position_range.xyz, low, high) - l.position_range.xyz
	return linalg.dot(away, away) <= l.position_range.w * l.position_range.w
}

// The light of the sun and the sky over GI_BLACKOUT_AREA, at `scale`.
@(private)
sky_flux :: proc "contextless" (sun: Sun_Desc, environment: Environment, scale: f32) -> f32 {
	flux := luminance_of(environment.sky) * math.PI * GI_BLACKOUT_AREA
	if sun.enabled {flux += sun.illuminance * luminance_of(sun.color) * GI_BLACKOUT_AREA}
	return flux * scale
}
