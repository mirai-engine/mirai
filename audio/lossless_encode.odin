package mirai_audio

import "base:runtime"
import "core:math"

// The encoder of lossless.odin. For every block it tries the four stereo
// pairs and, for each channel, a constant, the samples as they are, the
// fixed orders and the linear orders up to LOSSLESS_ENCODE_ORDER, and keeps
// the one that takes the fewest bits.

@(private) LOSSLESS_ENCODE_ORDER :: 12
@(private) LOSSLESS_PRECISION :: 12       // bits of a quantized coefficient, its sign included
@(private) LOSSLESS_PARTITION_ORDER :: 8  // at most 2^8 partitions of the residual
@(private) LOSSLESS_RESIDUAL_MAX :: i64(1)<<30
@(private) LOSSLESS_ESCAPE_ZERO :: u8(255) // a partition stored as the escape of width 0: all zero

@(private)
Lossless_Kind :: enum u8 {Constant,Verbatim,Fixed,Linear}
@(private)
Lossless_Plan :: struct {
    kind:Lossless_Kind,
    wasted:u32,
    order:int,
    shift:u32,
    coefficients:[LOSSLESS_ORDER_MAX]i32,
    partition_order:u32,
    parameters:[1<<LOSSLESS_PARTITION_ORDER]u8,
    bits:int,
}
@(private)
Lossless_Encoder :: struct {
    planes:[4][]i32, // left, right, mid, side
    shifted:[]i32,
    residual:[]i32,
    windowed:[]f64,
    window:[]f64,
    plans:[4]Lossless_Plan,
    candidate:Lossless_Plan,
    out:[dynamic]u8,
    acc:u64,
    count:u32,
    failed:bool, // out could not grow
}

// Codes interleaved 16 bit frames, mono or stereo, losslessly. The bytes
// belong to allocator.
lossless_encode :: proc(samples:[]i16,channels,sample_rate:int,allocator:=context.allocator) -> (file:[]u8,error:Error) {
    if channels<1 || channels>2 || sample_rate<=0 || sample_rate>int(max(u32)) || len(samples)%channels!=0 || len(samples)/channels>int(max(u32)) {return nil,.Invalid_Desc}
    frames:=len(samples)/channels
    blocks:=(frames+LOSSLESS_BLOCK_FRAMES-1)/LOSSLESS_BLOCK_FRAMES
    e:Lossless_Encoder
    defer lossless_encoder_destroy(&e,allocator)
    failed:runtime.Allocator_Error
    for &plane in e.planes {
        if plane,failed=make([]i32,LOSSLESS_BLOCK_FRAMES,allocator);failed!=nil {return nil,.Out_Of_Memory}
    }
    if e.shifted,failed=make([]i32,LOSSLESS_BLOCK_FRAMES,allocator);failed!=nil {return nil,.Out_Of_Memory}
    if e.residual,failed=make([]i32,LOSSLESS_BLOCK_FRAMES,allocator);failed!=nil {return nil,.Out_Of_Memory}
    if e.windowed,failed=make([]f64,LOSSLESS_BLOCK_FRAMES,allocator);failed!=nil {return nil,.Out_Of_Memory}
    if e.window,failed=make([]f64,LOSSLESS_BLOCK_FRAMES,allocator);failed!=nil {return nil,.Out_Of_Memory}
    // About half the size of the samples, for music.
    if e.out,failed=make([dynamic]u8,0,LOSSLESS_HEADER+(blocks+1)*4+len(samples),allocator);failed!=nil {return nil,.Out_Of_Memory}

    header:[LOSSLESS_HEADER]u8
    copy(header[:],LOSSLESS_MAGIC)
    header[4]=u8(channels)
    put_le(header[6:],LOSSLESS_BLOCK_FRAMES,2)
    put_le(header[8:],u32(sample_rate),4)
    put_le(header[12:],u32(frames),4)
    put_le(header[16:],u32(blocks),4)
    append(&e.out,..header[:])
    table:=len(e.out)
    if resize(&e.out,table+(blocks+1)*4)!=nil {return nil,.Out_Of_Memory}
    data:=len(e.out)

    window_frames:=-1
    for block in 0..<blocks {
        first:=block*LOSSLESS_BLOCK_FRAMES
        n:=min(LOSSLESS_BLOCK_FRAMES,frames-first)
        if n!=window_frames {
            tukey(e.window[:n])
            window_frames=n
        }
        put_le(e.out[table+block*4:],u32(len(e.out)-data),4)
        if channels==1 {
            for i in 0..<n {e.planes[0][i]=i32(samples[first+i])}
            lossless_plan(&e,e.planes[0][:n],16,&e.plans[0])
            lossless_write_subframe(&e,e.planes[0][:n],16,&e.plans[0])
        } else {
            left,right,mid,side:=e.planes[0][:n],e.planes[1][:n],e.planes[2][:n],e.planes[3][:n]
            for i in 0..<n {
                l,r:=i32(samples[(first+i)*2]),i32(samples[(first+i)*2+1])
                left[i],right[i],mid[i],side[i]=l,r,(l+r)>>1,l-r
            }
            for c in 0..<4 {lossless_plan(&e,e.planes[c][:n],c==3?17:16,&e.plans[c])}
            // The channels each mode stores.
            pairs:=[4][2]int{{0,1},{0,3},{3,1},{2,3}}
            mode:=0
            for pair,m in pairs {
                if e.plans[pair[0]].bits+e.plans[pair[1]].bits<e.plans[pairs[mode][0]].bits+e.plans[pairs[mode][1]].bits {mode=m}
            }
            bits_write(&e,u32(mode),2)
            for c in pairs[mode] {lossless_write_subframe(&e,e.planes[c][:n],c==3?17:16,&e.plans[c])}
        }
        bits_align(&e)
        if e.failed {return nil,.Out_Of_Memory}
        if len(e.out)-data>int(max(u32)) {return nil,.Invalid_Desc}
    }
    put_le(e.out[table+blocks*4:],u32(len(e.out)-data),4)
    // What it did not use goes back, so that the bytes are freed as a slice.
    if _,shrunk:=shrink(&e.out);shrunk!=nil {return nil,.Out_Of_Memory}
    file=e.out[:]
    e.out=nil
    return file,.None
}

