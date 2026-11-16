package mirai_anim

import "base:intrinsics"
import cmath "core:math"
import "core:simd"
import math "mirai:std/math"

Key_Encoding :: enum u8 {Raw,Sampled}

// The tracks of a clip as library_compress leaves them: one stream per clip with every track's
// values at a uniform rate from time 0 to `duration` (sample k at min(k/rate,duration): the last
// interval may be shorter). Little endian, without alignment:
//
//   Stream_Header
//   codes      4 bits per track of the clip, from the lowest: its Stream_Kind and then its
//              Stream_Width
//   constants  per Constant track, in the clip's order, its components as f32
//   keys       per Keys track held in the stream, in the clip's order: a u32 with its key count
//              and, in its top 4 bits, the floats of a value (stream_key_width), then the times
//              of its keys and their values as f32; between two keys it is linear, a rotation
//              along slerp, as track_evaluate. A Keys track kept in the library (encoding Raw) has
//              the width code 3
//   order      the Animated tracks as u16 places in the clip, in blocks: rotations, then positions
//              and scales, then curves, each block in the clip's order; what follows goes in this
//              order
//   ranges     per Animated track the minimum of each component and, after those of every
//              track, the extent of each, as f32
//   segments   per segment its Stream_Segment
//   per segment, from Stream_Segment.bits: a byte per Animated track with its bits per component
//              (stream_bits_valid), two bytes per component of each with fewer than STREAM_RAW,
//              and its samples one after another, each with the components of every Animated
//              track, packed from the lowest bit
//
// A component with b bits in 1..STREAM_MAX_BITS is q/(2^b-1) of its segment's range, which starts
// low/255 into the track's range and spans span/255 of it (its two bytes); with 0 bits it holds
// still in the segment at (low|span<<8)/65535 of the track's range; STREAM_RAW keeps its f32. A
// stream of one segment has no range bytes and no 0 bits: its segment's range is the track's. A
// rotation stores x, y and z of its quaternion with w>=0. A Default track holds STREAM_DEFAULTS
// of its property; a Keys track keeps its keys in the stream or, with encoding Raw, in the library.
Stream_Header :: struct #packed {
    bytes:u32, // the whole stream, without the STREAM_PADDING after it
    count:u32, // samples
    rate,duration:f32,
    tracks,constants,animated,segments:u32,
    rotations,threes:u32, // Animated tracks in the first two blocks of the order
    keyed:u32,              // Keys tracks held in the stream
    keys,order,ranges,table:u32, // where the keys, the order, the ranges and the segments start
}
Stream_Segment :: struct #packed {
    start:u32,   // its first sample
    bits:u32,    // where its bytes start in the stream
    samples:u32, // where its samples start in the stream
    stride:u32,  // the bits of one of its samples
}
Stream_Kind :: enum u8 {Default,Constant,Animated,Keys}
Stream_Width :: enum u8 {One,Three,Four}

STREAM_RAW :: 32
STREAM_MAX_BITS :: 23
// The bytes after the last stream: a component reads 8 bytes from the one it starts in.
STREAM_PADDING :: 8
STREAM_MAX_COUNT :: 1<<24
// The tracks of a clip that a stream can hold: the order keeps their places in u16.
STREAM_MAX_TRACKS :: 1<<16
// What a Default track of each property holds.
STREAM_DEFAULTS :: [Property]math.Vec4{.Position={},.Rotation={0,0,0,1},.Scale={1,1,1,0},.Float={},.Vector={}}
stream_default :: #force_inline proc "contextless" (property:Property) -> math.Vec4 {
    #partial switch property {
    case .Rotation:return {0,0,0,1}
    case .Scale:return {1,1,1,0}
    }
    return {}
}

stream_components :: #force_inline proc "contextless" (property:Property) -> int {
    switch property {
    case .Float:return 1
    case .Vector:return 4
    case .Position,.Rotation,.Scale:return 3
    }
    return 0
}
stream_width :: #force_inline proc "contextless" (property:Property) -> Stream_Width {
    switch property {
    case .Float:return .One
    case .Vector:return .Four
    case .Position,.Rotation,.Scale:return .Three
    }
    return .One
}
// The block of the order an Animated track of a property goes in.
stream_block :: #force_inline proc "contextless" (property:Property) -> int {
    switch property {
    case .Rotation:return 0
    case .Position,.Scale:return 1
    case .Float,.Vector:return 2
    }
    return 2
}
// The floats of a key's value held in a stream: a rotation keeps its four.
stream_key_width :: #force_inline proc "contextless" (property:Property) -> int {return 4 if property==.Rotation else stream_components(property)}
stream_bits_valid :: #force_inline proc "contextless" (bits:int) -> bool {return bits==STREAM_RAW || bits>=0 && bits<=STREAM_MAX_BITS}

@(private) STREAM_HEADER :: size_of(Stream_Header)

