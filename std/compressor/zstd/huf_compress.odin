package zstd

import "base:intrinsics"

HUF_BLOCKSIZE_MAX :: 128*KB
HUF_CTABLEBOUND :: 129
HUF_CTABLE_WORKSPACE_SIZE_U32 :: (4*(HUF_SYMBOLVALUE_MAX+1))+192
HUF_CTABLE_WORKSPACE_SIZE :: HUF_CTABLE_WORKSPACE_SIZE_U32*size_of(u32)
HUF_OPTIMAL_DEPTH_THRESHOLD :: Strategy.BTUltra

Huf_Flag :: enum u32 {Optimal_Depth,Prefer_Repeat,Suspect_Uncompressible}
Huf_Flags :: bit_set[Huf_Flag;u32]

Huf_CTable_Header :: struct {table_log,max_symbol_value:u8}

@(private="file") Node_Elt :: struct {
    count:u32,
    parent:u16,
    byte:u8,
    nb_bits:u8,
}

@(private="file")
huf_align_up_workspace :: proc "contextless" (workspace:[^]u8,workspace_size_ptr:^int,align:int) -> [^]u8 {
    mask:=align-1
    rem:=int(uintptr(workspace))&mask
    add:=(align-rem)&mask
    aligned:=padd(workspace,add)
    if workspace_size_ptr^>=add {
        workspace_size_ptr^-=add
        return aligned
    }
    workspace_size_ptr^=0
    return nil
}

@(private="file") MAX_FSE_TABLELOG_FOR_HUFF_HEADER :: 6
@(private="file") HUF_WEIGHTS_CTABLE_U32 :: 1+(1<<(MAX_FSE_TABLELOG_FOR_HUFF_HEADER-1))+((HUF_TABLELOG_MAX+1)*2)
@(private="file") HUF_WEIGHTS_SCRATCH_U32 :: ((HUF_TABLELOG_MAX+2)+(1<<MAX_FSE_TABLELOG_FOR_HUFF_HEADER))/2+size_of(u64)/size_of(u32)

@(private="file") Huf_Compress_Weights_Wksp :: struct {
    ctable:[HUF_WEIGHTS_CTABLE_U32]u32,
    scratch_buffer:[HUF_WEIGHTS_SCRATCH_U32]u32,
    count:[HUF_TABLELOG_MAX+1]u32,
    norm:[HUF_TABLELOG_MAX+1]i16,
}

@(private="file")
huf_compress_weights :: proc "contextless" (dst:[^]u8,dst_size:int,weight_table:[^]u8,wt_size:int,workspace:[^]u8,workspace_size_in:int) -> (size:int,err:Error) {
    ostart:=dst
    op:=ostart
    oend:=padd(ostart,dst_size)

    max_symbol_value:=u32(HUF_TABLELOG_MAX)
    table_log:=u32(MAX_FSE_TABLELOG_FOR_HUFF_HEADER)
    workspace_size:=workspace_size_in
    wksp:=(^Huf_Compress_Weights_Wksp)(huf_align_up_workspace(workspace,&workspace_size,align_of(u32)))

    if workspace_size<size_of(Huf_Compress_Weights_Wksp) {return 0,.Generic}

    if wt_size<=1 {return 0,.None}

    max_count:=hist_count_simple(([^]u32)(&wksp.count),&max_symbol_value,weight_table,wt_size)
    if int(max_count)==wt_size {return 1,.None}
    if max_count==1 {return 0,.None}

    table_log=fse_optimal_table_log(table_log,wt_size,max_symbol_value)
    _=fse_normalize_count(([^]i16)(&wksp.norm),table_log,([^]u32)(&wksp.count),wt_size,max_symbol_value,false) or_return

    h_size:=fse_write_ncount(op,pdiff(oend,op),([^]i16)(&wksp.norm),max_symbol_value,table_log) or_return
    op=padd(op,h_size)

    _=fse_build_ctable_wksp(([^]u32)(&wksp.ctable),([^]i16)(&wksp.norm),max_symbol_value,table_log,([^]u8)(&wksp.scratch_buffer),size_of(wksp.scratch_buffer)) or_return
    c_size:=fse_compress_using_ctable(op,pdiff(oend,op),weight_table,wt_size,([^]u32)(&wksp.ctable)) or_return
    if c_size==0 {return 0,.None}
    op=padd(op,c_size)

    return pdiff(op,ostart),.None
}

@(private="file") huf_get_nb_bits :: #force_inline proc "contextless" (elt:u64) -> u64 {return elt&0xFF}
@(private="file") huf_get_nb_bits_fast :: #force_inline proc "contextless" (elt:u64) -> u64 {return elt}
@(private="file") huf_get_value :: #force_inline proc "contextless" (elt:u64) -> u64 {return elt&~u64(0xFF)}
@(private="file") huf_get_value_fast :: #force_inline proc "contextless" (elt:u64) -> u64 {return elt}
@(private="file") huf_set_nb_bits :: #force_inline proc "contextless" (elt:^u64,nb_bits:u64) {elt^=nb_bits}

@(private="file")
huf_set_value :: #force_inline proc "contextless" (elt:^u64,value:u64) {
    nb_bits:=huf_get_nb_bits(elt^)
    if nb_bits>0 {elt^|=value<<(64-nb_bits)}
}

