package zstd

import "base:intrinsics"

// One-shot decoding of whole frames into one contiguous buffer: skippable frames, concatenated
// frames, content sizes and checksums. No dictionaries and no streaming.

CONTENTSIZE_UNKNOWN :: max(u64)
CONTENTSIZE_ERROR :: max(u64)-1

FRAME_HEADER_SIZE_PREFIX :: 5
FRAME_HEADER_SIZE_MIN :: 6
FRAME_HEADER_SIZE_MAX :: 18

@(rodata,private="file") Fcs_Field_Size:=[4]int{0,2,4,8}
@(rodata,private="file") Did_Field_Size:=[4]int{0,1,2,4}

Frame_Type :: enum u32 {Frame,Skippable}

Frame_Header :: struct {
    frame_content_size:u64,
    window_size:u64,
    block_size_max:u32,
    frame_type:Frame_Type,
    header_size:u32,
    dict_id:u32,
    checksum_flag:u32,
}

Entropy_DTables :: struct {
    ll_table:[SEQ_SYMBOL_TABLE_LL]Seq_Symbol,
    of_table:[SEQ_SYMBOL_TABLE_OF]Seq_Symbol,
    ml_table:[SEQ_SYMBOL_TABLE_ML]Seq_Symbol,
    huf_table:[1+(1<<HUFFDTABLE_CAPACITY_LOG)]u32,
    rep:[REP_NUM]u32,
}

Lit_Location :: enum {Not_In_Dst,In_Dst,Split}

// Plain data: zeroed memory is a valid context, and decoding allocates nothing.
DCtx :: struct {
    ll_tptr,ml_tptr,of_tptr:[^]Seq_Symbol,
    huf_ptr:[^]u32,
    entropy:Entropy_DTables,
    workspace:[HUF_DECOMPRESS_WORKSPACE_SIZE_U32]u32,
    prefix_start:[^]u8,
    f_params:Frame_Header,
    lit_entropy,fse_entropy:u32,
    xxh_state:Xxh64_State,
    validate_checksum:bool,
    lit_ptr:[^]u8,
    lit_size:int,
    lit_buffer,lit_buffer_end:[^]u8,
    lit_buffer_location:Lit_Location,
    lit_extra_buffer:[LIT_BUFFER_EXTRA_SIZE+WILDCOPY_OVERLENGTH]u8,
}

dctx_create :: proc(allocator:=context.allocator) -> (dctx:^DCtx,err:Error) {
    created,alloc_err:=new(DCtx,allocator)
    if alloc_err!=nil {return nil,.Memory_Allocation}
    return created,.None
}

dctx_destroy :: proc(dctx:^DCtx,allocator:=context.allocator) {
    free(dctx,allocator)
}

@(private="file")
frame_header_size_internal :: proc "contextless" (src:[^]u8,src_size:int) -> (size:int,err:Error) {
    if src_size<FRAME_HEADER_SIZE_PREFIX {return 0,.Src_Size_Wrong}
    fhd:=src[FRAME_HEADER_SIZE_PREFIX-1]
    dict_id:=fhd&3
    single_segment:=(fhd>>5)&1
    fcs_id:=fhd>>6
    size=FRAME_HEADER_SIZE_PREFIX+int(1-single_segment)+Did_Field_Size[dict_id]+Fcs_Field_Size[fcs_id]
    if single_segment!=0 && fcs_id==0 {size+=1}
    return size,.None
}

