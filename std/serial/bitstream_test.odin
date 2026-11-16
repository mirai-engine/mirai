package serial

import "core:math"
import "core:testing"

@(private="file")
bit_test_next :: proc(state:^u64) -> u64 {
    state^+=0x9e3779b97f4a7c15
    z:=state^
    z=(z~(z>>30))*0xbf58476d1ce4e5b9
    z=(z~(z>>27))*0x94d049bb133111eb
    return z~(z>>31)
}
@(private="file")
bit_test_unit :: proc(state:^u64) -> f32 {return f32(bit_test_next(state)>>40)/f32(1<<24)}

@(test)
bit_stream_round_trips_every_kind_of_value :: proc(t:^testing.T) {
    buffer:[256]u8
    w:Bit_Writer;bit_writer_init(&w,buffer[:])
    bit_write(&w,5,3)
    bit_write_bool(&w,true)
    bit_write(&w,0xdeadbeefcafef00d,64)
    bit_write_ranged(&w,-3,-10,10)
    bit_write_varuint(&w,300)
    bit_write_varuint(&w,max(u64))
    bit_write_varint(&w,-123456789)
    bit_write_varint(&w,min(i64))
    bit_write_f32(&w,3.25)
    bit_write_f64(&w,-1e300)
    bit_write_float_range(&w,0.5,-1,1,12)
    bit_write_float_precision(&w,12.34,0,100,0.01)
    bit_write_string(&w,"mirai")
    bit_write_align(&w)
    testing.expect_value(t,bit_writer_bits(&w)%8,0)
    bit_write_bytes(&w,{1,2,3,4,5,6,7,8,9,10,11})
    bit_write(&w,1,1)
    testing.expect(t,!w.overflow)
    bytes:=bit_writer_flush(&w)
    testing.expect_value(t,len(bytes),bit_writer_bytes(&w))

    r:Bit_Reader;bit_reader_init(&r,bytes,bit_writer_bits(&w))
    testing.expect_value(t,bit_read(&r,3),u64(5))
    testing.expect_value(t,bit_read_bool(&r),true)
    testing.expect_value(t,bit_read(&r,64),u64(0xdeadbeefcafef00d))
    testing.expect_value(t,bit_read_ranged(&r,-10,10),i64(-3))
    testing.expect_value(t,bit_read_varuint(&r),u64(300))
    testing.expect_value(t,bit_read_varuint(&r),max(u64))
    testing.expect_value(t,bit_read_varint(&r),i64(-123456789))
    testing.expect_value(t,bit_read_varint(&r),min(i64))
    testing.expect_value(t,bit_read_f32(&r),f32(3.25))
    testing.expect_value(t,bit_read_f64(&r),f64(-1e300))
    testing.expect(t,abs(bit_read_float_range(&r,-1,1,12)-0.5)<=1.0/4095)
    testing.expect(t,abs(bit_read_float_precision(&r,0,100,0.01)-12.34)<=0.005001)
    storage:[16]u8
    testing.expect_value(t,bit_read_string(&r,storage[:]),"mirai")
    bit_read_align(&r)
    out:[11]u8
    testing.expect(t,bit_read_bytes(&r,out[:]))
    testing.expect_value(t,out,[11]u8{1,2,3,4,5,6,7,8,9,10,11})
    testing.expect_value(t,bit_read(&r,1),u64(1))
    testing.expect(t,bit_reader_ok(&r))
    testing.expect_value(t,bit_reader_remaining(&r),0)
    bit_read(&r,1)
    testing.expect(t,!bit_reader_ok(&r))
}

@(private="file")
Bit_Test_Op :: struct {kind:u8,bits:u8,value:u64,length:u8}

