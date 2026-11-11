package terrain

import "core:math"
import "core:testing"

@(private="file")
grid_source :: proc(t:^testing.T,source:^Source,samples:int=33) {
    testing.expect(t,source_make(source,.Heightfield,{samples,1,samples},1,16))
    testing.expect(t,grid_prepare(&source.field,{},{samples-1,0,samples-1},source.allocator))
}

@(test)
capped_raise_and_lower_stop_at_the_height_of_the_press :: proc(t:^testing.T) {
    source:Source;grid_source(t,&source);defer source_destroy(&source)
    for x in 0..<33 {for z in 0..<33 {grid_set(&source.field,x,z,f32(x)*0.25)}}
    // Lifts what is under 4 m up to it, never over it, and leaves what is over it.
    for _ in 0..<40 {source_edit(&source,{kind=.Raise,center={},radius=20,amount=1,capped=true,target=4})}
    testing.expect_value(t,grid_get(&source.field,4,16),f32(4))
    testing.expect_value(t,grid_get(&source.field,30,16),f32(7.5))
    for _ in 0..<40 {source_edit(&source,{kind=.Lower,center={},radius=20,amount=1,capped=true,target=5})}
    testing.expect_value(t,grid_get(&source.field,30,16),f32(5))
    testing.expect_value(t,grid_get(&source.field,4,16),f32(4))
}

@(test)
a_way_keeps_flatten_raising_or_lowering_only :: proc(t:^testing.T) {
    source:Source;grid_source(t,&source);defer source_destroy(&source)
    for x in 0..<33 {for z in 0..<33 {grid_set(&source.field,x,z,x<16?f32(0):f32(10))}}
    source_edit(&source,{kind=.Flatten,center={},radius=40,amount=1,target=5,way=.Up,falloff=.Constant})
    testing.expect_value(t,grid_get(&source.field,2,16),f32(5))
    testing.expect_value(t,grid_get(&source.field,30,16),f32(10))
    source_edit(&source,{kind=.Flatten,center={},radius=40,amount=1,target=7,way=.Down,falloff=.Constant})
    testing.expect_value(t,grid_get(&source.field,2,16),f32(5))
    testing.expect_value(t,grid_get(&source.field,30,16),f32(7))
}

@(test)
terraces_level_each_step_and_rise_over_their_riser :: proc(t:^testing.T) {
    testing.expect_value(t,terrace_height(3.4,0,2,0),f32(2))
    testing.expect_value(t,terrace_height(-0.5,0,2,0),f32(-2))
    testing.expect_value(t,terrace_height(1.95,1,2,0.5),f32(1))
    testing.expect(t,abs(terrace_height(2.99,1,2,0.5)-2.99)<0.05,"over the riser it climbs to the next step")
    source:Source;grid_source(t,&source);defer source_destroy(&source)
    for x in 0..<33 {for z in 0..<33 {grid_set(&source.field,x,z,f32(x)*0.3)}}
    change:=source_edit(&source,{kind=.Terrace,center={},radius=40,amount=1,falloff=.Constant,interval=2})
    testing.expect(t,change.changed)
    for x in 0..<33 {testing.expect_value(t,grid_get(&source.field,x,16),math.floor(f32(x)*0.3/2)*2)}
    testing.expect(t,source_edit(&source,{kind=.Terrace,center={},radius=4,amount=1}).error==.Terrace,"a terrace without an interval is refused")
}

@(test)
noise_is_the_same_pattern_at_a_point_and_passes_deepen_it :: proc(t:^testing.T) {
    a:=brush_noise({12.5,0,-3.25},4,7,false)
    testing.expect_value(t,brush_noise({12.5,0,-3.25},4,7,false),a)
    testing.expect(t,brush_noise({12.5,0,-3.25},4,8,false)!=a,"another seed is another pattern")
    for x in -50..<50 {
        n:=brush_noise({f32(x)*0.37,0,f32(x)*-0.21},3,1,false)
        testing.expect(t,n>=-1 && n<=1)
    }
    source:Source;grid_source(t,&source);defer source_destroy(&source)
    testing.expect(t,source_edit(&source,{kind=.Noise,center={},radius=12,amount=1,scale=3,seed=1}).changed)
    once:=grid_get(&source.field,14,17)
    source_edit(&source,{kind=.Noise,center={},radius=12,amount=1,scale=3,seed=1,falloff=.Constant})
    testing.expect(t,abs(grid_get(&source.field,14,17))>=abs(once),"a second pass goes further the same way")
    testing.expect(t,source_edit(&source,{kind=.Noise,center={},radius=12,amount=1}).error==.Noise,"noise without a scale is refused")
}

@(test)
erosion_carries_ground_down_a_slope_into_a_basin_and_stays_near_the_disc :: proc(t:^testing.T) {
    source:Source;grid_source(t,&source,65);defer source_destroy(&source)
    for x in 0..<65 {for z in 0..<65 {grid_set(&source.field,x,z,f32(max(36-x,0))*0.5+f32(z%3)*0.05)}}
    before:=make([]f32,65*65);defer delete(before)
    for z in 0..<65 {for x in 0..<65 {before[x+65*z]=grid_get(&source.field,x,z)}}
    change:=source_edit(&source,{kind=.Erode,center={},radius=10,amount=1,seed=3})
    testing.expect(t,change.changed)
    taken,left:=f32(0),f32(0)
    for z in 0..<65 {for x in 0..<65 {
        d:=grid_get(&source.field,x,z)-before[x+65*z]
        if d<0 {taken-=d} else {left+=d}
        if math.hypot(f32(x-32),f32(z-32))>10*EROSION_REACH+1.5 {testing.expect_value(t,d,f32(0))}
    }}
    testing.expect(t,taken>0 && left>0,"drops take ground and leave it")
    // The same touch makes the same drops.
    other:Source;grid_source(t,&other,65);defer source_destroy(&other)
    for x in 0..<65 {for z in 0..<65 {grid_set(&other.field,x,z,before[x+65*z])}}
    source_edit(&other,{kind=.Erode,center={},radius=10,amount=1,seed=3})
    same:=true
    for z in 0..<65 {for x in 0..<65 {same&&=grid_get(&other.field,x,z)==grid_get(&source.field,x,z)}}
    testing.expect(t,same)
}

