package entropy

import "mirai:std/compressor"

// Split arrays: one count byte, then that many sub-arrays (small headers allowed) that
// concatenate to the whole. The 0x80 bit of the count byte marks an indexed multiarray.

MULTIARRAYS_ENCODER_MAX_NUM_ARRAYS_STRICT :: compressor.MULTIARRAY_MAX_ARRAYS
MULTIARRAYS_ENCODER_MAX_NUM_ARRAYS_TARGET :: MULTIARRAYS_ENCODER_MAX_NUM_ARRAYS_STRICT-1

encoder_max_num_arrays :: proc "contextless" (compression_level:int) -> int {
    n:=1<<uint(clamp(compression_level,0,30))
    n=clamp(n,8,32)
    if compression_level==9 {n=MULTIARRAYS_ENCODER_MAX_NUM_ARRAYS_TARGET}
    return n
}

@(private="file") Slide_Candidate :: struct {gain:i32, which:i32, right:bool, key1,key2:u64}
@(private="file")
slide_less :: proc "contextless" (a,b:Slide_Candidate) -> bool {return a.gain<b.gain}
@(private="file") slide_key :: #force_inline proc "contextless" (start,
    n:i32) -> u64 {return u64(u32(start))<<32|u64(u32(n))}
@(private="file") Merge_Candidate :: struct {gain_J, merged_J:f32, src1,src2:i32}

@(private="file") SPLIT_N_INITIAL_SIZE :: 512

@(private="file")
add_slides :: proc "contextless" (i:int, num_arrays:int, histos:[]Histo256, lens,start:[]i32,
    heap:[]Slide_Candidate,
    heap_size:^int, from:[^]u8, step:int, force_direction:int) #no_bounds_check {
    if i>0 && int(lens[i-1])>=2*step && force_direction<=0 && heap_size^<len(heap) {
        p:=from[int(start[i])-step:][:step]
        d:=entropysets_codelen_delta(p,&histos[i],int(lens[i]),&histos[i-1],int(lens[i-1]))
        if d<0 {
            heap[heap_size^]=Slide_Candidate{-d,i32(i),false,slide_key(start[i],lens[i]),
                slide_key(start[i-1],lens[i-1])}
            heap_size^+=1
        }
    }
    if i<num_arrays-1 && int(lens[i+1])>=2*step && force_direction>=0 && heap_size^<len(heap) {
        p:=from[int(start[i])+int(lens[i]):][:step]
        d:=entropysets_codelen_delta(p,&histos[i],int(lens[i]),&histos[i+1],int(lens[i+1]))
        if d<0 {
            heap[heap_size^]=Slide_Candidate{-d,i32(i),true,slide_key(start[i],lens[i]),
                slide_key(start[i+1],lens[i+1])}
            heap_size^+=1
        }
    }
}

@(private="file")
greedy_single_byte_slides :: proc "contextless" (from:[^]u8, histos:[]Histo256, lens,start:[]i32,
    num_arrays:int) #no_bounds_check {
    for i in 1..<num_arrays {
        p:=int(start[i])
        gl,gr:i64=0,0
        if lens[i-1]>0 {
            s:=from[p-1]
            gl=i64(histos[i].counts[s])*i64(lens[i-1])-i64(histos[i-1].counts[s])*i64(lens[i])
        }
        if lens[i]>0 {
            s:=from[p]
            gr=i64(histos[i-1].counts[s])*i64(lens[i])-i64(histos[i].counts[s])*i64(lens[i-1])
        }
        if gl>0 && gl>gr {
            for {
                s:=from[p-1]
                histos[i].counts[s]+=1
                histos[i-1].counts[s]-=1
                lens[i]+=1;lens[i-1]-=1;start[i]-=1
                p-=1
                if lens[i-1]==0 {break}
                s=from[p-1]
                gl=i64(histos[i].counts[s])*i64(lens[i-1])-i64(histos[i-1].counts[s])*i64(lens[i])
                if !(gl>0) {break}
            }
        } else if gr>0 {
            for {
                s:=from[p]
                histos[i-1].counts[s]+=1
                histos[i].counts[s]-=1
                lens[i-1]+=1;lens[i]-=1;start[i]+=1
                p+=1
                if lens[i]==0 {break}
                s=from[p]
                gr=i64(histos[i-1].counts[s])*i64(lens[i])-i64(histos[i].counts[s])*i64(lens[i-1])
                if !(gr>0) {break}
            }
        }
    }
}

