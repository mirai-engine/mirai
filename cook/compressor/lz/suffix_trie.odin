package lz_optimal

import "base:intrinsics"
import "mirai:std/compressor/lz/entropy"
import "mirai:std/compressor/lz/match"

// Find-all finder of the Optimal2+ levels: a suffix trie built incrementally, one suffix per
// position. Positions are 1-based (0 is null); a negative child is a leaf at -child. Nodes keep the
// most recent position of their substring (updated up to ST_PARENT_STEPS parents), so the pairs
// are the deepest match then shorter ones at lower offsets. Only the longest length is exact.
// The first 2 bytes (inputs up to 8 MiB) or 3 bytes index a jump-in table.

@(private="file") NUM_INLINE_CHILDREN :: 3
@(private="file") CAPACITY1 :: 8
@(private="file") CAPACITY2 :: 16
@(private="file") CAPACITYSI :: 48
@(private="file") CHUNK_SHIFT :: 14
@(private="file") CHUNK_SIZE :: 1<<CHUNK_SHIFT
@(private="file") CHUNK_MASK :: CHUNK_SIZE-1
@(private="file") ST_PARENT_STEPS :: 16
@(private="file") PREFETCH_AHEAD :: 6
@(private="file") POOL_BYTES :: 262000

SUFFIX_TRIE1_MAX_SIZE :: 1<<23

// children holds a pointer to the Children_* block once there are more than 3.
@(private="file")
St_Node :: struct {
    pos,parent,follow,depth:i32,
    nodes:[NUM_INLINE_CHILDREN]i32,
    num_children_minus_one:u8,
    iselect:[NUM_INLINE_CHILDREN]u8,
}
#assert(size_of(St_Node)==32)

@(private="file") Children_Sparse1 :: struct {select:[CAPACITY1]u8, nodes:[CAPACITY1]i32}
@(private="file") Children_Sparse2 :: struct {select:[CAPACITY2]u8, nodes:[CAPACITY2]i32}
@(private="file") Children_Sparse_I :: struct {sel2ind:[256]u8, nodes:[CAPACITYSI]i32}
@(private="file") Children_Full :: struct {nodes:[256]i32}

// Fixed-size blocks carved from arena chunks, with a free list through the freed blocks.
@(private="file")
Pool :: struct($T:typeid) {
    chunks:^Pool_Chunk,
    free:rawptr,
    next:[^]T,
    left:int,
}
@(private="file") Pool_Chunk :: struct {next:^Pool_Chunk, mem:[]u8}

@(private="file")
pool_alloc :: proc(p:^Pool($T),arena:^entropy.Arena) -> ^T {
    if p.free!=nil {
        r:=(^T)(p.free)
        p.free=(^rawptr)(p.free)^
        return r
    }
    if p.left==0 {
        n:=max(POOL_BYTES/size_of(T),1)
        mem:=entropy.arena_alloc(arena,u8,size_of(Pool_Chunk)+16+n*size_of(T))
        if mem==nil {return nil}
        c:=(^Pool_Chunk)(raw_data(mem))
        c^=Pool_Chunk{p.chunks,mem}
        p.chunks=c
        p.next=([^]T)(&mem[size_of(Pool_Chunk)+16-int(uintptr(&mem[size_of(Pool_Chunk)])&15)])
        p.left=n
    }
    r:=&p.next[0]
    p.next=p.next[1:]
    p.left-=1
    return r
}

@(private="file")
pool_free :: proc "contextless" (p:^Pool($T),x:^T) {
    (^rawptr)(x)^=p.free
    p.free=x
}

@(private="file")
pool_release :: proc(p:^Pool($T),arena:^entropy.Arena) {
    for c:=p.chunks;c!=nil; {
        next:=c.next
        entropy.arena_free(arena,c.mem)
        c=next
    }
    p^={}
}

Suffix_Trie_Finder :: struct {
    ubuf:[^]u8, // one before the input, so input byte i is position i+1
    size:int,
    sparse1_pool:Pool(Children_Sparse1),
    sparse2_pool:Pool(Children_Sparse2),
    sparse_i_pool:Pool(Children_Sparse_I),
    full_pool:Pool(Children_Full),
    firstbytes:[]i32,
    node_chunks:[]^[CHUNK_SIZE]St_Node,
    node_chunks_mem:[][]u8,
    lastml,follownode,node_to_update_follow,maxml_offs,maxml_pos,pos,nextnode:int,
    num_firstbytes:int,
    firstbytes_mask:u32,
    has_lrm:bool,
    failed:bool,
    scanner:Lrm_Scanner,
    arena:^entropy.Arena,
}

