package zstd

import "base:runtime"

// One call, one contiguous source, at levels 3, 6 and 22.

MAX_LEVEL :: 22
// Match indices are 32-bit and are never rebased, so they must stay well below 4 GiB.
MAX_SOURCE_BYTES :: 3000*MB

@(private="file") WINDOW_LOG_RESIZE_MAX :: u64(1)<<(WINDOW_LOG_MAX-1)
@(private="file") HASH_LOG_MIN :: 6
@(private="file") HASH_LOG3_MAX :: 17
@(private="file") FRAME_HEADER_SIZE_MAX :: 18
@(private="file") MAX_NB_BLOCK_SPLITS :: 196
@(private="file") MIN_SEQUENCES_BLOCK_SPLITTING :: 300
@(private="file") SUSPECT_UNCOMPRESSIBLE_LITERAL_RATIO :: 20
@(private="file") RLE_MAX_LENGTH :: 25
@(private="file") HUF_OPTIMAL_DEPTH_STRATEGY :: Strategy.BTUltra
@(private="file") COMPRESS_LITERALS_SIZE_MIN :: 63
@(private="file") TMP_WORKSPACE_SIZE :: max(HUF_WORKSPACE_SIZE+(MAX_SEQ+2)*size_of(u32),SPLIT_BLOCK_WORKSPACE_SIZE)

@(private="file") Level_Row :: enum {L3,L6,L22}

// By size of the source: above 256 KiB, up to 256 KiB, up to 128 KiB, up to 16 KiB.
@(rodata,private="file") DEFAULT_PARAMETERS:=[4][Level_Row]Compression_Parameters{
    0={.L3={21,16,17,1,5,0,.DFast},.L6={21,18,19,3,5,4,.Lazy},.L22={27,27,25,9,3,999,.BTUltra2}},
    1={.L3={18,16,16,1,4,0,.DFast},.L6={18,18,19,3,5,4,.Lazy},.L22={18,19,19,13,3,999,.BTUltra2}},
    2={.L3={17,15,16,2,5,0,.DFast},.L6={17,16,17,3,4,4,.Lazy},.L22={17,18,17,11,3,999,.BTUltra2}},
    3={.L3={14,14,15,2,4,0,.DFast},.L6={14,14,14,4,4,8,.Lazy2},.L22={14,15,15,10,3,999,.BTUltra2}},
}

compress_bound :: proc "contextless" (src_size:int) -> int {
    if src_size<0 {return 0}
    return src_size+(src_size>>8)+(src_size<128*KB?(128*KB-src_size)>>11:0)
}

@(private="file")
Block_Split_Ctx :: struct {
    full_seq_store_chunk,first_half_seq_store,second_half_seq_store,curr_seq_store,next_seq_store:Seq_Store,
    partitions:[MAX_NB_BLOCK_SPLITS]u32,
    entropy_metadata:Entropy_CTables_Metadata,
}

@(private="file")
Compressor :: struct {
    c_params:Compression_Parameters,
    use_row_match_finder,post_block_splitter:Param_Switch,
    is_first_block:bool,
    block_size_max:int,
    seq_store:Seq_Store,
    ms:Match_State,
    prev_cblock,next_cblock:^Compressed_Block_State,
    tmp_workspace:[^]u8,
    tmp_wksp_size:int,
    split:Block_Split_Ctx,
    block_compressor:Block_Compressor,
}

@(private="file")
adjust_params :: proc "contextless" (table_params:Compression_Parameters,src_size:int) -> Compression_Parameters {
    p:=table_params
    if u64(src_size)<=WINDOW_LOG_RESIZE_MAX {
        t_size:=u32(src_size)
        src_log:=t_size<(1<<HASH_LOG_MIN) ? HASH_LOG_MIN : highbit32(t_size-1)+1
        if p.window_log>src_log {p.window_log=src_log}
    }
    window_log_now:=p.window_log
    cycle_log:=p.chain_log-(p.strategy>=.BTLazy2?1:0)
    if p.hash_log>window_log_now+1 {p.hash_log=window_log_now+1}
    if cycle_log>window_log_now {p.chain_log-=cycle_log-window_log_now}
    if p.window_log<WINDOW_LOG_ABSOLUTE_MIN {p.window_log=WINDOW_LOG_ABSOLUTE_MIN}
    return p
}

@(private="file")
row_match_finder_supported :: #force_inline proc "contextless" (strategy:Strategy) -> bool {return strategy>=.Greedy && strategy<=.Lazy2}

@(private="file")
row_match_finder_used :: #force_inline proc "contextless" (strategy:Strategy,mode:Param_Switch) -> bool {
    return row_match_finder_supported(strategy) && mode==.Enable
}

@(private="file")
select_block_compressor :: proc "contextless" (strategy:Strategy,row:Param_Switch) -> Block_Compressor {
    if row_match_finder_used(strategy,row) {
        #partial switch strategy {
        case .Greedy: return compress_block_greedy_row
        case .Lazy: return compress_block_lazy_row
        case .Lazy2: return compress_block_lazy2_row
        }
    }
    #partial switch strategy {
    case .DFast: return compress_block_double_fast
    case .Greedy: return compress_block_greedy
    case .Lazy: return compress_block_lazy
    case .Lazy2: return compress_block_lazy2
    case .BTOpt: return compress_block_btopt
    case .BTUltra: return compress_block_btultra
    case .BTUltra2: return compress_block_btultra2
    }
    return nil
}

@(private="file")
bitmix :: proc "contextless" (value,length:u64) -> u64 {
    val:=value
    val~=rotr64(val,49)~rotr64(val,24)
    val*=0x9FB21C651E98DF25
    val~=(val>>35)+length
    val*=0x9FB21C651E98DF25
    return val~(val>>28)
}

// Where the piece of the workspace starts, 64-aligned, and how far it reaches.
@(private="file")
carve :: proc "contextless" (cursor:^uintptr,size:int) -> rawptr {
    at:=(cursor^+63)&~uintptr(63)
    cursor^=at+uintptr(size)
    return rawptr(at)
}

@(private="file")
seq_to_codes :: proc "contextless" (store:^Seq_Store) {
    sequences:=store.sequences_start
    nb_seq:=int((uintptr(store.sequences)-uintptr(store.sequences_start))/size_of(Seq_Def))
    #no_bounds_check for u in 0..<nb_seq {
        store.ll_code[u]=u8(ll_code(u32(sequences[u].lit_length)))
        store.of_code[u]=u8(highbit32(sequences[u].off_base))
        store.ml_code[u]=u8(ml_code(u32(sequences[u].ml_base)))
    }
    if store.long_length_type==.Literal_Length {store.ll_code[store.long_length_pos]=MAX_LL}
    if store.long_length_type==.Match_Length {store.ml_code[store.long_length_pos]=MAX_ML}
}

