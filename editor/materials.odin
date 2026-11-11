package editor

import "core:fmt"
import "core:math"
import "core:mem"
import "core:slice"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import "mirai:editor/history"
import erender "mirai:engine/render"
import "mirai:host"
import gpu "mirai:render"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:editor/kit"
import "mirai:ui"

// The material of a Mesh_Renderer in the inspector: a box with its preview and
// its name, which opens the list it is chosen from, and an arrow that unfolds
// what this entity shows of it: values, textures and the layers drawn over it.
// Those live in the entity, as its Material_Values: the inspector never
// edits the material there. Apply to material writes them in
// the file of the material, for every entity that shows it.

MATERIAL_ROW :: f32(26)
SECTION_MATERIAL :: "material parameters"
MAP_LABELS :: [asset.Material_Map_Kind]string{
    .Base_Color="Color map",.Metallic_Roughness="Metallic roughness map",.Normal="Normal map",.Emission="Emission map",
    .Occlusion="Occlusion map",.Specular="Specular map",.Specular_Color="Specular color map",.Coat="Coat map",
    .Coat_Roughness="Coat roughness map",.Coat_Normal="Coat normal map",.Fuzz_Color="Fuzz color map",
    .Fuzz_Roughness="Fuzz roughness map",.Anisotropy="Anisotropy map",
    .Diffuse_Transmission="Transmission map",.Diffuse_Transmission_Color="Transmission color map",
}
TEXTURE_PARAMETER :: 100 // the index of the row of a texture of a program starts here; below it, a map of MAP_LABELS plus one
OVERLAY_BLEND_NAMES :: [asset.Overlay_Blend]string{.Alpha="Alpha",.Additive="Additive",.Multiply="Multiply"}
ALPHA_MODE_NAMES :: [asset.Alpha_Mode]string{.Opaque="Opaque",.Mask="Mask",.Blend="Blend"}
EMISSION_MODE_NAMES :: [asset.Emission_Mode]string{.Physical="Nits",.Relative="Exposure"}
MATERIAL_LIST_ROWS :: 8

// The values of the standard model an entity gives its material, in the order of erender.MATERIAL_VALUE_FIELDS.
Material_Value :: enum u8 {
    Base_Color,Opacity,Metallic,Roughness,Emission,Specular,Ior,Transmission,Alpha_Mode,
    Coat,Coat_Roughness,Coat_Color,Coat_Ior,Fuzz,Fuzz_Color,Fuzz_Roughness,Anisotropy,Anisotropy_Rotation,Unlit,
    Emission_Mode,Diffuse_Transmission,Diffuse_Transmission_Color,
}
#assert(len(Material_Value)==len(erender.MATERIAL_VALUE_FIELDS))

Material_List_Kind :: enum u8 {None,Material,Overlay,Texture,Asset}

// The list of assets open for a slot of the material, a layer, a texture or
// an asset field of a component (asset_list_open).
Material_List :: struct {
    kind:Material_List_Kind,
    asset:asset.Fourcc, // Asset: the kind it lists
    none:[32]u8,        // Asset: the first row, the zero id
    table:int,         // Material, Asset: of the world info
    offset:int,        // Material, Asset: of the field in the component; Overlay: the id of the layer, 0 for a new one; Texture: the index of its row
    owner:base.Asset_Id, // Overlay, Texture: the material that owns the layers or the slot
    entity:core.Entity,  // Overlay, Texture: the one that takes it
    name:u64,            // Texture: as Material_Values names it
    slot:int,            // Texture: of the mesh whose material it is of
    scroll:f32,
}

// The color picker open for a value of the instance of a material.
Material_Color :: struct {
    key:u64,       // 0: closed
    entity:core.Entity,
    slot:int,      // of the mesh whose material the value is of
    name:u64,      // of the value or the parameter
    tint:bool,     // the color or the light of the entity instead of a value of a slot
    standard:bool, // base color or emission of the standard model
    emission:bool,
    alpha:f32,     // a fourth channel of a parameter is kept
    intensity:f64,
    state:kit.Color_Picker,
}

@(storage,free="materials_free")
Materials :: struct {
    list:Material_List,
    color:Material_Color,
    document:Material_Document,
    pending:Material_Pending,
    preview:Material_Preview,
    imported:Material_Base,
}

// What the source of the material Details or the material document shows
// gave at the last import, read from its file when the registry has another
// content for it. The two never show at once.
Material_Base :: struct {
    material:base.Asset_Id,
    content:u64,   // the content_hash of its file in the registry when it was read
    info:asset.Material_Info,
    imported:bool, // the file has it
}

// The preview of the material document: a shape in the studio with its
// material, seen by a camera of its own.
Material_Preview :: struct {
    image:Asset_Image,
    camera:Asset_View,
    material:base.Asset_Id, // the one it shows
    mesh:[dynamic]gpu.Thumbnail_Vertex, // of mesh_shape
    mesh_shape:Material_Shape,
    drawn:[1]gpu.Material_Desc, // what the frame draws the shape with
}

// A material a gesture of the material document changes in memory: its row
// shows every value at once, and its file takes them when the gesture ends.
Material_Pending :: struct {
    key:u64, // of the gesture; 0: none
    material:base.Asset_Id,
}

materials_free :: proc(m:^Materials) {
    material_document_unload(&m.document)
    material_variants_free(&m.document)
    asset_image_free(&m.preview.image)
    delete(m.preview.mesh)
    m^={}
}

// What an entity shows in a slot of its mesh.
@(private)
Appearance :: struct {
    entity:core.Entity,
    slot:int,
    material:base.Asset_Id,      // 0: the default material
    row:u32,                     // of the material in the table of the renderer
    values:gpu.Material_Desc,    // of the material, with those of the entity over them
    override:erender.Material_Values, // of the entity; the default without them
    program:^gpu.Program,        // the Surface program of the material; nil: the standard model
    slots:int,                   // of its mesh
}

@(private)
material_value_name :: proc(value:Material_Value) -> u64 {
    fields:=erender.MATERIAL_VALUE_FIELDS
    return base.name_hash(fields[int(value)].name)
}

// What an entity changes of the material of one slot, its values and
// textures and, for the first, the overlays drawn over it; and the rest.
@(private)
override_split :: proc "contextless" (o:^erender.Material_Values,slot:int) -> (given,rest:erender.Material_Values) {
    given,rest=erender.MATERIAL_VALUES_DEFAULT,erender.MATERIAL_VALUES_DEFAULT
    rest.color,rest.emission=o.color,o.emission
    for name,i in o.names[:min(int(o.count),len(o.names))] {
        to:=int(o.slots[i])==slot?&given:&rest
        to.slots[to.count],to.names[to.count],to.values[to.count]=o.slots[i],name,o.values[i]
        to.count+=1
    }
    for name,i in o.texture_names[:min(int(o.texture_count),len(o.texture_names))] {
        to:=int(o.texture_slots[i])==slot?&given:&rest
        to.texture_slots[to.texture_count],to.texture_names[to.texture_count],to.textures[to.texture_count],to.shown[to.texture_count]=o.texture_slots[i],name,o.textures[i],o.shown[i]
        to.texture_count+=1
    }
    to:=slot==0?&given:&rest
    to.own_overlays,to.overlay_count,to.overlays=o.own_overlays,o.overlay_count,o.overlays
    return
}

@(private)
value_key :: proc "contextless" (e:core.Entity,slot:int,name:u64,axis:int=0) -> u64 {
    return base.hash_combine(base.hash_combine(u64(e),name),u64(axis)<<1|u64(slot)<<8)|1
}

// What an entity shows of its materials: its Material_Values, the default without them.
entity_material_values :: proc(w:core.World_Ref,e:core.Entity) -> erender.Material_Values {
    if values,ok:=entity_get(w,e,erender.Material_Values);ok {return values}
    return erender.MATERIAL_VALUES_DEFAULT
}

