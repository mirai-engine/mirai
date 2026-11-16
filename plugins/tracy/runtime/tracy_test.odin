package tracy

import "core:testing"
import "mirai:std/base"

// A stack of zones takes them by start, the outer one first, and closes each
// before the next at its depth: a zone that lasted nothing still begins
// before it ends, also when it starts where its parent does.
@(test)
zones_come_out_as_a_stack_takes_them :: proc(t: ^testing.T) {
	zones := []base.Profile_Zone{
		{name = "child", start = 10, duration = 0, depth = 1},
		{name = "sibling", start = 10, duration = 5, depth = 1},
		{name = "first", start = 10, duration = 0, depth = 2},
		{name = "frame", start = 10, duration = 20, depth = 0},
	}
	out: [8]Zone_Event
	events := zone_events(zones, out[:])
	expected := []Zone_Event{
		{10, "frame", true}, {10, "child", true}, {10, "", false},
		{10, "sibling", true}, {10, "first", true}, {10, "", false}, {15, "", false}, {30, "", false},
	}
	if !testing.expect_value(t, len(events), len(expected)) {return}
	for event, i in events {
		testing.expectf(t, event.begin == expected[i].begin && event.time == expected[i].time && event.name == expected[i].name, "event %d: %v, expected %v", i, event, expected[i])
	}
}
