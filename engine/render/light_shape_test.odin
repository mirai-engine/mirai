package render

import "base:runtime"
import "core:math"
import "core:testing"
import "mirai:core"
import mm "mirai:std/math"

// The scale of the entity of a light sizes it: evenly, a larger sphere;
// stretched, a capsule along the axis it stretches most; a rectangle is the
// unit square of its entity. Every light shines toward -z of its entity, and
// the first sun shown is the sun.
@(test)
lights_take_their_shape_from_the_scale_of_their_entity :: proc(t: ^testing.T) {
	es: core.Entities
	defer core.entities_destroy(&es)
	worlds: core.Table(core.World_Transform)
	suns: core.Table(Sun)
	points: core.Table(Point_Light)
	spots: core.Table(Spot_Light)
	rects: core.Table(Rect_Light)
	emissions: core.Table(Light_Emission)
	meshes: core.Table(Mesh_Renderer)
	hidden: core.Table(Hidden)
	parents: core.Table(core.Parent)
	defer {core.table_destroy(&worlds); core.table_destroy(&suns); core.table_destroy(&points); core.table_destroy(&spots); core.table_destroy(&rects); core.table_destroy(&emissions); core.table_destroy(&meshes); core.table_destroy(&hidden); core.table_destroy(&parents)}
	sync: Render_Sync
	defer sync_free(&sync)
	place :: proc(es: ^core.Entities, worlds: ^core.Table(core.World_Transform), transform: mm.Transform) -> core.Entity {
		e := core.create(es)
		core.add(worlds, e, core.World_Transform{transform = transform, previous = transform})
		return e
	}
	point := Point_Light{color = {1, 1, 1}, intensity = 2, range = 10, radius = 0.1}
	turned := mm.quat_axis_angle({0, 1, 0}, math.PI * 0.5)
	core.add(&points, place(&es, &worlds, {position = {0, 1, 0}, rotation = 1, scale = {1, 1, 1}}), point)
	core.add(&points, place(&es, &worlds, {position = {0, 1, 0}, rotation = 1, scale = {3, 3, 3}}), point)
	core.add(&points, place(&es, &worlds, {position = {0, 1, 0}, rotation = turned, scale = {6, 2, 1}}), point)
	core.add(&spots, place(&es, &worlds, {position = {0, 3, 0}, rotation = turned, scale = {1, 1, 1}}), Spot_Light{color = {1, 1, 1}, intensity = 2, range = 10, radius = 0.1, angle = 0.5})
	core.add(&rects, place(&es, &worlds, {position = {0, 2, 0}, rotation = turned, scale = {2, 0.5, 1}}), Rect_Light{color = {1, 1, 1}, luminance = 2, range = 10})
	shown := place(&es, &worlds, {rotation = turned, scale = {1, 1, 1}})
	off := place(&es, &worlds, {rotation = 1, scale = {1, 1, 1}})
	core.add(&hidden, off, Hidden{})
	core.add(&suns, off, Sun{color = {1, 1, 1}, illuminance = 7})
	core.add(&suns, shown, Sun{color = {1, 1, 1}, illuminance = 3})
	core.table_settle(&worlds, &es); core.table_settle(&points, &es); core.table_settle(&spots, &es); core.table_settle(&rects, &es); core.table_settle(&suns, &es); core.table_settle(&hidden, &es)
	lights_build(&sync, nil, core.read(&worlds), {core.read(&suns), core.read(&points), core.read(&spots), core.read(&rects), core.NONE}, core.read(&emissions), core.read(&meshes), core.read(&hidden), core.read(&parents), nil, 0)
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
	// Without memory for them no light is left out in silence: the build says so, with none.
	refuse :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, runtime.Allocator_Error) {
		return nil, .Out_Of_Memory if mode == .Alloc || mode == .Alloc_Non_Zeroed || mode == .Resize || mode == .Resize_Non_Zeroed else nil
	}
	starved: Render_Sync
	starved.lights.allocator = {refuse, nil}
	testing.expect(t, !lights_build(&starved, nil, core.read(&worlds), {core.read(&suns), core.read(&points), core.read(&spots), core.read(&rects), core.NONE}, core.read(&emissions), core.read(&meshes), core.read(&hidden), core.read(&parents), nil, 0) && len(starved.lights) == 0, "lights built without memory for them")
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

	w: Render_World
	if !core.test_world_init(t, &w, test_types) {return}
	defer core.test_world_destroy(&w)
	sync: Render_Sync
	defer sync_free(&sync)
	e := core.create(&w.entities)
	core.add(&w.worlds, e, core.World_Transform{transform = {rotation = 1, scale = {1, 1, 1}}, previous = {rotation = 1, scale = {1, 1, 1}}})
	core.add(&w.suns, e, Sun{color = {1, 1, 1}, illuminance = 1000, height_fade = fade})
	core.test_world_settle(&w)
	lights_build(&sync, nil, core.read(&w.worlds), {core.read(&w.suns), core.read(&w.points), core.read(&w.spots), core.read(&w.rects), core.NONE}, core.read(&w.emissions), core.read(&w.meshes), core.read(&w.hidden), core.read(&w.parents), nil, -50)
	testing.expectf(t, abs(sync.sun.illuminance - 600) < 1e-3 && sync.sun_illuminance == 1000 && abs(sync.sun_factor - 0.6) < 1e-6, "halfway down, 0.6 of its 1000 lux: %v", sync.sun)
}
