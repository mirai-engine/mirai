package zstd

import "base:intrinsics"

XXH_PRIME64_1 :: u64(0x9E3779B185EBCA87)
XXH_PRIME64_2 :: u64(0xC2B2AE3D27D4EB4F)
XXH_PRIME64_3 :: u64(0x165667B19E3779F9)
XXH_PRIME64_4 :: u64(0x85EBCA77C2B2AE63)
XXH_PRIME64_5 :: u64(0x27D4EB2F165667C5)

Xxh64_State :: struct {
    total_len:u64,
    v:[4]u64,
    mem64:[4]u64,
    memsize:u32,
}

@(private="file")
xxh_rotl64 :: #force_inline proc "contextless" (x:u64,r:u32) -> u64 {return (x<<(r&63))|(x>>((64-r)&63))}

@(private="file")
xxh64_round :: #force_inline proc "contextless" (acc,input:u64) -> u64 {
    acc:=acc+input*XXH_PRIME64_2
    acc=xxh_rotl64(acc,31)
    return acc*XXH_PRIME64_1
}

@(private="file")
xxh64_merge_round :: #force_inline proc "contextless" (acc,val:u64) -> u64 {
    acc:=acc~xxh64_round(0,val)
    return acc*XXH_PRIME64_1+XXH_PRIME64_4
}

@(private="file")
xxh64_avalanche :: #force_inline proc "contextless" (hash:u64) -> u64 {
    hash:=hash
    hash~=hash>>33
    hash*=XXH_PRIME64_2
    hash~=hash>>29
    hash*=XXH_PRIME64_3
    hash~=hash>>32
    return hash
}

@(private="file")
xxh64_finalize :: proc "contextless" (hash_in:u64,ptr_in:[^]u8,len_in:int) -> u64 {
    hash:=hash_in
    ptr:=ptr_in
    len:=len_in&31
    for len>=8 {
        k1:=xxh64_round(0,read64(ptr))
        ptr=padd(ptr,8)
        hash~=k1
        hash=xxh_rotl64(hash,27)*XXH_PRIME64_1+XXH_PRIME64_4
        len-=8
    }
    if len>=4 {
        hash~=u64(read32(ptr))*XXH_PRIME64_1
        ptr=padd(ptr,4)
        hash=xxh_rotl64(hash,23)*XXH_PRIME64_2+XXH_PRIME64_3
        len-=4
    }
    for len>0 {
        hash~=u64(ptr[0])*XXH_PRIME64_5
        ptr=padd(ptr,1)
        hash=xxh_rotl64(hash,11)*XXH_PRIME64_1
        len-=1
    }
    return xxh64_avalanche(hash)
}

xxh64 :: proc "contextless" (src:[^]u8,size:int,seed:u64) -> u64 {
    input:=src
    h64:u64
    if size>=32 {
        limit:=padd(padd(input,size),-31)
        v1:=seed+XXH_PRIME64_1+XXH_PRIME64_2
        v2:=seed+XXH_PRIME64_2
        v3:=seed
        v4:=seed-XXH_PRIME64_1
        for {
            v1=xxh64_round(v1,read64(input));input=padd(input,8)
            v2=xxh64_round(v2,read64(input));input=padd(input,8)
            v3=xxh64_round(v3,read64(input));input=padd(input,8)
            v4=xxh64_round(v4,read64(input));input=padd(input,8)
            if uintptr(input)>=uintptr(limit) {break}
        }
        h64=xxh_rotl64(v1,1)+xxh_rotl64(v2,7)+xxh_rotl64(v3,12)+xxh_rotl64(v4,18)
        h64=xxh64_merge_round(h64,v1)
        h64=xxh64_merge_round(h64,v2)
        h64=xxh64_merge_round(h64,v3)
        h64=xxh64_merge_round(h64,v4)
    } else {
        h64=seed+XXH_PRIME64_5
    }
    h64+=u64(size)
    return xxh64_finalize(h64,input,size)
}

xxh64_reset :: proc "contextless" (state:^Xxh64_State,seed:u64) {
    state^={}
    state.v[0]=seed+XXH_PRIME64_1+XXH_PRIME64_2
    state.v[1]=seed+XXH_PRIME64_2
    state.v[2]=seed
    state.v[3]=seed-XXH_PRIME64_1
}

xxh64_update :: proc "contextless" (state:^Xxh64_State,input:[^]u8,len:int) {
    if input==nil {return}
    p:=input
    b_end:=padd(p,len)
    state.total_len+=u64(len)
    if int(state.memsize)+len<32 {
        if len>0 {intrinsics.mem_copy_non_overlapping(padd(([^]u8)(&state.mem64[0]),int(state.memsize)),input,len)}
        state.memsize+=u32(len)
        return
    }
    if state.memsize!=0 {
        intrinsics.mem_copy_non_overlapping(padd(([^]u8)(&state.mem64[0]),int(state.memsize)),input,32-int(state.memsize))
        state.v[0]=xxh64_round(state.v[0],state.mem64[0])
        state.v[1]=xxh64_round(state.v[1],state.mem64[1])
        state.v[2]=xxh64_round(state.v[2],state.mem64[2])
        state.v[3]=xxh64_round(state.v[3],state.mem64[3])
        p=padd(p,32-int(state.memsize))
        state.memsize=0
    }
    if uintptr(padd(p,32))<=uintptr(b_end) {
        limit:=padd(b_end,-32)
        for {
            state.v[0]=xxh64_round(state.v[0],read64(p));p=padd(p,8)
            state.v[1]=xxh64_round(state.v[1],read64(p));p=padd(p,8)
            state.v[2]=xxh64_round(state.v[2],read64(p));p=padd(p,8)
            state.v[3]=xxh64_round(state.v[3],read64(p));p=padd(p,8)
            if uintptr(p)>uintptr(limit) {break}
        }
    }
    if uintptr(p)<uintptr(b_end) {
        intrinsics.mem_copy_non_overlapping(&state.mem64[0],p,pdiff(b_end,p))
        state.memsize=u32(pdiff(b_end,p))
    }
}

xxh64_digest :: proc "contextless" (state:^Xxh64_State) -> u64 {
    h64:u64
    if state.total_len>=32 {
        h64=xxh_rotl64(state.v[0],1)+xxh_rotl64(state.v[1],7)+xxh_rotl64(state.v[2],12)+xxh_rotl64(state.v[3],18)
        h64=xxh64_merge_round(h64,state.v[0])
        h64=xxh64_merge_round(h64,state.v[1])
        h64=xxh64_merge_round(h64,state.v[2])
        h64=xxh64_merge_round(h64,state.v[3])
    } else {
        h64=state.v[2]+XXH_PRIME64_5
    }
    h64+=state.total_len
    return xxh64_finalize(h64,([^]u8)(&state.mem64[0]),int(state.total_len&31))
}