@(private="file")
Symbol_Encoding_Stats :: struct {
    ll_type,of_type,ml_type:Symbol_Encoding_Type,
    size:int,
    last_count_size:int,
}

@(private="file")
build_sequences_statistics :: proc(store:^Seq_Store,nb_seq:int,prev:^Fse_CTables,next:^Fse_CTables,dst:[^]u8,dst_end:[^]u8,strategy:Strategy,count_workspace:[^]u32,entropy_workspace:[^]u8,entropy_wksp_size:int) -> (stats:Symbol_Encoding_Stats,err:Error) {
    ostart:=dst
    oend:=dst_end
    op:=ostart
    seq_to_codes(store)

    {
        max_value:=u32(MAX_LL)
        most_frequent:=hist_count_fast_wksp(count_workspace,&max_value,store.ll_code,nb_seq,entropy_workspace,entropy_wksp_size) or_return
        next.litlength_repeat_mode=prev.litlength_repeat_mode
        stats.ll_type=select_encoding_type(&next.litlength_repeat_mode,count_workspace,max_value,most_frequent,nb_seq,LL_FSE_LOG,raw_data(prev.litlength_ctable[:]),raw_data(LL_default_norm[:]),LL_DEFAULT_NORM_LOG,.Allowed,strategy)
        count_size:=build_ctable(op,pdiff(oend,op),raw_data(next.litlength_ctable[:]),LL_FSE_LOG,stats.ll_type,count_workspace,max_value,store.ll_code,nb_seq,raw_data(LL_default_norm[:]),LL_DEFAULT_NORM_LOG,MAX_LL,raw_data(prev.litlength_ctable[:]),size_of(prev.litlength_ctable),entropy_workspace,entropy_wksp_size) or_return
        if stats.ll_type==.Compressed {stats.last_count_size=count_size}
        op=padd(op,count_size)
    }
    {
        max_value:=u32(MAX_OFF)
        most_frequent:=hist_count_fast_wksp(count_workspace,&max_value,store.of_code,nb_seq,entropy_workspace,entropy_wksp_size) or_return
        policy:Default_Policy=max_value<=DEFAULT_MAX_OFF ? .Allowed : .Disallowed
        next.offcode_repeat_mode=prev.offcode_repeat_mode
        stats.of_type=select_encoding_type(&next.offcode_repeat_mode,count_workspace,max_value,most_frequent,nb_seq,OFF_FSE_LOG,raw_data(prev.offcode_ctable[:]),raw_data(OF_default_norm[:]),OF_DEFAULT_NORM_LOG,policy,strategy)
        count_size:=build_ctable(op,pdiff(oend,op),raw_data(next.offcode_ctable[:]),OFF_FSE_LOG,stats.of_type,count_workspace,max_value,store.of_code,nb_seq,raw_data(OF_default_norm[:]),OF_DEFAULT_NORM_LOG,DEFAULT_MAX_OFF,raw_data(prev.offcode_ctable[:]),size_of(prev.offcode_ctable),entropy_workspace,entropy_wksp_size) or_return
        if stats.of_type==.Compressed {stats.last_count_size=count_size}
        op=padd(op,count_size)
    }
    {
        max_value:=u32(MAX_ML)
        most_frequent:=hist_count_fast_wksp(count_workspace,&max_value,store.ml_code,nb_seq,entropy_workspace,entropy_wksp_size) or_return
        next.matchlength_repeat_mode=prev.matchlength_repeat_mode
        stats.ml_type=select_encoding_type(&next.matchlength_repeat_mode,count_workspace,max_value,most_frequent,nb_seq,ML_FSE_LOG,raw_data(prev.matchlength_ctable[:]),raw_data(ML_default_norm[:]),ML_DEFAULT_NORM_LOG,.Allowed,strategy)
        count_size:=build_ctable(op,pdiff(oend,op),raw_data(next.matchlength_ctable[:]),ML_FSE_LOG,stats.ml_type,count_workspace,max_value,store.ml_code,nb_seq,raw_data(ML_default_norm[:]),ML_DEFAULT_NORM_LOG,MAX_ML,raw_data(prev.matchlength_ctable[:]),size_of(prev.matchlength_ctable),entropy_workspace,entropy_wksp_size) or_return
        if stats.ml_type==.Compressed {stats.last_count_size=count_size}
        op=padd(op,count_size)
    }
    stats.size=pdiff(op,ostart)
    return stats,.None
}

@(private="file")
entropy_compress_seq_store_internal :: proc(dst:[^]u8,dst_capacity:int,literals:[^]u8,lit_size:int,store:^Seq_Store,prev:^Entropy_CTables,next:^Entropy_CTables,strategy:Strategy,workspace:[^]u8,wksp_size:int) -> (size:int,err:Error) {
    count:=([^]u32)(workspace)
    entropy_workspace:=padd(workspace,(MAX_SEQ+1)*size_of(u32))
    entropy_wksp_size:=wksp_size-(MAX_SEQ+1)*size_of(u32)
    nb_seq:=int((uintptr(store.sequences)-uintptr(store.sequences_start))/size_of(Seq_Def))
    ostart:=dst
    oend:=padd(ostart,dst_capacity)
    op:=ostart
    last_count_size:=0
    {
        suspect:=nb_seq==0 || lit_size/nb_seq>=SUSPECT_UNCOMPRESSIBLE_LITERAL_RATIO
        c_size:=compress_literals(op,dst_capacity,literals,lit_size,entropy_workspace,entropy_wksp_size,&prev.huf,&next.huf,strategy,false,suspect) or_return
        op=padd(op,c_size)
    }
    if pdiff(oend,op)<4 {return 0,.Dst_Size_Too_Small}
    if nb_seq<128 {
        op[0]=u8(nb_seq)
        op=padd(op,1)
    } else if nb_seq<LONG_NB_SEQ {
        op[0]=u8((nb_seq>>8)+0x80)
        op[1]=u8(nb_seq)
        op=padd(op,2)
    } else {
        op[0]=0xFF
        write16(padd(op,1),u16(nb_seq-LONG_NB_SEQ))
        op=padd(op,3)
    }
    if nb_seq==0 {
        next.fse=prev.fse
        return pdiff(op,ostart),.None
    }
    {
        seq_head:=op
        op=padd(op,1)
        stats:=build_sequences_statistics(store,nb_seq,&prev.fse,&next.fse,op,oend,strategy,count,entropy_workspace,entropy_wksp_size) or_return
        seq_head[0]=u8(u32(stats.ll_type)<<6+u32(stats.of_type)<<4+u32(stats.ml_type)<<2)
        last_count_size=stats.last_count_size
        op=padd(op,stats.size)
    }
    {
        bitstream_size:=encode_sequences(op,pdiff(oend,op),raw_data(next.fse.matchlength_ctable[:]),store.ml_code,raw_data(next.fse.offcode_ctable[:]),store.of_code,raw_data(next.fse.litlength_ctable[:]),store.ll_code,store.sequences_start,nb_seq,false) or_return
        op=padd(op,bitstream_size)
        // Old decoders refuse a bitstream this short: such a block is stored raw.
        if last_count_size!=0 && last_count_size+bitstream_size<4 {return 0,.None}
    }
    return pdiff(op,ostart),.None
}

