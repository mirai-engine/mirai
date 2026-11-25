package mirai_math

import "core:fmt"
import "core:math/linalg"
import "core:testing"

// What the runtime computes every tick (simulation, animation, rollback, recorded scenarios) keeps
// its bits and the cook and import path takes its own _det procedures. A sweep of each procedure
// of f32 of this package that calls a transcendental function, hashed, against the hashes of the
// procedures as they were at fa567a075: pin_sweeps run against a copy of that tree, on macOS ARM64
// and Windows x86-64. Those that call the C library (sin, pow... of core:math) give other bits on
// another platform: they keep one hash per target, and a target without one is not checked for
// them.
@(test)
the_math_of_the_runtime_keeps_its_bits :: proc(t:^testing.T) {
    target:=fmt.tprintf("%v_%v",ODIN_OS,ODIN_ARCH)
    for pin in pin_sweeps(context.temp_allocator) {
        found:=false
        for reference in PINNED {
            if reference.name!=pin.name {continue}
            found=true
            want:=reference.hash
            if reference.per_target {
                want=0
                for h in reference.targets {if h.target==target {want=h.hash}}
                if want==0 {continue}
            }
            testing.expectf(t,pin.hash==want,"%s gives other bits than at fa567a075: %x, not %x",pin.name,pin.hash,want)
        }
        testing.expectf(t,found,"%s has no reference",pin.name)
    }
}

Pin :: struct {name:string,hash:u64}

