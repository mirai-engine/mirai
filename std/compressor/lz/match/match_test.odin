package match

import "core:testing"
import "core:math/rand"
import "base:intrinsics"
import "base:runtime"
import "mirai:std/compressor/lz/entropy"

@(private="file")
make_input :: proc(size,pattern:int,gen:runtime.Random_Generator) -> []u8 {
    d:=make([]u8,size)
    for i in 0..<size {
        switch pattern {
        case 0: d[i]=0
        case 1: d[i]=u8(rand.uint32(gen))
        case 2: d[i]=u8(i%3)
        case 3: d[i]=i<size/2?u8(rand.uint32(gen)&7):d[i-size/2]
        }
    }
    return d
}

@(private="file")
ctmf_parse :: proc(t:^testing.T,c:^$C,data:[]u8,arena:^entropy.Arena) -> int {
    testing.expect(t,allocate(c,16,16,16,arena,0))
    defer release(c,arena)
    base:=raw_data(data)
    half:=len(data)/2
    set_base_and_preload(c,base,padd(base,half),half)
    end:=len(data)-8
    found:=0
    when intrinsics.type_is_specialization_of(C,Ctmf) {
        ctmf_set_next(c,padd(base,half))
        for pos:=half;pos<end; {
            ptr:=padd(base,pos)
            row,row2,hash:=c.next_row,c.next_row_second,c.next_hash
            ctmf_set_next(c,padd(ptr,1))
            cand:[32]u32
            mask:=ctmf_find_candidates(c,raw_data(cand[:]),row,row2,u32(pos),hash)
            ctmf_insert(c,row,u32(pos),hash)
            best,best_off:=0,0
            for d in 0..<32 {
                if mask&(1<<uint(d))==0 {continue}
                off:=int(cand[d])
                if off==0 || off>pos {continue}
                l:=getmatchlen_mml4(ptr,padd(ptr,-off),padd(base,len(data)))
                if l>best {best,best_off=l,off}
            }
            if best>=4 && pos+best<end {
                found+=1
                for i in 0..<best {testing.expect(t,data[pos+i]==data[pos+i-best_off])}
                ctmf_step_and_insert(c,ptr,best)
                pos+=best
            } else {
                pos+=1
            }
        }
    } else {
        for pos:=half;pos<end;pos+=1 {
            ptr:=padd(base,pos)
            prev:=int(fast_ctmf_insert(raw_data(c.hash_table),ptr,c.hash_mul,c.hash_shift,pos))
            off:=pos-prev
            if prev!=0 && off>0 && getmatchlen_mml4(ptr,padd(ptr,-off),padd(base,
                len(data)))>=4 {found+=1}
        }
    }
    return found
}


@(test)
ctmf_tables_find_real_matches :: proc(t:^testing.T) {
    r:=rand.create(3)
    gen:=runtime.default_random_generator(&r)
    data:=make_input(1<<16,3,gen)
    defer delete(data)
    arena:=entropy.arena_make(context.allocator)
    {c:Ctmf(u32,2,8,4);testing.expect(t,ctmf_parse(t,&c,data,&arena)>0)}
    {c:Ctmf(u32,1,0,4);testing.expect(t,ctmf_parse(t,&c,data,&arena)>0)}
    {c:Ctmf(u32,3,0,4);testing.expect(t,ctmf_parse(t,&c,data,&arena)>0)}
    {c:Ctmf(u32,4,8,4);testing.expect(t,ctmf_parse(t,&c,data,&arena)>0)}
    {c:Ctmf(u32,0,0,4);testing.expect(t,ctmf_parse(t,&c,data,&arena)>0)}
    {c:Ctmf(u16,1,0,4);testing.expect(t,ctmf_parse(t,&c,data,&arena)>=0)}
    {c:Ctmf(u16,0,0,4);testing.expect(t,ctmf_parse(t,&c,data,&arena)>=0)}
    {c:Fast_Ctmf(u32);testing.expect(t,ctmf_parse(t,&c,data,&arena)>0)}
    {c:Fast_Ctmf(u16);testing.expect(t,ctmf_parse(t,&c,data,&arena)>0)}
}

// Matches of the second half against an LRM set over the first: found, real and in range.
@(test)
stdsort_sorts_with_ties :: proc(t:^testing.T) {
    r:=rand.create(5)
    gen:=runtime.default_random_generator(&r)
    Entry :: struct {hash,pos32:u32}
    less :: proc "contextless" (a,b:Entry) -> bool {return a.hash<b.hash}
    for n in ([?]int{0,1,2,3,4,5,6,7,100,1000,20000}) {
        for range in ([?]u32{1,3,1<<30}) {
            a:=make([]Entry,n)
            defer delete(a)
            sum:=0
            for i in 0..<n {a[i]=Entry{rand.uint32(gen)%range,u32(i)};sum+=i}
            entropy.stdsort(a,less)
            got:=0
            for i in 0..<n {
                got+=int(a[i].pos32)
                if i>0 {testing.expect(t,a[i-1].hash<=a[i].hash)}
            }
            testing.expect_value(t,got,sum)
        }
    }
}