@(private)
appearance_read :: proc(s:^Session,w:core.World_Ref,e:core.Entity,mesh:erender.Mesh_Renderer,slot:=0) -> (a:Appearance) {
    a.entity,a.slot,a.slots,a.material=e,slot,1,mesh.materials[slot]
    a.values=gpu.DEFAULT_MATERIAL
    assets:=s.app.assets
    if assets!=nil {
        if mesh.mesh!={} {
            if loaded:=host.assets_mesh(assets,mesh.mesh);loaded!=nil {
                a.slots=clamp(int(loaded.slot_count),1,erender.MATERIAL_SLOTS)
                if a.material=={} && slot<int(loaded.slot_count) {a.material=loaded.slot_materials[slot]}
            }
        }
        a.row=host.assets_material_row(assets,a.material)
        a.values=host.assets_material_values(assets,a.row)
        a.program=erender.surface_program(assets,a.values.program_id)
    }
    a.override=entity_material_values(w,e)
    if assets!=nil {erender.material_values_apply(assets,&a.values,&a.override,slot)}
    return
}

// ---------------------------------------------------------------- edits of the instance

// Gives the entity a value of its own for the material of a slot.
@(private)
override_store :: proc(s:^Session,e:core.Entity,slot:int,name:u64,value:[4]f32) -> bool {
    next:=entity_material_values(editing_world(s),e)
    if !erender.material_value(&next,name,value,slot) {
        notify(s,fmt.tprintf("An entity changes up to %d values of its material",erender.MATERIAL_VALUES_CAPACITY))
        return false
    }
    return override_put(s,e,next,"Material")
}

// What an entity changes of its material, as one step: no component when it changes nothing.
@(private)
override_put :: proc(s:^Session,e:core.Entity,next:erender.Material_Values,label:string) -> bool {
    w:=editing_world(s)
    table:=core.world_table_of(w,erender.Material_Values)
    if table==nil || !entity_alive(w,e) {return false}
    opened,edit_ready:=edit_open(s,label)
    if !edit_ready {return false}
    defer edit_close(s,opened)
    next:=next
    if erender.material_values_plain(&next) {
        if core.has(table,e) {core.remove(table,e)}
    } else {
        core.add(table,e,next)
    }
    return true
}

// Gives the entity a texture of its own for a map or a texture of the program
// of the material of a slot, or takes it away (put false).
@(private)
texture_override_store :: proc(s:^Session,e:core.Entity,slot:int,name:u64,texture:base.Asset_Id,put:=true) -> bool {
    next:=entity_material_values(editing_world(s),e)
    if !put {
        erender.material_texture_drop(&next,name,slot)
    } else if !erender.material_texture(&next,name,slot,texture) {
        notify(s,fmt.tprintf("An entity changes up to %d textures of its material",erender.MATERIAL_VALUES_TEXTURES))
        return false
    }
    return override_put(s,e,next,"Material")
}

// Writes the color or the light of the entity over its materials.
@(private)
tint_store :: proc(s:^Session,e:core.Entity,emission:bool,value:[3]f32) -> bool {
    w:=editing_world(s)
    table:=core.world_table_of(w,erender.Material_Values)
    if table==nil || !entity_alive(w,e) {return false}
    next:=erender.MATERIAL_VALUES_DEFAULT
    if row,ok:=core.get(core.read(table),e);ok {next=row}
    if emission {next.emission=value} else {next.color.rgb=value}
    opened,edit_ready:=edit_open(s,"Color")
    if !edit_ready {return false}
    defer edit_close(s,opened)
    core.add(table,e,next)
    return true
}

// The color or the emission of the standard model as the entity draws it in
// a mesh of one slot: the value is stored whole and the tint stops changing it.
@(private)
material_color_store :: proc(s:^Session,e:core.Entity,slot:int,emission:bool,value:[3]f32) -> bool {
    w:=editing_world(s)
    opened,edit_ready:=edit_open(s,"Material")
    if !edit_ready {return false}
    defer edit_close(s,opened)
    ok:=override_store(s,e,slot,material_value_name(emission?.Emission:.Base_Color),{value.x,value.y,value.z,0})
    if tint,found:=entity_get(w,e,erender.Material_Values);ok && found {
        neutral:=emission?tint.emission==[3]f32{}:tint.color.rgb==[3]f32{1,1,1}
        if !neutral {ok=tint_store(s,e,emission,emission?[3]f32{}:[3]f32{1,1,1})}
    }
    return ok
}

// Gives back to the material of a slot every value the entity had for it.
@(private)
material_revert :: proc(s:^Session,e:core.Entity,slot:int) -> bool {
    override,overridden:=entity_get(editing_world(s),e,erender.Material_Values)
    if !overridden {return false}
    _,rest:=override_split(&override,slot)
    return override_put(s,e,rest,"Revert material")
}

// Writes in the material of a slot what the entity changed of it, which it
// stops changing: every entity that shows the material takes it, but in what
// it changes itself. The material changes in memory, as every edit does:
// Save writes its file. One step.
@(private)
material_apply :: proc(s:^Session,e:core.Entity,slot:int) -> (material:base.Asset_Id,message:string) {
    w:=editing_world(s)
    override:=entity_material_values(w,e)
    mesh,meshed:=entity_get(w,e,erender.Mesh_Renderer)
    if !meshed || s.app.assets==nil {return {},"The entity shows no mesh"}
    given,rest:=override_split(&override,slot)
    if erender.material_values_plain(&given) {return {},"The entity changes nothing of the material of that slot"}
    material=slot<erender.MATERIAL_SLOTS?mesh.materials[slot]:{}
    if material=={} && mesh.mesh!={} {
        if loaded:=host.assets_mesh(s.app.assets,mesh.mesh);loaded!=nil && slot<int(loaded.slot_count) {material=loaded.slot_materials[slot]}
    }
    if _,found:=asset.registry_find(&s.app.assets.registry,material);!found {return {},"The default material has no file: give the entity a material to apply to"}
    opened,edit_ready:=edit_open(s,"Apply to material")
    if !edit_ready {return {},history.edits_error_text(s.edits.error)}
    defer edit_close(s,opened)
    if !material_write(s,material,{kind=.Override,override=&given}) {return {},"The material could not be written"}
    table:=core.world_table_of(w,erender.Material_Values)
    if erender.material_values_plain(&rest) {core.remove(table,e)} else {core.add(table,e,rest)}
    return material,""
}

// ---------------------------------------------------------------- previews

// The studio sphere of a material of the project; of the default one for the zero id.
@(private)
material_quad :: proc(s:^Session,id:base.Asset_Id) -> ui.Quad {
    if s.app.assets==nil || s.app.assets.renderer==nil {return {}}
    return ui.quad_whole(host.UI_QUAD_MATERIAL_PREVIEW,host.assets_material_row(s.app.assets,id))
}

// The image of a texture the renderer has; none without it.
@(private)
texture_quad :: proc(s:^Session,texture:base.Asset_Id) -> ui.Quad {
    a:=s.app.assets
    if texture=={} || a==nil || a.renderer==nil {return {}}
    loaded:=host.assets_texture(a,texture)
    if loaded==nil || loaded.failed || loaded.handle==0 {return {}}
    image:=gpu.ui_image(a.renderer,loaded.handle)
    if image==0 {return {}}
    return ui.quad_whole(.Image,image&~gpu.UI_MATERIAL_IMAGE_BIT)
}

// The name of a texture as its slot shows it: its file, without the extension.
@(private)
texture_label :: proc(path:string) -> string {
    name:=path[strings.last_index_byte(path,'/')+1:]
    if dot:=strings.last_index_byte(name,'.');dot>=0 {return name[:dot]}
    return name
}

asset_label_of :: proc(s:^Session,id:base.Asset_Id,none:string) -> string {
    if id=={} {return none}
    path:=asset_path(s,id)
    if path=="" {return "Missing"}
    return asset_name(path)
}

// ---------------------------------------------------------------- rows

@(private)
appearance_swatch :: proc(s:^Session,label:string,index:int,linear:[3]f32,p:Material_Color) {
    ctx:=s.gui.ctx
    row_begin(ctx,label)
    id:=ui.id(ctx,"color",index)
    if kit.color_swatch(ctx,id,swatch_color(linear),s.materials.color.key==p.key).clicked && s.materials.color.key!=p.key {
        rect,_:=ui.widget_rect(ctx,id)
        material_picker_open(s,p,linear,rect)
    }
    material_reset_button(s,p)
    row_end(ctx)
}

