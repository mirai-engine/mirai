package editor

import "core:fmt"
import "core:hash"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "mirai:asset"
import "mirai:cook/shaders"
import "mirai:editor/api"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:project"
import gpu "mirai:render"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:ui"

// The document of a material: its preview takes the workspace, lit or showing
// one channel of what the material writes, over the variants an agent
// proposed, and its values are in Details at the right, in a card per group
// of the parameters of its program. The source of the program is not shown:
// the agent changes the .slang with material.program.edit and proposes values
// with editor.material.variants. Picking parameters or a channel gives them to
// the next message of the chat. The source of a program alone opens the same
// document, without a preview or values.

MATERIAL_PREVIEW_SIDE :: u32(1024) // texels of a side of the image of its sphere
MATERIAL_PREVIEW_KEY :: u64(0x6d61742e70726576)
MATERIAL_VARIANT_SIDE :: u32(256)
MATERIAL_VARIANT_CELL :: f32(112) // points of a side of the image of a variant
MATERIAL_VARIANTS :: 6
MATERIAL_VARIANT_VALUES :: 16
MATERIAL_VARIANT_LABEL_BYTES :: 32
MATERIAL_PICKS :: 16
MATERIAL_SOURCE_FRAMES :: 30 // between two looks at the file of the program
MATERIAL_CONTRACT :: "shaders/include/mirai_material.slang" // under the engine: Mirai_Surface and its context

// What the preview shows: the lit sphere, or one value of what the material
// writes, as the views of material.preview.capture name them.
Material_Channel :: enum u8 {Lit,Base_Color,Roughness,Metallic,Normal,Emission}
MATERIAL_CHANNEL_NAMES :: [Material_Channel]string{.Lit="Lit",.Base_Color="Base color",.Roughness="Roughness",.Metallic="Metallic",.Normal="Normal",.Emission="Emission"}
MATERIAL_CHANNEL_IDS :: [Material_Channel]string{.Lit="lit",.Base_Color="base_color",.Roughness="roughness",.Metallic="metallic",.Normal="normal",.Emission="emission"}
MATERIAL_CHANNEL_VIEWS :: [Material_Channel]gpu.Debug_View{.Lit=.None,.Base_Color=.Albedo,.Roughness=.Roughness,.Metallic=.Metallic,.Normal=.Normal,.Emission=.Emission}

// What the preview draws the material on.
Material_Shape :: enum u8 {Sphere,Cube,Cylinder,Plane}
MATERIAL_SHAPE_ICONS :: [Material_Shape]ui.Icon{.Sphere=.Sphere,.Cube=.Cube,.Cylinder=.Cylinder,.Plane=.Plane}
MATERIAL_SHAPE_NAMES :: [Material_Shape]string{.Sphere="Sphere",.Cube="Cube",.Cylinder="Cylinder",.Plane="Plane"}

// The values of the standard model a variant may set, by the names
// material.set gives them.
MATERIAL_STANDARD_VALUES :: [4]string{"base_color","roughness","metallic","emission"}

Material_Variant_Value :: struct {
    name:[64]u8,
    value:[4]f64,
}

// Values an agent proposed for the material: a click on it sets them.
Material_Variant :: struct {
    label:[MATERIAL_VARIANT_LABEL_BYTES]u8,
    values:[MATERIAL_VARIANT_VALUES]Material_Variant_Value,
    count:int,
    image:Asset_Image,
    drawn:[1]gpu.Material_Desc, // what the frame draws its sphere with
}

// What the material document in front shows.
Material_Document :: struct {
    material:base.Asset_Id,          // zero: the program alone
    program:[64]u8,                  // its name
    path:[512]u8,                    // of its .slang
    looked:u64,                      // the frame the file was last looked at
    stamp:[2]i64,                    // of the source that was read (file_stamp)
    loaded:bool,
    timed:bool,                      // the program reads the time: its preview moves
    channel:Material_Channel,
    shape:Material_Shape,
    variants:[MATERIAL_VARIANTS]Material_Variant,
    variant_count:int,
    chosen:int,                      // 1 + the variant the preview shows instead of the material; 0: none
    applied:[MATERIAL_VARIANT_LABEL_BYTES]u8, // the variant set on the material last
    details_scroll:[2]f32,
    picks:[MATERIAL_PICKS][64]u8,    // names of the parameters picked for the next message
    pick_count:int,
}

@(private)
material_document_unload :: proc(w:^Material_Document) {
    w.loaded,w.timed=false,false
}

@(private)
material_variants_free :: proc(w:^Material_Document) {
    for &variant in w.variants {asset_image_free(&variant.image)}
}

@(private)
material_document_clear :: proc(s:^Session) {
    if s.materials==nil {return}
    w:=&s.materials.document
    material_document_unload(w)
    material_variants_free(w)
    w^={}
    ai_material_set(s.ai,{})
}

// The document in front is a material, and nothing plays.
material_document_shown :: proc(s:^Session) -> bool {
    d:=asset_document_active(s)
    return d!=nil && d.kind==asset.KIND_MATERIAL && s.materials!=nil && !playing(s)
}