@(private)
stream_load :: #force_inline proc "contextless" ($T:typeid,data:[]u8,at:int) -> T {
    return intrinsics.unaligned_load((^T)(raw_data(data[at:][:size_of(T)])))
}
// Every caller has checked i against the stream's tracks and the codes against its bytes.
@(private)
stream_code :: #force_inline proc "contextless" (data:[]u8,i:int) -> (kind:Stream_Kind,components:int) #no_bounds_check {
    code:=data[STREAM_HEADER+i>>1]>>(uint(i&1)*4)
    width:=int((code>>2)&3)
    return Stream_Kind(code&3),1 if width==0 else width+2 if width<3 else 0
}
@(private)
stream_constants :: #force_inline proc "contextless" (h:Stream_Header) -> int {return STREAM_HEADER+(int(h.tracks)+1)/2}
@(private)
stream_animated_floats :: #force_inline proc "contextless" (h:Stream_Header) -> int {return (int(h.table)-int(h.ranges))/8}
// The place in the clip of the Animated track at a place of the order, or -1 past the stream.
@(private)
stream_ordered :: #force_inline proc "contextless" (data:[]u8,h:Stream_Header,o:int) -> int {
    at:=int(h.order)+2*o
    if o<0 || at>len(data)-2 {return -1}
    return int(intrinsics.unaligned_load((^u16)(uintptr(raw_data(data))+uintptr(at))))
}

// The bytes of a stream whose clip has `tracks` (rows with a property and an encoding, the
// Sampled ones in the stream and the Raw ones Keys). ok is false unless the header, codes,
// order, values, segments and bit rates are consistent and finite and it fits in `data` with
// `padding` bytes after it.
stream_check :: proc "contextless" (data:[]u8,tracks:[]$T,padding:=STREAM_PADDING) -> (bytes:int,ok:bool) {
    if len(data)<STREAM_HEADER || padding<0 || len(tracks)>STREAM_MAX_TRACKS {return}
    h:=stream_load(Stream_Header,data,0)
    bytes=int(h.bytes)
    if bytes<STREAM_HEADER || bytes>len(data)-padding || h.count==0 || h.count>STREAM_MAX_COUNT || !anim_finite(h.duration) || h.duration<0 || int(h.tracks)!=len(tracks) || stream_constants(h)>bytes {return}
    if h.count==1 {
        if h.segments!=0 || h.animated!=0 {return}
    } else {
        span:=h.rate*h.duration
        if !(h.duration>0) || !anim_finite(h.rate) || !(span>f32(h.count)-2) || span>f32(h.count-1)+1e-3 || h.animated==0 || h.segments==0 || h.segments>h.count {return}
    }
    constants,constant_floats,animated_floats,keyed:=0,0,0,0
    blocks:[3]int
    for track,i in tracks {
        kind,components:=stream_code(data,i)
        if kind!=.Keys && track.encoding!=.Sampled || track.encoding>.Sampled || track.property>max(Property) {return}
        if components!=(0 if kind==.Keys && track.encoding==.Raw else stream_components(track.property)) {return}
        switch kind {
        case .Constant:constants+=1;constant_floats+=components
        case .Animated:blocks[stream_block(track.property)]+=1;animated_floats+=components
        case .Keys:if track.encoding==.Sampled {keyed+=1}
        case .Default:
        }
    }
    if constants!=int(h.constants) || keyed!=int(h.keyed) || blocks[0]+blocks[1]+blocks[2]!=int(h.animated) || blocks[0]!=int(h.rotations) || blocks[1]!=int(h.threes) {return}
    if int(h.keys)!=stream_constants(h)+4*constant_floats || int(h.order)<int(h.keys) || int(h.ranges)!=int(h.order)+2*int(h.animated) || int(h.table)!=int(h.ranges)+8*animated_floats {return}
    // The keys held in the stream: counts, times in order and finite values that fill their section.
    {
        at:=int(h.keys)
        for track,i in tracks {
            kind,_:=stream_code(data,i)
            if kind!=.Keys || track.encoding!=.Sampled {continue}
            if at>int(h.order)-4 {return}
            word:=stream_load(u32,data,at)
            count,width:=int(word&(1<<28-1)),int(word>>28)
            if width!=stream_key_width(track.property) || count==0 || count>(int(h.order)-at-4)/(4+4*width) {return}
            previous:=f32(0)
            for k in 0..<count {
                time:=stream_load(f32,data,at+4+4*k)
                if !anim_finite(time) || time<previous {return}
                previous=time
                value:math.Vec4
                for c in 0..<width {value[c]=stream_load(f32,data,at+4+4*count+4*(width*k+c))}
                for c in 0..<width {if !anim_finite(value[c]) {return}}
                if track.property==.Rotation && abs(value.x)+abs(value.y)+abs(value.z)+abs(value.w)<1e-8 {return}
            }
            at+=4+4*count*(1+width)
        }
        if at!=int(h.order) {return}
    }
    end:=int(h.table)+int(h.segments)*size_of(Stream_Segment)
    if end>bytes {return}
    // The order: every Animated track once, in its block, each block in the clip's order.
    previous,block:=-1,0
    for o in 0..<int(h.animated) {
        at:=stream_ordered(data,h,o)
        for block<2 && o>=(int(h.rotations) if block==0 else int(h.rotations+h.threes)) {block+=1;previous=-1}
        if at<=previous || at>=len(tracks) {return}
        kind,_:=stream_code(data,at)
        if kind!=.Animated || stream_block(tracks[at].property)!=block {return}
        previous=at
    }
    at:=stream_constants(h)
    for track,i in tracks {
        kind,components:=stream_code(data,i)
        if kind!=.Constant {continue}
        squares:f32
        for c in 0..<components {
            v:=stream_load(f32,data,at+4*c)
            if !anim_finite(v) {return}
            squares+=v*v
        }
        if track.property==.Rotation && squares>1.0001 {return}
        at+=4*components
    }
    for i in 0..<animated_floats {
        minimum,extent:=stream_load(f32,data,int(h.ranges)+4*i),stream_load(f32,data,int(h.ranges)+4*(animated_floats+i))
        if !anim_finite(minimum) || !anim_finite(extent) || extent<0 || !anim_finite(minimum+extent) {return}
    }
    ranged:=h.segments>1
    for s in 0..<int(h.segments) {
        segment:=stream_load(Stream_Segment,data,int(h.table)+s*size_of(Stream_Segment))
        next:=stream_load(Stream_Segment,data,int(h.table)+(s+1)*size_of(Stream_Segment)).start if s+1<int(h.segments) else h.count
        if s==0 && segment.start!=0 || next<=segment.start || next>h.count || int(segment.bits)!=end || int(h.animated)>bytes-end {return}
        ranges:=end+int(h.animated)
        stride:=0
        for o in 0..<int(h.animated) {
            _,components:=stream_code(data,stream_ordered(data,h,o))
            bits:=int(data[end+o])
            if !stream_bits_valid(bits) || bits==0 && !ranged {return}
            stride+=bits*components
            if bits==STREAM_RAW || !ranged {continue}
            if 2*components>bytes-ranges {return}
            if bits>0 {for c in 0..<components {if int(data[ranges+2*c])+int(data[ranges+2*c+1])>255 {return}}}
            ranges+=2*components
        }
        size:=(int(next-segment.start)*stride+7)/8
        if int(segment.samples)!=ranges || int(segment.stride)!=stride || size>bytes-ranges {return}
        end=ranges+size
    }
    if end!=bytes {return}
    return bytes,true
}