@(private="file")
lossless_encoder_destroy :: proc(e:^Lossless_Encoder,allocator:runtime.Allocator) {
    for plane in e.planes {delete(plane,allocator)}
    delete(e.shifted,allocator);delete(e.residual,allocator)
    delete(e.windowed,allocator);delete(e.window,allocator)
    delete(e.out)
}

@(private="file")
put_le :: proc(out:[]u8,value:u32,bytes:int) {
    for i in 0..<bytes {out[i]=u8(value>>(u32(i)*8))}
}

// Tukey window of ratio 0.5: flat in the middle half, cosine at the ends.
@(private="file")
tukey :: proc(w:[]f64) {
    n:=len(w)
    taper:=n/4
    for &value,i in w {
        value=1
        if taper>1 && i<taper {value=0.5-0.5*math.cos(math.PI*f64(i)/f64(taper))}
        if taper>1 && i>=n-taper {value=0.5-0.5*math.cos(math.PI*f64(n-1-i)/f64(taper))}
    }
}

// The cheapest way to store x, samples of bits bits.
@(private="file")
lossless_plan :: proc(e:^Lossless_Encoder,x:[]i32,bits:u32,plan:^Lossless_Plan) {
    n:=len(x)
    same:=true
    ored:i32
    for value in x {
        if value!=x[0] {same=false}
        ored|=value
    }
    if same {
        plan^={kind=.Constant,bits=2+int(bits)}
        return
    }
    wasted:=u32(0)
    for wasted<15 && wasted+1<bits && ored&(1<<wasted)==0 {wasted+=1}
    width:=bits-wasted
    y:=e.shifted[:n]
    for value,i in x {y[i]=value>>wasted}
    plan^={kind=.Verbatim,wasted=wasted,bits=2+4+n*int(width)}
    c:=&e.candidate

    // Fixed polynomials.
    for order in 0..=min(4,n) {
        r:=e.residual[:n]
        for i in order..<n {
            p:i32
            switch order {
            case 0:p=0
            case 1:p=y[i-1]
            case 2:p=2*y[i-1]-y[i-2]
            case 3:p=3*(y[i-1]-y[i-2])+y[i-3]
            case 4:p=4*(y[i-1]+y[i-3])-6*y[i-2]-y[i-4]
            }
            r[i]=y[i]-p
        }
        c^={kind=.Fixed,wasted=wasted,order=order}
        c.bits=2+4+3+order*int(width)+rice_plan(c,r,order)
        if c.bits<plan.bits {plan^=c^}
    }

    // Linear prediction from the autocorrelation of the windowed block.
    top:=min(LOSSLESS_ENCODE_ORDER,n-1)
    if top<1 {return}
    d:=e.windowed[:n]
    for value,i in y {d[i]=f64(value)*e.window[i]}
    autocorrelation:[LOSSLESS_ENCODE_ORDER+1]f64
    for lag in 0..=top {
        sum:f64
        for i in lag..<n {sum+=d[i]*d[i-lag]}
        autocorrelation[lag]=sum
    }
    if autocorrelation[0]<=0 {return}
    // Levinson-Durbin: the predictor of every order up to top.
    predictors:[LOSSLESS_ENCODE_ORDER][LOSSLESS_ENCODE_ORDER]f64
    reflection:[LOSSLESS_ENCODE_ORDER]f64
    remaining:=autocorrelation[0]
    for i in 0..<top {
        r:=-autocorrelation[i+1]
        for j in 0..<i {r-=reflection[j]*autocorrelation[i-j]}
        r/=remaining
        reflection[i]=r
        for j in 0..<i/2 {
            t:=reflection[j]
            reflection[j]+=r*reflection[i-1-j]
            reflection[i-1-j]+=r*t
        }
        if i&1==1 {reflection[i/2]+=reflection[i/2]*r}
        remaining*=1-r*r
        for j in 0..=i {predictors[i][j]=-reflection[j]}
        if remaining<=0 {top=i+1;break}
    }
    for order in 1..=top {
        if !quantize(predictors[order-1][:order],c) {continue}
        c.kind,c.wasted,c.order=.Linear,wasted,order
        r:=e.residual[:n]
        fits:=true
        for i in order..<n {
            sum:i64
            for j in 0..<order {sum+=i64(c.coefficients[j])*i64(y[i-1-j])}
            residual:=i64(y[i])-sum>>c.shift
            if residual>=LOSSLESS_RESIDUAL_MAX || residual<=-LOSSLESS_RESIDUAL_MAX {fits=false;break}
            r[i]=i32(residual)
        }
        if !fits {continue}
        c.bits=2+4+5+4+4+order*(LOSSLESS_PRECISION+int(width))+rice_plan(c,r,order)
        if c.bits<plan.bits {plan^=c^}
    }
}

