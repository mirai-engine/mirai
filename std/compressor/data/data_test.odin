package data

import "base:runtime"
import "core:mem"
import "core:testing"

@(private="file")
Pattern :: enum {Random,Repeated,Records,Palette}

@(private="file")
next_byte :: proc "contextless" (state:^u32) -> u8 {
    state^~=state^<<13
    state^~=state^>>17
    state^~=state^<<5
    return u8(state^)
}

@(private="file")
fill :: proc "contextless" (bytes:[]u8,pattern:Pattern,seed:u32) {
    state:=seed
    for &byte,i in bytes {
        random:=next_byte(&state)
        switch pattern {
        case .Random: byte=random
        case .Repeated: byte=u8(i%7)
        case .Records:
            field:=i%32
            switch {
            case field<8: byte=u8(i/256+field*17)
            case field<16: byte=u8((i/32+field)%11)
            case field<20: byte=random
            case: byte=0
            }
        case .Palette: byte=random&63
        }
    }
}

@(test)
mdc2_profiles_round_trip_block_extents :: proc(t:^testing.T) {
    e:Encoder
    d:Decoder
    if !testing.expect_value(t,encoder_init(&e),Error.None) {return}
    defer encoder_destroy(&e)
    if !testing.expect_value(t,decoder_init(&d),Error.None) {return}
    defer decoder_destroy(&d)

    for profile in Profile {
        testing.expect_value(t,format(profile),MDC2)
        testing.expect_value(t,format(profile,open=true),MDC2)
    }
    source:=make([]u8,2*BLOCK_BYTES+1)
    dest:=make([]u8,len(source))
    packed:=make([]u8,bound(len(source)))
    again:=make([]u8,len(packed))
    defer {
        delete(source)
        delete(dest)
        delete(packed)
        delete(again)
    }
    sizes:=[]int{0,1,3,4,31,63,4<<10,(32<<10)-1,32<<10,64<<10,
        BLOCK_BYTES,BLOCK_BYTES+1,2*BLOCK_BYTES,2*BLOCK_BYTES+1}
    for n in sizes {
        raw:=source[:n]
        for pattern in Pattern {
            fill(raw,pattern,1)
            for profile in Profile {
                encoded,err:=encode(&e,profile,raw,packed[:bound(n)])
                if !testing.expectf(t,err==.None,"%d %v %v: %v",n,pattern,profile,err) {return}
                wire:=packed[:encoded]
                decoded:=decode(&d,MDC2,wire,dest[:n])
                if !testing.expectf(t,decoded==.None && string(dest[:n])==string(raw),
                    "%d %v %v: %v",n,pattern,profile,decoded) {return}
                written,rewrite:=encode(&e,profile,raw,again[:bound(n)],open=true)
                if !testing.expectf(t,rewrite==.None && string(wire)==string(again[:written]),
                    "%d %v %v must be deterministic",n,pattern,profile) {return}
            }
        }
    }
}

@(test)
speed_uses_lz_and_entropy_pays_for_its_header :: proc(t:^testing.T) {
    e:Encoder
    encoder_init(&e)
    defer encoder_destroy(&e)
    raw:=make([]u8,16<<10)
    wire:=make([]u8,bound(len(raw)))
    defer {delete(raw);delete(wire)}

    cases:=[?]struct{profile:Profile,pattern:Pattern,mode:Block_Mode}{
        {.Fast,.Random,.Raw},
        {.Fast,.Repeated,.Entropy},
        {.Fast,.Palette,.Entropy},
        {.Speed,.Repeated,.LZ},
        {.Speed,.Palette,.Raw},
        {.Balanced,.Repeated,.Entropy},
        {.Balanced,.Palette,.Entropy},
        {.Ultra,.Palette,.Entropy},
    }
    for c in cases {
        fill(raw,c.pattern,3)
        n,error:=encode(&e,c.profile,raw,wire)
        if !testing.expect_value(t,error,Error.None) {return}
        testing.expect_value(t,Block_Mode(wire[0]),c.mode)
        if c.mode==.Entropy {testing.expect(t,n*100<=len(raw)*98)}
        if c.mode==.LZ {testing.expect(t,n<64)}
    }
}

