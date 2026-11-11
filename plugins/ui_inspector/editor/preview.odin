package ui_inspector_editor

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:strings"
import "mirai:asset"
import "mirai:cook/author"
import "mirai:core"
import "mirai:editor"
import "mirai:engine/gui"
import inp "mirai:engine/input"
import "mirai:project"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:editor/kit"
import "mirai:ui"

// The interface as the game builds it: the same tree, laid out at the size
// the game designs for and scaled into a stage of that shape, over a
// background that stands for the game. There is no game to read: the paths
// read samples of the types of the game (a number in the middle, a bool on,
// three elements of an array), and where the game does not have a path the
// node shows without values, a bound text its field in braces. What floats
// over the surface or its safe area floats over the stage. In Edit the
// pointer picks nodes, drags the one chosen by its handles and a double
// click on a text edits it there, in the language shown; in Try the
// interface takes the pointer, the keys and the gamepad as in the game, and
// navigation stays in it. Prompts show the device chosen with the images
// Project Settings > UI gives them (its pack and those of its inputs).

Background :: enum u8 {Checker,Dark,Light,Color,Texture}
BACKGROUND_NAMES :: [len(Background)]string{"Checker","Dark","Light","Color","Texture"}
REFERENCES :: [?][2]f32{{1920,1080},{1280,720},{2560,1440},{1080,1920}}
REFERENCE_NAMES :: [len(REFERENCES)+1]string{"1920 x 1080","1280 x 720","2560 x 1440","1080 x 1920","Custom"}
REFERENCE_LEAST :: f32(64) // of a side of a custom size

// How the stage shows the interface.
Stage :: struct {
    background:Background,
    color:ui.Color,
    texture:base.Asset_Id,
    family:ui.Prompt_Family,
    fixed:bool,     // family was chosen; otherwise it follows the device used last
    language:gui.Language, // of the localized texts, when chosen; until then the one they are written in
    chosen:bool,
    reference:int,  // of REFERENCES; past them, custom
    custom:[2]f32,  // the size of the game when it is none of REFERENCES
    trying:bool,    // the interface takes input, as in the game
    navigation:bool,// Try shows where navigation goes from the focused widget
    zoom:f32,       // over the size that fits the stage in its room; 0 is 1
    pan:[2]f32,     // points the stage is moved from the center of its room
    panning:bool,   // the middle button, or the right one in Edit, drags the stage
    grab:[2]f32,    // where the pointer was in the last frame of a drag
}
STAGE_DEFAULT :: Stage{background=.Checker,color={30,34,44,255},custom={1920,1080}}
STAGE_ZOOM_MIN :: f32(0.1)
STAGE_ZOOM_MAX :: f32(8)

Preview :: struct {
    tree:ui.Widget_Tree,
    instance:ui.Tree_Instance,
    change:u64,      // of the records it was made from; 0: none
    assets:u64,      // revision of the assets its images and programs were resolved at
    info:^core.World_Info, // of the game its samples were made from
    valid:bool,      // the records load
    sampled:bool,    // its paths read samples; otherwise they were taken out
    origins:[dynamic]int, // by node of the tree: the row of the scope it comes from
    center:[2]f32,   // of the box at the size of the game, as the last frame laid it out
    drawn:[2]f32,    // where that center is drawn this frame: zoom and pan move it
    scale:f32,       // that box drawn in the stage
    game:ui.Rect,    // the box at the size of the game, as the last frame laid it out
    samples:Preview_Samples,
}

Inline_Edit :: struct {
    row:int,          // of the scope; -1: none
    open:bool,
    language:gui.Language, // the text edited is the one in this language
    buffer:[TEXT_EDIT]u8,
    length:int,
}

preview_free :: proc(p:^Preview) {
    if p.tree.allocator.procedure!=nil {ui.tree_destroy(&p.tree)}
    if p.instance.allocator.procedure!=nil {ui.tree_instance_destroy(&p.instance)}
    delete(p.origins)
    preview_samples_free(&p.samples)
    p^={}
}

// The size of the game the stage shows.
stage_reference :: proc(st:^Stage) -> [2]f32 {
    references:=REFERENCES
    if st.reference>=0 && st.reference<len(references) {return references[st.reference]}
    return {max(st.custom.x,REFERENCE_LEAST),max(st.custom.y,REFERENCE_LEAST)}
}

// The note of the toolbar: how far the stage is zoomed, once it is.
stage_note :: proc(u:^Ui_Inspector) -> string {
    zoom:=u.stage.zoom if u.stage.zoom>0 else 1
    if abs(zoom-1)<1e-3 && u.stage.pan=={} {return ""}
    return fmt.tprintf("%.0f%%",zoom*100)
}

// The wheel over the stage zooms it around the pointer; the middle button,
// or the right one in Edit, drags it; Home fits it in its room again.
@(private)
stage_navigate :: proc(ctx:^ui.Context,u:^Ui_Inspector,room:ui.Rect) {
    st:=&u.stage
    if st.zoom<=0 {st.zoom=1}
    over:=!ctx.input.pointer_absent && ui.rect_contains(room,ctx.pointer) && ctx.active==0
    drags:=ui.Mouse_Buttons{.Middle} if st.trying else {.Middle,.Right}
    if st.panning {
        if ctx.input.down&drags=={} {
            st.panning=false
        } else {
            st.pan+=ctx.pointer-st.grab
            st.grab=ctx.pointer
        }
    } else if over && ctx.input.pressed&drags!={} {
        st.panning,st.grab=true,ctx.pointer
    }
    if !over {return}
    if wheel:=ctx.input.wheel.y;wheel!=0 {
        zoom:=clamp(st.zoom*math.pow(f32(1.15),wheel),STAGE_ZOOM_MIN,STAGE_ZOOM_MAX)
        // The point under the pointer stays there.
        from:=ctx.pointer-[2]f32{room.x+room.w*0.5,room.y+room.h*0.5}
        st.pan=from+(st.pan-from)*(zoom/st.zoom)
        st.zoom=zoom
    }
    if .Home in ctx.input.keys_pressed && ctx.edit.id==0 {st.zoom,st.pan=1,{}}
}

// A node as the preview builds it. With samples its paths stay; without,
// they go: bound texts show their field, templates their text, a localized
// node what its key says in the language texts are written in, and a bound
// list three elements. Its text goes to shown, from the texts of the records.
@(private)
preview_node :: proc(n:^ui.Tree_Node,texts:[]u8,shown:^[dynamic]u8,sampled:bool,said:^base.Texts) {
    text:=ui.tree_string(texts,n.text)
    if sampled {
        n.text=ui.tree_string_add(shown,text)
        return
    }
    if .Localized in n.flags {
        text=base.text(said,text,0) or_else text
        n.flags-={.Localized}
    }
    if field:=serial.text_field(n.bind_text[:]);field!="" {
        n.text=ui.tree_string_add(shown,strings.concatenate({"{{",preview_last(field),"}}"},context.temp_allocator))
    } else {n.text=ui.tree_string_add(shown,preview_text(text))}
    if n.kind==.List && n.count==0 && serial.text_field(n.bind_items[:])!="" {n.count=3}
    n.bind_text,n.bind_value,n.bind_visible,n.bind_selected,n.bind_disabled={},{},{},{},{}
    n.bind_items,n.bind_key,n.bind_image,n.bind_tint,n.bind_variant={},{},{},{},{}
    for &f in n.fields {f.path={}}
}

