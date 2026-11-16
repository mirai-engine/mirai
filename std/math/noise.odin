package mirai_math

import "core:math"
import "core:math/linalg"
import "core:math/noise"

// Coherent noise. Value, Perlin and simplex noise return about -1 to 1 and
// vary over a distance of about 1; Worley noise returns distances. For a
// seed, the lattice noises here give the same values on every platform.

@(private)
noise_hash :: #force_inline proc "contextless" (x,y,z:i32,seed:u32) -> u32 {
    h:=u32(x)*0x85ebca6b~u32(y)*0xc2b2ae35~u32(z)*0x27d4eb2f~seed*0x165667b1
    h~=h>>15;h*=0x2c1b3c6d
    h~=h>>12;h*=0x297a2d39
    return h~h>>15
}
@(private)
noise_unit :: #force_inline proc "contextless" (h:u32) -> f32 {return f32(h>>8)*(1.0/16777216.0)}
@(private)
noise_fade :: #force_inline proc "contextless" (t:f32) -> f32 {return t*t*t*(t*(t*6-15)+10)}
@(private)
noise_fade_slope :: #force_inline proc "contextless" (t:f32) -> f32 {return 30*t*t*(t-1)*(t-1)}

// Random values on the integer lattice, blended smoothly between them.
noise_value2 :: proc "contextless" (p:Vec2,seed:u32=0) -> f32 {
    fx,fy:=math.floor(p.x),math.floor(p.y)
    x,y:=i32(fx),i32(fy)
    u,v:=noise_fade(p.x-fx),noise_fade(p.y-fy)
    corner :: #force_inline proc "contextless" (x,y:i32,seed:u32) -> f32 {return noise_unit(noise_hash(x,y,0,seed))*2-1}
    low:=lerp(corner(x,y,seed),corner(x+1,y,seed),u)
    high:=lerp(corner(x,y+1,seed),corner(x+1,y+1,seed),u)
    return lerp(low,high,v)
}
noise_value3 :: proc "contextless" (p:Vec3,seed:u32=0) -> f32 {
    fx,fy,fz:=math.floor(p.x),math.floor(p.y),math.floor(p.z)
    x,y,z:=i32(fx),i32(fy),i32(fz)
    u,v,w:=noise_fade(p.x-fx),noise_fade(p.y-fy),noise_fade(p.z-fz)
    corner :: #force_inline proc "contextless" (x,y,z:i32,seed:u32) -> f32 {return noise_unit(noise_hash(x,y,z,seed))*2-1}
    near:=lerp(lerp(corner(x,y,z,seed),corner(x+1,y,z,seed),u),lerp(corner(x,y+1,z,seed),corner(x+1,y+1,z,seed),u),v)
    far:=lerp(lerp(corner(x,y,z+1,seed),corner(x+1,y,z+1,seed),u),lerp(corner(x,y+1,z+1,seed),corner(x+1,y+1,z+1,seed),u),v)
    return lerp(near,far,w)
}

