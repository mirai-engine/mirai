package serial

import "core:math/linalg"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:std/base"

// Every public procedure is handed truncated and mutated buffers, random
// bytes, huge counts and sizes, schemas and values that disagree, NaN and
// infinities, deep nesting and invalid UTF-8. A writer stays inside its buffer
// and counts what it dropped, a reader that failed gives zeros from then on,
// what is read is in the range it was written with, and what was written
// reads back. A case that
// crashes the runner can be skipped with -define:SERIAL_HOSTILE_SKIP=a,b to
// reach the cases after it; the names are the strings given to hostile_on.

@(private="file") HOSTILE_ROUNDS :: #config(SERIAL_HOSTILE_ROUNDS,400)
@(private="file") HOSTILE_SKIP :: #config(SERIAL_HOSTILE_SKIP,"")
@(private="file") HOSTILE_WEIGHT :: 4096
@(private="file") HOSTILE_SEED :: #config(SERIAL_HOSTILE_SEED,0)

@(private="file")
hostile_on :: proc(name:string) -> bool {
    rest:=string(HOSTILE_SKIP)
    for entry in strings.split_iterator(&rest,",") {
        if entry==name {return false}
    }
    return true
}


@(private="file")
hostile_i64 :: proc(h:^base.Hostile) -> i64 {
    switch base.hostile_int(h,10) {
    case 0: return min(i64)
    case 1: return max(i64)
    case 2: return -1
    case 3: return 0
    case 4: return 1
    case 5: return i64(max(u32))
    case 6: return i64(max(i32))+1
    case 7: return i64(base.hostile_int(h,300))-150
    }
    return i64(base.hostile_next(h))
}

// Counts, sizes and offsets of every kind: negative, zero, small, enormous.
@(private="file")
hostile_wild :: proc(h:^base.Hostile) -> int {
    switch base.hostile_int(h,12) {
    case 0: return min(int)
    case 1: return max(int)
    case 2: return max(int)-1
    case 3: return -1
    case 4: return 0
    case 5: return 1<<40
    case 6: return int(max(u32))
    case 7: return int(max(i32))
    case 8: return -(1<<40)
    }
    return base.hostile_int(h,70)-3
}

@(private="file")
hostile_count :: proc(h:^base.Hostile) -> int {
    if base.hostile_int(h,5)==0 {return hostile_wild(h)}
    return base.hostile_int(h,70)-2
}

@(private="file")
hostile_f64 :: proc(h:^base.Hostile) -> f64 {
    switch base.hostile_int(h,12) {
    case 0: return transmute(f64)u64(0x7ff8000000000000)
    case 1: return transmute(f64)u64(0x7ff0000000000000)
    case 2: return transmute(f64)u64(0xfff0000000000000)
    case 3: return 1e300
    case 4: return -1e300
    case 5: return 1e-300
    case 6: return 0
    case 7: return 18446744073709551616.0
    case 8: return -9223372036854775808.0
    case 9: return 0.5
    }
    return f64(base.hostile_int(h,2001)-1000)/100
}

@(private="file")
hostile_fill :: proc(h:^base.Hostile,data:[]u8) {
    for &b in data {b=u8(base.hostile_next(h))}
}

@(private="file")
hostile_bytes :: proc(h:^base.Hostile,size:int) -> []u8 {
    data:=make([]u8,size,context.temp_allocator)
    hostile_fill(h,data)
    return data
}

@(private="file")
hostile_copy :: proc(data:[]u8) -> []u8 {
    out:=make([]u8,len(data),context.temp_allocator)
    copy(out,data)
    return out
}

@(private="file")
hostile_mutate :: proc(h:^base.Hostile,data:[]u8) {
    if len(data)==0 {return}
    for _ in 0..<1+base.hostile_int(h,4) {
        at:=base.hostile_int(h,len(data))
        switch base.hostile_int(h,5) {
        case 0: data[at]=u8(base.hostile_next(h))
        case 1: data[at]=0
        case 2: data[at]=0xff
        case 3: data[at]~=1<<uint(base.hostile_int(h,8))
        case 4: data[at]=0x7f
        }
    }
}

@(private="file")
hostile_mutate_text :: proc(h:^base.Hostile,text:string) -> string {
    palette:="{}[]\":,\0123456789-+.eE ntfu\x00\xff\x80\n"
    out:=make([dynamic]u8,context.temp_allocator)
    append(&out,..transmute([]u8)text)
    for _ in 0..<1+base.hostile_int(h,4) {
        if len(out)==0 {append(&out,palette[base.hostile_int(h,len(palette))]);continue}
        at:=base.hostile_int(h,len(out))
        switch base.hostile_int(h,4) {
        case 0: out[at]=palette[base.hostile_int(h,len(palette))]
        case 1: ordered_remove(&out,at)
        case 2: inject_at(&out,at,palette[base.hostile_int(h,len(palette))])
        case 3: resize(&out,at)
        }
    }
    return string(out[:])
}

@(private="file")
hostile_value :: proc(h:^base.Hostile) -> Value {
    NAMES :: [?]string{"","Off","On","Auto","Down","Level","Up","A","B","C","x","a-name-that-is-far-longer-than-any-text-field-of-the-fixtures-can-hold"}
    names:=NAMES
    switch base.hostile_int(h,12) {
    case 0: return nil
    case 1: return base.hostile_int(h,2)==0
    case 2: return hostile_i64(h)
    case 3: return base.hostile_next(h)
    case 4: return hostile_f64(h)
    case 5: return names[base.hostile_int(h,len(names))]
    case 6: return base.Entity(base.hostile_next(h))
    case 7: return base.Entity_Id(base.hostile_next(h))
    case 8: return base.Asset_Id{base.hostile_next(h),base.hostile_next(h)}
    case 9: return u64(base.hostile_int(h,300))
    case 10: return i64(base.hostile_int(h,300))-150
    }
    return hostile_f64(h)
}

// ------------------------------------------------------------------ fixtures

@(private="file") Mode :: enum u8 {Off,On=4,Auto}
@(private="file") Sign :: enum i8 {Down=-1,Level,Up}
@(private="file") Flag :: enum {A,B,C}
@(private="file") Part :: struct {offset:[3]f32,mode:Mode}
@(private="file")
Fixture :: struct {
    id:base.Entity_Id,
    target:base.Entity `mirai:"requires=Camera"`,
    mesh:base.Asset_Id,
    name:[12]u8 `mirai:"text,label=Name"`,
    speed:f32 `mirai:"min=0,max=20,step=0.5,precision=0.01,bits=9,unit=m/s"`,
    ratio:f64,
    half:f16,
    count:i16,
    big:u64,
    wide:i128,
    wideu:u128,
    on:bool,
    sign:Sign,
    flags:bit_set[Flag;u8],
    many:bit_set[0..<100;u128],
    parts:[2]Part,
    grid:[2][2]u8,
    rot:quaternion128,
    mat:matrix[2,2]f32,
    cache:u32 `mirai:"transient"`,
}

@(private="file")
hostile_fixture :: proc(t:^testing.T,s:^Schema) -> Type_Index {
    schema_init(s)
    root,ok:=schema_add(s,Fixture)
    testing.expect(t,ok,s.error)
    return root
}

@(private="file")
hostile_schema_bytes :: proc(s:^Schema) -> []u8 {
    w:Writer
    writer_init(&w,allocator=context.temp_allocator)
    schema_write(&w,s)
    return writer_bytes(&w)
}

// ---------------------------------------------------------------- bitstream

@(private="file")
hostile_bit_write_op :: proc(h:^base.Hostile,w:^Bit_Writer,scratch:[]u8) {
    switch base.hostile_int(h,18) {
    case 0: bit_write(w,base.hostile_next(h),hostile_count(h))
    case 1: bit_write_bool(w,base.hostile_int(h,2)==0)
    case 2: bit_write_ranged(w,hostile_i64(h),hostile_i64(h),hostile_i64(h))
    case 3: bit_write_varuint(w,base.hostile_next(h)>>uint(base.hostile_int(h,64)))
    case 4: bit_write_varint(w,hostile_i64(h))
    case 5: bit_write_f32(w,base.hostile_f32(h))
    case 6: bit_write_f64(w,hostile_f64(h))
    case 7: bit_write_float_range(w,base.hostile_f32(h),base.hostile_f32(h),base.hostile_f32(h),hostile_count(h))
    case 8: bit_write_float_precision(w,base.hostile_f32(h),base.hostile_f32(h),base.hostile_f32(h),base.hostile_f32(h))
    case 9: bit_write_unit_vector(w,{base.hostile_f32(h),base.hostile_f32(h),base.hostile_f32(h)},hostile_count(h))
    case 10: bit_write_quaternion(w,quaternion(w=base.hostile_f32(h),x=base.hostile_f32(h),y=base.hostile_f32(h),z=base.hostile_f32(h)),hostile_count(h))
    case 11: bit_write_align(w)
    case 12: bit_write_bytes(w,scratch[:base.hostile_int(h,len(scratch)+1)])
    case 13: bit_write_string(w,string(scratch[:base.hostile_int(h,len(scratch)+1)]))
    case 14: _=bit_writer_bits(w);_=bit_writer_bytes(w);_=bit_writer_remaining(w)
    case 15: _=bit_count_for(base.hostile_next(h))
    case 16: _=bit_zigzag(hostile_i64(h));_=bit_unzigzag(base.hostile_next(h))
    case 17: _=bit_writer_flush(w)
    }
}

