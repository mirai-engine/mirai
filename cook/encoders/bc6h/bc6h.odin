package bc6h

import "core:math"
import "mirai:std/jobs"

Profile :: enum u8 {Very_Fast,Fast,Basic,Slow,Very_Slow}

Settings :: struct {
    slow_mode,fast_mode:bool,
    refine_iterations_1p,refine_iterations_2p,fast_skip_threshold:i32,
}

settings_of :: proc(profile:Profile) -> Settings {
    switch profile {
    case .Very_Fast: return {slow_mode=false,fast_mode=true,fast_skip_threshold=0,refine_iterations_1p=0,refine_iterations_2p=0}
    case .Fast:      return {slow_mode=false,fast_mode=true,fast_skip_threshold=2,refine_iterations_1p=0,refine_iterations_2p=1}
    case .Basic:     return {slow_mode=false,fast_mode=false,fast_skip_threshold=4,refine_iterations_1p=2,refine_iterations_2p=2}
    case .Slow:      return {slow_mode=true,fast_mode=false,fast_skip_threshold=10,refine_iterations_1p=2,refine_iterations_2p=2}
    case .Very_Slow: return {slow_mode=true,fast_mode=false,fast_skip_threshold=32,refine_iterations_1p=2,refine_iterations_2p=2}
    }
    return {}
}

encode_block :: proc(settings:^Settings,texels:^[16][4]u16,out:^[16]u8) {
    if settings==nil || texels==nil || out==nil {return}
    s:State
    for p in 0..<3 {
        for k in 0..<16 {s.block[p*16+k]=f32(texels[k][p])}
    }
    s.slow_mode=settings.slow_mode
    s.fast_mode=settings.fast_mode
    s.refine_iterations_1p=settings.refine_iterations_1p
    s.refine_iterations_2p=settings.refine_iterations_2p
    s.fast_skip_threshold=min(max(settings.fast_skip_threshold,0),PARTITIONS)
    s.best_err=math.INF_F32

    encode_core(&s)

    for k in 0..<4 {
        v:=s.best_data[k]
        out[k*4+0]=u8(v)
        out[k*4+1]=u8(v>>8)
        out[k*4+2]=u8(v>>16)
        out[k*4+3]=u8(v>>24)
    }
}

encode_image :: proc(settings:^Settings,pixels:[]u16,width,height:int,out:[]u8,worker:=jobs.Worker_Ref{}) -> bool {
    if settings==nil || width<=0 || height<=0 || width>(max(int)/16)/height {return false}
    if len(pixels)!=width*height*4 {return false}
    blocks_x:=(width+3)/4
    blocks_y:=(height+3)/4
    count:=blocks_x*blocks_y
    if len(out)!=count*16 {return false}

    work:=Image_Work{settings=settings,pixels=pixels,width=width,height=height,blocks_x=blocks_x,out=out}
    if worker.system!=nil {
        jobs.parallel_for(worker.system,worker.worker,count,1,encode_range,&work)
    } else {
        encode_range(&work,0,count,0)
    }
    return true
}

@(private="file")
Image_Work :: struct {
    settings:^Settings,
    pixels:[]u16,
    width,height,blocks_x:int,
    out:[]u8,
}

@(private="file")
encode_range :: proc(work:^Image_Work,first,last:int,worker:int) {
    for index in first..<last {
        block_x:=index%work.blocks_x
        block_y:=index/work.blocks_x
        texels:[16][4]u16
        for y in 0..<4 {
            source_y:=min(block_y*4+y,work.height-1)
            for x in 0..<4 {
                source_x:=min(block_x*4+x,work.width-1)
                offset:=(source_y*work.width+source_x)*4
                for c in 0..<4 {texels[y*4+x][c]=work.pixels[offset+c]}
            }
        }
        encode_block(work.settings,&texels,(^[16]u8)(&work.out[index*16]))
    }
}

@(private="file")
PARTITIONS :: 32

@(private)
State :: struct {
    block:[48]f32,
    best_err:f32,
    best_data:[5]u32,
    rgb_bounds:[6]f32,
    max_span:f32,
    max_span_idx:i32,
    mode,epb:i32,
    qbounds:[8]i32,
    slow_mode,fast_mode:bool,
    refine_iterations_1p,refine_iterations_2p,fast_skip_threshold:i32,
}

@(rodata,private="file") UNQUANT_3 := [8]i32{0,9,18,27,37,46,55,64}
@(rodata,private="file") UNQUANT_4 := [16]i32{0,4,9,13,17,21,26,30,34,38,43,47,51,55,60,64}

@(rodata,private="file") PATTERNS := [PARTITIONS]u32{
    0x50505050,0x40404040,0x54545454,0x54505040,0x50404000,0x55545450,0x55545040,0x54504000,
    0x50400000,0x55555450,0x55544000,0x54400000,0x55555440,0x55550000,0x55555500,0x55000000,
    0x55150100,0x00004054,0x15010000,0x00405054,0x00004050,0x15050100,0x05010000,0x40505054,
    0x00404050,0x05010100,0x14141414,0x05141450,0x01155440,0x00555500,0x15014054,0x05414150,
}