@(private="file")
entropy_compress_seq_store :: proc(store:^Seq_Store,prev:^Entropy_CTables,next:^Entropy_CTables,strategy:Strategy,dst:[^]u8,dst_capacity:int,src_size:int,workspace:[^]u8,wksp_size:int) -> (size:int,err:Error) {
    c_size,failure:=entropy_compress_seq_store_internal(dst,dst_capacity,store.lit_start,pdiff(store.lit,store.lit_start),store,prev,next,strategy,workspace,wksp_size)
    if failure!=nil {
        if failure==.Dst_Size_Too_Small && src_size<=dst_capacity {return 0,.None}
        return 0,failure
    }
    if c_size==0 {return 0,.None}
    max_c_size:=src_size-min_gain(src_size,strategy)
    if c_size>=max_c_size {return 0,.None}
    return c_size,.None
}

@(private="file") Build_Seq_Store :: enum {Compress,No_Compress}

@(private="file")
store_last_literals :: proc "contextless" (store:^Seq_Store,anchor:[^]u8,last_ll_size:int) {
    copy_bytes(store.lit,anchor,last_ll_size)
    store.lit=padd(store.lit,last_ll_size)
}

@(private="file")
build_seq_store :: proc "contextless" (zc:^Compressor,src:[^]u8,src_size:int) -> Build_Seq_Store {
    ms:=&zc.ms
    if src_size<MIN_CBLOCK_SIZE+BLOCK_HEADER_SIZE+1+1 {return .No_Compress}
    reset_seq_store(&zc.seq_store)
    ms.opt.literal_compression_mode=.Auto
    {
        curr:=u32(pdiff(src,ms.window.base))
        if curr>ms.next_to_update+384 {
            ms.next_to_update=curr-min(192,curr-ms.next_to_update-384)
        }
    }
    zc.next_cblock.rep=zc.prev_cblock.rep
    last_ll_size:=zc.block_compressor(ms,&zc.seq_store,&zc.next_cblock.rep,src,src_size)
    store_last_literals(&zc.seq_store,padd(src,src_size-last_ll_size),last_ll_size)
    return .Compress
}

@(private="file")
is_rle :: proc "contextless" (src:[^]u8,length:int) -> bool {
    value:=src[0]
    value_st:=u64(value)*0x0101010101010101
    unroll_size:=8*4
    unroll_mask:=unroll_size-1
    prefix_length:=length&unroll_mask
    if length==1 {return true}
    if prefix_length!=0 && count(padd(src,1),src,padd(src,prefix_length))!=prefix_length-1 {return false}
    for i:=prefix_length;i!=length;i+=unroll_size {
        for u:=0;u<unroll_size;u+=8 {
            if read64(padd(src,i+u))!=value_st {return false}
        }
    }
    return true
}

@(private="file")
confirm_repcodes_and_entropy_tables :: proc "contextless" (zc:^Compressor) {
    zc.prev_cblock,zc.next_cblock=zc.next_cblock,zc.prev_cblock
}

@(private="file")
write_block_header :: proc "contextless" (op:[^]u8,c_size,block_size:int,last_block:u32) {
    header:=c_size==1 ? last_block+u32(Block_Type.RLE)<<1+u32(block_size)<<3 : last_block+u32(Block_Type.Compressed)<<1+u32(c_size)<<3
    write24(op,header)
}

@(private="file")
build_block_entropy_stats_literals :: proc(src:[^]u8,src_size:int,prev_huf,next_huf:^Huf_CTables,huf_metadata:^Huf_CTables_Metadata,workspace:[^]u8,wksp_size:int,huf_optimal_depth:bool) -> (size:int,err:Error) {
    count_wksp:=([^]u32)(workspace)
    count_wksp_size:=(HUF_SYMBOLVALUE_MAX+1)*size_of(u32)
    node_wksp:=padd(workspace,count_wksp_size)
    node_wksp_size:=pdiff(padd(workspace,wksp_size),node_wksp)
    max_symbol_value:=u32(HUF_SYMBOLVALUE_MAX)
    huff_log:=u32(LIT_HUF_LOG)
    repeat:=prev_huf.repeat_mode
    flags:Huf_Flags
    if huf_optimal_depth {flags+={.Optimal_Depth}}

    next_huf^=prev_huf^

    {
        min_lit_size:=prev_huf.repeat_mode==.Valid ? 6 : COMPRESS_LITERALS_SIZE_MIN
        if src_size<=min_lit_size {
            huf_metadata.h_type=.Basic
            return 0,.None
        }
    }
    {
        largest:=hist_count_wksp(count_wksp,&max_symbol_value,src,src_size,workspace,wksp_size) or_return
        if largest==src_size {
            huf_metadata.h_type=.RLE
            return 0,.None
        }
        if largest<=(src_size>>7)+4 {
            huf_metadata.h_type=.Basic
            return 0,.None
        }
    }
    if repeat==.Check && !huf_validate_ctable(raw_data(prev_huf.ctable[:]),count_wksp,max_symbol_value) {repeat=.None}
    next_huf.ctable={}
    huff_log=huf_optimal_table_log(huff_log,src_size,max_symbol_value,node_wksp,node_wksp_size,raw_data(next_huf.ctable[:]),count_wksp,flags)
    {
        max_bits:=huf_build_ctable_wksp(raw_data(next_huf.ctable[:]),count_wksp,max_symbol_value,huff_log,node_wksp,node_wksp_size) or_return
        huff_log=u32(max_bits)
    }
    new_c_size:=huf_estimate_compressed_size(raw_data(next_huf.ctable[:]),count_wksp,max_symbol_value)
    h_size:=huf_write_ctable_wksp(raw_data(huf_metadata.huf_des_buffer[:]),size_of(huf_metadata.huf_des_buffer),raw_data(next_huf.ctable[:]),max_symbol_value,huff_log,node_wksp,node_wksp_size) or_return
    if repeat!=.None {
        old_c_size:=huf_estimate_compressed_size(raw_data(prev_huf.ctable[:]),count_wksp,max_symbol_value)
        if old_c_size<src_size && (old_c_size<=h_size+new_c_size || h_size+12>=src_size) {
            next_huf^=prev_huf^
            huf_metadata.h_type=.Repeat
            return 0,.None
        }
    }
    if new_c_size+h_size>=src_size {
        next_huf^=prev_huf^
        huf_metadata.h_type=.Basic
        return 0,.None
    }
    huf_metadata.h_type=.Compressed
    next_huf.repeat_mode=.Check
    return h_size,.None
}