@(private,rodata) stream_inverse:=[STREAM_MAX_BITS+1]f32{0,1.0/1,1.0/3,1.0/7,1.0/15,1.0/31,1.0/63,1.0/127,1.0/255,1.0/511,1.0/1023,1.0/2047,1.0/4095,1.0/8191,1.0/16383,1.0/32767,1.0/65535,1.0/131071,1.0/262143,1.0/524287,1.0/1048575,1.0/2097151,1.0/4194303,1.0/8388607}
@(private) Stream_F4 :: #simd[4]f32

// The components of a sample from their quantized values: a fraction of the segment's range,
// which is a fraction of the track's range; the same arithmetic in library_compress and here.
@(private)
stream_dequantize :: #force_inline proc "contextless" (minimum,extent:math.Vec4,low,span:[4]u8,bits:int,q:[4]u32,ranged:bool) -> math.Vec4 {
    l:=Stream_F4{f32(low[0]),f32(low[1]),f32(low[2]),f32(low[3])}
    w:=Stream_F4{f32(span[0]),f32(span[1]),f32(span[2]),f32(span[3])}
    part:Stream_F4
    if bits==0 {part=(l+w*Stream_F4(256))*Stream_F4(1.0/65535)} else {
        part=Stream_F4{f32(q[0]),f32(q[1]),f32(q[2]),f32(q[3])}*Stream_F4(stream_inverse[bits])
        if ranged {part=(l+w*part)*Stream_F4(1.0/255)}
    }
    return transmute(math.Vec4)(transmute(Stream_F4)minimum+transmute(Stream_F4)extent*part)
}
// 64 bits of the stream from a bit on, or 0 past its padding.
@(private)
stream_word :: #force_inline proc "contextless" (data:[]u8,position:int) -> u64 {
    at:=position>>3
    if at<0 || at>len(data)-8 {return 0}
    return intrinsics.unaligned_load((^u64)(uintptr(raw_data(data))+uintptr(at)))>>uint(position&7)
}
// Four floats from a byte, the ones past `components` zero, or zero past the padding.
@(private)
stream_floats :: #force_inline proc "contextless" (data:[]u8,at,components:int) -> (v:math.Vec4) {
    if at<0 || at>len(data)-16 {return}
    v=intrinsics.unaligned_load((^math.Vec4)(uintptr(raw_data(data))+uintptr(at)))
    if components<4 {v.w=0}
    if components<2 {v.y,v.z=0,0}
    return
}

// x, y and z of a unit quaternion with w>=0, with its w again.
@(private)
stream_quat :: #force_inline proc "contextless" (v:math.Vec4) -> math.Vec4 {return {v.x,v.y,v.z,intrinsics.sqrt(max(1-v.x*v.x-v.y*v.y-v.z*v.z,0))}}
@(private)
stream_finish :: #force_inline proc "contextless" (v:math.Vec4,property:Property) -> math.Vec4 {return stream_quat(v) if property==.Rotation else v}

