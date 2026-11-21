package data

import "base:intrinsics"

@(private) MIN_HUFF :: 32
@(private="file") LITERAL_SAVING_PERCENT :: 6
@(private) Huff_Work :: [HUF_WORKSPACE_SIZE/8]u64
@(private) Offsets :: [3]u32
@(private) INITIAL_OFFSETS :: Offsets{1,4,8}
@(private) ALIGN_BITS :: 4
@(private) OFFSET_NORMAL :: 3+WINDOW_BITS
@(private) OFFSET_CLASSES :: OFFSET_NORMAL+WINDOW_BITS-ALIGN_BITS
@(private) Offset_Dictionary :: struct {
    distances:[8]u32,
    count:int,
}

@(private)
Decode_Work :: struct {
    tags,offsets:[SEQUENCES_MAX]u8,
    literals:[BLOCK_BYTES+16]u8,
    offset_bits:[3*SEQUENCES_MAX+8]u8,
    length_extra:[SEQUENCES_MAX+1]u8,
    huff:[HUF_DECOMPRESS_WORKSPACE_SIZE_U32]u32,
    table:[1+(1<<HUFFDTABLE_CAPACITY_LOG)]u32,
}

@(private)
Stream :: enum {Tag,Offset,Literal}

@(private)
Symbol_Cost :: [Stream][256]u16

@(private)
LITERAL_ESCAPE :: 7

@(private)
MATCH_ESCAPE :: 31+MIN_MATCH

@(private)
literal_code :: #force_inline proc "contextless" (n:int) -> int {
    return min(n,LITERAL_ESCAPE)
}

@(private)
match_code :: #force_inline proc "contextless" (n:int) -> int {
    return min(n,MATCH_ESCAPE)-MIN_MATCH
}

@(private)
high_bit :: #force_inline proc "contextless" (n:int) -> int {
    return 31-int(intrinsics.count_leading_zeros(u32(n)))
}

@(private)
offset_code :: #force_inline proc "contextless" (reps:Offsets,distance:u32,
    dict:^Offset_Dictionary=nil) -> int {
    if distance==reps[0] {return 0}
    if distance==reps[1] {return 1}
    if distance==reps[2] {return 2}
    if dict!=nil {
        for d,i in dict.distances[:dict.count] {
            if d==distance {return OFFSET_CLASSES+i}
        }
    }
    if distance&((1<<ALIGN_BITS)-1)==0 {
        return OFFSET_NORMAL+high_bit(int(distance>>ALIGN_BITS))
    }
    return 3+high_bit(int(distance))
}

@(private)
offset_width :: #force_inline proc "contextless" (slot:int) -> int {
    if slot<OFFSET_NORMAL {return max(0,slot-3)}
    return slot-OFFSET_NORMAL if slot<OFFSET_CLASSES else 0
}

@(private)
offset_push :: #force_inline proc "contextless" (reps:Offsets,slot:int,distance:u32) -> Offsets {
    return {
        distance,
        reps[0] if slot!=0 else reps[1],
        reps[1] if slot>1 else reps[2],
    }
}

@(private="file")
pack_symbols :: proc "contextless" (w:^Huff_Work,src,dst:[]u8,saving:int) -> []u8 {
    if len(src)<MIN_HUFF {return src}
    log:=u32(9 if len(src)<4096 else 11)
    n,err:=huf_compress4x(w,src,dst,log)
    return dst[:n] if err==.None && n>0 && n<=len(src)-saving else src
}