@(private)
override_number_row :: proc(s:^Session,a:^Appearance,label:string,value:Material_Value,shown:f32,low:f64=0,high:f64=1,degrees:=false) {
    ctx:=s.gui.ctx
    name:=material_value_name(value)
    row_begin(ctx,label)
    scale:=f64(mm.DEG_PER_RAD) if degrees else 1
    number:=f64(shown)*scale
    field:=ui.Number_Field{decimals=3,speed=0.005,has_min=true,has_max=true,min=low*scale,max=high*scale,height=24}
    if degrees {field.decimals,field.speed=1,0.2}
    r:=kit.slider_field(ctx,ui.id(ctx,"value",int(value)+1),&number,field)
    key:=value_key(a.entity,a.slot,name)
    gesture_follow(s,key,r,"Material")
    if r.changed {override_store(s,a.entity,a.slot,name,{f32(number/scale),0,0,0})}
    if r.ended {gesture_end(s,key)}
    material_reset_button(s,{entity=a.entity,slot=a.slot,name=name})
    row_end(ctx)
}

// A value of the entity that is one of a few choices (alpha mode, unlit,
// emission mode), stored as the index of the choice.
@(private)
choice_row :: proc(s:^Session,a:^Appearance,label:string,value:Material_Value,names:[]string,current:int) {
    ctx:=s.gui.ctx
    name:=material_value_name(value)
    row_begin(ctx,label)
    for choice,i in names {
        if ui.button(ctx,ui.id(ctx,label,i+1),{label=choice,size=ui.metric(ctx,"font_small"),variant="tab",width=-1,center=true,active=current==i}).clicked && current!=i {
            override_store(s,a.entity,a.slot,name,{f32(i),0,0,0})
        }
    }
    material_reset_button(s,{entity=a.entity,slot=a.slot,name=name})
    row_end(ctx)
}

@(private)
alpha_row :: proc(s:^Session,a:^Appearance) {
    names:=ALPHA_MODE_NAMES
    choice_row(s,a,"Alpha",.Alpha_Mode,slice.enumerated_array(&names),int(a.values.alpha_mode))
}

// A texture the entity shows as a row: its slot shows the one of the entity,
// or the material's, and opens the list another is chosen from. Its arrow,
// while it differs, gives back the reference: the texture of the prefab, or
// the one of the material.
@(private)
texture_row :: proc(c:^Inspect,a:^Appearance,label:string,index:int,name:u64,material_texture:base.Asset_Id) {
    s:=c.s
    ctx:=s.gui.ctx
    texture:=material_texture
    if own,found:=erender.material_texture_of(&a.override,a.slot,name);found {texture=own}
    reference,inherited:=texture_reference(s,a.entity,a.slot,name,material_texture)
    shown:="None"
    if texture!={} {
        if path:=asset_path(s,texture);path!="" {shown=texture_label(path)} else {shown="Missing"}
    }
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(MATERIAL_ROW),gap=4,align_y=.Center}) {
        kit.column_label(ctx,label)
        l:=&s.materials.list
        open:=l.kind==.Texture && l.entity==a.entity && l.slot==a.slot && l.offset==index
        button:=ui.Button{label=shown,variant="field",width=-1,height=MATERIAL_ROW,size=ui.metric(ctx,"font_small"),active=open}
        button.quad=texture_quad(s,texture)
        if button.quad.kind==.Solid {button.icon=.Texture}
        id:=ui.id(ctx,"texture",index)
        if ui.button(ctx,id,button).clicked && !open {
            anchor,_:=ui.widget_rect(ctx,id)
            material_list_open(s,{kind=.Texture,owner=a.material,offset=index,entity=a.entity,slot=a.slot,name=name},anchor)
        }
        if texture!=reference && ui.button(ctx,ui.id(ctx,"texture_reset",index),{icon=.Revert,variant="ghost",width=22,height=22}).clicked {
            texture_override_store(s,a.entity,a.slot,name,reference,inherited)
        }
    }
}

// The parameters of the program of a material, under its name. Numbers and
// colors are values of the entity; a texture shows what the material has.
@(private)
program_rows :: proc(c:^Inspect,a:^Appearance) {
    s:=c.s
    ctx:=s.gui.ctx
    program:=a.program
    if len(program.parameters)==0 {return}
    kit.section(ctx,strings.to_upper(program.name,context.temp_allocator))
    stored:[]asset.Material_Parameter
    if material:=host.assets_material(s.app.assets,a.material);material!=nil {stored=host.assets_material_parameters(s.app.assets,material)}
    for &parameter,index in program.parameters {
        label:=readable(parameter.name)
        name:=base.name_hash(parameter.name)
        if parameter.kind==.Texture {
            texture:base.Asset_Id
            for &value in stored {
                if value.overlay==0 && value.kind==.Texture && base.text_get(value.name[:])==parameter.name {texture=value.texture}
            }
            texture_row(c,a,label,TEXTURE_PARAMETER+index,name,texture)
            continue
        }
        count:=clamp(int(parameter.components),1,4)
        numbers:=gpu.program_parameter_get(&a.values.custom_params,&parameter)
        current:=[4]f32{f32(numbers[0]),f32(numbers[1]),f32(numbers[2]),f32(numbers[3])}
        switch {
        case parameter.kind==.Bool:
            row_begin(ctx,label)
            letters:=[4]string{"X","Y","Z","W"}
            for axis in 0..<count {
                on:=numbers[axis]!=0
                text:=on?"On":"Off"
                if count>1 {text=fmt.tprintf("%s %s",letters[axis],text)}
                if ui.button(ctx,ui.id(ctx,"toggle",index*4+axis+1),{label=text,variant="tab",size=ui.metric(ctx,"font_small"),width=-1,center=true,active=on}).clicked {
                    next:=current
                    next[axis]=on?0:1
                    override_store(s,a.entity,a.slot,name,next)
                }
            }
            material_reset_button(s,{entity=a.entity,slot=a.slot,name=name})
            row_end(ctx)
        case parameter.color && count>=3:
            appearance_swatch(s,label,100+index,current.xyz,{key=value_key(a.entity,a.slot,name),entity=a.entity,slot=a.slot,name=name,alpha=current.w})
        case:
            field:=ui.Number_Field{integer=parameter.kind!=.Float,speed=parameter.kind!=.Float?0.05:0.02}
            if parameter.min<parameter.max {
                field.has_min,field.has_max,field.min,field.max=true,true,parameter.min,parameter.max
                if !field.integer {field.speed=max((parameter.max-parameter.min)/200,1e-4)}
            }
            row_begin(ctx,label)
            results:[4]ui.Number_Result
            axes:=[4]f64{numbers[0],numbers[1],numbers[2],numbers[3]}
            if count==1 {
                results[0]=kit.slider_field(ctx,ui.id(ctx,"parameter",index+1),&axes[0],field)
            } else {
                results=number_fields(ctx,ui.id(ctx,"parameter",index+1),axes[:count],{number=field})
            }
            for r,axis in results[:count] {
                if r=={} {continue}
                key:=value_key(a.entity,a.slot,name,axis)
                gesture_follow(s,key,r,label)
                if r.changed {
                    next:=current
                    next[axis]=f32(axes[axis])
                    override_store(s,a.entity,a.slot,name,next)
                }
                if r.ended {gesture_end(s,key)}
            }
            material_reset_button(s,{entity=a.entity,slot=a.slot,name=name})
            row_end(ctx)
        }
    }
}

