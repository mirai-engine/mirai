package zstd

no_compress_literals :: proc "contextless" (dst:[^]u8,dst_capacity:int,src:[^]u8,src_size:int) -> (size:int,err:Error) {
    ostart:=dst
    fl_size:=1+(src_size>31 ? 1 : 0)+(src_size>4095 ? 1 : 0)

    if src_size+fl_size>dst_capacity {return 0,.Dst_Size_Too_Small}

    switch fl_size {
    case 1: ostart[0]=u8(u32(Symbol_Encoding_Type.Basic)+u32(src_size)<<3)
    case 2: write16(ostart,u16(u32(Symbol_Encoding_Type.Basic)+(1<<2)+u32(src_size)<<4))
    case 3: write32(ostart,u32(Symbol_Encoding_Type.Basic)+(3<<2)+u32(src_size)<<4)
    }

    copy_bytes(padd(ostart,fl_size),src,src_size)
    return src_size+fl_size,.None
}

@(private="file")
all_bytes_identical :: proc "contextless" (src:[^]u8,src_size:int) -> bool {
    b:=src[0]
    for p:=1;p<src_size;p+=1 {
        if src[p]!=b {return false}
    }
    return true
}

// All the bytes of src are identical and dst_capacity is at least 4.
compress_rle_literals_block :: proc "contextless" (dst:[^]u8,dst_capacity:int,src:[^]u8,src_size:int) -> (size:int,err:Error) {
    ostart:=dst
    fl_size:=1+(src_size>31 ? 1 : 0)+(src_size>4095 ? 1 : 0)

    switch fl_size {
    case 1: ostart[0]=u8(u32(Symbol_Encoding_Type.RLE)+u32(src_size)<<3)
    case 2: write16(ostart,u16(u32(Symbol_Encoding_Type.RLE)+(1<<2)+u32(src_size)<<4))
    case 3: write32(ostart,u32(Symbol_Encoding_Type.RLE)+(3<<2)+u32(src_size)<<4)
    }

    ostart[fl_size]=src[0]
    return fl_size+1,.None
}

@(private="file")
min_literals_to_compress :: proc "contextless" (strategy:Strategy,huf_repeat:Huf_Repeat) -> int {
    shift:=9-u32(strategy)
    if shift>3 {shift=3}
    return huf_repeat==.Valid ? 6 : int(8)<<shift
}

// entropy_workspace is aligned to 4 bytes and of at least HUF_WORKSPACE_SIZE bytes.
compress_literals :: proc "contextless" (dst:[^]u8,dst_capacity:int,src:[^]u8,src_size:int,entropy_workspace:[^]u8,entropy_workspace_size:int,prev_huf,next_huf:^Huf_CTables,strategy:Strategy,disable_literal_compression,suspect_uncompressible:bool) -> (size:int,err:Error) {
    lh_size:=3+(src_size>=1*KB ? 1 : 0)+(src_size>=16*KB ? 1 : 0)
    ostart:=dst
    single_stream:=src_size<256
    h_type:=Symbol_Encoding_Type.Compressed
    c_lit_size:int

    next_huf^=prev_huf^

    if disable_literal_compression {return no_compress_literals(dst,dst_capacity,src,src_size)}

    if src_size<min_literals_to_compress(strategy,prev_huf.repeat_mode) {
        return no_compress_literals(dst,dst_capacity,src,src_size)
    }

    if dst_capacity<lh_size+1 {return 0,.Dst_Size_Too_Small}
    {
        repeat:=prev_huf.repeat_mode
        flags:Huf_Flags
        if strategy<.Lazy && src_size<=1024 {flags+={.Prefer_Repeat}}
        if strategy>=HUF_OPTIMAL_DEPTH_THRESHOLD {flags+={.Optimal_Depth}}
        if suspect_uncompressible {flags+={.Suspect_Uncompressible}}

        if repeat==.Valid && lh_size==3 {single_stream=true}
        huf_err:Error
        if single_stream {
            c_lit_size,huf_err=huf_compress1x_repeat(padd(ostart,lh_size),dst_capacity-lh_size,src,src_size,HUF_SYMBOLVALUE_MAX,LIT_HUF_LOG,entropy_workspace,entropy_workspace_size,([^]u64)(&next_huf.ctable),&repeat,flags)
        } else {
            c_lit_size,huf_err=huf_compress4x_repeat(padd(ostart,lh_size),dst_capacity-lh_size,src,src_size,HUF_SYMBOLVALUE_MAX,LIT_HUF_LOG,entropy_workspace,entropy_workspace_size,([^]u64)(&next_huf.ctable),&repeat,flags)
        }
        if huf_err!=.None {c_lit_size=0}
        if repeat!=.None {h_type=.Repeat}
    }

    {
        min_gain_size:=min_gain(src_size,strategy)
        if c_lit_size==0 || c_lit_size>=src_size-min_gain_size {
            next_huf^=prev_huf^
            return no_compress_literals(dst,dst_capacity,src,src_size)
        }
    }
    if c_lit_size==1 {
        if src_size>=8 || all_bytes_identical(src,src_size) {
            next_huf^=prev_huf^
            return compress_rle_literals_block(dst,dst_capacity,src,src_size)
        }
    }

    if h_type==.Compressed {next_huf.repeat_mode=.Check}

    switch lh_size {
    case 3:
        lhc:=u32(h_type)+(single_stream ? 0 : 1)<<2+u32(src_size)<<4+u32(c_lit_size)<<14
        write24(ostart,lhc)
    case 4:
        lhc:=u32(h_type)+(2<<2)+u32(src_size)<<4+u32(c_lit_size)<<18
        write32(ostart,lhc)
    case 5:
        lhc:=u32(h_type)+(3<<2)+u32(src_size)<<4+u32(c_lit_size)<<22
        write32(ostart,lhc)
        ostart[4]=u8(c_lit_size>>10)
    }
    return lh_size+c_lit_size,.None
}
