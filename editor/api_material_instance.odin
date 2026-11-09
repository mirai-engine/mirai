package editor

import "core:fmt"
import "mirai:asset"
import "mirai:core"
import "mirai:editor/api"
import erender "mirai:engine/render"
import "mirai:host"
import gpu "mirai:render"
import "mirai:std/base"
import "mirai:std/serial"

// material.instance.inspect, set, revert and apply: what an entity shows of
// the material of a slot of its mesh, its Material_Override, as the inspector
// edits it.

@(private)
MATERIAL_INSTANCE_SET_SCHEMA :: `{"type":"object","properties":{"entity":{`+api.ENTITY_SCHEMA+`,"description":"The entity with the Mesh_Renderer"},"slot":{"type":"integer","minimum":0,"description":"The slot of its mesh whose material the values, parameters and textures are of, from 0; 0 when omitted"},"values":{"type":"object","description":"Values it shows, as material.instance.inspect gives them: those that differ from its material become its own"},"parameters":{"type":"object","description":"Numbers of the Surface program of its material for this entity, by name, as 1 to 4 numbers; null takes one away"},"textures":{"type":"object","description":"Textures for this entity by a map (maps.base_color, maps.normal...) or a texture of the program: a texture by path or id, \"\" for none, null takes it away"},"overlays":{"type":["array","null"],"description":"Layers in place of those of its material, [{material, blend: Alpha|Additive|Multiply, enabled}]; null gives back those of the material"}},"required":["entity"],"additionalProperties":false}`

@(private)
Api_Material_Slot_Params :: struct {
    entity:base.Entity_Id,
    slot:int `mirai:"optional,min=0,label=The slot of its mesh, from 0"`,
}

@(private)
Api_Material_Instance :: struct {
    id:base.Entity_Id,
    slot:int,
    slots:int `mirai:"label=The slots of its mesh"`,
    material:base.Asset_Id `mirai:"label=The material of the slot"`,
    values:u8 `mirai:"any,label=The values of its material with those of the entity over them"`,
    overrides:[1][asset.MATERIAL_NAME_BYTES]u8 `mirai:"text,list,label=What the entity changes: values; maps; parameters and textures of the program by name; and overlays"`,
    parameters:u8 `mirai:"any,optional,label=Of the Surface program of its material by name: a list of the numbers it shows; or the id of the texture the entity gives it (all zeros: none)"`,
    overlays:[1]Api_Material_Instance_Overlay `mirai:"list,label=The layers it shows over the material of its first slot"`,
}

@(private)
Api_Material_Instance_Overlay :: struct {
    material:base.Asset_Id,
    blend:asset.Overlay_Blend,
    enabled:bool,
}

@(private)
material_instance_api_register :: proc(s:^Session,st:^Api_State) {
    api_register(s,st,{name="material.instance.inspect",params=Api_Material_Slot_Params,summary="What an entity shows of the material of a slot of its mesh: its values with those of the entity over them, what the entity changes of it, its parameters and its overlays.",result=Api_Material_Instance,writes_result=true,flags={.Read_Only},run=api_material_instance_inspect})
    api_register(s,st,{name="material.instance.set",params_schema=MATERIAL_INSTANCE_SET_SCHEMA,summary="Makes the values given that differ from the material of the slot, and the parameters, textures and overlays given, the entity's own; the material does not change. In Edit; one undo step.",result=Api_Material_Instance,writes_result=true,run=api_material_instance_set})
    api_register(s,st,{name="material.instance.revert",params=Api_Material_Slot_Params,summary="The entity takes back everything of the material of a slot, and for the first slot its overlays. In Edit; one undo step.",result=Api_Material_Instance,writes_result=true,run=api_material_instance_revert})
    api_register(s,st,{name="material.instance.apply",params=Api_Material_Slot_Params,summary="Writes what the entity changes of the material of a slot into it for every entity that shows it (but what each changes itself), saves it at once and reverts the slot of the entity, in one undo step.",result=Api_Material_Result,writes_result=true,run=api_material_instance_apply})
}

@(private)
material_instance_entity :: proc(s:^Session,w:core.World_Ref,call:^api.Call,id:base.Entity_Id,slot:int) -> (e:core.Entity,ok:bool) {
    e=api_entity(w,id)
    if e==core.NONE || !entity_has(w,e,erender.Mesh_Renderer) {
        api.call_failf(call,api.INVALID_PARAMS,"entity 0x%016x is not an entity with a Mesh_Renderer in the scene",u64(id))
        return
    }
    mesh,_:=entity_get(w,e,erender.Mesh_Renderer)
    if slots:=appearance_read(s,w,e,mesh).slots;slot<0 || slot>=slots {
        api.call_failf(call,api.INVALID_PARAMS,"slot %d is not a slot of its mesh: give one from 0 to %d",slot,slots-1)
        return
    }
    return e,true
}

