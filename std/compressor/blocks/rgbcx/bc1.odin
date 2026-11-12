#+private
package rgbcx

NUM_UNIQUE_TOTAL_ORDERINGS4::969
NUM_UNIQUE_TOTAL_ORDERINGS3::153

// Indices of the orderings that put all 16 texels on one selector.
TOTAL_ORDER_4_0_16::15
TOTAL_ORDER_4_1_16::700
TOTAL_ORDER_4_2_16::753
TOTAL_ORDER_4_3_16::515
TOTAL_ORDER_3_0_16::12
TOTAL_ORDER_3_1_16::15
TOTAL_ORDER_3_2_16::89

@(rodata)
WEIGHT_VALS4:=[4]u32{0x000009,0x010204,0x040201,0x090000}
@(rodata)
WEIGHT_VALS3:=[3]u32{0x000004,0x040000,0x010101}
@(rodata)
ADJACENT_VOXELS:=[16][4]i8{
    {1,0,0,3},{0,1,0,4},{0,0,1,5},{-1,0,0,0},{0,-1,0,1},{0,0,-1,2},{1,1,0,9},{1,0,1,10},
    {0,1,1,11},{-1,-1,0,6},{-1,0,-1,7},{0,-1,-1,8},{-1,1,0,13},{1,-1,0,12},{0,-1,1,15},{0,1,-1,14},
}

Match_Entry::struct {hi,lo,e:u8}
Vec3f::[3]f32
// Endpoints in 5:6:5, low and high in linear selector order.
Endpoints::struct {lr,lg,lb,hr,hg,hb:i32}
Block_Colors::struct {r,g,b:[4]i32}
Block_Stats::struct {min,max,avg,total:[3]i32}
Ordering_Sums::[3][17]u32

Encode_Results::struct {
    ep:Endpoints,
    sels:[16]u8,
    three_color:bool,
}

square::#force_inline proc "contextless" (a:i32) -> i32 {return a*a}

to_5::#force_inline proc "contextless" (v:i32) -> i32 {
    x:=u32(v)*31+128
    return i32(u8((x+(x>>8))>>8))
}

to_6::#force_inline proc "contextless" (v:i32) -> i32 {
    x:=u32(v)*63+128
    return i32(u8((x+(x>>8))>>8))
}

scale_5_to_8::#force_inline proc "contextless" (v:i32) -> i32 {return (v<<3)|(v>>2)}
scale_6_to_8::#force_inline proc "contextless" (v:i32) -> i32 {return (v<<2)|(v>>4)}

interp_5_6_ideal::#force_inline proc "contextless" (c0,c1:i32) -> i32 {return (c0*2+c1)/3}
interp_5_6_ideal_round::#force_inline proc "contextless" (c0,c1:i32) -> i32 {return (c0*2+c1+1)/3}
interp_half_5_6_ideal::#force_inline proc "contextless" (c0,c1:i32) -> i32 {return (c0+c1)/2}
interp_5_nv::#force_inline proc "contextless" (v0,v1:i32) -> i32 {return ((2*v0+v1)*22)/8}
interp_half_5_nv::#force_inline proc "contextless" (v0,v1:i32) -> i32 {return ((v0+v1)*33)/8}
interp_5_6_amd::#force_inline proc "contextless" (c0,c1:i32) -> i32 {return (c0*43+c1*21+32)>>6}
interp_half_5_6_amd::#force_inline proc "contextless" (c0,c1:i32) -> i32 {return (c0+c1+1)>>1}

interp_6_nv::#force_inline proc "contextless" (c0,c1:i32) -> i32 {
    gdiff:=c1-c0
    return (256*c0+(gdiff/4)+128+gdiff*80)/256
}

interp_half_6_nv::#force_inline proc "contextless" (c0,c1:i32) -> i32 {
    gdiff:=c1-c0
    return (256*c0+gdiff/4+128+gdiff*128)/256
}

interp_5::proc "contextless" (v0,v1,c0,c1:i32,mode:Bc1_Approx_Mode) -> i32 {
    #partial switch mode {
    case .Nvidia:return interp_5_nv(v0,v1)
    case .AMD:return interp_5_6_amd(c0,c1)
    case .Ideal_Round_4:return interp_5_6_ideal_round(c0,c1)
    }
    return interp_5_6_ideal(c0,c1)
}

interp_6::proc "contextless" (c0,c1:i32,mode:Bc1_Approx_Mode) -> i32 {
    #partial switch mode {
    case .Nvidia:return interp_6_nv(c0,c1)
    case .AMD:return interp_5_6_amd(c0,c1)
    case .Ideal_Round_4:return interp_5_6_ideal_round(c0,c1)
    }
    return interp_5_6_ideal(c0,c1)
}

interp_half_5::proc "contextless" (v0,v1,c0,c1:i32,mode:Bc1_Approx_Mode) -> i32 {
    #partial switch mode {
    case .Nvidia:return interp_half_5_nv(v0,v1)
    case .AMD:return interp_half_5_6_amd(c0,c1)
    }
    return interp_half_5_6_ideal(c0,c1)
}

interp_half_6::proc "contextless" (c0,c1:i32,mode:Bc1_Approx_Mode) -> i32 {
    #partial switch mode {
    case .Nvidia:return interp_half_6_nv(c0,c1)
    case .AMD:return interp_half_5_6_amd(c0,c1)
    }
    return interp_half_5_6_ideal(c0,c1)
}

prepare_single_color_table::proc "contextless" (table:^[256]Match_Entry,expand:[]u8,half:bool,mode:Bc1_Approx_Mode) {
    size:=i32(len(expand))
    for i in i32(0)..<256 {
        lowest_e:i32=256
        for lo in i32(0)..<size {
            lo_e:=i32(expand[lo])
            for hi in i32(0)..<size {
                hi_e:=i32(expand[hi])
                v:i32
                switch {
                case size==32 && half:v=interp_half_5(hi,lo,hi_e,lo_e,mode)
                case size==32:v=interp_5(hi,lo,hi_e,lo_e,mode)
                case half:v=interp_half_6(hi_e,lo_e,mode)
                case:v=interp_6(hi_e,lo_e,mode)
                }
                e:=abs(v-i)
                if mode==.Ideal || mode==.Ideal_Round_4 {e+=(abs(hi_e-lo_e)*3)/100}
                // Equal endpoints win ties: real GPUs approximate the interpolation.
                if e<lowest_e || (e==lowest_e && lo==hi) {
                    table[i]=Match_Entry{u8(hi),u8(lo),u8(e)}
                    lowest_e=e
                }
            }
        }
    }
}

