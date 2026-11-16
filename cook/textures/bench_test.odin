package textures

import "core:fmt"
import "core:testing"
import "core:time"

BENCH :: #config(COOK_BENCH,false)
BENCH_ROUNDS :: 5

@(test)
bench_mip_chains :: proc(t:^testing.T) {
    if !BENCH {return}
    SIZE :: 2048
    pixels:=make([]u8,SIZE*SIZE*4);defer delete(pixels)
    for i in 0..<SIZE*SIZE {
        pixels[i*4]=u8(i*7);pixels[i*4+1]=u8(i*13>>3);pixels[i*4+2]=u8(i>>5);pixels[i*4+3]=u8(i*3>>2)
    }
    cases:=[?]struct{name:string,options:Build_Options}{
        {"linear RGBA8",{encoding=.Uncompressed}},{"srgb RGBA8",{srgb=true,encoding=.Uncompressed}},{"normal map RGBA8",{normal_map=true,encoding=.Uncompressed}},{"masked srgb RGBA8",{srgb=true,alpha_coverage=0.5,encoding=.Uncompressed}},
        {"data BC3",{}},{"normal map BC5",{normal_map=true}},
    }
    for entry in cases {
        best:=time.Duration(max(i64))
        for _ in 0..<BENCH_ROUNDS {
            start:=time.tick_now()
            built,error:=build(rgba8(pixels,SIZE,SIZE),entry.options)
            assert(error==.None)
            built_destroy(&built)
            best=min(best,time.tick_since(start))
        }
        fmt.printfln("%dx%d %s: %v (%.1f Mtexel/s of the first level)",SIZE,SIZE,entry.name,best,f64(SIZE*SIZE)/1e6/time.duration_seconds(best))
    }
}

