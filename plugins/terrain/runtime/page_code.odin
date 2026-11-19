package terrain

import "base:intrinsics"
import "base:runtime"
import "core:math"
import "core:mem"
import "mirai:std/base"

// The values of a page as its block holds them: one coding for the file, the blocks of
// pages that leave memory and the pages the network sends. A value goes as how far it is
// from the plane through the neighbors before it along each axis, and those distances
// through an adaptive binary range coder that works in whole numbers alone: the same
// values code into the same bytes on every machine, and a page decodes without another.

// The step of the heights a .terrain stores, in meters: each is saved as the
// nearest multiple, at most half a step away. A power of two, so a height read
// from a file is saved again as it is and edits do not drift.
HEIGHT_STEP :: 1.0/1024

// The first byte of a coded page.
@(private)
Page_Code :: enum u8 {
    Values,  // the values as they are: what the others would not make smaller
    Bytes,   // each byte of a value from the plane of the same byte of its neighbors
    Lattice, // f32 on multiples of HEIGHT_STEP: each in steps from the plane of its neighbors
    Exact,   // f32 of any bits: as Lattice of the multiple nearest each, and how far it is from it
}

// The code, the bytes of a value, the values of a row and the rows of a slice, before the
// coded values.
@(private) PAGE_HEADER :: 4
// The most bytes a coded page takes: those of a page of Values.
PAGE_BYTES_MAX :: PAGE_HEADER+PAGE_VALUES*4

// Where a height lands on the lattice of HEIGHT_STEP.
@(private)
lattice_step :: #force_inline proc "contextless" (value:f32) -> i32 {return i32(math.round(f64(value)*(1/HEIGHT_STEP)))}

@(private)
lattice_value :: #force_inline proc "contextless" (step:i32) -> f32 {return f32(step)*HEIGHT_STEP}

// The height a file holds for value: the nearest multiple of HEIGHT_STEP.
height_quantize :: proc "contextless" (value:f32) -> f32 {return lattice_value(lattice_step(value))}

// Whether every value has a step on the lattice, and whether each is, bit for bit, the
// multiple of HEIGHT_STEP it lands on.
@(private)
page_lattice :: proc "contextless" (values:[]f32) -> (within,on:bool) {
    on=true
    for value in values {
        if !(abs(value)<1<<20) {return false,false}
        on&&=transmute(u32)lattice_value(lattice_step(value))==transmute(u32)value
    }
    return true,on
}

// The chance of a 0, of PROB_ONE, that a bit of the coder learns: each bit moves it a
// part of the way toward what it was.
@(private="file") PROB_BITS :: 12
@(private="file") PROB_ONE :: 1<<PROB_BITS
@(private="file") PROB_RATE :: 4
@(private="file") RANGE_LOW :: 1<<24
// The bytes a reader takes before its first bit, and the most a writer leaves unwritten
// at the end, where they are 0.
@(private="file") CODE_BYTES :: 4

@(private="file")
probs_reset :: proc "contextless" (model:^$M) {
    for &p in ([^]u16)(model)[:size_of(M)/size_of(u16)] {p=PROB_ONE/2}
}

// Bits into bytes: at counts past the end of bytes what does not fit.
@(private="file")
Bits_Out :: struct {
    bytes:[]u8,
    at:int,
    low:u64,
    range:u32,
    cache:u8, // the byte before low, which a carry may still raise
    held:int, // the bytes not written yet: cache and the 0xff after it
}

// The byte before the first is always 0 and is not written.
@(private="file")
out_init :: proc "contextless" (w:^Bits_Out,bytes:[]u8) {w^={bytes=bytes,at=-1,range=max(u32),held=1}}

@(private="file")
out_shift :: proc "contextless" (w:^Bits_Out) #no_bounds_check {
    if u32(w.low)<0xff000000 || w.low>>32!=0 {
        carry,b:=u8(w.low>>32),w.cache
        for ;w.held>0;w.held-=1 {
            if w.at>=0 && w.at<len(w.bytes) {w.bytes[w.at]=b+carry}
            w.at+=1
            b=0xff
        }
        w.cache=u8(w.low>>24)
    }
    w.held+=1
    w.low=(w.low&0x00ffffff)<<8
}

@(private="file")
out_bit :: #force_inline proc "contextless" (w:^Bits_Out,p:^u16,bit:bool) {
    bound:=(w.range>>PROB_BITS)*u32(p^)
    if bit {
        w.low+=u64(bound)
        w.range-=bound
        p^-=p^>>PROB_RATE
    } else {
        w.range=bound
        p^+=(PROB_ONE-p^)>>PROB_RATE
    }
    for w.range<RANGE_LOW {
        w.range<<=8
        out_shift(w)
    }
}