// Writes the count byte and the sub-arrays to a scratch buffer and copies them to `to` when the
// total J (6 + sub-array Js) beats prev_J.
@(private="file")
put_split_parts :: proc(to:[^]u8, to_end:[^]u8, from:[^]u8, from_len:int, starts,lens:[]i32,
    count:int,
    flags:u32, lambda:f32, prev_J:f32, pJ:^f32, arena:^Arena, compression_level:int) -> int {
    scratch:=arena_alloc(arena,u8,from_len)
    if scratch==nil {return -1}
    defer arena_free(arena,scratch)
    sp:=raw_data(scratch)
    send:=sp[from_len:]
    p:=sp
    p[0]=u8(count);p=p[1:]
    flags:=flags&~ARRAY_FLAG_ALLOW_SPLIT
    Jtot:f32=6
    for i in 0..<len(lens) {
        if lens[i]==0 {continue}
        J1:=LAGRANGE_COST_INVALID
        n:=put_array_small_allowed(p,send,from[starts[i]:][:lens[i]],flags,lambda,&J1,
            ARRAY_DEADLINE_HUGE,arena,compression_level)
        if n<0 {return -1}
        p=p[n:]
        Jtot+=J1
    }
    if Jtot>=prev_J {return -1}
    tot:=ptr_diff(p,sp)
    if tot>ptr_diff(to_end,to) {return -1}
    pJ^=Jtot
    copy_bytes(to,sp,tot)
    return tot
}