// Gradient noise: 0 on the lattice, with a random slope at every lattice point.
noise_perlin2 :: proc "contextless" (p:Vec2,seed:u32=0) -> f32 {
    fx,fy:=math.floor(p.x),math.floor(p.y)
    x,y:=i32(fx),i32(fy)
    dx,dy:=p.x-fx,p.y-fy
    corner :: #force_inline proc "contextless" (x,y:i32,dx,dy:f32,seed:u32) -> f32 {
        DIAGONAL :: 0.70710678
        gradients:=[8]Vec2{{1,0},{-1,0},{0,1},{0,-1},{DIAGONAL,DIAGONAL},{-DIAGONAL,DIAGONAL},{DIAGONAL,-DIAGONAL},{-DIAGONAL,-DIAGONAL}}
        g:=gradients[noise_hash(x,y,0,seed)>>29]
        return g.x*dx+g.y*dy
    }
    u,v:=noise_fade(dx),noise_fade(dy)
    low:=lerp(corner(x,y,dx,dy,seed),corner(x+1,y,dx-1,dy,seed),u)
    high:=lerp(corner(x,y+1,dx,dy-1,seed),corner(x+1,y+1,dx-1,dy-1,seed),u)
    return lerp(low,high,v)*1.41421356
}
noise_perlin3 :: proc "contextless" (p:Vec3,seed:u32=0) -> f32 {
    fx,fy,fz:=math.floor(p.x),math.floor(p.y),math.floor(p.z)
    x,y,z:=i32(fx),i32(fy),i32(fz)
    dx,dy,dz:=p.x-fx,p.y-fy,p.z-fz
    // One of the twelve directions from the center of a cube to its edges.
    corner :: #force_inline proc "contextless" (x,y,z:i32,dx,dy,dz:f32,seed:u32) -> f32 {
        h:=noise_hash(x,y,z,seed)>>28
        a:=dx if h<8 else dy
        b:=dy if h<4 else (dx if h==12 || h==14 else dz)
        return (a if h&1==0 else -a)+(b if h&2==0 else -b)
    }
    u,v,w:=noise_fade(dx),noise_fade(dy),noise_fade(dz)
    near:=lerp(lerp(corner(x,y,z,dx,dy,dz,seed),corner(x+1,y,z,dx-1,dy,dz,seed),u),lerp(corner(x,y+1,z,dx,dy-1,dz,seed),corner(x+1,y+1,z,dx-1,dy-1,dz,seed),u),v)
    far:=lerp(lerp(corner(x,y,z+1,dx,dy,dz-1,seed),corner(x+1,y,z+1,dx-1,dy,dz-1,seed),u),lerp(corner(x,y+1,z+1,dx,dy-1,dz-1,seed),corner(x+1,y+1,z+1,dx-1,dy-1,dz-1,seed),u),v)
    return lerp(near,far,w)
}

// Perlin noise with its gradient: the slope of the noise along each axis, exact
// rather than estimated from nearby samples. The value is that of noise_perlin2.
noise_perlin2_gradient :: proc "contextless" (p:Vec2,seed:u32=0) -> (value:f32,gradient:Vec2) {
    DIAGONAL :: 0.70710678
    fx,fy:=math.floor(p.x),math.floor(p.y)
    x,y:=i32(fx),i32(fy)
    dx,dy:=p.x-fx,p.y-fy
    directions:=[8]Vec2{{1,0},{-1,0},{0,1},{0,-1},{DIAGONAL,DIAGONAL},{-DIAGONAL,DIAGONAL},{DIAGONAL,-DIAGONAL},{-DIAGONAL,-DIAGONAL}}
    g00,g10:=directions[noise_hash(x,y,0,seed)>>29],directions[noise_hash(x+1,y,0,seed)>>29]
    g01,g11:=directions[noise_hash(x,y+1,0,seed)>>29],directions[noise_hash(x+1,y+1,0,seed)>>29]
    n00,n10:=g00.x*dx+g00.y*dy,g10.x*(dx-1)+g10.y*dy
    n01,n11:=g01.x*dx+g01.y*(dy-1),g11.x*(dx-1)+g11.y*(dy-1)
    u,v:=noise_fade(dx),noise_fade(dy)
    du,dv:=noise_fade_slope(dx),noise_fade_slope(dy)
    low,high:=lerp(n00,n10,u),lerp(n01,n11,u)
    value=lerp(low,high,v)*1.41421356
    // The blend of the corner directions, plus what moving the blend weights changes.
    gradient=lerp(lerp(g00,g10,u),lerp(g01,g11,u),v)
    gradient.x+=du*lerp(n10-n00,n11-n01,v)
    gradient.y+=dv*(high-low)
    return value,gradient*1.41421356
}
noise_perlin3_gradient :: proc "contextless" (p:Vec3,seed:u32=0) -> (value:f32,gradient:Vec3) {
    fx,fy,fz:=math.floor(p.x),math.floor(p.y),math.floor(p.z)
    x,y,z:=i32(fx),i32(fy),i32(fz)
    d:=Vec3{p.x-fx,p.y-fy,p.z-fz}
    // The directions noise_perlin3 picks with the same four bits.
    directions:=[16]Vec3{{1,1,0},{-1,1,0},{1,-1,0},{-1,-1,0},{1,0,1},{-1,0,1},{1,0,-1},{-1,0,-1},{0,1,1},{0,-1,1},{0,1,-1},{0,-1,-1},{1,1,0},{0,-1,1},{-1,1,0},{0,-1,-1}}
    g:[8]Vec3
    n:[8]f32
    for corner in 0..<8 {
        offset:=Vec3{f32(corner&1),f32(corner>>1&1),f32(corner>>2)}
        g[corner]=directions[noise_hash(x+i32(corner&1),y+i32(corner>>1&1),z+i32(corner>>2),seed)>>28]
        n[corner]=linalg.dot(g[corner],d-offset)
    }
    u,v,w:=noise_fade(d.x),noise_fade(d.y),noise_fade(d.z)
    x00,x10,x01,x11:=lerp(n[0],n[1],u),lerp(n[2],n[3],u),lerp(n[4],n[5],u),lerp(n[6],n[7],u)
    y0,y1:=lerp(x00,x10,v),lerp(x01,x11,v)
    value=lerp(y0,y1,w)
    gradient=lerp(lerp(lerp(g[0],g[1],u),lerp(g[2],g[3],u),v),lerp(lerp(g[4],g[5],u),lerp(g[6],g[7],u),v),w)
    gradient.x+=noise_fade_slope(d.x)*lerp(lerp(n[1]-n[0],n[3]-n[2],v),lerp(n[5]-n[4],n[7]-n[6],v),w)
    gradient.y+=noise_fade_slope(d.y)*lerp(x10-x00,x11-x01,w)
    gradient.z+=noise_fade_slope(d.z)*(y1-y0)
    return value,gradient
}

