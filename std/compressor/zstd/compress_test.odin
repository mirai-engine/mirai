package zstd

import "core:testing"

@(private="file")
noise :: proc(bytes:[]u8) {
    state:=u32(0x9E3779B9)
    for &b in bytes {
        state~=state<<13
        state~=state>>17
        state~=state<<5
        b=u8(state)
    }
}

// Runs of a small alphabet with repeats at many distances: every strategy finds work in it.
@(private="file")
structured :: proc(bytes:[]u8) {
    state:=u32(0x12345)
    i:=0
    for i<len(bytes) {
        state~=state<<13
        state~=state>>17
        state~=state<<5
        run:=min(int(state%37)+1,len(bytes)-i)
        distance:=int(state>>8)%max(i,1)
        for j in 0..<run {
            bytes[i+j]=i>64 && state&3!=0 ? bytes[i-distance-1+j] : u8('a'+(state>>uint(j%24))%16)
        }
        i+=run
    }
}

@(rodata,private="file")
LEVELS:=[?]int{3,6,22}

@(private="file") GUARD :: 64

@(test)
frames_decode_to_their_source_and_the_encoder_is_deterministic :: proc(t:^testing.T) {
    random:=make([]u8,1<<17,context.temp_allocator)
    noise(random)
    text:=make([]u8,600*KB,context.temp_allocator)
    structured(text)
    zeros:=make([]u8,300*KB,context.temp_allocator)
    inputs:=[?][]u8{{},{42},text[:100],text[:5000],random,zeros,text}

    dctx,err:=dctx_create()
    if !testing.expect(t,err==.None) {return}
    defer dctx_destroy(dctx)

    for input,index in inputs {
        for level in LEVELS {
            frame:=make([]u8,compress_bound(len(input)),context.temp_allocator)
            size,e:=compress(raw_data(frame),len(frame),raw_data(input),len(input),level)
            if !testing.expectf(t,e==.None,"input %d level %d: %v",index,level,e) {continue}

            again:=make([]u8,len(frame),context.temp_allocator)
            size_again,_:=compress(raw_data(again),len(again),raw_data(input),len(input),level)
            testing.expectf(t,size==size_again && string(frame[:size])==string(again[:size]),"input %d level %d changes between runs",index,level)

            output:=make([]u8,max(len(input),1)+2*GUARD,context.temp_allocator)
            for &b in output {b=0xA5}
            written,de:=decompress_dctx(dctx,raw_data(output)[GUARD:],len(output)-2*GUARD,raw_data(frame),size)
            testing.expectf(t,de==.None && written==len(input),"input %d level %d: %v wrote %d",index,level,de,written)
            testing.expect(t,string(output[GUARD:][:written])==string(input))
            for k in 0..<GUARD {testing.expect(t,output[k]==0xA5 && output[len(output)-1-k]==0xA5)}
        }
    }
}

@(test)
what_it_cannot_write_is_an_error_and_nothing_goes_past_the_buffer :: proc(t:^testing.T) {
    input:=make([]u8,70*KB,context.temp_allocator)
    structured(input)

    for level in LEVELS {
        for capacity:=0;capacity<40000;capacity+=999 {
            frame:=make([]u8,capacity+2*GUARD,context.temp_allocator)
            for &b in frame {b=0x5A}
            size,e:=compress(raw_data(frame)[GUARD:],capacity,raw_data(input),len(input),level)
            testing.expect(t,e==.Dst_Size_Too_Small || (e==.None && size<=capacity))
            for k in 0..<GUARD {testing.expect(t,frame[k]==0x5A && frame[len(frame)-1-k]==0x5A)}
        }
    }

    out:[64]u8
    for level in ([?]int{-1,0,1,5,23}) {
        _,e:=compress(&out[0],len(out),raw_data(input),len(input),level)
        testing.expect_value(t,e,Error.Parameter_Unsupported)
    }
    _,e:=compress(&out[0],len(out),raw_data(input),-1,3)
    testing.expect_value(t,e,Error.Src_Size_Wrong)
}
