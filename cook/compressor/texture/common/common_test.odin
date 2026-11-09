package common

import "core:math/rand"
import "core:testing"

@(private="file")
less_i32 :: proc(a,b:i32) -> bool {return a<b}

@(test)
stdsort_and_heaps_order_any_input :: proc(t:^testing.T) {
    r:=rand.create(7)
    gen:=rand.default_random_generator(&r)
    for n in ([]int{0,1,2,3,4,5,17,100,1000,5000}) {
        a:=make([]i32,n)
        defer delete(a)
        for mode in 0..<3 {
            for i in 0..<n {
                switch mode {
                case 0: a[i]=i32(rand.int_max(1000,gen))
                case 1: a[i]=i32(rand.int_max(3,gen))
                case 2: a[i]=i32(n-i)
                }
            }
            stdsort(a,less_i32)
            for i in 1..<max(n,1) {testing.expect(t,a[i-1]<=a[i])}
            heap_make(a,less_i32)
            for k:=n;k>1;k-=1 {heap_pop(a[:k],less_i32)}
            for i in 1..<max(n,1) {testing.expect(t,a[i-1]<=a[i])}
        }
    }
    v:=[]i32{1,3,3,5,9}
    testing.expect_value(t,lower_bound(v,i32(4),less_i32),3)
}

@(test)
bc1_palette_and_indices_round_trip :: proc(t:^testing.T) {
    r:=rand.create(3)
    gen:=rand.default_random_generator(&r)
    for _ in 0..<2000 {
        b:=BC1_Block{endpoints=rand.uint32(gen),indices=rand.uint32(gen)}
        for mode in BC1_Palette_Mode {
            colors:Color_Block
            bc1_decompress(&colors,b,mode)
            err:u32
            palette:[4]Color
            bc1_palette(b.endpoints,&palette,mode)
            indices:=bc1_find_indices_palette(&colors,&palette,&err)
            testing.expect_value(t,err,0)
            testing.expect_value(t,bc1_palette_ssd_rgba(&colors,&palette,indices),0)
        }
    }
}

@(test)
helpers_take_hostile_input :: proc(t:^testing.T) {
    testing.expect_value(t,round_to_int(f32(0h7fc00000)),min(i32))
    testing.expect_value(t,round_to_int(2.5),2)
    testing.expect_value(t,round_to_int(-1.5),-2)
    deltas:[16][8]i32
    out:i32
    // every delta free: an exhausted texel must not loop forever
    testing.expect_value(t,compute_sad_bound_for_ssd_threshold(&deltas,0,1000,&out),16*7)
    for i in 0..<16 {for k in 0..<8 {deltas[i][k]=max(i32)}}
    testing.expect_value(t,compute_sad_bound_for_ssd_threshold(&deltas,0,1000,&out),16*7)
    testing.expect_value(t,out,1000)
    entries:=[]BC1_VQ_Entry{{palette={{0,0,0,255},{9,9,9,255},{},{}}}}
    inds:=[]i32{0,5,-1}
    dest:[3]i32
    bbox:=[2]Color{{0,0,0,255},{255,255,255,255}}
    testing.expect_value(t,filter_endpoint_color_bbox(dest[:],entries,inds,&bbox,10,false),1)
    colors:Color_Block
    vqds:[6]f32
    act:Float_Block
    p:[4]Color
    batch_compute_vqds(vqds[:],entries,inds,&colors,&p,&p,&act)
    testing.expect_value(t,vqds[2],max(f32))
}

@(test)
activity_is_finite_and_rejects_bad_surfaces :: proc(t:^testing.T) {
    for size in ([][2]int{{1,1},{3,7},{40,9}}) {
        w,h:=size[0],size[1]
        pixels:=make([]u8,w*h*4)
        defer delete(pixels)
        r:=rand.create(u64(w*h))
        gen:=rand.default_random_generator(&r)
        for i in 0..<len(pixels) {pixels[i]=u8(rand.uint32(gen))}
        act:=make([]u8,w*h*4)
        defer delete(act)
        src:=Surface{pixels=pixels,width=w,height=h,stride=w*4,format=.RGBA8}
        dst:=Surface{pixels=act,width=w,height=h,stride=w*4,format=.R32F}
        for mode in Activity_Mode {
            for dc in ([]int{1,2,4}) {
                testing.expect_value(t,make_activity_mask(dst,src,mode,{},dc),Error.None)
                f:=([^]f32)(raw_data(act))[:w*h]
                for v in f {testing.expect(t,v>=1 && v<=256)}
            }
        }
        testing.expect_value(t,make_activity_mask_hdr(dst,{pixels=pixels,width=w,height=h,
            stride=w*4,format=.R32F},{}),Error.None)
    }
    bad:=Surface{pixels=nil,width=4,height=4,stride=16,format=.R32F}
    testing.expect_value(t,make_activity_mask(bad,bad,.RGB_1F,{}),Error.Invalid)
}
