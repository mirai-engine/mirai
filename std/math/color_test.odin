package mirai_math

import "core:math"
import "core:math/linalg"
import "core:testing"

@(test)
srgb_and_linear_convert_both_ways :: proc(t:^testing.T) {
    testing.expect_value(t,srgb_to_linear(f32(0)),f32(0))
    testing.expect(t,test_close(srgb_to_linear(f32(1)),1,1e-6))
    testing.expect(t,test_close(srgb_to_linear(f32(0.5)),0.21404114,1e-6),"Middle gray of a display is 21% of the light")
    testing.expect(t,test_close(linear_to_srgb(f32(0.21404114)),0.5,1e-6))
    testing.expect(t,test_close(srgb_to_linear(f32(0.04)),0.04/12.92,1e-7),"The dark end is a straight line")
    for step in 0..=255 {
        encoded:=f32(step)/255
        if !test_close(linear_to_srgb(srgb_to_linear(encoded)),encoded,1e-5) {testing.expectf(t,false,"%d does not round trip",step);break}
    }
    color:=srgb_to_linear(Vec3{1,0.5,0})
    testing.expect(t,test_close3(color,{1,0.21404114,0},1e-6))
    testing.expect(t,test_close3(linear_to_srgb(color),{1,0.5,0},1e-6))
    with_alpha:=srgb_to_linear(Vec4{0.5,0.5,0.5,0.5})
    testing.expect(t,test_close(with_alpha.x,0.21404114,1e-6) && with_alpha.w==0.5,"Alpha is not encoded")
    testing.expect_value(t,linear_to_srgb(with_alpha).w,f32(0.5))
}

@(test)
hsv_and_hsl_convert_both_ways :: proc(t:^testing.T) {
    testing.expect_value(t,hsv_to_rgb({0,1,1}),Vec3{1,0,0})
    testing.expect(t,test_close3(hsv_to_rgb({1.0/3,1,1}),{0,1,0},1e-6))
    testing.expect(t,test_close3(hsv_to_rgb({2.0/3,1,0.5}),{0,0,0.5},1e-6))
    testing.expect(t,test_close3(hsv_to_rgb({1.0/6,0.5,1}),{1,1,0.5},1e-6))
    testing.expect_value(t,hsv_to_rgb({0.7,0,0.3}),Vec3{0.3,0.3,0.3})
    testing.expect(t,test_close3(hsv_to_rgb({1.25,1,1}),hsv_to_rgb({0.25,1,1}),1e-5),"The hue wraps around")
    testing.expect(t,test_close3(hsv_to_rgb({-0.75,1,1}),hsv_to_rgb({0.25,1,1}),1e-5))
    testing.expect_value(t,rgb_to_hsv({0.3,0.3,0.3}),Vec3{0,0,0.3})
    testing.expect(t,test_close3(rgb_to_hsv({1,0,0}),{0,1,1}) && test_close3(rgb_to_hsv({0,0,0.5}),{2.0/3,1,0.5}))
    testing.expect(t,test_close3(rgb_to_hsv({1,0,0.5}),{11.0/12,1,1}),"Magenta-red hues are just below a full turn")
    testing.expect(t,test_close3(hsl_to_rgb({0,1,0.5}),{1,0,0},1e-6) && test_close3(hsl_to_rgb({2.0/3,1,0.25}),{0,0,0.5},1e-6))
    testing.expect(t,test_close3(hsl_to_rgb({0.3,0,0.7}),{0.7,0.7,0.7},1e-6))
    testing.expect(t,test_close3(rgb_to_hsl({0,0,0.5}),{2.0/3,1,0.25},1e-6))
    rng:=rng_make(31)
    for _ in 0..<500 {
        rgb:=Vec3{random_f32(&rng),random_f32(&rng),random_f32(&rng)}
        if !test_close3(hsv_to_rgb(rgb_to_hsv(rgb)),rgb,1e-4) || !test_close3(hsl_to_rgb(rgb_to_hsl(rgb)),rgb,1e-4) {testing.expectf(t,false,"%v does not round trip",rgb);break}
    }
}

