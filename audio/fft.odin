#+private
package mirai_audio

import "base:runtime"
import "core:math"

// A real Fourier transform of a power-of-two size, done as a complex one of
// half that size. A spectrum holds n/2+1 bins; the inverse is scaled by 1/n,
// so a forward and an inverse give the signal back. Complex values are
// interleaved real and imaginary f32.
Fft :: struct {
    n:int,
    reverse:[]u32,  // n/2: bit-reversed index
    twiddle:[]f32,  // n/4 complex: e^(-2*pi*i*k/(n/2))
    post:[]f32,     // n/2 complex: e^(-2*pi*i*k/n)
    work:[]f32,     // n/2 complex
}

next_pow2 :: proc "contextless" (n:int) -> int {
    size:=1
    for size<n {size*=2}
    return size
}

fft_init :: proc(f:^Fft,n:int,allocator:runtime.Allocator) -> Error {
    f.n=max(next_pow2(n),8)
    half:=f.n/2
    failed:runtime.Allocator_Error
    if f.reverse,failed=make([]u32,half,allocator);failed!=nil {return .Out_Of_Memory}
    if f.twiddle,failed=make([]f32,half,allocator);failed!=nil {return .Out_Of_Memory}
    if f.post,failed=make([]f32,f.n,allocator);failed!=nil {return .Out_Of_Memory}
    if f.work,failed=make([]f32,f.n,allocator);failed!=nil {return .Out_Of_Memory}
    bits:=0
    for 1<<uint(bits)<half {bits+=1}
    for i in 0..<half {
        r:=u32(0)
        for b in 0..<bits {r|=u32((i>>uint(b))&1)<<uint(bits-1-b)}
        f.reverse[i]=r
    }
    for k in 0..<half/2 {
        angle:=-2*math.PI*f64(k)/f64(half)
        f.twiddle[2*k],f.twiddle[2*k+1]=f32(math.cos(angle)),f32(math.sin(angle))
    }
    for k in 0..<half {
        angle:=-2*math.PI*f64(k)/f64(f.n)
        f.post[2*k],f.post[2*k+1]=f32(math.cos(angle)),f32(math.sin(angle))
    }
    return .None
}

fft_destroy :: proc(f:^Fft,allocator:runtime.Allocator) {
    delete(f.reverse,allocator);delete(f.twiddle,allocator);delete(f.post,allocator);delete(f.work,allocator)
    f^={}
}

// In place on f.work. sign: -1 forward, 1 inverse. Two radix-2 stages are
// done at once, as a radix-4 butterfly on bit-reversed data.
@(private="file")
fft_complex :: proc "contextless" (f:^Fft,sign:f32) #no_bounds_check {
    d:=raw_data(f.work)
    w:=raw_data(f.twiddle)
    m:=f.n/2
    for i in 0..<m {
        j:=int(f.reverse[i])
        if j>i {
            d[2*i],d[2*j]=d[2*j],d[2*i]
            d[2*i+1],d[2*j+1]=d[2*j+1],d[2*i+1]
        }
    }
    l:=1
    for 4*l<=m {
        size:=4*l
        step1,step2:=m/(2*l),m/size
        for k in 0..<l {
            w1r,w1i:=w[2*k*step1],-sign*w[2*k*step1+1]
            w2r,w2i:=w[2*k*step2],-sign*w[2*k*step2+1]
            for base:=k;base<m;base+=size {
                i0,i1,i2,i3:=2*base,2*(base+l),2*(base+2*l),2*(base+3*l)
                a0r,a0i:=d[i0],d[i0+1]
                a1r,a1i:=d[i1],d[i1+1]
                a2r,a2i:=d[i2],d[i2+1]
                a3r,a3i:=d[i3],d[i3+1]
                t1r,t1i:=a1r*w1r-a1i*w1i,a1r*w1i+a1i*w1r
                t3r,t3i:=a3r*w1r-a3i*w1i,a3r*w1i+a3i*w1r
                b0r,b0i:=a0r+t1r,a0i+t1i
                b1r,b1i:=a0r-t1r,a0i-t1i
                b2r,b2i:=a2r+t3r,a2i+t3i
                b3r,b3i:=a2r-t3r,a2i-t3i
                ur,ui:=b2r*w2r-b2i*w2i,b2r*w2i+b2i*w2r
                xr,xi:=b3r*w2r-b3i*w2i,b3r*w2i+b3i*w2r
                // times sign*i: the twiddle of the quarter turn
                vr,vi:=-sign*xi,sign*xr
                d[i0],d[i0+1]=b0r+ur,b0i+ui
                d[i2],d[i2+1]=b0r-ur,b0i-ui
                d[i1],d[i1+1]=b1r+vr,b1i+vi
                d[i3],d[i3+1]=b1r-vr,b1i-vi
            }
        }
        l=size
    }
    if 2*l<=m {
        size:=2*l
        step:=m/size
        for k in 0..<l {
            wr,wi:=w[2*k*step],-sign*w[2*k*step+1]
            for start:=k;start<m;start+=size {
                a,b:=2*start,2*(start+l)
                br,bi:=d[b],d[b+1]
                tr,ti:=br*wr-bi*wi,br*wi+bi*wr
                ar,ai:=d[a],d[a+1]
                d[a],d[a+1]=ar+tr,ai+ti
                d[b],d[b+1]=ar-tr,ai-ti
            }
        }
    }
}

// signal: n samples; spectrum: n/2+1 complex.
fft_forward :: proc "contextless" (f:^Fft,signal:[]f32,spectrum:[]f32) #no_bounds_check {
    m:=f.n/2
    z:=raw_data(f.work)
    copy(f.work,signal[:f.n])
    fft_complex(f,-1)
    s:=raw_data(spectrum)
    p:=raw_data(f.post)
    zr,zi:=z[0],z[1]
    s[0],s[1]=zr+zi,0
    s[2*m],s[2*m+1]=zr-zi,0
    for k in 1..<m {
        ar,ai:=z[2*k],z[2*k+1]
        br,bi:=z[2*(m-k)],-z[2*(m-k)+1]
        er,ei:=(ar+br)*0.5,(ai+bi)*0.5
        // (a-b)/(2i)
        or_,oi:=(ai-bi)*0.5,-(ar-br)*0.5
        pr,pi:=p[2*k],p[2*k+1]
        s[2*k]=er+pr*or_-pi*oi
        s[2*k+1]=ei+pr*oi+pi*or_
    }
}

// spectrum: n/2+1 complex; signal: n samples.
fft_inverse :: proc "contextless" (f:^Fft,spectrum:[]f32,signal:[]f32) #no_bounds_check {
    m:=f.n/2
    z:=raw_data(f.work)
    s:=raw_data(spectrum)
    p:=raw_data(f.post)
    for k in 0..<m {
        ar,ai:=s[2*k],s[2*k+1]
        br,bi:=s[2*(m-k)],-s[2*(m-k)+1]
        er,ei:=(ar+br)*0.5,(ai+bi)*0.5
        dr,di:=(ar-br)*0.5,(ai-bi)*0.5
        // times conj(post)
        pr,pi:=p[2*k],-p[2*k+1]
        or_,oi:=dr*pr-di*pi,dr*pi+di*pr
        // even + i*odd
        z[2*k]=er-oi
        z[2*k+1]=ei+or_
    }
    fft_complex(f,1)
    scale:=1/f32(m)
    out:=raw_data(signal)
    for i in 0..<f.n {out[i]=z[i]*scale}
}