@(private="file")
unpack_symbols :: proc "contextless" (w:^Decode_Work,src,dst:[]u8) -> ([]u8,bool) {
    if len(src)==len(dst) {return src,true}
    if len(src)==0 || len(src)>len(dst) || len(dst)<MIN_HUFF {return nil,false}
    if len(src)==1 {
        value:=src[0]
        for &byte in dst {byte=value}
        return dst,true
    }
    if len(dst)<1024 {
        w.table[0]=HUF_DECODER_FAST_TABLELOG-1
        head,err:=huf_read_dtable_x1_wksp(&w.table[0],raw_data(src),len(src),
            &w.huff[0],size_of(w.huff))
        if err!=.None || head>=len(src) {return nil,false}
        size,decode_error:=huf_decompress4x1_using_dtable_internal(raw_data(dst),len(dst),
            raw_data(src[head:]),len(src)-head,&w.table[0])
        return dst,decode_error==.None && size==len(dst)
    }
    w.table[0]=HUFFDTABLE_CAPACITY_LOG*0x1000001
    size,err:=huf_decompress4x_huf_only_wksp(&w.table[0],raw_data(dst),len(dst),
        raw_data(src),len(src),&w.huff[0],size_of(w.huff))
    return dst,err==.None && size==len(dst)
}

@(private="file")
offset_dictionary :: proc "contextless" (w:^Encode_Work) -> (dict:Offset_Dictionary) {
    seqs:=w.sequences[:w.sequence_count]
    reps:=INITIAL_OFFSETS
    for s in seqs {
        slot:=offset_code(reps,s.distance)
        if slot>=3 {w.offset_counts[s.distance]+=1}
        reps=offset_push(reps,slot,s.distance)
    }
    scores:[len(dict.distances)]int
    for s in seqs {
        count:=int(w.offset_counts[s.distance])
        if count==0 {continue}
        w.offset_counts[s.distance]=0
        score:=(count-1)*max(0,high_bit(int(s.distance))-1)
        if score<32 {continue}
        for old,i in scores {
            if score<=old {continue}
            for j:=len(scores)-1;j>i;j-=1 {
                scores[j]=scores[j-1]
                dict.distances[j]=dict.distances[j-1]
            }
            scores[i]=score
            dict.distances[i]=s.distance
            dict.count=min(dict.count+1,len(scores))
            break
        }
    }
    return dict
}

@(private)
Entropy_Streams :: struct {
    literals,length_bytes,offset_bytes:int,
    dictionary:Offset_Dictionary,
}

@(private)
Symbol_Writer :: struct {
    streams:Entropy_Streams,
    length_at:int,
    distances:Bit_Writer,
    reps:Offsets,
    pos,count:int,
}

@(private)
symbol_writer :: #force_inline proc "contextless" (w:^Encode_Work,first:int) -> Symbol_Writer {
    return {distances={bytes=raw_data(w.offset_bits[:])},
        reps=INITIAL_OFFSETS,pos=first}
}

@(private)
symbol_write :: #force_inline proc "contextless" (w:^Encode_Work,b:^Symbol_Writer,src:[]u8,
    ll,ml:int,distance:u32,$DICTIONARY:bool) #no_bounds_check {
    l,m:=literal_code(ll),match_code(ml)
    slot:=offset_code(b.reps,distance,&b.streams.dictionary if DICTIONARY else nil)
    w.tags[b.count]=u8(l<<5|m)
    w.offsets[b.count]=u8(slot)
    b.count+=1
    if ll>=LITERAL_ESCAPE {
        b.length_at+=length_write(w.length_extra[b.length_at:],ll-LITERAL_ESCAPE)
    }
    if ml>=MATCH_ESCAPE {
        b.length_at+=length_write(w.length_extra[b.length_at:],ml-MATCH_ESCAPE)
    }
    if slot>=3 && slot<OFFSET_CLASSES {
        width:=offset_width(slot)
        shift:=ALIGN_BITS if slot>=OFFSET_NORMAL else 0
        bit_write(&b.distances,int(distance>>uint(shift))-(1<<uint(width)),width)
    }
    b.reps=offset_push(b.reps,slot,distance)
    if ll<=8 && b.pos<=len(src)-8 {
        word:=intrinsics.unaligned_load((^u64)(&src[b.pos]))
        intrinsics.unaligned_store((^u64)(&w.literals[b.streams.literals]),word)
    } else {
        copy(w.literals[b.streams.literals:],src[b.pos:][:ll])
    }
    b.streams.literals+=ll
    b.pos+=ll+ml
}

