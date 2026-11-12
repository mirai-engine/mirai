package zstd

import "base:intrinsics"

HUF_READ_STATS_WORKSPACE_SIZE_U32 :: FSE_DTABLE_HEADER_U32+(1<<6)+1+((HUF_TABLELOG_MAX*2+(1<<6)+8+3)/4)+(FSE_MAX_SYMBOL_VALUE+1)/2+1
HUF_READ_STATS_WORKSPACE_SIZE :: HUF_READ_STATS_WORKSPACE_SIZE_U32*size_of(u32)

@(private="file")
fse_read_ncount_body :: proc "contextless" (normalized_counter:[^]i16,max_sv_ptr,table_log_ptr:^u32,header_buffer:[^]u8,hb_size:int) -> (size:int,err:Error) #no_bounds_check {
    istart:=header_buffer
    iend:=padd(istart,hb_size)
    ip:=istart
    nb_bits,remaining,threshold,bit_count:i32
    bit_stream:u32
    charnum:u32
    max_sv1:=max_sv_ptr^+1
    previous0:=false

    if hb_size<8 {
        buffer:[8]u8
        intrinsics.mem_copy_non_overlapping(&buffer[0],header_buffer,hb_size)
        count_size:=fse_read_ncount_body(normalized_counter,max_sv_ptr,table_log_ptr,([^]u8)(&buffer[0]),8) or_return
        if count_size>hb_size {return 0,.Corruption_Detected}
        return count_size,.None
    }

    intrinsics.mem_zero(normalized_counter,int(max_sv_ptr^+1)*size_of(i16))
    bit_stream=read32(ip)
    nb_bits=i32(bit_stream&0xF)+FSE_MIN_TABLELOG
    if nb_bits>FSE_TABLELOG_ABSOLUTE_MAX {return 0,.Table_Log_Too_Large}
    bit_stream>>=4
    bit_count=4
    table_log_ptr^=u32(nb_bits)
    remaining=(1<<u32(nb_bits))+1
    threshold=1<<u32(nb_bits)
    nb_bits+=1

    for {
        if previous0 {
            repeats:=i32(ctz32(~bit_stream|0x80000000)>>1)
            for repeats>=12 {
                charnum+=3*12
                if uintptr(ip)<=uintptr(padd(iend,-7)) {
                    ip=padd(ip,3)
                } else {
                    bit_count-=i32(8*pdiff(padd(iend,-7),ip))
                    bit_count&=31
                    ip=padd(iend,-4)
                }
                bit_stream=read32(ip)>>u32(bit_count&31)
                repeats=i32(ctz32(~bit_stream|0x80000000)>>1)
            }
            charnum+=u32(3*repeats)
            bit_stream>>=u32(2*repeats)&31
            bit_count+=2*repeats

            charnum+=bit_stream&3
            bit_count+=2

            if charnum>=max_sv1 {break}

            if uintptr(ip)<=uintptr(padd(iend,-7)) || uintptr(padd(ip,int(bit_count>>3)))<=uintptr(padd(iend,-4)) {
                ip=padd(ip,int(bit_count>>3))
                bit_count&=7
            } else {
                bit_count-=i32(8*pdiff(padd(iend,-4),ip))
                bit_count&=31
                ip=padd(iend,-4)
            }
            bit_stream=read32(ip)>>u32(bit_count&31)
        }
        {
            max_value:=(2*threshold-1)-remaining
            count:i32

            if bit_stream&u32(threshold-1)<u32(max_value) {
                count=i32(bit_stream&u32(threshold-1))
                bit_count+=nb_bits-1
            } else {
                count=i32(bit_stream&u32(2*threshold-1))
                if count>=threshold {count-=max_value}
                bit_count+=nb_bits
            }

            count-=1
            if count>=0 {
                remaining-=count
            } else {
                remaining+=count
            }
            normalized_counter[charnum]=i16(count)
            charnum+=1
            previous0=count==0

            if remaining<threshold {
                if remaining<=1 {break}
                nb_bits=i32(highbit32(u32(remaining)))+1
                threshold=1<<u32(nb_bits-1)
            }
            if charnum>=max_sv1 {break}

            if uintptr(ip)<=uintptr(padd(iend,-7)) || uintptr(padd(ip,int(bit_count>>3)))<=uintptr(padd(iend,-4)) {
                ip=padd(ip,int(bit_count>>3))
                bit_count&=7
            } else {
                bit_count-=i32(8*pdiff(padd(iend,-4),ip))
                bit_count&=31
                ip=padd(iend,-4)
            }
            bit_stream=read32(ip)>>u32(bit_count&31)
        }
    }
    if remaining!=1 {return 0,.Corruption_Detected}
    if charnum>max_sv1 {return 0,.Max_Symbol_Value_Too_Small}
    if bit_count>32 {return 0,.Corruption_Detected}
    max_sv_ptr^=charnum-1

    ip=padd(ip,int((bit_count+7)>>3))
    return pdiff(ip,istart),.None
}

fse_read_ncount :: proc "contextless" (normalized_counter:[^]i16,max_sv_ptr,table_log_ptr:^u32,header_buffer:[^]u8,hb_size:int) -> (size:int,err:Error) {
    return fse_read_ncount_body(normalized_counter,max_sv_ptr,table_log_ptr,header_buffer,hb_size)
}

huf_read_stats :: proc "contextless" (huff_weight:[^]u8,hw_size:int,rank_stats:[^]u32,nb_symbols_ptr,table_log_ptr:^u32,src:[^]u8,src_size:int,workspace:[^]u32,wksp_size:int) -> (size:int,err:Error) #no_bounds_check {
    ip:=src
    if src_size==0 {return 0,.Src_Size_Wrong}
    i_size:=int(ip[0])
    o_size:int

    if i_size>=128 {
        o_size=i_size-127
        i_size=(o_size+1)/2
        if i_size+1>src_size {return 0,.Src_Size_Wrong}
        if o_size>=hw_size {return 0,.Corruption_Detected}
        ip=padd(ip,1)
        for n:=0;n<o_size;n+=2 {
            huff_weight[n]=ip[n/2]>>4
            huff_weight[n+1]=ip[n/2]&15
        }
    } else {
        if i_size+1>src_size {return 0,.Src_Size_Wrong}
        o_size=fse_decompress_wksp(huff_weight,hw_size-1,padd(ip,1),i_size,6,workspace,wksp_size) or_return
    }

    intrinsics.mem_zero(rank_stats,(HUF_TABLELOG_MAX+1)*size_of(u32))
    weight_total:u32
    for n in 0..<o_size {
        if huff_weight[n]>HUF_TABLELOG_MAX {return 0,.Corruption_Detected}
        rank_stats[huff_weight[n]]+=1
        weight_total+=(u32(1)<<huff_weight[n])>>1
    }
    if weight_total==0 {return 0,.Corruption_Detected}

    table_log:=highbit32(weight_total)+1
    if table_log>HUF_TABLELOG_MAX {return 0,.Corruption_Detected}
    table_log_ptr^=table_log
    {
        total:=u32(1)<<table_log
        rest:=total-weight_total
        verif:=u32(1)<<highbit32(rest)
        last_weight:=highbit32(rest)+1
        if verif!=rest {return 0,.Corruption_Detected}
        huff_weight[o_size]=u8(last_weight)
        rank_stats[last_weight]+=1
    }

    if rank_stats[1]<2 || rank_stats[1]&1!=0 {return 0,.Corruption_Detected}

    nb_symbols_ptr^=u32(o_size+1)
    return i_size+1,.None
}
