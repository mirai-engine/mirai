package entropy

import "mirai:std/compressor"

// Decode-time model of the default speed fit, in cycles: the mean of four measured cores.
// The rate-distortion cost of an encoding is J = bytes + lambda * cycles.

LZ_Chunk_Deadlines :: struct {
    whole_chunk, literals_only, literal, packet, offsets, excesses_u8, parse:f32,
}

@(private="file")
blend :: #force_inline proc "contextless" (ivb,a57,jag,
    skl:f32) -> f32 {return (ivb+a57+jag+skl)*0.25}

speedfit_memcpy :: proc "contextless" (n:int) -> f32 {
    l:=f32(n)
    return blend(28.000+0.125*l,53.000+0.171*l,58.000+0.256*l,29.000+0.083*l)
}
speedfit_simd_mul_s32_sub_u8 :: proc "contextless" (n:int) -> f32 {
    l:=f32(n)
    return blend(28.000+0.595*l,53.000+1.050*l,62.000+1.179*l,33.000+0.567*l)
}
speedfit_get_offsets44 :: proc "contextless" (count:int) -> f32 {
    c:=f32(count)
    return blend(62.070+7.186*c,43.106+8.891*c,135.580+12.846*c,62.485+7.566*c)
}
speedfit_get_offsetsalt :: proc "contextless" (count:int) -> f32 {
    c:=f32(count)
    return blend(75.901+8.183*c,80.014+6.598*c,152.175+14.464*c,74.069+8.403*c)
}
speedfit_get_excesses :: proc "contextless" (count,u32_count:int) -> f32 {
    c,u:=f32(count),f32(u32_count)
    return blend(42.933+0.478*c+21.527*u,36.646+0.746*c+32.345*u,115.731+0.815*c+36.682*u,
        48.796+0.453*c+20.770*u)
}
speedfit_get_multiarrays :: proc "contextless" (num_intervals,tot_raw_len:int) -> f32 {
    n,t:=f32(num_intervals),f32(tot_raw_len)
    return blend(0.000+46.245*n+0.125*t,0.000+76.846*n+0.322*t,0.000+45.477*n+0.215*t,
        0.000+41.626*n+0.077*t)
}
speedfit_huff3 :: proc "contextless" (n,num_non_zero,num_alphabet_runs:int, bpb:f32) -> f32 {
    l,z:=f32(n),f32(num_non_zero)
    return blend(1880.931+3.243*l+10.960*z,2219.653+2.993*l+24.622*z,2889.858+2.468*l+21.296*z,
        2029.866+2.699*l+8.459*z)
}
speedfit_huff6 :: proc "contextless" (n,num_non_zero,num_alphabet_runs:int, bpb:f32) -> f32 {
    l,z:=f32(n),f32(num_non_zero)
    return blend(2029.917+2.436*l+10.792*z,2540.026+2.087*l+20.994*z,3227.433+2.501*l+18.925*z,
        2084.978+1.875*l+8.951*z)
}
speedfit_tans :: proc "contextless" (n,num_non_zero,L:int) -> f32 {
    l,z,t:=f32(n),f32(num_non_zero),f32(L)
    return blend(642.078+3.175*l+52.016*z+1.895*t,1073.963+2.963*l+77.065*z+1.695*t,
        1313.768+3.951*l+78.930*z+4.139*t,705.924+2.324*l+49.328*z+1.423*t)
}
speedfit_rle :: proc "contextless" (n:int) -> f32 {
    l:=f32(n)
    return blend(284.970+0.172*l,326.121+0.282*l,388.669+0.377*l,274.270+0.161*l)
}

@(private="file") PARSE_CONSTANT_TIME :: f32(200)

speedfit_parse_lz :: proc "contextless" (chunk_len,num_packets,num_excesses:int) -> f32 {
    c,p,e:=f32(chunk_len),f32(num_packets),f32(num_excesses)
    k:=PARSE_CONSTANT_TIME
    return blend(k+0.405*c+15.213*p+4.017*e,k+0.419*c+19.861*p+10.898*e,k+0.647*c+24.886*p+9.685*e,
        k+0.305*c+13.591*p+4.394*e)
}
speedfit_parse_lz_subliterals :: proc "contextless" (num_literals:int) -> f32 {
    l:=f32(num_literals)
    return blend(0.144*l,0.292*l,0.322*l,0.129*l)
}
speedfit_deadlines_lz :: proc "contextless" (d:^LZ_Chunk_Deadlines, chunk_len:int) {
    d^=LZ_Chunk_Deadlines{ARRAY_DEADLINE_HUGE,ARRAY_DEADLINE_HUGE,ARRAY_DEADLINE_HUGE,
        ARRAY_DEADLINE_HUGE,ARRAY_DEADLINE_HUGE,ARRAY_DEADLINE_HUGE,ARRAY_DEADLINE_HUGE}
}

// Decode time of the varbits part of the offsets (without their entropy arrays).
speedfit_get_offsets_time :: proc "contextless" (count:int, modulo:int) -> f32 {
    if modulo==0 {return speedfit_get_offsets44(count)}
    if modulo==1 {return speedfit_get_offsetsalt(count)}
    return speedfit_get_offsetsalt(count)+speedfit_simd_mul_s32_sub_u8(count)
}

speedfit_huff_time :: proc "contextless" (huff_type:u32, n,num_non_zero,num_alphabet_runs:int,
    bpb:f32) -> f32 {
    if huff_type==compressor.ARRAY_TYPE_HUFF {
        return speedfit_huff3(n,num_non_zero,num_alphabet_runs,bpb)
    }
    return speedfit_huff6(n,num_non_zero,num_alphabet_runs,bpb)
}

// Estimate used before an array type is chosen: as if it were huff3.
speedfit_estimate_entropy_array_time :: proc "contextless" (n:int) -> f32 {
    return speedfit_huff3(n,128,20,6.0)
}

speedfit_memcpy_array_j :: proc "contextless" (lambda:f32, n:int) -> f32 {
    return f32(n)+lambda*speedfit_memcpy(n)
}
