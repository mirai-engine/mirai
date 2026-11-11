package editor

import "mirai:core"
import erender "mirai:engine/render"
import "mirai:host"
import gpu "mirai:render"
import "mirai:std/base"
import "mirai:ui"

material_parameter_value :: proc(v:^gpu.Material_Desc,program:^gpu.Program,name:u64) -> [4]f32 {
    if standard:[4]f32;erender.material_standard_value(&v.info,name,&standard,false) {return standard}
    if program!=nil {
        for &parameter in program.parameters {
            if base.name_hash(parameter.name)!=name {continue}
            value:=gpu.program_parameter_get(&v.custom_params,&parameter)
            return {f32(value[0]),f32(value[1]),f32(value[2]),f32(value[3])}
        }
    }
    return {}
}

// What the prefab of an entity gives it of its material: its reference. None out of a prefab.
@(private)
material_inherited :: proc(s:^Session,w:core.World_Ref,e:core.Entity) -> (inherited:erender.Material_Values) {
    inherited=erender.MATERIAL_VALUES_DEFAULT
    c:=inspect_component(s,w,erender.Material_Values,{e})
    if c.t!=nil {inherited=(cast(^erender.Material_Values)raw_data(inspect_default(s,w,c.t,e)))^}
    return
}

// The texture a map or a texture of the program of a slot goes back to: the
// prefab's, when it gives one, else the material's.
@(private)
texture_reference :: proc(s:^Session,e:core.Entity,slot:int,name:u64,material_texture:base.Asset_Id) -> (texture:base.Asset_Id,inherited:bool) {
    given:=material_inherited(s,editing_world(s),e)
    if texture,inherited=erender.material_texture_of(&given,slot,name);inherited {return}
    return material_texture,false
}

material_reset_button :: proc(s:^Session,p:Material_Color) {
    w:=editing_world(s)
    mesh,ok:=entity_get(w,p.entity,erender.Mesh_Renderer)
    if !ok {return}
    a:=appearance_read(s,w,p.entity,mesh,p.slot)
    values:=gpu.DEFAULT_MATERIAL
    if s.app.assets!=nil {values=host.assets_material_values(s.app.assets,a.row)}
    inherited:=material_inherited(s,w,p.entity)
    tint:=inherited
    for name,index in inherited.names[:min(int(inherited.count),len(inherited.names))] {
        if int(inherited.slots[index])==p.slot {erender.material_value_apply(&values,a.program,name,inherited.values[index])}
    }
    current,default_value:=material_parameter_value(&a.values,a.program,p.name),material_parameter_value(&values,a.program,p.name)
    changed:=current!=default_value
    if p.tint {changed=false}
    if p.tint || p.standard {
        changed|=p.emission?a.override.emission!=tint.emission:a.override.color.rgb!=tint.color.rgb
    }
    ctx:=s.gui.ctx
    if !changed {ui.spacer(ctx,REVERT_SIDE,1);return}
    if !ui.button(ctx,ui.id(ctx,"material_reset",int((p.name~u64(p.emission))&0x7fffffff)),{icon=.Revert,icon_size=12,icon_color=ctx.theme.text_muted,style=.Ghost,width=REVERT_SIDE,height=REVERT_SIDE}).clicked {return}
    opened,edit_ready:=edit_open(s,"Revert material value")
    if !edit_ready {return}
    defer edit_close(s,opened)
    if !p.tint {
        next:=a.override
        at:=erender.material_value_find(&next,p.slot,p.name)
        source:=erender.material_value_find(&inherited,p.slot,p.name)
        if source>=0 {override_store(s,p.entity,p.slot,p.name,inherited.values[source])} else if at>=0 {
            erender.material_value_drop(&next,p.name,p.slot)
            override_put(s,p.entity,next,"Revert material value")
        }
    }
    if p.tint || p.standard {tint_store(s,p.entity,p.emission,p.emission?tint.emission:tint.color.rgb)}
}