// Between two decoded samples. A rotation follows the short arc at constant speed, as slerp does:
// normalized lerp at an amount moved by the series, in 1-cos of the half angle and to its third
// term, of the amount at which it is slerp (under 1e-7 radians up to 50 degrees between samples);
// past STREAM_SLERP_COS, slerp itself. The terms of the series that depend only on the amount are
// those of every track of a pose.
@(private)
Stream_Terms :: struct {amount,cubic,second,third:f32}
@(private)
stream_terms :: #force_inline proc "contextless" (amount:f32) -> Stream_Terms {
    u:=(amount-.5)*(amount-.5)
    return {amount,amount*(amount-1)*(amount-.5),2.0/15+8.0/15*u,4.0/105+u*(62.0/315+136.0/315*u)}
}
@(private)
stream_rotation_mix :: #force_inline proc "contextless" (a,b:math.Vec4,terms:Stream_Terms) -> math.Vec4 {
    d:=a.x*b.x+a.y*b.y+a.z*b.z+a.w*b.w
    b:=b
    if d<0 {b=-b;d=-d}
    if d<STREAM_SLERP_COS {return stream_slerp(a,b,d,terms.amount)}
    x:=1-d
    x2:=x*x
    t:=terms.amount+terms.cubic*(x*(2.0/3)+x2*terms.second+x2*x*terms.third)
    q:=a+(b-a)*t
    length:=q.x*q.x+q.y*q.y+q.z*q.z+q.w*q.w
    return q*(1/intrinsics.sqrt(length)) if length>0 else {0,0,0,1}
}
@(private)
stream_mix :: #force_inline proc "contextless" (a,b:math.Vec4,amount:f32,property:Property) -> math.Vec4 {
    if property!=.Rotation {return a+(b-a)*amount}
    return stream_rotation_mix(a,b,stream_terms(amount))
}

// The value at a time of the Keys track held in the stream at `at`, as track_evaluate gives that
// of linear keys, and where the next one starts. A section that does not fit gives 0.
@(private)
stream_keyed :: proc "contextless" (data:[]u8,at,end:int,property:Property,time:f32) -> (value:math.Vec4,next:int) {
    if at<0 || end>len(data) || at>end-4 {return {},end}
    word:=intrinsics.unaligned_load((^u32)(uintptr(raw_data(data))+uintptr(at)))
    count,width:=int(word&(1<<28-1)),int(word>>28)
    next=at+4+4*count*(1+width)
    if count==0 || width==0 || width>4 || count>(end-at-4)/(4+4*width) {return {},end}
    times:=at+4
    values:=times+4*count
    key :: #force_inline proc "contextless" (data:[]u8,values,width,k:int) -> (v:math.Vec4) {
        for c in 0..<width {v[c]=intrinsics.unaligned_load((^f32)(uintptr(raw_data(data))+uintptr(values+4*(width*k+c))))}
        return
    }
    time_of :: #force_inline proc "contextless" (data:[]u8,times,k:int) -> f32 {return intrinsics.unaligned_load((^f32)(uintptr(raw_data(data))+uintptr(times+4*k)))}
    last:=count-1
    if !(time>time_of(data,times,0)) {return key(data,values,width,0),next}
    if time>=time_of(data,times,last) {return key(data,values,width,last),next}
    low,high:=0,last
    for high-low>1 {
        middle:=(low+high)>>1
        if time_of(data,times,middle)<=time {low=middle} else {high=middle}
    }
    ta,tb:=time_of(data,times,low),time_of(data,times,low+1)
    a,b:=key(data,values,width,low),key(data,values,width,low+1)
    span:=tb-ta
    if span<=0 {return b,next}
    t:=math.ease_apply(.Linear,(time-ta)/span)
    if property==.Rotation {return quat_vec4(math.quat_slerp(vec4_quat(a),vec4_quat(b),t)),next}
    return a+(b-a)*t,next
}

// Cosine of half the largest rotation between two samples that stream_mix follows by its series.
@(private) STREAM_SLERP_COS :: .9
@(private)
stream_slerp :: proc "contextless" (a,b:math.Vec4,d,amount:f32) -> math.Vec4 {
    angle:=cmath.acos(d)
    q:=a*cmath.sin((1-amount)*angle)+b*cmath.sin(amount*angle)
    length:=q.x*q.x+q.y*q.y+q.z*q.z+q.w*q.w
    return q*(1/intrinsics.sqrt(length)) if length>0 else a
}

// The sample a time falls after and how far toward the next, as every sampled track reads it.
@(private)
stream_position :: #force_inline proc "contextless" (h:Stream_Header,time:f32) -> (index:int,amount:f32) {
    last:=int(h.count)-1
    if last<=0 {return 0,0}
    position:=time*h.rate
    if !(position>0) {position=0}
    end:=h.duration*h.rate
    if position>=end || position>=f32(last) {return last-1,1}
    index=min(int(position),last-1)
    amount=position-f32(index)
    if index==last-1 {amount=min(amount/(end-f32(index)),1)}
    return
}

// Where one side of an interpolation reads its segment: its bit rates, the next range bytes and
// the bit of the next component of its sample.
@(private)
Stream_Cursor :: struct {bits,ranges,offset:int,ranged:bool}

@(private)
stream_cursor :: #force_inline proc "contextless" (data:[]u8,h:Stream_Header,sample:int) -> (c:Stream_Cursor,ok:bool) {
    low,high:=0,int(h.segments)-1
    for low<high {
        middle:=(low+high+1)>>1
        if int(stream_load(u32,data,int(h.table)+middle*size_of(Stream_Segment)))<=sample {low=middle} else {high=middle-1}
    }
    segment:=stream_load(Stream_Segment,data,int(h.table)+low*size_of(Stream_Segment))
    if int(segment.bits)>int(h.bytes)-int(h.animated) || int(segment.start)>sample {return}
    c.bits=int(segment.bits)
    c.ranges=c.bits+int(h.animated)
    c.offset=int(segment.samples)*8+(sample-int(segment.start))*int(segment.stride)
    c.ranged=h.segments>1
    return c,true
}

