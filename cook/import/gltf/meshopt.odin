package gltf

import "core:math"
import cg "vendor:cgltf"
import importer "mirai:cook/import"

// The decoder of EXT_meshopt_compression
// (github.com/KhronosGroup/glTF/tree/main/extensions/2.0/Vendor/EXT_meshopt_compression)
// for attributes: a compressed buffer view is decoded once into scratch memory
// and handed to cgltf as the data of that view, so accessors read it as any
// other. The codec is meshoptimizer's (vertexcodec.cpp and vertexfilter.cpp,
// MIT) at version 0, with the quaternion and exponential filters that clips
// written by glTF-Transform use. Compressed indices and the octahedral filter
// of normals are refused.

@(private="file")
VERTEX_HEADER :: 0xa0
@(private="file")
BLOCK_BYTES :: 8192
@(private="file")
BLOCK_MAX :: 256
@(private="file")
GROUP :: 16
@(private="file")
TAIL_MIN :: 32

meshopt_decode :: proc(r:^importer.Reader,data:^cg.data) -> bool {
    for &view in data.buffer_views {
        if !view.has_meshopt_compression {continue}
        m:=view.meshopt_compression
        if m.buffer==nil || m.buffer.data==nil || m.offset+m.size>m.buffer.size {return importer.fail(r,.Malformed,"a meshopt buffer view points outside its buffer")}
        if m.stride==0 || m.count>uint(max(i32)) || m.count*m.stride!=view.size {return importer.fail(r,.Malformed,"a meshopt buffer view has %d elements of %d bytes for %d bytes",m.count,m.stride,view.size)}
        source:=([^]u8)(m.buffer.data)[m.offset:][:m.size]
        out:=make([]u8,view.size,context.temp_allocator)
        if m.mode!=.attributes || m.filter==.octahedral {return importer.fail(r,.Unsupported,"meshopt-compressed indices and normals are unsupported; export them without meshopt")}
        if m.stride%4!=0 || m.stride>256 || !decode_vertices(out,int(m.count),int(m.stride),source) {return importer.fail(r,.Malformed,"a meshopt buffer view of %d elements cannot be decoded",m.count)}
        #partial switch m.filter {
        case .quaternion:
            if m.stride!=8 {return importer.fail(r,.Malformed,"the quaternion meshopt filter needs 8 bytes per element")}
            filter_quaternion(out,int(m.count))
        case .exponential: filter_exponential(out)
        }
        view.data=raw_data(out)
    }
    return true
}

@(private="file")
unzigzag :: #force_inline proc "contextless" (v:u8) -> u8 {return (0-(v&1))~(v>>1)}

// A group of 16 bytes: zero, 2 or 4 bits each with a sentinel for a literal
// that follows, or 16 literals.
@(private="file")
decode_group :: proc "contextless" (data:[]u8,at:int,out:[]u8,bits:u8) -> (next:int,ok:bool) {
    switch bits {
    case 0:
        for &b in out[:GROUP] {b=0}
        return at,true
    case 1,2:
        width:=uint(1)<<bits
        header:=GROUP*int(width)/8
        literal:=at+header
        sentinel:=u8(1<<width-1)
        k:=0
        for i in 0..<header {
            if at+i>=len(data) {return}
            b:=data[at+i]
            for _ in 0..<8/width {
                v:=b>>(8-width)
                b<<=width
                if v==sentinel {
                    if literal>=len(data) {return}
                    v=data[literal]
                    literal+=1
                }
                out[k]=v
                k+=1
            }
        }
        return literal,true
    case 3:
        if at+GROUP>len(data) {return}
        copy(out[:GROUP],data[at:at+GROUP])
        return at+GROUP,true
    }
    return
}

@(private="file")
decode_bytes :: proc "contextless" (data:[]u8,at:int,out:[]u8) -> (next:int,ok:bool) {
    groups:=len(out)/GROUP
    header:=(groups+3)/4
    if at+header>len(data) {return}
    next=at+header
    for g in 0..<groups {
        bits:=(data[at+g/4]>>(uint(g%4)*2))&3
        next=decode_group(data,next,out[g*GROUP:],bits) or_return
    }
    return next,true
}

@(private="file")
decode_vertices :: proc(out:[]u8,count,stride:int,data:[]u8) -> bool {
    if len(data)<1+stride || data[0]&0xf0!=VERTEX_HEADER || data[0]&0x0f!=0 {return false}
    last:[256]u8
    copy(last[:stride],data[len(data)-stride:])
    block:=min((BLOCK_BYTES/stride)&~(GROUP-1),BLOCK_MAX)
    deltas:[BLOCK_MAX]u8
    at:=1
    for first:=0;first<count;first+=block {
        n:=min(block,count-first)
        aligned:=(n+GROUP-1)&~(GROUP-1)
        for k in 0..<stride {
            next,ok:=decode_bytes(data,at,deltas[:aligned])
            if !ok {return false}
            at=next
            p:=last[k]
            for i in 0..<n {
                p+=unzigzag(deltas[i])
                out[(first+i)*stride+k]=p
            }
        }
        copy(last[:stride],out[(first+n-1)*stride:][:stride])
    }
    return len(data)-at==max(stride,TAIL_MIN)
}

// Three components scaled into a signed 16-bit range and the index of the
// largest, which is rebuilt from them.
@(private="file")
filter_quaternion :: proc(out:[]u8,count:int) {
    values:=([^]i16le)(raw_data(out))[:count*4]
    for i in 0..<count {
        q:=values[i*4:][:4]
        scale:=f32(1/math.SQRT_TWO)/f32(i32(q[3])|3)
        x,y,z:=f32(q[0])*scale,f32(q[1])*scale,f32(q[2])*scale
        w:=math.sqrt(max(1-x*x-y*y-z*z,0))
        largest:=int(q[3]&3)
        round :: proc "contextless" (v:f32) -> i16le {return i16le(i32(v*32767+(0.5 if v>=0 else -0.5)))}
        q[(largest+1)&3],q[(largest+2)&3],q[(largest+3)&3],q[largest]=round(x),round(y),round(z),round(w)
    }
}

// A float as a signed 24-bit mantissa and a signed 8-bit exponent.
@(private="file")
filter_exponential :: proc(out:[]u8) {
    values:=([^]i32le)(raw_data(out))[:len(out)/4]
    for &v in values {
        e:=i32(v)>>24
        m:=(i32(v)<<8)>>8
        (^f32le)(&v)^=f32le(math.ldexp(f32(m),int(e)))
    }
}
