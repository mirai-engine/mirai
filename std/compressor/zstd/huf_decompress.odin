package zstd

HUF_DECODER_FAST_TABLELOG :: 11
HUF_DECOMPRESS_WORKSPACE_SIZE :: (2<<10)+(1<<9)
HUF_DECOMPRESS_WORKSPACE_SIZE_U32 :: HUF_DECOMPRESS_WORKSPACE_SIZE/size_of(u32)

HUFFDTABLE_CAPACITY_LOG :: 12

Huf_DTable_Desc :: struct {max_table_log,table_type,table_log,reserved:u8}

huf_get_dtable_desc :: #force_inline proc "contextless" (table:[^]u32) -> Huf_DTable_Desc {return transmute(Huf_DTable_Desc)table[0]}

@(private="file")
huf_init_fast_dstream :: #force_inline proc "contextless" (ip:[^]u8) -> u64 {
    last_byte:=ip[7]
    bits_consumed:=last_byte!=0 ? 8-highbit32(u32(last_byte)) : 0
    value:=read64(ip)|1
    return value<<(bits_consumed&63)
}

@(private="file")
Huf_Decompress_Fast_Args :: struct {
    ip:[4][^]u8,
    op:[4][^]u8,
    bits:[4]u64,
    dt:[^]u32,
    ilowest:[^]u8,
    oend:[^]u8,
    iend:[4][^]u8,
}

// 1 on success, 0 when the fallback has to be used.
@(private="file")
huf_decompress_fast_args_init :: proc "contextless" (args:^Huf_Decompress_Fast_Args,dst:[^]u8,dst_size:int,src:[^]u8,src_size:int,dtable:[^]u32) -> (ok:bool,err:Error) #no_bounds_check {
    dt_log:=u32(huf_get_dtable_desc(dtable).table_log)
    istart:=src
    oend:=dst_size>0 ? padd(dst,dst_size) : dst

    if dst_size==0 {return false,.None}

    if src_size<10 {return false,.Corruption_Detected}

    if dt_log!=HUF_DECODER_FAST_TABLELOG {return false,.None}

    {
        length1:=int(read16(istart))
        length2:=int(read16(padd(istart,2)))
        length3:=int(read16(padd(istart,4)))
        length4:=uint(src_size)-uint(length1+length2+length3+6)
        args.iend[0]=padd(istart,6)
        args.iend[1]=padd(args.iend[0],length1)
        args.iend[2]=padd(args.iend[1],length2)
        args.iend[3]=padd(args.iend[2],length3)

        if length1<8 || length2<8 || length3<8 || length4<8 {return false,.None}
        if length4>uint(src_size) {return false,.Corruption_Detected}
    }
    args.ip[0]=padd(args.iend[1],-8)
    args.ip[1]=padd(args.iend[2],-8)
    args.ip[2]=padd(args.iend[3],-8)
    args.ip[3]=padd(src,src_size-8)

    args.op[0]=dst
    args.op[1]=padd(args.op[0],(dst_size+3)/4)
    args.op[2]=padd(args.op[1],(dst_size+3)/4)
    args.op[3]=padd(args.op[2],(dst_size+3)/4)

    if uintptr(args.op[3])>=uintptr(oend) {return false,.None}

    args.bits[0]=huf_init_fast_dstream(args.ip[0])
    args.bits[1]=huf_init_fast_dstream(args.ip[1])
    args.bits[2]=huf_init_fast_dstream(args.ip[2])
    args.bits[3]=huf_init_fast_dstream(args.ip[3])

    args.ilowest=istart
    args.oend=oend
    args.dt=dtable[1:]

    return true,.None
}

@(private="file")
huf_init_remaining_dstream :: proc "contextless" (bit:^Bit_DStream,args:^Huf_Decompress_Fast_Args,stream:int,segment_end:[^]u8) -> Error #no_bounds_check {
    if uintptr(args.op[stream])>uintptr(segment_end) {return .Corruption_Detected}
    if uintptr(args.ip[stream])<uintptr(padd(args.iend[stream],-8)) {return .Corruption_Detected}

    bit.bit_container=read64(args.ip[stream])
    bit.bits_consumed=ctz64(args.bits[stream])
    bit.start=args.ilowest
    bit.limit_ptr=padd(bit.start,8)
    bit.ptr=args.ip[stream]
    return .None
}

// Single-symbol decoding.

Huf_DElt_X1 :: struct {nb_bits,symbol:u8}

@(private="file")
huf_delt_x1_set4 :: #force_inline proc "contextless" (symbol,nb_bits:u8) -> u64 {
    d4:=u64(u32(symbol)<<8+u32(nb_bits))
    return d4*0x0001000100010001
}

@(private="file")
huf_rescale_stats :: proc "contextless" (huff_weight:[^]u8,rank_val:[^]u32,nb_symbols,table_log,target_table_log:u32) -> u32 #no_bounds_check {
    if table_log>target_table_log {return table_log}
    if table_log<target_table_log {
        scale:=target_table_log-table_log
        for s in 0..<nb_symbols {
            huff_weight[s]+=huff_weight[s]==0 ? 0 : u8(scale)
        }
        for s:=target_table_log;s>scale;s-=1 {
            rank_val[s]=rank_val[s-scale]
        }
        for s:=scale;s>0;s-=1 {
            rank_val[s]=0
        }
    }
    return target_table_log
}

@(private="file")
Huf_Read_DTable_X1_Workspace :: struct {
    rank_val:[HUF_TABLELOG_ABSOLUTEMAX+1]u32,
    rank_start:[HUF_TABLELOG_ABSOLUTEMAX+1]u32,
    stats_wksp:[HUF_READ_STATS_WORKSPACE_SIZE_U32]u32,
    symbols:[HUF_SYMBOLVALUE_MAX+1]u8,
    huff_weight:[HUF_SYMBOLVALUE_MAX+1]u8,
}