// Takes what the material document in front shows: its material and the
// program it names, or the program alone. Another document clears it.
material_document_follow :: proc(s:^Session) {
    if s.materials==nil {return}
    w:=&s.materials.document
    d:=asset_document_active(s)
    if d==nil || d.kind!=asset.KIND_MATERIAL {
        if w.material!={} || base.text_get(w.path[:])!="" {material_document_clear(s)}
        return
    }
    if d.id!={} {
        if w.material==d.id {return}
        material_document_clear(s)
        w.material=d.id
        info,read:=material_file(s,d.id)
        if !read {return}
        program:=base.text_get(info.program[:])
        base.text_set(w.program[:],program)
        if program!="" {
            if path,_,found:=program_locate(s,program);found {base.text_set(w.path[:],path)}
        }
        return
    }
    path:=base.text_get(d.path[:])
    if w.material=={} && base.text_get(w.path[:])==path {return}
    material_document_clear(s)
    base.text_set(w.path[:],path)
    if data,read:=file_read(s,path);read {base.text_set(w.program[:],program_declared(string(data)))}
}

// Reads the program again when its file changed: whether it reads the time. Between frames; it allocates only then.
@(private)
material_document_read :: proc(s:^Session,w:^Material_Document) {
    path:=base.text_get(w.path[:])
    if path=="" {return}
    if w.loaded && s.frame<w.looked+MATERIAL_SOURCE_FRAMES {return}
    w.looked=s.frame
    stamp,there:=file_stamp(s,path)
    if !there {material_document_unload(w);return}
    if w.loaded && stamp==w.stamp {return}
    material_document_unload(w)
    w.loaded,w.stamp=true,stamp
    text,read:=program_text(s,path)
    if !read {material_document_unload(w);return}
    // The contract gives the types of the context, which the graph reads the time by.
    contract:^shaders.Surface_Source
    contract_source:shaders.Surface_Source
    if s.engine_root!="" {
        if data,error:=os.read_entire_file(project.path(s.engine_root,MATERIAL_CONTRACT,allocator=context.temp_allocator),context.temp_allocator);error==nil {
            contract_source=shaders.surface_parse(string(data),context.temp_allocator)
            contract=&contract_source
        }
    }
    src:=shaders.surface_parse(text,context.temp_allocator)
    graph:=shaders.surface_graph(&src,context.temp_allocator,contract)
    for &node in graph.nodes {w.timed||=node.label=="ctx.time" || node.label=="ctx.previous_time"}
}

@(private)
material_pick_index :: proc(w:^Material_Document,name:string) -> int {
    for i in 0..<w.pick_count {if base.text_get(w.picks[i][:])==name {return i}}
    return -1
}

// Picks a parameter for the next message, or takes it out; without add it is
// the only one picked.
@(private)
material_pick_toggle :: proc(w:^Material_Document,name:string,add:bool) {
    if at:=material_pick_index(w,name);at>=0 {
        if !add && w.pick_count>1 {w.pick_count=0} else {
            copy(w.picks[at:w.pick_count-1],w.picks[at+1:w.pick_count])
            w.pick_count-=1
            return
        }
    }
    if !add {w.pick_count=0}
    if w.pick_count>=len(w.picks) {return}
    base.text_set(w.picks[w.pick_count][:],name)
    w.pick_count+=1
}

// The name of a value in its row: a click picks it for the next message, with
// Ctrl or Shift beside the others; picked, it is lit.
@(private)
material_value_label :: proc(s:^Session,w:^Material_Document,name,label:string,index:int) {
    ctx:=s.gui.ctx;th:=&ctx.theme
    id:=ui.id(ctx,"pick",index+1)
    it:=ui.interact(ctx,id,{})
    picked:=material_pick_index(w,name)>=0
    color:=th.text_label
    if it.hot {color=th.text}
    if picked {color=th.accent}
    if ui.box(ctx,{id=id,width=ui.fixed(th.label_width),height=ui.GROW,align_y=.Center}) {ui.column_label(ctx,label,color)}
    if it.clicked {material_pick_toggle(w,name,.Primary in ctx.input.modifiers || .Shift in ctx.input.modifiers)}
}

// The values of the material in Details: those of its program, a card per
// group in the order the program declares them, or those of the standard
// model. A drag changes the material in memory, which its row shows at once,
// and is one step of the history of the document.
@(private)
material_document_parameters :: proc(s:^Session,w:^Material_Document) {
    a:=s.app.assets
    if a==nil || w.material=={} {return}
    loaded:=host.assets_material(a,w.material)
    if loaded==nil || loaded.failed {return}
    desc:=host.assets_material_values(a,loaded.row)
    program:=erender.surface_program(a,desc.program_id)
    if program==nil && loaded.info.program[0]!=0 {return}
    if program==nil {
        if material_card(s,"Surface",.Material) {material_document_standard(s,w,loaded.info)}
        return
    }
    groups:=make([dynamic]string,0,len(program.parameters),context.temp_allocator)
    for &parameter in program.parameters {
        if parameter.kind==.Texture || slice.contains(groups[:],parameter.group) {continue}
        append(&groups,parameter.group)
    }
    for group in groups {
        title:=group!=""?group:"Parameters"
        if !material_card(s,title,.Material) {continue}
        for &parameter,index in program.parameters {
            if parameter.kind==.Texture || parameter.group!=group {continue}
            ui.box_begin(s.gui.ctx,{width=ui.GROW,height=ui.fixed(s.gui.ctx.theme.row),gap=4,align_y=.Center})
            material_value_label(s,w,parameter.name,readable(parameter.name),index)
            material_parameter_field(s,w,&parameter,index,gpu.program_parameter_get(&desc.custom_params,&parameter))
            ui.box_end(s.gui.ctx,{})
        }
    }
}

