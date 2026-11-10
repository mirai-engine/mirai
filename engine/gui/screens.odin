package gui

import "core:fmt"
import "core:mem"
import "core:strings"
import masset "mirai:asset"
import "mirai:core"
import inp "mirai:engine/input"
import render "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:ui"

// An interface this frame builds.
Planned :: struct {
    entity:core.Entity,
    instance:int,      // in Gui.instances
    content:^host.Content_Ui,
    order:i32,
    player:int,        // the context it is built in
    input:UI_Input,
    input_context:inp.Input_Context,
    hiding:bool,       // its entity is hidden: it plays what its nodes play as they hide
    passive:bool,      // it takes no navigation, keys or actions
    top:bool,          // the top screen of its player that is not passive; the World_Widget that takes input
    back:bool,
    variant:u64,
    world:bool,        // a World_Widget, on panel
    interactive:bool,  // a World_Widget that takes input while its player points at it
    mesh:int,          // of a World_Widget on a mesh, in Gui.meshes; -1: none
    panel:ui.World_Panel,
}

Instance :: struct {
    entity:core.Entity,
    world:bool,        // of its World_Widget; of its UI_Screen otherwise
    slot:int,          // in its Instance_Slots
    asset:base.Asset_Id,
    generation:u32,    // of the content it was made for
    bound:core.Entity, // whose components its paths name first
    info:^core.World_Info, // whose types its paths were resolved with
    instance:ui.Tree_Instance, // with the copy of what it reads of the game
    copied:bool,       // the copy was made once
    edited:bool,       // a widget wrote values: they are copied again once the events went to the game after edited_at
    edited_at:u64,     // Gui.deliveries when it wrote them
    failed:bool,       // the tree names a path the game does not have
    seen:u64,
    changed:bool,      // what it shows changed since its last build
    shown:bool,        // its last build built something
    gone:bool,         // it hid and nothing of it is left
    top:bool,          // it took input in its last build
    focus:ui.Id,       // the focus while it was on top
    animating:bool,    // its last build said the next frame differs
    live:bool,         // its last build showed a camera or particles, which change every frame
    modal:bool,        // a Modal on top this frame
    taking:bool,       // a screen on top this frame that takes input
    input_context:inp.Input_Context, // of its UI_Screen
    blocking:bool,     // it asked for the seats it covers to be blocked
    entered:bool,      // it asked for the seats it covers to enter its input context
    player:int,
    placed:[2]u64,     // of a World_Widget: the stamps of its row and of its World_Transform
    revision:u64,      // advances with each change of what it shows
}

// Where the instances of an entity are in Gui.instances, plus one: that of
// its UI_Screen, then that of its World_Widget in each context; 0: none.
Instance_Slots :: [1+CONTEXT_CAPACITY]i32

// The slot of the instance of a screen, or of a World_Widget in context player.
instance_slot :: proc "contextless" (is_world:bool,player:int) -> int {return is_world?1+player:0}

// The screens in order, the lowest left out past SCREEN_CAPACITY; a hidden
// one only while it still shows something of its last build.
@(private)
plan_screens :: proc(gui:^Gui,app:^host.App,world:core.World_Ref,screens:core.Read(UI_Screen),hidden:core.Read(render.Hidden),parents:core.Read(core.Parent),seats:core.Read(inp.Seat),drivables:core.Read(inp.Drivable),time:core.Time,local_count:int,problems:^core.Problems) {
    Candidate :: struct {entity:core.Entity,screen:UI_Screen,hiding:bool}
    ordered:[SCREEN_CAPACITY]Candidate
    count:=0
    players:=max(local_count,1)
    for &instance in gui.instances {instance.modal,instance.taking=false,false}
    for row in 0..<core.count(screens) {
        e:=core.entity_at(screens,row)
        screen:=core.at(screens,row)
        // A screen that names no player is of the one its entity is of: in
        // its part while the window is split, and not on this machine when
        // that player is at another end or nobody drives the body.
        if screen.player==0 {
            if slot,owned,local:=screen_owner(seats,drivables,parents,e);owned {
                if !local || slot>=players {continue}
                if local_count>1 {screen.player=u8(slot+1)}
            }
        }
        if int(screen.player)>players {continue}
        hiding:=render.is_hidden(hidden,parents,e)
        if hiding && !screen_hiding(instance_find(gui,e,0)) {continue}
        if count>=len(ordered) {
            // The lowest order is the one left out.
            left:=screen.order<=ordered[0].screen.order?e:ordered[0].entity
            core.report(problems,left,"gui.screens","this UI_Screen is not shown: %d screens are visible, as many as fit, and its order is the lowest of them; hide the screens that are not in use, or raise its UI_Screen.order",SCREEN_CAPACITY)
            if screen.order<=ordered[0].screen.order {continue}
            copy(ordered[:count-1],ordered[1:count])
            count-=1
        }
        at:=count
        for at>0 && ordered[at-1].screen.order>screen.order {
            ordered[at]=ordered[at-1]
            at-=1
        }
        ordered[at]={e,screen,hiding}
        count+=1
    }
    for &c in ordered[:count] {
        index,content:=instance_get(gui,app,world,c.entity,0,c.screen.asset,c.screen.entity,problems)
        if index<0 {continue}
        instance:=&gui.instances[index]
        if !values_refresh(gui,app,world,instance,problems) {continue}
        append(&gui.plan,Planned{
            entity=c.entity,instance=index,content=content,order=c.screen.order,player=int(c.screen.player),input=c.screen.input,
            input_context=c.screen.input_context,hiding=c.hiding,back=c.screen.back,variant=ui.style_variant(base.text_get(c.screen.variant[:])),mesh=-1,
        })
        gui.pausing||=screen_pauses(c.screen,c.hiding)
        if c.screen.pause && c.screen.input!=.Modal {
            core.report(problems,c.entity,"gui.pause_modal","its UI_Screen.pause does nothing: only a Modal screen stops the clock; set UI_Screen.input to Modal, or turn pause off")
        }
    }
    stack_resolve(gui.plan[:])
    for entry in gui.plan {
        instance:=&gui.instances[entry.instance]
        instance.modal,instance.taking,instance.player=entry.top && entry.input==.Modal,entry.top,entry.player
        instance.input_context=entry.input_context
    }
}

