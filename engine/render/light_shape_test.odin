package render

import "core:math"
import "core:mem"
import "core:testing"
import "mirai:core"
import gpu "mirai:render"
import mm "mirai:std/math"

// The scale of the entity of a light sizes it: evenly, a larger sphere;
// stretched, a capsule along the axis it stretches most; a rectangle is the
// unit square of its entity. Every light shines toward -z of its entity, and
// a spot lays the width of its texture along its +x.
@(test)
lights_take_their_shape_from_the_scale_of_their_entity :: proc(t: ^testing.T) {
	f := new(Sync_Fixture)
	defer free(f)
	if !sync_fixture_init(t, f) {return}
	defer sync_fixture_destroy(f)
	es, worlds, spots, suns, sync := &f.world.entities, &f.world.worlds, &f.world.spots, &f.world.suns, &f.sync
	place :: proc(es: ^core.Entities, worlds: ^core.Table(core.World_Transform), transform: mm.Transform) -> core.Entity {
		e := core.create(es)
		core.add(worlds, e, core.World_Transform{transform = transform, previous = transform})
		return e
	}
	point := Point_Light{color = {1, 1, 1}, intensity = 2, range = 10, radius = 0.1}
	turned := mm.quat_axis_angle({0, 1, 0}, math.PI * 0.5)
	at :: proc(rotation: mm.Quat, scale: [3]f32) -> core.World_Transform {
		place := mm.Transform{position = {0, 1, 0}, rotation = rotation, scale = scale}
		return {transform = place, previous = place}
	}
	sphere :: point_desc
	near :: proc(a, b: [3]f32) -> bool {return abs(a.x - b.x) < 1e-5 && abs(a.y - b.y) < 1e-5 && abs(a.z - b.z) < 1e-5}
	one, even, capsule := sphere(at(1, 1), point), sphere(at(1, 3), point), sphere(at(turned, {6, 2, 1}), point)
	testing.expect(t, one.radius == 0.1 && one.length == 0, "at scale 1 a sphere of its radius")
	testing.expect(t, abs(even.radius - 0.3) < 1e-6 && even.length == 0, "scaled evenly, a larger sphere")
	testing.expectf(t, abs(capsule.radius - 0.2) < 1e-6 && abs(capsule.length - 0.8) < 1e-5, "stretched 6 by 2: radius 0.2 and a segment that ends 0.6 from its center, not %v and %v", capsule.radius, capsule.length)
	testing.expectf(t, near(capsule.axis, mm.quat_rotate(turned, [3]f32{1, 0, 0})), "along the axis it stretches most, turned: %v", capsule.axis)
	rectangle := rect_desc(at(turned, {2, 0.5, 1}), Rect_Light{color = {1, 1, 1}, luminance = 2, range = 10}, nil)
	testing.expectf(t, rectangle.size == {2, 0.5} && rectangle.radius == 0 && rectangle.intensity == 2, "the square of its entity, x by y: %v", rectangle.size)
	testing.expectf(t, near(rectangle.direction, mm.quat_forward(turned)) && near(rectangle.axis, mm.quat_rotate(turned, [3]f32{-1, 0, 0})), "facing -z, wide along -x, its right seen from the side it lights: %v %v", rectangle.direction, rectangle.axis)
	aimed := spot_desc(at(turned, 1), Spot_Light{color = {1, 1, 1}, intensity = 2, range = 10, angle = 0.5}, nil)
	testing.expectf(t, near(aimed.texture_axis, mm.quat_rotate(turned, [3]f32{1, 0, 0})), "the width of the texture of a spot along +x: %v", aimed.texture_axis)
	// A spot shines toward -z, its angle the half of its cone; the sun shown too.
	core.add(spots, place(es, worlds, {position = {0, 3, 0}, rotation = turned, scale = {1, 1, 1}}), Spot_Light{color = {1, 1, 1}, intensity = 2, range = 10, radius = 0.1, angle = 0.5})
	shown := place(es, worlds, {rotation = turned, scale = {1, 1, 1}})
	core.add(suns, shown, Sun{color = {1, 1, 1}, illuminance = 3})
	sync_frame(f)
	if !testing.expect_value(t, len(f.renderer.scene.lights), 1) {return}
	spot := f.renderer.scene.lights[0]
	testing.expectf(t, near(spot.direction_cone.xyz, mm.quat_forward(turned)) && abs(spot.direction_cone.w - math.cos(f32(0.5))) < 1e-6, "toward -z, its angle the half of its cone: %v", spot.direction_cone)
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
	testing.expectf(t, abs(f.sync.sun.illuminance - 600) < 1e-3, "halfway down, 0.6 of its 1000 lux: %v", f.sync.sun)
}

