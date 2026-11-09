package common

import "base:intrinsics"
import "core:simd"

// A value and how many times it occurs.
Dword_And_Count :: struct {
    dw:u32,
    count:u32,
}

// Same values: highest count first.
dword_and_count_compare_dword :: proc(lhs,rhs:Dword_And_Count) -> bool {
    if lhs.dw==rhs.dw {return lhs.count>rhs.count}
    return lhs.dw<rhs.dw
}

dword_and_count_compare_count_highest_first :: proc(lhs,rhs:Dword_And_Count) -> bool {
    if lhs.count==rhs.count {return lhs.dw<rhs.dw}
    return lhs.count>rhs.count
}

dword_and_count_compare_count_lowest_first :: proc(lhs,rhs:Dword_And_Count) -> bool {
    if lhs.count==rhs.count {return lhs.dw<rhs.dw}
    return lhs.count<rhs.count
}

@(private="file")
u32_less :: proc(a,b:u32) -> bool {return a<b}

// Sorts values and appends each distinct value with its count to counting (cleared first),
// in increasing order. counting must have room (cap) for len(values) entries.
sort_and_count_uniques :: proc(counting:^[dynamic]Dword_And_Count,values:[]u32) -> Error {
    clear(counting)
    if len(values)==0 {return .None}
    stdsort(values,u32_less)
    if reserve(counting,len(values))!=nil {return .Out_Of_Memory}
    i:=0
    for i<len(values) {
        cur:=values[i]
        j:=i+1
        for j<len(values) && cur==values[j] {j+=1}
        append(counting,Dword_And_Count{cur,u32(j-i)})
        i=j
    }
    return .None
}

sort_dword_and_count_compare_count_highest_first :: proc(counting:[]Dword_And_Count) {
    stdsort(counting,dword_and_count_compare_count_highest_first)
}

sort_dword_and_count_compare_dword :: proc(counting:[]Dword_And_Count) {
    stdsort(counting,dword_and_count_compare_dword)
}

// A 16-byte block (BC7), little endian: [0] is the low 64 bits.
Bits128 :: [2]u64

bits128_less :: #force_inline proc "contextless" (lhs,rhs:Bits128) -> bool {
    if lhs[1]==rhs[1] {return lhs[0]<rhs[0]}
    return lhs[1]<rhs[1]
}

Bits128_And_Count :: struct {
    val:Bits128,
    count:u32,
}

bits128_and_count_compare_bits :: proc(lhs,rhs:Bits128_And_Count) -> bool {
    if lhs.val==rhs.val {return lhs.count>rhs.count}
    return bits128_less(lhs.val,rhs.val)
}

// No tie break on equal counts: the sort algorithm decides their order.
bits128_and_count_compare_count_highest_first :: proc(lhs,rhs:Bits128_And_Count) -> bool {
    return lhs.count>rhs.count
}

@(private="file")
bits128_less_proc :: proc(a,b:Bits128) -> bool {return bits128_less(a,b)}

sort_and_count_uniques_bits128 :: proc(counting:^[dynamic]Bits128_And_Count,
    values:[]Bits128) -> Error {
    clear(counting)
    if len(values)==0 {return .None}
    stdsort(values,bits128_less_proc)
    if reserve(counting,len(values))!=nil {return .Out_Of_Memory}
    i:=0
    for i<len(values) {
        cur:=values[i]
        j:=i+1
        for j<len(values) && cur==values[j] {j+=1}
        append(counting,Bits128_And_Count{cur,u32(j-i)})
        i=j
    }
    return .None
}

sort_bits128_and_count_compare_count_highest_first :: proc(counting:[]Bits128_And_Count) {
    stdsort(counting,bits128_and_count_compare_count_highest_first)
}

sort_bits128_and_count_compare_bits :: proc(counting:[]Bits128_And_Count) {
    stdsort(counting,bits128_and_count_compare_bits)
}