OWNER_DEPTH :: 8 // entities over one that are asked whose it is

// Whose an entity is: the seat it is, the seat that drives it, or that of
// the nearest entity over it that is one of those. owned: it is of a player,
// or a body nobody drives; local: of the player of this machine in slot.
screen_owner :: proc(seats:core.Read(inp.Seat),drivables:core.Read(inp.Drivable),parents:core.Read(core.Parent),e:core.Entity) -> (slot:int,owned,local:bool) {
    at:=e
    for _ in 0..<OWNER_DEPTH {
        seat:=at
        if body,driven:=core.get(drivables,at);driven {
            if body.seat==core.NONE {return 0,true,false}
            seat=body.seat
        }
        if value,is_seat:=core.get(seats,seat);is_seat {return int(value.slot),true,inp.seat_local(value)}
        parent,has:=core.get(parents,at)
        if !has || parent.entity==core.NONE {return}
        at=parent.entity
    }
    return
}

// A World_Widget in sight of the camera of a context, while it is planned.
Widget_Candidate :: struct {
    entity:core.Entity,
    row:int,      // of the widget
    placed:int,   // of its World_Transform
    player:int,   // the context
    distance:f32, // from the camera
}

// The World_Widgets with a transform, a size and no Hidden over them, after
// the screens: an overlay one in the context of each local player that sees
// it (the window's with one player), one on a mesh in the window's while the
// camera of a local player sees its mesh. Of those a context sees, the
// nearest WIDGET_CAPACITY are built and the rest left out and reported; one
// out of sight keeps its instance, and one on a mesh its texture, without
// being built.
@(private)
plan_widgets :: proc(gui:^Gui,app:^host.App,world:core.World_Ref,widgets:core.Read(World_Widget),worlds:core.Read(core.World_Transform),meshes_of:core.Read(render.Mesh_Renderer),hidden:core.Read(render.Hidden),parents:core.Read(core.Parent),time:core.Time,players:int,problems:^core.Problems,preview:=false) {
    clear(&gui.candidates)
    split:=players>1 && gui.views[1].known
    for row in 0..<core.count(widgets) {
        e:=core.entity_at(widgets,row)
        placed:=core.row_of(worlds,e)
        widget:=core.at(widgets,row)
        if placed<0 || widget.size.x<=0 || widget.size.y<=0 || preview && !widget.preview || render.is_hidden(hidden,parents,e) {continue}
        position:=core.at(worlds,placed).transform.position
        first,last:=0,0
        if widget.target==.Overlay && split {first,last=1,players}
        if widget.target==.Mesh {
            // Built in the window's context, seen by the camera of any local player.
            nearest,seen:=max(f32),false
            for p in (1 if split else 0)..=(players if split else 0) {
                distance,in_sight:=mesh_seen(app.renderer,&app.extras,&gui.views[p],e,position)
                if in_sight {nearest,seen=min(nearest,distance),true}
            }
            if seen {append(&gui.candidates,Widget_Candidate{entity=e,row=row,placed=placed,player=0,distance=nearest});continue}
            // Out of sight its texture keeps what it showed, and the mesh goes on showing it.
            if instance:=instance_find(gui,e,instance_slot(true,0));instance!=nil {instance.seen=gui.frame}
            for &mesh in gui.meshes {if mesh.entity==e && mesh.texture!=0 {mesh.planned=gui.frame}}
            continue
        }
        for p in first..=last {
            distance,seen:=widget_seen(&gui.views[p],widget,position,gui.settings,gui.preferences.scale)
            if seen {
                append(&gui.candidates,Widget_Candidate{entity=e,row=row,placed=placed,player=p,distance=distance})
            } else if instance:=instance_find(gui,e,instance_slot(true,p));instance!=nil {
                instance.seen=gui.frame
            }
        }
    }
    sort_candidates(gui.candidates[:])
    built:[CONTEXT_CAPACITY]int
    dropped,meshes:=0,0
    left:=core.NONE
    for c in gui.candidates {
        widget:=core.at(widgets,c.row)
        mesh:=-1
        if built[c.player]>=WIDGET_CAPACITY || widget.target==.Mesh && meshes>=MESH_CAPACITY {
            if left==core.NONE {left=c.entity}
            dropped+=1
            continue
        }
        index,content:=instance_get(gui,app,world,c.entity,instance_slot(true,c.player),widget.asset,core.NONE,problems)
        if index<0 {continue}
        instance:=&gui.instances[index]
        if !values_refresh(gui,app,world,instance,problems) {continue}
        if widget.target==.Mesh {
            handle:=host.ASSETS_MESH_NONE
            if static,has:=core.get(meshes_of,c.entity);has && app.assets!=nil {
                if shape:=static.mesh!={}?host.assets_mesh(app.assets,static.mesh):host.assets_shape(app.assets,static.shape);shape!=nil {handle=shape.handle}
            }
            mesh=mesh_surface_get(gui,app.renderer,c.entity,widget,handle,problems)
            if mesh<0 {continue}
            meshes+=1
        }
        built[c.player]+=1
        stamps:=[2]u64{core.stamp(widgets,c.row),core.stamp(worlds,c.placed)}
        if stamps!=instance.placed {instance.placed,instance.changed=stamps,true}
        instance.player=c.player
        transform:=core.at(worlds,c.placed)
        // On a mesh: its plane is where the ray meets it when the mesh cannot
        // say, and its text is rasterized for the texels of its texture.
        facing,density:=widget.facing,f32(0)
        if widget.target==.Mesh {facing,density=.Fixed,widget.pixels>0?widget.pixels:MESH_TEXELS}
        rotation:=panel_rotation(transform.rotation)
        append(&gui.plan,Planned{
            entity=c.entity,instance=index,content=content,player=c.player,world=true,passive=true,interactive=widget.input==.Interactive,
            mesh=mesh,variant=ui.style_variant(base.text_get(widget.variant[:])),
            panel={
                position=transform.position,rotation=rotation,size=widget.size,facing=facing,sizing=widget.sizing,
                unit=widget_unit(&gui.views[c.player],widget,gui.settings,gui.preferences.scale) if widget.target==.Overlay else widget.scale,pivot=widget.pivot,density=density,depth_test=widget.depth_test,passive=widget.passive,offscreen=widget.target==.Mesh,
            },
        })
    }
    if dropped>0 {
        gui.dropped_widgets+=u64(dropped)
        core.report(problems,left,"gui.widgets","%d World_Widgets in sight were not built in a frame: a local player sees at most %d at once and %d on meshes, and the nearest win; give fewer entities a World_Widget, or hide those that are far",dropped,WIDGET_CAPACITY,MESH_CAPACITY)
    }
}