@(private="file")
build_block_entropy_stats_sequences :: proc(store:^Seq_Store,prev:^Fse_CTables,next:^Fse_CTables,strategy:Strategy,metadata:^Fse_CTables_Metadata,workspace:[^]u8,wksp_size:int) -> (size:int,err:Error) {
    nb_seq:=int((uintptr(store.sequences)-uintptr(store.sequences_start))/size_of(Seq_Def))
    ostart:=raw_data(metadata.fse_tables_buffer[:])
    oend:=padd(ostart,size_of(metadata.fse_tables_buffer))
    count_workspace:=([^]u32)(workspace)
    entropy_workspace:=padd(workspace,(MAX_SEQ+1)*size_of(u32))
    entropy_workspace_size:=wksp_size-(MAX_SEQ+1)*size_of(u32)
    stats:Symbol_Encoding_Stats
    if nb_seq!=0 {
        stats=build_sequences_statistics(store,nb_seq,prev,next,ostart,oend,strategy,count_workspace,entropy_workspace,entropy_workspace_size) or_return
    } else {
        stats={.Basic,.Basic,.Basic,0,0}
        next.litlength_repeat_mode=.None
        next.offcode_repeat_mode=.None
        next.matchlength_repeat_mode=.None
    }
    metadata.ll_type=stats.ll_type
    metadata.of_type=stats.of_type
    metadata.ml_type=stats.ml_type
    metadata.last_count_size=stats.last_count_size
    return stats.size,.None
}

@(private="file")
build_block_entropy_stats :: proc(store:^Seq_Store,prev:^Entropy_CTables,next:^Entropy_CTables,strategy:Strategy,metadata:^Entropy_CTables_Metadata,workspace:[^]u8,wksp_size:int) -> Error {
    lit_size:=pdiff(store.lit,store.lit_start)
    metadata.huf_metadata.huf_des_size=build_block_entropy_stats_literals(store.lit_start,lit_size,&prev.huf,&next.huf,&metadata.huf_metadata,workspace,wksp_size,strategy>=HUF_OPTIMAL_DEPTH_STRATEGY) or_return
    metadata.fse_metadata.fse_tables_size=build_block_entropy_stats_sequences(store,&prev.fse,&next.fse,strategy,&metadata.fse_metadata,workspace,wksp_size) or_return
    return .None
}

@(private="file")
estimate_block_size_literal :: proc(literals:[^]u8,lit_size:int,huf:^Huf_CTables,metadata:^Huf_CTables_Metadata,workspace:[^]u8,wksp_size:int,write_entropy:bool) -> int {
    count_wksp:=([^]u32)(workspace)
    max_symbol_value:=u32(HUF_SYMBOLVALUE_MAX)
    header_size:=3+(lit_size>=1*KB?1:0)+(lit_size>=16*KB?1:0)
    single_stream:=lit_size<256
    #partial switch metadata.h_type {
    case .Basic: return lit_size
    case .RLE: return 1
    case .Compressed,.Repeat:
        _,failure:=hist_count_wksp(count_wksp,&max_symbol_value,literals,lit_size,workspace,wksp_size)
        if failure!=nil {return lit_size}
        estimate:=huf_estimate_compressed_size(raw_data(huf.ctable[:]),count_wksp,max_symbol_value)
        if write_entropy {estimate+=metadata.huf_des_size}
        if !single_stream {estimate+=6}
        return estimate+header_size
    }
    return 0
}

@(private="file")
estimate_block_size_symbol_type :: proc(type:Symbol_Encoding_Type,code_table:[^]u8,nb_seq:int,max_code:u32,fse_ctable:[^]u32,additional_bits:[^]u8,default_norm:[^]i16,default_norm_log,default_max:u32,workspace:[^]u8,wksp_size:int) -> int {
    count_wksp:=([^]u32)(workspace)
    ctp:=code_table
    ct_end:=padd(code_table,nb_seq)
    estimate_in_bits:=0
    max_value:=max_code
    hist_count_fast_wksp(count_wksp,&max_value,code_table,nb_seq,workspace,wksp_size)
    #partial switch type {
    case .Basic: estimate_in_bits=cross_entropy_cost(default_norm,default_norm_log,count_wksp,max_value)
    case .RLE: estimate_in_bits=0
    case .Compressed,.Repeat:
        cost,failure:=zstd_fse_bit_cost(fse_ctable,count_wksp,max_value)
        if failure!=nil {return nb_seq*10}
        estimate_in_bits=cost
    }
    for uintptr(ctp)<uintptr(ct_end) {
        if additional_bits!=nil {estimate_in_bits+=int(additional_bits[ctp[0]])} else {estimate_in_bits+=int(ctp[0])}
        ctp=padd(ctp,1)
    }
    return estimate_in_bits>>3
}

