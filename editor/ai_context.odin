package editor

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"
import "mirai:asset"
import "mirai:core"
import "mirai:editor/api"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:project"
import gpu "mirai:render"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"
import "mirai:ui"

AI_FILE_PROMPT :: "prompt.md"   // the instructions of the editor
AI_PROJECT_MEMORY :: "AGENTS.md" // of the project: what its agent learned of the game, which it keeps
AI_PROJECT_SKILLS :: ".agents/skills" // of the project: the procedures its agent repeats
AI_FILE_MESSAGE :: "message.md" // what the user asked: read when the turn starts, so no text is kept in the state
AI_FILE_CONTEXT :: "context.json"
AI_FILE_IMAGE :: "region.png" // the region, cut from the capture
AI_FILE_MCP :: "mcp.json"
AI_FILE_STATE :: "state.json" // the entities selected in the paused Play, as they were when the message was sent
AI_ENTITY_CAPACITY :: 64      // entities of a region listed in the context

Ai_Entity :: struct {
    id:string,
    name:string,
    parent:string,
    position:[3]f32,
    rotation:[4]f32,
    scale:[3]f32,
    components:[]string,
    rect:[4]f32,
    inside:bool,
    indicator:bool,
}

Ai_Context_Region :: struct {
    rect:[4]f32,
    window:[2]f32,
}

Ai_Context_Camera :: struct {
    position,target:[3]f32,
    yaw,pitch,distance,fov_deg:f32,
}

Ai_Context_Document :: struct {
    path:string,
    state:u64,
    dirty:bool,
    entities:int,
}
// The asset document in front when the message was sent, instead of the scene.
Ai_Context_Asset :: struct {
    path:string,
    dirty:bool,
    picked:[]string, // what the user picked in it, by name: the nodes of an interface
    shown:string,    // what it showed, as its plugin says it: the clip and its time of an animation
}

Ai_Context_Project :: struct {root,name:string}

// A value of a material as it holds it when the message is sent; picked: the user pointed at it.
Ai_Context_Value :: struct {name,group:string,value:[]f64,picked:bool}

// The document of a material the message was sent from; empty otherwise.
Ai_Context_Material :: struct {
    material,program,file:string,
    preview:string, // the image of the region: the preview of the material
    channel:string, // what the preview showed instead of the lit sphere; empty: lit
    variant:string, // the label of the variant the preview showed, or of the one set last
    variant_applied:bool,
    parameters:[]Ai_Context_Value,
}
Ai_Context_Api :: struct {port:int,rpc,mcp,client:string}

Ai_Context :: struct {
    task,mode:string,
    instructions:string,
    region:Ai_Context_Region,
    entities:[]Ai_Entity,
    entities_in_region:int,
    camera:Ai_Context_Camera,
    selection:[]string,
    document:Ai_Context_Document,
    project:Ai_Context_Project,
    api:Ai_Context_Api,
    engine:string,
    player:Play_Player_Snapshot,
    material:Ai_Context_Material,
    asset:Ai_Context_Asset,
    references:[]string, // the images the user attached, in the folder of the turn
    assets:[]string,     // the assets the user dragged onto the chat, by their paths
    range:Ai_Context_Range, // the time the user chose on a timeline; to<=from: none
}

// The part of a rectangle that is on the window. False when what is left is
// not a region: smaller than AI_REGION_MIN on a side, or not a number.
ai_region_clamp :: proc "contextless" (rect:ui.Rect,window:[2]f32) -> (region:ui.Rect,ok:bool) {
    if rect.x-rect.x!=0 || rect.y-rect.y!=0 || rect.w-rect.w!=0 || rect.h-rect.h!=0 {return}
    low:=[2]f32{clamp(rect.x,0,window.x),clamp(rect.y,0,window.y)}
    high:=[2]f32{clamp(rect.x+rect.w,0,window.x),clamp(rect.y+rect.h,0,window.y)}
    region={low.x,low.y,high.x-low.x,high.y-low.y}
    return region,region.w>=AI_REGION_MIN && region.h>=AI_REGION_MIN
}

// The pixels of a capture of width by height that a region of the window
// covers: every pixel the region touches, kept inside the capture.
ai_crop_rect :: proc "contextless" (region:ui.Rect,window:[2]f32,width,height:int) -> (x,y,w,h:int,ok:bool) {
    if window.x<=0 || window.y<=0 || width<=0 || height<=0 {return}
    scale:=[2]f32{f32(width)/window.x,f32(height)/window.y}
    x0:=clamp(int(region.x*scale.x),0,width)
    y0:=clamp(int(region.y*scale.y),0,height)
    x1:=clamp(int((region.x+region.w)*scale.x+0.999),0,width)
    y1:=clamp(int((region.y+region.h)*scale.y+0.999),0,height)
    return x0,y0,x1-x0,y1-y0,x1>x0 && y1>y0
}

// Halves an image of four bytes per pixel: each pixel of out, of width/2 by
// height/2, is the mean of a block of 2x2 of pixels.
ai_half_pixels :: proc "contextless" (pixels:[]u8,width,height:int,out:[]u8) {
    half:=width/2
    for y in 0..<height/2 {
        for x in 0..<half {
            top,bottom:=(2*y*width+2*x)*4,((2*y+1)*width+2*x)*4
            for c in 0..<4 {
                sum:=int(pixels[top+c])+int(pixels[top+4+c])+int(pixels[bottom+c])+int(pixels[bottom+4+c])
                out[(y*half+x)*4+c]=u8((sum+2)/4)
            }
        }
    }
}

// Copies a rectangle of an image of four bytes per pixel into out, row by row.
ai_crop_pixels :: proc "contextless" (pixels:[]u8,width:int,x,y,w,h:int,out:[]u8) {
    for row in 0..<h {
        source:=pixels[((y+row)*width+x)*4:][:w*4]
        copy(out[row*w*4:][:w*4],source)
    }
}

