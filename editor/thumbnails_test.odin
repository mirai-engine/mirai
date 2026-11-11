package editor

import "core:fmt"
import "core:os"
import "core:slice"
import "core:testing"
import "core:time"
import "mirai:asset"
import "mirai:editor/history"
import "mirai:host"
import gpu "mirai:render"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:ui"

@(private="file") PROGRAMS :: u64(0x7072)

@(test)
stored_thumbnails_last_until_their_asset_or_what_it_needs_changes :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    root:=base.test_folder(t,"thumbnails")
    if root=="" {return}
    assets,folder:=fmt.tprintf("%s/assets",root),fmt.tprintf("%s/.mirai/thumbs",root)
    os.make_directory_all(fmt.tprintf("%s/textures",assets))
    texture,material,other:=base.Asset_Id{1,1},base.Asset_Id{2,2},base.Asset_Id{3,3}
    texture_write :: proc(t:^testing.T,types:^asset.Types,path:string,id:base.Asset_Id,value:u8) {
        pixels:[16]u8
        slice.fill(pixels[:],value)
        testing.expect_value(t,asset.texture_save(path,types,{id=id,width=2,height=2,format=.RGBA8,mips={pixels[:]}}),asset.Error.None)
    }
    material_write :: proc(t:^testing.T,types:^asset.Types,path:string,id,texture:base.Asset_Id,roughness:f32) {
        info:=asset.MATERIAL_DEFAULTS
        info.maps.base_color.texture=texture
        info.roughness=roughness
        testing.expect_value(t,asset.material_save(path,types,{id=id,info=info}),asset.Error.None)
    }
    texture_write(t,&types,fmt.tprintf("%s/textures/wood.tex",assets),texture,10)
    material_write(t,&types,fmt.tprintf("%s/wood.mat",assets),material,texture,0.5)
    material_write(t,&types,fmt.tprintf("%s/other.mat",assets),other,{},0.5)
    r:asset.Registry;asset.registry_init(&r,assets,fmt.tprintf("%s/.mirai/cache/registry",root));defer asset.registry_destroy(&r)
    testing.expect_value(t,asset.registry_scan(&r),asset.Error.None)

    subject:Thumbnail_Subject
    key:=thumbnail_store_key(&r,material,subject,.Small,PROGRAMS)
    testing.expect(t,key!=0 && key!=thumbnail_store_key(&r,material,subject,.Large,PROGRAMS) && key!=thumbnail_store_key(&r,other,subject,.Small,PROGRAMS))
    testing.expect_value(t,thumbnail_store_key(&r,{9,9},subject,.Small,PROGRAMS),u64(0))
    // The revision of the assets is not what a preview is drawn from; the shaders are.
    subject.revision=7
    testing.expect_value(t,thumbnail_store_key(&r,material,subject,.Small,PROGRAMS),key)
    testing.expect(t,thumbnail_store_key(&r,material,subject,.Small,PROGRAMS+1)!=key)

    image:=make([]u8,THUMBNAIL_SIZE*THUMBNAIL_SIZE*4,context.temp_allocator)
    for &value,at in image {value=u8(at%251)}
    file:Thumbnail_File
    read:[dynamic]u8
    defer {thumbnail_file_destroy(&file);delete(read)}
    testing.expect(t,thumbnail_save(folder,material,THUMBNAIL_SIZE,key,image,&file))
    testing.expect(t,thumbnail_load(folder,material,THUMBNAIL_SIZE,key,&file,&read) && slice.equal(read[:],image))
    testing.expect(t,!thumbnail_load(folder,material,THUMBNAIL_LARGE,key,&file,&read))
    testing.expect(t,!thumbnail_load(folder,other,THUMBNAIL_SIZE,key,&file,&read))

    // Saving what the asset needs gives another key: the stored preview is drawn again.
    time.sleep(10*time.Millisecond)
    texture_write(t,&types,fmt.tprintf("%s/textures/wood.tex",assets),texture,200)
    testing.expect_value(t,asset.registry_refresh(&r,{"textures/wood.tex"}),asset.Error.None)
    saved_texture:=thumbnail_store_key(&r,material,subject,.Small,PROGRAMS)
    testing.expect(t,saved_texture!=key && !thumbnail_load(folder,material,THUMBNAIL_SIZE,saved_texture,&file,&read))
    testing.expect_value(t,thumbnail_store_key(&r,other,{},.Small,PROGRAMS),thumbnail_store_key(&r,other,subject,.Small,PROGRAMS))
    testing.expect(t,thumbnail_save(folder,material,THUMBNAIL_SIZE,saved_texture,image,&file))
    testing.expect(t,thumbnail_load(folder,material,THUMBNAIL_SIZE,saved_texture,&file,&read))

    // Saving the asset itself does too.
    time.sleep(10*time.Millisecond)
    material_write(t,&types,fmt.tprintf("%s/wood.mat",assets),material,texture,0.25)
    testing.expect_value(t,asset.registry_refresh(&r,{"wood.mat"}),asset.Error.None)
    saved_material:=thumbnail_store_key(&r,material,subject,.Small,PROGRAMS)
    testing.expect(t,saved_material!=saved_texture && saved_material!=key && !thumbnail_load(folder,material,THUMBNAIL_SIZE,saved_material,&file,&read))

    // An unsaved change is another content; dropping it gives back the key of the file.
    held,_:=serial.file_read(fmt.tprintf("%s/other.mat",assets),context.temp_allocator)
    other_key:=thumbnail_store_key(&r,other,subject,.Small,PROGRAMS)
    material_write(t,&types,fmt.tprintf("%s/changed.mat.tmp",assets),other,{},0.75)
    changed,_:=serial.file_read(fmt.tprintf("%s/changed.mat.tmp",assets),context.temp_allocator)
    testing.expect(t,len(held)>0 && len(changed)>0)
    testing.expect_value(t,asset.registry_memory_set(&r,"other.mat",changed),asset.Error.None)
    testing.expect(t,thumbnail_store_key(&r,other,subject,.Small,PROGRAMS)!=other_key)
    {dropped,_:=asset.registry_memory_drop(&r,"other.mat");testing.expect(t,dropped)}
    testing.expect_value(t,thumbnail_store_key(&r,other,subject,.Small,PROGRAMS),other_key)

    // An asset that no file is any more loses its previews; the others keep theirs.
    other_large:=thumbnail_store_key(&r,other,subject,.Large,PROGRAMS)
    testing.expect(t,thumbnail_save(folder,other,THUMBNAIL_LARGE,other_large,make([]u8,THUMBNAIL_LARGE*THUMBNAIL_LARGE*4,context.temp_allocator),&file))
    testing.expect(t,thumbnail_save(folder,other,THUMBNAIL_SIZE,other_key,image,&file))
    testing.expect(t,os.remove(fmt.tprintf("%s/other.mat",assets))==nil)
    testing.expect_value(t,asset.registry_refresh(&r,{"other.mat"}),asset.Error.None)
    testing.expect(t,len(r.removed)==1 && r.removed[0]==other)
    thumbnail_store_forget(folder,r.removed[:])
    clear(&r.removed)
    testing.expect(t,!os.exists(thumbnail_file(folder,other,THUMBNAIL_SIZE)) && !os.exists(thumbnail_file(folder,other,THUMBNAIL_LARGE)))
    testing.expect(t,os.is_file(thumbnail_file(folder,material,THUMBNAIL_SIZE)))

    // A file cut short is no preview.
    path:=thumbnail_file(folder,material,THUMBNAIL_SIZE)
    whole,_:=serial.file_read(path,context.temp_allocator)
    for cut in ([]int{0,THUMBNAIL_FILE_HEADER-1,THUMBNAIL_FILE_HEADER,len(whole)-1}) {
        testing.expect_value(t,serial.file_write_atomic(path,whole[:cut]),serial.File_Error.None)
        testing.expect(t,!thumbnail_load(folder,material,THUMBNAIL_SIZE,saved_texture,&file,&read))
    }
    free_all(context.temp_allocator)
}

