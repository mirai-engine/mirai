package zstd

import "base:intrinsics"

// Decodes the compressed blocks: the literals section, then the sequences.

MIN_SEQUENCES_SIZE :: 1

Seq_Symbol_Header :: struct {fast_mode,table_log:u32}
Seq_Symbol :: struct {next_state:u16,nb_additional_bits,nb_bits:u8,base_value:u32}

SEQ_SYMBOL_TABLE_LL :: 1+(1<<LL_FSE_LOG)
SEQ_SYMBOL_TABLE_OF :: 1+(1<<OFF_FSE_LOG)
SEQ_SYMBOL_TABLE_ML :: 1+(1<<ML_FSE_LOG)

LIT_BUFFER_EXTRA_SIZE :: 1<<16

@(rodata,private="file") LL_base:=[MAX_LL+1]u32{
    0,1,2,3,4,5,6,7,
    8,9,10,11,12,13,14,15,
    16,18,20,22,24,28,32,40,
    48,64,0x80,0x100,0x200,0x400,0x800,0x1000,
    0x2000,0x4000,0x8000,0x10000,
}

@(rodata,private="file") OF_base:=[MAX_OFF+1]u32{
    0,1,1,5,0xD,0x1D,0x3D,0x7D,
    0xFD,0x1FD,0x3FD,0x7FD,0xFFD,0x1FFD,0x3FFD,0x7FFD,
    0xFFFD,0x1FFFD,0x3FFFD,0x7FFFD,0xFFFFD,0x1FFFFD,0x3FFFFD,0x7FFFFD,
    0xFFFFFD,0x1FFFFFD,0x3FFFFFD,0x7FFFFFD,0xFFFFFFD,0x1FFFFFFD,0x3FFFFFFD,0x7FFFFFFD,
}

@(rodata,private="file") OF_bits:=[MAX_OFF+1]u8{
    0,1,2,3,4,5,6,7,
    8,9,10,11,12,13,14,15,
    16,17,18,19,20,21,22,23,
    24,25,26,27,28,29,30,31,
}

@(rodata,private="file") ML_base:=[MAX_ML+1]u32{
    3,4,5,6,7,8,9,10,
    11,12,13,14,15,16,17,18,
    19,20,21,22,23,24,25,26,
    27,28,29,30,31,32,33,34,
    35,37,39,41,43,47,51,59,
    67,83,99,0x83,0x103,0x203,0x403,0x803,
    0x1003,0x2003,0x4003,0x8003,0x10003,
}

@(rodata,private="file") LL_default_dtable:=[(1<<LL_DEFAULT_NORM_LOG)+1]Seq_Symbol{
    {1,1,1,LL_DEFAULT_NORM_LOG},
    {0,0,4,0},{16,0,4,0},
    {32,0,5,1},{0,0,5,3},
    {0,0,5,4},{0,0,5,6},
    {0,0,5,7},{0,0,5,9},
    {0,0,5,10},{0,0,5,12},
    {0,0,6,14},{0,1,5,16},
    {0,1,5,20},{0,1,5,22},
    {0,2,5,28},{0,3,5,32},
    {0,4,5,48},{32,6,5,64},
    {0,7,5,128},{0,8,6,256},
    {0,10,6,1024},{0,12,6,4096},
    {32,0,4,0},{0,0,4,1},
    {0,0,5,2},{32,0,5,4},
    {0,0,5,5},{32,0,5,7},
    {0,0,5,8},{32,0,5,10},
    {0,0,5,11},{0,0,6,13},
    {32,1,5,16},{0,1,5,18},
    {32,1,5,22},{0,2,5,24},
    {32,3,5,32},{0,3,5,40},
    {0,6,4,64},{16,6,4,64},
    {32,7,5,128},{0,9,6,512},
    {0,11,6,2048},{48,0,4,0},
    {16,0,4,1},{32,0,5,2},
    {32,0,5,3},{32,0,5,5},
    {32,0,5,6},{32,0,5,8},
    {32,0,5,9},{32,0,5,11},
    {32,0,5,12},{0,0,6,15},
    {32,1,5,18},{32,1,5,20},
    {32,2,5,24},{32,2,5,28},
    {32,3,5,40},{32,4,5,48},
    {0,16,6,65536},{0,15,6,32768},
    {0,14,6,16384},{0,13,6,8192},
}

@(rodata,private="file") OF_default_dtable:=[(1<<OF_DEFAULT_NORM_LOG)+1]Seq_Symbol{
    {1,1,1,OF_DEFAULT_NORM_LOG},
    {0,0,5,0},{0,6,4,61},
    {0,9,5,509},{0,15,5,32765},
    {0,21,5,2097149},{0,3,5,5},
    {0,7,4,125},{0,12,5,4093},
    {0,18,5,262141},{0,23,5,8388605},
    {0,5,5,29},{0,8,4,253},
    {0,14,5,16381},{0,20,5,1048573},
    {0,2,5,1},{16,7,4,125},
    {0,11,5,2045},{0,17,5,131069},
    {0,22,5,4194301},{0,4,5,13},
    {16,8,4,253},{0,13,5,8189},
    {0,19,5,524285},{0,1,5,1},
    {16,6,4,61},{0,10,5,1021},
    {0,16,5,65533},{0,28,5,268435453},
    {0,27,5,134217725},{0,26,5,67108861},
    {0,25,5,33554429},{0,24,5,16777213},
}

@(rodata,private="file") ML_default_dtable:=[(1<<ML_DEFAULT_NORM_LOG)+1]Seq_Symbol{
    {1,1,1,ML_DEFAULT_NORM_LOG},
    {0,0,6,3},{0,0,4,4},
    {32,0,5,5},{0,0,5,6},
    {0,0,5,8},{0,0,5,9},
    {0,0,5,11},{0,0,6,13},
    {0,0,6,16},{0,0,6,19},
    {0,0,6,22},{0,0,6,25},
    {0,0,6,28},{0,0,6,31},
    {0,0,6,34},{0,1,6,37},
    {0,1,6,41},{0,2,6,47},
    {0,3,6,59},{0,4,6,83},
    {0,7,6,131},{0,9,6,515},
    {16,0,4,4},{0,0,4,5},
    {32,0,5,6},{0,0,5,7},
    {32,0,5,9},{0,0,5,10},
    {0,0,6,12},{0,0,6,15},
    {0,0,6,18},{0,0,6,21},
    {0,0,6,24},{0,0,6,27},
    {0,0,6,30},{0,0,6,33},
    {0,1,6,35},{0,1,6,39},
    {0,2,6,43},{0,3,6,51},
    {0,4,6,67},{0,5,6,99},
    {0,8,6,259},{32,0,4,4},
    {48,0,4,4},{16,0,4,5},
    {32,0,5,7},{32,0,5,8},
    {32,0,5,10},{32,0,5,11},
    {0,0,6,14},{0,0,6,17},
    {0,0,6,20},{0,0,6,23},
    {0,0,6,26},{0,0,6,29},
    {0,0,6,32},{0,16,6,65539},
    {0,15,6,32771},{0,14,6,16387},
    {0,13,6,8195},{0,12,6,4099},
    {0,11,6,2051},{0,10,6,1027},
}

