package host

import "core:fmt"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:platform"
import "mirai:std/base"
import "mirai:ui"

@(private="file")
Cursor_Fixture :: struct {
    app:App,
    assets:Assets,
    types:asset.Types,
    root:string,
}

@(private="file")
cursor_fixture :: proc(t:^testing.T,f:^Cursor_Fixture,name:string) -> bool {
    f.root=base.test_folder(t,name)
    if f.root=="" {return false}
    asset.types_init(&f.types)
    p,error:=platform.create({headless=true,pacing=platform.Frame_Pacing{}})
    if !testing.expect_value(t,error,platform.Error.None) {return false}
    f.app={allocator=context.allocator,platform=p,density=2,assets=&f.assets}
    return true
}

@(private="file")
cursor_fixture_destroy :: proc(f:^Cursor_Fixture) {
    if f.app.assets!=nil && f.assets.allocator.procedure!=nil {assets_destroy(&f.assets)}
    if f.app.platform!=nil {platform.destroy(f.app.platform)}
    asset.types_destroy(&f.types)
}

// A .tex of a side and its levels down to 1, whatever its format holds.
@(private="file")
cursor_texture_save :: proc(t:^testing.T,f:^Cursor_Fixture,path:string,desc:asset.Texture_Desc) -> bool {
    desc:=desc
    images:=max(desc.layers,1)
    mips:=make([dynamic][]u8,context.temp_allocator)
    for w,h:=desc.width,desc.height;;w,h=max(w/2,1),max(h/2,1) {
        level:=make([]u8,asset.texture_level_size(desc.format,w,h)*images,context.temp_allocator)
        for &value,i in level {value=u8(i*7)}
        append(&mips,level)
        if w==1 && h==1 {break}
    }
    desc.mips=mips[:]
    return testing.expect_value(t,asset.texture_save(fmt.tprintf("%s/%s",f.root,path),&f.types,desc),asset.Error.None)
}

// One frame of the game asking for the images of Pointer.
@(private="file")
cursor_declare :: proc(f:^Cursor_Fixture,image:ui.Cursor_Image,problems:^core.Problems) {
    images:[ui.Cursor]ui.Cursor_Image
    images[.Pointer]=image
    app_cursor_game(&f.app,.Pointer,false,images,problems)
}

@(private="file")
cursor_problem :: proc(problems:^core.Problems) -> string {
    for &p in problems.entries[:problems.count] {
        if base.text_get(p.code[:])=="gui.cursor" {return base.text_get(p.text[:])}
    }
    return ""
}

// A .tex becomes a cursor with its level at 1x and the larger ones; what
// cannot be one is told once, naming the file and the fix, and the shape keeps
// the system's.
@(test)
a_cursor_image_takes_a_color_tex_with_a_level_at_its_size :: proc(t:^testing.T) {
    f:Cursor_Fixture
    if !cursor_fixture(t,&f,"host-cursor-images") {return}
    defer cursor_fixture_destroy(&f)
    Saved :: struct {path:string,desc:asset.Texture_Desc}
    files:=[]Saved{
        {"arrow.tex",{id={1,1},width=64,height=64,format=.RGBA8,flags={.Srgb}}},
        {"small.tex",{id={1,2},width=32,height=32,format=.RGBA8,flags={.Srgb}}},
        {"packed.tex",{id={1,3},width=32,height=32,format=.BC7,flags={.Srgb}}},
        {"linear.tex",{id={1,4},width=32,height=32,format=.RGBA8}},
        {"hdr.tex",{id={1,5},width=32,height=32,format=.RGBA16F}},
        {"deep.tex",{id={1,6},width=32,height=32,format=.RGBA16}},
        {"normals.tex",{id={1,7},width=32,height=32,format=.BC5}},
        {"array.tex",{id={1,8},width=32,height=32,layers=2,format=.RGBA8,flags={.Srgb}}},
        {"cube.tex",{id={1,9},width=32,height=32,layers=6,format=.RGBA8,flags={.Srgb,.Cube}}},
        {"huge.tex",{id={1,10},width=512,height=512,format=.RGBA8,flags={.Srgb}}},
    }
    for file in files {
        if !cursor_texture_save(t,&f,file.path,file.desc) {return}
    }
    if !testing.expect(t,assets_init(&f.assets,{root=f.root,capacity=8})) {return}
    Image_Case :: struct {name:string,image:ui.Cursor_Image,fix:string}
    cases:=[]Image_Case{
        {"its 1x level and a denser one",{texture={1,1},hotspot={3,3}},""},
        {"the default size",{texture={1,2}},""},
        {"blocks of color",{texture={1,3},size=32},""},
        {"a denser level at 1x",{texture={1,1},size=64,hotspot={63,63}},""},
        {"not sRGB",{texture={1,4}},"import it as color"},
        {"HDR",{texture={1,5}},"not HDR, 16-bit or normals"},
        {"16-bit",{texture={1,6}},"not HDR, 16-bit or normals"},
        {"normals",{texture={1,7}},"not HDR, 16-bit or normals"},
        {"an array",{texture={1,8}},"a single image"},
        {"a cube",{texture={1,9}},"a single image"},
        {"too large",{texture={1,10}},"at most 256"},
        {"no level at its size",{texture={1,1},size=24},"no level 24 pixels wide"},
        {"hotspot outside",{texture={1,2},hotspot={32,0}},"outside its 32x32 points"},
        {"hotspot not a number",{texture={1,2},hotspot={f32(0h7fc00000),0}},"outside"},
        {"size not whole",{texture={1,2},size=31.5},"whole number of points"},
        {"size past the limit",{texture={1,2},size=1000},"whole number of points"},
        {"no such asset",{texture={9,9}},"a .tex of the project"},
    }
    for c in cases {
        cursor_declare(&f,{},nil)
        problems:core.Problems
        cursor_declare(&f,c.image,&problems)
        text:=cursor_problem(&problems)
        if c.fix=="" {
            testing.expectf(t,text=="","%s: %s",c.name,text)
        } else {
            testing.expectf(t,strings.contains(text,c.fix) && strings.contains(text,"Pointer"),"%s: %q does not say %q",c.name,text,c.fix)
        }
        testing.expectf(t,(platform.Cursor.Pointer in f.app.platform.window.imaged)==(c.fix==""),"%s: the shape has an image only when it took one",c.name)
        // Told once: the next frame asks for the same and reads nothing.
        loads:=f.assets.stats.loads
        again:core.Problems
        cursor_declare(&f,c.image,&again)
        testing.expectf(t,again.count==0 && f.assets.stats.loads==loads,"%s: an unchanged frame reads nothing and tells nothing",c.name)
    }
}

