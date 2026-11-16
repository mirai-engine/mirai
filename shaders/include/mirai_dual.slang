// Values with their screen derivatives, dual numbers of two directions: a
// Mirai_Dual* holds a value and how much it changes to the next pixel of the
// image along x (dx) and along y (dy). What a Surface program computes from
// mirai_uv0(ctx), mirai_uv1(ctx), mirai_world_position(ctx) or
// mirai_vertex_normal(ctx) through the arithmetic and the functions below
// carries its derivatives exactly, the chain rule applied term by term, and
// mirai_sample_texture filters by them in any branch, with no derivative
// across the pixels of a quad. A plain value mixes in as a constant: its
// derivatives are zero. Comparisons and branches read .value.
#ifndef MIRAI_DUAL_SLANG
#define MIRAI_DUAL_SLANG
struct Mirai_Dual { float value; float dx; float dy; };
struct Mirai_Dual2 { float2 value; float2 dx; float2 dy; };
struct Mirai_Dual3 { float3 value; float3 dx; float3 dy; };
struct Mirai_Dual4 { float4 value; float4 dx; float4 dy; };

// Of each of the four types D of values T (B their comparisons): the
// constructors, the arithmetic with another D or a constant, and the
// functions, each the derivative of its value times those of its argument.
#define MIRAI_DUAL_OPS(D, T, B) \
D mirai_dual(T value) { D r; r.value = value; r.dx = T(0.0); r.dy = T(0.0); return r; } \
D mirai_dual(T value, T dx, T dy) { D r; r.value = value; r.dx = dx; r.dy = dy; return r; } \
D mirai_dual_chain(D a, T value, T slope) { return mirai_dual(value, slope * a.dx, slope * a.dy); } \
D operator-(D a) { return mirai_dual(-a.value, -a.dx, -a.dy); } \
D operator+(D a, D b) { return mirai_dual(a.value + b.value, a.dx + b.dx, a.dy + b.dy); } \
D operator+(D a, T b) { return mirai_dual(a.value + b, a.dx, a.dy); } \
D operator+(T a, D b) { return mirai_dual(a + b.value, b.dx, b.dy); } \
D operator-(D a, D b) { return mirai_dual(a.value - b.value, a.dx - b.dx, a.dy - b.dy); } \
D operator-(D a, T b) { return mirai_dual(a.value - b, a.dx, a.dy); } \
D operator-(T a, D b) { return mirai_dual(a - b.value, -b.dx, -b.dy); } \
D operator*(D a, D b) { return mirai_dual(a.value * b.value, a.dx * b.value + a.value * b.dx, a.dy * b.value + a.value * b.dy); } \
D operator*(D a, T b) { return mirai_dual(a.value * b, a.dx * b, a.dy * b); } \
D operator*(T a, D b) { return mirai_dual(a * b.value, a * b.dx, a * b.dy); } \
D operator/(D a, D b) { \
    T denominator = T(1.0) / (b.value * b.value); \
    T by_a = b.value * denominator, by_b = -a.value * denominator; \
    return mirai_dual(a.value / b.value, by_a * a.dx + by_b * b.dx, by_a * a.dy + by_b * b.dy); \
} \
D operator/(D a, T b) { return mirai_dual(a.value / b, a.dx / b, a.dy / b); } \
D operator/(T a, D b) { return mirai_dual(a) / b; } \
D abs(D a) { return mirai_dual_chain(a, abs(a.value), select(a.value >= T(0.0), T(1.0), T(-1.0))); } \
D sin(D a) { return mirai_dual_chain(a, sin(a.value), cos(a.value)); } \
D cos(D a) { return mirai_dual_chain(a, cos(a.value), -sin(a.value)); } \
D tan(D a) { T c = cos(a.value); return mirai_dual_chain(a, tan(a.value), T(1.0) / (c * c)); } \
D asin(D a) { return mirai_dual_chain(a, asin(a.value), rsqrt(max(T(1.0) - a.value * a.value, T(0.00001)))); } \
D acos(D a) { return mirai_dual_chain(a, acos(a.value), -rsqrt(max(T(1.0) - a.value * a.value, T(0.00001)))); } \
D atan(D a) { return mirai_dual_chain(a, atan(a.value), T(1.0) / (a.value * a.value + T(1.0))); } \
D sqrt(D a) { return mirai_dual_chain(a, sqrt(a.value), T(0.5) * rsqrt(max(a.value, T(0.00001)))); } \
D rsqrt(D a) { return mirai_dual_chain(a, rsqrt(a.value), T(-0.5) * rsqrt(a.value) / a.value); } \
D rcp(D a) { T r = T(1.0) / a.value; return mirai_dual_chain(a, r, -r * r); } \
D exp(D a) { T e = exp(a.value); return mirai_dual_chain(a, e, e); } \
D exp2(D a) { T e = exp2(a.value); return mirai_dual_chain(a, e, e * T(0.693147)); } \
D log(D a) { return mirai_dual_chain(a, log(a.value), T(1.0) / a.value); } \
D log2(D a) { return mirai_dual_chain(a, log2(a.value), T(1.442695) / a.value); } \
D log10(D a) { return mirai_dual_chain(a, log10(a.value), T(0.4342945) / a.value); } \
D saturate(D a) { return mirai_dual_chain(a, saturate(a.value), select(a.value > T(0.0), select(a.value < T(1.0), T(1.0), T(0.0)), T(0.0))); } \
D frac(D a) { return mirai_dual(frac(a.value), a.dx, a.dy); } \
D floor(D a) { return mirai_dual(floor(a.value)); } \
D ceil(D a) { return mirai_dual(ceil(a.value)); } \
D round(D a) { return mirai_dual(round(a.value)); } \
D fmod(D a, T b) { return mirai_dual(fmod(a.value, b), a.dx, a.dy); } \
D min(D a, D b) { B lower = a.value < b.value; return mirai_dual(select(lower, a.value, b.value), select(lower, a.dx, b.dx), select(lower, a.dy, b.dy)); } \
D min(D a, T b) { return min(a, mirai_dual(b)); } \
D max(D a, D b) { B higher = a.value > b.value; return mirai_dual(select(higher, a.value, b.value), select(higher, a.dx, b.dx), select(higher, a.dy, b.dy)); } \
D max(D a, T b) { return max(a, mirai_dual(b)); } \
D clamp(D a, T low, T high) { return min(max(a, low), high); } \
D pow(D a, D b) { \
    T p = pow(a.value, b.value); \
    return mirai_dual(p, p * (b.dx * log(a.value) + (b.value / a.value) * a.dx), p * (b.dy * log(a.value) + (b.value / a.value) * a.dy)); \
} \
D pow(D a, T b) { return pow(a, mirai_dual(b)); } \
D atan2(D a, D b) { \
    T denominator = T(1.0) / (a.value * a.value + b.value * b.value); \
    T by_a = b.value * denominator, by_b = -a.value * denominator; \
    return mirai_dual(atan2(a.value, b.value), by_a * a.dx + by_b * b.dx, by_a * a.dy + by_b * b.dy); \
} \
D lerp(D a, D b, D s) { return mirai_dual(lerp(a.value, b.value, s.value), lerp(a.dx, b.dx, s.value) + s.dx * (b.value - a.value), lerp(a.dy, b.dy, s.value) + s.dy * (b.value - a.value)); } \
D lerp(D a, D b, T s) { return lerp(a, b, mirai_dual(s)); } \
D smoothstep(T low, T high, D x) { D t = saturate((x - low) / (high - low)); return t * t * (T(3.0) - T(2.0) * t); } \
D select(bool c, D a, D b) { return c ? a : b; }
MIRAI_DUAL_OPS(Mirai_Dual, float, bool)
MIRAI_DUAL_OPS(Mirai_Dual2, float2, bool2)
MIRAI_DUAL_OPS(Mirai_Dual3, float3, bool3)
MIRAI_DUAL_OPS(Mirai_Dual4, float4, bool4)

