package mirai_input

import "core:testing"
import "mirai:std/base"
import math "mirai:std/math"

@(private="file")
near :: proc(a,b:f32,eps:f32=1e-4) -> bool {return abs(a-b)<=eps}
@(private="file")
near_vec :: proc(a,b:$V/[$N]f32,eps:f32=1e-4) -> bool {
    for i in 0..<N {if abs(a[i]-b[i])>eps {return false}}
    return true
}

KEY_SPACE :: Input_Code(32)
KEY_A :: Input_Code(65)
KEY_D :: Input_Code(68)
KEY_W :: Input_Code(87)
KEY_S :: Input_Code(83)
KEY_E :: Input_Code(69)

TEST_DT :: f32(1.0/60)

input_make :: proc(t:^testing.T) -> Input {
    in_:Input
    testing.expect(t,input_init(&in_,{max_actions=8,max_bindings=12}))
    return in_
}
step :: proc(in_:^Input,codes:[]Input_Code,down:bool) {
    for code in codes {input_set_code(in_,code,down)}
    input_update(in_,TEST_DT)
}

@(test)
button_reports_pressed_held_and_released_on_the_right_ticks :: proc(t:^testing.T) {
    in_:=input_make(t)
    defer input_destroy(&in_)
    jump:=input_add_action(&in_,.Button,base.name_hash("jump"))
    testing.expect(t,input_bind_code(&in_,jump,KEY_SPACE))
    input_update(&in_,TEST_DT)
    testing.expect(t,!action_down(&in_,jump) && !action_pressed(&in_,jump))
    step(&in_,{KEY_SPACE},true)
    testing.expect(t,action_down(&in_,jump) && action_pressed(&in_,jump) && !action_released(&in_,jump))
    testing.expect(t,near(action_value(&in_,jump),1) && action_state(&in_,jump).held==TEST_DT)
    input_update(&in_,TEST_DT)
    testing.expect(t,action_down(&in_,jump) && !action_pressed(&in_,jump) && near(action_state(&in_,jump).held,2*TEST_DT))
    step(&in_,{KEY_SPACE},false)
    testing.expect(t,!action_down(&in_,jump) && action_released(&in_,jump) && action_state(&in_,jump).held==0)
    input_update(&in_,TEST_DT)
    testing.expect(t,!action_released(&in_,jump))
    testing.expect_value(t,input_find_action(&in_,base.name_hash("jump")),jump)
    testing.expect_value(t,input_find_action(&in_,base.name_hash("fly")),Action(0))
}

@(test)
a_press_and_release_between_two_updates_is_not_lost :: proc(t:^testing.T) {
    in_:=input_make(t)
    defer input_destroy(&in_)
    jump:=input_add_action(&in_,.Button)
    input_bind_code(&in_,jump,KEY_SPACE)
    input_set_code(&in_,KEY_SPACE,true)
    input_set_code(&in_,KEY_SPACE,false)
    input_update(&in_,TEST_DT)
    state:=action_state(&in_,jump)
    testing.expect(t,state.pressed && state.released && state.tapped && !state.down)
    input_update(&in_,TEST_DT)
    testing.expect(t,action_state(&in_,jump)==Action_State{})
}

// The tap and the hold are thresholds in seconds: at 60 and at 120 Hz they
// come at the tick nearest to TAP_SECONDS and HOLD_SECONDS.
@(test)
tap_and_hold_are_told_apart_by_how_long_the_button_was_down :: proc(t:^testing.T) {
    for hz in ([]f32{60,120}) {
        dt:=1/hz
        tap,hold:=int(TAP_SECONDS*hz+0.5),int(HOLD_SECONDS*hz+0.5)
        in_:=input_make(t)
        defer input_destroy(&in_)
        act:=input_add_action(&in_,.Button)
        input_bind_code(&in_,act,KEY_E)
        for ticks in ([]int{tap,tap+1}) {
            input_set_code(&in_,KEY_E,true)
            for _ in 0..<ticks {input_update(&in_,dt)}
            input_set_code(&in_,KEY_E,false)
            input_update(&in_,dt)
            testing.expectf(t,action_released(&in_,act) && action_tapped(&in_,act)==(ticks==tap),"%v Hz, held %d ticks",hz,ticks)
            testing.expect(t,near(action_state(&in_,act).released_held,f32(ticks)*dt))
        }
        input_set_code(&in_,KEY_E,true)
        for tick in 1..=hold+2 {
            input_update(&in_,dt)
            testing.expectf(t,action_hold_started(&in_,act)==(tick==hold) && action_holding(&in_,act)==(tick>=hold),"%v Hz, tick %d",hz,tick)
        }
    }
}