@(private="file")
children_of :: #force_inline proc "contextless" (n:^St_Node) -> rawptr {
    return intrinsics.unaligned_load((^rawptr)(&n.nodes[0]))
}
@(private="file")
set_children :: #force_inline proc "contextless" (n:^St_Node,c:rawptr) {
    intrinsics.unaligned_store((^rawptr)(&n.nodes[0]),c)
}

@(private="file")
read_firstbytes :: #force_inline proc "contextless" (p:[^]u8) -> u32 {
    return u32(load16(p))|u32(p[2])<<16
}

@(private="file")
alloc_node_chunk :: proc(f:^Suffix_Trie_Finder,node:int) -> bool {
    id:=node>>CHUNK_SHIFT
    if id>=len(f.node_chunks) {return false}
    mem,data:=match.alloc_aligned(f.arena,St_Node,CHUNK_SIZE)
    if mem==nil {return false}
    f.node_chunks_mem[id]=mem
    f.node_chunks[id]=(^[CHUNK_SIZE]St_Node)(raw_data(data))
    return true
}

@(private)
suffix_trie_init :: proc(f:^Suffix_Trie_Finder,ubuf:[^]u8,size,start_recording_pos:int,
    lrms:^Lrm_Set,arena:^entropy.Arena) -> bool {
    if size<=0 || size>=int(max(i32)) || start_recording_pos<0 ||
        start_recording_pos>=size {return false}
    f.arena=arena
    f.ubuf=padd(ubuf,-1)
    f.size=size+1
    start:=start_recording_pos+1
    f.num_firstbytes=size<=SUFFIX_TRIE1_MAX_SIZE?2:3
    count:=1<<uint(24-(f.num_firstbytes==2?8:0))
    f.firstbytes_mask=u32(count-1)
    f.firstbytes=entropy.arena_alloc_zeroed(arena,i32,count)
    if f.firstbytes==nil {return false}
    nchunks:=(f.size+CHUNK_MASK)>>CHUNK_SHIFT
    f.node_chunks=entropy.arena_alloc_zeroed(arena,^[CHUNK_SIZE]St_Node,nchunks)
    f.node_chunks_mem=entropy.arena_alloc_zeroed(arena,[]u8,nchunks)
    if f.node_chunks==nil || f.node_chunks_mem==nil {return false}
    f.pos=1
    f.nextnode=1
    if !alloc_node_chunk(f,f.nextnode) {return false}
    f.has_lrm=lrms!=nil
    lrm_scanner_windowed_init(&f.scanner,lrms,padd(f.ubuf,start),padd(f.ubuf,f.size),int(max(i32)))
    suffix_trie_chunk(f,start-1,nil,0)
    return !f.failed
}

@(private)
suffix_trie_release :: proc(f:^Suffix_Trie_Finder,arena:^entropy.Arena) {
    for m in f.node_chunks_mem {entropy.arena_free(arena,m)}
    entropy.arena_free(arena,f.node_chunks_mem)
    entropy.arena_free(arena,f.node_chunks)
    entropy.arena_free(arena,f.firstbytes)
    pool_release(&f.sparse1_pool,arena)
    pool_release(&f.sparse2_pool,arena)
    pool_release(&f.sparse_i_pool,arena)
    pool_release(&f.full_pool,arena)
    f.node_chunks_mem,f.node_chunks,f.firstbytes=nil,nil,nil
}

@(private="file")
report_max_len_match :: proc "contextless" (f:^Suffix_Trie_Finder,pairs:[^]match.Unpacked_Match_Pair,
    max_pairs,count:int) #no_bounds_check {
    p:=pairs
    for i in 0..<count {
        p[0]=match.Unpacked_Match_Pair{i32(f.size-i),i32(f.maxml_offs)}
        p[1].length=0
        p=p[max_pairs:]
    }
}

@(private="file")
Step :: enum u8 {Search, Promote, Branch, Done, Maxml}

