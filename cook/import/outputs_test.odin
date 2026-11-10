package importer

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:std/base"

// What a plugin that imports a source whole writes with Outputs: the root and
// the parts are the assets the sidecar of the source lists, each in the folder
// its kind goes to, and a run that fails leaves the sidecar as it was.
@(test)
the_outputs_of_a_source_are_the_assets_its_sidecar_lists :: proc(t:^testing.T) {
    root:=base.test_folder(t,"outputs")
    if root=="" {return}
    os.make_directory_all(fmt.tprintf("%s/source",root))
    source:=fmt.tprintf("%s/source/level.map",root)
    bytes:="a level"
    testing.expect(t,os.write_entire_file(source,bytes)==nil)
    Pass :: struct {scene,floor:base.Asset_Id,materials:[2]base.Asset_Id,scene_path,floor_path:string,warnings:int}
    pass :: proc(t:^testing.T,root,source,bytes:string,names:[]string,failed:=false) -> (p:Pass,ok:bool) {
        o:Outputs
        error:=outputs_begin(&o,source,fmt.tprintf("%s/assets/level",root),u64(len(bytes)),base.hash64(transmute([]u8)bytes),import_version(0),{root=root})
        if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
        root_error:Error
        p.scene,p.scene_path,root_error=output_root(&o,asset.KIND_SCENE,"level",".scene")
        testing.expect_value(t,root_error.code,Error_Code.None)
        p.floor,p.floor_path=output_part(&o,asset.KIND_MESH,"Floor",0,".mesh")
        ids,paths:=output_parts(&o,asset.KIND_MATERIAL,names,0,".mat",fmt.tprintf("%s/assets/level/materials",root))
        for id,at in ids {
            if at<len(p.materials) {p.materials[at]=id}
            testing.expectf(t,strings.contains(paths[at],"/assets/level/materials/"),"%s goes to the folder asked for",paths[at])
        }
        info:=output_info(&o,"Floor",0)
        testing.expect(t,base.text_get(info.source[:])=="source/level.map" && info.source_hash==base.hash64(transmute([]u8)bytes),"an output names the source by its place in the root")
        output_written(&o,p.scene,asset.KIND_SCENE,"level",p.scene_path,false)
        report:=outputs_end(&o,failed)
        p.warnings=len(report.warnings)
        testing.expect(t,failed || len(report.assets)==1 && report.saved!="","the report lists what was recorded, and the sidecar")
        report_destroy(&report)
        return p,true
    }
    first,ok:=pass(t,root,source,bytes,{"Stone","Wood"})
    if !ok {return}
    testing.expect(t,first.scene!={} && first.floor!={} && first.materials[0]!={} && first.materials[0]!=first.materials[1])
    testing.expect(t,strings.contains(first.scene_path,"/assets/level/level.scene"),first.scene_path)
    testing.expect(t,strings.contains(first.floor_path,"/.mirai/imported/") && strings.has_suffix(first.floor_path,".mesh"),first.floor_path)
    file:=fmt.tprintf("%s.import",source)
    sidecar,found,_:=sidecar_load(file,context.temp_allocator)
    testing.expect(t,found && len(sidecar.outputs)==4)

    // Again: the same assets. A run that fails writes no sidecar.
    again,again_ok:=pass(t,root,source,bytes,{"Wood","Stone"})
    testing.expect(t,again_ok && again.scene==first.scene && again.floor==first.floor && again.floor_path==first.floor_path && again.materials=={first.materials[1],first.materials[0]} && again.warnings==0,"each output is found by its kind and name")
    kept,_:=os.read_entire_file(file,context.temp_allocator)
    _,_=pass(t,root,source,bytes,{"Clay"},failed=true)
    after,_:=os.read_entire_file(file,context.temp_allocator)
    testing.expect(t,len(kept)>0 && string(after)==string(kept),"a failed import leaves the sidecar as it was")

    // A part renamed in the source is the one of its index that no name took; one that is gone leaves the sidecar.
    renamed,renamed_ok:=pass(t,root,source,bytes,{"Wood","Granite"})
    testing.expect(t,renamed_ok && renamed.materials=={first.materials[1],first.materials[0]},"Granite is what Stone was")
    _,gone_ok:=pass(t,root,source,bytes,{"Granite"})
    sidecar,found,_=sidecar_load(file,context.temp_allocator)
    testing.expect(t,gone_ok && found && len(sidecar.outputs)==3,"Wood is no longer listed")
}