// A card of the details of the material whose band folds it: true while it
// is open, with its rows to build.
@(private,deferred_in_out=material_card_end)
material_card :: proc(s:^Session,title:string,icon:ui.Icon) -> (open:bool) {
    card_begin(s)
    key:=base.hash_combine(base.name_hash("material document"),base.name_hash(title))
    open=inspector_section_open(s.inspector,key)
    if section_band(s,ui.id(s.gui.ctx,"card",int(key&0x7fffffff)),title,open,icon).clicked {
        inspector_section_toggle(s.inspector,key)
        open=!open
    }
    if open {card_body_begin(s)}
    return
}
@(private)
material_card_end :: proc(s:^Session,title:string,icon:ui.Icon,open:bool) {
    if open {card_body_end(s)}
    card_end(s)
}

// The field of a value of the program: toggles for a bool, a slider for one
// number and a field per component for more.
@(private)
material_parameter_field :: proc(s:^Session,w:^Material_Document,parameter:^gpu.Program_Parameter,index:int,numbers:[4]f64) {
    ctx:=s.gui.ctx;th:=&ctx.theme
    count:=clamp(int(parameter.components),1,4)
    key:=base.hash_combine(base.hash_combine(w.material[0],w.material[1]),base.name_hash(parameter.name))
    if parameter.kind==.Bool {
        for axis in 0..<count {
            on:=numbers[axis]!=0
            if ui.button(ctx,ui.id(ctx,"toggle",index*4+axis+1),{label=on?"On":"Off",style=.Tab,size=th.font_small,width=-1,center=true,active=on}).clicked {
                next:=numbers
                next[axis]=on?0:1
                if !material_write(s,w.material,{kind=.Value,name=parameter.name,value=next,parameter=asset.Parameter_Kind(parameter.kind),components=parameter.components}) {notify(s,"The material could not be written")}
            }
        }
        return
    }
    field:=ui.Number_Field{integer=parameter.kind!=.Float,speed=parameter.kind!=.Float?0.05:0.02}
    if parameter.min<parameter.max {
        field.has_min,field.has_max,field.min,field.max=true,true,parameter.min,parameter.max
        if !field.integer {field.speed=max((parameter.max-parameter.min)/200,1e-4)}
    }
    results:[4]ui.Number_Result
    axes:=numbers
    if count==1 {
        results[0]=ui.slider_field(ctx,ui.id(ctx,"parameter",index+1),&axes[0],field)
    } else {
        results=number_fields(ctx,ui.id(ctx,"parameter",index+1),axes[:count],{number=field,channels=parameter.color})
    }
    for r,axis in results[:count] {
        if r=={} {continue}
        axis_key:=base.hash_combine(key,u64(axis))
        gesture_follow(s,axis_key,r,"Material parameter")
        if r.changed {
            info,parameters,ok:=material_loaded(s,w.material)
            if ok {
                parameter_value_set(&parameters,parameter.name,asset.Parameter_Kind(parameter.kind),parameter.components,axes)
                material_document_set(s,w,axis_key,info,parameters[:])
            }
        }
        if r.ended {material_document_end(s,w,axis_key,r.cancelled)}
    }
}

// The values of the standard model: color, roughness, metallic and emission.
// Of an imported material, the arrow of a value that differs from what its
// source gave gives that back.
@(private)
material_document_standard :: proc(s:^Session,w:^Material_Document,info:asset.Material_Info) {
    ctx:=s.gui.ctx
    unit:=ui.Number_Field{has_min=true,has_max=true,min=0,max=1,speed=0.005}
    glow:=ui.Number_Field{has_min=true,min=0,speed=0.02}
    next:=info
    imported:=material_base(s,w.material)
    source:asset.Material_Info
    if imported!=nil {source=imported^}
    Row :: struct {label,path:string,values,source:[]f32,field:ui.Number_Field}
    rows:=[4]Row{
        {"Color","base_color",next.base_color[:],source.base_color[:],unit},
        {"Roughness","roughness",slice.from_ptr(&next.roughness,1),slice.from_ptr(&source.roughness,1),unit},
        {"Metallic","metallic",slice.from_ptr(&next.metallic,1),slice.from_ptr(&source.metallic,1),unit},
        {"Emission","emission",next.emission[:],source.emission[:],glow},
    }
    for row,index in rows {
        count:=len(row.values)
        axes:[4]f64
        for value,axis in row.values {axes[axis]=f64(value)}
        ui.box_begin(ctx,{width=ui.GROW,height=ui.fixed(ctx.theme.row),gap=4,align_y=.Center})
        material_value_label(s,w,row.path,row.label,index)
        results:[4]ui.Number_Result
        id:=ui.id(ctx,"standard",index+1)
        if count==1 {
            results[0]=ui.slider_field(ctx,id,&axes[0],row.field)
        } else {
            results=number_fields(ctx,id,axes[:count],{number=row.field,channels=true})
        }
        key:=base.hash_combine(base.hash_combine(w.material[0],w.material[1]),base.name_hash(row.label))
        for r,axis in results[:count] {
            if r=={} {continue}
            axis_key:=base.hash_combine(key,u64(axis))
            gesture_follow(s,axis_key,r,"Material value")
            if r.changed {
                for &value,i in row.values {value=f32(axes[i])}
                if _,parameters,ok:=material_loaded(s,w.material);ok {material_document_set(s,w,axis_key,next,parameters[:])}
            }
            if r.ended {material_document_end(s,w,axis_key,r.cancelled)}
        }
        if imported!=nil {
            if slice.equal(slice.to_bytes(row.values),slice.to_bytes(row.source)) {ui.spacer(ctx,22,1)} else if ui.button(ctx,ui.id(ctx,"standard_revert",index+1),{icon=.Revert,style=.Ghost,width=22,height=22}).clicked {
                if !material_write(s,w.material,{kind=.Revert,paths={row.path}}) {notify(s,"The material could not be written")}
            }
        }
        ui.box_end(ctx,{})
    }
}