// Positions of the set bits of i, one per nibble, lowest first.
@(rodata)
ACTIVE_LANE_TABLE8 := [256]u32{
    0x00000000, 0x00000000, 0x00000001, 0x00000010, 0x00000002, 0x00000020, 0x00000021, 0x00000210,
    0x00000003, 0x00000030, 0x00000031, 0x00000310, 0x00000032, 0x00000320, 0x00000321, 0x00003210,
    0x00000004, 0x00000040, 0x00000041, 0x00000410, 0x00000042, 0x00000420, 0x00000421, 0x00004210,
    0x00000043, 0x00000430, 0x00000431, 0x00004310, 0x00000432, 0x00004320, 0x00004321, 0x00043210,
    0x00000005, 0x00000050, 0x00000051, 0x00000510, 0x00000052, 0x00000520, 0x00000521, 0x00005210,
    0x00000053, 0x00000530, 0x00000531, 0x00005310, 0x00000532, 0x00005320, 0x00005321, 0x00053210,
    0x00000054, 0x00000540, 0x00000541, 0x00005410, 0x00000542, 0x00005420, 0x00005421, 0x00054210,
    0x00000543, 0x00005430, 0x00005431, 0x00054310, 0x00005432, 0x00054320, 0x00054321, 0x00543210,
    0x00000006, 0x00000060, 0x00000061, 0x00000610, 0x00000062, 0x00000620, 0x00000621, 0x00006210,
    0x00000063, 0x00000630, 0x00000631, 0x00006310, 0x00000632, 0x00006320, 0x00006321, 0x00063210,
    0x00000064, 0x00000640, 0x00000641, 0x00006410, 0x00000642, 0x00006420, 0x00006421, 0x00064210,
    0x00000643, 0x00006430, 0x00006431, 0x00064310, 0x00006432, 0x00064320, 0x00064321, 0x00643210,
    0x00000065, 0x00000650, 0x00000651, 0x00006510, 0x00000652, 0x00006520, 0x00006521, 0x00065210,
    0x00000653, 0x00006530, 0x00006531, 0x00065310, 0x00006532, 0x00065320, 0x00065321, 0x00653210,
    0x00000654, 0x00006540, 0x00006541, 0x00065410, 0x00006542, 0x00065420, 0x00065421, 0x00654210,
    0x00006543, 0x00065430, 0x00065431, 0x00654310, 0x00065432, 0x00654320, 0x00654321, 0x06543210,
    0x00000007, 0x00000070, 0x00000071, 0x00000710, 0x00000072, 0x00000720, 0x00000721, 0x00007210,
    0x00000073, 0x00000730, 0x00000731, 0x00007310, 0x00000732, 0x00007320, 0x00007321, 0x00073210,
    0x00000074, 0x00000740, 0x00000741, 0x00007410, 0x00000742, 0x00007420, 0x00007421, 0x00074210,
    0x00000743, 0x00007430, 0x00007431, 0x00074310, 0x00007432, 0x00074320, 0x00074321, 0x00743210,
    0x00000075, 0x00000750, 0x00000751, 0x00007510, 0x00000752, 0x00007520, 0x00007521, 0x00075210,
    0x00000753, 0x00007530, 0x00007531, 0x00075310, 0x00007532, 0x00075320, 0x00075321, 0x00753210,
    0x00000754, 0x00007540, 0x00007541, 0x00075410, 0x00007542, 0x00075420, 0x00075421, 0x00754210,
    0x00007543, 0x00075430, 0x00075431, 0x00754310, 0x00075432, 0x00754320, 0x00754321, 0x07543210,
    0x00000076, 0x00000760, 0x00000761, 0x00007610, 0x00000762, 0x00007620, 0x00007621, 0x00076210,
    0x00000763, 0x00007630, 0x00007631, 0x00076310, 0x00007632, 0x00076320, 0x00076321, 0x00763210,
    0x00000764, 0x00007640, 0x00007641, 0x00076410, 0x00007642, 0x00076420, 0x00076421, 0x00764210,
    0x00007643, 0x00076430, 0x00076431, 0x00764310, 0x00076432, 0x00764320, 0x00764321, 0x07643210,
    0x00000765, 0x00007650, 0x00007651, 0x00076510, 0x00007652, 0x00076520, 0x00076521, 0x00765210,
    0x00007653, 0x00076530, 0x00076531, 0x00765310, 0x00076532, 0x00765320, 0x00765321, 0x07653210,
    0x00007654, 0x00076540, 0x00076541, 0x00765410, 0x00076542, 0x00765420, 0x00765421, 0x07654210,
    0x00076543, 0x00765430, 0x00765431, 0x07654310, 0x00765432, 0x07654320, 0x07654321, 0x76543210,
}

