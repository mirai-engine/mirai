#+private
package data

import "base:intrinsics"

Huff_Hist :: [4][256]u32

// Every byte of src must be at most max_symbol_value_ptr^. Returns the largest count.
hist_count_simple :: proc "contextless" (count:[^]u32,max_symbol_value_ptr:^u32,src:[^]u8,
    src_size:int) -> u32 {
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

@(private="file")
hist_count_stripe :: #force_inline proc "contextless" (counting1,counting2,counting3,
    counting4:[^]u32,c:u32) {
    counting1[u8(c)]+=1
    counting2[u8(c>>8)]+=1
    counting3[u8(c>>16)]+=1
    counting4[c>>24]+=1
}

hist_count :: proc "contextless" (count:^[256]u32, max_symbol:^u32, source:[]u8,
    workspace:^Huff_Hist) -> int {
    max_symbol^=255
    ip:=raw_data(source)
    if len(source)<1500 {return int(hist_count_simple(raw_data(count[:]),max_symbol,ip,
        len(source)))}
    iend:=padd(ip,len(source))
    max_count:u32
    counting1,counting2:=raw_data(workspace[0][:]),raw_data(workspace[1][:])
    counting3,counting4:=raw_data(workspace[2][:]),raw_data(workspace[3][:])
    workspace^={}
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
    for counting1[max_symbol^]==0 {max_symbol^-=1}
    count^=workspace[0]
    return int(max_count)
}