@(private)
symbol_finish :: #force_inline proc "contextless" (w:^Encode_Work,b:^Symbol_Writer,
    src:[]u8) -> Entropy_Streams {
    w.sequence_count=b.count
    b.streams.literals+=copy(w.literals[b.streams.literals:],src[b.pos:])
    b.streams.length_bytes=b.length_at
    b.streams.offset_bytes=bit_finish(&b.distances)
    return b.streams
}

@(private)
build_symbols :: proc "contextless" (w:^Encode_Work,src:[]u8,first:int) -> Entropy_Streams {
    writer:=symbol_writer(w,first)
    writer.streams.dictionary=offset_dictionary(w)
    for s in w.sequences[:w.sequence_count] {
        symbol_write(w,&writer,src,int(s.literals),int(s.length),s.distance,true)
    }
    return symbol_finish(w,&writer,src)
}

@(private)
write_entropy :: proc "contextless" (w:^Encode_Work,streams:^Entropy_Streams,dst:[]u8,
    src:[]u8,first:int,profile:Profile) -> int {
    literal_bytes:=streams.literals
    length_bytes,offset_bytes:=streams.length_bytes,streams.offset_bytes
    dict:=&streams.dictionary
    count:=w.sequence_count
    tags:=pack_symbols(&w.huff,w.tags[:count],w.packed[:count],1)
    offsets:=pack_symbols(&w.huff,w.offsets[:count],w.packed[count:][:count],1)
    saving:=max(1,literal_bytes*(2 if profile==.Fast else LITERAL_SAVING_PERCENT)/100)
    literals:=pack_symbols(&w.huff,w.literals[:literal_bytes],
        w.packed[2*count:][:literal_bytes],saving)
    mode:=Block_Mode.Entropy
    if profile!=.Fast && literal_bytes>=MIN_HUFF && count>0 {
        out,lit,rep:=first,0,int(INITIAL_OFFSETS[0])
        for sequence in w.sequences[:count] {
            n:=int(sequence.literals)
            subtract_literals(w.delta[lit:][:n],src,out,rep)
            lit+=n
            out+=n+int(sequence.length)
            rep=int(sequence.distance)
        }
        subtract_literals(w.delta[lit:literal_bytes],src,out,rep)
        delta:=pack_symbols(&w.huff,w.delta[:literal_bytes],w.packed_delta[:literal_bytes],saving)
        if len(delta)+literal_bytes/200<len(literals) {
            literals,mode=delta,.Delta
        }
    }
    header:=[?]int{count,literal_bytes,len(tags),len(offsets),len(literals),dict.count,length_bytes}
    size:=1+len(tags)+len(offsets)+len(literals)+length_bytes+offset_bytes
    for n in header {size+=length_size(n)}
    for d in dict.distances[:dict.count] {size+=length_size(int(d))}
    if size>=len(dst) {return 0}
    dst[0]=u8(mode)
    at:=1
    for n in header {at+=length_write(dst[at:],n)}
    for d in dict.distances[:dict.count] {at+=length_write(dst[at:],int(d))}
    at+=copy(dst[at:],tags)
    at+=copy(dst[at:],offsets)
    at+=copy(dst[at:],literals)
    at+=copy(dst[at:],w.length_extra[:length_bytes])
    return at+copy(dst[at:],w.offset_bits[:offset_bytes])
}

@(private="file")
Bit_Writer :: struct {bytes:[^]u8,at,width:int,value:u32}

@(private="file")
bit_write :: #force_inline proc "contextless" (w:^Bit_Writer,value,width:int) #no_bounds_check {
    if width==0 {return}
    combined:=w.value|u32(value)<<uint(w.width)
    total:=w.width+width
    intrinsics.unaligned_store((^u32le)(&w.bytes[w.at]),u32le(combined))
    w.at+=total>>3
    w.value=combined>>uint(total&~7)
    w.width=total&7
}