// What of the light of each light bounces, what a fog scatters and whether it
// casts shadows go to the renderer with the light; the Bounce_Light on scales
// all the indirect light, and without one it is 1.
@(test)
the_shares_and_shadows_of_the_lights_and_the_bounce_of_the_world_reach_the_renderer :: proc(t: ^testing.T) {
	f := new(Sync_Fixture)
	defer free(f)
	if !sync_fixture_init(t, f) {return}
	defer sync_fixture_destroy(f)
	e := core.create(&f.world.entities)
	core.add(&f.world.worlds, e, core.World_Transform{transform = {rotation = 1, scale = {1, 1, 1}}, previous = {rotation = 1, scale = {1, 1, 1}}})
	lamp := POINT_LIGHT_DEFAULT
	lamp.indirect, lamp.scattering, lamp.shadows = 4, 2, false
	core.add(&f.world.points, e, lamp)
	sun := SUN_DEFAULT
	sun.indirect, sun.scattering, sun.shadows = 6, 0, false
	core.add(&f.world.suns, e, sun)
	sync_frame(f)
	testing.expect_value(t, f.renderer.scene.indirect, 1)
	if testing.expect_value(t, len(f.renderer.scene.lights), 1) {
		testing.expect_value(t, gpu.light_shares_of(f.renderer.scene.lights[0]), [2]f32{4, 2})
		testing.expect(t, f.renderer.scene.light_shadowless[0], "the lamp casts no shadows")
	}
	testing.expect(t, f.sync.sun.indirect == 6 && f.sync.sun.scattering == 0 && f.sync.sun.shadowless, "the shares and shadows of the sun")
	core.add(&f.world.bounces, e, Bounce_Light{scale = 5})
	sync_frame(f)
	testing.expect_value(t, f.renderer.scene.indirect, 5)
}

// An extra light the renderer refuses starves the frame: the next one gives
// the renderer everything again, and the lights given before the refused one
// go with the rest.
@(test)
a_refused_extra_light_leaves_none_lit_after_the_next_frame :: proc(t:^testing.T) {
    f:=new(Sync_Fixture);defer free(f)
    if !sync_fixture_init(t,f) {return}
    defer sync_fixture_destroy(f)

    e:=core.create(&f.world.entities)
    core.add(&f.world.worlds,e,core.World_Transform{transform={position={0,2,0},rotation=1,scale=1},previous={position={0,2,0},rotation=1,scale=1}})
    core.add(&f.world.points,e,POINT_LIGHT_DEFAULT)
    sync_frame(f)
    s:=&f.renderer.scene
    testing.expect_value(t,len(s.lights),1)
    // Room for two lights and no memory for a third.
    room :: proc(list:^[dynamic]$T,count:int) {
        reserve(list,count)
        shrink(list,count)
        list.allocator=mem.nil_allocator()
    }
    room(&s.lights,2);room(&s.light_shadowless,2);room(&s.light_leaves,2);room(&s.light_keys,2);room(&s.light_tree,4)
    defer s.lights.allocator,s.light_shadowless.allocator,s.light_leaves.allocator,s.light_keys.allocator,s.light_tree.allocator=context.allocator,context.allocator,context.allocator,context.allocator,context.allocator
    l1:=Light_Desc{position={2,1,0},color={1,0.5,0.2},intensity=400,range=8,radius=0.1,shadowless=true}
    l2:=Light_Desc{position={4,1,0},color={0.2,0.5,1},intensity=250,range=6,radius=0.1,shadowless=true}
    testing.expect(t,light_add(&f.app.extras,l1) && light_add(&f.app.extras,l2))
    sync_frame(f)
    f.app.extras.light_count=0
    testing.expect_value(t,len(s.lights),2)
    testing.expect(t,!f.sync.synced,"the frame starved")
    sync_frame(f)
    testing.expect_value(t,len(s.lights),1)
    testing.expect_value(t,f.sync.extra_lights,0)
    testing.expect_value(t,len(f.sync.light_owners),1)
}