huf_read_dtable_x1_wksp :: proc "contextless" (dtable:[^]u32,src:[^]u8,src_size:int,workspace:[^]u32,wksp_size:int) -> (size:int,err:Error) #no_bounds_check {
    table_log:u32
    nb_symbols:u32
    dt:=([^]Huf_DElt_X1)(&dtable[1])
    wksp:=(^Huf_Read_DTable_X1_Workspace)(workspace)

    if size_of(Huf_Read_DTable_X1_Workspace)>wksp_size {return 0,.Table_Log_Too_Large}

    i_size:=huf_read_stats(&wksp.huff_weight[0],HUF_SYMBOLVALUE_MAX+1,&wksp.rank_val[0],&nb_symbols,&table_log,src,src_size,&wksp.stats_wksp[0],size_of(wksp.stats_wksp)) or_return

    {
        dtd:=huf_get_dtable_desc(dtable)
        max_table_log:=u32(dtd.max_table_log)+1
        target_table_log:=min(max_table_log,HUF_DECODER_FAST_TABLELOG)
        table_log=huf_rescale_stats(&wksp.huff_weight[0],&wksp.rank_val[0],nb_symbols,table_log,target_table_log)
        if table_log>u32(dtd.max_table_log)+1 {return 0,.Table_Log_Too_Large}
        dtd.table_type=0
        dtd.table_log=u8(table_log)
        dtable[0]=transmute(u32)dtd
    }

    {
        next_rank_start:=u32(0)
        unroll:=4
        n_limit:=int(nb_symbols)-unroll+1
        for n in 0..<int(table_log)+1 {
            curr:=next_rank_start
            next_rank_start+=wksp.rank_val[n]
            wksp.rank_start[n]=curr
        }
        n:=0
        for ;n<n_limit;n+=unroll {
            for u in 0..<unroll {
                w:=wksp.huff_weight[n+u]
                wksp.symbols[wksp.rank_start[w]]=u8(n+u)
                wksp.rank_start[w]+=1
            }
        }
        for ;n<int(nb_symbols);n+=1 {
            w:=wksp.huff_weight[n]
            wksp.symbols[wksp.rank_start[w]]=u8(n)
            wksp.rank_start[w]+=1
        }
    }

    {
        symbol:=int(wksp.rank_val[0])
        rank_start:=0
        for w:=u32(1);w<table_log+1;w+=1 {
            symbol_count:=int(wksp.rank_val[w])
            length:=(1<<w)>>1
            u_start:=rank_start
            nb_bits:=u8(table_log+1-w)
            switch length {
            case 1:
                for s in 0..<symbol_count {
                    d:=Huf_DElt_X1{symbol=wksp.symbols[symbol+s],nb_bits=nb_bits}
                    dt[u_start]=d
                    u_start+=1
                }
            case 2:
                for s in 0..<symbol_count {
                    d:=Huf_DElt_X1{symbol=wksp.symbols[symbol+s],nb_bits=nb_bits}
                    dt[u_start+0]=d
                    dt[u_start+1]=d
                    u_start+=2
                }
            case 4:
                for s in 0..<symbol_count {
                    d4:=huf_delt_x1_set4(wksp.symbols[symbol+s],nb_bits)
                    write64(([^]u8)(&dt[u_start]),d4)
                    u_start+=4
                }
            case 8:
                for s in 0..<symbol_count {
                    d4:=huf_delt_x1_set4(wksp.symbols[symbol+s],nb_bits)
                    write64(([^]u8)(&dt[u_start]),d4)
                    write64(([^]u8)(&dt[u_start+4]),d4)
                    u_start+=8
                }
            case:
                for s in 0..<symbol_count {
                    d4:=huf_delt_x1_set4(wksp.symbols[symbol+s],nb_bits)
                    for u:=0;u<length;u+=16 {
                        write64(([^]u8)(&dt[u_start+u+0]),d4)
                        write64(([^]u8)(&dt[u_start+u+4]),d4)
                        write64(([^]u8)(&dt[u_start+u+8]),d4)
                        write64(([^]u8)(&dt[u_start+u+12]),d4)
                    }
                    u_start+=length
                }
            }
            symbol+=symbol_count
            rank_start+=symbol_count*length
        }
    }
    return i_size,.None
}

@(private="file")
huf_decode_symbol_x1 :: #force_inline proc "contextless" (d_stream:^Bit_DStream,dt:[^]Huf_DElt_X1,dt_log:u32) -> u8 {
    val:=bit_look_bits_fast(d_stream,dt_log)
    c:=dt[val].symbol
    bit_skip_bits(d_stream,u32(dt[val].nb_bits))
    return c
}

@(private="file")
huf_put_symbol_x1 :: #force_inline proc "contextless" (ptr:^[^]u8,d_stream:^Bit_DStream,dt:[^]Huf_DElt_X1,dt_log:u32) {
    ptr^[0]=huf_decode_symbol_x1(d_stream,dt,dt_log)
    ptr^=padd(ptr^,1)
}

@(private="file")
huf_decode_stream_x1 :: #force_inline proc "contextless" (p_in:[^]u8,bit_d_ptr:^Bit_DStream,p_end:[^]u8,dt:[^]Huf_DElt_X1,dt_log:u32) -> int {
    p:=p_in
    p_start:=p

    if pdiff(p_end,p)>3 {
        for bit_reload_dstream(bit_d_ptr)==.Unfinished && uintptr(p)<uintptr(padd(p_end,-3)) {
            huf_put_symbol_x1(&p,bit_d_ptr,dt,dt_log)
            huf_put_symbol_x1(&p,bit_d_ptr,dt,dt_log)
            huf_put_symbol_x1(&p,bit_d_ptr,dt,dt_log)
            huf_put_symbol_x1(&p,bit_d_ptr,dt,dt_log)
        }
    } else {
        bit_reload_dstream(bit_d_ptr)
    }

    for uintptr(p)<uintptr(p_end) {
        huf_put_symbol_x1(&p,bit_d_ptr,dt,dt_log)
    }

    return pdiff(p_end,p_start)
}

@(private="file")
huf_decompress1x1_using_dtable_internal :: proc "contextless" (dst:[^]u8,dst_size:int,c_src:[^]u8,c_src_size:int,dtable:[^]u32) -> (size:int,err:Error) #no_bounds_check {
    op:=dst
    oend:=dst_size>0 ? padd(op,dst_size) : op
    dt:=([^]Huf_DElt_X1)(&dtable[1])
    bit_d:Bit_DStream
    dtd:=huf_get_dtable_desc(dtable)
    dt_log:=u32(dtd.table_log)

    if e:=bit_init_dstream(&bit_d,c_src,c_src_size);e!=.None {return 0,e}

    huf_decode_stream_x1(op,&bit_d,oend,dt,dt_log)

    if !bit_end_of_dstream(&bit_d) {return 0,.Corruption_Detected}

    return dst_size,.None
}

