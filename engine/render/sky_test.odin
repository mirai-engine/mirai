package render

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:host"
import gpu "mirai:render"
import "mirai:render/abi"
import "mirai:std/base"

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
    environment:=sky_environment(e,sky,found,false,core.read(&w.worlds),nil,nil)
    testing.expect_value(t,environment.sky,[3]f32{2,2,3})
    testing.expect_value(t,environment.sky_from,[3]f32{1000,1000,1000})
    testing.expect_value(t,environment.sky_from_weight,f32(0.5))
    testing.expect(t,environment.sky_orientation==turn,"the image turns with its entity")

    // An entity without a Sky is a problem that says so; without a sky on, black.
    activate(&w.requests,core.create(&w.entities))
    environment_activate(&w.requests,&w.skies,&w.suns,{dt=0},&problems)
    testing.expect_value(t,problems.count,1)
    none:=sky_environment(core.NONE,{},false,false,core.read(&w.worlds),nil,nil)
    testing.expect(t,none.sky=={} && none.use_background && none.background=={})

    // The air shows only when a sun lights it, and then nothing shows behind it.
    lit:=sky_environment(e,SKY_DEFAULT,true,true,core.read(&w.worlds),nil,nil)
    testing.expect(t,lit.sky_atmosphere && !lit.use_background)
    unlit:=sky_environment(e,SKY_DEFAULT,true,false,core.read(&w.worlds),nil,nil)
    testing.expect(t,!unlit.sky_atmosphere && unlit.use_background && unlit.sky==SKY_DEFAULT.luminance)
}