// The low count bits of value, each as likely 0 as 1, in groups of RAW_BITS at most.
@(private="file") RAW_BITS :: 16

@(private="file")
out_raw :: proc "contextless" (w:^Bits_Out,value:u32,count:int) {
    for left:=count;left>0; {
        bits:=min(left,RAW_BITS)
        left-=bits
        w.range>>=uint(bits)
        w.low+=u64(value>>uint(left)&(1<<uint(bits)-1))*u64(w.range)
        for w.range<RANGE_LOW {
            w.range<<=8
            out_shift(w)
        }
    }
}

// count bits of value, the highest first, each learned by the bits before it.
@(private="file")
out_tree :: proc "contextless" (w:^Bits_Out,probs:[^]u16,value:u32,count:int) #no_bounds_check {
    node:=u32(1)
    for i:=count-1;i>=0;i-=1 {
        bit:=value>>uint(i)&1
        out_bit(w,&probs[node],bit!=0)
        node=node<<1|bit
    }
}

// Ends the bytes: how many they are, and whether they fit. What is left of the range
// lets the last bytes be 0, and those, CODE_BYTES at most, are not written.
@(private="file")
out_end :: proc "contextless" (w:^Bits_Out) -> (size:int,fits:bool) #no_bounds_check {
    top:=w.low+u64(w.range)-1
    for shift:=uint(32);;shift-=1 {
        if value:=top>>shift<<shift;value>=w.low {
            w.low=value
            break
        }
    }
    for _ in 0..=CODE_BYTES {out_shift(w)}
    if w.at>len(w.bytes) {return 0,false}
    size=w.at
    for size>w.at-CODE_BYTES && size>0 && w.bytes[size-1]==0 {size-=1}
    return size,true
}

// Bits out of bytes, which read as 0 past their end: at tells how many it took.
@(private="file")
Bits_In :: struct {bytes:[]u8,at:int,range:u32,code:u32}

@(private="file")
in_byte :: #force_inline proc "contextless" (r:^Bits_In) #no_bounds_check {
    b:u32
    if r.at<len(r.bytes) {b=u32(r.bytes[r.at])}
    r.at+=1
    r.code=r.code<<8|b
}

@(private="file")
in_init :: proc "contextless" (r:^Bits_In,bytes:[]u8) {
    r^={bytes=bytes,range=max(u32)}
    for _ in 0..<CODE_BYTES {in_byte(r)}
}

@(private="file")
in_bit :: #force_inline proc "contextless" (r:^Bits_In,p:^u16) -> bool {
    bound:=(r.range>>PROB_BITS)*u32(p^)
    bit:=r.code>=bound
    if bit {
        r.code-=bound
        r.range-=bound
        p^-=p^>>PROB_RATE
    } else {
        r.range=bound
        p^+=(PROB_ONE-p^)>>PROB_RATE
    }
    for r.range<RANGE_LOW {
        r.range<<=8
        in_byte(r)
    }
    return bit
}

@(private="file")
in_raw :: proc "contextless" (r:^Bits_In,count:int) -> (value:u32) {
    for left:=count;left>0; {
        bits:=min(left,RAW_BITS)
        left-=bits
        r.range>>=uint(bits)
        // What no writer makes, past the bits, reads as the most they hold.
        part:=min(r.code/r.range,1<<uint(bits)-1)
        r.code-=part*r.range
        value=value<<uint(bits)|part
        for r.range<RANGE_LOW {
            r.range<<=8
            in_byte(r)
        }
    }
    return
}

@(private="file")
in_tree :: proc "contextless" (r:^Bits_In,probs:[^]u16,count:int) -> u32 #no_bounds_check {
    node:=u32(1)
    for _ in 0..<count {node=node<<1|u32(in_bit(r,&probs[node]))}
    return node-(1<<uint(count))
}

// What the neighbors of the value at say it is: the plane through the ones before it along
// each axis that the page has (x, y, z), dx, dy and dz values before it. One outside the
// page is 0.
@(private="file")
plane :: #force_inline proc "contextless" (values:[^]$E,at,dx,dy,dz:int,x,y,z:bool) -> (p:E) #no_bounds_check {
    if x {p+=values[at-dx]}
    if y {
        p+=values[at-dy]
        if x {p-=values[at-dy-dx]}
    }
    if z {
        p+=values[at-dz]
        if x {p-=values[at-dz-dx]}
        if y {
            p-=values[at-dz-dy]
            if x {p+=values[at-dz-dy-dx]}
        }
    }
    return
}