@(rodata,private="file") PATTERN_MASKS := [PARTITIONS]u32{
    0xCCCC3333,0x88887777,0xEEEE1111,0xECC81337,0xC880377F,0xFEEC0113,0xFEC80137,0xEC80137F,
    0xC80037FF,0xFFEC0013,0xFE80017F,0xE80017FF,0xFFE80017,0xFF0000FF,0xFFF0000F,0xF0000FFF,
    0xF71008EF,0x008EFF71,0x71008EFF,0x08CEF731,0x008CFF73,0x73108CEF,0x3100CEFF,0x8CCE7331,
    0x088CF773,0x3110CEEF,0x66669999,0x366CC993,0x17E8E817,0x0FF0F00F,0x718E8E71,0x399CC663,
}

@(rodata,private="file") SECOND_ANCHORS := [PARTITIONS]i32{
    15,15,15,15,15,15,15,15,15,15,15,15,15,15,15,15,
    15, 2, 8, 2, 2, 8, 8,15, 2, 8, 2, 2, 8, 8, 2, 2,
}

@(rodata,private="file") MODE_PREFIXES := [14]u32{0,1,2,6,10,14,18,22,26,30,3,7,11,15}
@(rodata,private) MODE_SPANS := [14]f32{921,14745,204,-1,-1,1843,3686,-1,-1,65535,65535,7782,1945,6}
@(rodata,private="file") MODE_BITS := [14]i32{10,7,11,-1,-1,9,8,-1,-1,6,10,11,12,16}

// The conversion of x86 SIMD: NaN and out of range give the lowest integer.
// The encoder depends on it, because a squared error can exceed the i32 range.
@(private="file")
to_i32 :: #force_inline proc "contextless" (v:f32) -> i32 {
    if v>=-2147483648.0 && v<2147483648.0 {return i32(v)}
    return min(i32)
}

@(private="file") sq :: #force_inline proc "contextless" (v:f32) -> f32 {return v*v}
@(private="file") fmin :: #force_inline proc "contextless" (a,b:f32) -> f32 {return a<b?a:b}
@(private="file") fmax :: #force_inline proc "contextless" (a,b:f32) -> f32 {return a>b?a:b}

@(private="file")
pattern_mask :: #force_inline proc "contextless" (part_id:i32,subset:int) -> i32 {
    packed:=PATTERN_MASKS[part_id&(PARTITIONS-1)]
    return i32(packed&0xFFFF) if subset==0 else i32(packed>>16)
}

@(private="file")
compute_stats_masked :: proc(stats:^[15]f32,block:^[48]f32,mask:i32) {
    stats^={}
    mask_shifted:=mask<<1
    for k in 0..<16 {
        mask_shifted>>=1
        flag:=f32(mask_shifted&1)
        rgb:[3]f32
        for p in 0..<3 {rgb[p]=block[k+p*16]}
        for p in 0..<3 {rgb[p]*=flag}
        stats[14]+=flag

        stats[10]+=rgb[0]
        stats[11]+=rgb[1]
        stats[12]+=rgb[2]

        stats[0]+=rgb[0]*rgb[0]
        stats[1]+=rgb[0]*rgb[1]
        stats[2]+=rgb[0]*rgb[2]

        stats[4]+=rgb[1]*rgb[1]
        stats[5]+=rgb[1]*rgb[2]

        stats[7]+=rgb[2]*rgb[2]
    }
}

@(private="file")
covar_from_stats :: proc(covar:^[10]f32,stats:^[15]f32) {
    covar[0]=stats[0]-stats[10+0]*stats[10+0]/stats[14]
    covar[1]=stats[1]-stats[10+0]*stats[10+1]/stats[14]
    covar[2]=stats[2]-stats[10+0]*stats[10+2]/stats[14]

    covar[4]=stats[4]-stats[10+1]*stats[10+1]/stats[14]
    covar[5]=stats[5]-stats[10+1]*stats[10+2]/stats[14]

    covar[7]=stats[7]-stats[10+2]*stats[10+2]/stats[14]
}

@(private="file")
ssymv3 :: proc(a:^[4]f32,covar:^[10]f32,b:^[4]f32) {
    a[0]=covar[0]*b[0]+covar[1]*b[1]+covar[2]*b[2]
    a[1]=covar[1]*b[0]+covar[4]*b[1]+covar[5]*b[2]
    a[2]=covar[2]*b[0]+covar[5]*b[1]+covar[7]*b[2]
}

@(private="file")
compute_axis :: proc(axis:^[4]f32,covar:^[10]f32,power_iterations:int) {
    vec:=[4]f32{1,1,1,1}
    for i in 0..<power_iterations {
        ssymv3(axis,covar,&vec)
        for p in 0..<3 {vec[p]=axis[p]}

        if i%2==1 {
            norm_sq:f32=0
            for p in 0..<3 {norm_sq+=axis[p]*axis[p]}

            rnorm:=1.0/math.sqrt(norm_sq)
            for p in 0..<3 {vec[p]*=rnorm}
        }
    }
    for p in 0..<3 {axis[p]=vec[p]}
}

@(private="file") INV_VAR :f32: 1.0/65536.0