// The name of a value, a parameter or a texture of an override, as the API names it.
@(private)
override_label :: proc(program:^gpu.Program,name:u64) -> string {
    for standard in erender.MATERIAL_VALUE_NAMES {if base.name_hash(standard)==name {return standard}}
    for map_name in erender.MATERIAL_MAP_NAMES {if base.name_hash(map_name)==name {return map_name}}
    if program!=nil {
        for &parameter in program.parameters {if base.name_hash(parameter.name)==name {return parameter.name}}
    }
    return fmt.tprintf("0x%016x",name)
}

@(private)
material_instance_write :: proc(s:^Session,call:^api.Call,w:core.World_Ref,e:core.Entity,slot:int) {
    mesh,_:=entity_get(w,e,erender.Mesh_Renderer)
    a:=appearance_read(s,w,e,mesh,slot)
    given,_:=override_split(&a.override,slot)
    o:=&given
    out:=call.out
    serial.write_u8(out,'{')
    api.write_key(out,"id",first=true)
    api.write_id(out,api_entity_id(w,e))
    api.write_int(out,"slot",i64(slot))
    api.write_int(out,"slots",i64(a.slots))
    api.write_key(out,"material");api_asset_write(out,a.material)
    asset_values_write(out,"values",&a.values.info)
    api.write_key(out,"overrides")
    serial.write_u8(out,'[')
    first:=true
    for name in o.names[:min(int(o.count),len(o.names))] {
        if !first {serial.write_u8(out,',')}
        first=false
        serial.text_write_string(out,override_label(a.program,name))
    }
    for name in o.texture_names[:min(int(o.texture_count),len(o.texture_names))] {
        if !first {serial.write_u8(out,',')}
        first=false
        serial.text_write_string(out,override_label(a.program,name))
    }
    if o.own_overlays {
        if !first {serial.write_u8(out,',')}
        serial.text_write_string(out,"overlays")
    }
    serial.write_u8(out,']')
    if a.program!=nil {
        api.write_key(out,"parameters")
        serial.write_u8(out,'{')
        for &parameter,i in a.program.parameters {
            if i>0 {serial.write_u8(out,',')}
            serial.text_write_string(out,parameter.name)
            serial.write_u8(out,':')
            if parameter.kind==.Texture {
                texture,_:=erender.material_override_texture(o,slot,base.name_hash(parameter.name))
                api_asset_write(out,texture)
                continue
            }
            value:=gpu.program_parameter_get(&a.values.custom_params,&parameter)
            serial.write_u8(out,'[')
            for component in 0..<clamp(int(parameter.components),1,4) {
                if component>0 {serial.write_u8(out,',')}
                serial.text_write_float(out,transmute(u64)value[component],8)
            }
            serial.write_u8(out,']')
        }
        serial.write_u8(out,'}')
    }
    layers,count,_,_:=overlays_of(s,e)
    api.write_key(out,"overlays")
    serial.write_u8(out,'[')
    names:=OVERLAY_BLEND_NAMES
    for layer,i in layers[:count] {
        if i>0 {serial.write_u8(out,',')}
        serial.write_u8(out,'{')
        api.write_key(out,"material",first=true);api_asset_write(out,layer.material)
        api.write_text(out,"blend",names[layer.blend])
        api.write_key(out,"enabled");api.write_flag(out,layer.enabled)
        serial.write_u8(out,'}')
    }
    serial.write_u8(out,']')
    serial.write_u8(out,'}')
}

@(private)
api_material_instance_inspect :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Material_Slot_Params)
    w:=edited_world(s)
    if e,found:=material_instance_entity(s,w,call,p.entity,p.slot);found {material_instance_write(s,call,w,e,p.slot)}
}