// The rotation of the panel of an entity: its face shows toward the forward
// of the entity (-Z), and a panel has its face toward its own +Z.
@(private)
panel_rotation :: #force_inline proc "contextless" (entity:quaternion128) -> quaternion128 {
    return entity*quaternion(w=0,x=0,y=1,z=0)
}

// By context, then nearest first.
@(private)
sort_candidates :: proc "contextless" (candidates:[]Widget_Candidate) {
    for i in 1..<len(candidates) {
        c:=candidates[i]
        at:=i
        for at>0 && (candidates[at-1].player>c.player || candidates[at-1].player==c.player && candidates[at-1].distance>c.distance) {
            candidates[at]=candidates[at-1]
            at-=1
        }
        candidates[at]=c
    }
}

// Of the screens of each player, in order, the highest that neither is
// Passive nor hides takes input; the rest are passive, as world widgets are
// until gui_widgets finds the one their player points at.
stack_resolve :: proc "contextless" (plan:[]Planned) {
    tops:[CONTEXT_CAPACITY]int
    for &top in tops {top=-1}
    for entry,i in plan {
        if entry.world || entry.hiding || entry.input==.Passive || entry.player<0 || entry.player>=CONTEXT_CAPACITY {continue}
        tops[entry.player]=i
    }
    for &entry,i in plan {
        entry.top=!entry.world && entry.player>=0 && entry.player<CONTEXT_CAPACITY && tops[entry.player]==i
        entry.passive=!entry.top
    }
}