@(private="file")
block_pca_axis :: proc(axis,dc:^[4]f32,block:^[48]f32,mask:i32) {
    stats:[15]f32
    compute_stats_masked(&stats,block,mask)

    covar:[10]f32
    covar_from_stats(&covar,&stats)
    for p in 0..<3 {dc[p]=stats[10+p]/stats[14]}

    for k in 0..<10 {covar[k]*=INV_VAR}

    eps:=sq(0.001)
    covar[0]+=eps
    covar[4]+=eps
    covar[7]+=eps

    compute_axis(axis,&covar,8)
}

@(private="file")
block_segment_core :: proc(ep:[]f32,block:^[48]f32,mask:i32) {
    axis,dc:[4]f32
    block_pca_axis(&axis,&dc,block,mask)

    ext:=[2]f32{math.INF_F32,math.NEG_INF_F32}

    mask_shifted:=mask<<1
    for k in 0..<16 {
        mask_shifted>>=1
        if (mask_shifted&1)==0 {continue}

        dot:f32=0
        for p in 0..<3 {dot+=axis[p]*(block[16*p+k]-dc[p])}

        ext[0]=fmin(ext[0],dot)
        ext[1]=fmax(ext[1],dot)
    }

    if ext[1]-ext[0]<1 {
        ext[0]-=0.5
        ext[1]+=0.5
    }

    for i in 0..<2 {
        for p in 0..<3 {ep[4*i+p]=ext[i]*axis[p]+dc[p]}
    }
}

@(private="file")
get_pca_bound :: proc(covar:^[10]f32) -> f32 {
    for k in 0..<10 {covar[k]*=INV_VAR}

    eps:=sq(0.001)
    covar[0]+=eps
    covar[4]+=eps
    covar[7]+=eps

    axis:[4]f32
    compute_axis(&axis,covar,4)

    vec:[4]f32
    ssymv3(&vec,covar,&axis)

    sq_sum:f32=0
    for p in 0..<3 {sq_sum+=sq(vec[p])}
    lambda:=math.sqrt(sq_sum)

    bound:=covar[0]+covar[4]+covar[7]
    bound-=lambda
    return fmax(bound,0)
}

@(private="file")
block_pca_bound_split :: proc(block:^[48]f32,mask:i32,full_stats:^[15]f32) -> f32 {
    stats:[15]f32
    compute_stats_masked(&stats,block,mask)

    covar1:[10]f32
    covar_from_stats(&covar1,&stats)

    for i in 0..<15 {stats[i]=full_stats[i]-stats[i]}

    covar2:[10]f32
    covar_from_stats(&covar2,&stats)

    bound:f32=0
    bound+=get_pca_bound(&covar1)
    bound+=get_pca_bound(&covar2)

    return math.sqrt(bound)*256
}

@(private="file")
block_quant :: proc(qblock:^[2]u32,block:^[48]f32,bits:int,ep:[]f32,pattern:u32) -> f32 {
    total_err:f32=0
    unquant:=UNQUANT_3[:] if bits==3 else UNQUANT_4[:]
    levels:=i32(1)<<uint(bits)

    qblock^={}

    pattern_shifted:=i32(pattern)
    for k in 0..<16 {
        j:=int(pattern_shifted&3)
        pattern_shifted>>=2

        proj,div:f32
        for p in 0..<3 {
            ep_a:=ep[8*j+0+p]
            ep_b:=ep[8*j+4+p]
            proj+=(block[k+p*16]-ep_a)*(ep_b-ep_a)
            div+=sq(ep_b-ep_a)
        }

        proj/=div

        q1:=to_i32(proj*f32(levels)+0.5)
        q1=min(max(q1,1),levels-1)

        err0,err1:f32
        w0:=unquant[q1-1]
        w1:=unquant[q1]

        for p in 0..<3 {
            ep_a:=ep[8*j+0+p]
            ep_b:=ep[8*j+4+p]
            dec_v0:=f32(to_i32((f32(64-w0)*ep_a+f32(w0)*ep_b+32)/64))
            dec_v1:=f32(to_i32((f32(64-w1)*ep_a+f32(w1)*ep_b+32)/64))
            err0+=sq(dec_v0-block[k+p*16])
            err1+=sq(dec_v1-block[k+p*16])
        }

        best_err:=to_i32(err1)
        best_q:=q1
        if err0<err1 {
            best_err=to_i32(err0)
            best_q=q1-1
        }

        qblock[k/8]+=u32(best_q)<<uint(4*(k%8))
        total_err+=f32(best_err)
    }

    return total_err
}