// The next Animated track's components at one side of the interpolation, moving past them.
@(private)
stream_unpack :: #force_inline proc "contextless" (data:[]u8,c:^Stream_Cursor,a,components:int,minimum,extent:math.Vec4) -> (value:math.Vec4,ok:bool) #no_bounds_check {
    at:=c.bits+a
    if at<0 || at>=len(data) {return}
    bits:=int(data[at])
    if bits==STREAM_RAW {
        for i in 0..<components {value[i]=transmute(f32)u32(stream_word(data,c.offset+32*i))}
        c.offset+=32*components
        return value,true
    }
    if bits>STREAM_MAX_BITS {return}
    low,span:[4]u8
    if c.ranged {
        if c.ranges<0 || c.ranges>len(data)-2*components {return}
        for i in 0..<components {low[i],span[i]=data[c.ranges+2*i],data[c.ranges+2*i+1]}
        c.ranges+=2*components
    } else if bits==0 {return}
    q:[4]u32
    if bits>0 {
        mask:=u64(1)<<uint(bits)-1
        if bits*components<=57 {
            word:=stream_word(data,c.offset)
            for i in 0..<components {q[i]=u32(word&mask);word>>=uint(bits)}
        } else {
            for i in 0..<components {q[i]=u32(stream_word(data,c.offset+bits*i)&mask)}
        }
        c.offset+=bits*components
    }
    return stream_dequantize(minimum,extent,low,span,bits,q,c.ranged),true
}
// stream_unpack of a track of three components, in scalars: the arithmetic of stream_dequantize.
@(private)
stream_unpack3 :: #force_inline proc "contextless" (data:[]u8,c:^Stream_Cursor,a:int,minimum,extent:math.Vec3) -> (v:math.Vec3,ok:bool) #no_bounds_check {
    at:=c.bits+a
    if at<0 || at>=len(data) {return}
    bits:=uint(data[at])
    if bits==STREAM_RAW {
        v={transmute(f32)u32(stream_word(data,c.offset)),transmute(f32)u32(stream_word(data,c.offset+32)),transmute(f32)u32(stream_word(data,c.offset+64))}
        c.offset+=96
        return v,true
    }
    if bits>STREAM_MAX_BITS {return}
    lx,ly,lz,sx,sy,sz:f32
    if c.ranged {
        if c.ranges<0 || c.ranges>len(data)-8 {return}
        r:=intrinsics.unaligned_load((^u64)(uintptr(raw_data(data))+uintptr(c.ranges)))
        lx,sx,ly,sy,lz,sz=f32(r&255),f32((r>>8)&255),f32((r>>16)&255),f32((r>>24)&255),f32((r>>32)&255),f32((r>>40)&255)
        c.ranges+=6
    } else if bits==0 {return}
    px,py,pz:f32
    if bits==0 {
        px,py,pz=(lx+sx*256)*(1.0/65535),(ly+sy*256)*(1.0/65535),(lz+sz*256)*(1.0/65535)
    } else {
        mask:=u64(1)<<bits-1
        qx,qy,qz:u64
        if bits*3<=57 {
            word:=stream_word(data,c.offset)
            qx,qy,qz=word&mask,(word>>bits)&mask,(word>>(2*bits))&mask
        } else {
            qx,qy,qz=stream_word(data,c.offset)&mask,stream_word(data,c.offset+int(bits))&mask,stream_word(data,c.offset+2*int(bits))&mask
        }
        c.offset+=3*int(bits)
        i:=stream_inverse[bits]
        px,py,pz=f32(qx)*i,f32(qy)*i,f32(qz)*i
        if c.ranged {px,py,pz=(lx+sx*px)*(1.0/255),(ly+sy*py)*(1.0/255),(lz+sz*pz)*(1.0/255)}
    }
    return {minimum.x+extent.x*px,minimum.y+extent.y*py,minimum.z+extent.z*pz},true
}

// Past the next Animated track at one side without reading it.
@(private)
stream_skip :: #force_inline proc "contextless" (data:[]u8,c:^Stream_Cursor,a,components:int) {
    at:=c.bits+a
    if at<0 || at>=len(data) {return}
    bits:=int(data[at])
    c.offset+=bits*components
    if bits!=STREAM_RAW && c.ranged {c.ranges+=2*components}
}


// Reads every track of a clip at one time in one pass: first those that hold still or keep their
// keys, in the clip's order, then the Animated ones block after block, STREAM_CHUNK at a time with
// their rotations four at a time. clip_reader_next gives each with its place in the clip.
Clip_Reader :: struct {
    data:[]u8, // the clip's stream, nil when it has none
    h:Stream_Header,
    a,b:Stream_Cursor,
    amount,time:f32,
    terms:Stream_Terms,
    tracks:[]Track, // the clip's
    keys:[]Keyframe, // the library's
    streams:[]u8,    // the library's, for a track another clip's stream holds
    next:int,        // the next track of the clip or, once animated, the next place of the order
    animated:bool,
    constant_at,range_at,keyed_at:int,
    count,at:int,    // what chunk holds and the next of it to give
    chunk:[STREAM_CHUNK]math.Vec4,
    slots:[STREAM_CHUNK]int, // the place in the clip of each value of chunk
    failed:bool,
}
STREAM_CHUNK :: 32

