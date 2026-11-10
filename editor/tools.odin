package editor

import "core:path/filepath"
import "mirai:project"
import "core:math"
import "core:strings"
import "mirai:asset"
import importer "mirai:cook/import"
import "mirai:cook/import/sources"
import "mirai:core"
import "mirai:editor/api"
import erender "mirai:engine/render"
import "mirai:host"
import gpu "mirai:render"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"

// What the tools of the editor do each frame besides drawing: the atlas of
// previews the renderer is given, the files that arrive to be imported, and the popups and panels that float over
// the shell.

@(step="ui",stage="end",after="editor_end")
editor_services :: proc(s:^Session) {
    thumbnails_flush(s)
    settings_flush(s)
    import_frame(s)
}

// The popups and the floating panels of the tools, built with the rest of the shell.
@(private)
tools_popups :: proc(s:^Session,w:core.World_Ref) {
    graphics_build(s)
    finder_build(s,w)
    ai_build(s)
}

// ---------------------------------------------------------------- API

API_IMPORT_SECONDS :: 1800

Import_Params :: struct {
    path:[API_PATH_BYTES]u8 `mirai:"text,label=The source file anywhere on disk; the editor reads it and writes only into the asset folder: a model (OBJ or glTF or GLB or USD or FBX or a format a plugin adds); an image; a sound (WAV or Ogg); a font (TTF or OTF); a table of texts (CSV) that becomes .strings; a manifest of prompts (.prompts.json) or a folder of their images that becomes .prompts; or a source a plugin imports whole, which writes where its importer says"`,
    folder:[API_PATH_BYTES]u8 `mirai:"text,optional,label=The folder under the asset folder it goes in (a model keeps a folder of its name inside); without it, the root of the assets. A source a plugin imports whole takes none"`,
    profile:bool `mirai:"optional,label=Records where its time goes: the answer gives the seconds of each zone"`,
    seconds:int `mirai:"optional,min=1,max=7200,unit=s,label=How long it waits for the end of the import; past that it answers importing and the import goes on"`,
    rig:[16]u8 `mirai:"text,optional,label=Of a model: a template of Mesh2Motion fitted to its meshes and weighted to them, in place of what the source has: humanoid, fox, horse, bird, dragon, kaiju, shark, snake or spider, standing on +Y and facing -Z; source keeps the source's. Of a source in the project, the choice stays in its settings. Empty: what they say"`,
    rig_crotch:f32 `mirai:"optional,min=0,unit=m,label=With rig humanoid: the height of the crotch in the model, where a skirt or a coat hides it; 0 is where the fit finds it"`,
    rig_neck:f32 `mirai:"optional,min=0,unit=m,label=With rig humanoid: the height of the neck in the model; 0 is where the fit finds it"`,
    skeleton:[API_PATH_BYTES]u8 `mirai:"text,optional,label=Of a model: the id of a .skeleton of the project (with the same bones) its clips play on; the import writes only its clips, as an .anim bound to it, and no meshes, materials, skeleton or prefab. Of a source in the project the choice stays in its settings. Empty: what they say"`,
    front:[16]u8 `mirai:"text,optional,label=Of a model: where it stands facing once imported, when that is not the -Z every model faces: z, x or negative_x turn it about +Y to -Z with all its file holds; negative_z keeps it as read; auto turns a file that is a rig (all it draws is skinned) from where the body of its skeleton is found facing, and keeps any other as read. Of a source in the project the choice stays in its settings. Empty: what they say"`,
    image:[24]u8 `mirai:"text,optional,label=Of an image: what it holds; color (sRGB) or data (linear: a packed metallic-roughness or occlusion or a mask) or normal or normal_green_down (DirectX). Of a source in the project the choice stays in its settings. Empty: what they say or else what its name says"`,
}

