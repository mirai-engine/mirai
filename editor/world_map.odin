package editor

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "mirai:asset"
import "mirai:core"
import "mirai:editor/api"
import scene "mirai:engine/scene"
import "mirai:host"
import "mirai:platform"
import gpu "mirai:render"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:ui"

// The World tab: a map of the sections of the scene from above (Top) or
// from a side (Side, height up: a world of layers reads as a well), their
// boxes in the color of what the view shows of them, the sources the
// sections stream around and the camera of the editor; under it the list of
// the sections with what each one costs. The eye turns a section on or off
// in the view (section_view_set) and the arrow gives it back to what its
// reference asks; a click on a section, on the map or in the list, takes the
// camera there and loads it (section_travel). A drag moves the map and the
// wheel zooms it around the pointer.

MAP_ZOOM_STEP :: f32(1.2)     // of the scale, per wheel notch
MAP_DRAG :: f32(4)            // points a press travels before it moves the map instead of choosing
MAP_SCALE_MIN :: f32(0.0005)  // points per meter
MAP_SCALE_MAX :: f32(40)
MAP_GRID :: f32(36)           // points between the lines of the grid, at least
MAP_COST_SECONDS :: 0.5       // between counts of the cost of the sections while the world changes
MAP_NAME_BYTES :: 64

World_Map_View :: enum u8 {Top,Side}

// A section as the map draws it: in the plane of the map, in meters.
Map_Item :: struct {
    reference:core.Entity,
    id:base.Entity_Id,
    outline:[8][2]f32, // its box, convex; none without extents
    count:int,
    point:[2]f32,      // where its entity is
    shown:Section_Shown,
    overridden,edited:bool,
}

Map_Cost :: struct {id:base.Entity_Id,cost:Section_Cost}

// What a section costs: what hangs from it, the meshes and textures its
// scene uses with what they hold of the GPU now, and the size of their files.
Section_Cost :: struct {
    entities,meshes,textures:int,
    gpu,files:i64, // bytes
}

@(storage)
World_Map :: struct {
    view:World_Map_View,
    center:[2]f32,   // m: the point of the plane of the map at its middle
    scale:f32,       // points per meter; 0: fit the sections at the next build
    fitted:rawptr,   // the World it last fit: another fits again
    items:[dynamic]Map_Item,
    sources:[scene.SOURCES_MAX][3]f32, // where each one is in the plane, and the distance it streams
    source_count:int,
    camera,camera_forward:[2]f32,
    hovered:int,     // the item under the pointer, plus one
    chosen:base.Entity_Id, // the section the camera last travelled to
    name:[MAP_NAME_BYTES]u8, // of the hovered one, for the drawing
    name_length:int,
    scroll:f32,
    press,last:[2]f32,
    panning:bool,
    costs:[dynamic]Map_Cost,
    costs_key:[5]u64,
    costs_at:u64,    // ns, platform.clock_ns when they were counted
}

world_map_of :: proc(s:^Session) -> ^World_Map {
    if s.editor_world==nil {return nil}
    return core.world_storage_of(core.world_ref(s.editor_world,s.info,.Editor),World_Map)
}

// Where a point of the world is in the plane of the map: x and z from
// above, x and height (down the map) from a side.
map_plane :: proc "contextless" (view:World_Map_View,p:[3]f32) -> [2]f32 {
    return view==.Top?[2]f32{p.x,p.z}:[2]f32{p.x,-p.y}
}

map_to_screen :: proc "contextless" (m:^World_Map,rect:ui.Rect,p:[2]f32) -> [2]f32 {
    return ui.rect_center(rect)+(p-m.center)*m.scale
}

map_from_screen :: proc "contextless" (m:^World_Map,rect:ui.Rect,p:[2]f32) -> [2]f32 {
    return (p-ui.rect_center(rect))/max(m.scale,MAP_SCALE_MIN)+m.center
}

