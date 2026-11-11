package rdo

import "base:intrinsics"
import "core:math"

Color_Rgba :: [4]u8

@(private="file") MAX_BLOCK_PIXELS :: 12*12
@(private="file") MAX_BLOCK_SIZE_IN_BYTES :: 256
@(private="file") MIN_MATCH_LEN :: 3
@(private="file") LITERAL_BITS:f32:13
@(private="file") MATCH_CONTINUE_BITS:f32:1
@(private="file") HASH_SIZE :: 8192

Reduce_Entropy_Params :: struct {
    lambda:f32,                         // weight of the approximate LZ bits against the scaled MSE; larger favors rate
    lookback_window_size:u32,           // bytes each block may look back for matches
    max_allowed_rms_increase_ratio:f32, // 1: no RMS increase allowed for a trial, 1.05: 5%
    max_smooth_block_std_dev:f32,
    smooth_block_max_mse_scale:f32,
    color_weights:[4]u32,
    try_two_matches:bool,
    allow_relative_movement:bool,
    skip_zero_mse_blocks:bool,
}

reduce_entropy_params_default :: proc() -> Reduce_Entropy_Params {
    return {
        lambda=1,
        lookback_window_size=256,
        max_allowed_rms_increase_ratio=10,
        max_smooth_block_std_dev=18,
        smooth_block_max_mse_scale=10,
        color_weights={1,1,1,1},
    }
}

// Decodes one block to its texels; false rejects the block.
Unpack_Block_Proc :: #type proc(block:[^]u8,pixels:[^]Color_Rgba,block_index:u32,user:rawptr) -> bool

@(private="file")
clampf :: #force_inline proc "contextless" (value,low,high:f32) -> f32 {
    if value<low {return low}
    if value>high {return high}
    return value
}

@(private)
lerpf :: #force_inline proc "contextless" (a,b,s:f32) -> f32 {return a+(b-a)*s}

@(private="file")
match_cost_estimate :: #force_inline proc "contextless" (dist,match_len:int) -> u32 {
    len_cost:u32=6
    if match_len>=12 {len_cost=9} else if match_len>=8 {len_cost=8} else if match_len>=6 {len_cost=7}
    // Deflate's extra distance bits: upstream's two lookup tables reduce to this.
    dist_cost:u32=5
    if dist>=4 {dist_cost+=u32(63-intrinsics.count_leading_zeros(u64(dist)))-1}
    return len_cost+dist_cost
}

@(private)
block_max_std_dev :: proc(pixels:[^]Color_Rgba,total_pixels,num_comps:int) -> f32 {
    max_std_dev:f32
    count:=u64(total_pixels)
    for c in 0..<num_comps {
        total,total2:u64
        for i in 0..<total_pixels {
            value:=u64(pixels[i][c])
            total+=value
            total2+=value*value
        }
        max_std_dev=max(max_std_dev,math.sqrt(f32(count*total2-total*total))/f32(count))
    }
    return max_std_dev
}

@(private="file")
hash_hsieh :: proc "contextless" (buf:[^]u8,count:int,salt:u32) -> u32 {
    word16 :: #force_inline proc "contextless" (p:[^]u8) -> u32 {return u32(p[0])|u32(p[1])<<8}

    p:=buf
    h:=u32(count)+salt<<16
    bytes_left:=count&3
    for _ in 0..<count>>2 {
        h+=word16(p)
        t:=word16(p[2:])<<11~h
        h=h<<16~t
        p=p[4:]
        h+=h>>11
    }
    switch bytes_left {
    case 1:
        h+=u32(i32(i8(p[0])))
        h~=h<<10
        h+=h>>1
    case 2:
        h+=word16(p)
        h~=h<<11
        h+=h>>17
    case 3:
        h+=word16(p)
        h~=h<<16
        h~=u32(i32(i8(p[2])))<<18
        h+=h>>11
    }
    h~=h<<3
    h+=h>>5
    h~=h<<4
    h+=h>>17
    h~=h<<25
    h+=h>>6
    return h
}

@(private="file")
Block_Eval :: struct {
    pixels:[^]Color_Rgba,
    total_pixels,num_comps:int,
    color_weights:[4]u32,
    one_over_total_color_weight:f32,
    block_index:u32,
    unpack:Unpack_Block_Proc,
    user:rawptr,
}

@(private="file")
block_mse :: #force_inline proc "contextless" (e:^Block_Eval,decoded:[^]Color_Rgba) -> f32 {
    total_err:u64
    for i in 0..<e.total_pixels {
        for c in 0..<e.num_comps {
            d:=i32(e.pixels[i][c])-i32(decoded[i][c])
            total_err+=u64(e.color_weights[c])*u64(d*d)
        }
    }
    return f32(total_err)*(e.one_over_total_color_weight/f32(e.total_pixels))
}

