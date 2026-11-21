package data

import "base:intrinsics"
import "core:math"

@(private="file") HASH_BITS :: 17
@(private="file") CHAIN_SIZE :: 2*(WINDOW+1)
@(private="file") SEARCH_LENGTH :: 96
@(private="file") SEARCH_DEPTH :: 256
@(private="file") COST_UNIT :: 16
@(private="file") MATCH_CACHE_BITS :: 7

@(private="file")
Match_Cache :: [1<<MATCH_CACHE_BITS]struct {distance,end:int}

@(private)
Sequence :: struct {
    literals,length,distance:u32,
}

@(private="file")
Path :: struct {
    cost,literals,length,distance:u32,
    reps:Offsets,
}

@(private)
Encode_Work :: struct {
    head:[1<<HASH_BITS]u32,
    hash_shift:uint,
    previous,long_previous:[CHAIN_SIZE]u32,
    long_head:[1<<HASH_BITS]u32,
    paths:[BLOCK_BYTES+1]Path,
    sequences:[SEQUENCES_MAX]Sequence,
    sequence_count:int,
    tags,offsets:[SEQUENCES_MAX]u8,
    literals:[BLOCK_BYTES]u8,
    length_bits:[BLOCK_BYTES/8]u8,
    offset_bits:[3*SEQUENCES_MAX]u8,
    packed:[BLOCK_BYTES+2*SEQUENCES_MAX]u8,
    candidate:[BLOCK_BYTES+1]u8,
    huff:Huff_Work,
    offset_counts:[WINDOW+1]u16,
}

@(private="file")
Match :: struct {length,distance:int}

@(private)
index_begin :: proc "contextless" (w:^Encode_Work,size:int) {
    bits:=clamp(high_bit(size),6,HASH_BITS)
    w.hash_shift=uint(32-bits)
    intrinsics.mem_zero(&w.head,(1<<uint(bits))*size_of(u32))
    intrinsics.mem_zero(&w.long_head,(1<<uint(bits))*size_of(u32))
}

@(private)
encode_block :: proc "contextless" (w:^Encode_Work,profile:Profile,src:[]u8,first:int,
    dst:[]u8) -> int {
    if len(src)-first>=MIN_MATCH {
        if profile<=.Speed {
            parse_speed(w,src,first,profile)
            if n:=write_speed(w,src,first,dst);n>0 {return n}
        } else {
            for at in first..=len(src)-MIN_MATCH {index_at(w,src,at,true)}
            if profile==.Ultra {
                for at in first..=len(src)-8 {index_long(w,src,at)}
            }
            parse_greedy(w,src,first,profile)
            streams:=build_symbols(w,src,first)
            size:=write_entropy(w,&streams,dst)
            if profile==.Ultra {
                for _ in 0..<2 {
                    prices:=symbol_prices(w,streams.literals)
                    parse_optimal(w,src,first,&prices,&streams.dictionary)
                    streams=build_symbols(w,src,first)
                    limit:=size if size>0 else len(dst)
                    n:=write_entropy(w,&streams,w.candidate[:limit])
                    if n==0 {break}
                    size=copy(dst,w.candidate[:n])
                }
            }
            if size>0 {return size}
        }
    }
    dst[0]=u8(Block_Mode.Raw)
    return 1+copy(dst[1:],src[first:])
}

@(private="file")
hash_at :: #force_inline proc "contextless" (src:[]u8,at:int,shift:uint,short:bool) -> u32 {
    word:u32
    if at+4<=len(src) {
        word=u32(intrinsics.unaligned_load((^u32le)(&src[at])))
    } else {
        word=u32(src[at])|u32(src[at+1])<<8|u32(src[at+2])<<16
    }
    if short {word&=0xffffff}
    return (word*0x9e3779b1)>>shift
}

