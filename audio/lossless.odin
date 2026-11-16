package mirai_audio

import "base:intrinsics"
import "base:runtime"

// Lossless: 16 bit PCM coded the way FLAC codes it, in blocks that decode on
// their own, and decoded back bit for bit. Each block of a stereo sound first
// takes left and right to the pair that predicts best (left and side, side and
// right, or mid and side); then each channel is predicted from its past
// samples, by a fixed polynomial or by a linear predictor with quantized
// coefficients, and what the prediction missed is stored with Rice codes in
// partitions, each with its own parameter. lossless_encode writes it.
//
//   header   LOSSLESS_HEADER bytes, little endian: "MLPC", channels u8, 0 u8,
//            frames per block u16, sample rate u32, frames u32, blocks u32
//   offsets  u32 for each block and one more: where each block begins and the
//            last one ends, counted from the end of this table
//   blocks   bit streams, most significant bit first
//
// A block:
//   stereo mode     2 bits, only with two channels: 0 left right, 1 left side,
//                   2 side right, 3 mid side; side is left-right, mid (left+right)>>1
//   each channel    2 bits kind: 0 constant, 1 verbatim, 2 fixed, 3 linear
//     constant      the value in the bits of the channel: 16, or 17 for side
//     the others    4 bits of trailing zeros that every sample has and is stored
//                   without; then the samples in the bits that are left
//     verbatim      every sample
//     fixed         3 bits of order (0 to 4), its first samples, the residual
//     linear        5 bits of order-1, 4 bits of precision-1, 4 bits of shift,
//                   the coefficients in precision bits, its first samples, the
//                   residual. A sample is the residual plus the sum of each
//                   coefficient times the sample that many before, over 2^shift
//   residual        4 bits of partition order p: 2^p partitions of the block,
//                   the first without the first samples. Each: 5 bits of Rice
//                   parameter k and the values, zigzag (0,-1,1,-2...) and
//                   coded as value>>k in unary (zeros and a one) and the k low
//                   bits; k 31 is an escape: 5 bits of width and the values as
//                   signed integers of that width
// Values that span bits are signed two's complement.

LOSSLESS_MAGIC :: "MLPC"
LOSSLESS_HEADER :: 20
LOSSLESS_ORDER_MAX :: 32
// Frames of a block that lossless_encode writes.
LOSSLESS_BLOCK_FRAMES :: 4096

@(private)
Lossless :: struct {
    channels,sample_rate,frames:int,
    block_frames,blocks:int,
    offsets:[]u8, // blocks+1 u32
    data:[]u8,
}

@(private)
lossless_parse :: proc "contextless" (file:[]u8) -> (l:Lossless,error:Error) {
    if len(file)<LOSSLESS_HEADER || string(file[:4])!=LOSSLESS_MAGIC || file[5]!=0 {return {},.Invalid_Data}
    l.channels=int(file[4])
    l.block_frames=int(wav_u16(file[6:]))
    l.sample_rate=int(wav_u32(file[8:]))
    l.frames=int(wav_u32(file[12:]))
    l.blocks=int(wav_u32(file[16:]))
    if l.channels<1 || l.channels>2 || l.sample_rate<=0 || l.block_frames<1 {return {},.Invalid_Data}
    if l.blocks!=(l.frames+l.block_frames-1)/l.block_frames {return {},.Invalid_Data}
    table:=(l.blocks+1)*4
    if len(file)-LOSSLESS_HEADER<table {return {},.Invalid_Data}
    l.offsets=file[LOSSLESS_HEADER:][:table]
    l.data=file[LOSSLESS_HEADER+table:]
    return l,.None
}

// Every block begins where the one before ends, or later, and ends inside the file.
@(private)
lossless_table_valid :: proc "contextless" (l:^Lossless) -> bool {
    previous:=0
    for block in 0..=l.blocks {
        at:=int(wav_u32(l.offsets[block*4:]))
        if at<previous || at>len(l.data) {return false}
        previous=at
    }
    return true
}

// A whole file decoded, as the frames a WAV of the same samples gives.
lossless_decode :: proc(file:[]u8,allocator:runtime.Allocator) -> (pcm:Pcm,error:Error) {
    l:=lossless_parse(file) or_return
    planes,failed:=make([]i32,l.block_frames*l.channels,allocator)
    if failed!=nil {return {},.Out_Of_Memory}
    defer delete(planes,allocator)
    samples:[]f32
    if samples,failed=make([]f32,l.frames*l.channels,allocator);failed!=nil {return {},.Out_Of_Memory}
    for block in 0..<l.blocks {
        frames,ok:=lossless_block(&l,block,planes)
        if !ok {
            delete(samples,allocator)
            return {},.Invalid_Data
        }
        lossless_convert(planes,l.block_frames,l.channels,0,frames,samples[block*l.block_frames*l.channels:])
    }
    return {samples,l.channels,l.sample_rate,0},.None
}

