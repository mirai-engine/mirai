package textures

import "core:hash/xxhash"
import "core:os"
import "core:slice"
import "mirai:asset"
import "mirai:cook/cache"
import "mirai:std/base"

// Built textures kept by what they are made from (cook/cache): an import that
// builds the same image with the same settings, and a cook that compresses
// the same RGBA8 texture, read the levels instead of making them again. Its
// files are textures built by BUILD_VERSION.

CACHE_BUDGET :: 1<<30 // bytes of the folder

// An image built with options: its bytes, encoded, or the texels of made
// (whose width is 0 for encoded bytes).
cache_key_build :: proc(bytes:[]u8,made:Source,options:Build_Options) -> u64 {
    key:=base.hash_combine(xxhash.XXH3_64_default(bytes),u64(u32(made.width))<<32|u64(u32(made.height)))
    key=base.hash_combine(key,u64(u32(made.layers))|u64(made.format)<<32|u64(made.cube)<<40)
    return base.hash_combine(key,settings_hash(options))|1
}

// The blocks of a texture that stores RGBA8, by the content hash of its file.
cache_key_blocks :: proc(content_hash:u64,external:^External=nil) -> u64 {
    return base.hash_combine(base.hash_combine(base.hash_combine(content_hash,u64(BUILD_VERSION)),0x626c6f636b73),external_id(external))|1
}

// Whether the cache keeps a texture under key, without reading it.
cache_has :: proc(folder:string,key:u64) -> bool {
    return folder!="" && os.exists(cache.file_path(folder,key,".tex"))
}

// The texture the cache keeps under key, its levels in allocator. False
// without one, or with one that does not read back whole.
cache_read :: proc(folder:string,key:u64,types:^asset.Types,allocator:=context.allocator) -> (built:Built,ok:bool) {
    file:asset.Asset
    if !cache.load(folder,key,BUILD_VERSION,".tex",&file,context.temp_allocator) {return}
    defer asset.asset_close(&file)
    view,error:=asset.texture_view(&file,types)
    if error!=.None {return}
    info:=view.info
    built={width=int(info.width),height=int(info.height),layers=int(info.layers),format=info.format,flags=info.flags,alpha_coverage=info.alpha_coverage,allocator=allocator}
    built.mips=make([][]u8,len(view.mips),allocator)
    for _,level in view.mips {built.mips[level]=slice.clone(asset.texture_mip(view,level),allocator)}
    return built,true
}

// Keeps built under key; false when it cannot be written, which costs only
// the time of building it the next time.
cache_write :: proc(folder:string,key:u64,types:^asset.Types,built:^Built,budget:=i64(CACHE_BUDGET)) -> bool {
    if !cache.ready(folder) {return false}
    if asset.texture_save(cache.file_path(folder,key,".tex"),types,built_desc(built,cache.id(key,BUILD_VERSION),nil))!=.None {return false}
    cache.trim(folder,budget)
    return true
}
