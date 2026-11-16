package platform

import "core:testing"
import sdl "vendor:sdl3"

@(test)
custom_window_resizes_from_its_edges_and_corners :: proc(t:^testing.T) {
    size:=[2]i32{800,600}
    testing.expect_value(t,window_hit({2,2},size,nil,true),Window_Hit.Resize_Top_Left)
    testing.expect_value(t,window_hit({797,3},size,nil,true),Window_Hit.Resize_Top_Right)
    testing.expect_value(t,window_hit({3,597},size,nil,true),Window_Hit.Resize_Bottom_Left)
    testing.expect_value(t,window_hit({790,590},size,nil,true),Window_Hit.Resize_Bottom_Right)
    testing.expect_value(t,window_hit({400,3},size,nil,true),Window_Hit.Resize_Top)
    testing.expect_value(t,window_hit({400,596},size,nil,true),Window_Hit.Resize_Bottom)
    testing.expect_value(t,window_hit({4,300},size,nil,true),Window_Hit.Resize_Left)
    testing.expect_value(t,window_hit({795,300},size,nil,true),Window_Hit.Resize_Right)
    // The margin is WINDOW_RESIZE_MARGIN points wide and the corners WINDOW_RESIZE_CORNER.
    testing.expect_value(t,window_hit({400,WINDOW_RESIZE_MARGIN-1},size,nil,true),Window_Hit.Resize_Top)
    testing.expect_value(t,window_hit({400,WINDOW_RESIZE_MARGIN},size,nil,true),Window_Hit.Client)
    testing.expect_value(t,window_hit({WINDOW_RESIZE_CORNER-1,WINDOW_RESIZE_CORNER-1},size,nil,true),Window_Hit.Resize_Top_Left)
    testing.expect_value(t,window_hit({WINDOW_RESIZE_CORNER,WINDOW_RESIZE_CORNER},size,nil,true),Window_Hit.Client)
    // A window that cannot be resized now (maximized, fixed, the application is dragging) has no edges.
    testing.expect_value(t,window_hit({2,2},size,nil,false),Window_Hit.Client)
    testing.expect_value(t,window_hit({400,300},size,nil,true),Window_Hit.Client)
}

@(test)
custom_window_moves_from_drag_regions_and_leaves_widgets_alone :: proc(t:^testing.T) {
    size:=[2]i32{800,600}
    regions:=[]Window_Region{
        {{0,0,800,36},.Drag},      // the bar
        {{60,4,80,28},.Client},    // a button on the bar
        {{0,0,48,36},.Client},     // a menu at the very corner
        {{754,0,46,36},.Control},  // the close button, up to the corner
    }
    testing.expect_value(t,window_hit({300,20},size,regions,true),Window_Hit.Drag)
    testing.expect_value(t,window_hit({300,40},size,regions,true),Window_Hit.Client)
    testing.expect_value(t,window_hit({100,20},size,regions,true),Window_Hit.Client)
    // Edges of the bar resize before they move.
    testing.expect_value(t,window_hit({300,3},size,regions,true),Window_Hit.Resize_Top)
    testing.expect_value(t,window_hit({300,3},size,regions,false),Window_Hit.Drag)
    // A widget at the edge keeps its clicks; a caption button gives up only its outermost points.
    testing.expect_value(t,window_hit({2,2},size,regions,true),Window_Hit.Client)
    testing.expect_value(t,window_hit({780,20},size,regions,true),Window_Hit.Client)
    testing.expect_value(t,window_hit({780,2},size,regions,true),Window_Hit.Resize_Top_Right)
    testing.expect_value(t,window_hit({798,20},size,regions,true),Window_Hit.Resize_Top_Right)
    testing.expect_value(t,window_hit({798,30},size,regions,true),Window_Hit.Resize_Right)
    // Maximized, the caption button reaches the corner of the screen.
    testing.expect_value(t,window_hit({799,0},size,regions,false),Window_Hit.Client)
}

@(test)
window_regions_are_kept_up_to_their_capacity :: proc(t:^testing.T) {
    p:=test_headless(t,{window={size={800,600}},region_capacity=2})
    defer destroy(p)
    testing.expect_value(t,window_hit_at(p,{300,20}),Window_Hit.Client)
    testing.expect(t,window_set_regions(p,{{{0,0,800,36},.Drag},{{60,4,80,28},.Client}}))
    testing.expect_value(t,window_hit_at(p,{300,20}),Window_Hit.Drag)
    testing.expect_value(t,window_hit_at(p,{100,20}),Window_Hit.Client)
    testing.expect_value(t,window_hit_at(p,{300,2}),Window_Hit.Resize_Top)
    testing.expect(t,window_set_regions(p,{{{0,0,800,36},.Drag}},resizable=false))
    testing.expect_value(t,window_hit_at(p,{300,2}),Window_Hit.Drag)
    testing.expect(t,window_set_regions(p,{{{0,0,800,36},.Drag}}))
    window_set_maximized(p,true)
    testing.expect_value(t,window_hit_at(p,{300,2}),Window_Hit.Drag)
    window_set_maximized(p,false)
    testing.expect(t,!window_set_regions(p,{{{0,0,800,36},.Client},{{0,0,1,1},.Client},{{0,0,800,36},.Drag}}))
    testing.expect_value(t,stats(p).regions_dropped,u64(1))
    testing.expect_value(t,window_hit_at(p,{300,20}),Window_Hit.Client)
    testing.expect(t,window_set_regions(p,nil))
    testing.expect_value(t,window_hit_at(p,{300,20}),Window_Hit.Client)
}