@(test)
malformed_data_stays_inside_both_buffers_with_reused_scratch :: proc(t:^testing.T) {
    e:Encoder
    d:Decoder
    encoder_init(&e)
    defer encoder_destroy(&e)
    if !testing.expect_value(t,decoder_init(&d),Error.None) {return}
    defer decoder_destroy(&d)

    raw:=make([]u8,4096)
    guarded:=make([]u8,len(raw)+2)
    out:=guarded[1:len(guarded)-1]
    packed:=make([]u8,bound(len(raw)))
    mutated:=make([]u8,len(packed))
    defer {delete(raw);delete(guarded);delete(packed);delete(mutated)}

    guarded[0],guarded[len(guarded)-1]=0xa5,0x5a
    state:=u32(71)
    patterns:=[?]Pattern{.Repeated,.Palette,.Records,.Random}
    for pattern in patterns {
        fill(raw,pattern,19)
        n,err:=encode(&e,.Balanced,raw,packed)
        if !testing.expect_value(t,err,Error.None) {return}
        for cut in 0..<n {
            prefix:=make([]u8,cut)
            copy(prefix,packed[:cut])
            rejected:=decode(&d,MDC2,prefix,out)==.Corrupt
            delete(prefix)
            if !testing.expectf(t,rejected,"%v: cut at %d of %d",pattern,cut,n) {return}
        }
        for sample in 0..<4096 {
            copy(mutated,packed[:n])
            for _ in 0..<4 {
                i:=(int(next_byte(&state))<<8|int(next_byte(&state)))%n
                mutated[i]~=next_byte(&state)|1
            }
            if sample%4==0 {
                for &byte in mutated[:n] {byte=next_byte(&state)}
            }
            decode(&d,MDC2,mutated[:n],out)
        }
        testing.expect_value(t,guarded[0],u8(0xa5))
        testing.expect_value(t,guarded[len(guarded)-1],u8(0x5a))
        testing.expect_value(t,decode(&d,MDC2,packed[:n],out[:len(out)-1]),Error.Corrupt)
        testing.expect_value(t,decode(&d,MDC2,packed[:n],out),Error.None)
        testing.expect_value(t,string(out),string(raw))
    }
}

@(test)
invalid_commands_and_unavailable_scratch_report_errors :: proc(t:^testing.T) {
    e:Encoder
    d:Decoder
    allocator:=runtime.nil_allocator()
    testing.expect_value(t,decoder_init(&d,allocator),Error.Out_Of_Memory)
    encoder_init(&e,allocator)
    defer encoder_destroy(&e)
    raw,dst:[32]u8
    wire:[33]u8
    unsupported_formats:=[?]Format{
        Format(0x3143444d),Format(0x4454535a),Format(0x48345a4c),MLZ1,Format(1),
    }
    for unsupported in unsupported_formats {
        testing.expect_value(t,decode(&d,unsupported,nil,nil),Error.Unknown_Format)
    }
    testing.expect_value(t,decode(&d,MDC2,wire[:1],nil),Error.Corrupt)
    testing.expect_value(t,decode(&d,MDC2,nil,nil),Error.None)
    _,small:=encode(&e,.Fast,raw[:],wire[:32])
    testing.expect_value(t,small,Error.Output_Too_Small)
    _,memory:=encode(&e,.Fast,raw[:],wire[:])
    testing.expect_value(t,memory,Error.Out_Of_Memory)
    _,overlap:=encode(&e,.Fast,wire[:32],wire[:])
    testing.expect_value(t,overlap,Error.Corrupt)
    testing.expect_value(t,decode(&d,MDC2,wire[:],wire[1:]),Error.Corrupt)

    testing.expect_value(t,decoder_init(&d),Error.None)
    defer decoder_destroy(&d)
    cases:=[?][]u8{
        {1,0},
        {1,0x84,0,1,0,0,0},
        {1,4,0,0,0,0},
        {1,4,2,0,0,0},
        {1,4,1,0,255,0},
        {2,1,0,1,1,0,0,0,31,0},
        {2,1,0,1,1,0,0,0,0,255},
    }
    for src in cases {
        testing.expect_value(t,decode(&d,MDC2,src,dst[:]),Error.Corrupt)
    }
}