// Frames [first,first+count) of a decoded block to f32, interleaved.
@(private)
lossless_convert :: proc "contextless" (planes:[]i32,block_frames,channels,first,count:int,out:[]f32) {
    if count<=0 {return}
    if channels==1 {
        #no_bounds_check for i in 0..<count {out[i]=f32(planes[first+i])*(1.0/32768)}
        return
    }
    left,right:=planes[first:][:count],planes[block_frames+first:][:count]
    out:=out[:count*2]
    #no_bounds_check for i in 0..<count {
        out[i*2]=f32(left[i])*(1.0/32768)
        out[i*2+1]=f32(right[i])*(1.0/32768)
    }
}

// Frames [first,first+count) of a decoded block to 16 bits, interleaved.
@(private)
lossless_convert_i16 :: proc "contextless" (planes:[]i32,block_frames,channels,first,count:int,out:[]i16) {
    if count<=0 {return}
    if channels==1 {
        for i in 0..<count {out[i]=i16(planes[first+i])}
        return
    }
    left,right:=planes[first:][:count],planes[block_frames+first:][:count]
    out:=out[:count*2]
    #no_bounds_check for i in 0..<count {
        out[i*2]=i16(left[i])
        out[i*2+1]=i16(right[i])
    }
}

// Decodes a block into planes, block_frames samples per channel one after
// the other, and returns its frames. A damaged block fills them with silence
// and is not ok.
@(private)
lossless_block :: proc "contextless" (l:^Lossless,index:int,planes:[]i32) -> (frames:int,ok:bool) {
    frames=min(l.block_frames,l.frames-index*l.block_frames)
    start:=int(wav_u32(l.offsets[index*4:]))
    end:=int(wav_u32(l.offsets[index*4+4:]))
    defer if !ok {
        for &sample in planes[:l.block_frames*l.channels] {sample=0}
    }
    if start>end || end>len(l.data) {return frames,false}
    b:=Bits{data=l.data[start:end]}
    if l.channels==1 {
        if !lossless_subframe(&b,planes[:frames],16) {return frames,false}
        for &sample in planes[:frames] {sample=clamp(sample,-32768,32767)}
        return frames,!b.bad
    }
    mode:=bits_read(&b,2)
    left,right:=planes[:frames],planes[l.block_frames:][:frames]
    if !lossless_subframe(&b,left,mode==2?17:16) || !lossless_subframe(&b,right,mode==1 || mode==3?17:16) {return frames,false}
    #no_bounds_check switch mode {
    case 1:for i in 0..<frames {right[i]=left[i]-right[i]}
    case 2:for i in 0..<frames {left[i]+=right[i]}
    case 3:
        for i in 0..<frames {
            side:=right[i]
            mid:=left[i]<<1|side&1
            left[i]=(mid+side)>>1
            right[i]=(mid-side)>>1
        }
    }
    #no_bounds_check for i in 0..<frames {
        left[i]=clamp(left[i],-32768,32767)
        right[i]=clamp(right[i],-32768,32767)
    }
    return frames,!b.bad
}

@(private)
lossless_subframe :: proc "contextless" (b:^Bits,out:[]i32,bits:u32) -> bool {
    n:=len(out)
    kind:=bits_read(b,2)
    if kind==0 {
        value:=bits_signed(b,bits)
        for &sample in out {sample=value}
        return !b.bad
    }
    wasted:=bits_read(b,4)
    if wasted>=bits {return false}
    width:=bits-wasted
    switch kind {
    case 1:
        for &sample in out {sample=bits_signed(b,width)}
    case 2:
        order:=int(bits_read(b,3))
        if order>4 || order>n {return false}
        for &sample in out[:order] {sample=bits_signed(b,width)}
        if !lossless_residual(b,out,order) {return false}
        #no_bounds_check switch order {
        case 1:for i in 1..<n {out[i]+=out[i-1]}
        case 2:for i in 2..<n {out[i]+=2*out[i-1]-out[i-2]}
        case 3:for i in 3..<n {out[i]+=3*(out[i-1]-out[i-2])+out[i-3]}
        case 4:for i in 4..<n {out[i]+=4*(out[i-1]+out[i-3])-6*out[i-2]-out[i-4]}
        }
    case 3:
        order:=int(bits_read(b,5))+1
        precision:=bits_read(b,4)+1
        shift:=bits_read(b,4)
        if order>n {return false}
        coefficients:[LOSSLESS_ORDER_MAX]i64
        for &c in coefficients[:order] {c=i64(bits_signed(b,precision))}
        for &sample in out[:order] {sample=bits_signed(b,width)}
        if !lossless_residual(b,out,order) {return false}
        lossless_predict(out,coefficients[:order],shift)
    }
    if wasted>0 {
        for &sample in out {sample<<=wasted}
    }
    return !b.bad
}