// The sections of the World, and the sources and the camera, as the map shows them.
@(private)
world_map_gather :: proc(s:^Session,m:^World_Map,w:core.World_Ref) {
    clear(&m.items)
    m.source_count=0
    references:=core.world_table_of(w,scene.Scene_Reference)
    edited:=section_editing(s)
    if references!=nil {
        for row in 0..<core.count(references) {
            e:=core.entity_at(references,row)
            r:=core.at(core.read(references),row)
            pose:=entity_world(w,e)
            item:=Map_Item{reference=e,id=api_entity_id(w,e),point=map_plane(m.view,pose.position),shown=section_shown(s,w,e),edited=e==edited}
            _,item.overridden=section_view(s,w,e)
            if e==edited {item.overridden=false}
            if r.extents!={} {
                corners:[8][2]f32
                for corner,i in section_box(r,pose) {corners[i]=map_plane(m.view,corner)}
                item.count=hull(corners[:],&item.outline)
            }
            append(&m.items,item)
        }
    }
    if sources:=core.world_storage_of(w,scene.Streaming_Sources);sources!=nil {
        for source in sources.items[:min(sources.count,len(sources.items))] {
            plane:=map_plane(m.view,source.position)
            m.sources[m.source_count]={plane.x,plane.y,source.distance}
            m.source_count+=1
        }
    }
    o:=s.viewport.orbit
    forward,_,_:=orbit_basis(o)
    m.camera=map_plane(m.view,orbit_position(o))
    m.camera_forward=linalg.normalize0(map_plane(m.view,forward))
}

// The convex outline of some points, in order: monotone chain.
@(private)
hull :: proc(points:[][2]f32,out:^[8][2]f32) -> int {
    sorted:[8][2]f32
    n:=min(len(points),len(sorted))
    copy(sorted[:n],points[:n])
    slice.sort_by(sorted[:n],proc(a,b:[2]f32) -> bool {return a.x<b.x || a.x==b.x && a.y<b.y})
    cross :: proc "contextless" (o,a,b:[2]f32) -> f32 {return (a.x-o.x)*(b.y-o.y)-(a.y-o.y)*(b.x-o.x)}
    chain:[16][2]f32
    k:=0
    for p in sorted[:n] {
        for k>=2 && cross(chain[k-2],chain[k-1],p)<=1e-4 {k-=1}
        chain[k]=p;k+=1
    }
    lower:=k+1
    #reverse for p in sorted[:max(n-1,0)] {
        for k>=lower && cross(chain[k-2],chain[k-1],p)<=1e-4 {k-=1}
        chain[k]=p;k+=1
    }
    count:=min(max(k-1,0),len(out))
    copy(out[:count],chain[:count])
    return count
}

// Whether a point of the plane is inside a convex outline.
@(private)
hull_contains :: proc "contextless" (outline:[][2]f32,p:[2]f32) -> bool {
    if len(outline)<3 {return false}
    for a,i in outline {
        b:=outline[(i+1)%len(outline)]
        if (b.x-a.x)*(p.y-a.y)-(b.y-a.y)*(p.x-a.x)<0 {return false}
    }
    return true
}

@(private)
hull_area :: proc "contextless" (outline:[][2]f32) -> f32 {
    area:f32
    for a,i in outline {
        b:=outline[(i+1)%len(outline)]
        area+=a.x*b.y-b.x*a.y
    }
    return abs(area)*0.5
}

// Frames every section and the camera.
@(private)
world_map_fit :: proc(m:^World_Map,rect:ui.Rect) {
    low,high:=m.camera,m.camera
    for &item in m.items {
        low,high=linalg.min(low,item.point),linalg.max(high,item.point)
        for p in item.outline[:item.count] {low,high=linalg.min(low,p),linalg.max(high,p)}
    }
    size:=linalg.max(high-low,[2]f32{10,10})
    m.center=(low+high)*0.5
    m.scale=clamp(min(rect.w/(size.x*1.15),rect.h/(size.y*1.15)),MAP_SCALE_MIN,MAP_SCALE_MAX)
}

