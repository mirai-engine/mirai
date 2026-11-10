package terrain_editor

import "core:math"
import "core:path/filepath"
import "core:slice"
import "mirai:cook/textures"
import "mirai:core"
import "mirai:editor"
import terrain "plugins:terrain/runtime"
import "mirai:std/geom"

// What the tool keeps between sessions, in the preferences of the editor: a
// brush for each mode, so that the radius of Sculpt is not the one of Paint,
// and the values of the brushes and of Create.

Brush_Mode :: enum u8 {Sculpt,Holes,Shapes,Paint}

Brush_Settings :: struct {
    radius:f32 `mirai:"min=0.1,max=500,unit=m"`,
    strength:f32 `mirai:"min=0,max=1"`, // what one pass of a stroke does
    falloff:geom.Falloff,
    hardness:f32 `mirai:"min=0,max=0.95"`,
    pressure:bool,       // the pressure of a pen scales the strength
    alpha:u8,            // 0: the disc; n: alpha n-1 of the tool (Terrain_Alphas)
    turn:f32 `mirai:"angle"`, // of the alpha around y
    spin:bool,           // each touch turns the alpha at random
    slope_filter:bool,   // a Heightfield is touched where its slope is within slope
    slope:[2]f32 `mirai:"angle"`,
    slope_invert:bool,   // outside slope instead
}

Terrain_Preferences :: struct {
    brushes:[Brush_Mode]Brush_Settings,
    way:terrain.Brush_Way,    // of Smooth, Flatten, Terrace and Noise
    capped:bool,              // Raise and Lower stop at the height of the press, as with Alt
    interval:f32 `mirai:"min=0.01,unit=m"`, // of Terrace
    riser:f32 `mirai:"min=0,max=1"`,
    noise_scale:f32 `mirai:"min=0.1,unit=m"`,
    toward:bool,              // Paint takes the weight of its layer toward target
    target:f32 `mirai:"min=0,max=1"`,
    ramp_sides:f32 `mirai:"min=0,unit=m"`,
    blend:f32 `mirai:"min=0,unit=m"`,
    height_scale:f32 `mirai:"unit=m"`,
    height_offset:f32 `mirai:"unit=m"`,
    create_kind:terrain.Source_Kind,
    samples,depth,chunk_cells:int,
    cell:f32 `mirai:"min=0.01,unit=m"`,
}

BRUSH_DEFAULT :: Brush_Settings{radius=4,strength=0.5,slope={0,math.PI/4}}
TERRAIN_PREFERENCES_DEFAULT :: Terrain_Preferences{
    brushes={.Sculpt=BRUSH_DEFAULT,.Holes=BRUSH_DEFAULT,.Shapes=BRUSH_DEFAULT,.Paint=BRUSH_DEFAULT},
    interval=2,riser=0.25,noise_scale=8,target=1,
    ramp_sides=2,blend=0.5,height_scale=32,
    create_kind=.Heightfield,samples=65,depth=17,chunk_cells=32,cell=1,
}

@(storage)
Terrain_Tool_Preferences :: struct {provider:editor.Preferences_Provider}
terrain_tool_preferences_default :: proc() -> Terrain_Tool_Preferences {
    return {provider={name="Terrain_Tool",info=type_info_of(Terrain_Preferences),value=terrain_preferences,default=proc(dst:rawptr) {(^Terrain_Preferences)(dst)^=TERRAIN_PREFERENCES_DEFAULT}}}
}

@(private)
terrain_preferences :: proc(s:^editor.Session) -> rawptr {
    tool:=core.world_storage_of(core.world_ref(s.editor_world,s.info,.Editor),Terrain_Tool)
    if tool==nil {return nil}
    tool_ready(tool)
    return &tool.prefs
}

// The mode a brush of the tool is in.
@(private)
tool_mode :: proc "contextless" (t:^Terrain_Tool) -> Brush_Mode {
    switch {
    case tool_painting(t): return .Paint
    case tool_holing(t):   return .Holes
    case tool_shaping(t):  return .Shapes
    }
    return .Sculpt
}

// The brush of the mode the tool is in.
@(private)
brush_of :: proc "contextless" (t:^Terrain_Tool) -> ^Brush_Settings {return &t.prefs.brushes[tool_mode(t)]}

// The alphas the tool offers, from the brushes of Terrain3D (MIT, see
// alphas/LICENSE): the 16-bit PNG of alphas/, in the editor, read when the
// panel or a brush first needs them.
Terrain_Alphas :: struct {
    ready:bool,
    names:[dynamic]string, // of TERRAIN_ALPHAS, without the extension, in order
    list:[dynamic]terrain.Brush_Alpha,
}

@(private)
alphas_free :: proc(a:^Terrain_Alphas) {
    for alpha in a.list {delete(alpha.values)}
    delete(a.names);delete(a.list)
    a^={}
}

// The names of the alphas, read once.
@(private)
alphas_ready :: proc(a:^Terrain_Alphas) {
    if a.ready {return}
    a.ready=true
    embedded:=#load_directory("alphas")
    files:=make([dynamic]string,context.temp_allocator)
    for file in embedded {if filepath.ext(file.name)==".png" {append(&files,file.name)}}
    slice.sort(files[:])
    for name in files {
        for file in embedded {
            if file.name!=name {continue}
            heightmap,error:=textures.heightmap_decode(file.data,256)
            if error!=.None || heightmap.width!=heightmap.height || heightmap.width<2 {textures.heightmap_destroy(&heightmap);continue}
            append(&a.names,filepath.stem(filepath.base(name)))
            append(&a.list,terrain.Brush_Alpha{size=heightmap.width,values=heightmap.values})
        }
    }
}

// The alpha of a brush; nil for the disc.
@(private)
alpha_of :: proc(t:^Terrain_Tool,b:^Brush_Settings) -> ^terrain.Brush_Alpha {
    if b.alpha==0 {return nil}
    alphas_ready(&t.alphas)
    at:=int(b.alpha)-1
    return at<len(t.alphas.list)?&t.alphas.list[at]:nil
}