@(private="file")
estimate_block_size_sequences :: proc(of_code_table,ll_code_table,ml_code_table:[^]u8,nb_seq:int,fse:^Fse_CTables,metadata:^Fse_CTables_Metadata,workspace:[^]u8,wksp_size:int,write_entropy:bool) -> int {
    header_size:=1+1+(nb_seq>=128?1:0)+(nb_seq>=LONG_NB_SEQ?1:0)
    estimate:=0
    estimate+=estimate_block_size_symbol_type(metadata.of_type,of_code_table,nb_seq,MAX_OFF,raw_data(fse.offcode_ctable[:]),nil,raw_data(OF_default_norm[:]),OF_DEFAULT_NORM_LOG,DEFAULT_MAX_OFF,workspace,wksp_size)
    estimate+=estimate_block_size_symbol_type(metadata.ll_type,ll_code_table,nb_seq,MAX_LL,raw_data(fse.litlength_ctable[:]),raw_data(LL_bits[:]),raw_data(LL_default_norm[:]),LL_DEFAULT_NORM_LOG,MAX_LL,workspace,wksp_size)
    estimate+=estimate_block_size_symbol_type(metadata.ml_type,ml_code_table,nb_seq,MAX_ML,raw_data(fse.matchlength_ctable[:]),raw_data(ML_bits[:]),raw_data(ML_default_norm[:]),ML_DEFAULT_NORM_LOG,MAX_ML,workspace,wksp_size)
    if write_entropy {estimate+=metadata.fse_tables_size}
    return estimate+header_size
}

@(private="file")
build_entropy_statistics_and_estimate_sub_block_size :: proc(store:^Seq_Store,zc:^Compressor) -> (estimate:int,err:Error) {
    metadata:=&zc.split.entropy_metadata
    build_block_entropy_stats(store,&zc.prev_cblock.entropy,&zc.next_cblock.entropy,zc.c_params.strategy,metadata,zc.tmp_workspace,zc.tmp_wksp_size) or_return
    lit_size:=pdiff(store.lit,store.lit_start)
    nb_seq:=int((uintptr(store.sequences)-uintptr(store.sequences_start))/size_of(Seq_Def))
    literals_size:=estimate_block_size_literal(store.lit_start,lit_size,&zc.next_cblock.entropy.huf,&metadata.huf_metadata,zc.tmp_workspace,zc.tmp_wksp_size,metadata.huf_metadata.h_type==.Compressed)
    seq_size:=estimate_block_size_sequences(store.of_code,store.ll_code,store.ml_code,nb_seq,&zc.next_cblock.entropy.fse,&metadata.fse_metadata,zc.tmp_workspace,zc.tmp_wksp_size,true)
    return seq_size+literals_size+BLOCK_HEADER_SIZE,.None
}

@(private="file")
count_seq_store_literals_bytes :: proc "contextless" (store:^Seq_Store) -> int {
    bytes:=0
    nb_seqs:=int((uintptr(store.sequences)-uintptr(store.sequences_start))/size_of(Seq_Def))
    for i in 0..<nb_seqs {
        bytes+=int(store.sequences_start[i].lit_length)
        if u32(i)==store.long_length_pos && store.long_length_type==.Literal_Length {bytes+=0x10000}
    }
    return bytes
}

@(private="file")
count_seq_store_match_bytes :: proc "contextless" (store:^Seq_Store) -> int {
    bytes:=0
    nb_seqs:=int((uintptr(store.sequences)-uintptr(store.sequences_start))/size_of(Seq_Def))
    for i in 0..<nb_seqs {
        bytes+=int(store.sequences_start[i].ml_base)+MINMATCH
        if u32(i)==store.long_length_pos && store.long_length_type==.Match_Length {bytes+=0x10000}
    }
    return bytes
}

@(private="file")
derive_seq_store_chunk :: proc "contextless" (result,original:^Seq_Store,start_idx,end_idx:int) {
    result^=original^
    if start_idx>0 {
        result.sequences=original.sequences_start[start_idx:]
        result.lit_start=padd(result.lit_start,count_seq_store_literals_bytes(result))
    }
    if original.long_length_type!=.None {
        if original.long_length_pos<u32(start_idx) || original.long_length_pos>u32(end_idx) {
            result.long_length_type=.None
        } else {
            result.long_length_pos-=u32(start_idx)
        }
    }
    result.sequences_start=original.sequences_start[start_idx:]
    result.sequences=original.sequences_start[end_idx:]
    if end_idx!=int((uintptr(original.sequences)-uintptr(original.sequences_start))/size_of(Seq_Def)) {
        result.lit=padd(result.lit_start,count_seq_store_literals_bytes(result))
    }
    result.ll_code=padd(result.ll_code,start_idx)
    result.ml_code=padd(result.ml_code,start_idx)
    result.of_code=padd(result.of_code,start_idx)
}

@(private="file")
resolve_repcode_to_raw_offset :: proc "contextless" (rep:^[REP_NUM]u32,off_base,ll0:u32) -> u32 {
    adjusted:=offbase_to_repcode(off_base)-1+ll0
    if adjusted==REP_NUM {return rep[0]-1}
    return rep[adjusted]
}

@(private="file")
seq_store_resolve_off_codes :: proc "contextless" (d_rep,c_rep:^[REP_NUM]u32,store:^Seq_Store,nb_seq:u32) {
    long_lit_len_idx:=store.long_length_type==.Literal_Length ? store.long_length_pos : nb_seq
    for idx in 0..<nb_seq {
        seq:=&store.sequences_start[idx]
        ll0:=u32(seq.lit_length==0 && idx!=long_lit_len_idx ? 1 : 0)
        off_base:=seq.off_base
        if offbase_is_repcode(off_base) {
            d_raw_offset:=resolve_repcode_to_raw_offset(d_rep,off_base,ll0)
            c_raw_offset:=resolve_repcode_to_raw_offset(c_rep,off_base,ll0)
            if d_raw_offset!=c_raw_offset {seq.off_base=offset_to_offbase(c_raw_offset)}
        }
        update_rep(d_rep,seq.off_base,ll0)
        update_rep(c_rep,off_base,ll0)
    }
}

