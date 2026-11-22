package playtest_editor

import "base:runtime"
import "core:fmt"
import "core:math/linalg"
import "core:slice"
import "core:strings"
import "mirai:asset"
import img "mirai:cook/image"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import egui "mirai:engine/gui"
import input "mirai:engine/input"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"

// A preflight of a scene or of the game that plays, read from the world and
// its assets: the red flags a person sees in the first minute (problems,
// materials that draw black or nearly all blended, animations without their
// asset, a menu whose cursor the game holds, a transform that is not finite,
// a frame over budget, a frame all black or all white, a rig that plays and
// does not move or a bone that jumps), each with its entity, what is wrong and
// the fix.

AUDIT_FLAGS :: 64
@(private) AUDIT_BLEND_MESHES :: 20      // mesh entities from which the share of blended ones counts
@(private) AUDIT_BLACK :: f32(0.02)       // the brightest channel of a base color that draws black
@(private) AUDIT_DIELECTRIC :: f32(0.05)  // metallic under which a material is not a metal
@(private) AUDIT_COSTS :: 3               // costliest parts a frame over budget names
@(private) AUDIT_STATUS_ANSWER :: 256*1024
@(private) AUDIT_DARK_PERCENT :: f32(98)  // of the frame near black from which it is dark
@(private) AUDIT_BLOWN_PERCENT :: f32(98) // of the frame clipped from which it is blown out
@(private) AUDIT_BLOWN_LUMA :: f32(0.8)   // linear luminance the darkest 5% of a blown-out frame reach
@(private) AUDIT_FRAME_SIZE :: 256        // pixels of the width of the frame the audit measures
@(private) AUDIT_FRAME_FILE :: ".mirai/captures/audit-frame.png"
@(private) AUDIT_STILL :: f32(1e-5)       // m a bone moves in a tick under which it stays
@(private) AUDIT_FROZEN_TICKS :: 3        // ticks a rig plays with no bone moving before it is frozen
@(private) AUDIT_SNAP_SHARE :: f32(0.5)   // of the size of a rig, a bone moving more in one tick jumps
@(private) AUDIT_SNAP_LEAST :: f32(0.25)  // m, the least move in one tick that is a jump

Audit_Severity :: enum u8 {Error,Warn}
Audit_Area :: enum u8 {Input,Ui,Render,Material,Animation,Physics,Performance,Problems}
Audit_World :: enum u8 {Auto,Document,Game}

Audit_Flag :: struct {
    severity:Audit_Severity,
    area:Audit_Area,
    code:string `mirai:"label=The cause as <area>.<cause>, or the code of a core.report problem"`,
    entity:string `mirai:"optional,label=The name of the entity it is about; absent when it is about the world"`,
    message:string `mirai:"label=What is wrong"`,
    fix:string `mirai:"optional,label=How to fix it; absent when message says it"`,
}

Audit_Summary :: struct {
    entities:int,
    mesh_entities:int `mirai:"label=Entities with a Mesh_Renderer"`,
    blend_entities:int `mirai:"label=Of those, the ones that draw a material of alpha_mode Blend"`,
    textures_pending:int `mirai:"label=Textures still streaming"`,
    problems:int `mirai:"label=core.report problems of the world"`,
    mouse_captured:bool `mirai:"label=The game holds the mouse (hidden cursor, relative motion) as it does in its own window"`,
    ui_buttons_visible:int `mirai:"label=Buttons of the top screen of the focused player that show and can be pressed"`,
    keyboard_consumed:bool `mirai:"label=An interface of the game has the keyboard"`,
    frame_luma:f32 `mirai:"optional,label=Mean linear luminance of the frame of the game, 0 to 1; absent without a GPU"`,
    rigs:int `mirai:"optional,label=Rigs whose bones the ticks watched"`,
}

Api_Scene_Audit_Params :: struct {
    world:Audit_World `mirai:"optional,label=Auto: the game of the caller while one plays, else the document"`,
    blend_ratio_warn:f32 `mirai:"optional,min=0,max=1,label=Share of the mesh entities drawing a Blend material from which it warns"`,
}

