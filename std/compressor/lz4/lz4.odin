package lz4

import "base:intrinsics"

// LZ4 block format. The decoder and the high-compression encoder; the format is little-endian and
// so are the three platforms, so reads and writes do not swap.

HC_CLEVEL_MIN :: 2
HC_CLEVEL_DEFAULT :: 9
HC_CLEVEL_OPT_MIN :: 10
HC_CLEVEL_MAX :: 12

@(private) MAX_INPUT_SIZE :: 0x7E000000
@(private) MAX_INT :: 0x7FFFFFFF
@(private) MINMATCH :: 4
@(private) WILDCOPYLENGTH :: 8
@(private) LASTLITERALS :: 5
@(private) MFLIMIT :: 12
@(private) MATCH_SAFEGUARD_DISTANCE :: 2*WILDCOPYLENGTH-MINMATCH
@(private) FASTLOOP_SAFE_DISTANCE :: 64
@(private) MIN_LENGTH :: MFLIMIT+1
@(private) DISTANCE_MAX :: 65535
@(private) ML_BITS :: 4
@(private) ML_MASK :: (1<<ML_BITS)-1
@(private) RUN_BITS :: 8-ML_BITS
@(private) RUN_MASK :: (1<<RUN_BITS)-1

@(private,rodata) INC32_TABLE:=[8]uintptr{0,1,2,1,0,4,4,4}
@(private,rodata) DEC64_TABLE:=[8]int{0,0,0,-1,-4,1,2,3}

// 0 when input_size is out of range.
compress_bound :: proc "contextless" (input_size:int) -> int {
    return uint(input_size)>MAX_INPUT_SIZE?0:input_size+input_size/255+16
}

// Levels 3 to 12; the state comes from the allocator. Fails when dst is too small.
compress_hc :: proc(src,dst:[]u8,level:int,allocator:=context.allocator) -> (written:int,ok:bool) {
    if level<3 || level>HC_CLEVEL_MAX || uint(len(src))>MAX_INPUT_SIZE {return 0,false}
    hc,hc_error:=new(Hc_Ctx,allocator)
    if hc_error!=nil {return 0,false}
    defer free(hc,allocator)
    hc.next_to_update=HC_PREFIX_IDX
    limit:=len(dst)<compress_bound(len(src))
    params:=K_CL_TABLE[level]
    if params.strat==.Hc {
        written=hc_compress_hash_chain(hc,raw_data(src),raw_data(dst),len(src),len(dst),params.nb_searches,limit)
    } else {
        written=hc_compress_optimal(hc,raw_data(src),raw_data(dst),len(src),len(dst),params.nb_searches,params.target_length,limit,level>=HC_CLEVEL_MAX,allocator)
    }
    return written,written>0
}

