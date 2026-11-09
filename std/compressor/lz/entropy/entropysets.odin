package entropy

// Code lengths of byte sets in 1/256 bits, for choosing splits and merges of arrays.

ENTROPYSET_CODELEN_ONE_BIT_SHIFT :: 8
ENTROPYSET_CODELEN_ONE_BIT :: 1<<ENTROPYSET_CODELEN_ONE_BIT_SHIFT
ENTROPYSET_SYM_INVALID_HIGH_CL :: 14<<ENTROPYSET_CODELEN_ONE_BIT_SHIFT
ENTROPYSET_SYM_PRESENT_MAX_CL :: 11<<ENTROPYSET_CODELEN_ONE_BIT_SHIFT
ENTROPYSET_INVSUM_SHIFT :: 30
@(private)
LOG2TABLED_TO_ENTROPYSET_CODELEN_SHIFT :: LOG2TABLE_ONE_SHIFT-ENTROPYSET_CODELEN_ONE_BIT_SHIFT

Entropyset_Codelens :: struct {codelen:[256]u16}

Entropyset :: struct {histo:Histo256, total:u32, complen:u32}

@(private)
simple_codelen_30 :: #force_inline proc "contextless" (count:u32, inv_sum:u32) -> i32 {
    cl:=log2tabled(count*inv_sum,ENTROPYSET_INVSUM_SHIFT)>>LOG2TABLED_TO_ENTROPYSET_CODELEN_SHIFT
    return min(i32(ENTROPYSET_SYM_PRESENT_MAX_CL),cl)
}

@(private)
inv_sum_30 :: #force_inline proc "contextless" (n:int) -> u32 {
    d:=u32(n)
    return d==0 ? 0 : u32(1<<ENTROPYSET_INVSUM_SHIFT)/d
}

entropysets_histo_to_codelens :: proc "contextless" (histo:^Histo256, histo_sum:int,
    out:^Entropyset_Codelens) #no_bounds_check {
    inv:=inv_sum_30(histo_sum)
    for s in 0..<256 {out.codelen[s]=u16(simple_codelen_30(histo.counts[s],inv))}
}

entropysets_self_codelen :: proc "contextless" (histo:^Histo256,
    histo_sum:int) -> i32 #no_bounds_check {
    inv:=inv_sum_30(histo_sum)
    cl_sum:i32=0
    for s in 0..<256 {
        c:=histo.counts[s]
        cl_sum+=simple_codelen_30(c,inv)*i32(c)
    }
    return cl_sum
}

entropysets_order0_codelen_bits :: proc "contextless" (histo:^Histo256, sum_counts:int) -> u32 {
    return u32(entropysets_self_codelen(histo,sum_counts))>>ENTROPYSET_CODELEN_ONE_BIT_SHIFT
}

entropysets_cross_codelen :: proc "contextless" (histo:^Histo256,
    codelens:^Entropyset_Codelens) -> i32 #no_bounds_check {
    s:i32=0
    for i in 0..<256 {s+=i32(histo.counts[i])*i32(codelens.codelen[i])}
    return s
}

// Codelen of p under histo1 minus under histo2. Above 256 bytes each distinct symbol counts once,
// as in the library.
entropysets_codelen_delta :: proc "contextless" (p:[]u8, histo1:^Histo256, len1:int,
    histo2:^Histo256, len2:int) -> i32 #no_bounds_check {
    inv1:=inv_sum_30(len1)
    inv2:=inv_sum_30(len2)
    d:i32=0
    if len(p)>256 {
        ah:Histo256
        histo_count(&ah,p)
        for s in 0..<256 {
            if ah.counts[s]==0 {continue}
            d+=simple_codelen_30(histo1.counts[s],inv1)-simple_codelen_30(histo2.counts[s],inv2)
        }
    } else {
        for b in p {
            d+=simple_codelen_30(histo1.counts[b],inv1)-simple_codelen_30(histo2.counts[b],inv2)
        }
    }
    return d
}

histo_estimate_complen_bits :: proc "contextless" (histo:^Histo256, sum_counts:int) -> u32 {
    return array_estimate_complen_bits(histo.counts[:],256,u32(sum_counts))
}

histo_estimate_j :: proc "contextless" (histo:^Histo256, sum_counts:int, lambda:f32) -> f32 {
    bits:=array_estimate_complen_bits(histo.counts[:],256,u32(sum_counts))
    return f32(bits)/8.0+lambda*speedfit_estimate_entropy_array_time(sum_counts)
}
