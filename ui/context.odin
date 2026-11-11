package ui

import "base:runtime"
import "core:hash"
import "core:mem"
import "mirai:std/base"

// Reads the clipboard into buffer and returns the bytes written.
Clipboard_Get :: #type proc(user:rawptr,buffer:[]u8) -> int
Clipboard_Set :: #type proc(user:rawptr,text:string)
// Draws what the library does not know, by node.name: a canvas, a Draw node of
// a tree, or an icon from Icon.User on (its index). Only draw_* procedures may
// be called from it.
Draw_Proc :: #type proc(user:rawptr,ctx:^Context,node:Draw_Node)

Context_Desc :: struct {
    allocator:runtime.Allocator, // context.allocator when unset
    // Capacities of one frame; zero takes the default.
    max_elements:int,   // layout elements (8192)
    max_transitions:int, // elements a style carries to a new layout at once (64)
    max_text_words:int, // words kept measured for this frame, and as many for earlier ones (2 * max_elements)
    max_clips:int,      // containers that clip (256, at most 65535)
    max_widgets:int,    // interactive or tracked elements (2048)
    max_paints:int,     // drawn elements (max_elements)
    max_vertices:int,   // (262144)
    max_commands:int,   // (256)
    max_shapes:int,     // analytic primitives (8192)
    max_layers:int,     // isolated composition layers (64), nesting <= 8
    max_text:int,       // bytes of text kept until the frame is drawn (65536)
    max_scopes:int,     // animated subtrees (256)
    max_panels:int,     // world panels (32)
    max_grid_tracks:int, // rows of grid tracks a frame holds (64): grid_tracks_add
    fonts:[][]byte,     // TrueType files that outlive the context; Inter when empty
    font_sizes:[]i32,   // em sizes rasterized on their own; those of the editor when empty
    // A font on demand of the owner of the context, borrowed: the context
    // reads it, asks for the glyphs it lacks and never rasterizes. nil: the
    // context has a font of its own, from fonts and font_sizes.
    font:^Font,
    // Called with font_user when a glyph is asked for: the owner rasterizes it
    // there (font_update without growing) and it is drawn in that frame. nil:
    // what is asked for waits for the next frame.
    font_ask:proc(user:rawptr),
    font_user:rawptr,
    density:f32,        // device pixels per window point; 0 means 1
    font_texture:u32,   // travels in the data of glyph quads
    no_font:bool,       // lays out and draws shapes without rasterizing the atlas
    sheet:^Tree_Data,   // the style file of what nothing else styles (context_sheet_set), read at init; nil: none
    navigation:bool,    // keyboard and gamepad move the focus between widgets
    clipboard_get:Clipboard_Get,
    clipboard_set:Clipboard_Set,
    clipboard_user:rawptr,
    draw_user:Draw_Proc,
    draw_user_data:rawptr, // what draw_user is called with
}

Widget_Flag :: enum u8 {
    Block,     // takes the pointer and does nothing with it
    Focusable, // navigation stops on it
    Passive,   // tracked for its rectangle alone: the pointer goes through
    Scroll,    // the wheel moves it
    Disabled,
    Adjusts,   // left and right change its value while it has the focus, instead of moving it
    Kept,      // of a retained subtree drawn again: its rectangles are those it was kept with
    Scrolled,  // out of sight only because the area that holds it is scrolled away from it: navigation reaches it
}
Widget_Flags :: bit_set[Widget_Flag;u8]

@(private)
Widget :: struct {
    id:Id,
    layer:i16,
    clip:u16,    // index in clips of the container that clips it; 0: none
    scope:u16,
    surface:u16,
    flags:Widget_Flags,
    effect_clip:u16,
    order:i16,   // where Tab reaches it: those with an order first, by it; 0 after them, as built
    group:Id,    // navigation stays among the widgets of the group of the one with the focus
    rect:Rect,   // as laid out
    piece_of:i32,// of a piece of a text after the first of its span: the widget of that one, plus one
    area:Rect,   // the part of rect the pointer reaches
}

// Where the focus goes from a widget, up, right, down and left, before the
// nearest one is looked for; 0: the nearest.
Focus_Link :: struct {from:Id,to:[4]Id}
// A container the focus that leaves it by a side comes back into by the other.
Focus_Group :: struct {id:Id,x,y:bool}
// What the pointer drags: a node of a tree, until it is let go.
Drag :: struct {
    id:Id,       // its element
    name:u64,    // its name in its tree
    tag:u64,     // what it carries: the Drops that accept it
    item:i32,
    owner:u64,   // Context.owner when its tree was built
    node:i32,
    offset:[2]f32, // from its corner to the pointer
    rect:Rect,
    dropped:bool,  // let go this frame: a Drop under the pointer takes it
}