// The command line client of the API next to the engine; empty when it was not built.
@(private)
ai_client_path :: proc(engine:string) -> string {
    if engine=="" {return ""}
    path:=project.tool_file(engine,context.temp_allocator)
    return os.is_file(path)?path:""
}

// The snapshot belongs to this message even if the camera moves later. It is
// saved at half the size of the window's pixels, enough to see the scene and
// lighter for the agent. A job writes it (task.image_write); view_viewport
// waits for it if it asks before it is done.
@(private)
ai_capture_write :: proc(s:^Session,task:^Ai_Task) -> bool {
    pixels,width,height,ok:=host.app_capture_pixels(s.app,context.allocator)
    if !ok {return false}
    defer delete(pixels)
    x,y,cw,ch,inside:=ai_crop_rect(task.region,task.window,width,height)
    if !inside {return false}
    cut:=make([]u8,cw*ch*4,context.temp_allocator)
    ai_crop_pixels(pixels,width,x,y,cw,ch,cut)
    hw,hh:=max(cw/2,1),max(ch/2,1)
    image:=make([]u8,hw*hh*4,s.app.allocator)
    if cw>=2 && ch>=2 {ai_half_pixels(cut,cw,ch,image)} else {copy(image,cut)}
    host.app_png_write_wait(s.app,&task.image_write)
    host.app_png_write_start(s.app,&task.image_write,ai_task_path(s,task,AI_FILE_IMAGE),image,hw,hh)
    return true
}

@(private)
ai_entity_id_text :: proc(w:core.World_Ref,e:core.Entity) -> string {
    id,_:=entity_get(w,e,core.Id)
    if id.value==0 {return ""}
    buffer:[16]u8
    return strings.clone(base.entity_id_format(id.value,buffer[:]),context.temp_allocator)
}

// The rectangle of the window an item takes: its box when it has a body, the disc of its origin otherwise.
@(private)
ai_item_rect :: proc(s:^Session,item:Scene_Item) -> (rect:ui.Rect,ok:bool) {
    v:=s.viewport
    if item.body {
        if low,high,known:=picker_bounds(s.picker,s.app.assets,item.mesh);known {
            return project_box(v,mm.transform_matrix(item.world),low,high)
        }
    }
    if !item.body && (!v.show_indicators || !item.indicator) {return}
    p,front:=viewport_screen(v,item.world.position)
    if !front {return}
    return {p.x-INDICATOR_RADIUS,p.y-INDICATOR_RADIUS,2*INDICATOR_RADIUS,2*INDICATOR_RADIUS},true
}

@(private)
ai_rects_meet :: proc "contextless" (a,b:ui.Rect) -> bool {
    return a.x<b.x+b.w && b.x<a.x+a.w && a.y<b.y+b.h && b.y<a.y+a.h
}

@(private)
ai_entity_context :: proc(s:^Session,w:core.World_Ref,e:core.Entity,rect:ui.Rect,indicator,inside:bool) -> Ai_Entity {
    world:=entity_world(w,e)
    info:=Ai_Entity{
        id=ai_entity_id_text(w,e),name=entity_name(w,e),
        position=world.position,rotation={world.rotation.x,world.rotation.y,world.rotation.z,world.rotation.w},scale=world.scale,
        rect={rect.x,rect.y,rect.w,rect.h},indicator=indicator,inside=inside,
    }
    if parent:=entity_parent(w,e);parent!=core.NONE {info.parent=ai_entity_id_text(w,entity_author(w,parent))}
    names:=make([dynamic]string,context.temp_allocator)
    for &t in w.info.tables {
        if t.place!=.World || !inspector_listed(s,&t) {continue}
        if core.raw_find(core.world_table_at(w,&t),t.info,e)!=nil {append(&names,t.name)}
    }
    info.components=names[:]
    return info
}

// The entities the region shows with what the API says of each of them.
@(private)
ai_entities_gather :: proc(s:^Session,task:^Ai_Task) -> []Ai_Entity {
    w:=shown_world(s)
    out:=make([dynamic]Ai_Entity,0,AI_ENTITY_CAPACITY,context.temp_allocator)
    // A document in front of the scene hides it: the region shows the document.
    if asset_document_in_front(s)!=nil {
        task.entities,task.entities_total=0,0
        return out[:]
    }
    Visual :: struct {entity:core.Entity,rect:ui.Rect,indicator:bool}
    visuals:=make([dynamic]Visual,context.temp_allocator)
    by_entity:=make(map[core.Entity]int,context.temp_allocator)
    listed:=make(map[core.Entity]bool,context.temp_allocator)
    total:=0
    items:=scene_items(s,w)
    for item in scene_item_next(&items) {
        if item.hidden {continue}
        rect,ok:=ai_item_rect(s,item)
        if !ok {continue}
        owner:=entity_author(w,item.entity)
        if at,known:=by_entity[owner];known {
            visual:=&visuals[at]
            low:=[2]f32{min(visual.rect.x,rect.x),min(visual.rect.y,rect.y)}
            high:=[2]f32{max(visual.rect.x+visual.rect.w,rect.x+rect.w),max(visual.rect.y+visual.rect.h,rect.y+rect.h)}
            visual.rect={low.x,low.y,high.x-low.x,high.y-low.y}
            visual.indicator &&= !item.body
        } else {
            by_entity[owner]=len(visuals)
            append(&visuals,Visual{owner,rect,!item.body})
        }
    }
    if s.selection!=nil {
        for e in s.selection.entities {
            if len(out)>=AI_ENTITY_CAPACITY {break}
            e:=entity_author(w,e)
            if listed[e] || !entity_alive(w,e) {continue}
            visual:=Visual{entity=e}
            if at,visible:=by_entity[e];visible {visual=visuals[at]}
            rect:=visual.rect
            inside:=rect.w>0 && rect.h>0 && rect.x>=task.region.x && rect.y>=task.region.y && rect.x+rect.w<=task.region.x+task.region.w && rect.y+rect.h<=task.region.y+task.region.h
            append(&out,ai_entity_context(s,w,e,rect,visual.indicator,inside))
            listed[e]=true
        }
    }
    for visual in visuals {
        rect,e:=visual.rect,visual.entity
        if !ai_rects_meet(rect,task.region) {continue}
        total+=1
        if len(out)>=AI_ENTITY_CAPACITY || listed[e] {continue}
        inside:=rect.x>=task.region.x && rect.y>=task.region.y && rect.x+rect.w<=task.region.x+task.region.w && rect.y+rect.h<=task.region.y+task.region.h
        append(&out,ai_entity_context(s,w,e,rect,visual.indicator,inside))
        listed[e]=true
    }
    task.entities,task.entities_total=len(out),total
    return out[:]
}

