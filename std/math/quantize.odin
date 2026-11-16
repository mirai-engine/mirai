package mirai_math

import "core:math"
import "core:math/linalg"

// Compact encodings for assets and for the network. Every pack has the
// unpack that undoes it up to the stated precision.

// A value of the range low..high as an integer of `bits` bits, 1 to 32: 0 is
// low, the largest integer is high, and values outside are clamped. The
// error after dequantize is at most half a step: (high-low)/(2^bits-1)/2.
quantize :: proc "contextless" (value,low,high:f32,bits:uint) -> u32 {
    steps:=f64(u64(1)<<bits-1)
    if !(high>low) {return 0}
    return u32(clamp((f64(value)-f64(low))/(f64(high)-f64(low)),0,1)*steps+0.5)
}
dequantize :: proc "contextless" (quantized:u32,low,high:f32,bits:uint) -> f32 {
    steps:=f64(u64(1)<<bits-1)
    return f32(f64(low)+f64(quantized)/steps*(f64(high)-f64(low)))
}

// 0..1 in 8 or 16 bits, and -1..1 in 8 or 16 bits with 0 exact.
unorm8_pack :: proc "contextless" (value:f32) -> u8 {return u8(math.round(clamp(value,0,1)*255))}
unorm8_unpack :: proc "contextless" (packed:u8) -> f32 {return f32(packed)*(1.0/255)}
unorm16_pack :: proc "contextless" (value:f32) -> u16 {return u16(math.round(clamp(value,0,1)*65535))}
unorm16_unpack :: proc "contextless" (packed:u16) -> f32 {return f32(packed)*(1.0/65535)}
snorm8_pack :: proc "contextless" (value:f32) -> i8 {return i8(math.round(clamp(value,-1,1)*127))}
snorm8_unpack :: proc "contextless" (packed:i8) -> f32 {return max(f32(packed)*(1.0/127),-1)}
snorm16_pack :: proc "contextless" (value:f32) -> i16 {return i16(math.round(clamp(value,-1,1)*32767))}
snorm16_unpack :: proc "contextless" (packed:i16) -> f32 {return max(f32(packed)*(1.0/32767),-1)}

// IEEE half floats: about three decimal digits, up to 65504.
half_pack :: proc "contextless" (value:f32) -> u16 {return transmute(u16)f16(value)}
half_unpack :: proc "contextless" (packed:u16) -> f32 {return f32(transmute(f16)packed)}

// A unit vector as a point of the square -1..1: the octahedron unfolded.
octahedral_encode :: proc "contextless" (n:Vec3) -> Vec2 {
    sum:=abs(n.x)+abs(n.y)+abs(n.z)
    if sum<1e-12 {return {}}
    p:=Vec2{n.x/sum,n.y/sum}
    if n.z<0 {
        sx:f32=1 if p.x>=0 else -1
        sy:f32=1 if p.y>=0 else -1
        p={(1-abs(p.y))*sx,(1-abs(p.x))*sy}
    }
    return p
}
octahedral_decode :: proc "contextless" (p:Vec2) -> Vec3 {
    n:=Vec3{p.x,p.y,1-abs(p.x)-abs(p.y)}
    if n.z<0 {
        sx:f32=1 if n.x>=0 else -1
        sy:f32=1 if n.y>=0 else -1
        n.x,n.y=(1-abs(p.y))*sx,(1-abs(p.x))*sy
    }
    return n/math.sqrt(n.x*n.x+n.y*n.y+n.z*n.z)
}
// The packed normal of a mesh vertex: octahedral, 16 signed bits per axis, X
// in the low half. The shaders unpack the same layout.
normal_pack :: proc "contextless" (n:Vec3) -> u32 {
    p:=octahedral_encode(n)
    return u32(u16(snorm16_pack(p.x)))|u32(u16(snorm16_pack(p.y)))<<16
}
normal_unpack :: proc "contextless" (packed:u32) -> Vec3 {
    return octahedral_decode({f32(i16(u16(packed&0xffff)))/32767,f32(i16(u16(packed>>16)))/32767})
}
// The packed tangent of a mesh vertex: octahedral, 15 bits per axis (the
// value times 16383, plus 16384), X in bits 0-14 and Y in bits 15-29, and in
// bit 30 the sign of the bitangent, which MikkTSpace takes as sign *
// cross(normal, tangent). The shaders unpack the same layout.
tangent_pack :: proc "contextless" (t:Vec3,sign:f32) -> u32 {
    p:=octahedral_encode(t)
    axis :: proc "contextless" (v:f32) -> u32 {return u32(i32(math.round(clamp(v,-1,1)*16383))+16384)}
    return axis(p.x)|axis(p.y)<<15|(u32(1) if sign<0 else 0)<<30
}
tangent_unpack :: proc "contextless" (packed:u32) -> (tangent:Vec3,sign:f32) {
    axis :: proc "contextless" (v:u32) -> f32 {return f32(i32(v&0x7fff)-16384)/16383}
    return octahedral_decode({axis(packed),axis(packed>>15)}),-1 if packed&(1<<30)!=0 else 1
}

