package entropy

import "base:intrinsics"
import "mirai:std/compressor"

HUFFMAN_ENCODE_CODELEN_LIMIT :: 15

// Code lengths and canonical codes of an alphabet of at most 256 symbols.
Huffman :: struct {
    num_codes_of_len:[32]i32,
    num_symbols, got_num_symbols, one_char, top_sym, min_code_len, max_code_len:i32,
    code_len_table:[260]u8,
    encode_table:[260]u32,
    code_prefix_by_len:[32]u64,
}

// A symbol and its count (or, during the build, its parent or depth).
@(private) Char_And_Count :: struct {symbol:u16, count:u16}

@(private) MAX_CHAR_COUNT :: 0xFFFF
@(private) MAX_TOT_COUNT :: MAX_CHAR_COUNT

huffman_init :: proc "contextless" (h:^Huffman, num_symbols:int) {
    h^={}
    h.num_symbols=i32(clamp(num_symbols,0,256))
}

@(private="file")
finish_code_lens :: proc "contextless" (h:^Huffman) #no_bounds_check {
    h.num_codes_of_len={}
    for i in 0..=h.top_sym {
        cl:=h.code_len_table[i]
        if cl==0 {continue}
        h.num_codes_of_len[cl]+=1
    }
    mn:i32=1
    for mn<31 && h.num_codes_of_len[mn]==0 {mn+=1}
    mx:i32=31
    for mx>0 && h.num_codes_of_len[mx]==0 {mx-=1}
    h.min_code_len=mn
    h.max_code_len=mx
}

@(private="file")
scale_counts :: proc "contextless" (h:^Huffman, counts:[]u32, dest:[]u32, allowed_char:u32,
    allowed_tot:u32) -> []u32 #no_bounds_check {
    n:=int(h.num_symbols)
    tot,mx:u32=0,0
    maxi:=0
    for i in 0..<n {
        cc:=counts[i]
        tot+=cc
        if cc>mx {mx=cc;maxi=i}
    }
    if mx>allowed_char || tot>allowed_tot {
        a:=f32(allowed_char)/f32(mx)
        b:=f32(allowed_tot)/f32(tot)
        scale:=a<b ? a : b
        dest_total:u32=0
        for i in 0..<n {
            if counts[i]==0 {dest[i]=0;continue}
            out:=u32(i32(f32(counts[i])*scale+0.5))
            out=clamp(out,1,allowed_char)
            dest[i]=out
            dest_total+=out
        }
        if dest_total>allowed_tot {dest[maxi]+=allowed_tot-dest_total}
        return dest[:n]
    }
    return counts
}

@(private="file")
cc_less :: proc "contextless" (a,b:Char_And_Count) -> bool {return a.count<b.count}

// Ascending by count: introsort up to 32 entries, a stable radix sort above.
@(private="file")
huffman_sort :: proc "contextless" (t:[]Char_And_Count) #no_bounds_check {
    n:=len(t)
    if n<=1 {return}
    if n<=32 {stdsort(t,cc_less);return}
    hist:[512]u32
    for e in t {
        hist[e.count&0xFF]+=1
        hist[256+u32(e.count>>8)]+=1
    }
    tmp:[260]Char_And_Count
    t2:=tmp[:n]
    cur,nxt:=t,t2
    for pass in 0..<2 {
        ph:=hist[pass*256:][:256]
        if pass==1 && ph[0]==u32(n) {copy(t,cur);return}
        offsets:[256]u32
        o:u32=0
        for i in 0..<256 {offsets[i]=o;o+=ph[i]}
        for e in cur {
            k:=pass==0 ? e.count&0xFF : e.count>>8
            nxt[offsets[k]]=e
            offsets[k]+=1
        }
        cur,nxt=nxt,cur
    }
}

