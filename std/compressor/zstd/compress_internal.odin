package zstd

import "base:intrinsics"

// The state the encoder's parts share. Only one call into one contiguous buffer: no dictionary,
// no external sequences, no long-distance matching.

Strategy :: enum u32 {Fast=1,DFast=2,Greedy=3,Lazy=4,Lazy2=5,BTLazy2=6,BTOpt=7,BTUltra=8,BTUltra2=9}

Compression_Parameters :: struct {
    window_log,chain_log,hash_log,search_log,min_match,target_length:u32,
    strategy:Strategy,
}

Param_Switch :: enum {Auto,Enable,Disable}

Huf_Repeat :: enum {None,Check,Valid}
Fse_Repeat :: enum {None,Check,Valid}

Huf_CTables :: struct {
    ctable:[257]u64,
    repeat_mode:Huf_Repeat,
}

FSE_OFF_CTABLE_U32 :: 1+(1<<(OFF_FSE_LOG-1))+(MAX_OFF+1)*2
FSE_ML_CTABLE_U32 :: 1+(1<<(ML_FSE_LOG-1))+(MAX_ML+1)*2
FSE_LL_CTABLE_U32 :: 1+(1<<(LL_FSE_LOG-1))+(MAX_LL+1)*2

Fse_CTables :: struct {
    offcode_ctable:[FSE_OFF_CTABLE_U32]u32,
    matchlength_ctable:[FSE_ML_CTABLE_U32]u32,
    litlength_ctable:[FSE_LL_CTABLE_U32]u32,
    offcode_repeat_mode,matchlength_repeat_mode,litlength_repeat_mode:Fse_Repeat,
}

Entropy_CTables :: struct {
    huf:Huf_CTables,
    fse:Fse_CTables,
}

Seq_Def :: struct {
    off_base:u32, // offset + REP_NUM, or the repcodes 1 to 3
    lit_length:u16,
    ml_base:u16, // match length - MINMATCH
}

Long_Length_Type :: enum {None,Literal_Length,Match_Length}

Seq_Store :: struct {
    sequences_start,sequences:[^]Seq_Def, // sequences: past the last one
    lit_start,lit:[^]u8, // lit: past the last literal
    ll_code,ml_code,of_code:[^]u8,
    max_nb_seq,max_nb_lit:int,
    long_length_type:Long_Length_Type,
    long_length_pos:u32,
}

Sequence_Length :: struct {lit_length,match_length:u32}

get_sequence_length :: #force_inline proc "contextless" (store:^Seq_Store,seq:^Seq_Def) -> Sequence_Length {
    result:=Sequence_Length{u32(seq.lit_length),u32(seq.ml_base)+MINMATCH}
    if store.long_length_pos==u32((uintptr(seq)-uintptr(store.sequences_start))/size_of(Seq_Def)) {
        if store.long_length_type==.Literal_Length {result.lit_length+=0x10000}
        if store.long_length_type==.Match_Length {result.match_length+=0x10000}
    }
    return result
}

Huf_CTables_Metadata :: struct {
    h_type:Symbol_Encoding_Type,
    huf_des_buffer:[MAX_HUF_HEADER_SIZE]u8,
    huf_des_size:int,
}

Fse_CTables_Metadata :: struct {
    ll_type,of_type,ml_type:Symbol_Encoding_Type,
    fse_tables_buffer:[MAX_FSE_HEADERS_SIZE]u8,
    fse_tables_size:int,
    last_count_size:int,
}

Entropy_CTables_Metadata :: struct {
    huf_metadata:Huf_CTables_Metadata,
    fse_metadata:Fse_CTables_Metadata,
}

Match :: struct {off,len:u32}

Optimal :: struct {
    price:i32,
    off,mlen,litlen:u32,
    rep:[REP_NUM]u32,
}

Opt_Price :: enum {Dynamic,Predef}

OPT_SIZE :: OPT_NUM+3

// The tables are of 256, MAX_LL+1, MAX_ML+1, MAX_OFF+1 and OPT_SIZE entries.
Opt_State :: struct {
    lit_freq,lit_length_freq,match_length_freq,off_code_freq:[^]u32,
    match_table:[^]Match,
    price_table:[^]Optimal,
    lit_sum,lit_length_sum,match_length_sum,off_code_sum:u32,
    lit_sum_base_price,lit_length_sum_base_price,match_length_sum_base_price,off_code_sum_base_price:u32,
    price_type:Opt_Price,
    literal_compression_mode:Param_Switch,
}

Compressed_Block_State :: struct {
    entropy:Entropy_CTables,
    rep:[REP_NUM]u32,
}

WINDOW_START_INDEX :: 2

