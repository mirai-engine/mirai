package render

import "core:reflect"
import "core:strings"
import "core:testing"
import "mirai:host"
import gpu "mirai:render"
import "mirai:std/base"

@(test)
each_writer_of_material_values_changes_only_the_names_it_gives :: proc(t:^testing.T) {
    o:=MATERIAL_VALUES_DEFAULT
    emission,strength,offset:=base.name_hash("emission"),base.name_hash("strength"),base.name_hash("noise_offset")
    // One function owns the emission of slot 1, another the parameters of slot 0.
    testing.expect(t,material_value(&o,"emission",{2,2,2,0},1))
    testing.expect(t,material_value(&o,"strength",0.5) && material_value(&o,offset,{0.25,0.75,0,0}))
    testing.expect(t,material_value(&o,strength,{0.1,0,0,0}),"a name set again keeps its place")
    testing.expect_value(t,o.count,u32(3))
    testing.expect_value(t,o.values[material_value_find(&o,1,emission)],[4]f32{2,2,2,0})
    testing.expect_value(t,o.values[material_value_find(&o,0,strength)],[4]f32{0.1,0,0,0})
    testing.expect_value(t,material_value_find(&o,0,emission),-1)
    testing.expect(t,material_values_slot(&o,0) && material_values_slot(&o,1) && !material_values_slot(&o,2))

    material_value_drop(&o,strength)
    testing.expect_value(t,material_value_find(&o,0,strength),-1)
    testing.expect_value(t,o.values[material_value_find(&o,1,emission)],[4]f32{2,2,2,0})
    testing.expect_value(t,o.values[material_value_find(&o,0,offset)],[4]f32{0.25,0.75,0,0})
    material_value_drop(&o,strength)
    testing.expect_value(t,o.count,u32(2))

    // Full, it refuses a new name, and still takes those it has; an invalid slot and a value that is not finite are refused.
    for i in o.count..<MATERIAL_VALUES_CAPACITY {testing.expect(t,material_value(&o,u64(i)+1,{},2))}
    testing.expect(t,!material_value(&o,"strength",1))
    testing.expect(t,material_value(&o,"emission",{3,3,3,0},1))
    material_value_drop(&o,emission,1)
    testing.expect(t,!material_value(&o,"strength",1,MATERIAL_SLOTS) && !material_value(&o,"strength",1,-1))
    nan:=f32(0);nan/=nan
    testing.expect(t,!material_value(&o,"strength",nan) && !material_value(&o,"strength",{0,max(f32)*2,0,0}))
    testing.expect(t,material_value(&o,"strength",1))
}

// What makes an entity show a row of its own and what its instance holds:
// a value of the standard model the instance holds, or one a program may
// have, asks for no row; a texture, or a value that changes how the surface
// is drawn, does.
@(test)
only_what_changes_how_a_surface_is_drawn_asks_for_a_row :: proc(t:^testing.T) {
    Case :: struct {name:string,row:bool}
    cases:=[?]Case{
        {"base_color",false},{"opacity",false},{"metallic",false},{"roughness",false},{"emission",false},
        {"dissolve",false},{"progress",false},
        {"specular",false},{"coat",false},{"anisotropy_rotation",false},{"unlit",false},{"emission_mode",false},
        {"ior",true},{"transmission",true},{"alpha_mode",true},
    }
    for c in cases {
        o:=MATERIAL_VALUES_DEFAULT
        testing.expect(t,material_value(&o,c.name,0.5,1))
        testing.expectf(t,material_values_slot(&o,1) && material_values_slot(&o,1,true)==c.row && !material_values_slot(&o,0,true),"%s",c.name)
        testing.expect(t,!material_values_plain(&o))
        _,instanced:=material_value_instanced(base.name_hash(c.name))
        testing.expectf(t,!(instanced && c.row),"%s",c.name)
    }
    for field in MATERIAL_VALUE_FIELDS {
        if field.held=={} {continue}
        target,_:=reflect.enum_name_from_value(field.held)
        testing.expectf(t,strings.to_lower(target,context.temp_allocator)==field.name,"%s is held as %s",field.name,target)
    }
    o:=MATERIAL_VALUES_DEFAULT
    testing.expect(t,material_values_plain(&o))
    o.color.g=0.5
    testing.expect(t,!material_values_plain(&o) && !material_values_slot(&o,0),"a color is of no slot")
    emission,normal:=base.name_hash("maps.emission"),base.name_hash("maps.normal")
    testing.expect(t,material_texture(&o,emission,2,{},7) && material_values_slot(&o,2,true))
    testing.expect(t,material_texture(&o,emission,2,{},9) && o.texture_count==1 && o.shown[0]==9,"a texture given again takes its place")
    for i in 1..<MATERIAL_VALUES_TEXTURES {testing.expect(t,material_texture(&o,normal,i%MATERIAL_SLOTS,{3,3}))}
    testing.expect(t,!material_texture(&o,base.name_hash("maps.coat"),0,{3,3}) && !material_texture(&o,emission,MATERIAL_SLOTS,{3,3}))
    material_texture_drop(&o,emission,2)
    _,kept:=material_texture_of(&o,2,emission)
    testing.expect(t,o.texture_count==MATERIAL_VALUES_TEXTURES-1 && !kept && material_texture(&o,base.name_hash("maps.coat"),0,{3,3}))
}

