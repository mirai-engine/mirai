package multiplayer

import "core:log"
import "core:strings"
import "core:testing"
import "mirai:core"
import "mirai:host"
import wire "mirai:net"

// What a player reads when it cannot join says what to do: a code with a
// character changed is no code, and a server that does not answer a code or an
// address names how to get in.
@(test)
a_client_that_cannot_join_is_told_what_to_do :: proc(t:^testing.T) {
    code:=wire.invite_encode({lan=wire.address_loopback(9),token=7},context.temp_allocator)
    typo:=transmute([]u8)strings.clone(code,context.temp_allocator)
    typo[0]=typo[0]=='Z'?'Y':'Z'
    info,described:=net_test_info(t)
    if !described {return}
    defer test_info_destroy(&info)
    world:Net_Test_World
    net_test_init(&world,&info);defer core.world_destroy(&info,.World,&world)
    app:=host.App{info=&info,allocator=context.allocator,tick_dt=1.0/60}
    defer {host.app_world_scratch_free(&app);delete(app.worlds)}
    s:Net_Session
    copy(world.request.open.connect[:],typo)
    logger:=context.logger
    context.logger=log.nil_logger()
    session_start(&s,core.world_ref(&world,&info),&app,&Net_Settings{})
    context.logger=logger
    defer delete(s.reason_text,app.allocator)
    testing.expectf(t,s.ended && strings.contains(s.reason_text,"copy it again"),"%s",s.reason_text)
    Case :: struct {connect,says:string}
    for c in ([]Case{{code,"ask its host for the current code"},{"127.0.0.1:9","the code its host shows"}}) {
        text:=reason_text(.Connect_Timeout,c.connect,0)
        testing.expectf(t,strings.contains(text,c.says),"%s",text)
    }
}