huf_read_ctable_header :: #force_inline proc "contextless" (ctable:[^]u64) -> Huf_CTable_Header {
    return Huf_CTable_Header{u8(ctable[0]),u8(ctable[0]>>8)}
}

@(private="file")
huf_write_ctable_header :: #force_inline proc "contextless" (ctable:[^]u64,table_log,max_symbol_value:u32) {
    ctable[0]=u64(u8(table_log))|u64(u8(max_symbol_value))<<8
}

@(private="file") Huf_Write_CTable_Wksp :: struct {
    wksp:Huf_Compress_Weights_Wksp,
    bits_to_weight:[HUF_TABLELOG_MAX+1]u8,
    huff_weight:[HUF_SYMBOLVALUE_MAX]u8,
}

huf_write_ctable_wksp :: proc "contextless" (dst:[^]u8,max_dst_size:int,ctable:[^]u64,max_symbol_value,huff_log:u32,workspace:[^]u8,workspace_size_in:int) -> (size:int,err:Error) #no_bounds_check {
    ct:=ctable[1:]
    op:=dst
    workspace_size:=workspace_size_in
    wksp:=(^Huf_Write_CTable_Wksp)(huf_align_up_workspace(workspace,&workspace_size,align_of(u32)))

    if workspace_size<size_of(Huf_Write_CTable_Wksp) {return 0,.Generic}
    if max_symbol_value>HUF_SYMBOLVALUE_MAX {return 0,.Max_Symbol_Value_Too_Large}

    wksp.bits_to_weight[0]=0
    for n:=u32(1);n<huff_log+1;n+=1 {wksp.bits_to_weight[n]=u8(huff_log+1-n)}
    for n:=u32(0);n<max_symbol_value;n+=1 {wksp.huff_weight[n]=wksp.bits_to_weight[huf_get_nb_bits(ct[n])]}

    if max_dst_size<1 {return 0,.Dst_Size_Too_Small}
    h_size:=huf_compress_weights(padd(op,1),max_dst_size-1,([^]u8)(&wksp.huff_weight),int(max_symbol_value),([^]u8)(&wksp.wksp),size_of(wksp.wksp)) or_return
    if h_size>1 && h_size<int(max_symbol_value/2) {
        op[0]=u8(h_size)
        return h_size+1,.None
    }

    if max_symbol_value>(256-128) {return 0,.Generic}
    if int((max_symbol_value+1)/2)+1>max_dst_size {return 0,.Dst_Size_Too_Small}
    op[0]=u8(128+(max_symbol_value-1))
    wksp.huff_weight[max_symbol_value]=0
    for n:=u32(0);n<max_symbol_value;n+=2 {
        op[(n/2)+1]=wksp.huff_weight[n]<<4+wksp.huff_weight[n+1]
    }
    return int((max_symbol_value+1)/2)+1,.None
}

huf_get_nb_bits_from_ctable :: proc "contextless" (ctable:[^]u64,symbol_value:u32) -> u32 {
    ct:=ctable[1:]
    if symbol_value>u32(huf_read_ctable_header(ctable).max_symbol_value) {return 0}
    return u32(huf_get_nb_bits(ct[symbol_value]))
}

@(private="file")
huf_set_max_height :: proc "contextless" (huff_node:[^]Node_Elt,last_non_null,target_nb_bits:u32) -> u32 #no_bounds_check {
    largest_bits:=u32(huff_node[last_non_null].nb_bits)
    if largest_bits<=target_nb_bits {return largest_bits}

    {
        total_cost:=i32(0)
        base_cost:=u32(1)<<(largest_bits-target_nb_bits)
        n:=int(last_non_null)

        for u32(huff_node[n].nb_bits)>target_nb_bits {
            total_cost+=i32(base_cost-(u32(1)<<(largest_bits-u32(huff_node[n].nb_bits))))
            huff_node[n].nb_bits=u8(target_nb_bits)
            n-=1
        }
        for u32(huff_node[n].nb_bits)==target_nb_bits {n-=1}

        total_cost>>=(largest_bits-target_nb_bits)

        {
            NO_SYMBOL :: u32(0xF0F0F0F0)
            rank_last:[HUF_TABLELOG_MAX+2]u32=---
            for i in 0..<len(rank_last) {rank_last[i]=NO_SYMBOL}
            {
                current_nb_bits:=target_nb_bits
                for pos:=n;pos>=0;pos-=1 {
                    if u32(huff_node[pos].nb_bits)>=current_nb_bits {continue}
                    current_nb_bits=u32(huff_node[pos].nb_bits)
                    rank_last[target_nb_bits-current_nb_bits]=u32(pos)
                }
            }

            for total_cost>0 {
                n_bits_to_decrease:=highbit32(u32(total_cost))+1
                for ;n_bits_to_decrease>1;n_bits_to_decrease-=1 {
                    high_pos:=rank_last[n_bits_to_decrease]
                    low_pos:=rank_last[n_bits_to_decrease-1]
                    if high_pos==NO_SYMBOL {continue}
                    if low_pos==NO_SYMBOL {break}
                    high_total:=huff_node[high_pos].count
                    low_total:=2*huff_node[low_pos].count
                    if high_total<=low_total {break}
                }
                for n_bits_to_decrease<=HUF_TABLELOG_MAX && rank_last[n_bits_to_decrease]==NO_SYMBOL {
                    n_bits_to_decrease+=1
                }
                total_cost-=i32(1)<<(n_bits_to_decrease-1)
                huff_node[rank_last[n_bits_to_decrease]].nb_bits+=1

                if rank_last[n_bits_to_decrease-1]==NO_SYMBOL {
                    rank_last[n_bits_to_decrease-1]=rank_last[n_bits_to_decrease]
                }
                if rank_last[n_bits_to_decrease]==0 {
                    rank_last[n_bits_to_decrease]=NO_SYMBOL
                } else {
                    rank_last[n_bits_to_decrease]-=1
                    if u32(huff_node[rank_last[n_bits_to_decrease]].nb_bits)!=target_nb_bits-n_bits_to_decrease {
                        rank_last[n_bits_to_decrease]=NO_SYMBOL
                    }
                }
            }

            for total_cost<0 {
                if rank_last[1]==NO_SYMBOL {
                    for u32(huff_node[n].nb_bits)==target_nb_bits {n-=1}
                    huff_node[n+1].nb_bits-=1
                    rank_last[1]=u32(n+1)
                    total_cost+=1
                    continue
                }
                huff_node[rank_last[1]+1].nb_bits-=1
                rank_last[1]+=1
                total_cost+=1
            }
        }
    }
    return target_nb_bits
}

