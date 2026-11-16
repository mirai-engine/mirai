package ui

import "core:testing"

@(private="file") Disabled_Test :: struct {disabled:bool,value:f64,checked:bool,clicks:int,result:Number_Result}
@(private="file")
disabled_test_build :: proc(ctx:^Context,user:rawptr) {
    state:=cast(^Disabled_Test)user
    if panel(ctx,id(ctx,"panel"),{width=fixed(200),height=FIT,gap=4}) {
        if state.disabled {disabled_begin(ctx)}
        if button(ctx,id(ctx,"button"),{label="Button",width=-1}).clicked {state.clicks+=1}
        checkbox(ctx,id(ctx,"checkbox"),&state.checked)
        state.result=number_field(ctx,id(ctx,"number"),&state.value)
        if state.disabled {disabled_end(ctx)}
    }
}

@(test)
a_disabled_scope_blocks_controls_and_cancels_a_number_being_typed :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    state:=Disabled_Test{value=2}
    input:=test_input()
    test_frame(&ctx,&input,disabled_test_build,&state)
    rect:=test_rect(t,&ctx,id(&ctx,"number"))
    test_point(&input,rect)
    test_frame(&ctx,&input,disabled_test_build,&state)
    test_press(&input)
    test_frame(&ctx,&input,disabled_test_build,&state)
    test_release(&input)
    test_frame(&ctx,&input,disabled_test_build,&state)
    testing.expect(t,state.result.editing)
    test_type(&input,"9")
    test_frame(&ctx,&input,disabled_test_build,&state)
    state.disabled=true
    test_key(&input,.Enter)
    test_frame(&ctx,&input,disabled_test_build,&state)
    testing.expect(t,state.result.cancelled && state.result.ended && !state.result.changed)
    testing.expect_value(t,state.value,2.0)
    for name in ([]string{"button","checkbox"}) {
        test_point(&input,test_rect(t,&ctx,id(&ctx,name)))
        test_press(&input)
        test_frame(&ctx,&input,disabled_test_build,&state)
        test_release(&input)
        test_frame(&ctx,&input,disabled_test_build,&state)
    }
    testing.expect_value(t,state.clicks,0)
    testing.expect(t,!state.checked)
    state.disabled=false
    test_point(&input,test_rect(t,&ctx,id(&ctx,"button")))
    test_frame(&ctx,&input,disabled_test_build,&state)
    test_press(&input)
    test_frame(&ctx,&input,disabled_test_build,&state)
    testing.expect_value(t,state.clicks,1)
}