@(private)
shown_color :: proc(th:^ui.Theme,shown:Section_Shown) -> ui.Color {
    switch shown {
    case .Unloaded: return th.text_faint
    case .Loading:  return ui.color_alpha(SECTION_COLOR,150)
    case .Loaded:   return ui.color_alpha(SECTION_COLOR,190)
    case .Active:   return SECTION_COLOR
    }
    return th.text_faint
}

@(private)
world_map_build :: proc(s:^Session,w:core.World_Ref,width,height:f32) {
    m:=world_map_of(s)
    g:=s.gui
    ctx:=g.ctx
    th:=&ctx.theme
    if m==nil {return}
    if m.fitted!=w.data {m.fitted,m.scale,m.chosen=w.data,0,0}
    world_map_gather(s,m,w)
    map_id:=ui.id(ctx,"world_map")
    rect,placed:=ui.widget_rect(ctx,map_id)
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(th.control),gap=4,align_y=.Center}) {
        view:=int(m.view)
        if ui.tabs(ctx,ui.id(ctx,"world_map_view"),{"Top","Side"},&view,ui.fixed(120),th.control) {
            m.view=World_Map_View(view)
            m.scale=0
            world_map_gather(s,m,w)
        }
        ui.spacer(ctx)
        if ui.button(ctx,ui.id(ctx,"world_map_fit"),{icon=.Focus,icon_color=th.text_muted,icon_size=14,style=.Ghost,width=22,height=22}).clicked {m.scale=0}
    }
    if placed && m.scale<=0 {world_map_fit(m,rect)}
    if len(m.items)==0 {
        ui.label(ctx,"This scene has no sections",th.font_small,th.text_muted)
        return
    }
    map_height:=clamp(height*0.5,120,320)
    it:=drawing(g,map_id,ui.GROW,ui.fixed(map_height),world_map_draw,m,{.Scroll})
    m.hovered=0
    if placed && m.scale>0 {
        pointer:=ctx.pointer
        if it.hot || it.active {
            at:=map_from_screen(m,rect,pointer)
            smallest:=max(f32)
            for &item,i in m.items {
                area:f32
                if item.count>=3 && hull_contains(item.outline[:item.count],at) {area=hull_area(item.outline[:item.count])}
                else if linalg.length(map_to_screen(m,rect,item.point)-pointer)<=6 {area=0}
                else {continue}
                if area<smallest {smallest,m.hovered=area,i+1}
            }
        }
        if ctx.wheel_target==map_id && ctx.input.wheel.y!=0 {
            before:=map_from_screen(m,rect,pointer)
            m.scale=clamp(m.scale*math.pow(MAP_ZOOM_STEP,ctx.input.wheel.y),MAP_SCALE_MIN,MAP_SCALE_MAX)
            m.center+=before-map_from_screen(m,rect,pointer)
        }
        if it.pressed {m.press,m.last,m.panning=pointer,pointer,false}
        if it.active {
            if !m.panning && linalg.length(pointer-m.press)>MAP_DRAG {m.panning=true}
            if m.panning {m.center-=(pointer-m.last)/m.scale}
            m.last=pointer
        }
        if it.released && !m.panning && m.hovered>0 {world_map_travel(s,w,m,m.hovered-1)}
    }
    m.name_length=0
    if m.hovered>0 {m.name_length=copy(m.name[:],entity_label(w,m.items[m.hovered-1].reference))}
    world_map_costs(s,m,w)
    list:=ui.id(ctx,"world_map_list")
    room:=max(height-th.control-map_height-16-3*8,OUTLINER_ROW*2)
    first,last:=ui.list_begin(ctx,list,&m.scroll,len(m.items),OUTLINER_ROW,room)
    for index in first..<last {
        item:=m.items[index]
        if !entity_alive(w,item.reference) {continue}
        cost:=world_map_cost(m,item.id)
        if ui.box(ctx,{id=ui.id(ctx,"world_map_line",index+1),width=ui.GROW,height=ui.fixed(OUTLINER_ROW),align_y=.Center}) {
            color:=shown_color(th,item.shown)
            // The dot of a section that loads is what works: it beats while it does.
            if item.shown==.Loading {color=ui.color_alpha(color,u8(110+100*(0.5+0.5*math.sin(f32(ctx.time)*6))))}
            row:=ui.row(ctx,ui.id(ctx,"world_map_row",index+1),{label=entity_label(w,item.reference),detail=cost.gpu>0?bytes_text(cost.gpu):"",icon=.Dot,icon_color=color,icon_size=12,text_color=item.edited?SECTION_TEXT:{},selected=item.id==m.chosen || m.hovered==index+1,height=OUTLINER_ROW})
            if row.clicked {world_map_travel(s,w,m,index)}
            if item.overridden && ui.button(ctx,ui.id(ctx,"world_map_auto",index+1),{icon=.Revert,icon_color=th.text_muted,icon_size=13,style=.Ghost,width=22,height=OUTLINER_ROW}).clicked {
                if why:=section_view_set(s,w,item.reference,.Active,true);why!="" {notify(s,why)}
            }
            on:=section_wanted(s,w,item.reference)!=.Unloaded
            if ui.button(ctx,ui.id(ctx,"world_map_eye",index+1),{icon=on?.Eye:.Eye_Off,icon_color=item.overridden?th.accent:th.text_faint,icon_size=14,style=.Ghost,width=22,height=OUTLINER_ROW,disabled=item.edited}).clicked {
                if why:=section_view_set(s,w,item.reference,on?.Unloaded:.Active);why!="" {notify(s,why)}
            }
        }
    }
    ui.list_end(ctx,list,len(m.items),last,OUTLINER_ROW)
    shown:=m.hovered>0?m.items[m.hovered-1].id:m.chosen
    if shown!=0 {
        cost:=world_map_cost(m,shown)
        ui.label(ctx,fmt.tprintf("%d entities · %d meshes · %d textures · GPU %s · files %s",cost.entities,cost.meshes,cost.textures,bytes_text(cost.gpu),bytes_text(cost.files)),th.font_label,th.text_muted)
    }
}