@(private="file") Rank_Pos :: struct {base,curr:u16}

@(private="file") RANK_POSITION_TABLE_SIZE :: 192
@(private="file") RANK_POSITION_MAX_COUNT_LOG :: 32
@(private="file") RANK_POSITION_LOG_BUCKETS_BEGIN :: (RANK_POSITION_TABLE_SIZE-1)-RANK_POSITION_MAX_COUNT_LOG-1
@(private="file") RANK_POSITION_DISTINCT_COUNT_CUTOFF :: RANK_POSITION_LOG_BUCKETS_BEGIN+7

@(private="file") Huf_Build_CTable_Wksp_Tables :: struct {
    huff_node_tbl:[2*(HUF_SYMBOLVALUE_MAX+1)]Node_Elt,
    rank_position:[RANK_POSITION_TABLE_SIZE]Rank_Pos,
}
#assert(HUF_CTABLE_WORKSPACE_SIZE==size_of(Huf_Build_CTable_Wksp_Tables))

@(private="file")
huf_get_index :: #force_inline proc "contextless" (count:u32) -> u32 {
    return count<RANK_POSITION_DISTINCT_COUNT_CUTOFF ? count : highbit32(count)+RANK_POSITION_LOG_BUCKETS_BEGIN
}

@(private="file")
huf_insertion_sort :: #force_inline proc "contextless" (huff_node_in:[^]Node_Elt,low,high:int) {
    size:=high-low+1
    huff_node:=huff_node_in[low:]
    for i:=1;i<size;i+=1 {
        key:=huff_node[i]
        j:=i-1
        for j>=0 && huff_node[j].count<key.count {
            huff_node[j+1]=huff_node[j]
            j-=1
        }
        huff_node[j+1]=key
    }
}

@(private="file")
huf_quick_sort_partition :: proc "contextless" (arr:[^]Node_Elt,low,high:int) -> int {
    pivot:=arr[high].count
    i:=low-1
    for j:=low;j<high;j+=1 {
        if arr[j].count>pivot {
            i+=1
            arr[i],arr[j]=arr[j],arr[i]
        }
    }
    arr[i+1],arr[high]=arr[high],arr[i+1]
    return i+1
}

@(private="file")
huf_simple_quick_sort :: proc "contextless" (arr:[^]Node_Elt,low_in,high_in:int) {
    INSERTION_SORT_THRESHOLD :: 8
    low,high:=low_in,high_in
    if high-low<INSERTION_SORT_THRESHOLD {
        huf_insertion_sort(arr,low,high)
        return
    }
    for low<high {
        idx:=huf_quick_sort_partition(arr,low,high)
        if idx-low<high-idx {
            huf_simple_quick_sort(arr,low,idx-1)
            low=idx+1
        } else {
            huf_simple_quick_sort(arr,idx+1,high)
            high=idx-1
        }
    }
}

@(private="file")
huf_sort :: proc "contextless" (huff_node:[^]Node_Elt,count:[^]u32,max_symbol_value:u32,rank_position:[^]Rank_Pos) {
    max_symbol_value1:=max_symbol_value+1

    intrinsics.mem_zero(rank_position,size_of(Rank_Pos)*RANK_POSITION_TABLE_SIZE)
    for n:=u32(0);n<max_symbol_value1;n+=1 {
        lower_rank:=huf_get_index(count[n])
        rank_position[lower_rank].base+=1
    }

    for n:=u32(RANK_POSITION_TABLE_SIZE-1);n>0;n-=1 {
        rank_position[n-1].base+=rank_position[n].base
        rank_position[n-1].curr=rank_position[n-1].base
    }

    for n:=u32(0);n<max_symbol_value1;n+=1 {
        c:=count[n]
        r:=huf_get_index(c)+1
        pos:=rank_position[r].curr
        rank_position[r].curr+=1
        huff_node[pos].count=c
        huff_node[pos].byte=u8(n)
    }

    for n:=u32(RANK_POSITION_DISTINCT_COUNT_CUTOFF);n<RANK_POSITION_TABLE_SIZE-1;n+=1 {
        bucket_size:=int(rank_position[n].curr)-int(rank_position[n].base)
        bucket_start_idx:=rank_position[n].base
        if bucket_size>1 {
            huf_simple_quick_sort(huff_node[bucket_start_idx:],0,bucket_size-1)
        }
    }
}

