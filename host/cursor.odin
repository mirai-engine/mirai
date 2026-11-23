package host

import "core:fmt"
import "core:math"
import "mirai:asset"
import "mirai:core"
import "mirai:platform"
import "mirai:std/base"
import "mirai:ui"

// The pointer of the window. The game (engine/gui, while it has the input)
// and the editor declare what they want of it every frame; app_frame_end
// gives the window what wins, and the window system hears only of a change.
// What wins, in order: the relative mouse, which hides it until it ends; the
// editor while it holds the pointer, with its shape and never an image of the
// game; the game hiding it; the shape the interface under the pointer asks
// for, with the image the game gave that shape.
App_Cursor :: struct {
    game_shape:ui.Cursor, // what the interface of the game under the pointer asks for
    game_hidden:bool,     // UI_Cursor.hidden of the game
    editor:ui.Cursor,     // what the editor shows while it holds the pointer
    editor_holds:bool,    // its bars, a game without the input or the pointer off the scene
    images:[ui.Cursor]Cursor_Loaded, // what each shape of the window was given
    registry:u64, // Registry.revision the images were last compared with their files at
}

// The image a shape was given, and what it was read at: another image,
// another content of its file or another density reads it again.
@(private)
Cursor_Loaded :: struct {
    image:ui.Cursor_Image,
    content:u64, // Registry_File.content_hash of its .tex
    density:f32,
}

// What the window shows, for an agent: the OS cursor is in no capture.
App_Cursor_Shown :: struct {
    shape:ui.Cursor,
    image:base.Asset_Id, // the .tex the shape shows; none: that of the system
    relative:bool,       // the relative mouse hides it
}

@(rodata,private)
CURSORS := [ui.Cursor]platform.Cursor{
    .Default=.Default,.Text=.Text,.Pointer=.Pointer,.Crosshair=.Crosshair,.Move=.Move,
    .Resize_Horizontal=.Resize_Horizontal,.Resize_Vertical=.Resize_Vertical,
    .Resize_Diagonal_Down=.Resize_Diagonal_Down,.Resize_Diagonal_Up=.Resize_Diagonal_Up,
    .Not_Allowed=.Not_Allowed,.Wait=.Wait,.Progress=.Progress,.Hidden=.Hidden,
}
#assert(len(ui.Cursor)==len(platform.Cursor))

// What the interfaces of the game ask of the pointer this frame, from the
// ui phase of the game that has the input. An image that changed, or whose
// file changed, is read now; one that cannot be a cursor is told once in
// problems and the shape keeps the system's until it changes. A frame where
// nothing changed reads no file and calls no window system.
app_cursor_game :: proc(app:^App,shape:ui.Cursor,hidden:bool,images:[ui.Cursor]ui.Cursor_Image,problems:^core.Problems) {
    c:=&app.cursor
    c.game_shape,c.game_hidden=shape,hidden
    if app.platform==nil {return}
    registry:=app.assets.registry.revision if app.assets!=nil else 0
    files_moved:=registry!=c.registry
    c.registry=registry
    for wanted,which in images {
        loaded:=&c.images[which]
        if which==.Hidden || wanted.texture=={} {
            if loaded.image.texture!={} {platform.window_cursor_image_clear(app.platform,CURSORS[which])}
            loaded^={}
            continue
        }
        same:=cursor_image_same(loaded.image,wanted)
        content:=loaded.content
        if files_moved || !same {content=cursor_content(app,wanted.texture)}
        if same && loaded.content==content && loaded.density==app.density {continue}
        loaded^={image=wanted,content=content,density=app.density}
        if message:=cursor_image_load(app,CURSORS[which],wanted);message!="" {
            platform.window_cursor_image_clear(app.platform,CURSORS[which])
            core.report(problems,core.NONE,"gui.cursor","The image of the cursor %v, %s",which,message)
        }
    }
}

// What the editor shows, and whether it holds the pointer this frame.
app_cursor_editor :: proc(app:^App,shape:ui.Cursor,holds:bool) {
    app.cursor.editor,app.cursor.editor_holds=shape,holds
}

app_cursor_shown :: proc(app:^App) -> (shown:App_Cursor_Shown) {
    if app.platform==nil {return}
    cursor,image:=platform.window_cursor(app.platform)
    for system,which in CURSORS {
        if system==cursor {shown.shape=which}
    }
    if image {shown.image=app.cursor.images[shown.shape].image.texture}
    shown.relative=platform.window_relative_mouse(app.platform)
    return
}

// By bits: a NaN the game wrote is the same NaN the next frame.
@(private)
cursor_image_same :: proc "contextless" (a,b:ui.Cursor_Image) -> bool {
    return a.texture==b.texture && transmute([2]u32)a.hotspot==transmute([2]u32)b.hotspot && transmute(u32)a.size==transmute(u32)b.size
}

