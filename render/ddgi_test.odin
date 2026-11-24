package mirai_render

import "core:testing"

@(test)
renderer_gi_settling_reports_active_warm_or_urgent_probe_work :: proc(t: ^testing.T) {
	Case :: struct {
		name:     string,
		gi:       bool,
		valid:    bool,
		clear:    bool,
		warm:     bool,
		spread:   u32,
		moved:    bool,
		budget:   u32,
		traced:   u32,
		expected: bool,
	}
	cases := [?]Case{
		{name = "gi off", gi = false, warm = true, expected = false},
		{name = "uninitialized volume", gi = true, valid = false, expected = true},
		{name = "needs clear", gi = true, valid = true, clear = true, expected = true},
		{name = "world restarted", gi = true, valid = true, warm = true, expected = true},
		{name = "warm spread remaining", gi = true, valid = true, spread = 4, budget = 512, expected = true},
		{name = "cascades scrolled", gi = true, valid = true, moved = true, budget = 512, expected = true},
		{name = "urgent probes filling budget", gi = true, valid = true, budget = 512, traced = 256, expected = true},
		{name = "settled below half budget", gi = true, valid = true, budget = 512, traced = 64, expected = false},
		{name = "settled zero traced", gi = true, valid = true, budget = 512, traced = 0, expected = false},
	}
	testing.expect_value(t, renderer_gi_settling(nil), false)
	for c in cases {
		r := new(Renderer)
		defer free(r)
		r.settings.gi_enabled = c.gi
		r.ddgi.valid = c.valid
		r.ddgi.needs_clear = c.clear
		r.gi_warm = c.warm
		r.gi_warm_spread = c.spread
		r.ddgi.moved = c.moved
		r.ddgi.budget = c.budget
		r.stats.probes_traced = c.traced
		testing.expectf(t, renderer_gi_settling(r) == c.expected, "%s: got %v, want %v", c.name, renderer_gi_settling(r), c.expected)
	}
}
