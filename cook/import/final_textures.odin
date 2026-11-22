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
                           options:textures.Build_Options,worker:jobs.Worker_Ref) {
    if c.store==nil {return}
    jobs.worker_zone(worker,"texture.input")
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
                            worker:jobs.Worker_Ref,gpu:^textures.Gpu_Context) ->
    (built:textures.Built,error:asset.Error) {
    cached:bool
    if built,cached=textures.cache_read(c,final.key,types,context.temp_allocator);cached {return}
    file:asset.Asset
    if !cache.load(c,TEXTURE_INPUT_CACHE,final.key,TEXTURE_INPUT_VERSION,&file,context.temp_allocator) {
        return {},.Not_Found
    }
    defer asset.asset_close(&file)
    if file.blob.header.kind!=TEXTURE_INPUT_KIND {return {},.Corrupt}
    recipe:=asset.asset_row(&file,types,"input",Texture_Input,whole=true) or_return
    if recipe.options.speed!=.Final || textures.settings_hash(recipe.options)!=final.settings {
        return {},.Corrupt
    }

    texels:=asset.asset_rows(&file,types,"texels","",u8) or_return
    source:=textures.Source{
        texels=texels,width=recipe.width,height=recipe.height,layers=recipe.layers,
        format=recipe.format,cube=recipe.cube,
    }
    build_error:textures.Error
    built,build_error=textures.build(source,recipe.options,context.temp_allocator,worker,gpu)
    switch build_error {
    case .None:
    case .Out_Of_Memory: return {},.Out_Of_Memory
    case .Too_Large: return {},.Too_Large
    case .Invalid,.Unsupported: return {},.Corrupt
    case .Gpu: return {},.IO
    }
    _=textures.cache_write(c,final.key,types,&built)
    return built,.None
}

@(private="file")
Finalize_Item :: struct {
    output:^asset.Build_Output,
    error:asset.Error,
}

// Updates build after publishing Final. A missing cache input leaves the
// build untouched so the caller can import from the source.
finalize_build :: proc(
    s:^store.Store,build:^asset.Build,worker:jobs.Worker_Ref,gpu:^textures.Gpu_Context=nil,
) ->
    (object:store.Hash,error:asset.Error) {
    if s==nil || build==nil {return {},.Invalid}
    own:textures.Gpu_Context
    defer textures.gpu_context_destroy(&own)
    gpu:=gpu if gpu!=nil else &own
    final:=build^
    final.final=true
    allocation:mem.Allocator_Error
    final.outputs,allocation=make([dynamic]asset.Build_Output,len(build.outputs),context.temp_allocator)
    if allocation!=nil {return {},.Out_Of_Memory}
    defer if error!=.None {delete(final.outputs)}
    copy(final.outputs[:],build.outputs[:])

    scratch:mem.Dynamic_Arena
    mem.dynamic_arena_init(&scratch,context.allocator,context.allocator,
        block_size=1<<20,out_band_size=1<<20)
    defer mem.dynamic_arena_destroy(&scratch)
    context.temp_allocator=base.dynamic_arena_allocator(&scratch)
    width:=1 if worker.system==nil else jobs.worker_count(worker.system)
    items,items_error:=make([]Finalize_Item,min(width,len(final.outputs)),context.temp_allocator)
    if items_error!=nil {return {},.Out_Of_Memory}
    Work :: struct {s:^store.Store,worker:jobs.Worker_Ref,items:[]Finalize_Item,gpu:^textures.Gpu_Context}
    work:=Work{s,worker,items,gpu}
    run :: proc(work:^Work,first,last,worker:int) {
        on:=jobs.worker_ref_at(work.worker,worker)
        if on.system!=nil {context.allocator=on.system.allocator}
        for &item in work.items[first:last] {
            object,error:=texture_finalize(work.s,item.output,on,work.gpu)
            item.output.object=object
            item.error=error
        }
    }
    for next:=0;next<len(final.outputs); {
        count:=0
        for next<len(final.outputs) && count<len(items) {
            output:=&final.outputs[next]
            next+=1
            if output.kind!=asset.KIND_TEXTURE {continue}
            items[count]=Finalize_Item{output=output}
            count+=1
        }
        if worker.system!=nil {
            jobs.parallel_for(worker.system,worker.worker,count,1,run,&work)
        } else {
            run(&work,0,count,worker.worker)
        }
        for item in items[:count] {
            if item.error!=.None {return {},item.error}
        }
    }
    object=asset.build_put(s,&final) or_return
    digits:[64]u8
    switch store.ref_set(s,asset.REF_IMPORTS,store.hex(final.key,&digits),object) {
    case .None:
    case .Out_Of_Memory: return {},.Out_Of_Memory
    case .Corrupt,.Unsupported_Layout: return {},.Corrupt
    case .Missing: return {},.Not_Found
    case .Io,.No_Space,.Invalid_Argument: return {},.IO
    }
    build^=final
    return object,.None
}

@(private="file")
texture_finalize :: proc(
    s:^store.Store,output:^asset.Build_Output,worker:jobs.Worker_Ref,gpu:^textures.Gpu_Context,
) ->
    (object:store.Hash,error:asset.Error) {
    scratch:mem.Dynamic_Arena
    mem.dynamic_arena_init(&scratch,context.allocator,context.allocator,
        block_size=1<<20,out_band_size=1<<20)
    defer mem.dynamic_arena_destroy(&scratch)
    context.temp_allocator=base.dynamic_arena_allocator(&scratch)
    types:asset.Types
    asset.types_init(&types,context.temp_allocator)
    defer asset.types_destroy(&types)
    file:asset.Asset
    asset.asset_open_object(&file,s,output.object,context.temp_allocator) or_return
    defer asset.asset_close(&file)
    view:=asset.texture_open(&file,&types) or_return
    if file.blob.header.id!=output.id {return {},.Corrupt}
    if .Fast not_in view.info.flags {return output.object,.None}

    final:=asset.asset_row(&file,&types,TEXTURE_FINAL,Texture_Final,whole=true) or_return
    if view.source==nil || final.key==0 {return {},.Not_Found}
    built:=texture_input_build({store=s},final^,&types,worker,gpu) or_return
    if .Fast in built.flags || built.format!=view.info.format ||
       built.width!=int(view.info.width) || built.height!=int(view.info.height) ||
       built.layers!=int(view.info.layers) {return {},.Corrupt}
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
