package mirai_render

import "core:math"
import "core:testing"

// A bake is drawn again for another sky or a stage made again; the sun moves
// it only under a program that reads it, and then once it came on, went off or
// turned by more than SKY_SUN_TURN since the bake, not at each small step.
@(test)
a_sky_bake_is_drawn_again_only_when_what_its_program_reads_changes :: proc(t:^testing.T) {
	sky := Sky_Program{program = 3}
	other := sky
	other.params[0] = {1, 0, 0, 0}
	up := Vec4{0, 1, 0, 1}
	turn :: proc(by: f32) -> Vec4 {return {math.sin(by), math.cos(by), 0, 1}}
	held := Sky_Bake{key = {sky, up}, held = true}
	stale := held
	stale.stale = true
	Case :: struct {name: string, bake: Sky_Bake, sky: Sky_Program, sun: Vec4, reads_sun, due: bool}
	cases := [?]Case{
		{"never drawn", {}, sky, up, false, true},
		{"the same", held, sky, up, true, false},
		{"other parameters", held, other, up, false, true},
		{"its stage made again", stale, sky, up, false, true},
		{"the sun turned, not read", held, sky, turn(0.5), false, false},
		{"the sun went off, not read", held, sky, {}, false, false},
		{"the sun turned half a texel", held, sky, turn(0.5 * SKY_SUN_TURN), true, false},
		{"the sun turned two texels", held, sky, turn(2 * SKY_SUN_TURN), true, true},
		{"the sun went off", held, sky, {}, true, true},
	}
	for c in cases {
		testing.expectf(t, sky_bake_due(c.bake, c.sky, c.sun, c.reads_sun) == c.due, "%s: drawn again %v", c.name, c.due)
	}
	// Small steps that add up to more than SKY_SUN_TURN draw it again once, from where it was drawn.
	bake := held
	draws := 0
	for step in 1 ..= 20 {
		sun := turn(f32(step) * 0.25 * SKY_SUN_TURN)
		if sky_bake_due(bake, sky, sun, true) {
			bake.key.sun = sun
			draws += 1
		}
	}
	testing.expectf(t, draws >= 4 && draws <= 5, "five turns of a texel in steps of a quarter draw it %d times", draws)
}