@(private)
ai_context_write :: proc(s:^Session,task:^Ai_Task,entities:[]Ai_Entity) -> bool {
    w:=shown_world(s)
    port:=api_port(s)
    name:=filepath.base(s.project_root)
    if p,error:=project.open(s.project_root,s.engine_root,context.temp_allocator);error.code==.None {
        if title:=project.window_title(&p.manifest);title!="" {name=strings.clone(title,context.temp_allocator)}
    }
    o:=s.viewport.orbit
    selection:=make([dynamic]string,context.temp_allocator)
    front:=asset_document_in_front(s)
    if s.selection!=nil && front==nil {
        for e in s.selection.entities {
            if text:=ai_entity_id_text(w,e);text!="" {append(&selection,text)}
        }
    }
    document:=Ai_Context_Document{path=document_path(s.document),state=edits_scene_state(s.edits),dirty=document_dirty(s),entities=core.world_entities(w).alive}
    context_value:=Ai_Context{
        task=base.text_get(task.name[:]),mode=task.play?"play":"edit",instructions=ai_instructions_read(s),
        region={rect={task.region.x,task.region.y,task.region.w,task.region.h},window=task.window},
        camera={position=orbit_position(o),target=o.target,yaw=o.yaw,pitch=o.pitch,distance=o.distance,fov_deg=o.fov},
        selection=selection[:],document=document,
        project={root=s.project_root,name=name},
        api={port=port,rpc=fmt.tprintf("http://127.0.0.1:%d/rpc",port),mcp=fmt.tprintf("http://127.0.0.1:%d/mcp",port),client=ai_client_path(s.engine_root)},
        engine=s.engine_root,
    }
    if task.play {context_value.player=play_player_snapshot(run_ref(s,ai_task_run(s,task)))}
    context_value.material,_=ai_material_context(s,task)
    references:=make([]string,task.references,context.temp_allocator)
    for &file,i in references {file=ai_reference_file(i+1)}
    context_value.references=references
    context_value.assets=ai_attachment_paths(s,task)
    context_value.range=ai_context_range(&task.range)
    context_value.entities=entities
    context_value.entities_in_region=task.entities_total
    if front!=nil {
        picked:=make([]string,front.picked_count,context.temp_allocator)
        for &name,i in picked {name=base.text_get(front.picked[i][:])}
        context_value.asset={path=asset_document_path(s,front),dirty=asset_document_dirty(s,front),picked=picked,shown=strings.clone(base.text_get(front.shown[:]),context.temp_allocator)}
    }
    data,error:=json.marshal(context_value,{pretty=true},context.temp_allocator)
    if error!=nil {return false}
    return os.write_entire_file(ai_task_path(s,task,AI_FILE_CONTEXT),data)==nil && ai_state_write(s,task,w)
}

// The tick of the paused Play of the user a message is sent from; false
// outside the pause.
@(private)
ai_paused_tick :: proc(s:^Session,task:^Ai_Task) -> (tick:u64,paused:bool) {
    if !task.play || s.mode!=.Paused {return}
    r:=ai_task_run(s,task)
    if r==nil {return}
    if t:=core.world_storage_of(run_ref(s,r),core.Time);t!=nil {tick=t.tick}
    return tick,true
}

// The entities selected in the paused Play, with the values of their
// components at that tick: what the message refers to, which the game may
// change once it resumes. A turn sent otherwise has none.
@(private)
ai_state_write :: proc(s:^Session,task:^Ai_Task,w:core.World_Ref) -> bool {
    path:=ai_task_path(s,task,AI_FILE_STATE)
    tick,paused:=ai_paused_tick(s,task)
    st:=api_state(s)
    if !paused || st==nil || s.selection==nil || len(s.selection.entities)==0 || asset_document_in_front(s)!=nil {
        if os.exists(path) {return os.remove(path)==nil}
        return true
    }
    scratch,memory:=make([]u8,max(st.largest,1),context.temp_allocator)
    if memory!=nil {return false}
    out:serial.Writer
    serial.writer_init(&out,0,context.temp_allocator)
    serial.text_write_raw(&out,`{"tick":`);serial.text_write_int(&out,i64(tick))
    api.write_key(&out,"entities");serial.write_u8(&out,'[')
    first:=true
    for e in s.selection.entities {
        if !entity_alive(w,e) {continue}
        if !first {serial.write_u8(&out,',')}
        first=false
        api_entity_write(s,w,&out,e,true,scratch,true,true)
    }
    serial.text_write_raw(&out,"]}")
    return os.write_entire_file(path,serial.writer_bytes(&out))==nil
}