@(private="file")
block_size_max :: #force_inline proc "contextless" (dctx:^DCtx) -> int {return int(dctx.f_params.block_size_max)}

Block_Properties :: struct {
    block_type:Block_Type,
    last_block,orig_size:u32,
}

get_cblock_size :: proc "contextless" (src:[^]u8,src_size:int,bp:^Block_Properties) -> (size:int,err:Error) {
    if src_size<BLOCK_HEADER_SIZE {return 0,.Src_Size_Wrong}
    c_block_header:=read24(src)
    c_size:=c_block_header>>3
    bp.last_block=c_block_header&1
    bp.block_type=Block_Type((c_block_header>>1)&3)
    bp.orig_size=c_size
    if bp.block_type==.RLE {return 1,.None}
    if bp.block_type==.Reserved {return 0,.Corruption_Detected}
    return int(c_size),.None
}

@(private="file")
set_bytes :: #force_inline proc "contextless" (dst:[^]u8,value:u8,n:int) {
    for i in 0..<n {dst[i]=value}
}

set_rle_bytes :: proc "contextless" (dst:[^]u8,value:u8,n:int) {set_bytes(dst,value,n)}

// Literals go after the block when dst has room, in the extra buffer when they fit, or are split
// between the end of the block and the extra buffer.
@(private="file")
allocate_literals_buffer :: proc "contextless" (dctx:^DCtx,dst:[^]u8,dst_capacity,lit_size,expected_write_size:int,split_immediately:bool) {
    size_max:=block_size_max(dctx)
    if dst_capacity>size_max+WILDCOPY_OVERLENGTH+lit_size+WILDCOPY_OVERLENGTH {
        dctx.lit_buffer=padd(dst,size_max+WILDCOPY_OVERLENGTH)
        dctx.lit_buffer_end=padd(dctx.lit_buffer,lit_size)
        dctx.lit_buffer_location=.In_Dst
    } else if lit_size<=LIT_BUFFER_EXTRA_SIZE {
        dctx.lit_buffer=([^]u8)(&dctx.lit_extra_buffer[0])
        dctx.lit_buffer_end=padd(dctx.lit_buffer,lit_size)
        dctx.lit_buffer_location=.Not_In_Dst
    } else {
        if split_immediately {
            dctx.lit_buffer=padd(dst,expected_write_size-lit_size+LIT_BUFFER_EXTRA_SIZE-WILDCOPY_OVERLENGTH)
            dctx.lit_buffer_end=padd(dctx.lit_buffer,lit_size-LIT_BUFFER_EXTRA_SIZE)
        } else {
            dctx.lit_buffer=padd(dst,expected_write_size-lit_size)
            dctx.lit_buffer_end=padd(dst,expected_write_size)
        }
        dctx.lit_buffer_location=.Split
    }
}

// How many bytes of src the literals section takes.
@(private="file")
decode_literals_block :: proc "contextless" (dctx:^DCtx,src:[^]u8,src_size:int,dst:[^]u8,dst_capacity:int) -> (size:int,err:Error) {
    if src_size<MIN_CBLOCK_SIZE {return 0,.Corruption_Detected}

    istart:=src
    lit_enc_type:=Symbol_Encoding_Type(istart[0]&3)
    size_max:=block_size_max(dctx)

    switch lit_enc_type {
    case .Repeat:
        if dctx.lit_entropy==0 {return 0,.Corruption_Detected}
        fallthrough
    case .Compressed:
        if src_size<5 {return 0,.Corruption_Detected}
        lh_size,lit_size,lit_c_size:int
        single_stream:=false
        lhl_code:=(u32(istart[0])>>2)&3
        lhc:=read32(istart)
        huf_size:int
        huf_err:Error
        expected_write_size:=min(size_max,dst_capacity)
        switch lhl_code {
        case 2:
            lh_size=4
            lit_size=int((lhc>>4)&0x3FFF)
            lit_c_size=int(lhc>>18)
        case 3:
            lh_size=5
            lit_size=int((lhc>>4)&0x3FFFF)
            lit_c_size=int(lhc>>22)+int(istart[4])<<10
        case:
            single_stream=lhl_code==0
            lh_size=3
            lit_size=int((lhc>>4)&0x3FF)
            lit_c_size=int((lhc>>14)&0x3FF)
        }
        if lit_size>0 && dst==nil {return 0,.Dst_Size_Too_Small}
        if lit_size>size_max {return 0,.Corruption_Detected}
        if !single_stream {
            if lit_size<MIN_LITERALS_FOR_4_STREAMS {return 0,.Literals_Header_Wrong}
        }
        if lit_c_size+lh_size>src_size {return 0,.Corruption_Detected}
        if expected_write_size<lit_size {return 0,.Dst_Size_Too_Small}
        allocate_literals_buffer(dctx,dst,dst_capacity,lit_size,expected_write_size,false)

        if lit_enc_type==.Repeat {
            if single_stream {
                huf_size,huf_err=huf_decompress1x_using_dtable(dctx.lit_buffer,lit_size,padd(istart,lh_size),lit_c_size,dctx.huf_ptr)
            } else {
                huf_size,huf_err=huf_decompress4x_using_dtable(dctx.lit_buffer,lit_size,padd(istart,lh_size),lit_c_size,dctx.huf_ptr)
            }
        } else {
            if single_stream {
                huf_size,huf_err=huf_decompress1x1_dctx_wksp(&dctx.entropy.huf_table[0],dctx.lit_buffer,lit_size,padd(istart,lh_size),lit_c_size,&dctx.workspace[0],size_of(dctx.workspace))
            } else {
                huf_size,huf_err=huf_decompress4x_huf_only_wksp(&dctx.entropy.huf_table[0],dctx.lit_buffer,lit_size,padd(istart,lh_size),lit_c_size,&dctx.workspace[0],size_of(dctx.workspace))
            }
        }
        if dctx.lit_buffer_location==.Split {
            intrinsics.mem_copy_non_overlapping(&dctx.lit_extra_buffer[0],padd(dctx.lit_buffer_end,-LIT_BUFFER_EXTRA_SIZE),LIT_BUFFER_EXTRA_SIZE)
            intrinsics.mem_copy(padd(dctx.lit_buffer,LIT_BUFFER_EXTRA_SIZE-WILDCOPY_OVERLENGTH),dctx.lit_buffer,lit_size-LIT_BUFFER_EXTRA_SIZE)
            dctx.lit_buffer=padd(dctx.lit_buffer,LIT_BUFFER_EXTRA_SIZE-WILDCOPY_OVERLENGTH)
            dctx.lit_buffer_end=padd(dctx.lit_buffer_end,-WILDCOPY_OVERLENGTH)
        }
        _=huf_size

        if huf_err!=.None {return 0,.Corruption_Detected}

        dctx.lit_ptr=dctx.lit_buffer
        dctx.lit_size=lit_size
        dctx.lit_entropy=1
        if lit_enc_type==.Compressed {dctx.huf_ptr=([^]u32)(&dctx.entropy.huf_table[0])}
        return lit_c_size+lh_size,.None

    case .Basic:
        lit_size,lh_size:int
        lhl_code:=(u32(istart[0])>>2)&3
        expected_write_size:=min(size_max,dst_capacity)
        switch lhl_code {
        case 1:
            lh_size=2
            lit_size=int(read16(istart)>>4)
        case 3:
            lh_size=3
            if src_size<3 {return 0,.Corruption_Detected}
            lit_size=int(read24(istart)>>4)
        case:
            lh_size=1
            lit_size=int(istart[0]>>3)
        }

        if lit_size>0 && dst==nil {return 0,.Dst_Size_Too_Small}
        if lit_size>size_max {return 0,.Corruption_Detected}
        if expected_write_size<lit_size {return 0,.Dst_Size_Too_Small}
        allocate_literals_buffer(dctx,dst,dst_capacity,lit_size,expected_write_size,true)
        if lh_size+lit_size+WILDCOPY_OVERLENGTH>src_size {
            if lit_size+lh_size>src_size {return 0,.Corruption_Detected}
            if dctx.lit_buffer_location==.Split {
                intrinsics.mem_copy_non_overlapping(dctx.lit_buffer,padd(istart,lh_size),lit_size-LIT_BUFFER_EXTRA_SIZE)
                intrinsics.mem_copy_non_overlapping(&dctx.lit_extra_buffer[0],padd(istart,lh_size+lit_size-LIT_BUFFER_EXTRA_SIZE),LIT_BUFFER_EXTRA_SIZE)
            } else {
                copy_bytes(dctx.lit_buffer,padd(istart,lh_size),lit_size)
            }
            dctx.lit_ptr=dctx.lit_buffer
            dctx.lit_size=lit_size
            return lh_size+lit_size,.None
        }
        dctx.lit_ptr=padd(istart,lh_size)
        dctx.lit_size=lit_size
        dctx.lit_buffer_end=padd(dctx.lit_ptr,lit_size)
        dctx.lit_buffer_location=.Not_In_Dst
        return lh_size+lit_size,.None

    case .RLE:
        lit_size,lh_size:int
        lhl_code:=(u32(istart[0])>>2)&3
        expected_write_size:=min(size_max,dst_capacity)
        switch lhl_code {
        case 1:
            lh_size=2
            if src_size<3 {return 0,.Corruption_Detected}
            lit_size=int(read16(istart)>>4)
        case 3:
            lh_size=3
            if src_size<4 {return 0,.Corruption_Detected}
            lit_size=int(read24(istart)>>4)
        case:
            lh_size=1
            lit_size=int(istart[0]>>3)
        }
        if lit_size>0 && dst==nil {return 0,.Dst_Size_Too_Small}
        if lit_size>size_max {return 0,.Corruption_Detected}
        if expected_write_size<lit_size {return 0,.Dst_Size_Too_Small}
        allocate_literals_buffer(dctx,dst,dst_capacity,lit_size,expected_write_size,true)
        if dctx.lit_buffer_location==.Split {
            set_bytes(dctx.lit_buffer,istart[lh_size],lit_size-LIT_BUFFER_EXTRA_SIZE)
            set_bytes(([^]u8)(&dctx.lit_extra_buffer[0]),istart[lh_size],LIT_BUFFER_EXTRA_SIZE)
        } else {
            set_bytes(dctx.lit_buffer,istart[lh_size],lit_size)
        }
        dctx.lit_ptr=dctx.lit_buffer
        dctx.lit_size=lit_size
        return lh_size+1,.None
    }
    return 0,.Corruption_Detected
}

