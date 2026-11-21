package textures

import "base:runtime"
import "core:log"
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
    options:=Build_Options{srgb=true,encoding=.Uncompressed}
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
    _,no_room:=cache_read(c,key,&types,runtime.nil_allocator())
    testing.expect(t,!no_room,"a cached texture without room for its mips is a miss")
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


// One texel changed in the image of a texture changes a bounded run of the
// chunks of its object: the levels keep their cuts, so the rest are the same.
@(test)
a_texel_changed_changes_few_chunks_of_the_object :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    folder:=base.test_folder(t,"textures-one-texel")
    if folder=="" {return}
    s,opened:=store.open(folder,context.temp_allocator)
    if !testing.expect_value(t,opened,store.Error.None) {return}
    defer store.close(&s)
    SIDE :: 1024
    pixels:=make([]u8,SIDE*SIDE*4,context.temp_allocator)
    state:=u64(11)
    for &value in pixels {
        state=state*6364136223846793005+1442695040888963407
        value=u8(state>>56)
    }
    object_of :: proc(t:^testing.T,s:^store.Store,types:^asset.Types,pixels:[]u8) -> store.Hash {
        built,error:=build(rgba8(pixels,SIDE,SIDE),{srgb=true,encoding=.Uncompressed},context.temp_allocator)
        if !testing.expect_value(t,error,Error.None) {return {}}
        doc:asset.Document
        if !testing.expect_value(t,asset.texture_document(&doc,types,built_desc(&built,{9,9},nil),context.temp_allocator),asset.Error.None) {return {}}
        defer asset.document_destroy(&doc)
        bytes,_:=asset.document_bytes(&doc,context.temp_allocator)
        object,put_error:=asset.object_put(s,bytes)
        testing.expect_value(t,put_error,asset.Error.None)
        return object
    }
    leaves_of :: proc(s:^store.Store,root:store.Hash) -> map[store.Hash]bool {
        out:=make(map[store.Hash]bool,context.temp_allocator)
        walk :: proc(s:^store.Store,address:store.Hash,out:^map[store.Hash]bool) {
            buffer:=make([]u8,store.CHUNK_MAX,context.temp_allocator)
            bytes,_:=store.chunk_read(s,address,buffer)
            n,error:=store.node_parse(bytes)
            if error!=.None {return}
            for e in n.entries {
                if n.level>0 {walk(s,e.address,out)} else {out[e.address]=true}
            }
        }
        walk(s,root,&out)
        return out
    }
    before:=object_of(t,&s,&types,pixels)
    pixels[(SIDE/3*SIDE+SIDE/2)*4]~=0x40
    after:=object_of(t,&s,&types,pixels)
    store.commit(&s)
    testing.expect(t,before!=after)
    old,new:=leaves_of(&s,before),leaves_of(&s,after)
    changed:=0
    for address in new {
        if !(address in old) {changed+=1}
    }
    log.infof("one texel changed %d of %d chunks",changed,len(new))
    testing.expectf(t,changed>0 && changed<=len(new)/2+1,"%d of %d chunks changed",changed,len(new))
}
