package textures

import "core:fmt"
import "core:os"
import "core:slice"
import "core:testing"
import "core:time"
import "mirai:asset"
import "mirai:cook/cache"
import "mirai:std/base"
import "mirai:std/serial"

@(test)
built_textures_are_kept_by_image_and_settings_and_read_back_whole :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    folder:=base.test_folder(t,"textures-cache")
    if folder=="" {return}
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

    _,missing:=cache_read(folder,key,&types,context.temp_allocator)
    testing.expect(t,!missing,"an empty cache has nothing")
    built,error:=build(rgba8(pixels,16,16),options,context.temp_allocator)
    testing.expect_value(t,error,Error.None)
    testing.expect(t,cache_write(folder,key,&types,&built))
    read,found:=cache_read(folder,key,&types,context.temp_allocator)
    testing.expect(t,found && read.width==built.width && read.height==built.height && read.format==built.format && read.flags==built.flags && len(read.mips)==len(built.mips))
    for level,at in built.mips {
        side:=max(16>>uint(at),1)
        testing.expect(t,same_level(built.format,read.mips[at],level,side,side))
    }
    _,other_key:=cache_read(folder,key+2,&types,context.temp_allocator)
    testing.expect(t,!other_key)
    _,no_folder:=cache_read("",key,&types,context.temp_allocator)
    testing.expect(t,!no_folder && !cache_write("",key,&types,&built))

    // A file no build used for UNUSED_AGE goes, however small the folder; a read is a use.
    trimmed:=base.test_folder(t,"textures-trim")
    if trimmed=="" {return}
    keys:[2]u64
    long_ago:=time.time_add(time.now(),-cache.UNUSED_AGE-time.Hour)
    for &key_of,at in keys {
        other[0]=u8(at)
        key_of=cache_key_build(other,rgba8(other,16,16),options)
        level_built,_:=build(rgba8(other,16,16),options,context.temp_allocator)
        testing.expect(t,cache_write(trimmed,key_of,&types,&level_built))
        testing.expect(t,os.change_times(fmt.tprintf("%s/%016x.tex",trimmed,key_of),long_ago,long_ago)==nil)
    }
    _,first_read:=cache_read(trimmed,keys[0],&types,context.temp_allocator)
    testing.expect(t,first_read)
    testing.expect_value(t,cache.trim(trimmed),1)
    _,kept_first:=cache_read(trimmed,keys[0],&types,context.temp_allocator)
    _,kept_second:=cache_read(trimmed,keys[1],&types,context.temp_allocator)
    testing.expect(t,kept_first && !kept_second,"the one read lately stays and the one unused for long goes")

    // A file of the cache that does not read back whole is no texture.
    path:=fmt.tprintf("%s/%016x.tex",folder,key)
    whole,_:=serial.file_read(path,context.temp_allocator)
    damaged:=slice.clone(whole,context.temp_allocator)
    damaged[len(damaged)-1]~=0xff
    for bytes in ([][]u8{whole[:len(whole)/2],damaged}) {
        testing.expect_value(t,serial.file_write_atomic(path,bytes),serial.File_Error.None)
        _,read_back:=cache_read(folder,key,&types,context.temp_allocator)
        testing.expect(t,!read_back)
    }
}
