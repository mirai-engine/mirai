package terrain

import "core:fmt"
import "core:math"
import "core:testing"
import "mirai:asset"
import "mirai:std/base"

@(private="file")
dominant :: proc(w:[4]f32) -> int {
    best:=0
    for i in 1..<4 {if w[i]>w[best] {best=i}}
    return best
}

@(test)
the_interior_of_a_volume_shows_where_it_is_dug_and_what_fills_keeps_its_layer :: proc(t:^testing.T) {
    s:Source
    defer source_destroy(&s)
    // Solid from y -7 to the surface at 0.
    testing.expect(t,source_make(&s,.Volume,{33,17,33},1,8))
    for i in 0..<4 {testing.expect(t,source_layer_set(&s,i,LAYER_DEFAULT))}
    s.interior={strata_count=3,strata={{layer=0,depth=0.5},{layer=1,depth=2.5},{layer=2,depth=100},{}},vein_count=1,veins={{layer=3,shape=.Pocket,scale=2,amount=0.5,depth={3.5,100}},{},{},{}}}
    testing.expect(t,source_interior_apply(&s))
    testing.expect_value(t,dominant(source_weights_at(&s,{0,0,0})),0)
    testing.expect_value(t,dominant(source_weights_at(&s,{0,-1.5,0})),1)
    // Pockets of ore take part of what is deep, and nothing above their depth.
    ore,deep:=0,0
    // The columns inside the box, whose top is the surface at 0.
    for z in 4..<29 {for y in 0..<17 {for x in 4..<29 {
        p:=[3]int{x,y,z}
        depth:=-source_point(&s,p).y
        w:=grid_value(&s.weights,p)
        if depth<3.5 {testing.expect(t,w[3]==0);continue}
        if depth>7 {continue}
        deep+=1
        if w[3]==WEIGHT_FULL {ore+=1} else {testing.expect_value(t,w[2],u8(WEIGHT_FULL))}
    }}}
    testing.expectf(t,ore>deep/10 && ore<deep*9/10,"pockets take part of the deep samples: %d of %d",ore,deep)

    // A pit: its floor shows what is at that depth, and the dig counts each layer.
    change:=source_edit(&s,{kind=.Carve,center={0,0,0},radius=3,amount=1})
    testing.expect(t,change.changed && change.error==.None)
    hemisphere:=f32(2)/3*math.PI*27
    testing.expectf(t,abs(s.dug.volume-hemisphere)<hemisphere*0.25,"a ball of 3 m at the surface takes about %v cubic metres, it took %v",hemisphere,s.dug.volume)
    sum:=s.dug.layers[0]+s.dug.layers[1]+s.dug.layers[2]+s.dug.layers[3]
    testing.expect(t,abs(sum-s.dug.volume)<s.dug.volume*0.01)
    testing.expect(t,s.dug.layers[0]>0 && s.dug.layers[1]>s.dug.layers[0])
    floor,_,hit:=source_ray(&s,{0,20,0},{0,-1,0})
    testing.expect(t,hit && floor.y<-2.5)
    testing.expect(t,dominant(source_weights_at(&s,floor))>=2,"the floor of the pit shows rock or ore, not grass")
    // What Union fills with keeps its layer, and adds nothing to what is dug.
    change=source_edit(&s,{kind=.Add,shape=.Sphere,center={0,-3,0},radius=1.2,amount=1,layer=0})
    testing.expect(t,change.changed && s.dug.volume==0)
    testing.expect_value(t,dominant(source_weights_at(&s,{0,-3,0})),0)
    testing.expect_value(t,source_edit(&s,{kind=.Add,shape=.Sphere,center={0,-3,0},radius=1,amount=1,layer=4}).error,Edit_Error.Layer)

    // The interior travels in the file, and a layer that goes takes its strata.
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    loaded:Source;defer source_destroy(&loaded)
    path:=fmt.tprintf("%s/interior.terrain",base.test_folder(t,"terrain"))
    testing.expect_value(t,source_save(&s,path,{91,92},&types),asset.Error.None)
    _,ok:=source_load(&loaded,path,&types)
    testing.expect(t,ok && loaded.interior==s.interior && grid_equal(&loaded.weights,&s.weights))
    testing.expect(t,source_layer_remove(&loaded,1))
    testing.expect(t,loaded.interior.strata_count==2 && loaded.interior.strata[1]=={layer=1,depth=100} && loaded.interior.veins[0].layer==2)
    testing.expect(t,interior_valid(loaded.interior,loaded.layer_count))

    bad:=s.info
    bad.interior.strata[1].depth=0.1
    testing.expect(t,!source_valid(bad),"strata go down")
    bad=s.info
    bad.interior.veins[0].layer=4
    testing.expect(t,!source_valid(bad),"a vein of a layer the source does not have")
    heights:Source;defer source_destroy(&heights)
    testing.expect(t,source_make(&heights,.Heightfield,{9,1,9},1,4))
    heights.interior=s.interior
    testing.expect(t,!source_valid(heights.info) && !source_interior_apply(&heights),"only a Volume has an interior")
}

@(test)
lowering_a_heightfield_counts_the_height_it_takes_by_layer :: proc(t:^testing.T) {
    s:Source
    defer source_destroy(&s)
    testing.expect(t,source_make(&s,.Heightfield,{17,1,17},1,8))
    testing.expect(t,source_layer_set(&s,0,LAYER_DEFAULT) && source_layer_set(&s,1,LAYER_DEFAULT))
    middle:=source_origin(&s)+{8,0,8}
    testing.expect(t,source_edit(&s,{kind=.Paint,center=middle+{6,0,0},radius=6,amount=1,layer=1,falloff=.Constant}).changed)
    before:=f32(0)
    for z in 0..<17 {for x in 0..<17 {before+=grid_get(&s.field,x,z)}}
    testing.expect(t,source_edit(&s,{kind=.Lower,center=middle,radius=4,amount=1}).changed)
    after:=f32(0)
    for z in 0..<17 {for x in 0..<17 {after+=grid_get(&s.field,x,z)}}
    testing.expect(t,abs(s.dug.volume-(before-after))<1e-3)
    testing.expect(t,s.dug.layers[0]>0 && s.dug.layers[1]>0 && s.dug.sum.y<0)
    testing.expect(t,source_edit(&s,{kind=.Raise,center=middle,radius=4,amount=1}).changed && s.dug.volume==0)
}
