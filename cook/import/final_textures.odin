package importer

import "core:mem"
import "mirai:asset"
import "mirai:cook/cache"
import "mirai:cook/textures"
import "mirai:std/base"
import "mirai:std/jobs"
import "mirai:store"

@(private)
TEXTURE_FINAL :: "final"
@(private)
TEXTURE_INPUT_CACHE :: "texture-inputs"
@(private)
TEXTURE_INPUT_VERSION :: u64(textures.BUILD_VERSION)<<32|1
@(private)
TEXTURE_INPUT_KIND :: asset.Fourcc(0x504e4954) // TINP

@(private)
Texture_Final :: struct {key,settings:u64}

@(private)
Texture_Input :: struct {
    width,height,layers:int,
    format:textures.Source_Format,
    cube:bool,
    options:textures.Build_Options,
}

@(private)
texture_input_has :: proc(c:cache.Cache,key:u64) -> bool {
    return cache.has({store=c.store},TEXTURE_INPUT_CACHE,key,TEXTURE_INPUT_VERSION)
}

@(private)
texture_input_keep :: proc(c:cache.Cache,key:u64,types:^asset.Types,source:textures.Source,
                           options:textures.Build_Options) {
    if c.store==nil {return}
    recipe:=Texture_Input{source.width,source.height,source.layers,source.format,source.cube,options}
    doc:asset.Document
    asset.document_init(&doc,TEXTURE_INPUT_KIND,cache.id(key,TEXTURE_INPUT_VERSION))
    defer asset.document_destroy(&doc)
    if _,error:=asset.document_put_row(&doc,types,"input",&recipe);error!=.None {return}
    texels:=source.texels[:textures.source_bytes(source)]
    if _,error:=asset.document_put(&doc,types,"texels",texels,{.Bulk});error!=.None {return}
    bytes,error:=asset.document_bytes(&doc)
    if error!=.None {return}
    defer delete(bytes)
    _=cache.put(c,TEXTURE_INPUT_CACHE,key,TEXTURE_INPUT_VERSION,bytes)
}

@(private="file")
texture_input_build :: proc(c:cache.Cache,final:Texture_Final,types:^asset.Types,
                            worker:jobs.Worker_Ref) -> (built:textures.Built,ok:bool) {
    if built,ok=textures.cache_read(c,final.key,types,context.temp_allocator);ok {return}
    file:asset.Asset
    if !cache.load(c,TEXTURE_INPUT_CACHE,final.key,TEXTURE_INPUT_VERSION,&file,context.temp_allocator) {return}
    defer asset.asset_close(&file)
    if file.blob.header.kind!=TEXTURE_INPUT_KIND {return}
    recipe,error:=asset.asset_row(&file,types,"input",Texture_Input,whole=true)
    if error!=.None || recipe.options.speed!=.Final ||
       textures.settings_hash(recipe.options)!=final.settings {return}

    texels,texel_error:=asset.asset_rows(&file,types,"texels","",u8)
    if texel_error!=.None {return}
    source:=textures.Source{
        texels=texels,width=recipe.width,height=recipe.height,layers=recipe.layers,
        format=recipe.format,cube=recipe.cube,
    }
    build_error:textures.Error
    built,build_error=textures.build(source,recipe.options,context.temp_allocator,worker)
    if build_error!=.None {return}
    _=textures.cache_write(c,final.key,types,&built)
    return built,true
}

// Updates build after publishing Final. A missing cache input leaves the
// build untouched so the caller can import from the source.
finalize_build :: proc(s:^store.Store,build:^asset.Build,worker:jobs.Worker_Ref) ->
    (object:store.Hash,error:asset.Error) {
    final:=build^
    final.final=true
    final.outputs=make([dynamic]asset.Build_Output,0,len(build.outputs),context.temp_allocator)
    scratch:mem.Dynamic_Arena
    mem.dynamic_arena_init(&scratch,context.allocator,context.allocator,block_size=1<<20,out_band_size=1<<20)
    defer mem.dynamic_arena_destroy(&scratch)
    context.temp_allocator=base.dynamic_arena_allocator(&scratch)
    for output in build.outputs {
        output:=output
        if output.kind==asset.KIND_TEXTURE {
            output.object=texture_finalize(s,output,worker) or_return
            free_all(context.temp_allocator)
        }
        if _,no_room:=append(&final.outputs,output);no_room!=nil {return {},.Out_Of_Memory}
    }
    object=asset.build_put(s,&final) or_return
    digits:[64]u8
    if store.ref_set(s,asset.REF_IMPORTS,store.hex(final.key,&digits),object)!=.None {
        return {},.IO
    }
    build^=final
    return object,.None
}

@(private="file")
texture_finalize :: proc(s:^store.Store,output:asset.Build_Output,worker:jobs.Worker_Ref) ->
    (object:store.Hash,error:asset.Error) {
    types:asset.Types
    asset.types_init(&types,context.temp_allocator)
    defer asset.types_destroy(&types)
    file:asset.Asset
    asset.asset_open_object(&file,s,output.object,context.temp_allocator) or_return
    defer asset.asset_close(&file)
    view:=asset.texture_open(&file,&types) or_return
    if file.blob.header.id!=output.id {return {},.Corrupt}
    if .Fast not_in view.info.flags {return output.object,.None}

    final,recipe_error:=asset.asset_row(&file,&types,TEXTURE_FINAL,Texture_Final,whole=true)
    if recipe_error!=.None || view.source==nil || final.key==0 {return {},.Not_Found}
    built,ok:=texture_input_build({store=s},final^,&types,worker)
    if !ok || .Fast in built.flags || built.format!=view.info.format ||
       built.width!=int(view.info.width) || built.height!=int(view.info.height) ||
       built.layers!=int(view.info.layers) {return {},.Not_Found}
    info:=view.source^
    info.settings_hash=final.settings
    desc:=textures.built_desc(&built,output.id,&info)
    desc.owner=file.blob.header.owner
    doc:asset.Document
    asset.texture_document(&doc,&types,desc,context.temp_allocator) or_return
    defer asset.document_destroy(&doc)
    bytes:=asset.document_bytes(&doc,context.temp_allocator) or_return
    return asset.object_put(s,bytes)
}