@(test)
several_codes_drive_one_button_and_unbind_removes_them :: proc(t:^testing.T) {
    in_:=input_make(t)
    defer input_destroy(&in_)
    fire:=input_add_action(&in_,.Button)
    input_bind_code(&in_,fire,KEY_E)
    input_bind_code(&in_,fire,code_gamepad(1,3))
    step(&in_,{code_gamepad(1,3)},true)
    testing.expect(t,action_pressed(&in_,fire))
    step(&in_,{KEY_E},true) // a second code while the first is held is not a new press
    testing.expect(t,action_down(&in_,fire) && !action_pressed(&in_,fire))
    step(&in_,{code_gamepad(1,3)},false)
    testing.expect(t,action_down(&in_,fire) && !action_released(&in_,fire))
    step(&in_,{KEY_E},false)
    testing.expect(t,action_released(&in_,fire))
    input_unbind(&in_,fire)
    testing.expect_value(t,in_.binding_count,0)
    step(&in_,{KEY_E},true)
    testing.expect(t,!action_down(&in_,fire))
}

@(test)
analog_axes_apply_scale_and_dead_zone_continuously :: proc(t:^testing.T) {
    in_:=input_make(t)
    defer input_destroy(&in_)
    look:=input_add_action(&in_,.Axis)
    testing.expect(t,input_bind_axis(&in_,look,axis_gamepad(0,2),0.2))
    for sample in ([][2]f32{{0.1,0},{0.2,0},{0.6,0.5},{1,1},{-0.6,-0.5},{-1,-1},{3,1}}) {
        input_set_axis(&in_,axis_gamepad(0,2),sample[0])
        input_update(&in_,TEST_DT)
        testing.expectf(t,near(action_value(&in_,look),sample[1]),"axis %f read %f",sample[0],action_value(&in_,look))
    }
    testing.expect(t,action_down(&in_,look))
    inverted:=input_add_action(&in_,.Axis)
    input_bind_axis(&in_,inverted,axis_gamepad(0,2),0,-1)
    input_update(&in_,TEST_DT)
    testing.expect(t,near(action_value(&in_,inverted),-1))
    input_set_axis(&in_,axis_gamepad(0,2),0)
    input_update(&in_,TEST_DT)
    testing.expect(t,!action_down(&in_,look) && action_released(&in_,look))
}

@(test)
two_codes_make_an_axis_and_the_largest_binding_wins :: proc(t:^testing.T) {
    in_:=input_make(t)
    defer input_destroy(&in_)
    turn:=input_add_action(&in_,.Axis)
    input_bind_codes_axis(&in_,turn,KEY_A,KEY_D)
    input_bind_axis(&in_,turn,axis_gamepad(0,0),0.1)
    step(&in_,{KEY_D},true)
    testing.expect(t,near(action_value(&in_,turn),1))
    step(&in_,{KEY_A},true)
    testing.expect(t,near(action_value(&in_,turn),0))
    step(&in_,{KEY_D},false)
    testing.expect(t,near(action_value(&in_,turn),-1))
    input_set_axis(&in_,axis_gamepad(0,0),0.55)
    step(&in_,{KEY_A},false)
    testing.expect(t,near(action_value(&in_,turn),0.5))
    scaled:=input_add_action(&in_,.Axis)
    input_bind_codes_axis(&in_,scaled,KEY_A,KEY_D,2)
    step(&in_,{KEY_D},true)
    testing.expect(t,near(action_value(&in_,scaled),2))
}

@(test)
four_codes_make_a_2d_action_with_unit_diagonals :: proc(t:^testing.T) {
    in_:=input_make(t)
    defer input_destroy(&in_)
    move:=input_add_action(&in_,.Axis2)
    testing.expect(t,input_bind_codes_2d(&in_,move,KEY_A,KEY_D,KEY_S,KEY_W))
    step(&in_,{KEY_W},true)
    testing.expect(t,near_vec(action_vector(&in_,move),math.Vec2{0,1}) && action_pressed(&in_,move))
    step(&in_,{KEY_D},true)
    testing.expect(t,near_vec(action_vector(&in_,move),math.Vec2{0.70710678,0.70710678}) && near(action_value(&in_,move),1))
    step(&in_,{KEY_A},true)
    testing.expect(t,near_vec(action_vector(&in_,move),math.Vec2{0,1}))
    step(&in_,{KEY_S},true)
    testing.expect(t,near_vec(action_vector(&in_,move),math.Vec2{}) && action_released(&in_,move))
}