@(private="file")
build_code_lens_moffat :: proc "contextless" (h:^Huffman, limit:i32,
    table:[]Char_And_Count) #no_bounds_check {
    n:=int(h.got_num_symbols)
    A:=table
    A[n].count=MAX_CHAR_COUNT
    A[0].count=A[0].count+A[1].count
    root,leaf,next:=0,2,1
    for leaf<n {
        sum:int
        if A[root].count<A[leaf].count {
            sum=int(A[root].count)
            A[root].count=u16(next);root+=1
        } else {
            sum=int(A[leaf].count);leaf+=1
        }
        if root<next && A[root].count<A[leaf].count {
            sum+=int(A[root].count)
            A[root].count=u16(next);root+=1
        } else {
            sum+=int(A[leaf].count);leaf+=1
        }
        A[next].count=u16(sum);next+=1
    }
    for next<n-1 {
        A[root].count=u16(next);root+=1
        A[root].count=u16(next);root+=1
        next+=1
    }
    A[n-2].count=0
    for next=n-3;next>=0;next-=1 {
        parent:=int(A[next].count)
        A[next].count=A[parent].count+1
    }
    max_depth:=i32(A[0].count)+1
    avbl,dpth:=1,0
    root=n-2
    next=n
    for {
        used:=0
        for root>=0 && int(A[root].count)==dpth {root-=1;used+=1}
        count:=avbl-used
        if count>0 {
            next-=count
            for i in 0..<count {
                A[next+i].count=u16(dpth)
                h.code_len_table[A[next+i].symbol]=u8(dpth)
            }
            h.num_codes_of_len[dpth]=i32(count)
            if next==0 {break}
        }
        avbl=2*used
        dpth+=1
        if dpth==int(limit) {
            count=next
            next=0
            for i in 0..<count {
                A[i].count=u16(dpth)
                h.code_len_table[A[i].symbol]=u8(dpth)
            }
            h.num_codes_of_len[dpth]=i32(count)
            break
        }
        if dpth>=31 {break}
    }
    h.min_code_len=i32(A[n-1].count)
    h.max_code_len=max_depth
}

@(private="file") TREE_FLAG :: 1<<15

@(private="file")
build_code_lens_package_merge :: proc(h:^Huffman, counts:[]u32, max_code_len:i32,
    table:[]Char_And_Count, arena:^Arena) -> bool #no_bounds_check {
    sym:=table
    sym_count:=0
    for i in 0..<int(h.num_symbols) {
        if counts[i]==0 {continue}
        sym[sym_count]=Char_And_Count{u16(i),u16(counts[i])}
        sym_count+=1
    }
    h.got_num_symbols=i32(sym_count)
    huffman_sort(sym[:sym_count])
    sym[sym_count].count=MAX_CHAR_COUNT
    per_level:=2*sym_count-2
    levels:=int(max_code_len)
    storage:=arena_alloc(arena,Char_And_Count,per_level*(levels-1))
    if storage==nil && per_level*(levels-1)>0 {return false}
    defer arena_free(arena,storage)
    packages:[32][]Char_And_Count
    packages[0]=sym[:sym_count+1]
    for i in 1..<levels {packages[i]=storage[(i-1)*per_level:][:per_level]}
    package_count:[32]int
    package_count[0]=sym_count
    for l in 1..<levels {
        i0,i1:=0,0
        i:=0
        for ;i<per_level;i+=1 {
            c0:=int(sym[i0].count)
            if i1+1<package_count[l-1] {
                c1:=int(packages[l-1][i1].count)+int(packages[l-1][i1+1].count)
                if c1<=c0 {
                    packages[l][i]=Char_And_Count{u16(i1|TREE_FLAG),u16(c1)}
                    i1+=2
                    continue
                }
            }
            if c0==MAX_CHAR_COUNT {break}
            packages[l][i]=Char_And_Count{sym[i0].symbol,u16(c0)}
            i0+=1
        }
        package_count[l]=i
    }
    for i in 0..<int(h.num_symbols) {h.code_len_table[i]=0}
    cur:=package_count[levels-1]
    for l:=levels-1;l>=0;l-=1 {
        last_tree:=0
        for i in 0..<cur {
            s:=packages[l][i].symbol
            if s<TREE_FLAG {
                h.code_len_table[s]+=1
            } else {
                last_tree=int(s-TREE_FLAG)+2
            }
        }
        cur=last_tree
    }
    finish_code_lens(h)
    return true
}