// Starts a reader on a stream without clearing its chunk, which it fills before reading it.
@(private)
stream_reader :: proc "contextless" (r:^Clip_Reader,data:[]u8,time:f32) {
    r.data,r.h,r.a,r.b,r.amount,r.time,r.terms={},{},{},{},0,time,{}
    r.tracks,r.keys,r.streams,r.next,r.animated,r.constant_at,r.range_at,r.keyed_at,r.count,r.at,r.failed=nil,nil,nil,0,false,0,0,0,0,0,false
    if data==nil {return}
    if len(data)<STREAM_HEADER {r.failed=true;return}
    h:=stream_load(Stream_Header,data,0)
    bytes:=int(h.bytes)
    if bytes>len(data)-STREAM_PADDING || bytes<stream_constants(h) || int(h.keys)<stream_constants(h) || int(h.order)<int(h.keys) || int(h.ranges)<int(h.order) || int(h.table)<int(h.ranges) || int(h.table)+int(h.segments)*size_of(Stream_Segment)>bytes || h.rotations>h.animated || h.threes>h.animated-h.rotations {r.failed=true;return}
    r.data,r.h=data,h
    r.constant_at,r.range_at,r.keyed_at=stream_constants(h),int(h.ranges),int(h.keys)
    if h.animated>0 {
        if h.segments==0 || h.count<2 {r.failed=true;return}
        index:int
        index,r.amount=stream_position(h,time)
        r.terms=stream_terms(r.amount)
        ok_a,ok_b:bool
        r.a,ok_a=stream_cursor(data,h,index)
        r.b,ok_b=stream_cursor(data,h,index+1)
        r.failed=!ok_a || !ok_b
    }
}

// The stream of a clip with its padding, or nil when it has none or it lies outside the library.
@(private)
clip_stream :: #force_inline proc "contextless" (lib:^Library,clip:Clip_Data) -> []u8 {
    if clip.stream_bytes==0 || lib.stream_bytes<0 || lib.stream_bytes>len(lib.streams)-STREAM_PADDING || int(clip.stream)>lib.stream_bytes || int(clip.stream_bytes)>lib.stream_bytes-int(clip.stream) {return nil}
    return lib.streams[clip.stream:][:int(clip.stream_bytes)+STREAM_PADDING]
}

// Starts a reader of every track of a clip at a time. A reader is declared without zeroing
// (`r:Clip_Reader=---`): this sets what it reads.
clip_reader :: proc "contextless" (r:^Clip_Reader,lib:^Library,clip:Clip,time:f32) {
    stream_reader(r,nil,time)
    if !clip_valid(lib,clip) || lib.key_count<0 || lib.key_count>len(lib.keys) {r.failed=true;return}
    data:=lib.clips[clip-1]
    if int(data.first_track)>lib.track_count || int(data.track_count)>lib.track_count-int(data.first_track) {r.failed=true;return}
    tracks:=lib.tracks[data.first_track:][:data.track_count]
    if data.stream_bytes>0 {
        stream:=clip_stream(lib,data)
        if stream==nil {r.failed=true;return}
        stream_reader(r,stream,time)
        if int(r.h.tracks)!=len(tracks) {r.failed=true}
    }
    r.tracks,r.keys=tracks,lib.keys[:lib.key_count]
    if lib.stream_bytes>=0 && lib.stream_bytes<=len(lib.streams) {r.streams=lib.streams}
}
// The next track of the clip: its place in the clip and its value, as clip_evaluate gives it.
// ok is false once every track was given, or when the stream does not match the clip.
clip_reader_next :: #force_inline proc "contextless" (r:^Clip_Reader) -> (track:int,value:math.Vec4,ok:bool) #no_bounds_check {
    if r.at>=r.count {
        if r.failed || !stream_fill(r) {return -1,{},false}
    }
    at:=r.at
    if at<0 || at>=STREAM_CHUNK {r.failed=true;return -1,{},false}
    r.at+=1
    return r.slots[at],r.chunk[at],true
}

// The value of a track that is no Animated one of the reader's stream: its keys, or the stream of
// another clip that holds it.
@(private)
stream_held :: proc "contextless" (r:^Clip_Reader,track:Track) -> math.Vec4 {
    if track.encoding==.Sampled {
        lib:=Library{streams=r.streams,stream_bytes=max(len(r.streams)-STREAM_PADDING,0)}
        return stream_evaluate(&lib,track,r.time)
    }
    keys:[]Keyframe
    if int(track.first)<=len(r.keys) && int(track.count)<=len(r.keys)-int(track.first) {keys=r.keys[track.first:][:track.count]}
    return track_evaluate(keys,track.property,r.time)
}