@(private="file")
index_at :: #force_inline proc "contextless" (w:^Encode_Work,src:[]u8,at:int,short:bool) {
    h:=hash_at(src,at,w.hash_shift,short)
    w.previous[at&(CHAIN_SIZE-1)]=w.head[h]
    w.head[h]=u32(at+1)
}

@(private="file")
index_long :: #force_inline proc "contextless" (w:^Encode_Work,src:[]u8,at:int) {
    word:=u64(intrinsics.unaligned_load((^u64le)(&src[at])))
    h:=u32((word*0x9e3779b97f4a7c15)>>uint(w.hash_shift+32))
    w.long_previous[at&(CHAIN_SIZE-1)]=w.long_head[h]
    w.long_head[h]=u32(at+1)
}

@(private="file")
match_end :: #force_inline proc "contextless" (src:[]u8,left,right,start,limit:int) -> int {
    n:=start
    for n+8<=limit {
        a:=intrinsics.unaligned_load((^u64le)(&src[left+n]))
        b:=intrinsics.unaligned_load((^u64le)(&src[right+n]))
        if a!=b {return n+int(intrinsics.count_trailing_zeros(u64(a~b)))/8}
        n+=8
    }
    for n<limit && src[left+n]==src[right+n] {n+=1}
    return n
}

@(private="file")
Chain :: struct {
    links:^([CHAIN_SIZE]u32),
    next,remaining:int,
}

@(private="file")
chain_begin :: #force_inline proc "contextless" (links:^([CHAIN_SIZE]u32),at,depth:int) -> Chain {
    return {links,int(links[at&(CHAIN_SIZE-1)])-1,depth}
}

@(private="file")
chain_match :: #force_inline proc "contextless" (chain:^Chain,src:[]u8,at,best,limit,window:int,
    speed:bool) -> Match {
    for chain.remaining>0 {
        from:=chain.next
        distance:=at-from
        if from<0 || distance>window {break}
        chain.next=int(chain.links[from&(CHAIN_SIZE-1)])-1
        chain.remaining-=1
        if src[from+best]!=src[at+best] {continue}
        n:=match_end(src,from,at,0,limit)
        if n>best && (!speed || distance>=16 || n>=24) {return {n,distance}}
    }
    return {}
}

@(private="file")
find_match :: proc "contextless" (w:^Encode_Work,src:[]u8,at,depth,window,min_match:int,
    speed:=false) -> (best:Match) {
    limit:=min(len(src)-at,SEARCH_LENGTH)
    length:=min_match-1
    chain:=chain_begin(&w.previous,at,depth)
    for length<limit {
        match:=chain_match(&chain,src,at,length,limit,window,speed)
        if match.length==0 {break}
        best,length=match,match.length
    }
    return
}

@(private="file")
emit :: #force_inline proc "contextless" (w:^Encode_Work,literals:int,m:Match) {
    w.sequences[w.sequence_count]={u32(literals),u32(m.length),u32(m.distance)}
    w.sequence_count+=1
}

@(private="file")
parse_speed :: proc "contextless" (w:^Encode_Work,src:[]u8,first:int,profile:Profile) {
    w.sequence_count=0
    depth,minimum,skip_shift:=1,SPEED_MIN,6
    if profile==.Speed {depth,minimum,skip_shift=16,12,10}
    start,at,indexed:=first,first,first
    last:=len(src)-SPEED_MIN
    for at<=last {
        if indexed<=at {index_at(w,src,at,false);indexed=at+1}
        m:=find_match(w,src,at,depth,int(max(u16)),minimum,profile==.Speed)
        if m.length==0 {
            at+=1+min((at-start)>>uint(skip_shift),31)
            continue
        }
        if profile==.Speed && at<last && m.length<SEARCH_LENGTH {
            if indexed<=at+1 {index_at(w,src,at+1,false);indexed=at+2}
            next:=find_match(w,src,at+1,depth,int(max(u16)),minimum,true)
            if next.length>m.length+1 {at+=1;continue}
        }
        if m.length==SEARCH_LENGTH {m.length=match_end(src,at-m.distance,at,m.length,len(src)-at)}
        emit(w,at-start,m)
        start=at+m.length
        at=start
        if profile==.Speed {
            for i in max(indexed,at-8)..<min(at,last+1) {index_at(w,src,i,false)}
        }
    }
}