@(private)
world_map_travel :: proc(s:^Session,w:core.World_Ref,m:^World_Map,index:int) {
    item:=m.items[index]
    if why:=section_travel(s,w,item.reference);why!="" {
        notify(s,why)
        return
    }
    m.chosen=item.id
}

// Counts again what the sections cost once the world or its assets changed,
// at most every MAP_COST_SECONDS while they keep changing.
@(private)
world_map_costs :: proc(s:^Session,m:^World_Map,w:core.World_Ref) {
    a:=s.app.assets
    es:=core.world_entities(w)
    h:=core.world_storage_of(w,core.Hierarchy)
    key:=[5]u64{u64(uintptr(w.data)),a!=nil?a.registry.revision:0,a!=nil?a.revision:0,u64(es.alive),h!=nil?h.version:0}
    now:=platform.clock_ns()
    if key==m.costs_key && len(m.costs)==len(m.items) || len(m.costs)==len(m.items) && f64(now-m.costs_at)<MAP_COST_SECONDS*1e9 {return}
    m.costs_key,m.costs_at=key,now
    clear(&m.costs)
    for item in m.items {append(&m.costs,Map_Cost{item.id,section_cost(s,w,item.reference)})}
}

@(private)
world_map_cost :: proc(m:^World_Map,id:base.Entity_Id) -> Section_Cost {
    for c in m.costs {
        if c.id==id {return c.cost}
    }
    return {}
}

// A size in bytes as a person reads it.
@(private)
bytes_text :: proc(bytes:i64) -> string {
    switch {
    case bytes>=1<<30: return fmt.tprintf("%.1f GB",f64(bytes)/(1<<30))
    case bytes>=1<<20: return fmt.tprintf("%.1f MB",f64(bytes)/(1<<20))
    case bytes>=1<<10: return fmt.tprintf("%.0f KB",f64(bytes)/(1<<10))
    }
    return fmt.tprintf("%d B",bytes)
}