Window :: struct {
    next_src,base:[^]u8,
    dict_limit,low_limit:u32,
}

ROW_HASH_CACHE_SIZE :: 8
HASH_READ_SIZE :: 8

Match_State :: struct {
    window:Window,
    next_to_update,hash_log3:u32,
    row_hash_log:u32,
    tag_table:[^]u8,
    hash_cache:[ROW_HASH_CACHE_SIZE]u32,
    hash_salt:u64,
    hash_salt_entropy:u32,
    hash_table,hash_table3,chain_table:[^]u32,
    opt:Opt_State,
    c_params:Compression_Parameters,
    lazy_skipping:bool,
}

@(rodata,private="file") LL_Code:=[64]u8{
    0,1,2,3,4,5,6,7,
    8,9,10,11,12,13,14,15,
    16,16,17,17,18,18,19,19,
    20,20,20,20,21,21,21,21,
    22,22,22,22,22,22,22,22,
    23,23,23,23,23,23,23,23,
    24,24,24,24,24,24,24,24,
    24,24,24,24,24,24,24,24,
}

ll_code :: #force_inline proc "contextless" (lit_length:u32) -> u32 {
    return lit_length>63 ? highbit32(lit_length)+19 : u32(LL_Code[lit_length])
}

@(rodata,private="file") ML_Code:=[128]u8{
    0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,
    16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,
    32,32,33,33,34,34,35,35,36,36,36,36,37,37,37,37,
    38,38,38,38,38,38,38,38,39,39,39,39,39,39,39,39,
    40,40,40,40,40,40,40,40,40,40,40,40,40,40,40,40,
    41,41,41,41,41,41,41,41,41,41,41,41,41,41,41,41,
    42,42,42,42,42,42,42,42,42,42,42,42,42,42,42,42,
    42,42,42,42,42,42,42,42,42,42,42,42,42,42,42,42,
}

ml_code :: #force_inline proc "contextless" (ml_base:u32) -> u32 {
    return ml_base>127 ? highbit32(ml_base)+36 : u32(ML_Code[ml_base])
}

select_addr :: #force_inline proc "contextless" (index,low_limit:u32,candidate,backup:[^]u8) -> [^]u8 {
    return index>=low_limit ? candidate : backup
}

copy_bytes :: #force_inline proc "contextless" (dst,src:[^]u8,n:int) {
    if n>0 {intrinsics.mem_copy_non_overlapping(dst,src,n)}
}

no_compress_block :: proc "contextless" (dst:[^]u8,dst_capacity:int,src:[^]u8,src_size:int,last_block:u32) -> (size:int,err:Error) {
    header:=last_block+u32(Block_Type.Raw)<<1+u32(src_size)<<3
    if src_size+BLOCK_HEADER_SIZE>dst_capacity {return 0,.Dst_Size_Too_Small}
    write24(dst,header)
    copy_bytes(padd(dst,BLOCK_HEADER_SIZE),src,src_size)
    return BLOCK_HEADER_SIZE+src_size,.None
}

rle_compress_block :: proc "contextless" (dst:[^]u8,dst_capacity:int,value:u8,src_size:int,last_block:u32) -> (size:int,err:Error) {
    header:=last_block+u32(Block_Type.RLE)<<1+u32(src_size)<<3
    if dst_capacity<4 {return 0,.Dst_Size_Too_Small}
    write24(dst,header)
    dst[3]=value
    return 4,.None
}

min_gain :: #force_inline proc "contextless" (src_size:int,strategy:Strategy) -> int {
    min_log:=strategy>=.BTUltra ? u32(strategy)-1 : 6
    return src_size>>min_log+2
}

safecopy_literals :: proc "contextless" (op_in,ip_in,iend,ilimit_w:[^]u8) {
    op,ip:=op_in,ip_in
    if uintptr(ip)<=uintptr(ilimit_w) {
        wildcopy(op,ip,pdiff(ilimit_w,ip),.No_Overlap)
        op=padd(op,pdiff(ilimit_w,ip))
        ip=ilimit_w
    }
    for uintptr(ip)<uintptr(iend) {
        op[0]=ip[0]
        op=padd(op,1);ip=padd(ip,1)
    }
}

repcode_to_offbase :: #force_inline proc "contextless" (r:u32) -> u32 {return r}
offset_to_offbase :: #force_inline proc "contextless" (o:u32) -> u32 {return o+REP_NUM}
offbase_is_offset :: #force_inline proc "contextless" (o:u32) -> bool {return o>REP_NUM}
offbase_is_repcode :: #force_inline proc "contextless" (o:u32) -> bool {return 1<=o && o<=REP_NUM}
offbase_to_offset :: #force_inline proc "contextless" (o:u32) -> u32 {return o-REP_NUM}
offbase_to_repcode :: #force_inline proc "contextless" (o:u32) -> u32 {return o}

