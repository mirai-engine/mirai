package editor

import "mirai:asset"
import "mirai:editor/api"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/serial"

// material.inspect, material.set and material.revert:
// materials by code, with their values as the text of asset.Material_Info:
// the base, its layers (coat, fuzz, anisotropy, diffuse transmission, unlit), its maps and its
// program. Of an imported material, also what its source gave at the last
// import and the fields changed after it, which the next import keeps.

@(private)
Api_Material_Revert_Params :: struct {
    material:[API_PATH_BYTES]u8 `mirai:"text,label=A material by its path under the assets folder or its id"`,
    paths:[512]u8 `mirai:"text,optional,label=Fields separated by commas as overrides names them (roughness; maps.normal.texture) or parts of the material (coat; maps.normal); none: all of it"`,
}

@(private)
Api_Material_Result :: struct {
    material:base.Asset_Id,
    path:[API_PATH_BYTES]u8 `mirai:"text,optional,label=Under the assets folder"`,
    values:serial.Json `mirai:"label=Its base; its layers (coat; fuzz; anisotropy; diffuse transmission; unlit); its maps and its program; as material.set takes them"`,
    imported:serial.Json `mirai:"optional,label=Of an imported material: the values its source gave at the last import"`,
    overrides:[][asset.OVERRIDE_PATH_BYTES]u8 `mirai:"text,optional,label=Of an imported material: every field that differs from imported; importing it again keeps them"`,
}

// What material.inspect, material.set take.
Api_Material_Params :: struct {
    material:string `mirai:"optional,label=A material: its path under the assets folder, or its id"`,
    path:string `mirai:"optional,label=material.set: in place of material, a new material at this path under the assets folder, made over the defaults; it fails when that file exists"`,
    values:serial.Json `mirai:"optional,label=Fields of the material to change, as material.inspect shows them"`,
}

@(private)
materials_api_register :: proc(s:^Session,st:^Api_State) {
    api_register(s,st,{name="material.inspect",params=Api_Material_Params,summary="The values of a material (.mat) and, of an imported one, what its source gave at the last import and the fields that differ from it.",result=Api_Material_Result,writes_result=true,flags={.Read_Only},run=api_material_inspect})
    material_capture_register(s,st)
    api_register(s,st,{name="material.set",params=Api_Material_Params,summary="Changes the values of a material (.mat) for every entity that shows it, keeping its program parameters and overlays, or makes a new one at path over the defaults.",result=Api_Material_Result,writes_result=true,run=api_material_set})
    api_register(s,st,{name="material.revert",params=Api_Material_Revert_Params,summary="Gives fields of an imported material back what its source gave at the last import, so they stop being overrides.",result=Api_Material_Result,writes_result=true,flags={.Idempotent},run=api_material_revert})
    material_instance_api_register(s,st)
}

@(private)
material_values_read :: proc(call:^api.Call,text:string,info:^asset.Material_Info) -> bool {
    if !asset_values_read(call,text,info) {return false}
    if !asset.material_check({info=info}) {
        api.call_fail(call,api.INVALID_PARAMS,"values: a number that is not finite or is outside its range: opacity, metallic, roughness, weights, amounts and the colors of the layers go from 0 to 1, ior is 0 or at least 1 and the coat ior at least 1")
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
    out:=call.out
    asset_named_write(s,out,"material",id)
    asset_values_write(out,"values",view.info)
    if view.imported!=nil {
        asset_values_write(out,"imported",view.imported)
        overrides:=make([dynamic]string,context.temp_allocator)
        asset.material_overrides(&s.app.assets.types,view,&overrides)
        api.write_key(out,"overrides")
        serial.write_u8(out,'[')
        for path,i in overrides {
            if i>0 {serial.write_u8(out,',')}
            serial.text_write_string(out,path)
        }
        serial.write_u8(out,']')
    }
    serial.write_u8(out,'}')
}

@(private)
api_material_inspect :: proc(s:^Session,call:^api.Call) {
    p,read:=asset_params(call,"material")
    if !read {return}
    id,found:=asset_named(s,call,p.named,asset.KIND_MATERIAL,".mat","a material")
    if !found {return}
    api_material_write(s,call,id)
}

@(private)
api_material_set :: proc(s:^Session,call:^api.Call) {
    p,read:=asset_params(call,"material")
    if !read {return}
    t,found:=asset_target(s,call,&p,"material",asset.KIND_MATERIAL,".mat","a material")
    if !found {return}
    info:=asset.MATERIAL_DEFAULTS
    if !t.created {
        loaded:bool
        if info,loaded=material_file(s,t.id);!loaded {
            api.call_fail(call,api.SERVER_ERROR,api_asset_read_problem(s,t.id,"material"))
            return
        }
    }
    if !material_values_read(call,p.values,&info) {return}
    label:=t.created?"Create material":"Material"
    if !api_edit_begin(s,call,label) {return}
    written:bool
    if t.created {
        bytes,error:=asset.material_bytes(&s.app.assets.types,{id=t.id,info=info},context.temp_allocator)
        written=error==.None && file_write(s,t.file,bytes,label)
    } else {
        written=material_write(s,t.id,{kind=.Values,info=info})
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