@(private="file")
put_array_sub_split_n :: proc(to:[^]u8, to_end:[^]u8, from:[]u8, histogram:^[256]u32, arena:^Arena,
    compression_level:int, flags:u32, lambda:f32, prev_J:f32, pJ:^f32) -> int #no_bounds_check {
    from_len:=i32(len(from))
    src:=raw_data(from)
    num_arrays:=int((from_len+SPLIT_N_INITIAL_SIZE/2)/SPLIT_N_INITIAL_SIZE)
    num_arrays=clamp(num_arrays,3,encoder_max_num_arrays(compression_level))
    histos:=arena_alloc(arena,Histo256,num_arrays)
    if histos==nil {return -1}
    defer arena_free(arena,histos)
    lens_s,start_s:[MULTIARRAYS_ENCODER_MAX_NUM_ARRAYS_STRICT]i32
    lens:=lens_s[:num_arrays]
    start:=start_s[:num_arrays]
    seg:=from_len/i32(num_arrays)
    for i in 0..<num_arrays {
        start[i]=seg*i32(i)
        lens[i]=i==num_arrays-1 ? from_len-start[i] : seg
        histo_count(&histos[i],from[start[i]:][:lens[i]])
    }
    heap_cap:=num_arrays*3
    heap:=arena_alloc(arena,Slide_Candidate,heap_cap)
    if heap==nil {return -1}
    defer arena_free(arena,heap)
    for step:=64;step>=16;step>>=2 {
        hs:=0
        for i in 0..<num_arrays {add_slides(i,num_arrays,histos,lens,start,heap,&hs,src,step,0)}
        heap_make(heap[:hs],slide_less)
        max_num_slides:=num_arrays*2
        for hs>0 {
            sc:=heap[0]
            heap_popped(heap[:hs],slide_less)
            hs-=1
            i:=int(sc.which)
            dir:=sc.right ? 1 : -1
            if sc.key1!=slide_key(start[i],lens[i]) || sc.key2!=slide_key(start[i+dir],
                lens[i+dir]) {continue}
            if sc.right {
                histo_slide(from[start[i]+lens[i]:][:step],&histos[i+1],&histos[i])
                lens[i]+=i32(step);start[i+1]+=i32(step);lens[i+1]-=i32(step)
            } else {
                histo_slide(from[int(start[i])-step:][:step],&histos[i-1],&histos[i])
                lens[i]+=i32(step);start[i]-=i32(step);lens[i-1]-=i32(step)
            }
            if max_num_slides==0 {break}
            max_num_slides-=1
            if hs+4>=heap_cap {
                for hi:=hs-1;hi>=0;hi-=1 {
                    h:=heap[hi]
                    i1:=int(h.which)
                    i2:=i1+(h.right ? 1 : -1)
                    if h.key1!=slide_key(start[i1],lens[i1]) || h.key2!=slide_key(start[i2],
                        lens[i2]) {
                        heap[hi]=heap[hs-1]
                        hs-=1
                    }
                }
                heap_make(heap[:hs],slide_less)
            }
            hi:=hs
            add_slides(i,num_arrays,histos,lens,start,heap,&hs,src,step,0)
            add_slides(i+dir,num_arrays,histos,lens,start,heap,&hs,src,step,dir)
            for hi<hs {
                hi+=1
                heap_push(heap[:hi],slide_less)
            }
        }
    }
    greedy_single_byte_slides(src,histos,lens,start,num_arrays)
    merge_list:[MULTIARRAYS_ENCODER_MAX_NUM_ARRAYS_STRICT]Merge_Candidate
    ml:=0
    cur_J:[MULTIARRAYS_ENCODER_MAX_NUM_ARRAYS_STRICT]f32
    best_gain:f32=0
    best_i:=-1
    lasti:=-1
    for i in 0..<num_arrays {
        if lens[i]==0 {continue}
        cur_J[i]=histo_estimate_j(&histos[i],int(lens[i]),lambda)
        if lasti>-1 {
            mh:Histo256
            histo_add(&mh,&histos[i],&histos[lasti])
            mj:=histo_estimate_j(&mh,int(lens[i]+lens[lasti]),lambda)
            gain:=cur_J[i]+cur_J[lasti]-mj
            if gain>0 && ml<len(merge_list) {
                merge_list[ml]=Merge_Candidate{gain,mj,i32(lasti),i32(i)}
                if gain>best_gain {best_gain=gain;best_i=ml}
                ml+=1
            }
        }
        lasti=i
    }
    for ml>0 {
        if best_i<0 {break}
        mc:=merge_list[best_i]
        merge_list[best_i]=merge_list[ml-1]
        ml-=1
        best_gain=0
        best_i=-1
        i:=int(mc.src1)
        j:=int(mc.src2)
        histo_add(&histos[i],&histos[i],&histos[j])
        lens[i]=lens[i]+lens[j]
        cur_J[i]=mc.merged_J
        start[j]=0;lens[j]=0;cur_J[j]=0
        for h:=ml-1;h>=0;h-=1 {
            if int(merge_list[h].src2)==i || int(merge_list[h].src1)==j {
                merge_list[h]=merge_list[ml-1]
                if best_i==ml-1 {best_i=h}
                ml-=1
            } else {
                g:=merge_list[h].gain_J
                if g>best_gain {best_gain=g;best_i=h}
            }
        }
        below:=i-1
        for below>=0 && lens[below]==0 {below-=1}
        if below>=0 {
            k:=below
            mh:Histo256
            histo_add(&mh,&histos[i],&histos[k])
            mj:=histo_estimate_j(&mh,int(lens[i]+lens[k]),lambda)
            gain:=cur_J[i]+cur_J[k]-mj
            if gain>0 && ml<len(merge_list) {
                merge_list[ml]=Merge_Candidate{gain,mj,i32(k),i32(i)}
                if gain>best_gain {best_gain=gain;best_i=ml}
                ml+=1
            }
        }
        above:=j+1
        for above<num_arrays && lens[above]==0 {above+=1}
        if above<num_arrays {
            k:=above
            mh:Histo256
            histo_add(&mh,&histos[i],&histos[k])
            mj:=histo_estimate_j(&mh,int(lens[i]+lens[k]),lambda)
            gain:=cur_J[i]+cur_J[k]-mj
            if gain>0 && ml<len(merge_list) {
                merge_list[ml]=Merge_Candidate{gain,mj,i32(i),i32(k)}
                if gain>best_gain {best_gain=gain;best_i=ml}
                ml+=1
            }
        }
    }
    to_i:=0
    for i in 0..<num_arrays {
        if lens[i]==0 {continue}
        if i!=to_i {
            histos[to_i]=histos[i]
            lens[to_i]=lens[i]
            start[to_i]=start[i]
        }
        to_i+=1
    }
    num_arrays=to_i
    if num_arrays<=1 {return -1}
    return put_split_parts(to,to_end,src,len(from),start[:num_arrays],lens[:num_arrays],
        num_arrays,flags,lambda,prev_J,pJ,arena,compression_level)
}

