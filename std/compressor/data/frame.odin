package data

import "base:intrinsics"

@(private) BLOCK_BYTES :: 128<<10
@(private) MAX_BYTES :: int(max(i32))
@(private) WINDOW :: (512<<10)-1
@(private) MIN_MATCH :: 3
@(private) SPEED_MIN :: 4
@(private) SEQUENCES_MAX :: BLOCK_BYTES/MIN_MATCH

@(private)
Block_Mode :: enum u8 {Raw,LZ,Entropy}

@(private)
mdc_bound :: proc "contextless" (size:int) -> int {
    if size<=0 {return 0}
    return size+1+4*((size-1)/BLOCK_BYTES)
}

// The extent of each nonfinal block precedes its mode byte and payload.
encode_mdc1 :: proc(e:^Encoder,profile:Profile,src,dst:[]u8) -> (size:int,error:Error) {
    if profile>.Ultra {return 0,.Unknown_Format}
    if len(src)>MAX_BYTES {return 0,.Too_Large}
    if len(dst)<mdc_bound(len(src)) {return 0,.Output_Too_Small}
    if len(src)==0 {return 0,.None}
    if buffers_overlap(src,dst) {return 0,.Corrupt}
    if e==nil {return 0,.Out_Of_Memory}
    if len(src)>=MIN_MATCH && e.mdc==nil {
        allocator:=e.allocator if e.allocator.procedure!=nil else context.allocator
        work,err:=new(Encode_Work,allocator)
        if err!=nil {return 0,.Out_Of_Memory}
        e^={allocator=allocator,mdc=work}
    }
    if e.mdc!=nil {index_begin(e.mdc,len(src),profile)}
    for first:=0;first<len(src);first+=BLOCK_BYTES {
        last:=min(first+BLOCK_BYTES,len(src))
        header:=size
        if last<len(src) {size+=3}
        n:=encode_block(e.mdc,profile,src[:last],first,dst[size:][:last-first+1])
        if last<len(src) {dst[header],dst[header+1],dst[header+2]=u8(n),u8(n>>8),u8(n>>16)}
        size+=n
    }
    return size,.None
}

@(private)
decode_mdc1 :: proc "contextless" (d:^Decoder,src,dst:[]u8) -> Error {
    if len(src)>mdc_bound(len(dst)) {return .Corrupt}
    if len(dst)==0 {return .None}
    if len(src)==0 || buffers_overlap(src,dst) {return .Corrupt}
    at:=0
    for first:=0;first<len(dst);first+=BLOCK_BYTES {
        last:=min(first+BLOCK_BYTES,len(dst))
        n:=len(src)-at
        if last<len(dst) {
            if n<3 {return .Corrupt}
            n=int(src[at])|int(src[at+1])<<8|int(src[at+2])<<16
            at+=3
        }
        if n<1 || n>len(src)-at || n>last-first+1 {return .Corrupt}
        wire:=src[at:][:n]
        body:=wire[1:]
        switch Block_Mode(wire[0]) {
        case .Raw:
            if len(body)!=last-first {return .Corrupt}
            copy(dst[first:last],body)
        case .LZ:
            if !decode_speed(body,dst[:last],first) {return .Corrupt}
        case .Entropy:
            if d==nil || d.mdc==nil {return .Out_Of_Memory}
            if !decode_entropy(d.mdc,body,dst[:last],first) {return .Corrupt}
        case: return .Corrupt
        }
        at+=n
    }
    return .None
}

@(private="file")
buffers_overlap :: #force_inline proc "contextless" (a,b:[]u8) -> bool {
    ap,bp:=uintptr(raw_data(a)),uintptr(raw_data(b))
    if ap<=bp {return bp-ap<uintptr(len(a))}
    return ap-bp<uintptr(len(b))
}

@(private)
length_write :: #force_inline proc "contextless" (dst:[]u8,n:int) -> int {
    value:=n
    at:=0
    for value>=128 {
        dst[at]=u8(value)|128
        value>>=7
        at+=1
    }
    dst[at]=u8(value)
    return at+1
}

@(private)
length_read :: #force_inline proc "contextless" (src:[]u8,at:^int) -> int {
    value:=0
    for shift in 0..<3 {
        if at^>=len(src) {return -1}
        byte:=int(src[at^])
        at^+=1
        value|=(byte&127)<<uint(7*shift)
        if byte<128 {
            if shift!=0 && byte==0 {return -1}
            return value
        }
    }
    return -1
}

@(private)
length_size :: #force_inline proc "contextless" (n:int) -> int {
    return 1+int(n>=128)+int(n>=1<<14)
}