Api_Play_Audit_Params :: struct {
    ticks:int `mirai:"optional,min=0,max=300,label=Fixed ticks to run first as play.step runs them with no input; the checks read the game after them"`,
    frame_ms_budget:f32 `mirai:"optional,min=0,unit=ms,label=Longest whole frame of the application; 0: off"`,
    blend_ratio_warn:f32 `mirai:"optional,min=0,max=1,label=Share of the mesh entities drawing a Blend material from which it warns"`,
    player:int `mirai:"optional,min=0,max=3,label=The run of that player of a game a turn plays on the network"`,
}

Api_Audit :: struct {
    passed:bool `mirai:"label=No flag of severity Error"`,
    flags:[]Audit_Flag `mirai:"label=Errors first"`,
    flags_more:int `mirai:"optional,label=Flags that did not fit"`,
    summary:Audit_Summary,
}

@(private)
audit_api_register :: proc(s:^editor.Session) {
    scene:=Api_Scene_Audit_Params{blend_ratio_warn=0.25}
    play:=Api_Play_Audit_Params{frame_ms_budget=33.3,blend_ratio_warn=0.25}
    editor.api_method_register(s,{params=type_info_of(Api_Scene_Audit_Params),result=type_info_of(Api_Audit),name="scene.audit",summary="Red flags of the document or of the game that plays, read from its world and assets, each with its entity and fix: core.report problems, transforms that are not finite, materials that draw black or a scene nearly all blended, and animations whose asset is missing or of another kind.",defaults=&scene,flags={.Read_Only},run=api_scene_audit})
    editor.api_method_register(s,{params=type_info_of(Api_Play_Audit_Params),result=type_info_of(Api_Audit),name="play.audit",summary="The checks of scene.audit on the game of the caller and those of a game that plays: buttons on screen while the game holds the mouse, a screen that is not modal holding the keyboard, textures still streaming, a frame over budget with its costliest parts and, with a GPU, a frame nearly all black or all white; with ticks it first runs those ticks, watching for a stuck player, a rig that plays and does not move and a bone that jumps in one tick.",defaults=&play,run=api_play_audit})
}

@(private)
Audit :: struct {
    s:^editor.Session,
    w:core.World_Ref,
    allocator:runtime.Allocator,
    flags:[dynamic]Audit_Flag,
    more:int,
    summary:Audit_Summary,
}

@(private)
Audit_Cost :: struct {name:string,ms:f32}

// What engine.status says that the audit reads.
@(private)
Audit_Status :: struct {
    textures:struct {pending:int},
    gpu_timings:[]Audit_Cost,
    functions:[]Audit_Cost,
}

@(private)
audit_add :: proc(a:^Audit,f:Audit_Flag) {
    if len(a.flags)>=AUDIT_FLAGS {a.more+=1;return}
    append(&a.flags,f)
}

@(private)
audit_entity :: proc(a:^Audit,e:core.Entity) -> string {
    return strings.clone(editor.entity_label(a.w,e,context.temp_allocator),a.allocator)
}

// What engine.status answers; empty when it does not. A call of the API runs
// inside this one, so it goes before anything else lives in the scratch.
@(private)
audit_status :: proc(call:^api.Call) -> (status:Audit_Status) {
    buffer:=make([]u8,AUDIT_STATUS_ANSWER,call.allocator)
    text,_,ok:=editor.api_scenario_call(call.server,"engine.status","{}",buffer)
    if !ok {return}
    if serial.text_decode(text,&status,call.allocator,skip_unknown=true)!="" {return {}}
    return
}

// The checks of scene.audit on a world.
@(private)
audit_world :: proc(a:^Audit,blend_ratio:f32) {
    a.summary.entities=len(editor.api_entities_ordered(a.w))
    audit_problems(a)
    audit_non_finite(a)
    audit_materials(a,blend_ratio)
    audit_animations(a)
}