// One read of any kind, held to what a reader promises: it never gains bits,
// an error stays, a reader in error gives zeros, and a value is in the range
// it is read with.
@(private="file")
hostile_bit_read_op :: proc(t:^testing.T,h:^base.Hostile,r:^Bit_Reader,scratch:[]u8) {
    left,failed:=bit_reader_remaining(r),!bit_reader_ok(r)
    zero:=true // what a reader in error gave
    switch base.hostile_int(h,14) {
    case 0:
        count:=hostile_count(h)
        value:=bit_read(r,count)
        testing.expectf(t,count<=0 || count>=64 || value>>uint(count)==0,"%d bits were read as %x",count,value)
        zero=value==0
    case 1: zero=!bit_read_bool(r)
    case 2:
        lo,hi:=hostile_i64(h),hostile_i64(h)
        value:=bit_read_ranged(r,lo,hi)
        testing.expectf(t,!bit_reader_ok(r) || lo>hi || (value>=lo && value<=hi),"%d was read in the range %d..%d",value,lo,hi)
        zero=value==0 || value==lo
    case 3: zero=bit_read_varuint(r)==0
    case 4: zero=bit_read_varint(r)==0
    case 5: zero=transmute(u32)bit_read_f32(r)==0
    case 6: zero=transmute(u64)bit_read_f64(r)==0
    case 7:
        lo,hi,bits:=base.hostile_f32(h),base.hostile_f32(h),hostile_count(h)
        value:=bit_read_float_range(r,lo,hi,bits)
        if bit_reader_ok(r) && lo<=hi && hi-lo<=max(f32) && bits>=1 && bits<=32 {
            testing.expectf(t,value>=lo && value<=hi,"%v was read in the range %v..%v with %d bits",value,lo,hi,bits)
        }
    case 8: _=bit_read_float_precision(r,base.hostile_f32(h),base.hostile_f32(h),base.hostile_f32(h))
    case 9:
        bits:=hostile_count(h)
        value:=bit_read_unit_vector(r,bits)
        if bit_reader_ok(r) && bits>=2 && bits<=BIT_UNIT_VECTOR_MAX_BITS {
            testing.expectf(t,abs(linalg.length(value)-1)<1e-3,"A unit vector of %d bits was read as %v",bits,value)
        }
    case 10:
        bits:=hostile_count(h)
        value:=bit_read_quaternion(r,bits)
        if bit_reader_ok(r) && bits>=2 && bits<=BIT_QUATERNION_MAX_BITS {
            testing.expectf(t,abs(abs(value)-1)<1e-3,"A rotation of %d bits was read as %v",bits,value)
        }
    case 11: bit_read_align(r)
    case 12:
        out:=scratch[:base.hostile_int(h,len(scratch)+1)]
        for &b in out {b=0xa5}
        filled:=bit_read_bytes(r,out)
        blank:=true
        for b in out {blank&&=b==0}
        testing.expect(t,filled==bit_reader_ok(r) || len(out)==0,"Bytes were read exactly when the reader had them")
        testing.expect(t,filled || blank,"Bytes that were not read are not zeros")
        zero=!filled || len(out)==0
    case 13:
        storage:=scratch[:base.hostile_int(h,len(scratch)+1)]
        text:=bit_read_string(r,storage)
        testing.expect(t,len(text)<=len(storage) && (bit_reader_ok(r) || text==""),"A text was read past its storage, or from a reader in error")
        zero=text==""
    }
    now:=bit_reader_remaining(r)
    testing.expectf(t,now>=0 && now<=left,"A reader with %d bits left has %d after a read",left,now)
    testing.expect(t,!failed || (!bit_reader_ok(r) && zero),"A reader in error recovered, or gave something other than zeros")
}

@(test)
hostile_bit_writer :: proc(t:^testing.T) {
    GUARD :: 0x5a
    h:=base.Hostile{1+HOSTILE_SEED}
    scratch:[24]u8
    storage:[56]u8
    for _ in 0..<HOSTILE_ROUNDS {
        if testing.failed(t) {return}
        hostile_fill(&h,scratch[:])
        size:=base.hostile_int(&h,40)
        for &b in storage {b=GUARD}
        buffer:=storage[8:][:size]
        w:Bit_Writer
        measure:=base.hostile_int(&h,6)==0
        if measure {bit_writer_init_measure(&w)} else {bit_writer_init(&w,buffer)}
        for _ in 0..<1+base.hostile_int(&h,24) {
            bits,full:=bit_writer_bits(&w),w.overflow
            hostile_bit_write_op(&h,&w,scratch[:])
            now:=bit_writer_bits(&w)
            testing.expectf(t,now>=bits && (measure || now<=size*8) && bit_writer_remaining(&w)>=0,"A writer of %d bytes went from %d to %d bits",size,bits,now)
            testing.expect(t,!full || (w.overflow && now==bits),"A writer that ran out of room took a write")
        }
        out:=bit_writer_flush(&w)
        testing.expect(t,len(out)==(0 if measure else bit_writer_bytes(&w)) && (len(out)==0 || raw_data(out)==raw_data(buffer)),"The bytes of a writer are not those it wrote into its buffer")
        for b,i in storage {
            if i<8 || i>=8+size {testing.expect(t,b==GUARD,"A writer wrote outside its buffer")}
        }
        r:Bit_Reader
        limit:=base.hostile_int(&h,3)==0?hostile_wild(&h):-1
        bit_reader_init(&r,out,limit)
        testing.expect(t,bit_reader_remaining(&r)<=len(out)*8,"A reader has more bits than its buffer")
        for _ in 0..<1+base.hostile_int(&h,24) {hostile_bit_read_op(t,&h,&r,scratch[:])}
    }
    w:Bit_Writer
    bit_writer_init(&w,nil)
    bit_write(&w,1,1)
    testing.expect(t,w.overflow && len(bit_writer_flush(&w))==0,"A writer without a buffer took a bit")
}

@(test)
hostile_bit_reader :: proc(t:^testing.T) {
    h:=base.Hostile{2+HOSTILE_SEED}
    scratch:[24]u8
    for _ in 0..<HOSTILE_ROUNDS {
        if testing.failed(t) {return}
        hostile_fill(&h,scratch[:])
        data:=hostile_bytes(&h,base.hostile_int(&h,40))
        r:Bit_Reader
        bit_reader_init(&r,data,base.hostile_int(&h,3)==0?hostile_wild(&h):(base.hostile_int(&h,2)==0?base.hostile_int(&h,len(data)*8+8)-2:-1))
        testing.expect(t,bit_reader_remaining(&r)>=0 && bit_reader_remaining(&r)<=len(data)*8,"A reader has more bits than its buffer")
        for _ in 0..<1+base.hostile_int(&h,30) {hostile_bit_read_op(t,&h,&r,scratch[:])}
        free_all(context.temp_allocator)
    }
}

@(test)
hostile_quantization :: proc(t:^testing.T) {
    h:=base.Hostile{3+HOSTILE_SEED}
    for _ in 0..<HOSTILE_ROUNDS*4 {
        bits:=hostile_count(&h)
        a,b,c:=base.hostile_f32(&h),base.hostile_f32(&h),base.hostile_f32(&h)
        raw:=base.hostile_next(&h)
        ranged:=bits>=1 && bits<=32
        quantized:=quantize_range(a,b,c,bits)
        testing.expectf(t,!ranged || u64(quantized)<=u64(1)<<uint(bits)-1,"%v in %v..%v was quantized to %d, more than %d bits",a,b,c,quantized,bits)
        back:=dequantize_range(quantized,b,c,bits)
        if ranged && b<c && c-b<=max(f32) {testing.expectf(t,back>=b && back<=c,"%d of %d bits came back as %v, outside %v..%v",quantized,bits,back,b,c)}
        _=dequantize_range(u32(raw),a,b,bits)
        needed:=quantize_precision_bits(a,b,c)
        testing.expectf(t,needed>=0 && needed<=32,"%v..%v in steps of %v takes %d bits",a,b,c,needed)
        _=quantize_precision(a,b,c,base.hostile_f32(&h))
        _=dequantize_precision(u32(raw),a,b,c)
        _=quantize_unit_vector({a,b,c},bits)
        if vector:=dequantize_unit_vector(raw,bits);bits>=2 && bits<=BIT_UNIT_VECTOR_MAX_BITS {
            testing.expectf(t,abs(linalg.length(vector)-1)<1e-3,"%x of %d bits is the vector %v, not unit",raw,bits,vector)
        }
        _=quantize_quaternion(quaternion(w=a,x=b,y=c,z=base.hostile_f32(&h)),bits)
        if rotation:=dequantize_quaternion(raw,bits);bits>=2 && bits<=BIT_QUATERNION_MAX_BITS {
            testing.expectf(t,abs(abs(rotation)-1)<1e-3,"%x of %d bits is the rotation %v, not unit",raw,bits,rotation)
        }
    }
}

// ------------------------------------------------------------------- stream

@(private="file")
hostile_alignment :: proc(h:^base.Hostile) -> int {
    switch base.hostile_int(h,10) {
    case 0: return 0
    case 1: return -8
    case 2: return 3
    case 3: return min(int)
    case 4: return 1<<40
    case 5: return 6
    }
    return 1<<uint(base.hostile_int(h,8))
}

@(test)
hostile_stream_writer :: proc(t:^testing.T) {
    GUARD :: 0x5a
    h:=base.Hostile{4+HOSTILE_SEED}
    storage:[56]u8
    for round in 0..<HOSTILE_ROUNDS {
        if testing.failed(t) {return}
        fixed:=base.hostile_int(&h,2)==0
        for &b in storage {b=GUARD}
        buffer:=storage[8:][:base.hostile_int(&h,40)]
        w:Writer
        if fixed {writer_init_fixed(&w,buffer)} else {writer_init(&w,base.hostile_int(&h,3)==0?hostile_wild(&h)%256:base.hostile_int(&h,64))}
        for _ in 0..<1+base.hostile_int(&h,20) {
            // What a write of a known size adds: every byte is stored or counted as dropped.
            before,sized:=w.count+w.overflow,-1
            switch base.hostile_int(&h,14) {
            case 0:
                bytes:=hostile_bytes(&h,base.hostile_int(&h,40))
                write_bytes(&w,bytes);sized=len(bytes)
            case 1:
                size:=hostile_wild(&h)
                if hostile_on("write_zeros") && (fixed || size<=1<<16) {write_zeros(&w,size)}
            case 2:
                alignment:=hostile_alignment(&h)
                held:=w.count
                if hostile_on("write_align") && (fixed || alignment<=1<<16) {
                    write_align(&w,alignment)
                    power:=alignment>0 && alignment&(alignment-1)==0
                    testing.expectf(t,power || w.count==held,"An alignment of %d, not a power of two, wrote bytes",alignment)
                    testing.expectf(t,!power || w.overflow>0 || w.count&(alignment-1)==0,"A writer aligned to %d is at %d",alignment,w.count)
                }
            case 3: write_u8(&w,u8(base.hostile_next(&h)));write_u16(&w,u16(base.hostile_next(&h)));write_u32(&w,u32(base.hostile_next(&h)));write_u64(&w,base.hostile_next(&h));sized=15
            case 4: write_i8(&w,i8(base.hostile_next(&h)));write_i16(&w,i16(base.hostile_next(&h)));write_i32(&w,i32(base.hostile_next(&h)));write_i64(&w,hostile_i64(&h));sized=15
            case 5: write_f32(&w,base.hostile_f32(&h));write_f64(&w,hostile_f64(&h));write_bool(&w,base.hostile_int(&h,2)==0);sized=13
            case 6: write_varint(&w,base.hostile_next(&h)>>uint(base.hostile_int(&h,64)));write_svarint(&w,hostile_i64(&h))
            case 7: write_string(&w,string(hostile_bytes(&h,base.hostile_int(&h,30))))
            case 8:
                offset,bytes:=hostile_wild(&h),hostile_bytes(&h,base.hostile_int(&h,10))
                if hostile_on("writer_patch") {
                    held:=w.count
                    patched:=writer_patch(&w,offset,bytes)
                    testing.expectf(t,patched==(offset>=0 && offset<=held && len(bytes)<=held-offset) && w.count==held,"A patch of %d bytes at %d of %d was taken, or refused, wrongly",len(bytes),offset,held)
                }
            case 9,10:
                size:=hostile_wild(&h)
                if base.hostile_int(&h,2)==0 {size%=fixed?1<<40:70}
                if hostile_on("writer_grow") && (fixed || size<=1<<16) {
                    held:=w.count
                    out,grown:=writer_grow(&w,size)
                    testing.expectf(t,(grown && len(out)==max(size,0) && w.count==held+max(size,0)) || (!grown && len(out)==0 && w.count==held),"A writer of %d bytes grew by %d wrongly",held,size)
                }
            case 11: writer_reset(&w);before=0
            case 12,13: testing.expect(t,len(writer_bytes(&w))==w.count,"The bytes of a writer are not those it counts")
            }
            testing.expectf(t,sized<0 || w.count+w.overflow==before+sized || w.overflow==max(int),"A write of %d bytes was neither stored nor counted as dropped",sized)
            if !testing.expect(t,w.count>=0 && w.count<=len(w.data) && w.overflow>=0 && (!fixed || raw_data(w.data)==raw_data(buffer)),"A writer holds more than its room") {break}
        }
        for b,i in storage {
            if i<8 || i>=8+len(buffer) {testing.expect(t,b==GUARD,"A writer wrote outside its buffer")}
        }
        if !fixed {writer_destroy(&w)}
        free_all(context.temp_allocator)
    }
    w:Writer
    writer_init(&w,16)
    write_u32(&w,7)
    taken:=writer_take(&w)
    testing.expect(t,len(taken)==4 && len(writer_bytes(&w))==0,"A writer keeps what was taken from it")
    delete(taken)
    writer_destroy(&w)
    // The allocator of the test runner stops the process on a request it
    // cannot meet; the heap of the engine refuses it.
    for capacity in ([]int{min(int),-1,0,max(int)}) {
        if capacity==max(int) && !hostile_on("writer_init_max") {continue}
        writer_init(&w,capacity,runtime.heap_allocator())
        write_u8(&w,1)
        testing.expect(t,w.count+w.overflow==1,"A writer made with any capacity neither stored nor dropped a byte")
        writer_destroy(&w)
    }
}

