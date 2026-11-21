package build

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:cook/textures"
import "mirai:rhi/shared_device"
import "mirai:std/base"
import "mirai:std/jobs"
import "mirai:store"

cook_test_gpu :: proc(t:^testing.T,gpu:^textures.Gpu_Context) -> bool {
    device:=shared_device.take_or_skip(t)
    return device!=nil &&
        testing.expect_value(t,textures.gpu_context_init(gpu,device,""),textures.Error.None)
}

@(test)
a_cook_ships_what_the_scenes_and_the_roots_reach_as_the_runtime_loads_it :: proc(t:^testing.T) {
    gpu:textures.Gpu_Context
    if !cook_test_gpu(t,&gpu) {return}
    defer textures.gpu_context_destroy(&gpu)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    folder:=base.test_folder(t,"cook-reach")
    if folder=="" {return}
    assets,output:=fmt.tprintf("%s/project/assets",folder),fmt.tprintf("%s/ship/assets",folder)
    project_write(t,&types,assets)
    manifest:=fmt.tprintf("%s/project/%s",folder,COOK_FILE)

    // Without cook.mirai the scenes and the prefabs are the roots.
    report:=cook_assets({gpu=&gpu,assets=assets,output=output,manifest=manifest,codecs=.Open,allocator=context.temp_allocator})
    testing.expect_value(t,report.error,Cook_Error.None)
    kept,dropped:=names(&report)
    testing.expect_value(t,kept,"materials/wood.mat models/crate.mesh prefabs/prop.scene scenes/main.scene textures/wood_color.tex textures/wood_normal.tex ")
    testing.expect_value(t,dropped,"materials/lonely.mat materials/lost.mat materials/spare.mat notes.txt textures/blocks.tex textures/icon.tex textures/unused.tex ui/hud.ui ")
    testing.expect(t,report.roots==2 && len(report.missing)==0 && report.removed==0)
    for file in report.dropped {testing.expect(t,file.asset==(file.path!="notes.txt") && file.bytes>0)}
    testing.expect_value(t,report.textures_compressed,2)
    color,color_mips:=cooked_format(t,&types,fmt.tprintf("%s/textures/wood_color.tex",output))
    normal,_:=cooked_format(t,&types,fmt.tprintf("%s/textures/wood_normal.tex",output))
    testing.expect(t,color==.BC7 && normal==.BC5 && color_mips==2,"a texture is compressed by its use, level by level")
    total:i64
    for file in report.files {
        testing.expect(t,file.bytes>0 && file.source_bytes>0 && (file.compressed==(file.kind==asset.KIND_TEXTURE)))
        total+=file.bytes
    }
    testing.expect(t,report.output_bytes>total && report.source_bytes>report.output_bytes,"the size is that of the files and the index")
    testing.expect(t,!os.exists(fmt.tprintf("%s/notes.txt",output)) && !os.exists(fmt.tprintf("%s/ui",output)))
    // Any other asset is the same document, compressed for shipping.
    source,_:=os.read_entire_file(fmt.tprintf("%s/models/crate.mesh",assets),context.temp_allocator)
    shipped,_:=os.read_entire_file(fmt.tprintf("%s/models/crate.mesh",output),context.temp_allocator)
    repacked,repack_error:=asset.document_repack(source,.Ultra,.Open,context.temp_allocator)
    testing.expect(t,len(source)>0 && repack_error==.None && string(repacked)==string(shipped))

    // The index is what a scan of the output finds.
    indexed,scanned:asset.Registry
    asset.registry_init(&indexed,output);defer asset.registry_destroy(&indexed)
    asset.registry_init(&scanned,output);defer asset.registry_destroy(&scanned)
    testing.expect_value(t,asset.registry_load(&indexed,fmt.tprintf("%s/%s",output,asset.REGISTRY_INDEX)),asset.Error.None)
    testing.expect_value(t,asset.registry_scan(&scanned),asset.Error.None)
    testing.expect_value(t,len(indexed.files),6)
    testing.expect_value(t,len(scanned.files),6)
    for file,at in indexed.files {testing.expect(t,file.path==scanned.files[at].path && file.id==scanned.files[at].id && file.size==scanned.files[at].size && file.time==scanned.files[at].time)}
    crate,found:=asset.registry_find(&indexed,CRATE)
    testing.expect(t,found && len(asset.registry_dependencies(&indexed,crate))==1)

    // Roots by path, by folder and by id; a texture only an interface shows stays as it is.
    testing.expect(t,os.write_entire_file(manifest,`{"roots":["materials/spare.mat","ui/","00000000000000020000000000000004","notes.txt"]}`)==nil)
    report=cook_assets({gpu=&gpu,assets=assets,output=output,manifest=manifest,allocator=context.temp_allocator})
    testing.expect_value(t,report.error,Cook_Error.None)
    kept,dropped=names(&report)
    testing.expect_value(t,kept,"materials/lost.mat materials/spare.mat materials/wood.mat models/crate.mesh notes.txt prefabs/prop.scene scenes/main.scene textures/blocks.tex textures/icon.tex textures/wood_color.tex textures/wood_normal.tex ui/hud.ui ")
    testing.expect_value(t,dropped,"materials/lonely.mat textures/unused.tex ")
    testing.expect_value(t,report.roots,6)
    testing.expect(t,len(report.missing)==1 && report.missing[0].path=="materials/lost.mat" && report.missing[0].id==ABSENT,"a dependency that is no file is reported")
    icon,_:=cooked_format(t,&types,fmt.tprintf("%s/textures/icon.tex",output))
    blocks,_:=cooked_format(t,&types,fmt.tprintf("%s/textures/blocks.tex",output))
    testing.expect(t,icon==.RGBA8 && blocks==.BC1 && report.textures_compressed==2)
    summary:=cook_summary(&report,context.temp_allocator)
    testing.expect(t,strings.contains(summary,"assets: 12 of 14 files from 6 roots") && strings.contains(summary,"2 textures compressed") && strings.contains(summary,"  textures/unused.tex (") && strings.contains(summary,"missing: materials/lost.mat depends on 00000000000000090000000000000009"),summary)

    // A root that is no longer one: its files leave the output.
    testing.expect(t,os.write_entire_file(manifest,`{"roots":["ui/hud.ui"],"textures":"keep"}`)==nil)
    report=cook_assets({gpu=&gpu,assets=assets,output=output,manifest=manifest,allocator=context.temp_allocator})
    testing.expect_value(t,report.error,Cook_Error.None)
    testing.expect_value(t,report.removed,4)
    testing.expect(t,!os.exists(fmt.tprintf("%s/materials/spare.mat",output)) && !os.exists(fmt.tprintf("%s/notes.txt",output)) && os.is_file(fmt.tprintf("%s/ui/hud.ui",output)))
    testing.expect_value(t,report.textures_compressed,0)
    kept_color,_:=cooked_format(t,&types,fmt.tprintf("%s/textures/wood_color.tex",output))
    testing.expect_value(t,kept_color,asset.Texture_Format.RGBA8)
    testing.expect_value(t,asset.registry_load(&indexed,fmt.tprintf("%s/%s",output,asset.REGISTRY_INDEX)),asset.Error.None)
    testing.expect_value(t,len(indexed.files),8)

    // A dedicated server leaves behind what is only shown or heard, without missing it.
    testing.expect(t,os.write_entire_file(manifest,`{"roots":["materials/spare.mat","ui/","00000000000000020000000000000004","notes.txt"]}`)==nil)
    server:=fmt.tprintf("%s/server/assets",folder)
    report=cook_assets({gpu=&gpu,assets=assets,output=server,manifest=manifest,server=true,allocator=context.temp_allocator})
    testing.expect_value(t,report.error,Cook_Error.None)
    kept,_=names(&report)
    testing.expect_value(t,kept,"materials/lost.mat materials/spare.mat materials/wood.mat models/crate.mesh notes.txt prefabs/prop.scene scenes/main.scene ")
    testing.expect(t,len(report.missing)==1 && report.missing[0].id==ABSENT,"a texture a material names is not missing on a server")
    testing.expect(t,!os.exists(fmt.tprintf("%s/textures",server)) && !os.exists(fmt.tprintf("%s/ui",server)))
    summary=cook_summary(&report,context.temp_allocator)
    testing.expect(t,strings.contains(summary,"only shown or heard, which a dedicated server does not ship:\n  textures/blocks.tex") && strings.contains(summary,"that nothing reaches:\n  materials/lonely.mat"),summary)
}

