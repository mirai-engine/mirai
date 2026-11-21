package textures

import "core:mem"
import "core:slice"
import "mirai:asset"
import "mirai:cook/cache"
import "mirai:std/base"

// Built textures kept by what they are made from in the cache CACHE
// (cook/cache): an import that builds the same image with the same settings,
// and a cook that compresses the same RGBA8 texture, read the levels instead
// of making them again. Its files are textures built by BUILD_VERSION.

CACHE :: "textures"

// An image built with options: its bytes, encoded, or the texels of made
// (whose width is 0 for encoded bytes).
cache_key_build :: proc(bytes:[]u8,made:Source,options:Build_Options) -> u64 {
    key:=base.hash_combine(base.hash64(bytes),u64(u32(made.width))<<32|u64(u32(made.height)))
    key=base.hash_combine(key,u64(u32(made.layers))|u64(made.format)<<32|u64(made.cube)<<40)
    return base.hash_combine(key,settings_hash(options))|1
}

// The blocks of a texture that stores RGBA8, by the content hash of its file.
cache_key_blocks :: proc(content_hash:u64,rdo:=true) -> u64 {
    return base.hash_combine(base.hash_combine(base.hash_combine(content_hash,u64(BUILD_VERSION)),0x626c6f636b73|u64(!rdo)<<48),encoders_id())|1
}

// Whether the cache keeps a texture under key, without reading it.
cache_has :: proc(c:cache.Cache,key:u64) -> bool {
    return cache.has(c,CACHE,key,BUILD_VERSION)
}

// Which of keys the cache keeps, into here, asking its source once for those it lacks.
cache_lookup :: proc(c:cache.Cache,keys:[]u64,here:[]bool) {
    cache.lookup(c,CACHE,keys,BUILD_VERSION,here)
}

// The texture the cache keeps under key, its levels in allocator. False
// without one, or with one that does not read back whole.
cache_read :: proc(c:cache.Cache,key:u64,types:^asset.Types,allocator:=context.allocator) -> (built:Built,ok:bool) {
    file:asset.Asset
    if !cache.load(c,CACHE,key,BUILD_VERSION,&file,context.temp_allocator) {return}
    defer asset.asset_close(&file)
    view,error:=asset.texture_view(&file,types)
    if error!=.None {return}
    info:=view.info
    built={width=int(info.width),height=int(info.height),layers=int(info.layers),
        format=info.format,flags=info.flags-{.Fields},alpha_coverage=info.alpha_coverage,
        allocator=allocator}
    allocation:mem.Allocator_Error
    if built.mips,allocation=make([][]u8,len(view.mips),allocator);allocation!=nil {return {},false}
    for _,level in view.mips {
        if built.mips[level],allocation=slice.clone(asset.texture_mip(view,level),allocator);allocation!=nil {
            built_destroy(&built)
            return {},false
        }
    }
    return built,true
}

// Keeps built under key; false when it cannot be kept, which costs only the
// time of building it the next time.
cache_write :: proc(c:cache.Cache,key:u64,types:^asset.Types,built:^Built) -> bool {
    if c.store==nil {return false}
    doc:asset.Document
    if asset.texture_document(&doc,types,built_desc(built,cache.id(key,BUILD_VERSION),nil))!=.None {return false}
    defer asset.document_destroy(&doc)
    bytes,error:=asset.document_bytes(&doc)
    if error!=.None {return false}
    defer mem.free_bytes(bytes)
    return cache.put(c,CACHE,key,BUILD_VERSION,bytes)
}
