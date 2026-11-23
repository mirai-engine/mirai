package effect

import "core:fmt"
import "core:math"
import "core:testing"
import "mirai:asset"
import "mirai:std/base"
import "mirai:std/serial"

@(test)
particle_effects_keep_their_values_parameters_hidden_fields_and_assets :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    info:=PARTICLE_DEFAULTS
    info.rate,info.render,info.material,info.sub_particle,info.trigger=120,.Ribbon,{3,4},{5,6},.Death
    info.bursts[1]={time=0.5,count=9,cycles=2,interval=0.1}
    info.velocity={{-1,2,0},{1,3,0}}
    info.size_over_life.values[1]=0.25
    base.text_set(info.program[:],"Swirl")
    hidden:[2]Particle_Field
    base.text_set(hidden[0].name[:],"noise")
    base.text_set(hidden[1].name[:],"bursts")
    parameters:[3]Particle_Parameter
    base.text_set(parameters[0].name[:],"radius")
    parameters[0].kind,parameters[0].components,parameters[0].value=.Float,1,{2.5,0,0,0}
    base.text_set(parameters[1].name[:],"pattern")
    parameters[1].kind,parameters[1].components,parameters[1].texture=.Texture,1,{9,10}
    path:=fmt.tprintf("%s/spark.particle",base.test_folder(t,"effect"))
    parameters[2]=parameters[0]
    parameters[2].layer=1
    layers:=[2]Particle_Info{particle_preset(.Fire),particle_preset(.Smoke)}
    testing.expect_value(t,particle_save(path,&types,{
        id={7,8},info=info,layers=layers[:],parameters=parameters[:],hidden=hidden[:],
    }),asset.Error.None)

    a:asset.Asset
    testing.expect_value(t,asset.asset_load(&a,path),asset.Error.None)
    defer asset.asset_close(&a)
    view,error:=particle_view(&a,&types)
    testing.expect_value(t,error,asset.Error.None)
    testing.expect(t,view.info==info)
    testing.expect(t,len(view.layers)==2 && view.layers[0]==layers[0] && view.layers[1]==layers[1])
    testing.expect(t,len(view.hidden)==2 && serial.text_field(view.hidden[1].name[:])=="bursts")
    testing.expect(t,particle_hidden(view.hidden,"noise") && !particle_hidden(view.hidden,"rate"))
    testing.expect(t,len(view.parameters)==3 && view.parameters[0]==parameters[0])
    testing.expect(t,particle_parameter_find(view.parameters,"radius",1)==&view.parameters[2])
    found:=particle_parameter_find(view.parameters,"pattern")
    testing.expect(t,found!=nil && found.texture==base.Asset_Id{9,10})
    testing.expect_value(t,len(a.dependencies),3) // its material, its sub particle and the texture of a parameter
    testing.expect_value(t,a.blob.header.kind_version,u16(PARTICLE_VERSION))

    bad:=info
    bad.rate=math.nan_f32()
    testing.expect_value(t,particle_save(path,&types,{id={7,8},info=bad}),asset.Error.Invalid)
}

@(test)
an_effect_of_another_version_asks_to_be_written_again :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    doc:asset.Document
    info:=PARTICLE_DEFAULTS
    testing.expect_value(t,particle_document(&doc,&types,{id={1,2},info=info}),asset.Error.None)
    doc.kind_version=PARTICLE_VERSION-1
    path:=fmt.tprintf("%s/old.particle",base.test_folder(t,"effect"))
    testing.expect_value(t,asset.document_save(&doc,path),asset.Error.None)
    asset.document_destroy(&doc)
    a:asset.Asset
    testing.expect_value(t,asset.asset_load(&a,path),asset.Error.None)
    defer asset.asset_close(&a)
    _,error:=particle_view(&a,&types)
    testing.expect_value(t,error,asset.Error.Version)
}