// Files cooked at once on many workers are the files and the report of a
// cook on one: textures of one content share their blocks in the cache, and
// scenes resolve against the same prefab.
@(test)
a_cook_on_many_workers_writes_what_a_cook_on_one_does :: proc(t:^testing.T) {
    gpu:textures.Gpu_Context
    if !cook_test_gpu(t,&gpu) {return}
    defer textures.gpu_context_destroy(&gpu)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    folder:=base.test_folder(t,"cook-workers")
    if folder=="" {return}
    assets:=fmt.tprintf("%s/project/assets",folder)
    project_write(t,&types,assets)
    for at in 0..<16 {
        texture_write(t,&types,fmt.tprintf("%s/textures/tile_%02d.tex",assets,at),{8,u64(at)},{.Srgb},at%2==1)
        material_write(t,&types,fmt.tprintf("%s/materials/tile_%02d.mat",assets,at),{10,u64(at)},{8,u64(at)},{})
    }
    lamp_path:=fmt.tprintf("%s/prefabs/lamp.scene",assets)
    lamp:=glow_prefab_write(t,&types,lamp_path,1)
    for at in 0..<6 {
        level:asset.Scene;asset.scene_init(&level,&types,{11,u64(at)})
        _,placed:=asset.scene_instantiate(&level,&lamp,LAMP,0)
        testing.expect_value(t,placed,asset.Error.None)
        testing.expect_value(t,asset.scene_save(&level,fmt.tprintf("%s/scenes/level_%d.scene",assets,at)),asset.Error.None)
        asset.scene_destroy(&level)
    }
    asset.scene_destroy(&lamp)
    lamp=glow_prefab_write(t,&types,lamp_path,4)
    asset.scene_destroy(&lamp)
    manifest:=fmt.tprintf("%s/project/%s",folder,COOK_FILE)
    testing.expect(t,os.write_entire_file(manifest,`{"roots":["materials/"]}`)==nil)

    cook :: proc(folder,assets,manifest,name:string,threads:int,gpu:^textures.Gpu_Context) -> Cook_Report {
        js:jobs.Job_System
        if !jobs.system_init(&js,{threads=threads,allocator=runtime.heap_allocator()}) {return {error=.Write_Failed}}
        defer jobs.system_destroy(&js)
        kept,opened:=store.open(fmt.tprintf("%s/%s_store",folder,name),context.temp_allocator)
        if opened!=.None {return {error=.Write_Failed}}
        return cook_assets({gpu=gpu,assets=assets,output=fmt.tprintf("%s/%s",folder,name),manifest=manifest,store=&kept,worker={system=&js},allocator=context.temp_allocator})
    }
    one:=cook(folder,assets,manifest,"one",0,&gpu)
    many:=cook(folder,assets,manifest,"many",7,&gpu)
    testing.expectf(t,one.error==.None && many.error==.None,"%v %s, %v %s",one.error,one.detail,many.error,many.detail)
    testing.expect(t,one.textures_compressed>8 && one.scenes_resolved==6,"textures to compress and scenes to resolve")
    testing.expect(t,len(one.files)==len(many.files) && len(one.dropped)==len(many.dropped) && len(one.missing)==len(many.missing))
    testing.expect(t,one.roots==many.roots && one.textures_compressed==many.textures_compressed && one.scenes_resolved==many.scenes_resolved && one.output_bytes==many.output_bytes && one.source_bytes==many.source_bytes)
    for file,at in one.files {
        if at>=len(many.files) {break}
        other:=many.files[at]
        testing.expectf(t,file.path==other.path && file.id==other.id && file.kind==other.kind && file.bytes==other.bytes && file.compressed==other.compressed && file.resolved==other.resolved,"%s against %s",file.path,other.path)
        written,_:=os.read_entire_file(fmt.tprintf("%s/one/%s",folder,file.path),context.temp_allocator)
        again,_:=os.read_entire_file(fmt.tprintf("%s/many/%s",folder,other.path),context.temp_allocator)
        testing.expectf(t,len(written)>0 && slice.equal(written,again),"%s is not the same",file.path)
    }
    for file,at in one.dropped {
        if at<len(many.dropped) {testing.expect_value(t,many.dropped[at].path,file.path)}
    }
    for lost,at in one.missing {
        if at<len(many.missing) {testing.expect(t,many.missing[at].path==lost.path && many.missing[at].id==lost.id)}
    }
    // A quick cook writes the same files, a little larger, and each reads back as the asset it was.
    quick:=cook_assets({gpu=&gpu,assets=assets,output=fmt.tprintf("%s/quick",folder),manifest=manifest,quick=true,allocator=context.temp_allocator})
    testing.expectf(t,quick.error==.None && len(quick.files)==len(one.files) && quick.output_bytes>=one.output_bytes,"%v %s: %d against %d bytes",quick.error,quick.detail,quick.output_bytes,one.output_bytes)
}