// SSD over a set of blocks for every index of every texel; adding blocks adds their tables.
Any_Index_D :: struct {
    ssd:[4][16]u32, // [index][texel]
}

ANY_INDEX_D_MAX_PIXEL_ERR :: (3+4)*255*255
ANY_INDEX_D_MAX_BLOCK_ERR :: ANY_INDEX_D_MAX_PIXEL_ERR*16
ANY_INDEX_D_MAX_BLOCKS_FOR_S32 :: 0x7fffffff/ANY_INDEX_D_MAX_BLOCK_ERR

Any_Index_8D64 :: struct {
    ssdx:[16][8]u64, // [texel][index]
}

any_index_d_lookup :: #force_inline proc "contextless" (aid:^Any_Index_D,in_indices:u32) -> u32 {
    indices:=in_indices
    ssd:u32
    for c in 0..<16 {
        ssd+=aid.ssd[indices&3][c]
        indices>>=2
    }
    return ssd
}

// any_index_d_batch_lookup from i0 on, with min_d0 the lowest distortion so far.
@(private)
any_index_d_batch_lookup_from :: #force_inline proc "contextless" (out_d:[]i32,aid:^Any_Index_D,
    in_indices:[]u32,i0:int,min_d0:i32) -> i32 #no_bounds_check {
    min_d:=min_d0
    n:=min(len(out_d),len(in_indices))
    for i in i0..<n {
        d:=i32(any_index_d_lookup(aid,in_indices[i]))
        out_d[i]=d
        min_d=min(min_d,d)
    }
    return min_d
}

// The indices of eight candidates for any_index_8d64_batch_lookup_packed: [group][candidate],
// the indices (0 to 7) of texels 4*group to 4*group+3 in the bytes of a u32.
Any_Index_8D64_Pack :: [4][8]u32

// Puts the indices of a candidate (16 indices, each times 2) in place k of p.
any_index_8d64_pack_set :: #force_inline proc "contextless" (p:^Any_Index_8D64_Pack,k:int,
    indices8_scaled:^[16]u8) {
    for g in 0..<4 {
        v:u32
        for j in 0..<4 {v|=u32((indices8_scaled[4*g+j]>>1)&7)<<uint(8*j)}
        p[g][k&7]=v
    }
}

@(private)
any_index_8d64_lookup_packed_from :: #force_inline proc "contextless" (out_d:[]i64,
    aid:^Any_Index_8D64,packs:[]Any_Index_8D64_Pack,count,i0:int) #no_bounds_check {
    n:=min(count,len(out_d),len(packs)*8)
    for i in i0..<n {
        p:=&packs[i>>3]
        k:=i&7
        ssd:i64
        for g in 0..<4 {
            v:=p[g][k]
            for j in 0..<4 {ssd+=i64(aid.ssdx[4*g+j][(v>>uint(8*j))&7])}
        }
        out_d[i]=ssd
    }
}

color_block_sad_rgba :: #force_inline proc "contextless" (lhs,rhs:^Color_Block) -> u32 {
    l:=([^]V16u8)(lhs)
    r:=([^]V16u8)(rhs)
    return sad_u8x16(load_u8x16(&l[0]),load_u8x16(&r[0]))+sad_u8x16(load_u8x16(&l[1]),
        load_u8x16(&r[1]))+sad_u8x16(load_u8x16(&l[2]),load_u8x16(&r[2]))+
        sad_u8x16(load_u8x16(&l[3]),load_u8x16(&r[3]))
}

color_block_ssd_rgba :: #force_inline proc "contextless" (lhs,rhs:^Color_Block) -> u32 {
    l:=([^]V16u8)(lhs)
    r:=([^]V16u8)(rhs)
    s:=ssd_rgba4(load_u8x16(&l[0]),load_u8x16(&r[0]))+ssd_rgba4(load_u8x16(&l[1]),
        load_u8x16(&r[1]))+ssd_rgba4(load_u8x16(&l[2]),load_u8x16(&r[2]))+
        ssd_rgba4(load_u8x16(&l[3]),load_u8x16(&r[3]))
    return u32(simd.reduce_add_pairs(s))
}