// One number field per value, as kit.vector_field builds them, keeping what
// every axis did: Tab ends the edit of one and begins that of the next in the
// same frame, and both have to be heard.
@(private)
number_fields :: proc(ctx:^ui.Context,id:ui.Id,values:[]f64,field:kit.Vector_Field={}) -> (results:[4]ui.Number_Result) {
    names:=field.channels?kit.CHANNEL_NAMES:kit.AXIS_NAMES
    count:=min(len(values),4)
    ui.id_push(ctx,id)
    defer ui.id_pop(ctx)
    for i in 0..<count {
        one:=field.number
        one.label=names[i]
        one.strip=field.channels?ui.tone(ctx,kit.CHANNEL_TOKENS[i]):ui.tone(ctx,kit.AXIS_TOKENS[i])
        one.mixed=field.mixed_axes[i] || field.number.mixed
        results[i]=ui.number_field(ctx,ui.id(ctx,"axis",i+1),&values[i],one)
        if results[i].tab>0 && i+1<count {ui.edit_request(ctx,ui.id(ctx,"axis",i+2))}
        if results[i].tab<0 && i>0 {ui.edit_request(ctx,ui.id(ctx,"axis",i))}
    }
    return
}

// The color and the light of the entity, which tint every slot of its mesh and add to its emission.
@(private)
tint_rows :: proc(s:^Session,a:^Appearance,color,emission:string) {
    tint_name:=base.name_hash("Tint")
    appearance_swatch(s,color,1,a.override.color.rgb,{key=value_key(a.entity,0,tint_name),entity=a.entity,tint=true})
    appearance_swatch(s,emission,2,a.override.emission,{key=value_key(a.entity,0,tint_name,1),entity=a.entity,tint=true,emission=true})
}

// The values of the entity's instance of the material of a slot.
@(private)
material_parameters :: proc(c:^Inspect,a:^Appearance) {
    s:=c.s
    values:=&a.values
    // The slots of a model share the color of the entity, shown once over them; one slot shows it in its colors.
    shared:=a.slots>1
    if a.program!=nil {
        // A program keeps its colors: the entity tints them and adds its emission.
        if !shared {tint_rows(s,a,"Tint","Emission")}
        program_rows(c,a)
        return
    }
    info:^asset.Material_Info
    if s.app.assets!=nil {
        if material:=host.assets_material(s.app.assets,a.material);material!=nil && !material.failed {info=&material.info}
    }
    color,emission:=values.base_color,values.emission
    if !shared {color,emission=color*a.override.color.rgb,emission+a.override.emission}
    appearance_swatch(s,"Color",1,color,{key=value_key(a.entity,a.slot,material_value_name(.Base_Color)),entity=a.entity,slot=a.slot,name=material_value_name(.Base_Color),standard=!shared})
    map_row(c,a,info,.Base_Color)
    appearance_swatch(s,"Emission",2,emission,{key=value_key(a.entity,a.slot,material_value_name(.Emission)),entity=a.entity,slot=a.slot,name=material_value_name(.Emission),standard=!shared,emission=true})
    map_row(c,a,info,.Emission)
    emission_names:=EMISSION_MODE_NAMES
    choice_row(s,a,"Emission in",.Emission_Mode,slice.enumerated_array(&emission_names),int(values.emission_mode))
    if values.alpha_mode!=.Opaque {override_number_row(s,a,"Opacity",.Opacity,values.opacity)}
    // An unlit material shows its emission alone: the values of light do not apply.
    choice_row(s,a,"Unlit",.Unlit,{"Off","On"},int(values.unlit))
    if values.unlit {
        alpha_row(s,a)
        return
    }
    override_number_row(s,a,"Metallic",.Metallic,values.metallic)
    override_number_row(s,a,"Roughness",.Roughness,values.roughness)
    override_number_row(s,a,"Specular",.Specular,values.specular_factor)
    if values.alpha_mode!=.Mask {override_number_row(s,a,"Transmission",.Transmission,values.transmission)}
    if values.alpha_mode!=.Mask && values.transmission>0 {override_number_row(s,a,"IOR",.Ior,values.ior,1,3)}
    alpha_row(s,a)
    for kind in ([?]asset.Material_Map_Kind{.Metallic_Roughness,.Normal,.Occlusion,.Specular,.Specular_Color}) {map_row(c,a,info,kind)}
    override_number_row(s,a,"Coat",.Coat,values.coat.weight)
    if values.coat.weight>0 {
        map_row(c,a,info,.Coat)
        override_number_row(s,a,"Coat roughness",.Coat_Roughness,values.coat.roughness)
        map_row(c,a,info,.Coat_Roughness)
        coat_color:=material_value_name(.Coat_Color)
        appearance_swatch(s,"Coat color",3,values.coat.color,{key=value_key(a.entity,a.slot,coat_color),entity=a.entity,slot=a.slot,name=coat_color})
        override_number_row(s,a,"Coat IOR",.Coat_Ior,values.coat.ior,1,3)
        map_row(c,a,info,.Coat_Normal)
    }
    override_number_row(s,a,"Fuzz",.Fuzz,values.fuzz.weight)
    if values.fuzz.weight>0 {
        fuzz_color:=material_value_name(.Fuzz_Color)
        appearance_swatch(s,"Fuzz color",4,values.fuzz.color,{key=value_key(a.entity,a.slot,fuzz_color),entity=a.entity,slot=a.slot,name=fuzz_color})
        map_row(c,a,info,.Fuzz_Color)
        override_number_row(s,a,"Fuzz roughness",.Fuzz_Roughness,values.fuzz.roughness)
        map_row(c,a,info,.Fuzz_Roughness)
    }
    override_number_row(s,a,"Anisotropy",.Anisotropy,values.anisotropy.amount)
    if values.anisotropy.amount>0 {
        override_number_row(s,a,"Anisotropy rotation",.Anisotropy_Rotation,values.anisotropy.rotation,-math.PI,math.PI,degrees=true)
        map_row(c,a,info,.Anisotropy)
    }
    override_number_row(s,a,"Transmission",.Diffuse_Transmission,values.diffuse_transmission.weight)
    if values.diffuse_transmission.weight>0 {
        map_row(c,a,info,.Diffuse_Transmission)
        transmission_color:=material_value_name(.Diffuse_Transmission_Color)
        appearance_swatch(s,"Transmission color",5,values.diffuse_transmission.color,{key=value_key(a.entity,a.slot,transmission_color),entity=a.entity,slot=a.slot,name=transmission_color})
        map_row(c,a,info,.Diffuse_Transmission_Color)
    }
}

// A map of the material file, as the entity shows it; nothing while the file is not loaded.
@(private)
map_row :: proc(c:^Inspect,a:^Appearance,info:^asset.Material_Info,kind:asset.Material_Map_Kind) {
    if info==nil {return}
    labels:=MAP_LABELS
    names:=erender.MATERIAL_MAP_NAMES
    texture_row(c,a,labels[kind],int(kind)+1,base.name_hash(names[kind]),asset.material_maps(&info.maps)[kind].texture)
}


// The box of a material, or of an asset a plugin shows the same way, as a
// field of an asset: its thumbnail in the color of its kind, its name that
// opens the list it is chosen from and the magnifier that shows it in the
// content browser; revert, when given, gives the values of the entity back to
// the asset. value: the asset it shows; quad: its preview while it has none.
// dropped: an asset of its kind let go on it.
asset_box :: proc(s:^Session,name:string,index:int,label:string,quad:ui.Quad,open:bool,revert:^bool=nil,kind:=asset.KIND_MATERIAL,value:=base.Asset_Id{}) -> (clicked:bool,anchor:ui.Rect,dropped:base.Asset_Id) {
    ctx:=s.gui.ctx
    box:=ui.id(ctx,name,index)
    asset_field_thumbnail(s,ui.id_derive(ctx,box,"thumb"),kind,value,MATERIAL_ROW,quad if value=={} else {})
    hot:=ctx.hot==ui.id_derive(ctx,box,"pick") || ctx.hot==ui.id_derive(ctx,box,"arrow")
    fill,stroke,faded:=asset_field_drop_look(s,box,{0=kind})
    if fill[3]==0 {fill=ui.tone(ctx,"well")}
    if stroke[3]==0 {stroke=ui.tone(ctx,"accent") if open else (ui.tone(ctx,"well_stroke_hover") if hot else ui.tone(ctx,"well_stroke"))}
    appearance:=ui.Node_Style{radius=ui.metric(ctx,"radius_control"),text={size=ui.metric(ctx,"font_small"),color=ui.tone(ctx,"text")}}
    if ui.box(ctx,{id=box,width=ui.GROW,height=ui.fixed(MATERIAL_ROW),align_y=.Center,fill=fill,stroke=stroke,radius=ui.metric(ctx,"radius_control"),track=true,layer={enabled=faded,opacity=0.45}}) {
        ui.id_push(ctx,box)
        clicked=ui.button(ctx,ui.id(ctx,"pick"),{label=label,width=-1,height=MATERIAL_ROW,size=ui.metric(ctx,"font_small"),padding=7,active=open,look=&appearance}).clicked
        clicked|=ui.button(ctx,ui.id(ctx,"arrow"),{icon=.Chevron_Down,icon_size=13,icon_color=ui.tone(ctx,"text_muted"),width=18,height=MATERIAL_ROW,active=open,look=&appearance}).clicked
        if revert!=nil {revert^=ui.button(ctx,ui.id(ctx,"revert"),{icon=.Revert,variant="ghost",width=22,height=22}).clicked}
        ui.id_pop(ctx)
    }
    asset_field_find(s,ui.id_derive(ctx,box,"find"),value)
    anchor,_=ui.widget_rect(ctx,box)
    if id,ok:=asset_field_dropped(s,box,{0=kind},asset_kind_label(s,kind));ok {dropped=id}
    return clicked && !open,anchor,dropped
}