@(test)
hostile_stream_reader :: proc(t:^testing.T) {
    h:=base.Hostile{5+HOSTILE_SEED}
    for _ in 0..<HOSTILE_ROUNDS {
        if testing.failed(t) {return}
        data:=hostile_bytes(&h,base.hostile_int(&h,40))
        r:=reader_init(data)
        for _ in 0..<1+base.hostile_int(&h,20) {
            left,failed:=reader_remaining(&r),r.failed
            zero:=true // what a reader that failed gave
            switch base.hostile_int(&h,14) {
            case 0: reader_seek(&r,hostile_wild(&h))
            case 1:
                size:=hostile_wild(&h)
                if hostile_on("read_bytes") {
                    view:=read_bytes(&r,size)
                    testing.expectf(t,(view==nil && (r.failed || size<=0)) || (len(view)==size && size<=left),"%d bytes were read of %d as %d",size,left,len(view))
                    zero=view==nil
                }
            case 2:
                out:=make([]u8,base.hostile_int(&h,40),context.temp_allocator)
                read_into(&r,out)
                for b in out {zero&&=b==0}
            case 3: if hostile_on("read_skip") {read_skip(&r,hostile_wild(&h))}
            case 4: if hostile_on("read_align") {read_align(&r,hostile_alignment(&h))}
            case 5: zero=u64(read_u8(&r))|u64(read_u16(&r))|u64(read_u32(&r))|read_u64(&r)==0
            case 6: zero=i64(read_i8(&r))|i64(read_i16(&r))|i64(read_i32(&r))|read_i64(&r)==0
            case 7: zero=transmute(u32)read_f32(&r)==0 && transmute(u64)read_f64(&r)==0 && !read_bool(&r)
            case 8: zero=read_varint(&r)==0
            case 9: zero=read_svarint(&r)==0
            case 10:
                size:=hostile_wild(&h)
                if hostile_on("read_count") {
                    count:=read_count(&r,size)
                    // No more elements than the bytes left can hold.
                    testing.expectf(t,count>=0 && (r.failed || size<=0 || i128(count)*i128(size)<=i128(left)),"%d elements of %d bytes were counted in %d bytes",count,size,left)
                    zero=count==0
                }
            case 11: zero=read_string(&r)==""
            case 12: _=reader_remaining(&r)
            case 13: r.offset=base.hostile_int(&h,len(data)+1);r.failed=false;failed=false;left=len(data)
            }
            testing.expect(t,!failed || (r.failed && zero),"A reader that failed recovered, or gave something other than zeros")
            if !testing.expectf(t,r.offset>=0 && r.offset<=len(data) && reader_remaining(&r)<=len(data),"A reader of %d bytes is at %d",len(data),r.offset) {break}
        }
        free_all(context.temp_allocator)
    }
    all_ones:=[]u8{0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff}
    r:=reader_init(all_ones)
    testing.expect(t,read_varint(&r)==0 && r.failed,"A varint of more than ten bytes was read")
    r=reader_init(all_ones)
    testing.expect(t,read_string(&r)=="" && r.failed,"A text of a length that is no varint was read")
    r=reader_init(all_ones)
    testing.expect(t,read_count(&r,0)==0 && r.failed,"A count that is no varint was read")
    r=reader_init(nil)
    testing.expect(t,read_string(&r)=="" && r.failed,"A text was read from nothing")
    reader_seek(&r,0)
}

// ------------------------------------------------------- schema and walkers

@(private="file")
hostile_weights :: proc(s:^Schema) -> []u64 {
    weights:=make([]u64,len(s.types),context.temp_allocator)
    for type,index in s.types {
        weight:=u64(1)
        #partial switch type.kind {
        case .Struct:
            for field in s.fields[type.first:][:type.count] {weight=min(weight+weights[field.type],1<<20)}
        case .Array:
            weight=min(1+u64(type.count)*weights[type.elem],1<<20)
        case .Enum,.Bit_Set:
            weight=1+u64(type.count)
        }
        weights[index]=weight
    }
    return weights
}

@(private="file")
hostile_path :: proc(h:^base.Hostile,s:^Schema,type:Type_Index) -> string {
    GARBAGE :: [?]string{"[","]",".","..","[x]","[-1]","[99999999999]","[4294967296]","[4294967295]","a.b","[0","[]","\x00",".[0]","[0]]","[00000000000000000000000001]"}
    garbage:=GARBAGE
    b:strings.Builder
    strings.builder_init(&b,context.temp_allocator)
    current:=type
    for _ in 0..<base.hostile_int(h,7) {
        if int(current)>=len(s.types) {break}
        info:=s.types[current]
        #partial switch info.kind {
        case .Struct:
            if info.count==0 || base.hostile_int(h,12)==0 {
                if len(b.buf)>0 {strings.write_byte(&b,'.')}
                strings.write_string(&b,"nothing")
                break
            }
            field:=s.fields[info.first:][base.hostile_int(h,int(info.count))]
            if len(b.buf)>0 {strings.write_byte(&b,'.')}
            strings.write_string(&b,field.name)
            current=field.type
            continue
        case .Array:
            fmt.sbprintf(&b,"[%d]",base.hostile_int(h,int(min(info.count,10)+2)))
            current=info.elem
            continue
        case .Bit_Set,.Enum:
            if info.count>0 {
                if len(b.buf)>0 {strings.write_byte(&b,'.')}
                strings.write_string(&b,s.choices[info.first:][base.hostile_int(h,int(info.count))].name)
            }
        }
        break
    }
    if base.hostile_int(h,6)==0 {strings.write_string(&b,garbage[base.hostile_int(h,len(garbage))])}
    return strings.to_string(b)
}

@(private="file")
hostile_read_text :: proc(s:^Schema,index:Type_Index,text:string,out:[]u8) {
    r:Text_Reader
    text_reader_init(&r,text,context.temp_allocator)
    if text_read(&r,s,index,out,r.offset==0&&len(text)%2==0) {_=text_end(&r)}
    text_reader_destroy(&r)
}

@(private="file")
hostile_visit :: proc(kind:Type_Kind,ref:rawptr,user:rawptr) {
    (^int)(user)^+=1
}

@(private="file")
hostile_walk_type :: proc(h:^base.Hostile,s:^Schema,other:^Schema,other_weights:[]u64,index:Type_Index) {
    size:=int(s.types[index].size)
    _=schema_layout_hash(s,index)
    _=schema_fields(s,index);_=schema_choices(s,index);_=type_is_bytes(s,index)
    data:=hostile_bytes(h,size)

    l:Layout
    layout_init(&l,s,index,context.temp_allocator)
    count:=base.hostile_int(h,3)
    source:=hostile_bytes(h,count*size)
    target:=make([]u8,count*size,context.temp_allocator)
    value_write(&l,target,raw_data(source),count)
    layout_destroy(&l)

    refs:=make([dynamic]Ref,context.temp_allocator)
    if refs_collect(s,index,&refs) && len(refs)>0 {
        stride:=size+base.hostile_int(h,4)
        rows:=hostile_bytes(h,stride*3)
        visited:=0
        refs_visit(refs[:],rows,stride,3,hostile_visit,&visited)
    }

    w:Writer
    writer_init(&w,allocator=context.temp_allocator)
    text_write(&w,s,index,data,Text_Format(base.hostile_int(h,2)),base.hostile_int(h,4),base.hostile_int(h,2)==0)
    text:=string(writer_bytes(&w))
    out:=make([]u8,size,context.temp_allocator)
    hostile_read_text(s,index,text,out)
    hostile_read_text(s,index,hostile_mutate_text(h,text),out)
    hostile_read_text(s,index,hostile_mutate_text(h,text),out)
    hostile_read_text(s,index,text[:base.hostile_int(h,len(text)+1)],out)

    for _ in 0..<4 {
        path:=hostile_path(h,s,index)
        limit:=base.hostile_int(h,size+1)
        _,_=value_get(s,index,data,path)
        _,_=value_get(s,index,data[:limit],path)
        _=value_set(s,index,data,path,hostile_value(h))
        _=value_set(s,index,data[:limit],path,hostile_value(h))
        _,_,_=value_slice(s,index,data,path)
        _,_,_=value_slice(s,index,data[:limit],path)
        _,_,_=path_resolve(s,index,path)
    }

    if len(other.types)>0 {
        to:=Type_Index(base.hostile_int(h,len(other.types)))
        if other_weights[to]<=HOSTILE_WEIGHT && other.types[to].size<=1<<16 {
            m:Migration
            migration_init(&m,s,index,other,to,context.temp_allocator)
            dst_size:=int(other.types[to].size)
            count:=base.hostile_int(h,3)
            from:=hostile_bytes(h,count*size)
            into:=make([]u8,count*dst_size,context.temp_allocator)
            default:=base.hostile_int(h,2)==0?hostile_bytes(h,dst_size):nil
            migration_apply(&m,into,from,count,default)
            if count>0 && dst_size>0 {value_read(&m,raw_data(into),from,count,default==nil?nil:raw_data(default))}
            migration_destroy(&m)
        }
    }
}