@(test)
a_provider_image_is_drawn_between_frames_after_the_frame_that_asked :: proc(t:^testing.T) {
    p:Thumbnails
    defer {delete(p.pixels);delete(p.image);thumbnail_file_destroy(&p.file)}
    assets:host.Assets
    assets.renderer=(^gpu.Renderer)(uintptr(16))
    app:host.App
    app.assets=&assets
    edits:history.Edits
    s:=new(Session)
    defer free(s)
    s.app,s.thumbnails,s.edits,s.frame=&app,&p,&edits,10
    KIND :: asset.Fourcc(0x74736574)
    image :: proc(s:^Session,subject:^Thumbnail_Subject,side:int,out:[]u8) -> bool {
        for &value in out[:side*side*4] {value=200}
        return true
    }
    p.providers[0]={kinds={0=KIND},count=1,image=image}
    p.provider_count,p.providers_library=1,s.library_generation+1
    subject:=Thumbnail_Subject{provider=KIND}
    // The frame that asks shows nothing yet, and another subject waits its turn.
    testing.expect_value(t,preview_request(s,7,&subject,32),ui.Quad{})
    testing.expect(t,p.picture.key==7 && !p.dirty)
    other:=Thumbnail_Subject{provider=KIND,clip=1}
    testing.expect_value(t,preview_request(s,8,&other,32),ui.Quad{})
    testing.expect_value(t,p.picture.key,u64(7))
    thumbnail_picture_draw(s)
    testing.expect(t,p.picture.key==0 && p.dirty)
    testing.expect_value(t,p.pixels[0],u8(200))
    // The next frames show it, without drawing it again.
    s.frame+=1
    quad:=preview_request(s,7,&subject,32)
    testing.expect_value(t,quad.kind,host.UI_QUAD_THUMBNAIL)
    testing.expect_value(t,p.picture.key,u64(0))
    // A cell another subject took before its turn is not drawn into.
    s.frame+=1
    p.dirty=false
    testing.expect_value(t,preview_request(s,8,&other,32),ui.Quad{})
    p.cells[p.picture.slot].key=9
    thumbnail_picture_draw(s)
    testing.expect(t,p.picture.key==0 && !p.dirty)
}
