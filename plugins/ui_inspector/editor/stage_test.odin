package ui_inspector_editor

import "core:testing"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:ui"

@(test)
handles_resize_and_snap_to_the_edges_near_them :: proc(t:^testing.T) {
    start:=ui.Rect{100,50,200,40}
    testing.expect_value(t,gesture_rect(start,.Move,{10,-5},1),ui.Rect{110,45,200,40})
    testing.expect_value(t,gesture_rect(start,.Right,{30,99},1),ui.Rect{100,50,230,40})
    testing.expect_value(t,gesture_rect(start,.Top_Left,{-20,10},1),ui.Rect{80,60,220,30})
    // No side under the least.
    testing.expect_value(t,gesture_rect(start,.Left,{500,0},4),ui.Rect{296,50,4,40})
    // The edge nearest a target within reach takes it.
    values:[3]f32
    moved:=snap_values(ui.Rect{103,0,200,0},.Move,0,&values)
    testing.expect_value(t,len(moved),3)
    delta,line,ok:=snap_axis(moved,{0,100,400},6)
    testing.expect(t,ok && delta==-3 && line==100)
    _,_,ok=snap_axis(moved,{0,120,500},6)
    testing.expect(t,!ok)
    // A center: 103+100=203 near 205.
    delta,line,ok=snap_axis(moved,{205},6)
    testing.expect(t,ok && delta==2 && line==205)
    resized:=snap_values(ui.Rect{100,0,200,0},.Right,0,&values)
    testing.expect(t,len(resized)==1 && resized[0]==300)
    testing.expect_value(t,len(snap_values(ui.Rect{100,0,200,0},.Right,1,&values)),0)
    // A node hung by its center grows on the right: its offset moves half the growth.
    testing.expect_value(t,pivot_shift(start,gesture_rect(start,.Right,{20,0},1),.Center),[2]f32{10,0})
    testing.expect_value(t,pivot_shift(start,gesture_rect(start,.Left,{-20,0},1),.Top_Left),[2]f32{-20,0})
    testing.expect_value(t,pivot_shift(start,gesture_rect(start,.Left,{-20,0},1),.Top_Right),[2]f32{0,0})
}

@(test)
samples_fill_numbers_texts_and_arrays :: proc(t:^testing.T) {
    Item :: struct {count:i32,name:[16]u8}
    Stats :: struct {health:f32,alive:bool,items:[dynamic]Item,icon:base.Asset_Id,title:string}
    s:Preview_Samples
    s.allocator=context.allocator
    s.blocks=make([dynamic][]u8,context.allocator)
    defer {
        for block in s.blocks {delete(block)}
        delete(s.blocks)
    }
    stats:Stats
    sample_fill(&s,&stats,type_info_of(Stats),"",0)
    testing.expect_value(t,stats.health,f32(0.5))
    testing.expect(t,stats.alive)
    testing.expect_value(t,len(stats.items),SAMPLE_ELEMENTS)
    testing.expect_value(t,stats.items[2].count,i32(3))
    testing.expect_value(t,serial.text_field(stats.items[1].name[:]),"name")
    testing.expect_value(t,stats.icon,SAMPLE_ASSET)
    testing.expect_value(t,stats.title,"title")
}

@(test)
each_interface_keeps_where_it_was_left :: proc(t:^testing.T) {
    u:=new(Ui_Inspector,context.temp_allocator)
    u.id,u.selected,u.nodes_scroll=base.Asset_Id{1,1},3,{0,40}
    u.stage.zoom=2
    view_keep(u)
    u.id=base.Asset_Id{2,2}
    view_take(u)
    testing.expect(t,u.selected==-1 && u.nodes_scroll.y==0 && u.stage.zoom==0)
    u.selected=1
    view_keep(u)
    u.id=base.Asset_Id{1,1}
    view_take(u)
    testing.expect(t,u.selected==3 && u.nodes_scroll.y==40 && u.stage.zoom==2)
    testing.expect_value(t,widget_file_name("My Card!"),"My_Card")
    testing.expect_value(t,widget_file_name("../"),"widget")
}