@(test)
analog_sticks_use_a_radial_dead_zone :: proc(t:^testing.T) {
    in_:=input_make(t)
    defer input_destroy(&in_)
    move:=input_add_action(&in_,.Axis2)
    testing.expect(t,input_bind_axes_2d(&in_,move,axis_gamepad(0,0),axis_gamepad(0,1),0.2))
    input_set_axis(&in_,axis_gamepad(0,0),0.14);input_set_axis(&in_,axis_gamepad(0,1),0.14)
    input_update(&in_,TEST_DT)
    testing.expect(t,action_vector(&in_,move)==math.Vec2{}) // the length is 0.198
    input_set_axis(&in_,axis_gamepad(0,0),0.1);input_set_axis(&in_,axis_gamepad(0,1),0.1)
    input_update(&in_,TEST_DT)
    testing.expect(t,action_vector(&in_,move)==math.Vec2{})
    input_set_axis(&in_,axis_gamepad(0,0),0.6);input_set_axis(&in_,axis_gamepad(0,1),0)
    input_update(&in_,TEST_DT)
    testing.expect(t,near_vec(action_vector(&in_,move),math.Vec2{0.5,0}))
    input_set_axis(&in_,axis_gamepad(0,0),1);input_set_axis(&in_,axis_gamepad(0,1),1)
    input_update(&in_,TEST_DT)
    testing.expect(t,near_vec(action_vector(&in_,move),math.Vec2{0.70710678,0.70710678}) && near(action_value(&in_,move),1))
}

@(test)
a_trigger_can_press_a_button_action :: proc(t:^testing.T) {
    in_:=input_make(t)
    defer input_destroy(&in_)
    aim:=input_add_action(&in_,.Button)
    testing.expect(t,input_bind_axis_button(&in_,aim,axis_gamepad(0,4),0.5))
    input_set_axis(&in_,axis_gamepad(0,4),0.4)
    input_update(&in_,TEST_DT)
    testing.expect(t,!action_down(&in_,aim))
    input_set_axis(&in_,axis_gamepad(0,4),0.5)
    input_update(&in_,TEST_DT)
    testing.expect(t,action_pressed(&in_,aim))
    input_set_axis(&in_,axis_gamepad(0,4),0)
    input_update(&in_,TEST_DT)
    testing.expect(t,action_released(&in_,aim))
}

@(test)
releasing_everything_lets_go_of_held_codes_and_axes :: proc(t:^testing.T) {
    in_:=input_make(t)
    defer input_destroy(&in_)
    run:=input_add_action(&in_,.Button)
    look:=input_add_action(&in_,.Axis)
    input_bind_code(&in_,run,KEY_W)
    input_bind_axis(&in_,look,Axis_Code(3),0)
    step(&in_,{KEY_W},true)
    input_set_axis(&in_,Axis_Code(3),1)
    input_update(&in_,TEST_DT)
    testing.expect(t,action_down(&in_,run) && action_down(&in_,look))
    input_release_all(&in_)
    input_update(&in_,TEST_DT)
    testing.expect(t,!action_down(&in_,run) && !action_down(&in_,look) && action_released(&in_,run) && action_released(&in_,look))
}

@(test)
input_refuses_what_does_not_fit_or_does_not_match :: proc(t:^testing.T) {
    in_:Input
    testing.expect(t,input_init(&in_,{max_actions=2,max_bindings=2,code_count=100,axis_count=4}))
    defer input_destroy(&in_)
    button:=input_add_action(&in_,.Button)
    axis:=input_add_action(&in_,.Axis)
    testing.expect_value(t,input_add_action(&in_,.Axis2),Action(0))
    testing.expect(t,!input_bind_code(&in_,button,Input_Code(100))) // out of range
    testing.expect(t,!input_bind_axis(&in_,axis,Axis_Code(4)))
    testing.expect(t,!input_bind_code(&in_,axis,KEY_A)) // the wrong kind of action
    testing.expect(t,!input_bind_axis(&in_,button,Axis_Code(0)))
    testing.expect(t,!input_bind_code(&in_,0,KEY_A) && !input_bind_code(&in_,Action(9),KEY_A))
    testing.expect(t,input_bind_code(&in_,button,KEY_A) && input_bind_code(&in_,button,KEY_E))
    testing.expect(t,!input_bind_code(&in_,button,KEY_S)) // out of bindings
    testing.expect_value(t,in_.failed,u64(8))
    testing.expect(t,!input_set_code(&in_,Input_Code(100),true) && !input_set_axis(&in_,Axis_Code(4),1))
    testing.expect(t,action_state(&in_,0)==Action_State{} && action_state(&in_,Action(9))==Action_State{})
    bad:Input
    testing.expect(t,!input_init(&bad,{}) && !input_init(&bad,{max_actions=1,max_bindings=1,code_count=70000}))
    input_unbind(&in_,0)
    input_update(&bad,TEST_DT)
}

