package animation_editor

import "core:fmt"
import "mirai:asset"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import erender "mirai:engine/render"
import "mirai:std/base"
import "mirai:std/serial"
import anim "plugins:animation/runtime"

Morph_Inspect_Params :: struct {entity:editor.Api_Entity_Text `mirai:"text,entity"`,handle:core.Entity `mirai:"transient"`,offset:u32 `mirai:"optional"`,limit:u32 `mirai:"optional,min=1,max=256,clamp"`,diagnostics:bool `mirai:"optional"`}
Morph_Set_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity"`,
    name:[64]u8 `mirai:"text,label=A target of the mesh; an instance weights up to 16"`,
    value:f32 `mirai:"optional,label=Any finite weight"`,
    mode:anim.Morph_Weight_Mode `mirai:"optional"`,
    remove:bool `mirai:"optional,label=Gives the target back to the mesh and the animation; it also clears a weight that names no target"`,
}
Morph_Source_Kind :: enum u8 {None,Explicit,Pose_Source,Ancestor,Own} // Own: a rig that follows another of another skeleton, whose curves it takes
Morph_Target_Result :: struct {
    name:[64]u8 `mirai:"text"`,
    mesh_default,default_value,final_weight:f32,
    evaluated,controlled:bool,
    mode:anim.Morph_Weight_Mode,
    value:f32,
    curve:[328]u8 `mirai:"text"`,
}
Morph_Unresolved_Result :: struct {name_hash:u64,value:f32,mode:anim.Morph_Weight_Mode}
Morph_Diagnostic_Result :: struct {error:anim.Morph_Error,unknown:u16,pending:bool,problems:[PREVIEW_PROBLEMS]Problem_Result `mirai:"label=What its morph weights reported in its world; the most recent first"`,problems_total:u32}
Morph_Set_Result :: struct {id:base.Entity_Id,name:[64]u8 `mirai:"text"`,value:f32,mode:anim.Morph_Weight_Mode,removed:bool}

@(private)
morph_register :: proc(s:^editor.Session) {
    inspect:=Morph_Inspect_Params{limit=256}
    set:=Morph_Set_Params{mode=.Override}
    editor.api_method_register(s,{name="animation.morph.set",summary="Sets the weight of a morph target of a mesh instance by name. One step of undo in Edit; Play and Simulation change only the running world.",params=Morph_Set_Params,params_info=type_info_of(Morph_Set_Params),result=Morph_Set_Result,result_info=type_info_of(Morph_Set_Result),defaults=&set,run=morph_set})
}

@(private)
morph_mesh_open :: proc(s:^editor.Session,call:^api.Call,w:core.World_Ref,e:core.Entity,file:^asset.Asset) -> (view:asset.Mesh_View,id:base.Asset_Id,ok:bool) {
    mesh,present:=editor.entity_get(w,e,erender.Mesh_Renderer)
    if !present || mesh.mesh=={} {authoring_failure(call,"entity","Missing_Mesh","an entity with a Mesh_Renderer and a mesh asset","missing mesh","Select the mesh instance whose targets should be weighted");return}
    if !asset_open(s,call,mesh.mesh,file) {return}
    error:asset.Error;view,error=asset.mesh_view(file,&s.app.assets.types)
    if error!=.None {authoring_failure(call,"mesh","Invalid_Asset","a valid .mesh asset",fmt.tprintf("%v",error),"The mesh asset is invalid");return}
    return view,mesh.mesh,true
}

@(private)
morph_entity_id :: proc(w:core.World_Ref,e:core.Entity) -> base.Entity_Id {value,present:=editor.entity_get(w,e,core.Id);return value.value if present else 0}

@(private)
morph_instance_source :: proc(w:core.World_Ref,e:core.Entity,config:anim.Morph_Weights) -> (core.Entity,Morph_Source_Kind) {
    animations,sources,parents:=core.world_table_of(w,anim.Animation),core.world_table_of(w,anim.Pose_Source),core.world_table_of(w,core.Parent)
    if animations==nil || sources==nil || parents==nil {return core.NONE,.None}
    source:=anim.morph_source(e,config,core.read(animations),core.read(sources),core.read(parents),core.world_storage_of(w,anim.Playback))
    if source==core.NONE {return source,.None}
    if config.source!=core.NONE {return source,.Explicit}
    if source==e {return source,.Own}
    return source,.Pose_Source if core.has(core.read(sources),e) else .Ancestor
}

