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

Test_Placeholder :: struct {value:[32]u8,length:int}
test_placeholder_build :: proc(ctx:^Context,user:rawptr) {
    s:=cast(^Test_Placeholder)user
    text_field(ctx,id(ctx,"search"),s.value[:],&s.length,{width=fixed(160),height=24,size=12,bare=true,live=true,keep_caret=true,placeholder="Search assets"})
}
// Where the first piece that says text starts on the surface, the last frame.
test_piece_x :: proc(ctx:^Context,text:string) -> (x:f32,found:bool) {
    t:=&ctx.layout
    for &leaf in t.texts[:t.text_count] {
        for &line in t.lines[leaf.lines_first:][:leaf.lines_len] {
            for &piece in t.pieces[line.pieces_first:][:line.pieces_len] {
                if s:=&t.spans[piece.span];!s.box && s.text==text {return line.x+piece.x,true}
            }
        }
    }
    return
}

@(test)
a_placeholder_stays_still_while_the_caret_blinks_before_it :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_FONT));defer context_destroy(&ctx)
    s:Test_Placeholder
    input:=test_input()
    test_frame(&ctx,&input,test_placeholder_build,&s)
    idle,found:=test_piece_x(&ctx,"Search assets")
    testing.expect(t,found)
    edit_request(&ctx,id(&ctx,"search"))
    test_frame(&ctx,&input,test_placeholder_build,&s)
    shown,_:=test_piece_x(&ctx,"Search assets")
    testing.expect(t,test_caret(&ctx)!=nil)
    input.dt=0.6
    test_frame(&ctx,&input,test_placeholder_build,&s)
    hidden,_:=test_piece_x(&ctx,"Search assets")
    testing.expect(t,test_caret(&ctx)==nil && ctx.edit.id==id(&ctx,"search"))
    testing.expect(t,test_near(shown,idle) && test_near(hidden,idle),"the placeholder neither moves when the field takes the keys nor as the caret blinks")
}
