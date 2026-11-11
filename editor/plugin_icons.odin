package editor

import "core:os"
import "mirai:cook/textures"
import "mirai:project"
import "mirai:std/base"
import "mirai:ui"

// The icon of a plugin in the lists of plugins: the PNG its plugin.mirai
// names (project.Plugin_Manifest.icon) or, of one of the catalog not
// installed, the one beside its file (project.catalog_icon). It is read the
// first time a row shows it, and again only after its cell of the atlas of
// previews went to another image; without one, or when it cannot be read,
// the row shows the generic icon.

PLUGIN_ICON_SIZE :: f32(16) // points of the icon in a row

Plugin_Icon :: struct {
    key:u64,     // of its cell in the atlas; 0: not read
    slot:int,
    failed:bool, // the file could not be read as an image: the generic icon
}

// The icon of a plugin at folder whose manifest names icon; empty icon: none.
@(private)
plugin_icon_file :: proc(folder,icon:string) -> string {
    if icon=="" {return ""}
    return project.path(folder,icon,allocator=context.temp_allocator)
}

// The icon read from file, or the generic one, side points wide.
@(private)
plugin_icon_draw :: proc(s:^Session,icon:^Plugin_Icon,file:string,side:=PLUGIN_ICON_SIZE,color:ui.Color={}) {
    ctx:=s.gui.ctx
    quad:=plugin_icon_quad(s,icon,file)
    if quad.kind!=.Solid {
        if ui.box(ctx,{width=ui.fixed(side),height=ui.fixed(side),image=quad,layer={enabled=true,opacity=1,radius=side*0.2}}) {}
        return
    }
    ui.icon(ctx,ui.icon_user(u8(User_Icon.Plugin)),color if color!={} else ui.tone(ctx,"text_muted"),side)
}

@(private)
plugin_icon_quad :: proc(s:^Session,icon:^Plugin_Icon,file:string) -> ui.Quad {
    if file=="" || icon.failed || s.thumbnails==nil || s.app==nil || s.app.assets==nil || s.app.assets.renderer==nil {return {}}
    key:=thumbnail_key(transmute([]u8)file)
    if icon.key==key {
        if quad:=thumbnail_image_quad(s,icon.slot,key);quad.kind!=.Solid {return quad}
    }
    icon.key=0
    bytes,read_error:=os.read_entire_file(file,context.temp_allocator)
    if read_error!=nil {
        icon.failed=true
        return {}
    }
    picture,error:=textures.image_decode(bytes,context.temp_allocator)
    // Larger than an icon may be: the generic one, as mirai plugin check says.
    if error!=.None || picture.width==0 || picture.height==0 || picture.width>project.PLUGIN_ICON_MAX || picture.height>project.PLUGIN_ICON_MAX {
        icon.failed=true
        return {}
    }
    projects_cover(picture,THUMBNAIL_SIZE,&s.thumbnails.image)
    if icon.slot=thumbnail_image_put(s,key,.Small,s.thumbnails.image[:]);icon.slot<0 {return {}}
    icon.key=key
    return thumbnail_image_quad(s,icon.slot,key)
}

// The icon of the plugin of the catalog name, before it is installed.
@(private)
plugin_icon_catalog :: proc(s:^Session,name:string) -> string {
    folder:=base.text_get(s.plugins_git.catalog_folder[:])
    if folder=="" {return ""}
    return project.catalog_icon(folder,name,context.temp_allocator)
}