@(private="file")
build_seq_table_rle :: proc "contextless" (dt:[^]Seq_Symbol,base_value:u32,nb_add_bits:u8) {
    d_table_h:=(^Seq_Symbol_Header)(dt)
    cell:=&dt[1]
    d_table_h.table_log=0
    d_table_h.fast_mode=0
    cell.nb_bits=0
    cell.next_state=0
    cell.nb_additional_bits=nb_add_bits
    cell.base_value=base_value
}

@(private="file")
build_fse_table :: proc "contextless" (dt:[^]Seq_Symbol,normalized_counter:[^]i16,max_symbol_value:u32,base_value:[^]u32,nb_additional_bits:[^]u8,table_log:u32,wksp:[^]u32) #no_bounds_check {
    table_decode:=dt[1:]
    max_sv1:=max_symbol_value+1
    table_size:=u32(1)<<table_log

    symbol_next:=([^]u16)(wksp)
    spread:=([^]u8)(&symbol_next[MAX_SEQ+1])
    high_threshold:=table_size-1

    {
        d_table_h:=(^Seq_Symbol_Header)(dt)
        fast_mode:=u32(1)
        large_limit:=i16(1)<<(table_log-1)
        for s in 0..<max_sv1 {
            if normalized_counter[s]==-1 {
                table_decode[high_threshold].base_value=s
                high_threshold-=1
                symbol_next[s]=1
            } else {
                if normalized_counter[s]>=large_limit {fast_mode=0}
                symbol_next[s]=u16(normalized_counter[s])
            }
        }
        d_table_h.table_log=table_log
        d_table_h.fast_mode=fast_mode
    }

    if high_threshold==table_size-1 {
        table_mask:=int(table_size-1)
        step:=int(fse_table_step(table_size))
        {
            add:=u64(0x0101010101010101)
            pos:=0
            sv:=u64(0)
            for s in 0..<max_sv1 {
                n:=int(normalized_counter[s])
                write64(padd(spread,pos),sv)
                for i:=8;i<n;i+=8 {
                    write64(padd(spread,pos+i),sv)
                }
                pos+=n
                sv+=add
            }
        }
        {
            position:=0
            for s:=0;s<int(table_size);s+=2 {
                for u in 0..<2 {
                    u_position:=(position+u*step)&table_mask
                    table_decode[u_position].base_value=u32(spread[s+u])
                }
                position=(position+2*step)&table_mask
            }
        }
    } else {
        table_mask:=table_size-1
        step:=fse_table_step(table_size)
        position:=u32(0)
        for s in 0..<max_sv1 {
            n:=int(normalized_counter[s])
            for i:=0;i<n;i+=1 {
                table_decode[position].base_value=s
                position=(position+step)&table_mask
                for position>high_threshold {position=(position+step)&table_mask}
            }
        }
    }

    for u in 0..<table_size {
        symbol:=table_decode[u].base_value
        next_state:=u32(symbol_next[symbol])
        symbol_next[symbol]+=1
        table_decode[u].nb_bits=u8(table_log-highbit32(next_state))
        table_decode[u].next_state=u16((next_state<<table_decode[u].nb_bits)-table_size)
        table_decode[u].nb_additional_bits=nb_additional_bits[symbol]
        table_decode[u].base_value=base_value[symbol]
    }
}