// The id of the material every selected entity has in a slot; same is false when they differ.
@(private)
material_common :: proc(c:^Inspect,offset:int) -> (material:base.Asset_Id,same:bool) {
    material=(cast(^base.Asset_Id)rawptr(uintptr(c.value)+uintptr(offset)))^
    same=true
    for e in c.entities {
        value:=core.raw_find(c.table,c.t.info,e)
        if value==nil {continue}
        if (cast(^base.Asset_Id)rawptr(uintptr(value)+uintptr(offset)))^!=material {same=false}
    }
    return
}

// The rows of Mesh_Renderer under its geometry: a material per slot and, for
// one entity, the values of its instance under each slot and the layers of the material.
@(private)
material_rows :: proc(c:^Inspect) {
    s:=c.s
    ctx:=s.gui.ctx
    ins:=s.inspector
    single:=len(c.entities)==1 && len(s.selection.entities)==1
    active:=single?c.entities[0]:core.NONE
    value:=(cast(^erender.Mesh_Renderer)c.value)^
    a:=appearance_read(s,c.w,active,value)
    slots:=single?a.slots:1
    if slots>1 {tint_rows(s,&a,"Tint","Tint emission")}
    for slot in 0..<slots {
        offset:=int(offset_of(erender.Mesh_Renderer,materials))+slot*size_of(base.Asset_Id)
        material,same:=material_common(c,offset)
        shown:=material
        if shown=={} && value.mesh!={} && s.app.assets!=nil {
            if loaded:=host.assets_mesh(s.app.assets,value.mesh);loaded!=nil && slot<int(loaded.slot_count) {shown=loaded.slot_materials[slot]}
        }
        label:="Multiple"
        quad:ui.Quad
        if same {
            label=asset_label_of(s,shown,"Default")
            quad=material_quad(s,shown)
        }
        key:=material_slot_key(slot)
        unfolded:=single && inspector_section_open(ins,key,true)
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(MATERIAL_ROW),gap=4,align_y=.Center}) {
            name:=slots>1?fmt.tprintf("Material %d",slot+1):"Material"
            // The label folds the parameters under the row, with the arrow after it.
            if single {
                if fold_label(s,ui.id(ctx,"parameters",slot),name,unfolded) {inspector_section_toggle(ins,key)}
            } else {
                ui.label(ctx,name,ui.metric(ctx,"font_small"),ui.tone(ctx,"text_label"),ui.metric(ctx,"label_width"))
            }
            l:=&s.materials.list
            open:=l.kind==.Material && l.table==c.index && l.offset==offset
            clicked,anchor,dropped:=asset_box(s,"material",slot+1,label,quad,open,value=shown if same else {})
            if clicked {material_list_open(s,{kind=.Material,table=c.index,offset=offset},anchor)}
            if dropped!={} {inspect_write(c,offset,mem.ptr_to_bytes(&dropped))}
            field_reset_button(c,offset,size_of(base.Asset_Id))
        }
        if !unfolded {continue}
        ui.id_push(ctx,ui.id(ctx,"slot",slot))
        defer ui.id_pop(ctx)
        if fold_band(s) {
            shown_slot:=slot==0?a:appearance_read(s,c.w,active,value,slot)
            material_parameters(c,&shown_slot)
            if given,_:=override_split(&shown_slot.override,slot);!erender.material_values_plain(&given) {
                if ui.box(ctx,{width=ui.GROW,height=ui.fixed(24),gap=4,align_y=.Center}) {
                    if ui.button(ctx,ui.id(ctx,"material_apply"),{label="Apply to material",icon=.Check,icon_size=13,variant="ghost",width=-1,height=24,size=ui.metric(ctx,"font_small")}).clicked {
                        if _,message:=material_apply(s,active,slot);message!="" {notify(s,message)}
                    }
                    if ui.button(ctx,ui.id(ctx,"material_revert"),{label="Revert material changes",icon=.Revert,icon_size=13,variant="ghost",width=-1,height=24,size=ui.metric(ctx,"font_small")}).clicked {material_revert(s,active,slot)}
                }
            }
        }
    }
    if !single {return}
    overlay_rows(c,&a)
}

// The key of the open state of the parameters under a slot of the materials.
@(private)
material_slot_key :: proc(slot:int) -> u64 {
    key:=base.name_hash(SECTION_MATERIAL)
    return slot==0?key:base.hash_combine(key,u64(slot))
}

// ---------------------------------------------------------------- the file of a material

// What a row of the inspector changes in the file of a material. Loaded: the
// values and parameters the material holds in memory.
Material_Change :: struct {
    kind:enum u8 {Overlays,Map,Parameter,Values,Value,Loaded,Revert,Override,Set},
    overlays:[]asset.Material_Overlay, // Overlays: all of them
    slot:int,              // Map: of MAP_LABELS
    name:string,           // Parameter: a texture of the program; Value: a number of it
    texture:base.Asset_Id, // Map, Parameter: 0 takes it away
    info:asset.Material_Info, // Values, Set: all of them
    value:[4]f64,          // Value: its components
    parameter:asset.Parameter_Kind,
    components:u8,
    paths:[]string,        // Revert: the fields that take what the source gave (asset.material_revert); none: all
    override:^erender.Material_Values, // Override: what an entity changes of the material; Set: what a call gives it by name, over info
}

// The entities of the scene that show a material in some slot: theirs, or the one their mesh came with.
material_users :: proc(s:^Session,w:core.World_Ref,material:base.Asset_Id) -> (count:int) {
    t:=core.world_table_of(w,erender.Mesh_Renderer)
    if t==nil || material=={} {return}
    each: for mesh in t.values[:core.count(t)] {
        slots:=1
        loaded:^host.Assets_Mesh
        if s.app.assets!=nil && mesh.mesh!={} {
            if loaded=host.assets_mesh(s.app.assets,mesh.mesh);loaded!=nil {slots=clamp(int(loaded.slot_count),1,erender.MATERIAL_SLOTS)}
        }
        for slot in 0..<slots {
            shown:=mesh.materials[slot]
            if shown=={} && loaded!=nil {shown=loaded.slot_materials[slot]}
            if shown==material {
                count+=1
                continue each
            }
        }
    }
    return
}

