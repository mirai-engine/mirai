package render

import "core:math"
import "core:testing"
import "mirai:core"
import mm "mirai:std/math"

// The scale of the entity of a light sizes it: evenly, a larger sphere;
// stretched, a capsule along the axis it stretches most; a rectangle is the
// unit square of its entity. Every light shines toward -z of its entity.
@(test)
lights_take_their_shape_from_the_scale_of_their_entity :: proc(t: ^testing.T) {
	f := new(Sync_Fixture)
	defer free(f)
	if !sync_fixture_init(t, f) {return}
	defer sync_fixture_destroy(f)
	es, worlds, points, spots, rects, suns, sync := &f.world.entities, &f.world.worlds, &f.world.points, &f.world.spots, &f.world.rects, &f.world.suns, &f.sync
	place :: proc(es: ^core.Entities, worlds: ^core.Table(core.World_Transform), transform: mm.Transform) -> core.Entity {
		e := core.create(es)
		core.add(worlds, e, core.World_Transform{transform = transform, previous = transform})
		return e
	}
	point := Point_Light{color = {1, 1, 1}, intensity = 2, range = 10, radius = 0.1}
	turned := mm.quat_axis_angle({0, 1, 0}, math.PI * 0.5)
	core.add(points, place(es, worlds, {position = {0, 1, 0}, rotation = 1, scale = {1, 1, 1}}), point)
	core.add(points, place(es, worlds, {position = {0, 1, 0}, rotation = 1, scale = {3, 3, 3}}), point)
	core.add(points, place(es, worlds, {position = {0, 1, 0}, rotation = turned, scale = {6, 2, 1}}), point)
	core.add(spots, place(es, worlds, {position = {0, 3, 0}, rotation = turned, scale = {1, 1, 1}}), Spot_Light{color = {1, 1, 1}, intensity = 2, range = 10, radius = 0.1, angle = 0.5})
	core.add(rects, place(es, worlds, {position = {0, 2, 0}, rotation = turned, scale = {2, 0.5, 1}}), Rect_Light{color = {1, 1, 1}, luminance = 2, range = 10})
	shown := place(es, worlds, {rotation = turned, scale = {1, 1, 1}})
	core.add(suns, shown, Sun{color = {1, 1, 1}, illuminance = 3})
	sync_frame(f)
	if !testing.expect_value(t, len(sync.lights), 5) {return}
	near :: proc(a, b: [3]f32) -> bool {return abs(a.x - b.x) < 1e-5 && abs(a.y - b.y) < 1e-5 && abs(a.z - b.z) < 1e-5}
	testing.expect(t, sync.lights[0].radius == 0.1 && sync.lights[0].length == 0, "at scale 1 a sphere of its radius")
	testing.expect(t, abs(sync.lights[1].radius - 0.3) < 1e-6 && sync.lights[1].length == 0, "scaled evenly, a larger sphere")
	capsule := sync.lights[2]
	testing.expectf(t, abs(capsule.radius - 0.2) < 1e-6 && abs(capsule.length - 0.8) < 1e-5, "stretched 6 by 2: radius 0.2 and a segment that ends 0.6 from its center, not %v and %v", capsule.radius, capsule.length)
	testing.expectf(t, near(capsule.axis, mm.quat_rotate(turned, [3]f32{1, 0, 0})), "along the axis it stretches most, turned: %v", capsule.axis)
	spot := sync.lights[3]
	testing.expectf(t, near(spot.direction, mm.quat_forward(turned)) && spot.cone == 0.5, "toward -z, its angle the half of its cone: %v %v", spot.direction, spot.cone)
	rectangle := sync.lights[4]
	testing.expectf(t, rectangle.size == {2, 0.5} && rectangle.radius == 0 && rectangle.intensity == 2, "the square of its entity, x by y: %v", rectangle.size)
	testing.expectf(t, near(rectangle.direction, mm.quat_forward(turned)) && near(rectangle.axis, mm.quat_rotate(turned, [3]f32{-1, 0, 0})), "facing -z, wide along -x, its right seen from the side it lights: %v %v", rectangle.direction, rectangle.axis)
	testing.expectf(t, sync.sun.enabled && sync.sun.illuminance == 3 && near(sync.sun.direction, mm.quat_rotate(turned, [3]f32{0, 0, 1})), "the sun shown, shining toward -z: %v", sync.sun)
}

// A sun with a height fade dims from start to end and keeps minimum past it;
// without one, or with start at end, it shines whole at every height.
@(test)
sun_dims_with_the_height_of_the_view_only_when_asked :: proc(t: ^testing.T) {
	fade := Sun_Height_Fade{enabled = true, start = 0, end = -100, minimum = 0.2}
	testing.expect_value(t, sun_height_factor(fade, 10), 1)
	testing.expect(t, abs(sun_height_factor(fade, -50) - 0.6) < 1e-6)
	testing.expect(t, abs(sun_height_factor(fade, -500) - 0.2) < 1e-6)
	testing.expect_value(t, sun_height_factor({}, -500), 1)
	testing.expect_value(t, sun_height_factor({enabled = true, start = 5, end = 5}, -500), 1)

	// The view of a frame of the fixture is at height 0: halfway down a fade from 50 to -50.
	f := new(Sync_Fixture)
	defer free(f)
	if !sync_fixture_init(t, f) {return}
	defer sync_fixture_destroy(f)
	e := core.create(&f.world.entities)
	core.add(&f.world.worlds, e, core.World_Transform{transform = {rotation = 1, scale = {1, 1, 1}}, previous = {rotation = 1, scale = {1, 1, 1}}})
	core.add(&f.world.suns, e, Sun{color = {1, 1, 1}, illuminance = 1000, height_fade = {enabled = true, start = 50, end = -50, minimum = 0.2}})
	sync_frame(f)
	testing.expectf(t, abs(f.sync.sun.illuminance - 600) < 1e-3 && f.sync.sun_illuminance == 1000, "halfway down, 0.6 of its 1000 lux: %v", f.sync.sun)
}
