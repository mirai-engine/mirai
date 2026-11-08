package render

import "core:testing"
import "mirai:core"

// Turning a sky on turns off the one that was on, and over its seconds it
// blends from it: the renderer gets the mix, with the turn of its entity.
@(test)
a_sky_turned_on_blends_from_the_one_that_was_on :: proc(t:^testing.T) {
    es:core.Entities;core.entities_init(&es);defer core.entities_destroy(&es)
    skies:core.Table(Sky);core.table_init(&skies,"Sky");defer core.table_destroy(&skies)
    skies.single=true
    suns:core.Table(Sun);core.table_init(&suns,"Sun");defer core.table_destroy(&suns)
    worlds:core.Table(core.World_Transform);core.table_init(&worlds,"World_Transform");defer core.table_destroy(&worlds)
    hidden:core.Table(Hidden);core.table_init(&hidden,"Hidden");defer core.table_destroy(&hidden)
    parents:core.Table(core.Parent);core.table_init(&parents,"Parent");defer core.table_destroy(&parents)
    requests:Environment_Requests;defer delete(requests.queue.items)
    problems:core.Problems

    day,night:=core.create(&es),core.create(&es)
    core.add(&skies,day,Sky{luminance={1000,1000,1000}})
    core.add(&skies,night,Sky{luminance={2,2,3}})
    core.disable(&skies,night)
    core.table_settle(&skies,&es)
    e,sky,found:=sky_active(core.read(&skies),core.read(&hidden),core.read(&parents))
    testing.expect(t,found && e==day)

    activate(&requests,night,core.NONE,2)
    environment_activate(&requests,&skies,&suns,{dt=0},&problems)
    core.table_settle(&skies,&es)
    e,sky,found=sky_active(core.read(&skies),core.read(&hidden),core.read(&parents))
    testing.expect(t,found && e==night,"the sky asked for is on, the other off")
    testing.expect_value(t,sky.arrival,f32(1))
    testing.expect_value(t,sky.arrival_from.luminance,[3]f32{1000,1000,1000})

    environment_activate(&requests,&skies,&suns,{dt=1},&problems)
    core.table_settle(&skies,&es)
    e,sky,found=sky_active(core.read(&skies),core.read(&hidden),core.read(&parents))
    testing.expect_value(t,sky.arrival,f32(0.5))
    turn:=quaternion128(quaternion(w=0,x=0,y=1,z=0))
    core.add(&worlds,night,core.World_Transform{transform={rotation=turn,scale=1}})
    core.table_settle(&worlds,&es)
    environment:=sky_environment(e,sky,found,false,core.read(&worlds),nil)
    testing.expect_value(t,environment.sky,[3]f32{2,2,3})
    testing.expect_value(t,environment.sky_from,[3]f32{1000,1000,1000})
    testing.expect_value(t,environment.sky_from_weight,f32(0.5))
    testing.expect(t,environment.sky_orientation==turn,"the image turns with its entity")

    // An entity without a Sky is a problem that says so; without a sky on, black.
    activate(&requests,core.create(&es))
    environment_activate(&requests,&skies,&suns,{dt=0},&problems)
    testing.expect_value(t,problems.count,1)
    none:=sky_environment(core.NONE,{},false,false,core.read(&worlds),nil)
    testing.expect(t,none.sky=={} && none.use_background && none.background=={})

    // The air shows only when a sun lights it, and then nothing shows behind it.
    lit:=sky_environment(e,SKY_DEFAULT,true,true,core.read(&worlds),nil)
    testing.expect(t,lit.sky_atmosphere && !lit.use_background)
    unlit:=sky_environment(e,SKY_DEFAULT,true,false,core.read(&worlds),nil)
    testing.expect(t,!unlit.sky_atmosphere && unlit.use_background && unlit.sky==SKY_DEFAULT.luminance)
}

// Turning a sky on writes only how it arrives: what drives its change, its
// fade and its luminance, keeps what was written before the activation and
// after it in the same frame.
@(test)
turning_a_sky_on_keeps_what_drives_its_change :: proc(t:^testing.T) {
    es:core.Entities;core.entities_init(&es);defer core.entities_destroy(&es)
    skies:core.Table(Sky);core.table_init(&skies,"Sky");defer core.table_destroy(&skies)
    skies.single=true
    suns:core.Table(Sun);core.table_init(&suns,"Sun");defer core.table_destroy(&suns)
    requests:Environment_Requests;defer delete(requests.queue.items)
    problems:core.Problems

    day,night:=core.create(&es),core.create(&es)
    core.add(&skies,day,Sky{luminance={1000,1000,1000}})
    core.add(&skies,night,Sky{luminance={2,2,3}})
    core.disable(&skies,night)
    core.table_settle(&skies,&es)
    driven:=(^Sky)(core.raw_get(core.raw(&skies),type_info_of(Sky),night))
    driven.fade,driven.luminance=0.7,{5,5,5}
    activate(&requests,night,core.NONE,2)
    environment_activate(&requests,&skies,&suns,{dt=0},&problems)
    core.table_settle(&skies,&es)
    sky:=core.at(core.read(&skies),0)
    testing.expect(t,core.entity_at(core.read(&skies),0)==night && sky.fade==0.7 && sky.luminance==[3]f32{5,5,5} && sky.arrival==1)
    core.get(&skies,night).fade=0.4
    environment_activate(&requests,&skies,&suns,{dt=0.5},&problems)
    core.table_settle(&skies,&es)
    sky=core.at(core.read(&skies),0)
    testing.expect_value(t,sky.fade,f32(0.4))
    testing.expect_value(t,sky.arrival,f32(0.75))
}