// Adds the prediction to the residual in out[order:], in place.
@(private)
lossless_predict :: proc "contextless" (out:[]i32,coefficients:[]i64,shift:u32) {
    order:=len(coefficients)
    #no_bounds_check switch order {
    case 1..=12:
        // The usual orders, without a loop over the coefficients.
        c:[12]i64
        copy(c[:],coefficients)
        for i in order..<len(out) {
            x:=out[i-order:][:order]
            sum:i64
            switch order {
            case 12:sum+=c[11]*i64(x[0]);fallthrough
            case 11:sum+=c[10]*i64(x[order-11]);fallthrough
            case 10:sum+=c[9]*i64(x[order-10]);fallthrough
            case 9:sum+=c[8]*i64(x[order-9]);fallthrough
            case 8:sum+=c[7]*i64(x[order-8]);fallthrough
            case 7:sum+=c[6]*i64(x[order-7]);fallthrough
            case 6:sum+=c[5]*i64(x[order-6]);fallthrough
            case 5:sum+=c[4]*i64(x[order-5]);fallthrough
            case 4:sum+=c[3]*i64(x[order-4]);fallthrough
            case 3:sum+=c[2]*i64(x[order-3]);fallthrough
            case 2:sum+=c[1]*i64(x[order-2]);fallthrough
            case 1:sum+=c[0]*i64(x[order-1])
            }
            out[i]+=i32(sum>>shift)
        }
    case:
        for i in order..<len(out) {
            sum:i64
            for c,j in coefficients {sum+=c*i64(out[i-1-j])}
            out[i]+=i32(sum>>shift)
        }
    }
}

@(private)
lossless_residual :: proc "contextless" (b:^Bits,out:[]i32,order:int) -> bool {
    n:=len(out)
    p:=bits_read(b,4)
    parts:=1<<p
    if n%parts!=0 || n>>p<order {return false}
    at:=order
    for part in 0..<parts {
        count:=n>>p-(order if part==0 else 0)
        values:=out[at:][:count]
        at+=count
        k:=bits_read(b,5)
        if k==31 {
            width:=bits_read(b,5)
            for &value in values {value=bits_signed(b,width)}
            continue
        }
        #no_bounds_check for &value in values {
            u:=bits_unary(b)<<k|bits_read(b,k)
            value=i32(u>>1)~-i32(u&1)
        }
        if b.bad {return false}
    }
    return !b.bad
}

// Reads bits most significant first. Reading past the end gives zeros and
// sets bad.
@(private)
Bits :: struct {
    data:[]u8,
    at:int,
    cache:u64, // count bits from the top; below them, bits that follow, or zeros
    count:u32,
    bad:bool,
}

@(private)
bits_refill :: #force_inline proc "contextless" (b:^Bits) {
    if b.at+8<=len(b.data) {
        // The word may hold more than fits: the bits beyond count are those that
        // follow, and loading them again ors the same values.
        word:=u64(intrinsics.unaligned_load((^u64be)(raw_data(b.data[b.at:]))))
        bytes:=(63-b.count)>>3
        b.cache|=word>>b.count
        b.at+=int(bytes)
        b.count+=bytes*8
        return
    }
    for b.count<=56 && b.at<len(b.data) {
        b.cache|=u64(b.data[b.at])<<(56-b.count)
        b.at+=1
        b.count+=8
    }
}

@(private)
bits_read :: #force_inline proc "contextless" (b:^Bits,n:u32) -> u32 {
    if n==0 {return 0}
    if b.count<n {
        bits_refill(b)
        if b.count<n {b.bad=true;return 0}
    }
    value:=u32(b.cache>>(64-n))
    b.cache<<=n
    b.count-=n
    return value
}

@(private)
bits_signed :: #force_inline proc "contextless" (b:^Bits,n:u32) -> i32 {
    if n==0 {return 0}
    return i32(bits_read(b,n)<<(32-n))>>(32-n)
}

// Zeros up to a one, the one read too: how many zeros.
@(private)
bits_unary :: #force_inline proc "contextless" (b:^Bits) -> u32 {
    zeros:u32
    for {
        if b.count<32 {
            bits_refill(b)
            if b.count==0 {b.bad=true;return 0}
        }
        lead:=u32(intrinsics.count_leading_zeros(b.cache))
        if lead<b.count {
            b.cache=b.cache<<lead<<1
            b.count-=lead+1
            return zeros+lead
        }
        zeros+=b.count
        b.cache=0
        b.count=0
    }
}