@(private)
audit_problems :: proc(a:^Audit) {
    problems:=host.app_world_storage(a.s.app,a.w.data,core.Problems)
    list:=slice.clone(core.problems_list(problems),context.temp_allocator)
    a.summary.problems=len(list)
    slice.sort_by(list,proc(x,y:core.Problem) -> bool {return x.first<y.first})
    for &p in list {
        f:=Audit_Flag{severity=.Error,area=.Problems,code=strings.clone(core.problem_code(&p),a.allocator),message=strings.clone(core.problem_text(&p),a.allocator)}
        if p.entity!=core.NONE {f.entity=audit_entity(a,p.entity)}
        audit_add(a,f)
    }
}

@(private)
audit_non_finite :: proc(a:^Audit) {
    transforms:=core.world_table_of(a.w,core.Transform)
    if transforms==nil {return}
    first:=core.NONE
    count:=0
    for &t,row in transforms.values[:core.count(transforms)] {
        p,o,e:=t.position,transmute([4]f32)t.rotation,t.scale
        if qa_finite(p[:]) && qa_finite(o[:]) && qa_finite(e[:]) {continue}
        if count==0 {first=transforms.entities[row]}
        count+=1
    }
    if count==0 {return}
    audit_add(a,{severity=.Error,area=.Physics,code="physics.non_finite_transform",entity=audit_entity(a,first),
        message=fmt.aprintf("Its Transform is NaN or infinite (%d entities in all): it vanishes and spreads to what it touches",count,allocator=a.allocator),
        fix="play.history with trace finds the tick and the function that wrote it: guard divisions by a zero length and normalizations of a zero vector"})
}

// Whether a material draws black under any light: a base color near zero
// that no texture, emission or program changes, and no metal to reflect.
@(private)
audit_black :: proc "contextless" (m:^asset.Material_Info) -> bool {
    if m.unlit || m.transmission>0 || m.maps.base_color.texture!={} || max(m.emission.r,m.emission.g,m.emission.b)>0 || m.program[0]!=0 {return false}
    return max(m.base_color.r,m.base_color.g,m.base_color.b)<AUDIT_BLACK && m.metallic<AUDIT_DIELECTRIC
}

// Whether so many of the mesh entities draw blended that the scene is: it
// sorts per object, casts no proper shadow and costs the most.
@(private)
audit_blend_heavy :: proc "contextless" (meshes,blended:int,ratio:f32) -> bool {
    return meshes>=AUDIT_BLEND_MESHES && blended>0 && f32(blended)/f32(meshes)>=ratio
}

// The material an id names, when it is loaded; the audit loads nothing.
@(private)
audit_material :: proc(assets:^host.Assets,id:base.Asset_Id) -> ^host.Assets_Material {
    if assets==nil || id=={} {return nil}
    ref,known:=assets.index[id]
    if !known || ref.kind!=.Material {return nil}
    m:=&assets.materials[ref.index]
    return nil if m.failed else m
}

@(private)
audit_mesh :: proc(assets:^host.Assets,id:base.Asset_Id) -> ^host.Assets_Mesh {
    if assets==nil || id=={} {return nil}
    ref,known:=assets.index[id]
    if !known || ref.kind!=.Mesh {return nil}
    m:=&assets.meshes[ref.index]
    return nil if m.failed || m.arriving else m
}

