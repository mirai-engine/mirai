package lz4

import "base:runtime"
import "core:mem"
import "core:testing"

@(private="file") GUARD :: 64
@(private="file") GUARD_BYTE :: u8(0xA5)

@(private="file")
next :: proc(state:^u64) -> u64 {
    state^~=state^<<13
    state^~=state^>>7
    state^~=state^<<17
    return state^
}

@(private="file")
structured :: proc(size:int,seed:u64) -> []u8 {
    state:=seed|1
    data:=make([]u8,size)
    at_:=0
    for at_<size {
        switch next(&state)%4 {
        case 0:
            run:=min(int(1+next(&state)%24),size-at_)
            for i in 0..<run {data[at_+i]=u8(next(&state))}
            at_+=run
        case 1:
            run:=min(int(4+next(&state)%300),size-at_)
            value:=u8(next(&state))
            for i in 0..<run {data[at_+i]=value}
            at_+=run
        case 2,3:
            if at_<4 {
                data[at_]=u8(next(&state))
                at_+=1
                continue
            }
            distance:=int(1+next(&state)%u64(at_))
            run:=min(int(4+next(&state)%200),size-at_)
            for i in 0..<run {data[at_+i]=data[at_+i-distance]}
            at_+=run
        }
    }
    return data
}

@(private="file")
guarded_decode :: proc(t:^testing.T,stream:[]u8,capacity:int,buffer:[]u8) -> (written:int,ok:bool) {
    for i in 0..<GUARD*2+capacity {buffer[i]=GUARD_BYTE}
    written,ok=decompress_safe(stream,buffer[GUARD:][:capacity])
    for i in 0..<GUARD {
        if buffer[i]!=GUARD_BYTE || buffer[GUARD+capacity+i]!=GUARD_BYTE {
            testing.expect(t,false,"decode wrote outside its buffer")
            return 0,false
        }
    }
    if ok && !testing.expect(t,written>=0 && written<=capacity,"decode reported more than its buffer") {return 0,false}
    return
}

@(test)
round_trip_at_each_level :: proc(t:^testing.T) {
    inputs:=[][]u8{{},{42},make([]u8,20000),structured(40000,1),structured(70000,2)}
    defer {delete(inputs[2]);delete(inputs[3]);delete(inputs[4])}
    for input in inputs {
        bound:=compress_bound(len(input))
        compressed:=make([]u8,bound)
        defer delete(compressed)
        decoded:=make([]u8,len(input)+1)
        defer delete(decoded)
        for level in 3..=HC_CLEVEL_MAX {
            written,ok:=compress_hc(input,compressed,level)
            if !testing.expect(t,ok && written>0 && written<=bound) {return}
            size,valid:=decompress_safe(compressed[:written],decoded[:len(input)])
            if !testing.expect(t,valid && size==len(input)) {return}
            testing.expect(t,string(decoded[:len(input)])==string(input))
        }
    }
}

@(test)
rejects_levels_and_sizes :: proc(t:^testing.T) {
    src,dst:[32]u8
    for level in ([]int{-1,0,1,2,13}) {
        _,ok:=compress_hc(src[:],dst[:],level)
        testing.expect(t,!ok)
    }
    testing.expect(t,compress_bound(-1)==0)
    testing.expect(t,compress_bound(MAX_INPUT_SIZE+1)==0)
    testing.expect(t,compress_bound(255)==255+1+16)
}

@(test)
fails_when_dst_is_short :: proc(t:^testing.T) {
    input:=structured(5000,3)
    defer delete(input)
    compressed:=make([]u8,compress_bound(len(input)))
    defer delete(compressed)
    for level in ([]int{3,9,12}) {
        written,ok:=compress_hc(input,compressed,level)
        if !testing.expect(t,ok) {return}
        for capacity in max(0,written-8)..=written-1 {
            size,fits:=compress_hc(input,compressed[:capacity],level)
            testing.expect(t,!fits && size==0)
        }
        size,fits:=compress_hc(input,compressed[:written],level)
        testing.expect(t,fits && size==written)
    }
}

@(test)
truncation_stays_in_bounds :: proc(t:^testing.T) {
    input:=structured(600,4)
    defer delete(input)
    compressed:=make([]u8,compress_bound(len(input)))
    defer delete(compressed)
    buffer:=make([]u8,GUARD*2+len(input))
    defer delete(buffer)
    for level in ([]int{3,9,12}) {
        written,ok:=compress_hc(input,compressed,level)
        if !testing.expect(t,ok) {return}
        for cut in 0..<written {
            decoded,valid:=guarded_decode(t,compressed[:cut],len(input),buffer)
            if valid {testing.expect(t,string(buffer[GUARD:][:decoded])==string(input[:decoded]))}
        }
    }
}

@(test)
mutation_stays_in_bounds :: proc(t:^testing.T) {
    input:=structured(3000,5)
    defer delete(input)
    frame:=make([]u8,compress_bound(len(input)))
    defer delete(frame)
    written,ok:=compress_hc(input,frame,9)
    if !testing.expect(t,ok) {return}
    mutant:=make([]u8,written)
    defer delete(mutant)
    buffer:=make([]u8,GUARD*2+len(input)+64)
    defer delete(buffer)
    state:=u64(0x9E3779B97F4A7C15)
    for _ in 0..<4000 {
        copy(mutant,frame[:written])
        for _ in 0..<1+next(&state)%6 {
            at_:=int(next(&state)%u64(written))
            switch next(&state)%3 {
            case 0: mutant[at_]=u8(next(&state))
            case 1: mutant[at_]=0xFF
            case 2: mutant[at_]=0
            }
        }
        capacity:=len(input)
        switch next(&state)%3 {
        case 1: capacity=len(input)+int(next(&state)%64)
        case 2: capacity=int(next(&state)%u64(len(input)+1))
        }
        guarded_decode(t,mutant,capacity,buffer)
    }
}

@(test)
fails_without_memory :: proc(t:^testing.T) {
    input:=structured(2000,6)
    defer delete(input)
    compressed:=make([]u8,compress_bound(len(input)))
    defer delete(compressed)
    {
        _,ok:=compress_hc(input,compressed,9,runtime.nil_allocator())
        testing.expect(t,!ok)
    }
    // Room for the state of the encoder, not for what the highest levels add to it.
    backing:=make([]u8,size_of(Hc_Ctx)+256)
    defer delete(backing)
    arena:mem.Arena
    mem.arena_init(&arena,backing)
    _,ok:=compress_hc(input,compressed,12,mem.arena_allocator(&arena))
    testing.expect(t,!ok)
    free_all(mem.arena_allocator(&arena))
    written,fits:=compress_hc(input,compressed,9,mem.arena_allocator(&arena))
    testing.expect(t,fits && written>0)
}

@(test)
hand_made_blocks :: proc(t:^testing.T) {
    out:[32]u8
    {
        written,ok:=decompress_safe({0},nil)
        testing.expect(t,ok && written==0)
    }
    {
        _,ok:=decompress_safe(nil,out[:])
        testing.expect(t,!ok)
    }
    {
        // A match that starts before the output.
        _,ok:=decompress_safe({0x10,'a',0x02,0x00,0x00},out[:])
        testing.expect(t,!ok)
    }
    {
        // A literal run longer than the input.
        _,ok:=decompress_safe({0xF0,0xFF,0x00},out[:])
        testing.expect(t,!ok)
    }
    {
        block:=[]u8{0x50,'h','e','l','l','o'}
        written,ok:=decompress_safe(block,out[:])
        testing.expect(t,ok && written==5 && string(out[:5])=="hello")
    }
}
