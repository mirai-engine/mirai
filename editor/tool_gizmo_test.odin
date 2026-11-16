package editor

import "core:math/linalg"
import "core:testing"
import mm "mirai:std/math"

// A tool gizmo on a transform that is no entity: the axis handle of Move
// moves it along its axis as far as the pointer goes, Rotate turns it
// around its axis and Scale grows the axis it holds.
@(test)
a_tool_gizmo_moves_turns_and_scales_a_transform_of_its_own :: proc(t:^testing.T) {
    viewport:=Viewport{orbit=ORBIT_DEFAULT,size={1440,900}}
    viewport.orbit.distance=10
    viewport_camera(&viewport)
    start:=mm.Transform{position={0,0,0},rotation=1,scale={1,1,1}}
    g:=gizmo_place(&viewport,start.position,start.rotation,false,nil)
    if !testing.expect(t,g.visible && g.usable[0]) {return}
    // Grab the X arrow halfway along it and drag it to its end.
    viewport.pointer=(g.screen+g.ends[0])*0.5
    testing.expect_value(t,gizmo_hit(g,.Move,&viewport,viewport.pointer),Handle.X)
    drag,ok:=gizmo_drag_start(&viewport,g,.X,.Move)
    if !testing.expect(t,ok) {return}
    viewport.pointer=g.ends[0]
    move,radians,factor,snap,moved:=gizmo_delta(&viewport,&drag)
    testing.expect(t,moved)
    p:=tool_gizmo_apply(&viewport,&drag,start,move,radians,factor,snap)
    testing.expect(t,abs(p.position.x-g.size*0.5)<g.size*0.05 && abs(p.position.y)<1e-3 && abs(p.position.z)<1e-3,"along x, by what the pointer travelled")
    turn:=Gizmo_Drag{tool=.Rotate,handle=.Y,axes=g.axes}
    p=tool_gizmo_apply(&viewport,&turn,start,{},0.5,{1,1,1},false)
    testing.expect(t,mm.quat_angle(p.rotation,mm.quat_axis_angle({0,1,0},0.5))<1e-4)
    grow:=Gizmo_Drag{tool=.Scale,handle=.Y,axes=g.axes}
    p=tool_gizmo_apply(&viewport,&grow,start,{},0,{1,2,1},false)
    testing.expect(t,linalg.length(p.scale-[3]f32{1,2,1})<1e-5)
}