section_cost :: proc(s:^Session,w:core.World_Ref,reference:core.Entity) -> (cost:Section_Cost) {
    cost.entities=len(section_entities(w,reference))
    r,ok:=entity_get(w,reference,scene.Scene_Reference)
    a:=s.app.assets
    if !ok || a==nil {return}
    seen:=make(map[base.Asset_Id]bool,context.temp_allocator)
    stack:=make([dynamic]base.Asset_Id,context.temp_allocator)
    append(&stack,r.scene)
    for len(stack)>0 {
        id:=pop(&stack)
        if id=={} || id in seen {continue}
        seen[id]=true
        file,found:=asset.registry_find(&a.registry,id)
        if !found {continue}
        ref,known:=a.index[id]
        switch file.kind {
        case asset.KIND_MESH:
            cost.meshes+=1
            cost.files+=file.size
            if known && ref.kind==.Mesh {
                if mesh:=&a.meshes[ref.index];!mesh.failed {cost.gpu+=i64(mesh.vertex_count)*size_of(gpu.Gpu_Vertex)+i64(mesh.index_count)*size_of(u32)}
            }
        case asset.KIND_TEXTURE:
            cost.textures+=1
            cost.files+=file.size
            if known && ref.kind==.Texture && a.renderer!=nil {
                if handle:=int(a.textures[ref.index].handle);handle>0 && handle<=len(a.renderer.textures.stored) {cost.gpu+=i64(a.renderer.textures.stored[handle-1])}
            }
        }
        for dependency in asset.registry_dependencies(&a.registry,file) {append(&stack,dependency)}
    }
    return
}

// Paints the map: the grid, the boxes of the sections in the color of what
// the view shows of them, the sources with how far they stream, and the camera.
@(private)
world_map_draw :: proc(ctx:^ui.Context,rect:ui.Rect,user:rawptr) {
    m:=(^World_Map)(user)
    th:=&ctx.theme
    ui.draw_rounded(ctx,rect,th.radius_control,th.well)
    if m.scale<=0 {return}
    ui.clip_push(ctx,rect)
    defer ui.clip_pop(ctx)
    // A line every power of ten of meters that leaves MAP_GRID points between lines.
    step:=math.pow(10,math.ceil(math.log10(MAP_GRID/m.scale)))
    low,high:=map_from_screen(m,rect,{rect.x,rect.y}),map_from_screen(m,rect,{rect.x+rect.w,rect.y+rect.h})
    grid:=ui.color_alpha(th.border,90)
    for x:=math.floor(low.x/step)*step;x<=high.x;x+=step {
        p:=map_to_screen(m,rect,{x,0}).x
        ui.draw_line(ctx,{p,rect.y},{p,rect.y+rect.h},1,x==0?th.border:grid)
    }
    for y:=math.floor(low.y/step)*step;y<=high.y;y+=step {
        p:=map_to_screen(m,rect,{0,y}).y
        ui.draw_line(ctx,{rect.x,p},{rect.x+rect.w,p},1,y==0?th.border:grid)
    }
    for &item,i in m.items {
        if i+1==m.hovered {continue}
        map_item_draw(ctx,m,rect,&item,false)
    }
    if m.hovered>0 {map_item_draw(ctx,m,rect,&m.items[m.hovered-1],true)}
    for source in m.sources[:m.source_count] {
        at:=map_to_screen(m,rect,source.xy)
        if linalg.length(source.xy-m.camera)*m.scale<1 {continue}
        if source.z>0 {ui.draw_ring(ctx,at,source.z*m.scale,1,ui.color_alpha(th.accent,90))}
        ui.draw_circle(ctx,at,3,th.accent)
    }
    // The camera: a wedge toward where it looks.
    at:=map_to_screen(m,rect,m.camera)
    forward:=m.camera_forward
    if forward=={} {forward={0,-1}}
    side:=[2]f32{-forward.y,forward.x}
    ui.draw_triangle(ctx,at+forward*9,at-forward*5+side*6,at-forward*5-side*6,th.text)
    if m.hovered>0 && m.name_length>0 {
        item:=m.items[m.hovered-1]
        p:=map_to_screen(m,rect,item.point)
        ui.draw_text(ctx,string(m.name[:m.name_length]),clamp(p.x+6,rect.x+4,rect.x+rect.w-4),clamp(p.y-th.font_small-6,rect.y+4,rect.y+rect.h-th.font_small-4),th.font_small,th.text)
    }
}