@(private="file")
build_seq_table :: proc "contextless" (dtable_space:[^]Seq_Symbol,dtable_ptr:^[^]Seq_Symbol,encoding:Symbol_Encoding_Type,max_value_in,max_log:u32,src:[^]u8,src_size:int,base_value:[^]u32,nb_additional_bits:[^]u8,default_table:[^]Seq_Symbol,flag_repeat_table:u32,wksp:[^]u32) -> (size:int,err:Error) #no_bounds_check {
    max_value:=max_value_in
    switch encoding {
    case .RLE:
        if src_size==0 {return 0,.Src_Size_Wrong}
        if u32(src[0])>max_value {return 0,.Corruption_Detected}
        {
            symbol:=src[0]
            baseline:=base_value[symbol]
            nb_bits:=nb_additional_bits[symbol]
            build_seq_table_rle(dtable_space,baseline,nb_bits)
        }
        dtable_ptr^=dtable_space
        return 1,.None
    case .Basic:
        dtable_ptr^=default_table
        return 0,.None
    case .Repeat:
        if flag_repeat_table==0 {return 0,.Corruption_Detected}
        return 0,.None
    case .Compressed:
        table_log:u32
        norm:[MAX_SEQ+1]i16=---
        header_size,e:=fse_read_ncount(&norm[0],&max_value,&table_log,src,src_size)
        if e!=.None {return 0,.Corruption_Detected}
        if table_log>max_log {return 0,.Corruption_Detected}
        build_fse_table(dtable_space,&norm[0],max_value,base_value,nb_additional_bits,table_log,wksp)
        dtable_ptr^=dtable_space
        return header_size,.None
    }
    return 0,.Generic
}

decode_seq_headers :: proc "contextless" (dctx:^DCtx,nb_seq_ptr:^int,src:[^]u8,src_size:int) -> (size:int,err:Error) {
    istart:=src
    iend:=padd(istart,src_size)
    ip:=istart

    if src_size<MIN_SEQUENCES_SIZE {return 0,.Src_Size_Wrong}

    nb_seq:=int(ip[0])
    ip=padd(ip,1)
    if nb_seq>0x7F {
        if nb_seq==0xFF {
            if uintptr(padd(ip,2))>uintptr(iend) {return 0,.Src_Size_Wrong}
            nb_seq=int(read16(ip))+LONG_NB_SEQ
            ip=padd(ip,2)
        } else {
            if uintptr(ip)>=uintptr(iend) {return 0,.Src_Size_Wrong}
            nb_seq=((nb_seq-0x80)<<8)+int(ip[0])
            ip=padd(ip,1)
        }
    }
    nb_seq_ptr^=nb_seq

    if nb_seq==0 {
        if ip!=iend {return 0,.Corruption_Detected}
        return pdiff(ip,istart),.None
    }

    if uintptr(padd(ip,1))>uintptr(iend) {return 0,.Src_Size_Wrong}
    if ip[0]&3!=0 {return 0,.Corruption_Detected}
    {
        ll_type:=Symbol_Encoding_Type(ip[0]>>6)
        of_type:=Symbol_Encoding_Type((ip[0]>>4)&3)
        ml_type:=Symbol_Encoding_Type((ip[0]>>2)&3)
        ip=padd(ip,1)

        {
            ll_h_size,e:=build_seq_table(&dctx.entropy.ll_table[0],&dctx.ll_tptr,ll_type,MAX_LL,LL_FSE_LOG,ip,pdiff(iend,ip),&LL_base[0],&LL_bits[0],&LL_default_dtable[0],dctx.fse_entropy,&dctx.workspace[0])
            if e!=.None {return 0,.Corruption_Detected}
            ip=padd(ip,ll_h_size)
        }
        {
            of_h_size,e:=build_seq_table(&dctx.entropy.of_table[0],&dctx.of_tptr,of_type,MAX_OFF,OFF_FSE_LOG,ip,pdiff(iend,ip),&OF_base[0],&OF_bits[0],&OF_default_dtable[0],dctx.fse_entropy,&dctx.workspace[0])
            if e!=.None {return 0,.Corruption_Detected}
            ip=padd(ip,of_h_size)
        }
        {
            ml_h_size,e:=build_seq_table(&dctx.entropy.ml_table[0],&dctx.ml_tptr,ml_type,MAX_ML,ML_FSE_LOG,ip,pdiff(iend,ip),&ML_base[0],&ML_bits[0],&ML_default_dtable[0],dctx.fse_entropy,&dctx.workspace[0])
            if e!=.None {return 0,.Corruption_Detected}
            ip=padd(ip,ml_h_size)
        }
    }

    return pdiff(ip,istart),.None
}

@(private="file")
Seq :: struct {
    lit_length,match_length:int,
    offset:uint,
}

@(private="file")
Fse_State :: struct {
    state:uint,
    table:[^]Seq_Symbol,
}

@(private="file")
Seq_State :: struct {
    d_stream:Bit_DStream,
    state_ll,state_offb,state_ml:Fse_State,
    prev_offset:[REP_NUM]uint,
}

@(rodata,private="file") Dec32_Table:=[8]u32{0,1,2,1,4,4,4,4}
@(rodata,private="file") Dec64_Table:=[8]int{8,8,8,7,8,9,10,11}

// Copies 8 bytes; afterwards the two positions are at least 8 bytes apart.
@(private="file")
overlap_copy8 :: #force_inline proc "contextless" (op,ip:^[^]u8,offset:uint) #no_bounds_check {
    if offset<8 {
        sub2:=Dec64_Table[offset]
        op^[0]=ip^[0]
        op^[1]=ip^[1]
        op^[2]=ip^[2]
        op^[3]=ip^[3]
        ip^=padd(ip^,int(Dec32_Table[offset]))
        write32(padd(op^,4),read32(ip^))
        ip^=padd(ip^,-sub2)
    } else {
        copy8(op^,ip^)
    }
    ip^=padd(ip^,8)
    op^=padd(op^,8)
}

// May read up to WILDCOPY_OVERLENGTH past the input and write up to 16 bytes past oend_w.
@(private="file")
safecopy :: proc "contextless" (op_in,oend_w,ip_in:[^]u8,length_in:int,ovtype:Overlap) #no_bounds_check {
    op,ip:=op_in,ip_in
    length:=length_in
    diff:=pdiff(op,ip)
    oend:=padd(op,length)

    if length<8 {
        for uintptr(op)<uintptr(oend) {
            op[0]=ip[0]
            op=padd(op,1);ip=padd(ip,1)
        }
        return
    }
    if ovtype==.Src_Before_Dst {
        overlap_copy8(&op,&ip,uint(diff))
        length-=8
    }

    if uintptr(oend)<=uintptr(oend_w) {
        wildcopy(op,ip,length,ovtype)
        return
    }
    if uintptr(op)<=uintptr(oend_w) {
        wildcopy(op,ip,pdiff(oend_w,op),ovtype)
        ip=padd(ip,pdiff(oend_w,op))
        op=padd(op,pdiff(oend_w,op))
    }
    for uintptr(op)<uintptr(oend) {
        op[0]=ip[0]
        op=padd(op,1);ip=padd(ip,1)
    }
}