FOCUS_LINKS :: 256
@(private)
Clip :: struct {id:Id,parent:u16,surface:u16,scope:u16,rect:Rect,paint:^Paint,scroll:bool}

// Layers of floating surfaces: the highest one under the pointer takes it.
LAYER_PANEL   :: i16(1)
LAYER_BAR     :: i16(2)
LAYER_TOAST   :: i16(3)
LAYER_POPUP   :: i16(10)
LAYER_TOOLTIP :: i16(11)
LAYER_MODAL   :: i16(20)

ID_STACK_DEPTH :: 32
LAYER_STACK_DEPTH :: 16
// Elements left for what frame_end builds itself.
@(private) ELEMENT_RESERVE :: 16

@(private)
Effect_Clip :: struct {id:Id,parent,scope:u16,rect:Rect,radius,opacity:f32,suppressed:bool}
@(private)
Effect_Entry :: struct {clip:u16,refused:int}

Context :: struct {
    allocator:runtime.Allocator,
    sheet:Widget_Tree,        // the styles of the style file of what nothing else styles
    sheet_tokens:[]Tree_Token,
    sheet_names:[]Sheet_Name, // of its styles and its tokens, by hash
    release_activates:bool,   // a button activates when the pointer is let go over it, not when it is pressed
    font:Font,          // the context's own, or a copy of font_owner taken at frame_begin
    font_owner:^Font,   // the font the context borrows; nil when it has its own
    font_ask:proc(user:rawptr),
    font_user:rawptr,
    stats:Stats,
    game:Game_Source,
    owner:u64, // who builds what is being built: a Dropped event says it of what was dragged
    icons:[ICON_CUSTOM_CAPACITY]Icon_Drawing, // of icon_custom_set

    layout:Layout_Tree,
    layout_started:bool, // an element of this frame started the layout
    max_elements:int,
    elements:int,
    skipped:int,        // elements open that were refused for lack of capacity

    input:Input,
    scale:f32,          // layout units to window points
    size:[2]f32,        // the surface in layout units
    safe:Rect,          // the safe area in layout units
    pointer:[2]f32,     // in the units of the surface being built
    screen_pointer:[2]f32,
    time:f64,           // seconds added up from Input.dt
    in_frame:bool,

    widgets,previous:[]Widget,
    widget_count,previous_count:int,
    previous_ids:Id_Table, // the place in previous of the first widget of each id
    clips:[]Clip,clip_count:int, // the first is no clip
    // Containers that clip around what is being built; 0 is none, which a popup pushes.
    clip_stack:[LAYOUT_DEPTH+POPUP_DEPTH]u16,clip_depth,clip_skipped:int,
    paints:[]Paint,paint_count:int,
    text_open:Text_Open,
    widget_pieces:int,  // where the widgets frame_end adds for the pieces of texts start
    text:[]u8,text_length:int,
    draw:Draw,
    effects,previous_effects:[]Effect_Clip,
    effect_count,previous_effect_count:int,
    effect_clip:u16,
    effect_stack:[ID_STACK_DEPTH]Effect_Entry,effect_depth,effect_skipped,effect_refused:int,

    scopes:[]Scope,scope_count:int,
    previous_scopes:[]Affine,previous_scope_count:int, // surface to scope, for the pointer
    scope:u16,

    panels,previous_panels:[]Panel,
    panel_count,previous_panel_count:int,
    placements:[]World_Placement,
    surface:u16,        // 0: the screen; n: panels[n-1]
    area:Id,            // while not 0, what Surface and Safe floats hang from in place of the surface (Tree_Build_Desc.area)
    area_rect:Rect,     // its rectangle, in layout units

    // A push onto a full stack is not applied and is counted in its *_skipped,
    // so its pop takes nothing off: Stats.dropped_nesting.
    id_stack:[ID_STACK_DEPTH]u32,id_depth,id_skipped:int,
    layer:i16,
    layer_stack:[LAYER_STACK_DEPTH]i16,layer_depth,layer_skipped:int,

    hot:Id,             // widget under the pointer
    hot_layer:i16,
    active:Id,          // widget that holds the pointer since it was pressed on it
    focus:Id,           // widget the keyboard or the gamepad acts on
    press:[2]f32,       // where the pointer was pressed
    press_used:bool,    // the left press of this frame already did something
    right_press_used:bool,
    over:bool,          // the pointer is over something of the UI
    navigation:bool,
    focus_ring:bool,    // the focus moved by keyboard or gamepad, so it shows
    focus_seen:Id,      // focus when the last frame began
    focus_moved:bool,   // the keyboard or the gamepad moved it since then, or an area is still bringing it into sight
    focus_pending:bool, // an area moved toward the focus, or waits for one inside it, this frame
    reveal,reveal_next:Id, // a row the keys moved to in a list: the areas that hold it bring it into sight the next frame
    scroll_grab:f32,    // offset of the area whose bar is being dragged, when it was pressed
    scroll_target:Id,   // scroll area the keys and the stick that scroll move this frame
    scroll_keys:bool,   // the scroll target holds nothing focusable: Page Up, Page Down, Home and End move it
    edit_request:Id,    // field asked to start editing when it is built
    edit_request_frame:u64,
    active_frame:u64,   // last frame the active widget was built
    navigation_layer:i16, // navigation stays on this layer and above: the open popup or dialog
    escape_used:bool,
    wheel_target:Id,    // scroll area the wheel of this frame belongs to
    pointer_moved:bool,
    last_pointer:[2]f32,
    cursor:Cursor,      // the shape the pointer asks for this frame
    dropped_before:u32,
    activate:Id,        // focused widget the keyboard or gamepad activated this frame
    disabled_depth:int,
    invisible:int,      // scopes of what keeps its room but draws nothing and takes no input
    unfocusable:int,    // inside this many scopes navigation does not stop on widgets: a passive tree
    order:i16,          // the order of Tab the next widget gets
    nav_group:Id,       // the navigation group the next widget gets: an interface tried inside another
    links,previous_links:[]Focus_Link,
    link_count,previous_link_count:int,
    groups,previous_groups:[]Focus_Group,
    group_count,previous_group_count:int,
    drag:Drag,
    retained:[RETAINED_CAPACITY]Retained,
    retaining:u8,       // the retained subtree being built, plus one

    edit:Text_Edit,
    scrub:Scrub,
    popup:Popup_State,
    tooltip:string,
    tooltip_hot:Id,     // what the pointer rests on, since tooltip_since, still asked for on tooltip_frame
    tooltip_since:f64,
    tooltip_frame:u64,
    modal_open:bool,
    modal_layer:i16,

    clipboard_get:Clipboard_Get,
    clipboard_set:Clipboard_Set,
    clipboard_user:rawptr,
    draw_user:Draw_Proc,
    draw_user_data:rawptr, // what draw_user is called with
}

