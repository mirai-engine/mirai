package mirai_net

import "core:testing"
import "core:time"

@(test)
addresses_parse_with_brackets_and_map_ipv4_peers_of_ipv6_sockets :: proc(t:^testing.T) {
    a,ok:=address_parse("[::1]:7777")
    testing.expect(t,ok && a==address_loopback6(7777))
    a,ok=address_parse("[2001:db8::42]:80")
    testing.expect(t,ok && a.kind==.IP6 && a.port==80 && a.ip[0]==0x20 && a.ip[1]==0x01 && a.ip[15]==0x42)
    a,ok=address_parse("10.1.2.3:5")
    testing.expect(t,ok && a==address_ip4(10,1,2,3,5))
    _,ok=address_parse("[::1:7777")
    testing.expect(t,!ok)
    // A peer that reached a dual-stack socket by IPv4 shows its IPv4 address.
    mapped,_:=address_parse("[::ffff:192.168.0.9]:9")
    testing.expect_value(t,mapped,address_ip4(192,168,0,9,9))
}

@(test)
a_dual_stack_socket_talks_to_ipv4_and_ipv6_peers :: proc(t:^testing.T) {
    server:Udp
    if !testing.expect(t,udp_open(&server,address_any6(0)),"cannot bind [::]") {return}
    defer udp_close(&server)
    testing.expect(t,server.dual && server.address.port!=0)
    port:=int(server.address.port)
    for peer_address in ([2]Address{address_loopback(0),address_loopback6(0)}) {
        peer:Udp
        if !udp_open(&peer,peer_address) {
            testing.expectf(t,false,"cannot bind %v",peer_address)
            continue
        }
        defer udp_close(&peer)
        to:=peer_address.kind==.IP4?address_loopback(port):address_loopback6(port)
        testing.expect(t,udp_send(&peer,to,{1,2,3}))
        buffer:[PACKET_BYTES]u8
        size:int
        from:Address
        got:=false
        for _ in 0..<200 {
            if size,from,got=udp_receive(&server,buffer[:]);got {break}
            time.sleep(time.Millisecond)
        }
        testing.expectf(t,got && size==3 && from.kind==peer_address.kind,"from %v",from)
        // The answer goes back to that address, mapped again for an IPv4 peer.
        testing.expect(t,udp_send(&server,from,{9}))
        back:=false
        for _ in 0..<200 {
            if _,_,back=udp_receive(&peer,buffer[:]);back {break}
            time.sleep(time.Millisecond)
        }
        testing.expectf(t,back,"no answer to %v",from)
    }
}

@(test)
a_host_name_resolves_on_its_own_thread :: proc(t:^testing.T) {
    r:Resolve
    testing.expect(t,resolve_start(&r,"localhost:7777"))
    defer resolve_end(&r)
    addresses:[]Address
    done:=false
    for _ in 0..<5000 {
        if addresses,done=resolve_poll(&r);done {break}
        time.sleep(time.Millisecond)
    }
    testing.expect(t,done && len(addresses)>0)
    for a in addresses {testing.expect(t,a.port==7777 && (a==address_loopback(7777) || a==address_loopback6(7777)))}
    literal:Resolve
    testing.expect(t,resolve_start(&literal,"[::1]:9"))
    for _ in 0..<1000 {
        if addresses,done=resolve_poll(&literal);done {break}
        time.sleep(time.Millisecond)
    }
    testing.expect(t,done && len(addresses)==1 && addresses[0]==address_loopback6(9))
    resolve_end(&literal)
}