@(private="file")
hostile_battery :: proc(h:^base.Hostile,s:^Schema,other:^Schema) {
    if schema_validate(s)!=.None {return}
    weights:=hostile_weights(s)
    other_weights:=schema_validate(other)==.None?hostile_weights(other):nil
    hashes:=make([dynamic]u64,context.temp_allocator)
    schema_hashes_update(s,&hashes)
    for _,index in s.types {
        if weights[index]>HOSTILE_WEIGHT || s.types[index].size>1<<16 {continue}
        hostile_walk_type(h,s,other if other_weights!=nil else s,other_weights if other_weights!=nil else weights,Type_Index(index))
    }
    clone:Schema
    schema_clone(&clone,other)
    defer schema_destroy(&clone)
    clone_hashes:[dynamic]u64
    defer delete(clone_hashes)
    link:Schema_Import
    schema_import_init(&link,&clone,&clone_hashes,s)
    defer schema_import_destroy(&link)
    for _ in 0..<4 {
        if len(s.types)==0 {break}
        _=schema_import(&link,Type_Index(base.hostile_int(h,len(s.types))))
    }
    _=schema_import(&link,Type_Index(len(s.types)))
    _=schema_import(&link,TYPE_NONE)
    _=schema_validate(&clone)
    again:Schema
    schema_clone(&again,s)
    _=schema_validate(&again)
    schema_destroy(&again)
}

@(private="file")
hostile_read_schema :: proc(h:^base.Hostile,data:[]u8,other:^Schema) {
    r:=reader_init(data)
    s:Schema
    if schema_read(&r,&s)==.None {
        hostile_battery(h,&s,other)
        schema_destroy(&s)
    }
}

@(private="file")
hostile_schema_noise :: proc(h:^base.Hostile,w:^Writer) {
    SIZES :: [?]u64{0,1,2,4,8,16,3,12,24,100,0xffff,0xffffffff}
    ALIGNS :: [?]u64{1,2,4,8,16,0,3,4096,8192}
    sizes,aligns:=SIZES,ALIGNS
    types,fields,choices:=1+base.hostile_int(h,6),base.hostile_int(h,8),base.hostile_int(h,8)
    write_varint(w,base.hostile_int(h,20)==0?base.hostile_next(h):SCHEMA_FORMAT)
    write_varint(w,u64(types));write_varint(w,u64(fields));write_varint(w,u64(choices))
    for index in 0..<types {
        write_u8(w,u8(base.hostile_int(h,14)))
        write_varint(w,sizes[base.hostile_int(h,len(sizes))])
        write_varint(w,aligns[base.hostile_int(h,len(aligns))])
        write_string(w,base.hostile_int(h,2)==0?"":"T")
        write_varint(w,u64(base.hostile_int(h,fields+2)))
        write_varint(w,u64(base.hostile_int(h,min(fields,choices)+3)))
        write_varint(w,u64(base.hostile_int(h,index+3)))
    }
    for _ in 0..<fields {
        write_string(w,base.hostile_int(h,2)==0?"f":"label")
        write_varint(w,u64(base.hostile_int(h,types+1)))
        write_varint(w,u64(base.hostile_int(h,40)))
        write_u8(w,u8(base.hostile_next(h)))
        present:=u8(base.hostile_next(h))
        write_u8(w,present)
        if present&HAS_MIN_BIT!=0 {write_f64(w,hostile_f64(h))}
        if present&2!=0 {write_f64(w,hostile_f64(h))}
        if present&4!=0 {write_f64(w,hostile_f64(h))}
        if present&8!=0 {write_f32(w,base.hostile_f32(h))}
        if present&16!=0 {write_u8(w,u8(base.hostile_next(h)))}
        if present&32!=0 {write_string(w,"label")}
        if present&64!=0 {write_string(w,"unit")}
        if present&128!=0 {write_u64(w,base.hostile_next(h))}
    }
    for _ in 0..<choices {
        write_string(w,base.hostile_int(h,3)==0?"":"c")
        write_svarint(w,i64(base.hostile_int(h,12))-2)
    }
}
@(private="file") HAS_MIN_BIT :: 1

// A schema that validates, with every kind of type and field option.
@(private="file")
hostile_build_schema :: proc(h:^base.Hostile,s:^Schema) {
    schema_init(s)
    append(&s.types,Type{kind=.Uint,size=1,align=1,elem=TYPE_NONE})
    count:=1+base.hostile_int(h,11)
    for index in 1..<count {
        type:=Type{align=u32(1<<uint(base.hostile_int(h,4))),elem=TYPE_NONE}
        if base.hostile_int(h,2)==0 {
            type.name=fmt.aprintf("T%d",index,allocator=s.allocator)
            type.name_hash=base.name_hash(type.name)
        }
        pick:=base.hostile_int(h,11)
        if index<2 && pick>=9 {pick=base.hostile_int(h,9)}
        switch pick {
        case 0: type.kind=.Bool;type.size=u32(1<<uint(base.hostile_int(h,4)))
        case 1: type.kind=.Int;type.size=u32(1<<uint(base.hostile_int(h,5)))
        case 2: type.kind=.Uint;type.size=u32(1<<uint(base.hostile_int(h,5)))
        case 3: type.kind=.Float;type.size=u32(2<<uint(base.hostile_int(h,3)))
        case 4:
            type.kind=.Enum;type.size=u32(1<<uint(base.hostile_int(h,4)))
            type.first,type.count=u32(len(s.choices)),u32(base.hostile_int(h,5))
            for k in 0..<int(type.count) {append(&s.choices,Choice{fmt.aprintf("c%d",k,allocator=s.allocator),i64(base.hostile_int(h,300))-100})}
        case 5:
            type.kind=.Bit_Set;type.size=u32(1<<uint(base.hostile_int(h,5)))
            type.first,type.count=u32(len(s.choices)),u32(base.hostile_int(h,5))
            for k in 0..<int(type.count) {append(&s.choices,Choice{fmt.aprintf("b%d",k,allocator=s.allocator),i64(base.hostile_int(h,int(type.size)*8))})}
        case 6: type.kind=.Entity;type.size=8
        case 7: type.kind=base.hostile_int(h,2)==0?.Entity_Id:.Asset;type.size=type.kind==.Asset?16:8
        case 8: type.kind=.Float;type.size=4
        case 9:
            type.kind=.Struct
            type.first=u32(len(s.fields))
            end:=u32(0)
            for k in 0..<base.hostile_int(h,6) {
                field_type:=Type_Index(base.hostile_int(h,index))
                field:=Field{type=field_type,offset=end+u32(base.hostile_int(h,3)),flags=transmute(Field_Flags)u8(base.hostile_next(h))}
                field.name=fmt.aprintf("f%d",k,allocator=s.allocator)
                field.name_hash=base.name_hash(field.name)
                if base.hostile_int(h,2)==0 {field.min,field.has_min=hostile_f64(h),true}
                if base.hostile_int(h,3)==0 {field.max,field.has_max=hostile_f64(h),true;field.step=hostile_f64(h)}
                field.precision=base.hostile_f32(h)
                field.bits=u8(base.hostile_next(h))
                if base.hostile_int(h,3)==0 {field.label=fmt.aprintf("label %d",k,allocator=s.allocator);field.unit=strings.clone("m",s.allocator)}
                if s.types[field_type].kind==.Entity && base.hostile_int(h,2)==0 {field.required_component=base.hostile_next(h)|1}
                end=field.offset+s.types[field_type].size
                append(&s.fields,field)
                type.count+=1
            }
            type.size=end+u32(base.hostile_int(h,3))
        case 10:
            type.kind=.Array
            type.elem=Type_Index(base.hostile_int(h,index))
            type.count=u32(base.hostile_int(h,base.hostile_int(h,8)==0?200:5))
            type.size=type.count*s.types[type.elem].size+u32(base.hostile_int(h,3))
        }
        append(&s.types,type)
    }
}

@(private="file")
hostile_round_trip :: proc(h:^base.Hostile,s:^Schema,other:^Schema) {
    bytes:=hostile_schema_bytes(s)
    if base.hostile_int(h,2)==0 {
        bytes=hostile_copy(bytes)
        hostile_mutate(h,bytes)
    }
    hostile_read_schema(h,bytes,other)
}

@(test)
hostile_schema_binary :: proc(t:^testing.T) {
    h:=base.Hostile{7+HOSTILE_SEED}
    fixture:Schema
    hostile_fixture(t,&fixture)
    defer schema_destroy(&fixture)
    bytes:=hostile_schema_bytes(&fixture)
    for cut in 0..=len(bytes) {
        hostile_read_schema(&h,bytes[:cut],&fixture)
        free_all(context.temp_allocator)
    }
    for _ in 0..<HOSTILE_ROUNDS*2 {
        mutated:=hostile_copy(bytes)
        hostile_mutate(&h,mutated)
        hostile_read_schema(&h,mutated[:len(mutated)-(base.hostile_int(&h,4)==0?base.hostile_int(&h,len(mutated)):0)],&fixture)
        free_all(context.temp_allocator)
    }
    for _ in 0..<HOSTILE_ROUNDS {
        hostile_read_schema(&h,hostile_bytes(&h,base.hostile_int(&h,300)),&fixture)
        free_all(context.temp_allocator)
    }
    accepted:=0
    for _ in 0..<HOSTILE_ROUNDS*2 {
        w:Writer
        writer_init(&w,allocator=context.temp_allocator)
        hostile_schema_noise(&h,&w)
        r:=reader_init(writer_bytes(&w))
        s:Schema
        if schema_read(&r,&s)==.None {
            accepted+=1
            hostile_battery(&h,&s,&fixture)
            schema_destroy(&s)
        }
        free_all(context.temp_allocator)
    }
    for _ in 0..<HOSTILE_ROUNDS/2 {
        built:Schema
        hostile_build_schema(&h,&built)
        hostile_battery(&h,&built,&fixture)
        hostile_round_trip(&h,&built,&built)
        hostile_round_trip(&h,&built,&fixture)
        schema_destroy(&built)
        free_all(context.temp_allocator)
    }
    huge:=[?]u64{1<<63,1<<40,u64(max(u32)),65535,65534,1<<20}
    for count in huge {
        for variant in 0..<3 {
            w:Writer
            writer_init(&w,allocator=context.temp_allocator)
            write_varint(&w,SCHEMA_FORMAT)
            write_varint(&w,variant==0?count:1);write_varint(&w,variant==1?count:1);write_varint(&w,variant==2?count:1)
            write_bytes(&w,hostile_bytes(&h,64))
            r:=reader_init(writer_bytes(&w))
            s:Schema
            if schema_read(&r,&s)==.None {schema_destroy(&s)}
        }
    }
    r:=reader_init(nil)
    s:Schema
    _=schema_read(&r,&s)
    _=accepted
    free_all(context.temp_allocator)
}