@(private="file") STARTNODE :: HUF_SYMBOLVALUE_MAX+1

@(private="file")
huf_build_tree :: proc "contextless" (huff_node0:[^]Node_Elt,max_symbol_value:u32) -> int {
    huff_node:=huff_node0[1:]
    node_nb:=STARTNODE

    non_null_rank:=int(max_symbol_value)
    for huff_node[non_null_rank].count==0 {non_null_rank-=1}
    low_s:=non_null_rank
    node_root:=node_nb+low_s-1
    low_n:=node_nb
    huff_node[node_nb].count=huff_node[low_s].count+huff_node[low_s-1].count
    huff_node[low_s].parent=u16(node_nb)
    huff_node[low_s-1].parent=u16(node_nb)
    node_nb+=1
    low_s-=2
    for n:=node_nb;n<=node_root;n+=1 {huff_node[n].count=u32(1)<<30}
    huff_node0[0].count=u32(1)<<31

    for node_nb<=node_root {
        n1,n2:int
        if huff_node[low_s].count<huff_node[low_n].count {n1=low_s;low_s-=1} else {n1=low_n;low_n+=1}
        if huff_node[low_s].count<huff_node[low_n].count {n2=low_s;low_s-=1} else {n2=low_n;low_n+=1}
        huff_node[node_nb].count=huff_node[n1].count+huff_node[n2].count
        huff_node[n1].parent=u16(node_nb)
        huff_node[n2].parent=u16(node_nb)
        node_nb+=1
    }

    huff_node[node_root].nb_bits=0
    for n:=node_root-1;n>=STARTNODE;n-=1 {
        huff_node[n].nb_bits=huff_node[huff_node[n].parent].nb_bits+1
    }
    for n:=0;n<=non_null_rank;n+=1 {
        huff_node[n].nb_bits=huff_node[huff_node[n].parent].nb_bits+1
    }
    return non_null_rank
}

@(private="file")
huf_build_ctable_from_tree :: proc "contextless" (ctable:[^]u64,huff_node:[^]Node_Elt,non_null_rank:int,max_symbol_value,max_nb_bits:u32) #no_bounds_check {
    ct:=ctable[1:]
    nb_per_rank:[HUF_TABLELOG_MAX+1]u16
    val_per_rank:[HUF_TABLELOG_MAX+1]u16
    alphabet_size:=int(max_symbol_value+1)
    for n:=0;n<=non_null_rank;n+=1 {nb_per_rank[huff_node[n].nb_bits]+=1}
    {
        min_v:=u16(0)
        for n:=int(max_nb_bits);n>0;n-=1 {
            val_per_rank[n]=min_v
            min_v+=nb_per_rank[n]
            min_v>>=1
        }
    }
    for n:=0;n<alphabet_size;n+=1 {huf_set_nb_bits(&ct[huff_node[n].byte],u64(huff_node[n].nb_bits))}
    for n:=0;n<alphabet_size;n+=1 {
        nb:=huf_get_nb_bits(ct[n])
        huf_set_value(&ct[n],u64(val_per_rank[nb]))
        val_per_rank[nb]+=1
    }
    huf_write_ctable_header(ctable,max_nb_bits,max_symbol_value)
}

// Returns the depth of the table.
huf_build_ctable_wksp :: proc "contextless" (ctable:[^]u64,count:[^]u32,max_symbol_value,max_nb_bits_in:u32,workspace:[^]u8,wksp_size_in:int) -> (size:int,err:Error) {
    wksp_size:=wksp_size_in
    max_nb_bits:=max_nb_bits_in
    wksp_tables:=(^Huf_Build_CTable_Wksp_Tables)(huf_align_up_workspace(workspace,&wksp_size,align_of(u32)))
    if wksp_size<size_of(Huf_Build_CTable_Wksp_Tables) {return 0,.Workspace_Too_Small}
    huff_node0:=([^]Node_Elt)(&wksp_tables.huff_node_tbl)
    huff_node:=huff_node0[1:]

    if max_nb_bits==0 {max_nb_bits=HUF_TABLELOG_DEFAULT}
    if max_symbol_value>HUF_SYMBOLVALUE_MAX {return 0,.Max_Symbol_Value_Too_Large}
    intrinsics.mem_zero(huff_node0,size_of(wksp_tables.huff_node_tbl))

    huf_sort(huff_node,count,max_symbol_value,([^]Rank_Pos)(&wksp_tables.rank_position))

    non_null_rank:=huf_build_tree(huff_node0,max_symbol_value)

    max_nb_bits=huf_set_max_height(huff_node,u32(non_null_rank),max_nb_bits)
    if max_nb_bits>HUF_TABLELOG_MAX {return 0,.Generic}

    huf_build_ctable_from_tree(ctable,huff_node,non_null_rank,max_symbol_value,max_nb_bits)
    return int(max_nb_bits),.None
}

