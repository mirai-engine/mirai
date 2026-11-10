package build

import "core:fmt"
import "core:os"
import "core:slice"
import "core:testing"
import "mirai:asset"
import "mirai:cook/textures"
import "mirai:std/base"

@(test)
a_cook_takes_the_blocks_of_a_texture_from_the_cache_of_its_content :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    folder:=base.test_folder(t,"cook-texture-cache")
    if folder=="" {return}
    assets,cache:=fmt.tprintf("%s/assets",folder),fmt.tprintf("%s/cache",folder)
    os.make_directory_all(fmt.tprintf("%s/textures",assets))
    source:=fmt.tprintf("%s/textures/wood.tex",assets)
    pixels:[8*8*4]u8
    for &value,at in pixels {value=at%4==3?255:u8(at*5)}
    testing.expect_value(t,asset.texture_save(source,&types,{id={1,1},width=8,height=8,format=.RGBA8,mips={pixels[:]}}),asset.Error.None)
    manifest:=fmt.tprintf("%s/%s",folder,COOK_FILE)
    testing.expect(t,os.write_entire_file(manifest,`{"roots":["textures/wood.tex"]}`)==nil)
    level :: proc(t:^testing.T,types:^asset.Types,path:string) -> (format:asset.Texture_Format,blocks:[]u8) {
        a:asset.Asset
        if !testing.expect_value(t,asset.asset_load(&a,path,context.temp_allocator),asset.Error.None) {return}
        view,error:=asset.texture_view(&a,types)
        if !testing.expect_value(t,error,asset.Error.None) {return}
        return view.info.format,slice.clone(asset.texture_mip(view,0),context.temp_allocator)
    }

    // The first cook compresses the texture and keeps its blocks.
    report:=cook_assets({assets=assets,output=fmt.tprintf("%s/first",folder),manifest=manifest,texture_cache=cache,allocator=context.temp_allocator})
    testing.expect(t,report.error==.None && report.textures_compressed==1)
    testing.expect(t,report.seconds>0,"the report says how long the cook took")
    format,blocks:=level(t,&types,fmt.tprintf("%s/first/textures/wood.tex",folder))
    testing.expect(t,format==.BC1 && len(blocks)==32)
    original:asset.Asset
    testing.expect_value(t,asset.asset_load(&original,source,context.temp_allocator),asset.Error.None)
    key:=textures.cache_key_blocks(original.blob.header.content_hash)
    kept,found:=textures.cache_read(cache,key,&types,context.temp_allocator)
    testing.expect(t,found && kept.format==.BC1 && slice.equal(kept.mips[0],blocks))

    // The next cook reads them: blocks the cache was given are the ones it ships.
    kept.mips[0][0]~=0xff
    testing.expect(t,textures.cache_write(cache,key,&types,&kept))
    report=cook_assets({assets=assets,output=fmt.tprintf("%s/second",folder),manifest=manifest,texture_cache=cache,allocator=context.temp_allocator})
    testing.expect(t,report.error==.None && report.textures_compressed==1)
    _,cached:=level(t,&types,fmt.tprintf("%s/second/textures/wood.tex",folder))
    testing.expect(t,len(cached)==32 && cached[0]==blocks[0]~0xff && slice.equal(cached[1:],blocks[1:]))

    // A cook without a cache compresses, and another content is another key.
    report=cook_assets({assets=assets,output=fmt.tprintf("%s/third",folder),manifest=manifest,allocator=context.temp_allocator})
    _,fresh:=level(t,&types,fmt.tprintf("%s/third/textures/wood.tex",folder))
    testing.expect(t,report.error==.None && slice.equal(fresh,blocks))
    pixels[0]+=1
    testing.expect_value(t,asset.texture_save(source,&types,{id={1,1},width=8,height=8,format=.RGBA8,mips={pixels[:]}}),asset.Error.None)
    changed:asset.Asset
    testing.expect_value(t,asset.asset_load(&changed,source,context.temp_allocator),asset.Error.None)
    testing.expect(t,textures.cache_key_blocks(changed.blob.header.content_hash)!=key)
    free_all(context.temp_allocator)
}
