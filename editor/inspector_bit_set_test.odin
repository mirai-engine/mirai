package editor

import "base:runtime"
import "core:mem"
import "core:testing"
import "mirai:ui"

@(private="file") Inspector_Axis :: enum u8 {Linear_X,Linear_Y,Linear_Z,Angular_X,Angular_Y,Angular_Z}
@(private="file") Inspector_Axes :: bit_set[Inspector_Axis;u8]
@(private="file") Inspector_Wide_Flag :: enum u8 {Visible=32,Receives_Player_Collisions=127}
@(private="file") Inspector_Wide_Flags :: bit_set[Inspector_Wide_Flag;u128]

@(private="file")
inspector_bits_frame :: proc(t:^testing.T,ctx:^ui.Context,type:runtime.Type_Info_Bit_Set,bits:[]u8,width:f32,input:ui.Input,disabled:=false) {
    ui.frame_begin(ctx,input)
    if ui.box(ctx,{width=ui.fixed(width),height=ui.FIT,direction=.Column,gap=3}) {
        if disabled {ui.disabled_begin(ctx)}
        bit_set_field(ctx,123,"Locks",bits,type)
        if disabled {ui.disabled_end(ctx)}
    }
    output:=ui.frame_end(ctx)
    testing.expect(t,!output.overflow)
    testing.expect_value(t,ctx.stats.layout_errors,u32(0))
}

@(test)
named_bit_sets_keep_axis_groups_inside_details_and_toggle_wide_members :: proc(t:^testing.T) {
    ctx:ui.Context
    if !testing.expect(t,ui.context_init(&ctx,{})) {return}
    defer ui.context_destroy(&ctx)
    axes:Inspector_Axes={.Linear_Y,.Angular_Z}
    axis_type:=runtime.type_info_base(type_info_of(Inspector_Axes)).variant.(runtime.Type_Info_Bit_Set)
    input:=ui.Input{size={800,420},pointer_absent=true}
    for width in ([2]f32{180,264}) {
        for _ in 0..<3 {inspector_bits_frame(t,&ctx,axis_type,mem.ptr_to_bytes(&axes),width,input)}
        first_row_y,second_row_y:f32
        previous:ui.Rect
        for at in 0..<6 {
            rect,found:=ui.widget_rect(&ctx,ui.id_derive(&ctx,123,"member",at+1))
            testing.expect(t,found && rect.w>=24 && rect.x>=0 && rect.x+rect.w<=width+.01)
            if at==0 {first_row_y=rect.y}
            if at==3 {second_row_y=rect.y}
            testing.expect_value(t,rect.y,first_row_y if at<3 else second_row_y)
            if at%3!=0 {testing.expect(t,rect.x>=previous.x+previous.w)}
            previous=rect
        }
        testing.expect(t,second_row_y>=first_row_y+ui.metric(&ctx,"row"))
    }
    rect,_:=ui.widget_rect(&ctx,ui.id_derive(&ctx,123,"member",1))
    clicked:=ui.Input{size=input.size,pointer=ui.rect_center(rect),down={.Left},pressed={.Left}}
    inspector_bits_frame(t,&ctx,axis_type,mem.ptr_to_bytes(&axes),264,clicked)
    testing.expect_value(t,axes,Inspector_Axes{.Linear_X,.Linear_Y,.Angular_Z})
    inspector_bits_frame(t,&ctx,axis_type,mem.ptr_to_bytes(&axes),264,{size=input.size,released={.Left}})
    inspector_bits_frame(t,&ctx,axis_type,mem.ptr_to_bytes(&axes),264,clicked,true)
    testing.expect_value(t,axes,Inspector_Axes{.Linear_X,.Linear_Y,.Angular_Z})
    wide:Inspector_Wide_Flags={.Visible}
    wide_type:=runtime.type_info_base(type_info_of(Inspector_Wide_Flags)).variant.(runtime.Type_Info_Bit_Set)
    for _ in 0..<3 {inspector_bits_frame(t,&ctx,wide_type,mem.ptr_to_bytes(&wide),264,input)}
    wide_rect,found:=ui.widget_rect(&ctx,ui.id_derive(&ctx,123,"member",2))
    if !testing.expect(t,found && wide_rect.x+wide_rect.w<=264) {return}
    inspector_bits_frame(t,&ctx,wide_type,mem.ptr_to_bytes(&wide),264,{size=input.size,pointer=ui.rect_center(wide_rect),down={.Left},pressed={.Left}})
    testing.expect_value(t,wide,Inspector_Wide_Flags{.Visible,.Receives_Player_Collisions})
}