huf_estimate_compressed_size :: proc "contextless" (ctable:[^]u64,count:[^]u32,max_symbol_value:u32) -> int {
    ct:=ctable[1:]
    nb_bits:=u64(0)
    for s:=0;s<=int(max_symbol_value);s+=1 {
        nb_bits+=huf_get_nb_bits(ct[s])*u64(count[s])
    }
    return int(nb_bits>>3)
}

huf_validate_ctable :: proc "contextless" (ctable:[^]u64,count:[^]u32,max_symbol_value:u32) -> bool {
    header:=huf_read_ctable_header(ctable)
    ct:=ctable[1:]
    bad:=false
    if u32(header.max_symbol_value)<max_symbol_value {return false}
    for s:=0;s<=int(max_symbol_value);s+=1 {
        bad|=(count[s]!=0)&&(huf_get_nb_bits(ct[s])==0)
    }
    return !bad
}

@(private="file") HUF_BITS_IN_CONTAINER :: 64

@(private="file") Huf_CStream :: struct {
    bit_container:[2]u64,
    bit_pos:[2]u64,
    start_ptr,ptr,end_ptr:[^]u8,
}

@(private="file")
huf_init_cstream :: proc "contextless" (bit_c:^Huf_CStream,start_ptr:[^]u8,dst_capacity:int) -> bool {
    bit_c^={}
    bit_c.start_ptr=start_ptr
    bit_c.ptr=start_ptr
    bit_c.end_ptr=padd(start_ptr,dst_capacity-size_of(u64))
    return dst_capacity>size_of(u64)
}

@(private="file")
huf_add_bits :: #force_inline proc "contextless" (bit_c:^Huf_CStream,elt:u64,idx:int,k_fast:bool) #no_bounds_check {
    bit_c.bit_container[idx]>>=huf_get_nb_bits(elt)
    bit_c.bit_container[idx]|=k_fast ? huf_get_value_fast(elt) : huf_get_value(elt)
    bit_c.bit_pos[idx]+=huf_get_nb_bits_fast(elt)
}

@(private="file")
huf_zero_index1 :: #force_inline proc "contextless" (bit_c:^Huf_CStream) {
    bit_c.bit_container[1]=0
    bit_c.bit_pos[1]=0
}

@(private="file")
huf_merge_index1 :: #force_inline proc "contextless" (bit_c:^Huf_CStream) {
    bit_c.bit_container[0]>>=(bit_c.bit_pos[1]&0xFF)
    bit_c.bit_container[0]|=bit_c.bit_container[1]
    bit_c.bit_pos[0]+=bit_c.bit_pos[1]
}

// The upper bits of bit_pos hold noise.
@(private="file")
huf_flush_bits :: #force_inline proc "contextless" (bit_c:^Huf_CStream,k_fast:bool) {
    nb_bits:=bit_c.bit_pos[0]&0xFF
    nb_bytes:=nb_bits>>3
    bit_container:=bit_c.bit_container[0]>>(HUF_BITS_IN_CONTAINER-nb_bits)
    bit_c.bit_pos[0]&=7
    write64(bit_c.ptr,bit_container)
    bit_c.ptr=padd(bit_c.ptr,int(nb_bytes))
    if !k_fast && uintptr(bit_c.ptr)>uintptr(bit_c.end_ptr) {bit_c.ptr=bit_c.end_ptr}
}

@(private="file")
huf_end_mark :: proc "contextless" () -> u64 {
    end_mark:u64
    huf_set_nb_bits(&end_mark,1)
    huf_set_value(&end_mark,1)
    return end_mark
}

@(private="file")
huf_close_cstream :: proc "contextless" (bit_c:^Huf_CStream) -> int {
    huf_add_bits(bit_c,huf_end_mark(),0,false)
    huf_flush_bits(bit_c,false)
    nb_bits:=bit_c.bit_pos[0]&0xFF
    if uintptr(bit_c.ptr)>=uintptr(bit_c.end_ptr) {return 0}
    return pdiff(bit_c.ptr,bit_c.start_ptr)+(nb_bits>0 ? 1 : 0)
}

@(private="file")
huf_encode_symbol :: #force_inline proc "contextless" (bit_c_ptr:^Huf_CStream,symbol:u32,ctable:[^]u64,idx:int,fast:bool) {
    huf_add_bits(bit_c_ptr,ctable[symbol],idx,fast)
}

