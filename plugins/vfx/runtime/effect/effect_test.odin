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
    parameters:[2]Particle_Parameter
    base.text_set(parameters[0].name[:],"radius")
    parameters[0].kind,parameters[0].components,parameters[0].value=.Float,1,{2.5,0,0,0}
    base.text_set(parameters[1].name[:],"pattern")
    parameters[1].kind,parameters[1].components,parameters[1].texture=.Texture,1,{9,10}
    path:=fmt.tprintf("%s/spark.particle",base.test_folder(t,"effect"))
    testing.expect_value(t,particle_save(path,&types,{id={7,8},info=info,parameters=parameters[:],hidden=hidden[:]}),asset.Error.None)

    a:asset.Asset
    testing.expect_value(t,asset.asset_load(&a,path),asset.Error.None)
    defer asset.asset_close(&a)
    view,error:=particle_view(&a,&types)
    testing.expect_value(t,error,asset.Error.None)
    testing.expect(t,view.info^==info)
    testing.expect(t,len(view.hidden)==2 && serial.text_field(view.hidden[1].name[:])=="bursts")
    testing.expect(t,particle_hidden(view.hidden,"noise") && !particle_hidden(view.hidden,"rate"))
    testing.expect(t,len(view.parameters)==2 && view.parameters[0]==parameters[0])
    found:=particle_parameter_find(view.parameters,"pattern")
    testing.expect(t,found!=nil && found.texture==base.Asset_Id{9,10})
    testing.expect_value(t,len(a.dependencies),3) // its material, its sub particle and the texture of a parameter
    testing.expect_value(t,a.blob.header.kind_version,u16(VERSION))

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
    doc.kind_version=VERSION-1
    path:=fmt.tprintf("%s/old.particle",base.test_folder(t,"effect"))
    testing.expect_value(t,asset.document_save(&doc,path),asset.Error.None)
    asset.document_destroy(&doc)
    a:asset.Asset
    testing.expect_value(t,asset.asset_load(&a,path),asset.Error.None)
    defer asset.asset_close(&a)
    _,error:=particle_view(&a,&types)
    testing.expect_value(t,error,asset.Error.Version)
}

// The lights of an effect cast shadows only when it asks: not by default;
// one that asks keeps it, and an instance can ask on its own. An effect that
// does not store a field of its version is refused.
@(test)
particle_lights_cast_shadows_only_when_the_effect_asks :: proc(t:^testing.T) {
    testing.expect(t,!PARTICLE_DEFAULTS.light_shadows)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    path:=fmt.tprintf("%s/shadows.particle",base.test_folder(t,"effect"))
    Before :: struct {rate:f32,lights:u32,light_intensity:f32,light_range:f32}
    before:=Before{rate=30,lights=4,light_intensity=10,light_range=2}
    doc:asset.Document
    asset.document_init(&doc,PARTICLE_KIND,{1,2})
    doc.kind_version=VERSION
    _,error:=asset.document_put_row(&doc,&types,"particle",&before)
    testing.expect_value(t,error,asset.Error.None)
    testing.expect_value(t,asset.document_save(&doc,path),asset.Error.None)
    asset.document_destroy(&doc)
    {
        a:asset.Asset
        testing.expect_value(t,asset.asset_load(&a,path),asset.Error.None)
        defer asset.asset_close(&a)
        _,view_error:=particle_view(&a,&types)
        testing.expect_value(t,view_error,asset.Error.Version)
        testing.expect_value(t,a.lacking,[2]string{"particle","duration"})
    }
    info:=PARTICLE_DEFAULTS
    info.lights,info.light_shadows=4,true
    testing.expect_value(t,particle_save(path,&types,{id={1,2},info=info}),asset.Error.None)
    a:asset.Asset
    testing.expect_value(t,asset.asset_load(&a,path),asset.Error.None)
    defer asset.asset_close(&a)
    view,view_error:=particle_view(&a,&types)
    testing.expect(t,view_error==.None && view.info.light_shadows)
    value,found:=particle_value_at("light_shadows")
    testing.expect(t,found && value.kind==.Bool && value.offset==offset_of(Particle_Info,light_shadows))
}

