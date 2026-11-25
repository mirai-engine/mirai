package mirai_math

import "core:math"
import "core:math/linalg"

// exp, ln, sin and cos that give the same bits on every platform: core:math
// calls the ones of the compiler and the C library, which may round
// differently on another system. These take only additions, products,
// divisions and bit operations of IEEE f64, which every target rounds the
// same, and round once to f32 at the end: the result is within one unit in
// the last place of f32 of the exact value. What the simulation of a fixed
// tick computes with them (damp, damp_angle, spring_critical,
// random_gaussian) is the same on Windows, Linux and macOS, as long as the
// compiler does not fuse a product and a sum into one instruction. Rendering
// keeps the faster ones: color conversions, easing curves, noise and camera
// projections call core:math.
//
// What an import writes is versioned, so the cook and import path computes
// with the _det procedures below and never with core:math, the colors,
// easing curves and slerp of rendering and the runtime, which keep their
// speed and their values: the f64 ones (within 1e-13 of the exact value),
// pow, sRGB, easing curves and slerp. The compiler fuses each product and
// sum of `m*v` and `a*b` of a matrix with an odd side into one instruction
// where the target has it (arm64) and not elsewhere (x86-64): mat3_mul_det
// and mat3_mul_vec_det round each one, as separate operations do everywhere
// (fused_matrix_product, ODIN_WORKAROUNDS).

@(private="file") F32_INF :: f32(0h7f80_0000)
@(private="file") F32_NAN :: f32(0h7fc0_0000)
@(private="file") F64_INF :: f64(0h7ff0_0000_0000_0000)
@(private="file") F64_NAN :: f64(0h7ff8_0000_0000_0000)
@(private="file") LOG2_E :: 1.4426950408889634
@(private="file") LN2_HI :: 6.93147180369123816490e-01 // ln 2 in two parts: k*LN2_HI is exact
@(private="file") LN2_LO :: 1.90821492927058770002e-10
@(private="file") LN2 :: 0.6931471805599453
@(private="file") SQRT2 :: 1.4142135623730951
@(private="file") PIO2_HI :: 1.57079632673412561417e+00 // pi/2 in two parts, as above
@(private="file") PIO2_LO :: 6.07710050650619224932e-11
@(private="file") TWO_OVER_PI :: 0.6366197723675814

// 2 to an integer power within the normal range of f64.
@(private="file")
power_of_two :: #force_inline proc "contextless" (k:int) -> f64 {return transmute(f64)(u64(k+1023)<<52)}
@(private="file")
round_half_away :: #force_inline proc "contextless" (x:f64) -> f64 {return f64(i64(x+0.5)) if x>=0 else -f64(i64(-x+0.5))}

exp_det :: proc "contextless" (x:f32) -> f32 {
    if x!=x {return x}
    if x>88.72284 {return F32_INF}
    if x< -103.97209 {return 0}
    xd:=f64(x)
    k:=round_half_away(xd*LOG2_E)
    r:=(xd-k*LN2_HI)-k*LN2_LO // |r| <= ln 2 / 2
    p:=1+r*(1+r*(1.0/2+r*(1.0/6+r*(1.0/24+r*(1.0/120+r*(1.0/720+r*(1.0/5040+r*(1.0/40320+r*(1.0/362880+r*(1.0/3628800+r*(1.0/39916800)))))))))))
    return f32(p*power_of_two(int(k)))
}

exp_det_f64 :: proc "contextless" (x:f64) -> f64 {
    if x!=x {return x}
    if x>709.782712893384 {return F64_INF}
    if x< -745.1332191019412 {return 0}
    p,k:=exp_reduced(x)
    // 2^k in two factors where it leaves the normal range.
    if k>1023 {return p*power_of_two(int(k)-1)*2}
    if k< -1021 {return p*power_of_two(int(k)+600)*power_of_two(-600)}
    return p*power_of_two(int(k))
}

