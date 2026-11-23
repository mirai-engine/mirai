package mirai_pcg

import "base:runtime"
import "core:simd"

// Scalar fields for procedural generation: a text expression (`fbm2(x,z,5,2,0.5) * 40 + height`)
// compiles to flat bytecode over at most MAX_SLOTS registers, and the bytecode runs over tiles of
// TILE samples, one operation over the whole tile at a time, W lanes at a time. The arithmetic is
// IEEE f32 without fused products, comparisons pick lanes instead of the min and max of the
// target, and the hashing is integer, so the same program and inputs give the same bits on ARM64
// and x64. NaN results come out as one canonical NaN.

TILE :: 256 // samples in a tile
MAX_SLOTS :: 16 // registers of a program; each one is a tile of f32 in Field_Scratch
W :: 4 // lanes of the evaluator
MAX_OCTAVES :: 8
MAX_INPUT_INDEX :: 255 // highest i of mask(i) and ecotope(i)
MAX_SOURCE :: 64*1024 // bytes of an expression
MAX_DEPTH :: 64 // nesting of parentheses, calls and unary minus
MAX_NODES :: 4096 // operations before dead code is removed, with fractals unrolled
MAX_CODE :: 1024 // instructions of a program
MAX_LETS :: 64

V4 :: #simd[W]f32
I4 :: #simd[W]i32
U4 :: #simd[W]u32

// LUT-free lattice hashing: each axis multiplies its cell by a prime, so the next cell is one
// addition away, and the combined value is mixed once.
PRIME_X :: u32(0xF797C5C7)
PRIME_Y :: u32(0x6C060C89)
PRIME_Z :: u32(0x465FD04F)
HASH_MUL :: u32(0xB7E0A5F5)

CANONICAL_NAN :: u32(0x7fc00000)

Field_Op :: enum u8 {
    Const,      // dst = imm[0]
    Input,      // dst = the input `input` (with `index` for masks and ecotopes), 0 if absent
    Neg,
    Abs,
    Sqrt,
    Add,
    Sub,
    Mul,
    Div,
    Min,        // a<b ? a : b
    Max,        // b<a ? a : b
    Clamp,      // min(max(x,lo),hi)
    Lerp,       // a+(b-a)*t
    Smoothstep, // (e0,e1,x)
    Select,     // cond>0 ? a : b
    Value2,     // (x,z)
    Value3,     // (x,y,z)
    Perlin2,
    Perlin3,
    Cellular2,  // distance to the nearest feature point, about 0 to 1
    Cellular3,
}

OP_ARITY :: [Field_Op]u8{
    .Const=0, .Input=0, .Neg=1, .Abs=1, .Sqrt=1, .Add=2, .Sub=2, .Mul=2, .Div=2, .Min=2, .Max=2,
    .Clamp=3, .Lerp=3, .Smoothstep=3, .Select=3, .Value2=2, .Value3=3, .Perlin2=2, .Perlin3=3,
    .Cellular2=2, .Cellular3=3,
}

Field_Input :: enum u8 {X, Y, Z, Height, Slope, Occupancy, Mask, Ecotope}

// One instruction. Argument i reads imm[i] in every lane when bit i of imm_mask is set, else
// slot args[i]. dst may be one of the argument slots.
Field_Instr :: struct {
    op:Field_Op,
    dst:u8,
    args:[3]u8,
    imm_mask:u8,
    input:Field_Input,
    index:u8,
    seed:u32,
    imm:[3]f32,
}

Field_Program :: struct {
    code:[]Field_Instr,
    output:u8,   // slot that holds the result
    slots:u8,    // slots the code uses
    hash:u64,    // content hash of the code: equal programs, equal hash on every platform
    allocator:runtime.Allocator,
}

// The registers of an evaluation; the caller owns it and hands it in 64-byte aligned (`new`
// aligns it). One per thread.
Field_Scratch :: struct #align(64) {
    slots:[MAX_SLOTS][TILE/W]V4,
    imm:[3]V4,
}

// Samples of a tile. An empty slice reads as 0; a slice that is not empty holds at least the
// samples evaluated.
Field_Inputs :: struct {
    x,y,z:[]f32,
    height,slope,occupancy:[]f32,
    masks:[][]f32,    // mask(i) reads masks[i]
    ecotopes:[][]f32, // ecotope(i) reads ecotopes[i]
}

Field_Error_Kind :: enum u8 {
    None,
    Syntax,
    Unknown_Function,
    Unknown_Identifier,
    Arity,
    Non_Finite,    // a number or a constant part of the expression is NaN or infinite
    Not_Constant,  // octaves, lacunarity, gain, seeds and input indices must be constants
    Out_Of_Range,
    Slot_Overflow, // more than MAX_SLOTS values are alive at once
    Too_Large,     // over MAX_SOURCE, MAX_DEPTH, MAX_NODES, MAX_CODE or MAX_LETS
    Out_Of_Memory,
}

