package ui

import "core:testing"

@(test)
an_icon_given_as_data_is_drawn_from_its_parts :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    // A square over the middle half of the icon.
    testing.expect(t,icon_custom_set(&ctx,3,icon_drawing(icon_part(.Fill,{{-4,-4},{4,-4},{4,4},{-4,4}}))))
    testing.expect(t,!icon_custom_set(&ctx,ICON_CUSTOM_CAPACITY,{}))
    testing.expect(t,icon_custom(3)>=.Custom && icon_custom(ICON_CUSTOM_CAPACITY-1)<.User)
    input:=test_input()
    frame:=test_frame(&ctx,&input,proc(ctx:^Context,user:rawptr) {
        draw_icon(ctx,icon_custom(3),{100,50,32,32},{255,255,255,255})
        draw_icon(ctx,icon_custom(4),{0,0,32,32},{255,255,255,255})
    })
    // Two points to a unit of its grid; the icon nobody gave draws nothing.
    testing.expect(t,len(frame.vertices)>=6)
    testing.expect(t,test_rect_near(test_bounds(frame.vertices),{108,58,16,16},1.5))
    // More points than a part holds are left out, and more parts than a drawing holds.
    long:[ICON_POINT_CAPACITY+4][2]f32
    testing.expect_value(t,int(icon_part(.Line,long[:]).count),ICON_POINT_CAPACITY)
    parts:[ICON_PART_CAPACITY+2]Icon_Part
    testing.expect_value(t,int(icon_drawing(..parts[:]).count),ICON_PART_CAPACITY)
}