@(test)
manual_resize_keeps_the_opposite_edge_when_the_minimum_clamps_it :: proc(t:^testing.T) {
    rect:=sdl.Rect{100,100,800,600}
    minimum:=[2]i32{640,400}
    testing.expect_value(t,window_resize_rect(rect,.RESIZE_RIGHT,{50,30},minimum),sdl.Rect{100,100,850,600})
    testing.expect_value(t,window_resize_rect(rect,.RESIZE_BOTTOMRIGHT,{50,30},minimum),sdl.Rect{100,100,850,630})
    testing.expect_value(t,window_resize_rect(rect,.RESIZE_LEFT,{50,0},minimum),sdl.Rect{150,100,750,600})
    testing.expect_value(t,window_resize_rect(rect,.RESIZE_TOPLEFT,{-20,-10},minimum),sdl.Rect{80,90,820,610})
    // Dragging the left edge past the minimum width leaves the right edge at 900.
    testing.expect_value(t,window_resize_rect(rect,.RESIZE_LEFT,{500,0},minimum),sdl.Rect{260,100,640,600})
    testing.expect_value(t,window_resize_rect(rect,.RESIZE_TOP,{0,500},minimum),sdl.Rect{100,300,800,400})
    testing.expect_value(t,window_resize_rect(rect,.RESIZE_BOTTOM,{0,-500},minimum),sdl.Rect{100,100,800,400})
    testing.expect_value(t,window_resize_rect(rect,.NORMAL,{50,50},minimum),rect)
}

@(test)
headless_dialog_is_answered_through_the_path_of_a_native_one :: proc(t:^testing.T) {
    p:=test_headless(t)
    defer destroy(p)
    frame_begin(p)
    testing.expect(t,!dialog_pending(p))
    testing.expect(t,!dialog_answer(p,"nothing is open"))
    filters:=[]Dialog_Filter{{"Mirai scene","scene"},{"3D models","obj;gltf;glb"}}
    testing.expect(t,dialog_show(p,{kind=.Open_File,tag=7,filters=filters,location="C:/projects"}))
    testing.expect(t,dialog_pending(p))
    // One dialog at a time.
    testing.expect(t,!dialog_show(p,{kind=.Save_File,tag=8}))
    frame_begin(p)
    testing.expect_value(t,dialog_result(p).state,Dialog_State.None)
    testing.expect(t,dialog_answer(p,"C:/projects/main.scene"))
    // The answer is seen by the frame that follows it, and only by that one.
    testing.expect_value(t,dialog_result(p).state,Dialog_State.None)
    testing.expect(t,dialog_pending(p))
    frame_begin(p)
    result:=dialog_result(p)
    testing.expect_value(t,result.state,Dialog_State.Accepted)
    testing.expect_value(t,result.kind,Dialog_Kind.Open_File)
    testing.expect_value(t,result.tag,u32(7))
    testing.expect_value(t,result.path,"C:/projects/main.scene")
    testing.expect(t,!dialog_pending(p))
    frame_begin(p)
    testing.expect_value(t,dialog_result(p).state,Dialog_State.None)

    testing.expect(t,dialog_show(p,{kind=.Save_File,tag=8}))
    testing.expect(t,dialog_answer(p,""))
    frame_begin(p)
    testing.expect_value(t,dialog_result(p).state,Dialog_State.Cancelled)
    testing.expect_value(t,dialog_result(p).tag,u32(8))
    testing.expect_value(t,dialog_result(p).path,"")

    testing.expect(t,dialog_show(p,{kind=.Open_Folder,tag=9}))
    testing.expect(t,dialog_answer(p,"",failed=true))
    frame_begin(p)
    testing.expect_value(t,dialog_result(p).state,Dialog_State.Failed)
    testing.expect_value(t,dialog_result(p).kind,Dialog_Kind.Open_Folder)

    // What does not fit is refused before anything opens.
    many:[DIALOG_FILTER_CAPACITY+1]Dialog_Filter
    testing.expect(t,!dialog_show(p,{filters=many[:]}))
    testing.expect(t,!dialog_pending(p))
    // A dialog left open is dropped with the Platform.
    testing.expect(t,dialog_show(p,{kind=.Open_File}))
}