@(private="file")
opt_endpoints :: proc(ep:[]f32,block:^[48]f32,bits:int,qblock:^[2]u32,mask:i32) {
    max_q:=f32(i32(1)<<uint(bits)-1)

    atb1:[4]f32
    sum_q,sum_qq:f32
    sum:[5]f32

    mask_shifted:=mask<<1
    for k1 in 0..<2 {
        qbits_shifted:=qblock[k1]
        for k2 in 0..<8 {
            k:=k1*8+k2
            q:=f32(qbits_shifted&15)
            qbits_shifted>>=4

            mask_shifted>>=1
            if (mask_shifted&1)==0 {continue}

            x:=max_q-q

            sum_q+=q
            sum_qq+=q*q

            sum[4]+=1
            for p in 0..<3 {sum[p]+=block[k+p*16]}
            for p in 0..<3 {atb1[p]+=x*block[k+p*16]}
        }
    }

    atb2:[4]f32
    for p in 0..<3 {atb2[p]=max_q*sum[p]-atb1[p]}

    cxx:=sum[4]*sq(max_q)-2*max_q*sum_q+sum_qq
    cyy:=sum_qq
    cxy:=max_q*sum_q-sum_qq
    determinant:=cxx*cyy-cxy*cxy
    scale:=max_q/determinant

    for p in 0..<3 {
        ep[0+p]=(atb1[p]*cyy-atb2[p]*cxy)*scale
        ep[4+p]=(atb2[p]*cxx-atb1[p]*cxy)*scale
    }

    if abs(determinant)<0.001 {
        for p in 0..<3 {
            ep[0+p]=sum[p]/sum[4]
            ep[4+p]=ep[0+p]
        }
    }
}

@(private="file")
partial_sort_list :: proc(list:^[PARTITIONS]i32,partial_count:int) {
    for k in 0..<partial_count {
        best_idx:=k
        best_value:=list[k]
        for i in k+1..<PARTITIONS {
            if best_value>list[i] {
                best_value=list[i]
                best_idx=i
            }
        }

        list[best_idx]=list[k]
        list[k]=best_value
    }
}

@(private="file")
unpack_to_uf16 :: #force_inline proc "contextless" (v,bits:i32) -> i32 {
    if bits>=15 {return v}
    if v==0 {return 0}
    if v==i32(1)<<uint(bits)-1 {return 0xFFFF}
    return (v*2+1)<<uint(15-bits)
}

@(private="file")
ep_quant :: proc(qep:[]i32,ep:[]f32,bits:i32,pairs:int) {
    levels:=i32(1)<<uint(bits)
    for i in 0..<8*pairs {
        v:=to_i32(ep[i]/65535*f32(levels-1)+0.5)
        qep[i]=min(max(v,0),levels-1)
    }
}

@(private="file")
ep_dequant :: proc(ep:[]f32,qep:[]i32,bits:i32,pairs:int) {
    for i in 0..<8*pairs {ep[i]=f32(unpack_to_uf16(qep[i],bits))}
}

@(private="file")
ep_quant_dequant :: proc(s:^State,qep:[]i32,ep:[]f32,pairs:int) {
    ep_quant(qep,ep,s.epb,pairs)

    for i in 0..<2*pairs {
        for p in 0..<3 {
            qep[i*4+p]=min(max(qep[i*4+p],s.qbounds[p]),s.qbounds[4+p])
        }
    }

    ep_dequant(ep,qep,s.epb,pairs)
}

@(private="file")
enc_2p_part_fast :: proc(s:^State,qep:[]i32,qblock:^[2]u32,part_id:i32) -> f32 {
    ep:[16]f32
    for j in 0..<2 {
        block_segment_core(ep[j*8:],&s.block,pattern_mask(part_id,j))
    }

    ep_quant_dequant(s,qep,ep[:],2)

    return block_quant(qblock,&s.block,3,ep[:],PATTERNS[part_id])
}

@(private="file")
enc_2p_list :: proc(s:^State,part_list:^[PARTITIONS]i32,part_count:int) {
    if part_count==0 {return}

    best_qep:[16]i32
    best_qblock:[2]u32
    best_part_id:i32=0
    best_err:f32=math.INF_F32

    for part in 0..<part_count {
        part_id:=part_list[part]&31

        qep:[16]i32
        qblock:[2]u32
        err:=enc_2p_part_fast(s,qep[:],&qblock,part_id)

        if err<best_err {
            best_qep=qep
            best_qblock=qblock
            best_part_id=part_id
            best_err=err
        }
    }

    for _ in 0..<s.refine_iterations_2p {
        ep:[16]f32
        for j in 0..<2 {
            opt_endpoints(ep[j*8:],&s.block,3,&best_qblock,pattern_mask(best_part_id,j))
        }

        qep:[16]i32
        qblock:[2]u32
        ep_quant_dequant(s,qep[:],ep[:],2)

        err:=block_quant(&qblock,&s.block,3,ep[:],PATTERNS[best_part_id])

        if err<best_err {
            best_qep=qep
            best_qblock=qblock
            best_err=err
        }
    }

    if best_err<s.best_err {
        s.best_err=best_err
        code_2p(&s.best_data,best_qep[:],&best_qblock,best_part_id,s.mode)
    }
}

@(private="file")
enc_2p :: proc(s:^State) {
    full_stats:[15]f32
    compute_stats_masked(&full_stats,&s.block,-1)

    part_list:[PARTITIONS]i32
    for part in 0..<PARTITIONS {
        bound12:=block_pca_bound_split(&s.block,pattern_mask(i32(part),0),&full_stats)
        part_list[part]=i32(part)+to_i32(bound12)*64
    }

    partial_sort_list(&part_list,int(s.fast_skip_threshold))
    enc_2p_list(s,&part_list,int(s.fast_skip_threshold))
}