@(test)
oklab_matches_its_reference_colors :: proc(t:^testing.T) {
    testing.expect(t,test_close3(linear_to_oklab({1,1,1}),{1,0,0},1e-4),"White is full lightness without color")
    testing.expect_value(t,linear_to_oklab({0,0,0}),Vec3{0,0,0})
    testing.expect(t,test_close3(linear_to_oklab({1,0,0}),{0.62796,0.22486,0.12585},1e-4))
    testing.expect(t,test_close3(linear_to_oklab({0,1,0}),{0.86644,-0.23389,0.17950},1e-4))
    testing.expect(t,test_close3(linear_to_oklab({0,0,1}),{0.45201,-0.03246,-0.31153},1e-4))
    rng:=rng_make(32)
    for _ in 0..<500 {
        rgb:=Vec3{random_f32(&rng),random_f32(&rng),random_f32(&rng)}
        if !test_close3(oklab_to_linear(linear_to_oklab(rgb)),rgb,1e-4) {testing.expectf(t,false,"%v does not round trip",rgb);break}
    }
    // Between blue and yellow, linear RGB passes through gray; OKLab keeps the lightness rising evenly.
    blue,yellow:=Vec4{0,0,1,1},Vec4{1,1,0,0}
    testing.expect(t,test_close3(color_mix_oklab(blue,yellow,0).xyz,blue.xyz,1e-4) && test_close3(color_mix_oklab(blue,yellow,1).xyz,yellow.xyz,1e-4))
    middle:=color_mix_oklab(blue,yellow,0.5)
    testing.expect_value(t,middle.w,f32(0.5))
    expected:=(linear_to_oklab(blue.xyz).x+linear_to_oklab(yellow.xyz).x)*0.5
    testing.expect(t,test_close(linear_to_oklab(middle.xyz).x,expected,1e-4))
    testing.expect(t,linalg.length(middle.xyz-Vec3{0.5,0.5,0.5})>0.1,"The middle is not the gray of the linear mix")
}

@(test)
gradient_blends_between_its_stops :: proc(t:^testing.T) {
    stops:=[3]Gradient_Stop{{0.2,{1,0,0,1}},{0.5,{0,1,0,1}},{1,{0,0,1,0}}}
    testing.expect_value(t,gradient_evaluate(stops[:],0),Vec4{1,0,0,1})
    testing.expect_value(t,gradient_evaluate(stops[:],0.2),Vec4{1,0,0,1})
    testing.expect(t,linalg.length(gradient_evaluate(stops[:],0.35)-Vec4{0.5,0.5,0,1})<1e-5)
    testing.expect_value(t,gradient_evaluate(stops[:],0.5),Vec4{0,1,0,1})
    testing.expect(t,linalg.length(gradient_evaluate(stops[:],0.75)-Vec4{0,0.5,0.5,0.5})<1e-5)
    testing.expect_value(t,gradient_evaluate(stops[:],1),Vec4{0,0,1,0})
    testing.expect_value(t,gradient_evaluate(stops[:],7),Vec4{0,0,1,0})
    testing.expect_value(t,gradient_evaluate(nil,0.5),Vec4{})
    testing.expect_value(t,gradient_evaluate(stops[:1],0.9),Vec4{1,0,0,1})
    perceptual:=gradient_evaluate(stops[:],0.35,.Oklab)
    testing.expect(t,linalg.length(perceptual-color_mix_oklab(stops[0].color,stops[1].color,0.5))<1e-5)
    testing.expect(t,linalg.length(gradient_evaluate(stops[:],0.5,.Oklab).xyz-Vec3{0,1,0})<1e-4)
    // Two stops at the same position make a hard edge.
    edge:=[2]Gradient_Stop{{0.5,{1,1,1,1}},{0.5,{0,0,0,1}}}
    testing.expect_value(t,gradient_evaluate(edge[:],0.4),Vec4{1,1,1,1})
    testing.expect_value(t,gradient_evaluate(edge[:],0.6),Vec4{0,0,0,1})
}