@(private="file")
compress_seq_store_single_block :: proc(zc:^Compressor,store:^Seq_Store,d_rep,c_rep:^[REP_NUM]u32,dst:[^]u8,dst_capacity:int,src:[^]u8,src_size:int,last_block:u32,is_partition:bool) -> (size:int,err:Error) {
    op:=dst
    ip:=src
    d_rep_original:=d_rep^
    if is_partition {seq_store_resolve_off_codes(d_rep,c_rep,store,u32((uintptr(store.sequences)-uintptr(store.sequences_start))/size_of(Seq_Def)))}
    if dst_capacity<BLOCK_HEADER_SIZE {return 0,.Dst_Size_Too_Small}
    c_seqs_size:=entropy_compress_seq_store(store,&zc.prev_cblock.entropy,&zc.next_cblock.entropy,zc.c_params.strategy,padd(op,BLOCK_HEADER_SIZE),dst_capacity-BLOCK_HEADER_SIZE,src_size,zc.tmp_workspace,zc.tmp_wksp_size) or_return
    if !zc.is_first_block && c_seqs_size<RLE_MAX_LENGTH && is_rle(src,src_size) {c_seqs_size=1}
    c_size:int
    if c_seqs_size==0 {
        c_size=no_compress_block(op,dst_capacity,ip,src_size,last_block) or_return
        d_rep^=d_rep_original
    } else if c_seqs_size==1 {
        c_size=rle_compress_block(op,dst_capacity,ip[0],src_size,last_block) or_return
        d_rep^=d_rep_original
    } else {
        confirm_repcodes_and_entropy_tables(zc)
        write_block_header(op,c_seqs_size,src_size,last_block)
        c_size=BLOCK_HEADER_SIZE+c_seqs_size
    }
    if zc.prev_cblock.entropy.fse.offcode_repeat_mode==.Valid {zc.prev_cblock.entropy.fse.offcode_repeat_mode=.Check}
    return c_size,.None
}

@(private="file") Seq_Store_Splits :: struct {split_locations:[^]u32,idx:int}

@(private="file")
derive_block_splits_helper :: proc(splits:^Seq_Store_Splits,start_idx,end_idx:int,zc:^Compressor,orig:^Seq_Store) {
    full:=&zc.split.full_seq_store_chunk
    first:=&zc.split.first_half_seq_store
    second:=&zc.split.second_half_seq_store
    mid_idx:=(start_idx+end_idx)/2
    if end_idx-start_idx<MIN_SEQUENCES_BLOCK_SPLITTING || splits.idx>=MAX_NB_BLOCK_SPLITS {return}
    derive_seq_store_chunk(full,orig,start_idx,end_idx)
    derive_seq_store_chunk(first,orig,start_idx,mid_idx)
    derive_seq_store_chunk(second,orig,mid_idx,end_idx)
    original_size,e0:=build_entropy_statistics_and_estimate_sub_block_size(full,zc)
    first_size,e1:=build_entropy_statistics_and_estimate_sub_block_size(first,zc)
    second_size,e2:=build_entropy_statistics_and_estimate_sub_block_size(second,zc)
    if e0!=nil || e1!=nil || e2!=nil {return}
    if first_size+second_size<original_size {
        derive_block_splits_helper(splits,start_idx,mid_idx,zc,orig)
        splits.split_locations[splits.idx]=u32(mid_idx)
        splits.idx+=1
        derive_block_splits_helper(splits,mid_idx,end_idx,zc,orig)
    }
}

@(private="file")
derive_block_splits :: proc(zc:^Compressor,partitions:[^]u32,nb_seq:u32) -> int {
    splits:=Seq_Store_Splits{partitions,0}
    if nb_seq<=4 {return 0}
    derive_block_splits_helper(&splits,0,int(nb_seq),zc,&zc.seq_store)
    splits.split_locations[splits.idx]=nb_seq
    return splits.idx
}

@(private="file")
compress_block_split_internal :: proc(zc:^Compressor,dst:[^]u8,dst_capacity_in:int,src:[^]u8,block_size:int,last_block,nb_seq:u32) -> (size:int,err:Error) {
    c_size:=0
    ip:=src
    op:=dst
    dst_capacity:=dst_capacity_in
    src_bytes_total:=0
    partitions:=raw_data(zc.split.partitions[:])
    next_seq_store:=&zc.split.next_seq_store
    curr_seq_store:=&zc.split.curr_seq_store
    num_splits:=derive_block_splits(zc,partitions,nb_seq)
    d_rep:=zc.prev_cblock.rep
    c_rep:=zc.prev_cblock.rep
    next_seq_store^={}
    if num_splits==0 {
        return compress_seq_store_single_block(zc,&zc.seq_store,&d_rep,&c_rep,op,dst_capacity,ip,block_size,last_block,false)
    }
    derive_seq_store_chunk(curr_seq_store,&zc.seq_store,0,int(partitions[0]))
    for i in 0..=num_splits {
        last_partition:=i==num_splits
        last_block_entire_src:=u32(0)
        src_bytes:=count_seq_store_literals_bytes(curr_seq_store)+count_seq_store_match_bytes(curr_seq_store)
        src_bytes_total+=src_bytes
        if last_partition {
            src_bytes+=block_size-src_bytes_total
            last_block_entire_src=last_block
        } else {
            derive_seq_store_chunk(next_seq_store,&zc.seq_store,int(partitions[i]),int(partitions[i+1]))
        }
        c_size_chunk:=compress_seq_store_single_block(zc,curr_seq_store,&d_rep,&c_rep,op,dst_capacity,ip,src_bytes,last_block_entire_src,true) or_return
        ip=padd(ip,src_bytes)
        op=padd(op,c_size_chunk)
        dst_capacity-=c_size_chunk
        c_size+=c_size_chunk
        curr_seq_store^=next_seq_store^
    }
    zc.prev_cblock.rep=d_rep
    return c_size,.None
}

@(private="file")
compress_block_split :: proc(zc:^Compressor,dst:[^]u8,dst_capacity:int,src:[^]u8,src_size:int,last_block:u32) -> (size:int,err:Error) {
    if build_seq_store(zc,src,src_size)==.No_Compress {
        if zc.prev_cblock.entropy.fse.offcode_repeat_mode==.Valid {zc.prev_cblock.entropy.fse.offcode_repeat_mode=.Check}
        return no_compress_block(dst,dst_capacity,src,src_size,last_block)
    }
    nb_seq:=u32((uintptr(zc.seq_store.sequences)-uintptr(zc.seq_store.sequences_start))/size_of(Seq_Def))
    return compress_block_split_internal(zc,dst,dst_capacity,src,src_size,last_block,nb_seq)
}