// What a frame leaves for the renderer and the host. The slices belong to the
// context and last until its next frame begins.
Frame :: struct {
    vertices:[]Vertex,
    commands:[]Draw_Command,
    shapes:[]Shape,
    layers:[]Layer,
    placements:[]World_Placement,
    pointer_consumed:bool,  // the pointer is over the UI or held by it
    keyboard_consumed:bool, // typing or navigation belongs to the UI
    overflow:bool,          // something did not fit in a capacity this frame: see Stats
    transitioning:bool,     // an element is on its way to where the layout put it: the next frame differs
}

context_init :: proc(ctx:^Context,desc:Context_Desc) -> bool {
    ctx^={}
    ctx.allocator=desc.allocator if desc.allocator.procedure!=nil else context.allocator
    ctx.navigation=desc.navigation
    ctx.clipboard_get,ctx.clipboard_set,ctx.clipboard_user=desc.clipboard_get,desc.clipboard_set,desc.clipboard_user
    ctx.draw_user,ctx.draw_user_data=desc.draw_user,desc.draw_user_data
    ctx.max_elements=desc.max_elements if desc.max_elements>0 else 8192
    count :: proc(value,fallback:int) -> int {return value if value>0 else fallback}
    ok:=true
    slice :: proc($T:typeid,n:int,allocator:runtime.Allocator,ok:^bool) -> []T {
        result,error:=make([]T,n,allocator)
        if error!=nil {ok^=false}
        return result
    }
    a:=ctx.allocator
    ctx.widgets=slice(Widget,count(desc.max_widgets,2048),a,&ok)
    ctx.previous=slice(Widget,len(ctx.widgets),a,&ok)
    if !id_table_init(&ctx.previous_ids,len(ctx.widgets),a) {ok=false}
    ctx.links=slice(Focus_Link,FOCUS_LINKS,a,&ok)
    ctx.previous_links=slice(Focus_Link,FOCUS_LINKS,a,&ok)
    ctx.groups=slice(Focus_Group,FOCUS_LINKS,a,&ok)
    ctx.previous_groups=slice(Focus_Group,FOCUS_LINKS,a,&ok)
    ctx.paints=slice(Paint,count(desc.max_paints,ctx.max_elements),a,&ok)
    ctx.text=slice(u8,count(desc.max_text,65536),a,&ok)
    vertices:=count(desc.max_vertices,262144)
    if base.region_reserve(&ctx.draw.region,vertices*size_of(Vertex)) {
        ctx.draw.vertices=base.region_slice(&ctx.draw.region,Vertex,vertices)
    } else {ok=false}
    ctx.draw.commands=slice(Draw_Command,count(desc.max_commands,256),a,&ok)
    ctx.draw.shapes=slice(Shape,count(desc.max_shapes,8192),a,&ok)
    ctx.draw.layers=slice(Layer,count(desc.max_layers,64),a,&ok)
    ctx.effects=slice(Effect_Clip,len(ctx.draw.layers)+1,a,&ok)
    ctx.previous_effects=slice(Effect_Clip,len(ctx.effects),a,&ok)
    ctx.scopes=slice(Scope,count(desc.max_scopes,256),a,&ok)
    ctx.previous_scopes=slice(Affine,len(ctx.scopes),a,&ok)
    ctx.panels=slice(Panel,count(desc.max_panels,32),a,&ok)
    ctx.previous_panels=slice(Panel,len(ctx.panels),a,&ok)
    ctx.placements=slice(World_Placement,len(ctx.panels),a,&ok)
    // A widget names the clip it is in with 16 bits.
    ctx.clips=slice(Clip,min(count(desc.max_clips,256),int(max(u16)))+1,a,&ok)
    if !ok {context_destroy(ctx);return false}

    if desc.no_font {
        ctx.font={allocator=a,density=desc.density if desc.density>0 else 1}
    } else if desc.font!=nil && desc.font.ready {
        ctx.font,ctx.font_owner=desc.font^,desc.font
        ctx.font_ask,ctx.font_user=desc.font_ask,desc.font_user
    } else if !font_init(&ctx.font,desc.fonts,desc.font_sizes,desc.density,a) {
        context_destroy(ctx);return false
    }
    ctx.draw.font_quad=quad_pack(.Glyph,desc.font_texture)

    words:=desc.max_text_words if desc.max_text_words>0 else ctx.max_elements*2
    if !layout_init(&ctx.layout,a,ctx.max_elements,words,len(ctx.text),count(desc.max_grid_tracks,64),count(desc.max_transitions,64)) {context_destroy(ctx);return false}
    if desc.sheet!=nil && !context_sheet_set(ctx,desc.sheet^) {context_destroy(ctx);return false}
    return true
}