Import_Status_Result :: struct {
    importing:bool,
    ok:bool `mirai:"label=The last import that ended wrote its assets"`,
    path:[API_PATH_BYTES]u8 `mirai:"text,label=The source"`,
    scene:[API_PATH_BYTES]u8 `mirai:"text,label=The scene a map became; empty for another source"`,
    message:[IMPORT_MESSAGE_BYTES]u8 `mirai:"text"`,
    warnings:[1][IMPORT_MESSAGE_BYTES]u8 `mirai:"list,text,label=What the last import that ended warned of: what it left out or assumed, and how to change it"`,
    seconds:f64 `mirai:"label=From the request until the editor took what it wrote"`,
    unzoned:f64 `mirai:"label=Of seconds, those no zone covers on the thread that imports and the editor's; with profile"`,
    publishing:bool `mirai:"label=The programs the last import wrote are being published; with profile, programs.publish is a zone once they are"`,
    assets:[1]Import_Status_Asset `mirai:"list,label=What the last import that ended wrote"`,
    zones:[1]Import_Status_Zone `mirai:"list,label=With profile: each zone of the last import by name and the zone that held it, the zones a zone held after it and one deeper, heaviest first"`,
}
Import_Status_Zone :: struct {
    name:[48]u8 `mirai:"text"`,
    depth:int,
    seconds:f64 `mirai:"label=Summed over the threads"`,
    owner:f64 `mirai:"label=Of seconds, those on the thread that imports or the editor's"`,
    count:int,
}
Import_Status_Asset :: struct {
    path:[API_PATH_BYTES]u8 `mirai:"text,label=Under the asset folder"`,
    asset:base.Asset_Id,
    kind:[32]u8 `mirai:"text"`,
    kept:bool `mirai:"label=Its file already was what the import gives"`,
}

Graphics_Status :: struct {
    preset:[16]u8 `mirai:"text,label=Low Medium High or Ultra; Custom when the settings match none"`,
    frame_limit:u32 `mirai:"label=Frames per second; 0 is unlimited"`,
    vsync:bool,
    frame_generation:bool `mirai:"label=Asked for: only a technique that offers it (FSR 3.1) generates frames"`,
    generated:bool `mirai:"label=The last frame drew an image shown before its own"`,
    render_scale:f32 `mirai:"label=The 3D image per point of the window; 0 follows the target of the preset"`,
    preset_height:u32 `mirai:"label=The lines the last preset aims for; 0 is one per point"`,
    antialiasing:[24]u8 `mirai:"text,label=The technique of the setting: off or taa or one a plugin offers"`,
    options:[GRAPHICS_ROWS_CAPACITY]Api_Graphics_Option `mirai:"trim,label=Every option of the popup with its choices"`,
    fps,gpu_ms:f32,
}

Api_Graphics_Option :: struct {
    name:[16]u8 `mirai:"text,label=The option as the graphics popup names it"`,
    choice:[32]u8 `mirai:"text,label=Its choice now; empty when its values are none of the choices"`,
    choices:[8][32]u8 `mirai:"text,trim,label=The choices of the option"`,
}

@(private)
tools_api_register :: proc(s:^Session,st:^Api_State) {
    ai_api_register(s,st)
    settings_api_register(s,st)
    input_api_register(s,st)
    project_api_register(s,st)
    preferences_api_register(s,st)
    player_launch_api_register(s,st)
    materials_api_register(s,st)
    audio_api_register(s,st)
    records_api_register(s,st)
    programs_api_register(s,st)
    material_document_register(s,st)
    import_default:=Import_Params{seconds=API_IMPORT_SECONDS}
    api_register(s,st,{name="asset.import",flags={.Core},summary="Imports a source file from anywhere on disk into the asset folder as the Import button of the content browser does: a model, an image, a sound, a font, a CSV of texts, prompts or a source a plugin imports. Answers when it ends, with whether it wrote its assets, what it said and what it wrote; importing it again updates those assets.",params=Import_Params,result=Import_Status_Result,writes_result=true,defaults=&import_default,run=api_asset_import})
    api_register(s,st,{name="asset.import_status",summary="Whether an import runs, and of the last one that ended: whether it wrote its assets, what it said and what it wrote.",result=Import_Status_Result,writes_result=true,flags={.Read_Only},run=api_asset_import_status})
    api_register(s,st,{name="graphics.status",summary="The graphics settings the renderer runs with (those of the game that plays while one does), the pacing of the frames and the cost of the last ones.",result=Graphics_Status,flags={.Read_Only},run=api_graphics_status})
}