// The destination may be before the source and overlap it.
@(private="file")
safecopy_dst_before_src :: proc "contextless" (op_in,ip_in:[^]u8,length:int) {
    op,ip:=op_in,ip_in
    diff:=pdiff(op,ip)
    oend:=padd(op,length)

    if length<8 || diff>-8 {
        for uintptr(op)<uintptr(oend) {
            op[0]=ip[0]
            op=padd(op,1);ip=padd(ip,1)
        }
        return
    }

    if uintptr(op)<=uintptr(padd(oend,-WILDCOPY_OVERLENGTH)) && diff<-WILDCOPY_VECLEN {
        wildcopy(op,ip,pdiff(padd(oend,-WILDCOPY_OVERLENGTH),op),.No_Overlap)
        ip=padd(ip,pdiff(padd(oend,-WILDCOPY_OVERLENGTH),op))
        op=padd(op,pdiff(padd(oend,-WILDCOPY_OVERLENGTH),op))
    }

    for uintptr(op)<uintptr(oend) {
        op[0]=ip[0]
        op=padd(op,1);ip=padd(ip,1)
    }
}

@(private="file")
exec_sequence_end :: proc "contextless" (op_in,oend:[^]u8,sequence:Seq,lit_ptr,lit_limit,prefix_start:[^]u8) -> (size:int,err:Error) {
    op:=op_in
    o_lit_end:=padd(op,sequence.lit_length)
    sequence_length:=sequence.lit_length+sequence.match_length
    match:=padd(o_lit_end,-int(sequence.offset))
    oend_w:=padd(oend,-WILDCOPY_OVERLENGTH)

    if uint(sequence_length)>uint(pdiff(oend,op)) {return 0,.Dst_Size_Too_Small}
    if uint(sequence.lit_length)>uint(pdiff(lit_limit,lit_ptr)) {return 0,.Corruption_Detected}

    safecopy(op,oend_w,lit_ptr,sequence.lit_length,.No_Overlap)
    op=o_lit_end

    if sequence.offset>uint(pdiff(o_lit_end,prefix_start)) {return 0,.Corruption_Detected}
    safecopy(op,oend_w,match,sequence.match_length,.Src_Before_Dst)
    return sequence_length,.None
}

@(private="file")
exec_sequence_end_split_lit_buffer :: proc "contextless" (op_in,oend,oend_w:[^]u8,sequence:Seq,lit_ptr,lit_limit,prefix_start:[^]u8) -> (size:int,err:Error) {
    op:=op_in
    o_lit_end:=padd(op,sequence.lit_length)
    sequence_length:=sequence.lit_length+sequence.match_length
    match:=padd(o_lit_end,-int(sequence.offset))

    if uint(sequence_length)>uint(pdiff(oend,op)) {return 0,.Dst_Size_Too_Small}
    if uint(sequence.lit_length)>uint(pdiff(lit_limit,lit_ptr)) {return 0,.Corruption_Detected}

    if uintptr(op)>uintptr(lit_ptr) && uintptr(op)<uintptr(padd(lit_ptr,sequence.lit_length)) {return 0,.Dst_Size_Too_Small}
    safecopy_dst_before_src(op,lit_ptr,sequence.lit_length)
    op=o_lit_end

    if sequence.offset>uint(pdiff(o_lit_end,prefix_start)) {return 0,.Corruption_Detected}
    safecopy(op,oend_w,match,sequence.match_length,.Src_Before_Dst)
    return sequence_length,.None
}

@(private="file")
exec_sequence :: #force_inline proc "contextless" (op_in,oend:[^]u8,sequence:Seq,lit_ptr:^[^]u8,lit_limit,prefix_start:[^]u8) -> (size:int,err:Error) #no_bounds_check {
    op:=op_in
    o_lit_end:=padd(op,sequence.lit_length)
    sequence_length:=sequence.lit_length+sequence.match_length
    o_match_end:=padd(op,sequence_length)
    oend_w:=padd(oend,-WILDCOPY_OVERLENGTH)
    i_lit_end:=padd(lit_ptr^,sequence.lit_length)
    match:=padd(o_lit_end,-int(sequence.offset))

    when ODIN_ARCH==.arm64 {intrinsics.prefetch_read_data(match,3)}

    if uintptr(i_lit_end)>uintptr(lit_limit) || uintptr(o_match_end)>uintptr(oend_w) {
        size,err=exec_sequence_end(op,oend,sequence,lit_ptr^,lit_limit,prefix_start)
        if err==.None {lit_ptr^=i_lit_end}
        return size,err
    }

    copy16(op,lit_ptr^)
    if sequence.lit_length>16 {
        wildcopy(padd(op,16),padd(lit_ptr^,16),sequence.lit_length-16,.No_Overlap)
    }
    op=o_lit_end
    lit_ptr^=i_lit_end

    if sequence.offset>uint(pdiff(o_lit_end,prefix_start)) {return 0,.Corruption_Detected}

    if sequence.offset>=WILDCOPY_VECLEN {
        wildcopy(op,match,sequence.match_length,.No_Overlap)
        return sequence_length,.None
    }

    overlap_copy8(&op,&match,sequence.offset)

    if sequence.match_length>8 {
        wildcopy(op,match,sequence.match_length-8,.Src_Before_Dst)
    }
    return sequence_length,.None
}

@(private="file")
exec_sequence_split_lit_buffer :: #force_inline proc "contextless" (op_in,oend,oend_w:[^]u8,sequence:Seq,lit_ptr:^[^]u8,lit_limit,prefix_start:[^]u8) -> (size:int,err:Error) #no_bounds_check {
    op:=op_in
    o_lit_end:=padd(op,sequence.lit_length)
    sequence_length:=sequence.lit_length+sequence.match_length
    o_match_end:=padd(op,sequence_length)
    i_lit_end:=padd(lit_ptr^,sequence.lit_length)
    match:=padd(o_lit_end,-int(sequence.offset))

    if uintptr(i_lit_end)>uintptr(lit_limit) || uintptr(o_match_end)>uintptr(oend_w) {
        size,err=exec_sequence_end_split_lit_buffer(op,oend,oend_w,sequence,lit_ptr^,lit_limit,prefix_start)
        if err==.None {lit_ptr^=i_lit_end}
        return size,err
    }

    copy16(op,lit_ptr^)
    if sequence.lit_length>16 {
        wildcopy(padd(op,16),padd(lit_ptr^,16),sequence.lit_length-16,.No_Overlap)
    }
    op=o_lit_end
    lit_ptr^=i_lit_end

    if sequence.offset>uint(pdiff(o_lit_end,prefix_start)) {return 0,.Corruption_Detected}

    if sequence.offset>=WILDCOPY_VECLEN {
        wildcopy(op,match,sequence.match_length,.No_Overlap)
        return sequence_length,.None
    }

    overlap_copy8(&op,&match,sequence.offset)

    if sequence.match_length>8 {
        wildcopy(op,match,sequence.match_length-8,.Src_Before_Dst)
    }
    return sequence_length,.None
}