// A cursor reads its file again when the file changes, also when nothing else
// loaded it, and not when another file does.
@(test)
a_cursor_image_follows_its_file :: proc(t:^testing.T) {
    f:Cursor_Fixture
    if !cursor_fixture(t,&f,"host-cursor-reload") {return}
    defer cursor_fixture_destroy(&f)
    if !cursor_texture_save(t,&f,"arrow.tex",{id={2,1},width=32,height=32,format=.RGBA8,flags={.Srgb}}) {return}
    if !cursor_texture_save(t,&f,"other.tex",{id={2,2},width=8,height=8,format=.RGBA8,flags={.Srgb}}) {return}
    if !testing.expect(t,assets_init(&f.assets,{root=f.root,capacity=8})) {return}
    image:=ui.Cursor_Image{texture={2,1}}
    problems:core.Problems
    cursor_declare(&f,image,&problems)
    testing.expect(t,platform.Cursor.Pointer in f.app.platform.window.imaged && problems.count==0)

    if !cursor_texture_save(t,&f,"other.tex",{id={2,2},width=16,height=16,format=.RGBA8,flags={.Srgb}}) {return}
    testing.expect(t,assets_refresh(&f.assets,{"other.tex"}))
    loads:=f.assets.stats.loads
    cursor_declare(&f,image,&problems)
    testing.expect(t,f.assets.stats.loads==loads,"another file changing reads nothing")

    if !cursor_texture_save(t,&f,"arrow.tex",{id={2,1},width=32,height=32,format=.RGBA8}) {return}
    testing.expect(t,assets_refresh(&f.assets,{"arrow.tex"}))
    cursor_declare(&f,image,&problems)
    testing.expect(t,strings.contains(cursor_problem(&problems),"import it as color"),"the new content is read and refused")
    testing.expect(t,platform.Cursor.Pointer not_in f.app.platform.window.imaged)

    f.app.density=1
    loads=f.assets.stats.loads
    cursor_declare(&f,image,&problems)
    testing.expect(t,f.assets.stats.loads==loads+1,"another density reads it again")
}

// What the window shows from what the game and the editor declare.
@(test)
the_cursor_of_the_window_is_the_one_that_holds_the_pointer :: proc(t:^testing.T) {
    f:Cursor_Fixture
    if !cursor_fixture(t,&f,"host-cursor-precedence") {return}
    defer cursor_fixture_destroy(&f)
    if !cursor_texture_save(t,&f,"arrow.tex",{id={3,1},width=32,height=32,format=.RGBA8,flags={.Srgb}}) {return}
    if !testing.expect(t,assets_init(&f.assets,{root=f.root,capacity=8})) {return}
    Precedence_Case :: struct {
        name:string,
        relative,holds,hidden:bool,
        editor,game:ui.Cursor,
        want:ui.Cursor,
        image:bool,
    }
    cases:=[]Precedence_Case{
        {name="nothing asked",want=.Default},
        {name="the game's shape with its image",game=.Pointer,want=.Pointer,image=true},
        {name="the game's shape without one",game=.Text,want=.Text},
        {name="the game hides it",game=.Pointer,hidden=true,want=.Hidden},
        {name="a widget hides it",game=.Hidden,want=.Hidden},
        {name="the editor holds it",holds=true,editor=.Resize_Vertical,game=.Pointer,hidden=true,want=.Resize_Vertical},
        {name="the editor's Pointer never shows the game's image",holds=true,editor=.Pointer,game=.Pointer,want=.Pointer},
        {name="the relative mouse keeps what was shown",relative=true,holds=true,editor=.Text,game=.Text,want=.Wait},
    }
    images:[ui.Cursor]ui.Cursor_Image
    images[.Pointer]={texture={3,1}}
    for c in cases {
        p:=f.app.platform
        platform.window_set_relative_mouse(p,false)
        platform.window_set_cursor(p,.Wait,false)
        platform.window_set_relative_mouse(p,c.relative)
        app_cursor_game(&f.app,c.game,c.hidden,images,nil)
        app_cursor_editor(&f.app,c.editor,c.holds)
        app_cursor_apply(&f.app)
        shown:=app_cursor_shown(&f.app)
        testing.expectf(t,shown.shape==c.want && (shown.image==base.Asset_Id{3,1})==c.image && shown.relative==c.relative,"%s: %v",c.name,shown)
    }
}