// The sad_halves of a block against the four rows at c.
@(private)
block_sad_halves :: #force_inline proc "contextless" (p:^Color_Block,c:^[4]V16u8) -> V4u32 {
    r:=([^]V16u8)(p)
    return sad_halves(load_u8x16(&r[0]),c[0])+sad_halves(load_u8x16(&r[1]),c[1])+
        sad_halves(load_u8x16(&r[2]),c[2])+sad_halves(load_u8x16(&r[3]),c[3])
}

// compute_chunk_sads_indirect from position i on.
@(private)
chunk_sads_from :: #force_inline proc "contextless" (chunk_sads:[]i32,indices:[]u16,
    pair_colors:[]Color_Block,colors:^Color_Block,i0:int) #no_bounds_check {
    n:=min(len(chunk_sads),len(indices))
    if len(pair_colors)==0 {return}
    last:=len(pair_colors)-1
    cp:=([^]V16u8)(colors)
    c:=[4]V16u8{load_u8x16(&cp[0]),load_u8x16(&cp[1]),load_u8x16(&cp[2]),load_u8x16(&cp[3])}
    i:=i0
    for ; i+4<=n; i+=4 {
        s0:=block_sad_halves(&pair_colors[min(int(indices[i]),last)],&c)
        s1:=block_sad_halves(&pair_colors[min(int(indices[i+1]),last)],&c)
        s2:=block_sad_halves(&pair_colors[min(int(indices[i+2]),last)],&c)
        s3:=block_sad_halves(&pair_colors[min(int(indices[i+3]),last)],&c)
        intrinsics.unaligned_store((^V4i32)(&chunk_sads[i]),sad_sum4(s0,s1,s2,s3))
    }
    for ; i<n; i+=1 {
        s:=block_sad_halves(&pair_colors[min(int(indices[i]),last)],&c)
        chunk_sads[i]=i32(simd.extract(s,0)+simd.extract(s,2))
    }
}

// The SSD of pixels against the BC4 palette pal (8 entries) indexed by the 16 byte offsets
// index8[16*j:] of each j=inds[k], into dest[k]; from k=k0 on. Offsets out of the
// table give max(i32).
bc4_change_distortion_batch_from :: #force_inline proc "contextless" (dest:[]i32,
    pixels:^[16]i16,pal:^[8]i16,index8:[]u8,inds:[]i32,k0:int) #no_bounds_check {
    t:=transmute(V16u8)pal^
    px:=transmute([2]V8i16)pixels^
    n:=min(len(dest),len(inds))
    for k in k0..<n {
        j:=int(inds[k])
        if j<0 || j>=len(index8)/16 {dest[k]=max(i32); continue}
        q:=load_u8x16(&index8[j*16])&V16u8(14)
        lo:=simd.runtime_swizzle(t,simd.shuffle(q,q,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7)+
            V16u8{0,1,0,1,0,1,0,1,0,1,0,1,0,1,0,1})
        hi:=simd.runtime_swizzle(t,simd.shuffle(q,q,8,8,9,9,10,10,11,11,12,12,13,13,14,14,15,15)+
            V16u8{0,1,0,1,0,1,0,1,0,1,0,1,0,1,0,1})
        d0:=transmute(V8i16)lo-px[0]
        d1:=transmute(V8i16)hi-px[1]
        dest[k]=simd.reduce_add_ordered(madd_i16(d0,d0)+madd_i16(d1,d1))
    }
}

// filter_by_index_sad from group i on, with out positions already written.
@(private)
filter_by_index_sad_from :: #force_inline proc "contextless" (positions:[]i32,count:int,
    index_batch:[]u8,ref_inds:^[16]u8,threshold:i32,i0,out0:int) -> int #no_bounds_check {
    n:=min(count,len(positions),len(index_batch)/16)
    ref:=load_u8x16(ref_inds)
    p:=raw_data(index_batch)
    thr:=V4i32(threshold)
    i,out:=i0,out0
    // out <= i, so the four lanes written stay below n.
    for ; i+4<=n; i+=4 {
        s:=sad_sum4(sad_halves(ref,load_u8x16(&p[i*16])),sad_halves(ref,load_u8x16(&p[i*16+16])),
            sad_halves(ref,load_u8x16(&p[i*16+32])),sad_halves(ref,load_u8x16(&p[i*16+48])))
        m:=u32(transmute(u8)simd.extract_msbs(simd.lanes_lt(s,thr)))
        out+=store_active_lanes4(raw_data(positions[out:]),i32(i),m)
    }
    for ; i<n; i+=1 {
        sad:=i32(sad_u8x16(ref,load_u8x16(&p[i*16])))
        positions[out]=i32(i)
        out+=int(sad<threshold)
    }
    return out
}

