package data

import "base:intrinsics"
import "../zstd"

@(private) MIN_HUFF :: 32
@(private) Huff_Work :: [zstd.HUF_WORKSPACE_SIZE/8]u64
@(private) Offsets :: [3]u32
@(private) INITIAL_OFFSETS :: Offsets{1,4,8}
@(private) ALIGN_BITS :: 2
@(private) OFFSET_NORMAL :: 3+19
@(private) OFFSET_CLASSES :: OFFSET_NORMAL+19-ALIGN_BITS
@(private) Offset_Dictionary :: struct {
    distances:[8]u32,
    count:int,
}

@(private)
Decode_Work :: struct {
    tags,offsets:[SEQUENCES_MAX]u8,
    literals:[BLOCK_BYTES]u8,
    huff:[zstd.HUF_DECOMPRESS_WORKSPACE_SIZE_U32]u32,
    table:[1+(1<<zstd.HUFFDTABLE_CAPACITY_LOG)]u32,
}

@(private)
Stream :: enum {Tag,Offset,Literal}

@(private)
Symbol_Cost :: [Stream][256]u16

@(private)
Code :: struct {base,bits:int}

@(private)
LITERAL_CODES :: [8]Code{{0,0},{1,0},{2,0},{3,0},{4,2},{8,3},{16,4},{32,0}}

@(private)
MATCH_CODES :: [22]Code{
    {3,0},{4,0},{5,0},{6,0},{7,0},{8,0},{9,0},{10,0},
    {11,3},{19,4},{35,5},{67,6},{131,7},{259,8},{515,9},{1027,10},
    {2051,11},{4099,12},{8195,13},{16387,14},{32771,15},{65539,16},
}

@(private)
literal_code :: #force_inline proc "contextless" (n:int) -> int {
    if n<4 {return n}
    return min(7,2+high_bit(n))
}

@(private)
match_code :: #force_inline proc "contextless" (n:int) -> int {
    value:=n-MIN_MATCH
    if value<8 {return value}
    return 5+high_bit(value)
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
    n,err:=zstd.huf_compress4x_repeat(raw_data(dst),len(dst),raw_data(src),len(src),255,log,
        ([^]u8)(w),size_of(w^),nil,nil,{})
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
        w.table[0]=zstd.HUF_DECODER_FAST_TABLELOG-1
        head,err:=zstd.huf_read_dtable_x1_wksp(&w.table[0],raw_data(src),len(src),
            &w.huff[0],size_of(w.huff))
        if err!=.None || head>=len(src) {return nil,false}
        size,decode_error:=zstd.huf_decompress4x_using_dtable(raw_data(dst),len(dst),
            raw_data(src[head:]),len(src)-head,&w.table[0])
        return dst,decode_error==.None && size==len(dst)
    }
    w.table[0]=zstd.HUFFDTABLE_CAPACITY_LOG*0x1000001
    size,err:=zstd.huf_decompress4x_huf_only_wksp(&w.table[0],raw_data(dst),len(dst),
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
    literals,length_bits,offset_bits:int,
    dictionary:Offset_Dictionary,
}

@(private)
Symbol_Writer :: struct {
    streams:Entropy_Streams,
    lengths,distances:Bit_Writer,
    reps:Offsets,
    pos,count:int,
}

@(private)
symbol_writer :: #force_inline proc "contextless" (w:^Encode_Work,first:int) -> Symbol_Writer {
    return {lengths={bytes=raw_data(w.length_bits[:])},distances={bytes=raw_data(w.offset_bits[:])},
        reps=INITIAL_OFFSETS,pos=first}
}

@(private)
symbol_write :: #force_inline proc "contextless" (w:^Encode_Work,b:^Symbol_Writer,src:[]u8,
    ll,ml:int,distance:u32,$DICTIONARY:bool) #no_bounds_check {
    literal_codes,match_codes:=LITERAL_CODES,MATCH_CODES
    l,m:=literal_code(ll),match_code(ml)
    slot:=offset_code(b.reps,distance,&b.streams.dictionary if DICTIONARY else nil)
    w.tags[b.count]=u8(l<<5|m)
    w.offsets[b.count]=u8(slot)
    b.count+=1
    if l==7 {
        for n:=ll-32;;n>>=7 {
            bit_write(&b.lengths,n&127|int(n>=128)<<7,8)
            if n<128 {break}
        }
    }
    lc,mc:=literal_codes[l],match_codes[m]
    low:=ll-lc.base if l<7 else 0
    bit_write(&b.lengths,low|(ml-mc.base)<<uint(lc.bits),lc.bits+mc.bits)
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
    b.streams.length_bits=bit_finish(&b.lengths)
    b.streams.offset_bits=bit_finish(&b.distances)
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
write_entropy :: proc "contextless" (w:^Encode_Work,streams:^Entropy_Streams,dst:[]u8) -> int {
    literal_bytes:=streams.literals
    length_bytes,offset_bytes:=streams.length_bits,streams.offset_bits
    dict:=&streams.dictionary
    count:=w.sequence_count
    tags:=pack_symbols(&w.huff,w.tags[:count],w.packed[:count],1)
    offsets:=pack_symbols(&w.huff,w.offsets[:count],w.packed[count:][:count],1)
    literals:=pack_symbols(&w.huff,w.literals[:literal_bytes],w.packed[2*count:][:literal_bytes],
        max(1,literal_bytes/50))
    header:=[?]int{count,literal_bytes,len(tags),len(offsets),len(literals),dict.count,length_bytes}
    size:=1+len(tags)+len(offsets)+len(literals)+length_bytes+offset_bytes
    for n in header {size+=length_size(n)}
    for d in dict.distances[:dict.count] {size+=length_size(int(d))}
    if size>=len(dst) {return 0}
    dst[0]=u8(Block_Mode.Entropy)
    at:=1
    for n in header {at+=length_write(dst[at:],n)}
    for d in dict.distances[:dict.count] {at+=length_write(dst[at:],int(d))}
    at+=copy(dst[at:],tags)
    at+=copy(dst[at:],offsets)
    at+=copy(dst[at:],literals)
    at+=copy(dst[at:],w.length_bits[:length_bytes])
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
Bit_Reader :: struct {src:[^]u8,at,last:int,tail:u64}

@(private="file")
bit_reader :: #force_inline proc "contextless" (r:^Bit_Reader,extra:[]u8) {
    r.at=0
    r.last=max(0,len(extra)-8)
    if len(extra)>=8 {
        r.src=raw_data(extra)
    } else {
        r.tail=0
        if len(extra)>0 {intrinsics.mem_copy_non_overlapping(&r.tail,raw_data(extra),len(extra))}
        r.src=([^]u8)(&r.tail)
    }
}