@(private)
audit_materials :: proc(a:^Audit,blend_ratio:f32) {
    renderers:=core.world_table_of(a.w,erender.Mesh_Renderer)
    if renderers==nil {return}
    assets:=a.s.app.assets
    Black :: struct {id:base.Asset_Id,entity:core.Entity,count:int,info:asset.Material_Info}
    black:=make([dynamic]Black,context.temp_allocator)
    for &r,row in renderers.values[:core.count(renderers)] {
        e:=renderers.entities[row]
        a.summary.mesh_entities+=1
        mesh:=audit_mesh(assets,r.mesh)
        slots:=erender.MATERIAL_SLOTS
        if mesh!=nil {slots=min(int(mesh.slot_count),slots)} else if r.mesh=={} {slots=1}
        blended:=false
        for i in 0..<slots {
            id:=r.materials[i]
            if id=={} && mesh!=nil && i<len(mesh.slot_materials) {id=mesh.slot_materials[i]}
            m:=audit_material(assets,id)
            if m==nil {continue}
            if m.info.alpha_mode==.Blend {blended=true}
            if !audit_black(&m.info) {continue}
            known:=false
            for &b in black {
                if b.id==id {b.count+=1;known=true;break}
            }
            if !known {append(&black,Black{id,e,1,m.info})}
        }
        if blended {a.summary.blend_entities+=1}
    }
    if audit_blend_heavy(a.summary.mesh_entities,a.summary.blend_entities,blend_ratio) {
        audit_add(a,{severity=.Warn,area=.Material,code="material.blend_heavy",
            message=fmt.aprintf("%d of %d mesh entities draw a material of alpha_mode Blend: blended surfaces sort per object, cast no proper shadow and cost the most",a.summary.blend_entities,a.summary.mesh_entities,allocator=a.allocator),
            fix="Give opaque surfaces alpha_mode Opaque and cut-outs Mask; keep Blend for glass, smoke and fades"})
    }
    for &b in black {
        audit_add(a,{severity=.Warn,area=.Material,code="material.black_dielectric",entity=audit_entity(a,b.entity),
            message=fmt.aprintf("%s has base color %.3v, metallic %.2f and no base_color texture: it draws black under any light (%d entities)",editor.asset_path(a.s,b.id),b.info.base_color,b.info.metallic,b.count,allocator=a.allocator),
            fix="Give it its base color or a base_color texture (an import of specular-glossiness that lost the diffuse is the usual cause); a metal takes metallic 1"})
    }
}

// The offset of a field of an asset id in a struct a library declares, by name.
@(private)
audit_asset_field :: proc(type:^runtime.Type_Info,name:string) -> (offset:uintptr,found:bool) {
    if type==nil {return}
    s,is_struct:=runtime.type_info_base(type).variant.(runtime.Type_Info_Struct)
    if !is_struct {return}
    for i in 0..<int(s.field_count) {
        if s.names[i]==name && s.types[i].size==size_of(base.Asset_Id) {return s.offsets[i],true}
    }
    return
}

// The Animation of the animation plugin, read by its fields: whether each
// names a clip or a set the project has.
@(private)
audit_animations :: proc(a:^Audit) {
    table,info:=core.world_table_named(a.w,"Animation")
    if table==nil || info==nil || a.s.app.assets==nil {return}
    source,has_source:=audit_asset_field(info.info,"asset")
    library,has_library:=audit_asset_field(info.info,"library")
    if !has_source {return}
    registry:=&a.s.app.assets.registry
    for row in 0..<core.raw_count(table) {
        value:=uintptr(core.raw_value(table,info.info,row))
        e:=table.entities[row]
        clip:=(cast(^base.Asset_Id)(value+source))^
        if clip=={} {
            audit_add(a,{severity=.Warn,area=.Animation,code="animation.no_source",entity=audit_entity(a,e),message="Its Animation names no asset: it plays nothing",fix="Give asset a .anim clip or a .character set"})
            continue
        }
        audit_animation_asset(a,registry,e,clip,"asset")
        if has_library {
            if names:=(cast(^base.Asset_Id)(value+library))^;names!={} {audit_animation_asset(a,registry,e,names,"library")}
        }
    }
}

@(private)
audit_animation_asset :: proc(a:^Audit,registry:^asset.Registry,e:core.Entity,id:base.Asset_Id,field:string) {
    file,found:=asset.registry_find(registry,id)
    if !found {
        text:[base.ASSET_ID_TEXT]u8
        audit_add(a,{severity=.Error,area=.Animation,code="animation.asset_missing",entity=audit_entity(a,e),
            message=fmt.aprintf("Its Animation %s is %s, which no asset of the project is",field,base.asset_id_format(id,text[:]),allocator=a.allocator),
            fix="Point it at a .anim or a .character that asset.list gives, or import the missing file"})
        return
    }
    path:=file.path
    if file.state!=.Asset {
        audit_add(a,{severity=.Error,area=.Animation,code="animation.asset_broken",entity=audit_entity(a,e),
            message=fmt.aprintf("Its Animation %s is %s, which is broken and does not load",field,path,allocator=a.allocator),fix="Import it again from its source"})
        return
    }
    if !strings.has_suffix(path,".anim") && !(field=="asset" && strings.has_suffix(path,".character")) {
        audit_add(a,{severity=.Error,area=.Animation,code="animation.wrong_kind",entity=audit_entity(a,e),
            message=fmt.aprintf("Its Animation %s is %s, which is no %s",field,path,field=="asset"?".anim or .character":".anim",allocator=a.allocator),fix="Point it at a .anim clip or, for asset, a .character set"})
    }
}