@(private)
morph_inspect :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Morph_Inspect_Params)
    w,e,okay:=subject(s,call,p.entity[:],p.handle);if !okay {return}
    file:asset.Asset;defer asset.asset_close(&file)
    view,id,loaded:=morph_mesh_open(s,call,w,e,&file);if !loaded {return}
    config,_:=editor.entity_get(w,e,anim.Morph_Weights)
    stamp:u64
    if configs:=core.world_table_of(w,anim.Morph_Weights);configs!=nil {if row:=core.row_of(core.read(configs),e);row>=0 {stamp=core.stamp(core.read(configs),row)+1}}
    source,kind:=morph_instance_source(w,e,config)
    path:=base.text_get(config.path[:]);if path=="" {if target,present:=editor.entity_get(w,e,anim.Animation_Target);present {path=base.text_get(target.path[:])}}
    state,available:=anim.animation_morph_state(core.world_storage_of(w,anim.Morph_Playback),e)
    error,unknown:=anim.morph_weights_check(config,view.morphs)
    evaluated:=available && state.mesh==id && state.stamp==stamp && len(state.weights)==len(view.morphs) && error!=.Invalid_Weights
    out:=call.out;serial.text_write_raw(out,"{");api.write_key(out,"id",true);api.write_id(out,editor.api_entity_id(w,e))
    api.write_key(out,"mesh");serial.write_u8(out,'"');serial.text_write_asset_id(out,id);serial.write_u8(out,'"')
    api.write_key(out,"source");api.write_id(out,morph_entity_id(w,source))
    api.write_key(out,"source_kind");authoring_write_value(call,&kind,type_info_of(Morph_Source_Kind))
    api.write_text(out,"path",path);api.write_uint(out,"total",u64(len(view.morphs)))
    api.write_key(out,"targets");serial.write_u8(out,'[')
    first:=min(int(p.offset),len(view.morphs));last:=min(first+int(p.limit),len(view.morphs))
    for &target,i in view.morphs[first:last] {
        name:=base.text_get(target.name[:])
        row:=Morph_Target_Result{name=target.name,mesh_default=target.weight,default_value=target.weight,evaluated=evaluated}
        if error!=.Invalid_Weights {for entry,j in config.names {if entry!=0 && entry==base.name_hash(name) {
            row.controlled,row.mode,row.value=true,config.modes[j],config.values[j]
            if row.mode==.Default {row.default_value=row.value}
            break
        }}}
        row.final_weight=state.weights[first+i] if evaluated else row.default_value
        n:=copy(row.curve[:],path);n+=copy(row.curve[n:],"/@morph/");copy(row.curve[n:],name)
        if i>0 {serial.write_u8(out,',')};authoring_write_value(call,&row,type_info_of(Morph_Target_Result))
    }
    serial.write_u8(out,']')
    if p.diagnostics {
        diagnostic:=Morph_Diagnostic_Result{error=error,unknown=unknown,pending=!evaluated}
        _,problems_total:=entity_problems(s.app,w,e,"animation.morph",diagnostic.problems[:]);diagnostic.problems_total=u32(problems_total)
        if evaluated && (state.error==.Out_Of_Memory || state.error==.Invalid_Value) {diagnostic.error=state.error}
        api.write_key(out,"diagnostic");authoring_write_value(call,&diagnostic,type_info_of(Morph_Diagnostic_Result))
        api.write_key(out,"unresolved");serial.write_u8(out,'[');written:=0
        for entry,j in config.names {
            if entry==0 {continue}
            known:=false;for &target in view.morphs {known ||= base.name_hash(base.text_get(target.name[:]))==entry}
            if known {continue}
            value:=Morph_Unresolved_Result{entry,config.values[j],config.modes[j]}
            if written>0 {serial.write_u8(out,',')};authoring_write_value(call,&value,type_info_of(Morph_Unresolved_Result));written+=1
        }
        serial.write_u8(out,']')
    }
    serial.write_u8(out,'}')
}

@(private)
morph_set :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Morph_Set_Params)
    if editor.watching(s) {authoring_failure(call,"mode","Edit_Blocked","Edit, Play or Simulation","Watch","A watched world cannot be changed",fix="Stop watching the run first");return}
    name:=base.text_get(p.name[:])
    if name=="" {authoring_failure(call,"name","Required","the name of a target","empty","Use animation.inspect parts Morphs to choose a target by name");return}
    if !finite(p.value) || p.mode>max(anim.Morph_Weight_Mode) {authoring_failure(call,"value","Invalid_Value","a finite weight and a valid mode",fmt.tprintf("%v",p.value),"The target weight or mode is invalid");return}
    w,e,okay:=subject(s,call,p.entity[:]);if !okay {return}
    table:=core.world_table_of(w,anim.Morph_Weights)
    if table==nil {authoring_failure(call,"Morph_Weights","Unavailable","the Morph_Weights table","missing table","The project does not have the animation plugin's morph weights",api.SERVER_ERROR);return}
    config,present:=editor.entity_get(w,e,anim.Morph_Weights)
    before:=config
    file:asset.Asset;defer asset.asset_close(&file)
    view,_,loaded:=morph_mesh_open(s,call,w,e,&file);if !loaded {return}
    if error,_:=anim.morph_weights_check(config,view.morphs);error==.Invalid_Weights {authoring_failure(call,"Morph_Weights","Invalid_Weights","unique names, finite values and valid modes","invalid saved weights","Correct the instance's Morph_Weights before changing a target");return}
    key:=base.name_hash(name)
    declared:=false
    for &target in view.morphs {declared ||= base.text_get(target.name[:])==name}
    if !declared && p.remove {for entry in config.names {declared ||= entry==key}}
    if !declared {authoring_failure(call,"name","Unknown_Target","a name animation.inspect parts Morphs lists",name,"The mesh has no target with this name; inspect its targets and use an exact name");return}
    if p.remove {anim.morph_weight_clear(&config,name)} else if !anim.morph_weight_set(&config,name,p.value,p.mode) {
        authoring_failure(call,"name","Capacity",fmt.tprintf("at most %d weighted targets per instance",asset.MORPH_WEIGHTS),name,"Remove the weight of another target first");return
    }
    changed:=config!=before || !present && !p.remove
    if !edit_begin(s,call,"Set morph weight") {return}
    if changed {core.add(table,e,config)}
    if !edit_end(s,call,w,true) {return}
    api.call_result(call,Morph_Set_Result)^={id=editor.api_entity_id(w,e),name=p.name,value=p.value,mode=p.mode,removed=p.remove}
}
