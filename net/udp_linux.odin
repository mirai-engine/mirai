package mirai_net

import "core:sys/posix"

foreign import libc "system:c"
@(private) Mmsghdr :: struct {header:posix.msghdr,length:u32}
@(private,default_calling_convention="c")
foreign libc {
    sendmmsg :: proc(socket:posix.FD,messages:[^]Mmsghdr,count:u32,flags:i32) -> i32 ---
    recvmmsg :: proc(socket:posix.FD,messages:[^]Mmsghdr,count:u32,flags:i32,timeout:rawptr) -> i32 ---
}
@(private) UDP_BATCH :: 64

@(private)
udp_send_batch :: proc(u:^Udp,batch:[]Datagram) -> int {
    names:[UDP_BATCH]posix.sockaddr_storage
    vectors:[UDP_BATCH]posix.iovec
    messages:[UDP_BATCH]Mmsghdr
    sent,at:=0,0
    for at<len(batch) {
        count:=0
        for count<UDP_BATCH && at+count<len(batch) {
            datagram:=batch[at+count]
            size,ok:=udp_sockaddr(u,datagram.address,&names[count])
            if !ok {break}
            vectors[count]={raw_data(datagram.bytes),uint(len(datagram.bytes))}
            messages[count]={header={msg_name=&names[count],msg_namelen=size,msg_iov=&vectors[count],msg_iovlen=1}}
            count+=1
        }
        if count==0 {at+=1;continue}
        went:=int(sendmmsg(posix.FD(u.socket),&messages[0],u32(count),0))
        // One the system refuses, as to an unreachable address, is dropped and the rest go on.
        if went<=0 {
            if posix.errno()==.EWOULDBLOCK {return sent}
            went=1
        } else {
            sent+=went
        }
        at+=went
    }
    return sent
}

@(private)
udp_receive_batch :: proc(u:^Udp,batch:[]Datagram) -> int {
    names:[UDP_BATCH]posix.sockaddr_storage
    vectors:[UDP_BATCH]posix.iovec
    messages:[UDP_BATCH]Mmsghdr
    count:=min(len(batch),UDP_BATCH)
    for i in 0..<count {
        vectors[i]={raw_data(batch[i].bytes),uint(len(batch[i].bytes))}
        messages[i]={header={msg_name=&names[i],msg_namelen=size_of(posix.sockaddr_storage),msg_iov=&vectors[i],msg_iovlen=1}}
    }
    // An ICMP answer to an earlier send surfaces as an error on the next receive: skip those.
    for _ in 0..<8 {
        got:=int(recvmmsg(posix.FD(u.socket),&messages[0],u32(count),0,nil))
        if got>0 {
            for i in 0..<got {batch[i]={udp_from_sockaddr(&names[i]),batch[i].bytes[:min(int(messages[i].length),len(batch[i].bytes))]}}
            return got
        }
        if got==0 || posix.errno()==.EWOULDBLOCK || posix.errno()==.EINTR {return 0}
    }
    return 0
}