// The traps of input a screen sets: buttons on screen while the game holds
// the mouse, which hides the cursor; and the keyboard held by a screen that
// is not modal while the player drives a body, which takes the keys from it.
@(private)
audit_input_traps :: proc "contextless" (buttons:int,captured,modal,keyboard,driving:bool) -> (cursor,keys:bool) {
    return buttons>0 && captured,keyboard && !modal && driving
}

// Whether the game holds the mouse, as engine/gui decides it in its window.
@(private)
audit_mouse_held :: proc(s:^editor.Session,w:core.World_Ref,modal:bool) -> bool {
    seats:=core.world_table_of(w,input.Seat)
    state:=core.world_storage_of(w,input.Seats)
    bindings:=core.world_storage_of(w,input.Input_Map)
    actions:=core.actions_of(s.info,input.Look_Action)
    if seats==nil || state==nil || bindings==nil || actions==nil {return false}
    return egui.mouse_wanted(core.read(seats),state,bindings,input.Action(actions.base)+input.Action(input.Look_Action.Look),modal)
}

@(private)
audit_ui :: proc(a:^Audit,r:^editor.Run) {
    s:=a.s
    g:=host.app_world_storage(s.app,r.world,egui.Gui)
    if g==nil {return}
    top,shown:=editor.play_ui_screen(s,r,false,context.temp_allocator)
    if shown {
        for b in top.buttons {
            if b.shown && !b.disabled {a.summary.ui_buttons_visible+=1}
        }
    }
    for &surface in g.surfaces {
        if surface.ctx!=nil && surface.shown && surface.keyboard {a.summary.keyboard_consumed=true}
    }
    a.summary.mouse_captured=audit_mouse_held(s,a.w,g.modal_up)
    _,body:=editor.play_focused(a.w)
    cursor,keys:=audit_input_traps(a.summary.ui_buttons_visible,a.summary.mouse_captured,top.modal,a.summary.keyboard_consumed,body!=core.NONE)
    if cursor {
        audit_add(a,{severity=.Error,area=.Input,code="input.cursor_hidden_on_ui",entity=audit_entity(a,top.entity),
            message=fmt.aprintf("%s shows %d buttons while the game holds the mouse: the cursor is hidden and they cannot be clicked",top.screen,a.summary.ui_buttons_visible,allocator=a.allocator),
            fix="Make the screen Modal, which frees the mouse; or, while it shows, let its seat drive no body or bind look to no mouse motion"})
    }
    if keys {
        audit_add(a,{severity=.Warn,area=.Ui,code="ui.keyboard_held",entity=shown?audit_entity(a,top.entity):"",
            message="A screen that is not Modal holds the keyboard (a field or the focus of navigation) while the player drives a body: the keys go to the interface, not to the game",
            fix="Clear the focus when the screen is not in use or make it Passive; make it Modal while it should take the keys"})
    }
}

@(private)
audit_frame :: proc(a:^Audit,frame_ms,budget:f32,status:^Audit_Status) {
    if budget<=0 || frame_ms<=budget {return}
    costs:=make([dynamic]Audit_Cost,context.temp_allocator)
    for c in status.functions {append(&costs,Audit_Cost{fmt.tprintf("cpu %s",c.name),c.ms})}
    for c in status.gpu_timings {append(&costs,Audit_Cost{fmt.tprintf("gpu %s",c.name),c.ms})}
    slice.sort_by(costs[:],proc(x,y:Audit_Cost) -> bool {return x.ms>y.ms})
    b:=strings.builder_make(a.allocator)
    fmt.sbprintf(&b,"The last frame took %.1f ms, over %.1f",frame_ms,budget)
    for c,i in costs[:min(len(costs),AUDIT_COSTS)] {fmt.sbprintf(&b,"%s %s %.2f ms",i==0?"; costliest:":",",c.name,c.ms)}
    audit_add(a,{severity=.Warn,area=.Performance,code="performance.frame_over_budget",message=strings.to_string(b),fix="profile.capture says where the time goes; start with the costliest part"})
}