// A source is absolute or relative to the project, not to where the editor runs.
@(private)
asset_import_source :: proc(s:^Session,path:string) -> string {
    native,ok:=project.path_native(path)
    if !ok || native=="" || filepath.is_abs(native) || s.project_root=="" {return path}
    return project.path(s.project_root,native,allocator=context.temp_allocator)
}

@(private)
api_asset_import :: proc(s:^Session,call:^api.Call) {
    params:=api.call_params(call,Import_Params)
    // A person picks the files.
    if api_asks(s,base.text_get(params.path[:])) {
        import_ask(s)
        api_import_status_write(s,call.out)
        return
    }
    path:=asset_import_source(s,base.text_get(params.path[:]))
    folder:=base.text_get(params.folder[:])
    if folder!="" {
        r:=files_registry(s)
        if r==nil {
            api.call_fail(call,api.SERVER_ERROR,"The project has no asset folder to import into")
            return
        }
        refusal:string
        if folder,refusal=asset_folder_clean(r,folder);refusal!="" {
            api.call_failf(call,api.INVALID_PARAMS,"folder: %s",refusal)
            return
        }
    }
    rig:Maybe(importer.Import_Settings)
    if text:=base.text_get(params.rig[:]);text!="" {
        kind,known:=importer.rig_from_name(text)
        if !known {
            api.call_failf(call,api.INVALID_PARAMS,"rig %q: give humanoid, fox, horse, bird, dragon, kaiju, shark, snake or spider to fit that template, or source for the skeleton the source has",text)
            return
        }
        rig=importer.Import_Settings{rig=kind,rig_crotch=params.rig_crotch,rig_neck=params.rig_neck}
    }
    if settings,given:=rig.?;(!given || settings.rig!=.Humanoid) && (params.rig_crotch!=0 || params.rig_neck!=0) {
        api.call_fail(call,api.INVALID_PARAMS,"rig_crotch and rig_neck go with rig humanoid")
        return
    }
    image:Maybe(importer.Image_Use)
    if text:=base.text_get(params.image[:]);text!="" {
        use,known:=sources.image_use_from_name(text)
        if !known {
            api.call_failf(call,api.INVALID_PARAMS,"image %q: give color for sRGB colors, data for linear values (packed metallic-roughness, occlusion, masks), normal or normal_green_down",text)
            return
        }
        image=use
    }
    skeleton:base.Asset_Id
    if text:=base.text_get(params.skeleton[:]);text!="" {
        problem:string
        if skeleton,problem=asset_resolve(s,text,".skeleton");problem!="" {
            api.call_failf(call,api.INVALID_PARAMS,"skeleton: %s",problem)
            return
        }
    }
    front:Maybe(importer.Front)
    if text:=base.text_get(params.front[:]);text!="" {
        stated,known:=importer.front_from_name(text)
        if !known {
            api.call_failf(call,api.INVALID_PARAMS,"front %q: give z, x or negative_x for where the model stands facing once imported, negative_z to keep it as read, or auto to turn a rig from where its body faces",text)
            return
        }
        front=stated
    }
    if !import_file(s,path,folder,params.profile,rig,image,skeleton,front) {
        api.call_fail(call,api.SERVER_ERROR,string(s.importer.message[:s.importer.message_length]))
        return
    }
    importing :: proc(s:^Session,user:rawptr) -> bool {return s.importer.running!=nil}
    api_wait(s,f64(params.seconds),nil,importing,"importing")
    api_import_status_write(s,call.out)
}

@(private)
api_asset_import_status :: proc(s:^Session,call:^api.Call) {api_import_status_write(s,call.out)}