// A path shows as its last name: Player_Stats.health as health.
@(private)
preview_last :: proc(path:string) -> string {
    cut:=max(strings.last_index_byte(path,'.'),strings.last_index_byte(path,'@'))
    return path[cut+1:]
}

// A text as the preview shows it without values: its braces show as they
// are, with the last name of their path.
@(private)
preview_text :: proc(text:string) -> string {
    b:=strings.builder_make(context.temp_allocator)
    for i:=0;i<len(text); {
        c:=text[i]
        close:=strings.index_byte(text[i:],'}') if c=='{' else -1
        if c=='{' && close>0 && !(i+1<len(text) && text[i+1]=='{') {
            inside:=text[i+1:i+close]
            path,spec:=inside,""
            if colon:=strings.index_byte(inside,':');colon>=0 {path,spec=inside[:colon],inside[colon:]}
            strings.write_string(&b,"{{");strings.write_string(&b,preview_last(path));strings.write_string(&b,spec);strings.write_string(&b,"}}")
            i+=close+1
            continue
        }
        strings.write_byte(&b,c)
        if c=='{' || c=='}' {strings.write_byte(&b,c)}
        i+=1
    }
    return strings.to_string(b)
}

// For each image, its place in the texture table of the renderer that draws the editor.
@(private)
preview_textures :: proc(images:[]ui.Tree_Image,a:^host.Assets) -> []u32 {
    textures:=make([]u32,len(images),context.temp_allocator)
    if a==nil || a.renderer==nil {return textures}
    for image,i in images {
        if image.texture=={} {continue}
        if texture:=host.assets_texture_image(a,image.texture);texture!=nil {
            textures[i]=gui.image_quad(a.renderer,texture.handle).data
        }
    }
    return textures
}

// ---------------------------------------------------------------- samples

// What the paths of the preview read: for each source of the game they
// name, a value of its type filled with samples. The values are read once,
// when the tree is made: what Try writes in them (a Checkbox) stays.
Preview_Samples :: struct {
    types:author.Bind_Types,
    host:ui.Bind_Host,
    inner:ui.Bind_Host,    // what finds the types of the sources
    info:^core.World_Info,
    sources:[dynamic]Sample_Source,
    blocks:[dynamic][]u8,  // what the samples hold and point at
    allocator:runtime.Allocator,
}
Sample_Source :: struct {name:u64,bytes:[]u8}

SAMPLE_ELEMENTS :: 3  // of an array that grows
SAMPLE_DEPTH :: 6     // structs a sample goes into
SAMPLE_ASSET :: base.Asset_Id{1,1}
SAMPLE_ENTITY :: base.Entity(1)

preview_samples_free :: proc(s:^Preview_Samples) {
    author.bind_types_free(&s.types)
    for block in s.blocks {delete(block,s.allocator)}
    delete(s.blocks);delete(s.sources)
    s^={}
}

@(private)
preview_samples_host :: proc(s:^Preview_Samples,info:^core.World_Info,allocator:runtime.Allocator) -> ^ui.Bind_Host {
    s.allocator,s.info=allocator,info
    s.sources=make([dynamic]Sample_Source,allocator)
    s.blocks=make([dynamic][]u8,allocator)
    s.inner=author.bind_types_host(&s.types,info,allocator)
    s.host={user=s,schema=s.inner.schema,
        source=proc(user:rawptr,name:u64) -> (type:serial.Type_Index,storage,ok:bool) {
            s:=(^Preview_Samples)(user)
            return s.inner.source(s.inner.user,name)
        },
        fetch=proc(user:rawptr,name:u64,entity:base.Entity) -> (data:rawptr,stamp:u64) {
            s:=(^Preview_Samples)(user)
            for known in s.sources {if known.name==name {return raw_data(known.bytes),1}}
            found:^runtime.Type_Info
            for &t in s.info.tables {if t.place==.World && base.name_hash(t.name)==name {found=t.info;break}}
            if found==nil {
                for &st in s.info.storages {if st.place==.World && !st.by_world && base.name_hash(st.name)==name {found=st.info;break}}
            }
            if found==nil || found.size<=0 {return nil,0}
            bytes:=sample_block(s,found.size)
            if bytes==nil {return nil,0}
            sample_fill(s,raw_data(bytes),found,"",0)
            append(&s.sources,Sample_Source{name,bytes})
            return raw_data(bytes),1
        },
    }
    return &s.host
}

@(private)
sample_block :: proc(s:^Preview_Samples,size:int) -> []u8 {
    bytes,error:=make([]u8,size,s.allocator)
    if error!=nil {return nil}
    append(&s.blocks,bytes)
    return bytes
}

// Fills a value of type t with samples: numbers in the middle of what a
// bar shows, bools on, a text its name, an array of its elements.
@(private)
sample_fill :: proc(s:^Preview_Samples,p:rawptr,t:^runtime.Type_Info,name:string,depth:int) {
    if t==nil || depth>SAMPLE_DEPTH {return}
    switch t.id {
    case base.Asset_Id: (cast(^base.Asset_Id)p)^=SAMPLE_ASSET;return
    case base.Entity:   (cast(^base.Entity)p)^=SAMPLE_ENTITY;return
    }
    #partial switch v in runtime.type_info_base(t).variant {
    case runtime.Type_Info_Boolean: mem.set(p,1,1)
    case runtime.Type_Info_Integer:
        switch t.size {
        case 1: (cast(^u8)p)^=3
        case 2: (cast(^u16)p)^=3
        case 4: (cast(^u32)p)^=3
        case 8: (cast(^u64)p)^=3
        }
    case runtime.Type_Info_Float:
        switch t.size {
        case 4: (cast(^f32)p)^=0.5
        case 8: (cast(^f64)p)^=0.5
        }
    case runtime.Type_Info_Struct:
        for i in 0..<int(v.field_count) {sample_fill(s,rawptr(uintptr(p)+v.offsets[i]),v.types[i],v.names[i],depth+1)}
    case runtime.Type_Info_Array:
        if _,byte:=runtime.type_info_base(v.elem).variant.(runtime.Type_Info_Integer);byte && v.elem.size==1 {
            ui.tree_text_set((cast([^]u8)p)[:v.count],name if name!="" else "Text")
            return
        }
        for i in 0..<v.count {sample_fill(s,rawptr(uintptr(p)+uintptr(i*v.elem_size)),v.elem,name,depth+1)}
    case runtime.Type_Info_Dynamic_Array:
        elements:=sample_elements(s,v.elem,v.elem_size,name,depth)
        (cast(^runtime.Raw_Dynamic_Array)p)^={data=raw_data(elements),len=SAMPLE_ELEMENTS if elements!=nil else 0,cap=SAMPLE_ELEMENTS if elements!=nil else 0}
    case runtime.Type_Info_Slice:
        elements:=sample_elements(s,v.elem,v.elem_size,name,depth)
        (cast(^runtime.Raw_Slice)p)^={data=raw_data(elements),len=SAMPLE_ELEMENTS if elements!=nil else 0}
    case runtime.Type_Info_String:
        text:=sample_block(s,max(len(name),1))
        if text!=nil {
            copy(text,name)
            (cast(^runtime.Raw_String)p)^={data=raw_data(text),len=len(name)}
        }
    }
}