// Fills the chunk with the next values: tracks that hold still or keep keys, then the Animated
// ones of one block. False when nothing is left.
@(private)
stream_fill :: proc "contextless" (r:^Clip_Reader) -> bool #no_bounds_check {
    r.count,r.at=0,0
    data:=r.data
    tracks:=r.tracks
    if !r.animated {
        constant_at,keyed_at,next,count:=r.constant_at,r.keyed_at,r.next,0
        chunk,slots:=&r.chunk,&r.slots
        for next<len(tracks) && count<STREAM_CHUNK {
            i:=next
            next+=1
            property:=tracks[i].property
            value:math.Vec4
            if data==nil {value=stream_held(r,tracks[i])} else {
                kind,components:=stream_code(data,i)
                switch kind {
                case .Animated:continue
                case .Keys:
                    if components>0 {value,keyed_at=stream_keyed(data,keyed_at,int(r.h.order),property,r.time)} else {value=stream_held(r,tracks[i])}
                case .Default:value=stream_default(property)
                case .Constant:
                    value=stream_finish(stream_floats(data,constant_at,components),property)
                    constant_at+=4*components
                }
            }
            chunk[count],slots[count]=value,i
            count+=1
        }
        r.constant_at,r.keyed_at,r.next,r.count=constant_at,keyed_at,next,count
        if r.next<len(tracks) {return true}
        r.animated,r.next=true,0
        if r.count>0 {return true}
    }
    if data==nil || r.next>=int(r.h.animated) {return false}
    h:=r.h
    block_end:=int(h.rotations) if r.next<int(h.rotations) else int(h.rotations+h.threes) if r.next<int(h.rotations+h.threes) else int(h.animated)
    first:=r.next
    n:=min(STREAM_CHUNK,block_end-first)
    a,b:=r.a,r.b
    floats:=stream_animated_floats(h)
    range_at,amount:=r.range_at,r.amount
    if first<int(h.rotations) {
        // Rotations: unpacked one by one, then finished and mixed four at a time.
        ax,ay,az,bx,by,bz:[STREAM_CHUNK+3]f32=---,---,---,---,---,---
        for k in 0..<n {
            o:=first+k
            i:=stream_ordered(data,h,o)
            if i<0 || i>=len(tracks) {r.failed=true;return false}
            minimum,extent:=stream_floats(data,range_at,3),stream_floats(data,range_at+4*floats,3)
            range_at+=12
            p,ok_a:=stream_unpack3(data,&a,o,minimum.xyz,extent.xyz)
            q,ok_b:=stream_unpack3(data,&b,o,minimum.xyz,extent.xyz)
            if !ok_a || !ok_b {r.failed=true;return false}
            ax[k],ay[k],az[k],bx[k],by[k],bz[k]=p.x,p.y,p.z,q.x,q.y,q.z
            r.slots[k]=i
        }
        for k in n..<n+3 {ax[k],ay[k],az[k],bx[k],by[k],bz[k]=0,0,0,0,0,0}
        stream_mix_rotations(r.chunk[:],ax[:],ay[:],az[:],bx[:],by[:],bz[:],n,r.terms)
    } else if first<int(h.rotations+h.threes) {
        for k in 0..<n {
            o:=first+k
            i:=stream_ordered(data,h,o)
            if i<0 || i>=len(tracks) {r.failed=true;return false}
            minimum,extent:=stream_floats(data,range_at,3),stream_floats(data,range_at+4*floats,3)
            range_at+=12
            p,ok_a:=stream_unpack3(data,&a,o,minimum.xyz,extent.xyz)
            q,ok_b:=stream_unpack3(data,&b,o,minimum.xyz,extent.xyz)
            if !ok_a || !ok_b {r.failed=true;return false}
            v:=p+(q-p)*amount
            r.chunk[k],r.slots[k]=math.Vec4{v.x,v.y,v.z,0},i
        }
    } else {
        for k in 0..<n {
            o:=first+k
            i:=stream_ordered(data,h,o)
            if i<0 || i>=len(tracks) {r.failed=true;return false}
            property:=tracks[i].property
            _,components:=stream_code(data,i)
            minimum,extent:=stream_floats(data,range_at,components),stream_floats(data,range_at+4*floats,components)
            range_at+=4*components
            p,ok_a:=stream_unpack(data,&a,o,components,minimum,extent)
            q,ok_b:=stream_unpack(data,&b,o,components,minimum,extent)
            if !ok_a || !ok_b {r.failed=true;return false}
            r.chunk[k],r.slots[k]=stream_mix(stream_finish(p,property),stream_finish(q,property),amount,property),i
        }
    }
    r.a,r.b,r.range_at,r.next,r.count=a,b,range_at,first+n,n
    return true
}