// Writes the file of a material with a change and loads it again. The
// parameters stored for a layer that is gone go with it.
material_write :: proc(s:^Session,owner:base.Asset_Id,change:Material_Change) -> bool {
    a:=s.app.assets
    if a==nil || owner=={} {return false}
    record,found:=asset.registry_find(&a.registry,owner)
    if !found {return false}
    // The record is replaced when the file changes.
    relative:=strings.clone(record.path,context.temp_allocator)
    path:=asset.registry_file_path(&a.registry,relative,context.temp_allocator)
    file:asset.Asset
    if !asset_read(s,relative,&file) {return false}
    view,error:=asset.material_view(&file,&a.types)
    if error!=.None {
        asset.asset_close(&file)
        return false
    }
    info:=view.info^
    overlays:=make([]asset.Material_Overlay,len(view.overlays),context.temp_allocator)
    copy(overlays,view.overlays)
    hidden:=make([]asset.Material_Name,len(view.hidden),context.temp_allocator)
    copy(hidden,view.hidden)
    source:asset.Import_Info
    imported:=view.source!=nil
    if imported {source=view.source^}
    // What the source gave stays: only an import writes it.
    base_values:asset.Material_Info
    based:=view.imported!=nil
    if based {base_values=view.imported^}
    base_parameters:=make([]asset.Material_Parameter,len(view.imported_parameters),context.temp_allocator)
    copy(base_parameters,view.imported_parameters)
    reverted:asset.Material_Info
    revert_error:=asset.Error.None
    if change.kind==.Revert {reverted,_,revert_error=asset.material_revert(&a.types,view,change.paths)}
    parameters:=make([dynamic]asset.Material_Parameter,0,len(view.parameters)+1,context.temp_allocator)
    append(&parameters,..view.parameters)
    asset.asset_close(&file)
    switch change.kind {
    case .Overlays:
        overlays=change.overlays
        overlay_parameters_keep(&parameters,overlays)
    case .Override,.Set:
        o:=change.override
        program:=erender.surface_program(a,host.assets_material_values(a,host.assets_material_row(a,owner)).program_id)
        // The parameters are of the program the values of the call name.
        if change.kind==.Set {
            info=change.info
            program=erender.program_find(a,base.text_get(info.program[:]),.Surface)
        }
        values: for name,i in o.names[:min(int(o.count),len(o.names))] {
            if program!=nil {
                for &parameter in program.parameters {
                    if parameter.kind==.Texture || base.name_hash(parameter.name)!=name {continue}
                    value:=o.values[i]
                    parameter_value_set(&parameters,parameter.name,asset.Parameter_Kind(parameter.kind),parameter.components,{f64(value.x),f64(value.y),f64(value.z),f64(value.w)})
                    continue values
                }
            }
            erender.material_standard_value(&info,name,&o.values[i],true)
        }
        maps:=erender.MATERIAL_MAP_NAMES
        textures: for name,i in o.texture_names[:min(int(o.texture_count),len(o.texture_names))] {
            for map_name,kind in maps {
                if base.name_hash(map_name)!=name {continue}
                asset.material_maps(&info.maps)[kind].texture=o.textures[i]
                continue textures
            }
            if program==nil {continue}
            for &parameter in program.parameters {
                if parameter.kind==.Texture && base.name_hash(parameter.name)==name {parameter_texture_set(&parameters,parameter.name,o.textures[i])}
            }
        }
        if o.own_overlays {
            overlays=o.overlays[:min(int(o.overlay_count),len(o.overlays))]
            overlay_parameters_keep(&parameters,overlays)
        }
    case .Values:
        info=change.info
    case .Map:
        if change.slot<0 || change.slot>=len(asset.Material_Map_Kind) {return false}
        asset.material_maps(&info.maps)[asset.Material_Map_Kind(change.slot)].texture=change.texture
    case .Parameter:
        parameter_texture_set(&parameters,change.name,change.texture)
    case .Value:
        parameter_value_set(&parameters,change.name,change.parameter,change.components,change.value)
    case .Loaded:
        material:=host.assets_material(a,owner)
        if material==nil || material.failed {return false}
        info=material.info
        clear(&parameters)
        append(&parameters,..host.assets_material_parameters(a,material))
    case .Revert:
        if revert_error!=.None {return false}
        info=reverted
    }
    desc:=asset.Material_Desc{id=owner,info=info,imported=based?&base_values:nil,parameters=parameters[:],imported_parameters=base_parameters,overlays=overlays,hidden=hidden,source=imported?&source:nil}
    bytes,bytes_error:=asset.material_bytes(&a.types,desc,context.temp_allocator)
    if bytes_error!=.None || !file_write(s,path,bytes,"Material") {return false}
    if users:=material_users(s,editing_world(s),owner);users>1 {notify(s,fmt.tprintf("%s changed for the %d objects that show it",asset_name(relative),users))}
    return true
}

// After an import wrote the file of a material, what memory holds of it
// unsaved follows what the source gives now as the file did: it keeps what
// was changed after the last import, saved or not.
material_rebase :: proc(s:^Session,id:base.Asset_Id) {
    a:=s.app.assets
    if a==nil {return}
    record,found:=asset.registry_find(&a.registry,id)
    if !found {return}
    if held,unsaved:=asset.registry_memory_find(&a.registry,record.path);!unsaved || held.removed {return}
    path:=asset.registry_file_path(&a.registry,record.path,context.temp_allocator)
    written:asset.Asset
    if asset.asset_load(&written,path,context.temp_allocator)!=.None {return}
    defer asset.asset_close(&written)
    source,source_error:=asset.material_view(&written,&a.types)
    if source_error!=.None || source.imported==nil {return}
    file:asset.Asset
    if !asset_read(s,record.path,&file) {return}
    defer asset.asset_close(&file)
    view,error:=asset.material_view(&file,&a.types)
    if error!=.None {return}
    parameters:=asset.material_parameters_follow(view,source.imported_parameters,context.temp_allocator)
    desc:=asset.Material_Desc{id=id,info=asset.material_follow(&a.types,view,source.imported^),imported=source.imported,parameters=parameters,imported_parameters=source.imported_parameters,overlays=view.overlays,hidden=view.hidden,source=source.source}
    if bytes,bytes_error:=asset.material_bytes(&a.types,desc,context.temp_allocator);bytes_error==.None {file_set(s,path,bytes)}
}

// What the source of a material gave at the last import, the reference of
// its fields; nil for a material no import wrote.
material_base :: proc(s:^Session,id:base.Asset_Id) -> ^asset.Material_Info {
    a:=s.app.assets
    if a==nil || s.materials==nil || id=={} {return nil}
    record,found:=asset.registry_find(&a.registry,id)
    if !found {return nil}
    b:=&s.materials.imported
    if b.material!=id || b.content!=record.content_hash {
        b^={material=id,content=record.content_hash}
        file:asset.Asset
        if view,read:=material_open(s,id,&file);read {
            if view.imported!=nil {b.info,b.imported=view.imported^,true}
            asset.asset_close(&file)
        }
    }
    return b.imported?&b.info:nil
}

// Opens a file of the assets as it is now: what the registry holds of it in
// memory, unsaved, or the disk. The caller closes it with asset_close.
asset_read :: proc(s:^Session,relative:string,file:^asset.Asset,allocator:=context.temp_allocator) -> bool {
    a:=s.app.assets
    if a==nil {return false}
    data,error:=asset.registry_read(&a.registry,relative,allocator)
    return error==.None && asset.asset_take(file,data,allocator)==.None
}

// A texture of the program the material stores for itself, by name: the one
// it has takes it, or a new one is added.
@(private)
parameter_texture_set :: proc(parameters:^[dynamic]asset.Material_Parameter,name:string,texture:base.Asset_Id) {
    for &parameter in parameters {
        if parameter.overlay==0 && parameter.kind==.Texture && base.text_get(parameter.name[:])==name {
            parameter.texture=texture
            return
        }
    }
    added:=asset.Material_Parameter{kind=.Texture,components=1,texture=texture}
    base.text_set(added.name[:],name)
    append(parameters,added)
}

// The parameters stored for a layer that is no longer among overlays go.
@(private)
overlay_parameters_keep :: proc(parameters:^[dynamic]asset.Material_Parameter,overlays:[]asset.Material_Overlay) {
    kept:=0
    for parameter in parameters {
        keep:=parameter.overlay==0
        for overlay in overlays {keep|=overlay.id==parameter.overlay}
        if keep {
            parameters[kept]=parameter
            kept+=1
        }
    }
    resize(parameters,kept)
}

