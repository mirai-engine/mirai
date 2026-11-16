package ui

import "core:testing"

Test_Password :: struct {value:[64]u8,length:int,show:bool}
test_password_build :: proc(ctx:^Context,user:rawptr) {
    s:=cast(^Test_Password)user
    text_field(ctx,id(ctx,"secret"),s.value[:],&s.length,{password=!s.show,live=true})
}

@(test)
password_fields_mask_paint_and_keep_the_editable_value :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL));defer context_destroy(&ctx)
    s:Test_Password
    s.length=copy(s.value[:],"sk-example")
    input:=test_input()
    test_frame(&ctx,&input,test_password_build,&s)
    test_frame(&ctx,&input,test_password_build,&s)
    testing.expect_value(t,string(s.value[:s.length]),"sk-example")
    testing.expect(t,test_paint(&ctx,"**********")!=nil && test_paint(&ctx,"sk-example")==nil)
    edit_request(&ctx,id(&ctx,"secret"))
    test_frame(&ctx,&input,test_password_build,&s)
    test_type(&input,"new-key")
    test_frame(&ctx,&input,test_password_build,&s)
    testing.expect_value(t,string(s.value[:s.length]),"new-key")
    testing.expect(t,test_paint(&ctx,"*******")!=nil && test_paint(&ctx,"new-key")==nil)
    s.show=true
    test_frame(&ctx,&input,test_password_build,&s)
    testing.expect(t,test_paint(&ctx,"new-key")!=nil)
}