// Whether a screen whose entity is hidden is still built: while what its
// nodes play as they hide shows something.
screen_hiding :: proc "contextless" (instance:^Instance) -> bool {
    return instance!=nil && instance.shown && !instance.gone
}

@(private)
instance_find :: proc(gui:^Gui,e:core.Entity,slot:int) -> ^Instance {
    slots:=core.entity_map_get(&gui.index,e)
    if slots==nil || slots[slot]==0 {return nil}
    return &gui.instances[slots[slot]-1]
}

// The scope the tree of the UI_Screen of an entity is built in.
screen_scope :: proc(ctx:^ui.Context,e:core.Entity) -> ui.Id {return ui.id(ctx,"screen",core.entity_index(e))}

// Where the node at index of the tree of the UI_Screen of an entity was laid
// out in the last frame of its context, in window points, as the node is for
// element 0 of the lists around it. False when it was not laid out.
screen_node_rect :: proc(ctx:^ui.Context,tree:^ui.Widget_Tree,e:core.Entity,index:int) -> (rect:ui.Rect,found:bool) {
    ui.id_push(ctx,screen_scope(ctx,e))
    r,laid:=ui.widget_rect(ctx,ui.tree_node_element(ctx,tree,index))
    ui.id_pop(ctx)
    if !laid {return}
    s:=ctx.scale
    return {r.x*s,r.y*s,r.w*s,r.h*s},true
}

// Says once what a name a step asked of a screen that does not have it is:
// the screen, and what it does have.
@(private)
asked_check :: proc(gui:^Gui,app:^host.App,problems:^core.Problems) {
    for &asked in gui.names_asked.names[:gui.names_asked.count] {
        if asked.checked {continue}
        found:=false
        slots:=core.entity_map_get(&gui.index,asked.entity)
        if slots==nil {continue}
        any:=false
        for slot in slots^ {
            if slot==0 {continue}
            content:=host.content_ui(app,gui.instances[slot-1].asset)
            if content==nil || gui.instances[slot-1].failed {continue}
            any=true
            for &node in content.tree.nodes[:content.tree.node_count] {
                if node.name==asked.name {found=true;break}
            }
            if found {break}
        }
        if !any {continue}
        asked.checked=true
        if !found {asked_report(gui,app.assets,&asked,slots,problems)}
    }
}

// The problem of a name no interface of the entity has.
@(private)
asked_report :: proc(gui:^Gui,assets:^host.Assets,asked:^Asked_Name,slots:^Instance_Slots,problems:^core.Problems) {
    screen:[base.ASSET_ID_TEXT]u8
    title:=""
    has:=make([dynamic]string,context.temp_allocator)
    for slot in slots^ {
        if slot==0 {continue}
        id:=gui.instances[slot-1].asset
        if title=="" {title=host.assets_name(assets,id,&screen)}
        file:masset.Asset
        if host.assets_file(assets,id,masset.KIND_UI,&file)!=.None {continue}
        defer masset.asset_close(&file)
        data,error:=host.ui_tree_view(&file,&assets.types)
        if error!=.None {continue}
        for &n in data.nodes {
            #partial switch n.kind {
            case .Button,.Checkbox,.Slider,.Number,.Field,.Selector,.Dropdown,.Radio,.Component,.Tabs:
                if text:=string(cstring(&n.name[0]));text!="" {append(&has,text)}
            }
        }
    }
    core.report(problems,asked.entity,"gui.names","a step asks interface %s for '%s', which it does not have, so that event never comes; its nodes of events are: %s",title,base.text_get(asked.text[:]),strings.join(has[:],", ",context.temp_allocator))
}