@(private="file")
huf_compress1x_using_ctable_internal_body_loop :: #force_inline proc "contextless" (bit_c:^Huf_CStream,ip:[^]u8,src_size:int,ct:[^]u64,k_unroll:int,k_fast_flush,k_last_fast:bool) {
    n:=src_size
    rem:=n%k_unroll
    if rem>0 {
        for ;rem>0;rem-=1 {
            n-=1
            huf_encode_symbol(bit_c,u32(ip[n]),ct,0,false)
        }
        huf_flush_bits(bit_c,k_fast_flush)
    }

    if n%(2*k_unroll)!=0 {
        for u:=1;u<k_unroll;u+=1 {
            huf_encode_symbol(bit_c,u32(ip[n-u]),ct,0,true)
        }
        huf_encode_symbol(bit_c,u32(ip[n-k_unroll]),ct,0,k_last_fast)
        huf_flush_bits(bit_c,k_fast_flush)
        n-=k_unroll
    }

    for ;n>0;n-=2*k_unroll {
        for u:=1;u<k_unroll;u+=1 {
            huf_encode_symbol(bit_c,u32(ip[n-u]),ct,0,true)
        }
        huf_encode_symbol(bit_c,u32(ip[n-k_unroll]),ct,0,k_last_fast)
        huf_flush_bits(bit_c,k_fast_flush)
        huf_zero_index1(bit_c)
        for u:=1;u<k_unroll;u+=1 {
            huf_encode_symbol(bit_c,u32(ip[n-k_unroll-u]),ct,1,true)
        }
        huf_encode_symbol(bit_c,u32(ip[n-k_unroll-k_unroll]),ct,1,k_last_fast)
        huf_merge_index1(bit_c)
        huf_flush_bits(bit_c,k_fast_flush)
    }
}

@(private="file")
huf_tight_compress_bound :: proc "contextless" (src_size,table_log:int) -> int {
    return ((src_size*table_log)>>3)+8
}

// The size written, 0 if it did not fit.
@(private="file")
huf_compress1x_using_ctable_internal :: proc "contextless" (dst:[^]u8,dst_size:int,src:[^]u8,src_size:int,ctable:[^]u64) -> int {
    table_log:=u32(huf_read_ctable_header(ctable).table_log)
    ct:=ctable[1:]
    ip:=src
    ostart:=dst
    oend:=padd(ostart,dst_size)
    bit_c:Huf_CStream

    if dst_size<8 {return 0}
    if !huf_init_cstream(&bit_c,ostart,pdiff(oend,ostart)) {return 0}

    if dst_size<huf_tight_compress_bound(src_size,int(table_log)) || table_log>11 {
        huf_compress1x_using_ctable_internal_body_loop(&bit_c,ip,src_size,ct,4,false,false)
    } else {
        switch table_log {
        case 11: huf_compress1x_using_ctable_internal_body_loop(&bit_c,ip,src_size,ct,5,true,false)
        case 10: huf_compress1x_using_ctable_internal_body_loop(&bit_c,ip,src_size,ct,5,true,true)
        case 9: huf_compress1x_using_ctable_internal_body_loop(&bit_c,ip,src_size,ct,6,true,false)
        case 8: huf_compress1x_using_ctable_internal_body_loop(&bit_c,ip,src_size,ct,7,true,false)
        case 7: huf_compress1x_using_ctable_internal_body_loop(&bit_c,ip,src_size,ct,8,true,false)
        case: huf_compress1x_using_ctable_internal_body_loop(&bit_c,ip,src_size,ct,9,true,true)
        }
    }
    return huf_close_cstream(&bit_c)
}

huf_compress1x_using_ctable :: proc "contextless" (dst:[^]u8,dst_size:int,src:[^]u8,src_size:int,ctable:[^]u64) -> (size:int,err:Error) {
    return huf_compress1x_using_ctable_internal(dst,dst_size,src,src_size,ctable),.None
}

@(private="file")
huf_compress4x_using_ctable_internal :: proc "contextless" (dst:[^]u8,dst_size:int,src:[^]u8,src_size:int,ctable:[^]u64) -> int {
    segment_size:=(src_size+3)/4
    ip:=src
    iend:=padd(ip,src_size)
    ostart:=dst
    oend:=padd(ostart,dst_size)
    op:=ostart

    if dst_size<6+1+1+1+8 {return 0}
    if src_size<12 {return 0}
    op=padd(op,6)

    {
        c_size:=huf_compress1x_using_ctable_internal(op,pdiff(oend,op),ip,segment_size,ctable)
        if c_size==0 || c_size>65535 {return 0}
        write16(ostart,u16(c_size))
        op=padd(op,c_size)
    }

    ip=padd(ip,segment_size)
    {
        c_size:=huf_compress1x_using_ctable_internal(op,pdiff(oend,op),ip,segment_size,ctable)
        if c_size==0 || c_size>65535 {return 0}
        write16(padd(ostart,2),u16(c_size))
        op=padd(op,c_size)
    }

    ip=padd(ip,segment_size)
    {
        c_size:=huf_compress1x_using_ctable_internal(op,pdiff(oend,op),ip,segment_size,ctable)
        if c_size==0 || c_size>65535 {return 0}
        write16(padd(ostart,4),u16(c_size))
        op=padd(op,c_size)
    }

    ip=padd(ip,segment_size)
    {
        c_size:=huf_compress1x_using_ctable_internal(op,pdiff(oend,op),ip,pdiff(iend,ip),ctable)
        if c_size==0 || c_size>65535 {return 0}
        op=padd(op,c_size)
    }

    return pdiff(op,ostart)
}