@(private="file")
init_fse_state :: #force_inline proc "contextless" (d_state:^Fse_State,bit_d:^Bit_DStream,dt:[^]Seq_Symbol) {
    table_log:=(^Seq_Symbol_Header)(dt).table_log
    d_state.state=uint(bit_read_bits(bit_d,table_log))
    bit_reload_dstream(bit_d)
    d_state.table=dt[1:]
}

@(private="file")
update_fse_state_with_d_info :: #force_inline proc "contextless" (d_state:^Fse_State,bit_d:^Bit_DStream,next_state:u16,nb_bits:u32) {
    low_bits:=bit_read_bits(bit_d,nb_bits)
    d_state.state=uint(next_state)+uint(low_bits)
}

@(private="file")
decode_sequence :: #force_inline proc "contextless" (seq_state:^Seq_State,is_last_seq:bool) -> (seq:Seq) #no_bounds_check {
    ll_d_info:=&seq_state.state_ll.table[seq_state.state_ll.state]
    ml_d_info:=&seq_state.state_ml.table[seq_state.state_ml.state]
    of_d_info:=&seq_state.state_offb.table[seq_state.state_offb.state]
    seq.match_length=int(ml_d_info.base_value)
    seq.lit_length=int(ll_d_info.base_value)
    of_base:=of_d_info.base_value
    ll_bits:=ll_d_info.nb_additional_bits
    ml_bits:=ml_d_info.nb_additional_bits
    of_bits:=of_d_info.nb_additional_bits
    total_bits:=ll_bits+ml_bits+of_bits

    ll_next:=ll_d_info.next_state
    ml_next:=ml_d_info.next_state
    of_next:=of_d_info.next_state
    ll_nb_bits:=u32(ll_d_info.nb_bits)
    ml_nb_bits:=u32(ml_d_info.nb_bits)
    of_nb_bits:=u32(of_d_info.nb_bits)

    {
        offset:uint
        if of_bits>1 {
            offset=uint(of_base)+uint(bit_read_bits_fast(&seq_state.d_stream,u32(of_bits)))
            seq_state.prev_offset[2]=seq_state.prev_offset[1]
            seq_state.prev_offset[1]=seq_state.prev_offset[0]
            seq_state.prev_offset[0]=offset
        } else {
            ll0:=uint(ll_d_info.base_value==0 ? 1 : 0)
            if of_bits==0 {
                offset=seq_state.prev_offset[ll0]
                seq_state.prev_offset[1]=seq_state.prev_offset[1-ll0]
                seq_state.prev_offset[0]=offset
            } else {
                offset=uint(of_base)+ll0+uint(bit_read_bits_fast(&seq_state.d_stream,1))
                temp:=offset==3 ? seq_state.prev_offset[0]-1 : seq_state.prev_offset[offset]
                temp-=temp==0 ? 1 : 0
                if offset!=1 {seq_state.prev_offset[2]=seq_state.prev_offset[1]}
                seq_state.prev_offset[1]=seq_state.prev_offset[0]
                offset=temp
                seq_state.prev_offset[0]=offset
            }
        }
        seq.offset=offset
    }

    if ml_bits>0 {
        seq.match_length+=int(bit_read_bits_fast(&seq_state.d_stream,u32(ml_bits)))
    }

    if total_bits>=57-(LL_FSE_LOG+ML_FSE_LOG+OFF_FSE_LOG) {
        bit_reload_dstream(&seq_state.d_stream)
    }

    if ll_bits>0 {
        seq.lit_length+=int(bit_read_bits_fast(&seq_state.d_stream,u32(ll_bits)))
    }

    if !is_last_seq {
        update_fse_state_with_d_info(&seq_state.state_ll,&seq_state.d_stream,ll_next,ll_nb_bits)
        update_fse_state_with_d_info(&seq_state.state_ml,&seq_state.d_stream,ml_next,ml_nb_bits)
        update_fse_state_with_d_info(&seq_state.state_offb,&seq_state.d_stream,of_next,of_nb_bits)
        bit_reload_dstream(&seq_state.d_stream)
    }

    return seq
}

@(private="file")
init_seq_state :: #force_inline proc "contextless" (dctx:^DCtx,seq_state:^Seq_State,ip:[^]u8,seq_size:int) -> Error {
    dctx.fse_entropy=1
    for i in 0..<REP_NUM {seq_state.prev_offset[i]=uint(dctx.entropy.rep[i])}
    if bit_init_dstream(&seq_state.d_stream,ip,seq_size)!=.None {return .Corruption_Detected}
    init_fse_state(&seq_state.state_ll,&seq_state.d_stream,dctx.ll_tptr)
    init_fse_state(&seq_state.state_offb,&seq_state.d_stream,dctx.of_tptr)
    init_fse_state(&seq_state.state_ml,&seq_state.d_stream,dctx.ml_tptr)
    return .None
}