// The instance of the interface of a screen or a widget, made again when its
// asset, the content of the asset, the entity its paths start at or the
// types of the world change, or when a text of another language names a path
// it does not read. -1 when there is nothing to build.
@(private)
instance_get :: proc(gui:^Gui,app:^host.App,world:core.World_Ref,e:core.Entity,slot:int,asset:base.Asset_Id,bound:core.Entity,problems:^core.Problems) -> (index:int,content:^host.Content_Ui) {
    content=host.content_ui(app,asset)
    is_world:=slot>0
    found:=instance_find(gui,e,slot)
    kind:=is_world?"World_Widget":"UI_Screen"
    if content==nil {
        if found!=nil {found.seen=gui.frame}
        if asset!={} {
            file:[base.ASSET_ID_TEXT]u8
            core.report(problems,e,"gui.asset","interface %s of its %s does not load: it is missing, damaged or not a .ui, or the loaded interfaces are full; give %s.asset a .ui of the assets",host.assets_name(app.assets,asset,&file),kind,kind)
        }
        return -1,nil
    }
    target:=bound!=core.NONE?bound:e
    fresh:=found==nil
    if fresh {
        slots,ok:=core.entity_map_get(&gui.index,e),true
        if slots==nil {slots,ok=core.entity_map_put(&gui.index,e,Instance_Slots{})}
        if !ok {return -1,nil}
        append(&gui.instances,Instance{entity=e,world=is_world,slot=slot})
        index=len(gui.instances)-1
        slots[slot]=i32(index+1)
    } else {
        index=mem.ptr_sub(found,&gui.instances[0])
    }
    instance:=&gui.instances[index]
    instance.seen=gui.frame
    if fresh || instance.asset!=asset || instance.generation!=content.generation || instance.bound!=target || instance.info!=world.info || instance.instance.replan {
        instance_free(gui,instance)
        instance.asset,instance.generation,instance.bound,instance.info,instance.changed=asset,content.generation,target,world.info,true
        bind:=Bind{gui=gui,app=app,world=world}
        host_of:=bind_host(&bind)
        instance.failed=!ui.tree_instance_init(&instance.instance,&content.tree,&host_of,host.app_texts(app),ui_language(&gui.settings,&gui.preferences),gui.allocator)
        if instance.failed {
            failure:=instance.instance.failure
            file:[base.ASSET_ID_TEXT]u8
            name:=host.assets_name(app.assets,asset,&file)
            switch {
            case failure.capacity:
                core.report(problems,e,"gui.bind","interface %s of its %s is not shown: its lists need more than %d copies of their nodes, or memory ran out; show fewer elements",name,kind,ui.TREE_SLOTS)
            case failure.node>=0 && failure.node<content.tree.node_count && failure.template:
                core.report(problems,e,"gui.bind","interface %s of its %s is not shown: node %d names in braces of its text a path the game does not have, or one it cannot show; open the .ui and pick the field from the list of the game",name,kind,failure.node)
            case failure.node>=0 && failure.node<content.tree.node_count:
                path:=ui.tree_binding(&content.tree,&content.tree.nodes[failure.node],failure.binding)
                core.report(problems,e,"gui.bind","interface %s of its %s is not shown: node %d binds '%s' for its %v, which the game does not have or cannot show there; a path names a component or a storage first, then its fields; open the .ui and pick the field from the list of the game",name,kind,failure.node,path,failure.binding)
            }
        }
        // An action the game does not declare: its buttons do not take it and its prompts show nothing.
        if !instance.failed && app.info!=nil {
            missing,first:=0,""
            for &node in content.tree.nodes[:content.tree.node_count] {
                if node.action==0 {continue}
                if _,known:=action_named(gui,app.info,node.action);known {continue}
                if missing==0 {first=ui.tree_action_name(&content.tree,&node)}
                missing+=1
            }
            if missing>0 {
                file:[base.ASSET_ID_TEXT]u8
                more:=fmt.tprintf(" and %d more",missing-1) if missing>1 else ""
                core.report(problems,e,"gui.action","interface %s of its %s names the input action '%s'%s, which the game does not declare: its buttons do not take it and its prompts show nothing; declare it as an inp.Action constant and bind it in input.mirai, or choose another action in the .ui",host.assets_name(app.assets,asset,&file),kind,first,more)
            }
        }
        // A Draw whose procedure the game does not declare keeps its place and shows nothing.
        if !instance.failed && app.info!=nil {
            for &node,at in content.tree.nodes[:content.tree.node_count] {
                if node.kind!=.Draw || draw_named(app.info,node.draw)!=nil {continue}
                file:[base.ASSET_ID_TEXT]u8
                core.report(problems,e,"gui.draw","interface %s of its %s has a Draw, node %d, that names a procedure the game does not declare, so it shows nothing: write @(draw=\"name\") with the name its draw says on a proc(ctx:^ui.Context,node:ui.Draw_Node) of the game; mirai ui check names it",host.assets_name(app.assets,asset,&file),kind,at)
                break
            }
        }
    }
    if instance.failed {return -1,nil}
    return index,content
}