// The arithmetic of stream_quat and stream_rotation_mix, four rotations at a time, into out.
@(private)
stream_mix_rotations :: proc "contextless" (out:[]math.Vec4,ax,ay,az,bx,by,bz:[]f32,n:int,terms:Stream_Terms) #no_bounds_check {
    F :: Stream_F4
    for g:=0;g<n;g+=4 {
        x0,y0,z0:=F{ax[g],ax[g+1],ax[g+2],ax[g+3]},F{ay[g],ay[g+1],ay[g+2],ay[g+3]},F{az[g],az[g+1],az[g+2],az[g+3]}
        x1,y1,z1:=F{bx[g],bx[g+1],bx[g+2],bx[g+3]},F{by[g],by[g+1],by[g+2],by[g+3]},F{bz[g],bz[g+1],bz[g+2],bz[g+3]}
        w0:=simd.sqrt(simd.max(F(1)-x0*x0-y0*y0-z0*z0,F(0)))
        w1:=simd.sqrt(simd.max(F(1)-x1*x1-y1*y1-z1*z1,F(0)))
        d:=x0*x1+y0*y1+z0*z1+w0*w1
        flip:=simd.lanes_lt(d,F(0))
        x1,y1,z1,w1=simd.select(flip,-x1,x1),simd.select(flip,-y1,y1),simd.select(flip,-z1,z1),simd.select(flip,-w1,w1)
        d=simd.abs(d)
        x:=F(1)-d
        x2:=x*x
        t:=F(terms.amount)+F(terms.cubic)*(x*F(2.0/3)+x2*F(terms.second)+x2*x*F(terms.third))
        qx,qy,qz,qw:=x0+(x1-x0)*t,y0+(y1-y0)*t,z0+(z1-z0)*t,w0+(w1-w0)*t
        length:=qx*qx+qy*qy+qz*qz+qw*qw
        positive:=simd.lanes_gt(length,F(0))
        inverse:=F(1)/simd.sqrt(simd.select(positive,length,F(1)))
        qx,qy,qz,qw=simd.select(positive,qx*inverse,F(0)),simd.select(positive,qy*inverse,F(0)),simd.select(positive,qz*inverse,F(0)),simd.select(positive,qw*inverse,F(1))
        lx,ly,lz,lw,ld:=simd.to_array(qx),simd.to_array(qy),simd.to_array(qz),simd.to_array(qw),simd.to_array(d)
        for lane in 0..<min(4,n-g) {
            k:=g+lane
            out[k]=ld[lane]<STREAM_SLERP_COS ? stream_rotation_mix(stream_quat({ax[k],ay[k],az[k],0}),stream_quat({bx[k],by[k],bz[k],0}),terms) : math.Vec4{lx[lane],ly[lane],lz[lane],lw[lane]}
        }
    }
}

// Every track of a clip at a time into out, by its place in the clip. False when out is shorter
// than the clip's tracks or its stream does not match them.
clip_sample :: proc "contextless" (lib:^Library,clip:Clip,time:f32,out:[]math.Vec4) -> bool #no_bounds_check {
    if !clip_valid(lib,clip) || len(out)<len(clip_tracks(lib,clip)) {return false}
    r:Clip_Reader=---
    clip_reader(&r,lib,clip,time)
    for {
        i,value,ok:=clip_reader_next(&r)
        if !ok {break}
        if i>=0 && i<len(out) {out[i]=value}
    }
    return !r.failed
}

// The value of one sampled track at a time, as clip_evaluate gives it: `first` is the byte of
// lib.streams its clip's stream starts at and `count` its place among the clip's tracks.
stream_evaluate :: proc "contextless" (lib:^Library,track:Track,time:f32) -> math.Vec4 {
    if lib.stream_bytes<0 || lib.stream_bytes>len(lib.streams)-STREAM_PADDING || int(track.first)>lib.stream_bytes-STREAM_HEADER {return {}}
    data:=lib.streams[track.first:]
    h:=stream_load(Stream_Header,data,0)
    if int(h.bytes)>lib.stream_bytes-int(track.first) || int(track.count)>=int(h.tracks) || stream_constants(h)>int(h.bytes) {return {}}
    data=data[:int(h.bytes)+STREAM_PADDING]
    target:=int(track.count)
    kind,components:=stream_code(data,target)
    if components!=stream_components(track.property) {return {}}
    switch kind {
    case .Keys:
        if int(h.keys)<stream_constants(h) || int(h.order)<int(h.keys) || int(h.order)>int(h.bytes) {return {}}
        at:=int(h.keys)
        for i in 0..<target {
            if kind_i,components_i:=stream_code(data,i);kind_i!=.Keys || components_i==0 {continue}
            if at<0 || at>int(h.order)-4 {return {}}
            _,at=stream_keyed(data,at,int(h.order),.Float,0)
        }
        value,_:=stream_keyed(data,at,int(h.order),track.property,time)
        return value
    case .Default:return stream_default(track.property)
    case .Constant:
        at:=stream_constants(h)
        for i in 0..<target {if kind_i,components_i:=stream_code(data,i);kind_i==.Constant {at+=4*components_i}}
        return stream_finish(stream_floats(data,at,components),track.property)
    case .Animated:
    }
    r:Clip_Reader=---
    stream_reader(&r,data,time)
    if r.failed {return {}}
    // Past the Animated tracks before it in the order: their widths and bit rates.
    o:=0
    for o<int(h.animated) && stream_ordered(data,h,o)!=target {
        at:=stream_ordered(data,h,o)
        if at<0 || at>=int(h.tracks) {return {}}
        _,components_o:=stream_code(data,at)
        stream_skip(data,&r.a,o,components_o);stream_skip(data,&r.b,o,components_o)
        r.range_at+=4*components_o
        o+=1
    }
    if o>=int(h.animated) {return {}}
    floats:=stream_animated_floats(h)
    minimum,extent:=stream_floats(data,r.range_at,components),stream_floats(data,r.range_at+4*floats,components)
    p,ok_a:=stream_unpack(data,&r.a,o,components,minimum,extent)
    q,ok_b:=stream_unpack(data,&r.b,o,components,minimum,extent)
    if !ok_a || !ok_b {return {}}
    return stream_mix(stream_finish(p,track.property),stream_finish(q,track.property),r.amount,track.property)
}