// A distance as a count that grows with it, either way.
@(private="file")
fold :: #force_inline proc "contextless" (d:u32) -> u32 {return (d<<1)~u32(i32(d)>>31)}

@(private="file")
unfold :: #force_inline proc "contextless" (f:u32) -> u32 {return (f>>1)~(0-(f&1))}

@(private="file")
bit_length :: #force_inline proc "contextless" (v:u32) -> int {return 32-int(intrinsics.count_leading_zeros(v))}

// The bits of an f32 as a number that grows with its value, and back.
@(private="file")
ordered :: #force_inline proc "contextless" (bits:u32) -> u32 {return bits~(u32(i32(bits)>>31)&0x7fffffff)}

// How far the bits of a value are from those of the multiple of HEIGHT_STEP at step.
@(private="file")
away :: #force_inline proc "contextless" (bits:u32,step:u32) -> u32 {return ordered(bits)-ordered(transmute(u32)lattice_value(i32(step)))}

@(private="file") LENGTHS :: 33 // of a distance in bits, 0 to 32

// What the distances in steps of a page taught: the length of each by the one its
// neighbors had, and the two bits under its first by its length.
@(private="file")
Steps_Model :: struct {
    shorter:[LENGTHS]u16,
    less:[LENGTHS][LENGTHS]u16,
    more:[LENGTHS][LENGTHS]u16,
    under:[LENGTHS][4]u16,
}

// What the distances of exact values from their multiples taught: whether one is the one
// expected, by whether the last was and whether a neighbor on its step gave it, and its
// length by that of its step.
@(private="file")
Exact_Model :: struct {
    other:[4]u16,
    length:[LENGTHS][32]u16,
}

// The length the distance at k is likely to have: that of its neighbors.
@(private="file")
length_near :: #force_inline proc "contextless" (lengths:[^]u8,k,dy,dz:int,x,y,z:bool) -> int #no_bounds_check {
    sum,count:=0,0
    if x {sum+=int(lengths[k-1]);count+=1}
    if y {sum+=int(lengths[k-dy]);count+=1}
    if z {sum+=int(lengths[k-dz]);count+=1}
    return count<2?sum:(sum+1)/count
}

// The neighbor of k whose distance from its multiple the value at k is expected to have:
// one on the same step.
@(private="file")
exact_near :: #force_inline proc "contextless" (steps:[^]u32,k,dy,dz:int,x,y,z:bool) -> (neighbor:int,found:bool) #no_bounds_check {
    switch {
    case y && steps[k-dy]==steps[k]: return k-dy,true
    case x && steps[k-1]==steps[k]:  return k-1,true
    case z && steps[k-dz]==steps[k]: return k-dz,true
    }
    return
}

@(private="file")
steps_code :: proc "contextless" (w:^Bits_Out,values:[]f32,width,height:int,exact:bool) #no_bounds_check {
    n,slice:=len(values),width*height
    steps:[PAGE_VALUES]u32=---
    lengths:[PAGE_VALUES]u8=---
    model:Steps_Model=---
    exact_model:Exact_Model=---
    probs_reset(&model)
    probs_reset(&exact_model)
    bits:=([^]u32)(raw_data(values))
    for value,k in values {steps[k]=u32(lattice_step(value))}
    k,last:=0,0
    for z:=0;k<n;z+=1 {for y in 0..<height {for x in 0..<width {
        hx,hy,hz:=x>0,y>0,z>0
        f:=fold(steps[k]-plane(raw_data(steps[:]),k,1,width,slice,hx,hy,hz))
        length:=bit_length(f)
        lengths[k]=u8(length)
        near:=length_near(raw_data(lengths[:]),k,width,slice,hx,hy,hz)
        shorter:=length<near
        if near>0 {out_bit(w,&model.shorter[near],shorter)}
        if shorter {
            for i:=near-1;i>0;i-=1 {
                out_bit(w,&model.less[near][i],length<i)
                if length==i {break}
            }
        } else {
            for i:=near;i<LENGTHS-1;i+=1 {
                out_bit(w,&model.more[near][i],length>i)
                if length==i {break}
            }
        }
        if length>1 {
            learned:=min(length-1,2)
            rest:=length-1-learned
            out_tree(w,raw_data(model.under[length][:]),f>>uint(rest),learned)
            out_raw(w,f,rest)
        }
        if exact {
            d:=away(bits[k],steps[k])
            neighbor,found:=exact_near(raw_data(steps[:]),k,width,slice,hx,hy,hz)
            if found {d-=away(bits[neighbor],steps[neighbor])}
            f=fold(d)
            out_bit(w,&exact_model.other[last|int(found)<<1],f!=0)
            last=int(f!=0)
            if f!=0 {
                length=bit_length(f)
                step:=i32(steps[k])
                out_tree(w,raw_data(exact_model.length[bit_length(u32(step<0?-step:step))][:]),u32(length-1),5)
                out_raw(w,f,length-1)
            }
        }
        k+=1
    }}}
}