@(private)
api_import_status_write :: proc(s:^Session,w:^serial.Writer) {
    status:=&s.importer.status
    serial.text_write_raw(w,`{"importing":`);serial.text_write_raw(w,status.importing?"true":"false")
    api.write_key(w,"ok");serial.text_write_raw(w,status.ok?"true":"false")
    api.write_key(w,"path");serial.text_write_string(w,base.text_get(status.path[:]))
    api.write_key(w,"scene");serial.text_write_string(w,base.text_get(status.scene[:]))
    api.write_key(w,"message");serial.text_write_string(w,base.text_get(status.message[:]))
    api.write_key(w,"warnings");serial.write_u8(w,'[')
    for warning,i in s.importer.warnings {
        if i>0 {serial.write_u8(w,',')}
        serial.text_write_string(w,warning)
    }
    serial.write_u8(w,']')
    api.write_key(w,"seconds");serial.text_write_float(w,transmute(u64)status.seconds,8)
    api.write_key(w,"unzoned");serial.text_write_float(w,transmute(u64)status.unzoned,8)
    api.write_key(w,"publishing");serial.text_write_raw(w,s.importer.publishing!={}?"true":"false")
    api.write_key(w,"assets");serial.write_u8(w,'[')
    for written,i in s.importer.written {
        if i>0 {serial.write_u8(w,',')}
        serial.text_write_raw(w,`{"path":`);serial.text_write_string(w,written.path)
        api.write_key(w,"asset");api_asset_write(w,written.id)
        api.write_key(w,"kind");serial.text_write_string(w,api_asset_kind_name(s,written.kind))
        api.write_key(w,"kept");serial.text_write_raw(w,written.kept?"true":"false")
        serial.write_u8(w,'}')
    }
    serial.write_u8(w,']')
    api.write_key(w,"zones");serial.write_u8(w,'[')
    for zone,i in s.importer.zones {
        if i>0 {serial.write_u8(w,',')}
        serial.text_write_raw(w,`{"name":`);serial.text_write_string(w,zone.name)
        api.write_key(w,"depth");serial.text_write_int(w,i64(zone.depth))
        api.write_key(w,"seconds");serial.text_write_float(w,transmute(u64)zone.seconds,8)
        api.write_key(w,"owner");serial.text_write_float(w,transmute(u64)zone.owner,8)
        api.write_key(w,"count");serial.text_write_int(w,i64(zone.count))
        serial.write_u8(w,'}')
    }
    serial.text_write_raw(w,"]}")
}

@(private)
api_graphics_fill :: proc(s:^Session,result:^Graphics_Status,g:^erender.Graphics_Settings) {
    if g==nil {return}
    base.text_set(result.preset[:],graphics_quality_label(erender.graphics_quality_of(g^)))
    result.frame_limit,result.vsync,result.render_scale,result.preset_height=g.frame_limit,g.vsync,g.render_scale,g.preset_height
    result.frame_generation=g.frame_generation
    technique:=g.antialiasing
    base.text_set(result.antialiasing[:],base.text_get(technique[:]))
    rows:=graphics_rows_of(s,erender.antialiasing_offered(s.app.renderer))
    for &each,at in rows[:min(len(rows),len(result.options))] {
        option:=&result.options[at]
        info:=&s.info.storages[each.storage]
        data:=rawptr(g) if info.type==erender.Graphics_Settings else graphics_setting_of(s,info)
        base.text_set(option.name[:],each.label)
        if choice:=graphics_row_choice(&each,data);choice>=0 {base.text_set(option.choice[:],each.choices[choice])}
        for label,i in each.choices[:min(len(each.choices),len(option.choices))] {base.text_set(option.choices[i][:],label)}
    }
    result.fps=s.app.stats.fps
    if s.app.renderer!=nil {
        stats:=gpu.renderer_stats(s.app.renderer)
        result.gpu_ms,result.generated=stats.gpu_ms,stats.generated
    }
}