// offset and length are bytes of the source the error is about.
Field_Error :: struct {
    kind:Field_Error_Kind,
    offset:int,
    length:int,
    message:string,
}

Field_Eval_Error :: enum u8 {
    None,
    Invalid_Program,    // instructions out of range or a slot read before it is written
    Bad_Count,          // the samples are not 1 to TILE
    Input_Too_Short,    // an input that is not empty holds fewer samples than evaluated
    Scratch_Misaligned, // the scratch is nil or not 64-byte aligned
}

field_program_destroy :: proc(program:^Field_Program) {
    if program.code!=nil {delete(program.code,program.allocator)}
    program^={}
}

// Content hash of a program's code, output and slots.
field_program_hash :: proc "contextless" (code:[]Field_Instr,output,slots:u8) -> u64 {
    h:=mix64(0x6d6972616970636,u64(len(code)))
    for instr in code {
        word:=u64(instr.op)|u64(instr.dst)<<8|u64(instr.args[0])<<16|u64(instr.args[1])<<24|
            u64(instr.args[2])<<32|u64(instr.imm_mask)<<40|u64(instr.input)<<48|u64(instr.index)<<56
        h=mix64(h,word)
        h=mix64(h,u64(instr.seed)|u64(transmute(u32)instr.imm[0])<<32)
        h=mix64(h,u64(transmute(u32)instr.imm[1])|u64(transmute(u32)instr.imm[2])<<32)
    }
    return mix64(h,u64(output)|u64(slots)<<8)
}

@(private)
mix64 :: #force_inline proc "contextless" (h,word:u64) -> u64 {
    x:=(h~word)*0x9e3779b97f4a7c15
    x=(x~(x>>30))*0xbf58476d1ce4e5b9
    x=(x~(x>>27))*0x94d049bb133111eb
    return x~(x>>31)
}

// Kernels, shared by the evaluator and constant folding so both give the same bits.

@(private) COORD_LIMIT :: f32(2147483520) // largest f32 below 2^31
@(private) INV_SQRT2 :: f32(0.70710678)

@(private)
vmin :: #force_inline proc "contextless" (a,b:V4) -> V4 {return simd.select(simd.lanes_lt(a,b),a,b)}
@(private)
vmax :: #force_inline proc "contextless" (a,b:V4) -> V4 {return simd.select(simd.lanes_lt(b,a),a,b)}
@(private)
vabs :: #force_inline proc "contextless" (a:V4) -> V4 {return transmute(V4)(transmute(U4)a&U4(0x7fffffff))}
@(private)
vlerp :: #force_inline proc "contextless" (a,b,t:V4) -> V4 {return a+(b-a)*t}
@(private)
vfade :: #force_inline proc "contextless" (t:V4) -> V4 {return t*t*t*(t*(t*6-15)+10)}
@(private)
vcanonical :: #force_inline proc "contextless" (a:V4) -> V4 {
    return simd.select(simd.lanes_ne(a,a),transmute(V4)U4(CANONICAL_NAN),a)
}
@(private)
vsmoothstep :: #force_inline proc "contextless" (e0,e1,x:V4) -> V4 {
    t:=vmax(vmin((x-e0)/(e1-e0),1),0)
    return t*t*(3-2*t)
}

// The lattice cell of a coordinate and the position inside it. NaN and infinities count as 0
// and the coordinate is clamped to the i32 range before it is converted.
@(private)
vcell :: #force_inline proc "contextless" (p:V4,prime:u32) -> (primed:U4,frac:V4) {
    s:=simd.select(simd.lanes_eq(p-p,0),p,V4(0))
    s=vmax(vmin(s,COORD_LIMIT),-COORD_LIMIT)
    f:=simd.floor(s)
    return transmute(U4)cast(I4)f*U4(prime),s-f
}
@(private)
vhash :: #force_inline proc "contextless" (seed:u32,xp,yp,zp:U4) -> U4 {
    h:=(U4(seed)~xp~yp~zp)*U4(HASH_MUL)
    return h~simd.shr(h,U4(15))
}
@(private)
vbit :: #force_inline proc "contextless" (h:U4,bit:u32) -> U4 {return simd.lanes_ne(h&U4(u32(1)<<bit),U4(0))}
// -1 to 1 from the whole hash.
@(private)
vunit :: #force_inline proc "contextless" (h:U4) -> V4 {return cast(V4)transmute(I4)h*(1.0/2147483648.0)}
// 0 to 1 from 16 bits.
@(private)
vbits16 :: #force_inline proc "contextless" (h:U4) -> V4 {return cast(V4)transmute(I4)(h&U4(0xffff))*(1.0/65536.0)}
@(private)
vbits10 :: #force_inline proc "contextless" (h:U4,shift:u32) -> V4 {
    return cast(V4)transmute(I4)(simd.shr(h,U4(shift))&U4(0x3ff))*(1.0/1024.0)
}

