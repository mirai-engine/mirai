package editor

import "mirai:asset"
import "mirai:editor/api"
import erender "mirai:engine/render"
import "mirai:std/base"
import "mirai:std/serial"

// material.inspect, material.set and material.revert:
// materials by code, with their values as the text of asset.Material_Info:
// the base, its layers (coat, fuzz, anisotropy, diffuse transmission, unlit), its maps and its
// program; and, by name, the parameters of its Surface program and the layers
// drawn over it. Of an imported material, also what its source gave at the
// last import and the fields changed after it, which the next import keeps.

@(private)
Api_Material_Revert_Params :: struct {
    material:[API_PATH_BYTES]u8 `mirai:"text,label=A material by its path under the assets folder or its id"`,
    paths:[512]u8 `mirai:"text,optional,label=Fields separated by commas as overrides names them (roughness; maps.normal.texture) or parts of the material (coat; maps.normal); none: all of it"`,
}

@(private)
Api_Material_Result :: struct {
    material:base.Asset_Id,
    path:string `mirai:"optional,label=Under the assets folder"`,
    values:asset.Material_Info `mirai:"label=As material.set takes them"`,
    imported:asset.Material_Info `mirai:"optional,label=Of an imported material: the values its source gave at the last import"`,
    overrides:[]string `mirai:"optional,label=Of an imported material: every field that differs from imported; importing it again keeps them"`,
    parameters:serial.Json `mirai:"label=What it stores for its Surface program by name: a list of numbers; or the id of a texture"`,
    overlays:[]Api_Material_Instance_Overlay `mirai:"label=The layers drawn over it; bottom first"`,
}

Api_Material_Params :: struct {
    material:string `mirai:"optional,label=A material: its path under the assets folder, or its id"`,
    path:string `mirai:"optional,label=material.set: in place of material, a new material at this path under the assets folder, made over the defaults; it fails when that file exists"`,
    values:serial.Json `mirai:"optional,label=Fields of the material to change, as material.inspect shows them"`,
    parameters:serial.Json `mirai:"optional,label=material.set: numbers of the Surface program of the material by name, each a number or an array of its components"`,
    textures:serial.Json `mirai:"optional,label=material.set: textures of the Surface program of the material by name, each the path or the id of a texture; an empty text shows none"`,
    overlays:[]Api_Material_Overlay_Param `mirai:"optional,label=material.set: the layers drawn over the material, bottom first, in place of those it has"`,
}

@(private)
materials_api_register :: proc(s:^Session,st:^Api_State) {
    api_register(s,st,{name="material.inspect",params=type_info_of(Api_Material_Params),summary="The values of a material (.mat) and, of an imported one, what its source gave at the last import and the fields that differ from it.",result=type_info_of(Api_Material_Result),flags={.Read_Only},run=api_material_inspect})
    material_capture_register(s,st)
    api_register(s,st,{name="material.set",params=type_info_of(Api_Material_Params),summary="Changes a material (.mat) for every entity that shows it, its values and, by name, the parameters and textures of its Surface program and the layers drawn over it, or makes a new one at path over the defaults. What it is not given stays. One undo step, in memory: asset.save writes its file.",result=type_info_of(Api_Material_Result),run=api_material_set})
    api_register(s,st,{name="material.revert",params=type_info_of(Api_Material_Revert_Params),summary="Gives fields of an imported material back what its source gave at the last import, so they stop being overrides.",result=type_info_of(Api_Material_Result),flags={.Idempotent},run=api_material_revert})
    material_instance_api_register(s,st)
}

@(private)
material_values_read :: proc(call:^api.Call,text:string,info:^asset.Material_Info) -> bool {
    if !asset_values_read(call,text,info) {return false}
    if !asset.material_check({info=info}) {
        api.call_fail(call,api.INVALID_PARAMS,"values: a number that is not finite or is outside its range: opacity, metallic, roughness, weights, amounts and the colors of the layers go from 0 to 1, ior and the coat ior are at least 1")
        return false
    }
    return true
}

// The file of a material as it is now: unsaved in memory, or on disk. The
// caller closes file with asset_close.
@(private)
material_open :: proc(s:^Session,id:base.Asset_Id,file:^asset.Asset) -> (view:asset.Material_View,ok:bool) {
    a:=s.app.assets
    record,found:=asset.registry_find(&a.registry,id)
    if !found || !asset_read(s,record.path,file) {return}
    error:asset.Error
    if view,error=asset.material_view(file,&a.types);error!=.None {
        asset.asset_close(file)
        return {},false
    }
    return view,true
}

// The values a material has in its file, as it is now.
@(private)
material_file :: proc(s:^Session,id:base.Asset_Id) -> (info:asset.Material_Info,ok:bool) {
    file:asset.Asset
    view:=material_open(s,id,&file) or_return
    defer asset.asset_close(&file)
    return view.info^,true
}