// Quantizes the coefficients to LOSSLESS_PRECISION bits and a shift, carrying
// the error of each to the next.
@(private="file")
quantize :: proc(predictor:[]f64,c:^Lossless_Plan) -> bool {
    largest:f64
    for value in predictor {largest=max(largest,abs(value))}
    if largest<=0 || math.is_nan(largest) || math.is_inf(largest) {return false}
    _,exponent:=math.frexp(largest)
    shift:=LOSSLESS_PRECISION-1-exponent
    if shift<0 {return false}
    shift=min(shift,15)
    limit:=f64(1<<(LOSSLESS_PRECISION-1))
    carried:f64
    for value,j in predictor {
        carried+=value*f64(i64(1)<<uint(shift))
        q:=clamp(math.round(carried),-limit,limit-1)
        carried-=q
        c.coefficients[j]=i32(q)
    }
    c.shift=u32(shift)
    return true
}

// Chooses the partitions of the residual r[order:] and their Rice parameters,
// and returns the bits they take.
@(private="file")
rice_plan :: proc(c:^Lossless_Plan,r:[]i32,order:int) -> int {
    n:=len(r)
    top:=u32(0)
    for top<LOSSLESS_PARTITION_ORDER && n%(2<<top)==0 && n>>(top+1)>=order {top+=1}
    sums:[1<<LOSSLESS_PARTITION_ORDER]u64
    counts:[1<<LOSSLESS_PARTITION_ORDER]int
    size:=n>>top
    for part in 0..<1<<top {
        from:=part*size
        if part==0 {from=order}
        sum:u64
        for value in r[from:(part+1)*size] {sum+=u64(u32(value<<1)~u32(value>>31))}
        sums[part]=sum
        counts[part]=(part+1)*size-from
    }
    best:=max(int)
    parameters:[1<<LOSSLESS_PARTITION_ORDER]u8
    for p:=int(top);p>=0;p-=1 {
        bits:=4
        for part in 0..<1<<uint(p) {
            k,cost:=rice_parameter(sums[part],counts[part])
            parameters[part]=k
            bits+=cost
        }
        if bits<best {
            best=bits
            c.partition_order=u32(p)
            copy(c.parameters[:1<<uint(p)],parameters[:1<<uint(p)])
        }
        // The next order down: neighbours merged.
        if p==0 {break}
        for part in 0..<1<<uint(p-1) {
            sums[part]=sums[part*2]+sums[part*2+1]
            counts[part]=counts[part*2]+counts[part*2+1]
        }
    }
    return best
}

