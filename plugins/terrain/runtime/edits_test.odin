package terrain

import "core:fmt"
import "core:math"
import "core:testing"
import "mirai:asset"
import "mirai:std/base"
import mm "mirai:std/math"

@(private="file")
edits_source :: proc(t:^testing.T,s:^Source) {
    testing.expect(t,source_make(s,.Heightfield,{33,1,33},1,16))
    testing.expect(t,grid_prepare(&s.field,{},{32,0,32},s.allocator))
    for z in 0..<33 {for x in 0..<33 {grid_set(&s.field,x,z,f32(x)*0.2+math.sin(f32(z)*0.7))}}
}

@(private="file")
fields_near :: proc(a:^Source,b:^Grid(f32),tolerance:f32) -> bool {
    for z in 0..<33 {for x in 0..<33 {if abs(grid_get(&a.field,x,z)-grid_get(b,x,z))>tolerance {return false}}}
    return true
}

@(test)
edit_layers_hold_what_their_strokes_add_through_hide_show_save_and_remove :: proc(t:^testing.T) {
    s:Source;edits_source(t,&s);defer source_destroy(&s)
    base_field:Grid(f32);defer grid_destroy(&base_field,s.allocator)
    testing.expect(t,grid_clone(&base_field,&s.field,s.allocator))
    layer,added:=source_edit_layer_add(&s)
    if !testing.expect(t,added && layer==0) {return}
    // A stroke on the layer: the field takes it, and the layer what it changed.
    before:Grid(f32);defer grid_destroy(&before,s.allocator)
    testing.expect(t,grid_clone(&before,&s.field,s.allocator))
    change:=source_edit(&s,{kind=.Raise,center={},radius=6,amount=3,falloff=.Constant})
    testing.expect(t,change.changed)
    testing.expect(t,source_edit_layer_take(&s,&before,layer,change.low,change.high))
    raised:Grid(f32);defer grid_destroy(&raised,s.allocator)
    testing.expect(t,grid_clone(&raised,&s.field,s.allocator))
    // A stroke on the base under it stays when the layer hides.
    testing.expect(t,source_edit(&s,{kind=.Lower,center={10,0,10},radius=3,amount=1,falloff=.Constant}).changed)
    testing.expect(t,source_edit_layer_hide(&s,layer,true).changed)
    testing.expect_value(t,grid_get(&s.field,16,16),grid_get(&base_field,16,16))
    testing.expect(t,abs(grid_get(&s.field,26,26)-(grid_get(&base_field,26,26)-1))<1e-5)
    testing.expect(t,source_edit_layer_hide(&s,layer,false).changed)
    testing.expect(t,abs(grid_get(&s.field,16,16)-grid_get(&raised,16,16))<1e-5)
    // Through a file: the layer and what it adds stay.
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    path:=fmt.tprintf("%s/layers.terrain",base.test_folder(t,"terrain"))
    testing.expect_value(t,source_save(&s,path,base.Asset_Id{7,8},&types),asset.Error.None)
    loaded:Source;defer source_destroy(&loaded)
    _,ok:=source_load(&loaded,path,&types)
    if !testing.expect(t,ok) {return}
    testing.expect_value(t,loaded.edit_count,u32(1))
    testing.expect_value(t,grid_get(&loaded.edit_heights[0],16,16),f32(3))
    // Taken out, the field is the base with the stroke on it.
    testing.expect(t,source_edit_layer_remove(&loaded,0).changed)
    testing.expect_value(t,loaded.edit_count,u32(0))
    testing.expect(t,abs(grid_get(&loaded.field,16,16)-grid_get(&base_field,16,16))<=HEIGHT_STEP)
    testing.expect(t,source_edit_layer_remove(&loaded,0).error==.Layer)
    volume:Source;defer source_destroy(&volume)
    testing.expect(t,source_make(&volume,.Volume,{9,9,9},1,4))
    _,added=source_edit_layer_add(&volume)
    testing.expect(t,!added,"a Volume has no edit layers")
}

@(test)
splines_conform_a_bed_that_paints_follows_the_ground_and_gives_back_what_was_under :: proc(t:^testing.T) {
    s:Source;edits_source(t,&s);defer source_destroy(&s)
    testing.expect(t,source_layer_set(&s,1,LAYER_DEFAULT))
    base_field:Grid(f32);defer grid_destroy(&base_field,s.allocator)
    testing.expect(t,grid_clone(&base_field,&s.field,s.allocator))
    base_weights:=grid_get(&s.weights,16,16)
    road :: proc(x:f32) -> (points:[33]mm.Path_Point) {
        for &p,i in points {p={position={x,0,f32(i)-16},width=4}}
        return
    }
    points:=road(0)
    paths:=[1]Conform_Path{{points=points[:],depth=1,sides=2,smooth=100,layer=1}}
    change:=source_conform(&s,paths[:])
    testing.expect(t,change.changed && change.error==.None)
    testing.expect_value(t,s.edit_count,u32(1))
    testing.expect(t,s.edit_layers[0].splines)
    // Across its width the bed is level, a metre under the mean of the ground along its middle.
    bed:=grid_get(&s.field,16,10)
    for x in 14..=18 {testing.expectf(t,abs(grid_get(&s.field,x,10)-bed)<1e-3,"level across at %d",x)}
    mean:=f32(0)
    for z in 0..<33 {mean+=grid_get(&base_field,16,z)/33}
    testing.expectf(t,abs(bed-(mean-1))<1e-3,"the bed lies a metre under the mean of the ground of its middle: %v, not %v",mean-1,bed)
    testing.expect_value(t,grid_get(&s.field,30,10),grid_get(&base_field,30,10))
    testing.expect(t,weights_float(grid_get(&s.weights,16,10))[1]==1,"it paints its layer")
    // Sculpting under it raises the ground its bed follows the next time.
    testing.expect(t,source_edit(&s,{kind=.Raise,center={},radius=40,amount=2,falloff=.Constant}).changed)
    testing.expect(t,source_conform(&s,paths[:]).changed)
    testing.expect(t,abs(grid_get(&s.field,16,10)-(bed+2))<0.05)
    testing.expect(t,source_edit(&s,{kind=.Lower,center={},radius=40,amount=2,falloff=.Constant}).changed)
    // Moved, what it held goes back where it was.
    points=road(8)
    testing.expect(t,source_conform(&s,paths[:]).changed)
    testing.expect(t,abs(grid_get(&s.field,16,10)-grid_get(&base_field,16,10))<1e-4)
    testing.expect_value(t,grid_get(&s.weights,16,10),base_weights)
    testing.expect(t,weights_float(grid_get(&s.weights,24,10))[1]==1)
    // Without splines the ground is the base again, with its weights, and the layer is gone.
    testing.expect(t,source_conform(&s,nil).changed)
    testing.expect(t,fields_near(&s,&base_field,1e-4))
    testing.expect_value(t,grid_get(&s.weights,24,10),base_weights)
    testing.expect(t,grid_none(&s.edit_under))
    testing.expect_value(t,s.edit_count,u32(0))
    // It follows its splines alone: it is not hidden or taken out by hand, and a wrong path changes nothing.
    testing.expect(t,source_conform(&s,paths[:]).changed)
    testing.expect_value(t,source_edit_layer_hide(&s,0,true).error,Edit_Error.Layer)
    testing.expect_value(t,source_edit_layer_remove(&s,0).error,Edit_Error.Layer)
    bad:=paths
    bad[0].layer=3
    testing.expect_value(t,source_conform(&s,bad[:]).error,Edit_Error.Layer)
    testing.expect_value(t,s.edit_count,u32(1))
}
