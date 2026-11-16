package editor

import "core:testing"
import "mirai:core"

Follow_Test_Provider :: struct {provider:Edit_Follow_Provider}
follow_test_provider_default :: proc() -> Follow_Test_Provider {return {provider={follow=proc(s:^Session) {notify(s,"followed")}}}}

@(private)
@(test_world,editor="Follow_Test_Editor")
Follow_Test_World :: struct {using world:Test_World,ids:core.Table(core.Id)}

@(private)
Follow_Test_Editor :: struct {provider:Follow_Test_Provider}

@(test)
a_gesture_about_to_be_recorded_lets_the_plugins_derive_what_follows_it :: proc(t:^testing.T) {
    info,described:=test_info(t,Follow_Test_World)
    if !described {return}
    defer test_info_destroy(&info)
    session:=Session{info=&info}
    edits_follow(&session)
    testing.expect_value(t,string(session.toast[:session.toast_length]),"followed")
    // Out of Edit, nothing is recorded and nothing follows.
    session.toast_length=0
    session.mode=.Play
    edits_follow(&session)
    testing.expect_value(t,session.toast_length,0)
}