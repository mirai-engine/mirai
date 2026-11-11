package kit

import "core:log"
import "core:testing"
import "mirai:ui"

UI_UPDATE_REFERENCES :: #config(UI_UPDATE_REFERENCES,false)

Test_Reference :: struct {name:string,origin:[2]int,size:[2]int,data:[]u8}
TEST_REFERENCES :: [?]Test_Reference{
    {"bar",{0,0},{1440,84},#load("reference/bar.png")},
    {"create",{16,100},{320,302},#load("reference/create.png")},
    {"details",{1112,100},{312,369},#load("reference/details.png")},
}

@(test)
the_editor_widgets_match_the_current_reference :: proc(t:^testing.T) {
    ctx:ui.Context
    testing.expect(t,test_context_init(&ctx,TEST_FONT))
    defer ui.context_destroy(&ctx)
    e:=test_editor_default()
    input:=test_input(1440,900)
    test_frame(&ctx,&input,test_editor_build,&e)
    frame:=test_frame(&ctx,&input,test_editor_build,&e)
    testing.expect(t,!frame.overflow)
    testing.expect_value(t,ctx.stats.layout_errors,u32(0))
    testing.expect(t,test_rect_near(test_rect(t,&ctx,ui.id(&ctx,"content")),{16,100,320,302}))
    details:=test_rect(t,&ctx,ui.id(&ctx,"details"))
    testing.expectf(t,test_rect_near(details,{1112,100,312,369}),"Details bounds: %v",details)
    image:=test_raster(&ctx,frame,1440,900,1,{0,0,0,255})
    defer test_image_destroy(&image)
    test_image_dump(&image,"editor_reference_scene")
    if UI_UPDATE_REFERENCES {testing.expect(t,UI_DUMP_DIR!="","UI_UPDATE_REFERENCES needs UI_DUMP_DIR")}
    references:=TEST_REFERENCES
    for reference in references {
        rect:=ui.Rect{f32(reference.origin.x),f32(reference.origin.y),f32(reference.size.x),f32(reference.size.y)}
        ours:=test_image_crop(&image,rect,1)
        defer test_image_destroy(&ours)
        test_image_dump(&ours,reference.name)
        if UI_UPDATE_REFERENCES {continue}
        golden,decoded:=test_image_decode(reference.data)
        testing.expectf(t,decoded && golden.width==reference.size.x && golden.height==reference.size.y,"%s decodes at its documented size",reference.name)
        if !decoded {continue}
        defer test_image_destroy(&golden)
        d:=test_image_compare(&ours,&golden,{0,0,f32(ours.width),f32(ours.height)},2)
        if UI_DUMP_DIR!="" {log.infof("%s: %d of %d pixels differ by more than 2 levels (largest %d, mean %.3f)",reference.name,d.different,d.pixels,d.largest,d.mean)}
        testing.expectf(t,d.different==0,"%s: %d of %d pixels differ by more than 2 levels (largest %d, mean %.3f)",reference.name,d.different,d.pixels,d.largest,d.mean)
    }
}