@(private="file")
bit_peek :: #force_inline proc "contextless" (r:^Bit_Reader) -> u64 {
    // Clamp the load even for a corrupt cursor. bit_end validates the consumed extent.
    byte:=min(r.at>>3,r.last)
    word:=u64(intrinsics.unaligned_load((^u64le)(&r.src[byte])))
    return word>>uint(min(r.at-byte*8,63))
}

@(private="file")
bit_end :: #force_inline proc "contextless" (bits:[]u8,at:int) -> bool {
    if (at+7)/8!=len(bits) {return false}
    return at&7==0 || bits[len(bits)-1]>>uint(at&7)==0
}

@(private)
decode_entropy :: proc "contextless" (w:^Decode_Work,src,dst:[]u8,first:int) -> bool {
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
        return at==len(src) && raw==extent && copy(dst[first:],literals)==extent
    }
    return execute_entropy(tags,offsets,literals,src[at:][:length_bytes],
        src[at+length_bytes:],dst,first,&dict)
}

@(private="file")
execute_entropy :: proc "contextless" (tags,offsets,literals,length_bits,offset_bits,dst:[]u8,
    first:int,dict:^Offset_Dictionary) -> bool #no_bounds_check {
    lengths,distances:Bit_Reader
    bit_reader(&lengths,length_bits)
    bit_reader(&distances,offset_bits)
    // Distance base above the extra bit count and alignment shift.
    slots:[OFFSET_CLASSES+len(dict.distances)]u32
    for distance,i in INITIAL_OFFSETS {slots[i]=distance<<8}
    for slot in 3..<OFFSET_CLASSES {
        shift:=ALIGN_BITS if slot>=OFFSET_NORMAL else 0
        width:=offset_width(slot)
        slots[slot]=u32(width)|u32(shift)<<5|u32(1)<<uint(width+shift+8)
    }
    for distance,i in dict.distances[:dict.count] {slots[OFFSET_CLASSES+i]=distance<<8}
    lit,out:=0,first
    literal_codes,match_codes:=LITERAL_CODES,MATCH_CODES
    for token,i in tags {
        l,m:=int(token>>5),int(token&31)
        slot:=int(offsets[i])
        if m>=len(match_codes) || slot>=OFFSET_CLASSES+dict.count {return false}
        literal,match:=l,m+MIN_MATCH
        if l>=4 || m>=8 {
            ll,ml:=literal_codes[l],match_codes[m]
            value:=bit_peek(&lengths)
            literal=ll.base
            if l==7 {
                for shift in 0..<3 {
                    byte:=int(u8(value))
                    if shift>0 && byte==0 {return false}
                    literal+=(byte&127)<<uint(7*shift)
                    value>>=8
                    lengths.at+=8
                    if byte<128 {break}
                    if shift==2 {return false}
                }
            }
            literal+=int(value)&((1<<uint(ll.bits))-1)
            match=ml.base+(int(value>>uint(ll.bits))&((1<<uint(ml.bits))-1))
            lengths.at+=ll.bits+ml.bits
        }

        code:=slots[slot]
        distance:=code>>8
        width:=uint(code&31)
        if width!=0 {
            offset:=u32(bit_peek(&distances))&((u32(1)<<width)-1)
            distances.at+=int(width)
            distance|=offset<<uint(code>>5&3)
        }
        slots[2]=slots[1] if slot>1 else slots[2]
        slots[1]=slots[0] if slot!=0 else slots[1]
        slots[0]=distance<<8
        if !copy_sequence(dst,literals,out,lit,literal,match,int(distance)) {return false}
        lit+=literal
        out+=literal+match
    }
    if !bit_end(length_bits,lengths.at) || !bit_end(offset_bits,distances.at) ||
       len(literals)-lit!=len(dst)-out {return false}
    copy(dst[out:],literals[lit:])
    return true
}
