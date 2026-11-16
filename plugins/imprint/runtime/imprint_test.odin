package imprint

import "core:testing"
import "mirai:core"

// A stamp presses all of its depth on the ground, less as it rises, and
// nothing from its reach up; one without reach presses only on the ground.
@(test)
a_stamp_presses_less_the_higher_it_is :: proc(t: ^testing.T) {
	stamp := Imprint_Stamp{radius = 0.3, depth = 0.2, reach = 0.1}
	testing.expect_value(t, stamp_press(stamp, 0), 0.2)
	testing.expect_value(t, stamp_press(stamp, -0.05), 0.2)
	testing.expect(t, abs(stamp_press(stamp, 0.05) - 0.1) < 1e-6, "halfway up its reach it presses half its depth")
	testing.expect_value(t, stamp_press(stamp, 0.1), 0)
	testing.expect_value(t, stamp_press(stamp, 1), 0)
	stamp.reach = 0
	testing.expect_value(t, stamp_press(stamp, 0), 0.2)
	testing.expect_value(t, stamp_press(stamp, 0.01), 0)
	stamp.depth = 0
	testing.expect_value(t, stamp_press(stamp, 0), 0)
}

// A stamp with a stride leaves a print each stride it goes, on alternate
// sides of where it goes, half its gait away; between prints, none.
@(test)
a_stride_leaves_prints_on_alternate_sides :: proc(t: ^testing.T) {
	stamp := Imprint_Stamp{radius = 0.1, depth = 0.1, stride = 0.6, gait = 0.3}
	stride := Stride{entity = core.Entity(1)}
	forward := [3]f32{1, 0, 0}
	_, early := stride_print(&stride, stamp, {0, 0, 0}, forward, 0.4)
	testing.expect(t, !early, "no print before a stride")
	first, ok := stride_print(&stride, stamp, {1, 0, 0}, forward, 0.4)
	testing.expect(t, ok, "a print once it went a stride")
	second, again := stride_print(&stride, stamp, {2, 0, 0}, forward, 0.6)
	testing.expect(t, again, "and one each stride after")
	testing.expect(t, abs(first.z) > 0.149 && abs(first.z) < 0.151 && abs(second.z) > 0.149 && first.z * second.z < 0, "half the gait away, on alternate sides")
	testing.expect(t, first.x == 1 && second.x == 2, "where it stands along its way")
	testing.expect(t, abs(stride.travelled - 0.2) < 1e-5, "what it went past the stride counts for the next one")
}