@(private)
sample_elements :: proc(s:^Preview_Samples,elem:^runtime.Type_Info,size:int,name:string,depth:int) -> []u8 {
    if size<=0 {return nil}
    bytes:=sample_block(s,size*SAMPLE_ELEMENTS)
    if bytes==nil {return nil}
    for i in 0..<SAMPLE_ELEMENTS {sample_fill(s,&bytes[i*size],elem,name,depth+1)}
    return bytes
}

// Writes a number where a node reads a value of the samples, as its type holds it.
@(private)
sample_write :: proc(values:rawptr,b:$B,value:f64) {
    if values==nil || !b.bound {return}
    p:=rawptr(uintptr(values)+uintptr(b.offset))
    #partial switch b.kind {
    case .Bool:  (cast(^bool)p)^=value!=0
    case .Float: if b.size==4 {(cast(^f32)p)^=f32(value)} else if b.size==8 {(cast(^f64)p)^=value}
    case .Int,.Enum,.Uint:
        v:=i64(math.round(value))
        switch b.size {
        case 1: (cast(^i8)p)^=i8(v)
        case 2: (cast(^i16)p)^=i16(v)
        case 4: (cast(^i32)p)^=i32(v)
        case 8: (cast(^i64)p)^=v
        }
    }
}

// What each kind of node shows of the samples: a bar half full, a slider
// in the middle of its range, a box ticked, the first option, nodes enabled
// and not chosen. Of the nodes outside lists, whose values are the copy itself.
@(private)
samples_shown :: proc(p:^Preview) {
    tree,instance:=&p.tree,&p.instance
    values:=raw_data(instance.values)
    if values==nil {return}
    for &n,i in tree.nodes[:tree.node_count] {
        listed:=false
        for parent:=n.parent;parent>=0;parent=tree.nodes[parent].parent {
            if tree.nodes[parent].kind==.List {listed=true;break}
        }
        if listed || i>=len(instance.bounds) {continue}
        b:=&instance.bounds[i]
        #partial switch n.kind {
        case .Progress:              sample_write(values,b.value,0.5)
        case .Slider,.Number:        sample_write(values,b.value,f64(n.range[0]+n.range[1])*0.5)
        case .Checkbox,.Popup:       sample_write(values,b.value,1)
        case .Selector,.Dropdown,.Switcher,.Tabs,.Radio: sample_write(values,b.value,0)
        }
        sample_write(values,b.disabled,0)
        sample_write(values,b.selected,0)
        sample_write(values,b.visible,1)
    }
}

// ---------------------------------------------------------------- the tree

// Makes the tree again when the records, the assets or the game changed.
@(private)
preview_update :: proc(u:^Ui_Inspector,app:^host.App,allocator:runtime.Allocator) {
    a:=app.assets
    p:=&u.preview
    if p.change==u.change && p.assets==a.revision && p.info==app.info {return}
    // An edit does not play again what the nodes animate when they appear.
    states:[]ui.Anim_State
    if p.valid {states=make([]ui.Anim_State,len(p.instance.states),context.temp_allocator);copy(states,p.instance.states)}
    center,drawn,scale,game:=p.center,p.drawn,p.scale,p.game
    preview_free(p)
    p.change,p.assets,p.info=u.change,a.revision,app.info
    p.center,p.drawn,p.scale,p.game=center,drawn,scale,game
    data:=author.records_data(&u.records)
    imports,imported:=imports_cached(&u.imports,a,data,u.allocator)
    if !imported {return}
    preview_load(p,app,data,imports,allocator)
    if p.valid && len(states)==len(p.instance.states) {copy(p.instance.states,states)}
}

// Builds p from the records of an interface and the widgets it imports as the
// game would: with the samples of the game, and where it does not have a
// path, without values. False when they do not load.
@(private)
preview_load :: proc(p:^Preview,app:^host.App,data:ui.Tree_Data,imports:[]ui.Tree_Data,allocator:runtime.Allocator) -> bool {
    linked,linked_ok:=ui.tree_link(data,imports)
    if !linked_ok {return false}
    p.origins=make([dynamic]int,allocator)
    for n,row in linked.nodes {
        for _ in 0..<author.tree_node_count(linked,n,0) {append(&p.origins,row)}
    }
    if app.info!=nil && preview_build(p,app,linked,true,allocator) {
        p.sampled=true
        return true
    }
    return preview_build(p,app,linked,false,allocator)
}

@(private)
preview_build :: proc(p:^Preview,app:^host.App,linked:ui.Tree_Data,sampled:bool,allocator:runtime.Allocator) -> bool {
    a:=app.assets
    linked:=linked
    nodes:=make([]ui.Tree_Node,len(linked.nodes),context.temp_allocator)
    component_nodes:=make([]ui.Tree_Node,len(linked.component_nodes),context.temp_allocator)
    overrides:=make([]ui.Tree_Override,len(linked.overrides),context.temp_allocator)
    copy(nodes,linked.nodes);copy(component_nodes,linked.component_nodes);copy(overrides,linked.overrides)
    shown:=make([dynamic]u8,context.temp_allocator)
    said:=host.app_texts(app)
    for &n in nodes {preview_node(&n,linked.text,&shown,sampled,said)}
    for &n in component_nodes {preview_node(&n,linked.text,&shown,sampled,said)}
    for &o in overrides {preview_node(&o.values,linked.text,&shown,sampled,said)}
    linked.nodes,linked.component_nodes,linked.overrides,linked.text=nodes,component_nodes,overrides,shown[:]
    // A font that does not load shows its texts in the font of the editor.
    fonts:=make([]u8,len(linked.fonts),context.temp_allocator)
    for font,i in linked.fonts {fonts[i],_=host.content_font(app,font.font)}
    resources:=ui.Tree_Resources{textures=preview_textures(linked.images,a),fonts=fonts,programs=host.content_ui_programs(a,linked.styles)}
    if !ui.tree_load(&p.tree,linked,resources,allocator) {return false}
    if !sampled {
        p.valid=ui.tree_instance_init(&p.instance,&p.tree,nil,nil,0,allocator)
        return p.valid
    }
    host_of:=preview_samples_host(&p.samples,app.info,allocator)
    if !ui.tree_instance_init(&p.instance,&p.tree,host_of,said,0,allocator) {
        if p.instance.allocator.procedure!=nil {ui.tree_instance_destroy(&p.instance)}
        ui.tree_destroy(&p.tree)
        preview_samples_free(&p.samples)
        return false
    }
    ui.tree_values_refresh(&p.instance,host_of,SAMPLE_ENTITY,true)
    samples_shown(p)
    p.valid=true
    return true
}

