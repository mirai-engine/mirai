package ui

import "core:testing"

Test_Retain :: struct {
    key:u64,
    built:int,        // frames the subtree was built
    floating:bool,    // its root floats; otherwise it is in the flow of the surface
    other:int,        // rows of the widgets built after it, which are never kept
}
test_retain_build :: proc(ctx:^Context,user:rawptr) {
    s:=cast(^Test_Retain)user
    retained:=id(ctx,"retained")
    if retained_begin(ctx,retained,s.key) {
        s.built+=1
        float:=Float{to=.Surface,offset={10,10},layer=3} if s.floating else {}
        if box(ctx,{id=id(ctx,"panel"),width=fixed(200),height=fixed(100),float=float,fill={20,30,40,255},radius=8,direction=.Column,gap=4,padding=padding_all(8)}) {
            button(ctx,id(ctx,"ok"),{label="OK",width=80,height=24})
            progress(ctx,{id=id(ctx,"bar"),value=0.5,width=fixed(120),height=fixed(8),fill={200,80,40,255},track={40,40,40,255},radius=4})
        }
        retained_end(ctx,retained)
    }
    if box(ctx,{width=fixed(50),height=fixed(20),fill={1,2,3,255}}) {}
}

@(test)
a_retained_subtree_is_drawn_again_without_being_built :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_FONT))
    defer context_destroy(&ctx)
    s:=Test_Retain{key=1,floating=true}
    input:=test_input()
    input.pointer_absent=true
    first:=test_frame(&ctx,&input,test_retain_build,&s)
    vertices:=make([]Vertex,len(first.vertices))
    defer delete(vertices)
    copy(vertices,first.vertices)
    shapes:=len(first.shapes)
    ok:=test_rect(t,&ctx,id(&ctx,"ok"))
    second:=test_frame(&ctx,&input,test_retain_build,&s)
    testing.expect_value(t,s.built,1)
    testing.expect_value(t,len(second.vertices),len(vertices))
    testing.expect_value(t,len(second.shapes),shapes)
    same:=0
    for v,i in second.vertices {if v==vertices[i] {same+=1}}
    testing.expect_value(t,same,len(vertices))
    testing.expect_value(t,test_rect(t,&ctx,id(&ctx,"ok")),ok)
    // The pointer over one of its widgets builds it again, and it is kept again after.
    input.pointer_absent=false
    test_point(&input,ok)
    test_frame(&ctx,&input,test_retain_build,&s)
    testing.expect_value(t,s.built,2)
    // It stays hovered, as it was kept.
    test_frame(&ctx,&input,test_retain_build,&s)
    test_frame(&ctx,&input,test_retain_build,&s)
    testing.expect_value(t,s.built,2)
    // A click builds it.
    test_press(&input)
    test_frame(&ctx,&input,test_retain_build,&s)
    testing.expect_value(t,s.built,3)
    test_release(&input)
    test_frame(&ctx,&input,test_retain_build,&s)
    input.pointer={700,500}
    test_frame(&ctx,&input,test_retain_build,&s)
    built:=s.built
    test_frame(&ctx,&input,test_retain_build,&s)
    testing.expect_value(t,s.built,built)
    // Another key builds it.
    s.key=2
    test_frame(&ctx,&input,test_retain_build,&s)
    testing.expect_value(t,s.built,built+1)
}

@(test)
what_lays_out_in_the_flow_of_the_surface_is_never_kept :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    s:=Test_Retain{key=1}
    input:=test_input()
    input.pointer_absent=true
    for _ in 0..<3 {test_frame(&ctx,&input,test_retain_build,&s)}
    testing.expect_value(t,s.built,3)
}
