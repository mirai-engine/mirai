package parse

import "base:intrinsics"
import "base:runtime"
import "mirai:std/compressor/lz/entropy"
import "mirai:std/compressor"

// The streams one chunk parse produces before entropy coding, in one scratch block sized for
// the worst case: literals chunk_len, packets chunk_len/2 (all LRL 0 + len 2 rep matches),
// offsets chunk_len/3, excess u8s chunk_len/5, excess u32s chunk_len/256.
Encoder_Arrays :: struct {
    literals_space_raw,literals_ptr_raw:[^]u8,
    literals_space_sub,literals_ptr_sub:[^]u8,
    packets_space,packets_ptr:[^]u8,
    offsets_u8_space,offsets_u8_ptr:[^]u8,
    offsets_space,offsets_ptr:[^]u32,
    excess_u8_space,excess_u8_ptr:[^]u8,
    excess_u32_space,excess_u32_ptr:[^]u32,
    excess_ptr_end:[^]u8,
    chunk_len:int,
    chunk_ptr:[^]u8,
    lastoffset:i32,
    bitstream_flags:u32,
}

// One parse step: lrl literals then a match; offset > 0 is a normal offset, -i is last offset i.
Parse :: struct {lastoffset,lrl,ml,offset:i32}

// Rep offsets of the encoder; lasts[3] is room for the decoder's normal offset slot.
LOs :: struct {lasts:[4]i32}

los_reset :: #force_inline proc "contextless" (l:^LOs) {
    l.lasts={compressor.MIN_OFFSET,compressor.MIN_OFFSET,compressor.MIN_OFFSET,0}
}

@(private)
los_mtf3 :: #force_inline proc "contextless" (l:^LOs,index:int) -> i32 {
    switch index {
    case 1: l.lasts[0],l.lasts[1]=l.lasts[1],l.lasts[0]
    case 2: top:=l.lasts[2];l.lasts[2]=l.lasts[1];l.lasts[1]=l.lasts[0];l.lasts[0]=top
    }
    return l.lasts[0]
}

@(private)
los_add :: #force_inline proc "contextless" (l:^LOs,offset:i32) {
    l.lasts[2]=l.lasts[1];l.lasts[1]=l.lasts[0];l.lasts[0]=offset
}

arrays_point_to_scratch :: proc "contextless" (ea:^Encoder_Arrays, scratch:[^]u8, chunk_len:int,
    chunk_ptr:[^]u8, bitstream_flags:u32) {
    align4 :: #force_inline proc "contextless" (p:[^]u8) -> [^]u8 {
        return ([^]u8)((uintptr(p)+3)&~uintptr(3))
    }
    ea.chunk_ptr=chunk_ptr
    ea.chunk_len=chunk_len
    lits:=chunk_len+8
    p:=scratch
    ea.literals_space_raw=p;ea.literals_ptr_raw=p;p=p[lits:]
    ea.literals_space_sub=p;ea.literals_ptr_sub=p;p=p[lits:]
    ea.packets_space=p;ea.packets_ptr=p;p=p[chunk_len/2+8:]
    ea.offsets_u8_space=p;ea.offsets_u8_ptr=p;p=p[chunk_len/3:]
    p=align4(p)
    ea.offsets_space=([^]u32)(p);ea.offsets_ptr=ea.offsets_space;p=p[(chunk_len/3)*4:]
    ea.excess_u8_space=p;ea.excess_u8_ptr=p;p=p[chunk_len/5:]
    p=align4(p)
    ea.excess_u32_space=([^]u32)(p);ea.excess_u32_ptr=ea.excess_u32_space;p=p[(chunk_len/256)*4:]
    ea.excess_ptr_end=p
    ea.lastoffset=compressor.MIN_OFFSET
    ea.bitstream_flags=bitstream_flags
}

// Bytewise a-b of 8 packed bytes.
@(private)
sub_bytes8 :: #force_inline proc "contextless" (a,b:u64) -> u64 {
    H :: 0x8080808080808080
    return ((a|H)-(b&~u64(H)))~((a~~b)&H)
}

@(private)
arrays_put_excess :: #force_inline proc "contextless" (ea:^Encoder_Arrays, val:int) {
    if val<255 {
        ea.excess_u8_ptr[0]=u8(val);ea.excess_u8_ptr=ea.excess_u8_ptr[1:]
    } else {
        ea.excess_u8_ptr[0]=255;ea.excess_u8_ptr=ea.excess_u8_ptr[1:]
        ea.excess_u32_ptr[0]=u32(val-255);ea.excess_u32_ptr=ea.excess_u32_ptr[1:]
    }
}

