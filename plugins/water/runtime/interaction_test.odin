package water

import "core:testing"
import "mirai:core"
import phys "plugins:physics/runtime"

@(private="file")
born :: proc(births:^core.Births,name:string) -> (count:int) {
    channel:=core.birth_channel(name)
    for birth in births.queue.items {if birth.channel==channel {count+=1}}
    return
}

@(test)
a_body_that_moves_under_the_water_bubbles_behind_it_and_a_still_one_does_not :: proc(t:^testing.T) {
    swimming:=phys.Fluid_Body{entity=core.Entity(7),center={0,-1,0},velocity={2,0,0},volume=0.08,whole=0.08,surface=0,reach=0.9}
    birth,ok:=bubbles_of(swimming)
    testing.expect(t,ok)
    testing.expect(t,birth.position.x<0 && birth.position.y<=-BUBBLE_DEPTH && birth.count>=1,"behind it, under the surface")
    still:=swimming
    still.velocity={0.1,0,0}
    _,ok=bubbles_of(still)
    testing.expect(t,!ok,"a still body leaves none")
    floating:=swimming
    floating.volume=0.01
    _,ok=bubbles_of(floating)
    testing.expect(t,!ok,"nor one mostly out of the water")
    near:=swimming
    near.center.y=-0.02
    birth,_=bubbles_of(near)
    testing.expect(t,birth.position.y<=-BUBBLE_DEPTH,"a body at the surface bubbles under it")
    fast:=swimming
    fast.velocity={6,0,0}
    many,_:=bubbles_of(fast)
    testing.expect(t,many.count>birth.count,"faster, more")

    // Through the step, a pause between the bubbles of a body.
    wet:Water_Wet
    births:core.Births
    defer core.value_free(&births,type_info_of(core.Births))
    for _ in 0..<BUBBLE_PAUSE+1 {bodies_step(&wet,{swimming,still},{},&births,1.0/60)}
    testing.expect_value(t,born(&births,CHANNEL_BUBBLES),2)
    testing.expect_value(t,born(&births,CHANNEL_SPLASHES),0)
}

@(test)
a_body_that_leaves_the_water_stays_wet_and_dries_in_wet_seconds :: proc(t:^testing.T) {
    wet:Water_Wet
    births:core.Births
    defer core.value_free(&births,type_info_of(core.Births))
    crate:=phys.Fluid_Body{entity=core.Entity(3),center={0,-1,0},volume=1,whole=1,surface=0,reach=0.9}
    dt:=f32(1.0/60)
    bodies_step(&wet,{crate},{},&births,dt)
    testing.expect(t,wet.count==1 && wet.marks[0].wet==1,"under the water it is soaked")
    // Out of the water but in the bounds of the fluid: nothing under the surface.
    out:=crate
    out.center.y,out.volume=1,0
    bodies_step(&wet,{out},{},&births,dt)
    testing.expect(t,wet.marks[0].wet<1 && wet.marks[0].wet>0.99)
    // Out of the bounds, the physics finds it no more: it keeps drying.
    ticks:=0
    for wet.count>0 && ticks<1000 {
        bodies_step(&wet,{},{},&births,dt)
        ticks+=1
    }
    seconds:=f32(ticks+1)*dt
    testing.expectf(t,abs(seconds-WET_SECONDS)<=2*dt,"dry in %v s",seconds)
    // Half under the surface, it is that wet while it floats.
    half:=crate
    half.volume=0.5
    for _ in 0..<10 {bodies_step(&wet,{half},{},&births,dt)}
    testing.expect_value(t,wet.marks[0].wet,f32(0.5))
    testing.expect(t,wet_level(0.5)==0.5 && wet_level(1.0/1000)==0 && wet_level(2)==1)
}

@(test)
under_the_surface_the_listener_hears_through_the_water :: proc(t:^testing.T) {
    under:=medium_at({density=1025},true)
    testing.expect(t,under.lowpass==UNDER_LOWPASS && under.weight==1 && under.reverb==UNDER_REVERB)
    testing.expect(t,medium_at({density=0},true)=={},"in a dry box or over the surface, the air")
    testing.expect(t,medium_at({},false)=={},"and where there is no fluid")
}