// e^x = p*2^k.
@(private="file")
exp_reduced :: #force_inline proc "contextless" (x:f64) -> (p,k:f64) {
    k=round_half_away(x*LOG2_E)
    r:=(x-k*LN2_HI)-k*LN2_LO // |r| <= ln 2 / 2
    p=1+r*(1+r*(1.0/2+r*(1.0/6+r*(1.0/24+r*(1.0/120+r*(1.0/720+r*(1.0/5040+r*(1.0/40320+r*(1.0/362880+r*(1.0/3628800+r*(1.0/39916800)))))))))))
    return
}

ln_det :: proc "contextless" (x:f32) -> f32 {
    if x!=x || x<0 {return F32_NAN}
    if x==0 {return -F32_INF}
    if x==F32_INF {return x}
    bits:=transmute(u64)f64(x)
    exponent:=int((bits>>52)&0x7ff)-1023
    m:=transmute(f64)((bits&0x000f_ffff_ffff_ffff)|0x3ff0_0000_0000_0000) // in [1, 2)
    if m>SQRT2 {m*=0.5;exponent+=1}
    s:=(m-1)/(m+1) // |s| <= 0.172
    s2:=s*s
    series:=2*s*(1+s2*(1.0/3+s2*(1.0/5+s2*(1.0/7+s2*(1.0/9+s2*(1.0/11+s2*(1.0/13+s2*(1.0/15))))))))
    return f32(f64(exponent)*LN2+series)
}

ln_det_f64 :: proc "contextless" (x:f64) -> f64 {
    if x!=x || x<0 {return F64_NAN}
    if x==0 {return -F64_INF}
    if x==F64_INF {return x}
    bits:=transmute(u64)x
    exponent:=int((bits>>52)&0x7ff)-1023
    if exponent== -1023 { // subnormal: scaled by 2^54 into the normal range
        bits=transmute(u64)(x*power_of_two(54))
        exponent=int((bits>>52)&0x7ff)-1023-54
    }
    return ln_normal(bits,exponent)
}

// The logarithm of a normal f64 by its bits and its exponent.
@(private="file")
ln_normal :: #force_inline proc "contextless" (bits:u64,exponent:int) -> f64 {
    exponent:=exponent
    m:=transmute(f64)((bits&0x000f_ffff_ffff_ffff)|0x3ff0_0000_0000_0000) // in [1, 2)
    if m>SQRT2 {m*=0.5;exponent+=1}
    s:=(m-1)/(m+1) // |s| <= 0.172
    s2:=s*s
    series:=2*s*(1+s2*(1.0/3+s2*(1.0/5+s2*(1.0/7+s2*(1.0/9+s2*(1.0/11+s2*(1.0/13+s2*(1.0/15))))))))
    return f64(exponent)*LN2+series
}

// x to the power y, as the C library defines it for zeros, infinities and negative x.
pow_det :: proc "contextless" (x,y:f32) -> f32 {return f32(pow_det_f64(f64(x),f64(y)))}

pow_det_f64 :: proc "contextless" (x,y:f64) -> f64 {
    switch {
    case y==0 || x==1: return 1
    case x!=x || y!=y: return F64_NAN
    case x<0:
        whole:=y==f64(i64(y)) if abs(y)<0h4330_0000_0000_0000 else true
        if !whole {return F64_NAN}
        odd:=abs(y)<0h4340_0000_0000_0000 && i64(y)&1==1
        p:=pow_det_f64(-x,y)
        return -p if odd else p
    case x==0: return 0 if y>0 else F64_INF
    case x==F64_INF: return F64_INF if y>0 else 0
    }
    return exp_det_f64(y*ln_det_f64(x))
}

