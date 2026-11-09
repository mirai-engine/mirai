package entropy

import "base:intrinsics"
import "mirai:std/compressor"

Histo256 :: struct {counts:[256]u32}

COST_ONE_BIT :: 32
COST_ONE_BYTE :: COST_ONE_BIT*8

// Counts the bytes of raw into counts[:num_symbols] (every byte must be < num_symbols).
// add_on adds to the counts instead of replacing them.
count_histo_array_u8 :: proc "contextless" (raw:[]u8, counts:[]u32, num_symbols:int=256,
    add_on:=false) #no_bounds_check {
    n:=min(num_symbols,len(counts),256)
    t:[4][256]u32
    p:=raw_data(raw)
    i:=0
    for ;i+8<=len(raw);i+=8 {
        x:=intrinsics.unaligned_load((^u64)(&p[i]))
        t[0][x&0xff]+=1
        t[1][(x>>8)&0xff]+=1
        t[2][(x>>16)&0xff]+=1
        t[3][(x>>24)&0xff]+=1
        t[0][(x>>32)&0xff]+=1
        t[1][(x>>40)&0xff]+=1
        t[2][(x>>48)&0xff]+=1
        t[3][x>>56]+=1
    }
    for ;i<len(raw);i+=1 {t[0][p[i]]+=1}
    for k in 0..<n {
        s:=t[0][k]+t[1][k]+t[2][k]+t[3][k]
        counts[k]=add_on ? counts[k]+s : s
    }
}

histo_count :: proc "contextless" (h:^Histo256, raw:[]u8) {count_histo_array_u8(raw,h.counts[:])}

sum_of_histogram :: proc "contextless" (counts:[]u32) -> u32 {
    s:u32=0
    for c in counts {s+=c}
    return s
}

histo_sum :: proc "contextless" (h:^Histo256) -> u32 {return sum_of_histogram(h.counts[:])}

histo_slide :: proc "contextless" (raw:[]u8, from,to:^Histo256) {
    for b in raw {from.counts[b]-=1;to.counts[b]+=1}
}
histo_add :: proc "contextless" (to:^Histo256, lhs,rhs:^Histo256) {
    for i in 0..<256 {to.counts[i]=lhs.counts[i]+rhs.counts[i]}
}
histo_sub :: proc "contextless" (to:^Histo256, lhs,rhs:^Histo256) {
    for i in 0..<256 {to.counts[i]=lhs.counts[i]-rhs.counts[i]}
}

find_max_u32_256 :: proc "contextless" (h:^[256]u32) -> u32 {
    m:u32=0
    for c in h {m=max(m,c)}
    return m
}

// Sum of histogram[i]*code_len[i].
code_len_of_histogram256 :: proc "contextless" (histogram:[]u32, code_len:[]u8,
    alphabet:int) -> u32 #no_bounds_check {
    s:u32=0
    for i in 0..<min(alphabet,len(histogram),len(code_len)) {s+=histogram[i]*u32(code_len[i])}
    return s
}

@(private="file") HISTO_COUNT_ADD :: 1
@(private="file") HISTO_SCALE :: 4

// codecost[i] in COST_ONE_BIT units; all become one byte plus add_cost when the total exceeds
// cost_entropy_threshold (in COST_ONE_BIT units) per symbol.
histo_to_codecost :: proc "contextless" (histo:[]u32, codecost:[]i32, alphabet:int, add_cost:int,
    cost_entropy_threshold:int) #no_bounds_check {
    n:=min(alphabet,len(histo),len(codecost))
    histo_sum:u32=0
    for i in 0..<n {histo_sum+=histo[i]}
    histo_sum*=HISTO_SCALE
    histo_sum+=u32(alphabet*HISTO_COUNT_ADD)
    log2_sum:=log2tabled_bk_32(histo_sum)
    total_cost:i32=0
    for i in 0..<n {
        count:=histo[i]*HISTO_SCALE+HISTO_COUNT_ADD
        log2_count:=log2tabled_bk_32(count)-log2_sum
        cost:=(log2_count*COST_ONE_BIT)>>LOG2TABLE_ONE_SHIFT
        total_cost+=cost*i32(count)
        codecost[i]=cost+i32(add_cost)
    }
    threshold_bits:=i32(cost_entropy_threshold)*i32(histo_sum)
    if total_cost>threshold_bits {
        for i in 0..<n {codecost[i]=COST_ONE_BYTE+i32(add_cost)}
    }
}

@(private="file")
count_zero_run_len :: proc "contextless" (values:[]u32) -> int #no_bounds_check {
    i:=0
    for i<len(values) && values[i]==0 {i+=1}
    return i
}

// A close under-estimate of the comp len in bits of an order-0 entropy array, with its header.
array_estimate_complen_bits :: proc "contextless" (histo:[]u32, alphabet:int,
    sum_counts:u32) -> u32 #no_bounds_check {
    header_bits:u32:5*8
    alphabet:=min(alphabet,len(histo))
    if sum_counts<compressor.HUFF_ARRAY_MIN_SIZE {
        if sum_counts>0 {
            i:=count_zero_run_len(histo[:alphabet])
            if i<alphabet && histo[i]==sum_counts {return header_bits+8}
        }
        return (3+sum_counts)*8
    }
    inv_sum:=u32(i32((1<<30)/i64(sum_counts)))
    header_bits_counts:u32=0
    header_bits_shape:u32=0
    cl_sum:u64=0
    num_non_zero:u32=0
    for i:=0;i<alphabet; {
        zero_runlen:=u32(count_zero_run_len(histo[i:alphabet]))
        i+=int(zero_runlen)
        if zero_runlen!=0 {header_bits_shape+=u32(count_bits_elias_gamma((zero_runlen-1)>>1))+1}
        if i>=alphabet {break}
        nonzero_runlen:u32=0
        for ;i<alphabet && histo[i]!=0;i+=1 {
            c:=histo[i]
            nonzero_runlen+=1
            header_bits_counts+=u32(count_bits_elias_gamma(c-1))
            cl:=u32(log2tabled(c*inv_sum,30))
            cl_sum+=u64(c)*u64(cl)
        }
        header_bits_shape+=u32(count_bits_elias_gamma(nonzero_runlen-1))
        num_non_zero+=nonzero_runlen
    }
    if num_non_zero==1 {return 8+header_bits}
    alt_shape_size:=num_non_zero*8
    header_sum:=header_bits_counts+min(alt_shape_size,header_bits_shape)
    cl_sum>>=LOG2TABLE_ONE_SHIFT
    return header_sum+u32(cl_sum)+header_bits
}

array_estimate_complen_bytes :: proc "contextless" (histo:[]u32, alphabet:int,
    sum_counts:u32) -> u32 {
    return (array_estimate_complen_bits(histo,alphabet,sum_counts)+7)/8
}