@(private)
copy_sequence :: #force_inline proc "contextless" (dst,literals:[]u8,
    out,lit,ll,ml,distance:int) -> bool #no_bounds_check {
    at:=out+ll
    invalid:=(len(literals)-lit-ll)|(len(dst)-at-ml)|(distance-1)|(at-distance)
    if invalid<0 {return false}
    if ll<=16 && lit<=len(literals)-16 && out<=len(dst)-16 {
        copy16(&dst[out],&literals[lit])
    } else if ll>0 {
        intrinsics.mem_copy_non_overlapping(&dst[out],&literals[lit],ll)
    }
    copy_match(dst,at,distance,ml)
    return true
}

@(private="file")
Short_Match :: #simd[16]u8

// The last distance bytes of the preceding vector, repeated to fill a vector.
@(private="file")
SHORT_MATCH_ORDER :: [15]Short_Match{
    {15,15,15,15,15,15,15,15,15,15,15,15,15,15,15,15},
    {14,15,14,15,14,15,14,15,14,15,14,15,14,15,14,15},
    {13,14,15,13,14,15,13,14,15,13,14,15,13,14,15,13},
    {12,13,14,15,12,13,14,15,12,13,14,15,12,13,14,15},
    {11,12,13,14,15,11,12,13,14,15,11,12,13,14,15,11},
    {10,11,12,13,14,15,10,11,12,13,14,15,10,11,12,13},
    {9,10,11,12,13,14,15,9,10,11,12,13,14,15,9,10},
    {8,9,10,11,12,13,14,15,8,9,10,11,12,13,14,15},
    {7,8,9,10,11,12,13,14,15,7,8,9,10,11,12,13},
    {6,7,8,9,10,11,12,13,14,15,6,7,8,9,10,11},
    {5,6,7,8,9,10,11,12,13,14,15,5,6,7,8,9},
    {4,5,6,7,8,9,10,11,12,13,14,15,4,5,6,7},
    {3,4,5,6,7,8,9,10,11,12,13,14,15,3,4,5},
    {2,3,4,5,6,7,8,9,10,11,12,13,14,15,2,3},
    {1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,1},
}

@(private="file")
copy_short_match :: #force_inline proc "contextless" (dst:[]u8,at,distance:int) #no_bounds_check {
    orders:=SHORT_MATCH_ORDER
    previous:=intrinsics.unaligned_load((^Short_Match)(&dst[at-16]))
    tiled:=intrinsics.simd_runtime_swizzle(previous,orders[distance-1])
    intrinsics.unaligned_store((^Short_Match)(&dst[at]),tiled)
}

@(private="file")
copy_match :: #force_inline proc "contextless" (dst:[]u8,at,distance,count:int) #no_bounds_check {
    from:=at-distance
    if count<=16 && len(dst)-at>=16 {
        if distance>=16 {
            copy16(&dst[at],&dst[from])
            return
        }
        if at>=16 {
            copy_short_match(dst,at,distance)
            return
        }
    }
    if count<=32 && distance>=16 && len(dst)-at>=32 {
        copy16(&dst[at],&dst[from])
        if count>16 {copy16(&dst[at+16],&dst[from+16])}
        return
    }
    if count<=64 && distance>=8 && len(dst)-at>=count+7 {
        if distance>=16 && len(dst)-at>=count+15 {
            for i:=0;i<count;i+=16 {copy16(&dst[at+i],&dst[from+i])}
        } else {
            for i:=0;i<count;i+=8 {copy8(&dst[at+i],&dst[from+i])}
        }
        return
    }
    if distance>=count {
        intrinsics.mem_copy_non_overlapping(&dst[at],&dst[from],count)
        return
    }
    if distance<=8 && distance&(distance-1)==0 {
        word:u64
        switch distance {
        case 1: word=u64(dst[from])*0x0101010101010101
        case 2: word=u64(intrinsics.unaligned_load((^u16)(&dst[from])))*0x0001000100010001
        case 4: word=u64(intrinsics.unaligned_load((^u32)(&dst[from])))*0x0000000100000001
        case 8: word=intrinsics.unaligned_load((^u64)(&dst[from]))
        }
        i:=0
        for ;i+8<=count;i+=8 {intrinsics.unaligned_store((^u64)(&dst[at+i]),word)}
        for ;i<count;i+=1 {dst[at+i]=dst[at+i-distance]}
        return
    }
    for filled:=0;filled<count; {
        n:=min(distance+filled,count-filled)
        intrinsics.mem_copy_non_overlapping(&dst[at+filled],&dst[from],n)
        filled+=n
    }
}

@(private="file")
copy16 :: #force_inline proc "contextless" (dst,src:^u8) {
    word:=intrinsics.unaligned_load((^u128)(src))
    intrinsics.unaligned_store((^u128)(dst),word)
}

@(private="file")
copy8 :: #force_inline proc "contextless" (dst,src:^u8) {
    word:=intrinsics.unaligned_load((^u64)(src))
    intrinsics.unaligned_store((^u64)(dst),word)
}
