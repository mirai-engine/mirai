package tracy

import "base:intrinsics"
import "core:mem"
import "core:testing"

@(private="file")
fuzz_next :: proc(state:^u64) -> u64 {
    state^~=state^>>12
    state^~=state^<<25
    state^~=state^>>27
    return state^*0x2545f4914f6cdd1d
}

@(private="file")
test_lz4_decompress :: proc(src:[]u8,dst:[]u8) -> (size:int,ok:bool) {
    in_,out:=raw_data(src),raw_data(dst)
    in_size,out_size:=len(src),len(dst)
    ip,op:=0,0
    for {
        if ip>=in_size {return op,false}
        token:=in_[ip]
        ip+=1
        literals:=int(token>>4)
        if literals==15 {
            for {
                if ip>=in_size {return op,false}
                extra:=in_[ip]
                ip+=1
                literals+=int(extra)
                if literals>out_size {return op,false}
                if extra!=255 {break}
            }
        }
        if literals>in_size-ip || literals>out_size-op {return op,false}
        if literals>0 {intrinsics.mem_copy_non_overlapping(&out[op],&in_[ip],literals)}
        ip+=literals
        op+=literals
        if ip==in_size {return op,true}
        if in_size-ip<2 {return op,false}
        offset:=int(in_[ip])|int(in_[ip+1])<<8
        ip+=2
        if offset==0 || offset>op {return op,false}
        match:=int(token&15)
        if match==15 {
            for {
                if ip>=in_size {return op,false}
                extra:=in_[ip]
                ip+=1
                match+=int(extra)
                if match>out_size {return op,false}
                if extra!=255 {break}
            }
        }
        match+=4
        if match>out_size-op {return op,false}
        from:=op-offset
        for i in 0..<match {out[op+i]=out[from+i]}
        op+=match
    }
}

@(private="file")
round_trip :: proc(t:^testing.T,input:[]u8,loc:=#caller_location) -> int {
    packed:=make([]u8,lz4_bound(len(input)));defer delete(packed)
    size,ok:=lz4_compress(input,packed)
    testing.expect(t,ok,"compression fits its bound",loc=loc)
    // Canaries on both sides catch a decoder that writes outside its output.
    guarded:=make([]u8,len(input)+64);defer delete(guarded)
    for &b in guarded {b=0xa5}
    out:=guarded[32:][:len(input)]
    count,decoded:=test_lz4_decompress(packed[:size],out)
    testing.expect(t,decoded && count==len(input),"decompression returns the input size",loc=loc)
    testing.expect(t,mem.compare(out,input)==0,"decompression returns the input",loc=loc)
    for b in guarded[:32] {testing.expect(t,b==0xa5,"nothing written before the output",loc=loc)}
    for b in guarded[32+len(input):] {testing.expect(t,b==0xa5,"nothing written after the output",loc=loc)}
    testing.expect(t,end_rules_hold(packed[:size]),"the block keeps the end rules of the reference decoder",loc=loc)
    return size
}

// The rules a lenient decoder ignores and the reference one (Tracy's server
// among its users) enforces: the block ends with literals only, the last five
// bytes are literals and no match starts within the last twelve.
@(private="file")
end_rules_hold :: proc(block:[]u8) -> bool {
    length :: proc(block:[]u8,ip:^int,nibble:int) -> int {
        total:=nibble
        if nibble==15 {
            for ip^<len(block) {
                extra:=block[ip^];ip^+=1;total+=int(extra)
                if extra!=255 {break}
            }
        }
        return total
    }
    ip,op:=0,0
    last_start,last_end:=-1,-1
    for ip<len(block) {
        token:=block[ip];ip+=1
        literals:=length(block,&ip,int(token>>4))
        ip+=literals;op+=literals
        if ip>=len(block) {
            if token&0xf!=0 {return false}
            break
        }
        ip+=2
        match:=length(block,&ip,int(token&0xf))+4
        last_start=op;op+=match;last_end=op
    }
    return last_start<0 || (last_start<=op-12 && last_end<=op-5)
}

@(private="file")
sample_text :: proc(size:int,seed:u64,allocator:=context.allocator) -> []u8 {
    words:=[?]string{"position","rotation","scale","entity","mesh","material","0.25","1.0","{","}","\n","  ",":",","}
    out:=make([dynamic]u8,0,size,allocator)
    state:=seed
    for len(out)<size {append(&out,words[fuzz_next(&state)%len(words)])}
    resize(&out,size)
    return out[:]
}

@(test)
lz4_round_trips_inputs_of_every_shape :: proc(t:^testing.T) {
    round_trip(t,nil)
    state:=u64(0x1234)
    for size in 1..=80 {
        input:=make([]u8,size);defer delete(input)
        for &b in input {b=u8(fuzz_next(&state)%3)}
        round_trip(t,input)
    }
    zeros:=make([]u8,100000);defer delete(zeros)
    testing.expect(t,round_trip(t,zeros)<500)

    noise:=make([]u8,70000);defer delete(noise)
    for &b in noise {b=u8(fuzz_next(&state))}
    testing.expect(t,round_trip(t,noise)<=lz4_bound(len(noise)))

    text:=sample_text(200000,7);defer delete(text)
    testing.expect(t,round_trip(t,text)<len(text)/2)

    // Matches at every distance up to past the 64 KB window, short and overlapping.
    distances:=[?]int{1,2,3,4,7,8,15,16,17,31,255,256,4095,65535,65536,70000}
    for distance in distances {
        input:=make([]u8,distance*2+300);defer delete(input)
        for &b,i in input {b=i<distance?u8(fuzz_next(&state)):input[i-distance]}
        round_trip(t,input)
    }
    // Literal and match lengths around the 15 and 255 extension steps.
    for run in ([]int{14,15,16,18,19,20,254,255,256,269,270,271,272,273,274,524,525,526,527,528,529,530}) {
        input:=make([]u8,run*2+64);defer delete(input)
        for &b,i in input {b=i<run?u8(fuzz_next(&state)):(i<run*2?7:u8(fuzz_next(&state)))}
        round_trip(t,input)
    }
}

@(test)
lz4_compression_fails_cleanly_when_the_output_is_too_small :: proc(t:^testing.T) {
    text:=sample_text(5000,3);defer delete(text)
    packed:=make([]u8,lz4_bound(len(text)));defer delete(packed)
    full,ok:=lz4_compress(text,packed)
    testing.expect(t,ok)
    for capacity in ([]int{0,1,16,full/2,full-1}) {
        guarded:=make([]u8,capacity+16);defer delete(guarded)
        for &b in guarded {b=0x5a}
        _,fits:=lz4_compress(text,guarded[:capacity])
        testing.expect(t,!fits)
        for b in guarded[capacity:] {testing.expect(t,b==0x5a)}
    }
    exact:=make([]u8,full);defer delete(exact)
    size,exact_ok:=lz4_compress(text,exact)
    testing.expect(t,exact_ok && size==full)
}
