package kai

import "core:os"
import win "core:sys/windows"
import cnet "core:net"

// The lock of a workspace: a file held open with an exclusive LockFileEx,
// which the system lets go when the process ends.
Lock :: struct {
    file:^os.File,
}

@(private)
lock_take :: proc(path:string) -> (lock:Lock,error:Error) {
    file,e:=os.open(path,{.Read,.Write,.Create})
    if e!=nil {return {},.Io}
    overlapped:win.OVERLAPPED
    if !win.LockFileEx(win.HANDLE(os.fd(file)),win.LOCKFILE_EXCLUSIVE_LOCK|win.LOCKFILE_FAIL_IMMEDIATELY,0,1,0,&overlapped) {
        os.close(file)
        return {},.Locked
    }
    return {file},.None
}

@(private)
lock_release :: proc(lock:^Lock) {
    if lock.file==nil {return}
    os.close(lock.file)
    lock^={}
}

// ReFS block cloning (FSCTL_DUPLICATE_EXTENTS_TO_FILE) is not used yet: a
// switch writes the file from the store instead.
file_clone :: proc(from,to:string) -> Error {
    return .Unsupported
}

// Lets other sockets of this user bind the port too: SO_REUSEADDR does it on
// Windows, and every one of them gets a broadcast to it.
@(private)
socket_share_port :: proc(socket:cnet.UDP_Socket) -> bool {
    on:win.BOOL=true
    return win.setsockopt(win.SOCKET(uintptr(socket)),win.SOL_SOCKET,win.SO_REUSEADDR,&on,size_of(on))==0
}

@(private) ERROR_BUFFER_OVERFLOW :: 111

// Keeps an IPv6 socket, before its bind, to IPv6 alone.
@(private)
socket_ip6_only :: proc(socket:cnet.UDP_Socket) -> bool {
    on:win.DWORD=1
    return win.setsockopt(win.SOCKET(uintptr(socket)),win.IPPROTO_IPV6,win.IPV6_V6ONLY,&on,size_of(on))==0
}

// Lets an IPv6 socket take what is sent to the multicast group on the
// interface of index.
@(private)
socket_join6 :: proc(socket:cnet.UDP_Socket,group:[16]u8,index:u32) -> bool {
    m:=win.ipv6_mreq{ipv6mr_multiaddr={s6_addr=group},ipv6mr_interface=win.c_uint(index)}
    return win.setsockopt(win.SOCKET(uintptr(socket)),win.IPPROTO_IPV6,win.IPV6_ADD_MEMBERSHIP,&m,size_of(m))==0
}

// The indexes of the interfaces that are up and have an IPv6 address: where
// a link-local multicast goes out.
@(private)
interfaces6 :: proc(out:^[dynamic]u32) {
    size:u32=16*1024
    for _ in 0..<4 {
        buffer,e:=make([]u8,int(size),context.temp_allocator)
        if e!=nil {return}
        first:=(^win.IP_Adapter_Addresses)(raw_data(buffer))
        result:=win.GetAdaptersAddresses(.IPv6,{.Skip_Anycast,.Skip_Multicast,.Skip_DNS_Server,.Skip_Friendly_Name},nil,first,&size)
        if result==ERROR_BUFFER_OVERFLOW {continue}
        if result!=0 {return}
        for a:=first;a!=nil;a=a.Next {
            if a.OperStatus==.Up && a.Ipv6IfIndex!=0 && a.FirstUnicastAddress!=nil {append(out,a.Ipv6IfIndex)}
        }
        return
    }
}
