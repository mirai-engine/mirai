package data

import "base:intrinsics"

@(private)
write_speed :: proc "contextless" (w:^Encode_Work,src:[]u8,first:int,dst:[]u8) -> int {
    if w.sequence_count==0 {return 0}
    command_bytes:=w.sequence_count*4
    literal_bytes:=len(src)-first
    for s in w.sequences[:w.sequence_count] {
        if s.distance>u32(max(u16)) {return 0}
        if s.literals>=255 {command_bytes+=length_size(int(s.literals)-255)}
        match:=int(s.length)-SPEED_MIN
        if match>=255 {command_bytes+=length_size(match-255)}
        literal_bytes-=int(s.length)
    }
    size:=1+length_size(command_bytes)+command_bytes+literal_bytes
    if size>len(dst)-max(1,(len(dst)-1)/100) {return 0}

    dst[0]=u8(Block_Mode.LZ)
    at:=1+length_write(dst[1:],command_bytes)
    lit:=at+command_bytes
    input:=first
    for s in w.sequences[:w.sequence_count] {
        ll,ml:=int(s.literals),int(s.length)-SPEED_MIN
        word:=u32(s.distance)|u32(min(ll,255))<<16|u32(min(ml,255))<<24
        intrinsics.unaligned_store((^u32le)(&dst[at]),u32le(word))
        at+=4
        if ll>=255 {at+=length_write(dst[at:],ll-255)}
        if ml>=255 {at+=length_write(dst[at:],ml-255)}
        lit+=copy(dst[lit:],src[input:][:ll])
        input+=ll+int(s.length)
    }
    return lit+copy(dst[lit:],src[input:])
}

@(private)
decode_speed :: proc "contextless" (body,dst:[]u8,first:int) -> bool {
    header:=0
    n:=length_read(body,&header)
    if n<4 || n>len(body)-header {return false}
    return execute_speed(body[header:][:n],body[header+n:],dst,first)
}

@(private="file")
execute_speed :: proc "contextless" (commands,literals,dst:[]u8,
    first:int) -> bool #no_bounds_check {
    ip,lit,out:=0,0,first
    for ip<=len(commands)-4 {
        command:=u32(intrinsics.unaligned_load((^u32le)(&commands[ip])))
        ip+=4
        ll,ml:=int((command>>16)&255),int(command>>24)+SPEED_MIN
        distance:=int(command&65535)
        if ll==255 {
            extra:=length_read(commands,&ip)
            if extra<0 {return false}
            ll+=extra
        }
        if ml==255+SPEED_MIN {
            extra:=length_read(commands,&ip)
            if extra<0 {return false}
            ml+=extra
        }
        if !copy_sequence(dst,literals,out,lit,ll,ml,distance) {return false}
        lit+=ll
        out+=ll+ml
    }
    if ip!=len(commands) || len(literals)-lit!=len(dst)-out {return false}
    copy(dst[out:],literals[lit:])
    return true
}