@(private="file")
decompress_sequences_split_lit_buffer :: proc "contextless" (dctx:^DCtx,dst:[^]u8,max_dst_size:int,seq_start:[^]u8,seq_size,nb_seq_in:int) -> (size:int,err:Error) #no_bounds_check {
    nb_seq:=nb_seq_in
    ip:=seq_start
    ostart:=dst
    oend:=max_dst_size>0 ? padd(ostart,max_dst_size) : ostart
    op:=ostart
    lit_ptr:=dctx.lit_ptr
    lit_buffer_end:=dctx.lit_buffer_end
    prefix_start:=dctx.prefix_start

    if nb_seq!=0 {
        seq_state:Seq_State
        if e:=init_seq_state(dctx,&seq_state,ip,seq_size);e!=.None {return 0,e}

        {
            sequence:Seq
            for nb_seq!=0 {
                sequence=decode_sequence(&seq_state,nb_seq==1)
                if uintptr(padd(lit_ptr,sequence.lit_length))>uintptr(dctx.lit_buffer_end) {break}
                one_seq_size,e:=exec_sequence_split_lit_buffer(op,oend,padd(lit_ptr,sequence.lit_length-WILDCOPY_OVERLENGTH),sequence,&lit_ptr,lit_buffer_end,prefix_start)
                if e!=.None {return 0,e}
                op=padd(op,one_seq_size)
                nb_seq-=1
            }

            if nb_seq>0 {
                leftover_lit:=pdiff(dctx.lit_buffer_end,lit_ptr)
                if leftover_lit!=0 {
                    if uint(leftover_lit)>uint(pdiff(oend,op)) {return 0,.Dst_Size_Too_Small}
                    safecopy_dst_before_src(op,lit_ptr,leftover_lit)
                    sequence.lit_length-=leftover_lit
                    op=padd(op,leftover_lit)
                }
                lit_ptr=([^]u8)(&dctx.lit_extra_buffer[0])
                lit_buffer_end=padd(lit_ptr,LIT_BUFFER_EXTRA_SIZE)
                dctx.lit_buffer_location=.Not_In_Dst
                one_seq_size,e:=exec_sequence(op,oend,sequence,&lit_ptr,lit_buffer_end,prefix_start)
                if e!=.None {return 0,e}
                op=padd(op,one_seq_size)
                nb_seq-=1
            }
        }

        if nb_seq>0 {
            for ;nb_seq!=0;nb_seq-=1 {
                sequence:=decode_sequence(&seq_state,nb_seq==1)
                one_seq_size,e:=exec_sequence(op,oend,sequence,&lit_ptr,lit_buffer_end,prefix_start)
                if e!=.None {return 0,e}
                op=padd(op,one_seq_size)
            }
        }

        if nb_seq!=0 {return 0,.Corruption_Detected}
        if !bit_end_of_dstream(&seq_state.d_stream) {return 0,.Corruption_Detected}
        for i in 0..<REP_NUM {dctx.entropy.rep[i]=u32(seq_state.prev_offset[i])}
    }

    if dctx.lit_buffer_location==.Split {
        last_ll_size:=pdiff(lit_buffer_end,lit_ptr)
        if uint(last_ll_size)>uint(pdiff(oend,op)) {return 0,.Dst_Size_Too_Small}
        if op!=nil {
            intrinsics.mem_copy(op,lit_ptr,last_ll_size)
            op=padd(op,last_ll_size)
        }
        lit_ptr=([^]u8)(&dctx.lit_extra_buffer[0])
        lit_buffer_end=padd(lit_ptr,LIT_BUFFER_EXTRA_SIZE)
        dctx.lit_buffer_location=.Not_In_Dst
    }
    {
        last_ll_size:=pdiff(lit_buffer_end,lit_ptr)
        if uint(last_ll_size)>uint(pdiff(oend,op)) {return 0,.Dst_Size_Too_Small}
        if op!=nil {
            copy_bytes(op,lit_ptr,last_ll_size)
            op=padd(op,last_ll_size)
        }
    }

    return pdiff(op,ostart),.None
}

@(private="file")
decompress_sequences :: proc "contextless" (dctx:^DCtx,dst:[^]u8,max_dst_size:int,seq_start:[^]u8,seq_size,nb_seq_in:int) -> (size:int,err:Error) #no_bounds_check {
    nb_seq:=nb_seq_in
    ip:=seq_start
    ostart:=dst
    oend:=dctx.lit_buffer_location==.Not_In_Dst ? (max_dst_size>0 ? padd(ostart,max_dst_size) : ostart) : dctx.lit_buffer
    op:=ostart
    lit_ptr:=dctx.lit_ptr
    lit_end:=padd(lit_ptr,dctx.lit_size)
    prefix_start:=dctx.prefix_start

    if nb_seq!=0 {
        seq_state:Seq_State
        if e:=init_seq_state(dctx,&seq_state,ip,seq_size);e!=.None {return 0,e}

        for ;nb_seq!=0;nb_seq-=1 {
            sequence:=decode_sequence(&seq_state,nb_seq==1)
            one_seq_size,e:=exec_sequence(op,oend,sequence,&lit_ptr,lit_end,prefix_start)
            if e!=.None {return 0,e}
            op=padd(op,one_seq_size)
        }

        if !bit_end_of_dstream(&seq_state.d_stream) {return 0,.Corruption_Detected}
        for i in 0..<REP_NUM {dctx.entropy.rep[i]=u32(seq_state.prev_offset[i])}
    }

    {
        last_ll_size:=pdiff(lit_end,lit_ptr)
        if uint(last_ll_size)>uint(pdiff(oend,op)) {return 0,.Dst_Size_Too_Small}
        if op!=nil {
            copy_bytes(op,lit_ptr,last_ll_size)
            op=padd(op,last_ll_size)
        }
    }

    return pdiff(op,ostart),.None
}

@(private="file")
prefetch_match :: #force_inline proc "contextless" (prefetch_pos_in:uint,sequence:Seq,prefix_start:[^]u8) -> uint {
    prefetch_pos:=prefetch_pos_in+uint(sequence.lit_length)
    match_base:=sequence.offset>prefetch_pos ? nil : prefix_start
    match:=rawptr(uintptr(match_base)+uintptr(prefetch_pos)-uintptr(sequence.offset))
    intrinsics.prefetch_read_data(match,3)
    intrinsics.prefetch_read_data(rawptr(uintptr(match)+64),3)
    return prefetch_pos+uint(sequence.match_length)
}

STORED_SEQS :: 8
STORED_SEQS_MASK :: STORED_SEQS-1
ADVANCED_SEQS :: STORED_SEQS

