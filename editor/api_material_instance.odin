package editor

import "base:runtime"
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
// the material of a slot of its mesh, its Material_Values, as the inspector
// edits it.

@(private)
Api_Material_Slot_Params :: struct {
    entity:Api_Entity_Text `mirai:"text,entity"`,
    slot:int `mirai:"optional,min=0,label=The slot of its mesh, from 0"`,
}

@(private)
Api_Material_Instance :: struct {
    id:base.Entity_Id,
    slot:int,
    slots:int `mirai:"label=The slots of its mesh"`,
    material:base.Asset_Id `mirai:"label=The material of the slot"`,
    values:asset.Material_Info `mirai:"label=The values of its material with those of the entity over them"`,
    overrides:[]string `mirai:"label=What the entity changes: values; maps; parameters and textures of the program by name; and overlays"`,
    parameters:serial.Json `mirai:"optional,label=Of the Surface program of its material by name: a list of the numbers it shows; or the id of the texture the entity gives it (all zeros: none)"`,
    overlays:[]Api_Material_Instance_Overlay `mirai:"label=The layers it shows over the material of its first slot"`,
}

@(private)
Api_Material_Instance_Overlay :: struct {
    material:base.Asset_Id,
    blend:asset.Overlay_Blend,
    enabled:bool,
}

Api_Material_Instance_Set_Params :: struct {
    entity:Api_Entity_Text `mirai:"text,entity,label=The entity with the Mesh_Renderer"`,
    slot:int `mirai:"optional,min=0,label=The slot of its mesh whose material the values, parameters and textures are of, from 0; 0 when omitted"`,
    values:serial.Json `mirai:"optional,label=Values it shows, as material.instance.inspect gives them: those that differ from its material become its own"`,
    parameters:serial.Json `mirai:"optional,label=Numbers of the Surface program of its material for this entity, by name, as 1 to 4 numbers; null takes one away"`,
    textures:serial.Json `mirai:"optional,label=Textures for this entity by a map (maps.base_color, maps.normal...) or a texture of the program: a texture by path or id, '' for none, null takes it away"`,
    overlays:[]Api_Material_Overlay_Param `mirai:"optional,label=Layers in place of those of its material; null gives back those of the material"`,
}
Api_Material_Overlay_Param :: struct {
    material:string `mirai:"label=A material other than the one it is drawn over, by its path or id"`,
    blend:asset.Overlay_Blend `mirai:"optional"`,
    enabled:bool,
}

@(private)
material_instance_api_register :: proc(s:^Session,st:^Api_State) {
    api_register(s,st,{name="material.instance.inspect",params=type_info_of(Api_Material_Slot_Params),summary="What an entity shows of the material of a slot of its mesh: its values with those of the entity over them, what the entity changes of it, its parameters and its overlays.",result=type_info_of(Api_Material_Instance),flags={.Read_Only},run=api_material_instance_inspect})
    api_register(s,st,{name="material.instance.set",params=type_info_of(Api_Material_Instance_Set_Params),summary="Makes the values given that differ from the material of the slot, and the parameters, textures and overlays given, the entity's own; the material does not change. In Edit; one undo step.",result=type_info_of(Api_Material_Instance),run=api_material_instance_set})
    api_register(s,st,{name="material.instance.revert",params=type_info_of(Api_Material_Slot_Params),summary="The entity takes back everything of the material of a slot, and for the first slot its overlays. In Edit; one undo step.",result=type_info_of(Api_Material_Instance),run=api_material_instance_revert})
    api_register(s,st,{name="material.instance.apply",params=type_info_of(Api_Material_Slot_Params),summary="Writes what the entity changes of the material of a slot into it for every entity that shows it (but what each changes itself) and reverts the slot of the entity, in one undo step. The material changes in memory: asset.save writes its file.",result=type_info_of(Api_Material_Result),run=api_material_instance_apply})
}