// Inverts the normal matrix packed in weight_accum, which holds z00, z10 and z11 by bytes.
weight_inverse::proc "contextless" (weight_accum:u32,scale:f32) -> (iz00,iz10,iz11:f32,ok:bool) {
    z00:=f32((weight_accum>>16)&0xFF)
    z10:=f32((weight_accum>>8)&0xFF)
    z11:=f32(weight_accum&0xFF)
    det:=z00*z11-z10*z10
    if abs(det)<1e-8 {return}
    det=scale/det
    return z11*det,-z10*det,z00*det,true
}

selector_factors4::proc "contextless" (hist:[4]u8) -> [3]f32 {
    weight_accum:u32
    for sel in 0..<4 {weight_accum+=WEIGHT_VALS4[sel]*u32(hist[sel])}
    iz00,iz10,iz11,_:=weight_inverse(weight_accum,3.0/255.0)
    return {iz00,iz10,iz11}
}

selector_factors3::proc "contextless" (hist:[3]u8) -> [3]f32 {
    weight_accum:u32
    for sel in 0..<3 {weight_accum+=WEIGHT_VALS3[sel]*u32(hist[sel])}
    iz00,iz10,iz11,_:=weight_inverse(weight_accum,2.0/255.0)
    return {iz00,iz10,iz11}
}

lookup_ordering4::#force_inline proc "contextless" (t:^Tables,h:[4]u8) -> u32 {
    switch {
    case h[0]==16:return TOTAL_ORDER_4_0_16
    case h[1]==16:return TOTAL_ORDER_4_1_16
    case h[2]==16:return TOTAL_ORDER_4_2_16
    case h[3]==16:return TOTAL_ORDER_4_3_16
    }
    return u32(t.total_ordering4_hash[u32(h[0])|u32(h[1])<<4|u32(h[2])<<8])
}

lookup_ordering3::#force_inline proc "contextless" (t:^Tables,h:[3]u8) -> u32 {
    switch {
    case h[0]==16:return TOTAL_ORDER_3_0_16
    case h[1]==16:return TOTAL_ORDER_3_1_16
    case h[2]==16:return TOTAL_ORDER_3_2_16
    }
    return u32(t.total_ordering3_hash[u32(h[0])|u32(h[1])<<4])
}

least_squares_ordering4::#force_inline proc "contextless" (total:[3]i32,factors:[3]f32,s:u32,sums:^Ordering_Sums) -> (xl,xh:Vec3f) {
    iz00,iz10,iz11:=factors[0],factors[1],factors[2]
    iz01:=iz10
    o:=UNIQUE_TOTAL_ORDERS4[s]
    f1:=u32(o[0])
    f2:=f1+u32(o[1])
    f3:=f2+u32(o[2])
    for ch in 0..<3 {
        sum:=&sums[ch]
        uq00:=(sum[f2]-sum[f1])+(sum[f3]-sum[f2])*2+(sum[16]-sum[f3])*3
        q10:=f32(u32(total[ch]*3)-uq00)
        xl[ch]=iz00*f32(uq00)+iz01*q10
        xh[ch]=iz10*f32(uq00)+iz11*q10
    }
    return
}

// Compensates for the BC1 3-color selector order, which is 0, 2, 1.
least_squares_ordering3::#force_inline proc "contextless" (total:[3]i32,factors:[3]f32,s:u32,sums:^Ordering_Sums) -> (xl,xh:Vec3f) {
    iz00,iz10,iz11:=factors[0],factors[1],factors[2]
    iz01:=iz10
    o:=UNIQUE_TOTAL_ORDERS3[s]
    f1:=u32(o[0])
    f2:=f1+u32(o[2])
    for ch in 0..<3 {
        sum:=&sums[ch]
        uq00:=(sum[16]-sum[f2])*2+(sum[f2]-sum[f1])
        q10:=f32(u32(total[ch]*2)-uq00)
        xl[ch]=iz00*f32(uq00)+iz01*q10
        xh[ch]=iz10*f32(uq00)+iz11*q10
    }
    return
}

least_squares_sels4::proc "contextless" (src:[^]Color32,sels:^[16]u8,total:[3]i32) -> (xl,xh:Vec3f,ok:bool) {
    uq00:[3]u32
    weight_accum:u32
    for i in 0..<16 {
        sel:=sels[i]
        weight_accum+=WEIGHT_VALS4[sel]
        for ch in 0..<3 {uq00[ch]+=u32(sel)*u32(src[i][ch])}
    }
    iz00,iz10,iz11,solved:=weight_inverse(weight_accum,3.0/255.0)
    if !solved {return}
    iz01:=iz10
    for ch in 0..<3 {
        q10:=f32(i32(total[ch]*3)-i32(uq00[ch]))
        xl[ch]=iz00*f32(uq00[ch])+iz01*q10
        xh[ch]=iz10*f32(uq00[ch])+iz11*q10
    }
    return xl,xh,true
}

least_squares_sels3::proc "contextless" (use_black:bool,src:[^]Color32,sels:^[16]u8) -> (xl,xh:Vec3f,ok:bool) {
    TRAN:=[3]i32{0,2,1}
    uq00,total:[3]i32
    weight_accum:u32
    for i in 0..<16 {
        c:=src[i]
        if use_black && (c.r|c.g|c.b)<4 {continue}
        sel:=sels[i]
        if sel==3 {continue}
        weight_accum+=WEIGHT_VALS3[sel]
        for ch in 0..<3 {
            uq00[ch]+=TRAN[sel]*i32(c[ch])
            total[ch]+=i32(c[ch])
        }
    }
    iz00,iz10,iz11,solved:=weight_inverse(weight_accum,2.0/255.0)
    if !solved {return}
    iz01:=iz10
    for ch in 0..<3 {
        q10:=f32(total[ch]*2-uq00[ch])
        xl[ch]=iz00*f32(uq00[ch])+iz01*q10
        xh[ch]=iz10*f32(uq00[ch])+iz11*q10
    }
    return xl,xh,true
}