@(private="file")
enc_1p :: proc(s:^State) {
    ep:[8]f32
    block_segment_core(ep[:],&s.block,-1)

    qep:[8]i32
    ep_quant_dequant(s,qep[:],ep[:],1)

    qblock:[2]u32
    err:=block_quant(&qblock,&s.block,4,ep[:],0)

    for _ in 0..<s.refine_iterations_1p {
        opt_endpoints(ep[:],&s.block,4,&qblock,-1)
        ep_quant_dequant(s,qep[:],ep[:],1)
        err=block_quant(&qblock,&s.block,4,ep[:],0)
    }

    if err<s.best_err {
        s.best_err=err
        code_1p(&s.best_data,qep[:],&qblock,s.mode)
    }
}

@(private="file")
compute_qbounds :: proc(s:^State,rgb_span:[3]f32) {
    bounds:[8]f32
    for p in 0..<3 {
        middle:=(s.rgb_bounds[p]+s.rgb_bounds[3+p])/2

        bounds[p]=middle-rgb_span[p]/2
        bounds[4+p]=middle+rgb_span[p]/2
    }

    ep_quant(s.qbounds[:],bounds[:],s.epb,1)
}

@(private)
test_mode :: proc(s:^State,mode:i32,enc:bool,margin:f32) {
    span:=MODE_SPANS[mode]
    if s.max_span*margin>span {return}

    s.epb=MODE_BITS[mode]
    if mode>=10 {
        s.mode=mode
        compute_qbounds(s,{span,span,span})
        if enc {enc_1p(s)}
    } else if mode<=1 || mode==5 || mode==9 {
        s.mode=mode
        compute_qbounds(s,{span,span,span})
        if enc {enc_2p(s)}
    } else {
        s.mode=mode+s.max_span_idx
        rgb_span:=[3]f32{span,span,span}
        rgb_span[s.max_span_idx]*=2
        compute_qbounds(s,rgb_span)
        if enc {enc_2p(s)}
    }
}

@(private="file")
bit_at :: #force_inline proc "contextless" (v:i32,pos:uint) -> u32 {
    return u32((v>>pos)&1)
}

@(private="file")
reverse_bits :: proc "contextless" (v:u32,bits:int) -> u32 {
    if bits==2 {return (v>>1)+(v&1)*2}
    t:=(v&0x5555)*2+((v>>1)&0x5555)
    return (t>>4)+((t>>2)&3)*4+(t&3)*16
}

@(private="file")
transform :: proc(d:^[16]i32,qep:[]i32,endpoints:int,mask:i32,wide_channel:=-1,wide_mask:i32=0) {
    for p in 0..<3 {
        channel_mask:=wide_mask if p==wide_channel else mask
        d[p]=qep[p]
        for i in 1..<endpoints {d[i*4+p]=(qep[i*4+p]-qep[p])&channel_mask}
    }
}