@(private)
api_graphics_status :: proc(s:^Session,call:^api.Call) {
    g:=graphics_settings(s)
    if r,_:=api_play_run(s,call);r!=nil {
        if played:=core.world_storage_of(run_ref(s,r),erender.Graphics_Settings);played!=nil {g=played}
    }
    api_graphics_fill(s,api.call_result(call,Graphics_Status),g)
}

// The pointer for a tool of the viewport in a frame: whether the tool is on,
// whether the pointer is over the scene and free of a pick, and whether a
// press there begins its work. Nothing begins while the editor plays, before
// the gui of the frame, or while the tool lent the scene (tool_lend).
tool_pointer :: proc(s:^Session,name:string,input:core.Input) -> (active,over,begin:bool) {
    active=tool_on(s,name)
    over=s.viewport.hovered && !s.viewport.pick.active
    begin=active && over && s.gui.begun && !playing(s) && !tool_aside(s,name) && core.mouse_pressed(input,.Left)
    return
}

// Whether a call to a method of a tool gave a key of its params: one it did
// not give keeps its default.
tool_call_given :: proc(call:^api.Call,key:string) -> bool {
    values:[1]string
    return api.object_values(context.temp_allocator,call.raw,{key},values[:]) && values[0]!=""
}

// What a tool said when it failed (notify), as the error of a call.
tool_call_fail :: proc(s:^Session,call:^api.Call,fallback:string) {
    said:=string(s.toast[:s.toast_length])
    api.call_fail(call,api.INVALID_PARAMS,said!=""?strings.clone(said,context.temp_allocator):fallback)
}

// The name of an asset of the registry as people read it (asset_name);
// missing for one the registry does not have.
asset_name_of :: proc(a:^host.Assets,id:base.Asset_Id,missing:="") -> string {
    if a==nil || id=={} {return ""}
    file,found:=asset.registry_find(&a.registry,id)
    return found?asset_name(file.path):missing
}

// The lines a plugin draws over each selected entity with a T while the
// editor edits (the face of a mirror, the box of a decal), into vertices.
selection_gizmo :: proc(s:^Session,app:^host.App,vertices:[]gpu.Debug_Vertex,$T:typeid,draw:proc(lines:^gpu.Debug_Lines,w:core.World_Ref,e:core.Entity,value:T)) {
    if playing(s) || len(s.selection.entities)==0 {return}
    w:=shown_world(s)
    lines:=gpu.debug_lines_make(vertices,false)
    for e in s.selection.entities {
        if !entity_alive(w,e) {continue}
        if value,ok:=entity_get(w,e,T);ok {draw(&lines,w,e,value)}
    }
    if lines.count>0 {host.extras_debug_lines_add(&app.extras,lines)}
}

// The outline of a face of side 1 on the XY plane of placed, an ellipse or a
// rectangle, and the arrow of the side it shows (+Z).
gizmo_face :: proc(lines:^gpu.Debug_Lines,placed:mm.Transform,ellipse:bool,color:[4]f32) {
    SEGMENTS :: 32
    if ellipse {
        previous:=mm.transform_point(placed,{0.5,0,0})
        for i in 1..=SEGMENTS {
            angle:=f32(i)/SEGMENTS*2*math.PI
            point:=mm.transform_point(placed,{0.5*math.cos(angle),0.5*math.sin(angle),0})
            gpu.debug_line(lines,previous,point,color)
            previous=point
        }
    } else {
        corners:=[4][3]f32{{-0.5,-0.5,0},{0.5,-0.5,0},{0.5,0.5,0},{-0.5,0.5,0}}
        for corner,i in corners {
            gpu.debug_line(lines,mm.transform_point(placed,corner),mm.transform_point(placed,corners[(i+1)%4]),color)
        }
    }
    shown:=mm.quat_rotate(placed.rotation,[3]f32{0,0,1})
    gpu.debug_arrow(lines,placed.position,placed.position+shown*0.75,color)
}