@(test)
rgba8_packs_red_in_the_low_byte :: proc(t:^testing.T) {
    testing.expect_value(t,rgba8_pack({1,0,0,0}),u32(0x000000ff))
    testing.expect_value(t,rgba8_pack({0,1,0,0}),u32(0x0000ff00))
    testing.expect_value(t,rgba8_pack({0,0,1,0}),u32(0x00ff0000))
    testing.expect_value(t,rgba8_pack({0,0,0,1}),u32(0xff000000))
    testing.expect_value(t,rgba8_pack({0.5,2,-1,0.2}),u32(0x3300ff80))
    testing.expect(t,linalg.length(rgba8_unpack(0x3300ff80)-Vec4{128.0/255,1,0,0.2})<1e-6)
    for value in ([4]u32{0,0xffffffff,0x12345678,0x80c0e0f0}) {testing.expect_value(t,rgba8_pack(rgba8_unpack(value)),value)}
    // Linear half gray is sRGB 188; alpha is stored as it is.
    testing.expect_value(t,rgba8_from_linear({0.5,0.5,0.5,0.5}),u32(0x80bcbcbc))
    testing.expect(t,linalg.length(rgba8_to_linear(0x80bcbcbc)-Vec4{0.5,0.5,0.5,0.5})<0.01)
}

@(test)
rgb9e5_keeps_a_wide_range_within_its_mantissa :: proc(t:^testing.T) {
    testing.expect_value(t,rgb9e5_pack({0,0,0}),u32(0))
    testing.expect_value(t,rgb9e5_unpack(rgb9e5_pack({1,0,0})),Vec3{1,0,0})
    for c in ([]Vec3{{0.25,0.5,0.75},{3,40,500},{2000,10,0.5},{1e-3,2e-3,0}}) {
        back:=rgb9e5_unpack(rgb9e5_pack(c))
        high:=max(c.x,c.y,c.z)
        for axis in 0..<3 {testing.expectf(t,abs(back[axis]-c[axis])<=high/256,"%v comes back as %v",c,back)}
    }
    // Past its largest value it saturates, and what is not a light is none.
    testing.expect_value(t,rgb9e5_unpack(rgb9e5_pack({1e9,0,0})),Vec3{RGB9E5_MAX,0,0})
    testing.expect_value(t,rgb9e5_pack({-1,-5,0}),u32(0))
}

@(test)
hex_colors_parse_and_format :: proc(t:^testing.T) {
    color,ok:=color_parse_hex("#ff8000")
    testing.expect(t,ok && linalg.length(color-Vec4{1,0.21586053,0,1})<1e-5)
    color,ok=color_parse_hex("FF800080")
    testing.expect(t,ok && linalg.length(color-Vec4{1,0.21586053,0,128.0/255})<1e-5,"Alpha is not sRGB encoded")
    color,ok=color_parse_hex("#f80")
    testing.expect(t,ok && linalg.length(color-Vec4{1,srgb_to_linear(f32(0x88)/255),0,1})<1e-5,"Short digits repeat")
    color,ok=color_parse_hex("#0008")
    testing.expect(t,ok && linalg.length(color-Vec4{0,0,0,f32(0x88)/255})<1e-6)
    for bad in ([6]string{"","#","#12","#12345","#gggggg","#1234567"}) {
        _,ok=color_parse_hex(bad)
        testing.expectf(t,!ok,"'%s' is not a color",bad)
    }
    buffer:[9]u8
    testing.expect_value(t,color_format_hex({1,0.21586053,0,1},buffer[:]),"#ff8000ff")
    testing.expect_value(t,color_format_hex({0,0,0,0.5},buffer[:]),"#00000080")
    testing.expect_value(t,color_format_hex({1,1,1,1},buffer[:8]),"")
    rng:=rng_make(33)
    for _ in 0..<200 {
        packed:=rng_u32(&rng)
        text:=color_format_hex(rgba8_to_linear(packed),buffer[:])
        parsed,parsed_ok:=color_parse_hex(text)
        if !parsed_ok || rgba8_from_linear(parsed)!=packed {testing.expectf(t,false,"%s does not round trip",text);break}
    }
}