// dst has to hold the whole decoded block.
decompress_safe :: proc "contextless" (src,dst:[]u8) -> (written:int,ok:bool) #no_bounds_check {
    if raw_data(src)==nil || len(src)>MAX_INT || len(dst)>MAX_INT {return 0,false}
    ip:=uintptr(raw_data(src))
    iend:=ip+uintptr(len(src))
    low_prefix:=uintptr(raw_data(dst))
    op:=low_prefix
    oend:=op+uintptr(len(dst))
    shortiend:=iend-14-2
    shortoend:=oend-14-18
    token,length,offset,match,cpy:uintptr
    stage:=Decode_Stage.Token

    if len(dst)==0 {return 0,len(src)==1 && src[0]==0}
    if len(src)==0 {return 0,false}

    if oend-op>=FASTLOOP_SAFE_DISTANCE {
        fast: for {
            token=uintptr(read8(ip));ip+=1
            length=token>>ML_BITS

            if length==RUN_MASK {
                addl,valid:=read_variable_length(&ip,iend-RUN_MASK,true)
                if !valid {return 0,false}
                length+=addl
                if op+length>oend-32 || ip+length>iend-32 {
                    stage=.Literal_Copy
                    break fast
                }
                wild_copy32(op,ip,op+length)
                ip+=length;op+=length
            } else if ip<=iend-(16+1) {
                copy16(op,ip)
                ip+=length;op+=length
            } else {
                stage=.Literal_Copy
                break fast
            }

            offset=uintptr(read16(ip));ip+=2
            match=op-offset
            length=token&ML_MASK

            if length==ML_MASK {
                addl,valid:=read_variable_length(&ip,iend-LASTLITERALS+1,false)
                if !valid {return 0,false}
                length+=addl
                length+=MINMATCH
                if op+length>=oend-FASTLOOP_SAFE_DISTANCE {
                    stage=.Match_Copy
                    break fast
                }
            } else {
                length+=MINMATCH
                if op+length>=oend-FASTLOOP_SAFE_DISTANCE {
                    stage=.Match_Copy
                    break fast
                }
                if match>=low_prefix && offset>=8 {
                    copy8(op,match)
                    copy8(op+8,match+8)
                    copy2(op+16,match+16)
                    op+=length
                    continue
                }
            }

            if match<low_prefix {return 0,false}

            cpy=op+length
            if offset<16 {
                memcpy_using_offset(op,match,cpy,offset)
            } else {
                wild_copy32(op,match,cpy)
            }
            op=cpy
        }
    }

    safe: for {
        if stage==.Token {
            token=uintptr(read8(ip));ip+=1
            length=token>>ML_BITS

            if length!=RUN_MASK && ip<shortiend && op<=shortoend {
                copy16(op,ip)
                op+=length;ip+=length

                length=token&ML_MASK
                offset=uintptr(read16(ip));ip+=2
                match=op-offset

                if length!=ML_MASK && offset>=8 && match>=low_prefix {
                    copy8(op,match)
                    copy8(op+8,match+8)
                    copy2(op+16,match+16)
                    op+=length+MINMATCH
                    continue safe
                }
                stage=.Copy_Match
            } else {
                if length==RUN_MASK {
                    addl,valid:=read_variable_length(&ip,iend-RUN_MASK,true)
                    if !valid {return 0,false}
                    length+=addl
                }
                stage=.Literal_Copy
            }
        }

        if stage==.Literal_Copy {
            cpy=op+length
            if cpy>oend-MFLIMIT || ip+length>iend-(2+1+LASTLITERALS) {
                if ip+length!=iend || cpy>oend {return 0,false}
                intrinsics.mem_copy(rawptr(op),rawptr(ip),length)
                ip+=length
                op+=length
                break safe
            } else {
                wild_copy8(op,ip,cpy)
                ip+=length;op=cpy
            }

            offset=uintptr(read16(ip));ip+=2
            match=op-offset
            length=token&ML_MASK
            stage=.Copy_Match
        }

        if stage==.Copy_Match {
            if length==ML_MASK {
                addl,valid:=read_variable_length(&ip,iend-LASTLITERALS+1,false)
                if !valid {return 0,false}
                length+=addl
            }
            length+=MINMATCH
        }

        if match<low_prefix {return 0,false}

        cpy=op+length

        if offset<8 {
            write32(op,0)
            copy1(op,match)
            copy1(op+1,match+1)
            copy1(op+2,match+2)
            copy1(op+3,match+3)
            match+=INC32_TABLE[offset]
            copy4(op+4,match)
            match-=uintptr(DEC64_TABLE[offset])
        } else {
            copy8(op,match)
            match+=8
        }
        op+=8

        if cpy>oend-MATCH_SAFEGUARD_DISTANCE {
            o_copy_limit:=oend-(WILDCOPYLENGTH-1)
            if cpy>oend-LASTLITERALS {return 0,false}
            if op<o_copy_limit {
                wild_copy8(op,match,o_copy_limit)
                match+=o_copy_limit-op
                op=o_copy_limit
            }
            for op<cpy {
                copy1(op,match)
                op+=1;match+=1
            }
        } else {
            copy8(op,match)
            if length>16 {wild_copy8(op+8,match+8,cpy)}
        }
        op=cpy
        stage=.Token
    }

    return int(op-low_prefix),true
}

@(private="file")
Decode_Stage :: enum {Token,Literal_Copy,Copy_Match,Match_Copy}

@(private="file")
read_variable_length :: #force_inline proc "contextless" (ip:^uintptr,ilimit:uintptr,initial_check:bool) -> (length:uintptr,ok:bool) {
    if initial_check && ip^>=ilimit {return 0,false}
    s:=uintptr(read8(ip^))
    ip^+=1
    length+=s
    if ip^>ilimit {return 0,false}
    if s!=255 {return length,true}
    for {
        s=uintptr(read8(ip^))
        ip^+=1
        length+=s
        if ip^>ilimit {return 0,false}
        if s!=255 {break}
    }
    return length,true
}

@(private="file")
memcpy_using_offset_base :: #force_inline proc "contextless" (d,s,e,offset:uintptr) #no_bounds_check {
    d,s:=d,s
    if offset<8 {
        write32(d,0)
        copy1(d,s)
        copy1(d+1,s+1)
        copy1(d+2,s+2)
        copy1(d+3,s+3)
        s+=INC32_TABLE[offset]
        copy4(d+4,s)
        s-=uintptr(DEC64_TABLE[offset])
        d+=8
    } else {
        copy8(d,s)
        d+=8
        s+=8
    }
    wild_copy8(d,s,e)
}

