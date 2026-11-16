package zstd

import "base:intrinsics"

HIST_WKSP_SIZE_U32 :: 1024
HIST_WKSP_SIZE :: HIST_WKSP_SIZE_U32*size_of(u32)

hist_add :: proc "contextless" (count:[^]u32,src:[^]u8,src_size:int) {
    for i in 0..<src_size {count[src[i]]+=1}
}

// Every byte of src must be at most max_symbol_value_ptr^. Returns the largest count.
hist_count_simple :: proc "contextless" (count:[^]u32,max_symbol_value_ptr:^u32,src:[^]u8,src_size:int) -> u32 {
    max_symbol_value:=max_symbol_value_ptr^
    largest_count:u32
    intrinsics.mem_zero(count,int(max_symbol_value+1)*size_of(u32))
    if src_size==0 {max_symbol_value_ptr^=0;return 0}
    for i in 0..<src_size {count[src[i]]+=1}
    for count[max_symbol_value]==0 {max_symbol_value-=1}
    max_symbol_value_ptr^=max_symbol_value
    for s:=u32(0);s<=max_symbol_value;s+=1 {
        if count[s]>largest_count {largest_count=count[s]}
    }
    return largest_count
}

@(private="file") Hist_Check_Input :: enum {Trust_Input,Check_Max_Symbol_Value}

@(private="file")
hist_count_stripe :: #force_inline proc "contextless" (counting1,counting2,counting3,counting4:[^]u32,c:u32) {
    counting1[u8(c)]+=1
    counting2[u8(c>>8)]+=1
    counting3[u8(c>>16)]+=1
    counting4[c>>24]+=1
}

@(private="file")
hist_count_parallel_wksp :: proc "contextless" (count:[^]u32,max_symbol_value_ptr:^u32,source:[^]u8,source_size:int,check:Hist_Check_Input,workspace:[^]u32) -> (size:int,err:Error) {
    ip:=source
    iend:=padd(ip,source_size)
    count_size:=int(max_symbol_value_ptr^+1)*size_of(u32)
    max_count:u32
    counting1:=workspace
    counting2:=counting1[256:]
    counting3:=counting2[256:]
    counting4:=counting3[256:]
    if source_size==0 {
        intrinsics.mem_zero(count,count_size)
        max_symbol_value_ptr^=0
        return 0,.None
    }
    intrinsics.mem_zero(workspace,4*256*size_of(u32))
    cached:=read32(ip);ip=padd(ip,4)
    for uintptr(ip)<uintptr(padd(iend,-15)) {
        c:=cached;cached=read32(ip);ip=padd(ip,4)
        hist_count_stripe(counting1,counting2,counting3,counting4,c)
        c=cached;cached=read32(ip);ip=padd(ip,4)
        hist_count_stripe(counting1,counting2,counting3,counting4,c)
        c=cached;cached=read32(ip);ip=padd(ip,4)
        hist_count_stripe(counting1,counting2,counting3,counting4,c)
        c=cached;cached=read32(ip);ip=padd(ip,4)
        hist_count_stripe(counting1,counting2,counting3,counting4,c)
    }
    ip=padd(ip,-4)
    for uintptr(ip)<uintptr(iend) {
        counting1[ip[0]]+=1
        ip=padd(ip,1)
    }
    for s in 0..<256 {
        counting1[s]+=counting2[s]+counting3[s]+counting4[s]
        if counting1[s]>max_count {max_count=counting1[s]}
    }
    max_symbol_value:=u32(255)
    for counting1[max_symbol_value]==0 {max_symbol_value-=1}
    if check==.Check_Max_Symbol_Value && max_symbol_value>max_symbol_value_ptr^ {return 0,.Max_Symbol_Value_Too_Small}
    max_symbol_value_ptr^=max_symbol_value
    intrinsics.mem_copy(count,counting1,count_size)
    return int(max_count),.None
}

// workspace is aligned to 4 bytes and of at least HIST_WKSP_SIZE. Every byte of source must be
// at most max_symbol_value_ptr^.
hist_count_fast_wksp :: proc "contextless" (count:[^]u32,max_symbol_value_ptr:^u32,source:[^]u8,source_size:int,workspace:[^]u8,workspace_size:int) -> (size:int,err:Error) {
    if source_size<1500 {return int(hist_count_simple(count,max_symbol_value_ptr,source,source_size)),.None}
    if uintptr(workspace)&3!=0 {return 0,.Generic}
    if workspace_size<HIST_WKSP_SIZE {return 0,.Workspace_Too_Small}
    return hist_count_parallel_wksp(count,max_symbol_value_ptr,source,source_size,.Trust_Input,([^]u32)(workspace))
}

// workspace is aligned to 4 bytes and of at least HIST_WKSP_SIZE.
hist_count_wksp :: proc "contextless" (count:[^]u32,max_symbol_value_ptr:^u32,source:[^]u8,source_size:int,workspace:[^]u8,workspace_size:int) -> (size:int,err:Error) {
    if uintptr(workspace)&3!=0 {return 0,.Generic}
    if workspace_size<HIST_WKSP_SIZE {return 0,.Workspace_Too_Small}
    if max_symbol_value_ptr^<255 {
        return hist_count_parallel_wksp(count,max_symbol_value_ptr,source,source_size,.Check_Max_Symbol_Value,([^]u32)(workspace))
    }
    max_symbol_value_ptr^=255
    return hist_count_fast_wksp(count,max_symbol_value_ptr,source,source_size,workspace,workspace_size)
}

hist_count :: proc "contextless" (count:[^]u32,max_symbol_value_ptr:^u32,src:[^]u8,src_size:int) -> (size:int,err:Error) {
    tmp_counters:[HIST_WKSP_SIZE_U32]u32=---
    return hist_count_wksp(count,max_symbol_value_ptr,src,src_size,([^]u8)(&tmp_counters),size_of(tmp_counters))
}