// FNV-1a over the bits of every result of each sweep.
pin_sweeps :: proc(allocator:=context.allocator) -> []Pin {
    N :: 4096
    pins:=make([dynamic]Pin,allocator)
    h:u64
    begin :: proc(h:^u64) {h^=0xcbf29ce484222325}
    put :: proc(h:^u64,values:..f32) {
        for v in values {
            // A NaN is one value: its sign and payload are those of the processor that made it.
            bits:=transmute(u32)v if v==v else 0x7fc00000
            for k in 0..<4 {h^=(h^~u64(bits>>(8*uint(k))&0xff))*0x100000001b3}
        }
    }
    sweep :: #force_inline proc(i:int,lo,hi:f32) -> f32 {return lo+(hi-lo)*f32(i)/N}
    unit :: proc(i:int) -> Quat {
        v:=linalg.normalize(Vec4{sweep(i,-1,1),sweep((i*7)%N,-1,1),sweep((i*13)%N,-1,1),0.3})
        return quaternion(w=v.w,x=v.x,y=v.y,z=v.z)
    }
    Scalar :: struct {name:string,f:proc "contextless" (f32) -> f32,lo,hi:f32}
    for s in ([]Scalar{
        {"exp_det",exp_det,-110,95},{"ln_det",ln_det,-1,10000},{"sin_det",sin_det,-2000,2000},{"cos_det",cos_det,-2000,2000},
        {"srgb_to_linear_scalar",srgb_to_linear_scalar,-0.1,1.2},{"linear_to_srgb_scalar",linear_to_srgb_scalar,-0.1,1.2},
    }) {
        begin(&h)
        for i in 0..<N {put(&h,s.f(sweep(i,s.lo,s.hi)))}
        append(&pins,Pin{s.name,h})
    }
    for kind in Ease {
        begin(&h)
        for i in 0..<N {put(&h,ease_apply(kind,sweep(i,-0.25,1.25)))}
        append(&pins,Pin{fmt.aprintf("ease_apply %v",kind,allocator=allocator),h})
    }
    begin(&h)
    for i in 0..<N {put(&h,damp(f32(1),sweep(i,-3,3),sweep(i,0,20),1.0/60),damp_angle(sweep(i,-7,7),sweep((i*5)%N,-7,7),sweep(i,0,20),1.0/60))}
    append(&pins,Pin{"damp, damp_angle",h})
    begin(&h)
    for i in 0..<N {v,w:=spring_critical(f32(0),sweep(i,-2,2),sweep(i,-5,5),sweep(i,0.1,30),1.0/60);put(&h,v,w)}
    append(&pins,Pin{"spring_critical",h})
    begin(&h)
    for i in 0..<N {
        c:=Vec3{sweep(i,-0.1,1.2),sweep((i*3)%N,0,1),sweep((i*11)%N,0,4)}
        a:=srgb_to_linear_rgb(c);b:=linear_to_srgb_rgb(c);d:=srgb_to_linear_rgba({c.x,c.y,c.z,0.5});e:=linear_to_srgb_rgba({c.x,c.y,c.z,0.5})
        put(&h,a.x,a.y,a.z,b.x,b.y,b.z,d.x,d.y,d.z,d.w,e.x,e.y,e.z,e.w)
    }
    append(&pins,Pin{"srgb_to_linear, linear_to_srgb of rgb and rgba",h})
    begin(&h)
    for i in 0..<N {
        c:=Vec3{sweep(i,0,1),sweep((i*3)%N,0,1),sweep((i*11)%N,0,1)}
        a:=hsl_to_rgb(c);b:=rgb_to_hsl(c);u:=rgb9e5_unpack(rgb9e5_pack(c*sweep(i,0.001,6e4)));k:=blackbody_linear(sweep(i,800,40000))
        put(&h,a.x,a.y,a.z,b.x,b.y,b.z,u.x,u.y,u.z,k.x,k.y,k.z)
    }
    append(&pins,Pin{"hsl, rgb9e5, blackbody_linear",h})
    begin(&h)
    for i in 0..<N {
        a,b:=unit(i),unit((i*31+5)%N)
        tt:=sweep(i,0,1)
        s:=quat_slerp(a,b,tt);n:=quat_nlerp(a,b,tt)
        put(&h,s.x,s.y,s.z,s.w,n.x,n.y,n.z,n.w,quat_angle(a,b))
    }
    append(&pins,Pin{"quat_slerp, quat_nlerp, quat_angle",h})
    begin(&h)
    for i in 0..<N {
        angles:=Vec3{sweep(i,-3.2,3.2),sweep((i*3)%N,-1.6,1.6),sweep((i*7)%N,-3.2,3.2)}
        q:=quat_from_euler(angles);e:=quat_to_euler(unit(i));r:=quat_axis_angle(linalg.normalize(angles+{0.01,0,0}),angles.x)
        put(&h,q.x,q.y,q.z,q.w,e.x,e.y,e.z,r.x,r.y,r.z,r.w,yaw_of_direction(angles))
    }
    append(&pins,Pin{"euler, axis angle, yaw",h})
    begin(&h)
    for i in 0..<N {
        p:=perspective(sweep(i,0.2,2.5),sweep((i*3)%N,0.5,3),0.05,1000);q:=perspective_infinite(sweep(i,0.2,2.5),1.7,0.1)
        for c in 0..<4 {for r in 0..<4 {put(&h,p[r,c],q[r,c])}}
        put(&h,perspective_world_per_pixel(sweep(i,0.1,500),sweep(i,0.2,2.5),1080))
    }
    append(&pins,Pin{"perspective",h})
    begin(&h)
    for i in 0..<N {
        n:=linalg.normalize(Vec3{sweep(i,-1,1),sweep((i*3)%N,-1,1),0.4})
        packed:=normal_pack(n)
        tangent:=linalg.normalize(linalg.cross(n,Vec3{0,1,0.1}))
        a:=tangent_angle_pack(packed,tangent,1)
        u,sign:=tangent_angle_unpack(packed,a)
        put(&h,f32(a),u.x,u.y,u.z,sign)
    }
    append(&pins,Pin{"tangent_angle_pack, tangent_angle_unpack",h})
    begin(&h)
    r:=rng_make(17,1)
    for i in 0..<N {
        g:=random_gaussian(&r,sweep(i,-1,1),2)
        c:=random_in_cone(&r,linalg.normalize(Vec3{sweep(i,-1,1),1,0.2}),sweep(i,0,3))
        put(&h,g,c.x,c.y,c.z)
    }
    append(&pins,Pin{"random_gaussian, random_in_cone",h})
    return pins[:]
}

Pinned :: struct {name:string,hash:u64,per_target:bool,targets:[]struct {target:string,hash:u64}}