// need>0 asks for that many bytes of src; 0 means zfh is filled.
get_frame_header :: proc "contextless" (zfh:^Frame_Header,src:[^]u8,src_size:int) -> (need:int,err:Error) {
    ip:=src
    min_input_size:=FRAME_HEADER_SIZE_PREFIX

    if src_size>0 {
        if src==nil {return 0,.Generic}
    }
    if src_size<min_input_size {
        if src_size>0 {
            to_copy:=min(4,src_size)
            hbuf:[4]u8
            write32(&hbuf[0],MAGIC_NUMBER)
            intrinsics.mem_copy_non_overlapping(&hbuf[0],src,to_copy)
            if read32(&hbuf[0])!=MAGIC_NUMBER {
                write32(&hbuf[0],MAGIC_SKIPPABLE_START)
                intrinsics.mem_copy_non_overlapping(&hbuf[0],src,to_copy)
                if read32(&hbuf[0])&MAGIC_SKIPPABLE_MASK!=MAGIC_SKIPPABLE_START {
                    return 0,.Prefix_Unknown
                }
            }
        }
        return min_input_size,.None
    }

    zfh^={}
    if read32(src)!=MAGIC_NUMBER {
        if read32(src)&MAGIC_SKIPPABLE_MASK==MAGIC_SKIPPABLE_START {
            if src_size<SKIPPABLE_HEADER_SIZE {return SKIPPABLE_HEADER_SIZE,.None}
            zfh^={}
            zfh.frame_type=.Skippable
            zfh.dict_id=read32(src)-MAGIC_SKIPPABLE_START
            zfh.header_size=SKIPPABLE_HEADER_SIZE
            zfh.frame_content_size=u64(read32(padd(src,FRAME_ID_SIZE)))
            return 0,.None
        }
        return 0,.Prefix_Unknown
    }

    {
        fhsize:=frame_header_size_internal(src,src_size) or_return
        if src_size<fhsize {return fhsize,.None}
        zfh.header_size=u32(fhsize)
    }

    {
        fhd_byte:=ip[min_input_size-1]
        pos:=min_input_size
        dict_id_size_code:=fhd_byte&3
        checksum_flag:=(fhd_byte>>2)&1
        single_segment:=(fhd_byte>>5)&1
        fcs_id:=fhd_byte>>6
        window_size:u64
        dict_id:u32
        frame_content_size:=CONTENTSIZE_UNKNOWN
        if fhd_byte&0x08!=0 {return 0,.Frame_Parameter_Unsupported}

        if single_segment==0 {
            wl_byte:=ip[pos]
            pos+=1
            window_log:=u32(wl_byte>>3)+WINDOW_LOG_ABSOLUTE_MIN
            if window_log>WINDOW_LOG_MAX {return 0,.Frame_Parameter_Window_Too_Large}
            window_size=u64(1)<<window_log
            window_size+=(window_size>>3)*u64(wl_byte&7)
        }
        switch dict_id_size_code {
        case 1:
            dict_id=u32(ip[pos])
            pos+=1
        case 2:
            dict_id=u32(read16(padd(ip,pos)))
            pos+=2
        case 3:
            dict_id=read32(padd(ip,pos))
            pos+=4
        }
        switch fcs_id {
        case 0:
            if single_segment!=0 {frame_content_size=u64(ip[pos])}
        case 1:
            frame_content_size=u64(read16(padd(ip,pos)))+256
        case 2:
            frame_content_size=u64(read32(padd(ip,pos)))
        case 3:
            frame_content_size=read64(padd(ip,pos))
        }
        if single_segment!=0 {window_size=frame_content_size}

        zfh.frame_type=.Frame
        zfh.frame_content_size=frame_content_size
        zfh.window_size=window_size
        zfh.block_size_max=u32(min(window_size,BLOCK_SIZE_MAX))
        zfh.dict_id=dict_id
        zfh.checksum_flag=u32(checksum_flag)
    }
    return 0,.None
}

// The decompressed size of the single frame at src: CONTENTSIZE_UNKNOWN when the header does not
// say it, CONTENTSIZE_ERROR on an invalid or truncated header.
get_frame_content_size :: proc "contextless" (src:[^]u8,src_size:int) -> u64 {
    zfh:Frame_Header
    need,err:=get_frame_header(&zfh,src,src_size)
    if err!=.None || need!=0 {return CONTENTSIZE_ERROR}
    if zfh.frame_type==.Skippable {return 0}
    return zfh.frame_content_size
}

@(private="file")
read_skippable_frame_size :: proc "contextless" (src:[^]u8,src_size:int) -> (size:int,err:Error) {
    if src_size<SKIPPABLE_HEADER_SIZE {return 0,.Src_Size_Wrong}
    size_u32:=read32(padd(src,FRAME_ID_SIZE))
    if size_u32+SKIPPABLE_HEADER_SIZE<size_u32 {return 0,.Frame_Parameter_Unsupported}
    skippable_size:=SKIPPABLE_HEADER_SIZE+int(size_u32)
    if skippable_size>src_size {return 0,.Src_Size_Wrong}
    return skippable_size,.None
}

@(private="file")
decode_frame_header :: proc "contextless" (dctx:^DCtx,src:[^]u8,header_size:int) -> Error {
    result,err:=get_frame_header(&dctx.f_params,src,header_size)
    if err!=.None {return err}
    if result>0 {return .Src_Size_Wrong}

    if dctx.f_params.dict_id!=0 {return .Frame_Parameter_Unsupported}
    dctx.validate_checksum=dctx.f_params.checksum_flag!=0
    if dctx.validate_checksum {xxh64_reset(&dctx.xxh_state,0)}
    return .None
}

@(private="file")
copy_raw_block :: proc "contextless" (dst:[^]u8,dst_capacity:int,src:[^]u8,src_size:int) -> (size:int,err:Error) {
    if src_size>dst_capacity {return 0,.Dst_Size_Too_Small}
    if dst==nil {
        if src_size==0 {return 0,.None}
        return 0,.Dst_Size_Too_Small
    }
    intrinsics.mem_copy(dst,src,src_size)
    return src_size,.None
}

@(private="file")
set_rle_block :: proc "contextless" (dst:[^]u8,dst_capacity:int,b:u8,regen_size:int) -> (size:int,err:Error) {
    if regen_size>dst_capacity {return 0,.Dst_Size_Too_Small}
    if dst==nil {
        if regen_size==0 {return 0,.None}
        return 0,.Dst_Size_Too_Small
    }
    set_rle_bytes(dst,b,regen_size)
    return regen_size,.None
}