// Of the vectors D of values T: with a scalar dual or value, the product,
// the quotient and lerp, and dot, length and normalize.
#define MIRAI_DUAL_VECTOR(D, T) \
D operator*(D a, Mirai_Dual b) { return mirai_dual(a.value * b.value, a.dx * b.value + a.value * b.dx, a.dy * b.value + a.value * b.dy); } \
D operator*(Mirai_Dual a, D b) { return b * a; } \
D operator*(D a, float b) { return mirai_dual(a.value * b, a.dx * b, a.dy * b); } \
D operator*(float a, D b) { return b * a; } \
D operator/(D a, Mirai_Dual b) { return a * rcp(b); } \
D operator/(D a, float b) { return a * (1.0 / b); } \
D lerp(D a, D b, Mirai_Dual s) { return mirai_dual(lerp(a.value, b.value, s.value), lerp(a.dx, b.dx, s.value) + s.dx * (b.value - a.value), lerp(a.dy, b.dy, s.value) + s.dy * (b.value - a.value)); } \
Mirai_Dual dot(D a, D b) { return mirai_dual(dot(a.value, b.value), dot(a.dx, b.value) + dot(a.value, b.dx), dot(a.dy, b.value) + dot(a.value, b.dy)); } \
Mirai_Dual dot(D a, T b) { return mirai_dual(dot(a.value, b), dot(a.dx, b), dot(a.dy, b)); } \
Mirai_Dual length(D a) { return sqrt(dot(a, a)); } \
D normalize(D a) { return a * rsqrt(dot(a, a)); }
MIRAI_DUAL_VECTOR(Mirai_Dual2, float2)
MIRAI_DUAL_VECTOR(Mirai_Dual3, float3)
MIRAI_DUAL_VECTOR(Mirai_Dual4, float4)