@(private="file")
huf_decompress4x1_using_dtable_internal_body :: proc "contextless" (dst:[^]u8,dst_size:int,c_src:[^]u8,c_src_size:int,dtable:[^]u32) -> (size:int,err:Error) #no_bounds_check {
    if c_src_size<10 {return 0,.Corruption_Detected}
    if dst_size<6 {return 0,.Corruption_Detected}

    istart:=c_src
    ostart:=dst
    oend:=padd(ostart,dst_size)
    olimit:=padd(oend,-3)
    dt:=([^]Huf_DElt_X1)(&dtable[1])

    bit_d1,bit_d2,bit_d3,bit_d4:Bit_DStream
    length1:=int(read16(istart))
    length2:=int(read16(padd(istart,2)))
    length3:=int(read16(padd(istart,4)))
    length4:=uint(c_src_size)-uint(length1+length2+length3+6)
    istart1:=padd(istart,6)
    istart2:=padd(istart1,length1)
    istart3:=padd(istart2,length2)
    istart4:=padd(istart3,length3)
    segment_size:=(dst_size+3)/4
    op_start2:=padd(ostart,segment_size)
    op_start3:=padd(op_start2,segment_size)
    op_start4:=padd(op_start3,segment_size)
    op1:=ostart
    op2:=op_start2
    op3:=op_start3
    op4:=op_start4
    dtd:=huf_get_dtable_desc(dtable)
    dt_log:=u32(dtd.table_log)
    end_signal:=true

    if length4>uint(c_src_size) {return 0,.Corruption_Detected}
    if uintptr(op_start4)>uintptr(oend) {return 0,.Corruption_Detected}
    if e:=bit_init_dstream(&bit_d1,istart1,length1);e!=.None {return 0,e}
    if e:=bit_init_dstream(&bit_d2,istart2,length2);e!=.None {return 0,e}
    if e:=bit_init_dstream(&bit_d3,istart3,length3);e!=.None {return 0,e}
    if e:=bit_init_dstream(&bit_d4,istart4,int(length4));e!=.None {return 0,e}

    if pdiff(oend,op4)>=size_of(uint) {
        for end_signal && uintptr(op4)<uintptr(olimit) {
            huf_put_symbol_x1(&op1,&bit_d1,dt,dt_log)
            huf_put_symbol_x1(&op2,&bit_d2,dt,dt_log)
            huf_put_symbol_x1(&op3,&bit_d3,dt,dt_log)
            huf_put_symbol_x1(&op4,&bit_d4,dt,dt_log)
            huf_put_symbol_x1(&op1,&bit_d1,dt,dt_log)
            huf_put_symbol_x1(&op2,&bit_d2,dt,dt_log)
            huf_put_symbol_x1(&op3,&bit_d3,dt,dt_log)
            huf_put_symbol_x1(&op4,&bit_d4,dt,dt_log)
            huf_put_symbol_x1(&op1,&bit_d1,dt,dt_log)
            huf_put_symbol_x1(&op2,&bit_d2,dt,dt_log)
            huf_put_symbol_x1(&op3,&bit_d3,dt,dt_log)
            huf_put_symbol_x1(&op4,&bit_d4,dt,dt_log)
            huf_put_symbol_x1(&op1,&bit_d1,dt,dt_log)
            huf_put_symbol_x1(&op2,&bit_d2,dt,dt_log)
            huf_put_symbol_x1(&op3,&bit_d3,dt,dt_log)
            huf_put_symbol_x1(&op4,&bit_d4,dt,dt_log)
            reload1:=bit_reload_dstream_fast(&bit_d1)
            reload2:=bit_reload_dstream_fast(&bit_d2)
            reload3:=bit_reload_dstream_fast(&bit_d3)
            reload4:=bit_reload_dstream_fast(&bit_d4)
            end_signal=reload1==.Unfinished && reload2==.Unfinished && reload3==.Unfinished && reload4==.Unfinished
        }
    }

    if uintptr(op1)>uintptr(op_start2) {return 0,.Corruption_Detected}
    if uintptr(op2)>uintptr(op_start3) {return 0,.Corruption_Detected}
    if uintptr(op3)>uintptr(op_start4) {return 0,.Corruption_Detected}

    huf_decode_stream_x1(op1,&bit_d1,op_start2,dt,dt_log)
    huf_decode_stream_x1(op2,&bit_d2,op_start3,dt,dt_log)
    huf_decode_stream_x1(op3,&bit_d3,op_start4,dt,dt_log)
    huf_decode_stream_x1(op4,&bit_d4,oend,dt,dt_log)

    if !(bit_end_of_dstream(&bit_d1) && bit_end_of_dstream(&bit_d2) && bit_end_of_dstream(&bit_d3) && bit_end_of_dstream(&bit_d4)) {return 0,.Corruption_Detected}

    return dst_size,.None
}

@(private="file")
huf_4x1_decode_symbol :: #force_inline proc "contextless" (bits:^u64,op:[^]u8,dtable:[^]u16,symbol:int) {
    index:=int(bits^>>53)
    entry:=int(dtable[index])
    bits^=bits^<<(u64(entry)&0x3F)
    op[symbol]=u8((entry>>8)&0xFF)
}

@(private="file")
huf_4x1_reload_stream :: #force_inline proc "contextless" (bits:^u64,ip,op:^[^]u8) {
    ctz:=int(ctz64(bits^))
    nb_bits:=ctz&7
    nb_bytes:=ctz>>3
    op^=padd(op^,5)
    ip^=padd(ip^,-nb_bytes)
    bits^=read64(ip^)|1
    bits^=bits^<<(u64(nb_bits)&63)
}

@(private="file")
huf_decompress4x1_using_dtable_internal_fast_c_loop :: proc "contextless" (args:^Huf_Decompress_Fast_Args) #no_bounds_check {
    bits:=args.bits
    ip:=args.ip
    op:=args.op
    dtable:=([^]u16)(args.dt)
    oend:=args.oend
    ilowest:=args.ilowest

    fast: for {
        olimit:[^]u8
        {
            oiters:=pdiff(oend,op[3])/5
            iiters:=pdiff(ip[0],ilowest)/7
            iters:=min(oiters,iiters)
            symbols:=iters*5
            olimit=padd(op[3],symbols)
            if op[3]==olimit {break fast}
            for stream in 1..<4 {
                if uintptr(ip[stream])<uintptr(ip[stream-1]) {break fast}
            }
        }

        for {
            huf_4x1_decode_symbol(&bits[0],op[0],dtable,0)
            huf_4x1_decode_symbol(&bits[1],op[1],dtable,0)
            huf_4x1_decode_symbol(&bits[2],op[2],dtable,0)
            huf_4x1_decode_symbol(&bits[3],op[3],dtable,0)
            huf_4x1_decode_symbol(&bits[0],op[0],dtable,1)
            huf_4x1_decode_symbol(&bits[1],op[1],dtable,1)
            huf_4x1_decode_symbol(&bits[2],op[2],dtable,1)
            huf_4x1_decode_symbol(&bits[3],op[3],dtable,1)
            huf_4x1_decode_symbol(&bits[0],op[0],dtable,2)
            huf_4x1_decode_symbol(&bits[1],op[1],dtable,2)
            huf_4x1_decode_symbol(&bits[2],op[2],dtable,2)
            huf_4x1_decode_symbol(&bits[3],op[3],dtable,2)
            huf_4x1_decode_symbol(&bits[0],op[0],dtable,3)
            huf_4x1_decode_symbol(&bits[1],op[1],dtable,3)
            huf_4x1_decode_symbol(&bits[2],op[2],dtable,3)
            huf_4x1_decode_symbol(&bits[3],op[3],dtable,3)
            huf_4x1_decode_symbol(&bits[0],op[0],dtable,4)
            huf_4x1_decode_symbol(&bits[1],op[1],dtable,4)
            huf_4x1_decode_symbol(&bits[2],op[2],dtable,4)
            huf_4x1_decode_symbol(&bits[3],op[3],dtable,4)

            huf_4x1_reload_stream(&bits[0],&ip[0],&op[0])
            huf_4x1_reload_stream(&bits[1],&ip[1],&op[1])
            huf_4x1_reload_stream(&bits[2],&ip[2],&op[2])
            huf_4x1_reload_stream(&bits[3],&ip[3],&op[3])

            if uintptr(op[3])>=uintptr(olimit) {break}
        }
    }

    args.bits=bits
    args.ip=ip
    args.op=op
}