@(test)
quantize_keeps_the_ends_exact_and_the_error_within_half_a_step :: proc(t:^testing.T) {
    testing.expect_value(t,quantize(-5,-5,5,8),u32(0))
    testing.expect_value(t,quantize(5,-5,5,8),u32(255))
    testing.expect_value(t,quantize(99,-5,5,8),u32(255))
    testing.expect_value(t,quantize(-99,-5,5,8),u32(0))
    testing.expect_value(t,quantize(0,0,1,1),u32(0))
    testing.expect_value(t,quantize(0.6,0,1,1),u32(1))
    testing.expect_value(t,quantize(1,0,1,32),max(u32))
    testing.expect_value(t,quantize(3,2,2,8),u32(0))
    testing.expect_value(t,dequantize(0,-5,5,8),f32(-5))
    testing.expect_value(t,dequantize(255,-5,5,8),f32(5))
    testing.expect_value(t,dequantize(max(u32),0,1,32),f32(1))
    rng:=rng_make(41)
    for bits in ([5]uint{1,7,10,16,24}) {
        step:=f32(1024)/f32(u64(1)<<bits-1)
        for _ in 0..<500 {
            value:=random_range(&rng,-512,512)
            back:=dequantize(quantize(value,-512,512,bits),-512,512,bits)
            if abs(back-value)>step*0.5+1e-4 {testing.expectf(t,false,"%d bits: %v came back as %v",bits,value,back);break}
        }
    }
}

@(test)
normalized_and_half_packs_round_trip :: proc(t:^testing.T) {
    testing.expect_value(t,unorm8_pack(1),u8(255))
    testing.expect_value(t,unorm8_pack(0.5),u8(128))
    testing.expect_value(t,unorm8_pack(-3),u8(0))
    testing.expect_value(t,unorm8_unpack(255),f32(1))
    testing.expect_value(t,unorm16_pack(1),u16(65535))
    testing.expect(t,test_close(unorm16_unpack(unorm16_pack(0.25)),0.25,1e-5))
    testing.expect_value(t,snorm8_pack(-1),i8(-127))
    testing.expect_value(t,snorm8_pack(1),i8(127))
    testing.expect_value(t,snorm8_unpack(-128),f32(-1))
    testing.expect_value(t,snorm8_unpack(0),f32(0))
    testing.expect_value(t,snorm16_pack(0),i16(0))
    testing.expect_value(t,snorm16_pack(-7),i16(-32767))
    testing.expect_value(t,snorm16_pack(0.5),i16(16384))
    testing.expect_value(t,snorm16_unpack(32767),f32(1))
    testing.expect_value(t,snorm16_unpack(-32768),f32(-1))
    for i in -32767..=32767 {
        if snorm16_pack(snorm16_unpack(i16(i)))!=i16(i) {testing.expectf(t,false,"%d does not round trip",i);break}
    }
    testing.expect_value(t,half_pack(1),u16(0x3c00))
    testing.expect_value(t,half_pack(-2),u16(0xc000))
    testing.expect_value(t,half_pack(0),u16(0))
    testing.expect_value(t,half_unpack(0x3c00),f32(1))
    testing.expect_value(t,half_unpack(half_pack(0.15625)),f32(0.15625))
    testing.expect_value(t,half_unpack(half_pack(65504)),f32(65504))
    testing.expect(t,math.is_inf(half_unpack(half_pack(1e6))),"Beyond the range of a half")
    testing.expect(t,test_close(half_unpack(half_pack(3.14159)),3.14159,1e-3))
}