// The methods a turn uses most, named in the instructions by their MCP tool.
AI_PROMPT_TOOLS :: [?]string{"scene.inspect","scene.write","scene.add","scene.set","scene.delete","scene.batch","play.start","play.step","play.inspect","play.check","play.set","play.capture","play.stop","view.viewport","editor.capture","panel.save","asset.import","profile.audit","finish","engine.describe"}
// The methods whose parameters go in the instructions, from the live
// registry: most of what a turn does, without looking their schemas up.
AI_PROMPT_SCHEMAS :: [?]string{"scene.inspect","scene.write","scene.add","scene.set","scene.delete","scene.batch","finish"}

// The instructions of a turn. The agent works on the game of the project:
// the open scene through the API, Play to test it, and game code in the
// project folder, which it builds. The engine is not its work: of it, it only
// gets the declarations the project compiles against and the gameplay skill.
@(private)
ai_prompt_write :: proc(s:^Session,task:^Ai_Task,entities:[]Ai_Entity) -> bool {
    b:=strings.builder_make(context.temp_allocator)
    engine:=s.engine_root
    turn:=base.text_get(task.name[:])
    fmt.sbprintf(&b,"You are the game agent of the Mirai project at %s, working from inside its editor, which is running.\n",s.project_root)
    strings.write_string(&b,"Respond in English. Do not narrate tool use, progress, or collection of automatically supplied context. Do not write assistant chat messages before or after completing the task.\n")
    strings.write_string(&b,"Call the `mirai` MCP tool `finish` exactly once when this request is complete. For questions or explanations, put the final English answer in its optional `response` field. For tasks whose result is visible in the editor, omit `response`. This is the only way to send a response to the user; finish with an empty assistant response afterward.\n")
    strings.write_string(&b,"When `response` names entities of the scene, write each one as [Name](entity:ID) with the id the API gives it: the chat shows it as a pill that selects it. Name an asset you created or changed as [Name](asset:path), with its path under the assets folder (materials/Wet stone.mat): the pill opens its document.\n")
    fmt.sbprint(&b,"When you need the user to decide instead of guessing, finish with a `question` instead of closing the subject; their answer arrives as the next message of this conversation.\n")
    strings.write_string(&b,"- Your work is the game of this project: edit the open scene through the editor API, play it when the user asks to try or test something, and write game code (components, storages and loop functions) in the project folder when the request needs it. Do only what the request asks. The engine is not part of your work: do not read or change its source or its documentation, and do not write outside the project folder.\n")
    fmt.sbprintf(&b,"- You build the code you write; the user never does. `%s` compiles it and a build that succeeds loads it into the running editor, new components and storages too, without closing it or ending this turn; `%s` says when it ends, and `%s` lists its errors (`build`, with file and line). `%s` checks the types without building, and `%s` runs the @(test) procedures of the project. `play_start` builds first by itself when an Odin source changed.\n",ai_tool_name("build.start"),ai_tool_name("build.status"),ai_tool_name("engine.diagnostics"),ai_tool_name("build.check"),ai_tool_name("build.test"))
    if decl,plugins:=code_api_folders(s);decl!="" {
        fmt.sbprintf(&b,"- The public API the code of the project compiles against is in %s (the collection `mirai`)",decl)
        if plugins!="" {fmt.sbprintf(&b," and %s (the collection `plugins`)",plugins)}
        strings.write_string(&b,": read the declarations there for the types and procedures you use, not the sources of the engine.\n")
    }
    strings.write_string(&b,"- You may read files outside the project only to import them, as when the user names a model in Downloads or an image in Pictures: `asset_import` takes the path wherever it is and writes the assets into the project, in `folder` when given; it runs in the background and `asset_import_status` says when it ended and what it wrote. Deleting a file asks the user first and moving one does not; delete an asset with `asset_delete`, which moves it to the trash, after `asset_users` says what uses it.\n")
    strings.write_string(&b,"- When the game is slow or the user asks about performance, measure instead of guessing: `profile_audit` measures the open scene, or Play once `play_start` runs it, and answers whether the performance budgets of project.mirai hold (the user decides them; `project_set` changes them) with findings, the severest first. Act on those whose `actionable` is true: owner `game` or `project_plugin` is code of the project and `scene` is what it draws; `plugin` and `engine` are not your work, so report them instead. The `next` of a finding is the call that explains it. Before changing something for performance, audit with `save` to keep a baseline; after it, audit with `baseline` to show what changed, and say whether it helped. With VSync or a frame limit on it refuses and says how to turn them off; `allow_limited` measures anyway, against the CPU time of the frames.\n")
    strings.write_string(&b,"- Saved games of the project: `save.list` and `save.inspect` read their slots and `save.delete` removes one; `save.write` and `save.load` save and load your run of the game as the game asks for it, so start it with `play.start` first.\n")
    if gameplay:=project.path(engine,".agents/skills/mirai-gameplay/SKILL.md",allocator=context.temp_allocator);engine!="" && os.is_file(gameplay) {
        fmt.sbprintf(&b,"- Only when you write game code, read %s and the references it links; it is the only engine documentation you need. Editing the scene does not need it.\n",gameplay)
    }
    fmt.sbprintf(&b,"- The memory of this project is yours to keep, in its folder, versioned with the game: %s says how this game is made (what each system does, its conventions, what the user decided) and %s holds the procedures you repeat, one SKILL.md per folder with a name and a description. Read AGENTS.md when a chat starts, if it exists. Write there only what matters and holds beyond this request: a decision of the user, a convention of this game, how one of its systems works, a trap that cost you time. Not the details of a task, nothing trivial, nothing the code or the scene already says. Each one is a line under its topic that replaces what it changes: the file describes the game as it is now, not a log of what was done.\n",project.path(s.project_root,AI_PROJECT_MEMORY,allocator=context.temp_allocator),project.path(s.project_root,AI_PROJECT_SKILLS,allocator=context.temp_allocator))
    strings.write_string(&b,"- The earlier chats of this project are its raw memory: `ai.history.search`, through `call`, finds what was asked, answered or done in them by words, an entity id or an asset path, and `ai.history` with the `id` of a hit's conversation and `before` reads the messages around it.\n")
    strings.write_string(&b,"- The MCP server `mirai` of the editor has one tool per API method, named after it with `_` for `.`; call them directly:")
    for method,i in AI_PROMPT_TOOLS {fmt.sbprintf(&b,"%s `%s`",i==0?"":",",ai_tool_name(method))}
    strings.write_string(&b,".\n")
    strings.write_string(&b,"- Entity ids are 16 hex digits in strings. An edit changes only the fields it names, and the user may edit meanwhile: read again before you rely on what you read earlier. Edits that belong together go in one `scene_batch` (up to 64, one undo step). To build or rewrite a group of entities, `scene_write` declares an entity and what hangs from it as one nested document in one step; `scene_inspect` with `root` gives that document to edit and write back. A method that fails changes nothing.\n")
    if st:=api_state(s);st!=nil {
        listed:=false
        for name in AI_PROMPT_SCHEMAS {
            method:=api.method_find(&st.server,name)
            if method==nil {continue}
            if !listed {strings.write_string(&b,"- Parameters of the tools used most, as JSON Schema; they are complete, so call those tools without looking them up (`engine_describe` has the others: without params it lists the methods and the plugins, and `methods`, `plugin` or `prefix` give the schemas of a few):\n");listed=true}
            w:serial.Writer
            serial.writer_init(&w,0,context.temp_allocator)
            api.method_schema_write(&w,&st.server,method,false)
            fmt.sbprintf(&b,"  - `%s`: %s\n",name,string(serial.writer_bytes(&w)))
        }
    }
    if len(entities)>0 {
        strings.write_string(&b,"- Entities the user had in view when they sent this message, the selected ones first; one per line: id | name | parent | world position | world scale | components. `scene_inspect` lists the whole scene and the values of the components.\n")
        for &entity in entities {
            selected:=false
            if s.selection!=nil {for e in s.selection.entities {if ai_entity_id_text(shown_world(s),e)==entity.id {selected=true;break}}}
            fmt.sbprintf(&b,"  - %s | %s%s | %s | %.3g %.3g %.3g | %.3g %.3g %.3g | ",entity.id,entity.name,selected?" (selected)":"",entity.parent,entity.position.x,entity.position.y,entity.position.z,entity.scale.x,entity.scale.y,entity.scale.z)
            for component,i in entity.components {fmt.sbprintf(&b,"%s%s",i==0?"":", ",component)}
            strings.write_string(&b,"\n")
        }
        if task.entities_total>len(entities) {fmt.sbprintf(&b,"  - and %d more in view\n",task.entities_total-len(entities))}
    }
    if task.image {
        fmt.sbprintf(&b,"- `view_viewport` with request `%s` shows what the user was looking at when they sent this message.\n",turn)
    }
    if task.references>0 {
        fmt.sbprintf(&b,"- The user attached %d reference image%s to this message, after its text, to show what they want the result to look like. Look at them before you start.\n",task.references,task.references>1?"s":"")
    }
    ai_attachments_prompt(s,task,&b)
    ai_range_prompt(task,&b)
    fmt.sbprintf(&b,"- %s has the region, the camera, the selection and the open scene.\n",ai_task_path(s,task,AI_FILE_CONTEXT))
    strings.write_string(&b,"- To let the user try a scene in Play, write a link to it in your response as `[What to try](play:path of the scene under the assets folder)`: the chat draws it as a button that opens the scene and plays it.\n")
    strings.write_string(&b,"- The tools of the server `mirai` are the basics of a scene. Every other method, of the editor or of a plugin (animation, terrain, navigation, physics, particles, interfaces and the rest), goes through the tool `call` with its name as `method` and its `params`; `engine_describe` with `methods` (several names at once), `prefix` or `plugin` gives their schemas. The methods named below by their tool name (such as `panel_save`) go through `call` too when they are not tools.\n")
    if tool:=ai_client_path(engine);tool!="" {fmt.sbprintf(&b,"- For many calls, write and run a script instead of calling tools one by one, with `%s rpc <method> '<json>'` (or `--file params.json`) for each call, never with requests of your own to the editor.\n",tool)}
    strings.write_string(&b,"- Do not edit scene files while the editor has them open.\n")
    if tick,paused:=ai_paused_tick(s,task);paused {
        fmt.sbprintf(&b,"- The game of the user is paused at tick %d. Answer questions about it using read-only observations: `play.player`, `play.status` and `play.inspect` with `include_runtime=true`. Do not edit files or scenes, resume, step or stop the game, or mutate the paused world.\n",tick)
        if os.exists(ai_task_path(s,task,AI_FILE_STATE)) {
            fmt.sbprintf(&b,"- %s has the entities the user selected in the paused game, which the message refers to, with the values of their components at tick %d, when they sent it.\n",ai_task_path(s,task,AI_FILE_STATE),tick)
        }
    } else if task.play {
        strings.write_string(&b,"- The game is playing. Answer questions about the live game and player using read-only observations. The context includes a player snapshot; use `play.player`, `play.status` and `play.inspect` with `include_runtime=true` for current values, components of the body it drives and runtime storage. Do not edit files or scenes, stop or pause the game, or mutate the playing world.\n")
    }
    strings.write_string(&b,"- To test the game, `play_start` opens a copy of your own that only `play_step` advances, with keys, the pointer (`mouse_position` clicks its UI), `text`, gamepads of local seats, `segments` that change them along the ticks (each held for `ticks` or `seconds`, `tap_keys` for a press shorter than a tick, `mouse_delta` spread over the segment), `until` to run until conditions hold and a `trace` that returns values every some ticks; test as a player does: a click is a press of a few ticks then a release, a double click two of them with a gap, and `play_input` with `segments` schedules that input for the next steps so you look between them. `play_view` says what the player sees (camera, mode and blend, distance to what it follows, where entities show on the screen); `view` in a `trace` or a `play_check` condition asserts on it. Change your copy between steps with `play_set` (component values and teleports), `play_spawn`, `play_destroy` and `play_push` (requests to its queues); read it with `play_inspect` (`storages` gives score and match state) and assert with `play_check`; `play_ui` gives its live interface with the rectangle of each node to click and `play_audio` the voices that sound. `play_capture` returns the image of your copy (with `every` and `count`, one filmstrip of it stepping, around an entity it `follow`s), and `editor_capture` that of the editor or of an open `.ui`. In the scene, `scene_raycast`, `scene_bounds` and `scene_ground` (rests entities on what is under them) answer where things are. A test to play again after each change is a scenario file in `tests/scenarios/` (its scene, the params of play.start and its steps as play methods with their params) that `play.scenario.run` plays from tick 0 and reports step by step.\n")
    strings.write_string(&b,"- When the user asks for an interface, panel or controls of their own (to try the sky, the post process or the lights, to compare configurations), make it with `panel_save` instead of writing editor code: for variants to try, give it buttons, each setting its fields to its values (on one entity, or with `where` on every entity whose fields match, found when it is pressed), without rows for those fields; buttons are pressed in any order, so every button that sets a target sets all the fields the others set there (an Off button sets intensity 0, so the others set their intensity too); rows show fields the user tunes by hand with the controls of the editor (with `where`, every matching entity at once, as to soften what a button set), and headings group them; the panel has Restore. It is kept in the project, opens at once in place of Details and stays in the Tools menu; `panel_list` gives the saved ones to change, and saving with the same id replaces one.\n")
    strings.write_string(&b,"- When something does not play, move, spawn or show, read `engine.diagnostics`: its `problems` list, by world and entity, what the functions of the game could not do and how to fix it. After fixing one, step again: it is fixed when its `last` stops passing the `serial` you read.\n")
    // How to use the methods of a plugin goes with them, in engine_describe;
    // here only when the message comes from a document of that plugin.
    strings.write_string(&b,"- engine_describe with `plugin` (such as animation, cinematics, physics or paint) or with a `prefix` (such as material.program) gives those methods with a guide to them: read it before using them.\n")
    if topic:=ai_guide_topic_in_front(s);topic!="" {
        if guide:=ai_guide(topic);guide!="" {fmt.sbprintf(&b,"- %s\n",guide)}
    }
    if front:=asset_document_in_front(s);front!=nil && front.kind!=asset.KIND_MATERIAL {
        fmt.sbprintf(&b,"- This message comes from the document of %s, not from the scene",asset_document_path(s,front))
        if asset_document_dirty(s,front) {strings.write_string(&b," (it has unsaved changes)")}
        if task.image {strings.write_string(&b,"; `view_viewport` shows it as the user saw it")}
        strings.write_string(&b,".\n")
        if shown:=base.text_get(front.shown[:]);shown!="" {fmt.sbprintf(&b,"- It showed %s.\n",shown)}
        if front.picked_count>0 {
            strings.write_string(&b,"- The user picked in it:")
            for i in 0..<front.picked_count {fmt.sbprintf(&b,"%s %s",i==0?"":",",base.text_get(front.picked[i][:]))}
            strings.write_string(&b,".\n")
        }
    }
    if material,about:=ai_material_context(s,task);about {
        fmt.sbprintf(&b,"- This message comes from the document of %s (program %s",material.material!=""?material.material:"a program",material.program)
        if material.file!="" {fmt.sbprintf(&b,", %s",material.file)}
        strings.write_string(&b,")")
        if material.preview!="" {strings.write_string(&b,"; `view_viewport` shows its preview as the user saw it")}
        strings.write_string(&b,".\n")
        if material.channel!="" {fmt.sbprintf(&b,"- The preview showed the %s channel of the material, not the lit sphere.\n",material.channel)}
        if material.variant!="" && material.variant_applied {fmt.sbprintf(&b,"- The user set the variant %q, which you proposed, on the material.\n",material.variant)}
        if material.variant!="" && !material.variant_applied {fmt.sbprintf(&b,"- The preview showed the variant %q, which you proposed, instead of the material, which does not have it.\n",material.variant)}
        if len(material.parameters)>0 {
            strings.write_string(&b,"- The values of the material when the message was sent; the picked ones are those the user pointed at:\n")
            for value in material.parameters {
                fmt.sbprintf(&b,"  - %s",value.name)
                if value.group!="" {fmt.sbprintf(&b," (group %s)",value.group)}
                strings.write_string(&b,":")
                for component in value.value {fmt.sbprintf(&b," %.4g",component)}
                if value.picked {strings.write_string(&b," (picked)")}
                strings.write_string(&b,"\n")
            }
        }
    }
    if instructions:=ai_instructions_read(s);instructions!="" {fmt.sbprintf(&b,"\nAdditional editor instructions:\n%s\n",instructions)}
    return os.write_entire_file(ai_task_path(s,task,AI_FILE_PROMPT),strings.to_string(b))==nil
}