// 0 means the fallback has to be used.
@(private="file")
huf_decompress4x1_using_dtable_internal_fast :: proc "contextless" (dst:[^]u8,dst_size:int,c_src:[^]u8,c_src_size:int,dtable:[^]u32) -> (size:int,err:Error) #no_bounds_check {
    dt:=([^]Huf_DElt_X1)(&dtable[1])
    oend:=dst_size>0 ? padd(dst,dst_size) : dst
    args:Huf_Decompress_Fast_Args
    ok:bool
    ok,err=huf_decompress_fast_args_init(&args,dst,dst_size,c_src,c_src_size,dtable)
    if err!=.None {return 0,err}
    if !ok {return 0,.None}

    huf_decompress4x1_using_dtable_internal_fast_c_loop(&args)

    {
        segment_size:=(dst_size+3)/4
        segment_end:=dst
        for i in 0..<4 {
            bit:Bit_DStream
            if segment_size<=pdiff(oend,segment_end) {
                segment_end=padd(segment_end,segment_size)
            } else {
                segment_end=oend
            }
            if e:=huf_init_remaining_dstream(&bit,&args,i,segment_end);e!=.None {return 0,e}
            args.op[i]=padd(args.op[i],huf_decode_stream_x1(args.op[i],&bit,segment_end,dt,HUF_DECODER_FAST_TABLELOG))
            if args.op[i]!=segment_end {return 0,.Corruption_Detected}
        }
    }

    return dst_size,.None
}

@(private="file")
huf_decompress4x1_using_dtable_internal :: proc "contextless" (dst:[^]u8,dst_size:int,c_src:[^]u8,c_src_size:int,dtable:[^]u32) -> (size:int,err:Error) {
    ret,fast_err:=huf_decompress4x1_using_dtable_internal_fast(dst,dst_size,c_src,c_src_size,dtable)
    if fast_err!=.None {return 0,fast_err}
    if ret!=0 {return ret,.None}
    return huf_decompress4x1_using_dtable_internal_body(dst,dst_size,c_src,c_src_size,dtable)
}

@(private="file")
huf_decompress4x1_dctx_wksp :: proc "contextless" (dctx:[^]u32,dst:[^]u8,dst_size:int,c_src:[^]u8,c_src_size_in:int,workspace:[^]u32,wksp_size:int) -> (size:int,err:Error) {
    c_src_size:=c_src_size_in
    ip:=c_src
    h_size:=huf_read_dtable_x1_wksp(dctx,c_src,c_src_size,workspace,wksp_size) or_return
    if h_size>=c_src_size {return 0,.Src_Size_Wrong}
    ip=padd(ip,h_size)
    c_src_size-=h_size
    return huf_decompress4x1_using_dtable_internal(dst,dst_size,ip,c_src_size,dctx)
}

// Double-symbol decoding.

Huf_DElt_X2 :: struct {sequence:u16,nb_bits,length:u8}

@(private="file")
Rank_Val_Col :: [HUF_TABLELOG_MAX+1]u32

@(private="file")
huf_build_delt_x2_u32 :: #force_inline proc "contextless" (symbol,nb_bits,base_seq:u32,level:int) -> u32 {
    seq:=level==1 ? symbol : base_seq+(symbol<<8)
    return seq+(nb_bits<<16)+(u32(level)<<24)
}

@(private="file")
huf_build_delt_x2 :: #force_inline proc "contextless" (symbol,nb_bits,base_seq:u32,level:int) -> Huf_DElt_X2 {
    return transmute(Huf_DElt_X2)huf_build_delt_x2_u32(symbol,nb_bits,base_seq,level)
}

@(private="file")
huf_build_delt_x2_u64 :: #force_inline proc "contextless" (symbol,nb_bits:u32,base_seq:u16,level:int) -> u64 {
    d_elt:=huf_build_delt_x2_u32(symbol,nb_bits,u32(base_seq),level)
    return u64(d_elt)+(u64(d_elt)<<32)
}

@(private="file")
huf_x2_write2 :: #force_inline proc "contextless" (table:[^]Huf_DElt_X2,value:u64) {write64(([^]u8)(table),value)}

@(private="file")
huf_fill_dtable_x2_for_weight :: proc "contextless" (dtable_rank_in:[^]Huf_DElt_X2,begin,end:[^]u8,nb_bits,table_log:u32,base_seq:u16,level:int) #no_bounds_check {
    dtable_rank:=dtable_rank_in
    length:=u32(1)<<((table_log-nb_bits)&0x1F)
    switch length {
    case 1:
        for ptr:=begin;ptr!=end;ptr=padd(ptr,1) {
            d_elt:=huf_build_delt_x2(u32(ptr[0]),nb_bits,u32(base_seq),level)
            dtable_rank[0]=d_elt
            dtable_rank=dtable_rank[1:]
        }
    case 2:
        for ptr:=begin;ptr!=end;ptr=padd(ptr,1) {
            d_elt:=huf_build_delt_x2(u32(ptr[0]),nb_bits,u32(base_seq),level)
            dtable_rank[0]=d_elt
            dtable_rank[1]=d_elt
            dtable_rank=dtable_rank[2:]
        }
    case 4:
        for ptr:=begin;ptr!=end;ptr=padd(ptr,1) {
            d_elt:=huf_build_delt_x2_u64(u32(ptr[0]),nb_bits,base_seq,level)
            huf_x2_write2(dtable_rank[0:],d_elt)
            huf_x2_write2(dtable_rank[2:],d_elt)
            dtable_rank=dtable_rank[4:]
        }
    case 8:
        for ptr:=begin;ptr!=end;ptr=padd(ptr,1) {
            d_elt:=huf_build_delt_x2_u64(u32(ptr[0]),nb_bits,base_seq,level)
            huf_x2_write2(dtable_rank[0:],d_elt)
            huf_x2_write2(dtable_rank[2:],d_elt)
            huf_x2_write2(dtable_rank[4:],d_elt)
            huf_x2_write2(dtable_rank[6:],d_elt)
            dtable_rank=dtable_rank[8:]
        }
    case:
        for ptr:=begin;ptr!=end;ptr=padd(ptr,1) {
            d_elt:=huf_build_delt_x2_u64(u32(ptr[0]),nb_bits,base_seq,level)
            dtable_rank_end:=dtable_rank[length:]
            for ;dtable_rank!=dtable_rank_end;dtable_rank=dtable_rank[8:] {
                huf_x2_write2(dtable_rank[0:],d_elt)
                huf_x2_write2(dtable_rank[2:],d_elt)
                huf_x2_write2(dtable_rank[4:],d_elt)
                huf_x2_write2(dtable_rank[6:],d_elt)
            }
        }
    }
}