arrays_put_packet :: #force_inline proc "contextless" (ea:^Encoder_Arrays, los:^LOs, lrl,ml,
    offset:int,
    literals_start:[^]u8, $LO0_ONLY:bool, $SUB_LITS:bool) #no_bounds_check {
    packet:int
    if lrl>0 {
        packet=min(lrl,compressor.LZ_LRL_MAX)
        if lrl>=compressor.LZ_LRL_MAX {arrays_put_excess(ea,lrl-compressor.LZ_LRL_MAX)}
        // a match of at least LOMML and the match end pad follow the literals, and the literal
        // spaces have 8 bytes of slack, so short runs copy 8 bytes at once
        if lrl<=8 {
            intrinsics.unaligned_store((^u64)(ea.literals_ptr_raw),load64(literals_start))
            when SUB_LITS {
                ref:=load64(padd(literals_start,-int(ea.lastoffset)))
                cur:=load64(literals_start)
                intrinsics.unaligned_store((^u64)(ea.literals_ptr_sub),sub_bytes8(cur,ref))
            }
        } else {
            runtime.mem_copy_non_overlapping(ea.literals_ptr_raw,literals_start,lrl)
            when SUB_LITS {entropy.put_sub_literals(ea.literals_ptr_sub,literals_start,lrl,
                int(ea.lastoffset))}
        }
        ea.literals_ptr_raw=ea.literals_ptr_raw[lrl:]
        when SUB_LITS {ea.literals_ptr_sub=ea.literals_ptr_sub[lrl:]}
    }
    ml_to_send:=ml-compressor.LZ_LOMML
    ml_for_packet:=ml_to_send
    if ml_to_send>=compressor.LZ_ML_MAX {
        ml_for_packet=compressor.LZ_ML_MAX
        arrays_put_excess(ea,ml_to_send-compressor.LZ_ML_MAX)
    }
    packet+=ml_for_packet<<2
    if offset<=0 {
        when !LO0_ONLY {
            loi:=-offset
            packet+=loi<<6
            ea.lastoffset=los_mtf3(los,loi)
        }
    } else {
        off:=i32(offset)
        packet+=3<<6
        when !LO0_ONLY {los_add(los,off)}
        ea.lastoffset=off
        if off<ESCAPE_OFFSET_MIN {
            ea.offsets_u8_ptr[0]=offset44_pack_low_u8(off)
        } else {
            ea.offsets_u8_ptr[0]=offset44_pack_high_u8(off)
        }
        ea.offsets_u8_ptr=ea.offsets_u8_ptr[1:]
        ea.offsets_ptr[0]=u32(off);ea.offsets_ptr=ea.offsets_ptr[1:]
    }
    ea.packets_ptr[0]=u8(packet);ea.packets_ptr=ea.packets_ptr[1:]
}

arrays_finish_chunk :: proc "contextless" (ea:^Encoder_Arrays, literals_start:[^]u8,
    $SUB_LITS:bool) {
    final_lrl:=pdiff(ea.chunk_ptr,literals_start)+ea.chunk_len
    if final_lrl>0 {
        runtime.mem_copy_non_overlapping(ea.literals_ptr_raw,literals_start,final_lrl)
        ea.literals_ptr_raw=ea.literals_ptr_raw[final_lrl:]
        when SUB_LITS {
            entropy.put_sub_literals(ea.literals_ptr_sub,literals_start,final_lrl,
                int(ea.lastoffset))
            ea.literals_ptr_sub=ea.literals_ptr_sub[final_lrl:]
        }
    }
}

// Histograms of the arrays of a chunk output, for the optimal parse statistics.
Passinfo :: struct {
    literal_histo_raw:[256]u32,
    literal_histo_sub:[256]u32,
    packet_histo:[256]u32,
    excess_histo:[256]u32,
    offset_alt_modulo:int, // 0 for offsets44
    offset_histo1:[256]u32,
    offset_histo2:[256]u32, // filled when modulo > 1
}

// LZ: min(chunk_len,128k)*3 + alignment pad + array scratch + phase headers.
@(private)
scratch_mem_size :: proc "contextless" (raw_len:int) -> int {
    n:=raw_len<=0 ? compressor.CHUNK_LEN : min(raw_len,compressor.CHUNK_LEN)
    return n*3+32+compressor.ARRAY_INTERNAL_MAX_SCRATCH+4096
}

