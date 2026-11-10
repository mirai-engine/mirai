package foliage

import "core:testing"
import "mirai:core"
import mm "mirai:std/math"

@(private = "file")
Bend_World :: struct {
	using world: core.Test_World,
	benders: core.Table(Foliage_Bender),
	worlds: core.Table(core.World_Transform),
}

// The benders nearest the view bend the foliage, BENDERS at most, nearest
// first, with where each was the frame before; one without radius or lean
// bends nothing, and lean and radius are held to their limits.
@(test)
the_benders_nearest_the_view_bend_the_foliage :: proc(t: ^testing.T) {
	w: Bend_World
	if !core.test_world_init(t, &w, test_types) {return}
	defer core.test_world_destroy(&w)
	placed: [BENDERS + 2]core.Entity
	for &e, i in placed {
		e = core.create(&w.entities)
		place := mm.TRANSFORM_IDENTITY
		place.position = {f32(len(placed) - i), 0, 0}
		core.add(&w.benders, e, Foliage_Bender{radius = 9, lean = 3})
		core.add(&w.worlds, e, core.World_Transform{place, place})
	}
	idle := core.create(&w.entities)
	core.add(&w.benders, idle, Foliage_Bender{radius = 0, lean = 1})
	core.add(&w.worlds, idle, core.World_Transform{mm.TRANSFORM_IDENTITY, mm.TRANSFORM_IDENTITY})
	core.test_world_settle(&w)
	resident: Foliage_Resident
	benders_gather(&resident, core.read(&w.benders), core.read(&w.worlds), core.FRAME_TIME_DEFAULT, {})
	if !testing.expect_value(t, resident.bender_count, BENDERS) {return}
	for i in 1 ..< resident.bender_count {
		testing.expect(t, resident.benders[i - 1].position.x <= resident.benders[i].position.x, "nearest first")
	}
	testing.expect_value(t, resident.benders[0].position.x, 1)
	testing.expect(t, resident.benders[0].radius == BEND_RADIUS_MAX && resident.benders[0].lean == BEND_LEAN_MAX, "held to the limits")
	testing.expect(t, resident.benders[0].previous == resident.benders[0].position, "a new bender was where it is")
	moved := mm.TRANSFORM_IDENTITY
	moved.position = {0.5, 0, 0}
	core.free(&w.worlds, placed[len(placed) - 1])^ = core.World_Transform{moved, moved}
	benders_gather(&resident, core.read(&w.benders), core.read(&w.worlds), core.FRAME_TIME_DEFAULT, {})
	testing.expect(t, resident.benders[0].position.x == 0.5 && resident.benders[0].previous.x == 1, "it was where the frame before had it")
}
