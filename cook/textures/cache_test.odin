package textures

import "core:slice"
import "core:testing"
import "mirai:asset"
import "mirai:cook/cache"
import "mirai:std/base"
import "mirai:store"

@(test)
built_textures_are_kept_by_image_and_settings_and_read_back_whole :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    folder:=base.test_folder(t,"textures-cache")
    if folder=="" {return}
    kept,opened:=store.open(folder,context.temp_allocator)
    if !testing.expect_value(t,opened,store.Error.None) {return}
    c:=cache.Cache{store=&kept}
    pixels:=make([]u8,16*16*4,context.temp_allocator)
    for &value,at in pixels {value=at%4==3?255:u8(at*7)}
    options:=Build_Options{srgb=true}
    key:=cache_key_build(pixels,rgba8(pixels,16,16),options)
    testing.expect(t,key!=cache_key_build(pixels,rgba8(pixels,16,16),{}),"other settings are another texture")
    testing.expect(t,key!=cache_key_build(pixels,rgba8(pixels,8,32),options),"another size of the same bytes too")
    other:=slice.clone(pixels,context.temp_allocator)
    other[5]+=1
    testing.expect(t,key!=cache_key_build(other,rgba8(other,16,16),options),"and other bytes")
    testing.expect(t,cache_key_blocks(1)!=cache_key_blocks(2))

    _,missing:=cache_read(c,key,&types,context.temp_allocator)
    testing.expect(t,!missing,"an empty cache has nothing")
    built,error:=build(rgba8(pixels,16,16),options,context.temp_allocator)
    testing.expect_value(t,error,Error.None)
    testing.expect(t,cache_write(c,key,&types,&built))
    read,found:=cache_read(c,key,&types,context.temp_allocator)
    testing.expect(t,found && read.width==built.width && read.height==built.height && read.format==built.format && read.flags==built.flags && len(read.mips)==len(built.mips))
    for level,at in built.mips {
        side:=max(16>>uint(at),1)
        testing.expect(t,same_level(built.format,read.mips[at],level,side,side))
    }
    _,other_key:=cache_read(c,key+2,&types,context.temp_allocator)
    testing.expect(t,!other_key)
    _,no_store:=cache_read({},key,&types,context.temp_allocator)
    testing.expect(t,!no_store && !cache_write({},key,&types,&built))
    testing.expect(t,cache_has(c,key) && !cache_has(c,key+2) && !cache_has({},key))
}