context_destroy :: proc(ctx:^Context) {
    a:=ctx.allocator
    if ctx.font_owner==nil && ctx.font.allocator.procedure!=nil {font_destroy(&ctx.font)}
    layout_destroy(&ctx.layout)
    delete(ctx.widgets,a);delete(ctx.previous,a);delete(ctx.paints,a);delete(ctx.text,a)
    id_table_destroy(&ctx.previous_ids,a)
    delete(ctx.links,a);delete(ctx.previous_links,a);delete(ctx.groups,a);delete(ctx.previous_groups,a)
    retained_destroy(ctx)
    sheet_destroy(ctx)
    base.region_release(&ctx.draw.region);delete(ctx.draw.commands,a)
    delete(ctx.draw.shapes,a);delete(ctx.draw.layers,a)
    delete(ctx.effects,a);delete(ctx.previous_effects,a)
    delete(ctx.scopes,a);delete(ctx.previous_scopes,a)
    delete(ctx.panels,a);delete(ctx.previous_panels,a);delete(ctx.placements,a)
    delete(ctx.clips,a)
    ctx^={}
}

// Rasterizes the atlas again for a display of another density. A transaction:
// it may allocate, and on failure the previous atlas stays.
context_set_density :: proc(ctx:^Context,density:f32) -> bool {
    // A borrowed font follows the density its owner gives it.
    if ctx.font_owner!=nil {return true}
    if !ctx.font.ready {ctx.font.density=density if density>0 else 1;return true}
    if ctx.font.density==clamp(density,FONT_DENSITY_MIN,FONT_DENSITY_MAX) {return true}
    return font_set_density(&ctx.font,density)
}

// ---------------------------------------------------------------- ids

@(private) ID_SEED :: u32(0x811c9dc5) // of an element outside every scope: the start of FNV-1a 32

// Identity of an element from a name and an index, inside the scopes pushed
// with id_push.
id :: proc(ctx:^Context,name:string,index:int=0) -> Id {
    seed:=ctx.id_stack[ctx.id_depth-1] if ctx.id_depth>0 else ID_SEED
    value:=hash.fnv32a(transmute([]byte)name,seed)
    if index!=0 {
        number:=u32(index)
        value=hash.fnv32a(mem.ptr_to_bytes(&number),value)
    }
    return Id(value) if value!=0 else Id(1)
}
// Ids made until id_pop belong to this scope: the rows of a list, the fields
// of an object. A scope nested deeper than ID_STACK_DEPTH is not opened: its
// ids are those of the scope around it.
id_push :: proc(ctx:^Context,scope:Id) {
    if ctx.id_depth>=ID_STACK_DEPTH {ctx.id_skipped+=1;ctx.stats.dropped_nesting+=1;return}
    ctx.id_stack[ctx.id_depth]=u32(scope);ctx.id_depth+=1
}
id_pop :: proc(ctx:^Context) {
    if ctx.id_skipped>0 {ctx.id_skipped-=1;return}
    if ctx.id_depth>0 {ctx.id_depth-=1}
}

