package parse

import "mirai:std/compressor/lz/entropy"

// Adapters from the pointer+count form of the parsers to the entropy package.

@(private)
ent_put_array :: #force_inline proc(to,to_end:[^]u8, from:[^]u8, from_len:int, flags:u32,
    lambda:f32, pJ:^f32,
    deadline:f32, arena:^entropy.Arena, level:i32, histo:[^]u32) -> int {
    if from_len<0 || uintptr(to_end)<uintptr(to) {return -1}
    return entropy.put_array(to,to_end,from[:from_len],flags,lambda,pJ,deadline,arena,int(level),
        (^[256]u32)(histo))
}

@(private)
ent_put_array_small_allowed :: #force_inline proc(to,to_end:[^]u8, from:[^]u8, from_len:int,
    flags:u32, lambda:f32,
    pJ:^f32, deadline:f32, arena:^entropy.Arena, level:i32, histo:[^]u32) -> int {
    if from_len<0 || uintptr(to_end)<uintptr(to) {return -1}
    return entropy.put_array_small_allowed(to,to_end,from[:from_len],flags,lambda,pJ,deadline,
        arena,int(level),
        (^[256]u32)(histo))
}

@(private)
ent_put_array_histo :: #force_inline proc(to,to_end:[^]u8, from:[^]u8, from_len:int, histo:[]u32,
    flags:u32,
    lambda:f32, pJ:^f32, deadline:f32, arena:^entropy.Arena, level:i32) -> int {
    if from_len<0 || uintptr(to_end)<uintptr(to) || len(histo)!=256 {return -1}
    return entropy.put_array_histo(to,to_end,from[:from_len],(^[256]u32)(raw_data(histo)),flags,
        lambda,pJ,deadline,
        arena,int(level))
}

@(private)
ent_put_array_uncompressed :: #force_inline proc(to,to_end:[^]u8, from:[^]u8, from_len:int) -> int {
    if from_len<0 || uintptr(to_end)<uintptr(to) {return -1}
    return entropy.put_array_uncompressed(to,to_end,from[:from_len])
}

@(private)
ent_estimate_complen_bits :: #force_inline proc "contextless" (histo:[]u32, total:u32) -> i32 {
    return i32(entropy.array_estimate_complen_bits(histo,len(histo),total))
}

@(private)
ent_estimate_complen_bytes :: #force_inline proc "contextless" (histo:[]u32, total:u32) -> i32 {
    return i32(entropy.array_estimate_complen_bytes(histo,len(histo),total))
}
