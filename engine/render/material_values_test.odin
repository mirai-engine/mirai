package render

import "core:testing"
import "mirai:std/base"

@(test)
each_writer_of_material_values_changes_only_the_names_it_gives :: proc(t:^testing.T) {
    o:=MATERIAL_VALUES_DEFAULT
    emission,strength,offset:=base.name_hash("emission"),base.name_hash("strength"),base.name_hash("noise_offset")
    // One function owns the emission of slot 1, another the parameters of slot 0.
    testing.expect(t,material_value(&o,"emission",[3]f32{2,2,2},1))
    testing.expect(t,material_value(&o,"strength",0.5) && material_value(&o,offset,{0.25,0.75,0,0}))
    testing.expect(t,material_value(&o,strength,{0.1,0,0,0}),"a name set again keeps its place")
    testing.expect_value(t,o.count,u32(3))
    testing.expect_value(t,o.values[material_value_find(&o,1,emission)],[4]f32{2,2,2,0})
    testing.expect_value(t,o.values[material_value_find(&o,0,strength)],[4]f32{0.1,0,0,0})
    testing.expect_value(t,material_value_find(&o,0,emission),-1)
    testing.expect(t,material_values_slot(&o,0) && material_values_slot(&o,1) && !material_values_slot(&o,2))

    material_value_drop(&o,"strength")
    testing.expect_value(t,material_value_find(&o,0,strength),-1)
    testing.expect_value(t,o.values[material_value_find(&o,1,emission)],[4]f32{2,2,2,0})
    testing.expect_value(t,o.values[material_value_find(&o,0,offset)],[4]f32{0.25,0.75,0,0})
    material_value_drop(&o,strength)
    testing.expect_value(t,o.count,u32(2))

    // Full, it refuses a new name, and still takes those it has; an invalid slot and a value that is not finite are refused.
    for i in o.count..<MATERIAL_VALUES_CAPACITY {testing.expect(t,material_value(&o,u64(i)+1,{},2))}
    testing.expect(t,!material_value(&o,"strength",1))
    testing.expect(t,material_value(&o,"emission",[3]f32{3,3,3},1))
    material_value_drop(&o,"emission",1)
    testing.expect(t,!material_value(&o,"strength",1,MATERIAL_SLOTS) && !material_value(&o,"strength",1,-1))
    nan:=f32(0);nan/=nan
    testing.expect(t,!material_value(&o,"strength",nan) && !material_value(&o,"strength",[4]f32{0,max(f32)*2,0,0}))
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
        {"ior",true},{"transmission",true},{"alpha_mode",true},{"coat",true},{"unlit",true},{"emission_mode",true},{"specular",true},
    }
    for c in cases {
        o:=MATERIAL_VALUES_DEFAULT
        testing.expect(t,material_value(&o,c.name,0.5,1))
        testing.expectf(t,material_values_slot(&o,1) && material_values_slot(&o,1,true)==c.row && !material_values_slot(&o,0,true),"%s",c.name)
        testing.expect(t,!material_values_plain(&o) && !material_values_unnamed(&o))
        _,instanced:=material_value_instanced(base.name_hash(c.name))
        testing.expectf(t,!(instanced && c.row),"%s",c.name)
    }
    o:=MATERIAL_VALUES_DEFAULT
    testing.expect(t,material_values_plain(&o) && material_values_unnamed(&o))
    o.color.g=0.5
    testing.expect(t,!material_values_plain(&o) && material_values_unnamed(&o),"a color is no name")
    testing.expect(t,material_texture_shown(&o,"maps.emission",7,2) && material_values_slot(&o,2,true) && !material_values_unnamed(&o))
    testing.expect(t,material_texture_shown(&o,"maps.emission",9,2) && o.texture_count==1 && o.shown[0]==9,"a texture given again takes its place")
    for i in 1..<MATERIAL_VALUES_TEXTURES {testing.expect(t,material_texture_shown(&o,"maps.normal",1,i%MATERIAL_SLOTS))}
    other:=MATERIAL_VALUES_DEFAULT
    testing.expect(t,!material_texture_shown(&o,"maps.coat",1) && !material_texture_shown(&other,"maps.coat",1,MATERIAL_SLOTS))
}

// What a frame gives an entity goes over its own: its color times, its light
// plus, and each name in place of the same.
@(test)
values_given_over_those_of_an_entity_compose_with_them :: proc(t:^testing.T) {
    own:=Material_Values{color={0.5,1,1,0.5},emission={1,0,0}}
    testing.expect(t,material_value(&own,"roughness",0.2) && material_value(&own,"metallic",1,1))
    over:=MATERIAL_VALUES_DEFAULT
    over.emission={0,2,0}
    testing.expect(t,material_value(&over,"roughness",0.9) && material_value(&over,"emission",[3]f32{4,4,4},2) && material_texture_shown(&over,"maps.base_color",5,2))
    material_values_over(&own,&over)
    testing.expect_value(t,own.color,[4]f32{0.5,1,1,0.5})
    testing.expect_value(t,own.emission,[3]f32{1,2,0})
    testing.expect_value(t,own.count,u32(3))
    testing.expect_value(t,own.values[material_value_find(&own,0,base.name_hash("roughness"))].x,f32(0.9))
    testing.expect_value(t,own.values[material_value_find(&own,1,base.name_hash("metallic"))].x,f32(1))
    testing.expect(t,own.texture_count==1 && own.shown[0]==5 && own.texture_slots[0]==2)
}
