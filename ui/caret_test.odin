package ui

import "core:testing"

Test_Caret :: struct {value:[32]u8,length:int,result:Text_Result}
test_caret_build :: proc(ctx:^Context,user:rawptr) {
    s:=cast(^Test_Caret)user
    s.result=text_field(ctx,id(ctx,"caret"),s.value[:],&s.length,{width=fixed(128),height=72,size=12,bare=true,live=true,keep_caret=true})
}

@(test)
text_caret_blinks_at_text_height_and_restarts_on_input_without_allocating :: proc(t:^testing.T) {
    ctx:Context
    counter:Test_Counter
    desc:=TEST_SMALL
    desc.allocator=test_counter(&counter,context.allocator)
    testing.expect(t,test_context_init(&ctx,desc));defer context_destroy(&ctx)
    s:Test_Caret
    input:=test_input()
    test_frame(&ctx,&input,test_caret_build,&s)
    test_frame(&ctx,&input,test_caret_build,&s)
    requests:=counter.requests
    edit_request(&ctx,id(&ctx,"caret"))
    frame:=test_frame(&ctx,&input,test_caret_build,&s)
    testing.expect(t,test_caret(&ctx)!=nil)
    testing.expect_value(t,len(frame.vertices),6)
    min_y,max_y:=max(f32),min(f32)
    min_x,max_x:=max(f32),min(f32)
    for v in frame.vertices {
        min_y=min(min_y,v.position.y);max_y=max(max_y,v.position.y)
        min_x=min(min_x,v.position.x);max_x=max(max_x,v.position.x)
    }
    testing.expect(t,test_near(max_y-min_y,12*TEXT_LINE) && test_near(max_x-min_x,1),"a tall field uses a one-unit caret with the text height")
    input.dt=0.6
    frame=test_frame(&ctx,&input,test_caret_build,&s)
    testing.expect(t,test_caret(&ctx)==nil && len(frame.vertices)==0,"the caret blinks while editing remains active")
    testing.expect(t,s.result.editing && ctx.edit.id==id(&ctx,"caret"))
    test_type(&input,"x")
    test_frame(&ctx,&input,test_caret_build,&s)
    testing.expect(t,test_caret(&ctx)!=nil && s.result.changed && s.length==1,"typing restarts the visible phase")
    test_frame(&ctx,&input,test_caret_build,&s)
    testing.expect(t,test_caret(&ctx)==nil)
    test_key(&input,.Left)
    test_frame(&ctx,&input,test_caret_build,&s)
    testing.expect(t,test_caret(&ctx)!=nil && ctx.edit.cursor==0,"moving the caret restarts its visible phase")
    testing.expect_value(t,counter.requests,requests)
}