@(private="file")
pack :: proc(packed:^[4]u32,qep:[]i32,mode:i32) {
    d:[16]i32
    q:[10]u32
    switch mode {
    case 0:
        transform(&d,qep,4,31)

        q[4]=u32(d[4]+(d[8+1]&15)*64)
        q[5]=u32(d[5]+(d[12+1]&15)*64)
        q[6]=u32(d[6]+(d[8+2]&15)*64)

        q[4]+=bit_at(d[12+1],4)<<5
        q[5]+=bit_at(d[12+2],0)<<5
        q[6]+=bit_at(d[12+2],1)<<5

        q[8]=u32(d[8])+bit_at(d[12+2],2)*32
        q[9]=u32(d[12])+bit_at(d[12+2],3)*32

        packed[0]=MODE_PREFIXES[0]
        packed[0]+=bit_at(d[8+1],4)<<2
        packed[0]+=bit_at(d[8+2],4)<<3
        packed[0]+=bit_at(d[12+2],4)<<4

        q[0]=u32(d[0]);q[1]=u32(d[1]);q[2]=u32(d[2])
        packed[1]=(q[2]<<20)+(q[1]<<10)+q[0]
        packed[2]=(q[6]<<20)+(q[5]<<10)+q[4]
        packed[3]=(q[9]<<6)+q[8]
    case 1:
        transform(&d,qep,4,63)

        q[0]=u32(d[0])
        q[0]+=bit_at(d[12+2],0)<<7
        q[0]+=bit_at(d[12+2],1)<<8
        q[0]+=bit_at(d[8+2],4)<<9

        q[1]=u32(d[1])
        q[1]+=bit_at(d[8+2],5)<<7
        q[1]+=bit_at(d[12+2],2)<<8
        q[1]+=bit_at(d[8+1],4)<<9

        q[2]=u32(d[2])
        q[2]+=bit_at(d[12+2],3)<<7
        q[2]+=bit_at(d[12+2],5)<<8
        q[2]+=bit_at(d[12+2],4)<<9

        q[4]=u32(d[4]+(d[8+1]&15)*64)
        q[5]=u32(d[5]+(d[12+1]&15)*64)
        q[6]=u32(d[6]+(d[8+2]&15)*64)

        packed[0]=MODE_PREFIXES[1]
        packed[0]+=bit_at(d[8+1],5)<<2
        packed[0]+=bit_at(d[12+1],4)<<3
        packed[0]+=bit_at(d[12+1],5)<<4

        packed[1]=(q[2]<<20)+(q[1]<<10)+q[0]
        packed[2]=(q[6]<<20)+(q[5]<<10)+q[4]
        packed[3]=(u32(d[12])<<6)+u32(d[8])
    case 2,3,4:
        transform(&d,qep,4,15,int(mode-2),31)

        q[0]=u32(d[0]&1023)
        q[1]=u32(d[1]&1023)
        q[2]=u32(d[2]&1023)

        q[4]=u32(d[4]+(d[8+1]&15)*64)
        q[5]=u32(d[5]+(d[12+1]&15)*64)
        q[6]=u32(d[6]+(d[8+2]&15)*64)

        q[8]=u32(d[8])
        q[9]=u32(d[12])

        packed[0]=MODE_PREFIXES[mode]
        switch mode {
        case 2:
            q[5]+=bit_at(d[0+1],10)<<4
            q[6]+=bit_at(d[0+2],10)<<4

            q[4]+=bit_at(d[0+0],10)<<5
            q[5]+=bit_at(d[12+2],0)<<5
            q[6]+=bit_at(d[12+2],1)<<5
            q[8]+=bit_at(d[12+2],2)<<5
            q[9]+=bit_at(d[12+2],3)<<5
        case 3:
            q[4]+=bit_at(d[0+0],10)<<4
            q[6]+=bit_at(d[0+2],10)<<4
            q[8]+=bit_at(d[12+2],0)<<4
            q[9]+=bit_at(d[8+1],4)<<4

            q[4]+=bit_at(d[12+1],4)<<5
            q[5]+=bit_at(d[0+1],10)<<5
            q[6]+=bit_at(d[12+2],1)<<5
            q[8]+=bit_at(d[12+2],2)<<5
            q[9]+=bit_at(d[12+2],3)<<5
        case 4:
            q[4]+=bit_at(d[0+0],10)<<4
            q[5]+=bit_at(d[0+1],10)<<4
            q[8]+=bit_at(d[12+2],1)<<4
            q[9]+=bit_at(d[12+2],4)<<4

            q[4]+=bit_at(d[8+2],4)<<5
            q[5]+=bit_at(d[12+2],0)<<5
            q[6]+=bit_at(d[0+2],10)<<5
            q[8]+=bit_at(d[12+2],2)<<5
            q[9]+=bit_at(d[12+2],3)<<5
        }

        packed[1]=(q[2]<<20)+(q[1]<<10)+q[0]
        packed[2]=(q[6]<<20)+(q[5]<<10)+q[4]
        packed[3]=(q[9]<<6)+q[8]
    case 5:
        transform(&d,qep,4,31)

        q[0]=u32(d[0])
        q[1]=u32(d[1])
        q[2]=u32(d[2])
        q[4]=u32(d[4]+(d[8+1]&15)*64)
        q[5]=u32(d[5]+(d[12+1]&15)*64)
        q[6]=u32(d[6]+(d[8+2]&15)*64)
        q[8]=u32(d[8])
        q[9]=u32(d[12])

        q[0]+=bit_at(d[8+2],4)<<9
        q[1]+=bit_at(d[8+1],4)<<9
        q[2]+=bit_at(d[12+2],4)<<9

        q[4]+=bit_at(d[12+1],4)<<5
        q[5]+=bit_at(d[12+2],0)<<5
        q[6]+=bit_at(d[12+2],1)<<5

        q[8]+=bit_at(d[12+2],2)<<5
        q[9]+=bit_at(d[12+2],3)<<5

        packed[0]=MODE_PREFIXES[5]

        packed[1]=(q[2]<<20)+(q[1]<<10)+q[0]
        packed[2]=(q[6]<<20)+(q[5]<<10)+q[4]
        packed[3]=(q[9]<<6)+q[8]
    case 6,7,8:
        transform(&d,qep,4,31,int(mode-6),63)

        q[0]=u32(d[0])
        q[0]+=bit_at(d[8+2],4)<<9

        q[1]=u32(d[1])
        q[1]+=bit_at(d[8+1],4)<<9

        q[2]=u32(d[2])
        q[2]+=bit_at(d[12+2],4)<<9

        q[4]=u32(d[4]+(d[8+1]&15)*64)
        q[5]=u32(d[5]+(d[12+1]&15)*64)
        q[6]=u32(d[6]+(d[8+2]&15)*64)

        q[8]=u32(d[8])
        q[9]=u32(d[12])

        packed[0]=MODE_PREFIXES[mode]
        switch mode {
        case 6:
            q[0]+=bit_at(d[12+1],4)<<8
            q[1]+=bit_at(d[12+2],2)<<8
            q[2]+=bit_at(d[12+2],3)<<8
            q[5]+=bit_at(d[12+2],0)<<5
            q[6]+=bit_at(d[12+2],1)<<5
        case 7:
            q[0]+=bit_at(d[12+2],0)<<8
            q[1]+=bit_at(d[8+1],5)<<8
            q[2]+=bit_at(d[12+1],5)<<8
            q[4]+=bit_at(d[12+1],4)<<5
            q[6]+=bit_at(d[12+2],1)<<5
            q[8]+=bit_at(d[12+2],2)<<5
            q[9]+=bit_at(d[12+2],3)<<5
        case 8:
            q[0]+=bit_at(d[12+2],1)<<8
            q[1]+=bit_at(d[8+2],5)<<8
            q[2]+=bit_at(d[12+2],5)<<8
            q[4]+=bit_at(d[12+1],4)<<5
            q[5]+=bit_at(d[12+2],0)<<5
            q[8]+=bit_at(d[12+2],2)<<5
            q[9]+=bit_at(d[12+2],3)<<5
        }

        packed[1]=(q[2]<<20)+(q[1]<<10)+q[0]
        packed[2]=(q[6]<<20)+(q[5]<<10)+q[4]
        packed[3]=(q[9]<<6)+q[8]
    case 9:
        q[0]=u32(qep[0])
        q[0]+=bit_at(qep[12+1],4)<<6
        q[0]+=bit_at(qep[12+2],0)<<7
        q[0]+=bit_at(qep[12+2],1)<<8
        q[0]+=bit_at(qep[8+2],4)<<9

        q[1]=u32(qep[1])
        q[1]+=bit_at(qep[8+1],5)<<6
        q[1]+=bit_at(qep[8+2],5)<<7
        q[1]+=bit_at(qep[12+2],2)<<8
        q[1]+=bit_at(qep[8+1],4)<<9

        q[2]=u32(qep[2])
        q[2]+=bit_at(qep[12+1],5)<<6
        q[2]+=bit_at(qep[12+2],3)<<7
        q[2]+=bit_at(qep[12+2],5)<<8
        q[2]+=bit_at(qep[12+2],4)<<9

        q[4]=u32(qep[4]+(qep[8+1]&15)*64)
        q[5]=u32(qep[5]+(qep[12+1]&15)*64)
        q[6]=u32(qep[6]+(qep[8+2]&15)*64)

        packed[0]=MODE_PREFIXES[9]
        packed[1]=(q[2]<<20)+(q[1]<<10)+q[0]
        packed[2]=(q[6]<<20)+(q[5]<<10)+q[4]
        packed[3]=(u32(qep[12])<<6)+u32(qep[8])
    case 10:
        packed[0]=MODE_PREFIXES[10]
        packed[1]=(u32(qep[2])<<20)+(u32(qep[1])<<10)+u32(qep[0])
        packed[2]=(u32(qep[6])<<20)+(u32(qep[5])<<10)+u32(qep[4])
    case 11:
        transform(&d,qep,2,511)

        q[0]=u32(d[0]&1023)
        q[1]=u32(d[1]&1023)
        q[2]=u32(d[2]&1023)

        q[4]=u32(d[4]+(d[0]>>10)*512)
        q[5]=u32(d[5]+(d[1]>>10)*512)
        q[6]=u32(d[6]+(d[2]>>10)*512)

        packed[0]=MODE_PREFIXES[11]
        packed[1]=(q[2]<<20)+(q[1]<<10)+q[0]
        packed[2]=(q[6]<<20)+(q[5]<<10)+q[4]
    case 12:
        transform(&d,qep,2,255)

        q[0]=u32(d[0]&1023)
        q[1]=u32(d[1]&1023)
        q[2]=u32(d[2]&1023)

        q[4]=u32(d[4])+reverse_bits(u32(d[0]>>10),2)*256
        q[5]=u32(d[5])+reverse_bits(u32(d[1]>>10),2)*256
        q[6]=u32(d[6])+reverse_bits(u32(d[2]>>10),2)*256

        packed[0]=MODE_PREFIXES[12]
        packed[1]=(q[2]<<20)+(q[1]<<10)+q[0]
        packed[2]=(q[6]<<20)+(q[5]<<10)+q[4]
    case 13:
        transform(&d,qep,2,15)

        q[0]=u32(d[0]&1023)
        q[1]=u32(d[1]&1023)
        q[2]=u32(d[2]&1023)

        q[4]=u32(d[4])+reverse_bits(u32(d[0]>>10),6)*16
        q[5]=u32(d[5])+reverse_bits(u32(d[1]>>10),6)*16
        q[6]=u32(d[6])+reverse_bits(u32(d[2]>>10),6)*16

        packed[0]=MODE_PREFIXES[13]
        packed[1]=(q[2]<<20)+(q[1]<<10)+q[0]
        packed[2]=(q[6]<<20)+(q[5]<<10)+q[4]
    }
}

