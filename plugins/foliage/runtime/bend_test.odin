package foliage

import "core:math"
import "core:testing"
import "mirai:core"
import volume "mirai:engine/volume"
import mm "mirai:std/math"

@(private)
@(test_world)
Bend_World :: struct {
	using world: Test_World,
	benders: core.Table(Foliage_Bender),
	volumes: core.Table(volume.Volume),
	worlds: core.Table(core.World_Transform),
}

@(private = "file")
bender_add :: proc(w: ^Bend_World, position: [3]f32, region: volume.Volume, lean: f32) -> core.Entity {
	e := core.create(&w.entities)
	place := mm.TRANSFORM_IDENTITY
	place.position = position
	core.add(&w.benders, e, Foliage_Bender{lean = lean})
	core.add(&w.volumes, e, region)
	core.add(&w.worlds, e, core.World_Transform{place, place})
	return e
}

@(private = "file")
trample_frame :: proc(w: ^Bend_World, f: ^Foliage_Trample, at: [3]f32, dt: f32) {
	frame := core.FRAME_TIME_DEFAULT
	frame.dt = dt
	trample_update(f, core.read(&w.benders), core.read(&w.volumes), core.read(&w.worlds), frame, at)
}

// Every bender in the field tramples it, however many, away from its middle
// as far as half the largest side of the box its Volume is in, at the height
// of its centre, with lean and radius held to their limits; one without
// radius or lean tramples nothing. What it trampled stays after it goes and
// stands back up over TRAMPLE_RECOVER seconds, the field stops writing once
// all stands, and what leaves the field enters it again standing.
@(test)
every_bender_tramples_the_foliage_and_it_stands_back_up_over_time :: proc(t: ^testing.T) {
	w: Bend_World
	if !test_world_init(t, &w) {return}
	defer test_world_destroy(&w)
	crowd: [24]core.Entity
	for &e, i in crowd {e = bender_add(&w, {f32(i % 6) * 5 - 12, 1, f32(i / 6) * 5 - 8}, volume.sphere(2), 0.8)}
	strong := bender_add(&w, {20, 3, 20}, volume.sphere(9), 3)
	bender_add(&w, {-20, 1, -20}, volume.sphere(0), 1)
	bender_add(&w, {-20, 1, 20}, volume.sphere(1), 0)
	test_world_settle(&w)
	f: Foliage_Trample
	defer delete(f.texels)
	trample_frame(&w, &f, {}, 0)
	testing.expect_value(t, f.writes, 2)
	for i in 0 ..< len(crowd) {
		at := [3]f32{f32(i % 6) * 5 - 12, 0, f32(i / 6) * 5 - 8}
		lean, height, inside := trample_at(&f, at + {0.5, 0, 0})
		testing.expectf(t, inside && lean.x > 0.5 && abs(lean.y) < 0.35 && abs(height - 1) < 0.05, "bender %d leans what is beside it away: %v at %v", i, lean, height)
		lean, _, _ = trample_at(&f, at + {2.5, 0, 0})
		testing.expectf(t, lean == {}, "bender %d leans nothing past its radius", i)
	}
	lean, _, _ := trample_at(&f, {20 - 0.25, 0, 20.25})
	testing.expect(t, abs(math.sqrt(lean.x * lean.x + lean.y * lean.y) - BEND_LEAN_MAX) < 0.01, "a lean held to BEND_LEAN_MAX")
	lean, _, _ = trample_at(&f, {20 + BEND_RADIUS_MAX + 0.5, 0, 20})
	testing.expect(t, lean == {}, "a radius held to BEND_RADIUS_MAX")
	for z in ([]f32{-20, 20}) {
		lean, _, _ = trample_at(&f, {-19.75, 0, z + 0.25})
		testing.expect(t, lean == {}, "a bender without radius or lean tramples nothing")
	}
	// Gone, what it trampled stands back up: by 1/e in TRAMPLE_RECOVER seconds, and all of it in a while.
	before, _, _ := trample_at(&f, {-11.5, 0, -8})
	for e in crowd {core.destroy(&w.entities, e)}
	core.destroy(&w.entities, strong)
	test_world_settle(&w)
	for _ in 0 ..< 10 {trample_frame(&w, &f, {}, TRAMPLE_RECOVER / 10)}
	after, _, _ := trample_at(&f, {-11.5, 0, -8})
	testing.expectf(t, abs(after.x - before.x / math.e) < 0.01 * before.x, "%v stands back up to %v", before.x, after.x)
	for _ in 0 ..< 60 {trample_frame(&w, &f, {}, TRAMPLE_RECOVER / 4)}
	after, _, _ = trample_at(&f, {-11.5, 0, -8})
	testing.expect(t, after == {} && f.writes == 2, "all stands, written for this frame and the one after")
	f.writes = 0
	trample_frame(&w, &f, {}, 0.1)
	testing.expect_value(t, f.writes, 0)
	// What the field leaves behind enters again standing.
	passer := bender_add(&w, {0, 1, 0}, volume.sphere(2), 1)
	test_world_settle(&w)
	trample_frame(&w, &f, {}, 0)
	lean, _, _ = trample_at(&f, {0.5, 0, 0})
	testing.expect(t, lean.x > 0.5)
	core.destroy(&w.entities, passer)
	test_world_settle(&w)
	trample_frame(&w, &f, {40, 0, 0}, 0)
	_, _, inside := trample_at(&f, {0.5, 0, 0})
	testing.expect(t, !inside, "the field follows the view")
	trample_frame(&w, &f, {}, 0)
	lean, _, inside = trample_at(&f, {0.5, 0, 0})
	testing.expect(t, inside && lean == {}, "what enters the field enters standing")
}