@(private="file")
huf_fill_dtable_x2_level2 :: proc "contextless" (dtable:[^]Huf_DElt_X2,target_log,consumed_bits:u32,rank_val:[^]u32,min_weight,max_weight1:int,sorted_symbols:[^]u8,rank_start:[^]u32,nb_bits_baseline:u32,base_seq:u16) #no_bounds_check {
    if min_weight>1 {
        length:=u32(1)<<((target_log-consumed_bits)&0x1F)
        d_elt:=huf_build_delt_x2_u64(u32(base_seq),consumed_bits,0,1)
        skip_size:=int(rank_val[min_weight])
        switch length {
        case 2:
            huf_x2_write2(dtable,d_elt)
        case 4:
            huf_x2_write2(dtable[0:],d_elt)
            huf_x2_write2(dtable[2:],d_elt)
        case:
            for i:=0;i<skip_size;i+=8 {
                huf_x2_write2(dtable[i+0:],d_elt)
                huf_x2_write2(dtable[i+2:],d_elt)
                huf_x2_write2(dtable[i+4:],d_elt)
                huf_x2_write2(dtable[i+6:],d_elt)
            }
        }
    }

    for w:=min_weight;w<max_weight1;w+=1 {
        begin:=int(rank_start[w])
        end:=int(rank_start[w+1])
        nb_bits:=nb_bits_baseline-u32(w)
        total_bits:=nb_bits+consumed_bits
        huf_fill_dtable_x2_for_weight(dtable[rank_val[w]:],padd(sorted_symbols,begin),padd(sorted_symbols,end),total_bits,target_log,base_seq,2)
    }
}

@(private="file")
huf_fill_dtable_x2 :: proc "contextless" (dtable:[^]Huf_DElt_X2,target_log:u32,sorted_list:[^]u8,rank_start:[^]u32,rank_val_origin:[^]Rank_Val_Col,max_weight,nb_bits_baseline:u32) #no_bounds_check {
    rank_val:=([^]u32)(&rank_val_origin[0])
    scale_log:=int(nb_bits_baseline)-int(target_log)
    min_bits:=nb_bits_baseline-max_weight
    w_end:=int(max_weight)+1

    for w:=1;w<w_end;w+=1 {
        begin:=int(rank_start[w])
        end:=int(rank_start[w+1])
        nb_bits:=nb_bits_baseline-u32(w)

        if target_log-nb_bits>=min_bits {
            start:=int(rank_val[w])
            length:=int(u32(1)<<((target_log-nb_bits)&0x1F))
            min_weight:=int(nb_bits)+scale_log
            if min_weight<1 {min_weight=1}
            for s:=begin;s!=end;s+=1 {
                huf_fill_dtable_x2_level2(dtable[start:],target_log,nb_bits,([^]u32)(&rank_val_origin[nb_bits]),min_weight,w_end,sorted_list,rank_start,nb_bits_baseline,u16(sorted_list[s]))
                start+=length
            }
        } else {
            huf_fill_dtable_x2_for_weight(dtable[rank_val[w]:],padd(sorted_list,begin),padd(sorted_list,end),nb_bits,target_log,0,1)
        }
    }
}

@(private="file")
Huf_Read_DTable_X2_Workspace :: struct {
    rank_val:[HUF_TABLELOG_MAX]Rank_Val_Col,
    rank_stats:[HUF_TABLELOG_MAX+1]u32,
    rank_start0:[HUF_TABLELOG_MAX+3]u32,
    sorted_symbol:[HUF_SYMBOLVALUE_MAX+1]u8,
    weight_list:[HUF_SYMBOLVALUE_MAX+1]u8,
    callee_wksp:[HUF_READ_STATS_WORKSPACE_SIZE_U32]u32,
}

huf_read_dtable_x2_wksp :: proc "contextless" (dtable:[^]u32,src:[^]u8,src_size:int,workspace:[^]u32,wksp_size:int) -> (size:int,err:Error) #no_bounds_check {
    table_log,max_w,nb_symbols:u32
    dtd:=huf_get_dtable_desc(dtable)
    max_table_log:=u32(dtd.max_table_log)
    dt:=([^]Huf_DElt_X2)(&dtable[1])
    wksp:=(^Huf_Read_DTable_X2_Workspace)(workspace)

    if size_of(Huf_Read_DTable_X2_Workspace)>wksp_size {return 0,.Generic}

    rank_start:=([^]u32)(&wksp.rank_start0[1])
    wksp.rank_stats={}
    wksp.rank_start0={}

    if max_table_log>HUF_TABLELOG_MAX {return 0,.Table_Log_Too_Large}

    i_size:=huf_read_stats(&wksp.weight_list[0],HUF_SYMBOLVALUE_MAX+1,&wksp.rank_stats[0],&nb_symbols,&table_log,src,src_size,&wksp.callee_wksp[0],size_of(wksp.callee_wksp)) or_return

    if table_log>max_table_log {return 0,.Table_Log_Too_Large}
    if table_log<=HUF_DECODER_FAST_TABLELOG && max_table_log>HUF_DECODER_FAST_TABLELOG {max_table_log=HUF_DECODER_FAST_TABLELOG}

    for max_w=table_log;wksp.rank_stats[max_w]==0;max_w-=1 {}

    {
        next_rank_start:=u32(0)
        for w:=u32(1);w<max_w+1;w+=1 {
            curr:=next_rank_start
            next_rank_start+=wksp.rank_stats[w]
            rank_start[w]=curr
        }
        rank_start[0]=next_rank_start
        rank_start[max_w+1]=next_rank_start
    }

    {
        for s in 0..<nb_symbols {
            w:=u32(wksp.weight_list[s])
            r:=rank_start[w]
            rank_start[w]+=1
            wksp.sorted_symbol[r]=u8(s)
        }
        rank_start[0]=0
    }

    {
        rank_val0:=([^]u32)(&wksp.rank_val[0])
        {
            rescale:=int(max_table_log)-int(table_log)-1
            next_rank_val:=u32(0)
            for w:=u32(1);w<max_w+1;w+=1 {
                curr:=next_rank_val
                next_rank_val+=wksp.rank_stats[w]<<u32(int(w)+rescale)
                rank_val0[w]=curr
            }
        }
        {
            min_bits:=table_log+1-max_w
            for consumed:=min_bits;consumed<max_table_log-min_bits+1;consumed+=1 {
                rank_val_ptr:=([^]u32)(&wksp.rank_val[consumed])
                for w:=u32(1);w<max_w+1;w+=1 {
                    rank_val_ptr[w]=rank_val0[w]>>consumed
                }
            }
        }
    }

    huf_fill_dtable_x2(dt,max_table_log,&wksp.sorted_symbol[0],&wksp.rank_start0[0],&wksp.rank_val[0],max_w,table_log+1)

    dtd.table_log=u8(max_table_log)
    dtd.table_type=1
    dtable[0]=transmute(u32)dtd
    return i_size,.None
}