store_seq_only :: #force_inline proc "contextless" (store:^Seq_Store,lit_length:int,off_base:u32,match_length:int) {
    position:=u32((uintptr(store.sequences)-uintptr(store.sequences_start))/size_of(Seq_Def))
    if lit_length>0xFFFF {
        store.long_length_type=.Literal_Length
        store.long_length_pos=position
    }
    store.sequences[0].lit_length=u16(lit_length)
    store.sequences[0].off_base=off_base
    ml_base:=match_length-MINMATCH
    if ml_base>0xFFFF {
        store.long_length_type=.Match_Length
        store.long_length_pos=position
    }
    store.sequences[0].ml_base=u16(ml_base)
    store.sequences=store.sequences[1:]
}

// May read the literals up to lit_limit.
store_seq :: #force_inline proc "contextless" (store:^Seq_Store,lit_length:int,literals,lit_limit:[^]u8,off_base:u32,match_length:int) {
    lit_limit_w:=padd(lit_limit,-WILDCOPY_OVERLENGTH)
    lit_end:=padd(literals,lit_length)
    if uintptr(lit_end)<=uintptr(lit_limit_w) {
        copy16(store.lit,literals)
        if lit_length>16 {wildcopy(padd(store.lit,16),padd(literals,16),lit_length-16,.No_Overlap)}
    } else {
        safecopy_literals(store.lit,literals,lit_end,lit_limit_w)
    }
    store.lit=padd(store.lit,lit_length)
    store_seq_only(store,lit_length,off_base,match_length)
}

update_rep :: #force_inline proc "contextless" (rep:^[REP_NUM]u32,off_base:u32,ll0:u32) {
    if offbase_is_offset(off_base) {
        rep[2]=rep[1]
        rep[1]=rep[0]
        rep[0]=offbase_to_offset(off_base)
    } else {
        rep_code:=offbase_to_repcode(off_base)-1+ll0
        if rep_code>0 {
            current:=rep_code==REP_NUM ? rep[0]-1 : rep[rep_code]
            rep[2]=rep_code>=2 ? rep[1] : rep[2]
            rep[1]=rep[0]
            rep[0]=current
        }
    }
}

new_rep :: #force_inline proc "contextless" (rep:[REP_NUM]u32,off_base,ll0:u32) -> [REP_NUM]u32 {
    result:=rep
    update_rep(&result,off_base,ll0)
    return result
}

// How many bytes of p_in, up to p_in_limit, equal those of p_match.
count :: #force_inline proc "contextless" (p_in_start,p_match_start,p_in_limit:[^]u8) -> int {
    p_in,p_match:=p_in_start,p_match_start
    loop_limit:=padd(p_in_limit,-7)
    if uintptr(p_in)<uintptr(loop_limit) {
        diff:=read64(p_match)~read64(p_in)
        if diff!=0 {return nb_common_bytes(diff)}
        p_in=padd(p_in,8);p_match=padd(p_match,8)
        for uintptr(p_in)<uintptr(loop_limit) {
            diff=read64(p_match)~read64(p_in)
            if diff==0 {p_in=padd(p_in,8);p_match=padd(p_match,8);continue}
            p_in=padd(p_in,nb_common_bytes(diff))
            return pdiff(p_in,p_in_start)
        }
    }
    if uintptr(p_in)<uintptr(padd(p_in_limit,-3)) && read32(p_match)==read32(p_in) {p_in=padd(p_in,4);p_match=padd(p_match,4)}
    if uintptr(p_in)<uintptr(padd(p_in_limit,-1)) && read16(p_match)==read16(p_in) {p_in=padd(p_in,2);p_match=padd(p_match,2)}
    if uintptr(p_in)<uintptr(p_in_limit) && p_match[0]==p_in[0] {p_in=padd(p_in,1)}
    return pdiff(p_in,p_in_start)
}

PRIME3_BYTES :: u32(506832829)
PRIME4_BYTES :: u32(2654435761)
PRIME5_BYTES :: u64(889523592379)
PRIME6_BYTES :: u64(227718039650203)
PRIME7_BYTES :: u64(58295818150454627)
PRIME8_BYTES :: u64(0xCF1BBCDCB7A56463)