// Recorded with pin_sweeps against std/math of fa567a075 (one hash, or one per target).
PINNED :: []Pinned{
    {"exp_det",0x6a0a89edfb162277,false,nil},
    {"ln_det",0xd5550e23a6d97ac5,false,nil},
    {"sin_det",0xbabb0c98f1187661,false,nil},
    {"cos_det",0xb06f3028b548af93,false,nil},
    {"srgb_to_linear_scalar",0,true,{{"Darwin_arm64",0xba5667be1e332d86},{"Windows_amd64",0x3fe4beaaefdcfb5}}},
    {"linear_to_srgb_scalar",0,true,{{"Darwin_arm64",0x95718f5a7e6e509a},{"Windows_amd64",0x2708d5ef5ffb0bf8}}},
    {"ease_apply Linear",0xe05579b36e319406,false,nil},
    {"ease_apply Quad_In",0x75f7a93d8aa5c838,false,nil},
    {"ease_apply Quad_Out",0xdda9ed77b4a7ecc5,false,nil},
    {"ease_apply Quad_In_Out",0x9874f035c099ea07,false,nil},
    {"ease_apply Cubic_In",0xa63dfda9f7d76e4,false,nil},
    {"ease_apply Cubic_Out",0x501e55d6e5646413,false,nil},
    {"ease_apply Cubic_In_Out",0x482ad09b73312919,false,nil},
    {"ease_apply Quart_In",0x1f1f65ef2089c159,false,nil},
    {"ease_apply Quart_Out",0x36e804d700c66cef,false,nil},
    {"ease_apply Quart_In_Out",0x940cae8173ceb7ed,false,nil},
    {"ease_apply Quint_In",0xe33b0b6805ab0980,false,nil},
    {"ease_apply Quint_Out",0x5b634e77aa7ffa04,false,nil},
    {"ease_apply Quint_In_Out",0xe708c7fd5f49d01e,false,nil},
    {"ease_apply Sine_In",0,true,{{"Darwin_arm64",0xc60fd99d057c8642},{"Windows_amd64",0xef5bfa58c464e54}}},
    {"ease_apply Sine_Out",0,true,{{"Darwin_arm64",0xfbc185fcfca2f543},{"Windows_amd64",0x992bd7b0d68ab4c6}}},
    {"ease_apply Sine_In_Out",0,true,{{"Darwin_arm64",0x99bee4d66e30e18e},{"Windows_amd64",0xdd1dc50a05cd0c80}}},
    {"ease_apply Expo_In",0,true,{{"Darwin_arm64",0x1526bfb58da553f3},{"Windows_amd64",0x2814f72b72b7ad21}}},
    {"ease_apply Expo_Out",0,true,{{"Darwin_arm64",0x3aee95cc0b64ab6e},{"Windows_amd64",0x86db5ea654493e88}}},
    {"ease_apply Expo_In_Out",0,true,{{"Darwin_arm64",0x8f27ee9dc7e25da5},{"Windows_amd64",0xf4aa85bda21500d6}}},
    {"ease_apply Circ_In",0x4a0385c1cd1448fc,false,nil},
    {"ease_apply Circ_Out",0x7162f2eed88c810f,false,nil},
    {"ease_apply Circ_In_Out",0x35a4a837225657a5,false,nil},
    {"ease_apply Back_In",0x8a9e53bab484602c,false,nil},
    {"ease_apply Back_Out",0x9d44ceb44c9cadf6,false,nil},
    {"ease_apply Back_In_Out",0x361a812931a234a,false,nil},
    {"ease_apply Elastic_In",0,true,{{"Darwin_arm64",0x147003be921ccf01},{"Windows_amd64",0xa3ae99aaf830bd7f}}},
    {"ease_apply Elastic_Out",0,true,{{"Darwin_arm64",0x1d75e24c0c744fe1},{"Windows_amd64",0x9b1cb4555338ede}}},
    {"ease_apply Elastic_In_Out",0,true,{{"Darwin_arm64",0x5440a3a7a96909dd},{"Windows_amd64",0x9fafc472cb38ca6c}}},
    {"ease_apply Bounce_In",0x87fc45b65e1543e2,false,nil},
    {"ease_apply Bounce_Out",0x497828920cc61438,false,nil},
    {"ease_apply Bounce_In_Out",0x81b20f1a9866c325,false,nil},
    {"damp, damp_angle",0x8ff9cfa1b740c413,false,nil},
    {"spring_critical",0x498fc17cec4c1b81,false,nil},
    {"srgb_to_linear, linear_to_srgb of rgb and rgba",0,true,{{"Darwin_arm64",0x5d16a903929f0861},{"Windows_amd64",0xbb827b334e0941b5}}},
    {"hsl, rgb9e5, blackbody_linear",0xd666a848a043d89b,false,nil},
    {"quat_slerp, quat_nlerp, quat_angle",0,true,{{"Darwin_arm64",0x75c00181b79fc1cd},{"Windows_amd64",0xddd6bc6efd15e3a9}}},
    {"euler, axis angle, yaw",0xf1bfff9408dc28ea,false,nil},
    {"perspective",0,true,{{"Darwin_arm64",0xf05f13ea028b1070},{"Windows_amd64",0x72bed9c16b33f216}}},
    {"tangent_angle_pack, tangent_angle_unpack",0,true,{{"Darwin_arm64",0xa4d4ac3caab993a3},{"Windows_amd64",0x9c98367902fdf720}}},
    {"random_gaussian, random_in_cone",0x44c7d95320f5a5be,false,nil},
}