// The document of a material a message was sent from: the material, its
// program and its file, the channel and the variant, and the
// values the user picked as the material holds them.
@(private)
ai_material_context :: proc(s:^Session,task:^Ai_Task) -> (out:Ai_Context_Material,ok:bool) {
    m:=&task.material
    if !m.open {return}
    out.material=strings.clone(base.text_get(m.material[:]),context.temp_allocator)
    out.program=strings.clone(base.text_get(m.program[:]),context.temp_allocator)
    out.channel=strings.clone(base.text_get(m.channel[:]),context.temp_allocator)
    out.variant=strings.clone(base.text_get(m.variant[:]),context.temp_allocator)
    out.variant_applied=m.variant_applied
    if task.image {out.preview=AI_FILE_IMAGE}
    out.parameters=ai_material_values(s,m)
    if out.program=="" {return out,true}
    if path,_,found:=program_locate(s,out.program);found {out.file=file_relative(s,path)}
    return out,true
}

// The values of the material of a document as it holds them, those the user
// picked marked: the parameters of its program that are not textures, or
// those of the standard model.
@(private)
ai_material_values :: proc(s:^Session,m:^Ai_Material_Context) -> []Ai_Context_Value {
    a:=s.app!=nil?s.app.assets:nil
    if a==nil || m.id=={} {return nil}
    loaded:=host.assets_material(a,m.id)
    if loaded==nil || loaded.failed {return nil}
    desc:=host.assets_material_values(a,loaded.row)
    program:=erender.surface_program(a,desc.program_id)
    picked :: proc(m:^Ai_Material_Context,name:string) -> bool {
        for i in 0..<m.pick_count {if base.text_get(m.picks[i][:])==name {return true}}
        return false
    }
    values:=make([dynamic]Ai_Context_Value,0,8,context.temp_allocator)
    if program!=nil {
        for &parameter in program.parameters {
            if parameter.kind==.Texture {continue}
            numbers:=gpu.program_parameter_get(&desc.custom_params,&parameter)
            append(&values,Ai_Context_Value{parameter.name,parameter.group,slice.clone(numbers[:parameter.components],context.temp_allocator),picked(m,parameter.name)})
        }
        return values[:]
    }
    info:=&loaded.info
    standard:=[4]struct{name:string,value:[]f32}{{"base_color",info.base_color[:]},{"roughness",slice.from_ptr(&info.roughness,1)},{"metallic",slice.from_ptr(&info.metallic,1)},{"emission",info.emission[:]}}
    for entry in standard {
        out:=make([]f64,len(entry.value),context.temp_allocator)
        for v,c in entry.value {out[c]=f64(v)}
        append(&values,Ai_Context_Value{entry.name,"",out,picked(m,entry.name)})
    }
    return values[:]
}

