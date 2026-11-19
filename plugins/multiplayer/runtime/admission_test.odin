package multiplayer

import "base:runtime"
import "core:log"
import "core:reflect"
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
    private:wire.Key
    private[0]=7
    key:=wire.invite_key_from(&private,7)
    code:=wire.invite_encode({lan=wire.address_loopback(9),key={public=key.public,secret=key.secret}},context.temp_allocator)
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

// The private key of a server's invitation never sits in a storage of the
// World: what a World is asked to open carries no key, invite_give hands it to
// the session, and the session zeroes it when it ends.
@(test)
the_key_of_an_invitation_skips_the_world_and_ends_with_its_session :: proc(t:^testing.T) {
    holds_key :: proc(info:^runtime.Type_Info) -> bool {
        named:=reflect.type_info_base(info)
        if named.id==typeid_of(wire.Invite_Key) || named.id==typeid_of(wire.Key) {return true}
        if s,is_struct:=named.variant.(runtime.Type_Info_Struct);is_struct {
            for i in 0..<s.field_count {
                if holds_key(s.types[i]) {return true}
            }
        }
        return false
    }
    testing.expect(t,!holds_key(type_info_of(Session_Request)),"Session_Request carries a key")
    private:wire.Key
    private[3]=9
    key:=wire.invite_key_from(&private,11)
    s:Net_Session
    s.allocator=context.allocator
    invite_give(&s,key)
    testing.expect(t,s.invite==key)
    session_destroy(&s)
    testing.expect(t,s.invite==wire.Invite_Key{})
}