@(test)
bit_stream_fuzzed_round_trip_matches_what_was_written_and_measured :: proc(t:^testing.T) {
    state:=u64(0x1234)
    buffer:[4096]u8
    payload:[64]u8
    for &b,i in payload {b=u8(i*37+11)}
    ops:[200]Bit_Test_Op
    for iteration in 0..<400 {
        count:=1+int(bit_test_next(&state)%len(ops))
        w,m:Bit_Writer
        bit_writer_init(&w,buffer[:]);bit_writer_init_measure(&m)
        for &op in ops[:count] {
            op={kind=u8(bit_test_next(&state)%6),bits=u8(1+bit_test_next(&state)%64),value=bit_test_next(&state),length=u8(bit_test_next(&state)%len(payload))}
            if bit_test_next(&state)%4==0 {op.value>>=bit_test_next(&state)%64}
            for target in ([2]^Bit_Writer{&w,&m}) {
                switch op.kind {
                case 0: bit_write(target,op.value,int(op.bits))
                case 1: bit_write_varuint(target,op.value)
                case 2: bit_write_varint(target,i64(op.value))
                case 3: bit_write_bytes(target,payload[:op.length])
                case 4: bit_write_align(target)
                case 5: bit_write_ranged(target,i64(op.value%1000)-500,-500,499)
                }
            }
        }
        testing.expect(t,!w.overflow)
        testing.expect_value(t,bit_writer_bits(&m),bit_writer_bits(&w))
        r:Bit_Reader;bit_reader_init(&r,bit_writer_flush(&w),bit_writer_bits(&w))
        for op in ops[:count] {
            switch op.kind {
            case 0:
                expected:=op.bits==64?op.value:op.value&(u64(1)<<op.bits-1)
                if bit_read(&r,int(op.bits))!=expected {testing.expect(t,false,"bits differ");return}
            case 1: if bit_read_varuint(&r)!=op.value {testing.expect(t,false,"varuint differs");return}
            case 2: if bit_read_varint(&r)!=i64(op.value) {testing.expect(t,false,"varint differs");return}
            case 3:
                out:[64]u8
                bit_read_bytes(&r,out[:op.length])
                for i in 0..<int(op.length) {if out[i]!=payload[i] {testing.expect(t,false,"bytes differ");return}}
            case 4: bit_read_align(&r)
            case 5: if bit_read_ranged(&r,-500,499)!=i64(op.value%1000)-500 {testing.expect(t,false,"ranged differs");return}
            }
        }
        testing.expect(t,bit_reader_ok(&r))
        testing.expect_value(t,bit_reader_remaining(&r),0)
    }
}

@(test)
bit_writer_overflow_is_reported_and_writes_nothing_past_the_buffer :: proc(t:^testing.T) {
    storage:[24]u8
    for &b in storage {b=0xaa}
    w:Bit_Writer;bit_writer_init(&w,storage[4:14])
    bit_write(&w,max(u64),64)
    bit_write(&w,0x1ff,9)
    mark:=w
    bit_write(&w,0xff,8)
    testing.expect(t,w.overflow)
    bit_write(&w,1,1)
    testing.expect_value(t,bit_writer_bits(&w),73)
    w=mark
    testing.expect(t,!w.overflow)
    bit_write(&w,0x7f,7)
    testing.expect(t,!w.overflow)
    testing.expect_value(t,bit_writer_remaining(&w),0)
    bytes:=bit_writer_flush(&w)
    testing.expect_value(t,len(bytes),10)
    for b in bytes {testing.expect_value(t,b,u8(0xff))}
    for b in storage[:4] {testing.expect_value(t,b,u8(0xaa))}
    for b in storage[14:] {testing.expect_value(t,b,u8(0xaa))}
    bit_write_bytes(&w,{1})
    bit_write_string(&w,"x")
    testing.expect(t,w.overflow)
}

@(test)
bit_reader_fed_random_bytes_fails_cleanly :: proc(t:^testing.T) {
    state:=u64(77)
    storage:[40]u8
    scratch:[16]u8
    for iteration in 0..<2000 {
        length:=int(bit_test_next(&state)%33)
        for &b in storage {b=u8(bit_test_next(&state))}
        r:Bit_Reader;bit_reader_init(&r,storage[4:4+length])
        for step in 0..<64 {
            switch bit_test_next(&state)%8 {
            case 0: bit_read(&r,int(bit_test_next(&state)%70))
            case 1: bit_read_varuint(&r)
            case 2: bit_read_string(&r,scratch[:])
            case 3: bit_read_bytes(&r,scratch[:bit_test_next(&state)%17])
            case 4: bit_read_ranged(&r,-5,900)
            case 5: bit_read_quaternion(&r,int(bit_test_next(&state)%30))
            case 6: bit_read_unit_vector(&r,int(bit_test_next(&state)%30))
            case 7: bit_read_align(&r)
            }
        }
        testing.expect(t,r.position<=length*8)
        if r.error {
            testing.expect_value(t,bit_read(&r,1),u64(0))
            testing.expect_value(t,bit_reader_remaining(&r),0)
        }
    }
    limited:Bit_Reader;bit_reader_init(&limited,storage[:2],17)
    testing.expect(t,!bit_reader_ok(&limited))
    huge:=[?]u8{0xff,0xff,0xff,0xff,0x0f}
    text:Bit_Reader;bit_reader_init(&text,huge[:])
    testing.expect_value(t,bit_read_string(&text,scratch[:]),"")
    testing.expect(t,text.error)
    endless:=[?]u8{0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff}
    varint:Bit_Reader;bit_reader_init(&varint,endless[:])
    bit_read_varuint(&varint)
    testing.expect(t,varint.error)
}