// The facing, spin axis, rotation and scale of the mesh of Mesh particles
// are written and read back as they are; their zeros stand for X, no turn
// and a scale of one.
@(test)
mesh_particles_keep_their_facing_axis_rotation_and_scale :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    info:=PARTICLE_DEFAULTS
    info.render,info.facing,info.spin_axis=.Mesh,.Camera_Plane,{0,0,2}
    info.mesh_rotation,info.mesh_scale={0,0.70710677,0,0.70710677},{0.5,3,0.25}
    path:=fmt.tprintf("%s/blade.particle",base.test_folder(t,"effect"))
    testing.expect_value(t,particle_save(path,&types,{id={3,4},info=info}),asset.Error.None)
    a:asset.Asset
    testing.expect_value(t,asset.asset_load(&a,path),asset.Error.None)
    defer asset.asset_close(&a)
    view,error:=particle_view(&a,&types)
    testing.expect_value(t,error,asset.Error.None)
    if error!=.None {return}
    testing.expect(t,view.info^==info)
    testing.expect_value(t,view.info.facing,Particle_Facing.Camera_Plane)
    testing.expect_value(t,view.info.mesh_scale,[3]f32{0.5,3,0.25})
    for field in ([?]string{"facing","spin_axis","mesh_rotation","mesh_scale"}) {
        _,found:=particle_value_at(field)
        testing.expectf(t,found,"an instance can change %s",field)
    }

    axis,rotation,scale:=particle_mesh_placement(info.spin_axis,info.mesh_rotation,info.mesh_scale)
    testing.expect_value(t,axis,[3]f32{0,0,1})
    testing.expect(t,abs(rotation.y-0.70710677)<1e-6 && abs(rotation.w-0.70710677)<1e-6)
    testing.expect_value(t,scale,info.mesh_scale)
    axis,rotation,scale=particle_mesh_placement({},{},{})
    testing.expect(t,axis==[3]f32{1,0,0} && rotation==[4]f32{0,0,0,1} && scale==[3]f32{1,1,1})

    bad:=info
    bad.mesh_scale.y=math.inf_f32(1)
    testing.expect_value(t,particle_validate({info=&bad}).field,"mesh_scale")
    bad=info
    bad.mesh_rotation.w=math.nan_f32()
    testing.expect_value(t,particle_validate({info=&bad}).field,"mesh_rotation")
    bad=info
    bad.spin_axis.x=math.nan_f32()
    testing.expect_value(t,particle_validate({info=&bad}).field,"spin_axis")
    bad=info
    bad.mesh_scale.z=-1
    testing.expect_value(t,particle_validate({info=&bad}).field,"mesh_scale")
    bad=info
    bad.facing=Particle_Facing(7)
    testing.expect_value(t,particle_validate({info=&bad}).field,"facing")
    testing.expect_value(t,particle_save(path,&types,{id={3,4},info=bad}),asset.Error.Invalid)
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
    }
    for c in cases {
        info:=PARTICLE_DEFAULTS
        c.change(&info)
        problem:=particle_validate({info=&info})
        testing.expect_value(t,problem.field,c.field)
        testing.expect(t,problem.message!="")
    }
    info:=PARTICLE_DEFAULTS
    testing.expect_value(t,particle_validate({info=&info}).message,"")

    parameters:[2]Particle_Parameter
    base.text_set(parameters[0].name[:],"count")
    parameters[0].kind,parameters[0].components,parameters[0].value=.Uint,1,{-1,0,0,0}
    testing.expect_value(t,particle_validate({info=&info,parameters=parameters[:1]}).field,"parameters")
    parameters[0].value={3,0,0,0}
    parameters[1]=parameters[0]
    testing.expect_value(t,particle_validate({info=&info,parameters=parameters[:1]}).message,"")
    testing.expect_value(t,particle_validate({info=&info,parameters=parameters[:]}).field,"parameters")
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