// What a material holds in memory, as copies to change.
@(private)
material_loaded :: proc(s:^Session,id:base.Asset_Id) -> (info:asset.Material_Info,parameters:[dynamic]asset.Material_Parameter,ok:bool) {
    a:=s.app.assets
    material:=host.assets_material(a,id)
    if material==nil || material.failed {return}
    stored:=host.assets_material_parameters(a,material)
    parameters=make([dynamic]asset.Material_Parameter,0,len(stored)+MATERIAL_VARIANT_VALUES,context.temp_allocator)
    append(&parameters,..stored)
    return material.info,parameters,true
}

// The material takes values in memory while the gesture key changes them:
// its row shows them with the next frame and its file takes them when the
// gesture ends. Without the gesture the file takes them at once.
@(private)
material_document_set :: proc(s:^Session,w:^Material_Document,key:u64,info:asset.Material_Info,parameters:[]asset.Material_Parameter) {
    if !host.assets_material_set(s.app.assets,w.material,info,parameters) {
        notify(s,"The material could not be changed")
        return
    }
    if s.inspector.gesture==key {
        s.materials.pending={key,w.material}
    } else if !material_write(s,w.material,{kind=.Loaded}) {
        notify(s,"The material could not be written")
    }
}

// The gesture of a value ended. Cancelled, the material goes back to what
// its file holds; otherwise gesture_end writes what it left.
@(private)
material_document_end :: proc(s:^Session,w:^Material_Document,key:u64,cancelled:bool) {
    if cancelled && s.materials.pending.key==key {
        s.materials.pending={}
        host.assets_reload(s.app.assets,w.material)
    }
    gesture_end(s,key)
}

// The file of the material a gesture of the document changed in memory
// takes what it holds, once, when the gesture key ends.
@(private)
material_pending_write :: proc(s:^Session,key:u64) {
    p:=&s.materials.pending
    if p.key==0 || p.key!=key {return}
    material:=p.material
    p^={}
    if !material_write(s,material,{kind=.Loaded}) {notify(s,"The material could not be written")}
}

// The values of a variant over a copy of what the material holds. The name of
// a value is a parameter of its program, or of the standard model without one.
@(private)
material_variant_apply :: proc(program:^gpu.Program,variant:^Material_Variant,info:^asset.Material_Info,parameters:^[dynamic]asset.Material_Parameter) {
    for &entry in variant.values[:variant.count] {
        name:=base.text_get(entry.name[:])
        if program!=nil {
            if parameter:=gpu.program_parameter(program,name);parameter!=nil {parameter_value_set(parameters,name,asset.Parameter_Kind(parameter.kind),parameter.components,entry.value)}
            continue
        }
        switch name {
        case "base_color": for &c,i in info.base_color {c=f32(entry.value[i])}
        case "roughness":  info.roughness=f32(entry.value[0])
        case "metallic":   info.metallic=f32(entry.value[0])
        case "emission":   for &c,i in info.emission {c=f32(entry.value[i])}
        }
    }
}

// The row of the renderer a variant draws its sphere with: the material as it
// is in memory, with the values of the variant.
@(private)
material_variant_desc :: proc(a:^host.Assets,w:^Material_Document,variant:^Material_Variant) -> gpu.Material_Desc {
    desc:=host.assets_material_values(a,host.assets_material_row(a,w.material))
    program:=erender.surface_program(a,desc.program_id)
    for &entry in variant.values[:variant.count] {
        name:=base.text_get(entry.name[:])
        if program!=nil {
            if parameter:=gpu.program_parameter(program,name);parameter!=nil && parameter.kind!=.Texture {gpu.program_parameter_set(&desc.custom_params,parameter,entry.value)}
            continue
        }
        switch name {
        case "base_color": for &c,i in desc.info.base_color {c=f32(entry.value[i])}
        case "roughness":  desc.info.roughness=f32(entry.value[0])
        case "metallic":   desc.info.metallic=f32(entry.value[0])
        case "emission":   for &c,i in desc.info.emission {c=f32(entry.value[i])}
        }
    }
    return desc
}

// The material as it is in memory with the values of a variant over it.
@(private)
material_variant_values :: proc(s:^Session,w:^Material_Document,index:int) -> (info:asset.Material_Info,parameters:[dynamic]asset.Material_Parameter,ok:bool) {
    a:=s.app.assets
    if a==nil || index<0 || index>=w.variant_count {return}
    info,parameters=material_loaded(s,w.material) or_return
    loaded:=host.assets_material(a,w.material)
    program:=erender.surface_program(a,host.assets_material_values(a,loaded.row).program_id)
    material_variant_apply(program,&w.variants[index],&info,&parameters)
    return info,parameters,true
}

// Sets the values of the variant the preview shows on the material: one step
// of the history of the document.
@(private)
material_variant_set :: proc(s:^Session,w:^Material_Document) {
    index:=w.chosen-1
    info,parameters,ok:=material_variant_values(s,w,index)
    if !ok {return}
    // Outside a gesture: the file takes the values at once, as one step.
    material_document_set(s,w,base.name_hash("material variant"),info,parameters[:])
    w.applied=w.variants[index].label
    w.chosen=0
}