@(private="file")
build_code_lens_limited_heuristic :: proc "contextless" (h:^Huffman, counts:[]u32, limit:i32,
    table:[]Char_And_Count) #no_bounds_check {
    kraft_one_shifted:[18]u32
    for i in 0..=int(limit)+1 {kraft_one_shifted[i]=u32(u64(1)<<uint(32-i))}
    cl_start:[18]int
    last_cl:=int(limit)+1
    cl_start[last_cl]=0
    kraft:u64=0
    kraft_one:=u64(1)<<32
    {
        next:=0
        for cl:=int(limit);cl>=1;cl-=1 {
            n:=h.num_codes_of_len[cl]
            kraft+=u64(u32(n)*kraft_one_shifted[cl])
            cl_start[cl]=next
            next+=int(n)
        }
        cl_start[0]=next
    }
    for kraft!=kraft_one {
        if kraft>kraft_one {
            delta:=u32(kraft-kraft_one)
            best_score:=min(i32)
            best_i:=-1
            start_cl:=int(intrinsics.count_leading_zeros(delta))
            if start_cl>1 && kraft_one_shifted[start_cl]<delta*2 {start_cl-=1}
            for cl in start_cl..<int(limit) {
                first:=cl_start[cl]
                if cl_start[cl-1]-first==0 {continue}
                s:=table[first].symbol
                score:=-i32(counts[s]<<uint(cl))
                if score>best_score {best_score=score;best_i=first}
            }
            if best_i<0 {break}
            cl:=int(table[best_i].count)
            kraft-=u64(kraft_one_shifted[cl+1])
            cl_start[cl]+=1
            cl+=1
            table[best_i].count=u16(cl)
        }
        if kraft<kraft_one {
            delta:=u32(kraft_one-kraft)
            best_score:=min(i32)
            best_i:=-1
            start_cl:=int(intrinsics.count_leading_zeros(delta))+1
            if start_cl>2 && kraft_one_shifted[start_cl-1]<delta*2 {start_cl-=1}
            for cl in start_cl..=int(limit) {
                first:=cl_start[cl]
                l:=cl_start[cl-1]-first
                if l==0 {continue}
                i:=first+l-1
                s:=table[i].symbol
                score:=i32(counts[s]<<uint(cl))
                if score>best_score {best_score=score;best_i=i}
            }
            if best_i<0 {break}
            cl:=int(table[best_i].count)
            kraft+=u64(kraft_one_shifted[cl])
            cl-=1
            cl_start[cl]-=1
            table[best_i].count=u16(cl)
        }
    }
    if kraft!=kraft_one {
        for kraft>kraft_one {
            best_score:=min(i32)
            best_i:=-1
            for cl in 1..<int(limit) {
                first:=cl_start[cl]
                if cl_start[cl-1]-first==0 {continue}
                s:=table[first].symbol
                score:=-i32(counts[s]<<uint(cl))
                if score>best_score {best_score=score;best_i=first}
            }
            if best_i<0 {break}
            cl:=int(table[best_i].count)
            kraft-=u64(kraft_one_shifted[cl+1])
            cl_start[cl]+=1
            cl+=1
            table[best_i].count=u16(cl)
        }
        for kraft<kraft_one {
            best_score:=min(i32)
            best_i:=-1
            for cl in 2..=int(limit) {
                first:=cl_start[cl]
                l:=cl_start[cl-1]-first
                if l==0 {continue}
                if kraft+u64(kraft_one_shifted[cl])>kraft_one {continue}
                i:=first+l-1
                s:=table[i].symbol
                score:=i32(counts[s]<<uint(cl))
                if score>best_score {best_score=score;best_i=i}
            }
            if best_i<0 {break}
            cl:=int(table[best_i].count)
            kraft+=u64(kraft_one_shifted[cl])
            cl-=1
            cl_start[cl]-=1
            table[best_i].count=u16(cl)
        }
    }
    n:=int(h.got_num_symbols)
    h.min_code_len=i32(table[n-1].count)
    h.max_code_len=i32(table[0].count)
    for cl in 1..=int(limit) {h.num_codes_of_len[cl]=i32(cl_start[cl-1]-cl_start[cl])}
    for i in 0..<n {h.code_len_table[table[i].symbol]=u8(table[i].count)}
}