@(test)
speed_matches_copy_exactly_across_overlap_and_end :: proc(t:^testing.T) {
    wire:[83]u8
    wire[0],wire[1]=u8(Block_Mode.LZ),8
    wire[2],wire[4],wire[5]=20,20,4
    wire[8]=2
    for &b,i in wire[10:] {b=u8(i*11)}
    for distance in 1..=30 {
        for length in SPEED_MIN..=32 {
            wire[6],wire[9]=u8(distance),u8(length-SPEED_MIN)
            expected,out:[113]u8
            copy(expected[:20],wire[10:30])
            copy(expected[20:28],expected[:8])
            copy(expected[28:30],wire[30:32])
            for at in 30..<30+length {expected[at]=expected[at-distance]}
            copy(expected[30+length:],wire[32:])

            for tail in ([3]int{0,19,51}) {
                actual:=out[:30+length+tail]
                result:=decode(nil,MDC2,wire[:32+tail],actual)
                if !testing.expectf(t,result==.None &&
                    string(actual)==string(expected[:len(actual)]),
                    "distance %d length %d tail %d: %v",distance,length,tail,result) {return}
            }
        }
    }
}

@(test)
a_multiblock_frame_requires_exact_extents :: proc(t:^testing.T) {
    e:Encoder
    encoder_init(&e)
    defer encoder_destroy(&e)
    input:=make([]u8,BLOCK_BYTES+1)
    wire:=make([]u8,bound(len(input)))
    out:=make([]u8,len(input))
    defer {delete(input);delete(wire);delete(out)}
    n,err:=encode(&e,.Speed,input,wire)
    if !testing.expect_value(t,err,Error.None) {return}
    testing.expect_value(t,decode(nil,MDC2,wire[:n],out),Error.None)
    testing.expect_value(t,decode(nil,MDC2,wire[:n-1],out),Error.Corrupt)
    testing.expect_value(t,decode(nil,MDC2,wire[:n+1],out),Error.Corrupt)
    wire[0],wire[1],wire[2]=0,0,0
    testing.expect_value(t,decode(nil,MDC2,wire[:n],out),Error.Corrupt)
    wire[0],wire[1],wire[2]=0xff,0xff,0xff
    testing.expect_value(t,decode(nil,MDC2,wire[:n],out),Error.Corrupt)
}

@(test)
entropy_uses_three_repeat_slots_and_decodes_without_an_allocator :: proc(t:^testing.T) {
    e:Encoder
    d:Decoder
    encoder_init(&e)
    defer encoder_destroy(&e)
    if !testing.expect_value(t,decoder_init(&d),Error.None) {return}
    defer decoder_destroy(&d)

    raw,out:[320]u8
    for &byte in raw {byte=41}
    wire:[len(raw)+1]u8
    if _,err:=encode(&e,.Balanced,raw[:],wire[:]);err!=.None {
        testing.expect_value(t,err,Error.None)
        return
    }
    choices:=[?]Sequence{{32,3,11},{1,7,1},{2,8,4},{0,14,4},{6,238,11}}
    copy(e.mdc.sequences[:],choices[:])
    e.mdc.sequence_count=len(choices)
    streams:=build_symbols(e.mdc,raw[:],0)
    slots:=[?]u8{6,1,2,0,2}
    testing.expect_value(t,string(e.mdc.offsets[:len(choices)]),string(slots[:]))
    size:=write_entropy(e.mdc,&streams,wire[:],raw[:],0,.Fast)
    if !testing.expect(t,size>0) {return}

    allocator:=context.allocator
    tracking:mem.Tracking_Allocator
    mem.tracking_allocator_init(&tracking,allocator)
    defer mem.tracking_allocator_destroy(&tracking)
    context.allocator=mem.tracking_allocator(&tracking)
    result:=decode(&d,MDC2,wire[:size],out[:])
    context.allocator=allocator
    testing.expect_value(t,tracking.total_allocation_count,i64(0))
    testing.expect_value(t,result,Error.None)
    testing.expect_value(t,string(out[:]),string(raw[:]))
}