@(private="file")
decompress_sequences_long :: proc "contextless" (dctx:^DCtx,dst:[^]u8,max_dst_size:int,seq_start:[^]u8,seq_size,nb_seq:int) -> (size:int,err:Error) #no_bounds_check {
    ip:=seq_start
    ostart:=dst
    oend:=dctx.lit_buffer_location==.In_Dst ? dctx.lit_buffer : (max_dst_size>0 ? padd(ostart,max_dst_size) : ostart)
    op:=ostart
    lit_ptr:=dctx.lit_ptr
    lit_buffer_end:=dctx.lit_buffer_end
    prefix_start:=dctx.prefix_start

    if nb_seq!=0 {
        sequences:[STORED_SEQS]Seq=---
        seq_advance:=min(nb_seq,ADVANCED_SEQS)
        seq_state:Seq_State
        seq_nb:int
        prefetch_pos:=uint(pdiff(op,prefix_start))

        if e:=init_seq_state(dctx,&seq_state,ip,seq_size);e!=.None {return 0,e}

        for seq_nb=0;seq_nb<seq_advance;seq_nb+=1 {
            sequence:=decode_sequence(&seq_state,seq_nb==nb_seq-1)
            prefetch_pos=prefetch_match(prefetch_pos,sequence,prefix_start)
            sequences[seq_nb]=sequence
        }

        for ;seq_nb<nb_seq;seq_nb+=1 {
            sequence:=decode_sequence(&seq_state,seq_nb==nb_seq-1)
            pending:=&sequences[(seq_nb-ADVANCED_SEQS)&STORED_SEQS_MASK]

            if dctx.lit_buffer_location==.Split && uintptr(padd(lit_ptr,pending.lit_length))>uintptr(dctx.lit_buffer_end) {
                leftover_lit:=pdiff(dctx.lit_buffer_end,lit_ptr)
                if leftover_lit!=0 {
                    if uint(leftover_lit)>uint(pdiff(oend,op)) {return 0,.Dst_Size_Too_Small}
                    safecopy_dst_before_src(op,lit_ptr,leftover_lit)
                    pending.lit_length-=leftover_lit
                    op=padd(op,leftover_lit)
                }
                lit_ptr=([^]u8)(&dctx.lit_extra_buffer[0])
                lit_buffer_end=padd(lit_ptr,LIT_BUFFER_EXTRA_SIZE)
                dctx.lit_buffer_location=.Not_In_Dst
                {
                    one_seq_size,e:=exec_sequence(op,oend,pending^,&lit_ptr,lit_buffer_end,prefix_start)
                    if e!=.None {return 0,e}

                    prefetch_pos=prefetch_match(prefetch_pos,sequence,prefix_start)
                    sequences[seq_nb&STORED_SEQS_MASK]=sequence
                    op=padd(op,one_seq_size)
                }
            } else {
                one_seq_size:int
                e:Error
                if dctx.lit_buffer_location==.Split {
                    one_seq_size,e=exec_sequence_split_lit_buffer(op,oend,padd(lit_ptr,pending.lit_length-WILDCOPY_OVERLENGTH),pending^,&lit_ptr,lit_buffer_end,prefix_start)
                } else {
                    one_seq_size,e=exec_sequence(op,oend,pending^,&lit_ptr,lit_buffer_end,prefix_start)
                }
                if e!=.None {return 0,e}

                prefetch_pos=prefetch_match(prefetch_pos,sequence,prefix_start)
                sequences[seq_nb&STORED_SEQS_MASK]=sequence
                op=padd(op,one_seq_size)
            }
        }
        if !bit_end_of_dstream(&seq_state.d_stream) {return 0,.Corruption_Detected}

        seq_nb-=seq_advance
        for ;seq_nb<nb_seq;seq_nb+=1 {
            sequence:=&sequences[seq_nb&STORED_SEQS_MASK]
            if dctx.lit_buffer_location==.Split && uintptr(padd(lit_ptr,sequence.lit_length))>uintptr(dctx.lit_buffer_end) {
                leftover_lit:=pdiff(dctx.lit_buffer_end,lit_ptr)
                if leftover_lit!=0 {
                    if uint(leftover_lit)>uint(pdiff(oend,op)) {return 0,.Dst_Size_Too_Small}
                    safecopy_dst_before_src(op,lit_ptr,leftover_lit)
                    sequence.lit_length-=leftover_lit
                    op=padd(op,leftover_lit)
                }
                lit_ptr=([^]u8)(&dctx.lit_extra_buffer[0])
                lit_buffer_end=padd(lit_ptr,LIT_BUFFER_EXTRA_SIZE)
                dctx.lit_buffer_location=.Not_In_Dst
                {
                    one_seq_size,e:=exec_sequence(op,oend,sequence^,&lit_ptr,lit_buffer_end,prefix_start)
                    if e!=.None {return 0,e}
                    op=padd(op,one_seq_size)
                }
            } else {
                one_seq_size:int
                e:Error
                if dctx.lit_buffer_location==.Split {
                    one_seq_size,e=exec_sequence_split_lit_buffer(op,oend,padd(lit_ptr,sequence.lit_length-WILDCOPY_OVERLENGTH),sequence^,&lit_ptr,lit_buffer_end,prefix_start)
                } else {
                    one_seq_size,e=exec_sequence(op,oend,sequence^,&lit_ptr,lit_buffer_end,prefix_start)
                }
                if e!=.None {return 0,e}
                op=padd(op,one_seq_size)
            }
        }

        for i in 0..<REP_NUM {dctx.entropy.rep[i]=u32(seq_state.prev_offset[i])}
    }

    if dctx.lit_buffer_location==.Split {
        last_ll_size:=pdiff(lit_buffer_end,lit_ptr)
        if uint(last_ll_size)>uint(pdiff(oend,op)) {return 0,.Dst_Size_Too_Small}
        if op!=nil {
            intrinsics.mem_copy(op,lit_ptr,last_ll_size)
            op=padd(op,last_ll_size)
        }
        lit_ptr=([^]u8)(&dctx.lit_extra_buffer[0])
        lit_buffer_end=padd(lit_ptr,LIT_BUFFER_EXTRA_SIZE)
    }
    {
        last_ll_size:=pdiff(lit_buffer_end,lit_ptr)
        if uint(last_ll_size)>uint(pdiff(oend,op)) {return 0,.Dst_Size_Too_Small}
        if op!=nil {
            intrinsics.mem_copy(op,lit_ptr,last_ll_size)
            op=padd(op,last_ll_size)
        }
    }

    return pdiff(op,ostart),.None
}

@(private="file")
Offset_Info :: struct {long_offset_share,max_nb_additional_bits:u32}

@(private="file")
get_offset_info :: proc "contextless" (off_table:[^]Seq_Symbol,nb_seq:int) -> (info:Offset_Info) #no_bounds_check {
    if nb_seq!=0 {
        table_log:=(^Seq_Symbol_Header)(off_table).table_log
        table:=off_table[1:]
        max_value:=u32(1)<<table_log
        for u in 0..<max_value {
            info.max_nb_additional_bits=max(info.max_nb_additional_bits,u32(table[u].nb_additional_bits))
            if table[u].nb_additional_bits>22 {info.long_offset_share+=1}
        }
        info.long_offset_share<<=(OFF_FSE_LOG-table_log)
    }
    return info
}

decompress_block_internal :: proc "contextless" (dctx:^DCtx,dst:[^]u8,dst_capacity:int,src:[^]u8,src_size_in:int) -> (size:int,err:Error) {
    ip:=src
    src_size:=src_size_in

    if src_size>block_size_max(dctx) {return 0,.Src_Size_Wrong}

    {
        lit_c_size:=decode_literals_block(dctx,src,src_size,dst,dst_capacity) or_return
        ip=padd(ip,lit_c_size)
        src_size-=lit_c_size
    }

    {
        history_end_add:=min(dst_capacity,block_size_max(dctx))
        history_end:=history_end_add>0 ? padd(dst,history_end_add) : dst
        total_history_size:=uint(pdiff(history_end,dctx.prefix_start))
        use_prefetch_decoder:=false
        nb_seq:int
        seq_h_size:=decode_seq_headers(dctx,&nb_seq,ip,src_size) or_return
        ip=padd(ip,seq_h_size)
        src_size-=seq_h_size

        if (dst==nil || dst_capacity==0) && nb_seq>0 {return 0,.Dst_Size_Too_Small}
        if max(uint)-uint(uintptr(dst))<uint(1<<20) {return 0,.Dst_Size_Too_Small}

        if total_history_size>(1<<24) && nb_seq>8 {
            info:=get_offset_info(dctx.of_tptr,nb_seq)
            use_prefetch_decoder=info.long_offset_share>=7
        }

        if use_prefetch_decoder {
            return decompress_sequences_long(dctx,dst,dst_capacity,ip,src_size,nb_seq)
        }

        if dctx.lit_buffer_location==.Split {
            return decompress_sequences_split_lit_buffer(dctx,dst,dst_capacity,ip,src_size,nb_seq)
        }
        return decompress_sequences(dctx,dst,dst_capacity,ip,src_size,nb_seq)
    }
}