Mirai_Dual3 cross(Mirai_Dual3 a, Mirai_Dual3 b) {
    return mirai_dual(cross(a.value, b.value),
        a.dx.yzx * b.value.zxy + a.value.yzx * b.dx.zxy - a.dx.zxy * b.value.yzx - a.value.zxy * b.dx.yzx,
        a.dy.yzx * b.value.zxy + a.value.yzx * b.dy.zxy - a.dy.zxy * b.value.yzx - a.value.zxy * b.dy.yzx);
}

// Components, and vectors of them.
Mirai_Dual mirai_dual_x(Mirai_Dual2 a) { return mirai_dual(a.value.x, a.dx.x, a.dy.x); }
Mirai_Dual mirai_dual_y(Mirai_Dual2 a) { return mirai_dual(a.value.y, a.dx.y, a.dy.y); }
Mirai_Dual mirai_dual_x(Mirai_Dual3 a) { return mirai_dual(a.value.x, a.dx.x, a.dy.x); }
Mirai_Dual mirai_dual_y(Mirai_Dual3 a) { return mirai_dual(a.value.y, a.dx.y, a.dy.y); }
Mirai_Dual mirai_dual_z(Mirai_Dual3 a) { return mirai_dual(a.value.z, a.dx.z, a.dy.z); }
Mirai_Dual mirai_dual_x(Mirai_Dual4 a) { return mirai_dual(a.value.x, a.dx.x, a.dy.x); }
Mirai_Dual mirai_dual_y(Mirai_Dual4 a) { return mirai_dual(a.value.y, a.dx.y, a.dy.y); }
Mirai_Dual mirai_dual_z(Mirai_Dual4 a) { return mirai_dual(a.value.z, a.dx.z, a.dy.z); }
Mirai_Dual mirai_dual_w(Mirai_Dual4 a) { return mirai_dual(a.value.w, a.dx.w, a.dy.w); }
Mirai_Dual2 mirai_dual_xy(Mirai_Dual3 a) { return mirai_dual(a.value.xy, a.dx.xy, a.dy.xy); }
Mirai_Dual2 mirai_dual_xy(Mirai_Dual4 a) { return mirai_dual(a.value.xy, a.dx.xy, a.dy.xy); }
Mirai_Dual3 mirai_dual_xyz(Mirai_Dual4 a) { return mirai_dual(a.value.xyz, a.dx.xyz, a.dy.xyz); }
Mirai_Dual2 mirai_dual2(Mirai_Dual x, Mirai_Dual y) { return mirai_dual(float2(x.value, y.value), float2(x.dx, y.dx), float2(x.dy, y.dy)); }
Mirai_Dual2 mirai_dual2(Mirai_Dual s) { return mirai_dual2(s, s); }
Mirai_Dual3 mirai_dual3(Mirai_Dual x, Mirai_Dual y, Mirai_Dual z) { return mirai_dual(float3(x.value, y.value, z.value), float3(x.dx, y.dx, z.dx), float3(x.dy, y.dy, z.dy)); }
Mirai_Dual3 mirai_dual3(Mirai_Dual2 xy, Mirai_Dual z) { return mirai_dual(float3(xy.value, z.value), float3(xy.dx, z.dx), float3(xy.dy, z.dy)); }
Mirai_Dual3 mirai_dual3(Mirai_Dual s) { return mirai_dual3(s, s, s); }
Mirai_Dual4 mirai_dual4(Mirai_Dual x, Mirai_Dual y, Mirai_Dual z, Mirai_Dual w) { return mirai_dual(float4(x.value, y.value, z.value, w.value), float4(x.dx, y.dx, z.dx, w.dx), float4(x.dy, y.dy, z.dy, w.dy)); }
Mirai_Dual4 mirai_dual4(Mirai_Dual3 xyz, Mirai_Dual w) { return mirai_dual(float4(xyz.value, w.value), float4(xyz.dx, w.dx), float4(xyz.dy, w.dy)); }
Mirai_Dual4 mirai_dual4(Mirai_Dual s) { return mirai_dual4(s, s, s, s); }
#endif