@(test)
the_slope_filter_and_an_alpha_choose_what_a_brush_touches :: proc(t:^testing.T) {
    source:Source;grid_source(t,&source);defer source_destroy(&source)
    // Flat on the left, a 45 degree slope on the right.
    for x in 0..<33 {for z in 0..<33 {grid_set(&source.field,x,z,x<16?f32(0):f32(x-16))}}
    source_edit(&source,{kind=.Raise,center={},radius=40,amount=1,falloff=.Constant,slope={0,math.to_radians(f32(10))}})
    testing.expect_value(t,grid_get(&source.field,4,16),f32(1))
    testing.expect_value(t,grid_get(&source.field,28,16),f32(12))
    source_edit(&source,{kind=.Raise,center={},radius=40,amount=1,falloff=.Constant,slope={0,math.to_radians(f32(10))},slope_invert=true})
    testing.expect_value(t,grid_get(&source.field,4,16),f32(1))
    testing.expect_value(t,grid_get(&source.field,28,16),f32(13))
    // An alpha lit on its +x half only, turned half a turn: the -x half.
    values:=make([]f32,16);defer delete(values)
    for z in 0..<4 {for x in 2..<4 {values[x+4*z]=1}}
    alpha:=Brush_Alpha{4,values}
    flat:Source;grid_source(t,&flat);defer source_destroy(&flat)
    source_edit(&flat,{kind=.Raise,center={},radius=10,amount=1,falloff=.Constant,alpha=&alpha})
    testing.expect(t,grid_get(&flat.field,22,16)>0.9 && grid_get(&flat.field,10,16)==0)
    source_edit(&flat,{kind=.Raise,center={},radius=10,amount=1,falloff=.Constant,alpha=&alpha,turn=math.PI})
    testing.expect(t,grid_get(&flat.field,10,16)>0.9)
}

@(test)
paint_toward_a_target_stops_at_its_weight :: proc(t:^testing.T) {
    source:Source;grid_source(t,&source);defer source_destroy(&source)
    testing.expect(t,source_layer_set(&source,0,LAYER_DEFAULT) && source_layer_set(&source,1,LAYER_DEFAULT))
    for _ in 0..<20 {source_paint(&source,{kind=.Paint,center={},radius=10,amount=0.5,layer=1,toward=true,target=0.5,falloff=.Constant})}
    w:=grid_get(&source.weights,16,16)
    testing.expect(t,abs(int(w[1])-WEIGHT_FULL/2)<=2,"half of the sample goes to the layer and no more")
    for _ in 0..<20 {source_paint(&source,{kind=.Paint,center={},radius=10,amount=0.5,layer=1,toward=true,target=0.2,falloff=.Constant})}
    testing.expect(t,abs(int(grid_get(&source.weights,16,16)[1])-51)<=2,"a lower target takes the layer back down")
}

@(test)
a_resized_heightfield_keeps_its_ground_in_place_and_grows_from_its_edges :: proc(t:^testing.T) {
    source:Source;grid_source(t,&source,9);defer source_destroy(&source)
    for x in 0..<9 {for z in 0..<9 {grid_set(&source.field,x,z,f32(x*10+z))}}
    testing.expect(t,source_layer_set(&source,0,LAYER_DEFAULT) && source_layer_set(&source,1,LAYER_DEFAULT))
    source_paint(&source,{kind=.Paint,center={-4,0,-4},radius=0.5,amount=1,layer=1,falloff=.Constant})
    source_holes_edit(&source,{kind=.Hole,center={3.5,0,3.5},radius=0.4})
    grown:Source;defer source_destroy(&grown)
    testing.expect(t,source_resize(&grown,&source,{13,9}))
    testing.expect_value(t,grown.samples,[3]u32{13,1,9})
    // The sample at x of the source is at x+2 of the grown one, the same place.
    testing.expect_value(t,source_point(&grown,{6,0,4}),source_point(&source,{4,0,4}))
    testing.expect_value(t,grid_get(&grown.field,0,4),grid_get(&source.field,0,4))
    testing.expect_value(t,grid_get(&grown.field,12,4),grid_get(&source.field,8,4))
    testing.expect_value(t,grid_get(&grown.weights,2,0),grid_get(&source.weights,0,0))
    testing.expect(t,source_hole(&grown,9,7) && source_hole(&source,7,7))
    testing.expect(t,!source_resize(&grown,&source,{12,9}),"an odd change of a side is refused")
    shrunk:Source;defer source_destroy(&shrunk)
    testing.expect(t,source_resize(&shrunk,&source,{5,5}))
    testing.expect_value(t,grid_get(&shrunk.field,0,0),grid_get(&source.field,2,2))
}
