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

// A relay address keeps its node, IPv4 or IPv6, and the key of the peer behind it; it is another
// address for each peer, and only a node with a port and a peer make one.
@(test)
relay_addresses_round_trip_their_node_and_peer :: proc(t:^testing.T) {
    peer,other:Key
    for &b,i in peer {b=u8(i+1)}
    other=peer
    other[0]~=1
    v6,_:=address_parse("[2001:db8::7]:4000")
    for node in ([2]Address{address_ip4(203,0,113,9,4000),v6}) {
        relay,ok:=address_relay(node,peer)
        testing.expect(t,ok && relay.kind==.Relay)
        back,behind,is_relay:=address_relay_node(relay)
        testing.expect(t,is_relay && back==node && behind==peer)
        second,_:=address_relay(node,other)
        testing.expect(t,second!=relay)
    }
    no_port:=address_ip4(1,2,3,4,0)
    relay,_:=address_relay(v6,peer)
    for node in ([4]Address{{},address_memory(1),no_port,relay}) {
        _,made:=address_relay(node,peer)
        testing.expectf(t,!made,"%v makes no relay",node)
    }
    _,made:=address_relay(v6,{})
    testing.expect(t,!made)
    _,_,is_relay:=address_relay_node(v6)
    testing.expect(t,!is_relay)
}

// Only a public IPv4 address or a global unicast IPv6 one reaches across the internet; what this
// machine finds as its global IPv6 address is one, or none.
@(test)
global_addresses_are_public_ipv4_and_global_unicast_ipv6 :: proc(t:^testing.T) {
    cases:=[]struct{text:string,global:bool}{
        {"8.8.8.8:1",true},{"10.0.0.1:1",false},{"192.168.1.2:1",false},{"100.64.0.1:1",false},
        {"[2606:4700::1111]:1",true},{"[::1]:1",false},{"[fe80::1]:1",false},{"[fd00::1]:1",false},
        {"[::ffff:8.8.8.8]:1",true},{"[ff02::1]:1",false},
    }
    for c in cases {
        a,ok:=address_parse(c.text)
        testing.expectf(t,ok && address_global(a)==c.global,"%s",c.text)
    }
    found:=address_global6(7777)
    testing.expectf(t,found.kind==.None || found.kind==.IP6 && found.port==7777 && address_global(found),"%v",found)
}
