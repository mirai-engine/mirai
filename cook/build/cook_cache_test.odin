package build

import "core:fmt"
import "core:os"
import "core:slice"
import "core:testing"
import "mirai:asset"
import "mirai:cook/cache"
import "mirai:cook/textures"
import "mirai:std/base"
import "mirai:store"

@(test)
a_cook_takes_the_blocks_of_a_texture_from_the_cache_of_its_content :: proc(t:^testing.T) {
    gpu:textures.Gpu_Context
    if !cook_test_gpu(t,&gpu) {return}
    defer textures.gpu_context_destroy(&gpu)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    folder:=base.test_folder(t,"cook-texture-cache")
    if folder=="" {return}
    assets:=fmt.tprintf("%s/assets",folder)
    kept_store,opened:=store.open(fmt.tprintf("%s/store",folder),context.temp_allocator)
    if !testing.expect_value(t,opened,store.Error.None) {return}
    texture_cache:=cache.Cache{store=&kept_store}
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
    report:=cook_assets({gpu=&gpu,assets=assets,output=fmt.tprintf("%s/first",folder),manifest=manifest,store=&kept_store,codecs=.Compressed,allocator=context.temp_allocator})
    testing.expect(t,report.error==.None && report.textures_compressed==1)
    testing.expect(t,report.seconds>0,"the report says how long the cook took")
    format,blocks:=level(t,&types,fmt.tprintf("%s/first/textures/wood.tex",folder))
    testing.expect(t,format==.BC1 && len(blocks)==32)
    original:asset.Asset
    testing.expect_value(t,asset.asset_load(&original,source,context.temp_allocator),asset.Error.None)
    key:=textures.cache_key_blocks(original.blob.header.content_hash)
    kept,found:=textures.cache_read(texture_cache,key,&types,context.temp_allocator)
    testing.expect(t,found && kept.format==.BC1 && slice.equal(kept.mips[0],blocks))

    // The next cook reads them: blocks the cache was given are the ones it ships.
    kept.mips[0][0]~=0xff
    testing.expect(t,textures.cache_write(texture_cache,key,&types,&kept))
    report=cook_assets({gpu=&gpu,assets=assets,output=fmt.tprintf("%s/second",folder),manifest=manifest,store=&kept_store,codecs=.Compressed,allocator=context.temp_allocator})
    testing.expect(t,report.error==.None && report.textures_compressed==1)
    _,cached:=level(t,&types,fmt.tprintf("%s/second/textures/wood.tex",folder))
    testing.expect(t,len(cached)==32 && cached[0]==blocks[0]~0xff && slice.equal(cached[1:],blocks[1:]))

    // A cook without a cache compresses, and another content is another key.
    report=cook_assets({gpu=&gpu,assets=assets,output=fmt.tprintf("%s/third",folder),manifest=manifest,codecs=.Compressed,allocator=context.temp_allocator})
    _,fresh:=level(t,&types,fmt.tprintf("%s/third/textures/wood.tex",folder))
    testing.expect(t,report.error==.None && slice.equal(fresh,blocks))
    pixels[0]+=1
    testing.expect_value(t,asset.texture_save(source,&types,{id={1,1},width=8,height=8,format=.RGBA8,mips={pixels[:]}}),asset.Error.None)
    changed:asset.Asset
    testing.expect_value(t,asset.asset_load(&changed,source,context.temp_allocator),asset.Error.None)
    testing.expect(t,textures.cache_key_blocks(changed.blob.header.content_hash)!=key)
    free_all(context.temp_allocator)
}

// Every table and column of two opened assets, decoded.
@(private="file")
same_tables :: proc(a,b:^asset.Asset) -> bool {
    if a.blob.header.id!=b.blob.header.id || a.blob.header.kind!=b.blob.header.kind || len(a.tables)!=len(b.tables) {return false}
    for &table,at in a.tables {
        other:=&b.tables[at]
        if table.name!=other.name || table.rows!=other.rows || len(table.columns)!=len(other.columns) {return false}
        for _,column in table.columns {
            x,x_error:=asset.asset_column_data(a,&table,column)
            y,y_error:=asset.asset_column_data(b,other,column)
            if x_error!=.None || y_error!=.None || !slice.equal(x,y) {return false}
        }
    }
    return true
}