// Writes the material with the values of the variant the preview shows as a
// new material beside it, named after both, unsaved like the rest of the
// document. Its document does not open: the variants stay to save others.
@(private)
material_variant_save :: proc(s:^Session,w:^Material_Document) {
    a:=s.app.assets
    index:=w.chosen-1
    info,parameters,ok:=material_variant_values(s,w,index)
    file,found:=asset.registry_find(&a.registry,w.material)
    if !ok || !found {notify(s,"The variant could not be read");return}
    folder,stem:="",strings.trim_suffix(file.path,".mat")
    if slash:=strings.last_index_byte(stem,'/');slash>=0 {folder,stem=stem[:slash],stem[slash+1:]}
    label:=base.text_get(w.variants[index].label[:])
    path:string
    for n in 1..=99 {
        name:=n==1?fmt.tprintf("%s %s.mat",stem,label):fmt.tprintf("%s %s %d.mat",stem,label,n)
        path=folder==""?name:fmt.tprintf("%s/%s",folder,name)
        if !file_exists(s,scene_file(s,path)) {break}
    }
    id:=asset_id_new(s)
    bytes,error:=asset.material_bytes(&a.types,{id=id,info=info,parameters=parameters[:]},context.temp_allocator)
    if error!=.None || !file_write(s,scene_file(s,path),bytes,"Save variant as material") {notify(s,"The material could not be written");return}
    host.assets_scan(a)
    notify(s,fmt.tprintf("Created %s",path))
}

// What the toolbar says of the document in front: its program, or the
// standard model, and how it covers what is behind it.
material_document_kind :: proc(s:^Session) -> string {
    w:=&s.materials.document
    program:=base.text_get(w.program[:])
    if w.material=={} || s.app.assets==nil {return program}
    model:=program!=""?program:"Surface"
    material:=host.assets_material(s.app.assets,w.material)
    if material==nil || material.failed {return model}
    modes:=ALPHA_MODE_NAMES
    return fmt.tprintf("%s · %s",model,modes[material.info.alpha_mode])
}

// Asks the next frame for a sphere when what it shows changed: the values it
// is drawn with, its view, its channel, the assets, the shaders or, when it
// moves with a program that reads the time, the frame.
@(private)
material_sphere_draw :: proc(s:^Session,w:^Material_Document,image:^Asset_Image,drawn:^[1]gpu.Material_Desc,values:gpu.Material_Desc,side:u32,view:gpu.Preview_View,channel:Material_Channel,moves:bool) {
    p:=&s.materials.preview
    a:=s.app.assets
    Shown :: struct {values:gpu.Material_Desc,view:gpu.Preview_View,channel:Material_Channel,shape:Material_Shape,revision,reloads,frame:u64}
    shown:=Shown{values=values,view=view,channel=channel,shape=w.shape,revision=a.revision,reloads=s.app.shaders.reloads}
    if moves && w.timed && w.loaded {shown.frame=s.frame}
    signature:=hash.fnv64a(mem.ptr_to_bytes(&shown))|1
    if !asset_image_due(s,image,signature) {return}
    drawn[0]=values
    views:=MATERIAL_CHANNEL_VIEWS
    asset_image_draw(s,image,side,signature,p.mesh[:],drawn[:],{},view,channel=views[channel])
}

// The preview and the variants, on the shape chosen. The preview shows the
// variant chosen, if one is. Another material starts from the view of the
// studio. Only the preview moves with the time: a frame draws few images,
// and variants that moved too would take them all.
@(private)
material_previews_draw :: proc(s:^Session,w:^Material_Document) {
    p:=&s.materials.preview
    a:=s.app.assets
    if a==nil || a.renderer==nil || w.material=={} {return}
    if p.material!=w.material {p.material,p.camera=w.material,{}}
    if p.mesh==nil || p.mesh_shape!=w.shape {
        if p.mesh==nil {p.mesh=make([dynamic]gpu.Thumbnail_Vertex,s.app.allocator)}
        clear(&p.mesh)
        material_shape_build(&p.mesh,w.shape)
        p.mesh_shape=w.shape
    }
    if p.image.key==0 {p.image.key,p.image.name=MATERIAL_PREVIEW_KEY,"material.preview"}
    shown:=host.assets_material_values(a,host.assets_material_row(a,w.material))
    if w.chosen>0 && w.chosen<=w.variant_count {shown=material_variant_desc(a,w,&w.variants[w.chosen-1])}
    material_sphere_draw(s,w,&p.image,&p.drawn,shown,MATERIAL_PREVIEW_SIDE,p.camera.view,w.channel,true)
    for &variant,i in w.variants[:w.variant_count] {
        if variant.image.key==0 {variant.image.key,variant.image.name=MATERIAL_PREVIEW_KEY+u64(i)+1,"material.variant"}
        material_sphere_draw(s,w,&variant.image,&variant.drawn,material_variant_desc(a,w,&variant),MATERIAL_VARIANT_SIDE,p.camera.view,w.channel,false)
    }
}

// What the preview shows, in the middle of the toolbar: the channel and the
// shape it draws the material on.
@(private)
material_toolbar :: proc(s:^Session,w:^Material_Document) {
    g:=s.gui;ctx:=g.ctx;th:=&ctx.theme
    rect,found:=asset_toolbar_whole(g)
    if !found || rect.w<=0 || w.material=={} {return}
    if ui.box(ctx,{width=ui.fixed(rect.w),height=ui.fixed(rect.h),gap=8,align_x=.Center,align_y=.Center,float={to=.Surface,offset={rect.x,rect.y},layer=ui.LAYER_BAR}}) {
        ui.id_push(ctx,shell_id(g,"material_toolbar"))
        defer ui.id_pop(ctx)
        names:=MATERIAL_CHANNEL_NAMES
        labels:=make([]string,len(Material_Channel),context.temp_allocator)
        for channel in Material_Channel {labels[int(channel)]=names[channel]}
        current:=int(w.channel)
        ui.tabs(ctx,ui.id(ctx,"channel"),labels,&current,ui.fixed(f32(len(labels))*80),th.control)
        w.channel=Material_Channel(current)
        if ui.box(ctx,{width=ui.fixed(1),height=ui.fixed(18),fill=th.border}) {}
        icons,shapes:=MATERIAL_SHAPE_ICONS,MATERIAL_SHAPE_NAMES
        for shape in Material_Shape {
            if ui.button(ctx,ui.id(ctx,"shape",int(shape)+1),{icon=icons[shape],tip=shapes[shape],style=.Tab,active=w.shape==shape,width=26,height=th.control}).clicked {w.shape=shape}
        }
    }
}

