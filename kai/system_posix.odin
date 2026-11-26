#+build darwin, linux
package kai

import "core:os"
import cnet "core:net"
import "core:strings"
import "core:sys/posix"

// The lock of a workspace: a file held open with an exclusive flock, which
// the system lets go when the process ends.
Lock :: struct {
    file:^os.File,
}

@(private)
lock_take :: proc(path:string) -> (lock:Lock,error:Error) {
    file,e:=os.open(path,{.Read,.Write,.Create})
    if e!=nil {return {},.Io}
    if !flock_exclusive(os.fd(file)) {
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

// What tells a file from another that took its place with the same size and
// time: its inode.
@(private)
file_inode :: proc(info:os.File_Info) -> u64 {return u64(info.inode)}

// Lets other sockets of this user bind the port too: every one of them gets
// a broadcast to it.
@(private)
socket_share_port :: proc(socket:cnet.UDP_Socket) -> bool {
    on:i32=1
    return posix.setsockopt(posix.FD(socket),posix.SOL_SOCKET,posix.Sock_Option(SO_REUSEPORT),&on,size_of(on))==.OK
}




// The broadcast address of every IPv4 network this machine is on. A beacon
// goes to each: the limited broadcast leaves through one interface alone,
// the system's choice, which on a machine with several is often not the LAN.
@(private)
broadcasts4 :: proc(out:^[dynamic][4]u8) {
    interfaces,e:=cnet.enumerate_interfaces(context.temp_allocator)
    if e!=nil {return}
    for interface in interfaces {
        if cnet.Link_States.Up not_in interface.link.state {continue}
        for lease in interface.unicast {
            ip,is_ip4:=lease.address.(cnet.IP4_Address)
            mask,has_mask:=cnet.Address(lease.netmask).(cnet.IP4_Address)
            if is_ip4 && has_mask {broadcast4_add(out,([4]u8)(ip),transmute(u32be)mask)}
        }
    }
}

// This machine's host name, in buffer; empty when the system gives none.
@(private)
host_name :: proc(buffer:[]u8) -> string {
    if len(buffer)<2 || posix.gethostname(raw_data(buffer),uint(len(buffer)-1))!=.OK {return ""}
    n:=0
    for n<len(buffer) && buffer[n]!=0 {n+=1}
    return string(buffer[:n])
}