block_colors4::#force_inline proc "contextless" (mode:Bc1_Approx_Mode,e:Endpoints) -> (c:Block_Colors) {
    c.r[0],c.g[0],c.b[0]=scale_5_to_8(e.lr),scale_6_to_8(e.lg),scale_5_to_8(e.lb)
    c.r[3],c.g[3],c.b[3]=scale_5_to_8(e.hr),scale_6_to_8(e.hg),scale_5_to_8(e.hb)
    switch mode {
    case .Ideal:
        c.r[1],c.g[1],c.b[1]=interp_5_6_ideal(c.r[0],c.r[3]),interp_5_6_ideal(c.g[0],c.g[3]),interp_5_6_ideal(c.b[0],c.b[3])
        c.r[2],c.g[2],c.b[2]=interp_5_6_ideal(c.r[3],c.r[0]),interp_5_6_ideal(c.g[3],c.g[0]),interp_5_6_ideal(c.b[3],c.b[0])
    case .Ideal_Round_4:
        c.r[1],c.g[1],c.b[1]=interp_5_6_ideal_round(c.r[0],c.r[3]),interp_5_6_ideal_round(c.g[0],c.g[3]),interp_5_6_ideal_round(c.b[0],c.b[3])
        c.r[2],c.g[2],c.b[2]=interp_5_6_ideal_round(c.r[3],c.r[0]),interp_5_6_ideal_round(c.g[3],c.g[0]),interp_5_6_ideal_round(c.b[3],c.b[0])
    case .AMD:
        c.r[1],c.g[1],c.b[1]=interp_5_6_amd(c.r[0],c.r[3]),interp_5_6_amd(c.g[0],c.g[3]),interp_5_6_amd(c.b[0],c.b[3])
        c.r[2],c.g[2],c.b[2]=interp_5_6_amd(c.r[3],c.r[0]),interp_5_6_amd(c.g[3],c.g[0]),interp_5_6_amd(c.b[3],c.b[0])
    case .Nvidia:
        c.r[1],c.g[1],c.b[1]=interp_5_nv(e.lr,e.hr),interp_6_nv(c.g[0],c.g[3]),interp_5_nv(e.lb,e.hb)
        c.r[2],c.g[2],c.b[2]=interp_5_nv(e.hr,e.lr),interp_6_nv(c.g[3],c.g[0]),interp_5_nv(e.hb,e.lb)
    }
    return
}

block_colors3::#force_inline proc "contextless" (mode:Bc1_Approx_Mode,e:Endpoints) -> (c:Block_Colors) {
    c.r[0],c.g[0],c.b[0]=scale_5_to_8(e.lr),scale_6_to_8(e.lg),scale_5_to_8(e.lb)
    c.r[1],c.g[1],c.b[1]=scale_5_to_8(e.hr),scale_6_to_8(e.hg),scale_5_to_8(e.hb)
    switch mode {
    case .Ideal,.Ideal_Round_4:
        c.r[2],c.g[2],c.b[2]=interp_half_5_6_ideal(c.r[0],c.r[1]),interp_half_5_6_ideal(c.g[0],c.g[1]),interp_half_5_6_ideal(c.b[0],c.b[1])
    case .AMD:
        c.r[2],c.g[2],c.b[2]=interp_half_5_6_amd(c.r[0],c.r[1]),interp_half_5_6_amd(c.g[0],c.g[1]),interp_half_5_6_amd(c.b[0],c.b[1])
    case .Nvidia:
        c.r[2],c.g[2],c.b[2]=interp_half_5_nv(e.lr,e.hr),interp_half_6_nv(c.g[0],c.g[1]),interp_half_5_nv(e.lb,e.hb)
    }
    return
}

find_sels4_noerr::proc "contextless" (mode:Bc1_Approx_Mode,src:[^]Color32,e:Endpoints,sels:^[16]u8) #no_bounds_check {
    c:=block_colors4(mode,e)
    ar,ag,ab:=c.r[3]-c.r[0],c.g[3]-c.g[0],c.b[3]-c.b[0]
    d0:=c.r[0]*ar+c.g[0]*ag+c.b[0]*ab
    d1:=c.r[1]*ar+c.g[1]*ag+c.b[1]*ab
    d2:=c.r[2]*ar+c.g[2]*ag+c.b[2]*ab
    d3:=c.r[3]*ar+c.g[3]*ag+c.b[3]*ab
    t0,t1,t2:=d0+d1,d1+d2,d2+d3
    ar,ag,ab=ar*2,ag*2,ab*2
    for i in 0..<16 {
        d:=i32(src[i].r)*ar+i32(src[i].g)*ag+i32(src[i].b)*ab
        sels[i]=u8(3-(i32(d<=t0)+i32(d<t1)+i32(d<t2)))
    }
}

find_sels4_fasterr::proc "contextless" (mode:Bc1_Approx_Mode,src:[^]Color32,e:Endpoints,sels:^[16]u8,cur_err:u32) -> u32 #no_bounds_check {
    c:=block_colors4(mode,e)
    ar,ag,ab:=c.r[3]-c.r[0],c.g[3]-c.g[0],c.b[3]-c.b[0]
    d0:=c.r[0]*ar+c.g[0]*ag+c.b[0]*ab
    d1:=c.r[1]*ar+c.g[1]*ag+c.b[1]*ab
    d2:=c.r[2]*ar+c.g[2]*ag+c.b[2]*ab
    d3:=c.r[3]*ar+c.g[3]*ag+c.b[3]*ab
    t0,t1,t2:=d0+d1,d1+d2,d2+d3
    ar,ag,ab=ar*2,ag*2,ab*2
    total_err:u32
    for i in 0..<16 {
        r,g,b:=i32(src[i].r),i32(src[i].g),i32(src[i].b)
        d:=r*ar+g*ag+b*ab
        sel:=3-(i32(d<=t0)+i32(d<t1)+i32(d<t2))
        sels[i]=u8(sel)
        total_err+=u32(square(r-c.r[sel])+square(g-c.g[sel])+square(b-c.b[sel]))
        if i&3==3 && total_err>=cur_err {break}
    }
    return total_err
}

find_sels4_check2_err::proc "contextless" (mode:Bc1_Approx_Mode,src:[^]Color32,e:Endpoints,sels:^[16]u8,cur_err:u32) -> u32 #no_bounds_check {
    c:=block_colors4(mode,e)
    dr,dg,db:=c.r[3]-c.r[0],c.g[3]-c.g[0],c.b[3]-c.b[0]
    f:=4.0/(f32(square(dr)+square(dg)+square(db))+0.00000125)
    total_err:u32
    for i in 0..<16 {
        r,g,b:=i32(src[i].r),i32(src[i].g),i32(src[i].b)
        sel:=clamp(i32(f32((r-c.r[0])*dr+(g-c.g[0])*dg+(b-c.b[0])*db)*f+0.5),1,3)
        err0:=u32(square(c.r[sel-1]-r)+square(c.g[sel-1]-g)+square(c.b[sel-1]-b))
        err1:=u32(square(c.r[sel]-r)+square(c.g[sel]-g)+square(c.b[sel]-b))
        best_sel:=sel
        best_err:=err1
        if err0==err1 {
            // Prefer non-interpolation.
            if best_sel-1==0 {best_sel=0}
        } else if err0<best_err {
            best_sel=sel-1
            best_err=err0
        }
        total_err+=best_err
        if total_err>=cur_err {break}
        sels[i]=u8(best_sel)
    }
    return total_err
}