@(private="file")
compress_block_internal :: proc(zc:^Compressor,dst:[^]u8,dst_capacity:int,src:[^]u8,src_size:int) -> (size:int,err:Error) {
    c_size:=0
    if build_seq_store(zc,src,src_size)==.Compress {
        c_size=entropy_compress_seq_store(&zc.seq_store,&zc.prev_cblock.entropy,&zc.next_cblock.entropy,zc.c_params.strategy,dst,dst_capacity,src_size,zc.tmp_workspace,zc.tmp_wksp_size) or_return
        if !zc.is_first_block && c_size<RLE_MAX_LENGTH && is_rle(src,src_size) {
            c_size=1
            dst[0]=src[0]
        }
    }
    if c_size>1 {confirm_repcodes_and_entropy_tables(zc)}
    if zc.prev_cblock.entropy.fse.offcode_repeat_mode==.Valid {zc.prev_cblock.entropy.fse.offcode_repeat_mode=.Check}
    return c_size,.None
}

@(rodata,private="file") SPLIT_LEVELS:=[?]int{0,0,1,2,2,3,3,4,4,4}

@(private="file")
optimal_block_size :: proc "contextless" (zc:^Compressor,src:[^]u8,src_size,block_size_max:int,strategy:Strategy,savings:i64) -> int {
    if src_size<128*KB || block_size_max<128*KB {return min(src_size,block_size_max)}
    if savings<3 {return 128*KB}
    return split_block(src,block_size_max,SPLIT_LEVELS[strategy],zc.tmp_workspace,zc.tmp_wksp_size)
}

@(private="file")
window_enforce_max_dist :: proc "contextless" (window:^Window,block_end:[^]u8,max_dist:u32) {
    block_end_idx:=u32(pdiff(block_end,window.base))
    if block_end_idx>max_dist {
        new_low_limit:=block_end_idx-max_dist
        if window.low_limit<new_low_limit {window.low_limit=new_low_limit}
        if window.dict_limit<window.low_limit {window.dict_limit=window.low_limit}
    }
}

@(private="file")
compress_frame_chunk :: proc(zc:^Compressor,dst:[^]u8,dst_capacity_in:int,src:[^]u8,src_size:int) -> (size:int,err:Error) {
    block_size_max:=zc.block_size_max
    remaining:=src_size
    ip:=src
    ostart:=dst
    op:=ostart
    dst_capacity:=dst_capacity_in
    max_dist:=u32(1)<<zc.c_params.window_log
    savings:=i64(0)
    ms:=&zc.ms
    for remaining!=0 {
        block_size:=optimal_block_size(zc,ip,remaining,block_size_max,zc.c_params.strategy,savings)
        last_block:=u32(block_size==remaining?1:0)
        if dst_capacity<BLOCK_HEADER_SIZE+MIN_CBLOCK_SIZE+1 {return 0,.Dst_Size_Too_Small}
        window_enforce_max_dist(&ms.window,ip,max_dist)
        if ms.next_to_update<ms.window.low_limit {ms.next_to_update=ms.window.low_limit}
        c_size:int
        if zc.post_block_splitter==.Enable {
            c_size=compress_block_split(zc,op,dst_capacity,ip,block_size,last_block) or_return
        } else {
            c_size=compress_block_internal(zc,padd(op,BLOCK_HEADER_SIZE),dst_capacity-BLOCK_HEADER_SIZE,ip,block_size) or_return
            if c_size==0 {
                c_size=no_compress_block(op,dst_capacity,ip,block_size,last_block) or_return
            } else {
                write_block_header(op,c_size,block_size,last_block)
                c_size+=BLOCK_HEADER_SIZE
            }
        }
        savings+=i64(block_size)-i64(c_size)
        ip=padd(ip,block_size)
        remaining-=block_size
        op=padd(op,c_size)
        dst_capacity-=c_size
        zc.is_first_block=false
    }
    return pdiff(op,ostart),.None
}

@(private="file")
write_frame_header :: proc "contextless" (dst:[^]u8,dst_capacity:int,window_log:u32,checksum:bool,pledged_src_size:u64) -> (size:int,err:Error) {
    op:=dst
    checksum_flag:=u32(checksum?1:0)
    window_size:=u32(1)<<window_log
    single_segment:=u32(u64(window_size)>=pledged_src_size?1:0)
    window_log_byte:=u8((window_log-WINDOW_LOG_ABSOLUTE_MIN)<<3)
    fcs_code:=u32((pledged_src_size>=256?1:0)+(pledged_src_size>=65536+256?1:0)+(pledged_src_size>=0xFFFFFFFF?1:0))
    frame_header_description:=u8(checksum_flag<<2+single_segment<<5+fcs_code<<6)
    pos:=0
    if dst_capacity<FRAME_HEADER_SIZE_MAX {return 0,.Dst_Size_Too_Small}
    write32(dst,MAGIC_NUMBER)
    pos=4
    op[pos]=frame_header_description
    pos+=1
    if single_segment==0 {
        op[pos]=window_log_byte
        pos+=1
    }
    switch fcs_code {
    case 0:
        if single_segment!=0 {
            op[pos]=u8(pledged_src_size)
            pos+=1
        }
    case 1:
        write16(padd(op,pos),u16(pledged_src_size-256))
        pos+=2
    case 2:
        write32(padd(op,pos),u32(pledged_src_size))
        pos+=4
    case 3:
        write64(padd(op,pos),pledged_src_size)
        pos+=8
    }
    return pos,.None
}

// How many bytes of workspace a level asks for on a source.
@(private="file")
workspace_bytes :: proc "contextless" (p:Compression_Parameters,row:Param_Switch,block_size,max_nb_seq:int) -> int {
    total:=2*(64+size_of(Compressed_Block_State))+64+TMP_WORKSPACE_SIZE
    chain_size:=p.strategy!=.Fast && !row_match_finder_used(p.strategy,row) ? 1<<p.chain_log : 0
    h_size:=1<<p.hash_log
    hash_log3:=p.min_match==3 ? min(HASH_LOG3_MAX,p.window_log) : 0
    h3_size:=hash_log3!=0 ? 1<<hash_log3 : 0
    total+=64*3+(chain_size+h_size+h3_size)*size_of(u32)
    if row_match_finder_used(p.strategy,row) {total+=64+h_size}
    if p.strategy>=.BTOpt {
        total+=64*6+((1<<LIT_BITS)+MAX_LL+1+MAX_ML+1+MAX_OFF+1)*size_of(u32)
        total+=OPT_SIZE*size_of(Match)+OPT_SIZE*size_of(Optimal)
    }
    total+=64*5+max_nb_seq*size_of(Seq_Def)+block_size+WILDCOPY_OVERLENGTH+3*max_nb_seq
    return total
}

