package mirai_math

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

@(private="file") F32_INF :: f32(0h7f80_0000)
@(private="file") F32_NAN :: f32(0h7fc0_0000)
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