@(private)
audit_finish :: proc(a:^Audit) -> (result:Api_Audit) {
    slice.stable_sort_by(a.flags[:],proc(x,y:Audit_Flag) -> bool {return x.severity<y.severity})
    result={passed=true,flags=a.flags[:],flags_more=a.more,summary=a.summary}
    for f in a.flags {
        if f.severity==.Error {result.passed=false}
    }
    return
}

@(private)
api_scene_audit :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Api_Scene_Audit_Params)
    r,_:=editor.api_play_run(s,call,0)
    game:=p.world==.Game || p.world==.Auto && r!=nil
    if game && r==nil {editor.api_no_game(call,"or give world Document");return}
    status:=audit_status(call)
    a:=Audit{s=s,w=editor.run_ref(s,r) if game else editor.edited_world(s),allocator=call.allocator}
    a.flags=make([dynamic]Audit_Flag,call.allocator)
    a.summary.textures_pending=status.textures.pending
    audit_world(&a,p.blend_ratio_warn)
    api.call_result(call,Api_Audit)^=audit_finish(&a)
}

@(private)
api_play_audit :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Api_Play_Audit_Params)
    r,_:=editor.api_play_run(s,call,p.player)
    if r==nil {editor.api_no_game(call);return}
    stuck:f64
    rigs:=make([dynamic]Audit_Rig,call.allocator)
    if p.ticks>0 {
        stepped:bool
        if stuck,stepped=audit_step(s,call,r,p.ticks,p.player,&rigs);!stepped {return}
        if r,_=editor.api_play_run(s,call,p.player);r==nil {api.call_failf(call,api.SERVER_ERROR,"The game ended during the %d ticks of the audit",p.ticks);return}
    }
    status:=audit_status(call)
    luma,dark,blown,measured:=audit_frame_measure(s,call,p.player)
    a:=Audit{s=s,w=editor.run_ref(s,r),allocator=call.allocator}
    a.flags=make([dynamic]Audit_Flag,call.allocator)
    a.summary.textures_pending=status.textures.pending
    a.summary.rigs=len(rigs)
    audit_world(&a,p.blend_ratio_warn)
    audit_ui(&a,r)
    if status.textures.pending>0 {
        audit_add(&a,{severity=.Warn,area=.Render,code="render.textures_pending",
            message=fmt.aprintf("%d textures are still streaming: what shows is coarser than it will be",status.textures.pending,allocator=call.allocator),
            fix="Judge the image once they arrive (capture waits for them); if the count stays, the pool of textures is short"})
    }
    if stuck>=API_OBSERVE_STUCK_SECONDS {
        _,body:=editor.play_focused(a.w)
        audit_add(&a,{severity=.Warn,area=.Physics,code="physics.player_stuck",entity=audit_entity(&a,body),
            message=fmt.aprintf("The player asked to move for %.1f s of the ticks and did not move",stuck,allocator=call.allocator),
            fix="play.observe and capture show what holds it: a collider in the way or the ground it stands on"})
    }
    audit_rigs(&a,rigs[:])
    audit_frame(&a,s.app.stats.frame_ms,p.frame_ms_budget,&status)
    if measured {
        a.summary.frame_luma=luma
        if dark {
            audit_add(&a,{severity=.Error,area=.Render,code="render.frame_dark",
                message=fmt.aprintf("The frame of the game is nearly all black (mean luminance %.4f; %s shows it): the player sees nothing",luma,AUDIT_FRAME_FILE,allocator=call.allocator),
                fix="world exposure in the docs: a camera inside a mesh or with no View, no light or sky, or an exposure far too low; render.inspect_entity tells what draws"})
        }
        if blown {
            audit_add(&a,{severity=.Error,area=.Render,code="render.frame_blown",
                message=fmt.aprintf("The frame of the game is nearly all clipped white (mean luminance %.2f; %s shows it): the player sees nothing",luma,AUDIT_FRAME_FILE,allocator=call.allocator),
                fix="world exposure in the docs: a light or emission thousands of times too strong, or an exposure far too high"})
        }
    }
    api.call_result(call,Api_Audit)^=audit_finish(&a)
}

