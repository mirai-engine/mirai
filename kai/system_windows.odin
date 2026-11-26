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

// What tells a file from another that took its place with the same size and
// time: nothing here. A folder's listing gives no file index, and one read
// from the file alone would differ from it in every row.
@(private)
file_inode :: proc(info:os.File_Info) -> u64 {return 0}

// Lets other sockets of this user bind the port too: SO_REUSEADDR does it on
// Windows, and every one of them gets a broadcast to it.
@(private)
socket_share_port :: proc(socket:cnet.UDP_Socket) -> bool {
    on:win.BOOL=true
    return win.setsockopt(win.SOCKET(uintptr(socket)),win.SOL_SOCKET,win.SO_REUSEADDR,&on,size_of(on))==0
}

@(private) ERROR_BUFFER_OVERFLOW :: 111



// The broadcast address of every IPv4 network this machine is on. A beacon
// goes to each: the limited broadcast leaves through one interface alone,
// the system's choice, which on a machine with several is often not the LAN.
@(private)
broadcasts4 :: proc(out:^[dynamic][4]u8) {
    size:u32=16*1024
    for _ in 0..<4 {
        buffer,e:=make([]u8,int(size),context.temp_allocator)
        if e!=nil {return}
        first:=(^win.IP_Adapter_Addresses)(raw_data(buffer))
        result:=win.GetAdaptersAddresses(.IPv4,{.Skip_Anycast,.Skip_Multicast,.Skip_DNS_Server,.Skip_Friendly_Name},nil,first,&size)
        if result==ERROR_BUFFER_OVERFLOW {continue}
        if result!=0 {return}
        for a:=first;a!=nil;a=a.Next {
            if a.OperStatus!=.Up {continue}
            for u:=a.FirstUnicastAddress;u!=nil;u=u.Next {
                address:=(^win.sockaddr_in)(u.Address.lpSockaddr)
                if address==nil || address.sin_family!=win.ADDRESS_FAMILY(win.AF_INET) || u.OnLinkPrefixLength>32 {continue}
                mask:=u.OnLinkPrefixLength==0?u32be(0):u32be(~u32(0)<<(32-u32(u.OnLinkPrefixLength)))
                broadcast4_add(out,transmute([4]u8)address.sin_addr.s_addr,mask)
            }
        }
        return
    }
}

// This machine's host name, in buffer; empty when the system gives none.
host_name :: proc(buffer:[]u8) -> string {
    name,found:=os.lookup_env("COMPUTERNAME",context.temp_allocator)
    if !found {return ""}
    return string(buffer[:copy(buffer,name)])
}
