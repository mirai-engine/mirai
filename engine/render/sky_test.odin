package render

import "core:testing"
import "mirai:core"

// Turning a sky on turns off the one that was on, and over its seconds it
// blends from it: the renderer gets the mix, with the turn of its entity.
@(test)
a_sky_turned_on_blends_from_the_one_that_was_on :: proc(t:^testing.T) {
    w:Render_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    problems:core.Problems

    day,night:=core.create(&w.entities),core.create(&w.entities)
    core.add(&w.skies,day,Sky{luminance={1000,1000,1000}})
    core.add(&w.skies,night,Sky{luminance={2,2,3}})
    core.disable(&w.skies,night)
    test_world_settle(&w)
    e,sky,found:=sky_active(core.read(&w.skies),core.read(&w.hidden),core.read(&w.parents))
    testing.expect(t,found && e==day)

    activate(&w.requests,night,core.NONE,2)
    environment_activate(&w.requests,&w.skies,&w.suns,{dt=0},&problems)
    test_world_settle(&w)
    e,sky,found=sky_active(core.read(&w.skies),core.read(&w.hidden),core.read(&w.parents))
    testing.expect(t,found && e==night,"the sky asked for is on, the other off")
    testing.expect_value(t,sky.arrival,f32(1))
    testing.expect_value(t,sky.arrival_from.luminance,[3]f32{1000,1000,1000})

    environment_activate(&w.requests,&w.skies,&w.suns,{dt=1},&problems)
    test_world_settle(&w)
    e,sky,found=sky_active(core.read(&w.skies),core.read(&w.hidden),core.read(&w.parents))
    testing.expect_value(t,sky.arrival,f32(0.5))
    turn:=quaternion128(quaternion(w=0,x=0,y=1,z=0))
    core.add(&w.worlds,night,core.World_Transform{transform={rotation=turn,scale=1}})
    test_world_settle(&w)
    environment:=sky_environment(e,sky,found,false,core.read(&w.worlds),nil)
    testing.expect_value(t,environment.sky,[3]f32{2,2,3})
    testing.expect_value(t,environment.sky_from,[3]f32{1000,1000,1000})
    testing.expect_value(t,environment.sky_from_weight,f32(0.5))
    testing.expect(t,environment.sky_orientation==turn,"the image turns with its entity")

    // An entity without a Sky is a problem that says so; without a sky on, black.
    activate(&w.requests,core.create(&w.entities))
    environment_activate(&w.requests,&w.skies,&w.suns,{dt=0},&problems)
    testing.expect_value(t,problems.count,1)
    none:=sky_environment(core.NONE,{},false,false,core.read(&w.worlds),nil)
    testing.expect(t,none.sky=={} && none.use_background && none.background=={})

    // The air shows only when a sun lights it, and then nothing shows behind it.
    lit:=sky_environment(e,SKY_DEFAULT,true,true,core.read(&w.worlds),nil)
    testing.expect(t,lit.sky_atmosphere && !lit.use_background)
    unlit:=sky_environment(e,SKY_DEFAULT,true,false,core.read(&w.worlds),nil)
    testing.expect(t,!unlit.sky_atmosphere && unlit.use_background && unlit.sky==SKY_DEFAULT.luminance)
}

// Turning a sky on writes only how it arrives: what drives its change, its
// fade and its luminance, keeps what was written before the activation and
// after it in the same frame.
@(test)
turning_a_sky_on_keeps_what_drives_its_change :: proc(t:^testing.T) {
    w:Render_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    problems:core.Problems

    day,night:=core.create(&w.entities),core.create(&w.entities)
    core.add(&w.skies,day,Sky{luminance={1000,1000,1000}})
    core.add(&w.skies,night,Sky{luminance={2,2,3}})
    core.disable(&w.skies,night)
    test_world_settle(&w)
    driven:=(^Sky)(core.raw_edit(core.raw(&w.skies),type_info_of(Sky),night))
    driven.fade,driven.luminance=0.7,{5,5,5}
    activate(&w.requests,night,core.NONE,2)
    environment_activate(&w.requests,&w.skies,&w.suns,{dt=0},&problems)
    test_world_settle(&w)
    sky:=core.at(&w.skies,0)
    testing.expect(t,core.entity_at(&w.skies,0)==night && sky.fade==0.7 && sky.luminance==[3]f32{5,5,5} && sky.arrival==1)
    core.edit(&w.skies,night).fade=0.4
    environment_activate(&w.requests,&w.skies,&w.suns,{dt=0.5},&problems)
    test_world_settle(&w)
    sky=core.at(&w.skies,0)
    testing.expect_value(t,sky.fade,f32(0.4))
    testing.expect_value(t,sky.arrival,f32(0.75))
}
