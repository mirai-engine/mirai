package input

import "core:math"
import "core:testing"
import "mirai:core"
import mm "mirai:std/math"

// The aim of a body is the view its seat saw the tick through, placed on the
// body: the eye from the body and the look in the frame of its vertical. A
// body no seat drives, or whose seat saw through no camera, has none.
@(test)
aim_is_the_view_of_the_seat_placed_on_its_body :: proc(t:^testing.T) {
    w:Test_Seats
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    body,other,seat:=core.create(&w.entities),core.create(&w.entities),core.create(&w.entities)
    core.add(&w.seats,seat,Seat{body=body})
    core.add(&w.worlds,body,core.World_Transform{transform={position={1,0,2},rotation=1,scale=1}})
    core.add(&w.worlds,other,core.World_Transform{transform={rotation=1,scale=1}})
    core.add(&w.verticals,body,core.Vertical{frame=1})
    test_world_settle(&w)
    input_seat_index(core.ref(&w.entities),core.read(&w.seats),&w.seat_state,nil)
    aims:=Aims{core.ref(&w.seat_state),core.ref(&w.runtime),core.read(&w.worlds),core.read(&w.verticals)}
    upside:=mm.quat_axis_angle({0,0,1},math.PI)
    Case :: struct {view:Seat_View,vertical:mm.Quat,origin,direction:[3]f32}
    for c in ([]Case{
        {{kind=.Body},1,{1,0,2},{0,0,-1}},
        {{yaw=-math.PI/2,eye={0,1.6,0},kind=.Apart},1,{1,1.6,2},{1,0,0}},
        {{yaw=math.PI/2,pitch=math.PI/4,eye={0.5,1,3},kind=.Apart},1,{1.5,1,5},{-math.SQRT_TWO/2,math.SQRT_TWO/2,0}},
        // Upside down on a ceiling: the eye and the look turn with the vertical of the body.
        {{pitch=math.PI/2-0.001,eye={0,1.6,0},kind=.Body},upside,{1,-1.6,2},{0,-1,0}},
    }) {
        core.edit(&w.verticals,body).frame=c.vertical
        seat_runtime_edit(&w.runtime,seat).view=c.view
        origin,direction,rotation,ok:=aim(aims,body)
        testing.expectf(t,ok && linalg_near(origin,c.origin) && linalg_near(direction,c.direction,1e-3),"%v: %v %v",c.view,origin,direction)
        testing.expectf(t,linalg_near(mm.quat_forward(rotation),direction),"%v: the rotation looks along the direction",c.view)
    }
    seat_runtime_edit(&w.runtime,seat).view={}
    _,_,_,ok:=aim(aims,body)
    testing.expect(t,!ok,"a seat that saw through no camera has no aim")
    _,_,_,ok=aim(aims,other)
    testing.expect(t,!ok,"a body no seat drives has no aim")
}

@(private="file")
linalg_near :: proc(a,b:[3]f32,within:f32=1e-4) -> bool {
    d:=a-b
    return d.x*d.x+d.y*d.y+d.z*d.z<=within*within
}

// A kick turns the look of the Move_Input of its body in the next tick, adding to where it looks;
// a body without one is left alone, and a kick that names none or turns more than half a turn is
// refused.
@(test)
a_look_kick_turns_the_look_of_its_body :: proc(t:^testing.T) {
    w:Test_Seats
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    body,other:=core.create(&w.entities),core.create(&w.entities)
    core.add(&w.moves,body,Move_Input{look_yaw=math.PI-0.01,look_pitch=0.1})
    test_world_settle(&w)
    problems:core.Problems
    look_kick(&w.kicks,body,0.02,0.05)
    look_kick(&w.kicks,body,0,0.05)
    look_kick(&w.kicks,other,0.5,0.5)
    look_kick(&w.kicks,core.NONE,0,0.1)
    look_kick(&w.kicks,body,0,f32(0h7fc00000))
    look_kick(&w.kicks,body,4,0)
    input_look_kicks(&w.kicks,&w.moves,&problems)
    test_world_settle(&w)
    move,_:=core.get(&w.moves,body)
    testing.expectf(t,abs(move.look_yaw-(-math.PI+0.01))<1e-5 && abs(move.look_pitch-0.2)<1e-5,"%v",move)
    testing.expect(t,!core.has(&w.moves,other))
    testing.expect(t,core.problem_find(&problems,core.NONE,"input.look_kicks")!=nil,"the refused kicks are reported")
    // Nothing asked: nothing written.
    version:=w.moves.version
    input_look_kicks(&w.kicks,&w.moves,&problems)
    testing.expect_value(t,w.moves.version,version)
}