// The packing of the 40-byte mesh vertex of the previous engine, as its renderer wrote it.
@(private="file")
legacy_pack_normal :: proc(n:Vec3) -> u32 {
    snorm :: proc(v:f32) -> u32 {return u32(u16(i16(math.round(clamp(v,-1,1)*32767))))}
    l1:=abs(n.x)+abs(n.y)+abs(n.z)
    if l1<1e-12 {return snorm(0)|snorm(0)<<16}
    p:=Vec2{n.x/l1,n.y/l1}
    if n.z<0 {
        sx:f32=1 if p.x>=0 else -1
        sy:f32=1 if p.y>=0 else -1
        p=Vec2{(1-abs(p.y))*sx,(1-abs(p.x))*sy}
    }
    return snorm(p.x)|snorm(p.y)<<16
}
@(private="file")
legacy_unpack_normal :: proc(packed:u32) -> Vec3 {
    x:=f32(i16(u16(packed&0xffff)))/32767
    y:=f32(i16(u16(packed>>16)))/32767
    n:=Vec3{x,y,1-abs(x)-abs(y)}
    if n.z<0 {
        sx:f32=1 if n.x>=0 else -1
        sy:f32=1 if n.y>=0 else -1
        n.x,n.y=(1-abs(y))*sx,(1-abs(x))*sy
    }
    return n/math.sqrt(n.x*n.x+n.y*n.y+n.z*n.z)
}

@(test)
packed_normals_match_the_legacy_vertex :: proc(t:^testing.T) {
    testing.expect_value(t,normal_pack({0,0,1}),u32(0))
    testing.expect_value(t,normal_pack({1,0,0}),u32(0x00007fff))
    testing.expect_value(t,normal_pack({0,1,0}),u32(0x7fff0000))
    testing.expect_value(t,normal_pack({-1,0,0}),u32(0x00008001))
    testing.expect_value(t,normal_pack({0,0,-1}),u32(0x7fff7fff))
    testing.expect_value(t,normal_pack({}),u32(0))
    testing.expect_value(t,normal_unpack(0),Vec3{0,0,1})
    rng:=rng_make(42)
    worst:f32
    for _ in 0..<20000 {
        n:=random_unit_vec3(&rng)
        packed:=normal_pack(n)
        if packed!=legacy_pack_normal(n) || normal_unpack(packed)!=legacy_unpack_normal(packed) {testing.expectf(t,false,"%v packs differently",n);return}
        worst=max(worst,linalg.length(linalg.cross(normal_unpack(packed),n)))
        // Vectors that are not unit pack like their direction.
        if normal_pack(n*3.5)!=packed && linalg.length(normal_unpack(normal_pack(n*3.5))-normal_unpack(packed))>1e-3 {testing.expect(t,false,"Length changed the packing");return}
    }
    testing.expectf(t,worst<0.0001,"worst error: %v radians",worst)
    square:=octahedral_encode({0,0,-1})
    testing.expect(t,abs(square.x)==1 && abs(square.y)==1,"The pole opposite to +Z is at the corners of the square")
    testing.expect(t,test_close3(octahedral_decode(octahedral_encode(linalg.normalize(Vec3{1,-2,-3}))),linalg.normalize(Vec3{1,-2,-3}),1e-5))
}

@(test)
packed_tangents_keep_their_direction_and_the_sign_of_the_bitangent :: proc(t:^testing.T) {
    for sign in ([]f32{1,-1}) {
        tangent,back:=tangent_unpack(tangent_pack({1,0,0},sign))
        testing.expect(t,tangent==Vec3{1,0,0} && back==sign,"axes and zero are exact")
    }
    testing.expect_value(t,tangent_pack({0,0,1},1)&(1<<31),u32(0))
    rng:=rng_make(7)
    worst:f32
    for _ in 0..<20000 {
        n:=random_unit_vec3(&rng)
        sign:f32=1 if rng_u32(&rng)&1==0 else -1
        tangent,back:=tangent_unpack(tangent_pack(n,sign))
        if back!=sign {testing.expectf(t,false,"%v lost its sign",n);return}
        worst=max(worst,linalg.length(linalg.cross(tangent,n)))
    }
    testing.expectf(t,worst<0.0002,"worst error: %v radians",worst)
}