filter_by_index_sad_with_inds :: proc "contextless" (positions:[]i32,out_indices:[]u32,count:int,
    index_batch:[]u8,in_indices:[]u32,ref_inds:^[16]u8,threshold:i32) -> int {
    n:=filter_by_index_sad(positions,count,index_batch,ref_inds,threshold)
    n=min(n,len(out_indices))
    for i in 0..<n {
        p:=int(positions[i])
        out_indices[i]=p<len(in_indices)?in_indices[p]:0
    }
    return n
}

// The largest index SAD whose cheapest SSD increase (delta_ssd_per_pixel_per_sad gives, per
// texel, the cost of each further unit of index distance) keeps base_ssd within ssd_limit.
// out_ssd_limit gets the smallest SSD that gives the same answer.
compute_sad_bound_for_ssd_threshold :: proc "contextless" (delta_ssd_per_pixel_per_sad:^[16][8]i32,
    base_ssd,in_ssd_limit:i32,out_ssd_limit:^i32=nil) -> i32 {
    ssd_limit:=min(in_ssd_limit,(1<<28)-2)
    limit:=u32(ssd_limit+1)
    delta:[16][8]u32
    cur:[16]u32
    for i in 0..<16 {
        for k in 0..<8 {delta[i][k]=(min(u32(delta_ssd_per_pixel_per_sad[i][k]),limit)<<4)+u32(i)}
        cur[i]=delta[i][0]
    }
    total_ssd:=base_ssd
    smallest_ssd:u32
    sad:i32=1
    for ;;sad+=1 {
        smallest_ssd=cur[0]
        for p in 1..<16 {smallest_ssd=min(smallest_ssd,cur[p])}
        smallest_p:=smallest_ssd&15
        smallest_ssd>>=4
        next_ssd:=total_ssd+i32(smallest_ssd)
        if next_ssd>ssd_limit {break}
        total_ssd=next_ssd
        // an exhausted texel shifts in zeros, which would never end
        if sad>16*8 {break}
        next_value:=delta[smallest_p][1]
        for k in 0..<7 {delta[smallest_p][k]=delta[smallest_p][k+1]}
        delta[smallest_p][7]=0
        cur[smallest_p]=next_value
    }
    if i32(smallest_ssd)>ssd_limit || sad>16*8 {
        if out_ssd_limit!=nil {out_ssd_limit^=ssd_limit}
        return 16*7
    }
    if out_ssd_limit!=nil {out_ssd_limit^=total_ssd}
    return sad-1
}

// Sorted L1 norms of up to CHUNK_SIZE blocks, to find the blocks within an L1 distance.
FINAL_MATRIX_CHUNK_SIZE :: 256

// Norms above any SAD (64*255) pad the keys, so that every search reads 16 of them.
@(private="file")
L1_INDEX_SENTINEL :: 32767

Final_Matrix_L1_Index :: struct {
    sorted_norms:[FINAL_MATRIX_CHUNK_SIZE+16]i16,
    sorted_norms_sub:[FINAL_MATRIX_CHUNK_SIZE/16]i16, // the last norm of each full group of 16
    sorted_inds:[FINAL_MATRIX_CHUNK_SIZE]u16,
    count:int,
}

final_matrix_l1_index_build :: proc(index:^Final_Matrix_L1_Index,blocks:[]Color_Block) {
    n:=min(len(blocks),FINAL_MATRIX_CHUNK_SIZE)
    keys:[FINAL_MATRIX_CHUNK_SIZE]u32
    zero:Color_Block
    for i in 0..<n {keys[i]=(color_block_sad_rgba(&blocks[i],&zero)<<16)|u32(i)}
    stdsort(keys[:n],u32_less)
    index.count=n
    for i in 0..<n {
        index.sorted_norms[i]=i16(keys[i]>>16)
        index.sorted_inds[i]=u16(keys[i]&0xffff)
    }
    for i in n..<len(index.sorted_norms) {index.sorted_norms[i]=L1_INDEX_SENTINEL}
    for g in 0..<len(index.sorted_norms_sub) {
        index.sorted_norms_sub[g]=g<n/16 ? index.sorted_norms[g*16+15] : L1_INDEX_SENTINEL
    }
}