@(test)
unbounded_axes_pass_through_scaled_without_dead_zone_or_limit :: proc(t:^testing.T) {
    in_:Input
    testing.expect(t,input_init(&in_,{max_actions=2,max_bindings=2,axis_count=8}))
    defer input_destroy(&in_)
    scroll:=input_add_action(&in_,.Axis)
    look:=input_add_action(&in_,.Axis2)
    testing.expect(t,input_bind_delta(&in_,scroll,Axis_Code(2),2) && input_bind_delta_2d(&in_,look,Axis_Code(0),Axis_Code(1),0.5))
    testing.expect(t,!input_bind_delta(&in_,look,Axis_Code(0)) && !input_bind_delta_2d(&in_,look,Axis_Code(0),Axis_Code(8)))
    input_set_axis(&in_,Axis_Code(0),30)
    input_set_axis(&in_,Axis_Code(1),-40)
    input_set_axis(&in_,Axis_Code(2),0.05)
    input_update(&in_,TEST_DT)
    testing.expect_value(t,action_vector(&in_,look),[2]f32{15,-20})
    testing.expect_value(t,action_value(&in_,look),25)
    testing.expect_value(t,action_value(&in_,scroll),0.1)
    testing.expect(t,action_pressed(&in_,look))
}

// Ctrl+S saves without stepping back or crouching; S alone steps back, and
// Ctrl alone crouches while the chord is not in use.
@(test)
a_held_chord_takes_its_codes_from_the_shorter_bindings :: proc(t:^testing.T) {
    KEY_CTRL :: Input_Code(17)
    in_:=input_make(t)
    defer input_destroy(&in_)
    back:=input_add_action(&in_,.Button)
    crouch:=input_add_action(&in_,.Button)
    save:=input_add_action(&in_,.Button)
    testing.expect(t,input_bind_code(&in_,back,KEY_S) && input_bind_code(&in_,crouch,KEY_CTRL))
    testing.expect(t,input_bind_code(&in_,save,KEY_S) && input_chord(&in_,KEY_CTRL))
    step(&in_,{KEY_S},true)
    testing.expect(t,action_pressed(&in_,back) && !action_down(&in_,save),"S alone steps back")
    step(&in_,{KEY_S},false)
    step(&in_,{KEY_CTRL},true)
    testing.expect(t,action_pressed(&in_,crouch) && !action_down(&in_,save),"Ctrl alone crouches")
    step(&in_,{KEY_S},true)
    testing.expect(t,action_pressed(&in_,save) && !action_down(&in_,back) && action_released(&in_,crouch),"Ctrl+S saves and nothing else")
    step(&in_,{KEY_CTRL},false)
    testing.expect(t,action_released(&in_,save) && action_pressed(&in_,back),"S, still held, steps back once the chord lets go")

    // The wheel scrolls, and with Shift held zooms instead.
    KEY_SHIFT :: Input_Code(16)
    wheel:Input
    testing.expect(t,input_init(&wheel,{max_actions=2,max_bindings=2,axis_count=8}))
    defer input_destroy(&wheel)
    scroll:=input_add_action(&wheel,.Axis)
    zoom:=input_add_action(&wheel,.Axis)
    testing.expect(t,input_bind_delta(&wheel,scroll,Axis_Code(3)) && input_bind_delta(&wheel,zoom,Axis_Code(3)) && input_chord(&wheel,KEY_SHIFT))
    input_set_axis(&wheel,Axis_Code(3),2)
    input_update(&wheel,TEST_DT)
    testing.expect(t,action_value(&wheel,scroll)==2 && action_value(&wheel,zoom)==0)
    input_set_code(&wheel,KEY_SHIFT,true)
    input_update(&wheel,TEST_DT)
    testing.expect(t,action_value(&wheel,scroll)==0 && action_value(&wheel,zoom)==2)
}

@(test)
a_chord_needs_a_binding_and_codes_that_fit :: proc(t:^testing.T) {
    in_:Input
    testing.expect(t,input_init(&in_,{max_actions=1,max_bindings=1,code_count=100}))
    defer input_destroy(&in_)
    jump:=input_add_action(&in_,.Button)
    testing.expect(t,!input_chord(&in_,KEY_A),"no binding yet")
    testing.expect(t,input_bind_code(&in_,jump,KEY_SPACE))
    testing.expect(t,!input_chord(&in_) && !input_chord(&in_,KEY_A,KEY_D,KEY_E) && !input_chord(&in_,Input_Code(100)))
    testing.expect_value(t,in_.failed,u64(4))
    testing.expect(t,input_chord(&in_,KEY_A,KEY_D))
}