// The workspace: the preview, with the variants under it, and Details at its
// right; what the preview shows is chosen in the toolbar.
material_document_build :: proc(s:^Session) {
    g:=s.gui;ctx:=g.ctx;th:=&ctx.theme
    w:=&s.materials.document
    a:=s.app.assets
    if w.material!={} && a!=nil {
        if _,found:=asset.registry_find(&a.registry,w.material);!found {return}
    }
    material_document_read(s,w)
    material_document_context(s.ai,a!=nil?&a.registry:nil,w)
    document:=asset_workspace(g)
    details:ui.Panel_Float
    room:f32
    if w.material!={} {document,details,room=asset_workspace_details(s)}
    id:=shell_id(g,"material_document")
    if ui.panel(ctx,id,document) {
        ui.id_push(ctx,id)
        defer ui.id_pop(ctx)
        if w.material=={} {
            asset_heading(ctx,"Program")
            if ui.box(ctx,{width=ui.GROW,height=ui.GROW,align_x=.Center,align_y=.Center,fill=th.well}) {ui.label(ctx,base.text_get(w.program[:]),th.font,th.text_muted)}
            return
        }
        preview:=&s.materials.preview
        it,rect:=asset_image_show(s,&preview.image)
        asset_view_input(ctx,&preview.camera,it,rect)
        // The preview is what a message shows the agent of the material.
        if rect.w>0 {ai_region_set(s.ai,rect)}
        if w.variant_count>0 {
            ui.box_begin(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column,padding={asset_workspace_under(g),0,0,0}})
            defer ui.box_end(ctx,{})
            // A click shows a variant in the preview; Apply sets it on the material, Save as new writes it apart.
            if ui.box(ctx,asset_heading_box(ctx)) {
                ui.label(ctx,"Variants",th.font,th.text,font=ui.FONT_MEDIUM)
                ui.spacer(ctx)
                if w.chosen>0 {
                    if ui.button(ctx,ui.id(ctx,"variant_save"),{label="Save as new",style=.Field,size=th.font_small,height=24,padding=10}).clicked {material_variant_save(s,w)}
                    if ui.button(ctx,ui.id(ctx,"variant_apply"),{label="Apply",style=.Accent,size=th.font_small,height=24,padding=12}).clicked {material_variant_set(s,w)}
                }
            }
            asset_heading_end(ctx)
            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(MATERIAL_VARIANT_CELL+38),gap=8,padding={12,8,12,8},fill=th.card}) {
                for &variant,i in w.variants[:w.variant_count] {
                    ui.id_push(ctx,ui.id(ctx,"variant",i+1))
                    chosen:=w.chosen==i+1
                    if ui.box(ctx,{width=ui.fixed(MATERIAL_VARIANT_CELL),height=ui.GROW,direction=.Column,gap=4,align_x=.Center}) {
                        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(MATERIAL_VARIANT_CELL),stroke=chosen?th.accent:th.rule,stroke_width=chosen?2:1,radius=th.radius_control,padding=ui.padding_all(1)}) {
                            cell,_:=asset_image_show(s,&variant.image)
                            if cell.clicked {w.chosen=chosen?0:i+1}
                        }
                        ui.label(ctx,base.text_get(variant.label[:]),th.font_small,chosen?th.text:th.text_muted,MATERIAL_VARIANT_CELL)
                    }
                    ui.id_pop(ctx)
                }
            }
        }
    }
    material_toolbar(s,w)
    material_previews_draw(s,w)
    if w.material=={} {return}
    details_id:=shell_id(g,"material_details")
    if ui.panel(ctx,details_id,details) {
        ui.id_push(ctx,details_id)
        defer ui.id_pop(ctx)
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(INSPECTOR_HEAD),padding={11,0,7,0},gap=6,align_y=.Center}) {
            ui.icon(ctx,.Material,th.text_muted,15)
            title:=""
            if d:=asset_document_active(s);d!=nil {title=asset_document_title(s,d)}
            ui.label(ctx,title,th.font_heading,th.text,0,font=ui.FONT_SEMIBOLD)
        }
        origin:=ai_provenance_asset_row(s)
        if ui.scroll_area(ctx,ui.id(ctx,"details"),&w.details_scroll,{height=ui.FIT,max_height=max(room-INSPECTOR_HEAD-origin,40),padding={8,7,8,8},gap=7,fade=th.panel}) {
            material_document_parameters(s,w)
        }
    }
}

Api_Material_Document_Result :: struct {
    open:bool,
    program:[64]u8 `mirai:"text"`,
    picked:int,
    channel:[16]u8 `mirai:"text"`,
}

Api_Material_Variants_Result :: struct {
    count:int,
}

