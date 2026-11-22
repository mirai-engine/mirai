package tls

import "core:net"
import "core:time"

// The Transport of the system's TCP: a stream is a socket, and a read or a write that waits
// longer than TCP_TIMEOUT fails.
TCP_TRANSPORT :: Transport{dial=tcp_dial,read=tcp_read,write=tcp_write,close=tcp_close}

@(private) TCP_TIMEOUT :: 30*time.Second

@(private)
tcp_dial :: proc(data:rawptr,host:string,port:int) -> (stream:uintptr,ok:bool) {
    socket,err:=net.dial_tcp_from_hostname_with_port_override(host,port)
    if err!=nil {return 0,false}
    if net.set_option(socket,.Receive_Timeout,TCP_TIMEOUT)!=nil || net.set_option(socket,.Send_Timeout,TCP_TIMEOUT)!=nil {
        net.close(socket)
        return 0,false
    }
    return uintptr(socket),true
}

@(private)
tcp_read :: proc(data:rawptr,stream:uintptr,buffer:[]u8) -> (count:int,ok:bool) {
    n,err:=net.recv_tcp(net.TCP_Socket(stream),buffer)
    return n,err==nil
}

@(private)
tcp_write :: proc(data:rawptr,stream:uintptr,bytes:[]u8) -> bool {
    for at:=0;at<len(bytes); {
        n,err:=net.send_tcp(net.TCP_Socket(stream),bytes[at:])
        if err!=nil || n<=0 {return false}
        at+=n
    }
    return true
}

@(private)
tcp_close :: proc(data:rawptr,stream:uintptr) {net.close(net.TCP_Socket(stream))}