@(private)
kernel_value2 :: proc "contextless" (x,z:V4,seed:u32) -> V4 {
    x0,fx:=vcell(x,PRIME_X)
    z0,fz:=vcell(z,PRIME_Z)
    x1,z1:=x0+U4(PRIME_X),z0+U4(PRIME_Z)
    u,v:=vfade(fx),vfade(fz)
    low:=vlerp(vunit(vhash(seed,x0,0,z0)),vunit(vhash(seed,x1,0,z0)),u)
    high:=vlerp(vunit(vhash(seed,x0,0,z1)),vunit(vhash(seed,x1,0,z1)),u)
    return vlerp(low,high,v)
}
@(private)
kernel_value3 :: proc "contextless" (x,y,z:V4,seed:u32) -> V4 {
    x0,fx:=vcell(x,PRIME_X)
    y0,fy:=vcell(y,PRIME_Y)
    z0,fz:=vcell(z,PRIME_Z)
    x1,y1,z1:=x0+U4(PRIME_X),y0+U4(PRIME_Y),z0+U4(PRIME_Z)
    u,v,w:=vfade(fx),vfade(fy),vfade(fz)
    near:=vlerp(vlerp(vunit(vhash(seed,x0,y0,z0)),vunit(vhash(seed,x1,y0,z0)),u),
        vlerp(vunit(vhash(seed,x0,y1,z0)),vunit(vhash(seed,x1,y1,z0)),u),v)
    far:=vlerp(vlerp(vunit(vhash(seed,x0,y0,z1)),vunit(vhash(seed,x1,y0,z1)),u),
        vlerp(vunit(vhash(seed,x0,y1,z1)),vunit(vhash(seed,x1,y1,z1)),u),v)
    return vlerp(near,far,w)
}

// One of four axis and four diagonal unit directions, picked by bits 28 to 31.
@(private)
vgrad2 :: #force_inline proc "contextless" (h:U4,dx,dz:V4) -> V4 {
    a:=simd.select(vbit(h,31),-dx,dx)
    b:=simd.select(vbit(h,30),-dz,dz)
    return simd.select(vbit(h,29),(a+b)*INV_SQRT2,simd.select(vbit(h,28),b,a))
}
// One of the twelve directions from the center of a cube to its edges, by bits 28 to 31.
@(private)
vgrad3 :: #force_inline proc "contextless" (h:U4,dx,dy,dz:V4) -> V4 {
    top:=simd.shr(h,U4(28))
    a:=simd.select(simd.lanes_lt(top,U4(8)),dx,dy)
    edge_x:=simd.lanes_eq(top,U4(12))|simd.lanes_eq(top,U4(14))
    b:=simd.select(simd.lanes_lt(top,U4(4)),dy,simd.select(edge_x,dx,dz))
    return simd.select(vbit(h,28),-a,a)+simd.select(vbit(h,29),-b,b)
}
@(private)
kernel_perlin2 :: proc "contextless" (x,z:V4,seed:u32) -> V4 {
    x0,dx:=vcell(x,PRIME_X)
    z0,dz:=vcell(z,PRIME_Z)
    x1,z1:=x0+U4(PRIME_X),z0+U4(PRIME_Z)
    u,v:=vfade(dx),vfade(dz)
    low:=vlerp(vgrad2(vhash(seed,x0,0,z0),dx,dz),vgrad2(vhash(seed,x1,0,z0),dx-1,dz),u)
    high:=vlerp(vgrad2(vhash(seed,x0,0,z1),dx,dz-1),vgrad2(vhash(seed,x1,0,z1),dx-1,dz-1),u)
    return vlerp(low,high,v)*1.41421356
}
@(private)
kernel_perlin3 :: proc "contextless" (x,y,z:V4,seed:u32) -> V4 {
    x0,dx:=vcell(x,PRIME_X)
    y0,dy:=vcell(y,PRIME_Y)
    z0,dz:=vcell(z,PRIME_Z)
    x1,y1,z1:=x0+U4(PRIME_X),y0+U4(PRIME_Y),z0+U4(PRIME_Z)
    ex,ey,ez:=dx-1,dy-1,dz-1
    u,v,w:=vfade(dx),vfade(dy),vfade(dz)
    near:=vlerp(vlerp(vgrad3(vhash(seed,x0,y0,z0),dx,dy,dz),vgrad3(vhash(seed,x1,y0,z0),ex,dy,dz),u),
        vlerp(vgrad3(vhash(seed,x0,y1,z0),dx,ey,dz),vgrad3(vhash(seed,x1,y1,z0),ex,ey,dz),u),v)
    far:=vlerp(vlerp(vgrad3(vhash(seed,x0,y0,z1),dx,dy,ez),vgrad3(vhash(seed,x1,y0,z1),ex,dy,ez),u),
        vlerp(vgrad3(vhash(seed,x0,y1,z1),dx,ey,ez),vgrad3(vhash(seed,x1,y1,z1),ex,ey,ez),u),v)
    return vlerp(near,far,w)
}