@(private="file")
put_bits :: proc(data:^[5]u32,pos:^int,bits:int,v:u32) {
    data[pos^/32]|=v<<uint(pos^%32)
    if pos^%32+bits>32 {
        data[pos^/32+1]|=v>>uint(32-pos^%32)
    }
    pos^+=bits
}

@(private="file")
data_shl_1bit_from :: proc(data:^[5]u32,from:int) {
    if from<96 {
        shifted:=(data[2]>>1)|(data[3]<<31)
        mask:=((u32(1)<<uint(from-64))-1)>>1
        data[2]=(mask&data[2])|(~mask&shifted)
        data[3]=(data[3]>>1)|(data[4]<<31)
        data[4]=data[4]>>1
    } else if from<128 {
        shifted:=(data[3]>>1)|(data[4]<<31)
        mask:=((u32(1)<<uint(from-96))-1)>>1
        data[3]=(mask&data[3])|(~mask&shifted)
        data[4]=data[4]>>1
    }
}

@(private="file")
code_qblock :: proc(data:^[5]u32,pos:^int,qblock:^[2]u32,bits:int,flips:i32) {
    levels:=i32(1)<<uint(bits)
    flips_shifted:=flips
    for k1 in 0..<2 {
        qbits_shifted:=qblock[k1]
        for k2 in 0..<8 {
            q:=i32(qbits_shifted&15)
            if (flips_shifted&1)>0 {q=(levels-1)-q}

            if k1==0 && k2==0 {
                put_bits(data,pos,bits-1,u32(q))
            } else {
                put_bits(data,pos,bits,u32(q))
            }
            qbits_shifted>>=4
            flips_shifted>>=1
        }
    }
}