@(private)
map_item_draw :: proc(ctx:^ui.Context,m:^World_Map,rect:ui.Rect,item:^Map_Item,hovered:bool) {
    th:=&ctx.theme
    color:=shown_color(th,item.shown)
    if item.count>=2 {
        points:[8][2]f32
        for p,i in item.outline[:item.count] {points[i]=map_to_screen(m,rect,p)}
        fill:u8=0
        #partial switch item.shown {
        case .Active: fill=70
        case .Loaded: fill=30
        }
        if hovered {fill=max(fill,45)}
        if fill>0 {
            for i in 2..<item.count {ui.draw_triangle(ctx,points[0],points[i-1],points[i],ui.color_alpha(SECTION_COLOR,fill))}
        }
        ui.draw_polyline(ctx,points[:item.count],hovered || item.id==m.chosen?2:1,hovered?th.text:color,item.count>=3)
    }
    at:=map_to_screen(m,rect,item.point)
    ui.draw_circle(ctx,at,item.overridden?4:3,item.overridden?th.accent:color)
}

// ---------------------------------------------------------------- the API

Api_Section_Id_Params :: struct {
    entity:Api_Entity_Text `mirai:"text,entity,label=The entity of a Scene_Reference, as editor.sections lists them"`,
}

Api_Section_View_Params :: struct {
    entity:Api_Entity_Text `mirai:"text,entity,label=The entity of a Scene_Reference, as editor.sections lists them"`,
    state:[16]u8 `mirai:"text,label=Active (loaded and on), Loaded (loaded and off), Unloaded, or Auto (what its reference asks)"`,
}

SECTION_STATE_NAMES :: [scene.Section_State]string{.Active="Active",.Loaded="Loaded",.Unloaded="Unloaded"}
SECTION_SHOWN_NAMES :: [Section_Shown]string{.Unloaded="Unloaded",.Loading="Loading",.Loaded="Loaded",.Active="Active"}
SECTION_RULE_NAMES :: [scene.Section_Rule]string{.With_Document="With_Document",.Manual="Manual",.Spatial="Spatial"}

// One section, as editor.sections and the answers of its methods write it.
@(private)
api_section_write :: proc(s:^Session,out:^serial.Writer,w:core.World_Ref,e:core.Entity,costs:bool) {
    r,_:=entity_get(w,e,scene.Scene_Reference)
    pose:=entity_world(w,e)
    rules,states,shown_names:=SECTION_RULE_NAMES,SECTION_STATE_NAMES,SECTION_SHOWN_NAMES
    serial.write_u8(out,'{')
    api.write_key(out,"id",true)
    api.write_id(out,api_entity_id(w,e))
    api.write_text(out,"name",entity_label(w,e))
    scene_path:=""
    if s.app.assets!=nil {
        if file,found:=asset.registry_find(&s.app.assets.registry,r.scene);found {scene_path=file.path}
    }
    api.write_text(out,"scene",scene_path)
    api.write_text(out,"rule",rules[r.rule])
    api.write_text(out,"asked",states[r.state])
    view,overridden:=section_view(s,w,e)
    api.write_text(out,"view",overridden?states[view]:"Auto")
    api.write_text(out,"shown",shown_names[section_shown(s,w,e)])
    api.write_bool(out,"edited",section_editing(s)==e)
    api.write_numbers(out,"position",pose.position)
    if r.extents!={} {
        box:=section_box(r,pose)
        low,high:=box[0],box[0]
        for corner in box[1:] {low,high=linalg.min(low,corner),linalg.max(high,corner)}
        api.write_numbers(out,"min",low)
        api.write_numbers(out,"max",high)
    }
    if costs {
        cost:=section_cost(s,w,e)
        api.write_key(out,"cost")
        serial.write_u8(out,'{')
        api.write_int(out,"entities",i64(cost.entities),true)
        api.write_int(out,"meshes",i64(cost.meshes))
        api.write_int(out,"textures",i64(cost.textures))
        api.write_int(out,"gpu_bytes",cost.gpu)
        api.write_int(out,"file_bytes",cost.files)
        serial.write_u8(out,'}')
    }
    serial.write_u8(out,'}')
}