@(private)
api_material_write :: proc(s:^Session,call:^api.Call,id:base.Asset_Id) {
    file:asset.Asset
    view,read:=material_open(s,id,&file)
    if !read {
        api.call_fail(call,api.SERVER_ERROR,api_asset_read_problem(s,id,"material"))
        return
    }
    defer asset.asset_close(&file)
    r:=api.call_result(call,Api_Material_Result)
    r.material,r.path=id,asset_path(s,id)
    r.values=view.info^
    if view.imported!=nil {
        r.imported=view.imported^
        overrides:=make([dynamic]string,call.allocator)
        asset.material_overrides(&s.app.assets.types,view,&overrides)
        r.overrides=overrides[:]
    }
    out:serial.Writer
    serial.writer_init(&out,256,call.allocator)
    serial.write_u8(&out,'{')
    first:=true
    for &parameter in view.parameters {
        if parameter.overlay!=0 {continue}
        if !first {serial.write_u8(&out,',')}
        first=false
        serial.text_write_string(&out,base.text_get(parameter.name[:]))
        serial.write_u8(&out,':')
        if parameter.kind==.Texture {
            api_asset_write(&out,parameter.texture)
            continue
        }
        serial.write_u8(&out,'[')
        for component in 0..<clamp(int(parameter.components),1,4) {
            if component>0 {serial.write_u8(&out,',')}
            serial.text_write_float(&out,transmute(u64)parameter.value[component],8)
        }
        serial.write_u8(&out,']')
    }
    serial.write_u8(&out,'}')
    r.parameters=serial.Json(serial.writer_bytes(&out))
    r.overlays=api_overlays(view.overlays,call.allocator)
}

@(private)
api_material_inspect :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Material_Params)
    id,found:=asset_named(s,call,p.material,asset.KIND_MATERIAL,".mat","a material")
    if !found {return}
    api_material_write(s,call,id)
}

@(private)
api_material_set :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Material_Params)
    t,found:=asset_target(s,call,p.material,p.path,"material",asset.KIND_MATERIAL,".mat","a material")
    if !found {return}
    info:=asset.MATERIAL_DEFAULTS
    if !t.created {
        loaded:bool
        if info,loaded=material_file(s,t.id);!loaded {
            api.call_fail(call,api.SERVER_ERROR,api_asset_read_problem(s,t.id,"material"))
            return
        }
    }
    if !material_values_read(call,string(p.values),&info) {return}
    // What it is given by name, of the program its values name now.
    given:=erender.MATERIAL_VALUES_DEFAULT
    program:=erender.program_find(s.app.assets,base.text_get(info.program[:]),.Surface)
    if !material_given_read(s,call,program,t.id,0,string(p.parameters),string(p.textures),p.overlays,&given,"material.set takes") {return}
    label:=t.created?"Create material":"Material"
    if !api_edit_begin(s,call,label) {return}
    written:bool
    if t.created {
        bytes,error:=asset.material_bytes(&s.app.assets.types,{id=t.id,info=info},context.temp_allocator)
        written=error==.None && file_write(s,t.file,bytes,label)
        if written && !erender.material_values_plain(&given) {written=material_write(s,t.id,{kind=.Set,info=info,override=&given})}
    } else {
        written=material_write(s,t.id,{kind=.Set,info=info,override=&given})
    }
    if !written {api.call_fail(call,api.SERVER_ERROR,api_asset_write_problem(s,t.file))}
    if !api_edit_end(s,call,written) {return}
    api_material_write(s,call,t.id)
}

@(private)
api_material_revert :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Material_Revert_Params)
    id,found:=asset_named(s,call,base.text_get(p.material[:]),asset.KIND_MATERIAL,".mat","a material")
    if !found {return}
    paths:=api_paths_split(base.text_get(p.paths[:]))
    file:asset.Asset
    view,read:=material_open(s,id,&file)
    if !read {
        api.call_fail(call,api.SERVER_ERROR,api_asset_read_problem(s,id,"material"))
        return
    }
    reverted,failed,error:=asset.material_revert(&s.app.assets.types,view,paths)
    asset.asset_close(&file)
    switch {
    case error==.None:
    case view.imported==nil:
        api.call_fail(call,api.INVALID_PARAMS,"The material was not imported: it has no values of a source to go back to; material.set changes it")
        return
    case failed!="":
        api.call_failf(call,api.INVALID_PARAMS,"paths: %q is not a field of the material; material.inspect names them, as in overrides",failed)
        return
    case:
        api.call_fail(call,api.SERVER_ERROR,api_asset_read_problem(s,id,"material"))
        return
    }
    if !api_edit_begin(s,call,"Revert material") {return}
    written:=material_write(s,id,{kind=.Values,info=reverted})
    if !written {api.call_fail(call,api.SERVER_ERROR,api_asset_write_problem(s,asset_name_of(s.app.assets,id)))}
    if !api_edit_end(s,call,written) {return}
    api_material_write(s,call,id)
}