@(test)
invalid_effects_say_which_field_and_how_to_correct_it :: proc(t:^testing.T) {
    Case :: struct {change:proc(p:^Particle_Info),field:string}
    cases:=[?]Case{
        {proc(p:^Particle_Info) {p.speed[1]=math.inf_f32(1)},"speed"},
        {proc(p:^Particle_Info) {p.shell=2},"shell"},
        {proc(p:^Particle_Info) {p.size_over_life.times[2]=0.1},"size_over_life"},
        {proc(p:^Particle_Info) {p.color_over_life.times[0]=-1},"color_over_life"},
        {proc(p:^Particle_Info) {p.size_over_life.values[3]=-1},"size_over_life"},
        {proc(p:^Particle_Info) {p.render=Particle_Render(9)},"render"},
        {proc(p:^Particle_Info) {p.emission_mode=asset.Emission_Mode(7)},"emission_mode"},
        {proc(p:^Particle_Info) {p.bursts[3].interval=-1},"bursts"},
        {proc(p:^Particle_Info) {p.render,p.sort,p.meshes[0],p.meshes[2]=.Mesh,true,{1,2},{3,4}},"sort"},
        {proc(p:^Particle_Info) {p.mesh_weights[1]=-1},"mesh_weights"},
        {proc(p:^Particle_Info) {p.facing=Particle_Facing(5)},"facing"},
        {proc(p:^Particle_Info) {p.lifetime={0,0}},"lifetime"},
        {proc(p:^Particle_Info) {p.blend=Particle_Blend(3)},"blend"},
        {proc(p:^Particle_Info) {p.ribbon_axis=Particle_Ribbon_Axis(2)},"ribbon_axis"},
        {proc(p:^Particle_Info) {p.scale.y=-1},"scale"},
        {proc(p:^Particle_Info) {p.ribbon_tile=-0.5},"ribbon_tile"},
    }
    for c in cases {
        info:=PARTICLE_DEFAULTS
        c.change(&info)
        problem:=particle_validate({info=info})
        testing.expect_value(t,problem.field,c.field)
        testing.expect(t,problem.message!="")
    }
    info:=PARTICLE_DEFAULTS
    testing.expect_value(t,particle_validate({info=info}).message,"")
    // A scale left at 0 on an axis keeps that axis.
    info.scale={0,2,0}
    testing.expect_value(t,particle_scale(&info),[3]f32{1,2,1})
    info.scale=PARTICLE_DEFAULTS.scale
    // A mesh blends as its material does; only a ribbon has an axis and a tile.
    info.render=.Mesh
    testing.expect(t,!particle_field_applies(&info,"blend") && particle_field_applies(&info,"facing") && !particle_field_applies(&info,"ribbon_tile"))
    info.render=.Ribbon
    testing.expect(t,particle_field_applies(&info,"blend") && particle_field_applies(&info,"ribbon_axis") && !particle_field_applies(&info,"facing"))
    info.render=PARTICLE_DEFAULTS.render
    // Some particles of a range may die as they are born.
    info.lifetime={0,2}
    testing.expect_value(t,particle_validate({info=info}).message,"")
    info.lifetime=PARTICLE_DEFAULTS.lifetime

    parameters:[2]Particle_Parameter
    base.text_set(parameters[0].name[:],"count")
    parameters[0].kind,parameters[0].components,parameters[0].value=.Uint,1,{-1,0,0,0}
    testing.expect_value(t,particle_validate({info=info,parameters=parameters[:1]}).field,"parameters")
    parameters[0].value={3,0,0,0}
    parameters[1]=parameters[0]
    testing.expect_value(t,particle_validate({info=info,parameters=parameters[:1]}).message,"")
    testing.expect_value(t,particle_validate({info=info,parameters=parameters[:]}).field,"parameters")
}

@(test)
particle_values_are_named_by_their_paths :: proc(t:^testing.T) {
    found :: proc(path:string) -> (Particle_Value,bool) {return particle_value_find(base.name_hash(path))}
    rate,has_rate:=found("rate")
    testing.expect(t,has_rate && rate.offset==offset_of(Particle_Info,rate) && rate.kind==.Float && rate.top=="rate")
    color,has_color:=found("colors.1")
    testing.expect(t,has_color && color.offset==offset_of(Particle_Info,colors)+16 && color.size==16 && color.top=="colors")
    count,has_count:=found("bursts.2.count")
    testing.expect(t,has_count && count.offset==offset_of(Particle_Info,bursts)+2*size_of(Particle_Burst)+offset_of(Particle_Burst,count) && count.kind==.Integer)
    keys,has_keys:=found("color_over_life.colors.7")
    testing.expect(t,has_keys && keys.size==16)
    key,has_key:=found("size_over_life.values.5")
    testing.expect(t,has_key && key.offset==offset_of(Particle_Info,size_over_life)+5*4 && key.size==4)
    velocity,has_velocity:=found("velocity.1")
    testing.expect(t,has_velocity && velocity.size==12 && velocity.top=="velocity")
    material,has_material:=found("material")
    testing.expect(t,has_material && material.kind==.Asset)
    _,missing:=found("colors")
    testing.expect(t,!missing)
    _,program:=found("program")
    testing.expect(t,!program)
    at,has_at:=particle_value_at("bursts.2.count")
    testing.expect(t,has_at && at.offset==count.offset && at.path=="bursts.2.count")
    _,unknown:=particle_value_at("bursts.9.count")
    testing.expect(t,!unknown)
    for value in particle_fields() {testing.expect(t,value.size<=PARTICLE_VALUE_BYTES)}
}

@(test)
curves_and_gradients_accept_short_key_lists :: proc(t:^testing.T) {
    info:=PARTICLE_DEFAULTS
    info.size_over_life={times={1=0.4},values={0=1,1=2}}
    info.color_over_life={times={1=0.2,2=0.8},colors={0={1,0,0,1},1={1,1,0,1}}}
    testing.expect(t,particle_check({info=info}))
    testing.expect_value(t,particle_key_count(info.size_over_life.times[:]),2)
    testing.expect_value(t,particle_key_count(info.color_over_life.times[:]),3)
    info.color_over_life.times[1]=0.9
    testing.expect(t,!particle_check({info=info}))
}


@(test)
starter_presets_have_valid_motion_and_look :: proc(t:^testing.T) {
    for preset in Particle_Preset {
        info:=particle_preset(preset)
        testing.expect(t,particle_check({info=info}))
        testing.expect(t,info.rate>0 || info.bursts[0].count>0 || info.rate_over_distance>0)
    }
    beam:=particle_preset(.Beam)
    testing.expect(t,beam.render==.Beam && beam.beam_end!={} && beam.beam_arc!=0)
}
