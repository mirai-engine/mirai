package editor

import "core:mem"
import "core:testing"
import "mirai:std/base"

@(test)
the_view_of_a_scene_is_kept_at_each_size_and_shown_where_it_already_is :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"scene-thumbs")
    if folder=="" {return}
    p:Thumbnails
    defer {delete(p.pixels);delete(p.image);thumbnail_file_destroy(&p.file)}
    id:=base.Asset_Id{0x7363,1}
    // A view in columns of red and blue, one pixel each: every cell averages them.
    pixels:=make([]u8,THUMBNAIL_CAPTURE_SIDE*THUMBNAIL_CAPTURE_SIDE*4,context.temp_allocator)
    for i in 0..<THUMBNAIL_CAPTURE_SIDE*THUMBNAIL_CAPTURE_SIDE {
        pixels[i*4+(0 if i%2==0 else 2)]=200
        pixels[i*4+3]=0
    }
    // The large cell of the scene is on screen, without an image yet.
    key:=thumbnail_scene_key(id)
    large:=thumbnail_key(mem.ptr_to_bytes(&key))
    p.cells[THUMBNAIL_SMALL_CELLS+3]={key=large,absent=THUMBNAIL_CAPTURED}
    thumbnail_scene_store(&p,folder,id,pixels)

    cell:=p.cells[THUMBNAIL_SMALL_CELLS+3]
    testing.expect(t,cell.ready && cell.stored==THUMBNAIL_CAPTURED && cell.absent==0)
    testing.expect(t,p.dirty)
    sides:=THUMBNAIL_SIDES
    for side in sides {
        image:[dynamic]u8
        defer delete(image)
        if !testing.expect(t,thumbnail_load(folder,id,side,THUMBNAIL_CAPTURED,&p.file,&image)) {continue}
        testing.expect_value(t,len(image),side*side*4)
        testing.expect_value(t,[4]u8{image[0],image[1],image[2],image[3]},[4]u8{100,0,100,255})
        testing.expect(t,!thumbnail_load(folder,id,side,THUMBNAIL_CAPTURED+1,&p.file,&image))
    }
}
