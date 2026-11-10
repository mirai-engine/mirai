package serial

import "base:intrinsics"
import "core:math"

// Bit-level writer and reader over a byte buffer, least significant bit
// first, working a 64-bit word at a time. A writer that runs out of room sets
// overflow and ignores every later write; a reader asked for more than it has
// sets error and returns zeros from then on. Neither touches memory outside
// its buffer, so a reader can be pointed at bytes that came from the network.

Bit_Writer :: struct {
    buffer:[]u8,
    scratch:u64,      // bits not stored yet, lowest first
    scratch_bits:u32,
    stored:int,       // bytes stored in buffer
    bits:int,         // bits written
    capacity:int,     // bits
    measure:bool,     // counts bits and stores nothing
    overflow:bool,
}

Bit_Reader :: struct {
    buffer:[]u8,
    position:int, // bits
    size:int,     // bits
    error:bool,
}

BIT_VARINT_GROUPS :: 10
BIT_QUATERNION_MAX_BITS :: 20
BIT_UNIT_VECTOR_MAX_BITS :: 24

bit_writer_init :: proc "contextless" (w:^Bit_Writer,buffer:[]u8) {w^={buffer=buffer,capacity=len(buffer)*8}}
// A measuring writer has no buffer and no limit: bit_writer_bits is the size the same writes would take.
bit_writer_init_measure :: proc "contextless" (w:^Bit_Writer) {w^={measure=true}}
bit_writer_bits :: #force_inline proc "contextless" (w:^Bit_Writer) -> int {return w.bits}
bit_writer_bytes :: #force_inline proc "contextless" (w:^Bit_Writer) -> int {return (w.bits+7)>>3}
bit_writer_remaining :: #force_inline proc "contextless" (w:^Bit_Writer) -> int {return w.measure?max(int):w.capacity-w.bits}

// Stores the bits still held in the scratch word and returns the bytes written so far.
// Writing can continue afterwards. A copy of the writer taken earlier rewinds it.
bit_writer_flush :: proc "contextless" (w:^Bit_Writer) -> []u8 {
    if w.measure {return nil}
    count:=int(w.scratch_bits+7)>>3
    for i in 0..<count {w.buffer[w.stored+i]=u8(w.scratch>>(8*uint(i)))}
    return w.buffer[:w.stored+count]
}

bit_write :: proc "contextless" (w:^Bit_Writer,value:u64,count:int) {
    if count<=0 {return}
    // A measuring writer refuses what a writer with room would: more bits than a word.
    if w.overflow || count>64 || (!w.measure && w.bits+count>w.capacity) {w.overflow=true;return}
    if w.measure {w.bits+=count;return}
    value:=count==64?value:value&(u64(1)<<uint(count)-1)
    w.scratch|=value<<w.scratch_bits
    total:=w.scratch_bits+u32(count)
    if total>=64 {
        intrinsics.unaligned_store((^u64le)(&w.buffer[w.stored]),u64le(w.scratch))
        w.stored+=8
        used:=64-w.scratch_bits
        w.scratch=used<64?value>>used:0
        total-=64
    }
    w.scratch_bits=total
    w.bits+=count
}

bit_write_bool :: #force_inline proc "contextless" (w:^Bit_Writer,value:bool) {bit_write(w,u64(value),1)}

// Bits needed to hold any value in 0..=max_value.
bit_count_for :: #force_inline proc "contextless" (max_value:u64) -> int {return 64-int(intrinsics.count_leading_zeros(max_value))}

// An integer known to lie in lo..=hi takes only the bits of that range. Values outside are clamped.
bit_write_ranged :: proc "contextless" (w:^Bit_Writer,value,lo,hi:i64) {
    bit_write(w,u64(clamp(value,lo,hi))-u64(lo),bit_count_for(u64(hi)-u64(lo)))
}

// Groups of seven bits, lowest first, each followed by a bit that says whether another group follows.
bit_write_varuint :: proc "contextless" (w:^Bit_Writer,value:u64) {
    value:=value
    for {
        group:=value&0x7f
        value>>=7
        bit_write(w,group|(value!=0?0x80:0),8)
        if value==0 {return}
    }
}