// Where what has an id is: the first place put for it. A slot of an earlier
// generation is free, so emptying the table costs nothing. It has slots for
// twice what it is made for, and is given no more than that.
@(private)
Id_Table :: struct {ids:[]Id,places:[]i32,generations:[]u32,mask,generation:u32}

@(private)
id_table_init :: proc(t:^Id_Table,most:int,allocator:runtime.Allocator) -> bool {
    slots:=16
    for slots<most*2 {slots<<=1}
    errors:[3]runtime.Allocator_Error
    t.ids,errors[0]=make([]Id,slots,allocator)
    t.places,errors[1]=make([]i32,slots,allocator)
    t.generations,errors[2]=make([]u32,slots,allocator)
    if errors!={} {id_table_destroy(t,allocator);return false}
    // Allocated memory is not promised to be zeroed, and a slot is free by
    // the generation it holds.
    mem.zero_slice(t.generations)
    t.mask,t.generation=u32(slots-1),1
    return true
}
@(private)
id_table_destroy :: proc(t:^Id_Table,allocator:runtime.Allocator) {
    delete(t.ids,allocator);delete(t.places,allocator);delete(t.generations,allocator)
    t^={}
}
@(private)
id_table_clear :: proc(t:^Id_Table) {
    t.generation+=1
    if t.generation==0 {mem.zero_slice(t.generations);t.generation=1}
}
@(private)
id_table_slot :: #force_inline proc "contextless" (t:^Id_Table,id:Id) -> u32 {
    // Ids are hashes already: one multiplication spreads them over the slots.
    return (u32(id)*2654435761)>>8 & t.mask
}
// False when the id has a place already, which it keeps.
@(private)
id_table_put :: proc(t:^Id_Table,id:Id,place:i32) -> bool {
    slot:=id_table_slot(t,id)
    for t.generations[slot]==t.generation {
        if t.ids[slot]==id {return false}
        slot=(slot+1)&t.mask
    }
    t.generations[slot]=t.generation
    t.ids[slot]=id
    t.places[slot]=place
    return true
}
@(private)
id_table_find :: proc(t:^Id_Table,id:Id) -> (place:i32,found:bool) {
    if len(t.ids)==0 {return}
    slot:=id_table_slot(t,id)
    for t.generations[slot]==t.generation {
        if t.ids[slot]==id {return t.places[slot],true}
        slot=(slot+1)&t.mask
    }
    return
}

// Adds the widths of the columns of a Grid to the frame and returns what its
// Layout.tracks names them by; 0 when the frame holds no more (counted in
// Stats.dropped_tracks), and the Grid has columns of one width.
grid_tracks_add :: proc(ctx:^Context,tracks:Grid_Tracks) -> u16 {
    t:=&ctx.layout
    if t.track_count>=len(t.tracks) || t.track_count>=int(max(u16)) {ctx.stats.dropped_tracks+=1;return 0}
    t.tracks[t.track_count]=tracks
    t.track_count+=1
    return u16(t.track_count)
}

// ---------------------------------------------------------------- frame storage

// Copies text so it lasts until the frame is drawn, whatever buffer it came from.
text_store :: proc(ctx:^Context,text:string) -> string {
    if len(text)==0 {return ""}
    if ctx.text_length+len(text)>len(ctx.text) {ctx.stats.dropped_text+=1;return ""}
    stored:=ctx.text[ctx.text_length:][:len(text)]
    copy(stored,text)
    ctx.text_length+=len(text)
    return string(stored)
}
// Room for formatted text that lasts until the frame is drawn; give back what
// was not used with text_commit.
text_reserve :: proc(ctx:^Context,size:int) -> []u8 {
    if ctx.text_length+size>len(ctx.text) {ctx.stats.dropped_text+=1;return nil}
    return ctx.text[ctx.text_length:][:size]
}
text_commit :: proc(ctx:^Context,used:string) -> string {
    ctx.text_length+=len(used)
    return used
}

paint_add :: proc(ctx:^Context,paint:Paint) -> ^Paint {
    if ctx.paint_count>=len(ctx.paints) {ctx.stats.dropped_paints+=1;return nil}
    stored:=paint
    if ctx.invisible>0 {stored.hidden,stored.layer.enabled=true,false}
    stored.surface,stored.scope=ctx.surface,ctx.scope
    stored.text=text_store(ctx,paint.text);stored.detail=text_store(ctx,paint.detail)
    stored.label=text_store(ctx,paint.label);stored.placeholder=text_store(ctx,paint.placeholder)
    p:=&ctx.paints[ctx.paint_count];ctx.paint_count+=1
    p^=stored
    return p
}

// ---------------------------------------------------------------- elements