@(private="file")
put_array_sub_split_2 :: proc(to:[^]u8, to_end:[^]u8, from:[]u8, histogram:^[256]u32, arena:^Arena,
    compression_level:int, flags:u32, lambda:f32, prev_J:f32, pJ:^f32) -> int #no_bounds_check {
    from_len:=len(from)
    all:=transmute(^Histo256)histogram
    best:=histo_estimate_j(all,from_len,lambda)
    histos:[2]Histo256
    len1_best:=0
    n_init:=clamp((from_len+128)/256,1,8)
    h1,h2:Histo256
    for i in 0..<n_init {
        l1:=((i+1)*from_len)/(n_init+1)
        l2:=from_len-l1
        histo_count(&h1,from[:l1])
        histo_sub(&h2,all,&h1)
        e1:=histo_estimate_j(&h1,l1,lambda)
        e2:=histo_estimate_j(&h2,l2,lambda)
        e:=e1+e2+6
        if e<best {
            best=e
            len1_best=l1
            histos[0]=h1
            histos[1]=h2
        }
    }
    if len1_best==0 {return -1}
    len1:=len1_best
    len2:=from_len-len1
    for step:=64;step>=16;step>>=2 {
        for len2>=step*2 {
            p:=from[len1:][:step]
            if i64(entropysets_codelen_delta(p,&histos[0],len1,&histos[1],len2))>0 {break}
            len1+=step;len2-=step
            histo_slide(p,&histos[1],&histos[0])
        }
        for len1>=step*2 {
            p:=from[len1-step:][:step]
            if i64(entropysets_codelen_delta(p,&histos[1],len2,&histos[0],len1))>0 {break}
            len2+=step;len1-=step
            histo_slide(p,&histos[0],&histos[1])
        }
    }
    lens:=[2]i32{i32(len1),i32(len2)}
    start:=[2]i32{0,i32(len1)}
    greedy_single_byte_slides(raw_data(from),histos[:],lens[:],start[:],2)
    len1,len2=int(lens[0]),int(lens[1])
    if len1<compressor.HUFF_ARRAY_MIN_SIZE || len2<compressor.HUFF_ARRAY_MIN_SIZE {return -1}
    starts:=[2]i32{0,i32(len1)}
    return put_split_parts(to,to_end,raw_data(from),from_len,starts[:],lens[:],2,flags,lambda,
        prev_J,pJ,arena,compression_level)
}

// The split payload (without the 5-byte array header) of from; written only when it beats min_J.
put_array_sub_split :: proc(to:[^]u8, to_end:[^]u8, from:[]u8, histogram:^[256]u32, arena:^Arena,
    compression_level:int, flags:u32, lambda:f32, prev_J:f32, pJ:^f32) -> int {
    from_len:=len(from)
    if from_len<compressor.HUFF_ARRAY_MIN_SIZE*3 {return -1}
    n:int
    if from_len>=SPLIT_N_INITIAL_SIZE*3 {
        n=put_array_sub_split_n(to,to_end,from,histogram,arena,compression_level,flags,lambda,
            prev_J,pJ)
    } else {
        n=put_array_sub_split_2(to,to_end,from,histogram,arena,compression_level,flags,lambda,
            prev_J,pJ)
    }
    if flags&ARRAY_FLAG_ALLOW_SPLIT_INDEXED!=0 {
        prev_J:=prev_J<pJ^ ? prev_J : pJ^
        indexed_J:=prev_J-5
        ptrs:=[1][^]u8{raw_data(from)}
        lens:=[1]int{from_len}
        m:=put_multiarray_indexed_sub(to,to_end,ptrs[:],lens[:],flags,lambda,&indexed_J,arena,
            compression_level)
        indexed_J+=5
        if m>0 {
            pJ^=indexed_J
            return m
        }
    }
    return n
}