// A number of the program the material stores for itself, by name: the one
// it has takes the value, or a new one is added.
@(private)
parameter_value_set :: proc(parameters:^[dynamic]asset.Material_Parameter,name:string,kind:asset.Parameter_Kind,components:u8,value:[4]f64) {
    for &parameter in parameters {
        if parameter.overlay==0 && parameter.kind!=.Texture && base.text_get(parameter.name[:])==name {
            parameter.value=value
            return
        }
    }
    added:=asset.Material_Parameter{kind=kind,components=components,value=value}
    base.text_set(added.name[:],name)
    append(parameters,added)
}

// The layers an entity shows over the material of its first slot: its own,
// or the material's. owner: that material.
@(private)
overlays_of :: proc(s:^Session,e:core.Entity) -> (layers:[asset.MATERIAL_MAX_OVERLAYS]asset.Material_Overlay,count:int,owner:base.Asset_Id,ok:bool) {
    w:=editing_world(s)
    mesh,meshed:=entity_get(w,e,erender.Mesh_Renderer)
    if !meshed {return}
    owner=appearance_read(s,w,e,mesh).material
    if override,found:=entity_get(w,e,erender.Material_Values);found && override.own_overlays {
        return override.overlays,min(int(override.overlay_count),len(layers)),owner,true
    }
    if owner=={} || s.app.assets==nil {return {},0,owner,true}
    material:=host.assets_material(s.app.assets,owner)
    if material==nil || material.failed {return}
    return material.overlays,int(material.overlay_count),owner,true
}

// The layers of the entity in place of those of its material.
@(private)
overlays_store :: proc(s:^Session,e:core.Entity,layers:[]asset.Material_Overlay,own:=true) -> bool {
    next:=entity_material_values(editing_world(s),e)
    next.own_overlays,next.overlay_count,next.overlays=own,u32(len(layers)),{}
    copy(next.overlays[:],layers)
    return override_put(s,e,next,"Overlays")
}

// A new layer over the ones the entity shows, or another material for one of them.
overlay_assign :: proc(s:^Session,e:core.Entity,layer:u32,material:base.Asset_Id) -> bool {
    layers,count,owner,ok:=overlays_of(s,e)
    if !ok || material=={} || material==owner {return false}
    if layer==0 {
        if count>=len(layers) {return false}
        next:=u32(1)
        for existing in layers[:count] {next=max(next,existing.id+1)}
        layers[count]={id=next,material=material,blend=.Alpha,enabled=true}
        count+=1
    } else {
        changed:=false
        for &existing in layers[:count] {
            if existing.id==layer {existing.material,changed=material,true}
        }
        if !changed {return false}
    }
    return overlays_store(s,e,layers[:count])
}

overlay_remove :: proc(s:^Session,e:core.Entity,layer:u32) -> bool {
    layers,count,_,ok:=overlays_of(s,e)
    if !ok {return false}
    kept:=0
    for existing in layers[:count] {
        if existing.id==layer {continue}
        layers[kept]=existing
        kept+=1
    }
    return kept<count && overlays_store(s,e,layers[:kept])
}

overlay_blend :: proc(s:^Session,e:core.Entity,layer:u32,blend:asset.Overlay_Blend) -> bool {
    layers,count,_,ok:=overlays_of(s,e)
    if !ok {return false}
    changed:=false
    for &existing in layers[:count] {
        if existing.id==layer && existing.blend!=blend {existing.blend,changed=blend,true}
    }
    return changed && overlays_store(s,e,layers[:count])
}

@(private)
overlay_key :: proc "contextless" (material:base.Asset_Id,layer:u32) -> u64 {
    return base.hash_combine(base.hash_combine(material[0],material[1]),u64(layer)+1)
}

@(private)
overlay_rows :: proc(c:^Inspect,a:^Appearance) {
    s:=c.s
    ctx:=s.gui.ctx
    ins:=s.inspector
    l:=&s.materials.list
    layers,count,_,editable:=overlays_of(s,a.entity)
    given:=material_inherited(s,c.w,a.entity)
    failed:=false
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(ui.metric(ctx,"row")),gap=4,align_y=.Center}) {
        ui.label(ctx,"Overlays",ui.metric(ctx,"font_small"),ui.tone(ctx,"text_label"),ui.metric(ctx,"label_width"))
        if editable && count<len(layers) {
            add:=ui.id(ctx,"overlay_add")
            open:=l.kind==.Overlay && l.entity==a.entity && l.offset==0
            if ui.button(ctx,add,{icon=.Plus,icon_size=12,icon_color=ui.tone(ctx,"text_label"),variant="well",width=HIERARCHY_TILE,height=ui.metric(ctx,"row"),active=open}).clicked && !open {
                anchor,_:=ui.widget_rect(ctx,add)
                material_list_open(s,{kind=.Overlay,owner=a.material,entity=a.entity},anchor)
            }
        }
        // Back to the layers of the prefab, or of the material.
        own:=a.override.own_overlays
        if own!=given.own_overlays || own && (a.override.overlay_count!=given.overlay_count || a.override.overlays!=given.overlays) {
            if ui.button(ctx,ui.id(ctx,"overlays_reset"),{icon=.Revert,variant="ghost",width=22,height=22}).clicked {
                failed|=!overlays_store(s,a.entity,given.overlays[:min(int(given.overlay_count),len(given.overlays))],given.own_overlays)
            }
        }
    }
    names:=OVERLAY_BLEND_NAMES
    for layer in layers[:count] {
        key:=overlay_key(a.material,layer.id)
        unfolded:=!inspector_section_open(ins,key)
        index:=int(layer.id)
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(MATERIAL_ROW),gap=4,align_y=.Center}) {
            if ui.button(ctx,ui.id(ctx,"overlay_fold",index),{icon=unfolded?.Chevron_Down:.Chevron_Right,variant="ghost",width=24,height=MATERIAL_ROW}).clicked {inspector_section_toggle(ins,key)}
            open:=l.kind==.Overlay && l.entity==a.entity && l.offset==index
            if clicked,anchor,_:=asset_box(s,"overlay",index,asset_label_of(s,layer.material,"Default"),material_quad(s,layer.material),open,value=layer.material);clicked {
                material_list_open(s,{kind=.Overlay,owner=a.material,offset=index,entity=a.entity},anchor)
            }
            if ui.button(ctx,ui.id(ctx,"overlay_remove",index),{icon=.Cross,variant="ghost",width=22,height=22}).clicked {
                failed|=!overlay_remove(s,a.entity,layer.id)
            }
        }
        if !unfolded {continue}
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(ui.metric(ctx,"row")),gap=4,align_y=.Center}) {
            ui.label(ctx,"Blend",ui.metric(ctx,"font_small"),ui.tone(ctx,"text_label"),ui.metric(ctx,"label_width"))
            for blend in asset.Overlay_Blend {
                if ui.button(ctx,ui.id(ctx,"overlay_blend",index*4+int(blend)),{label=names[blend],size=ui.metric(ctx,"font_small"),variant="tab",width=-1,center=true,active=layer.blend==blend}).clicked {
                    if layer.blend!=blend {failed|=!overlay_blend(s,a.entity,layer.id,blend)}
                }
            }
        }
    }
    if failed {notify(s,"The overlays of the entity could not be changed")}
}

// ---------------------------------------------------------------- popups

@(private)
material_list_popup :: proc(g:^Editor_Ui) -> ui.Id {return shell_id(g,"material_list")}
@(private)
material_color_popup :: proc(g:^Editor_Ui) -> ui.Id {return shell_id(g,"material_color")}

@(private)
material_list_open :: proc(s:^Session,list:Material_List,anchor:ui.Rect) {
    s.materials.list=list
    ui.popup_open(s.gui.ctx,material_list_popup(s.gui),anchor)
}

// Opens the list of the assets of a kind for an Asset_Id field at offset of
// a component, with their previews: what it chooses goes to that field of
// the selected entities that have the component, as one step. none: the
// first row, the zero id ("None", or "Default" for a kind whose zero id
// shows a default).
asset_list_open :: proc(s:^Session,t:^core.Table_Info,offset:int,kind:asset.Fourcc,none:string,anchor:ui.Rect) {
    index:=asset_list_table(s,t)
    if index<0 {return}
    list:=Material_List{kind=.Asset,asset=kind,table=index,offset=offset}
    base.text_set(list.none[:],none)
    material_list_open(s,list,anchor)
}

