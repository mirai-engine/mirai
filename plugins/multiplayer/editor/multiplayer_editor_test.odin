package multiplayer_editor

import "core:testing"
import wire "mirai:net"
import "mirai:std/base"

// The code play.network.status returns is the whole code: it decodes to the invitation of the server.
@(test)
the_code_play_network_status_returns_reads_as_the_invitation :: proc(t:^testing.T) {
    key,made:=wire.invite_key()
    if !testing.expect(t,made) {return}
    invitation:=wire.Invitation{lan=wire.address_ip4(192,168,1,2,27500),public=wire.address_ip4(203,0,113,9,27500),key={public=key.public,secret=key.secret}}
    r:Api_Network_Result
    testing.expect(t,base.text_set(r.invite[:],wire.invite_encode(invitation,context.temp_allocator)))
    got,refused:=wire.invite_decode(base.text_get(r.invite[:]))
    testing.expect(t,refused==.None && got==invitation)
}