// Simplex noise: core's OpenSimplex2, with fewer directional artifacts than Perlin noise.
noise_simplex2 :: proc(p:Vec2,seed:u32=0) -> f32 {return noise.noise_2d(i64(seed),{f64(p.x),f64(p.y)})}
noise_simplex3 :: proc(p:Vec3,seed:u32=0) -> f32 {return noise.noise_3d_fallback(i64(seed),{f64(p.x),f64(p.y),f64(p.z)})}

// Cellular noise: one feature point in every lattice cell, placed on a fine
// grid inside it. Returns the distances to the nearest point and to the
// second nearest.
noise_worley2 :: proc "contextless" (p:Vec2,seed:u32=0) -> (nearest,second:f32) {
    fx,fy:=math.floor(p.x),math.floor(p.y)
    x,y:=i32(fx),i32(fy)
    nearest,second=math.F32_MAX,math.F32_MAX
    for cy in y-1..=y+1 {for cx in x-1..=x+1 {
        h:=noise_hash(cx,cy,0,seed)
        feature:=Vec2{f32(cx)+f32(h&0xffff)*(1.0/65536),f32(cy)+f32(h>>16)*(1.0/65536)}
        distance:=linalg.dot(feature-p,feature-p)
        if distance<nearest {second=nearest;nearest=distance} else if distance<second {second=distance}
    }}
    return math.sqrt(nearest),math.sqrt(second)
}
noise_worley3 :: proc "contextless" (p:Vec3,seed:u32=0) -> (nearest,second:f32) {
    fx,fy,fz:=math.floor(p.x),math.floor(p.y),math.floor(p.z)
    x,y,z:=i32(fx),i32(fy),i32(fz)
    nearest,second=math.F32_MAX,math.F32_MAX
    for cz in z-1..=z+1 {for cy in y-1..=y+1 {for cx in x-1..=x+1 {
        h:=noise_hash(cx,cy,cz,seed)
        feature:=Vec3{f32(cx)+f32(h&0x3ff)*(1.0/1024),f32(cy)+f32(h>>10&0x3ff)*(1.0/1024),f32(cz)+f32(h>>20&0x3ff)*(1.0/1024)}
        distance:=linalg.dot(feature-p,feature-p)
        if distance<nearest {second=nearest;nearest=distance} else if distance<second {second=distance}
    }}}
    return math.sqrt(nearest),math.sqrt(second)
}