// The blocks whose norm lies within must_beat_dist (exclusive) of the target's: returns
// the positions in the chunk.
final_matrix_l1_index_lookup :: proc "contextless" (index:^Final_Matrix_L1_Index,
    target:^Color_Block,must_beat_dist:i32) -> []u16 {
    if must_beat_dist<=0 {return nil}
    zero:Color_Block
    ref_norm:=i64(color_block_sad_rgba(target,&zero))
    lo:=i16(clamp(ref_norm-i64(must_beat_dist)+1,-32768,32767))
    hi:=i16(clamp(ref_norm+i64(must_beat_dist),-32768,32767))
    // Lower bounds: the group of 16 where the norms reach the key, then within it.
    l:=count_below_i16x16(&index.sorted_norms_sub[0],lo)*16
    r:=count_below_i16x16(&index.sorted_norms_sub[0],hi)*16
    l+=count_below_i16x16(&index.sorted_norms[l],lo)
    r+=count_below_i16x16(&index.sorted_norms[r],hi)
    r=min(r,index.count)
    if r<=l {return nil}
    return index.sorted_inds[l:r]
}

// A candidate pair of endpoints or indices of the BC1 RDO, with its palette (BGRA).
BC1_VQ_Entry :: struct {
    dw:u32,
    codelen:f32,
    block_count:i32,
    block_link:i32,
    palette:[4]Color,
}

// dest_vqd[2i], dest_vqd[2i+1]: the VQD of colors against first_palette and second_palette
// with the indices vqindices[inds[i]].dw. Four candidates at a time: the weighted errors of
// a texel against the four entries of a palette are a table its indices shuffle.
@(private)
batch_compute_vqds_body :: #force_inline proc "contextless" (dest_vqd:[]f32,
    vqindices:[]BC1_VQ_Entry,inds:[]i32,colors:^Color_Block,first_palette,second_palette:^[4]Color,
    activity:^Float_Block) #no_bounds_check {
    errs:[16][2]V16u8
    pal:=[2]V16u8{load_u8x16(first_palette),load_u8x16(second_palette)}
    for i in 0..<16 {
        px:=transmute(V16u8)V4u32(color_dw(colors[i]))
        w:=V4f32(activity[i])
        for p in 0..<2 {errs[i][p]=transmute(V16u8)(cast(V4f32)ssd_rgba4(px,pal[p])*w)}
    }
    n:=min(len(inds),len(dest_vqd)/2)
    for i:=0; i<n; i+=4 {
        dw:[4]u32
        for k in 0..<4 {
            j:=int(inds[min(i+k,n-1)])
            dw[k]=j>=0 && j<len(vqindices) ? vqindices[j].dw : 0
        }
        idx:=transmute(V4u32)dw
        // Columns sum down the rows: texel t adds to column t&3.
        col:[2][4]V4f32
        cur:=idx
        #unroll for t in 0..<16 {
            s4:=transmute(V16u8)simd.shl(cur&V4u32(3),V4u32(2))
            cur=simd.shr(cur,V4u32(2))
            ctrl:=simd.shuffle(s4,s4,0,0,0,0,4,4,4,4,8,8,8,8,12,12,12,12)+
                V16u8{0,1,2,3,0,1,2,3,0,1,2,3,0,1,2,3}
            e0:=transmute(V4f32)simd.runtime_swizzle(errs[t][0],ctrl)
            e1:=transmute(V4f32)simd.runtime_swizzle(errs[t][1],ctrl)
            if t<4 {col[0][t&3]=e0; col[1][t&3]=e1} else {col[0][t&3]+=e0; col[1][t&3]+=e1}
        }
        r:[2]V4f32
        for p in 0..<2 {r[p]=(col[p][0]+col[p][1])+(col[p][2]+col[p][3])}
        out:=transmute([8]f32)[2]V4f32{simd.shuffle(r[0],r[1],0,4,1,5),
            simd.shuffle(r[0],r[1],2,6,3,7)}
        for k in 0..<min(4,n-i) {
            j:=int(inds[i+k])
            ok:=j>=0 && j<len(vqindices)
            dest_vqd[(i+k)*2]=ok ? out[k*2] : max(f32)
            dest_vqd[(i+k)*2+1]=ok ? out[k*2+1] : max(f32)
        }
    }
}