// The direction of a packed normal (normal_pack) in integers, not unit
// length: the octahedron folded back as octahedral_decode does, the same on
// every machine. Which axis it is furthest from is decided by them, so a
// shader and the CPU agree on it at the edges between those regions.
normal_direction :: proc "contextless" (packed:u32) -> [3]i32 {
    x:=max(i32(i16(u16(packed&0xffff))),-32767)
    y:=max(i32(i16(u16(packed>>16))),-32767)
    z:=32767-abs(x)-abs(y)
    if z<0 {x,y=(32767-abs(y))*(1 if x>=0 else -1),(32767-abs(x))*(1 if y>=0 else -1)}
    return {x,y,z}
}

// The axes a tangent turns in about a packed normal: one across the axis the
// normal is furthest from, and the one across both.
tangent_axes :: proc "contextless" (normal_packed:u32) -> (normal,along,across:Vec3) {
    d:=normal_direction(normal_packed)
    least:=0
    if abs(d.y)<abs(d[least]) {least=1}
    if abs(d.z)<abs(d[least]) {least=2}
    normal=normal_unpack(normal_packed)
    axis:Vec3
    axis[least]=1
    along=linalg.normalize(linalg.cross(axis,normal))
    across=linalg.cross(normal,along)
    return
}

// A tangent in 16 bits about the normal of its vertex: its angle in the plane
// across that normal (tangent_axes) in bits 0-14 and the sign of its
// bitangent in bit 15. 15 bits turn a tangent by at most 0.006 degrees.
tangent_angle_pack :: proc "contextless" (normal_packed:u32,tangent:Vec3,sign:f32) -> u16 {
    _,along,across:=tangent_axes(normal_packed)
    angle:=math.atan2(linalg.dot(tangent,across),linalg.dot(tangent,along))
    turns:=angle/math.TAU
    turns-=math.floor(turns)
    return u16(u32(math.round(turns*32768))&0x7fff)|(u16(0x8000) if sign<0 else 0)
}
tangent_angle_unpack :: proc "contextless" (normal_packed:u32,packed:u16) -> (tangent:Vec3,sign:f32) {
    _,along,across:=tangent_axes(normal_packed)
    angle:=f32(packed&0x7fff)*(math.TAU/32768)
    return along*math.cos(angle)+across*math.sin(angle),-1 if packed&0x8000!=0 else 1
}

// A rotation in 2+3*bits bits: which component is largest, and the other
// three, since the four squares add up to 1. The largest is taken as
// positive, which is the same rotation. A component of 0 is exact, so the
// identity survives. With 10 bits per component it fits in 32 bits with an
// error under 0.3 degrees; bits goes from 2 to 20.
quat_pack :: proc "contextless" (q:Quat,bits:uint=10) -> u64 {
    components:=[4]f32{q.x,q.y,q.z,q.w}
    largest:=0
    for component,i in components {
        if abs(component)>abs(components[largest]) {largest=i}
    }
    sign:f32=-1 if components[largest]<0 else 1
    levels:=f32(u64(1)<<(bits-1)-1)
    packed:=u64(largest)
    for component,i in components {
        if i==largest {continue}
        level:=math.round(clamp(component*sign*math.SQRT_TWO,-1,1)*levels)+levels
        packed=packed<<bits|u64(level)
    }
    return packed
}
quat_unpack :: proc "contextless" (packed:u64,bits:uint=10) -> Quat {
    mask:=u64(1)<<bits-1
    levels:=f32(u64(1)<<(bits-1)-1)
    largest:=int(packed>>(3*bits)&3)
    components:[4]f32
    sum:f32
    slot:=uint(3)
    for &component,i in components {
        if i==largest {continue}
        slot-=1
        component=(f32(packed>>(slot*bits)&mask)-levels)/levels*(1/math.SQRT_TWO)
        sum+=component*component
    }
    components[largest]=math.sqrt(max(1-sum,0))
    q:=Quat(quaternion(w=components[3],x=components[0],y=components[1],z=components[2]))
    // Only bits that no rotation packs to add up to more than 1.
    return linalg.normalize(q) if sum>1 else q
}