Api_Editor_Material_Show_Params_Channel :: enum u8 {lit,base_color,roughness,metallic,normal,emission}
Api_Editor_Material_Show_Params :: struct {
    material:string `mirai:"optional,label=A material: its path under the assets folder, or its id; absent or empty closes the material document in front"`,
    parameters:[]string `mirai:"optional,label=At most 16. Values of the material to pick, which the next message takes as context: parameters of its program by name, or base_color, roughness, metallic and emission of the standard model"`,
    channel:Api_Editor_Material_Show_Params_Channel `mirai:"optional,label=What the preview shows, which the next message takes as context: the lit sphere, or one value the material writes"`,
}

Api_Editor_Material_Variants_Params_Variants :: struct {
    label:string,
    values:serial.Json `mirai:"label=Those of material.set by parameter of its program (or base_color, roughness, metallic and emission of the standard model): a number, a bool, or an array of its components, inside the range of the parameter"`,
}
Api_Editor_Material_Variants_Params :: struct {
    material:string `mirai:"optional,label=A material: its path under the assets folder, or its id; absent: the one of the material document in front"`,
    variants:[]Api_Editor_Material_Variants_Params_Variants `mirai:"label=At most 6. Replaces the variants; an empty array takes them out"`,
}

@(private)
material_document_register :: proc(s:^Session,st:^Api_State) {
    api_register(s,st,{name="editor.material.show",params=type_info_of(Api_Editor_Material_Show_Params),summary="Opens the document of a material for the user in a tab next to the scenes, with its preview, its variants and its values; without material it closes the one in front.",result=type_info_of(Api_Material_Document_Result),flags={.Idempotent},run=api_material_document})
    api_register(s,st,{name="editor.material.variants",params=type_info_of(Api_Editor_Material_Variants_Params),summary="Proposes to the user sets of values of a material, each on its own sphere in its document, which it opens; the material changes only when a click on one sets them, as one undo step.",result=type_info_of(Api_Material_Variants_Result),flags={.Idempotent},run=api_material_variants})
}

@(private)
api_material_document :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Editor_Material_Show_Params)
    name:=p.material
    picking:=api.call_given(call,"parameters") // the picks it names replace those there were
    if len(p.parameters)>MATERIAL_PICKS {api.call_failf(call,api.INVALID_PARAMS,"parameters takes at most %d names",MATERIAL_PICKS);return}
    channel_ids:=MATERIAL_CHANNEL_IDS
    channel:=api.call_given(call,"channel")?channel_ids[Material_Channel(p.channel)]:""
    if name=="" {
        if material_document_shown(s) {asset_document_close_now(s,s.asset_shown-1)}
        api.call_result(call,Api_Material_Document_Result)^={}
        return
    }
    chosen:=Material_Channel(p.channel)
    if playing(s) {api_playing(call,"the document of a material opens in Edit");return}
    id,found:=asset_named(s,call,name,asset.KIND_MATERIAL,".mat","a material")
    if !found {return}
    if !asset_document_show(s,id) {api.call_failf(call,api.SERVER_ERROR,"The document of %s could not open: %s",name,string(s.toast[:s.toast_length]));return}
    material_document_follow(s)
    w:=&s.materials.document
    w.looked=0
    material_document_read(s,w)
    if picking {
        known:=material_value_names(s,w)
        for pick in p.parameters {
            if pick!="" && !slice.contains(known,pick) {api.call_failf(call,api.INVALID_PARAMS,"%q is not a value of the material (material.inspect lists them)",pick);return}
        }
        w.pick_count=0
        for pick in p.parameters {
            if pick!="" {material_pick_toggle(w,pick,true)}
        }
    }
    if channel!="" {w.channel=chosen}
    result:=api.call_result(call,Api_Material_Document_Result)
    result.open,result.picked=true,w.pick_count
    result.program=w.program
    ids:=MATERIAL_CHANNEL_IDS
    base.text_set(result.channel[:],ids[w.channel])
}

// The names of the values of a material a variant or a pick takes: the
// parameters of its program that are not textures, or those of the standard model.
@(private)
material_value_names :: proc(s:^Session,w:^Material_Document) -> []string {
    a:=s.app.assets
    if a==nil || w.material=={} {return nil}
    program:=erender.surface_program(a,host.assets_material_values(a,host.assets_material_row(a,w.material)).program_id)
    if program==nil {
        standard:=MATERIAL_STANDARD_VALUES
        return slice.clone(standard[:],context.temp_allocator)
    }
    names:=make([dynamic]string,0,len(program.parameters),context.temp_allocator)
    for &parameter in program.parameters {if parameter.kind!=.Texture {append(&names,parameter.name)}}
    return names[:]
}