// Adds the suffixes of [pos,pos+chunk_size) and, when matches is not nil, writes their pairs.
@(private)
suffix_trie_chunk :: proc(f:^Suffix_Trie_Finder,chunk_size:int,matches:[^]match.Unpacked_Match_Pair,
    max_pairs:int) -> int #no_bounds_check {
    ubuf:=f.ubuf
    size:=f.size
    pfb:=raw_data(f.firstbytes)
    fbmask:=f.firstbytes_mask
    chunks:=raw_data(f.node_chunks)
    node :: #force_inline proc "contextless" (chunks:[^]^[CHUNK_SIZE]St_Node,n:int) -> ^St_Node {
        return &chunks[n>>CHUNK_SHIFT][n&CHUNK_MASK]
    }
    chunk_start:=f.pos
    chunk_end:=min(f.pos+chunk_size,size-3-1)
    real_chunk_end:=min(f.pos+chunk_size,size)
    prefetch_end:=chunk_end-PREFETCH_AHEAD
    if f.num_firstbytes!=3 {prefetch_end=chunk_start}
    pos:=f.pos
    nfb:=f.num_firstbytes

    if chunk_start<chunk_end && !f.failed {
    if f.maxml_offs!=0 {
        if matches!=nil {
            report_max_len_match(f,matches,max_pairs,chunk_end-chunk_start)
            pos=chunk_end
        }
    } else {
        run_lrm:=matches!=nil && f.has_lrm
        pos_loop: for pos=chunk_start;pos<chunk_end;pos+=1 {
            ptr:=padd(ubuf,pos)
            if pos<prefetch_end {
                intrinsics.prefetch_write_data(&pfb[read_firstbytes(padd(ptr,
                    PREFETCH_AHEAD))&fbmask],3)
                c:=max(int(pfb[read_firstbytes(padd(ptr,PREFETCH_AHEAD/2))&fbmask]),0)
                intrinsics.prefetch_write_data(node(chunks,c),3)
            }
            maxml:=size-pos
            cur,curml:int
            guaranteedml:=max(0,f.lastml-1)
            deepest_with_follow,deepest_without_follow,parent:=0,0,0
            ntuf_prev_depth:=max(int)
            if f.node_to_update_follow!=0 {
                fo:=int(node(chunks,f.node_to_update_follow).follow)
                ntuf_prev_depth=fo==0?0:int(node(chunks,fo).depth)
            }
            update_follow :: #force_inline proc "contextless" (chunks:[^]^[CHUNK_SIZE]St_Node,
                ntuf:int,prev_depth:^int,cur,curml:int) {
                if curml>prev_depth^ {
                    n:=node(chunks,ntuf)
                    if curml>=int(n.depth) {
                        prev_depth^=max(int)
                    } else {
                        prev_depth^=curml
                        n.follow=i32(cur)
                    }
                }
            }
            step:Step
            pslot:^i32 // the slot that gets nextnode when a branch or promotion makes a node
            if f.follownode>0 {
                cur=f.follownode
                curml=int(node(chunks,cur).depth)
                step=.Search
            } else {
                fb:=read_firstbytes(ptr)&fbmask
                cur=int(pfb[fb])
                if cur==0 {
                    pfb[fb]=i32(-pos)
                    f.lastml=0
                    f.follownode=0
                    if matches!=nil {matches[(pos-chunk_start)*max_pairs].length=0}
                    continue
                }
                curml=nfb
                pslot=&pfb[fb]
                if cur<0 {
                    step=.Promote
                } else {
                    child:=node(chunks,cur)
                    cd:=int(child.depth)
                    curml=max(curml,guaranteedml)
                    step=.Search
                    if curml>=cd {
                        curml=cd
                    } else {
                        cp:=padd(ubuf,int(child.pos))
                        for curml<cd {
                            if curml==maxml {step=.Maxml;break}
                            if ptr[curml]!=cp[curml] {step=.Branch;break}
                            curml+=1
                        }
                    }
                }
            }
            search: for step==.Search {
                update_follow(chunks,f.node_to_update_follow,&ntuf_prev_depth,cur,curml)
                if curml>=maxml {step=.Maxml;break}
                sel:=ptr[curml]
                n:=node(chunks,cur)
                if n.follow!=0 {deepest_with_follow=cur} else {deepest_without_follow=cur}
                nc:=int(n.num_children_minus_one)+1
                pchild:^i32
                if nc<=NUM_INLINE_CHILDREN {
                    for i in 0..<nc {
                        if n.iselect[i]==sel {pchild=&n.nodes[i];break}
                    }
                    if pchild==nil {
                        if nc<NUM_INLINE_CHILDREN {
                            n.iselect[nc]=sel
                            n.nodes[nc]=i32(-pos)
                        } else {
                            c:=pool_alloc(&f.sparse1_pool,f.arena)
                            if c==nil {f.failed=true;break pos_loop}
                            c.select={}
                            for i in 0..<NUM_INLINE_CHILDREN {
                                c.select[i]=n.iselect[i]
                                c.nodes[i]=n.nodes[i]
                            }
                            c.select[NUM_INLINE_CHILDREN]=sel
                            c.nodes[NUM_INLINE_CHILDREN]=i32(-pos)
                            set_children(n,c)
                        }
                        n.num_children_minus_one+=1
                        step=.Done;break
                    }
                } else if nc<=CAPACITY1 {
                    c:=(^Children_Sparse1)(children_of(n))
                    for i in 0..<nc {
                        if c.select[i]==sel {pchild=&c.nodes[i];break}
                    }
                    if pchild==nil {
                        if nc==CAPACITY1 {
                            c2:=pool_alloc(&f.sparse2_pool,f.arena)
                            if c2==nil {f.failed=true;break pos_loop}
                            c2.select={}
                            for i in 0..<CAPACITY1 {c2.select[i]=c.select[i];c2.nodes[i]=c.nodes[i]}
                            c2.select[CAPACITY1]=sel
                            c2.nodes[CAPACITY1]=i32(-pos)
                            set_children(n,c2)
                            pool_free(&f.sparse1_pool,c)
                        } else {
                            c.select[nc]=sel
                            c.nodes[nc]=i32(-pos)
                        }
                        n.num_children_minus_one+=1
                        step=.Done;break
                    }
                } else if nc<=CAPACITY2 {
                    c:=(^Children_Sparse2)(children_of(n))
                    for i in 0..<nc {
                        if c.select[i]==sel {pchild=&c.nodes[i];break}
                    }
                    if pchild==nil {
                        if nc==CAPACITY2 {
                            si:=pool_alloc(&f.sparse_i_pool,f.arena)
                            if si==nil {f.failed=true;break pos_loop}
                            si.sel2ind={}
                            s:=sel
                            nd:=i32(-pos)
                            for i:=0;;i+=1 {
                                si.sel2ind[s]=u8(i+1)
                                si.nodes[i]=nd
                                if i==CAPACITY2 {break}
                                s=c.select[i]
                                nd=c.nodes[i]
                            }
                            set_children(n,si)
                            pool_free(&f.sparse2_pool,c)
                        } else {
                            c.select[nc]=sel
                            c.nodes[nc]=i32(-pos)
                        }
                        n.num_children_minus_one+=1
                        step=.Done;break
                    }
                } else if nc<=CAPACITYSI {
                    si:=(^Children_Sparse_I)(children_of(n))
                    idx:=int(si.sel2ind[sel])
                    if idx==0 {
                        if nc==CAPACITYSI {
                            full:=pool_alloc(&f.full_pool,f.arena)
                            if full==nil {f.failed=true;break pos_loop}
                            full.nodes={}
                            for i in 0..<256 {
                                if ind:=int(si.sel2ind[i]);ind!=0 {full.nodes[i]=si.nodes[ind-1]}
                            }
                            full.nodes[sel]=i32(-pos)
                            set_children(n,full)
                            pool_free(&f.sparse_i_pool,si)
                        } else {
                            si.sel2ind[sel]=u8(nc+1)
                            si.nodes[nc]=i32(-pos)
                        }
                        n.num_children_minus_one+=1
                        step=.Done;break
                    }
                    pchild=&si.nodes[idx-1]
                } else {
                    full:=(^Children_Full)(children_of(n))
                    pchild=&full.nodes[sel]
                    if pchild^==0 {
                        pchild^=i32(-pos)
                        n.num_children_minus_one+=1
                        step=.Done;break
                    }
                }
                child:=int(pchild^)
                if child<0 {
                    pslot=pchild
                    parent=cur
                    cur=child
                    curml+=1
                    step=.Promote
                    break
                }
                curml+=1
                cn:=node(chunks,child)
                cd:=int(cn.depth)
                curml=max(curml,guaranteedml)
                if curml>=cd {
                    curml=cd
                } else {
                    cp:=padd(ubuf,int(cn.pos))
                    for curml<cd {
                        if curml==maxml {cur=child;step=.Maxml;break search}
                        if ptr[curml]!=cp[curml] {
                            pslot=pchild
                            parent=cur
                            cur=child
                            step=.Branch
                            break search
                        }
                        curml+=1
                    }
                }
                cur=child
            }

            match_ptr:[^]u8
            switch step {
            case .Done:
                f.node_to_update_follow=deepest_with_follow
                if deepest_without_follow>0 {f.node_to_update_follow=deepest_without_follow}
                match_ptr=padd(ubuf,int(node(chunks,cur).pos))
                parent=cur
            case .Promote:
                match_ptr=padd(ubuf,-cur)
                curml=max(curml,guaranteedml)
                for {
                    if curml==maxml {step=.Maxml;break}
                    if ptr[curml]!=match_ptr[curml] {break}
                    curml+=1
                }
            case .Branch:
                node(chunks,cur).parent=i32(f.nextnode)
                match_ptr=padd(ubuf,int(node(chunks,cur).pos))
            case .Search,.Maxml:
            }
            if step==.Promote || step==.Branch {
                new_node:=f.nextnode
                f.nextnode+=1
                if new_node&CHUNK_MASK==0 && !alloc_node_chunk(f,
                    new_node) {f.failed=true;break pos_loop}
                pslot^=i32(new_node)
                n:=node(chunks,new_node)
                n.depth=i32(curml)
                n.follow=0
                n.pos=i32(pos)
                n.parent=i32(parent)
                n.num_children_minus_one=1
                n.iselect[0]=ptr[curml]
                n.nodes[0]=i32(-pos)
                n.iselect[1]=match_ptr[curml]
                n.nodes[1]=i32(cur)
                update_follow(chunks,f.node_to_update_follow,&ntuf_prev_depth,new_node,curml)
                f.node_to_update_follow=new_node
            }
            if step==.Maxml {
                match_ptr=cur<0?padd(ubuf,-cur):padd(ubuf,int(node(chunks,cur).pos))
                f.maxml_offs=pdiff(ptr,match_ptr)
                f.maxml_pos=pos
                if matches!=nil {report_max_len_match(f,matches[(pos-chunk_start)*max_pairs:],
                    max_pairs,chunk_end-pos)}
                pos=chunk_end
                break pos_loop
            }
            f.follownode=deepest_with_follow!=0?int(node(chunks,deepest_with_follow).follow):0
            f.lastml=curml
            if matches!=nil {
                pairs:=matches[(pos-chunk_start)*max_pairs:]
                curoff:=pdiff(ptr,match_ptr)
                np:=1
                pairs[0]=match.Unpacked_Match_Pair{i32(curml),i32(curoff)}
                pos_to_beat:=pos-curoff
                steps_left:=ST_PARENT_STEPS
                for parent!=0 {
                    n:=node(chunks,parent)
                    if int(n.pos)>pos_to_beat && np<max_pairs {
                        length:=n.depth
                        if length<=2 {break}
                        pairs[np]=match.Unpacked_Match_Pair{length,i32(pos)-n.pos}
                        np+=1
                        pos_to_beat=int(n.pos)
                    }
                    steps_left-=1
                    if steps_left<0 {break}
                    n.pos=i32(pos)
                    parent=int(n.parent)
                }
                if np<max_pairs {pairs[np].length=0}
            } else {
                steps:=0
                for parent!=0 {
                    n:=node(chunks,parent)
                    steps+=1
                    if steps>ST_PARENT_STEPS {break}
                    n.pos=i32(pos)
                    parent=int(n.parent)
                }
            }
        }
        if f.failed {pos=chunk_end}
        if run_lrm {
            merge_end:=f.maxml_offs!=0?f.maxml_pos:chunk_end
            end:=padd(ubuf,size)
            for mp in chunk_start..<chunk_end {
                off:int
                l:=lrm_scanner_windowed_find_match_and_roll(&f.scanner,padd(ubuf,mp),end,&off)
                if mp>=merge_end {continue}
                out:=matches[(mp-chunk_start)*max_pairs:]
                if l>out[0].length {
                    for i:=max_pairs-1;i>0;i-=1 {out[i]=out[i-1]}
                    out[0]=match.Unpacked_Match_Pair{l,i32(off)}
                }
            }
        }
    }
    }

    if pos!=real_chunk_end {
        if matches!=nil {
            for i in pos..<real_chunk_end {matches[(i-chunk_start)*max_pairs].length=0}
        }
        pos=real_chunk_end
    }
    f.pos=pos
    return real_chunk_end-chunk_start
}
