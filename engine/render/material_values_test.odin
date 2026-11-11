package render

import "core:testing"
import "mirai:asset"
import "mirai:core"
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

// What an entity gives its materials by name, and its fade, are held by its
// instance, which is traced and drawn by them; only a texture makes it show
// a row of its own.
@(test)
only_a_texture_makes_an_entity_show_a_row_of_its_own :: proc(t:^testing.T) {
    f:=new(Sync_Fixture);defer free(f)
    if !sync_fixture_init(t,f) {return}
    defer sync_fixture_destroy(f)
    e:=sync_cube(f,0)
    values:=MATERIAL_VALUES_DEFAULT
    for name in ([]string{"ior","transmission","opacity","roughness","coat","dissolve"}) {testing.expect(t,material_value(&values,name,0.5))}
    core.add(&f.world.values,e,values)
    sync_frame(f)
    s:=&f.renderer.scene
    testing.expect(t,f.assets.stats.derived==0 && s.instances[0].material_values!=0 && len(s.translucent)==1,"its transmission makes the instance glass")
    testing.expect(t,material_value(core.edit(&f.world.values,e),"transmission",0))
    sync_frame(f)
    testing.expect(t,f.assets.stats.derived==0 && len(s.translucent)==0)
    core.edit(&f.world.values,e).color.a=0.5
    sync_frame(f)
    testing.expect(t,f.assets.stats.derived==0 && len(s.translucent)==1,"a fade blends the instance, and derives no row")
    testing.expect(t,material_value(core.edit(&f.world.values,e),"alpha_mode",f32(asset.Alpha_Mode.Mask)))
    sync_frame(f)
    testing.expect(t,f.assets.stats.derived==0 && len(s.translucent)==0,"a masked one stays masked as it fades")
    core.edit(&f.world.values,e).live.screen={texture=7}
    sync_frame(f)
    testing.expect_value(t,f.assets.stats.derived,1)
}

// The names an entity gives a slot, and the textures it gives and takes away.
@(test)
values_and_textures_are_of_their_slot :: proc(t:^testing.T) {
    o:=MATERIAL_VALUES_DEFAULT
    testing.expect(t,material_values_plain(&o))
    o.color.g=0.5
    testing.expect(t,!material_values_plain(&o) && !material_values_slot(&o,0),"a color is of no slot")
    emission,normal:=base.name_hash("maps.emission"),base.name_hash("maps.normal")
    testing.expect(t,material_texture(&o,emission,2,{7,7}) && material_values_slot(&o,2))
    testing.expect(t,material_texture(&o,emission,2,{9,9}) && o.texture_count==1 && o.textures[0]==base.Asset_Id{9,9},"a texture given again takes its place")
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
    testing.expect(t,material_value(&over,"roughness",0.9) && material_value(&over,"emission",{4,4,4,0},2) && material_texture(&over,base.name_hash("maps.base_color"),2,{5,5}))
    material_values_over(&own,&over)
    testing.expect_value(t,own.color,[4]f32{0.5,1,1,0.5})
    testing.expect_value(t,own.emission,[3]f32{1,2,0})
    testing.expect_value(t,own.count,u32(3))
    testing.expect_value(t,own.values[material_value_find(&own,0,base.name_hash("roughness"))].x,f32(0.9))
    testing.expect_value(t,own.values[material_value_find(&own,1,base.name_hash("metallic"))].x,f32(1))
    testing.expect(t,own.texture_count==1 && own.textures[0]==base.Asset_Id{5,5} && own.texture_slots[0]==2)
}

// What shows a row through an instance without drawing it (the rectangle a
// screen lights) is given the row with what the entity gives its slot: the
// row those values derive from its material, and the row itself without any.
@(test)
a_light_that_shows_the_row_of_an_instance_is_given_it_with_its_values :: proc(t:^testing.T) {
    f:=new(Sync_Fixture);defer free(f)
    if !sync_fixture_init(t,f) {return}
    defer sync_fixture_destroy(f)
    e:=sync_cube(f,0)
    core.add(&f.world.rects,e,RECT_LIGHT_DEFAULT)
    core.add(&f.world.emissions,e,Light_Emission{})
    sync_frame(f)
    s:=&f.renderer.scene
    if !testing.expect_value(t,len(s.lights),1) {return}
    plain:=transmute(u32)s.lights[0].size.w
    values:=MATERIAL_VALUES_DEFAULT
    testing.expect(t,material_value(&values,"emission",{40,20,10,0}))
    core.add(&f.world.values,e,values)
    sync_frame(f)
    shown:=transmute(u32)s.lights[0].size.w
    testing.expect(t,shown!=plain && host.assets_material_values(&f.assets,shown).emission==[3]f32{40,20,10},"the row its values derive")
    core.remove(&f.world.values,e)
    sync_frame(f)
    testing.expect_value(t,transmute(u32)s.lights[0].size.w,plain)
}

// What a step gives an entity at run time is live over what the entity
// authors: a value wins over the authored one of its name and leaves it as
// it was, a screen shows in its slot, and an entity without the component
// takes it only in a world that plays.
@(test)
what_is_live_goes_over_what_an_entity_authors_and_leaves_it :: proc(t:^testing.T) {
    f:=new(Sync_Fixture);defer free(f)
    if !sync_fixture_init(t,f) {return}
    defer sync_fixture_destroy(f)
    w:=&f.world
    authored,bare:=sync_cube(f,0),sync_cube(f,2)
    own:=MATERIAL_VALUES_DEFAULT
    roughness:=base.name_hash("roughness")
    testing.expect(t,material_value(&own,roughness,{0.2,0,0,0}))
    core.add(&w.values,authored,own)
    test_world_settle(w)
    shown :: proc(f:^Sync_Fixture,e:core.Entity) -> (look:Material_Values,desc:gpu.Material_Desc) {
        test_world_settle(&f.world)
        look,_=core.get(&f.world.values,e)
        desc=gpu.DEFAULT_MATERIAL
        material_values_apply(&f.assets,&desc,&look,0)
        return
    }
    testing.expect(t,material_live(&w.values,bare,false)==nil,"a step authors nothing")
    live:=material_live(&w.values,authored,false)
    if !testing.expect(t,live!=nil && material_value(live,roughness,{0.9,0,0,0})) {return}
    live.screen={texture=9,lit=true,emission=200}
    look,desc:=shown(f,authored)
    testing.expect(t,desc.roughness==0.9 && desc.textures[.Emission]==9 && desc.base_color==[3]f32{} && desc.emission==[3]f32{200,200,200})
    testing.expect(t,material_values_slot(&look,0) && material_values_plain(&look)==material_values_plain(&own))
    look.live={}
    testing.expect(t,look==own,"what it authors is as it was")
    live=material_live(&w.values,authored,false)
    material_value_drop(live,roughness)
    live.screen={}
    look,desc=shown(f,authored)
    testing.expect(t,look==own && desc.roughness==0.2 && desc.textures[.Emission]==0,"without them its own show again")
    testing.expect(t,material_live(&w.values,bare,true)!=nil)
    test_world_settle(w)
    testing.expect(t,core.has(&w.values,bare),"in a world that plays the entity takes the component")
}