@(private="file")
greedy_match :: proc "contextless" (w:^Encode_Work,src:[]u8,at,penalty:int,reps:Offsets) -> Match {
    limit:=min(SEARCH_LENGTH,len(src)-at)
    m:=find_match(w,src,at,48,WINDOW,MIN_MATCH)
    score:=match_score(m,reps,penalty)
    if score<=0 {m={};score=0}
    for distance in reps {
        if int(distance)>at {continue}
        rep:=int(distance)
        n:=match_end(src,at-rep,at,0,limit)
        candidate:=Match{n,rep}
        if n<MIN_MATCH {continue}
        candidate_score:=match_score(candidate,reps,penalty)
        if candidate_score>=score {
            m,score=candidate,candidate_score
        }
    }
    return m
}

@(private="file")
match_score :: #force_inline proc "contextless" (m:Match,reps:Offsets,penalty:int) -> int {
    if m.length==0 {return 0}
    slot:=offset_code(reps,u32(m.distance))
    return 7*m.length-(penalty+offset_width(slot) if slot>=3 else 18)
}

@(private="file")
parse_greedy :: proc "contextless" (w:^Encode_Work,src:[]u8,first:int,profile:Profile) {
    w.sequence_count=0
    start,at:=first,first
    penalty:=32 if profile==.Balanced else 20
    reps:=INITIAL_OFFSETS
    last:=len(src)-MIN_MATCH
    for at<=last {
        m:=greedy_match(w,src,at,penalty,reps)
        if m.length==0 {at+=1;continue}
        if at<last && m.length<SEARCH_LENGTH {
            next:=greedy_match(w,src,at+1,penalty,reps)
            if match_score(next,reps,penalty)>match_score(m,reps,penalty)+7 {at+=1;continue}
        }
        if m.length==SEARCH_LENGTH {m.length=match_end(src,at-m.distance,at,m.length,len(src)-at)}
        emit(w,at-start,m)
        distance:=u32(m.distance)
        reps=offset_push(reps,offset_code(reps,distance),distance)
        start=at+m.length
        at=start
    }
}

@(private="file")
symbol_prices :: proc "contextless" (w:^Encode_Work,literal_bytes:int) -> Symbol_Cost {
    streams:=[Stream][]u8{
        .Tag=w.tags[:w.sequence_count],
        .Offset=w.offsets[:w.sequence_count],
        .Literal=w.literals[:literal_bytes],
    }
    result:Symbol_Cost
    for stream in Stream {
        counts:[256]int
        for symbol in streams[stream] {counts[symbol]+=1}
        size:=len(streams[stream])
        for count,i in counts {
            if stream==.Literal && count==0 {result[stream][i]=10*COST_UNIT;continue}
            total:=f64(size+16)
            chance:=f64(count)+0.5
            price:=math.log2(total/chance)
            result[stream][i]=u16(COST_UNIT*max(0.5,price)+0.5)
        }
    }
    return result
}