// The background shows in place of the sky with use_background, unless a lit
// atmosphere is what shows; the sky lights as without it. A background image
// without use_background never shows: a problem that says how to fix it.
@(test)
a_sky_background_shows_with_use_background_and_reports_an_image_that_cannot :: proc(t:^testing.T) {
    w:Render_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    e:=core.create(&w.entities)
    painted:=base.Asset_Id{1,2}
    Case::struct {name:string,sky:Sky,sunlit,shown,problem:bool}
    cases:=[]Case{
        {name="a color",sky={luminance={900,900,900},background={10,20,30},use_background=true},shown=true},
        {name="an image",sky={luminance={900,900,900},background={400,400,400},background_image=painted,use_background=true},shown=true},
        {name="an image under a lit atmosphere",sky={luminance={900,900,900},background_image=painted,use_background=true,atmosphere=true},sunlit=true},
        {name="an image under an unlit atmosphere",sky={luminance={900,900,900},background_image=painted,use_background=true,atmosphere=true},shown=true},
        {name="an image without use_background",sky={luminance={900,900,900},background_image=painted},problem=true},
    }
    for c in cases {
        problems:core.Problems
        environment:=sky_environment(e,c.sky,true,c.sunlit,core.read(&w.worlds),nil,&problems)
        testing.expectf(t,environment.use_background==c.shown,"%s: the background shows: %v",c.name,environment.use_background)
        testing.expectf(t,environment.sky==c.sky.luminance && environment.background==c.sky.background,"%s: the sky lights as without a background",c.name)
        testing.expectf(t,(core.problem_find(&problems,e,"render.sky_background")!=nil)==c.problem,"%s: a problem: %d",c.name,problems.count)
    }
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

// A Sky whose material has a Sky program gives the renderer that program with
// the values the material stores, in place of its image, and the one it
// changes from too. A material that draws no sky, or one a lit atmosphere
// hides, is a problem of the Sky that says what to do.
@(test)
a_sky_material_gives_its_program_and_reports_one_that_draws_no_sky :: proc(t:^testing.T) {
    root:=base.test_folder(t,"sky-material")
    if root=="" {return}
    track:mem.Tracking_Allocator
    mem.tracking_allocator_init(&track,context.allocator)
    defer mem.tracking_allocator_destroy(&track)
    context.allocator=mem.tracking_allocator(&track)
    {
        types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
        Saved :: struct {program:string,glow:f64}
        saved:=[4]Saved{{"Dusk",3},{"Grade",0},{"",0},{"Missing",0}}
        for m,i in saved {
            info:=asset.MATERIAL_DEFAULTS
            asset.text_set(info.program[:],m.program)
            stored:[1]asset.Material_Parameter
            asset.text_set(stored[0].name[:],"glow")
            stored[0].kind,stored[0].components,stored[0].value=.Float,1,{m.glow,0,0,0}
            desc:=asset.Material_Desc{id={7,u64(i)},info=info}
            if m.glow>0 {desc.parameters=stored[:]}
            testing.expect_value(t,asset.material_save(fmt.tprintf("%s/m%d.mat",root,i),&types,desc),asset.Error.None)
        }
        f:=new(Sync_Fixture);defer free(f)
        if !sync_fixture_init(t,f,root) {return}
        defer sync_fixture_destroy(f)
        text:=fmt.tprintf(`{{"version":%d,"programs":[{{"id":1,"name":"Grade","domain":"Postprocess","size":0,"parameters":[]}},{{"id":2,"name":"Dusk","domain":"Sky","size":16,"parameters":[{{"name":"zenith","kind":"Float","components":3,"offset":0,"defaults":[0.1,0.2,0.3,0]}},{{"name":"glow","kind":"Float","components":1,"offset":12,"defaults":[1,0,0,0],"max":8}}]}}]}}`,abi.SHADER_CATALOG_VERSION)
        parsed,valid:=gpu.program_catalog_parse(transmute([]u8)text)
        if !testing.expect(t,valid,"the catalog is read") {return}
        f.renderer.programs=parsed
        f.renderer.programs.loaded=true
        host.assets_programs_refresh(&f.assets)

        e:=core.create(&f.world.entities)
        core.add(&f.world.skies,e,Sky{luminance={2000,2000,2000},material={7,0},from={luminance={10,10,10},material={7,0}},fade=0.25})
        problems:core.Problems
        frame :: proc(f:^Sync_Fixture,problems:^core.Problems) {
            problems^={}
            test_world_settle(&f.world)
            world_sync(&f.world,&f.sync,&f.app,{},problems=problems)
        }
        frame(f,&problems)
        given:=f.renderer.scene.environment
        testing.expectf(t,given.sky_program.program==2 && given.sky==[3]f32{2000,2000,2000},"the Sky program draws the sky: program %d",given.sky_program.program)
        testing.expect(t,given.sky_program.params[0]==gpu.Vec4{0.1,0.2,0.3,3},"its defaults, and the glow the material stores")
        testing.expect(t,given.sky_from_program==given.sky_program && given.sky_from_weight==0.25,"what it changes from is drawn by its program too")
        testing.expect_value(t,problems.count,0)

        Case :: struct {name:string,sky:Sky,sunlit:bool,says:string}
        cases:=[]Case{
            {"a PostProcess program",{luminance={1,1,1},material={7,1}},false,"not a Sky program"},
            {"no program",{luminance={1,1,1},material={7,2}},false,"names no program"},
            {"a program the project lacks",{luminance={1,1,1},material={7,3}},false,"//! mirai sky Missing"},
            {"a material that does not load",{luminance={1,1,1},material={7,9}},false,"does not load"},
            {"under a lit atmosphere",{luminance={1,1,1},material={7,0},atmosphere=true},true,"turn atmosphere off"},
        }
        for c in cases {
            said:core.Problems
            environment:=sky_environment(e,c.sky,true,c.sunlit,core.read(&f.world.worlds),&f.assets,&said)
            found:=core.problem_find(&said,e,"render.sky_material")
            text:=base.text_get(found.text[:]) if found!=nil else ""
            testing.expectf(t,strings.contains(text,c.says),"%s: %q",c.name,text)
            testing.expectf(t,(environment.sky_program.program!=0)==c.sunlit,"%s: only a material that has a Sky program gives one: %d",c.name,environment.sky_program.program)
        }
    }
    testing.expectf(t,len(track.allocation_map)==0,"%d allocations are left after the fixture is gone",len(track.allocation_map))
}