// One feature point per cell, kept within JITTER of the cell center so the nearest one is always
// among the 3x3 (3x3x3) cells around the sample.
@(private) JITTER :: f32(0.45)
@(private) JITTER_BASE :: f32(0.275)

@(private)
kernel_cellular2 :: proc "contextless" (x,z:V4,seed:u32) -> V4 {
    xc,fx:=vcell(x,PRIME_X)
    zc,fz:=vcell(z,PRIME_Z)
    best:=V4(8)
    for oz in -1..=1 {
        zp:=zc+U4(u32(i32(oz))*PRIME_Z)
        for ox in -1..=1 {
            h:=vhash(seed,xc+U4(u32(i32(ox))*PRIME_X),0,zp)
            ddx:=(f32(ox)+JITTER_BASE+vbits16(h)*JITTER)-fx
            ddz:=(f32(oz)+JITTER_BASE+vbits16(simd.shr(h,U4(16)))*JITTER)-fz
            best=vmin(best,ddx*ddx+ddz*ddz)
        }
    }
    return simd.sqrt(best)
}
@(private)
kernel_cellular3 :: proc "contextless" (x,y,z:V4,seed:u32) -> V4 {
    xc,fx:=vcell(x,PRIME_X)
    yc,fy:=vcell(y,PRIME_Y)
    zc,fz:=vcell(z,PRIME_Z)
    best:=V4(8)
    for oz in -1..=1 {
        zp:=zc+U4(u32(i32(oz))*PRIME_Z)
        for oy in -1..=1 {
            yp:=yc+U4(u32(i32(oy))*PRIME_Y)
            for ox in -1..=1 {
                h:=vhash(seed,xc+U4(u32(i32(ox))*PRIME_X),yp,zp)
                ddx:=(f32(ox)+JITTER_BASE+vbits10(h,0)*JITTER)-fx
                ddy:=(f32(oy)+JITTER_BASE+vbits10(h,10)*JITTER)-fy
                ddz:=(f32(oz)+JITTER_BASE+vbits10(h,20)*JITTER)-fz
                best=vmin(best,ddx*ddx+ddy*ddy+ddz*ddz)
            }
        }
    }
    return simd.sqrt(best)
}

// One operation on W lanes; constant folding runs it on splats.
@(private)
kernel_apply :: proc "contextless" (op:Field_Op,a,b,c:V4,seed:u32) -> V4 {
    switch op {
    case .Const, .Input: return a
    case .Neg:        return -a
    case .Abs:        return vabs(a)
    case .Sqrt:       return simd.sqrt(a)
    case .Add:        return a+b
    case .Sub:        return a-b
    case .Mul:        return a*b
    case .Div:        return a/b
    case .Min:        return vmin(a,b)
    case .Max:        return vmax(a,b)
    case .Clamp:      return vmin(vmax(a,b),c)
    case .Lerp:       return vlerp(a,b,c)
    case .Smoothstep: return vsmoothstep(a,b,c)
    case .Select:     return simd.select(simd.lanes_lt(V4(0),a),b,c)
    case .Value2:     return kernel_value2(a,b,seed)
    case .Value3:     return kernel_value3(a,b,c,seed)
    case .Perlin2:    return kernel_perlin2(a,b,seed)
    case .Perlin3:    return kernel_perlin3(a,b,c,seed)
    case .Cellular2:  return kernel_cellular2(a,b,seed)
    case .Cellular3:  return kernel_cellular3(a,b,c,seed)
    }
    return a
}

op_arity :: proc "contextless" (op:Field_Op) -> int {
    arity:=OP_ARITY
    return int(arity[op])
}

// make that returns false instead of a slice when the allocator has no memory.
@(private)
slice_alloc :: proc($T:typeid/[]$E,count:int,allocator:runtime.Allocator) -> (T,bool) {
    s,err:=make(T,count,allocator)
    if err!=nil || len(s)!=count {delete(s,allocator);return nil,false}
    return s,true
}