// The parameter of a partition of count values that add up to sum, and the
// bits it takes, the 5 of the parameter included. The cost is estimated from
// the sum; it is exact for the unary part up to rounding.
@(private="file")
rice_parameter :: proc(sum:u64,count:int) -> (k:u8,bits:int) {
    if count==0 {return 0,5}
    if sum==0 {
        if count<=5 {return 0,5+count}
        return LOSSLESS_ESCAPE_ZERO,10
    }
    mean:=sum/u64(count)
    guess:=0
    for guess<30 && mean>>uint(guess+1)>0 {guess+=1}
    bits=max(int)
    for candidate in max(guess-1,0)..=min(guess+1,30) {
        cost:=5+count*(candidate+1)+int(sum>>uint(candidate))
        if cost<bits {bits,k=cost,u8(candidate)}
    }
    return k,bits
}

@(private="file")
lossless_write_subframe :: proc(e:^Lossless_Encoder,x:[]i32,bits:u32,plan:^Lossless_Plan) {
    n:=len(x)
    bits_write(e,u32(plan.kind),2)
    if plan.kind==.Constant {
        bits_write(e,u32(x[0]),bits)
        return
    }
    bits_write(e,plan.wasted,4)
    width:=bits-plan.wasted
    y:=e.shifted[:n]
    for value,i in x {y[i]=value>>plan.wasted}
    switch plan.kind {
    case .Constant:
    case .Verbatim:
        for value in y {bits_write(e,u32(value),width)}
        return
    case .Fixed:
        bits_write(e,u32(plan.order),3)
    case .Linear:
        bits_write(e,u32(plan.order-1),5)
        bits_write(e,LOSSLESS_PRECISION-1,4)
        bits_write(e,plan.shift,4)
        for coefficient in plan.coefficients[:plan.order] {bits_write(e,u32(coefficient),LOSSLESS_PRECISION)}
    }
    for value in y[:plan.order] {bits_write(e,u32(value),width)}
    order:=plan.order
    r:=e.residual[:n]
    for i in order..<n {
        p:i64
        if plan.kind==.Fixed {
            switch order {
            case 1:p=i64(y[i-1])
            case 2:p=2*i64(y[i-1])-i64(y[i-2])
            case 3:p=3*(i64(y[i-1])-i64(y[i-2]))+i64(y[i-3])
            case 4:p=4*(i64(y[i-1])+i64(y[i-3]))-6*i64(y[i-2])-i64(y[i-4])
            }
        } else {
            for j in 0..<order {p+=i64(plan.coefficients[j])*i64(y[i-1-j])}
            p>>=plan.shift
        }
        r[i]=i32(i64(y[i])-p)
    }
    bits_write(e,plan.partition_order,4)
    size:=n>>plan.partition_order
    for part in 0..<1<<plan.partition_order {
        from:=part*size
        if part==0 {from=order}
        k:=plan.parameters[part]
        if k==LOSSLESS_ESCAPE_ZERO {
            bits_write(e,31,5)
            bits_write(e,0,5)
            continue
        }
        bits_write(e,u32(k),5)
        for value in r[from:(part+1)*size] {
            u:=u32(value<<1)~u32(value>>31)
            q:=u>>k
            for q>=32 {bits_write(e,0,32);q-=32}
            bits_write(e,1,q+1)
            bits_write(e,u,u32(k))
        }
    }
}

@(private="file")
bits_write :: proc(e:^Lossless_Encoder,value:u32,n:u32) {
    if n==0 {return}
    e.acc=e.acc<<n|u64(value)&((u64(1)<<n)-1)
    e.count+=n
    for e.count>=8 {
        e.count-=8
        if _,failed:=append(&e.out,u8(e.acc>>e.count));failed!=nil {e.failed=true}
    }
}

@(private="file")
bits_align :: proc(e:^Lossless_Encoder) {
    if e.count>0 {bits_write(e,0,8-e.count)}
    e.acc=0
}