// Registers an element whose rectangle matters after the frame: the pointer
// reaches it, or it is looked up with widget_rect.
@(private)
widget_add :: proc(ctx:^Context,id:Id,flags:Widget_Flags) {
    if id==0 || ctx.skipped>0 {return}
    flags:=flags
    if ctx.effect_refused>0 || ctx.invisible>0 {flags+={.Passive,.Disabled}}
    if ctx.unfocusable>0 {flags-={.Focusable}}
    // The element that a scope registered as its pivot takes the place of that entry.
    if ctx.widget_count>0 && ctx.widgets[ctx.widget_count-1].id==id && .Passive in ctx.widgets[ctx.widget_count-1].flags {ctx.widget_count-=1}
    if ctx.widget_count>=len(ctx.widgets) {ctx.stats.dropped_widgets+=1;return}
    ctx.widgets[ctx.widget_count]={id=id,layer=ctx.layer,clip=ctx.clip_stack[ctx.clip_depth-1] if ctx.clip_depth>0 else 0,scope=ctx.scope,surface=ctx.surface,flags=flags,effect_clip=ctx.effect_clip,order=ctx.order,group=ctx.nav_group}
    ctx.widget_count+=1
}

// The rectangle an element had when the previous frame was laid out: the one
// that was on screen when this frame's input happened.
widget_rect :: proc(ctx:^Context,id:Id) -> (rect:Rect,found:bool) {
    w:=widget_previous(ctx,id)
    if w==nil {return {},false}
    return w.rect,true
}
// The widget of an id in the previous frame, the first registered with it;
// nil when none was.
@(private)
widget_previous :: proc(ctx:^Context,id:Id) -> ^Widget {
    place,found:=id_table_find(&ctx.previous_ids,id)
    return &ctx.previous[place] if found else nil
}

// A float nested deeper than LAYER_STACK_DEPTH stays in the layer around it.
@(private)
layer_push :: proc(ctx:^Context,layer:i16) {
    if ctx.layer_depth>=LAYER_STACK_DEPTH {ctx.layer_skipped+=1;ctx.stats.dropped_nesting+=1;return}
    ctx.layer_stack[ctx.layer_depth]=ctx.layer;ctx.layer_depth+=1
    ctx.layer=layer
}
@(private)
layer_pop :: proc(ctx:^Context) {
    if ctx.layer_skipped>0 {ctx.layer_skipped-=1;return}
    if ctx.layer_depth<=0 {return}
    ctx.layer_depth-=1;ctx.layer=ctx.layer_stack[ctx.layer_depth]
}

// Keeps the composition layer around what is built for effect_pop. False when
// the stack is full: the box changes nothing of it.
@(private)
effect_push :: proc(ctx:^Context) -> bool {
    if ctx.effect_depth>=len(ctx.effect_stack) {ctx.effect_skipped+=1;ctx.stats.dropped_nesting+=1;return false}
    ctx.effect_stack[ctx.effect_depth]={ctx.effect_clip,ctx.effect_refused};ctx.effect_depth+=1
    return true
}
@(private)
effect_pop :: proc(ctx:^Context) {
    if ctx.effect_skipped>0 {ctx.effect_skipped-=1;return}
    if ctx.effect_depth<=0 {return}
    ctx.effect_depth-=1
    e:=ctx.effect_stack[ctx.effect_depth]
    ctx.effect_clip,ctx.effect_refused=e.clip,e.refused
}

// The containers around what is built stop clipping it until clips_resume: a
// popup, a modal.
@(private)
clips_suspend :: proc(ctx:^Context) {
    if ctx.clip_depth>=len(ctx.clip_stack) {ctx.clip_skipped+=1;ctx.stats.dropped_clips+=1;return}
    ctx.clip_stack[ctx.clip_depth]=0;ctx.clip_depth+=1
}
@(private)
clips_resume :: proc(ctx:^Context) {
    if ctx.clip_skipped>0 {ctx.clip_skipped-=1;return}
    if ctx.clip_depth>0 {ctx.clip_depth-=1}
}

// ---------------------------------------------------------------- frame

@(private)
dropped_total :: proc "contextless" (s:^Stats) -> u32 {
    return s.dropped_elements+s.dropped_widgets+s.dropped_paints+s.dropped_vertices+s.dropped_commands+s.dropped_text+s.dropped_scopes+s.dropped_panels+s.dropped_clips+s.layout_errors+s.dropped_shapes+s.dropped_layers+s.dropped_tree+s.dropped_tracks+s.dropped_nesting+s.dropped_transitions
}