@(private="file")
swap_endpoints :: proc(a,b:[]i32) {
    for i in 0..<4 {a[i],b[i]=b[i],a[i]}
}

@(private="file")
code_2p :: proc(data:^[5]u32,qep:[]i32,qblock:^[2]u32,part_id:i32,mode:i32) {
    anchors:=[2]int{0,int(SECOND_ANCHORS[part_id])}
    flips:i32=0
    for j in 0..<2 {
        k0:=anchors[j]
        q:=(qblock[k0>>3]<<uint(28-(k0&7)*4))>>28
        if q>=4 {
            swap_endpoints(qep[8*j:],qep[8*j+4:])
            flips|=pattern_mask(part_id,j)
        }
    }

    data^={}
    pos:=0

    packed:[4]u32
    pack(&packed,qep,mode)

    put_bits(data,&pos,5,packed[0])
    put_bits(data,&pos,30,packed[1])
    put_bits(data,&pos,30,packed[2])
    put_bits(data,&pos,12,packed[3])
    put_bits(data,&pos,5,u32(part_id))

    code_qblock(data,&pos,qblock,3,flips)
    data_shl_1bit_from(data,129-(15-anchors[1])*3)
}

@(private="file")
code_1p :: proc(data:^[5]u32,qep:[]i32,qblock:^[2]u32,mode:i32) {
    if (qblock[0]&15)>=8 {
        swap_endpoints(qep[0:],qep[4:])
        for k in 0..<2 {qblock[k]=0xFFFFFFFF-qblock[k]}
    }

    data^={}
    pos:=0

    packed:[4]u32
    pack(&packed,qep,mode)

    put_bits(data,&pos,5,packed[0])
    put_bits(data,&pos,30,packed[1])
    put_bits(data,&pos,30,packed[2])

    code_qblock(data,&pos,qblock,4,0)
}

@(private)
setup :: proc(s:^State) {
    for p in 0..<3 {
        s.rgb_bounds[p]=0xFFFF
        s.rgb_bounds[3+p]=0
    }

    for p in 0..<3 {
        for k in 0..<16 {
            s.block[p*16+k]=(s.block[p*16+k]/31)*64

            s.rgb_bounds[p]=fmin(s.rgb_bounds[p],s.block[p*16+k])
            s.rgb_bounds[3+p]=fmax(s.rgb_bounds[3+p],s.block[p*16+k])
        }
    }

    s.max_span=0
    s.max_span_idx=0

    for p in 0..<3 {
        rgb_span:=s.rgb_bounds[3+p]-s.rgb_bounds[p]
        if rgb_span>s.max_span {
            s.max_span_idx=i32(p)
            s.max_span=rgb_span
        }
    }
}

@(private="file")
encode_core :: proc(s:^State) {
    setup(s)

    if s.slow_mode {
        test_mode(s,0,true,0)
        test_mode(s,1,true,0)
        test_mode(s,2,true,0)
        test_mode(s,5,true,0)
        test_mode(s,6,true,0)
        test_mode(s,9,true,0)
        test_mode(s,10,true,0)
        test_mode(s,11,true,0)
        test_mode(s,12,true,0)
        test_mode(s,13,true,0)
        return
    }

    divisor:f32=1.2
    margin:=1/divisor

    if s.fast_skip_threshold>0 {
        test_mode(s,9,false,0)
        if s.fast_mode {test_mode(s,1,false,1)}
        test_mode(s,6,false,margin)
        test_mode(s,5,false,margin)
        test_mode(s,0,false,margin)
        test_mode(s,2,false,1)

        enc_2p(s)
        if !s.fast_mode {test_mode(s,1,true,0)}
    }

    test_mode(s,10,false,0)
    test_mode(s,11,false,1)
    test_mode(s,12,false,1)
    test_mode(s,13,false,1)
    enc_1p(s)
}