huf_compress4x_using_ctable :: proc "contextless" (dst:[^]u8,dst_size:int,src:[^]u8,src_size:int,ctable:[^]u64) -> (size:int,err:Error) {
    return huf_compress4x_using_ctable_internal(dst,dst_size,src,src_size,ctable),.None
}

@(private="file") Huf_Nb_Streams :: enum {Single_Stream,Four_Streams}

@(private="file")
huf_compress_ctable_internal :: proc "contextless" (ostart,op_in,oend:[^]u8,src:[^]u8,src_size:int,nb_streams:Huf_Nb_Streams,ctable:[^]u64) -> int {
    c_size:=nb_streams==.Single_Stream ? huf_compress1x_using_ctable_internal(op_in,pdiff(oend,op_in),src,src_size,ctable) : huf_compress4x_using_ctable_internal(op_in,pdiff(oend,op_in),src,src_size,ctable)
    if c_size==0 {return 0}
    op:=padd(op_in,c_size)
    if pdiff(op,ostart)>=src_size-1 {return 0}
    return pdiff(op,ostart)
}

@(private="file") Huf_Compress_Wksps :: struct #raw_union {
    build_ctable_wksp:Huf_Build_CTable_Wksp_Tables,
    write_ctable_wksp:Huf_Write_CTable_Wksp,
    hist_wksp:[HIST_WKSP_SIZE_U32]u32,
}

@(private="file") Huf_Compress_Tables :: struct {
    count:[HUF_SYMBOLVALUE_MAX+1]u32,
    ctable:[HUF_SYMBOLVALUE_MAX+2]u64,
    wksps:Huf_Compress_Wksps,
}
#assert(size_of(Huf_Compress_Tables)+8<=HUF_WORKSPACE_SIZE)

@(private="file") SUSPECT_INCOMPRESSIBLE_SAMPLE_SIZE :: 4096
@(private="file") SUSPECT_INCOMPRESSIBLE_SAMPLE_RATIO :: 10

huf_cardinality :: proc "contextless" (count:[^]u32,max_symbol_value:u32) -> u32 {
    cardinality:=u32(0)
    for i:=u32(0);i<max_symbol_value+1;i+=1 {
        if count[i]!=0 {cardinality+=1}
    }
    return cardinality
}

huf_min_table_log :: proc "contextless" (symbol_cardinality:u32) -> u32 {
    return highbit32(symbol_cardinality)+1
}

// table is scratch space, not a result. workspace is of at least HUF_CTABLE_WORKSPACE_SIZE bytes.
huf_optimal_table_log :: proc "contextless" (max_table_log:u32,src_size:int,max_symbol_value:u32,workspace:[^]u8,wksp_size:int,table:[^]u64,count:[^]u32,flags:Huf_Flags) -> u32 {
    if .Optimal_Depth not_in flags {
        return fse_optimal_table_log_internal(max_table_log,src_size,max_symbol_value,1)
    }

    dst:=padd(workspace,size_of(Huf_Write_CTable_Wksp))
    dst_size:=wksp_size-size_of(Huf_Write_CTable_Wksp)
    symbol_cardinality:=huf_cardinality(count,max_symbol_value)
    min_table_log:=huf_min_table_log(symbol_cardinality)
    opt_size:=~u64(0)-1
    opt_log:=max_table_log

    for opt_log_guess:=min_table_log;opt_log_guess<=max_table_log;opt_log_guess+=1 {
        max_bits,build_err:=huf_build_ctable_wksp(table,count,max_symbol_value,opt_log_guess,workspace,wksp_size)
        if build_err!=.None {continue}

        if u32(max_bits)<opt_log_guess && opt_log_guess>min_table_log {break}

        h_size,write_err:=huf_write_ctable_wksp(dst,dst_size,table,max_symbol_value,u32(max_bits),workspace,wksp_size)
        if write_err!=.None {continue}

        new_size:=u64(huf_estimate_compressed_size(table,count,max_symbol_value)+h_size)

        if new_size>opt_size+1 {break}

        if new_size<opt_size {
            opt_size=new_size
            opt_log=opt_log_guess
        }
    }
    return opt_log
}