// A cook writes again only what changed: a file and every asset it is made of keep their
// contents, and its output is as the cook before left it.
@(test)
a_cook_writes_again_only_what_is_made_of_what_changed :: proc(t:^testing.T) {
    gpu:textures.Gpu_Context
    if !cook_test_gpu(t,&gpu) {return}
    defer textures.gpu_context_destroy(&gpu)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    folder:=base.test_folder(t,"cook-keys")
    if folder=="" {return}
    assets,output,keys:=fmt.tprintf("%s/project/assets",folder),fmt.tprintf("%s/ship/assets",folder),fmt.tprintf("%s/ship.cook",folder)
    project_write(t,&types,assets)
    written :: proc(report:^Cook_Report) -> string {
        b:=strings.builder_make(context.temp_allocator)
        for file in report.files {
            if !file.reused {fmt.sbprintf(&b,"%s ",file.path)}
        }
        return strings.to_string(b)
    }
    all:="materials/wood.mat models/crate.mesh prefabs/prop.scene scenes/main.scene textures/wood_color.tex textures/wood_normal.tex "
    Step :: struct {name:string,change:proc(t:^testing.T,assets,output,keys:string),written:string}
    steps:=[]Step{
        {"the first cook",nil,all},
        {"nothing changed",nil,""},
        {"the wood changed: the mesh and the scenes are made of it",proc(t:^testing.T,assets,output,keys:string) {
            types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
            material_write(t,&types,fmt.tprintf("%s/materials/wood.mat",assets),WOOD,WOOD_NORMAL,WOOD_COLOR)
        },"materials/wood.mat models/crate.mesh prefabs/prop.scene scenes/main.scene "},
        {"an output went",proc(t:^testing.T,assets,output,keys:string) {_=os.remove(fmt.tprintf("%s/textures/wood_color.tex",output))},"textures/wood_color.tex "},
        {"the keys are random bytes",proc(t:^testing.T,assets,output,keys:string) {
            noise:[64]u8
            for &b,i in noise {b=u8(i*37+11)}
            noise[0]=1 // the version: what follows is read, and is noise
            testing.expect(t,os.write_entire_file(keys,noise[:])==nil)
        },all},
    }
    for step in steps {
        if step.change!=nil {step.change(t,assets,output,keys)}
        report:=cook_assets({gpu=&gpu,assets=assets,output=output,keys=keys,allocator=context.temp_allocator})
        testing.expect_value(t,report.error,Cook_Error.None)
        testing.expectf(t,written(&report)==step.written,"%s: %s",step.name,written(&report))
        testing.expect_value(t,report.reused,len(report.files)-strings.count(step.written," "))
    }
}