// Builds length-limited code lens from counts[:num_symbols]. Sets got_num_symbols, top_sym,
// one_char, num_codes_of_len, min/max_code_len and code_len_table. False only when the
// arena runs out.
huffman_build_code_lens :: proc(h:^Huffman, counts:[]u32, count_sum:u32,
    limit:i32=HUFFMAN_ENCODE_CODELEN_LIMIT,
    arena:^Arena=nil, do_package_merge:=false) -> bool #no_bounds_check {
    n:=int(h.num_symbols)
    if len(counts)<n {return false}
    h.min_code_len,h.max_code_len=0,0
    h.num_codes_of_len={}
    h.code_len_table={}
    limit:=limit
    if limit<=0 || limit>HUFFMAN_ENCODE_CODELEN_LIMIT {limit=HUFFMAN_ENCODE_CODELEN_LIMIT}
    counts:=counts
    scaled:[256]u32
    if count_sum>MAX_TOT_COUNT {counts=scale_counts(h,counts,scaled[:],MAX_CHAR_COUNT,
        MAX_TOT_COUNT)}
    table_storage:[260]Char_And_Count
    table:=table_storage[:]
    ti:=0
    for i in 0..<n {
        if counts[i]==0 {continue}
        table[ti]=Char_And_Count{u16(i),u16(counts[i])}
        ti+=1
    }
    h.top_sym=ti>0 ? i32(table[ti-1].symbol) : 0
    h.got_num_symbols=i32(ti)
    if ti<2 {
        h.one_char=i32(table[0].symbol)
        return true
    }
    huffman_sort(table[:ti])
    h.one_char=i32(table[ti-1].symbol)
    build_code_lens_moffat(h,limit,table)
    if h.max_code_len>limit {
        if do_package_merge {
            if arena==nil {return false}
            return build_code_lens_package_merge(h,counts,limit,table,arena)
        }
        build_code_lens_limited_heuristic(h,counts,limit,table)
    }
    return true
}

// Canonical codes (MSB-first) into encode_table, from code_len_table and num_codes_of_len.
huffman_build_encode_table :: proc "contextless" (h:^Huffman) -> bool #no_bounds_check {
    if h.got_num_symbols<2 {
        if h.got_num_symbols==0 {h.one_char=0}
        h.encode_table[clamp(h.one_char,0,255)]=0
        return true
    }
    if h.max_code_len==0 || h.max_code_len>30 {return false}
    last:u32=0
    h.code_prefix_by_len[0]=0
    h.code_prefix_by_len[h.min_code_len]=0
    for i:=h.min_code_len;i<h.max_code_len; {
        last=(last+u32(h.num_codes_of_len[i]))<<1
        i+=1
        h.code_prefix_by_len[i]=u64(last)
    }
    for i in 0..<int(h.num_symbols) {
        cl:=h.code_len_table[i]
        h.encode_table[i]=u32(h.code_prefix_by_len[cl])
        h.code_prefix_by_len[cl]+=1
    }
    return true
}

@(private="file") pred_init :: #force_inline proc "contextless" (log2:int) -> int {return log2*4}

