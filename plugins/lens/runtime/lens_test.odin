package lens

import "core:math"
import "core:testing"
import "mirai:core"
import render "mirai:engine/render"
import volume "mirai:engine/volume"

@(private)
@(test_world)
Fixture :: struct {
    using world:Test_World,
    lenses:core.Table(Lens),
    zones:core.Table(Lens_Volume),
    places:core.Table(volume.Volume),
    worlds:core.Table(core.World_Transform),
    exposures:core.Table(render.Exposure),
    view_volumes:core.Table(render.View_Volume),
}

@(private="file")
look :: proc(f:^Fixture,view:core.View) -> View_Lens {
    return view_lens(&f.lenses,&f.zones,&f.places,&f.worlds,&f.exposures,&f.view_volumes,view)
}

// Half way into the border of a volume that replaces, its numbers are half
// blended and its switches not yet taken; one that adds adds its effects.
@(test)
a_volume_blends_its_numbers_and_takes_its_switches_past_half :: proc(t:^testing.T) {
    value:=LENS_VOLUME_DEFAULT
    by:=Lens_Volume{lens={depth_of_field=true,focus=2,sensor=0.024,bloom=0.1,vignette=1}}
    lens_mix(&value,by,0.4,false)
    testing.expect_value(t,value.lens.focus,f32(10+(2-10)*0.4))
    testing.expect_value(t,value.lens.vignette,f32(0.4))
    testing.expect(t,!value.lens.depth_of_field)
    lens_mix(&value,by,1,false)
    testing.expect_value(t,value.lens,by.lens)
    lens_mix(&value,Lens_Volume{lens={bloom=0.02,motion_blur=true}},1,true)
    testing.expect(t,math.abs(value.lens.bloom-0.12)<1e-6 && value.lens.motion_blur && value.lens.depth_of_field)
    testing.expect_value(t,value.lens.focus,f32(2))
}

// A 70 mm lens (20 degrees on full frame) at f/2 focused at 5 m blurs what is
// infinitely far by a circle of about 9.8 pixels in an image 1000 tall; at f/4
// by half, and a wider lens by less.
@(test)
the_circle_of_confusion_follows_the_aperture_and_the_focal_length :: proc(t:^testing.T) {
    radius:=coc_infinity(20,0.024,2,5,1000)
    testing.expectf(t,math.abs(radius-9.78)<0.01,"radius %v",radius)
    testing.expect(t,math.abs(coc_infinity(20,0.024,4,5,1000)-radius/2)<1e-4)
    testing.expect(t,coc_infinity(60,0.024,2,5,1000)<radius/5)
    testing.expect_value(t,coc_infinity(0,0.024,2,5,1000),f32(0))
}

// A view takes the Lens_Volume where it is and the aperture and shutter of the
// View_Volume there; through a camera with its own Lens and Exposure, those.
@(test)
a_camera_with_its_own_lens_and_exposure_keeps_them :: proc(t:^testing.T) {
    f:Fixture
    if !test_world_init(t,&f) {return}
    defer test_world_destroy(&f)
    zone:=core.create(&f.entities)
    core.add(&f.zones,zone,Lens_Volume{lens={bloom=0.04,focus=10,sensor=0.024}})
    view_volume:=render.VIEW_VOLUME_DEFAULT
    view_volume.exposure.aperture,view_volume.exposure.shutter=2.8,1.0/60
    core.add(&f.view_volumes,zone,view_volume)
    core.add(&f.worlds,zone,core.World_Transform{transform={rotation=1,scale=1}})
    cam:=core.create(&f.entities)
    core.add(&f.worlds,cam,core.World_Transform{transform={rotation=1,scale=1}})
    test_world_settle(&f)
    free:=look(&f,core.View{position={0,1,0},camera=core.NONE})
    testing.expect(t,free.used)
    testing.expect_value(t,free.lens.bloom,f32(0.04))
    // Blended over the default by a weight of 1.
    testing.expect(t,math.abs(free.aperture-2.8)<1e-5 && math.abs(free.shutter-1.0/60)<1e-6)
    core.add(&f.lenses,cam,Lens{depth_of_field=true,focus=3,sensor=0.024})
    exposure:=render.EXPOSURE_DEFAULT
    exposure.aperture=1.4
    core.add(&f.exposures,cam,exposure)
    test_world_settle(&f)
    through:=look(&f,core.View{camera=cam})
    testing.expect(t,through.used && through.lens.depth_of_field && through.lens.bloom==0)
    testing.expect_value(t,through.aperture,f32(1.4))
    // A lens with every effect off draws nothing.
    plain:=core.create(&f.entities)
    core.add(&f.lenses,plain,LENS_DEFAULT)
    test_world_settle(&f)
    testing.expect(t,!look(&f,core.View{camera=plain}).used)
}