@(private="file")
bit_finish :: proc "contextless" (w:^Bit_Writer) -> int {
    if w.width==0 {return w.at}
    w.bytes[w.at]=u8(w.value)
    return w.at+1
}

@(private="file")
bit_end :: #force_inline proc "contextless" (bits:[]u8,at:int) -> bool {
    if (at+7)/8!=len(bits) {return false}
    return at&7==0 || bits[len(bits)-1]>>uint(at&7)==0
}

@(private)
decode_entropy :: proc "contextless" (w:^Decode_Work,src,dst:[]u8,first:int,delta:bool) -> bool {
    at:=0
    count:=length_read(src,&at)
    raw:=length_read(src,&at)
    nt,no,nl:=length_read(src,&at),length_read(src,&at),length_read(src,&at)
    dict:Offset_Dictionary
    dict.count=length_read(src,&at)
    length_bytes:=length_read(src,&at)
    if dict.count<0 || dict.count>len(dict.distances) {return false}
    for &distance in dict.distances[:dict.count] {
        value:=length_read(src,&at)
        if value<=0 || value>WINDOW {return false}
        distance=u32(value)
    }
    extent:=len(dst)-first
    if count<0 || raw<0 || count>(extent-raw)/MIN_MATCH || raw>extent ||
       nt<0 || no<0 || nl<0 || length_bytes<0 || nt+no+nl+length_bytes>len(src)-at {return false}
    tags,a:=unpack_symbols(w,src[at:][:nt],w.tags[:count])
    if !a {return false}
    at+=nt
    offsets,b:=unpack_symbols(w,src[at:][:no],w.offsets[:count])
    if !b {return false}
    at+=no
    literals,c:=unpack_symbols(w,src[at:][:nl],w.literals[:raw])
    if !c {return false}
    at+=nl
    if count==0 {
        return !delta && at==len(src) && raw==extent && copy(dst[first:],literals)==extent
    }
    // A valid output prefix bounds the literal cursor within this block's padded scratch.
    if raw_data(literals)!=raw_data(w.literals[:]) {copy(w.literals[:],literals)}
    if length_bytes>SEQUENCES_MAX {return false}
    copy(w.length_extra[:],src[at:][:length_bytes])
    w.length_extra[length_bytes]=0
    lengths:=w.length_extra[:length_bytes+1]
    offset_bits:=src[at+length_bytes:]
    if len(offset_bits)>3*count {return false}
    copy(w.offset_bits[:],offset_bits)
    intrinsics.unaligned_store((^u64)(&w.offset_bits[len(offset_bits)]),0)
    // Each validated slot consumes at most WINDOW_BITS-1 bits. The final cursor checks the wire.
    padded:=w.offset_bits[:3*count+8]
    if delta {
        return execute_entropy(tags,offsets,w.literals[:],lengths,
            padded,raw,len(offset_bits),dst,first,&dict,true)
    }
    return execute_entropy(tags,offsets,w.literals[:],lengths,
        padded,raw,len(offset_bits),dst,first,&dict,false)
}

