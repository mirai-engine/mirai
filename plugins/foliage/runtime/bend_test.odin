package foliage

import "core:testing"
import "mirai:core"
import volume "mirai:engine/volume"
import mm "mirai:std/math"

@(private = "file")
Bend_World :: struct {
	using world: core.Test_World,
	benders: core.Table(Foliage_Bender),
	volumes: core.Table(volume.Volume),
	worlds: core.Table(core.World_Transform),
}

// The benders nearest the view bend the foliage, BENDERS at most, nearest
// first, with where each was the frame before, as far as the sphere of the
// Volume of its entity by its scale; one without a sphere, without radius or
// without lean bends nothing, and lean and radius are held to their limits.
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
		core.add(&w.benders, e, Foliage_Bender{lean = 3})
		core.add(&w.volumes, e, volume.sphere(9))
		core.add(&w.worlds, e, core.World_Transform{place, place})
	}
	// Each would be the nearest: no Volume, a box, a sphere without radius, no lean.
	idle := [?]Maybe(volume.Volume){nil, volume.box({1, 1, 1}), volume.sphere(0), volume.sphere(1)}
	for region, i in idle {
		e := core.create(&w.entities)
		core.add(&w.benders, e, Foliage_Bender{lean = i == len(idle) - 1 ? 0 : 1})
		if v, has := region.?; has {core.add(&w.volumes, e, v)}
		core.add(&w.worlds, e, core.World_Transform{mm.TRANSFORM_IDENTITY, mm.TRANSFORM_IDENTITY})
	}
	small := core.create(&w.entities)
	half := mm.TRANSFORM_IDENTITY
	half.position, half.scale = {0.25, 0, 0}, {1, 0.5, 0.25}
	core.add(&w.benders, small, Foliage_Bender{lean = 0.5})
	core.add(&w.volumes, small, volume.sphere(2))
	core.add(&w.worlds, small, core.World_Transform{half, half})
	core.test_world_settle(&w)
	resident: Foliage_Resident
	benders_gather(&resident, core.read(&w.benders), core.read(&w.volumes), core.read(&w.worlds), core.FRAME_TIME_DEFAULT, {})
	if !testing.expect_value(t, resident.bender_count, BENDERS) {return}
	for i in 1 ..< resident.bender_count {
		testing.expect(t, resident.benders[i - 1].position.x <= resident.benders[i].position.x, "nearest first")
	}
	testing.expect(t, resident.benders[0].entity == small && resident.benders[0].radius == 2 && resident.benders[0].lean == 0.5, "the radius of its sphere by the largest scale")
	testing.expect_value(t, resident.benders[1].position.x, 1)
	testing.expect(t, resident.benders[1].radius == BEND_RADIUS_MAX && resident.benders[1].lean == BEND_LEAN_MAX, "held to the limits")
	testing.expect(t, resident.benders[1].previous == resident.benders[1].position, "a new bender was where it is")
	moved := mm.TRANSFORM_IDENTITY
	moved.position = {0.5, 0, 0}
	core.free(&w.worlds, placed[len(placed) - 1])^ = core.World_Transform{moved, moved}
	benders_gather(&resident, core.read(&w.benders), core.read(&w.volumes), core.read(&w.worlds), core.FRAME_TIME_DEFAULT, {})
	testing.expect(t, resident.benders[1].position.x == 0.5 && resident.benders[1].previous.x == 1, "it was where the frame before had it")
}