// What a cook writes is compressed as its project allows and reads back as what the project
// holds: nothing, or streams of the formats of the codecs it allows, with the layouts of blocks
// only of the best. The cook is where the container's own compression is made: the project keeps
// its assets written without a compressor.
@(test)
a_cook_compresses_as_its_project_says_and_what_it_writes_decodes :: proc(t:^testing.T) {
    gpu:textures.Gpu_Context
    if !cook_test_gpu(t,&gpu) {return}
    defer textures.gpu_context_destroy(&gpu)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    folder:=base.test_folder(t,"cook-codecs")
    if folder=="" {return}
    assets:=fmt.tprintf("%s/project/assets",folder)
    project_write(t,&types,assets)
    manifest:=fmt.tprintf("%s/project/%s",folder,COOK_FILE)
    for codecs in asset.Codecs {
        output:=fmt.tprintf("%s/ship-%v/assets",folder,codecs)
        report:=cook_assets({gpu=&gpu,assets=assets,output=output,manifest=manifest,codecs=codecs,allocator=context.temp_allocator})
        testing.expect_value(t,report.error,Cook_Error.None)
        testing.expect(t,report.textures_compressed==2)
        streams:=0
        for file in report.files {
            if file.id=={} {continue}
            path:=fmt.tprintf("%s/%s",output,file.path)
            a:asset.Asset
            if !testing.expect_value(t,asset.asset_load(&a,path),asset.Error.None) {continue}
            defer asset.asset_close(&a)
            for i in 0..<int(a.blob.header.chunk_count) {
                entry:=asset.blob_chunk(&a.blob,i)
                if entry.compression==.None {continue}
                streams+=1
                testing.expectf(t,asset.pack_matches(asset.blob_stored(&a.blob,entry),.Ultra,codecs),"%s is a stream of %v",file.path,codecs)
            }
            if file.kind==asset.KIND_TEXTURE {
                _,error:=asset.texture_view(&a,&types)
                testing.expect_value(t,error,asset.Error.None)
                _,laid:=asset.asset_table(&a,asset.TEXTURE_TABLE_LAYOUTS)
                testing.expect(t,!laid || codecs==.Best,"layouts only of the best codecs")
            }
            if file.compressed || file.resolved {continue}
            // Written again without a compressor, the file shipped is the one the project holds.
            source,_:=os.read_entire_file(fmt.tprintf("%s/%s",assets,file.path),context.temp_allocator)
            shipped,_:=os.read_entire_file(path,context.temp_allocator)
            header,_:=asset.header_read(source)
            raw :: proc(bytes:[]u8,types:^asset.Types,texture:bool) -> []u8 {
                out:[]u8
                if texture {out,_=asset.texture_repack(bytes,types,.Fast,context.temp_allocator)} else {out,_=asset.document_repack(bytes,.Fast,.None,context.temp_allocator)}
                return out
            }
            want,got:=raw(source,&types,header.kind==asset.KIND_TEXTURE),raw(shipped,&types,header.kind==asset.KIND_TEXTURE)
            testing.expectf(t,len(want)>0 && string(want)==string(got),"%s ships what the project holds (%v)",file.path,codecs)
        }
        testing.expect(t,(streams==0)==(codecs==.None),"something compresses unless nothing may")
    }
}