fold_up_negatives :: #force_inline proc "contextless" (i:i32) -> u32 {return (u32(i)<<1)~u32(i>>31)}

entropy_of_counts_rice :: proc "contextless" (counts:[]i32, rice_bits:int) -> int {
    h:=0
    for c,i in counts {
        if c>0 {h+=int(c)*((i>>uint(rice_bits))+1+rice_bits)}
    }
    return h
}

@(private="file")
pack_code_lens4 :: proc "contextless" (h:^Huffman, vb:^Var_Bits) #no_bounds_check {
    log2_num_syms:=int(ilog2ceil(u32(h.num_symbols)))
    varbits_output(vb)
    varbits_put(vb,u64(h.got_num_symbols),log2_num_syms)
    if h.got_num_symbols==0 {return}
    if h.got_num_symbols==1 {
        varbits_output(vb)
        varbits_put(vb,u64(h.one_char),log2_num_syms)
        return
    }
    log2_code_len:=int(ilog2ceil(u32(h.max_code_len)))
    varbits_put(vb,u64(log2_code_len),3)
    for i in 0..<int(h.num_symbols) {
        if h.code_len_table[i]==0 {continue}
        l:=u64(h.code_len_table[i])-1
        varbits_output(vb)
        varbits_put(vb,u64(i),log2_num_syms)
        varbits_put(vb,l,log2_code_len)
    }
}

@(private="file") RUNLEN_EXPGOLOMB_BITS :: 1

@(private="file")
pack_code_lens8 :: proc "contextless" (h:^Huffman, vb:^Var_Bits) #no_bounds_check {
    n:=int(h.num_symbols)
    log2_num_syms:=int(ilog2ceil(u32(n)))
    num_delta:[32]i32
    prev4:=pred_init(log2_num_syms)
    for i in 0..=int(h.top_sym) {
        cl:=int(h.code_len_table[i])
        if cl>0 {
            pred:=compressor.hufflen_pred_get(prev4)
            num_delta[fold_up_negatives(i32(cl-pred))&31]+=1
            prev4=compressor.hufflen_pred_update(prev4,cl)
        }
    }
    varbits_output(vb)
    rice_bits:=1
    {
        best:=f64(99999999999.0)
        for cur in 0..<4 {
            e:=f64(entropy_of_counts_rice(num_delta[:],cur))
            if e<best {best=e;rice_bits=cur}
        }
        varbits_put(vb,u64(rice_bits),2)
    }
    first_is_on:=h.code_len_table[0]!=0
    varbits_put(vb,first_is_on ? 1 : 0,1)
    prev4=pred_init(log2_num_syms)
    i:=0
    for {
        if !(first_is_on && i==0) {
            run:=0
            for i<n && h.code_len_table[i]==0 {run+=1;i+=1}
            run-=1
            write_exp_golomb(vb,u32(run),RUNLEN_EXPGOLOMB_BITS)
        }
        if i>=n {break}
        run:=0
        for i+run<n && h.code_len_table[i+run]!=0 {run+=1}
        write_exp_golomb(vb,u32(run-1),RUNLEN_EXPGOLOMB_BITS)
        for _ in 0..<run {
            pred:=compressor.hufflen_pred_get(prev4)
            cl:=int(h.code_len_table[i])
            write_rice(vb,fold_up_negatives(i32(cl-pred)),u32(rice_bits))
            prev4=compressor.hufflen_pred_update(prev4,cl)
            i+=1
        }
        if i>=n {break}
    }
}

huffman_pack_code_lens :: proc "contextless" (h:^Huffman, vb:^Var_Bits) {
    varbits_output(vb)
    if h.got_num_symbols<=4 {
        varbits_put(vb,0,1)
        pack_code_lens4(h,vb)
    } else {
        varbits_put(vb,1,1)
        pack_code_lens8(h,vb)
    }
}