Noise_Kind :: enum u8 {Perlin,Value,Simplex}

// Several octaves of one noise: each one has `lacunarity` times the frequency
// of the one before and `gain` times its amplitude.
Fractal :: struct {
    kind:Noise_Kind,
    octaves:u8,
    lacunarity:f32,
    gain:f32,
    seed:u32,
}
FRACTAL_DEFAULT :: Fractal{.Perlin,5,2,0.5,0}

noise2 :: proc(kind:Noise_Kind,p:Vec2,seed:u32=0) -> f32 {
    switch kind {
    case .Perlin:  return noise_perlin2(p,seed)
    case .Value:   return noise_value2(p,seed)
    case .Simplex: return noise_simplex2(p,seed)
    }
    return 0
}
noise3 :: proc(kind:Noise_Kind,p:Vec3,seed:u32=0) -> f32 {
    switch kind {
    case .Perlin:  return noise_perlin3(p,seed)
    case .Value:   return noise_value3(p,seed)
    case .Simplex: return noise_simplex3(p,seed)
    }
    return 0
}

@(private) Fractal_Shape :: enum u8 {Sum,Ridged,Turbulence}

// The octaves added up, scaled back to about -1 to 1: clouds, terrain.
noise_fbm2 :: proc(p:Vec2,fractal:=FRACTAL_DEFAULT) -> f32 {return noise_fractal(p,fractal,.Sum)}
noise_fbm3 :: proc(p:Vec3,fractal:=FRACTAL_DEFAULT) -> f32 {return noise_fractal(p,fractal,.Sum)}
// Sharp crests where the noise crosses zero, from 0 to 1: mountain ridges, veins.
noise_ridged2 :: proc(p:Vec2,fractal:=FRACTAL_DEFAULT) -> f32 {return noise_fractal(p,fractal,.Ridged)}
noise_ridged3 :: proc(p:Vec3,fractal:=FRACTAL_DEFAULT) -> f32 {return noise_fractal(p,fractal,.Ridged)}
// The absolute value of every octave, from 0 to 1: billows, marble, fire.
noise_turbulence2 :: proc(p:Vec2,fractal:=FRACTAL_DEFAULT) -> f32 {return noise_fractal(p,fractal,.Turbulence)}
noise_turbulence3 :: proc(p:Vec3,fractal:=FRACTAL_DEFAULT) -> f32 {return noise_fractal(p,fractal,.Turbulence)}

@(private)
noise_fractal :: proc(p:$V/[$N]f32,fractal:Fractal,shape:Fractal_Shape) -> f32 {
    total,amplitude,range:f32=0,1,0
    position:=p
    for octave in 0..<u32(max(fractal.octaves,1)) {
        value:f32
        when N==2 {value=noise2(fractal.kind,position,fractal.seed+octave)} else {value=noise3(fractal.kind,position,fractal.seed+octave)}
        switch shape {
        case .Sum:
        case .Ridged:     value=1-abs(value);value*=value
        case .Turbulence: value=abs(value)
        }
        total+=value*amplitude
        range+=amplitude
        amplitude*=fractal.gain
        position*=fractal.lacunarity
    }
    return total/range if range>0 else 0
}

// Curl noise: a field without sources or sinks, so what it moves neither
// piles up nor thins out. In 2D it is the gradient of Perlin noise turned a
// quarter; in 3D, the curl of three independent Perlin noises.
noise_curl2 :: proc "contextless" (p:Vec2,seed:u32=0) -> Vec2 {
    _,gradient:=noise_perlin2_gradient(p,seed)
    return {gradient.y,-gradient.x}
}
noise_curl3 :: proc "contextless" (p:Vec3,seed:u32=0) -> Vec3 {
    _,a:=noise_perlin3_gradient(p,seed)
    _,b:=noise_perlin3_gradient(p,seed+7919)
    _,c:=noise_perlin3_gradient(p,seed+15838)
    return {c.y-b.z,a.z-c.x,b.x-a.y}
}