@(private="file")
parse_optimal :: proc "contextless" (w:^Encode_Work,src:[]u8,first:int,
    prices:^Symbol_Cost,dict:^Offset_Dictionary) {
    extent:=len(src)-first
    w.paths[0]={reps=INITIAL_OFFSETS}
    for &path in w.paths[1:extent+1] {path.cost=max(u32)}
    last:=len(src)-MIN_MATCH
    cache:Match_Cache
    for at in first..<len(src) {
        i:=at-first
        path:=w.paths[i]
        literal_cost:=path.cost+u32(prices[.Literal][src[at]])
        if literal_cost<w.paths[i+1].cost {
            path.cost=literal_cost
            path.literals+=1
            path.length=0
            w.paths[i+1]=path
        }
        if at>last {continue}

        limit:=min(len(src)-at,SEARCH_LENGTH)
        current:=w.paths[i]
        for distance in current.reps {
            if int(distance)>at {continue}
            rep:=int(distance)
            n:=match_end(src,at-rep,at,0,limit)
            if n>=MIN_MATCH {offer(w,src,first,at,Match{n,rep},limit,&cache,prices,dict)}
        }
        for distance in dict.distances[:dict.count] {
            if int(distance)>at || distance==current.reps[0] ||
               distance==current.reps[1] || distance==current.reps[2] {continue}
            dist:=int(distance)
            n:=match_end(src,at-dist,at,0,limit)
            if n>=MIN_MATCH {offer(w,src,first,at,Match{n,dist},limit,&cache,prices,dict)}
        }
        best:=MIN_MATCH-1
        for links in ([2]^([CHAIN_SIZE]u32){&w.previous,&w.long_previous}) {
            if best==limit || (links==&w.long_previous && at>len(src)-8) {break}
            chain:=chain_begin(links,at,SEARCH_DEPTH)
            for best<limit {
                match:=chain_match(&chain,src,at,best,limit,WINDOW,false)
                if match.length==0 {break}
                offer(w,src,first,at,match,limit,&cache,prices,dict)
                best=match.length
            }
        }
    }

    w.sequence_count=0
    for at:=extent;at>0; {
        path:=w.paths[at]
        if path.length==0 {at-=1;continue}
        n:=int(path.length)
        at-=n
        literals:=int(w.paths[at].literals)
        emit(w,literals,Match{n,int(path.distance)})
        at-=literals
    }
    for i in 0..<w.sequence_count/2 {
        j:=w.sequence_count-1-i
        w.sequences[i],w.sequences[j]=w.sequences[j],w.sequences[i]
    }
}

@(private="file")
offer :: proc "contextless" (w:^Encode_Work,src:[]u8,first,at:int,
    match:Match,limit:int,cache:^Match_Cache,prices:^Symbol_Cost,dict:^Offset_Dictionary) {
    i:=at-first
    path:=w.paths[i]
    l:=literal_code(int(path.literals))
    literal_codes:=LITERAL_CODES
    extra:=literal_codes[l].bits
    if l==7 {extra=8*length_size(int(path.literals)-32)}
    distance:=u32(match.distance)
    slot:=offset_code(path.reps,distance,dict)
    width:=offset_width(slot)
    price:=path.cost+u32(prices[.Offset][slot])+u32(COST_UNIT*(extra+width))
    reps:=offset_push(path.reps,slot,distance)
    match_codes:=MATCH_CODES
    for n:=MIN_MATCH;n<=match.length; {
        m:=match_code(n)
        code:=match_codes[m]
        cost:=price+u32(prices[.Tag][l<<5|m])+u32(COST_UNIT*code.bits)
        after:=min(match.length+1,code.base+(1<<uint(code.bits)))
        for length in n..<after {relax(w,i,length,cost,distance,reps)}
        n=after
    }

    if match.length==limit && limit<len(src)-at {
        entry:=&cache[(distance*0x9e3779b1)>>uint(32-MATCH_CACHE_BITS)]
        known:=max(limit,entry.end-at) if entry.distance==match.distance else limit
        n:=match_end(src,at-match.distance,at,known,len(src)-at)
        entry.distance,entry.end=match.distance,at+n
        for extent in max(limit+1,n-4)..=n {
            m:=match_code(extent)
            cost:=price+u32(prices[.Tag][l<<5|m])+u32(COST_UNIT*match_codes[m].bits)
            relax(w,i,extent,cost,distance,reps)
        }
    }
}

@(private="file")
relax :: #force_inline proc "contextless" (w:^Encode_Work,at,n:int,cost,distance:u32,
    reps:Offsets) {
    if cost<w.paths[at+n].cost {w.paths[at+n]={cost,0,u32(n),distance,reps}}
}