// The frame of src at a level, into dst. The output is deterministic and the same on every
// platform. Levels other than 3, 6 and 22 are refused.
compress :: proc(dst:[^]u8,dst_capacity:int,src:[^]u8,src_size:int,level:int,checksum:=false,allocator:=context.allocator) -> (written:int,err:Error) {
    row:Level_Row
    switch level {
    case 3: row=.L3
    case 6: row=.L6
    case 22: row=.L22
    case: return 0,.Parameter_Unsupported
    }
    if src_size<0 || src_size>MAX_SOURCE_BYTES {return 0,.Src_Size_Wrong}

    table_id:=(src_size<=256*KB?1:0)+(src_size<=128*KB?1:0)+(src_size<=16*KB?1:0)
    params:=adjust_params(DEFAULT_PARAMETERS[table_id][row],src_size)

    zc:Compressor
    zc.c_params=params
    zc.is_first_block=true
    zc.use_row_match_finder=.Disable
    if row_match_finder_supported(params.strategy) && params.window_log>14 {zc.use_row_match_finder=.Enable}
    zc.post_block_splitter=params.strategy>=.BTOpt && params.window_log>=17 ? .Enable : .Disable
    zc.block_compressor=select_block_compressor(params.strategy,zc.use_row_match_finder)
    if zc.block_compressor==nil {return 0,.Parameter_Unsupported}

    window_size:=max(1,min(1<<params.window_log,src_size))
    block_size:=min(BLOCK_SIZE_MAX,window_size)
    max_nb_seq:=block_size/(params.min_match==3?3:4)
    zc.block_size_max=block_size

    bytes:=workspace_bytes(params,zc.use_row_match_finder,block_size,max_nb_seq)
    memory,alloc_err:=runtime.mem_alloc(bytes,64,allocator)
    if alloc_err!=nil {return 0,.Memory_Allocation}
    defer runtime.mem_free_with_size(raw_data(memory),bytes,allocator)

    cursor:=uintptr(raw_data(memory))
    zc.prev_cblock=(^Compressed_Block_State)(carve(&cursor,size_of(Compressed_Block_State)))
    zc.next_cblock=(^Compressed_Block_State)(carve(&cursor,size_of(Compressed_Block_State)))
    zc.tmp_workspace=([^]u8)(carve(&cursor,TMP_WORKSPACE_SIZE))
    zc.tmp_wksp_size=TMP_WORKSPACE_SIZE

    zc.prev_cblock.rep=REP_START_VALUE
    zc.prev_cblock.entropy.huf.repeat_mode=.None
    zc.prev_cblock.entropy.fse.offcode_repeat_mode=.None
    zc.prev_cblock.entropy.fse.matchlength_repeat_mode=.None
    zc.prev_cblock.entropy.fse.litlength_repeat_mode=.None

    ms:=&zc.ms
    ms.c_params=params
    chain_size:=params.strategy!=.Fast && !row_match_finder_used(params.strategy,zc.use_row_match_finder) ? 1<<params.chain_log : 0
    h_size:=1<<params.hash_log
    ms.hash_log3=params.min_match==3 ? min(HASH_LOG3_MAX,params.window_log) : 0
    h3_size:=ms.hash_log3!=0 ? 1<<ms.hash_log3 : 0
    ms.window.base=padd(src,-WINDOW_START_INDEX)
    ms.window.next_src=src
    ms.window.dict_limit=WINDOW_START_INDEX
    ms.window.low_limit=WINDOW_START_INDEX
    ms.next_to_update=WINDOW_START_INDEX
    ms.hash_table=([^]u32)(carve(&cursor,h_size*size_of(u32)))
    ms.chain_table=([^]u32)(carve(&cursor,chain_size*size_of(u32)))
    ms.hash_table3=([^]u32)(carve(&cursor,h3_size*size_of(u32)))
    if row_match_finder_used(params.strategy,zc.use_row_match_finder) {
        ms.tag_table=([^]u8)(carve(&cursor,h_size))
        ms.hash_salt=bitmix(0,8)~bitmix(0,4)
        row_log:=clamp(params.search_log,4,6)
        ms.row_hash_log=params.hash_log-row_log
    }
    if params.strategy>=.BTOpt {
        ms.opt.lit_freq=([^]u32)(carve(&cursor,(1<<LIT_BITS)*size_of(u32)))
        ms.opt.lit_length_freq=([^]u32)(carve(&cursor,(MAX_LL+1)*size_of(u32)))
        ms.opt.match_length_freq=([^]u32)(carve(&cursor,(MAX_ML+1)*size_of(u32)))
        ms.opt.off_code_freq=([^]u32)(carve(&cursor,(MAX_OFF+1)*size_of(u32)))
        ms.opt.match_table=([^]Match)(carve(&cursor,OPT_SIZE*size_of(Match)))
        ms.opt.price_table=([^]Optimal)(carve(&cursor,OPT_SIZE*size_of(Optimal)))
    }

    zc.seq_store.sequences_start=([^]Seq_Def)(carve(&cursor,max_nb_seq*size_of(Seq_Def)))
    zc.seq_store.lit_start=([^]u8)(carve(&cursor,block_size+WILDCOPY_OVERLENGTH))
    zc.seq_store.max_nb_lit=block_size
    zc.seq_store.max_nb_seq=max_nb_seq
    zc.seq_store.ll_code=([^]u8)(carve(&cursor,max_nb_seq))
    zc.seq_store.ml_code=([^]u8)(carve(&cursor,max_nb_seq))
    zc.seq_store.of_code=([^]u8)(carve(&cursor,max_nb_seq))

    op:=dst
    capacity:=dst_capacity
    header_size:=write_frame_header(op,capacity,params.window_log,checksum,u64(src_size)) or_return
    op=padd(op,header_size)
    capacity-=header_size

    if src_size>0 {
        ms.window.next_src=padd(src,src_size)
        c_size:=compress_frame_chunk(&zc,op,capacity,src,src_size) or_return
        op=padd(op,c_size)
        capacity-=c_size
    } else {
        if capacity<3 {return 0,.Dst_Size_Too_Small}
        write24(op,1+u32(Block_Type.Raw)<<1)
        op=padd(op,BLOCK_HEADER_SIZE)
        capacity-=BLOCK_HEADER_SIZE
    }
    if checksum {
        if capacity<4 {return 0,.Dst_Size_Too_Small}
        write32(op,u32(xxh64(src,src_size,0)))
        op=padd(op,4)
    }
    return pdiff(op,dst),.None
}