// The input of the project, as the game reads it: its actions by the
// name_hash of their names and the bindings of each.
Preview_Input :: struct {
    ready:bool,
    map_:inp.Input_Map,
    actions:[dynamic]Preview_Action,
    problems:core.Problems,
}
Preview_Action :: struct {hash:u64,action:inp.Action}

// The bindings the project gives over the defaults of the code; nil without the Shared.
@(private)
app_input_settings :: proc(app:^host.App) -> ^inp.Input_Settings {
    if app.shared==nil || app.info==nil {return nil}
    return core.world_storage_of(core.world_ref(app.shared,app.info,.Shared),inp.Input_Settings)
}

@(private)
preview_input :: proc(u:^Ui_Inspector,app:^host.App) -> ^Preview_Input {
    p:=&u.input
    if p.ready || app.info==nil {return p}
    p.ready=true
    p.actions=make([dynamic]Preview_Action,u.allocator)
    for entry in core.names_of(app.info,inp.Action) {
        if entry.value>=0 && entry.value<inp.ACTION_CAPACITY {append(&p.actions,Preview_Action{base.name_hash(entry.name),inp.Action(entry.value)})}
    }
    inp.input_map_make(&p.map_,app.info,app_input_settings(app),&p.problems)
    return p
}

// What the preview builds with: the stage, the input and the assets of the editor.
@(private)
Preview_Game :: struct {
    u:^Ui_Inspector,
    app:^host.App,
    settings:^gui.UI_Settings, // of the project; nil: prompts are drawn
}

// What the game gives the preview: the prompts of the device chosen, the
// language chosen and the textures of the assets.
@(private)
preview_game :: proc(u:^Ui_Inspector,app:^host.App,settings:^gui.UI_Settings,stage:^Stage) -> ui.Game_Source {
    user:=new(Preview_Game,context.temp_allocator)
    user^={u,app,settings}
    preview_input(u,app)
    language:u64
    if settings!=nil {
        shown:=gui.UI_PREFERENCES_DEFAULT
        shown.language=stage.language if stage.chosen else settings.source
        language=gui.ui_language(settings,&shown)
    }
    return {
        user=user,
        texts=host.app_texts(app),
        family=stage.family,
        prompts=proc(user:rawptr,action:u64,family:ui.Prompt_Family,out:[]ui.Prompt) -> int {
            g:=cast(^Preview_Game)user
            input:=&g.u.input
            for named in input.actions {
                if named.hash!=action {continue}
                count:=gui.prompts_of(&input.map_,named.action,family,-1,out)
                if g.settings==nil {return count}
                pack:=host.content_prompts(g.app,g.settings.prompts)
                a:=g.app.assets
                for &prompt in out[:count] {
                    // As the game shows it: the image of the settings, or else that of the pack.
                    if at:=gui.prompt_image_find(g.settings,prompt.family,prompt.input,prompt.text);at>=0 && a.renderer!=nil {
                        if texture:=host.assets_texture_image(a,g.settings.prompt_images[at].texture);texture!=nil && texture.height>0 {
                            prompt.quad=gui.image_quad(a.renderer,texture.handle)
                            prompt.aspect=f32(texture.width)/f32(texture.height)
                            continue
                        }
                    }
                    if found,ok:=host.prompts_find(pack,a,prompt.family,prompt.input,prompt.text);ok {prompt=found}
                }
                return count
            }
            return 0
        },
        language=language,
        texture=proc(user:rawptr,id:base.Asset_Id) -> ui.Quad {
            a:=(cast(^Preview_Game)user).app.assets
            texture:=host.assets_texture_image(a,id)
            if texture==nil || a.renderer==nil {return {}}
            return gui.image_quad(a.renderer,texture.handle)
        },
    }
}