// Whether a frame is nearly all black or nearly all clipped white: what the
// player sees is nothing, whatever the scene holds.
@(private)
audit_exposure :: proc "contextless" (stats:img.Image_Stats) -> (dark,blown:bool) {
    return stats.black_percent>=AUDIT_DARK_PERCENT,stats.saturated_percent>=AUDIT_BLOWN_PERCENT && stats.p5>=AUDIT_BLOWN_LUMA
}

// The frame of the game as capture draws it, measured; false without a GPU
// or when it could not be drawn or read.
@(private)
audit_frame_measure :: proc(s:^editor.Session,call:^api.Call,player:int) -> (luma:f32,dark,blown,measured:bool) {
    if s.app==nil || s.app.renderer==nil || s.project_root=="" {return}
    buffer:=make([]u8,AUDIT_STATUS_ANSWER,call.allocator)
    params:=fmt.tprintf(`{{"of":"Game","player":%d,"width":%d,"path":"%s"}}`,player,AUDIT_FRAME_SIZE,AUDIT_FRAME_FILE)
    if _,_,called:=editor.api_scenario_call(call.server,"capture",params,buffer);!called {return}
    file:=project.path(s.project_root,AUDIT_FRAME_FILE,allocator=context.temp_allocator)
    image,error:=img.image_load(file,context.temp_allocator)
    if error!=.None {return}
    stats,stats_error:=img.image_stats(image,{},context.temp_allocator)
    if stats_error!=.None {return}
    dark,blown=audit_exposure(stats)
    return stats.mean_luma,dark,blown,true
}

// A rig as the ticks of the audit saw it.
@(private)
Audit_Rig :: struct {
    entity:core.Entity,
    bones:[][3]f32,    // m, of the last tick watched, in the space of the entity
    names:[]string,
    playing:bool,      // in the last tick watched
    extent:f32,        // m, the farthest a bone was from the entity
    played:int,        // ticks it played from one to the next with the same bones
    moved:f32,         // m, the most a bone moved in one of those
    jump:f32,          // m, the most a bone moved in one tick
    jump_bone,jump_tick:int,
}

// The most a bone moved between two poses of the same bones, and which;
// bone -1 when they are not of the same bones.
@(private)
audit_bones_moved :: proc(before,after:[][3]f32) -> (most:f32,bone:int) {
    if len(before)!=len(after) || len(before)==0 {return 0,-1}
    bone=0
    for at,i in before {
        if moved:=linalg.length(after[i]-at);moved>most {most,bone=moved,i}
    }
    return
}

// Whether a rig that played that many ticks with none of its bones moving
// more than moved shows one pose while it should move.
@(private)
audit_rig_frozen :: proc "contextless" (played:int,moved:f32) -> bool {return played>=AUDIT_FROZEN_TICKS && moved<=AUDIT_STILL}

// Whether a bone that moved jump in one tick, in a rig that reaches extent
// from its entity, jumped: a head that leaves its neck, a pop of the skin.
@(private)
audit_bone_snap :: proc "contextless" (jump,extent:f32) -> bool {return jump>max(AUDIT_SNAP_SHARE*extent,AUDIT_SNAP_LEAST)}