hash3 :: #force_inline proc "contextless" (u,h,s:u32) -> u32 {return ((u<<(32-24))*PRIME3_BYTES~s)>>(32-h)}
hash3_ptr :: #force_inline proc "contextless" (p:[^]u8,h:u32) -> int {return int(hash3(read32(p),h,0))}
hash3_ptr_s :: #force_inline proc "contextless" (p:[^]u8,h,s:u32) -> int {return int(hash3(read32(p),h,s))}
hash4 :: #force_inline proc "contextless" (u,h,s:u32) -> u32 {return (u*PRIME4_BYTES~s)>>(32-h)}
hash4_ptr :: #force_inline proc "contextless" (p:[^]u8,h:u32) -> int {return int(hash4(read32(p),h,0))}
hash4_ptr_s :: #force_inline proc "contextless" (p:[^]u8,h,s:u32) -> int {return int(hash4(read32(p),h,s))}
hash5 :: #force_inline proc "contextless" (u:u64,h:u32,s:u64) -> int {return int(((u<<(64-40))*PRIME5_BYTES~s)>>(64-h))}
hash5_ptr :: #force_inline proc "contextless" (p:[^]u8,h:u32) -> int {return hash5(read64(p),h,0)}
hash5_ptr_s :: #force_inline proc "contextless" (p:[^]u8,h:u32,s:u64) -> int {return hash5(read64(p),h,s)}
hash6 :: #force_inline proc "contextless" (u:u64,h:u32,s:u64) -> int {return int(((u<<(64-48))*PRIME6_BYTES~s)>>(64-h))}
hash6_ptr :: #force_inline proc "contextless" (p:[^]u8,h:u32) -> int {return hash6(read64(p),h,0)}
hash6_ptr_s :: #force_inline proc "contextless" (p:[^]u8,h:u32,s:u64) -> int {return hash6(read64(p),h,s)}
hash7 :: #force_inline proc "contextless" (u:u64,h:u32,s:u64) -> int {return int(((u<<(64-56))*PRIME7_BYTES~s)>>(64-h))}
hash7_ptr :: #force_inline proc "contextless" (p:[^]u8,h:u32) -> int {return hash7(read64(p),h,0)}
hash7_ptr_s :: #force_inline proc "contextless" (p:[^]u8,h:u32,s:u64) -> int {return hash7(read64(p),h,s)}
hash8 :: #force_inline proc "contextless" (u:u64,h:u32,s:u64) -> int {return int((u*PRIME8_BYTES~s)>>(64-h))}
hash8_ptr :: #force_inline proc "contextless" (p:[^]u8,h:u32) -> int {return hash8(read64(p),h,0)}
hash8_ptr_s :: #force_inline proc "contextless" (p:[^]u8,h:u32,s:u64) -> int {return hash8(read64(p),h,s)}

hash_ptr :: #force_inline proc "contextless" (p:[^]u8,h_bits,mls:u32) -> int {
    switch mls {
    case 5: return hash5_ptr(p,h_bits)
    case 6: return hash6_ptr(p,h_bits)
    case 7: return hash7_ptr(p,h_bits)
    case 8: return hash8_ptr(p,h_bits)
    case: return hash4_ptr(p,h_bits)
    }
}

hash_ptr_salted :: #force_inline proc "contextless" (p:[^]u8,h_bits,mls:u32,salt:u64) -> int {
    switch mls {
    case 5: return hash5_ptr_s(p,h_bits,salt)
    case 6: return hash6_ptr_s(p,h_bits,salt)
    case 7: return hash7_ptr_s(p,h_bits,salt)
    case 8: return hash8_ptr_s(p,h_bits,salt)
    case: return hash4_ptr_s(p,h_bits,u32(salt))
    }
}

// The lowest index a match may have: no dictionary, so the window is all there is.
get_lowest_match_index :: #force_inline proc "contextless" (ms:^Match_State,curr,window_log:u32) -> u32 {
    max_distance:=u32(1)<<window_log
    lowest_valid:=ms.window.low_limit
    return curr-lowest_valid>max_distance ? curr-max_distance : lowest_valid
}

get_lowest_prefix_index :: #force_inline proc "contextless" (ms:^Match_State,curr,window_log:u32) -> u32 {
    max_distance:=u32(1)<<window_log
    lowest_valid:=ms.window.dict_limit
    return curr-lowest_valid>max_distance ? curr-max_distance : lowest_valid
}

// Whether the three bytes before the prefix start do not hold rep_index.
index_overlap_check :: #force_inline proc "contextless" (prefix_lowest_index,rep_index:u32) -> bool {
    return (prefix_lowest_index-1)-rep_index>=3
}

reset_seq_store :: #force_inline proc "contextless" (store:^Seq_Store) {
    store.lit=store.lit_start
    store.sequences=store.sequences_start
    store.long_length_type=.None
}

// What each strategy runs on a block. Returns how many bytes at the end are left as literals.
Block_Compressor :: #type proc "contextless" (ms:^Match_State,store:^Seq_Store,rep:^[REP_NUM]u32,src:[^]u8,src_size:int) -> int