// newLZ_encoder_arrays_output: entropy codes the arrays into comp. Returns the comp length,
// chunk_len when expanded, -1 on failure.
arrays_output :: proc(c:^Chunk, pJ:^f32, pchunktype:^i32, passinfo:^Passinfo, comp,
    comp_end_in:[^]u8,
    ea:^Encoder_Arrays, level:i32, entropy_flags:u32) -> int {
    e:=c.e
    arena:=c.arena
    chunk_len:=ea.chunk_len
    chunk_ptr:=ea.chunk_ptr
    lambda:=e.lambda
    deadline:=c.deadline
    comp_end:=comp_end_in
    pJ^=entropy.LAGRANGE_COST_INVALID

    packet_count:=pdiff(ea.packets_ptr,ea.packets_space)
    if passinfo!=nil {passinfo^={}}

    comp_ptr:=comp
    start_pos:=c.chunk_pos==0 ? compressor.MIN_OFFSET : 0
    if pdiff(comp_end,comp_ptr)<start_pos {return chunk_len}
    for i in 0..<start_pos {comp_ptr[0]=chunk_ptr[i];comp_ptr=comp_ptr[1:]}

    excess_stream_bytes:=0
    excesses_u32_hdr_size:=0
    if ea.bitstream_flags&BITSTREAM_FLAG_SEND_EXCESS_SIZE!=0 {
        n:=int(uintptr(ea.excess_u32_ptr)-uintptr(ea.excess_u32_space))/4
        excess_stream_bytes=put_excesses_u32_separate(comp_ptr,comp_end,ea.excess_u32_space,n)
        if excess_stream_bytes<0 {return chunk_len}
        comp_end=padd(comp_end,-excess_stream_bytes)
        if pdiff(comp_end,comp_ptr)<2 {return chunk_len}
        if excess_stream_bytes<32 {
            comp_ptr[0]=u8(0x80+excess_stream_bytes);comp_ptr=comp_ptr[1:]
            excesses_u32_hdr_size=1
        } else {
            if excess_stream_bytes>=64+(255<<5) {return chunk_len}
            comp_ptr[0]=u8(0x80+(32+(excess_stream_bytes&31)))
            comp_ptr[1]=u8((excess_stream_bytes-32)>>5)
            comp_ptr=comp_ptr[2:]
            excesses_u32_hdr_size=2
        }
    }

    literal_count:=pdiff(ea.literals_ptr_raw,ea.literals_space_raw)
    have_sub_lits:=ea.literals_ptr_sub!=ea.literals_space_sub
    literals_J:=entropy.LAGRANGE_COST_INVALID
    literals_uncompressed_J:=3+f32(literal_count)
    literal_comp_len:=-1

    if literal_count<compressor.HUFF_ARRAY_MIN_SIZE || level<=compressor.LEVEL_HYPER_FAST4 {
        pchunktype^=compressor.CHUNK_LITERALS_RAW
        literal_comp_len=ent_put_array_uncompressed(comp_ptr,comp_end,ea.literals_space_raw,
            literal_count)
        if literal_comp_len<0 {return chunk_len}
        comp_ptr=comp_ptr[literal_comp_len:]
        literals_J=literals_uncompressed_J
    } else {
        histo_raw,histo_sub:[256]u32
        entropy.count_histo_array_u8(ea.literals_space_raw[:literal_count],histo_raw[:])
        if have_sub_lits {entropy.count_histo_array_u8(ea.literals_space_sub[:literal_count],
            histo_sub[:])}
        if passinfo!=nil {
            passinfo.literal_histo_raw=histo_raw
            if have_sub_lits {passinfo.literal_histo_sub=histo_sub}
        }
        do_both_ways:=level>=compressor.LEVEL_OPTIMAL2
        do_put_sub:=do_both_ways
        sub_literal_time_J:=f32(0)
        if !have_sub_lits {
            do_both_ways=false
            do_put_sub=false
        } else {
            sub_literal_time_J=lambda*entropy.speedfit_parse_lz_subliterals(literal_count)
            if !do_both_ways {
                bits_raw:=ent_estimate_complen_bits(histo_raw[:],u32(literal_count))
                bits_sub:=ent_estimate_complen_bits(histo_sub[:],u32(literal_count))
                J_sub:=f32(bits_sub)/8+sub_literal_time_J
                J_raw:=f32(bits_raw)/8
                do_put_sub=J_sub<J_raw
            }
        }
        if do_put_sub {
            pchunktype^=compressor.CHUNK_LITERALS_SUB
            literal_comp_len=ent_put_array_histo(comp_ptr,comp_end,ea.literals_space_sub,
                literal_count,
                histo_sub[:],entropy_flags,lambda,&literals_J,deadline.literal,arena,level)
            literals_J+=sub_literal_time_J
        }
        do_put_raw:=do_both_ways
        if literal_comp_len<0 || literal_comp_len>=literal_count ||
            literals_J>literals_uncompressed_J {
            literals_J=entropy.LAGRANGE_COST_INVALID
            do_put_raw=true
        }
        if do_put_raw {
            len_raw:=ent_put_array_histo(comp_ptr,comp_end,ea.literals_space_raw,literal_count,
                histo_raw[:],entropy_flags,lambda,&literals_J,deadline.literal,arena,level)
            if len_raw>0 {
                literal_comp_len=len_raw
                pchunktype^=compressor.CHUNK_LITERALS_RAW
            }
        }
        if literal_comp_len<0 {return chunk_len}
        comp_ptr=comp_ptr[literal_comp_len:]
    }

    packet_J:=entropy.LAGRANGE_COST_INVALID
    packet_comp_len:=ent_put_array(comp_ptr,comp_end,ea.packets_space,packet_count,entropy_flags,
        lambda,
        &packet_J,deadline.packet,arena,level,
            passinfo!=nil ? raw_data(passinfo.packet_histo[:]) : nil)
    if packet_comp_len<0 {return chunk_len}
    comp_ptr=comp_ptr[packet_comp_len:]

    offsets_count:=pdiff(ea.offsets_u8_ptr,ea.offsets_u8_space)
    offset_alt_modulo:=0
    try_alt:=e.bitstream_flags&BITSTREAM_FLAG_ALT_OFFSETS!=0
    offsets_J:=entropy.LAGRANGE_COST_INVALID
    offsets_comp_len:=put_offset_44_or_alt_arrays(comp_ptr,comp_end,ea.offsets_u8_space,
        ea.offsets_space,
        offsets_count,entropy_flags,lambda,&offsets_J,deadline.offsets,true,try_alt,
            &offset_alt_modulo,
        arena,level,passinfo!=nil ? raw_data(passinfo.offset_histo1[:]) : nil,
        passinfo!=nil ? raw_data(passinfo.offset_histo2[:]) : nil)
    if offsets_comp_len<0 {return -1}
    comp_ptr=comp_ptr[offsets_comp_len:]
    if passinfo!=nil {passinfo.offset_alt_modulo=offset_alt_modulo}

    excesses_u8_J:=entropy.LAGRANGE_COST_INVALID
    excesses_u8_count:=pdiff(ea.excess_u8_ptr,ea.excess_u8_space)
    excesses_u8_comp_len:=ent_put_array(comp_ptr,comp_end,ea.excess_u8_space,excesses_u8_count,
        entropy_flags,
        lambda,&excesses_u8_J,deadline.excesses_u8,arena,level,
        passinfo!=nil ? raw_data(passinfo.excess_histo[:]) : nil)
    if excesses_u8_comp_len<0 {return chunk_len}
    comp_ptr=comp_ptr[excesses_u8_comp_len:]

    arrays_needed:=literal_count+packet_count+offsets_count*6+excesses_u8_count*5
    phase1:=arrays_needed+max(offsets_count,excesses_u8_count)
    phase1=max(phase1,literal_count*2)
    phase1=max(phase1,literal_count+packet_count*2)
    phase1+=compressor.ARRAY_INTERNAL_MAX_SCRATCH
    phase1+=32
    if phase1+4096>scratch_mem_size(chunk_len) {return chunk_len}

    excesses_u32_count:=int(uintptr(ea.excess_u32_ptr)-uintptr(ea.excess_u32_space))/4
    varbits_comp_len:=put_offsets_excesses(comp_ptr,comp_end,ea.offsets_u8_space,ea.offsets_space,
        offsets_count,offset_alt_modulo,ea.excess_u32_space,excesses_u32_count,
            excesses_u32_hdr_size,
        excess_stream_bytes)
    if varbits_comp_len<0 {return chunk_len}
    comp_ptr=comp_ptr[varbits_comp_len:]

    total_comp:=pdiff(comp_ptr,comp)
    if total_comp>=chunk_len {return chunk_len}
    parse_time:=entropy.speedfit_parse_lz(chunk_len,packet_count,excesses_u8_count)
    if parse_time>deadline.parse {return chunk_len}
    parse_complen:=varbits_comp_len+start_pos+excesses_u32_hdr_size
    parse_J:=f32(parse_complen)+lambda*parse_time
    total_J:=literals_J+packet_J+offsets_J+excesses_u8_J+parse_J
    total_J+=lambda*entropy.speedfit_get_excesses(excesses_u8_count,excesses_u32_count)
    pJ^=total_J
    return total_comp
}