// What a file of the assets holds; 0 for an id no file is.
@(private)
cursor_content :: proc(app:^App,id:base.Asset_Id) -> u64 {
    if app.assets==nil {return 0}
    file,found:=asset.registry_find(&app.assets.registry,id)
    return file.content_hash if found else 0
}

// What wins goes to the window. Nothing while the relative mouse hides it.
@(private)
app_cursor_apply :: proc(app:^App) {
    if app.platform==nil || platform.window_relative_mouse(app.platform) {return}
    c:=&app.cursor
    shape,custom:=c.editor,false
    if !c.editor_holds {shape,custom=.Hidden if c.game_hidden else c.game_shape,true}
    platform.window_set_cursor(app.platform,CURSORS[shape],custom)
}

// Gives a shape of the window the levels of a .tex: the one image.size wide
// at 1x, the larger ones for denser displays. Empty when it did; otherwise
// what is wrong with it and how to fix it.
@(private)
cursor_image_load :: proc(app:^App,cursor:platform.Cursor,image:ui.Cursor_Image) -> string {
    a:=app.assets
    if a==nil {return "has no assets to be read from"}
    name:=fmt.tprintf("%v",image.texture)
    if record,found:=asset.registry_find(&a.registry,image.texture);found {name=record.path}
    file:asset.Asset
    if error:=assets_file(a,image.texture,asset.KIND_TEXTURE,&file);error!=.None {
        return fmt.tprintf("%s, cannot be read (%v): give it a .tex of the project",name,error)
    }
    defer asset.asset_close(&file)
    view,error:=asset.texture_open(&file,&a.types)
    if error!=.None {return fmt.tprintf("%s, cannot be read (%v): import it again",name,error)}
    info:=view.info^
    size:=image.size if image.size!=0 else ui.CURSOR_SIZE
    switch {
    case !(size>=1 && size<=platform.CURSOR_SIDE_MAX) || size!=math.floor(size):
        return fmt.tprintf("%s, has size %v: give a whole number of points from 1 to %d, or 0 for %d",name,image.size,platform.CURSOR_SIDE_MAX,ui.CURSOR_SIZE)
    case info.format!=.RGBA8 && info.format!=.BC1 && info.format!=.BC7:
        return fmt.tprintf("%s, stores %v: import it as 8-bit color (RGBA8, BC1 or BC7), not HDR, 16-bit or normals",name,info.format)
    case .Srgb not_in info.flags:
        return fmt.tprintf("%s, is not sRGB color: import it as color",name)
    case .Cube in info.flags || info.layers>1:
        return fmt.tprintf("%s, is a cube or an array of %d images: give it a single image",name,info.layers)
    case info.width>platform.CURSOR_SIDE_MAX || info.height>platform.CURSOR_SIDE_MAX:
        return fmt.tprintf("%s, is %dx%d pixels: make it at most %d on each side",name,info.width,info.height,platform.CURSOR_SIDE_MAX)
    }
    one:=-1 // the level at 1x
    for mip,level in view.mips {
        if mip.width==u32(size) {one=level;break}
    }
    if one<0 {return fmt.tprintf("%s, has no level %v pixels wide: make it %v pixels wide, or set size to the width of one of its levels",name,size,size)}
    one_x:=view.mips[one]
    hotspot:=image.hotspot
    if !(hotspot.x>=0 && hotspot.y>=0 && hotspot.x<f32(one_x.width) && hotspot.y<f32(one_x.height)) {
        return fmt.tprintf("%s, has its hotspot at %v, outside its %vx%v points",name,hotspot,one_x.width,one_x.height)
    }
    first:=max(one-(platform.CURSOR_LEVELS-1),0)
    if error=asset.texture_decode(&file,&a.types,&view,first,one+1);error!=.None {
        return fmt.tprintf("%s, cannot be read (%v): import it again",name,error)
    }
    total:=0
    for mip in view.mips[first:one+1] {total+=int(mip.width)*int(mip.height)*4}
    pixels,allocation:=make([]u8,total,app.allocator)
    if allocation!=nil {return fmt.tprintf("%s, has no memory to be decoded",name)}
    defer delete(pixels,app.allocator)
    levels:[platform.CURSOR_LEVELS]platform.Cursor_Level
    count,at:=0,0
    // 1x first, then the larger ones.
    #reverse for mip,i in view.mips[first:one+1] {
        level:=first+i
        out:=pixels[at:][:int(mip.width)*int(mip.height)*4]
        at+=len(out)
        if !asset.texture_level_rgba8(info.format,asset.texture_mip(view,level),int(mip.width),int(mip.height),out) {
            return fmt.tprintf("%s, has a level that does not decode: import it again",name)
        }
        levels[count]={pixels=out,width=i32(mip.width),height=i32(mip.height)}
        count+=1
    }
    if error:=platform.window_cursor_image_set(app.platform,cursor,levels[:count],hotspot);error!=.None {
        return fmt.tprintf("%s, was refused by the window (%v)",name,error)
    }
    return ""
}