@(private)
material_instance_entity :: proc(s:^Session,w:core.World_Ref,call:^api.Call,text:[]u8,slot:int) -> (e:core.Entity,ok:bool) {
    e=api_call_entity(call,w,text) or_return
    if !entity_has(w,e,erender.Mesh_Renderer) {
        api.call_failf(call,api.INVALID_PARAMS,"entity %q has no Mesh_Renderer",base.text_get(text))
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
    for standard in erender.MATERIAL_VALUE_FIELDS {if base.name_hash(standard.name)==name {return standard.name}}
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
    r:=api.call_result(call,Api_Material_Instance)
    r.id,r.slot,r.slots,r.material=api_entity_id(w,e),slot,a.slots,a.material
    r.values=a.values.info
    overrides:=make([dynamic]string,call.allocator)
    for name in o.names[:min(int(o.count),len(o.names))] {append(&overrides,override_label(a.program,name))}
    for name in o.texture_names[:min(int(o.texture_count),len(o.texture_names))] {append(&overrides,override_label(a.program,name))}
    if o.own_overlays {append(&overrides,"overlays")}
    r.overrides=overrides[:]
    if a.program!=nil {
        out:serial.Writer
        serial.writer_init(&out,256,call.allocator)
        serial.write_u8(&out,'{')
        for &parameter,i in a.program.parameters {
            if i>0 {serial.write_u8(&out,',')}
            serial.text_write_string(&out,parameter.name)
            serial.write_u8(&out,':')
            if parameter.kind==.Texture {
                texture,_:=erender.material_texture_of(o,slot,base.name_hash(parameter.name))
                api_asset_write(&out,texture)
                continue
            }
            value:=gpu.program_parameter_get(&a.values.custom_params,&parameter)
            serial.write_u8(&out,'[')
            for component in 0..<clamp(int(parameter.components),1,4) {
                if component>0 {serial.write_u8(&out,',')}
                serial.text_write_float(&out,transmute(u64)value[component],8)
            }
            serial.write_u8(&out,']')
        }
        serial.write_u8(&out,'}')
        r.parameters=serial.Json(serial.writer_bytes(&out))
    }
    layers,count,_,_:=overlays_of(s,e)
    r.overlays=api_overlays(layers[:count],call.allocator)
}

// The layers drawn over a material, as a result lists them.
@(private)
api_overlays :: proc(layers:[]asset.Material_Overlay,allocator:runtime.Allocator) -> []Api_Material_Instance_Overlay {
    overlays:=make([]Api_Material_Instance_Overlay,len(layers),allocator)
    for layer,i in layers {overlays[i]={layer.material,layer.blend,layer.enabled}}
    return overlays
}

@(private)
api_material_instance_inspect :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Material_Slot_Params)
    w:=edited_world(s)
    if e,found:=material_instance_entity(s,w,call,p.entity[:],p.slot);found {material_instance_write(s,call,w,e,p.slot)}
}

@(private)
api_material_instance_set :: proc(s:^Session,call:^api.Call) {
    if watching(s) {
        api.call_fail(call,api.SERVER_ERROR,"Stop watching another run before editing the document")
        return
    }
    p:=api.call_params(call,Api_Material_Instance_Set_Params)
    slot:=min(p.slot,erender.MATERIAL_SLOTS)
    values,parameters,textures:=string(p.values),string(p.parameters),string(p.textures)
    w:=edited_world(s)
    e,found:=material_instance_entity(s,w,call,p.entity[:],slot)
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
            erender.material_standard_value(&kept,name,&now,true)
            if now==material_parameter_value(&material,nil,name) {
                erender.material_value_drop(&next,name,slot)
            } else if !erender.material_value(&next,name,now,slot) {
                api.call_failf(call,api.INVALID_PARAMS,"An entity changes up to %d values of its material",erender.MATERIAL_VALUES_CAPACITY)
                return
            }
        }
        if kept!=shown {
            api.call_fail(call,api.INVALID_PARAMS,"values: only the values the inspector shows are of an entity (base_color, roughness, coat...); material.set changes the others, and textures go in textures")
            return
        }
    }

    if !material_given_read(s,call,a.program,a.material,slot,parameters,textures,p.overlays,&next,"An entity changes") {return}

    if !api_edit_begin(s,call,"Material") {return}
    w=edited_world(s)
    table:=core.world_table_of(w,erender.Material_Values)
    if table==nil {api_edit_end(s,call,false);return}
    if erender.material_values_plain(&next) {
        if core.has(table,e) {core.remove(table,e)}
    } else {
        core.add(table,e,next)
    }
    if !api_edit_end(s,call,true) {return}
    material_instance_write(s,call,edited_world(s),e,slot)
}