@(private="file")
block_trial_mse :: #force_inline proc(e:^Block_Eval,block:[^]u8) -> (mse:f32,ok:bool) {
    decoded:[MAX_BLOCK_PIXELS]Color_Rgba=---
    if !e.unpack(block,&decoded[0],e.block_index,e.user) {return}
    return block_mse(e,&decoded[0]),true
}

// Rewrites blocks in place to trade distortion for LZ rate. Each block holds
// block_size bytes at the start of each total_block_stride; block_pixels has
// block_width*block_height texels per block. block_mse_scales, when given,
// replaces the smooth block scale of the blocks whose value is positive.
// Stops with ok=false at the first block whose original bytes unpack rejects;
// the blocks before it stay rewritten.
reduce_entropy :: proc(
    blocks:[]u8,num_blocks,total_block_stride,block_size,block_width,block_height,num_comps:int,
    block_pixels:[]Color_Rgba,params:Reduce_Entropy_Params,
    unpack:Unpack_Block_Proc,user:rawptr,
    block_mse_scales:[]f32=nil,
) -> (total_modified:int,ok:bool) {
    if num_comps<1 || num_comps>4 {return}
    total_color_weight:u64
    for weight,i in params.color_weights {
        if i>=num_comps && weight!=0 {return}
        total_color_weight+=u64(weight)
    }
    if total_color_weight==0 {return}
    if block_size<MIN_MATCH_LEN || block_size>MAX_BLOCK_SIZE_IN_BYTES || total_block_stride<block_size {return}
    if block_width<=0 || block_height<=0 || block_width>MAX_BLOCK_PIXELS || block_height>MAX_BLOCK_PIXELS {return}
    total_block_pixels:=block_width*block_height
    if total_block_pixels>MAX_BLOCK_PIXELS || unpack==nil || num_blocks<0 {return}
    if num_blocks==0 {return 0,true}
    if len(blocks)<block_size || num_blocks>(len(blocks)-block_size)/total_block_stride+1 {return}
    if num_blocks>len(block_pixels)/total_block_pixels {return}
    if block_mse_scales!=nil && len(block_mse_scales)<num_blocks {return}

    total_blocks_to_check:=max(1,int(params.lookback_window_size)/total_block_stride)
    prev_match_window_ofs_to_favor_cont:=-1
    hash:[HASH_SIZE]u32=---

    eval:=Block_Eval{
        total_pixels=total_block_pixels,
        num_comps=num_comps,
        color_weights=params.color_weights,
        one_over_total_color_weight=1/f32(total_color_weight),
        unpack=unpack,
        user=user,
    }

    #no_bounds_check for block_index in 0..<num_blocks {
        if block_index&0xFF==0 {intrinsics.mem_zero(&hash,size_of(hash))}

        block_ofs:=block_index*total_block_stride
        orig_block:=blocks[block_ofs:block_ofs+block_size]
        pixels:=([^]Color_Rgba)(&block_pixels[block_index*total_block_pixels])
        eval.pixels=pixels
        eval.block_index=u32(block_index)

        cur_mse,decoded_ok:=block_trial_mse(&eval,&orig_block[0])
        if !decoded_ok {return total_modified,false}
        if params.skip_zero_mse_blocks && cur_mse==0 {continue}

        yl:=clampf(block_max_std_dev(pixels,total_block_pixels,num_comps)/params.max_smooth_block_std_dev,0,1)
        yl=yl*yl
        smooth_block_mse_scale:=lerpf(params.smooth_block_max_mse_scale,1,yl)
        if block_mse_scales!=nil && block_mse_scales[block_index]>0 {smooth_block_mse_scale=block_mse_scales[block_index]}

        cur_bits:=LITERAL_BITS*f32(block_size)
        cur_t:=cur_mse*smooth_block_mse_scale+cur_bits*params.lambda

        first_block_to_check:=max(0,block_index-total_blocks_to_check)
        last_block_to_check:=block_index-1

        best_block:[MAX_BLOCK_SIZE_IN_BYTES]u8=---
        trial_block:[MAX_BLOCK_SIZE_IN_BYTES]u8=---
        copy(best_block[:block_size],orig_block)

        best_t:=cur_t
        best_match_len,best_match_src_window_ofs,best_match_dst_window_ofs,best_match_dst_block_ofs:int
        best_match_bits:f32

        // A floor of 1 lets zero-error blocks take slightly more distortion.
        thresh_ms_err:=params.max_allowed_rms_increase_ratio*params.max_allowed_rms_increase_ratio*max(cur_mse,1)

        for prev_block_index:=last_block_to_check;prev_block_index>=first_block_to_check;prev_block_index-=1 {
            prev_block_ofs:=prev_block_index*total_block_stride
            prev_block:=blocks[prev_block_ofs:prev_block_ofs+block_size]

            for match_len:=block_size;match_len>=MIN_MATCH_LEN;match_len-=1 {
                last_ofs:=block_size-match_len
                literal_bits:=f32(last_ofs)*LITERAL_BITS

                for src_ofs in 0..=last_ofs {
                    src_match_window_ofs:=prev_block_ofs+src_ofs
                    first_dst_ofs,last_dst_ofs:=src_ofs,src_ofs
                    if params.allow_relative_movement {first_dst_ofs,last_dst_ofs=0,last_ofs}

                    for dst_ofs in first_dst_ofs..=last_dst_ofs {
                        dst_match_window_ofs:=block_ofs+dst_ofs
                        hs:=hash_hsieh(&prev_block[src_ofs],match_len,u32(dst_ofs))

                        trial_match_bits:f32
                        if src_match_window_ofs==prev_match_window_ofs_to_favor_cont && dst_ofs==0 {
                            trial_match_bits=MATCH_CONTINUE_BITS
                        } else {
                            trial_match_bits=f32(match_cost_estimate(dst_match_window_ofs-src_match_window_ofs,match_len))
                            hash_check:=hash[hs&(HASH_SIZE-1)]
                            if hash_check&0xFF==u32(block_index)&0xFF && hash_check>>8==hs>>8 {continue}
                        }
                        hash[hs&(HASH_SIZE-1)]=hs&0xFFFFFF00|u32(block_index)&0xFF

                        copy(trial_block[:block_size],orig_block)
                        copy(trial_block[dst_ofs:dst_ofs+match_len],prev_block[src_ofs:src_ofs+match_len])

                        trial_mse,trial_ok:=block_trial_mse(&eval,&trial_block[0])
                        if !trial_ok || !(trial_mse<thresh_ms_err) {continue}

                        t:=trial_mse*smooth_block_mse_scale+(literal_bits+trial_match_bits)*params.lambda
                        if t<best_t {
                            best_t=t
                            copy(best_block[:block_size],trial_block[:block_size])
                            best_match_len=match_len
                            best_match_src_window_ofs=src_match_window_ofs
                            best_match_dst_window_ofs=dst_match_window_ofs
                            best_match_dst_block_ofs=dst_ofs
                            best_match_bits=trial_match_bits
                        }
                    }
                }
            }
        }

        if !(best_t<cur_t) {
            prev_match_window_ofs_to_favor_cont=-1
            continue
        }

        best_second_match_len,best_second_match_src_window_ofs,best_second_match_dst_window_ofs,best_second_match_dst_block_ofs:int

        if params.try_two_matches && best_match_len<=block_size-3 {
            matched_flags:[MAX_BLOCK_SIZE_IN_BYTES]bool
            for i in best_match_dst_block_ofs..<best_match_dst_block_ofs+best_match_len {matched_flags[i]=true}

            orig_best_block:=best_block

            for prev_block_index:=last_block_to_check;prev_block_index>=first_block_to_check;prev_block_index-=1 {
                prev_block_ofs:=prev_block_index*total_block_stride
                prev_block:=blocks[prev_block_ofs:prev_block_ofs+block_size]
                match_dist:=(block_index-prev_block_index)*total_block_stride

                for match_len:=3;match_len<=block_size-best_match_len;match_len+=1 {
                    trial_total_bits:=f32(block_size-match_len-best_match_len)*LITERAL_BITS+f32(match_cost_estimate(match_dist,match_len))+best_match_bits
                    trial_total_bits_times_lambda:=trial_total_bits*params.lambda

                    next_ofs: for ofs in 0..=block_size-match_len {
                        for i in 0..<match_len {if matched_flags[ofs+i] {continue next_ofs}}

                        copy(trial_block[:block_size],orig_best_block[:block_size])
                        copy(trial_block[ofs:ofs+match_len],prev_block[ofs:ofs+match_len])

                        trial_mse,trial_ok:=block_trial_mse(&eval,&trial_block[0])
                        if !trial_ok || !(trial_mse<thresh_ms_err) {continue}

                        t:=trial_mse*smooth_block_mse_scale+trial_total_bits_times_lambda
                        if t<best_t {
                            best_t=t
                            copy(best_block[:block_size],trial_block[:block_size])
                            best_second_match_len=match_len
                            best_second_match_src_window_ofs=prev_block_ofs+ofs
                            best_second_match_dst_window_ofs=block_ofs+ofs
                            best_second_match_dst_block_ofs=ofs
                        }
                    }
                }
            }
        }

        copy(orig_block,best_block[:block_size])
        total_modified+=1

        if block_size==total_block_stride {
            last_len,last_src_window_ofs,last_dst_block_ofs:=best_match_len,best_match_src_window_ofs,best_match_dst_block_ofs
            if best_second_match_len!=0 && best_match_dst_window_ofs<=best_second_match_dst_window_ofs {
                last_len,last_src_window_ofs,last_dst_block_ofs=best_second_match_len,best_second_match_src_window_ofs,best_second_match_dst_block_ofs
            }
            // A match that reaches the end of the block can continue on the next one.
            prev_match_window_ofs_to_favor_cont=-1
            if last_dst_block_ofs+last_len==total_block_stride {prev_match_window_ofs_to_favor_cont=last_src_window_ofs+last_len}
        }
    }

    return total_modified,true
}
