package ui

// One UI library for the editor and for games. A Context is one surface:
// widgets are procedures over explicit state, the layout of the frame places
// their elements and every frame ends in a draw list the renderer consumes as
// bytes.
//
// Units: layout happens in layout units; Input.scale converts them to window
// points and Font.density converts points to device pixels. The editor uses
// scale 1, so its layout units are points.

Rect :: struct {x,y,w,h:f32}
Color :: [4]u8 // display (sRGB) values, straight alpha

// Identity of an element inside one context: stable across frames, never zero.
Id :: distinct u32

// Layout of the renderer's UI vertex. position is in the units of its surface.
// The shape the pointer asks for over what it is on, for the host to show.
Cursor :: enum u8 {Default,Text,Resize_Horizontal}

Vertex :: struct {
    position:[3]f32,
    color:[4]f32,
    quad:u32, // quad_pack: how the fragment gets its color
    uv:[2]f32,
}
#assert(size_of(Vertex)==40)
#assert(offset_of(Vertex,color)==12 && offset_of(Vertex,quad)==28 && offset_of(Vertex,uv)==32)

// What a quad samples. Kinds from User on belong to the host: the editor
// uses them for material preview spheres and asset thumbnails.
Quad_Kind :: enum u8 {
    Solid, // color alone
    Glyph, // coverage of the font atlas (data: Context_Desc.font_texture) times color
    Image, // RGBA texture (data: texture index), straight alpha, times color
    Shape, // analytic primitive (data: index in Frame.shapes), local coordinates in uv
    Program, // a ui program over a rounded rectangle (data: index in Frame.shapes; see draw_program)
    User=16,
}
QUAD_DATA_BITS :: 24
QUAD_DATA_MASK :: u32(1)<<QUAD_DATA_BITS-1
quad_pack :: #force_inline proc "contextless" (kind:Quad_Kind,data:u32=0) -> u32 {return u32(kind)<<QUAD_DATA_BITS|data&QUAD_DATA_MASK}
quad_kind :: #force_inline proc "contextless" (quad:u32) -> Quad_Kind {return Quad_Kind(quad>>QUAD_DATA_BITS)}
quad_data :: #force_inline proc "contextless" (quad:u32) -> u32 {return quad&QUAD_DATA_MASK}
quad_user :: #force_inline proc "contextless" (index:u8) -> Quad_Kind {return Quad_Kind(u8(Quad_Kind.User)+index)}

// A textured rectangle to show inside a widget: an image, a thumbnail, a
// material preview. kind Solid means none.
Quad :: struct {kind:Quad_Kind,data:u32,uv:Rect}
quad_whole :: proc "contextless" (kind:Quad_Kind,data:u32) -> Quad {return {kind,data,{0,0,1,1}}}

// Per-primitive data; the shader evaluates coverage in local coordinates.
// The vertex color applies the scope tint without duplicating this data.
Shape :: struct {
    bounds,radii,fill,fill2,stroke,params:[4]f32,
}
#assert(size_of(Shape)==96)
Gradient :: enum u8 {Solid,Vertical,Horizontal}
Shape_Style :: struct {
    fill,fill2,stroke:Color,
    radii:[4]f32, // superior izquierda, superior derecha, inferior derecha, inferior izquierda
    stroke_width:f32,
    gradient:Gradient,
}

// A layer isolates its content before compositing it over its parent.
Layer_Style :: struct {enabled:bool,opacity,radius,backdrop_blur:f32}
Layer :: struct {bounds:Rect,radius,opacity,backdrop_blur,pad:f32}
#assert(size_of(Layer)==32)
Command_Kind :: enum u8 {Triangles,Begin_Layer,End_Layer}

Draw_Command :: struct {
    first,count:u32, // vertices of a triangle list
    scissor:Rect,    // in the units of its surface; the whole surface when nothing clips
    surface:u32,     // 0: the screen; n: Frame.placements[n-1]
    kind:Command_Kind,
    layer:u16,       // Begin/End_Layer: index in Frame.layers
}

Stats :: struct {
    frame:u64,
    // Used by the last frame.
    elements,widgets,paints,vertices,commands,text_bytes,scopes,panels:u32,
    text_measured,text_reused:u32, // runs of text measured anew, and found measured by an earlier one
    // Requests refused since the context was created because a capacity was exhausted.
    dropped_elements,dropped_widgets,dropped_paints,dropped_vertices,dropped_commands:u32,
    dropped_text,dropped_scopes,dropped_panels,dropped_clips:u32,
    shapes,layers:u32,
    dropped_shapes,dropped_layers:u32,
    layout_errors:u32, // ids declared twice in a frame, and frames begun or ended with something left open
    dropped_tree:u32,  // what the nodes of a tree could not hold: spans of a rich text, buttons and letters of an Action_Bar
    dropped_tracks:u32, // rows of grid tracks the frame had no room for
    dropped_nesting:u32, // id scopes, floats and layers nested deeper than their stacks hold, which were not applied
    dropped_transitions:u32, // elements that asked to transition when LAYOUT_TRANSITIONS of them already had this frame
}

rect_intersect :: proc "contextless" (a,b:Rect) -> Rect {
    x,y:=max(a.x,b.x),max(a.y,b.y)
    return {x,y,max(min(a.x+a.w,b.x+b.w)-x,0),max(min(a.y+a.h,b.y+b.h)-y,0)}
}
rect_contains :: proc "contextless" (r:Rect,p:[2]f32) -> bool {
    return p.x>=r.x && p.x<r.x+r.w && p.y>=r.y && p.y<r.y+r.h
}
rect_center :: proc "contextless" (r:Rect) -> [2]f32 {return {r.x+r.w*0.5,r.y+r.h*0.5}}
rect_inset :: proc "contextless" (r:Rect,amount:f32) -> Rect {
    return {r.x+amount,r.y+amount,max(r.w-2*amount,0),max(r.h-2*amount,0)}
}

color_alpha :: proc "contextless" (c:Color,alpha:u8) -> Color {return {c[0],c[1],c[2],alpha}}
color_shade :: proc "contextless" (c:Color,f:f32) -> Color {return {u8(f32(c[0])*f),u8(f32(c[1])*f),u8(f32(c[2])*f),c[3]}}