// Begun inside a frame that was not ended, it starts over and that frame is lost.
frame_begin :: proc(ctx:^Context,input:Input) {
    if ctx.in_frame {ctx.stats.layout_errors+=1}
    ctx.in_frame=true
    if ctx.font_owner!=nil {ctx.font=ctx.font_owner^}
    ctx.input=input
    ctx.scale=input.scale if input.scale>0 else 1
    ctx.size={max(input.size.x,1),max(input.size.y,1)}/ctx.scale
    ctx.safe={input.safe[0]/ctx.scale,input.safe[1]/ctx.scale,0,0}
    ctx.safe.w=max(ctx.size.x-ctx.safe.x-input.safe[2]/ctx.scale,0)
    ctx.safe.h=max(ctx.size.y-ctx.safe.y-input.safe[3]/ctx.scale,0)
    ctx.screen_pointer=input.pointer/ctx.scale
    ctx.pointer=ctx.screen_pointer
    ctx.cursor=.Default
    ctx.pointer_moved=input.pointer!=ctx.last_pointer
    ctx.last_pointer=input.pointer
    ctx.time+=f64(input.dt)
    ctx.stats.frame+=1
    ctx.dropped_before=dropped_total(&ctx.stats)

    ctx.widget_count=0;ctx.paint_count=0;ctx.text_length=0;ctx.text_open={}
    ctx.effect_count=1;ctx.effect_clip=0;ctx.effect_depth=0;ctx.effect_skipped=0;ctx.effect_refused=0
    ctx.clip_count=1;ctx.clip_depth=0;ctx.clip_skipped=0;ctx.scope_count=1;ctx.scope=0
    ctx.scopes[0]={m=AFFINE_IDENTITY,tint={1,1,1,1}}
    ctx.panel_count=0;ctx.surface=0;ctx.area=0
    ctx.id_depth=0;ctx.id_skipped=0;ctx.layer=0;ctx.layer_depth=0;ctx.layer_skipped=0;ctx.disabled_depth=0;ctx.invisible=0;ctx.unfocusable=0;ctx.order=0;ctx.nav_group=0
    ctx.link_count=0;ctx.group_count=0;ctx.retaining=0
    ctx.elements=0;ctx.skipped=0
    ctx.tooltip="";ctx.modal_open=false;ctx.activate=0
    ctx.press_used=false;ctx.right_press_used=false;ctx.escape_used=false
    ctx.popup.depth=0
    ctx.layout.track_count=0
    draw_reset(&ctx.draw,{0,0,ctx.size.x,ctx.size.y},ctx.scale,ctx.font.density)

    // A drag ends when the button that holds it is let go: a Drop under the
    // pointer takes it in this frame. Escape ends it with nothing taking it.
    if ctx.drag.id!=0 && .Left not_in input.down {ctx.drag.dropped=true}
    if ctx.drag.id!=0 && .Escape in input.keys_pressed {ctx.drag={};ctx.escape_used=true}
    input_route(ctx)
    popup_route(ctx)
    navigation_route(ctx)
    scroll_route(ctx)
    // Moves made while building the last frame count in this one, and areas
    // that are still bringing the focus into sight go on until it is.
    ctx.focus_moved=ctx.focus!=ctx.focus_seen && ctx.focus_ring || ctx.focus_pending && ctx.focus==ctx.focus_seen
    ctx.focus_pending=false
    ctx.reveal,ctx.reveal_next=ctx.reveal_next,0
    ctx.focus_seen=ctx.focus

    ctx.layout_started=false
}

// Closes the panel, the containers and the layers the builder left open, so a
// frame that misses an end is still laid out and drawn.
@(private)
frame_close :: proc(ctx:^Context) {
    d:=&ctx.draw
    open:=ctx.layout_started && ctx.layout.open_len>1
    if ctx.text_open.open {
        ctx.stats.layout_errors+=1
        text_end(ctx)
    }
    if !open && ctx.surface==0 && ctx.skipped==0 && ctx.clip_depth==0 && d.composition_depth==0 && d.skipped_layers==0 {return}
    ctx.stats.layout_errors+=1
    compositions_close(ctx)
    if ctx.surface!=0 {world_panel_end(ctx)}
    if open {for ctx.layout.open_len>1 {layout_close(&ctx.layout)}}
    ctx.skipped,ctx.clip_depth,ctx.clip_skipped=0,0,0
}