// Takes the poses of the rigs of a run after a tick into rigs, through the plugins that pose them.
@(private)
audit_rigs_watch :: proc(s:^editor.Session,r:^editor.Run,tick:int,rigs:^[dynamic]Audit_Rig,allocator:runtime.Allocator) {
    found:[editor.PROVIDER_CAPACITY]editor.Rig_Provider
    poses:=make([dynamic]editor.Rig_Pose,context.temp_allocator)
    w:=editor.run_ref(s,r)
    for provider in found[:editor.provided_all(s,found[:])] {
        if provider.poses!=nil {provider.poses(s,w,&poses,context.temp_allocator)}
    }
    for &pose in poses {
        rig:^Audit_Rig
        for &known in rigs {
            if known.entity==pose.entity {rig=&known;break}
        }
        if rig==nil {
            append(rigs,Audit_Rig{entity=pose.entity,jump_bone=-1})
            rig=&rigs[len(rigs)-1]
        }
        most,bone:=audit_bones_moved(rig.bones,pose.bones)
        if bone<0 {
            rig.bones=slice.clone(pose.bones,allocator)
            rig.names=make([]string,len(pose.names),allocator)
            for name,i in pose.names {rig.names[i]=strings.clone(name,allocator)}
        } else {
            if rig.playing && pose.playing {rig.played+=1;rig.moved=max(rig.moved,most)}
            if most>rig.jump {rig.jump,rig.jump_bone,rig.jump_tick=most,bone,tick}
            copy(rig.bones,pose.bones)
        }
        rig.playing=pose.playing
        for at in pose.bones {rig.extent=max(rig.extent,linalg.length(at))}
    }
}

@(private)
audit_rigs :: proc(a:^Audit,rigs:[]Audit_Rig) {
    for &rig in rigs {
        if audit_bone_snap(rig.jump,rig.extent) {
            name:=rig.jump_bone<len(rig.names) && rig.names[rig.jump_bone]!=""?rig.names[rig.jump_bone]:fmt.tprintf("%d",rig.jump_bone)
            audit_add(a,{severity=.Error,area=.Animation,code="animation.bone_snap",entity=audit_entity(a,rig.entity),
                message=fmt.aprintf("Its bone %s jumped %.2f m in tick %d of the audit, in a rig %.2f m across from its entity: it pops off where it was",name,rig.jump,rig.jump_tick,rig.extent,allocator=a.allocator),
                fix="animation.history over that tick says what changed it: a clip that loops with its root motion not taken out, a cut between actions with no blend, or a pose request far from the rig"})
        }
        if audit_rig_frozen(rig.played,rig.moved) {
            audit_add(a,{severity=.Warn,area=.Animation,code="animation.rig_frozen",entity=audit_entity(a,rig.entity),
                message=fmt.aprintf("It played an animation for %d ticks and none of its %d bones moved: it shows one pose",rig.played,max(len(rig.bones)-1,0),allocator=a.allocator),
                fix="animation.inspect says what it plays and animation.analyze whether its tracks reach the bones of its skeleton: a clip of one key, a time that does not advance, or tracks bound to no bone"})
        }
    }
}

// Runs ticks of the run by play.step one at a time, watching the focused body
// and the rigs: the seconds it asked to move without moving, or false after
// failing the call.
@(private)
audit_step :: proc(s:^editor.Session,call:^api.Call,r:^editor.Run,ticks,player:int,rigs:^[dynamic]Audit_Rig) -> (stuck:f64,ok:bool) {
    slot:=playtest_run(s,r)
    watch :: proc(s:^editor.Session,r:^editor.Run,slot:^Playtest_Run) -> f64 {
        if slot==nil {return 0}
        w:=editor.run_ref(s,r)
        _,body:=editor.play_focused(w)
        seconds:f64
        if t:=core.world_storage_of(w,core.Time);t!=nil {seconds=t.seconds}
        at:[3]f32
        if body!=core.NONE {at=editor.entity_world(w,body).position}
        return stuck_watch(&slot.stuck,w,body,at,seconds)
    }
    watch(s,r,slot)
    audit_rigs_watch(s,r,0,rigs,call.allocator)
    buffer:=make([]u8,OBSERVE_STEP_ANSWER,call.allocator)
    after:=r
    for tick in 1..=ticks {
        _,error,called:=editor.api_scenario_call(call.server,"play.step",`{"for":1}`,buffer)
        if !called {api.call_fail(call,error.code,error.message);return}
        after,_=editor.api_play_run(s,call,player)
        if after==nil || after.id!=r.id {return 0,true}
        audit_rigs_watch(s,after,tick,rigs,call.allocator)
    }
    return watch(s,after,playtest_run(s,after)),true
}