// The assets a project lists from its packages are objects of the store: a
// cook ships each as a file that loads as the object does, and looks the
// texture cache up once for the textures of its pass, in one fetch.
@(test)
a_cook_ships_package_assets_from_their_objects_and_looks_the_cache_up_once :: proc(t:^testing.T) {
    gpu:textures.Gpu_Context
    if !cook_test_gpu(t,&gpu) {return}
    defer textures.gpu_context_destroy(&gpu)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    folder:=base.test_folder(t,"cook-package-objects")
    if folder=="" {return}
    root:=fmt.tprintf("%s/game",folder)
    assets:=fmt.tprintf("%s/assets",root)
    os.make_directory_all(assets)
    s,opened:=store.open(fmt.tprintf("%s/store",folder),context.temp_allocator)
    if !testing.expect_value(t,opened,store.Error.None) {return}
    defer store.close(&s)
    file_of :: proc(t:^testing.T,types:^asset.Types,id:base.Asset_Id,fill:u8) -> []u8 {
        pixels:=make([]u8,8*8*4,context.temp_allocator)
        for &value,at in pixels {value=at%4==3?255:u8(at)*fill}
        doc:asset.Document
        testing.expect_value(t,asset.texture_document(&doc,types,{id=id,width=8,height=8,format=.RGBA8,mips={pixels}},context.temp_allocator),asset.Error.None)
        defer asset.document_destroy(&doc)
        bytes,_:=asset.document_bytes(&doc,context.temp_allocator)
        return bytes
    }
    p:=asset.Package{id={40,40},name="kit"}
    p.assets=make([dynamic]asset.Package_Asset,context.temp_allocator)
    b:=asset.Build{package_id=p.id,final=true}
    b.outputs=make([dynamic]asset.Build_Output,context.temp_allocator)
    info,_:=asset.kind_info(asset.KIND_TEXTURE)
    objects:[2]store.Hash
    for name,at in ([2]string{"wood","stone"}) {
        id:=base.Asset_Id{41+u64(at),1}
        append(&p.assets,asset.Package_Asset{kind=asset.KIND_TEXTURE,name=name,id=id})
        objects[at],_=asset.object_put(&s,file_of(t,&types,id,u8(3+at)))
        append(&b.outputs,asset.Build_Output{id=id,kind=asset.KIND_TEXTURE,kind_version=info.version,object=objects[at]})
    }
    manifest,_:=asset.package_put(&s,&p)
    built,_:=asset.build_put(&s,&b)
    digits:[64]u8
    testing.expect_value(t,store.ref_set(&s,asset.REF_BUILDS,store.hex(asset.build_select(manifest,&p),&digits),built),store.Error.None)
    list:asset.Packages
    list.packages=make([dynamic]asset.Project_Package,context.temp_allocator)
    append(&list.packages,asset.Project_Package{id=p.id,manifest=manifest,folder="kit"})
    testing.expect_value(t,asset.packages_save(root,&list),asset.Error.None)
    Counted :: struct {calls,names:int}
    counted:Counted
    fetch :: proc(user:rawptr,into:^store.Store,namespace:string,names:[]string,given:[]bool) {
        c:=(^Counted)(user)
        c.calls+=1
        c.names+=len(names)
    }
    for pass in ([2]string{"blocks","keep"}) {
        manifest_file:=fmt.tprintf("%s/%s-%s",folder,pass,COOK_FILE)
        testing.expect(t,os.write_entire_file(manifest_file,fmt.tprintf(`{{"roots":["kit/"],"textures":"%s"}}`,pass))==nil)
        output:=fmt.tprintf("%s/%s",folder,pass)
        report:=cook_assets({gpu=&gpu,assets=assets,root=root,output=output,manifest=manifest_file,store=&s,cache_source={fetch=fetch,user=&counted},allocator=context.temp_allocator})
        if !testing.expectf(t,report.error==.None,"%s: %v %s",pass,report.error,report.detail) {continue}
        testing.expect_value(t,len(report.files),2)
        if pass=="blocks" {
            testing.expectf(t,counted.calls==1 && counted.names==2 && report.textures_compressed==2,"one lookup for the pass: %v",counted)
            continue
        }
        for name,at in ([2]string{"wood","stone"}) {
            shipped,stored:asset.Asset
            testing.expect_value(t,asset.asset_load(&shipped,fmt.tprintf("%s/kit/%s.tex",output,name),context.temp_allocator),asset.Error.None)
            testing.expect_value(t,asset.asset_open_object(&stored,&s,objects[at],context.temp_allocator),asset.Error.None)
            testing.expectf(t,same_tables(&shipped,&stored),"%s ships as its object loads",name)
            asset.asset_close(&shipped)
            asset.asset_close(&stored)
        }
    }
}