@(private="file")
decompress_begin :: proc "contextless" (dctx:^DCtx) {
    dctx.prefix_start=nil
    dctx.entropy.huf_table[0]=HUFFDTABLE_CAPACITY_LOG*0x1000001
    dctx.lit_entropy=0
    dctx.fse_entropy=0
    dctx.entropy.rep=REP_START_VALUE
    dctx.ll_tptr=&dctx.entropy.ll_table[0]
    dctx.ml_tptr=&dctx.entropy.ml_table[0]
    dctx.of_tptr=&dctx.entropy.of_table[0]
    dctx.huf_ptr=&dctx.entropy.huf_table[0]
}

// Moves src_ptr past the frame.
@(private="file")
decompress_frame :: proc "contextless" (dctx:^DCtx,dst:[^]u8,dst_capacity:int,src_ptr:^[^]u8,src_size_ptr:^int) -> (size:int,err:Error) {
    istart:=src_ptr^
    ip:=istart
    ostart:=dst
    oend:=dst_capacity!=0 ? padd(ostart,dst_capacity) : ostart
    op:=ostart
    remaining_src_size:=src_size_ptr^

    if remaining_src_size<FRAME_HEADER_SIZE_MIN+BLOCK_HEADER_SIZE {return 0,.Src_Size_Wrong}

    {
        frame_header_size:=frame_header_size_internal(ip,FRAME_HEADER_SIZE_PREFIX) or_return
        if remaining_src_size<frame_header_size+BLOCK_HEADER_SIZE {return 0,.Src_Size_Wrong}
        if e:=decode_frame_header(dctx,ip,frame_header_size);e!=.None {return 0,e}
        ip=padd(ip,frame_header_size)
        remaining_src_size-=frame_header_size
    }

    for {
        o_block_end:=oend
        decoded_size:int
        block_properties:Block_Properties
        c_block_size:=get_cblock_size(ip,remaining_src_size,&block_properties) or_return

        ip=padd(ip,BLOCK_HEADER_SIZE)
        remaining_src_size-=BLOCK_HEADER_SIZE
        if c_block_size>remaining_src_size {return 0,.Src_Size_Wrong}

        if uintptr(ip)>=uintptr(op) && uintptr(ip)<uintptr(o_block_end) {
            o_block_end=padd(op,pdiff(ip,op))
        }

        switch block_properties.block_type {
        case .Compressed:
            decoded_size=decompress_block_internal(dctx,op,pdiff(o_block_end,op),ip,c_block_size) or_return
        case .Raw:
            decoded_size=copy_raw_block(op,pdiff(oend,op),ip,c_block_size) or_return
        case .RLE:
            decoded_size=set_rle_block(op,pdiff(o_block_end,op),ip[0],int(block_properties.orig_size)) or_return
        case .Reserved:
            return 0,.Corruption_Detected
        }
        if dctx.validate_checksum {
            xxh64_update(&dctx.xxh_state,op,decoded_size)
        }
        if decoded_size!=0 {
            op=padd(op,decoded_size)
        }
        ip=padd(ip,c_block_size)
        remaining_src_size-=c_block_size
        if block_properties.last_block!=0 {break}
    }

    if dctx.f_params.frame_content_size!=CONTENTSIZE_UNKNOWN {
        if u64(pdiff(op,ostart))!=dctx.f_params.frame_content_size {return 0,.Corruption_Detected}
    }
    if dctx.f_params.checksum_flag!=0 {
        if remaining_src_size<4 {return 0,.Checksum_Wrong}
        check_calc:=u32(xxh64_digest(&dctx.xxh_state))
        check_read:=read32(ip)
        if check_read!=check_calc {return 0,.Checksum_Wrong}
        ip=padd(ip,4)
        remaining_src_size-=4
    }
    src_ptr^=ip
    src_size_ptr^=remaining_src_size
    return pdiff(op,ostart),.None
}

// Decodes every frame of src, which must end exactly at the end of the last one. Never reads or
// writes outside src and dst.
decompress_dctx :: proc "contextless" (dctx:^DCtx,dst:[^]u8,dst_capacity:int,src:[^]u8,src_size:int) -> (written:int,err:Error) {
    src_ptr:=src
    remaining:=src_size
    dst_ptr:=dst
    capacity:=dst_capacity
    more_than_1_frame:=false

    for remaining>=FRAME_HEADER_SIZE_PREFIX {
        if remaining>=4 {
            magic_number:=read32(src_ptr)
            if magic_number&MAGIC_SKIPPABLE_MASK==MAGIC_SKIPPABLE_START {
                skippable_size:=read_skippable_frame_size(src_ptr,remaining) or_return
                src_ptr=padd(src_ptr,skippable_size)
                remaining-=skippable_size
                continue
            }
        }

        decompress_begin(dctx)
        if dst_ptr!=nil && capacity>0 {dctx.prefix_start=dst_ptr}

        {
            res,e:=decompress_frame(dctx,dst_ptr,capacity,&src_ptr,&remaining)
            if e==.Prefix_Unknown && more_than_1_frame {return 0,.Src_Size_Wrong}
            if e!=.None {return 0,e}
            if res!=0 {dst_ptr=padd(dst_ptr,res)}
            capacity-=res
        }
        more_than_1_frame=true
    }

    if remaining!=0 {return 0,.Src_Size_Wrong}

    return pdiff(dst_ptr,dst),.None
}
