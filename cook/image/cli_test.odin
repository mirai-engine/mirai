package image

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:std/base"
import "mirai:std/subprocess"

// End to end: builds the mirai tool from this tree and runs `mirai image` on
// PNG files. It needs MIRAI_ROOT, which `mirai test` sets, and the Odin
// compiler it used.

@(private="file") EXE :: ".exe" when ODIN_OS==.Windows else ""

@(private="file")
Result :: struct {code:int,out,err:string}

@(private="file")
run :: proc(t:^testing.T,exe:string,args:..string) -> Result {
    command:=make([dynamic]string,context.temp_allocator)
    append(&command,exe,"image")
    append(&command,..args)
    state,stdout,stderr,error:=subprocess.exec({command=command[:]},context.temp_allocator)
    if error!=nil {
        testing.expectf(t,false,"could not run %s: %v",exe,error)
        return {code=-1}
    }
    return {state.exit_code,string(stdout),string(stderr)}
}

@(test)
mirai_image_reports_metrics_and_exit_codes :: proc(t:^testing.T) {
    root,has_root:=os.lookup_env("MIRAI_ROOT",context.temp_allocator)
    if !has_root {
        log.warn("MIRAI_ROOT is not set: the mirai image command was not run. Use `mirai test cook/image`.")
        return
    }
    compiler,has_compiler:=os.lookup_env("MIRAI_ODIN",context.temp_allocator)
    if !has_compiler || compiler=="" {compiler="odin"}
    folder:=base.test_folder(t,"image-cli")
    if folder=="" {return}
    exe:=fmt.tprintf("%s/bin/tests/mirai-image-cli%s",root,EXE)
    os.make_directory_all(fmt.tprintf("%s/bin/tests",root))
    {
        state,stdout,stderr,error:=subprocess.exec({command={compiler,"build",fmt.tprintf("%s/tools/mirai",root),fmt.tprintf("-collection:mirai=%s",root),"-ignore-unknown-attributes","-o:minimal",fmt.tprintf("-out:%s",exe)}},context.temp_allocator)
        if !testing.expectf(t,error==nil && state.exit_code==0,"the tool does not build: %v\n%s%s",error,string(stdout),string(stderr)) {return}
    }
    a,b,small:=fmt.tprintf("%s/a.png",folder),fmt.tprintf("%s/b.png",folder),fmt.tprintf("%s/small.png",folder)
    testing.expect_value(t,image_write(a,solid(16,16,100,100,100)),Error.None)
    testing.expect_value(t,image_write(b,solid(16,16,140,100,100)),Error.None)
    testing.expect_value(t,image_write(small,solid(8,16,100,100,100)),Error.None)

    same:=run(t,exe,"diff",a,a,"--metric","psnr","--threshold","30")
    testing.expectf(t,same.code==0 && strings.contains(same.out,"\"psnr\": null") && strings.contains(same.out,"\"ssim\": 1.000000") && strings.contains(same.out,"\"pass\": true"),"%d: %s%s",same.code,same.out,same.err)
    diff_map:=fmt.tprintf("%s/diff.png",folder)
    different:=run(t,exe,"diff",a,b,"--metric","mae","--threshold","1","--out",diff_map)
    testing.expectf(t,different.code==1 && strings.contains(different.out,"\"pass\": false") && strings.contains(different.out,"\"over_threshold_percent\": 100"),"%d: %s%s",different.code,different.out,different.err)
    map_image,map_error:=image_load(diff_map,context.temp_allocator)
    testing.expect_value(t,map_error,Error.None)
    testing.expect_value(t,map_image.pixels[0],u8(255))
    testing.expect_value(t,run(t,exe,"diff",a,b,"--metric","ssim","--threshold","0.1").code,0)
    testing.expect_value(t,run(t,exe,"diff",a,b).code,0)

    mismatch:=run(t,exe,"diff",a,small)
    testing.expect(t,mismatch.code==2 && strings.contains(mismatch.err,"16x16") && strings.contains(mismatch.err,"8x16"),mismatch.err)
    missing:=run(t,exe,"diff",a,fmt.tprintf("%s/missing.png",folder))
    testing.expect(t,missing.code==2 && strings.contains(missing.err,"missing.png"),missing.err)
    testing.expect_value(t,run(t,exe,"diff",a,b,"--region","0,0,99,99").code,2)
    testing.expect_value(t,run(t,exe,"diff",a,b,"--region","1,2,3").code,2)
    testing.expect_value(t,run(t,exe,"diff",a,b,"--metric","lpips").code,2)
    testing.expect_value(t,run(t,exe,"diff",a).code,2)

    stats:=run(t,exe,"stats",a,"--region","0,0,4,4")
    testing.expectf(t,stats.code==0 && strings.contains(stats.out,"\"pixels\": 16") && strings.contains(stats.out,"\"saturated_percent\": 0.000000"),"%d: %s%s",stats.code,stats.out,stats.err)
    testing.expect_value(t,run(t,exe,"stats").code,2)
    sequence:=run(t,exe,"stats",a,b,a)
    testing.expectf(t,sequence.code==0 && strings.count(sequence.out,"\"file\"")==3 && strings.contains(sequence.out,"\"delta_luma\": null") && !strings.contains(sequence.out,"\"stddev\": 0.000000") && strings.contains(sequence.out,"\"max_delta_file\""),"%d: %s%s",sequence.code,sequence.out,sequence.err)
    still:=run(t,exe,"stats",a,a,"--region","0,0,4,4")
    testing.expectf(t,still.code==0 && strings.contains(still.out,"\"max_delta\": 0.000000") && strings.contains(still.out,"\"stddev\": 0.000000"),"%d: %s%s",still.code,still.out,still.err)
    unreadable:=run(t,exe,"stats",a,fmt.tprintf("%s/missing.png",folder))
    testing.expect(t,unreadable.code==2 && strings.contains(unreadable.err,"missing.png"),unreadable.err)

    montage:=fmt.tprintf("%s/montage.png",folder)
    made:=run(t,exe,"montage",a,small,"--out",montage)
    testing.expectf(t,made.code==0,"%d: %s%s",made.code,made.out,made.err)
    loaded,load_error:=image_load(montage,context.temp_allocator)
    testing.expect_value(t,load_error,Error.None)
    testing.expect_value(t,loaded.width,24)
    testing.expect_value(t,loaded.height,16)
    testing.expect_value(t,run(t,exe,"montage",a,"--out",montage).code,2)
    testing.expect_value(t,run(t,exe,"montage",a,small).code,2)

    spot:=solid(16,16,100,100,100)
    spot.pixels[(5*16+3)*4],spot.pixels[(5*16+3)*4+1],spot.pixels[(5*16+3)*4+2]=255,0,0
    spotted:=fmt.tprintf("%s/spot.png",folder)
    testing.expect_value(t,image_write(spotted,spot),Error.None)
    cut:=fmt.tprintf("%s/cut.png",folder)
    cropped:=run(t,exe,"crop",spotted,"2","4","3","2","--out",cut)
    testing.expectf(t,cropped.code==0 && strings.contains(cropped.out,"\"width\": 3,\n  \"height\": 2"),"%d: %s%s",cropped.code,cropped.out,cropped.err)
    cut_image,cut_error:=image_load(cut,context.temp_allocator)
    testing.expect_value(t,cut_error,Error.None)
    testing.expect_value(t,[3]u8{cut_image.pixels[(1*3+1)*4],cut_image.pixels[(1*3+1)*4+1],cut_image.pixels[0]},[3]u8{255,0,100})
    near:=fmt.tprintf("%s/near.png",folder)
    zoomed:=run(t,exe,"zoom",spotted,"3,5,1,1","--factor","4","--out",near)
    testing.expectf(t,zoomed.code==0 && strings.contains(zoomed.out,"\"factor\": 4"),"%d: %s%s",zoomed.code,zoomed.out,zoomed.err)
    near_image,near_error:=image_load(near,context.temp_allocator)
    testing.expect_value(t,near_error,Error.None)
    testing.expect_value(t,[3]int{near_image.width,near_image.height,int(near_image.pixels[(3*4+3)*4])},[3]int{4,4,255})
    picked:=run(t,exe,"pick",spotted,"3","5","0","0")
    testing.expectf(t,picked.code==0 && strings.contains(picked.out,"{\"x\": 3, \"y\": 5, \"r\": 255, \"g\": 0, \"b\": 0, \"a\": 255, \"luma\": 0.212600}") && strings.contains(picked.out,"\"r\": 100"),"%d: %s%s",picked.code,picked.out,picked.err)
    outside:=run(t,exe,"pick",spotted,"16","0")
    testing.expect(t,outside.code==2 && strings.contains(outside.err,"16x16"),outside.err)
    testing.expect_value(t,run(t,exe,"crop",spotted,"14","14","4","4","--out",cut).code,2)
    testing.expect_value(t,run(t,exe,"crop",spotted,"0","0","4","--out",cut).code,2)
    testing.expect_value(t,run(t,exe,"crop",spotted,"0","0","4","4").code,2)
    testing.expect_value(t,run(t,exe,"zoom",spotted,"0","0","4","4","--factor","0","--out",near).code,2)
    testing.expect_value(t,run(t,exe,"pick",spotted,"3").code,2)
}