bit_zigzag :: #force_inline proc "contextless" (value:i64) -> u64 {return u64(value<<1)~u64(value>>63)}
bit_unzigzag :: #force_inline proc "contextless" (value:u64) -> i64 {return i64(value>>1)~-i64(value&1)}
bit_write_varint :: #force_inline proc "contextless" (w:^Bit_Writer,value:i64) {bit_write_varuint(w,bit_zigzag(value))}

bit_write_f32 :: #force_inline proc "contextless" (w:^Bit_Writer,value:f32) {bit_write(w,u64(transmute(u32)value),32)}
bit_write_f64 :: #force_inline proc "contextless" (w:^Bit_Writer,value:f64) {bit_write(w,transmute(u64)value,64)}

bit_write_float_range :: proc "contextless" (w:^Bit_Writer,value,lo,hi:f32,bits:int) {
    bit_write(w,u64(quantize_range(value,lo,hi,bits)),bits)
}
bit_write_float_precision :: proc "contextless" (w:^Bit_Writer,value,lo,hi,precision:f32) {
    bit_write(w,u64(quantize_precision(value,lo,hi,precision)),quantize_precision_bits(lo,hi,precision))
}
bit_write_unit_vector :: proc "contextless" (w:^Bit_Writer,value:[3]f32,bits:int) {
    bit_write(w,quantize_unit_vector(value,bits),2*clamp(bits,2,BIT_UNIT_VECTOR_MAX_BITS))
}
bit_write_quaternion :: proc "contextless" (w:^Bit_Writer,value:quaternion128,bits:int) {
    bit_write(w,quantize_quaternion(value,bits),2+3*clamp(bits,2,BIT_QUATERNION_MAX_BITS))
}

bit_write_align :: proc "contextless" (w:^Bit_Writer) {bit_write(w,0,(8-w.bits&7)&7)}

bit_write_bytes :: proc "contextless" (w:^Bit_Writer,bytes:[]u8) {
    if w.overflow || (!w.measure && w.bits+len(bytes)*8>w.capacity) {w.overflow=true;return}
    if w.measure {w.bits+=len(bytes)*8;return}
    i:=0
    for ;i+8<=len(bytes);i+=8 {bit_write(w,u64(intrinsics.unaligned_load((^u64le)(&bytes[i]))),64)}
    for ;i<len(bytes);i+=1 {bit_write(w,u64(bytes[i]),8)}
}

// Length as a varuint, then the bytes.
bit_write_string :: proc "contextless" (w:^Bit_Writer,value:string) {
    bit_write_varuint(w,u64(len(value)))
    bit_write_bytes(w,transmute([]u8)value)
}

// bits limits the reader to a prefix of the buffer; negative reads all of it.
bit_reader_init :: proc "contextless" (r:^Bit_Reader,buffer:[]u8,bits:=-1) {
    r^={buffer=buffer,size=len(buffer)*8}
    if bits>=0 {
        if bits>r.size {r.error=true} else {r.size=bits}
    }
}
bit_reader_remaining :: #force_inline proc "contextless" (r:^Bit_Reader) -> int {return r.error?0:r.size-r.position}
bit_reader_ok :: #force_inline proc "contextless" (r:^Bit_Reader) -> bool {return !r.error}

bit_read :: proc "contextless" (r:^Bit_Reader,count:int) -> u64 {
    if count<=0 {return 0}
    if r.error || count>64 || r.position+count>r.size {r.error=true;return 0}
    first:=r.position>>3
    shift:=uint(r.position&7)
    r.position+=count
    available:=len(r.buffer)-first
    word:u64
    if available>=8 {
        word=u64(intrinsics.unaligned_load((^u64le)(&r.buffer[first])))
    } else {
        for i in 0..<available {word|=u64(r.buffer[first+i])<<(8*uint(i))}
    }
    value:=word>>shift
    if shift+uint(count)>64 {value|=u64(r.buffer[first+8])<<(64-shift)}
    return count==64?value:value&(u64(1)<<uint(count)-1)
}

bit_read_bool :: #force_inline proc "contextless" (r:^Bit_Reader) -> bool {return bit_read(r,1)!=0}

// A value outside lo..=hi cannot come from bit_write_ranged: it is an error and lo is returned.
bit_read_ranged :: proc "contextless" (r:^Bit_Reader,lo,hi:i64) -> i64 {
    span:=u64(hi)-u64(lo)
    value:=bit_read(r,bit_count_for(span))
    if value>span {r.error=true;return lo}
    return i64(u64(lo)+value)
}