find_sels4_fullerr::proc "contextless" (mode:Bc1_Approx_Mode,src:[^]Color32,e:Endpoints,sels:^[16]u8,cur_err:u32) -> u32 #no_bounds_check {
    c:=block_colors4(mode,e)
    total_err:u32
    for i in 0..<16 {
        r,g,b:=i32(src[i].r),i32(src[i].g),i32(src[i].b)
        best_err:=u32(square(c.r[0]-r)+square(c.g[0]-g)+square(c.b[0]-b))
        best_sel:u8
        for j:=1;j<4 && best_err!=0;j+=1 {
            err:=u32(square(c.r[j]-r)+square(c.g[j]-g)+square(c.b[j]-b))
            if err<best_err || (err==best_err && j==3) {
                best_err=err
                best_sel=u8(j)
            }
        }
        total_err+=best_err
        if total_err>=cur_err {break}
        sels[i]=best_sel
    }
    return total_err
}

find_sels4::#force_inline proc "contextless" (mode:Bc1_Approx_Mode,flags:u32,src:[^]Color32,e:Endpoints,sels:^[16]u8,cur_err:u32) -> u32 {
    if flags&ENCODE_BC1_USE_FASTER_MSE_EVAL!=0 {return find_sels4_fasterr(mode,src,e,sels,cur_err)}
    if flags&ENCODE_BC1_USE_FULL_MSE_EVAL!=0 {return find_sels4_fullerr(mode,src,e,sels,cur_err)}
    return find_sels4_check2_err(mode,src,e,sels,cur_err)
}

find_sels3_fullerr::proc "contextless" (mode:Bc1_Approx_Mode,use_black:bool,src:[^]Color32,e:Endpoints,sels:^[16]u8,cur_err:u32) -> u32 #no_bounds_check {
    c:=block_colors3(mode,e)
    total_err:u32
    for i in 0..<16 {
        r,g,b:=i32(src[i].r),i32(src[i].g),i32(src[i].b)
        best_err:=u32(square(c.r[0]-r)+square(c.g[0]-g)+square(c.b[0]-b))
        best_sel:u8
        err1:=u32(square(c.r[1]-r)+square(c.g[1]-g)+square(c.b[1]-b))
        if err1<best_err {
            best_err=err1
            best_sel=1
        }
        err2:=u32(square(c.r[2]-r)+square(c.g[2]-g)+square(c.b[2]-b))
        if err2<best_err {
            best_err=err2
            best_sel=2
        }
        if use_black {
            err3:=u32(square(r)+square(g)+square(b))
            if err3<best_err {
                best_err=err3
                best_sel=3
            }
        }
        total_err+=best_err
        if total_err>=cur_err {return total_err}
        sels[i]=best_sel
    }
    return total_err
}

round_5::#force_inline proc "contextless" (x:f32) -> i32 #no_bounds_check {
    v:=clamp(i32(x*31.0),0,31)
    return (v+i32(x>MIDPOINT5[v]))&31
}

round_6::#force_inline proc "contextless" (x:f32) -> i32 #no_bounds_check {
    v:=clamp(i32(x*63.0),0,63)
    return (v+i32(x>MIDPOINT6[v]))&63
}

precise_round_565::#force_inline proc "contextless" (xl,xh:Vec3f) -> Endpoints {
    return {round_5(xl[0]),round_6(xl[1]),round_5(xl[2]),round_5(xh[0]),round_6(xh[1]),round_5(xh[2])}
}

write_endpoints::#force_inline proc "contextless" (dst:[^]u8,low,high:u32) {
    dst[0]=u8(low)
    dst[1]=u8(low>>8)
    dst[2]=u8(high)
    dst[3]=u8(high>>8)
}

encode4::proc "contextless" (dst:[^]u8,e:Endpoints,sels:^[16]u8) {
    lc16:=u32(e.lb)|u32(e.lg)<<5|u32(e.lr)<<11
    hc16:=u32(e.hb)|u32(e.hg)<<5|u32(e.hr)<<11
    if lc16==hc16 {
        mask:u8=0
        if hc16>0 {
            hc16-=1
        } else {
            hc16=0
            lc16=1
            mask=0x55
        }
        write_endpoints(dst,lc16,hc16)
        dst[4],dst[5],dst[6],dst[7]=mask,mask,mask,mask
        return
    }
    invert_mask:u8
    if lc16<hc16 {
        lc16,hc16=hc16,lc16
        invert_mask=0x55
    }
    write_endpoints(dst,lc16,hc16)
    TRAN:=[4]u32{0,2,3,1}
    packed:u32
    for i in 0..<u32(16) {packed|=TRAN[sels[i]]<<(i*2)}
    dst[4]=u8(packed)~invert_mask
    dst[5]=u8(packed>>8)~invert_mask
    dst[6]=u8(packed>>16)~invert_mask
    dst[7]=u8(packed>>24)~invert_mask
}

encode3::proc "contextless" (dst:[^]u8,e:Endpoints,sels:^[16]u8) {
    lc16:=u32(e.lb)|u32(e.lg)<<5|u32(e.lr)<<11
    hc16:=u32(e.hb)|u32(e.hg)<<5|u32(e.hr)<<11
    invert:=lc16>hc16
    if invert {lc16,hc16=hc16,lc16}
    write_endpoints(dst,lc16,hc16)
    TRAN:=[4]u32{1,0,2,3}
    packed:u32
    for i in 0..<u32(16) {packed|=(invert?TRAN[sels[i]]:u32(sels[i]))<<(i*2)}
    dst[4]=u8(packed)
    dst[5]=u8(packed>>8)
    dst[6]=u8(packed>>16)
    dst[7]=u8(packed>>24)
}

solid_endpoints4::#force_inline proc "contextless" (t:^Tables,avg:[3]i32) -> Endpoints {
    r,g,b:=t.match5_equals_1[avg[0]],t.match6_equals_1[avg[1]],t.match5_equals_1[avg[2]]
    return {i32(r.hi),i32(g.hi),i32(b.hi),i32(r.lo),i32(g.lo),i32(b.lo)}
}