// The MCP tool of an API method: its name with `_` for `.`.
@(private)
ai_tool_name :: proc(method:string) -> string {
    name,_:=strings.replace_all(method,".","_",context.temp_allocator)
    return name
}

// The MCP servers of the task for a client that takes them from a file: the
// editor, through its command line client when it is built and by HTTP otherwise.
@(private)
ai_mcp_write :: proc(s:^Session,task:^Ai_Task) -> bool {
    text:=fmt.tprintf(`{{"mcpServers":{{"mirai":{{"type":"http","url":"http://127.0.0.1:%d/mcp","headers":{{"X-Mirai-Ai-Task":"%s"}}}}}}}}`+"\n",api_port(s),base.text_get(task.name[:]))
    return os.write_entire_file(ai_task_path(s,task,AI_FILE_MCP),text)==nil
}

// Creates a task for a region of the window: its folder with the capture, the
// context and the prompt, and its place in the queue, which starts it at once
// when no agent runs. The last frame drawn is the window the region is about,
// so whoever calls draws a frame first. Between frames only;
// message says why there is none.
ai_task_create :: proc(s:^Session,m:^Ai,region:ui.Rect,prompt,agent:string,continuing:int=0,model:string="",effort:string="") -> (task:^Ai_Task,message:string) {
    text:=strings.trim_space(prompt)
    if text=="" {return nil,"The task needs a prompt"}
    if len(text)>=AI_MESSAGE_BYTES {return nil,"The prompt is too long"}
    if api_port(s)==0 {return nil,"The editor serves no API for the agent to use"}
    clamped,ok:=ai_region_clamp(region,s.viewport.window)
    if !ok {return nil,"The region is outside the window, or too small"}
    if !s.has_project {return nil,"The editor has no project folder"}
    ai_initialize(s)
    if m.store.folder=="" {return nil,"The project chat history is unavailable"}
    chosen_agent:=agent
    if chosen_agent=="" && continuing!=0 {
        if previous:=ai_task_find(m,continuing);previous!=nil {
            chosen_agent=string(previous.conversation.provider[:previous.conversation.provider_len])
        }
    }
    if chosen_agent=="" {chosen_agent=base.text_get(m.agent[:])}
    if chosen_agent=="" {
        for &connection in ai_connections(m) {
            if connection.configured {chosen_agent=base.text_get(connection.id[:]);break}
        }
    }
    provider,known:=ai_provider_find(m,chosen_agent)
    if chosen_agent!="" && !known {return nil,"Unknown AI connection"}
    chosen:=ai_connection_id(m,provider)
    connection:=&m.connections[provider]
    // A session keeps its own model and effort; a new one takes those of its agent.
    chosen_model,chosen_effort:=base.text_get(connection.model[:]),base.text_get(connection.effort[:])
    if previous:=ai_task_find(m,continuing);continuing!=0 && previous!=nil {
        c:=&previous.conversation
        if c.model_len>0 {chosen_model=string(c.model[:c.model_len])}
        if c.effort_len>0 {chosen_effort=string(c.effort[:c.effort_len])}
    }
    if model!="" {chosen_model=model}
    if effort!="" {chosen_effort=effort}
    if connection.agent==.Codex && !ai_codex_model_supported(chosen_model) {return nil,"Unsupported Codex model"}
    // An agent added by its command may keep the level it starts with.
    if chosen_effort!="low" && chosen_effort!="medium" && chosen_effort!="high" && !(chosen_effort=="" && connection.agent==.Command) {return nil,"Unsupported reasoning effort"}
    document:=document_path(s.document)
    if continuing!=0 {
        task=ai_task_find(m,continuing)
        if task==nil {return nil,"The selected conversation is not loaded"}
        if !ai_task_finished(task) {return nil,"The selected conversation is still running"}
        previous_document:=string(task.conversation.document[:task.conversation.document_len])
        if previous_document!=document || document=="" && task.world!=nil && task.world!=s.edit_world {
            return nil,"The selected conversation belongs to another document"}
        if string(task.conversation.provider[:task.conversation.provider_len])!=chosen {
            return nil,"Start a new chat to use a different agent"}
        if !task.review_finished {ai_task_finish(s,m,task)}
        task.state=.Queued;task.stop=false;task.exit_code=0;task.pid=0;task.seconds=0
        task.question=.None;task.options_length=0
        task.state_before=0;task.state_after=0;task.step_count=0;task.undone=false;task.declined=false;task.needs_build=false;task.files_changed=false
        ai_review_free(&task.review)
        task.review_finished=false
        task.stream_open=false;task.finish_called=false;task.document_closed=false
    } else {
        id,error:=ai_store_next_id(&m.store)
        if error!="" {return nil,error}
        if id>u64(max(int)) {return nil,"Chat identifiers are exhausted"}
        task=ai_task_slot(m)
        if task==nil {return nil,"Too many tasks are waiting or running"}
        task.id=int(id)
        task.conversation.id=id
        task.conversation.created_at=time.time_to_unix_nano(time.now())/1_000_000
        title:=text
        if split:=strings.index_byte(title,'\n');split>=0 {title=title[:split]}
        title=title[:min(len(title),len(task.conversation.title))]
        ai_conversation_set_text(task.conversation.title[:],&task.conversation.title_len,title)
        ai_conversation_set_text(task.conversation.document[:],&task.conversation.document_len,document)
        ai_conversation_set_text(task.conversation.provider[:],&task.conversation.provider_len,chosen)
        connection:=&m.connections[provider]
        ai_conversation_set_text(task.conversation.model[:],&task.conversation.model_len,base.text_get(connection.model[:]))
        ai_conversation_set_text(task.conversation.effort[:],&task.conversation.effort_len,base.text_get(connection.effort[:]))
        base.text_set(task.title[:],title[:min(len(title),len(task.title)-1)])
    }
    ai_conversation_set_text(task.conversation.model[:],&task.conversation.model_len,chosen_model)
    ai_conversation_set_text(task.conversation.effort[:],&task.conversation.effort_len,chosen_effort)
    if continuing==0 {
        task.icon=u8(base.hash_combine(u64(task.id),u64(time.time_to_unix_nano(time.now()))))%AI_AGENT_ICON_COUNT
        task.color_index=u8((task.id-1)%len(AGENT_COLORS))
        for _ in 0..<AI_AGENT_ICON_COUNT {
            used:=false
            for &other in m.tasks[:m.task_count] {if &other!=task && !other.review_finished && other.icon==task.icon {used=true;break}}
            if !used {break}
            task.icon=(task.icon+1)%AI_AGENT_ICON_COUNT
        }
    }
    base.text_set(task.agent[:],chosen)
    ai_task_glyph_set(m,task)
    task.world=s.edit_world
    task.play=s.mode!=.Edit
    task.context_count=0
    if s.selection!=nil {
        w:=shown_world(s)
        for e in s.selection.entities {
            if task.context_count==len(task.context_ids) {break}
            id,_:=entity_get(w,entity_author(w,e),core.Id)
            if id.value==0 {continue}
            task.context_ids[task.context_count]=id.value
            task.context_count+=1
        }
    }
    task.material=m.material.open?m.material:{}
    // A figure in the scene keeps its place through a message that gives it nothing new to work on.
    if task.context_count>0 || !task.figure_shown {task.anchor_set=false}
    ai_scene_anchor(s,task)
    m.next_id=max(m.next_id,task.id)
    m.scene_serial+=1
    task.region,task.window=clamped,s.viewport.window
    base.text_set(task.agent[:],chosen)
    base.text_format(task.name[:],"%d-%d",task.id,task.transcript.dropped+task.transcript.count)
    prompt_sequence:=task.transcript.dropped+task.transcript.count
    ai_task_prompt_add(s,task,text)
    if os.make_directory_all(ai_task_path(s,task,""))!=nil || os.write_entire_file(ai_task_path(s,task,AI_FILE_MESSAGE),text)!=nil {
        ai_task_fail(task,"The folder of the task could not be created")
        ai_task_persist(s,task)
        return task,""
    }
    task.image=ai_capture_write(s,task)
    task.references=ai_references_write(s,m,task)
    task.attachments=m.attachments
    task.attachment_count=m.attachment_count
    task.range=m.range
    entities:=ai_entities_gather(s,task)
    if !ai_context_write(s,task,entities) || !ai_prompt_write(s,task,entities) || !ai_mcp_write(s,task) {
        ai_task_fail(task,"The files of the task could not be written")
        ai_task_persist(s,task)
        return task,""
    }
    ai_task_persist(s,task)
    if !task.dirty {
        if snapshot,error:=os.read_entire_file(ai_task_path(s,task,AI_FILE_CONTEXT),context.temp_allocator);error==nil {
            if error:=ai_store_annotate(&m.store,task.conversation.id,u64(prompt_sequence),"user","user_message","",string(snapshot));error!="" {notify(s,error)}
        }
    }
    ai_history_refresh(s)
    ai_queue_advance(s,m)
    return task,""
}