bit_read_varuint :: proc "contextless" (r:^Bit_Reader) -> u64 {
    value:u64
    for group in 0..<BIT_VARINT_GROUPS {
        bits:=bit_read(r,8)
        if r.error {return 0}
        value|=(bits&0x7f)<<(7*uint(group))
        if bits&0x80==0 {return value}
    }
    r.error=true
    return 0
}
bit_read_varint :: #force_inline proc "contextless" (r:^Bit_Reader) -> i64 {return bit_unzigzag(bit_read_varuint(r))}

bit_read_f32 :: #force_inline proc "contextless" (r:^Bit_Reader) -> f32 {return transmute(f32)u32(bit_read(r,32))}
bit_read_f64 :: #force_inline proc "contextless" (r:^Bit_Reader) -> f64 {return transmute(f64)bit_read(r,64)}

bit_read_float_range :: proc "contextless" (r:^Bit_Reader,lo,hi:f32,bits:int) -> f32 {
    return dequantize_range(u32(bit_read(r,bits)),lo,hi,bits)
}
bit_read_float_precision :: proc "contextless" (r:^Bit_Reader,lo,hi,precision:f32) -> f32 {
    return dequantize_precision(u32(bit_read(r,quantize_precision_bits(lo,hi,precision))),lo,hi,precision)
}
bit_read_unit_vector :: proc "contextless" (r:^Bit_Reader,bits:int) -> [3]f32 {
    return dequantize_unit_vector(bit_read(r,2*clamp(bits,2,BIT_UNIT_VECTOR_MAX_BITS)),bits)
}
bit_read_quaternion :: proc "contextless" (r:^Bit_Reader,bits:int) -> quaternion128 {
    return dequantize_quaternion(bit_read(r,2+3*clamp(bits,2,BIT_QUATERNION_MAX_BITS)),bits)
}

bit_read_align :: proc "contextless" (r:^Bit_Reader) {bit_read(r,(8-r.position&7)&7)}

// Fills out, or sets error and leaves it zeroed when the stream is shorter.
bit_read_bytes :: proc "contextless" (r:^Bit_Reader,out:[]u8) -> bool {
    if r.error || r.position+len(out)*8>r.size {
        r.error=true
        for &b in out {b=0}
        return false
    }
    i:=0
    for ;i+8<=len(out);i+=8 {intrinsics.unaligned_store((^u64le)(&out[i]),u64le(bit_read(r,64)))}
    for ;i<len(out);i+=1 {out[i]=u8(bit_read(r,8))}
    return true
}

// Reads into storage and returns the part used. A length that does not fit storage or the stream is an error.
bit_read_string :: proc "contextless" (r:^Bit_Reader,storage:[]u8) -> string {
    length:=bit_read_varuint(r)
    if r.error || length>u64(len(storage)) || length*8>u64(r.size-r.position) {r.error=true;return ""}
    bit_read_bytes(r,storage[:length])
    return string(storage[:length])
}

// value in lo..=hi to an integer of bits bits (1 to 32); the ends of the range are exact.
quantize_range :: proc "contextless" (value,lo,hi:f32,bits:int) -> u32 {
    top:=f64(u64(1)<<uint(clamp(bits,1,32))-1)
    if !(hi>lo) || value!=value {return 0}
    return u32(clamp((f64(value)-f64(lo))/(f64(hi)-f64(lo)),0,1)*top+0.5)
}
dequantize_range :: proc "contextless" (value:u32,lo,hi:f32,bits:int) -> f32 {
    top:=u64(1)<<uint(clamp(bits,1,32))-1
    // Weighted, not lo plus a share of the range: the ends stay exact when the range is far wider than one of them.
    share:=f64(min(u64(value),top))/f64(top)
    return f32(f64(lo)*(1-share)+f64(hi)*share)
}