api_sections :: proc(s:^Session,call:^api.Call) {
    w:=edited_world(s)
    out:=call.out
    serial.text_write_raw(out,`{"sections":[`)
    if references:=core.world_table_of(w,scene.Scene_Reference);references!=nil {
        for row in 0..<core.count(references) {
            if row>0 {serial.write_u8(out,',')}
            api_section_write(s,out,w,core.entity_at(references,row),true)
        }
    }
    serial.text_write_raw(out,`],"sources":[`)
    if sources:=core.world_storage_of(w,scene.Streaming_Sources);sources!=nil {
        for source,i in sources.items[:min(sources.count,len(sources.items))] {
            if i>0 {serial.write_u8(out,',')}
            serial.write_u8(out,'{')
            api.write_numbers(out,"position",source.position,true)
            api.write_key(out,"distance")
            api.write_number(out,source.distance)
            serial.write_u8(out,'}')
        }
    }
    o:=s.viewport.orbit
    forward,_,_:=orbit_basis(o)
    serial.text_write_raw(out,`],"camera":{`)
    api.write_numbers(out,"position",orbit_position(o),true)
    api.write_numbers(out,"forward",forward)
    serial.text_write_raw(out,`}}`)
}

api_section_view :: proc(s:^Session,call:^api.Call) {
    params:=api.call_params(call,Api_Section_View_Params)
    w:=edited_world(s)
    e,ok:=api_section_reference(call,w,params.entity[:])
    if !ok {return}
    given:=base.text_get(params.state[:])
    state:scene.Section_State
    auto:=false
    found:=false
    names:=SECTION_STATE_NAMES
    for name,candidate in names {
        if name==given {state,found=candidate,true}
    }
    if given=="Auto" {auto,found=true,true}
    if !found {
        api.call_failf(call,api.INVALID_PARAMS,"state %q is none of Active, Loaded, Unloaded and Auto",given)
        return
    }
    if why:=section_view_set(s,w,e,state,auto);why!="" {
        api.call_fail(call,api.INVALID_PARAMS,why)
        return
    }
    api_sections_settle(s)
    api_section_write(s,call.out,edited_world(s),e,false)
}

api_section_travel :: proc(s:^Session,call:^api.Call) {
    params:=api.call_params(call,Api_Section_Id_Params)
    w:=edited_world(s)
    e,ok:=api_section_reference(call,w,params.entity[:])
    if !ok {return}
    if why:=section_travel(s,w,e);why!="" {
        api.call_fail(call,api.INVALID_PARAMS,why)
        return
    }
    if m:=world_map_of(s);m!=nil {m.chosen=api_entity_id(w,e)}
    api_sections_settle(s)
    api_section_write(s,call.out,edited_world(s),e,false)
}

// What a section asked for is there when the call answers: its load, over
// the frames it takes, also in a manual editor.
@(private)
api_sections_settle :: proc(s:^Session) {
    Settle :: struct {frames:int}
    settle:Settle
    loading :: proc(s:^Session,user:rawptr) -> bool {
        settle:=(^Settle)(user)
        settle.frames+=1
        // The frame after the request begins the loads it needs.
        if settle.frames<=2 {return true}
        sections:=host.app_world_storage(s.app,edited_world(s).data,scene.Section_Loads)
        if sections==nil {return false}
        for item in sections.items {if item.job!=nil {return true}}
        for item in sections.far {if item.job!=nil {return true}}
        return false
    }
    api_settle(s,&settle,loading)
}