// What a frame gives an entity goes over its own: its color times, its light
// plus, and each name in place of the same.
@(test)
values_given_over_those_of_an_entity_compose_with_them :: proc(t:^testing.T) {
    own:=Material_Values{color={0.5,1,1,0.5},emission={1,0,0}}
    testing.expect(t,material_value(&own,"roughness",0.2) && material_value(&own,"metallic",1,1))
    over:=MATERIAL_VALUES_DEFAULT
    over.emission={0,2,0}
    testing.expect(t,material_value(&over,"roughness",0.9) && material_value(&over,"emission",{4,4,4,0},2) && material_texture(&over,base.name_hash("maps.base_color"),2,{},5))
    material_values_over(&own,&over)
    testing.expect_value(t,own.color,[4]f32{0.5,1,1,0.5})
    testing.expect_value(t,own.emission,[3]f32{1,2,0})
    testing.expect_value(t,own.count,u32(3))
    testing.expect_value(t,own.values[material_value_find(&own,0,base.name_hash("roughness"))].x,f32(0.9))
    testing.expect_value(t,own.values[material_value_find(&own,1,base.name_hash("metallic"))].x,f32(1))
    testing.expect(t,own.texture_count==1 && own.shown[0]==5 && own.texture_slots[0]==2)
}

// What shows a row through an instance without drawing it (the rectangle a
// screen lights) is given the row with the values the instance holds for it:
// the same row their values give derived from its material.
@(test)
the_values_an_instance_holds_give_the_row_they_derive :: proc(t:^testing.T) {
    root:=base.test_folder(t,"values-held")
    if root=="" {return}
    a:host.Assets
    if !testing.expect(t,host.assets_init(&a,{root=root,capacity=8})) {return}
    defer host.assets_destroy(&a)
    material:=gpu.DEFAULT_MATERIAL
    material.roughness=0.8
    row,derived:=host.assets_material_derive(&a,material)
    if !testing.expect(t,derived) {return}
    held:gpu.Instance_Material_Values
    held.entries[0]=gpu.instance_material_value(row,gpu.Instance_Material_Value_Target.Emission,{40,20,10,0})
    held.entries[1]=gpu.instance_material_value(row,gpu.Instance_Material_Value_Target.Base_Color,{0,0,0,0})
    held.entries[2]=gpu.instance_material_value(row+1,gpu.Instance_Material_Value_Target.Roughness,{0.1,0,0,0})
    held.count=3
    expected:=material
    testing.expect(t,material_value_apply(&expected,nil,base.name_hash("emission"),{40,20,10,0}) && material_value_apply(&expected,nil,base.name_hash("base_color"),{}))
    want,_:=host.assets_material_derive(&a,expected)
    shown:=material_row_held(&a,row,&held)
    testing.expect(t,shown!=row && shown==want,"the values for the row, and not those for another")
    testing.expect_value(t,material_row_held(&a,row,&gpu.Instance_Material_Values{}),row)
}