// Bits needed to cover lo..=hi in steps of precision.
quantize_precision_bits :: proc "contextless" (lo,hi,precision:f32) -> int {
    if !(hi>lo) || !(precision>0) {return 1}
    return clamp(bit_count_for(u64(math.ceil((f64(hi)-f64(lo))/f64(precision)))),1,32)
}
quantize_precision :: proc "contextless" (value,lo,hi,precision:f32) -> u32 {
    if !(hi>lo) || !(precision>0) || value!=value {return 0}
    top:=f64(u64(1)<<uint(quantize_precision_bits(lo,hi,precision))-1)
    return u32(min((f64(clamp(value,lo,hi))-f64(lo))/f64(precision)+0.5,top))
}
dequantize_precision :: proc "contextless" (value:u32,lo,hi,precision:f32) -> f32 {
    return f32(min(f64(lo)+f64(value)*f64(precision),f64(hi)))
}

// Octahedral mapping of a unit vector to two components of bits bits each (2 to 24).
quantize_unit_vector :: proc "contextless" (value:[3]f32,bits:int) -> u64 {
    bits:=uint(clamp(bits,2,BIT_UNIT_VECTOR_MAX_BITS))
    top:=f64(u64(1)<<bits-1)
    v:=[3]f64{f64(value.x),f64(value.y),f64(value.z)}
    sum:=abs(v.x)+abs(v.y)+abs(v.z)
    if !(sum>0) {v={0,0,1};sum=1}
    x,y:=v.x/sum,v.y/sum
    if v.z<0 {
        fx,fy:=(1-abs(y))*(x>=0?1:-1),(1-abs(x))*(y>=0?1:-1)
        x,y=fx,fy
    }
    qx:=u64(clamp(x*0.5+0.5,0,1)*top+0.5)
    qy:=u64(clamp(y*0.5+0.5,0,1)*top+0.5)
    return qx|qy<<bits
}
dequantize_unit_vector :: proc "contextless" (value:u64,bits:int) -> [3]f32 {
    bits:=uint(clamp(bits,2,BIT_UNIT_VECTOR_MAX_BITS))
    mask:=u64(1)<<bits-1
    top:=f64(mask)
    x:=f64(value&mask)/top*2-1
    y:=f64(value>>bits&mask)/top*2-1
    z:=1-abs(x)-abs(y)
    if z<0 {
        fx,fy:=(1-abs(y))*(x>=0?1:-1),(1-abs(x))*(y>=0?1:-1)
        x,y=fx,fy
    }
    length:=math.sqrt(x*x+y*y+z*z)
    if !(length>0) {return {0,0,1}}
    return {f32(x/length),f32(y/length),f32(z/length)}
}

// Smallest three: the index of the largest component in two bits and the other
// three, which lie in -1/sqrt(2)..1/sqrt(2), in bits bits each (2 to 20).
quantize_quaternion :: proc "contextless" (value:quaternion128,bits:int) -> u64 {
    bits:=uint(clamp(bits,2,BIT_QUATERNION_MAX_BITS))
    top:=f64(u64(1)<<bits-1)
    c:=[4]f64{f64(value.x),f64(value.y),f64(value.z),f64(value.w)}
    length:=math.sqrt(c[0]*c[0]+c[1]*c[1]+c[2]*c[2]+c[3]*c[3])
    if !(length>0) || length!=length {c={0,0,0,1};length=1}
    largest:=0
    for i in 1..<4 {if abs(c[i])>abs(c[largest]) {largest=i}}
    scale:=(c[largest]<0?-1:1)/length
    packed:=u64(largest)
    shift:=uint(2)
    for i in 0..<4 {
        if i==largest {continue}
        packed|=u64(clamp(c[i]*scale*math.SQRT_TWO*0.5+0.5,0,1)*top+0.5)<<shift
        shift+=bits
    }
    return packed
}
dequantize_quaternion :: proc "contextless" (value:u64,bits:int) -> quaternion128 {
    bits:=uint(clamp(bits,2,BIT_QUATERNION_MAX_BITS))
    mask:=u64(1)<<bits-1
    top:=f64(mask)
    largest:=int(value&3)
    c:[4]f64
    shift:=uint(2)
    sum:f64
    for i in 0..<4 {
        if i==largest {continue}
        c[i]=(f64(value>>shift&mask)/top*2-1)*math.SQRT_TWO*0.5
        sum+=c[i]*c[i]
        shift+=bits
    }
    c[largest]=math.sqrt(max(1-sum,0))
    // Only bits that no rotation is written as add up to more than 1.
    if sum>1 {c/=math.sqrt(sum)}
    return quaternion(w=f32(c[3]),x=f32(c[0]),y=f32(c[1]),z=f32(c[2]))
}