@(private="file")
memcpy_using_offset :: #force_inline proc "contextless" (d,s,e,offset:uintptr) {
    d:=d
    v:u64
    switch offset {
    case 1:
        v=u64(read8(s))*0x0101010101010101
    case 2:
        v=u64(read16(s))
        v|=v<<16
        v|=v<<32
    case 4:
        v=u64(read32(s))
        v|=v<<32
    case:
        memcpy_using_offset_base(d,s,e,offset)
        return
    }
    write64(d,v)
    d+=8
    for d<e {
        write64(d,v)
        d+=8
    }
}

@(private) at :: #force_inline proc "contextless" (p:[^]u8,n:int) -> uintptr {return uintptr(p)+uintptr(n)}

@(private) read8 :: #force_inline proc "contextless" (p:uintptr) -> u8 {return (^u8)(p)^}
@(private) read16 :: #force_inline proc "contextless" (p:uintptr) -> u16 {return intrinsics.unaligned_load((^u16)(p))}
@(private) read32 :: #force_inline proc "contextless" (p:uintptr) -> u32 {return intrinsics.unaligned_load((^u32)(p))}
@(private) read64 :: #force_inline proc "contextless" (p:uintptr) -> u64 {return intrinsics.unaligned_load((^u64)(p))}
@(private) write16 :: #force_inline proc "contextless" (p:uintptr,v:u16) {intrinsics.unaligned_store((^u16)(p),v)}
@(private) write32 :: #force_inline proc "contextless" (p:uintptr,v:u32) {intrinsics.unaligned_store((^u32)(p),v)}
@(private) write64 :: #force_inline proc "contextless" (p:uintptr,v:u64) {intrinsics.unaligned_store((^u64)(p),v)}

@(private) copy1 :: #force_inline proc "contextless" (d,s:uintptr) {(^u8)(d)^=(^u8)(s)^}
@(private) copy2 :: #force_inline proc "contextless" (d,s:uintptr) {write16(d,read16(s))}
@(private) copy4 :: #force_inline proc "contextless" (d,s:uintptr) {write32(d,read32(s))}
@(private) copy8 :: #force_inline proc "contextless" (d,s:uintptr) {write64(d,read64(s))}

@(private) copy16 :: #force_inline proc "contextless" (d,s:uintptr) {
    a,b:=read64(s),read64(s+8)
    write64(d,a)
    write64(d+8,b)
}

// May write up to 7 bytes past e.
@(private) wild_copy8 :: #force_inline proc "contextless" (d,s,e:uintptr) {
    d,s:=d,s
    for {
        copy8(d,s)
        d+=8;s+=8
        if d>=e {break}
    }
}

// May write up to 31 bytes past e; s and d are at least 16 bytes apart.
@(private) wild_copy32 :: #force_inline proc "contextless" (d,s,e:uintptr) {
    d,s:=d,s
    for {
        copy16(d,s)
        copy16(d+16,s+16)
        d+=32;s+=32
        if d>=e {break}
    }
}

@(private) nb_common_bytes :: #force_inline proc "contextless" (val:u64) -> int {return int(intrinsics.count_trailing_zeros(val))>>3}

// Positions are offsets of the same buffer src.
@(private) count :: #force_inline proc "contextless" (src:[^]u8,p_in,p_match,p_in_limit:int) -> int #no_bounds_check {
    p_in,p_match:=p_in,p_match
    start:=p_in
    if p_in<p_in_limit-7 {
        diff:=read64(at(src,p_match))~read64(at(src,p_in))
        if diff!=0 {return nb_common_bytes(diff)}
        p_in+=8;p_match+=8
    }
    for p_in<p_in_limit-7 {
        diff:=read64(at(src,p_match))~read64(at(src,p_in))
        if diff==0 {
            p_in+=8;p_match+=8
            continue
        }
        p_in+=nb_common_bytes(diff)
        return p_in-start
    }
    if p_in<p_in_limit-3 && read32(at(src,p_match))==read32(at(src,p_in)) {p_in+=4;p_match+=4}
    if p_in<p_in_limit-1 && read16(at(src,p_match))==read16(at(src,p_in)) {p_in+=2;p_match+=2}
    if p_in<p_in_limit && src[p_match]==src[p_in] {p_in+=1}
    return p_in-start
}