solid_endpoints3::#force_inline proc "contextless" (t:^Tables,avg:[3]i32) -> Endpoints {
    r,g,b:=t.match5_half[avg[0]],t.match6_half[avg[1]],t.match5_half[avg[2]]
    return {i32(r.hi),i32(g.hi),i32(b.hi),i32(r.lo),i32(g.lo),i32(b.lo)}
}

// Sums the texels sorted along the endpoint axis, as cumulative prefixes.
ordered_sums::proc "contextless" (src:[^]Color32,e:Endpoints,total:[3]i32,sums:^Ordering_Sums) {
    ar:=scale_5_to_8(e.hr)-scale_5_to_8(e.lr)
    ag:=scale_6_to_8(e.hg)-scale_6_to_8(e.lg)
    ab:=scale_5_to_8(e.hb)-scale_5_to_8(e.lb)
    dots:[16]i32
    for i in 0..<16 {
        d:=0x1000000+(i32(src[i].r)*ar+i32(src[i].g)*ag+i32(src[i].b)*ab)
        dots[i]=(d<<4)+i32(i)
    }
    for i in 1..<16 {
        key:=dots[i]
        j:=i-1
        for j>=0 && dots[j]>key {
            dots[j+1]=dots[j]
            j-=1
        }
        dots[j+1]=key
    }
    running:[3]u32
    for i in 0..<16 {
        p:=dots[i]&15
        for ch in 0..<3 {
            sums[ch][i]=running[ch]
            running[ch]+=u32(src[p][ch])
        }
    }
    for ch in 0..<3 {sums[ch][16]=u32(total[ch])}
}

three_color_ls_passes::proc "contextless" (t:^Tables,src:[^]Color32,flags:u32,use_black:bool,avg:[3]i32,e:^Endpoints,sels:^[16]u8,err:^u32) {
    passes:=flags&ENCODE_BC1_TWO_LEAST_SQUARES_PASSES!=0?2:1
    for _ in 0..<passes {
        xl,xh,ok:=least_squares_sels3(use_black,src,sels)
        trial:=ok?precise_round_565(xh,xl):solid_endpoints3(t,avg)
        if trial==e^ {break}
        trial_sels:[16]u8=---
        trial_err:=find_sels3_fullerr(t.mode,use_black,src,trial,&trial_sels,err^)
        if trial_err>=err^ {break}
        err^=trial_err
        e^=trial
        sels^=trial_sels
    }
}

try_3color_block_useblack::proc "contextless" (t:^Tables,src:[^]Color32,flags:u32,cur_err:^u32,results:^Encode_Results) -> bool {
    total,max_c:[3]i32
    min_c:=[3]i32{255,255,255}
    total_pixels:i32
    for i in 0..<16 {
        c:=src[i]
        if (c.r|c.g|c.b)<4 {continue}
        for ch in 0..<3 {
            v:=i32(c[ch])
            max_c[ch]=max(max_c[ch],v)
            min_c[ch]=min(min_c[ch],v)
            total[ch]+=v
        }
        total_pixels+=1
    }
    if total_pixels==0 {return false}

    half:=total_pixels>>1
    avg:=[3]i32{(total[0]+half)/total_pixels,(total[1]+half)/total_pixels,(total[2]+half)/total_pixels}

    icov:[6]i32
    for i in 0..<16 {
        c:=src[i]
        if (c.r|c.g|c.b)<4 {continue}
        r,g,b:=i32(c.r)-avg[0],i32(c.g)-avg[1],i32(c.b)-avg[2]
        icov[0]+=r*r
        icov[1]+=r*g
        icov[2]+=r*b
        icov[3]+=g*g
        icov[4]+=g*b
        icov[5]+=b*b
    }

    cov:[6]f32
    for i in 0..<6 {cov[i]=f32(icov[i])*(1.0/255.0)}

    xr:=f32(max_c[0]-min_c[0])
    xg:=f32(max_c[1]-min_c[1])
    xb:=f32(max_c[2]-min_c[2])
    if icov[2]<0 {xr=-xr}
    if icov[4]<0 {xg=-xg}

    for _ in 0..<4 {
        r:=xr*cov[0]+xg*cov[1]+xb*cov[2]
        g:=xr*cov[1]+xg*cov[3]+xb*cov[4]
        b:=xr*cov[2]+xg*cov[4]+xb*cov[5]
        xr,xg,xb=r,g,b
    }

    k:=max(abs(xr),abs(xg),abs(xb))
    saxis_r,saxis_g,saxis_b:i32=306,601,117
    if k>=2 {
        m:=1024.0/k
        saxis_r=i32(xr*m)
        saxis_g=i32(xg*m)
        saxis_b=i32(xb*m)
    }

    low_dot,high_dot:=max(i32),min(i32)
    low_c,high_c:int
    for i in 0..<16 {
        c:=src[i]
        if (c.r|c.g|c.b)<4 {continue}
        dot:=i32(c.r)*saxis_r+i32(c.g)*saxis_g+i32(c.b)*saxis_b
        if dot<low_dot {
            low_dot=dot
            low_c=i
        }
        if dot>high_dot {
            high_dot=dot
            high_c=i
        }
    }

    e:=Endpoints{
        to_5(i32(src[low_c].r)),to_6(i32(src[low_c].g)),to_5(i32(src[low_c].b)),
        to_5(i32(src[high_c].r)),to_6(i32(src[high_c].g)),to_5(i32(src[high_c].b)),
    }

    trial_sels:[16]u8=---
    trial_err:=find_sels3_fullerr(t.mode,true,src,e,&trial_sels,max(u32))
    if trial_err!=0 {three_color_ls_passes(t,src,flags,true,avg,&e,&trial_sels,&trial_err)}

    if trial_err<cur_err^ {
        results.three_color=true
        results.ep=e
        results.sels=trial_sels
        cur_err^=trial_err
        return true
    }
    return false
}