@(private)
batch_find_best_errors_body :: #force_inline proc "contextless" (dest_ssd:[]i32,
    vqendpoints:[]BC1_VQ_Entry,inds:[]i32,colors:^Color_Block) #no_bounds_check {
    n:=min(len(inds),len(dest_ssd))
    ctx:BC1_Find_Errors_Context
    bc1_find_errors_init(&ctx,colors)
    for i in 0..<n {
        j:=int(inds[i]&0xffff)
        if j>=len(vqendpoints) {dest_ssd[i]=max(i32); continue}
        dest_ssd[i]=i32(bc1_eval_palette(&ctx,&vqendpoints[j].palette))
    }
}

@(private="file")
dist_to_bbox :: #force_inline proc "contextless" (v,lo,hi:Color) -> i32 {
    d:i32
    for c in 0..<4 {
        a:=i32(lo[c])-i32(v[c])
        b:=i32(v[c])-i32(hi[c])
        x:=max(a,0)+max(b,0)
        d+=x*x
    }
    return d
}

@(private="file")
avg_u8 :: #force_inline proc "contextless" (a,b:Color) -> Color {
    return {
        u8((u32(a[0])+u32(b[0])+1)>>1),u8((u32(a[1])+u32(b[1])+1)>>1),
        u8((u32(a[2])+u32(b[2])+1)>>1),u8((u32(a[3])+u32(b[3])+1)>>1),
    }
}

// True when both endpoints and their midpoint are farther than min_d (squared) from the
// color box [lo,hi]. The comparison is signed, as in the vector code.
reject_endpoints_color_bbox :: #force_inline proc "contextless" (endpoints:^[4]Color,bbox:^[2]Color,
    min_d:u32) -> bool {
    md:=i32(min_d)
    d0:=dist_to_bbox(endpoints[0],bbox[0],bbox[1])
    d1:=dist_to_bbox(endpoints[1],bbox[0],bbox[1])
    dm:=dist_to_bbox(avg_u8(endpoints[0],endpoints[1]),bbox[0],bbox[1])
    return d0>md && d1>md && dm>md
}

// The squared distance of four colors to the box [lo,hi].
@(private="file")
dist_to_bbox4 :: #force_inline proc "contextless" (v,lo,hi:V16u8) -> V4i32 {
    d:=simd.saturating_sub(lo,v)+simd.saturating_sub(v,hi)
    e:=transmute(V8i16)(transmute(V8u16)d&V8u16(0xff))
    o:=transmute(V8i16)simd.shr(transmute(V8u16)d,V8u16(8))
    return madd_i16(e,e)+madd_i16(o,o)
}

// Endpoints 0 and 1 of the palette of entry idx (the last one when idx is out of range).
@(private)
endpoint_pair :: #force_inline proc "contextless" (vqendpoints:[]BC1_VQ_Entry,idx:i32,
    last:uint) -> u64 #no_bounds_check {
    return intrinsics.unaligned_load((^u64)(&vqendpoints[min(uint(idx),last)].palette))
}

// Packs the lanes of values whose bit is set in m into to[0:4] (all four are written).
@(private)
store_compact4 :: #force_inline proc "contextless" (to:[^]i32,values:V4i32,m:u32) {
    t:=ACTIVE_LANE_TABLE8[m&15]
    lane:=simd.shr(V4u32(t),V4u32{0,4,8,12})&V4u32(15)
    ctrl:=transmute(V16u8)(lane*V4u32(0x04040404)+V4u32(0x03020100))
    intrinsics.unaligned_store((^V4i32)(to),
        transmute(V4i32)simd.runtime_swizzle(transmute(V16u8)values,ctrl))
}