// Whether the list of asset_list_open is open for that field.
asset_list_shown :: proc(s:^Session,t:^core.Table_Info,offset:int) -> bool {
    l:=&s.materials.list
    return l.kind==.Asset && l.table==asset_list_table(s,t) && l.offset==offset
}

@(private)
asset_list_table :: proc(s:^Session,t:^core.Table_Info) -> int {
    for &candidate,index in editing_world(s).info.tables {
        if &candidate==t {return index}
    }
    return -1
}

@(private)
material_picker_open :: proc(s:^Session,p:Material_Color,linear:[3]f32,anchor:ui.Rect) {
    m:=s.materials
    shown:=linear
    m.color=p
    m.color.intensity=1
    if peak:=max(shown.x,shown.y,shown.z);p.emission && peak>1 {
        m.color.intensity=f64(peak)
        shown/=peak
    }
    kit.color_picker_set(&m.color.state,ui.display_color({clamp(shown.x,0,1),clamp(shown.y,0,1),clamp(shown.z,0,1)}))
    ui.popup_open(s.gui.ctx,material_color_popup(s.gui),anchor)
}

@(private)
material_popups :: proc(s:^Session,w:core.World_Ref) {
    material_picker_build(s,w)
    material_list_build(s,w)
}

// Everything one session of the picker changes is one step.
@(private)
material_picker_build :: proc(s:^Session,w:core.World_Ref) {
    ins:=s.inspector
    p:=&s.materials.color
    if p.key==0 {return}
    g:=s.gui
    ctx:=g.ctx
    popup:=material_color_popup(g)
    if !ui.popup_is_open(ctx,popup) {
        gesture_end(s,p.key)
        p^={}
        return
    }
    if ins.gesture==p.key {ins.gesture_frame=s.frame}
    changed:=false
    emission:=p.emission
    if ui.popup(ctx,popup,{width=240,padding=12}) {
        changed=kit.color_picker(ctx,ui.id_derive(ctx,popup,"picker"),&p.state).changed
        if emission {
            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(ui.metric(ctx,"row")),gap=4,align_y=.Center}) {
                ui.label(ctx,"Intensity",ui.metric(ctx,"font_small"),ui.tone(ctx,"text_label"),ui.metric(ctx,"label_width"))
                changed|=ui.number_field(ctx,ui.id_derive(ctx,popup,"intensity"),&p.intensity,{decimals=2,speed=0.02,has_min=true,has_max=true,max=1e5}).changed
            }
        }
    }
    if !changed || !entity_alive(w,p.entity) {return}
    if ins.gesture!=p.key && !gesture_begin(s,p.key,"Material") {return}
    linear:=ui.linear_color(kit.color_picker_rgb(&p.state))*f32(p.intensity)
    switch {
    case p.tint:     tint_store(s,p.entity,p.emission,linear)
    case p.standard: material_color_store(s,p.entity,p.slot,p.emission,linear)
    case:            override_store(s,p.entity,p.slot,p.name,{linear.x,linear.y,linear.z,p.alpha})
    }
}

@(private)
registry_files :: proc(s:^Session,kind:asset.Fourcc) -> []^asset.Registry_File {
    files:=make([dynamic]^asset.Registry_File,0,16,context.temp_allocator)
    if a:=s.app.assets;a!=nil {
        for &file in a.registry.files {
            if file.state==.Asset && file.kind==kind && asset.registry_listed(&file) {append(&files,&file)}
        }
    }
    return files[:]
}

// The materials, layers or textures to choose from, with their previews.
@(private)
material_list_build :: proc(s:^Session,w:core.World_Ref) {
    l:=&s.materials.list
    if l.kind==.None {return}
    g:=s.gui
    ctx:=g.ctx
    popup:=material_list_popup(g)
    if !ui.popup_is_open(ctx,popup) {
        l^={}
        return
    }
    all:=registry_files(s,l.kind==.Texture?asset.KIND_TEXTURE:l.kind==.Asset?l.asset:asset.KIND_MATERIAL)
    filter,_:=ui.popup_search(ctx,popup)
    files:=make([dynamic]^asset.Registry_File,0,len(all),context.temp_allocator)
    for file in all {
        if l.kind==.Overlay && file.id==l.owner {continue}
        if !base.contains_fold(file.path,filter) {continue}
        append(&files,file)
    }
    first_row:=l.kind==.Overlay?0:1 // a row for none or for the default material
    count:=len(files)+first_row
    height:=f32(clamp(count,1,MATERIAL_LIST_ROWS))*MATERIAL_ROW
    chosen:=-1
    mesh_value:base.Asset_Id
    if (l.kind==.Material || l.kind==.Asset) && l.table>=0 && l.table<len(w.info.tables) {
        t:=&w.info.tables[l.table]
        if v:=core.raw_find(core.world_table_at(w,t),t.info,history.selection_active(s.selection));v!=nil {
            mesh_value=(cast(^base.Asset_Id)rawptr(uintptr(v)+uintptr(l.offset)))^
        }
    }
    if ui.popup(ctx,popup,{width=width_of(RIGHT_WIDTH,ctx.size.x)-24,search="Search"}) {
        ui.id_push(ctx,popup)
        if _,changed:=ui.popup_search(ctx,popup);changed {l.scroll=0}
        rows:=ui.id(ctx,"rows")
        first,last:=ui.list_begin(ctx,rows,&l.scroll,count,MATERIAL_ROW,height)
        for index in first..<last {
            row:=ui.Row{accent=true,height=MATERIAL_ROW}
            file:^asset.Registry_File
            if index>=first_row {file=files[index-first_row]}
            switch l.kind {
            case .None:
            case .Material:
                row.label=file==nil?"Default":asset_name(file.path)
                row.quad=material_quad(s,file==nil?base.Asset_Id{}:file.id)
                row.checked=mesh_value==(file==nil?base.Asset_Id{}:file.id)
                row.check_room=!row.checked
            case .Asset:
                row.label=file==nil?base.text_get(l.none[:]):asset_name(file.path)
                row.quad=asset_quad(s,l.asset,file==nil?base.Asset_Id{}:file.id,MATERIAL_ROW)
                row.checked=mesh_value==(file==nil?base.Asset_Id{}:file.id)
                row.check_room=!row.checked
            case .Overlay:
                row.label=asset_name(file.path)
                row.quad=material_quad(s,file.id)
            case .Texture:
                if file==nil {
                    row.label="None"
                } else {
                    row.label=texture_label(file.path)
                    row.quad=texture_quad(s,file.id)
                    if row.quad.kind==.Solid {row.icon=.Texture}
                }
            }
            if ui.row(ctx,ui.id(ctx,"row",index+1),row).clicked {chosen=index}
        }
        ui.list_end(ctx,rows,count,last,MATERIAL_ROW)
        ui.id_pop(ctx)
    }
    if chosen<0 {return}
    chosen_file:^asset.Registry_File
    if chosen>=first_row {chosen_file=files[chosen-first_row]}
    kind,offset,table,entity,name,slot:=l.kind,l.offset,l.table,l.entity,l.name,l.slot
    ui.popup_close(ctx,popup)
    l^={}
    id:=chosen_file==nil?base.Asset_Id{}:chosen_file.id
    switch kind {
    case .None:
    case .Material,.Asset:
        if table<0 || table>=len(w.info.tables) {return}
        t:=&w.info.tables[table]
        targets:=make([dynamic]core.Entity,context.temp_allocator)
        for e in s.selection.entities {
            if core.raw_find(core.world_table_at(w,t),t.info,e)!=nil {append(&targets,e)}
        }
        value:=id
        field_write(s,t,targets[:],offset,mem.ptr_to_bytes(&value))
    case .Overlay:
        if !overlay_assign(s,entity,u32(offset),id) {notify(s,"The overlays of the entity could not be changed")}
    case .Texture:
        texture_override_store(s,entity,slot,name,id)
    }
}