// What a call gives a material by name, into next for a slot: numbers of its
// Surface program (parameters), its maps and the textures of its program
// (textures), and the layers drawn over it (overlays; null in the params
// gives back those below). material: the one they are given to, which no
// layer names. who: whose limits the errors name
// ("An entity changes", "material.set takes"). False when the call failed.
@(private)
material_given_read :: proc(s:^Session,call:^api.Call,program:^gpu.Program,material:base.Asset_Id,slot:int,parameters,textures:string,overlays:[]Api_Material_Overlay_Param,next:^erender.Material_Values,who:string) -> bool {
    if parameters!="" {
        r:Rpc_Args
        rpc_init(&r,call,parameters)
        if !rpc_object_begin(&r,"parameters") {return false}
        object:Rpc_Object
        for key in rpc_next(&r,&object) {
            parameter:^gpu.Program_Parameter
            if program!=nil {
                for &candidate in program.parameters {if candidate.kind!=.Texture && candidate.name==key {parameter=&candidate}}
            }
            if parameter==nil {
                rpc_fail(&r,"parameters: %s is not a number of the Surface program of the material",key)
                break
            }
            name:=base.name_hash(parameter.name)
            if serial.text_keyword(&r.r,"null") {
                erender.material_value_drop(next,name,slot)
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
            if !erender.material_value(next,name,value,slot) {
                rpc_fail(&r,"%s up to %d values of a material",who,erender.MATERIAL_VALUES_CAPACITY)
                break
            }
        }
        if r.failed {return false}
    }

    if textures!="" {
        r:Rpc_Args
        rpc_init(&r,call,textures)
        if !rpc_object_begin(&r,"textures") {return false}
        object:Rpc_Object
        for key in rpc_next(&r,&object) {
            name:=base.name_hash(key)
            known:=false
            for map_name in erender.MATERIAL_MAP_NAMES {known|=map_name==key}
            if program!=nil {
                for &parameter in program.parameters {known|=parameter.kind==.Texture && parameter.name==key}
            }
            if !known {
                rpc_fail(&r,"textures: %s is not a map (maps.base_color, maps.normal...) or a texture of the program of the material",key)
                break
            }
            if serial.text_keyword(&r.r,"null") {
                erender.material_texture_drop(next,name,slot)
                continue
            }
            buffer:[API_PATH_BYTES]u8
            text:=rpc_text(&r,fmt.tprintf("textures.%s",key),buffer[:]) or_break
            texture:base.Asset_Id
            if text!="" {
                named:bool
                if texture,named=asset_named(s,call,text,asset.KIND_TEXTURE,".tex","a texture");!named {return false}
            }
            if !erender.material_texture(next,name,slot,texture) {
                rpc_fail(&r,"%s up to %d textures of a material",who,erender.MATERIAL_VALUES_TEXTURES)
                break
            }
        }
        if r.failed {return false}
    }

    switch api.json_member(call.raw,"overlays") {
    case "":
    case "null": next.own_overlays,next.overlay_count,next.overlays=false,0,{}
    case:
        if len(overlays)>asset.MATERIAL_MAX_OVERLAYS {
            api.call_failf(call,api.INVALID_PARAMS,"%s up to %d overlays",who,asset.MATERIAL_MAX_OVERLAYS)
            return false
        }
        list:[asset.MATERIAL_MAX_OVERLAYS]asset.Material_Overlay
        for &given,i in overlays {
            layer:=asset.Material_Overlay{id=u32(i+1),blend=given.blend,enabled=given.enabled}
            named:bool
            if layer.material,named=asset_named(s,call,given.material,asset.KIND_MATERIAL,".mat","a material");!named {return false}
            if layer.material==material {
                api.call_failf(call,api.INVALID_PARAMS,"overlays[%d]: each one names a material other than the one it is drawn over",i)
                return false
            }
            list[i]=layer
        }
        next.own_overlays,next.overlay_count,next.overlays=true,u32(len(overlays)),list
    }
    return true
}

@(private)
api_material_instance_revert :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Material_Slot_Params)
    w:=edited_world(s)
    e,found:=material_instance_entity(s,w,call,p.entity[:],p.slot)
    if !found {return}
    if !api_edit_begin(s,call,"Revert material") {return}
    w=edited_world(s)
    if table:=core.world_table_of(w,erender.Material_Values);table!=nil {
        if override,overridden:=core.get(core.read(table),e);overridden {
            _,rest:=override_split(&override,p.slot)
            if erender.material_values_plain(&rest) {core.remove(table,e)} else {core.add(table,e,rest)}
        }
    }
    if !api_edit_end(s,call,true) {return}
    material_instance_write(s,call,edited_world(s),e,p.slot)
}

@(private)
api_material_instance_apply :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Material_Slot_Params)
    e,found:=material_instance_entity(s,edited_world(s),call,p.entity[:],p.slot)
    if !found {return}
    if !api_edit_begin(s,call,"Apply to material") {return}
    material,message:=material_apply(s,e,p.slot)
    if message!="" {api.call_fail(call,material=={}?api.INVALID_PARAMS:api.SERVER_ERROR,message)}
    if !api_edit_end(s,call,material!={}) {return}
    api_material_write(s,call,material)
}
