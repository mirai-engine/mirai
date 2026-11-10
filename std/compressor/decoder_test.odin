package compressor

import "base:sanitizer"
import "core:mem"
import "core:testing"

// Streams of fixture_input at Normal, Fast (with a period), Optimal5 and SuperFast: the bytes of
// the reference encoder.
@(private="file")
Fixture :: struct {name:string,stream:[]u8,size:int,period:int}

@(private="file")
FIXTURES := [?]Fixture{
    {"lz_normal",#load("testdata/lz_normal.bin"),140*1024,0},
    {"lz_blocks",#load("testdata/lz_blocks.bin"),600*1024,100*1024},
    {"lz_optimal5",#load("testdata/lz_optimal5.bin"),140*1024,0},
    {"lz_small",#load("testdata/lz_small.bin"),700,0},
}

// Words, deltas, runs, repeats, small symbols, ramps and noise. The fixture
// streams were checked against the reference encoder with the same procedure.
@(private="file")
fixture_input :: proc(out:[]u8) {
    WORDS :: [?]string{"press ","lz ","stream ","decode ","mirai ","engine ","block ",
        "chunk ","quantum ","huffman ","offset ","literal ","match ","the ","and ","of "}
    words:=WORDS
    state:=u64(0x9E3779B97F4A7C15)
    next :: proc(s:^u64) -> u64 {s^~=s^<<13;s^~=s^>>7;s^~=s^<<17;return s^}
    i:=0
    for i<len(out) {
        LENS :: [7]int{1500,1500,3000,12000,600,3000,150}
        lens:=LENS
        kind:=int(next(&state)%7)
        if i<1024 && kind==3 {kind=5}
        seg:=min(len(out)-i,lens[kind]+int(next(&state)%500))
        switch kind {
        case 0:
            j:=0
            for j<seg {
                w:=words[next(&state)%len(words)]
                for c in transmute([]u8)w {if j<seg {out[i+j]=c;j+=1}}
            }
        case 1:
            v:=u16(next(&state))
            for j:=0;j+1<seg;j+=2 {
                v+=u16(next(&state)%7)
                out[i+j]=u8(v);out[i+j+1]=u8(v>>8)
            }
            if seg&1==1 {out[i+seg-1]=0}
        case 2:
            for j:=0;j<seg; {
                run:=1+int(next(&state)%300)
                b:=u8(next(&state)%4)
                for k:=0;k<run && j<seg;k+=1 {out[i+j]=b;j+=1}
            }
        case 3:
            if i<1024 {for j in 0..<seg {out[i+j]=u8(j)};break}
            for j:=0;j<seg; {
                l:=min(seg-j,20+int(next(&state)%200))
                from:=int(next(&state)%u64(i-l))
                for k in 0..<l {out[i+j+k]=out[from+k]}
                j+=l
            }
        case 4:
            for j in 0..<seg {
                r:=next(&state)
                out[i+j]=u8(r&15)+u8((r>>8)&3)*u8(r>>20&1)
            }
        case 5:
            for j in 0..<seg {out[i+j]=u8(j/8)}
        case 6:
            for j in 0..<seg {out[i+j]=u8(next(&state))}
        }
        i+=seg
    }
}

@(private="file")
fixture_raw :: proc(f:Fixture) -> []u8 {
    raw:=make([]u8,f.size)
    if f.period==0 {
        fixture_input(raw)
    } else {
        fixture_input(raw[:f.period])
        for i in f.period..<len(raw) {raw[i]=raw[i-f.period]}
    }
    return raw
}

@(private="file") SANITIZED :: .Address in ODIN_SANITIZER_FLAGS
// A multiple of the 8 bytes the sanitizer tracks at once, so that a buffer starts where its guard
// ends.
@(private="file") GUARD :: 4096 when SANITIZED else 64

// size bytes between two guards of canaries. Under the address sanitizer the guards are
// poisoned: it reports any read or write of them, which the canaries alone do not see when it is
// a read. The allocator of a test hands out parts of larger blocks, which the sanitizer does not
// tell apart.
@(private="file")
guarded_make :: proc(size:int) -> []u8 {
    buf:=make([]u8,size+2*GUARD)
    for &b in buf {b=0xa5}
    when SANITIZED {
        sanitizer.address_poison(buf[:GUARD])
        sanitizer.address_poison(buf[GUARD+size:])
    }
    return buf[GUARD:][:size]
}

// Whether the guards hold their canaries, and the buffer freed.
@(private="file")
guarded_free :: proc(out:[]u8) -> (intact:bool) {
    buf:=([^]u8)(raw_data(out))[-GUARD:][:len(out)+2*GUARD]
    when SANITIZED {sanitizer.address_unpoison(buf)}
    intact=true
    for b in buf[:GUARD] {intact&=b==0xa5}
    for b in buf[GUARD+len(out):] {intact&=b==0xa5}
    delete(buf)
    return
}

// A decoder whose scratch is between guards, as what it decodes from and into.
@(private="file")
guarded_decoder_init :: proc(t:^testing.T,d:^Decoder) -> (own:[]u8) {
    testing.expect_value(t,decoder_init(d),Error.None)
    own=d.scratch
    d.scratch=guarded_make(len(own))
    return
}

@(private="file")
guarded_decoder_destroy :: proc(t:^testing.T,d:^Decoder,own:[]u8) {
    testing.expect(t,guarded_free(d.scratch),"nothing written outside the scratch")
    d.scratch=own
    decoder_destroy(d)
}

// Decodes into a guarded buffer; under the sanitizer, from a guarded copy of src too.
@(private="file")
guarded_decode :: proc(t:^testing.T,d:^Decoder,src:[]u8,size:int) -> (out:[]u8,written:int,err:Error) {
    out=guarded_make(size)
    when SANITIZED {
        from:=guarded_make(len(src))
        copy(from,src)
        written,err=decompress(d,from,out)
        guarded_free(from)
    } else {
        written,err=decompress(d,src,out)
    }
    return
}

@(private="file")
release :: proc(t:^testing.T,out:[]u8,loc:=#caller_location) {
    testing.expect(t,guarded_free(out),"nothing written outside dst",loc=loc)
}

@(test)
library_streams_decode_to_their_input :: proc(t:^testing.T) {
    d:Decoder
    own:=guarded_decoder_init(t,&d)
    defer guarded_decoder_destroy(t,&d,own)
    for f in FIXTURES {
        raw:=fixture_raw(f);defer delete(raw)
        out,n,err:=guarded_decode(t,&d,f.stream,f.size);defer release(t,out)
        testing.expectf(t,err==.None && n==f.size,"%s: %v, %d bytes",f.name,err,n)
        testing.expectf(t,string(out)==string(raw),"%s decodes to its input",f.name)
    }
}

@(test)
decompress_does_not_allocate :: proc(t:^testing.T) {
    d:Decoder
    testing.expect_value(t,decoder_init(&d),Error.None)
    defer decoder_destroy(&d)
    out:=make([]u8,FIXTURES[0].size);defer delete(out)
    tracking:mem.Tracking_Allocator
    mem.tracking_allocator_init(&tracking,
        context.allocator);defer mem.tracking_allocator_destroy(&tracking)
    {
        context.allocator=mem.tracking_allocator(&tracking)
        context.temp_allocator=mem.tracking_allocator(&tracking)
        for f in FIXTURES[:1] {_,_=decompress(&d,f.stream,out)}
    }
    testing.expect_value(t,tracking.total_allocation_count,0)
}

@(test)
an_uninitialized_decoder_fails :: proc(t:^testing.T) {
    d:Decoder
    out:[16]u8
    _,err:=decompress(&d,FIXTURES[3].stream,out[:])
    testing.expect(t,err!=.None)
    _,err=decompress(nil,FIXTURES[3].stream,out[:])
    testing.expect(t,err!=.None)
}

@(test)
truncated_streams_fail :: proc(t:^testing.T) {
    d:Decoder
    own:=guarded_decoder_init(t,&d)
    defer guarded_decoder_destroy(t,&d,own)
    for f in FIXTURES {
        step:=max(1,len(f.stream)/3000)
        for n:=0;n<len(f.stream);n+=step {
            out,_,err:=guarded_decode(t,&d,f.stream[:n],f.size)
            release(t,out)
            testing.expectf(t,err!=.None,"%s cut at %d fails",f.name,n)
        }
    }
}

@(test)
a_wrong_output_size_fails :: proc(t:^testing.T) {
    d:Decoder
    own:=guarded_decoder_init(t,&d)
    defer guarded_decoder_destroy(t,&d,own)
    for f in FIXTURES {
        for size in ([?]int{f.size-1,f.size-200,f.size/2+3,f.size+1,f.size+5000}) {
            if size<=0 {continue}
            out,_,err:=guarded_decode(t,&d,f.stream,size)
            release(t,out)
            testing.expectf(t,err!=.None,"%s into %d bytes fails",f.name,size)
        }
    }
}

@(private="file")
next_random :: proc(state:^u64) -> u64 {
    state^+=0x9e3779b97f4a7c15
    z:=state^
    z=(z~(z>>30))*0xbf58476d1ce4e5b9
    z=(z~(z>>27))*0x94d049bb133111eb
    return z~(z>>31)
}

@(private="file") MUTATIONS :: #config(COMPRESSOR_MUTATIONS,1500)
@(private="file") MUTATION_SEED :: #config(COMPRESSOR_MUTATION_SEED,7)

// A run of bytes the decoder takes sizes, counts or a table from.
@(private="file")
Field :: struct {at,len:int}

// The header of the entropy array at at and the start of what it codes, where its code lengths
// or its state table are; the arrays of a split, each. Returns the bytes of the array, or -1.
@(private="file")
array_fields :: proc(out:^[dynamic]Field,stream:[]u8,at,end:int) -> int {
    if at>=end {return -1}
    from:=raw_data(stream)[at:]
    n:int
    used:=get_arraylens(from,raw_data(stream)[end:],&n,CHUNK_LEN)
    if used<0 {return -1}
    small:=from[0]>=ARRAY_SMALL_FLAG
    kind:=int(from[0]>>4)&(small ? 7 : 15)
    header:=kind==ARRAY_TYPE_UNCOMPRESSED ? (small ? 2 : 3) : (small ? 3 : 5)
    append(out,Field{at,min(header,used)})
    if kind==ARRAY_TYPE_UNCOMPRESSED || used<=header {return used}
    TABLE :: 24
    append(out,Field{at+header,min(TABLE,used-header)})
    if used-header>2*TABLE {append(out,Field{at+used-TABLE,TABLE})}
    if kind==ARRAY_TYPE_SPLIT && stream[at+header]&0x80==0 {
        p:=at+header+1
        for _ in 0..<int(stream[at+header]&0x7f) {
            part:=array_fields(out,stream,p,at+used)
            if part<0 {break}
            p+=part
        }
    }
    return used
}

// The fields of a chunk of LZ arrays, in the order lz_phase1 reads them: the excess header, the
// arrays of literals, packets, offsets and excesses, and the two ends of the bits after them.
@(private="file")
chunk_fields :: proc(out:^[dynamic]Field,stream:[]u8,at,end:int,first:bool) {
    p:=at
    if first {p+=MIN_OFFSET}
    if p<end && stream[p]>=LZ_EXCESS_HEADER {
        long:=stream[p]&0x3f>=32
        append(out,Field{p,long ? 2 : 1})
        p+=long ? 2 : 1
    }
    arrays:=3
    for i:=0;i<arrays;i+=1 {
        if i==2 && p<end && stream[p]>=LZ_ALT_OFFSETS {
            append(out,Field{p,1})
            if stream[p]!=LZ_ALT_OFFSETS {arrays+=1}
            p+=1
        }
        used:=array_fields(out,stream,p,end)
        if used<0 {return}
        p+=used
    }
    if used:=array_fields(out,stream,p,end);used>=0 {p+=used} else {return}
    if p<end {
        append(out,Field{p,min(8,end-p)})
        append(out,Field{max(p,end-8),end-max(p,end-8)})
    }
}

// Where a valid stream keeps what the decoder trusts: the headers of its blocks, quanta, chunks
// and entropy arrays, and the tables of those arrays.
@(private="file")
stream_fields :: proc(stream:[]u8,size:int) -> [dynamic]Field {
    out:=make([dynamic]Field)
    pos,at,since_reset:=0,0,0
    for pos<size {
        block_len:=min(BLOCK_LEN,size-pos)
        b,err:=block_read(raw_data(stream),len(stream),at,block_len,pos==0)
        if err!=.None {break}
        if b.reset {since_reset=0}
        append(&out,Field{at,b.data-at})
        if b.size>0 && b.size<block_len {
            p,end:=b.data,b.data+b.size
            for raw:=0;raw<block_len && end-p>=4; {
                chunk_len:=min(CHUNK_LEN,block_len-raw)
                header:=int(load24be(raw_data(stream)[p:]))
                if header>=CHUNK_COMPRESSED {
                    append(&out,Field{p,CHUNK_HEADER_SIZE})
                    comp_len:=header&CHUNK_COMP_LEN_MASK
                    p+=CHUNK_HEADER_SIZE
                    if comp_len>end-p {break}
                    if comp_len<chunk_len {chunk_fields(&out,stream,p,p+comp_len,since_reset+raw==0)}
                    p+=comp_len
                } else {
                    used:=array_fields(&out,stream,p,end)
                    if used<0 {break}
                    p+=used
                }
                raw+=chunk_len
            }
        }
        at=b.data+b.size
        pos+=block_len
        since_reset+=block_len
    }
    return out
}

// A field with a value its writer would not put there: an extreme, a neighbor of what it holds,
// noise in all of it, or one bit.
@(private="file")
field_mutate :: proc(work:[]u8,field:Field,state:^u64) {
    if field.len<=0 {return}
    HOSTILE :: [?]u8{0x00,0x01,0x7f,0x80,0xfe,0xff}
    hostile:=HOSTILE
    at:=field.at+int(next_random(state)%u64(field.len))
    switch next_random(state)%5 {
    case 0: work[at]=hostile[next_random(state)%len(hostile)]
    case 1: work[at]=u8(int(work[at])+int(next_random(state)%5)-2)
    case 2: for &b in work[field.at:][:field.len] {b=u8(next_random(state))}
    case 3: work[at]~=u8(1)<<(next_random(state)%8)
    case 4: for &b in work[field.at:][:field.len] {b=hostile[next_random(state)%len(hostile)]}
    }
}

// Mutated streams decode to anything or fail, without reading or writing out
// of bounds (run under the sanitizer for the reads). Half of the rounds change
// bytes anywhere, which mostly lands in what the arrays code; the other half
// keeps the stream valid up to a header or a table and changes that.
@(test)
mutated_streams_never_escape_their_buffers :: proc(t:^testing.T) {
    d:Decoder
    own:=guarded_decoder_init(t,&d)
    defer guarded_decoder_destroy(t,&d,own)
    state:=u64(MUTATION_SEED)
    for f in FIXTURES {
        fields:=stream_fields(f.stream,f.size);defer delete(fields)
        testing.expectf(t,len(fields)>=2,"%s has headers to mutate",f.name)
        work:=make([]u8,len(f.stream));defer delete(work)
        for round in 0..<MUTATIONS/len(FIXTURES) {
            copy(work,f.stream)
            for _ in 0..<1+int(next_random(&state)%4) {
                if round&1==1 && len(fields)>0 {
                    field_mutate(work,fields[next_random(&state)%u64(len(fields))],&state)
                    continue
                }
                at:=int(next_random(&state)%u64(len(work)))
                switch next_random(&state)%3 {
                case 0: work[at]~=u8(1)<<(next_random(&state)%8)
                case 1: work[at]=u8(next_random(&state))
                case 2: work[at]=u8(int(work[at])+int(next_random(&state)%5)-2)
                }
            }
            out,_,_:=guarded_decode(t,&d,work,f.size)
            release(t,out)
        }
    }
}

@(test)
random_data_fails :: proc(t:^testing.T) {
    d:Decoder
    own:=guarded_decoder_init(t,&d)
    defer guarded_decoder_destroy(t,&d,own)
    state:=u64(11)
    buf:=make([]u8,64*1024);defer delete(buf)
    for round in 0..<200 {
        n:=1+int(next_random(&state)%u64(len(buf)))
        for i in 0..<n {buf[i]=u8(next_random(&state))}
        // Valid block headers lead the random payload half of the time.
        if round&1==1 && n>=2 {
            buf[0]=BLOCK_HEADER_VERSION_NIBBLE|BLOCK_HEADER_RESET
            buf[1]=u8(round&2==0 ? DECODE_TYPE_LZ : round%DECODE_TYPE_COUNT)
        }
        out,_,err:=guarded_decode(t,&d,buf[:n],1+int(next_random(&state)%300000))
        release(t,out)
        testing.expect(t,err!=.None,"random data fails")
    }
}

// A stream of two pieces: a stored block that resets, a whole match of it that does not, and the
// lz_blocks fixture, which resets at its first block.
@(private="file")
pieced_stream :: proc() -> (stream:[]u8,size:int) {
    out:=make([dynamic]u8)
    append(&out,BLOCK_HEADER_VERSION_NIBBLE|BLOCK_HEADER_MEMCPY|BLOCK_HEADER_RESET,DECODE_TYPE_LZ)
    stored:=make([]u8,BLOCK_LEN);defer delete(stored)
    fixture_input(stored)
    append(&out,..stored)
    // QUANTUM_SPECIAL_WHOLE_MATCH at offset 4096: the 15-bit form of offset-1.
    word:=(1<<WHOLE_MATCH_BITS1)+4095
    append(&out,BLOCK_HEADER_VERSION_NIBBLE,DECODE_TYPE_LZ,0x03,0xFF,0xFF,u8(word>>8),u8(word))
    append(&out,..FIXTURES[1].stream)
    return out[:],2*BLOCK_LEN+FIXTURES[1].size
}

// Decodes each piece on its own into its part of out; false when one fails.
@(private="file")
pieces_decode :: proc(t:^testing.T,d:^Decoder,src:[]u8,out:[]u8,found:[]Piece) -> bool {
    for piece,i in found {
        src_end,dst_end:=len(src),len(out)
        if i+1<len(found) {src_end,dst_end=found[i+1].src,found[i+1].dst}
        testing.expect(t,piece.src<src_end && piece.dst<dst_end && src_end<=len(src))
        part,written,err:=guarded_decode(t,d,src[piece.src:src_end],dst_end-piece.dst)
        defer release(t,part)
        if err!=.None || written!=len(part) {return false}
        copy(out[piece.dst:],part)
    }
    return true
}

// Each piece decodes on its own to what the whole stream decodes to, also when the stream is
// mutated: the whole fails exactly when a piece does.
@(test)
pieces_decode_on_their_own_to_the_whole_stream :: proc(t:^testing.T) {
    d:Decoder
    own:=guarded_decoder_init(t,&d)
    defer guarded_decoder_destroy(t,&d,own)
    stream,size:=pieced_stream();defer delete(stream)
    found:[8]Piece
    count,err:=pieces(stream,size,found[:])
    testing.expect_value(t,err,Error.None)
    testing.expect_value(t,count,2)
    testing.expect(t,found[0]=={0,0} && found[1]=={BLOCK_HEADER_SIZE+BLOCK_LEN+7,2*BLOCK_LEN})
    one:[1]Piece
    count,err=pieces(stream,size,one[:])
    testing.expect(t,count==2 && err==.None && one[0]=={0,0},"count goes past what out holds")
    whole,_,whole_err:=guarded_decode(t,&d,stream,size);defer release(t,whole)
    testing.expect_value(t,whole_err,Error.None)
    raw:=fixture_raw(FIXTURES[1]);defer delete(raw)
    testing.expect(t,string(whole[2*BLOCK_LEN:])==string(raw))
    testing.expect(t,string(whole[BLOCK_LEN:2*BLOCK_LEN])==string(whole[BLOCK_LEN-4096:2*BLOCK_LEN-4096]))
    apart:=make([]u8,size);defer delete(apart)
    testing.expect(t,pieces_decode(t,&d,stream,apart,found[:count]))
    testing.expect(t,string(apart)==string(whole))
    // A whole match that reaches back past the reset of its piece is corrupt, whole or apart.
    reaching:=make([]u8,len(stream));defer delete(reaching)
    copy(reaching,stream)
    reaching[BLOCK_HEADER_SIZE+BLOCK_LEN]|=BLOCK_HEADER_RESET
    count,err=pieces(reaching,size,found[:])
    testing.expect(t,count==3 && err==.None)
    reached,_,reached_err:=guarded_decode(t,&d,reaching,size);release(t,reached)
    testing.expect_value(t,reached_err,Error.Corrupt)
    testing.expect(t,!pieces_decode(t,&d,reaching,apart,found[:count]))
    // A stream whose first block does not reset has no pieces.
    reaching[0]&=~u8(BLOCK_HEADER_RESET)
    _,err=pieces(reaching,size,found[:])
    testing.expect_value(t,err,Error.Corrupt)
    work:=make([]u8,len(stream));defer delete(work)
    state:=u64(13)
    for round in 0..<MUTATIONS/4 {
        copy(work,stream)
        // Mostly the headers of the blocks after the first.
        for _ in 0..<1+int(next_random(&state)%3) {
            at:=round%2==0 ? 2+BLOCK_LEN+int(next_random(&state)%40) : int(next_random(&state)%u64(len(work)))
            work[at]~=u8(1)<<(next_random(&state)%8)
        }
        out,written,whole_error:=guarded_decode(t,&d,work,size)
        defer release(t,out)
        n,scan_error:=pieces(work,size,found[:])
        if whole_error==.None {
            testing.expect(t,written==size && scan_error==.None && n>=1 && n<=len(found))
        }
        if scan_error!=.None || n<1 || n>len(found) {continue}
        ok:=pieces_decode(t,&d,work,apart,found[:n])
        testing.expectf(t,ok==(whole_error==.None),"round %d: pieces %v, whole %v",round,ok,whole_error)
        if ok && whole_error==.None {testing.expect(t,string(apart)==string(out))}
    }
}