@(test)
delta_literals_use_the_previous_distance :: proc(t:^testing.T) {
    e:Encoder
    d:Decoder
    encoder_init(&e)
    defer encoder_destroy(&e)
    if !testing.expect_value(t,decoder_init(&d),Error.None) {return}
    defer decoder_destroy(&d)

    raw,out:[1024]u8
    wire:[len(raw)+1]u8
    if _,err:=encode(&e,.Balanced,raw[:],wire[:]);err!=.None {
        testing.expect_value(t,err,Error.None)
        return
    }
    sequences:=[?]Sequence{{151,41,16},{61,16,8},{61,24,16},{61,40,16}}
    pos,rep:=0,int(INITIAL_OFFSETS[0])
    for sequence in sequences {
        for _ in 0..<sequence.literals {
            raw[pos]=1
            if pos>=rep {raw[pos]+=raw[pos-rep]}
            pos+=1
        }
        rep=int(sequence.distance)
        for _ in 0..<sequence.length {
            raw[pos]=raw[pos-rep]
            pos+=1
        }
    }
    for i in pos..<len(raw) {raw[i]=1+raw[i-rep]}
    copy(e.mdc.sequences[:],sequences[:])
    e.mdc.sequence_count=len(sequences)
    streams:=build_symbols(e.mdc,raw[:],0)
    size:=write_entropy(e.mdc,&streams,wire[:],raw[:],0,.Balanced)
    if !testing.expect(t,size>0) {return}
    testing.expect_value(t,Block_Mode(wire[0]),Block_Mode.Delta)
    testing.expect_value(t,decode(&d,MDC2,wire[:size],out[:]),Error.None)
    testing.expect_value(t,string(out[:]),string(raw[:]))
    for cut in 0..<size {
        testing.expect_value(t,decode(&d,MDC2,wire[:cut],out[:]),Error.Corrupt)
    }
}

@(test)
entropy_can_match_beyond_two_mebibytes :: proc(t:^testing.T) {
    e:Encoder
    d:Decoder
    encoder_init(&e)
    defer encoder_destroy(&e)
    if !testing.expect_value(t,decoder_init(&d),Error.None) {return}
    defer decoder_destroy(&d)

    blocks:=9
    first:=blocks*BLOCK_BYTES
    raw:=make([]u8,first+4096)
    out:=make([]u8,len(raw))
    wire:=make([]u8,bound(len(raw)))
    defer {delete(raw);delete(out);delete(wire)}
    fill(raw[:first],.Random,19)
    copy(raw[first:],raw[64:][:4096])

    for profile in ([]Profile{.Balanced,.Ultra}) {
        size,err:=encode(&e,profile,raw,wire)
        if !testing.expect_value(t,err,Error.None) {return}
        at:=0
        for _ in 0..<blocks {
            extent:=int(wire[at])|int(wire[at+1])<<8|int(wire[at+2])<<16
            at+=3+extent
        }
        mode:=Block_Mode(wire[at])
        testing.expect(t,mode==.Entropy || mode==.Delta)
        testing.expect(t,size-at<len(raw)-first)
        testing.expect_value(t,decode(&d,MDC2,wire[:size],out),Error.None)
        testing.expect_value(t,string(out),string(raw))
        testing.expect_value(t,decode(&d,MDC2,wire[at:size],out[first:]),Error.Corrupt)
    }
}