// filter_endpoint_color_bbox from candidate i0 on, with out0 already written.
@(private)
filter_endpoint_color_bbox_from :: #force_inline proc "contextless" (dest_inds:[]i32,
    vqendpoints:[]BC1_VQ_Entry,inds:[]i32,bbox:^[2]Color,bbox_min_d:u32,require_3c:bool,
    i0,out0:int) -> int #no_bounds_check {
    n:=min(len(inds),len(dest_inds),65535)
    i,out:=i0,out0
    if len(vqendpoints)>0 {
        last:=uint(len(vqendpoints)-1)
        count:=V4u32(u32(min(len(vqendpoints),int(max(u32)))))
        lo:=transmute(V16u8)V4u32(color_dw(bbox[0]))
        hi:=transmute(V16u8)V4u32(color_dw(bbox[1]))
        min_d:=V4i32(i32(bbox_min_d))
        // out <= i, so the four lanes written stay below n.
        for ; i+4<=n; i+=4 {
            iv:=intrinsics.unaligned_load((^V4i32)(&inds[i]))
            q01:=#simd[2]u64{endpoint_pair(vqendpoints,inds[i],last),
                endpoint_pair(vqendpoints,inds[i+1],last)}
            q23:=#simd[2]u64{endpoint_pair(vqendpoints,inds[i+2],last),
                endpoint_pair(vqendpoints,inds[i+3],last)}
            e0:=simd.shuffle(transmute(V4u32)q01,transmute(V4u32)q23,0,2,4,6)
            e1:=simd.shuffle(transmute(V4u32)q01,transmute(V4u32)q23,1,3,5,7)
            b0,b1:=transmute(V16u8)e0,transmute(V16u8)e1
            avg:=cast(V16u8)simd.shr(cast(#simd[16]u16)b0+cast(#simd[16]u16)b1+1,1)
            d:=simd.min(simd.min(dist_to_bbox4(b0,lo,hi),dist_to_bbox4(b1,lo,hi)),
                dist_to_bbox4(avg,lo,hi))
            accept:=transmute(V4i32)simd.lanes_le(d,min_d)
            if require_3c {
                // Alpha 255 in both makes the signed compare order them as unsigned.
                accept&=~transmute(V4i32)simd.lanes_gt(transmute(V4i32)e0,transmute(V4i32)e1)
            }
            accept&=transmute(V4i32)simd.lanes_lt(transmute(V4u32)iv,count)
            m:=u32(transmute(u8)simd.extract_msbs(accept))
            values:=simd.shl(V4i32{0,1,2,3}+V4i32(i32(i)),V4u32(16))|iv
            store_compact4(raw_data(dest_inds[out:]),values,m)
            out+=int(intrinsics.count_ones(m))
        }
    }
    for ; i<n; i+=1 {
        idx:=int(inds[i])
        if idx<0 || idx>=len(vqendpoints) {continue}
        e:=&vqendpoints[idx]
        is4c:=bc1_is_4color(e.dw,.Alpha)
        rejected:=reject_endpoints_color_bbox(&e.palette,bbox,bbox_min_d)
        rejected|=is4c && require_3c
        if !rejected {
            dest_inds[out]=i32((i<<16)|idx)
            out+=1
        }
    }
    return out
}

// The first i >= i0 with vals[i] < x; a later entry must be below x (a sentinel).
find_next_below_i32 :: #force_inline proc "contextless" (vals:[]i32,i0:int,
    x:i32) -> int #no_bounds_check {
    i:=i0
    p:=raw_data(vals)
    for ; i+4<=len(vals); i+=4 {
        v:=intrinsics.unaligned_load((^V4i32)(&p[i]))
        m:=u32(transmute(u8)simd.extract_msbs(simd.lanes_lt(v,V4i32(x))))
        if m!=0 {return i+int(intrinsics.count_trailing_zeros(m))}
    }
    for i<len(vals) && vals[i]>=x {i+=1}
    return i
}

find_next_below_f32 :: #force_inline proc "contextless" (vals:[]f32,i0:int,
    x:f32) -> int #no_bounds_check {
    i:=i0
    p:=raw_data(vals)
    for ; i+4<=len(vals); i+=4 {
        v:=intrinsics.unaligned_load((^V4f32)(&p[i]))
        m:=u32(transmute(u8)simd.extract_msbs(simd.lanes_lt(v,V4f32(x))))
        if m!=0 {return i+int(intrinsics.count_trailing_zeros(m))}
    }
    for i<len(vals) && !(vals[i]<x) {i+=1}
    return i
}

