package monitors

import "core:math"
import "core:testing"
import "mirai:core"
import mm "mirai:std/math"

@(test)
an_image_has_levels_down_to_the_smallest_size :: proc(t:^testing.T) {
    testing.expect_value(t,levels_of(1280,720),LEVELS)
    testing.expect_value(t,levels_of(64,64),3)
    testing.expect_value(t,levels_of(64,16),1)
    testing.expect_value(t,levels_of(4096,4096),LEVELS)
}

@(test)
a_screen_is_as_wide_as_it_is_seen_where_it_is_nearest :: proc(t:^testing.T) {
    view:=core.VIEW_DEFAULT
    view.position,view.rotation,view.fov={0,0,10},1,60*mm.RAD_PER_DEG
    size:=[2]f32{1600,900}
    // A pane four metres wide, ten metres ahead: its nearest point is its middle.
    pane:=mm.Transform{{0,0,0},1,{4,2.25,0.02}}
    pixels,inside:=box_in_view(view,size,pane,{-0.5,-0.5,-0.5},{0.5,0.5,0.5})
    per_metre:=900/(2*math.tan(f32(30*mm.RAD_PER_DEG))*9.99)
    testing.expect(t,inside && abs(pixels-4*per_metre)<1)
    // Twice as near, twice as wide.
    view.position={0,0,5}
    closer,_:=box_in_view(view,size,pane,{-0.5,-0.5,-0.5},{0.5,0.5,0.5})
    testing.expect(t,abs(closer/pixels-9.99/4.99)<0.01)
    // Behind the eye and out to the side it is not seen.
    view.position={0,0,-10}
    _,inside=box_in_view(view,size,pane,{-0.5,-0.5,-0.5},{0.5,0.5,0.5})
    testing.expect(t,!inside)
    view.position={60,0,10}
    _,inside=box_in_view(view,size,pane,{-0.5,-0.5,-0.5},{0.5,0.5,0.5})
    testing.expect(t,!inside)
    // A parallel view sees it the same size from anywhere.
    view.position,view.projection,view.height={0,0,10},.Orthographic,9
    flat,seen:=box_in_view(view,size,pane,{-0.5,-0.5,-0.5},{0.5,0.5,0.5})
    testing.expect(t,seen && abs(flat-400)<0.5)
}