@(private)
instance_free :: proc(gui:^Gui,instance:^Instance) {
    ui.tree_instance_destroy(&instance.instance)
    instance.copied,instance.edited=false,false
}

// What the paths of the interfaces of a world read: its components and
// storages, by their names.
@(private)
Bind :: struct {gui:^Gui,app:^host.App,world:core.World_Ref}

@(private)
bind_host :: proc(b:^Bind) -> ui.Bind_Host {
    gui:=b.gui
    if gui.schema_info!=b.world.info {
        if gui.schema_ready {serial.schema_destroy(&gui.schema)}
        serial.schema_init(&gui.schema,gui.allocator)
        gui.schema_ready,gui.schema_info=true,b.world.info
        clear(&gui.sources)
        clear(&gui.source_index)
    }
    return {user=b,schema=&gui.schema,source=bind_source,fetch=bind_fetch,rows=bind_rows,commits=bind_commits}
}

// The component or the storage of the world called by name, its type added
// to the schema the first time.
@(private)
bind_named :: proc(b:^Bind,name:u64) -> ^Bound_Source {
    gui:=b.gui
    if at,known:=gui.source_index[name];known {return &gui.sources[at]}
    world:=b.world
    found:Bound_Source
    ok:=false
    for &t in world.info.tables {
        if base.name_hash(t.name)==name {found,ok={name=name,type=t.type,info=t.info},true;break}
    }
    if !ok {
        for &s in world.info.storages {
            if s.place==world.place && !s.by_world && base.name_hash(s.name)==name {found,ok={name=name,type=s.type,info=s.info,storage=true},true;break}
        }
    }
    if !ok {return nil}
    found.index,ok=serial.schema_add_type_info(&gui.schema,found.info)
    if !ok {return nil}
    if gui.source_index==nil {gui.source_index=make(map[u64]int,gui.allocator)}
    if _,err:=append(&gui.sources,found);err!=nil {return nil}
    gui.source_index[name]=len(gui.sources)-1
    return &gui.sources[len(gui.sources)-1]
}

// A control bound to a field of a storage writes it: the settings and what the
// game keeps of its interfaces (the page a menu shows). A component is the
// game's to write, in the tick its events reach.
@(private)
bind_commits :: proc(user:rawptr,name:u64) -> bool {
    source:=bind_named((^Bind)(user),name)
    return source!=nil && source.storage
}

@(private)
bind_source :: proc(user:rawptr,name:u64) -> (type:serial.Type_Index,storage,ok:bool) {
    source:=bind_named((^Bind)(user),name)
    if source==nil {return}
    return source.index,source.storage,true
}

@(private)
bind_fetch :: proc(user:rawptr,name:u64,entity:base.Entity) -> (data:rawptr,stamp:u64) {
    b:=(^Bind)(user)
    source:=bind_named(b,name)
    if source==nil {return}
    if source.storage {return core.world_storage(b.world,source.type),0}
    table,_:=core.world_table(b.world,source.type)
    if table==nil {return}
    row:=core.raw_row(table,core.Entity(entity))
    if row<0 {return}
    return core.raw_value(table,source.info,row),table.stamps[row]
}

// The rows on of the table of a component: a List that names it shows them.
@(private)
bind_rows :: proc(user:rawptr,name:u64) -> (data:rawptr,count,stride:int,stamp:u64) {
    b:=(^Bind)(user)
    source:=bind_named(b,name)
    if source==nil || source.storage {return}
    table,_:=core.world_table(b.world,source.type)
    if table==nil || table.on<=0 {return}
    // Both only grow: a write raises the version, rows that come or go the layout.
    return core.raw_value(table,source.info,0),table.on,source.info.size,table.version+table.layout
}

// Brings the copy an interface is built with up to date: what its paths
// read of the game. False when the entity it reads does not have a
// component its paths name.
@(private)
values_refresh :: proc(gui:^Gui,app:^host.App,world:core.World_Ref,instance:^Instance,problems:^core.Problems) -> bool {
    // What a widget wrote stays shown until its events went to the game, which writes it or not.
    all:=!instance.copied
    if instance.edited {
        if gui.deliveries<=instance.edited_at {return true}
        instance.edited,all=false,true
    }
    bind:=Bind{gui=gui,app=app,world=world}
    host_of:=bind_host(&bind)
    changed,missing:=ui.tree_values_refresh(&instance.instance,&host_of,instance.bound,all)
    if !instance.copied {changed=true}
    instance.copied=true
    if missing!=0 {
        kind:=instance.world?"World_Widget":"UI_Screen"
        name:="a component"
        if at,known:=gui.source_index[missing];known {
            for &t in world.info.tables {if t.type==gui.sources[at].type {name=t.name}}
        }
        core.report(problems,instance.entity,"gui.bind","its %s reads %s of entity 0x%016x, which does not have it, so its interface is not shown; add it to that entity, or set %s.entity to one that has it",kind,name,u64(instance.bound),kind)
        return false
    }
    if changed {instance.changed=true}
    return true
}

