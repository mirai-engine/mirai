package terrain

import "core:math"
import "core:testing"

@(private="file")
region_source :: proc(t:^testing.T,source:^Source) {
    testing.expect(t,source_make(source,.Heightfield,{33,1,33},1,16))
    testing.expect(t,grid_prepare(&source.field,{},{32,0,32},source.allocator))
}

@(test)
a_copied_region_goes_elsewhere_turned_mirrored_raised_and_faded :: proc(t:^testing.T) {
    source:Source;region_source(t,&source);defer source_destroy(&source)
    // A ramp along x with a bump at (6,4): origin -16, so sample i is at i-16 m.
    for x in 0..<33 {for z in 0..<33 {grid_set(&source.field,x,z,f32(x)*0.1+(x==6 && z==4?5:0))}}
    region:Region;defer region_destroy(&region)
    if !testing.expect(t,source_region_copy(&source,{2,2},{10,6},&region)) {return}
    testing.expect_value(t,region.size,[2]int{9,5})
    // Its middle (6,4) goes to (20,20), a quarter turn, raised 2 m: x of the region runs along z.
    change:=source_region_paste(&source,&region,{center={4,4},turn=math.PI/2,offset=2})
    testing.expect(t,change.changed && change.error==.None)
    testing.expect(t,abs(grid_get(&source.field,20,20)-(0.6+5+2))<1e-4,"the bump lands at the center")
    // A quarter turn takes +x of the region to -z of the ground.
    testing.expect(t,abs(grid_get(&source.field,20,16)-(1.0+2))<1e-4)
    testing.expect(t,abs(grid_get(&source.field,20,24)-(0.2+2))<1e-4)
    testing.expect_value(t,grid_get(&source.field,20,25),f32(2.0))
    // Mirrored, the ends trade places.
    source_region_paste(&source,&region,{center={4,4},turn=math.PI/2,offset=2,mirror=true})
    testing.expect(t,abs(grid_get(&source.field,20,16)-(0.2+2))<1e-4)
    // Only raising keeps what stands higher; a blend fades into the ground toward the edges.
    low:=grid_get(&source.field,28,4)
    source_region_paste(&source,&region,{center={12,-12},offset=-50,way=.Up})
    testing.expect_value(t,grid_get(&source.field,28,4),low)
    before:=grid_get(&source.field,24,4)
    source_region_paste(&source,&region,{center={12,-12},offset=10,blend=2})
    testing.expect_value(t,grid_get(&source.field,24,4),before)
    middle:=grid_get(&source.field,28,4)
    testing.expect(t,abs(middle-(0.6+5+10))<1e-4,"the middle takes the region whole")
    edge:=grid_get(&source.field,25,4)
    testing.expect(t,edge>f32(25)*0.1 && edge<0.3+10,"near its edge it is part of the way")
    cases:=[3]struct {paste:Region_Paste,error:Edit_Error}{{{center={math.nan_f32(),0}},.Center},{{blend=-1},.Blend},{{offset=math.inf_f32(1)},.Target}}
    for entry in cases {testing.expect_value(t,source_region_paste(&source,&region,entry.paste).error,entry.error)}
}

@(test)
a_mirrored_heightfield_meets_itself_at_the_plane :: proc(t:^testing.T) {
    shape :: proc(x,z:int) -> f32 {return f32(x)*0.3+f32(z*z)*0.01+(x==3?4:0)}
    cases:=[3]struct {rotate:bool,blend:int}{{false,0},{true,0},{false,3}}
    for entry in cases {
        source:Source;region_source(t,&source);defer source_destroy(&source)
        for x in 0..<33 {for z in 0..<33 {grid_set(&source.field,x,z,shape(x,z))}}
        testing.expect(t,source_layer_set(&source,1,LAYER_DEFAULT))
        testing.expect(t,source_edit(&source,{kind=.Paint,center={-12,0,-12},radius=3,amount=1,layer=1}).changed)
        change:=source_mirror(&source,0,16,rotate=entry.rotate,blend=entry.blend)
        testing.expect(t,change.changed && change.error==.None)
        symmetric:=true
        for x in 0..<33 {for z in 0..<33 {
            mz:=entry.rotate?32-z:z
            symmetric&&=abs(grid_get(&source.field,x,z)-grid_get(&source.field,32-x,mz))<1e-4
            if entry.blend==0 && x<16 {symmetric&&=grid_get(&source.field,x,z)==shape(x,z)}
        }}
        testing.expectf(t,symmetric,"%v: each sample has its image across the plane",entry)
        testing.expect(t,grid_get(&source.weights,28,entry.rotate?28:4)[1]>200,"the layers go over too")
    }
    source:Source;region_source(t,&source);defer source_destroy(&source)
    testing.expect_value(t,source_mirror(&source,2,16).error,Edit_Error.Invalid)
    testing.expect_value(t,source_mirror(&source,0,33).error,Edit_Error.Invalid)
}