@(test)
packed_rotations_come_back_within_their_precision :: proc(t:^testing.T) {
    testing.expect_value(t,quat_unpack(quat_pack(QUAT_IDENTITY)),QUAT_IDENTITY)
    testing.expect(t,quat_pack(QUAT_IDENTITY)<1<<32,"Ten bits per component fit in 32 bits")
    testing.expect_value(t,quat_pack(QUAT_IDENTITY)>>30,u64(3))
    q:=quat_from_euler({0.3,-1.2,2.5})
    testing.expect_value(t,quat_pack(q),quat_pack(-q))
    rng:=rng_make(43)
    for bits in ([4]uint{6,10,12,16}) {
        // Half a step on three components, and what that does to the fourth.
        limit:=7*0.70710678/f32(u64(1)<<bits-2)
        worst:f32
        for _ in 0..<5000 {
            rotation:=random_quat(&rng)
            back:=quat_unpack(quat_pack(rotation,bits),bits)
            if !test_close(abs(back),1,1e-5) {testing.expect(t,false,"The unpacked rotation is not unit");return}
            worst=max(worst,quat_angle(rotation,back))
        }
        testing.expectf(t,worst<limit,"%d bits: worst error %v radians, limit %v",bits,worst,limit)
        testing.expect(t,worst>limit*0.05,"The limit is not far from what happens")
    }
    // Rotations whose largest component is each of the four.
    for rotation in ([4]Quat{quaternion(w=0,x=1,y=0,z=0),quaternion(w=0,x=0,y=-1,z=0),quaternion(w=0,x=0,y=0,z=1),quaternion(w=-1,x=0,y=0,z=0)}) {
        testing.expect(t,test_same_rotation(quat_unpack(quat_pack(rotation)),rotation,1e-6))
    }
}

@(test)
batch_culling_agrees_with_the_single_test :: proc(t:^testing.T) {
    COUNT :: 3000
    boxes:=make([]Aabb,COUNT);defer delete(boxes)
    visible:=make([]u64,(COUNT+63)/64+1);defer delete(visible)
    reference:=make([]u64,(COUNT+63)/64+1);defer delete(reference)
    rng:=rng_make(51)
    for &box in boxes {
        center:=Vec3{random_range(&rng,-60,60),random_range(&rng,-60,60),random_range(&rng,-120,20)}
        box=aabb_from_center(center,{random_range(&rng,0.1,6),random_range(&rng,0.1,6),random_range(&rng,0.1,6)})
    }
    for projection in ([2]Mat4{perspective(1.2,1.6,0.5,100),orthographic(40,30,0.5,100)}) {
        frustum:=frustum_from_matrix(projection*look_at({1,2,3},{-4,0,-30},{0,1,0}))
        for &word in visible {word=~u64(0)}
        visible[len(visible)-1]=0x1234
        count:=frustum_cull_aabbs(frustum,boxes,visible)
        expected:=frustum_cull_aabbs_scalar(frustum,boxes,reference)
        testing.expect_value(t,count,expected)
        testing.expect(t,count>COUNT/20 && count<COUNT*19/20,"The scene has boxes on both sides")
        disagreements:=0
        for box,i in boxes {
            inside:=visible[i>>6]&(1<<uint(i&63))!=0
            if inside!=frustum_overlaps_aabb(frustum,box) {disagreements+=1}
        }
        testing.expect_value(t,disagreements,0)
        testing.expect_value(t,visible[len(visible)-1],u64(0x1234))
    }
    testing.expect_value(t,frustum_cull_aabbs({},nil,nil),0)
}

@(test)
a_black_body_is_white_at_6500_kelvin_and_warm_below :: proc(t:^testing.T) {
    white:=blackbody_linear(6500)
    testing.expectf(t,test_close3(white,{1,1,1},0.06),"6500 K is about white: %v",white)
    warm:=blackbody_linear(2000)
    testing.expect(t,warm.r>warm.g && warm.g>warm.b,"2000 K is warm")
    luminance:=0.2126*warm.r+0.7152*warm.g+0.0722*warm.b
    testing.expectf(t,test_close(luminance,1,0.05),"of luminance one: %v",luminance)
}