@(test)
quantize_floats_stay_within_half_a_step :: proc(t:^testing.T) {
    state:=u64(9)
    for bits in 1..=24 {
        step:=200.0/f64(u64(1)<<uint(bits)-1)
        for _ in 0..<200 {
            value:=bit_test_unit(&state)*200-100
            back:=dequantize_range(quantize_range(value,-100,100,bits),-100,100,bits)
            testing.expect(t,abs(f64(back)-f64(value))<=step*0.5+1e-4)
        }
        testing.expect_value(t,dequantize_range(quantize_range(-100,-100,100,bits),-100,100,bits),f32(-100))
        testing.expect_value(t,dequantize_range(quantize_range(100,-100,100,bits),-100,100,bits),f32(100))
    }
    testing.expect_value(t,quantize_range(500,-1,1,8),u32(255))
    testing.expect_value(t,quantize_range(math.nan_f32(),-1,1,8),u32(0))
    testing.expect_value(t,quantize_precision_bits(0,100,0.01),14)
    for _ in 0..<500 {
        value:=bit_test_unit(&state)*1000-500
        back:=dequantize_precision(quantize_precision(value,-500,500,0.01),-500,500,0.01)
        testing.expect(t,abs(back-value)<=0.0051)
    }
    testing.expect(t,abs(dequantize_precision(quantize_precision(9999,-500,500,0.01),-500,500,0.01)-500)<0.001)
}

@(test)
quantize_unit_vectors_and_quaternions_keep_their_direction :: proc(t:^testing.T) {
    state:=u64(31)
    worst_vector,worst_rotation:f64
    for _ in 0..<4000 {
        v:=[3]f64{f64(bit_test_unit(&state))*2-1,f64(bit_test_unit(&state))*2-1,f64(bit_test_unit(&state))*2-1}
        length:=math.sqrt(v.x*v.x+v.y*v.y+v.z*v.z)
        if length<0.05 {continue}
        unit:=[3]f32{f32(v.x/length),f32(v.y/length),f32(v.z/length)}
        back:=dequantize_unit_vector(quantize_unit_vector(unit,12),12)
        worst_vector=max(worst_vector,math.acos(clamp(f64(unit.x*back.x+unit.y*back.y+unit.z*back.z),-1,1)))

        c:=[4]f64{f64(bit_test_unit(&state))*2-1,f64(bit_test_unit(&state))*2-1,f64(bit_test_unit(&state))*2-1,f64(bit_test_unit(&state))*2-1}
        norm:=math.sqrt(c[0]*c[0]+c[1]*c[1]+c[2]*c[2]+c[3]*c[3])
        if norm<0.05 {continue}
        q:=quaternion(w=f32(c[3]/norm),x=f32(c[0]/norm),y=f32(c[1]/norm),z=f32(c[2]/norm))
        p:=dequantize_quaternion(quantize_quaternion(q,12),12)
        dot:=abs(f64(q.x*p.x+q.y*p.y+q.z*p.z+q.w*p.w))
        worst_rotation=max(worst_rotation,2*math.acos(clamp(dot,0,1)))
    }
    testing.expect(t,worst_vector<0.0015)
    testing.expect(t,worst_rotation<0.0025)
    testing.expect_value(t,dequantize_unit_vector(quantize_unit_vector({0,0,-1},16),16),[3]f32{0,0,-1})
    testing.expect(t,dequantize_unit_vector(quantize_unit_vector({0,0,0},16),16).z>0.9999)
    identity:=dequantize_quaternion(quantize_quaternion(quaternion(w=1,x=0,y=0,z=0),10),10)
    testing.expect(t,abs(identity.w-1)<1e-5)
    zero:=dequantize_quaternion(quantize_quaternion(quaternion128(0),10),10)
    testing.expect(t,abs(zero.w-1)<1e-5)
    buffer:[32]u8
    w:Bit_Writer;bit_writer_init(&w,buffer[:])
    bit_write_unit_vector(&w,{0,1,0},10)
    bit_write_quaternion(&w,quaternion(w=0,x=0,y=1,z=0),9)
    testing.expect_value(t,bit_writer_bits(&w),20+29)
    r:Bit_Reader;bit_reader_init(&r,bit_writer_flush(&w))
    up:=bit_read_unit_vector(&r,10)
    turn:=bit_read_quaternion(&r,9)
    testing.expect(t,abs(up.y-1)<0.01 && abs(turn.y-1)<0.01)
}