try_3color_block::proc "contextless" (t:^Tables,src:[^]Color32,flags:u32,cur_err:^u32,stats:^Block_Stats,initial:Endpoints,total_orderings_to_try:u32,results:^Encode_Results) -> bool {
    e:=initial
    trial_sels:[16]u8=---
    trial_err:=find_sels3_fullerr(t.mode,false,src,e,&trial_sels,max(u32))
    if trial_err!=0 {three_color_ls_passes(t,src,flags,false,stats.avg,&e,&trial_sels,&trial_err)}

    if trial_err!=0 && flags&ENCODE_BC1_USE_LIKELY_TOTAL_ORDERINGS!=0 && total_orderings_to_try!=0 {
        h:[3]u8
        for i in 0..<16 {h[trial_sels[i]]+=1}
        orig_index:=lookup_ordering3(t,h)

        sums:Ordering_Sums=---
        ordered_sums(src,e,stats.total,&sums)

        exhaustive:=flags&ENCODE_BC1_EXHAUSTIVE!=0
        q_total:=exhaustive?NUM_UNIQUE_TOTAL_ORDERINGS3:min(total_orderings_to_try,MAX_TOTAL_ORDERINGS3)
        for q in 0..<q_total {
            s:=exhaustive?q:u32(BEST_TOTAL_ORDERINGS3[orig_index][q])
            trial:Endpoints
            if s==TOTAL_ORDER_3_0_16 || s==TOTAL_ORDER_3_1_16 || s==TOTAL_ORDER_3_2_16 {
                trial=solid_endpoints3(t,stats.avg)
            } else {
                xl,xh:=least_squares_ordering3(stats.total,t.selector_factors3[s],s,&sums)
                trial=precise_round_565(xh,xl)
            }
            trial_sels2:[16]u8=---
            trial_err2:=find_sels3_fullerr(t.mode,false,src,trial,&trial_sels2,max(u32))
            if trial_err2<trial_err {
                trial_err=trial_err2
                e=trial
                trial_sels=trial_sels2
            }
        }
    }

    if trial_err<cur_err^ {
        results.three_color=true
        results.ep=e
        results.sels=trial_sels
        cur_err^=trial_err
        return true
    }
    return false
}

pick_initial::proc "contextless" (src:[^]Color32,flags:u32,grayscale:bool,stats:^Block_Stats) -> (e:Endpoints) {
    min_c,max_c,avg,total:=stats.min,stats.max,stats.avg,stats.total
    if grayscale {
        fr:=i32(src[0].r)
        if max_c[0]-min_c[0]<2 {
            v5,v6:=to_5(fr),to_6(fr)
            e={v5,v6,v5,v5,v6,v5}
        } else {
            e={to_5(min_c[0]),to_6(min_c[0]),to_5(min_c[0]),to_5(max_c[0]),to_6(max_c[0]),to_5(max_c[0])}
        }
        return
    }

    if flags&ENCODE_BC1_USE_2DLS!=0 {
        // 2D least squares along the widest channel, with an inset and optimal rounding.
        x,y,z:=0,1,2
        if max_c[1]-min_c[1]>max_c[x]-min_c[x] {x,y,z=1,0,2}
        if max_c[2]-min_c[2]>max_c[x]-min_c[x] {x,y,z=2,0,1}
        min_chan_val,max_chan_val:=min_c[x],max_c[x]

        sum_xx,sum_xy,sum_xz:i32
        for i in 0..<16 {
            vx,vy,vz:=i32(src[i][x]),i32(src[i][y]),i32(src[i][z])
            sum_xx+=vx*vx
            sum_xy+=vx*vy
            sum_xz+=vx*vz
        }

        sum_x:=total[x]
        div:=f32(16*sum_xx-sum_x*sum_x)
        b_y,b_z:f32
        if abs(div)>1e-8 {
            div=1.0/div
            b_y=f32(16*sum_xy-sum_x*total[y])*div
            b_z=f32(16*sum_xz-sum_x*total[z])*div
        }

        a_y:=(f32(total[y])-b_y*f32(sum_x))/16.0
        a_z:=(f32(total[z])-b_z*f32(sum_x))/16.0

        l,h:Vec3f
        l[y]=a_y+b_y*f32(min_chan_val)
        l[z]=a_z+b_z*f32(min_chan_val)
        h[y]=a_y+b_y*f32(max_chan_val)
        h[z]=a_z+b_z*f32(max_chan_val)

        dy:=h[y]-l[y]
        dz:=h[z]-l[z]
        h[y]=l[y]+dy*(15.0/16.0)
        h[z]=l[z]+dz*(15.0/16.0)
        l[y]=l[y]+dy*(1.0/16.0)
        l[z]=l[z]+dz*(1.0/16.0)

        d:=f32(max_chan_val-min_chan_val)
        l[x]=f32(min_chan_val)+d*(1.0/16.0)
        h[x]=f32(min_chan_val)+d*(15.0/16.0)

        return precise_round_565(l*(1.0/255.0),h*(1.0/255.0))
    }

    if flags&ENCODE_BC1_BOUNDING_BOX!=0 {
        l,h:Vec3f
        for ch in 0..<3 {
            l[ch]=f32(min_c[ch])*(1.0/255.0)
            h[ch]=f32(max_c[ch])*(1.0/255.0)
        }
        bias:f32=8.0/255.0
        for ch in 0..<3 {
            inset:=(h[ch]-l[ch]-bias)*(1.0/16.0)
            l[ch]=clamp(l[ch]+inset,0.0,1.0)
            h[ch]=clamp(h[ch]-inset,0.0,1.0)
        }
        icov_xz,icov_yz:i32
        for i in 0..<16 {
            r,g,b:=i32(src[i].r)-avg[0],i32(src[i].g)-avg[1],i32(src[i].b)-avg[2]
            icov_xz+=r*b
            icov_yz+=g*b
        }
        if icov_xz<0 {l[0],h[0]=h[0],l[0]}
        if icov_yz<0 {l[1],h[1]=h[1],l[1]}
        return precise_round_565(l,h)
    }

    if flags&ENCODE_BC1_BOUNDING_BOX_INT!=0 {
        inset_r:=(max_c[0]-min_c[0]-8)>>4
        inset_g:=(max_c[1]-min_c[1]-8)>>4
        inset_b:=(max_c[2]-min_c[2]-8)>>4

        x0:=clamp(min_c[0]+inset_r,0,255)
        y0:=clamp(min_c[1]+inset_g,0,255)
        z0:=clamp(min_c[2]+inset_b,0,255)
        x1:=clamp(max_c[0]-inset_r,0,255)
        y1:=clamp(max_c[1]-inset_g,0,255)
        z1:=clamp(max_c[2]-inset_b,0,255)

        icov_xz,icov_yz:i32
        for i in 0..<16 {
            r,g,b:=i32(src[i].r)-avg[0],i32(src[i].g)-avg[1],i32(src[i].b)-avg[2]
            icov_xz+=r*b
            icov_yz+=g*b
        }
        if icov_xz<0 {x0,x1=x1,x0}
        if icov_yz<0 {y0,y1=y1,y0}
        return {to_5(x0),to_6(y0),to_5(z0),to_5(x1),to_6(y1),to_5(z1)}
    }

    icov:[6]i32
    for i in 0..<16 {
        r,g,b:=i32(src[i].r)-avg[0],i32(src[i].g)-avg[1],i32(src[i].b)-avg[2]
        icov[0]+=r*r
        icov[1]+=r*g
        icov[2]+=r*b
        icov[3]+=g*g
        icov[4]+=g*b
        icov[5]+=b*b
    }

    saxis_r,saxis_g,saxis_b:i32=306,601,117

    xr:=f32(max_c[0]-min_c[0])
    xg:=f32(max_c[1]-min_c[1])
    xb:=f32(max_c[2]-min_c[2])
    if icov[2]<0 {xr=-xr}
    if icov[4]<0 {xg=-xg}

    cov:[6]f32
    for i in 0..<6 {cov[i]=f32(icov[i])*(1.0/255.0)}

    power_iters:=flags&ENCODE_BC1_USE_6_POWER_ITERS!=0?6:4
    for _ in 0..<power_iters {
        r:=xr*cov[0]+xg*cov[1]+xb*cov[2]
        g:=xr*cov[1]+xg*cov[3]+xb*cov[4]
        b:=xr*cov[2]+xg*cov[4]+xb*cov[5]
        xr,xg,xb=r,g,b
    }

    k:=max(abs(xr),abs(xg),abs(xb))
    if k>=2 {
        m:=2048.0/k
        saxis_r=i32(xr*m)
        saxis_g=i32(xg*m)
        saxis_b=i32(xb*m)
    }

    saxis_r<<=4
    saxis_g<<=4
    saxis_b<<=4

    low_dot,high_dot:=max(i32),min(i32)
    for i in 0..<16 {
        dot:=((i32(src[i].r)*saxis_r+i32(src[i].g)*saxis_g+i32(src[i].b)*saxis_b)&~0xF)+i32(i)
        low_dot=min(low_dot,dot)
        high_dot=max(high_dot,dot)
    }
    low_c:=low_dot&15
    high_c:=high_dot&15

    return {
        to_5(i32(src[low_c].r)),to_6(i32(src[low_c].g)),to_5(i32(src[low_c].b)),
        to_5(i32(src[high_c].r)),to_6(i32(src[high_c].g)),to_5(i32(src[high_c].b)),
    }
}