@(private="file")
huf_decode_symbol_x2 :: #force_inline proc "contextless" (op:[^]u8,d_stream:^Bit_DStream,dt:[^]Huf_DElt_X2,dt_log:u32) -> u32 {
    val:=bit_look_bits_fast(d_stream,dt_log)
    write16(op,dt[val].sequence)
    bit_skip_bits(d_stream,u32(dt[val].nb_bits))
    return u32(dt[val].length)
}

@(private="file")
huf_decode_last_symbol_x2 :: #force_inline proc "contextless" (op:[^]u8,d_stream:^Bit_DStream,dt:[^]Huf_DElt_X2,dt_log:u32) -> u32 {
    val:=bit_look_bits_fast(d_stream,dt_log)
    op[0]=u8(dt[val].sequence)
    if dt[val].length==1 {
        bit_skip_bits(d_stream,u32(dt[val].nb_bits))
    } else {
        if d_stream.bits_consumed<64 {
            bit_skip_bits(d_stream,u32(dt[val].nb_bits))
            if d_stream.bits_consumed>64 {
                d_stream.bits_consumed=64
            }
        }
    }
    return 1
}

@(private="file")
huf_put_symbol_x2 :: #force_inline proc "contextless" (ptr:^[^]u8,d_stream:^Bit_DStream,dt:[^]Huf_DElt_X2,dt_log:u32) {
    ptr^=padd(ptr^,int(huf_decode_symbol_x2(ptr^,d_stream,dt,dt_log)))
}

@(private="file")
huf_decode_stream_x2 :: #force_inline proc "contextless" (p_in:[^]u8,bit_d_ptr:^Bit_DStream,p_end:[^]u8,dt:[^]Huf_DElt_X2,dt_log:u32) -> int {
    p:=p_in
    p_start:=p

    if uint(pdiff(p_end,p))>=size_of(u64) {
        if dt_log<=11 {
            for bit_reload_dstream(bit_d_ptr)==.Unfinished && uintptr(p)<uintptr(padd(p_end,-9)) {
                huf_put_symbol_x2(&p,bit_d_ptr,dt,dt_log)
                huf_put_symbol_x2(&p,bit_d_ptr,dt,dt_log)
                huf_put_symbol_x2(&p,bit_d_ptr,dt,dt_log)
                huf_put_symbol_x2(&p,bit_d_ptr,dt,dt_log)
                huf_put_symbol_x2(&p,bit_d_ptr,dt,dt_log)
            }
        } else {
            for bit_reload_dstream(bit_d_ptr)==.Unfinished && uintptr(p)<uintptr(padd(p_end,-(size_of(u64)-1))) {
                huf_put_symbol_x2(&p,bit_d_ptr,dt,dt_log)
                huf_put_symbol_x2(&p,bit_d_ptr,dt,dt_log)
                huf_put_symbol_x2(&p,bit_d_ptr,dt,dt_log)
                huf_put_symbol_x2(&p,bit_d_ptr,dt,dt_log)
            }
        }
    } else {
        bit_reload_dstream(bit_d_ptr)
    }

    if uint(pdiff(p_end,p))>=2 {
        for bit_reload_dstream(bit_d_ptr)==.Unfinished && uintptr(p)<=uintptr(padd(p_end,-2)) {
            huf_put_symbol_x2(&p,bit_d_ptr,dt,dt_log)
        }

        for uintptr(p)<=uintptr(padd(p_end,-2)) {
            huf_put_symbol_x2(&p,bit_d_ptr,dt,dt_log)
        }
    }

    if uintptr(p)<uintptr(p_end) {
        p=padd(p,int(huf_decode_last_symbol_x2(p,bit_d_ptr,dt,dt_log)))
    }

    return pdiff(p,p_start)
}

@(private="file")
huf_decompress1x2_using_dtable_internal :: proc "contextless" (dst:[^]u8,dst_size:int,c_src:[^]u8,c_src_size:int,dtable:[^]u32) -> (size:int,err:Error) #no_bounds_check {
    bit_d:Bit_DStream

    if e:=bit_init_dstream(&bit_d,c_src,c_src_size);e!=.None {return 0,e}

    {
        ostart:=dst
        oend:=dst_size>0 ? padd(ostart,dst_size) : ostart
        dt:=([^]Huf_DElt_X2)(&dtable[1])
        dtd:=huf_get_dtable_desc(dtable)
        huf_decode_stream_x2(ostart,&bit_d,oend,dt,u32(dtd.table_log))
    }

    if !bit_end_of_dstream(&bit_d) {return 0,.Corruption_Detected}

    return dst_size,.None
}