@(private)
api_material_variants :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Editor_Material_Variants_Params)
    name:=p.material
    variants:[MATERIAL_VARIANTS]Material_Variant
    count:=len(p.variants)
    raw:[MATERIAL_VARIANTS][MATERIAL_VARIANT_VALUES]string // the JSON of each value, read once the program is known
    if count>MATERIAL_VARIANTS {api.call_failf(call,api.INVALID_PARAMS,"variants takes at most %d",MATERIAL_VARIANTS);return}
    for &given,i in p.variants {
        v:=&variants[i]
        if given.label=="" {api.call_failf(call,api.INVALID_PARAMS,"variants[%d] needs its label",i);return}
        base.text_set(v.label[:len(v.label)-1],given.label)
        values,is_object:=api.json_members(string(given.values))
        if !is_object && given.values!="" {api.call_failf(call,api.INVALID_PARAMS,"variants[%d].values is an object of values by name",i);return}
        if len(values)>MATERIAL_VARIANT_VALUES {api.call_failf(call,api.INVALID_PARAMS,"a variant takes at most %d values",MATERIAL_VARIANT_VALUES);return}
        for value,k in values {
            base.text_set(v.values[k].name[:],value.name)
            raw[i][k]=value.value
        }
        v.count=len(values)
    }
    if playing(s) {api_playing(call,"the document of a material opens in Edit");return}
    id:base.Asset_Id
    if name!="" {
        found:bool
        id,found=asset_named(s,call,name,asset.KIND_MATERIAL,".mat","a material")
        if !found {return}
    } else {
        if !material_document_shown(s) || s.materials.document.material=={} {api.call_fail(call,api.INVALID_PARAMS,"No material document is in front: name the material");return}
        id=s.materials.document.material
    }
    assets:=s.app.assets
    if assets==nil {api.call_fail(call,api.SERVER_ERROR,"The editor has no assets");return}
    loaded:=host.assets_material(assets,id)
    if loaded==nil || loaded.failed {api.call_fail(call,api.SERVER_ERROR,api_asset_read_problem(s,id,"material"));return}
    program:=erender.surface_program(assets,host.assets_material_values(assets,loaded.row).program_id)
    if program==nil && loaded.info.program[0]!=0 {api.call_fail(call,api.SERVER_ERROR,"The program of the material is not published yet");return}
    for &v,vi in variants[:count] {
        for &entry,ei in v.values[:v.count] {
            value_name:=base.text_get(entry.name[:])
            components:=1
            is_bool:=false
            minimum,maximum:=f64(-1e20),f64(1e20)
            if program!=nil {
                parameter:=gpu.program_parameter(program,value_name)
                if parameter==nil || parameter.kind==.Texture {api.call_failf(call,api.INVALID_PARAMS,"%q is not a value of program %s (material.program.inspect lists its parameters)",value_name,program.name);return}
                components,is_bool=int(parameter.components),parameter.kind==.Bool
                if parameter.min<parameter.max {minimum,maximum=parameter.min,parameter.max}
            } else {
                switch value_name {
                case "base_color": components,minimum,maximum=3,0,1
                case "roughness","metallic": minimum,maximum=0,1
                case "emission": components,minimum=3,0
                case: api.call_failf(call,api.INVALID_PARAMS,"%q is not a value of the standard model: base_color, roughness, metallic or emission",value_name);return
                }
            }
            if !material_variant_value(raw[vi][ei],components,is_bool,&entry.value) {
                api.call_failf(call,api.INVALID_PARAMS,"%s of %q must be %s",value_name,base.text_get(v.label[:]),components>1?fmt.tprintf("an array of %d numbers",components):is_bool?"true or false":"a number");return
            }
            for c in 0..<components {
                if entry.value[c]<minimum || entry.value[c]>maximum {api.call_failf(call,api.INVALID_PARAMS,"%s of %q is out of its range %g to %g",value_name,base.text_get(v.label[:]),minimum,maximum);return}
            }
        }
    }
    if !asset_document_show(s,id) {api.call_fail(call,api.SERVER_ERROR,"The document of the material could not open");return}
    material_document_follow(s)
    w:=&s.materials.document
    material_variants_free(w)
    w.variants={}
    for v,i in variants[:count] {
        w.variants[i].label=v.label
        w.variants[i].values=v.values
        w.variants[i].count=v.count
    }
    w.variant_count,w.chosen,w.applied=count,0,{}
    api.call_result(call,Api_Material_Variants_Result).count=count
}

// A value of a variant as JSON: a number, a bool or an array of components.
@(private)
material_variant_value :: proc(text:string,components:int,is_bool:bool,out:^[4]f64) -> bool {
    r:serial.Text_Reader
    serial.text_reader_init(&r,text,context.temp_allocator)
    one :: proc(r:^serial.Text_Reader,is_bool:bool) -> (value:f64,ok:bool) {
        if is_bool {
            if serial.text_keyword(r,"true") {return 1,true}
            if serial.text_keyword(r,"false") {return 0,true}
            return
        }
        bits,read:=serial.text_read_float(r,8)
        value=transmute(f64)bits
        return value,read && value-value==0
    }
    if components==1 && !serial.text_accept(&r,'[') {
        out[0]=one(&r,is_bool) or_return
        return true
    } else if components==1 {
        out[0]=one(&r,is_bool) or_return
        return serial.text_accept(&r,']')
    }
    if !serial.text_accept(&r,'[') {return false}
    for c in 0..<components {
        if c>0 && !serial.text_accept(&r,',') {return false}
        out[c]=one(&r,is_bool) or_return
    }
    return serial.text_accept(&r,']')
}

// What the next message takes of the document: the material, its program,
// the values picked, the channel shown and the variant set last.
@(private)
material_document_context :: proc(ai:^Ai,registry:^asset.Registry,w:^Material_Document) {
    m:=Ai_Material_Context{open=true,id=w.material}
    if w.material!={} && registry!=nil {
        if file,found:=asset.registry_find(registry,w.material);found {base.text_set(m.material[:],file.path)}
    }
    m.program=w.program
    m.pick_count=w.pick_count
    for i in 0..<w.pick_count {m.picks[i]=w.picks[i]}
    if w.channel!=.Lit {
        ids:=MATERIAL_CHANNEL_IDS
        base.text_set(m.channel[:],ids[w.channel])
    }
    if w.chosen>0 {m.variant=w.variants[w.chosen-1].label} else {m.variant,m.variant_applied=w.applied,base.text_get(w.applied[:])!=""}
    ai_material_set(ai,m)
}