@(private="file")
huf_compress_internal :: proc "contextless" (dst:[^]u8,dst_size:int,src:[^]u8,src_size:int,max_symbol_value_in,huff_log_in:u32,nb_streams:Huf_Nb_Streams,workspace:[^]u8,wksp_size_in:int,old_huf_table:[^]u64,repeat:^Huf_Repeat,flags:Huf_Flags) -> (size:int,err:Error) {
    wksp_size:=wksp_size_in
    max_symbol_value:=max_symbol_value_in
    huff_log:=huff_log_in
    table:=(^Huf_Compress_Tables)(huf_align_up_workspace(workspace,&wksp_size,align_of(u64)))
    ostart:=dst
    oend:=padd(ostart,dst_size)
    op:=ostart

    if wksp_size<size_of(Huf_Compress_Tables) {return 0,.Workspace_Too_Small}
    if src_size==0 {return 0,.None}
    if dst_size==0 {return 0,.None}
    if src_size>HUF_BLOCKSIZE_MAX {return 0,.Src_Size_Wrong}
    if huff_log>HUF_TABLELOG_MAX {return 0,.Table_Log_Too_Large}
    if max_symbol_value>HUF_SYMBOLVALUE_MAX {return 0,.Max_Symbol_Value_Too_Large}
    if max_symbol_value==0 {max_symbol_value=HUF_SYMBOLVALUE_MAX}
    if huff_log==0 {huff_log=HUF_TABLELOG_DEFAULT}

    count:=([^]u32)(&table.count)
    ctable:=([^]u64)(&table.ctable)

    if .Prefer_Repeat in flags && repeat!=nil && repeat^==.Valid {
        return huf_compress_ctable_internal(ostart,op,oend,src,src_size,nb_streams,old_huf_table),.None
    }

    if .Suspect_Uncompressible in flags && src_size>=SUSPECT_INCOMPRESSIBLE_SAMPLE_SIZE*SUSPECT_INCOMPRESSIBLE_SAMPLE_RATIO {
        largest_total:=0
        {
            max_symbol_value_begin:=max_symbol_value
            largest_total+=int(hist_count_simple(count,&max_symbol_value_begin,src,SUSPECT_INCOMPRESSIBLE_SAMPLE_SIZE))
        }
        {
            max_symbol_value_end:=max_symbol_value
            largest_total+=int(hist_count_simple(count,&max_symbol_value_end,padd(src,src_size-SUSPECT_INCOMPRESSIBLE_SAMPLE_SIZE),SUSPECT_INCOMPRESSIBLE_SAMPLE_SIZE))
        }
        if largest_total<=((2*SUSPECT_INCOMPRESSIBLE_SAMPLE_SIZE)>>7)+4 {return 0,.None}
    }

    {
        largest:=hist_count_wksp(count,&max_symbol_value,src,src_size,([^]u8)(&table.wksps.hist_wksp),size_of(table.wksps.hist_wksp)) or_return
        if largest==src_size {ostart[0]=src[0];return 1,.None}
        if largest<=(src_size>>7)+4 {return 0,.None}
    }

    if repeat!=nil && repeat^==.Check && !huf_validate_ctable(old_huf_table,count,max_symbol_value) {
        repeat^=.None
    }
    if .Prefer_Repeat in flags && repeat!=nil && repeat^!=.None {
        return huf_compress_ctable_internal(ostart,op,oend,src,src_size,nb_streams,old_huf_table),.None
    }

    huff_log=huf_optimal_table_log(huff_log,src_size,max_symbol_value,([^]u8)(&table.wksps),size_of(table.wksps),ctable,count,flags)
    {
        max_bits:=huf_build_ctable_wksp(ctable,count,max_symbol_value,huff_log,([^]u8)(&table.wksps.build_ctable_wksp),size_of(table.wksps.build_ctable_wksp)) or_return
        huff_log=u32(max_bits)
    }

    {
        h_size:=huf_write_ctable_wksp(op,dst_size,ctable,max_symbol_value,huff_log,([^]u8)(&table.wksps.write_ctable_wksp),size_of(table.wksps.write_ctable_wksp)) or_return
        if repeat!=nil && repeat^!=.None {
            old_size:=huf_estimate_compressed_size(old_huf_table,count,max_symbol_value)
            new_size:=huf_estimate_compressed_size(ctable,count,max_symbol_value)
            if old_size<=h_size+new_size || h_size+12>=src_size {
                return huf_compress_ctable_internal(ostart,op,oend,src,src_size,nb_streams,old_huf_table),.None
            }
        }

        if h_size+12>=src_size {return 0,.None}
        op=padd(op,h_size)
        if repeat!=nil {repeat^=.None}
        if old_huf_table!=nil {
            intrinsics.mem_copy_non_overlapping(old_huf_table,ctable,size_of(table.ctable))
        }
    }
    return huf_compress_ctable_internal(ostart,op,oend,src,src_size,nb_streams,ctable),.None
}

// workspace is of at least HUF_WORKSPACE_SIZE bytes. Returns 0 when the input should be stored,
// 1 when it holds a single repeated byte.
huf_compress1x_repeat :: proc "contextless" (dst:[^]u8,dst_size:int,src:[^]u8,src_size:int,max_symbol_value,huff_log:u32,workspace:[^]u8,wksp_size:int,huf_table:[^]u64,repeat:^Huf_Repeat,flags:Huf_Flags) -> (size:int,err:Error) {
    return huf_compress_internal(dst,dst_size,src,src_size,max_symbol_value,huff_log,.Single_Stream,workspace,wksp_size,huf_table,repeat,flags)
}

// workspace is of at least HUF_WORKSPACE_SIZE bytes. Returns 0 when the input should be stored,
// 1 when it holds a single repeated byte.
huf_compress4x_repeat :: proc "contextless" (dst:[^]u8,dst_size:int,src:[^]u8,src_size:int,max_symbol_value,huff_log:u32,workspace:[^]u8,wksp_size:int,huf_table:[^]u64,repeat:^Huf_Repeat,flags:Huf_Flags) -> (size:int,err:Error) {
    return huf_compress_internal(dst,dst_size,src,src_size,max_symbol_value,huff_log,.Four_Streams,workspace,wksp_size,huf_table,repeat,flags)
}