// The f32 values steps_code wrote, into out, which holds PAGE_VALUES of them at most.
@(private="file")
steps_uncode :: proc "contextless" (r:^Bits_In,out:[]u8,width,height:int,exact:bool) #no_bounds_check {
    n,slice:=len(out)/4,width*height
    steps:[PAGE_VALUES]u32=---
    lengths:[PAGE_VALUES]u8=---
    model:Steps_Model=---
    exact_model:Exact_Model=---
    probs_reset(&model)
    probs_reset(&exact_model)
    bits:=([^]u32)(raw_data(out))
    k,last:=0,0
    for z:=0;k<n;z+=1 {for y in 0..<height {for x in 0..<width {
        hx,hy,hz:=x>0,y>0,z>0
        near:=length_near(raw_data(lengths[:]),k,width,slice,hx,hy,hz)
        length:int
        if near>0 && in_bit(r,&model.shorter[near]) {
            for length=near-1;length>0;length-=1 {
                if !in_bit(r,&model.less[near][length]) {break}
            }
        } else {
            for length=near;length<LENGTHS-1;length+=1 {
                if !in_bit(r,&model.more[near][length]) {break}
            }
        }
        lengths[k]=u8(length)
        f:=u32(length>0)
        if length>1 {
            learned:=min(length-1,2)
            rest:=length-1-learned
            f=f<<uint(learned)|in_tree(r,raw_data(model.under[length][:]),learned)
            f=f<<uint(rest)|in_raw(r,rest)
        }
        steps[k]=plane(raw_data(steps[:]),k,1,width,slice,hx,hy,hz)+unfold(f)
        value:=transmute(u32)lattice_value(i32(steps[k]))
        if exact {
            d:u32
            neighbor,found:=exact_near(raw_data(steps[:]),k,width,slice,hx,hy,hz)
            if found {d=away(intrinsics.unaligned_load(&bits[neighbor]),steps[neighbor])}
            other:=in_bit(r,&exact_model.other[last|int(found)<<1])
            last=int(other)
            if other {
                step:=i32(steps[k])
                length=int(in_tree(r,raw_data(exact_model.length[bit_length(u32(step<0?-step:step))][:]),5))+1
                d+=unfold(1<<uint(length-1)|in_raw(r,length-1))
            }
            value=ordered(ordered(value)+d)
        }
        intrinsics.unaligned_store(&bits[k],value)
        k+=1
    }}}
}

// What the bytes of a page taught: whether a value is off its plane, by whether the ones
// left and above were; which of its bytes are; and how far each is, by which byte.
@(private="file")
Bytes_Model :: struct {
    off:[4]u16,
    which:[16]u16,
    byte:[4][256]u16,
}

@(private="file")
bytes_code :: proc "contextless" (w:^Bits_Out,values:[]u8,size,width,height:int) #no_bounds_check {
    n:=len(values)/size
    dx,dy,dz:=size,size*width,size*width*height
    off:[PAGE_VALUES]bool=---
    model:Bytes_Model=---
    probs_reset(&model)
    k:=0
    for z:=0;k<n;z+=1 {for y in 0..<height {for x in 0..<width {
        hx,hy,hz:=x>0,y>0,z>0
        folded:[4]u8
        which:u32
        for b in 0..<size {
            d:=i8(values[k*size+b]-plane(raw_data(values),k*size+b,dx,dy,dz,hx,hy,hz))
            folded[b]=u8((d<<1)~(d>>7))
            if d!=0 {which|=1<<uint(b)}
        }
        off[k]=which!=0
        out_bit(w,&model.off[int(hx && off[k-1])|int(hy && off[k-width])<<1],which!=0)
        if which!=0 {
            if size>1 {out_tree(w,raw_data(model.which[:]),which,size)}
            for b in 0..<size {
                if which>>uint(b)&1!=0 {out_tree(w,raw_data(model.byte[b][:]),u32(folded[b]),8)}
            }
        }
        k+=1
    }}}
}