// A schema that validates can still describe a value with an astronomic
// number of parts of no size at all: walking its types never ends.
@(private="file")
hostile_explosion :: proc(s:^Schema,arrays:bool,levels:int) {
    schema_init(s)
    append(&s.types,Type{kind=.Struct,size=0,align=1,elem=TYPE_NONE})
    for level in 1..=levels {
        previous:=Type_Index(level-1)
        if arrays {
            append(&s.types,Type{kind=.Array,size=0,align=1,count=max(u32),elem=previous})
        } else {
            first:=u32(len(s.fields))
            for _ in 0..<8 {append(&s.fields,Field{type=previous})}
            append(&s.types,Type{kind=.Struct,size=0,align=1,first=first,count=8,elem=TYPE_NONE})
        }
    }
}

@(private="file")
hostile_explosion_loaded :: proc(t:^testing.T,arrays:bool,levels:int,s:^Schema) -> bool {
    built:Schema
    hostile_explosion(&built,arrays,levels)
    defer schema_destroy(&built)
    w:Writer
    writer_init(&w,allocator=context.temp_allocator)
    schema_write(&w,&built)
    r:=reader_init(writer_bytes(&w))
    return schema_read(&r,s)==.None
}

@(test)
hostile_zero_size_arrays_layout :: proc(t:^testing.T) {
    s:Schema
    if !hostile_explosion_loaded(t,true,3,&s) {return}
    defer schema_destroy(&s)
    l:Layout
    layout_init(&l,&s,Type_Index(len(s.types)-1),context.temp_allocator)
    layout_destroy(&l)
}

@(test)
hostile_zero_size_arrays_layout_hash :: proc(t:^testing.T) {
    s:Schema
    if !hostile_explosion_loaded(t,true,3,&s) {return}
    defer schema_destroy(&s)
    _=schema_layout_hash(&s,Type_Index(len(s.types)-1))
}

@(test)
hostile_zero_size_arrays_text_write :: proc(t:^testing.T) {
    s:Schema
    if !hostile_explosion_loaded(t,true,3,&s) {return}
    defer schema_destroy(&s)
    buffer:[64]u8
    w:Writer
    writer_init_fixed(&w,buffer[:])
    text_write(&w,&s,Type_Index(len(s.types)-1),nil)
}

@(test)
hostile_zero_size_fan_out_layout_hash :: proc(t:^testing.T) {
    s:Schema
    if !hostile_explosion_loaded(t,false,31,&s) {return}
    defer schema_destroy(&s)
    _=schema_layout_hash(&s,Type_Index(len(s.types)-1))
}

@(test)
hostile_zero_size_fan_out_layout :: proc(t:^testing.T) {
    s:Schema
    if !hostile_explosion_loaded(t,false,31,&s) {return}
    defer schema_destroy(&s)
    l:Layout
    layout_init(&l,&s,Type_Index(len(s.types)-1),context.temp_allocator)
    layout_destroy(&l)
}

@(test)
hostile_zero_size_fan_out_text_write :: proc(t:^testing.T) {
    s:Schema
    if !hostile_explosion_loaded(t,false,31,&s) {return}
    defer schema_destroy(&s)
    buffer:[64]u8
    w:Writer
    writer_init_fixed(&w,buffer[:])
    text_write(&w,&s,Type_Index(len(s.types)-1),nil)
}

@(test)
hostile_huge_array_layout :: proc(t:^testing.T) {
    s:Schema
    schema_init(&s)
    defer schema_destroy(&s)
    append(&s.types,Type{kind=.Uint,size=1,align=1,elem=TYPE_NONE})
    append(&s.types,Type{kind=.Array,size=max(u32),align=1,count=max(u32),elem=0})
    w:Writer
    writer_init(&w,allocator=context.temp_allocator)
    schema_write(&w,&s)
    r:=reader_init(writer_bytes(&w))
    loaded:Schema
    if schema_read(&r,&loaded)!=.None {return}
    defer schema_destroy(&loaded)
    testing.expect_value(t,schema_validate(&loaded),Schema_Error.None)
    l:Layout
    layout_init(&l,&loaded,1,context.temp_allocator)
    layout_destroy(&l)
}

@(test)
hostile_random_schemas_validate :: proc(t:^testing.T) {
    h:=base.Hostile{8+HOSTILE_SEED}
    for _ in 0..<HOSTILE_ROUNDS {
        s:Schema
        schema_init(&s)
        types:=base.hostile_int(&h,8)
        for index in 0..<types {
            append(&s.types,Type{
                kind=Type_Kind(base.hostile_int(&h,11)),
                size=u32(base.hostile_int(&h,3)==0?base.hostile_next(&h):u64(base.hostile_int(&h,20))),
                align=u32(base.hostile_int(&h,10)),
                first=u32(base.hostile_int(&h,10)),
                count=u32(base.hostile_int(&h,10)),
                elem=base.hostile_int(&h,3)==0?TYPE_NONE:Type_Index(base.hostile_int(&h,types+2)),
            })
        }
        for _ in 0..<base.hostile_int(&h,10) {
            append(&s.fields,Field{type=Type_Index(base.hostile_int(&h,types+2)),offset=u32(base.hostile_int(&h,30)),required_component=u64(base.hostile_int(&h,2))})
        }
        for _ in 0..<base.hostile_int(&h,10) {append(&s.choices,Choice{value=hostile_i64(&h)})}
        valid:=schema_validate(&s)==.None
        // What is read back from the bytes of any schema keeps what a read promises.
        r:=reader_init(hostile_schema_bytes(&s))
        loaded:Schema
        if schema_read(&r,&loaded)==.None {
            testing.expect(t,valid && schema_validate(&loaded)==.None,"A schema that does not validate was read from its own bytes")
            schema_destroy(&loaded)
        }
        schema_destroy(&s)
        free_all(context.temp_allocator)
    }
}

// --------------------------------------------------------------- text reader

@(private="file")
HOSTILE_FRAGMENTS :: [?]string{
    "{","}","[","]",",",":","\"","\"id\"","\"name\"","\"flags\"","\"many\"","\"parts\"","\"grid\"","\"sign\"","\"mode\"","\"offset\"",
    "\"wide\"","\"mesh\"","\"target\"","\"rot\"","\"mat\"","\"half\"","\"speed\"","\"cache\"","\"count\"","\"big\"","\"on\"",
    "0","-1","-0","1","7","255","256","65536","1e999","-1e999","0.5e-400","1.5","99999999999999999999","9223372036854775808","-9223372036854775809",
    "18446744073709551615","18446744073709551616","1.","-","e5","+1",
    "nan","\"nan\"","\"inf\"","\"-inf\"","\"bits:0x7ff8000000000001\"","\"bits:0xzz\"","\"bits:\"","\"bits:0x7fc00000\"",
    "\"\\u00\"","\"\\ud800\"","\"\\udc00\"","\"\\ud800\\udc00\"","\"\\ud800\\u0041\"","\"\\x\"","\"\\","\\","\"\\u","\"\\uzzzz\"","\"\\u0x41\"",
    "true","false","null","tru","\"Off\"","\"On\"","\"Auto\"","\"Down\"","\"A\"","\"Z\"","\"0x1f\"","\"0x\"","\"\"",
    "\"00000000000000000000000000000000\"","\"0x00000000000000000000000000000000\"","\"0xffffffffffffffffffffffffffffffff\"",
    "\"0x0000000000000000000000000000000g\"","\"ffffffffffffffffffffffffffffffff\"",
    "\"0xffffffffffffffff\"","\"0x10000000000000000\""," ","\n","\t","\x00","\xff","\x80\x80","\xc3\x28","\xed\xa0\x80",
}

@(private="file")
hostile_fragments :: proc(h:^base.Hostile) -> string {
    fragments:=HOSTILE_FRAGMENTS
    b:strings.Builder
    strings.builder_init(&b,context.temp_allocator)
    for _ in 0..<1+base.hostile_int(h,14) {
        strings.write_string(&b,fragments[base.hostile_int(h,len(fragments))])
        if base.hostile_int(h,3)==0 {strings.write_byte(&b,' ')}
    }
    return strings.to_string(b)
}

@(test)
hostile_text_read :: proc(t:^testing.T) {
    h:=base.Hostile{9+HOSTILE_SEED}
    s:Schema
    root:=hostile_fixture(t,&s)
    defer schema_destroy(&s)
    size:=int(s.types[root].size)
    data:=hostile_bytes(&h,size)
    w:Writer
    writer_init(&w,allocator=context.temp_allocator)
    text_write(&w,&s,root,data,.Pretty)
    pretty:=strings.clone(string(writer_bytes(&w)))
    defer delete(pretty)
    writer_reset(&w)
    text_write(&w,&s,root,data,.Line)
    line:=strings.clone(string(writer_bytes(&w)))
    defer delete(line)
    out:=make([]u8,size,context.temp_allocator)
    for text in ([]string{pretty,line}) {
        for cut in 0..=len(text) {hostile_read_text(&s,root,text[:cut],out)}
    }
    free_all(context.temp_allocator)
    for round in 0..<HOSTILE_ROUNDS*4 {
        out=make([]u8,size,context.temp_allocator)
        source:=round%2==0?pretty:line
        hostile_read_text(&s,root,hostile_mutate_text(&h,source),out)
        index:=Type_Index(base.hostile_int(&h,len(s.types)))
        scratch:=make([]u8,int(s.types[index].size),context.temp_allocator)
        hostile_read_text(&s,index,hostile_fragments(&h),scratch)
        hostile_read_text(&s,root,hostile_fragments(&h),out)
        if round%64==0 {free_all(context.temp_allocator)}
    }
    free_all(context.temp_allocator)
}

@(test)
hostile_text_depth :: proc(t:^testing.T) {
    s:Schema
    root:=hostile_fixture(t,&s)
    defer schema_destroy(&s)
    out:=make([]u8,s.types[root].size)
    defer delete(out)
    DEPTH :: 10000
    open_arrays:=strings.repeat("[",DEPTH,context.temp_allocator)
    close_arrays:=strings.repeat("]",DEPTH,context.temp_allocator)
    open_objects:=strings.repeat("{\"a\":",DEPTH,context.temp_allocator)
    for text in ([]string{open_arrays,strings.concatenate({open_arrays,close_arrays},context.temp_allocator),open_objects,strings.concatenate({open_objects,"1",strings.repeat("}",DEPTH,context.temp_allocator)},context.temp_allocator)}) {
        r:Text_Reader
        text_reader_init(&r,text,context.temp_allocator)
        _=text_skip(&r)
        text_reader_destroy(&r)
        for depth in ([]int{0,-5,TEXT_MAX_DEPTH,TEXT_MAX_DEPTH+1,max(int),min(int)}) {
            if depth<0 && !hostile_on("text_skip_negative_depth") {continue}
            text_reader_init(&r,text,context.temp_allocator)
            _=text_skip(&r,depth)
            text_reader_destroy(&r)
        }
        hostile_read_text(&s,root,text,out)
        hostile_read_text(&s,root,strings.concatenate({"{\"grid\":",text,"}"},context.temp_allocator),out)
        hostile_read_text(&s,root,strings.concatenate({"{\"parts\":",text,"}"},context.temp_allocator),out)
        hostile_read_text(&s,root,strings.concatenate({"{\"flags\":",text,"}"},context.temp_allocator),out)
        hostile_read_text(&s,root,strings.concatenate({"{\"name\":",text,"}"},context.temp_allocator),out)
    }
    free_all(context.temp_allocator)
}