// Builds the tree of an interface where the UI is, with the copy of what it
// binds, and queues what its widgets did: a control bound to a field of a
// storage writes it itself, and one bound to a component asks the game, which
// writes it. The event is queued all the same.
@(private)
screen_build :: proc(world:core.World_Ref,gui:^Gui,app:^host.App,ctx:^ui.Context,s:^Surface,instance:^Instance,entry:^Planned,problems:^core.Problems,area:ui.Id=0,area_rect:ui.Rect={}) {
    content:=entry.content
    focus_restore(ctx,instance,entry.top)
    requests_apply(gui,ctx,instance,content,problems)
    ctx.owner=u64(entry.entity)
    s.source.building=instance
    instance.live=false
    events:[EVENT_BATCH]ui.Tree_Event
    // Through a transmute: tree_build keeps nothing of events, which the escape analysis of Odin cannot tell.
    built:=ui.tree_build(ctx,&content.tree,&instance.instance,{
        events=transmute([]ui.Tree_Event)events[:],hidden=entry.hiding,passive=entry.passive,variant=entry.variant,area=area,area_rect=area_rect,
    })
    s.source.building=nil
    ctx.owner=0
    instance_built(instance,entry,built)
    if entry.top {instance.focus=ctx.focus}
    s.animating||=built.animating
    if built.dropped>0 {
        core.report(problems,entry.entity,"gui.events","%d events of the interface of this entity were lost in a frame: its widgets gave more than %d at once; give the interface fewer widgets that change in one frame",built.dropped,EVENT_BATCH)
    }
    bind:=Bind{gui=gui,app=app,world=world}
    host_of:=bind_host(&bind)
    for event in events[:built.count] {
        append(&gui.pending,event_of(entry.entity,event,1 if entry.world else ctx.scale))
        if event.kind==.Changed {
            instance.edited,instance.edited_at=true,gui.deliveries
            ui.tree_commit_event(&instance.instance,event,&host_of)
        }
    }
    if entry.top && entry.back && !ctx.escape_used && (.Escape in ctx.input.keys_pressed || .Cancel in ctx.input.pad) {
        append(&gui.pending,UI_Event{entity=entry.entity,kind=.Back,item=-1,from_item=-1})
        ctx.escape_used=true
    }
}

// Whether a screen may be drawn again from what it drew: it plays nothing,
// shows no camera or particles, does not hide, has no request waiting and is
// not on top when Back may come.
@(private)
screen_retains :: proc(gui:^Gui,ctx:^ui.Context,instance:^Instance,entry:^Planned) -> bool {
    if instance.animating || instance.live || entry.hiding || !instance.shown {return false}
    if entry.top && entry.back && (.Escape in ctx.input.keys_pressed || .Cancel in ctx.input.pad) {return false}
    for request in gui.requests {if request.entity==entry.entity {return false}}
    return true
}

// What a screen is drawn for: its values, its asset, its place, its layer,
// whether it takes input, the textures of the assets, the prompts of the
// device and the texts of the language.
@(private)
screen_key :: proc(assets:^host.Assets,ctx:^ui.Context,instance:^Instance,entry:^Planned,layer:int,rect:[4]f32) -> u64 {
    revision:=assets.revision if assets!=nil else 0
    // The family of the device shows other prompts, and other texts come with the language.
    mark:=[12]u64{instance.revision,u64(instance.generation),u64(i64(layer)),u64(entry.passive)|u64(entry.top)<<1,entry.variant,revision,
        u64(transmute(u32)rect.x)<<32|u64(transmute(u32)rect.y),u64(transmute(u32)rect.z)<<32|u64(transmute(u32)rect.w),u64(entry.entity),
        u64(ctx.game.family),ctx.game.language,u64(ctx.game.texts.generation) if ctx.game.texts!=nil else 0}
    return base.hash64(mem.slice_to_bytes(mark[:]))
}

// A screen drawn again: it shows what it showed and plays nothing.
@(private)
instance_kept :: proc "contextless" (instance:^Instance,entry:^Planned) {
    instance.changed,instance.animating=false,false
    instance.top=entry.top
}

// A screen that comes back on top gets back the focus it had there.
focus_restore :: proc(ctx:^ui.Context,instance:^Instance,top:bool) {
    if top && !instance.top && instance.focus!=0 {ui.focus_set(ctx,instance.focus)}
}