endpoint_search::proc "contextless" (t:^Tables,src:[^]Color32,any_black:bool,flags:u32,results:^Encode_Results,start_err:u32) {
    cur_err:=start_err
    prev_improvement_index,forbidden_direction:=i32(0),i32(-1)
    rounds:=i32((flags&ENCODE_BC1_ENDPOINT_SEARCH_ROUNDS_MASK)>>ENCODE_BC1_ENDPOINT_SEARCH_ROUNDS_SHIFT)
    use_black:=any_black && flags&ENCODE_BC1_USE_3COLOR_BLOCKS_FOR_BLACK_PIXELS!=0
    for i in i32(0)..<rounds {
        if forbidden_direction==i&31 {continue}
        voxel:=ADJACENT_VOXELS[i&15]
        trial:=results.ep
        if (i>>4)&1!=0 {
            trial.lr=clamp(trial.lr+i32(voxel[0]),0,31)
            trial.lg=clamp(trial.lg+i32(voxel[1]),0,63)
            trial.lb=clamp(trial.lb+i32(voxel[2]),0,31)
        } else {
            trial.hr=clamp(trial.hr+i32(voxel[0]),0,31)
            trial.hg=clamp(trial.hg+i32(voxel[1]),0,63)
            trial.hb=clamp(trial.hb+i32(voxel[2]),0,31)
        }

        trial_sels:[16]u8=---
        trial_err:u32
        if results.three_color {
            trial_err=find_sels3_fullerr(t.mode,use_black,src,trial,&trial_sels,cur_err)
        } else {
            trial_err=find_sels4(t.mode,flags,src,trial,&trial_sels,cur_err)
        }

        if trial_err<cur_err {
            cur_err=trial_err
            forbidden_direction=i32(voxel[3])|(i&16)
            results.ep=trial
            results.sels=trial_sels
            prev_improvement_index=i
        }

        if i-prev_improvement_index>32 {break}
    }
}

encode_solid::proc "contextless" (t:^Tables,dst:[^]u8,fr,fg,fb:u8,allow_3color:bool) {
    mask:u8=0xAA
    max16,min16:i32=-1,0

    if allow_3color {
        err4:=u32(t.match5_equals_1[fr].e)+u32(t.match6_equals_1[fg].e)+u32(t.match5_equals_1[fb].e)
        err3:=u32(t.match5_half[fr].e)+u32(t.match6_half[fg].e)+u32(t.match5_half[fb].e)
        if err3<err4 {
            max16=i32(t.match5_half[fr].hi)<<11|i32(t.match6_half[fg].hi)<<5|i32(t.match5_half[fb].hi)
            min16=i32(t.match5_half[fr].lo)<<11|i32(t.match6_half[fg].lo)<<5|i32(t.match5_half[fb].lo)
            if max16>min16 {max16,min16=min16,max16}
        }
    }

    if max16==-1 {
        max16=i32(t.match5_equals_1[fr].hi)<<11|i32(t.match6_equals_1[fg].hi)<<5|i32(t.match5_equals_1[fb].hi)
        min16=i32(t.match5_equals_1[fr].lo)<<11|i32(t.match6_equals_1[fg].lo)<<5|i32(t.match5_equals_1[fb].lo)
        if min16==max16 {
            // 3-color blocks are forbidden so BC3 never uses punchthrough mode.
            mask=0
            if min16>0 {
                min16-=1
            } else {
                max16=1
                min16=0
                mask=0x55
            }
        }
        if max16<min16 {
            max16,min16=min16,max16
            mask~=0x55
        }
    }

    write_endpoints(dst,u32(max16),u32(min16))
    dst[4],dst[5],dst[6],dst[7]=mask,mask,mask,mask
}