@(private="file")
huf_decompress4x2_using_dtable_internal_body :: proc "contextless" (dst:[^]u8,dst_size:int,c_src:[^]u8,c_src_size:int,dtable:[^]u32) -> (size:int,err:Error) #no_bounds_check {
    if c_src_size<10 {return 0,.Corruption_Detected}
    if dst_size<6 {return 0,.Corruption_Detected}

    istart:=c_src
    ostart:=dst
    oend:=padd(ostart,dst_size)
    olimit:=padd(oend,-(size_of(uint)-1))
    dt:=([^]Huf_DElt_X2)(&dtable[1])

    bit_d1,bit_d2,bit_d3,bit_d4:Bit_DStream
    length1:=int(read16(istart))
    length2:=int(read16(padd(istart,2)))
    length3:=int(read16(padd(istart,4)))
    length4:=uint(c_src_size)-uint(length1+length2+length3+6)
    istart1:=padd(istart,6)
    istart2:=padd(istart1,length1)
    istart3:=padd(istart2,length2)
    istart4:=padd(istart3,length3)
    segment_size:=(dst_size+3)/4
    op_start2:=padd(ostart,segment_size)
    op_start3:=padd(op_start2,segment_size)
    op_start4:=padd(op_start3,segment_size)
    op1:=ostart
    op2:=op_start2
    op3:=op_start3
    op4:=op_start4
    end_signal:=true
    dtd:=huf_get_dtable_desc(dtable)
    dt_log:=u32(dtd.table_log)

    if length4>uint(c_src_size) {return 0,.Corruption_Detected}
    if uintptr(op_start4)>uintptr(oend) {return 0,.Corruption_Detected}
    if e:=bit_init_dstream(&bit_d1,istart1,length1);e!=.None {return 0,e}
    if e:=bit_init_dstream(&bit_d2,istart2,length2);e!=.None {return 0,e}
    if e:=bit_init_dstream(&bit_d3,istart3,length3);e!=.None {return 0,e}
    if e:=bit_init_dstream(&bit_d4,istart4,int(length4));e!=.None {return 0,e}

    if pdiff(oend,op4)>=size_of(uint) {
        for end_signal && uintptr(op4)<uintptr(olimit) {
            huf_put_symbol_x2(&op1,&bit_d1,dt,dt_log)
            huf_put_symbol_x2(&op2,&bit_d2,dt,dt_log)
            huf_put_symbol_x2(&op3,&bit_d3,dt,dt_log)
            huf_put_symbol_x2(&op4,&bit_d4,dt,dt_log)
            huf_put_symbol_x2(&op1,&bit_d1,dt,dt_log)
            huf_put_symbol_x2(&op2,&bit_d2,dt,dt_log)
            huf_put_symbol_x2(&op3,&bit_d3,dt,dt_log)
            huf_put_symbol_x2(&op4,&bit_d4,dt,dt_log)
            huf_put_symbol_x2(&op1,&bit_d1,dt,dt_log)
            huf_put_symbol_x2(&op2,&bit_d2,dt,dt_log)
            huf_put_symbol_x2(&op3,&bit_d3,dt,dt_log)
            huf_put_symbol_x2(&op4,&bit_d4,dt,dt_log)
            huf_put_symbol_x2(&op1,&bit_d1,dt,dt_log)
            huf_put_symbol_x2(&op2,&bit_d2,dt,dt_log)
            huf_put_symbol_x2(&op3,&bit_d3,dt,dt_log)
            huf_put_symbol_x2(&op4,&bit_d4,dt,dt_log)
            reload1:=bit_reload_dstream_fast(&bit_d1)
            reload2:=bit_reload_dstream_fast(&bit_d2)
            reload3:=bit_reload_dstream_fast(&bit_d3)
            reload4:=bit_reload_dstream_fast(&bit_d4)
            end_signal=reload1==.Unfinished && reload2==.Unfinished && reload3==.Unfinished && reload4==.Unfinished
        }
    }

    if uintptr(op1)>uintptr(op_start2) {return 0,.Corruption_Detected}
    if uintptr(op2)>uintptr(op_start3) {return 0,.Corruption_Detected}
    if uintptr(op3)>uintptr(op_start4) {return 0,.Corruption_Detected}

    huf_decode_stream_x2(op1,&bit_d1,op_start2,dt,dt_log)
    huf_decode_stream_x2(op2,&bit_d2,op_start3,dt,dt_log)
    huf_decode_stream_x2(op3,&bit_d3,op_start4,dt,dt_log)
    huf_decode_stream_x2(op4,&bit_d4,oend,dt,dt_log)

    if !(bit_end_of_dstream(&bit_d1) && bit_end_of_dstream(&bit_d2) && bit_end_of_dstream(&bit_d3) && bit_end_of_dstream(&bit_d4)) {return 0,.Corruption_Detected}

    return dst_size,.None
}

@(private="file")
huf_4x2_decode_symbol :: #force_inline proc "contextless" (bits:^u64,op:^[^]u8,dtable:[^]Huf_DElt_X2) {
    index:=int(bits^>>53)
    entry:=dtable[index]
    write16(op^,entry.sequence)
    bits^=bits^<<(u64(entry.nb_bits)&0x3F)
    op^=padd(op^,int(entry.length))
}

@(private="file")
huf_4x2_reload_stream :: #force_inline proc "contextless" (bits:^u64,ip:^[^]u8) {
    ctz:=int(ctz64(bits^))
    nb_bits:=ctz&7
    nb_bytes:=ctz>>3
    ip^=padd(ip^,-nb_bytes)
    bits^=read64(ip^)|1
    bits^=bits^<<(u64(nb_bits)&63)
}

@(private="file")
huf_decompress4x2_using_dtable_internal_fast_c_loop :: proc "contextless" (args:^Huf_Decompress_Fast_Args) #no_bounds_check {
    bits:=args.bits
    ip:=args.ip
    op:=args.op
    oend:=[4][^]u8{op[1],op[2],op[3],args.oend}
    dtable:=([^]Huf_DElt_X2)(args.dt)
    ilowest:=args.ilowest

    fast: for {
        olimit:[^]u8
        {
            iters:=pdiff(ip[0],ilowest)/7
            for stream in 0..<4 {
                oiters:=pdiff(oend[stream],op[stream])/10
                iters=min(iters,oiters)
            }

            olimit=padd(op[3],iters*5)

            if op[3]==olimit {break fast}

            for stream in 1..<4 {
                if uintptr(ip[stream])<uintptr(ip[stream-1]) {break fast}
            }
        }

        for {
            huf_4x2_decode_symbol(&bits[0],&op[0],dtable)
            huf_4x2_decode_symbol(&bits[1],&op[1],dtable)
            huf_4x2_decode_symbol(&bits[2],&op[2],dtable)
            huf_4x2_decode_symbol(&bits[0],&op[0],dtable)
            huf_4x2_decode_symbol(&bits[1],&op[1],dtable)
            huf_4x2_decode_symbol(&bits[2],&op[2],dtable)
            huf_4x2_decode_symbol(&bits[0],&op[0],dtable)
            huf_4x2_decode_symbol(&bits[1],&op[1],dtable)
            huf_4x2_decode_symbol(&bits[2],&op[2],dtable)
            huf_4x2_decode_symbol(&bits[0],&op[0],dtable)
            huf_4x2_decode_symbol(&bits[1],&op[1],dtable)
            huf_4x2_decode_symbol(&bits[2],&op[2],dtable)
            huf_4x2_decode_symbol(&bits[0],&op[0],dtable)
            huf_4x2_decode_symbol(&bits[1],&op[1],dtable)
            huf_4x2_decode_symbol(&bits[2],&op[2],dtable)

            huf_4x2_decode_symbol(&bits[3],&op[3],dtable)

            huf_4x2_decode_symbol(&bits[3],&op[3],dtable)
            huf_4x2_reload_stream(&bits[0],&ip[0])
            huf_4x2_decode_symbol(&bits[3],&op[3],dtable)
            huf_4x2_reload_stream(&bits[1],&ip[1])
            huf_4x2_decode_symbol(&bits[3],&op[3],dtable)
            huf_4x2_reload_stream(&bits[2],&ip[2])
            huf_4x2_decode_symbol(&bits[3],&op[3],dtable)
            huf_4x2_reload_stream(&bits[3],&ip[3])

            if uintptr(op[3])>=uintptr(olimit) {break}
        }
    }

    args.bits=bits
    args.ip=ip
    args.op=op
}

