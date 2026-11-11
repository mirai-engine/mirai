package editor

import "core:testing"
import "mirai:core"
import "mirai:std/base"
import "mirai:ui"

@(private="file")
@(component,description="A component description that explains the purpose of this entity capability and wraps to fit beside the pointer without covering the whole screen.")
Description_Tag :: struct {}

@(private="file") Description_World :: struct {using world:core.Test_World,tags:core.Table(Description_Tag)}

@(test)
component_descriptions_wait_for_the_pointer_to_rest_on_the_header :: proc(t:^testing.T) {
    ctx:ui.Context
    if !testing.expect(t,test_ui_init(&ctx,{})) {return}
    defer ui.context_destroy(&ctx)
    inspector:Inspector
    defer core.value_free(&inspector,type_info_of(Inspector))
    gui:=Editor_Ui{ctx=&ctx}
    session:=Session{gui=&gui,inspector=&inspector}
    info,described:=core.test_info(t,Description_World,test_types)
    if !described {return}
    defer core.test_info_destroy(&info)
    metadata:=&info.tables[0]
    inspect:=Inspect{s=&session,t=metadata,size=0}
    frame :: proc(t:^testing.T,inspect:^Inspect,input:ui.Input) {
        ctx:=inspect.s.gui.ctx
        ui.frame_begin(ctx,input)
        if ui.box(ctx,{width=ui.fixed(280),height=ui.FIT,direction=.Column}) {component_section(inspect,280)}
        output:=ui.frame_end(ctx)
        testing.expect(t,!output.overflow)
        testing.expect_value(t,ctx.stats.layout_errors,u32(0))
    }
    input:=ui.Input{size={800,420},pointer_absent=true}
    frame(t,&inspect,input)
    id:=ui.id(&ctx,"section",int(base.name_hash(readable("Description_Tag"))&0x7fffffff))
    rect,found:=ui.widget_rect(&ctx,id)
    if !testing.expect(t,found) {return}
    input.pointer_absent=false;input.pointer=ui.rect_center(rect)
    frame(t,&inspect,input)
    testing.expect_value(t,ctx.tooltip,"")
    input.dt=ui.TOOLTIP_DELAY/4
    for _ in 0..<3 {frame(t,&inspect,input);testing.expect_value(t,ctx.tooltip,"")}
    input.dt=ui.TOOLTIP_DELAY/2
    frame(t,&inspect,input)
    testing.expect_value(t,ctx.tooltip,metadata.description)
    input.pointer={700,350}
    frame(t,&inspect,input)
    testing.expect_value(t,ctx.tooltip,"")
    input.pointer=ui.rect_center(rect);input.dt=0
    frame(t,&inspect,input)
    testing.expect_value(t,ctx.tooltip,"")
    input.dt=ui.TOOLTIP_DELAY+0.1
    frame(t,&inspect,input)
    testing.expect_value(t,ctx.tooltip,metadata.description)
    description:=metadata.description
    metadata.description=""
    frame(t,&inspect,input)
    testing.expect_value(t,ctx.tooltip,"")
    metadata.description=description
}