// What a build leaves for the next frame: whether it still shows, and
// whether it is gone after hiding.
instance_built :: proc "contextless" (instance:^Instance,entry:^Planned,built:ui.Tree_Build_Result) {
    instance.changed=false
    instance.animating=built.animating
    instance.shown=built.present
    instance.gone=entry.hiding && !built.present
    instance.top=entry.top
}

event_of :: proc "contextless" (entity:core.Entity,e:ui.Tree_Event,scale:=f32(1)) -> UI_Event {
    return {
        entity=entity,name=e.name,kind=UI_Event_Kind(e.kind),on=e.on,item=e.item,value=e.value,
        from=e.from,from_item=e.from_item,from_entity=core.Entity(e.from_owner),text=e.text,
        rect=[4]f32{e.rect.x,e.rect.y,e.rect.w,e.rect.h}*scale,
    }
}

// The requests of the game for this interface, before it builds.
@(private)
requests_apply :: proc(gui:^Gui,ctx:^ui.Context,instance:^Instance,content:^host.Content_Ui,problems:^core.Problems) {
    for i:=0;i<len(gui.requests); {
        r:=gui.requests[i]
        if r.entity!=instance.entity {i+=1;continue}
        node:=base.text_get(r.node[:])
        switch r.kind {
        case .Play:
            anim:=base.text_get(r.anim[:])
            if !ui.tree_play(&content.tree,&instance.instance,base.name_hash(node),base.name_hash(anim),r.item) {
                core.report(problems,r.entity,"gui.play","animation '%s' was not played on node '%s': its interface has no node or animation of those names, or no copy %d of that node; name them as the .ui does",anim,node,r.item)
            }
        case .Focus:
            if r.item>=0 {ui.id_push(ctx,ui.id(ctx,"item",int(r.item)+1))}
            ui.focus_set(ctx,ui.tree_element_id(ctx,node))
            if r.item>=0 {ui.id_pop(ctx)}
        }
        ordered_remove(&gui.requests,i)
    }
}

// The instances no interface used this frame, and those that hid, go.
@(private)
instances_sweep :: proc(gui:^Gui) {
    #reverse for &instance,i in gui.instances {
        if instance.seen==gui.frame && !instance.gone {continue}
        if instance.blocking || instance.entered {append(&gui.unblock,instance.entity)}
        instance_free(gui,&instance)
        if slots:=core.entity_map_get(&gui.index,instance.entity);slots!=nil && slots[instance.slot]==i32(i+1) {
            slots[instance.slot]=0
            if slots^=={} {core.entity_map_remove(&gui.index,instance.entity)}
        }
        last:=len(gui.instances)-1
        unordered_remove(&gui.instances,i)
        // The last one took its place.
        if i<last {
            moved:=&gui.instances[i]
            if slots:=core.entity_map_get(&gui.index,moved.entity);slots!=nil && slots[moved.slot]==i32(last+1) {slots[moved.slot]=i32(i+1)}
        }
    }
}

// A screen on top with an input context puts the seats it covers (every
// local one for the window, the seat of its player otherwise) in it, modal
// for a Modal; a Modal without one blocks them. Both go through the requests
// of input and let the seats go when it stops being on top. True when a
// Modal is on top.
@(private)
modal_apply :: proc(
    gui:^Gui,seat_state:core.Ref(inp.Seats),seats:core.Read(inp.Seat),requests:^inp.Seat_Requests,
    contexts:core.Ref(inp.Input_Contexts),context_requests:^inp.Context_Requests,
) -> (on_top:bool) {
    for e in gui.unblock {
        inp.input_unblock(requests,e)
        inp.input_context_leave(context_requests,e)
    }
    clear(&gui.unblock)
    for &instance in gui.instances {
        on_top||=instance.modal
        enter:=instance.taking && instance.input_context!=inp.CONTEXT_BASE
        block:=instance.modal && !enter
        if enter || block {
            seat:=core.NONE
            if instance.player>0 {
                seat=inp.local_seat(seats,instance.player-1)
                if seat==core.NONE {continue}
            }
            // Asked again until input applies it, and after a load or a rollback took it away.
            if block && !inp.blocking(seat_state.ptr,instance.entity) {inp.input_block(requests,instance.entity,seat)}
            if enter && !inp.in_context(contexts.ptr,instance.entity) {inp.input_context_enter(context_requests,instance.entity,seat,instance.input_context,instance.modal)}
        }
        if instance.blocking && !block {inp.input_unblock(requests,instance.entity)}
        if instance.entered && !enter {inp.input_context_leave(context_requests,instance.entity)}
        instance.blocking,instance.entered=block,enter
    }
    return
}
