package terrain

import "core:testing"
import "mirai:std/geom"

@(test)
a_wide_smooth_reaches_past_the_samples_next_to_it :: proc(t:^testing.T) {
    source:Source;testing.expect(t,source_make(&source,.Heightfield,{33,1,33},1,16));defer source_destroy(&source)
    testing.expect(t,source_edit(&source,{kind=.Raise,center={},radius=0.4,amount=1}).changed)
    narrow:=source_value(&source,{16,0,16}) or_else 0
    testing.expect(t,source_edit(&source,{kind=.Smooth,center={},radius=2,amount=1}).changed)
    testing.expect_value(t,source_value(&source,{18,0,16}) or_else 0,f32(0))
    testing.expect(t,(source_value(&source,{16,0,16}) or_else 0)<narrow)
    testing.expect(t,source_edit(&source,{kind=.Raise,center={},radius=0.4,amount=1}).changed)
    testing.expect(t,source_edit(&source,{kind=.Smooth,center={},radius=12,amount=1,falloff=.Constant}).changed)
    testing.expect(t,(source_value(&source,{19,0,16}) or_else 0)>0,"a radius of 12 cells averages 3 samples to each side")
}

@(test)
a_ramp_reaches_the_heights_of_its_ends_along_its_line :: proc(t:^testing.T) {
    source:Source;testing.expect(t,source_make(&source,.Heightfield,{33,1,33},1,16));defer source_destroy(&source)
    // From A at sample (8,16), 2 high, to B at (24,16), 10 high.
    a:=source_point(&source,{8,0,16})+{0,2,0}
    change:=source_edit(&source,{kind=.Ramp,center=a,delta={16,8,0},radius=3,hardness=0.5,amount=1})
    testing.expect(t,change.changed)
    testing.expect_value(t,source_value(&source,{8,0,16}) or_else 0,f32(2))
    testing.expect_value(t,source_value(&source,{16,0,16}) or_else 0,f32(6))
    testing.expect_value(t,source_value(&source,{24,0,16}) or_else 0,f32(10))
    testing.expect_value(t,source_value(&source,{16,0,25}) or_else 0,f32(0))
    testing.expect(t,(source_value(&source,{16,0,17}) or_else 0)==6,"inside the hard part of its width")
    testing.expect(t,(source_value(&source,{16,0,18}) or_else 0)>0 && (source_value(&source,{16,0,18}) or_else 0)<6,"the sides fall off")
    testing.expect_value(t,source_edit(&source,{kind=.Ramp,center=a,delta={16,8,0},radius=3,amount=1}).error,Edit_Error.None)
    volume:Source;testing.expect(t,source_make(&volume,.Volume,{9,9,9},1,8));defer source_destroy(&volume)
    testing.expect_value(t,source_edit(&volume,{kind=.Ramp,center={},delta={2,1,0},radius=1,amount=1}).error,Edit_Error.Kind)
}

@(test)
volume_shapes_join_and_carve_and_a_blend_softens_the_join :: proc(t:^testing.T) {
    source:Source;testing.expect(t,source_make(&source,.Volume,{33,33,33},1,16));defer source_destroy(&source)
    air:=source.cell*SDF_BAND_CELLS
    testing.expect(t,grid_fill_box(&source.field,{},source.field.counts-1,air,source.allocator))
    capsule:=Brush{kind=.Add,shape=.Capsule,center=source_point(&source,{8,16,16}),delta={16,0,0},radius=3,amount=1}
    testing.expect(t,source_edit(&source,capsule).changed)
    testing.expect(t,(source_value(&source,{16,16,16}) or_else 0)<0,"the middle of the capsule is solid")
    testing.expect(t,(source_value(&source,{8,16,16}) or_else 0)<0 && (source_value(&source,{24,16,16}) or_else 0)<0)
    testing.expect(t,(source_value(&source,{16,21,16}) or_else 0)>0,"two cells past its radius is air")
    box:=Brush{kind=.Carve,shape=.Box,center=source_point(&source,{16,16,16}),extent={2,2,2},rotation=1,amount=1}
    testing.expect(t,source_edit(&source,box).changed)
    testing.expect(t,(source_value(&source,{16,16,16}) or_else 0)>0,"the box takes the middle away")
    testing.expect(t,(source_value(&source,{9,16,16}) or_else 0)<0,"and leaves the rest of the capsule")
    hard,soft:=source_value(&source,{16,22,16}) or_else 0,f32(0)
    sphere:=Brush{kind=.Add,shape=.Sphere,center=source_point(&source,{16,26,16}),radius=3,amount=1,blend=4}
    testing.expect(t,source_edit(&source,sphere).changed)
    soft=source_value(&source,{16,22,16}) or_else 0
    testing.expect(t,soft<min(hard,1),"between two solids a blend fills more than their union")
    testing.expect_value(t,source_edit(&source,{kind=.Add,shape=.Box,center={},extent={0,1,1},amount=1}).error,Edit_Error.Extent)
    testing.expect(t,smooth_min(1,1,2)<1 && smooth_min(1,5,2)==1 && smooth_min(1,3,0)==1)
}

@(test)
falloffs_go_from_one_to_zero_and_hardness_keeps_the_middle_full :: proc(t:^testing.T) {
    for falloff in geom.Falloff {
        testing.expect_value(t,geom.falloff_weight(falloff,0,0),f32(1))
        testing.expect_value(t,geom.falloff_weight(falloff,0,1),f32(0))
        testing.expect_value(t,geom.falloff_weight(falloff,0.5,0.4),f32(1))
        if falloff!=.Constant {testing.expect(t,geom.falloff_weight(falloff,0,0.5)<1)}
    }
    testing.expect(t,geom.falloff_weight(.Sharp,0,0.5)<geom.falloff_weight(.Linear,0,0.5))
    testing.expect(t,geom.falloff_weight(.Sphere,0,0.5)>geom.falloff_weight(.Smooth,0,0.5))
}