@(private="file")
huf_decompress4x2_using_dtable_internal_fast :: proc "contextless" (dst:[^]u8,dst_size:int,c_src:[^]u8,c_src_size:int,dtable:[^]u32) -> (size:int,err:Error) #no_bounds_check {
    dt:=([^]Huf_DElt_X2)(&dtable[1])
    oend:=dst_size>0 ? padd(dst,dst_size) : dst
    args:Huf_Decompress_Fast_Args
    ok:bool
    ok,err=huf_decompress_fast_args_init(&args,dst,dst_size,c_src,c_src_size,dtable)
    if err!=.None {return 0,err}
    if !ok {return 0,.None}

    huf_decompress4x2_using_dtable_internal_fast_c_loop(&args)

    {
        segment_size:=(dst_size+3)/4
        segment_end:=dst
        for i in 0..<4 {
            bit:Bit_DStream
            if segment_size<=pdiff(oend,segment_end) {
                segment_end=padd(segment_end,segment_size)
            } else {
                segment_end=oend
            }
            if e:=huf_init_remaining_dstream(&bit,&args,i,segment_end);e!=.None {return 0,e}
            args.op[i]=padd(args.op[i],huf_decode_stream_x2(args.op[i],&bit,segment_end,dt,HUF_DECODER_FAST_TABLELOG))
            if args.op[i]!=segment_end {return 0,.Corruption_Detected}
        }
    }

    return dst_size,.None
}

@(private="file")
huf_decompress4x2_using_dtable_internal :: proc "contextless" (dst:[^]u8,dst_size:int,c_src:[^]u8,c_src_size:int,dtable:[^]u32) -> (size:int,err:Error) {
    ret,fast_err:=huf_decompress4x2_using_dtable_internal_fast(dst,dst_size,c_src,c_src_size,dtable)
    if fast_err!=.None {return 0,fast_err}
    if ret!=0 {return ret,.None}
    return huf_decompress4x2_using_dtable_internal_body(dst,dst_size,c_src,c_src_size,dtable)
}

@(private="file")
huf_decompress4x2_dctx_wksp :: proc "contextless" (dctx:[^]u32,dst:[^]u8,dst_size:int,c_src:[^]u8,c_src_size_in:int,workspace:[^]u32,wksp_size:int) -> (size:int,err:Error) {
    c_src_size:=c_src_size_in
    ip:=c_src
    h_size:=huf_read_dtable_x2_wksp(dctx,c_src,c_src_size,workspace,wksp_size) or_return
    if h_size>=c_src_size {return 0,.Src_Size_Wrong}
    ip=padd(ip,h_size)
    c_src_size-=h_size
    return huf_decompress4x2_using_dtable_internal(dst,dst_size,ip,c_src_size,dctx)
}

@(private="file")
Algo_Time :: struct {table_time,decode256_time:u32}

@(rodata,private="file") Algo_Time_Table:=[16][2]Algo_Time{
    {{0,0},{1,1}},
    {{0,0},{1,1}},
    {{150,216},{381,119}},
    {{170,205},{514,112}},
    {{177,199},{539,110}},
    {{197,194},{644,107}},
    {{221,192},{735,107}},
    {{256,189},{881,106}},
    {{359,188},{1167,109}},
    {{582,187},{1570,114}},
    {{688,187},{1712,122}},
    {{825,186},{1965,136}},
    {{976,185},{2131,150}},
    {{1180,186},{2070,175}},
    {{1377,185},{1731,202}},
    {{1412,185},{1695,202}},
}

// 0 for the single-symbol decoder, 1 for the double-symbol one. dst_size is above 0 and at most 128 KB.
huf_select_decoder :: proc "contextless" (dst_size,c_src_size:int) -> u32 #no_bounds_check {
    q:=c_src_size>=dst_size ? u32(15) : u32(c_src_size*16/dst_size)
    d256:=u32(dst_size>>8)
    d_time0:=Algo_Time_Table[q][0].table_time+Algo_Time_Table[q][0].decode256_time*d256
    d_time1:=Algo_Time_Table[q][1].table_time+Algo_Time_Table[q][1].decode256_time*d256
    d_time1+=d_time1>>5
    return d_time1<d_time0 ? 1 : 0
}

huf_decompress1x_using_dtable :: proc "contextless" (dst:[^]u8,max_dst_size:int,c_src:[^]u8,c_src_size:int,dtable:[^]u32) -> (size:int,err:Error) {
    dtd:=huf_get_dtable_desc(dtable)
    if dtd.table_type!=0 {return huf_decompress1x2_using_dtable_internal(dst,max_dst_size,c_src,c_src_size,dtable)}
    return huf_decompress1x1_using_dtable_internal(dst,max_dst_size,c_src,c_src_size,dtable)
}

huf_decompress1x1_dctx_wksp :: proc "contextless" (dctx:[^]u32,dst:[^]u8,dst_size:int,c_src:[^]u8,c_src_size_in:int,workspace:[^]u32,wksp_size:int) -> (size:int,err:Error) {
    c_src_size:=c_src_size_in
    ip:=c_src
    h_size:=huf_read_dtable_x1_wksp(dctx,c_src,c_src_size,workspace,wksp_size) or_return
    if h_size>=c_src_size {return 0,.Src_Size_Wrong}
    ip=padd(ip,h_size)
    c_src_size-=h_size
    return huf_decompress1x1_using_dtable_internal(dst,dst_size,ip,c_src_size,dctx)
}

huf_decompress4x_using_dtable :: proc "contextless" (dst:[^]u8,max_dst_size:int,c_src:[^]u8,c_src_size:int,dtable:[^]u32) -> (size:int,err:Error) {
    dtd:=huf_get_dtable_desc(dtable)
    if dtd.table_type!=0 {return huf_decompress4x2_using_dtable_internal(dst,max_dst_size,c_src,c_src_size,dtable)}
    return huf_decompress4x1_using_dtable_internal(dst,max_dst_size,c_src,c_src_size,dtable)
}

huf_decompress4x_huf_only_wksp :: proc "contextless" (dctx:[^]u32,dst:[^]u8,dst_size:int,c_src:[^]u8,c_src_size:int,workspace:[^]u32,wksp_size:int) -> (size:int,err:Error) {
    if dst_size==0 {return 0,.Dst_Size_Too_Small}
    if c_src_size==0 {return 0,.Corruption_Detected}
    algo_nb:=huf_select_decoder(dst_size,c_src_size)
    if algo_nb!=0 {return huf_decompress4x2_dctx_wksp(dctx,dst,dst_size,c_src,c_src_size,workspace,wksp_size)}
    return huf_decompress4x1_dctx_wksp(dctx,dst,dst_size,c_src,c_src_size,workspace,wksp_size)
}