@(private)
api_material_instance_set :: proc(s:^Session,call:^api.Call) {
    if watching(s) {
        api.call_fail(call,api.SERVER_ERROR,"Stop watching another run before editing the document")
        return
    }
    request:Rpc_Args
    rpc_init(&request,call,call.raw)
    if !rpc_object_begin(&request,"params") {return}
    fields:Rpc_Object
    id:base.Entity_Id
    values,parameters,textures,overlays:string
    has_id:bool
    slot:int
    for key in rpc_next(&request,&fields) {
        switch key {
        case "entity": id,has_id=rpc_id(&request,"entity")
        case "slot":
            number:=rpc_unsigned(&request,"slot") or_break
            slot=int(min(number,u64(erender.MATERIAL_SLOTS)))
        case "values": values,_=rpc_raw(&request)
        case "parameters": parameters,_=rpc_raw(&request)
        case "textures": textures,_=rpc_raw(&request)
        case "overlays": overlays,_=rpc_raw(&request)
        }
    }
    if request.failed {return}
    if !has_id {
        api.call_fail(call,api.INVALID_PARAMS,"entity is required")
        return
    }
    w:=edited_world(s)
    e,found:=material_instance_entity(s,w,call,id,slot)
    if !found {return}
    mesh,_:=entity_get(w,e,erender.Mesh_Renderer)
    a:=appearance_read(s,w,e,mesh,slot)
    next:=a.override
    material:=gpu.DEFAULT_MATERIAL
    if s.app.assets!=nil {material=host.assets_material_values(s.app.assets,a.row)}

    // The values it shows, with those given over them; what differs from the material is its own.
    if values!="" {
        shown:=a.values.info
        if !asset_values_read(call,values,&shown) {return}
        if !asset.material_check({info=&shown}) {
            api.call_fail(call,api.INVALID_PARAMS,"values: a number that is not finite or is outside its range")
            return
        }
        kept:=material.info
        kept.maps=shown.maps
        given:=gpu.Material_Desc{info=shown}
        for value in Material_Value {
            name:=material_value_name(value)
            now:=material_parameter_value(&given,nil,name)
            erender.material_standard_apply(&kept,name,now)
            if now==material_parameter_value(&material,nil,name) {
                erender.material_override_value_drop(&next,slot,name)
            } else if !erender.material_override_value_set(&next,slot,name,now) {
                api.call_failf(call,api.INVALID_PARAMS,"An entity changes up to %d values of its material",erender.MATERIAL_OVERRIDE_CAPACITY)
                return
            }
        }
        if kept!=shown {
            api.call_fail(call,api.INVALID_PARAMS,"values: only the values the inspector shows are of an entity (base_color, roughness, coat...); material.set changes the others, and textures go in textures")
            return
        }
    }

    if parameters!="" {
        r:Rpc_Args
        rpc_init(&r,call,parameters)
        if !rpc_object_begin(&r,"parameters") {return}
        object:Rpc_Object
        for key in rpc_next(&r,&object) {
            parameter:^gpu.Program_Parameter
            if a.program!=nil {
                for &candidate in a.program.parameters {if candidate.kind!=.Texture && candidate.name==key {parameter=&candidate}}
            }
            if parameter==nil {
                rpc_fail(&r,"parameters: %s is not a number of the Surface program of the material",key)
                break
            }
            name:=base.name_hash(parameter.name)
            if serial.text_keyword(&r.r,"null") {
                erender.material_override_value_drop(&next,slot,name)
                continue
            }
            value:[4]f32
            count:=clamp(int(parameter.components),1,4)
            if serial.text_peek(&r.r)=='[' {
                if !rpc_vector(&r,fmt.tprintf("parameters.%s",key),value[:count]) {break}
            } else if count==1 {
                value.x=rpc_number(&r,fmt.tprintf("parameters.%s",key)) or_break
            } else {
                rpc_fail(&r,"parameters.%s must be an array of %d numbers",key,count)
                break
            }
            if !erender.material_override_value_set(&next,slot,name,value) {
                rpc_fail(&r,"An entity changes up to %d values of its material",erender.MATERIAL_OVERRIDE_CAPACITY)
                break
            }
        }
        if r.failed {return}
    }

    if textures!="" {
        r:Rpc_Args
        rpc_init(&r,call,textures)
        if !rpc_object_begin(&r,"textures") {return}
        object:Rpc_Object
        for key in rpc_next(&r,&object) {
            name:=base.name_hash(key)
            known:=false
            for map_name in erender.MATERIAL_MAP_NAMES {known|=map_name==key}
            if a.program!=nil {
                for &parameter in a.program.parameters {known|=parameter.kind==.Texture && parameter.name==key}
            }
            if !known {
                rpc_fail(&r,"textures: %s is not a map (maps.base_color, maps.normal...) or a texture of the program of the material",key)
                break
            }
            if serial.text_keyword(&r.r,"null") {
                override_texture_put(&next,slot,name,{},false)
                continue
            }
            buffer:[API_PATH_BYTES]u8
            text:=rpc_text(&r,fmt.tprintf("textures.%s",key),buffer[:]) or_break
            texture:base.Asset_Id
            if text!="" {
                named:bool
                if texture,named=asset_named(s,call,text,asset.KIND_TEXTURE,".tex","a texture");!named {return}
            }
            if !override_texture_put(&next,slot,name,texture,true) {
                rpc_fail(&r,"An entity changes up to %d textures of its material",erender.MATERIAL_OVERRIDE_TEXTURES)
                break
            }
        }
        if r.failed {return}
    }

    if overlays!="" {
        r:Rpc_Args
        rpc_init(&r,call,overlays)
        if serial.text_keyword(&r.r,"null") {
            next.own_overlays,next.overlay_count,next.overlays=false,0,{}
        } else {
            if !serial.text_accept(&r.r,'[') {
                api.call_fail(call,api.INVALID_PARAMS,"overlays must be an array or null")
                return
            }
            list:[asset.MATERIAL_MAX_OVERLAYS]asset.Material_Overlay
            count:=0
            for !serial.text_accept(&r.r,']') {
                if count>0 && !serial.text_accept(&r.r,',') {
                    rpc_fail(&r,"overlays must be an array of objects")
                    break
                }
                if count>=len(list) {
                    rpc_fail(&r,"An entity shows up to %d overlays",len(list))
                    break
                }
                layer:=asset.Material_Overlay{id=u32(count+1),blend=.Alpha,enabled=true}
                if !rpc_object_begin(&r,"an overlay") {break}
                object:Rpc_Object
                for key in rpc_next(&r,&object) {
                    switch key {
                    case "material":
                        buffer:[API_PATH_BYTES]u8
                        text:=rpc_text(&r,"overlays.material",buffer[:]) or_break
                        named:bool
                        if layer.material,named=asset_named(s,call,text,asset.KIND_MATERIAL,".mat","a material");!named {return}
                    case "blend":
                        buffer:[16]u8
                        text:=rpc_text(&r,"overlays.blend",buffer[:]) or_break
                        known:=false
                        for name,blend in OVERLAY_BLEND_NAMES {
                            if name==text {layer.blend,known=blend,true}
                        }
                        if !known {rpc_fail(&r,"overlays.blend must be Alpha, Additive or Multiply")}
                    case "enabled": layer.enabled=rpc_bool(&r,"overlays.enabled") or_break
                    case: rpc_fail(&r,"overlays: %s is not a field: material, blend, enabled",key)
                    }
                }
                if r.failed {break}
                if layer.material=={} || layer.material==a.material {
                    rpc_fail(&r,"overlays: each one names a material other than the one the entity shows")
                    break
                }
                list[count]=layer
                count+=1
            }
            if r.failed {return}
            next.own_overlays,next.overlay_count,next.overlays=true,u32(count),list
        }
    }

    if !api_edit_begin(s,call,"Material") {return}
    w=edited_world(s)
    table:=core.world_table_of(w,erender.Material_Override)
    if table==nil {api_edit_end(s,call,false);return}
    if erender.material_override_empty(&next) {
        if core.has(table,e) {core.remove(table,e)}
    } else {
        core.add(table,e,next)
    }
    if !api_edit_end(s,call,true) {return}
    material_instance_write(s,call,edited_world(s),e,slot)
}

@(private)
api_material_instance_revert :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Material_Slot_Params)
    w:=edited_world(s)
    e,found:=material_instance_entity(s,w,call,p.entity,p.slot)
    if !found {return}
    if !api_edit_begin(s,call,"Revert material") {return}
    w=edited_world(s)
    if table:=core.world_table_of(w,erender.Material_Override);table!=nil {
        if override,overridden:=core.get(core.read(table),e);overridden {
            _,rest:=override_split(&override,p.slot)
            if erender.material_override_empty(&rest) {core.remove(table,e)} else {core.add(table,e,rest)}
        }
    }
    if !api_edit_end(s,call,true) {return}
    material_instance_write(s,call,edited_world(s),e,p.slot)
}

@(private)
api_material_instance_apply :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Material_Slot_Params)
    e,found:=material_instance_entity(s,edited_world(s),call,p.entity,p.slot)
    if !found {return}
    if !api_edit_begin(s,call,"Apply to material") {return}
    material,message:=material_apply(s,e,p.slot)
    if message!="" {api.call_fail(call,material=={}?api.INVALID_PARAMS:api.SERVER_ERROR,message)}
    if !api_edit_end(s,call,material!={}) {return}
    api_material_write(s,call,material)
}