@(test)
hostile_text_strings_and_numbers :: proc(t:^testing.T) {
    h:=base.Hostile{10+HOSTILE_SEED}
    s:Schema
    root:=hostile_fixture(t,&s)
    defer schema_destroy(&s)
    out:=make([]u8,s.types[root].size)
    defer delete(out)
    LONG :: 1<<20
    texts:=[]string{
        strings.concatenate({"\"",strings.repeat("a",LONG,context.temp_allocator),"\""},context.temp_allocator),
        strings.concatenate({"\"",strings.repeat("\\u0041",LONG/6,context.temp_allocator),"\""},context.temp_allocator),
        strings.concatenate({"\"",strings.repeat("\\ud83d\\ude00",LONG/12,context.temp_allocator),"\""},context.temp_allocator),
        strings.concatenate({"\"",strings.repeat("\xe2\x82",LONG/2,context.temp_allocator),"\""},context.temp_allocator),
        strings.concatenate({"\"",strings.repeat("\\",LONG,context.temp_allocator),"\""},context.temp_allocator),
        strings.concatenate({"\"",strings.repeat("a",LONG,context.temp_allocator)},context.temp_allocator),
        strings.concatenate({"1",strings.repeat("0",5000,context.temp_allocator)},context.temp_allocator),
        strings.concatenate({"0.",strings.repeat("9",5000,context.temp_allocator)},context.temp_allocator),
        strings.concatenate({"1e",strings.repeat("9",5000,context.temp_allocator)},context.temp_allocator),
        strings.concatenate({"-",strings.repeat("9",100000,context.temp_allocator),".5e-",strings.repeat("9",100000,context.temp_allocator)},context.temp_allocator),
        strings.repeat("1,",LONG,context.temp_allocator),
        strings.repeat(" ",LONG,context.temp_allocator),
        "","-","\"","\\","\"\\","\"\\u","\"\\ud800","\"\\ud800\\","\"\\ud800\\u","\"\\ud800\\udc0",
    }
    for text in texts {
        r:Text_Reader
        text_reader_init(&r,text,context.temp_allocator)
        _,_=text_string(&r)
        text_reader_destroy(&r)
        text_reader_init(&r,text,context.temp_allocator)
        _,_=text_number(&r)
        text_reader_destroy(&r)
        text_reader_init(&r,text,context.temp_allocator)
        _,_,_=text_integer(&r)
        text_reader_destroy(&r)
        text_reader_init(&r,text,context.temp_allocator)
        _=text_skip(&r)
        text_reader_destroy(&r)
        for size in ([]int{2,4,8}) {
            text_reader_init(&r,text,context.temp_allocator)
            _,_=text_read_float(&r,size)
            text_reader_destroy(&r)
        }
        for field in ([]string{"name","id","target","mesh","speed","ratio","half","count","big","wide","wideu","sign","flags","many","rot","mat"}) {
            hostile_read_text(&s,root,strings.concatenate({"{\"",field,"\":",text,"}"},context.temp_allocator),out)
        }
        _,_=text_position(text,hostile_wild(&h))
        _,_=text_position(text,len(text))
        _,_=text_parse_asset_id(text)
        _,_=text_parse_hex(text)
    }
    free_all(context.temp_allocator)
}

@(test)
hostile_text_reader_primitives :: proc(t:^testing.T) {
    h:=base.Hostile{11+HOSTILE_SEED}
    for _ in 0..<HOSTILE_ROUNDS*2 {
        text:=base.hostile_int(&h,2)==0?hostile_fragments(&h):string(hostile_bytes(&h,base.hostile_int(&h,30)))
        r:Text_Reader
        text_reader_init(&r,text,context.temp_allocator)
        for _ in 0..<1+base.hostile_int(&h,10) {
            switch base.hostile_int(&h,12) {
            case 0: _=text_peek(&r)
            case 1: _=text_accept(&r,u8(base.hostile_next(&h)))
            case 2: _=text_expect(&r,u8(base.hostile_next(&h)))
            case 3: _=text_end(&r)
            case 4: _=text_keyword(&r,hostile_pick_string(&h,[]string{"","true","false","null","a-word-longer-than-the-whole-text-ever-is-ok"}))
            case 5: _,_=text_string(&r)
            case 6: _,_=text_number(&r)
            case 7: _,_,_=text_integer(&r)
            case 8: _=text_skip(&r)
            case 9: _,_=text_read_float(&r,hostile_pick(&h,[]int{2,4,8}))
            case 10: text_space(&r)
            case 11: testing.expect(t,!text_fail(&r,Text_Error_Code(base.hostile_int(&h,15)),hostile_wild(&h)),"A failure reads as a success")
            }
            if !testing.expectf(t,r.offset>=0 && r.offset<=len(text),"A reader of %d bytes of text is at %d",len(text),r.offset) {break}
        }
        line,column:=text_position(text,hostile_wild(&h))
        testing.expect(t,line>=1 && column>=1,"A position in a text is not a line and a column from one")
        text_reader_destroy(&r)
        _,_=text_parse_hex(text)
        id,parsed:=text_parse_asset_id(text)
        known,is_id:=base.asset_id_parse(text)
        testing.expect(t,parsed==is_id && (!parsed || id==known),"The text of an asset id is read here as base does not read it")
        free_all(context.temp_allocator)
    }
    r:Text_Reader
    text_reader_init(&r,"",context.temp_allocator)
    _=text_end(&r)
    text_reader_destroy(&r)
    text_reader_destroy(&r)
}

@(test)
hostile_text_float_sizes :: proc(t:^testing.T) {
    samples:=[]u64{0x7ff8000000000001,0x3ff0000000000000,0,max(u64),0x7fc00001,0x3f800000,0x7e01,0x3c00}
    for size in ([]int{min(int),-8,-1,0,1,3,5,7,9,16,17,1<<20,2,4,8}) {
        sized:=size==2 || size==4 || size==8
        if hostile_on("float_size_read") {
            r:Text_Reader
            for text in ([]string{"1.5","\"nan\"","\"inf\"","\"-inf\"","\"bits:0x7ff8000000000001\"","\"bits:\"","\"bits:0x\"","\"bits:0x7ff80000000000010000000000\""}) {
                text_reader_init(&r,text,context.temp_allocator)
                _,read:=text_read_float(&r,size)
                testing.expectf(t,sized || !read,"A float of %d bytes was read from %s",size,text)
                text_reader_destroy(&r)
            }
        }
        if hostile_on("float_size_write") {
            buffer:[256]u8
            for sample in samples {
                w:Writer
                writer_init_fixed(&w,buffer[:])
                text_write_float(&w,sample,size)
                if !sized {
                    testing.expectf(t,w.count==0,"A float of %d bytes was written",size)
                    continue
                }
                // What is written for the bits of a float of this size reads back as them.
                bits:=sample if size==8 else sample&(1<<uint(size*8)-1)
                w.count=0
                text_write_float(&w,bits,size)
                r:Text_Reader
                text_reader_init(&r,string(writer_bytes(&w)),context.temp_allocator)
                back,read:=text_read_float(&r,size)
                testing.expectf(t,read && back==bits,"The %d bytes %x were written as %s and read back as %x",size,bits,string(writer_bytes(&w)),back)
                text_reader_destroy(&r)
            }
        }
    }
    free_all(context.temp_allocator)
}

@(test)
hostile_text_write_primitives :: proc(t:^testing.T) {
    h:=base.Hostile{12+HOSTILE_SEED}
    for _ in 0..<HOSTILE_ROUNDS {
        if testing.failed(t) {return}
        buffer:[200]u8
        w:Writer
        fixed:=base.hostile_int(&h,2)==0
        if fixed {writer_init_fixed(&w,buffer[:base.hostile_int(&h,200)])} else {writer_init(&w,allocator=context.temp_allocator)}
        signed,unsigned:=hostile_i64(&h),base.hostile_next(&h)
        id:=base.Asset_Id{base.hostile_next(&h),base.hostile_next(&h)}
        text_write_string(&w,string(hostile_bytes(&h,base.hostile_int(&h,60))))
        text_write_int(&w,signed)
        text_write_uint(&w,unsigned)
        if hostile_on("text_write_hex") {text_write_hex(&w,base.hostile_next(&h),hostile_pick(&h,[]int{-1,0,1,5,16,17,33,64,100,1000}),base.hostile_int(&h,2)==0)}
        text_write_asset_id(&w,id)
        text_write_float(&w,base.hostile_next(&h),hostile_pick(&h,[]int{2,4,8}))
        if hostile_on("text_write_break") {text_write_break(&w,hostile_pick(&h,[]int{min(int),-1,0,1,5,1000,100000,1<<30,max(int),max(int)/2}))}
        testing.expect(t,w.count>=0 && w.count<=len(w.data) && w.overflow>=0 && (fixed || w.overflow==0),"A writer of text holds more than its room, or dropped what it could grow for")

        // What is written for a value reads back as it.
        one:Writer
        writer_init(&one,allocator=context.temp_allocator)
        text_write_int(&one,signed)
        r:Text_Reader
        text_reader_init(&r,string(writer_bytes(&one)),context.temp_allocator)
        negative,magnitude,read:=text_integer(&r)
        testing.expectf(t,read && negative==(signed<0) && magnitude==(u64(signed) if signed>=0 else ~u64(signed)+1),"%d was written as %s",signed,string(writer_bytes(&one)))
        text_reader_destroy(&r)
        writer_reset(&one)
        text_write_uint(&one,unsigned)
        text_reader_init(&r,string(writer_bytes(&one)),context.temp_allocator)
        negative,magnitude,read=text_integer(&r)
        testing.expectf(t,read && !negative && magnitude==unsigned,"%d was written as %s",unsigned,string(writer_bytes(&one)))
        text_reader_destroy(&r)
        writer_reset(&one)
        text_write_asset_id(&one,id)
        again,parsed:=text_parse_asset_id(string(writer_bytes(&one)))
        testing.expectf(t,parsed && again==id,"The asset id %v was written as %s",id,string(writer_bytes(&one)))
        writer_reset(&one)
        word:=hostile_bytes(&h,base.hostile_int(&h,30))
        for &b in word {b=' '+b%95}
        text_write_string(&one,string(word))
        text_reader_init(&r,string(writer_bytes(&one)),context.temp_allocator)
        value,quoted:=text_string(&r)
        testing.expectf(t,quoted && value==string(word),"The text %q was written as %s",string(word),string(writer_bytes(&one)))
        text_reader_destroy(&r)
        free_all(context.temp_allocator)
    }
}