@(private="file")
execute_entropy :: proc "contextless" (tags,offsets,literals,lengths,offset_bits:[]u8,
    literal_end,offset_end:int,dst:[]u8,first:int,dict:^Offset_Dictionary,$DELTA:bool,
) -> bool #no_bounds_check {
    length_at:=0
    length_end:=len(lengths)-1
    offset_at:=0
    // Distance base above the extra bit count and alignment shift.
    slots:[OFFSET_CLASSES+len(dict.distances)]u32
    for distance,i in INITIAL_OFFSETS {slots[i]=distance<<9}
    for slot in 3..<OFFSET_CLASSES {
        shift:=ALIGN_BITS if slot>=OFFSET_NORMAL else 0
        width:=offset_width(slot)
        slots[slot]=u32(width)|u32(shift)<<5|u32(1)<<uint(width+shift+9)
    }
    for distance,i in dict.distances[:dict.count] {slots[OFFSET_CLASSES+i]=distance<<9}
    lit,out:=0,first
    for token,i in tags {
        literal,match:=int(token>>5),int(token&31)+MIN_MATCH
        slot:=int(offsets[i])
        if slot>=OFFSET_CLASSES+dict.count {return false}
        escape:=int(literal==LITERAL_ESCAPE)
        short_len:=int(lengths[min(length_at,length_end)])*escape
        literal+=short_len
        if short_len>=128 {
            extra:=length_read(lengths[:length_end],&length_at)
            if extra<0 {return false}
            literal=LITERAL_ESCAPE+extra
        } else {
            length_at+=escape
        }
        if match==MATCH_ESCAPE {
            extra:=length_read(lengths[:length_end],&length_at)
            if extra<0 {return false}
            match+=extra
        }
        code:=slots[slot]
        distance:=code>>9
        width:=uint(code&31)
        byte:=offset_at>>3
        word:=u64(intrinsics.unaligned_load((^u64le)(&offset_bits[byte])))
        extra:=u32(word>>uint(offset_at&7))&((u32(1)<<width)-1)
        distance|=extra<<uint(code>>5&7)
        offset_at+=int(width)
        rep:=int(slots[0]>>9)
        slots[2]=slots[1] if slot>1 else slots[2]
        slots[1]=slots[0] if slot!=0 else slots[1]
        slots[0]=distance<<9
        when DELTA {
            at:=out+literal
            invalid:=(len(dst)-at-match)|
                (int(distance)-1)|(at-int(distance))
            if invalid<0 {return false}
            if literal<=16 && rep>=16 && out>=rep && len(dst)-out>=16 {
                add16(raw_data(dst),raw_data(literals),out,lit,rep)
            } else {
                add_literals(dst,literals,out,lit,literal,rep)
            }
            copy_match(dst,at,int(distance),match)
        } else {
            if !copy_sequence(dst,literals,out,lit,literal,match,int(distance),true) {return false}
        }
        lit+=literal
        out+=literal+match
    }
    if length_at!=length_end || !bit_end(offset_bits[:offset_end],offset_at) ||
       literal_end-lit!=len(dst)-out {return false}
    when DELTA {
        add_literals(dst,literals,out,lit,literal_end-lit,int(slots[0]>>9))
    } else {
        copy(dst[out:],literals[lit:literal_end])
    }
    return true
}

@(private="file")
subtract_literals :: #force_inline proc "contextless" (dst,src:[]u8,
    start,rep:int) #no_bounds_check {
    out:=0
    for ;start+out<rep && out<len(dst);out+=1 {dst[out]=src[start+out]}
    for ;out+16<=len(dst);out+=16 {
        lit:=intrinsics.unaligned_load((^Bytes16)(&src[start+out]))
        prev:=intrinsics.unaligned_load((^Bytes16)(&src[start+out-rep]))
        intrinsics.unaligned_store((^Bytes16)(&dst[out]),lit-prev)
    }
    for ;out<len(dst);out+=1 {dst[out]=src[start+out]-src[start+out-rep]}
}

@(private="file")
add16 :: #force_inline proc "contextless" (dst,src:[^]u8,out,lit,rep:int) {
    residual:=intrinsics.unaligned_load((^Bytes16)(&src[lit]))
    reference:=intrinsics.unaligned_load((^Bytes16)(&dst[out-rep]))
    intrinsics.unaligned_store((^Bytes16)(&dst[out]),residual+reference)
}

@(private="file")
add_literals :: proc "contextless" (dst,src:[]u8,out,lit,count,rep:int) #no_bounds_check {
    i:=0
    for ;out+i<rep && i<count;i+=1 {dst[out+i]=src[lit+i]}
    if rep>=16 {
        for ;i+16<=count;i+=16 {add16(raw_data(dst),raw_data(src),out+i,lit+i,rep)}
    }
    for ;i<count;i+=1 {dst[out+i]=src[lit+i]+dst[out+i-rep]}
}
