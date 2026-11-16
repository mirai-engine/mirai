package save

import "core:c"
import "mirai:host"
import "mirai:std/base"
import stbi "vendor:stb/image"

// The thumbnail of a slot shown in the game: its PNG decoded into a texture
// of the assets (host.assets_texture_generate) whose id an Image of a .ui
// binds, as any texture asset. A world holds THUMBNAIL_TEXTURES of them; each
// lives until the game releases it, the slot is deleted, the slot is written
// again and asked for, or the world goes.

THUMBNAIL_TEXTURES :: 32 // thumbnails a world holds as textures at once
THUMBNAIL_SIDE_MAX :: 4096 // the widest a thumbnail decodes: past it the slot is Corrupt

// The game asks with thumbnail_texture and this library releases what a
// slot deleted or a world that goes leaves: both write it, in the order of
// the loop.
@(storage,host,by_world,shared)
Save_Thumbnails :: struct {
    items:[THUMBNAIL_TEXTURES]Thumbnail_Texture,
}

Thumbnail_Texture :: struct {
    slot:[SLOT_CAPACITY]u8 `mirai:"text"`,
    written:i64,           // of the slot it was read from, in nanoseconds since 1970 UTC
    texture:base.Asset_Id, // none: a free entry
}

// The thumbnail of a slot as a texture: the id an Image of a .ui binds to
// show it. The first time it reads and decodes the PNG; asked again it reads
// only the header, and gives the same id while the slot was not written
// again, or a new one in place of the old, which goes. {} with None when
// the slot has none. Unavailable: the world was not made by the application
// or it has no assets; Corrupt: the PNG does not decode, or is larger than
// THUMBNAIL_SIDE_MAX; No_Room: THUMBNAIL_TEXTURES are held, or the assets
// or the renderer have no room for another texture. Between frames, as
// every load.
thumbnail_texture :: proc(thumbnails:^Save_Thumbnails,state:^Save_State,app:^host.App,slot:string) -> (texture:base.Asset_Id,error:Error) {
    if thumbnails==nil || app.assets==nil {return {},.Unavailable}
    path:=slot_path(state,app,slot) or_return
    header,_,header_error:=slot_header(path)
    held,free:=-1,-1
    for &item,i in thumbnails.items {
        if item.texture=={} {
            if free<0 {free=i}
        } else if base.text_get(item.slot[:])==slot {
            held=i
        }
    }
    if held>=0 {
        item:=&thumbnails.items[held]
        if header_error==.None && item.written==header.written {return item.texture,.None}
        host.assets_texture_release(app.assets,item.texture)
        item^={}
        free=held
    }
    if header_error!=.None {return {},header_error}
    if header.thumbnail==0 {return {},.None}
    if free<0 {return {},.No_Room}
    png:=slot_thumbnail(state,app,slot,context.temp_allocator) or_return
    width,height,channels:c.int
    if len(png)==0 || stbi.info_from_memory(raw_data(png),c.int(len(png)),&width,&height,&channels)==0 {return {},.Corrupt}
    if width<=0 || height<=0 || width>THUMBNAIL_SIDE_MAX || height>THUMBNAIL_SIDE_MAX {return {},.Corrupt}
    pixels:=stbi.load_from_memory(raw_data(png),c.int(len(png)),&width,&height,&channels,4)
    if pixels==nil {return {},.Corrupt}
    defer stbi.image_free(pixels)
    made:bool
    texture,made=host.assets_texture_generate(app.assets,pixels[:int(width)*int(height)*4],int(width),int(height),name="save thumbnail")
    if !made {return {},.No_Room}
    item:=&thumbnails.items[free]
    base.text_set(item.slot[:],slot)
    item.written,item.texture=header.written,texture
    return texture,.None
}

// Lets go of the texture of the thumbnail of a slot, if the world holds one:
// what showed its id shows nothing.
thumbnail_release :: proc(thumbnails:^Save_Thumbnails,assets:^host.Assets,slot:string) {
    if thumbnails==nil {return}
    for &item in thumbnails.items {
        if item.texture=={} || base.text_get(item.slot[:])!=slot {continue}
        if assets!=nil {host.assets_texture_release(assets,item.texture)}
        item={}
    }
}

// Lets go of every thumbnail the world holds.
thumbnails_release :: proc(thumbnails:^Save_Thumbnails,assets:^host.Assets) {
    if thumbnails==nil {return}
    for &item in thumbnails.items {
        if item.texture!={} && assets!=nil {host.assets_texture_release(assets,item.texture)}
        item={}
    }
}