@(test)
hostile_text_write_data :: proc(t:^testing.T) {
    h:=base.Hostile{13+HOSTILE_SEED}
    s:Schema
    root:=hostile_fixture(t,&s)
    defer schema_destroy(&s)
    size:=int(s.types[root].size)
    for _ in 0..<HOSTILE_ROUNDS {
        data:=hostile_bytes(&h,size+base.hostile_int(&h,8))
        buffer:[512]u8
        w:Writer
        if base.hostile_int(&h,2)==0 {writer_init_fixed(&w,buffer[:base.hostile_int(&h,512)])} else {writer_init(&w,allocator=context.temp_allocator)}
        index:=Type_Index(base.hostile_int(&h,len(s.types)))
        text_write(&w,&s,index,data,Text_Format(base.hostile_int(&h,2)),base.hostile_int(&h,5),base.hostile_int(&h,2)==0)
        if hostile_on("text_write_depth") {text_write(&w,&s,root,data,.Pretty,hostile_pick(&h,[]int{-1,1000,2000}))}
        free_all(context.temp_allocator)
    }
    if hostile_on("text_write_short") {
        w:Writer
        writer_init(&w,allocator=context.temp_allocator)
        text_write(&w,&s,root,make([]u8,size-1,context.temp_allocator))
    }
    if hostile_on("text_write_empty") {
        w:Writer
        writer_init(&w,allocator=context.temp_allocator)
        text_write(&w,&s,root,nil)
    }
    free_all(context.temp_allocator)
}

@(test)
hostile_text_read_destination :: proc(t:^testing.T) {
    s:Schema
    root:=hostile_fixture(t,&s)
    defer schema_destroy(&s)
    size:=int(s.types[root].size)
    if hostile_on("text_read_short") {
        r:Text_Reader
        text_reader_init(&r,"{}",context.temp_allocator)
        _=text_read(&r,&s,root,make([]u8,size-1,context.temp_allocator))
        text_reader_destroy(&r)
    }
    if hostile_on("text_read_empty") {
        r:Text_Reader
        text_reader_init(&r,"{}",context.temp_allocator)
        _=text_read(&r,&s,root,nil)
        text_reader_destroy(&r)
    }
    free_all(context.temp_allocator)
}

// --------------------------------------------------------------- path, value

@(test)
hostile_paths_and_values :: proc(t:^testing.T) {
    h:=base.Hostile{14+HOSTILE_SEED}
    s:Schema
    root:=hostile_fixture(t,&s)
    defer schema_destroy(&s)
    size:=int(s.types[root].size)
    data:=hostile_bytes(&h,size)
    for round in 0..<HOSTILE_ROUNDS*6 {
        index:=base.hostile_int(&h,3)==0?Type_Index(base.hostile_int(&h,len(s.types))):root
        path:=hostile_path(&h,&s,index)
        if base.hostile_int(&h,8)==0 {path=string(hostile_bytes(&h,base.hostile_int(&h,12)))}
        view:=data[:min(int(s.types[index].size)+(base.hostile_int(&h,3)==0?0:base.hostile_int(&h,40)),size)]
        if base.hostile_int(&h,5)==0 {view=data[:base.hostile_int(&h,size+1)]}
        _,_=value_get(&s,index,view,path)
        _=value_set(&s,index,view,path,hostile_value(&h))
        _,_,_=value_slice(&s,index,view,path)
        _,_,_=path_resolve(&s,index,path)
        _=text_field(view)
        _,_=value_get(&s,index,nil,path)
        _=value_set(&s,index,nil,path,hostile_value(&h))
        if round%256==0 {free_all(context.temp_allocator)}
    }
    for path in ([]string{"","count","count[0]","name[99]","name[4294967296]","parts[1].offset[2]","parts[2]","parts[1].mode","flags.A","flags.A.B","flags[0]","many.zzz","grid[1][1]","grid[1][2]","grid[2][0]","rot[3]","mat[3]","wide","wideu","half","mesh","target","id","sign","cache",".","[","]","a..b","parts..offset","[0]","..","parts[","parts[-1]","parts[99999999999999999999]"}) {
        for value in ([]Value{nil,true,i64(-1),i64(min(i64)),i64(max(i64)),u64(max(u64)),f64(1.5),f64(-0.5),transmute(f64)u64(0x7ff8000000000000),transmute(f64)u64(0x7ff0000000000000),f64(1e300),f64(-1e300),f64(18446744073709551615),f64(-9223372036854775808),"",   "Off","On","Auto","Down","a-name-that-is-far-longer-than-any-text-field-of-the-fixtures-can-hold",base.Entity(max(u64)),base.Entity_Id(max(u64)),base.Asset_Id{max(u64),max(u64)}}) {
            _=value_set(&s,root,data,path,value)
            _,_=value_get(&s,root,data,path)
        }
    }
    free_all(context.temp_allocator)
}

@(test)
hostile_type_indices :: proc(t:^testing.T) {
    s:Schema
    root:=hostile_fixture(t,&s)
    defer schema_destroy(&s)
    data:=make([]u8,s.types[root].size,context.temp_allocator)
    for bad in ([]Type_Index{Type_Index(len(s.types)),Type_Index(len(s.types)+1),TYPE_NONE}) {
        if hostile_on("index_schema_fields") {_=schema_fields(&s,bad)}
        if hostile_on("index_schema_choices") {_=schema_choices(&s,bad)}
        if hostile_on("index_schema_field") {_=schema_field(&s,bad,1)}
        if hostile_on("index_layout_hash") {_=schema_layout_hash(&s,bad)}
        if hostile_on("index_type_is_bytes") {_=type_is_bytes(&s,bad)}
        if hostile_on("index_path_resolve") {_,_,_=path_resolve(&s,bad,"a")}
        if hostile_on("index_path_resolve_empty") {_,_,_=path_resolve(&s,bad,"")}
        if hostile_on("index_value_get") {_,_=value_get(&s,bad,data,"")}
        if hostile_on("index_value_set") {_=value_set(&s,bad,data,"",true)}
        if hostile_on("index_value_slice") {_,_,_=value_slice(&s,bad,data,"")}
        if hostile_on("index_refs_collect") {
            refs:=make([dynamic]Ref,context.temp_allocator)
            _=refs_collect(&s,bad,&refs)
        }
        if hostile_on("index_layout_init") {
            l:Layout
            layout_init(&l,&s,bad,context.temp_allocator)
            layout_destroy(&l)
        }
        if hostile_on("index_text_write") {
            w:Writer
            writer_init(&w,allocator=context.temp_allocator)
            text_write(&w,&s,bad,data)
        }
        if hostile_on("index_text_read") {
            r:Text_Reader
            text_reader_init(&r,"{}",context.temp_allocator)
            _=text_read(&r,&s,bad,data)
        }
        if hostile_on("index_migration_src") {
            m:Migration
            migration_init(&m,&s,bad,&s,root,context.temp_allocator)
            migration_destroy(&m)
        }
        if hostile_on("index_migration_dst") {
            m:Migration
            migration_init(&m,&s,root,&s,bad,context.temp_allocator)
            migration_destroy(&m)
        }
        if hostile_on("index_schema_import") {
            clone:Schema
            schema_clone(&clone,&s)
            hashes:[dynamic]u64
            link:Schema_Import
            schema_import_init(&link,&clone,&hashes,&s)
            _=schema_import(&link,bad)
            schema_import_destroy(&link)
            delete(hashes)
            schema_destroy(&clone)
        }
    }
    empty:Schema
    schema_init(&empty)
    defer schema_destroy(&empty)
    _,_=schema_find(&empty,0)
    _,_=schema_find(&s,0)
    if hostile_on("index_empty_schema") {_=schema_layout_hash(&empty,0)}
    free_all(context.temp_allocator)
}

// --------------------------------------------------------------------- refs

@(test)
hostile_refs :: proc(t:^testing.T) {
    h:=base.Hostile{15+HOSTILE_SEED}
    s:Schema
    root:=hostile_fixture(t,&s)
    defer schema_destroy(&s)
    for index in 0..<len(s.types) {
        for limit in ([]int{0,1,2,3,REFS_LIMIT,-1,min(int),max(int)}) {
            refs:=make([dynamic]Ref,context.temp_allocator)
            _=refs_collect(&s,Type_Index(index),&refs,limit)
        }
    }
    refs:=make([dynamic]Ref,context.temp_allocator)
    _=refs_collect(&s,root,&refs)
    visited:=0
    stride:=int(s.types[root].size)
    rows:=hostile_bytes(&h,stride*4)
    refs_visit(refs[:],rows,stride,4,hostile_visit,&visited)
    refs_visit(refs[:],rows,stride,0,hostile_visit,&visited)
    refs_visit(refs[:],rows,stride,-5,hostile_visit,&visited)
    refs_visit(nil,rows,stride,4,hostile_visit,&visited)
    refs_visit(refs[:],nil,0,0,hostile_visit,&visited)
    if hostile_on("refs_visit_short") {refs_visit(refs[:],rows[:stride],stride,2,hostile_visit,&visited)}
    if hostile_on("refs_visit_count") {refs_visit(refs[:],rows,stride,1<<40,hostile_visit,&visited)}
    if hostile_on("refs_visit_negative_stride") {refs_visit(refs[:],rows,-stride,2,hostile_visit,&visited)}
    if hostile_on("refs_visit_big_stride") {refs_visit(refs[:],rows,max(int)/2,2,hostile_visit,&visited)}
    if hostile_on("refs_visit_offsets") {
        wild:=[]Ref{{offset=max(u32),kind=.Entity},{offset=0,kind=.Entity}}
        refs_visit(wild,rows,stride,1,hostile_visit,&visited)
    }
    if hostile_on("refs_visit_unsorted") {
        wild:=[]Ref{{offset=u32(stride*8),kind=.Entity},{offset=0,kind=.Entity}}
        refs_visit(wild,rows,stride,1,hostile_visit,&visited)
    }
    free_all(context.temp_allocator)
}

// ------------------------------------------------- layout and migration

