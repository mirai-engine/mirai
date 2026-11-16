package ai

import "core:testing"
import mm "mirai:std/math"

// A source spreads farther with every pass, less the farther it goes, only
// once a pass finishes, and never past the cells a call is given.
@(test)
an_influence_spreads_by_passes_within_its_budget :: proc(t:^testing.T) {
    g:Influence_Grid
    testing.expect(t,influence_init(&g,{-8,-8},1,16,16,2))
    defer influence_destroy(&g)
    source:=mm.Vec3{0.5,0,0.5}
    near:=mm.Vec3{2.5,0,0.5}
    far:=mm.Vec3{6.5,0,0.5}
    for pass in 0..<12 {
        if !influence_running(&g) {influence_stamp(&g,1,source,1)}
        calls:=0
        for !influence_spread(&g,100,0.2,1) {
            calls+=1
            testing.expect(t,g.cursor==calls*100)
        }
        testing.expect_value(t,calls,(16*16*2-1)/100)
        if pass==0 {testing.expect(t,influence_sample(&g,1,near)==0)}
    }
    at:=influence_sample(&g,1,source)
    testing.expect(t,at>0.99)
    a:=influence_sample(&g,1,near)
    b:=influence_sample(&g,1,far)
    testing.expect(t,a>b && b>0 && a<at)
    testing.expect(t,abs(a-0.64)<0.01) // two metres at 20 % less a metre
    testing.expect(t,influence_sample(&g,0,near)==0)
    // Without sources it fades by the blend.
    for _ in 0..<3 {for !influence_spread(&g,1000,0.2,0.5) {}}
    testing.expect(t,influence_sample(&g,1,source)<at)
}

// The cover of a cell faces the directions measured, and half the next ones.
@(test)
the_cover_of_a_cell_faces_where_it_was_blocked :: proc(t:^testing.T) {
    g:Influence_Grid
    testing.expect(t,influence_init(&g,{0,0},2,4,4,1))
    defer influence_destroy(&g)
    here:=mm.Vec3{3,0,3}
    testing.expect_value(t,influence_cover(&g,here,{10,0,3}),0)
    influence_cover_set(&g,{1,1},1<<0) // blocked toward +x
    cases:=[?]struct{from:mm.Vec3,cover:f32}{{{10,0,3},1},{{10,0,10},0.5},{{3,0,10},0},{{-5,0,3},0}}
    for c in cases {testing.expectf(t,influence_cover(&g,here,c.from)==c.cover,"from %v",c.from)}
}

@(test)
an_influence_grid_survives_wild_input :: proc(t:^testing.T) {
    g:Influence_Grid
    testing.expect(t,!influence_init(&g,{},0,4,4,1))
    testing.expect(t,!influence_init(&g,{},f32(0h7fc00000),4,4,1))
    testing.expect(t,!influence_init(&g,{},1,-1,4,1))
    testing.expect(t,!influence_init(&g,{},1,1<<20,1<<20,1))
    wild:=[?]f32{f32(0h7fc00000),f32(0h7f800000),f32(0hff800000),-1,0,1e30}
    empty:Influence_Grid
    testing.expect(t,!influence_spread(&empty,10,0.1,1))
    testing.expect(t,influence_sample(&empty,0,{})==0)
    testing.expect(t,influence_init(&g,{-1,-1},0.5,4,4,2))
    defer influence_destroy(&g)
    for v in wild {
        p:=mm.Vec3{v,v,v}
        influence_stamp(&g,0,p,v)
        influence_stamp(&g,-1,{},1)
        influence_stamp(&g,9,{},1)
        _=influence_spread(&g,int(v) if v==v && abs(v)<1e6 else 3,v,v)
        _=influence_sample(&g,0,p)
        _=influence_sample(&g,5,p)
        _=influence_cover(&g,p,{})
        _,_=influence_direction(p,p)
        influence_cover_set(&g,{i32(-1),9},0xFF)
    }
}