// An empty Frame when no frame was begun.
frame_end :: proc(ctx:^Context) -> Frame {
    if !ctx.in_frame {ctx.stats.layout_errors+=1;return {}}
    frame_close(ctx)
    popup_frame_end(ctx)
    if ctx.tooltip!="" && ctx.popup.count==0 && !ctx.modal_open {tooltip_build(ctx)}

    // Without an element in the frame there is no layout to end.
    laid:=ctx.layout_started
    transitioning:=false
    ctx.widget_pieces=ctx.widget_count
    if laid {
        t:=&ctx.layout
        transitioning=layout_finish(t,&ctx.font,ctx.stats.frame,ctx.input.dt,ctx.scale*ctx.font.density)
        ctx.stats.layout_errors+=u32(t.duplicates)
        if t.overflow {ctx.stats.dropped_elements+=1}
        for &w in ctx.widgets[:ctx.widget_count] {
            if rect,found:=layout_find(t,w.id);found {w.rect=rect}
        }
        text_widgets_place(ctx)
        // A clip of another scope is in other coordinates: a scaled game in a clipped stage.
    for &c in ctx.clips[1:ctx.clip_count] {
            if rect,found:=layout_find(t,c.id);found {c.rect=rect}
            if c.parent!=0 && ctx.clips[c.parent].scope==c.scope {c.rect=rect_intersect(c.rect,ctx.clips[c.parent].rect)}
        }
        for &e in ctx.effects[1:ctx.effect_count] {
            if rect,found:=layout_find(t,e.id);found {e.rect=rect}
        }
    }
    for &w in ctx.widgets[:ctx.widget_count] {
        if .Kept in w.flags {continue}
        w.area=w.rect
        if w.clip!=0 && ctx.clips[w.clip].scope==w.scope {
            c:=&ctx.clips[w.clip]
            w.area=rect_intersect(w.rect,c.rect)
            if c.scroll && (w.area.w<=0 || w.area.h<=0) && c.rect.w>0 && c.rect.h>0 && w.rect.w>0 && w.rect.h>0 {w.flags+={.Scrolled}}
        }
        for index:=w.effect_clip;index!=0;index=ctx.effects[index].parent {
            e:=&ctx.effects[index]
            if e.opacity<=0 || e.suppressed {w.area.w=0;w.area.h=0;break}
            if e.scope==w.scope {w.area=rect_intersect(w.area,e.rect)}
        }
    }
    scopes_resolve(ctx)
    panels_resolve(ctx)
    if laid {layout_paint(ctx)}
    retained_frame_end(ctx)
    focus_ring_draw(ctx)

    input_frame_end(ctx)
    ctx.widgets,ctx.previous=ctx.previous,ctx.widgets
    ctx.previous_count=ctx.widget_count
    id_table_clear(&ctx.previous_ids)
    for &w,place in ctx.previous[:ctx.previous_count] {id_table_put(&ctx.previous_ids,w.id,i32(place))}
    ctx.links,ctx.previous_links=ctx.previous_links,ctx.links
    ctx.previous_link_count=ctx.link_count
    ctx.groups,ctx.previous_groups=ctx.previous_groups,ctx.groups
    ctx.previous_group_count=ctx.group_count
    if ctx.drag.dropped {ctx.drag={}}
    ctx.effects,ctx.previous_effects=ctx.previous_effects,ctx.effects
    ctx.previous_effect_count=ctx.effect_count
    ctx.panels,ctx.previous_panels=ctx.previous_panels,ctx.panels
    ctx.previous_panel_count=ctx.panel_count

    d:=&ctx.draw
    s:=&ctx.stats
    s.dropped_vertices+=d.dropped_vertices;s.dropped_commands+=d.dropped_commands
    s.dropped_shapes+=d.dropped_shapes;s.dropped_layers+=d.dropped_layers
    s.shapes,s.layers=u32(d.shape_count),u32(d.layer_count)
    s.elements,s.widgets,s.paints=u32(ctx.elements),u32(ctx.previous_count),u32(ctx.paint_count)
    s.vertices,s.commands,s.text_bytes=u32(d.count),u32(d.command_count),u32(ctx.text_length)
    s.scopes,s.panels=u32(ctx.scope_count-1),u32(ctx.previous_panel_count)
    s.text_measured,s.text_reused=u32(ctx.layout.measured),u32(ctx.layout.reused)
    ctx.layout.measured,ctx.layout.reused=0,0
    ctx.in_frame=false
    return {
        vertices=d.vertices[:d.count],commands=d.commands[:d.command_count],shapes=d.shapes[:d.shape_count],layers=d.layers[:d.layer_count],placements=ctx.placements[:ctx.previous_panel_count],
        pointer_consumed=ctx.over || ctx.active!=0,
        keyboard_consumed=ctx.edit.id!=0 || ctx.popup.count>0 || ctx.modal_open || (ctx.navigation && ctx.focus!=0),
        overflow=dropped_total(s)!=ctx.dropped_before,
        transitioning=transitioning,
    }
}

// Draws from here on in the surface and the scope of an element.
@(private)
paint_select :: proc(ctx:^Context,surface,scope:u16) {
    d:=&ctx.draw
    if u32(surface)!=d.surface {
        if surface==0 {
            draw_surface(d,0,{0,0,ctx.size.x,ctx.size.y},ctx.scale,ctx.scale*ctx.font.density,false,true)
        } else {
            panel:=&ctx.panels[surface-1]
            draw_surface(d,u32(surface),{0,0,panel.size.x,panel.size.y},1,panel.density,true,ctx.placements[surface-1].offscreen)
        }
    }
    s:=&ctx.scopes[scope]
    draw_transform(d,s.m,s.tint,scope==0)
}