@(private="file")
bytes_uncode :: proc "contextless" (r:^Bits_In,out:[]u8,size,width,height:int) #no_bounds_check {
    n:=len(out)/size
    dx,dy,dz:=size,size*width,size*width*height
    off:[PAGE_VALUES]bool=---
    model:Bytes_Model=---
    probs_reset(&model)
    k:=0
    for z:=0;k<n;z+=1 {for y in 0..<height {for x in 0..<width {
        hx,hy,hz:=x>0,y>0,z>0
        off[k]=in_bit(r,&model.off[int(hx && off[k-1])|int(hy && off[k-width])<<1])
        which:=u32(0)
        if off[k] {which=size>1?in_tree(r,raw_data(model.which[:]),size):1}
        for b in 0..<size {
            d:u8
            if which>>uint(b)&1!=0 {
                f:=u8(in_tree(r,raw_data(model.byte[b][:]),8))
                d=(f>>1)~(0-(f&1))
            }
            out[k*size+b]=plane(raw_data(out),k*size+b,dx,dy,dz,hx,hy,hz)+d
        }
        k+=1
    }}}
}

// The values of a page of extent samples (grid_page_extent), coded into out, of
// PAGE_BYTES_MAX bytes. quantize puts f32 values on the lattice of HEIGHT_STEP;
// otherwise a page comes back bit for bit.
@(private)
page_code :: proc(values:[]$T,extent:[3]int,quantize:bool,out:[]u8) -> []u8 {
    n:=len(values)
    width,height:=extent.x,extent.y>1?extent.y:extent.z
    coded:=out[:PAGE_HEADER+n*size_of(T)]
    coded[0],coded[1],coded[2],coded[3]=u8(Page_Code.Values),size_of(T),u8(width),u8(height)
    if n>0 && n<=PAGE_VALUES && width>=1 && height>=1 && width<=PAGE && height<=PAGE && n%(width*height)==0 {
        code:=Page_Code.Bytes
        w:Bits_Out
        out_init(&w,coded[PAGE_HEADER:len(coded)-1])
        when T==f32 {
            within,on:=page_lattice(values)
            switch {
            case !within:        code=.Values
            case quantize || on: code=.Lattice
            case:                code=.Exact
            }
            if within {steps_code(&w,values,width,height,code==.Exact)}
        } else {
            bytes_code(&w,mem.slice_to_bytes(values),size_of(T),width,height)
        }
        if size,fits:=out_end(&w);fits && code!=.Values {
            coded[0]=u8(code)
            return coded[:PAGE_HEADER+size]
        }
    }
    copy(coded[PAGE_HEADER:],mem.slice_to_bytes(values))
    when T==f32 {
        if within,_:=page_lattice(values);quantize && within {
            heights:=([^]f32)(raw_data(coded[PAGE_HEADER:]))
            for value,k in values {intrinsics.unaligned_store(&heights[k],height_quantize(value))}
        }
    }
    return coded
}

// The values of a coded page into out, all of them: false when coded is not a page of
// that many.
@(private)
page_uncode :: proc(coded,out:[]u8) -> bool {
    if len(coded)<PAGE_HEADER {return false}
    size,width,height:=int(coded[1]),int(coded[2]),int(coded[3])
    if size<1 || size>4 || len(out)%size!=0 {return false}
    n:=len(out)/size
    body:=coded[PAGE_HEADER:]
    if coded[0]==u8(Page_Code.Values) {
        if len(body)!=len(out) {return false}
        copy(out,body)
        return true
    }
    if coded[0]>u8(Page_Code.Exact) || n<1 || n>PAGE_VALUES || width<1 || height<1 || n%(width*height)!=0 || len(body)>=len(out) {return false}
    r:Bits_In
    in_init(&r,body)
    if coded[0]==u8(Page_Code.Bytes) {
        bytes_uncode(&r,out,size,width,height)
    } else {
        if size!=4 {return false}
        steps_uncode(&r,out,width,height,coded[0]==u8(Page_Code.Exact))
    }
    return r.at>=len(body) && r.at<=len(body)+CODE_BYTES
}

// Room for the block of a page read from its file.
@(private)
Page_Reader :: struct {block:[]u8}

@(private)
page_reader_init :: proc(r:^Page_Reader,allocator:runtime.Allocator) -> bool {
    error:runtime.Allocator_Error
    r.block,error=make([]u8,PAGE_BYTES_MAX,allocator)
    return error==nil
}

@(private)
page_reader_destroy :: proc(r:^Page_Reader,allocator:runtime.Allocator) {
    delete(r.block,allocator)
    r^={}
}

// The values of a block into out, those of its page: false when the block is not the one
// hashed or does not hold them.
@(private)
page_decode :: proc(block:[]u8,hash:u64,out:[]u8) -> bool {
    return base.hash64(block)==hash && page_uncode(block,out)
}