encode_bc1_block::proc "contextless" (t:^Tables,dst:[^]u8,src:[^]Color32,flags,total_orderings_to_try,total_orderings_to_try3:u32) {
    fr,fg,fb:=src[0].r,src[0].g,src[0].b

    solid:=true
    for j:=15;j>=1;j-=1 {
        if src[j].r!=fr || src[j].g!=fg || src[j].b!=fb {
            solid=false
            break
        }
    }
    if solid {
        encode_solid(t,dst,fr,fg,fb,flags&(ENCODE_BC1_USE_3COLOR_BLOCKS|ENCODE_BC1_USE_3COLOR_BLOCKS_FOR_BLACK_PIXELS)!=0)
        return
    }

    stats:Block_Stats
    stats.total={i32(fr),i32(fg),i32(fb)}
    stats.min=stats.total
    stats.max=stats.total

    grayscale:=fr==fg && fr==fb
    any_black:=(fr|fg|fb)<4

    for i in 1..<16 {
        c:=src[i]
        grayscale&=(c.r==c.g && c.r==c.b)
        any_black|=(c.r|c.g|c.b)<4
        for ch in 0..<3 {
            v:=i32(c[ch])
            stats.max[ch]=max(stats.max[ch],v)
            stats.min[ch]=min(stats.min[ch],v)
            stats.total[ch]+=v
        }
    }

    for ch in 0..<3 {stats.avg[ch]=(stats.total[ch]+8)>>4}

    results:Encode_Results
    orig:Endpoints

    needs_block_error:=flags&(ENCODE_BC1_USE_LIKELY_TOTAL_ORDERINGS|ENCODE_BC1_USE_3COLOR_BLOCKS|ENCODE_BC1_USE_FULL_MSE_EVAL|ENCODE_BC1_ENDPOINT_SEARCH_ROUNDS_MASK)!=0 ||
        (any_black && flags&ENCODE_BC1_USE_3COLOR_BLOCKS_FOR_BLACK_PIXELS!=0)

    cur_err:=max(u32)
    ls_passes:=flags&ENCODE_BC1_TWO_LEAST_SQUARES_PASSES!=0?2:1

    if !needs_block_error {
        results.ep=pick_initial(src,flags,grayscale,&stats)
        orig=results.ep
        find_sels4_noerr(t.mode,src,results.ep,&results.sels)

        for _ in 0..<ls_passes {
            xl,xh,ok:=least_squares_sels4(src,&results.sels,stats.total)
            // Equal selectors act as a solid block, which is always equal or better.
            trial:=ok?precise_round_565(xh,xl):solid_endpoints4(t,stats.avg)
            if trial==results.ep {break}
            find_sels4_noerr(t.mode,src,trial,&results.sels)
            results.ep=trial
        }
    } else {
        total_rounds:=flags&ENCODE_BC1_TRY_ALL_INITIAL_ENDPOINTS!=0?2:1
        for round in 0..<total_rounds {
            modified_flags:=flags
            if round==1 {
                modified_flags&~=ENCODE_BC1_USE_2DLS|ENCODE_BC1_BOUNDING_BOX
                modified_flags|=ENCODE_BC1_BOUNDING_BOX
            }

            round_ep:=pick_initial(src,modified_flags,grayscale,&stats)
            orig_round:=round_ep

            round_sels:[16]u8=---
            round_err:=find_sels4(t.mode,flags,src,round_ep,&round_sels,max(u32))

            for _ in 0..<ls_passes {
                xl,xh,ok:=least_squares_sels4(src,&round_sels,stats.total)
                trial:=ok?precise_round_565(xh,xl):solid_endpoints4(t,stats.avg)
                if trial==round_ep {break}

                trial_sels:[16]u8=---
                trial_err:=find_sels4(t.mode,flags,src,trial,&trial_sels,round_err)
                if trial_err>=round_err {break}
                round_ep=trial
                round_err=trial_err
                round_sels=trial_sels
            }

            if round_err<=cur_err {
                cur_err=round_err
                results.ep=round_ep
                orig=orig_round
                results.sels=round_sels
            }
        }
    }

    if cur_err!=0 && flags&ENCODE_BC1_USE_LIKELY_TOTAL_ORDERINGS!=0 {
        total_iters:=flags&ENCODE_BC1_ITERATIVE!=0?2:1
        for _ in 0..<total_iters {
            orig_err:=cur_err

            h:[4]u8
            for i in 0..<16 {h[results.sels[i]]+=1}
            orig_index:=lookup_ordering4(t,h)

            sums:Ordering_Sums=---
            ordered_sums(src,results.ep,stats.total,&sums)

            exhaustive:=flags&ENCODE_BC1_EXHAUSTIVE!=0
            q_total:=exhaustive?NUM_UNIQUE_TOTAL_ORDERINGS4:clamp(total_orderings_to_try,MIN_TOTAL_ORDERINGS,MAX_TOTAL_ORDERINGS4)
            for q in 0..<q_total {
                s:=exhaustive?q:u32(BEST_TOTAL_ORDERINGS4[orig_index][q])
                trial:Endpoints
                if s==TOTAL_ORDER_4_0_16 || s==TOTAL_ORDER_4_1_16 || s==TOTAL_ORDER_4_2_16 || s==TOTAL_ORDER_4_3_16 {
                    trial=solid_endpoints4(t,stats.avg)
                } else {
                    xl,xh:=least_squares_ordering4(stats.total,t.selector_factors4[s],s,&sums)
                    trial=precise_round_565(xh,xl)
                }

                trial_sels:[16]u8=---
                trial_err:=find_sels4(t.mode,flags,src,trial,&trial_sels,cur_err)
                if trial_err<cur_err {
                    cur_err=trial_err
                    results.ep=trial
                    results.sels=trial_sels
                }
            }

            if cur_err==0 || cur_err==orig_err {break}
        }
    }

    if flags&(ENCODE_BC1_USE_3COLOR_BLOCKS|ENCODE_BC1_USE_3COLOR_BLOCKS_FOR_BLACK_PIXELS)!=0 && cur_err!=0 {
        if flags&ENCODE_BC1_USE_3COLOR_BLOCKS!=0 {
            try_3color_block(t,src,flags,&cur_err,&stats,orig,total_orderings_to_try3,&results)
        }
        if any_black && flags&ENCODE_BC1_USE_3COLOR_BLOCKS_FOR_BLACK_PIXELS!=0 {
            try_3color_block_useblack(t,src,flags,&cur_err,&results)
        }
    }

    if flags&ENCODE_BC1_ENDPOINT_SEARCH_ROUNDS_MASK!=0 && cur_err!=0 {
        endpoint_search(t,src,any_black,flags,&results,cur_err)
    }

    if results.three_color {
        encode3(dst,results.ep,&results.sels)
    } else {
        encode4(dst,results.ep,&results.sels)
    }
}