@(test)
hostile_layout_and_migration_arguments :: proc(t:^testing.T) {
    h:=base.Hostile{16+HOSTILE_SEED}
    s:Schema
    root:=hostile_fixture(t,&s)
    defer schema_destroy(&s)
    size:=int(s.types[root].size)
    l:Layout
    layout_init(&l,&s,root,context.temp_allocator)
    defer layout_destroy(&l)
    data:=hostile_bytes(&h,size*4)
    out:=make([]u8,size*4,context.temp_allocator)
    value_write(&l,out,raw_data(data),0)
    value_write(&l,out,raw_data(data),-1)
    value_write(&l,out,raw_data(data),min(int))
    value_write(&l,nil,nil,0)
    if hostile_on("value_write_short") {value_write(&l,out[:size-1],raw_data(data),1)}
    if hostile_on("value_write_nil_dst") {value_write(&l,nil,raw_data(data),1)}
    if hostile_on("value_write_overflow") {value_write(&l,out,raw_data(data),(1<<62)/size*4+1)}
    if hostile_on("value_write_nil_src") {value_write(&l,out,nil,1)}

    m:Migration
    migration_init(&m,&s,root,&s,root,context.temp_allocator)
    defer migration_destroy(&m)
    migration_apply(&m,out,data,0)
    migration_apply(&m,out,data,-1)
    migration_apply(&m,out,data,min(int))
    migration_apply(&m,out,data,4,data[:size])
    if hostile_on("migration_apply_short_dst") {migration_apply(&m,out[:size],data,2)}
    if hostile_on("migration_apply_short_src") {migration_apply(&m,out,data[:size],2)}
    if hostile_on("migration_apply_short_default") {migration_apply(&m,out,data,1,out[:size-1])}
    if hostile_on("migration_apply_overflow") {migration_apply(&m,out,data,(1<<62)/size*4+1)}
    value_read(&m,raw_data(out),data,0)
    if hostile_on("value_read_negative") {value_read(&m,raw_data(out),data,-1)}
    if hostile_on("value_read_nil_dst") {value_read(&m,nil,data,1)}
    if hostile_on("value_read_short_src") {value_read(&m,raw_data(out),data[:size-1],1)}

    other:Schema
    schema_init(&other)
    defer schema_destroy(&other)
    other_root,ok:=schema_add(&other,Smaller)
    testing.expect(t,ok)
    for count in 0..=2 {
        small:=hostile_bytes(&h,count*int(other.types[other_root].size))
        mig:Migration
        migration_init(&mig,&other,other_root,&s,root,context.temp_allocator)
        into:=make([]u8,count*size,context.temp_allocator)
        migration_apply(&mig,into,small,count)
        migration_apply(&mig,into,small,count,data[:size])
        migration_destroy(&mig)
        migration_init(&mig,&s,root,&other,other_root,context.temp_allocator)
        into=make([]u8,count*int(other.types[other_root].size),context.temp_allocator)
        migration_apply(&mig,into,data,count)
        migration_destroy(&mig)
    }
    free_all(context.temp_allocator)
}

@(private="file")
Smaller :: struct {
    id:u32,
    name:[6]u8 `mirai:"text"`,
    speed:f64,
    sign:Mode,
    flags:bit_set[Flag;u16],
    parts:[3]Part,
    count:i8,
    on:u8,
    wide:u128,
    half:f32,
    target:u64,
}

// ------------------------------------------------------------------ schema add

@(private="file") Negative :: enum i16 {Low=-300,Zero=0,High=300}
@(private="file") Sparse :: enum {Zero,Ten=10,Hundred=100}
@(private="file") Sixty :: enum {Late=60,Later=63}
@(private="file") Pad :: struct #packed {a:u8,b:u32,c:u16}
@(private="file") Aligned :: struct #align(64) {a:u8}
@(private="file") Union_Raw :: struct #raw_union {a:u32,b:f32}
@(private="file") Empty :: struct {}
@(private="file") Tags :: struct {
    a:f32 `mirai:"min=nan,max=inf,step=-1e999,precision=garbage,bits=999999,label=,unit=,requires="`,
    b:u8 `mirai:"bits=-5,,,=,min=,max=1e999,label==="`,
    c:u8 `mirai:`,
    d:u8 `mirai:"`,
    e:u8 `mirai:"transient,local,readonly,hidden,color,angle,text,unknown,min=1,min=2"`,
    f:[4]u8 `mirai:"text" other:"x"`,
    g:f32 `x:"y" mirai:"label=\"quoted\",unit=\n"`,
    h:u8 `mirai:"requires=1234567890"`,
}

@(test)
hostile_schema_add :: proc(t:^testing.T) {
    check :: proc(t:^testing.T,s:^Schema,index:Type_Index,ok:bool) {
        if !ok {return}
        h:=base.Hostile{99+HOSTILE_SEED}
        if schema_validate(s)==.None {
            weights:=hostile_weights(s)
            if weights[index]<=HOSTILE_WEIGHT && s.types[index].size<=1<<16 {
                hostile_walk_type(&h,s,s,weights,index)
            }
        }
        w:Writer
        writer_init(&w,allocator=context.temp_allocator)
        schema_write(&w,s)
        r:=reader_init(writer_bytes(&w))
        loaded:Schema
        if schema_read(&r,&loaded)==.None {schema_destroy(&loaded)}
        free_all(context.temp_allocator)
    }
    s:Schema
    schema_init(&s)
    defer schema_destroy(&s)
    index,ok:=schema_add(&s,[0]u8);check(t,&s,index,ok)
    index,ok=schema_add(&s,Empty);check(t,&s,index,ok)
    index,ok=schema_add(&s,[0]Empty);check(t,&s,index,ok)
    index,ok=schema_add(&s,[3]Empty);check(t,&s,index,ok)
    index,ok=schema_add(&s,Negative);check(t,&s,index,ok)
    index,ok=schema_add(&s,Sparse);check(t,&s,index,ok)
    index,ok=schema_add(&s,bit_set[Sixty;u64]);check(t,&s,index,ok)
    index,ok=schema_add(&s,bit_set['a'..='z';u32]);check(t,&s,index,ok)
    index,ok=schema_add(&s,bit_set[0..=3;u8]);check(t,&s,index,ok)
    index,ok=schema_add(&s,bit_set[0..<128;u128]);check(t,&s,index,ok)
    index,ok=schema_add(&s,Pad);check(t,&s,index,ok)
    index,ok=schema_add(&s,Aligned);check(t,&s,index,ok)
    index,ok=schema_add(&s,Tags);check(t,&s,index,ok)
    index,ok=schema_add(&s,matrix[3,3]f32);check(t,&s,index,ok)
    index,ok=schema_add(&s,matrix[2,3]f32);check(t,&s,index,ok)
    index,ok=schema_add(&s,matrix[4,4]f16);check(t,&s,index,ok)
    index,ok=schema_add(&s,quaternion64);check(t,&s,index,ok)
    index,ok=schema_add(&s,quaternion256);check(t,&s,index,ok)
    index,ok=schema_add(&s,complex64);check(t,&s,index,ok)
    index,ok=schema_add(&s,#sparse[Sparse]u8);check(t,&s,index,ok)
    index,ok=schema_add(&s,[2][2][2][2][2][2][2][2][2][2][2][2][2][2][2][2][2][2][2][2][2][2][2][2][2][2][2][2][2][2][2][2][2][2][2][2][2][2]u8);check(t,&s,index,ok)
    index,ok=schema_add(&s,b8);check(t,&s,index,ok)
    index,ok=schema_add(&s,i128);check(t,&s,index,ok)
    index,ok=schema_add(&s,Union_Raw);check(t,&s,index,ok)
    index,ok=schema_add(&s,string);check(t,&s,index,ok)
    index,ok=schema_add(&s,cstring);check(t,&s,index,ok)
    index,ok=schema_add(&s,^u8);check(t,&s,index,ok)
    index,ok=schema_add(&s,rawptr);check(t,&s,index,ok)
    index,ok=schema_add(&s,[]u8);check(t,&s,index,ok)
    index,ok=schema_add(&s,[dynamic]u8);check(t,&s,index,ok)
    index,ok=schema_add(&s,map[int]int);check(t,&s,index,ok)
    index,ok=schema_add(&s,union{u8,u16});check(t,&s,index,ok)
    index,ok=schema_add(&s,Maybe(u8));check(t,&s,index,ok)
    index,ok=schema_add(&s,any);check(t,&s,index,ok)
    index,ok=schema_add(&s,typeid);check(t,&s,index,ok)
    index,ok=schema_add(&s,proc());check(t,&s,index,ok)
    index,ok=schema_add(&s,#soa[4]Part);check(t,&s,index,ok)
    index,ok=schema_add(&s,struct{a:u8,b:struct{c:[]u8}});check(t,&s,index,ok)
    index,ok=schema_add(&s,[4]struct{c:^int});check(t,&s,index,ok)
    index,ok=schema_add(&s,bit_field u32 {a:u8|3,b:u8|5});check(t,&s,index,ok)
    _,_=schema_add_type_info(&s,type_info_of(Fixture))
    _,_=schema_add_type_info(&s,type_info_of(Fixture))
    _=type_label(type_info_of(Fixture))
    _=type_label(type_info_of(any))
}

// ------------------------------------------------------------------- files

@(test)
hostile_files :: proc(t:^testing.T) {
    path:=test_path("hostile.bin")
    defer os.remove(path)
    contents:=[?]u8{1,2,3,4,5,6,7,8,9,10}
    testing.expect_value(t,file_write_atomic(path,contents[:]),File_Error.None)
    directory,_:=os.temp_directory(context.temp_allocator)
    long_name:=strings.repeat("a",3000,context.temp_allocator)
    medium_name:=strings.repeat("b",1000,context.temp_allocator)
    paths:=[]string{"","/","\\",".","..",directory,"NUL","\x00","a\x00b",fmt.tprintf("%s/%s",directory,long_name),fmt.tprintf("%s/%s",directory,medium_name),"<>|*?\"","::","C:"}
    writes:=[]string{"","\x00","a\x00b",paths[9],paths[10],"<>|*?\"","::"}
    buffer:[16]u8
    for candidate in paths {
        if hostile_on("file_read") {
            data,_:=file_read(candidate)
            delete(data)
        }
        if hostile_on("file_read_head") {_,_,_=file_read_head(candidate,buffer[:])}
        if hostile_on("file_read_range") {_=file_read_range(candidate,0,buffer[:])}
    }
    for candidate in writes {
        if hostile_on("file_write") {
            if file_write_atomic(candidate,contents[:])==.None {os.remove(candidate)}
        }
    }
    for limit in ([]i64{-1,0,1,9,10,11,min(i64),max(i64)}) {
        data,_:=file_read(path,limit=limit)
        delete(data)
    }
    for alignment in ([]int{0,1,2,3,7,8,64,4096,-1,min(int),1<<40}) {
        if !hostile_on("file_alignment") {break}
        data,_:=file_read(path,alignment=alignment)
        delete(data)
    }
    for offset in ([]i64{-1,min(i64),max(i64),0,1,9,10,11,1<<40}) {
        _=file_read_range(path,offset,buffer[:])
        _=file_read_range(path,offset,nil)
        _=file_read_range(path,offset,buffer[:0])
    }
    _,_,_=file_read_head(path,nil)
    big:=make([]u8,1<<16)
    defer delete(big)
    head,size,_:=file_read_head(path,big)
    testing.expect(t,len(head)==10 && size==10)
    _=file_write_atomic(path,nil)
    _=file_write_atomic(path,nil,sync=true)
    data,error:=file_read(path)
    testing.expect(t,data==nil && error==.None)
}

@(private="file")
hostile_pick :: proc(h:^base.Hostile,values:[]int) -> int {return values[base.hostile_int(h,len(values))]}

@(private="file")
hostile_pick_string :: proc(h:^base.Hostile,values:[]string) -> string {return values[base.hostile_int(h,len(values))]}