// Exact to the last place for |x| below 2^20; beyond, the reduction to a quarter turn loses bits.
sincos_det :: proc "contextless" (x:f32) -> (sin,cos:f32) {
    if x!=x || x==F32_INF || x==-F32_INF {return F32_NAN,F32_NAN}
    xd:=f64(x)
    n:=round_half_away(xd*TWO_OVER_PI)
    r:=(xd-n*PIO2_HI)-n*PIO2_LO // |r| <= pi/4
    r2:=r*r
    s:=r*(1+r2*(-1.0/6+r2*(1.0/120+r2*(-1.0/5040+r2*(1.0/362880+r2*(-1.0/39916800+r2*(1.0/6227020800)))))))
    c:=1+r2*(-1.0/2+r2*(1.0/24+r2*(-1.0/720+r2*(1.0/40320+r2*(-1.0/3628800+r2*(1.0/479001600+r2*(-1.0/87178291200)))))))
    switch i64(n)&3 {
    case 0: return f32(s),f32(c)
    case 1: return f32(c),f32(-s)
    case 2: return f32(-s),f32(-c)
    }
    return f32(-c),f32(s)
}
sin_det :: proc "contextless" (x:f32) -> f32 {s,_:=sincos_det(x);return s}
cos_det :: proc "contextless" (x:f32) -> f32 {_,c:=sincos_det(x);return c}

sincos_det_f64 :: proc "contextless" (x:f64) -> (sin,cos:f64) {
    if x!=x || x==F64_INF || x==-F64_INF {return F64_NAN,F64_NAN}
    return sincos_reduced(x)
}
sin_det_f64 :: proc "contextless" (x:f64) -> f64 {s,_:=sincos_det_f64(x);return s}
cos_det_f64 :: proc "contextless" (x:f64) -> f64 {_,c:=sincos_det_f64(x);return c}

@(private="file")
sincos_reduced :: #force_inline proc "contextless" (x:f64) -> (sin,cos:f64) {
    n:=round_half_away(x*TWO_OVER_PI)
    r:=(x-n*PIO2_HI)-n*PIO2_LO // |r| <= pi/4
    r2:=r*r
    s:=r*(1+r2*(-1.0/6+r2*(1.0/120+r2*(-1.0/5040+r2*(1.0/362880+r2*(-1.0/39916800+r2*(1.0/6227020800)))))))
    c:=1+r2*(-1.0/2+r2*(1.0/24+r2*(-1.0/720+r2*(1.0/40320+r2*(-1.0/3628800+r2*(1.0/479001600+r2*(-1.0/87178291200)))))))
    switch i64(n)&3 {
    case 0: return s,c
    case 1: return c,-s
    case 2: return -s,-c
    }
    return -c,s
}

mat3_mul_det :: proc "contextless" (a,b:matrix[3,3]$T) -> (out:matrix[3,3]T) {
    for i in 0..<3 {
        for j in 0..<3 {out[i,j]=a[i,0]*b[0,j]+a[i,1]*b[1,j]+a[i,2]*b[2,j]}
    }
    return
}
mat3_mul_vec_det :: proc "contextless" (m:matrix[3,3]$T,v:[3]T) -> (out:[3]T) {
    for i in 0..<3 {out[i]=m[i,0]*v[0]+m[i,1]*v[1]+m[i,2]*v[2]}
    return
}

srgb_to_linear_det :: proc "contextless" (value:f32) -> f32 {
    return pow_det((value+0.055)/1.055,2.4) if value>0.04045 else value/12.92
}
linear_to_srgb_det :: proc "contextless" (value:f32) -> f32 {
    return 1.055*pow_det(value,1.0/2.4)-0.055 if value>0.0031308 else 12.92*value
}

// quat_slerp with the sine of the engine.
quat_slerp_det :: proc "contextless" (a,b:Quat,t:f32) -> Quat {
    b:=b
    cosine:=linalg.dot(a,b)
    if cosine<0 {b,cosine=-b,-cosine}
    if cosine>1-math.F32_EPSILON {return linalg.normalize(quaternion(w=a.w+(b.w-a.w)*t,x=a.x+(b.x-a.x)*t,y=a.y+(b.y-a.y)*t,z=a.z+(b.z-a.z)*t))}
    angle:=math.acos(cosine)
    sine:=sin_det(angle)
    factor_a,factor_b:=sin_det((1-t)*angle)/sine,sin_det(t*angle)/sine
    return linalg.normalize(quaternion(w=factor_a*a.w+factor_b*b.w,x=factor_a*a.x+factor_b*b.x,y=factor_a*a.y+factor_b*b.y,z=factor_a*a.z+factor_b*b.z))
}