@(private)
preview_column :: proc(s:^editor.Session,u:^Ui_Inspector,app:^host.App) {
    ctx:=s.gui.ctx
    a:=app.assets
    ux_sync(u)
    preview_update(u,app,u.allocator)
    p:=&u.preview
    area:=ui.id(ctx,"stage_area")
    // The zoom and the pan of this frame move the area too: they come before it.
    room:=ui.Rect{0,0,640,360}
    under:=editor.asset_workspace_under(s.gui)
    if r,found:=ui.widget_rect(ctx,area);found {
        room={r.x+16+under,r.y+16,max(r.w-32-under,64),max(r.h-32,64)}
        // Try takes no gesture of Edit; one that holds the pointer keeps the stage still.
        if u.stage.trying {u.ux.gesture.handle=.None}
        if p.valid && u.ux.gesture.handle==.None {stage_navigate(ctx,u,r)}
    }
    // It clips: the stage it holds is made from its size and must not ask for one.
    area_box:=ui.Box{id=area,width=ui.GROW,height=ui.GROW,padding={16+under,16,16,16},align_x=.Center,align_y=.Center,track=true,clip_x=true,clip_y=true,clip_floats=true,scroll=-u.stage.pan}
    ui.box_begin(ctx,area_box)
    defer ui.box_end(ctx,area_box)
    if !p.valid {
        ui.label(ctx,"The interface does not load",ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted"))
        return
    }
    reference:=stage_reference(&u.stage)
    // The stage is centered in its room and moved by the pan.
    p.drawn=[2]f32{room.x+room.w*0.5,room.y+room.h*0.5}+u.stage.pan
    scale:=min(room.w/reference.x,room.h/reference.y)*(u.stage.zoom if u.stage.zoom>0 else 1)
    size:=reference*scale
    stage:=ui.id(ctx,"stage")
    background:=stage_background(u,a)
    if ui.box(ctx,{id=stage,width=ui.fixed(size.x),height=ui.fixed(size.y),clip_x=true,clip_y=true,clip_floats=true,
        fill=background.fill,image=background.image,track=true}) {
        // The game floats over the checker: what floats covers what lays out in the flow.
        if u.stage.background==.Checker {
            ui.checker(ctx,ui.fixed(size.x),ui.fixed(size.y),{58,62,72,255},{44,47,56,255},12)
        }
        game_box:=ui.id(ctx,"game")
        ui.id_push(ctx,stage)
        saved_game,saved_group,saved_safe:=ctx.game,ctx.nav_group,ctx.safe
        ctx.game=preview_game(u,app,cast(^gui.UI_Settings)editor.setting_value(s,gui.UI_Settings),&u.stage)
        if u.stage.trying {ctx.nav_group=stage}
        if ui.animated_begin(ctx,game_box,{scale={scale,scale},opacity=1,color={1,1,1,1}}) {}
        if ui.box(ctx,{id=game_box,width=ui.fixed(reference.x),height=ui.fixed(reference.y),track=true,float={to=.Parent,anchor=.Center,pivot=.Center}}) {
            // What floats over the surface or its safe area floats over the game box:
            // there is no safe area of a platform, so it is the box too.
            game:=p.game
            if game.w!=reference.x || game.h!=reference.y {game={p.center.x-reference.x*0.5,p.center.y-reference.y*0.5,reference.x,reference.y}}
            ctx.safe=game
            desc:=ui.Tree_Build_Desc{passive=!u.stage.trying,track=true,area=game_box,area_rect=game}
            // Edit shows the selected node in the state of the fold opened last.
            if !u.stage.trying {
                if states:=shown_states(u);states!={} {
                    if node:=preview_node_of(p,u.selected);node>=0 {desc.shown,desc.shown_states=i32(node)+1,states}
                }
            }
            ui.tree_build(ctx,&p.tree,&p.instance,desc)
        }
        ui.animated_end(ctx)
        ctx.game,ctx.nav_group,ctx.safe=saved_game,saved_group,saved_safe
        if r,found:=ui.widget_rect(ctx,game_box);found {p.center,p.game={r.x+r.w*0.5,r.y+r.h*0.5},r}
        p.scale=scale
        if u.stage.trying {
            if u.stage.navigation {preview_navigation(s,u,stage)}
        } else {preview_edit(s,u,stage,size)}
        ui.id_pop(ctx)
    }
}

// The states Edit shows the node chosen in: those of the fold of Style opened last.
@(private)
shown_states :: proc(u:^Ui_Inspector) -> ui.Style_States {
    x:=&u.ux
    if x.combo_shown!={} && x.combo_open[transmute(u8)x.combo_shown] {return x.combo_shown}
    if u.state_shown!=.Normal && u.state_open[u.state_shown] {return state_rule_states(u.state_shown)}
    return {}
}

// A rectangle of the game box as the stage draws it.
@(private)
preview_drawn :: proc(p:^Preview,r:ui.Rect) -> ui.Rect {
    return {p.drawn.x+(r.x-p.center.x)*p.scale,p.drawn.y+(r.y-p.center.y)*p.scale,r.w*p.scale,r.h*p.scale}
}

// The first node of the tree that comes from a row of the scope; -1: none.
@(private)
preview_node_of :: proc(p:^Preview,row:int) -> int {
    for origin,i in p.origins {if origin==row {return i}}
    return -1
}

// Plays again what the node chosen and the nodes inside it play when they
// appear, and the animation the Animations card shows when it has a name.
@(private)
preview_play :: proc(u:^Ui_Inspector) {
    p:=&u.preview
    node:=preview_node_of(p,u.selected)
    if !p.valid || node<0 {return}
    tree,instance:=&p.tree,&p.instance
    last:=node+int(tree.nodes[node].subtree)
    for i in node..=min(last,tree.node_count-1) {
        first:=int(instance.slots[i])
        end:=int(instance.slots[i+1]) if i+1<tree.node_count else len(instance.states)
        for slot in first..<min(end,len(instance.states)) {instance.states[slot].started=false}
    }
    if u.anim>=0 && u.anim<len(u.records.anims) {
        if name:=serial.text_field(u.records.anims[u.anim].name[:]);name!="" {
            ui.tree_play(tree,instance,tree.nodes[node].name,base.name_hash(name))
        }
    }
}

@(private)
Stage_Fill :: struct {fill:ui.Color,image:ui.Quad}

@(private)
stage_background :: proc(u:^Ui_Inspector,a:^host.Assets) -> (out:Stage_Fill) {
    switch u.stage.background {
    case .Checker: out.fill={44,47,56,255}
    case .Dark:    out.fill={18,20,26,255}
    case .Light:   out.fill={225,228,234,255}
    case .Color:   out.fill=u.stage.color
    case .Texture:
        out.fill={255,255,255,255}
        if texture:=host.assets_texture_image(a,u.stage.texture);texture!=nil && a.renderer!=nil {
            out.image=gui.image_quad(a.renderer,texture.handle)
        } else {out.fill={18,20,26,255}}
    }
    return
}

// ---------------------------------------------------------------- handles

// What the pointer holds of the node chosen on the stage: the whole node,
// which moves its offset while it floats, or an edge or a corner, which
// resize a fixed width or height.
Stage_Handle :: enum u8 {None,Move,Left,Top,Right,Bottom,Top_Left,Top_Right,Bottom_Left,Bottom_Right}
Edge :: enum u8 {Left,Top,Right,Bottom}
Edges :: bit_set[Edge;u8]
HANDLE_EDGES :: [Stage_Handle]Edges{.None={},.Move={.Left,.Top,.Right,.Bottom},.Left={.Left},.Top={.Top},.Right={.Right},.Bottom={.Bottom},
    .Top_Left={.Top,.Left},.Top_Right={.Top,.Right},.Bottom_Left={.Bottom,.Left},.Bottom_Right={.Bottom,.Right}}
HANDLE_SIDE :: f32(8)   // of the square of a handle, on screen
SNAP_REACH :: f32(6)    // on screen: how close an edge comes to another to take its place
SIZE_LEAST :: f32(1)    // of a side a handle leaves

Stage_Gesture :: struct {
    handle:Stage_Handle,
    row:int,
    from:[2]f32,     // where the pointer went down, on screen
    rect:ui.Rect,    // of the node then, in units of the game
    offset:[2]f32,   // its float offset then
    size:[2]f32,     // its width and height values then
    moved:bool,      // the pointer went farther than NODE_DRAG
    double:bool,     // the press was the second of a double click
    guides:[2]f32,   // x and y of the edge or center taken this frame, in units of the game
    guided:[2]bool,
}

// The rectangle a gesture leaves: moved by delta, or with the edges it holds
// moved by it, no side under least.
gesture_rect :: proc(start:ui.Rect,handle:Stage_Handle,delta:[2]f32,least:f32) -> ui.Rect {
    if handle==.Move {return {start.x+delta.x,start.y+delta.y,start.w,start.h}}
    edges:=HANDLE_EDGES
    e:=edges[handle]
    left,top,right,bottom:=start.x,start.y,start.x+start.w,start.y+start.h
    if .Left in e {left=min(left+delta.x,right-least)}
    if .Right in e {right=max(right+delta.x,left+least)}
    if .Top in e {top=min(top+delta.y,bottom-least)}
    if .Bottom in e {bottom=max(bottom+delta.y,top+least)}
    return {left,top,right-left,bottom-top}
}

// Of values, the one nearest to a target within reach: how far it moves to
// it, and the target. ok false: none is within reach.
snap_axis :: proc(values,targets:[]f32,reach:f32) -> (delta,line:f32,ok:bool) {
    best:=reach
    for value in values {
        for target in targets {
            if d:=target-value;abs(d)<=best && (!ok || abs(d)<abs(delta)) {delta,line,ok,best=d,target,true,abs(d)}
        }
    }
    return
}

// The values of a rectangle a gesture snaps on an axis (0: x, 1: y): the
// edges it moves, and its center when it moves whole.
snap_values :: proc(r:ui.Rect,handle:Stage_Handle,axis:int,out:^[3]f32) -> []f32 {
    edges:=HANDLE_EDGES
    e:=edges[handle]
    low,size:=r.x if axis==0 else r.y,r.w if axis==0 else r.h
    count:=0
    if handle==.Move {
        out^={low,low+size*0.5,low+size}
        return out[:]
    }
    if (.Left if axis==0 else .Top) in e {out[count]=low;count+=1}
    if (.Right if axis==0 else .Bottom) in e {out[count]=low+size;count+=1}
    return out[:count]
}

// How far the pivot of a floating node moves when its rectangle goes from
// start to now: what its offset changes by so that the edges it does not
// hold stay.
pivot_shift :: proc(start,now:ui.Rect,pivot:ui.Anchor) -> [2]f32 {
    fx,fy:=f32(int(pivot)/3)*0.5,f32(int(pivot)%3)*0.5
    return {now.x+fx*now.w-(start.x+fx*start.w),now.y+fy*now.h-(start.y+fy*start.h)}
}

// The edges and centers of the parent of a node of the tree and of its
// siblings, which a gesture snaps to: x on axis 0, y on axis 1.
@(private)
snap_targets :: proc(ctx:^ui.Context,p:^Preview,node:int,axis:int) -> []f32 {
    targets:=make([dynamic]f32,context.temp_allocator)
    add :: proc(targets:^[dynamic]f32,r:ui.Rect,axis:int) {
        low,size:=r.x if axis==0 else r.y,r.w if axis==0 else r.h
        append(targets,low,low+size*0.5,low+size)
    }
    parent:=p.tree.nodes[node].parent
    if parent>=0 {
        if r,found:=ui.widget_rect(ctx,ui.tree_node_element(ctx,&p.tree,&p.instance,int(parent)));found {add(&targets,r,axis)}
    } else {add(&targets,p.game,axis)}
    for &n,i in p.tree.nodes[:p.tree.node_count] {
        if i==node || n.parent!=parent {continue}
        if r,found:=ui.widget_rect(ctx,ui.tree_node_element(ctx,&p.tree,&p.instance,i));found {add(&targets,r,axis)}
    }
    return targets[:]
}

// Edit: the pointer picks the node under it, the one chosen shows its
// outline with handles that move it while it floats and resize what it has
// fixed, snapping to its parent and its siblings, and a double click on a
// text edits it in place. A gesture is one step when it lets go.
@(private)
preview_edit :: proc(s:^editor.Session,u:^Ui_Inspector,stage:ui.Id,size:[2]f32) {
    ctx:=s.gui.ctx
    p:=&u.preview
    g:=&u.ux.gesture
    layer:=ctx.layer+4
    // The window of texts is over the stage: the stage takes no press under it.
    it:ui.Interaction
    if !u.texts.open {
        cover:=ui.id(ctx,"cover")
        it=ui.interact(ctx,cover,{})
        if ui.box(ctx,{id=cover,width=ui.fixed(size.x),height=ui.fixed(size.y),float={to=.Parent,layer=layer}}) {}
    }
    if it.pressed {stage_pick(s,u,ctx.pointer,it.double)}
    n:=selected_node(u)
    node:=preview_node_of(p,u.selected)
    if n==nil || node<0 {g.handle=.None;return}
    r,shown:=ui.widget_rect(ctx,ui.tree_node_element(ctx,&p.tree,&p.instance,node))
    if !shown {g.handle=.None;return}
    drawn:=preview_drawn(p,r)
    if ui.box(ctx,{width=ui.fixed(drawn.w+4),height=ui.fixed(drawn.h+4),float={to=.Surface,offset={drawn.x-2,drawn.y-2},layer=layer},stroke=ui.tone(ctx,"accent"),stroke_width=2,radius=3}) {}
    inline_field(s,u,drawn,layer+2)
    if u.editing.open || u.texts.open {g.handle=.None;return}
    // What the node lets the pointer change: where it floats, and what it has fixed.
    floats:=n.float.to!=.None && (ui.node_kind_holds(n.kind) || n.kind==.Component)
    wide,high:=n.layout.width.kind==.Fixed,n.layout.height.kind==.Fixed
    handles:=[Stage_Handle]bool{.None=false,.Move=floats,.Left=wide,.Right=wide,.Top=high,.Bottom=high,
        .Top_Left=wide && high,.Top_Right=wide && high,.Bottom_Left=wide && high,.Bottom_Right=wide && high}
    if floats {
        move:=ui.id(ctx,"handle_move")
        held:=ui.interact(ctx,move,{})
        if ui.box(ctx,{id=move,width=ui.fixed(drawn.w),height=ui.fixed(drawn.h),float={to=.Surface,offset={drawn.x,drawn.y},layer=layer+1}}) {}
        if held.pressed {gesture_begin(ctx,u,.Move,r,held.double)}
    }
    for handle in Stage_Handle {
        if !handles[handle] || handle==.Move {continue}
        edges:=HANDLE_EDGES
        e:=edges[handle]
        at:=[2]f32{drawn.x+drawn.w*0.5,drawn.y+drawn.h*0.5}
        if .Left in e {at.x=drawn.x}
        if .Right in e {at.x=drawn.x+drawn.w}
        if .Top in e {at.y=drawn.y}
        if .Bottom in e {at.y=drawn.y+drawn.h}
        id:=ui.id(ctx,"handle",int(handle))
        held:=ui.interact(ctx,id,{})
        on:=held.hot || g.handle==handle
        if ui.box(ctx,{id=id,width=ui.fixed(HANDLE_SIDE),height=ui.fixed(HANDLE_SIDE),float={to=.Surface,offset=at-HANDLE_SIDE*0.5,layer=layer+2},
            fill=ui.tone(ctx,"accent") if on else ui.tone(ctx,"panel"),stroke=ui.tone(ctx,"accent"),stroke_width=1,radius=2}) {}
        if held.pressed {gesture_begin(ctx,u,handle,r,false)}
    }
    gesture_update(s,u,node)
    // The edges and centers the gesture took.
    for axis in 0..<2 {
        if g.handle==.None || !g.guided[axis] {continue}
        stage_rect,_:=ui.widget_rect(ctx,stage)
        at:=preview_drawn(p,{g.guides[0],g.guides[1],0,0})
        line:=ui.Box{width=ui.fixed(1),height=ui.fixed(stage_rect.h),float={to=.Surface,offset={at.x,stage_rect.y},layer=layer+1},fill=ui.tone(ctx,"accent")}
        if axis==1 {line=ui.Box{width=ui.fixed(stage_rect.w),height=ui.fixed(1),float={to=.Surface,offset={stage_rect.x,at.y},layer=layer+1},fill=ui.tone(ctx,"accent")}}
        if ui.box(ctx,line) {}
    }
}

// A press on the stage chooses the node under the pointer; a second one
// edits its text there.
@(private)
stage_pick :: proc(s:^editor.Session,u:^Ui_Inspector,pointer:[2]f32,double:bool) {
    p:=&u.preview
    if p.scale<=0 {return}
    point:=p.center+(pointer-p.drawn)/p.scale
    hit:=ui.tree_hit(s.gui.ctx,&p.tree,&p.instance,point)
    row:=p.origins[hit] if hit>=0 && hit<len(p.origins) else -1
    choose_rows(u,{row} if row>=0 else {})
    u.ux.peek.instance=-1
    if double && row>=0 {inline_begin(s,u)}
}

@(private)
gesture_begin :: proc(ctx:^ui.Context,u:^Ui_Inspector,handle:Stage_Handle,rect:ui.Rect,double:bool) {
    n:=selected_node(u)
    if n==nil {return}
    u.ux.gesture={handle=handle,row=u.selected,from=ctx.pointer,rect=rect,offset=n.float.offset,size={n.layout.width.value,n.layout.height.value},double=double}
}

// The node follows the pointer while the gesture holds it; a Move that did
// not move is a press that chooses what is under it.
@(private)
gesture_update :: proc(s:^editor.Session,u:^Ui_Inspector,node:int) {
    ctx:=s.gui.ctx
    p:=&u.preview
    g:=&u.ux.gesture
    g.guided={}
    if g.handle==.None {return}
    n:=selected_node(u)
    if n==nil || g.row!=u.selected || p.scale<=0 {g.handle=.None;return}
    pointer:=ctx.pointer-g.from
    if !g.moved && abs(pointer.x)+abs(pointer.y)>NODE_DRAG {g.moved=true}
    if .Left not_in ctx.input.down {
        if g.handle==.Move && !g.moved {stage_pick(s,u,ctx.pointer,g.double)}
        g.handle=.None
        return
    }
    if !g.moved {return}
    delta:=pointer/p.scale
    reach:=SNAP_REACH/p.scale
    // Edges near those of the parent or a sibling take their place.
    if .Shift not_in ctx.input.modifiers {
        for axis in 0..<2 {
            values:[3]f32
            candidate:=gesture_rect(g.rect,g.handle,delta,SIZE_LEAST)
            if d,line,ok:=snap_axis(snap_values(candidate,g.handle,axis,&values),snap_targets(ctx,p,node,axis),reach);ok {
                delta[axis]+=d
                g.guides[axis],g.guided[axis]=line,true
            }
        }
    }
    now:=gesture_rect(g.rect,g.handle,delta,SIZE_LEAST)
    before_offset,before_width,before_height:=n.float.offset,n.layout.width.value,n.layout.height.value
    if g.handle==.Move {
        n.float.offset=g.offset+delta
    } else {
        edges:=HANDLE_EDGES
        e:=edges[g.handle]
        if n.layout.width.kind==.Fixed && e&{.Left,.Right}!={} {n.layout.width.value=g.size.x+now.w-g.rect.w}
        if n.layout.height.kind==.Fixed && e&{.Top,.Bottom}!={} {n.layout.height.value=g.size.y+now.h-g.rect.h}
        if n.float.to!=.None {n.float.offset=g.offset+pivot_shift(g.rect,now,n.float.pivot)}
    }
    if n.float.offset!=before_offset || n.layout.width.value!=before_width || n.layout.height.value!=before_height {
        changed(u,"Move node" if g.handle==.Move else "Resize node")
    }
}

// ---------------------------------------------------------------- texts in place

// The text of the node chosen in the language the stage shows, edited over
// where the stage draws it. A text that is not localized is one in every
// language: it is edited while the stage shows the one it is written in.
@(private)
inline_begin :: proc(s:^editor.Session,u:^Ui_Inspector) {
    n:=selected_node(u)
    if n==nil || n.kind!=.Text && n.kind!=.Button && n.kind!=.Rich_Text || serial.text_field(n.bind_text[:])!="" {return}
    _,source:=texts_languages(s)
    shown:=u.stage.language if u.stage.chosen else source
    if shown!=source && .Localized not_in n.flags {
        editor.notify(s,fmt.tprintf("This text is the same in every language: it is edited in %s, or localized with its bubble in Properties",language_name(source)))
        return
    }
    u.editing={row=u.selected,open=true,language=shown}
    u.editing.length=copy(u.editing.buffer[:len(u.editing.buffer)-1],node_text_in(s,&u.records,n,shown,source))
}

@(private)
inline_field :: proc(s:^editor.Session,u:^Ui_Inspector,drawn:ui.Rect,layer:i16) {
    e:=&u.editing
    if !e.open || e.row!=u.selected {e.open=false;return}
    ctx:=s.gui.ctx
    field:=ui.id(ctx,"inline")
    if ctx.edit.id!=field {ui.edit_request(ctx,field)}
    if ui.box(ctx,{width=ui.fixed(max(drawn.w,120)),height=ui.fixed(ui.metric(ctx,"row")),float={to=.Surface,offset={drawn.x,drawn.y},layer=layer}}) {
        result:=ui.text_field(ctx,field,e.buffer[:len(e.buffer)-1],&e.length,{width=ui.GROW})
        if result.committed || result.cancelled {
            if result.committed {
                if n:=selected_node(u);n!=nil && node_text_set(s,&u.records,n,e.language,string(e.buffer[:e.length])) {changed(u,"Text")}
            }
            e.open=false
        }
    }
}

// Try: where navigation goes from the widget with the focus, each way.
@(private)
preview_navigation :: proc(s:^editor.Session,u:^Ui_Inspector,stage:ui.Id) {
    ctx:=s.gui.ctx
    p:=&u.preview
    stage_rect,found:=ui.widget_rect(ctx,stage)
    focus,has:=ui.widget_rect(ctx,ctx.focus)
    if !found || !has || ctx.focus==0 {return}
    drawn_focus:=preview_drawn(p,focus)
    if !ui.rect_contains(stage_rect,{drawn_focus.x+drawn_focus.w*0.5,drawn_focus.y+drawn_focus.h*0.5}) {return}
    directions:=[4][2]f32{{0,-1},{1,0},{0,1},{-1,0}}
    arrows:=[4]string{"↑","→","↓","←"}
    layer:=ctx.layer+4
    for direction,i in directions {
        next:=ui.focus_neighbor(ctx,ctx.focus,direction)
        if next==0 {continue}
        r,shown:=ui.widget_rect(ctx,next)
        if !shown {continue}
        drawn:=preview_drawn(p,r)
        if ui.box(ctx,{width=ui.fixed(drawn.w+4),height=ui.fixed(drawn.h+4),float={to=.Surface,offset={drawn.x-2,drawn.y-2},layer=layer},stroke=ui.tone(ctx,"accent"),stroke_width=1,radius=3}) {}
        if ui.box(ctx,{width=ui.fixed(16),height=ui.fixed(16),float={to=.Surface,offset={drawn.x+drawn.w-8,drawn.y-8},layer=layer},fill=ui.tone(ctx,"accent"),radius=8,align_x=.Center,align_y=.Center}) {
            ui.label(ctx,arrows[i],11,ui.tone(ctx,"on_accent"))
        }
    }
}

// What plays the stage: Edit or Try, Play, its background, the device of
// its prompts, the size of the game and whether Try shows navigation.
@(private)
stage_toolbar :: proc(s:^editor.Session,u:^Ui_Inspector) {
    g:=s.gui
    ctx:=g.ctx
    rect,found:=editor.asset_toolbar(g)
    if !found || rect.w<=0 || !u.read {return}
    bar:=ui.Box{width=ui.fixed(rect.w),height=ui.fixed(rect.h),padding={12,0,0,0},gap=8,align_y=.Center,float={to=.Surface,offset={rect.x,rect.y},layer=ui.LAYER_BAR}}
    ui.box_begin(ctx,bar)
    defer ui.box_end(ctx,bar)
    ui.id_push(ctx,ui.id_derive(ctx,SCOPE,"stage"))
    defer ui.id_pop(ctx)
    if ui.box(ctx,{width=ui.fixed(1),height=ui.fixed(18),fill=ui.tone(ctx,"border")}) {}
    if kit.segments(ctx,ui.FIT,ui.metric(ctx,"control")) {
        if ui.button(ctx,ui.id(ctx,"edit"),{label="Edit",variant="tab",active=!u.stage.trying,height=ui.metric(ctx,"control")-4}).clicked {u.stage.trying=false}
        if ui.button(ctx,ui.id(ctx,"try"),{label="Try",variant="tab",active=u.stage.trying,height=ui.metric(ctx,"control")-4}).clicked {u.stage.trying=true;u.editing.open=false}
    }
    if ui.button(ctx,ui.id(ctx,"play"),{icon=.Play,icon_size=13,icon_color=ui.tone(ctx,"text_muted"),tip="Play",variant="ghost",width=ui.metric(ctx,"control"),height=ui.metric(ctx,"control"),disabled=preview_node_of(&u.preview,u.selected)<0}).clicked {preview_play(u)}
    backgrounds:=BACKGROUND_NAMES
    background:=int(u.stage.background)
    if ui.dropdown(ctx,ui.id(ctx,"background"),{list=backgrounds[:]},&background,{width=84}) {u.stage.background=Background(background)}
    if u.stage.background==.Color {
        rgb:=[3]f32{f32(u.stage.color.r)/255,f32(u.stage.color.g)/255,f32(u.stage.color.b)/255}
        if ui.box(ctx,{width=ui.fixed(210),height=ui.fixed(ui.metric(ctx,"row")),align_y=.Center}) {
            if r,_:=kit.color_field(ctx,ui.id(ctx,"color"),&rgb);r.changed {u.stage.color=ui.rgb_color(rgb,255)}
        }
    }
    if u.stage.background==.Texture {
        _=editor.held_asset_button(s,ui.id(ctx,"texture"),STAGE_TEXTURE_KEY,{0=asset.KIND_TEXTURE},&u.stage.texture,200)
    }
    families:=[ui.Prompt_Family]string{.Keyboard="Keyboard",.Xbox="Xbox",.PlayStation="PlayStation",.Nintendo="Nintendo"}
    devices:=make([dynamic]string,context.temp_allocator)
    append(&devices,fmt.tprintf("Auto: %s",families[u.stage.family]))
    for name in families {append(&devices,name)}
    device:=int(u.stage.family)+1 if u.stage.fixed else 0
    if ui.dropdown(ctx,ui.id(ctx,"device"),{list=devices[:]},&device,{width=124}) {
        u.stage.fixed=device>0
        if device>0 {u.stage.family=ui.Prompt_Family(device-1)}
    }
    stage_language(ctx,u,cast(^gui.UI_Settings)editor.setting_value(s,gui.UI_Settings))
    references:=REFERENCE_NAMES
    if ui.dropdown(ctx,ui.id(ctx,"reference"),{list=references[:]},&u.stage.reference,{width=104}) {
        if u.stage.reference<len(REFERENCES) {u.stage.custom=stage_reference(&u.stage)}
    }
    if u.stage.reference>=len(REFERENCES) {
        for axis in 0..<2 {
            value:=f64(u.stage.custom[axis])
            if ui.number_field(ctx,ui.id(ctx,"custom",axis+1),&value,{width=ui.fixed(64),height=ui.metric(ctx,"control"),label="W" if axis==0 else "H",integer=true,speed=1,min=f64(REFERENCE_LEAST),max=8192,has_min=true,has_max=true}).changed {
                u.stage.custom[axis]=f32(value)
            }
        }
    }
    if u.stage.trying {
        ui.checkbox(ctx,ui.id(ctx,"navigation"),&u.stage.navigation)
        ui.label(ctx,"Navigation",ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted"))
    }
    if note:=stage_note(u);note!="" {ui.label(ctx,note,ui.metric(ctx,"font_label"),ui.tone(ctx,"text_muted"))}
}

// The language the localized texts show in: one of the game, the one they
// are written in until another is chosen.
@(private)
stage_language :: proc(ctx:^ui.Context,u:^Ui_Inspector,settings:^gui.UI_Settings) {
    if settings==nil {return}
    names:=make([dynamic]string,context.temp_allocator)
    values:=make([dynamic]gui.Language,context.temp_allocator)
    shown:=u.stage.language if u.stage.chosen else settings.source
    chosen:=0
    for language in gui.Language {
        if language not_in settings.languages && language!=settings.source {continue}
        if language==shown {chosen=len(names)}
        append(&names,language_name(language))
        append(&values,language)
    }
    ui.label(ctx,"Language",ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted"))
    if ui.dropdown(ctx,ui.id(ctx,"language"),{list=names[:]},&chosen,{width=110}) {u.stage.language,u.stage.chosen=values[chosen],true}
}

@(private) STAGE_TEXTURE_KEY :: u64(0x75697374616765)
