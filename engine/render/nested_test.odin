package render

import "core:testing"
import mm "mirai:std/math"

// The faces a view gets nested views for are those it looks into from their
// front and sees, the nearest first, and only as many as it has room for.
@(test)
the_nearest_faces_in_front_of_the_eye_get_the_nested_views :: proc(t:^testing.T) {
    Item :: struct {place,normal:[3]f32}
    of :: proc(item:^Item,origin:[3]f32) -> (plane:[4]f32,corners:[4][3]f32,view:Nested_View) {
        plane=origin_plane_through({item.normal.x,item.normal.y,item.normal.z,0},item.place,origin)
        for &corner,i in corners {corner=item.place+{(i&1!=0?0.5:-0.5),(i&2!=0?0.5:-0.5),0}}
        return
    }
    origin:=[3]f32{16384,0,-8192}
    pass:Pass
    pass.width,pass.height,pass.origin,pass.eye=256,256,origin,{0,0,0,1}
    pass.view_projection=mm.perspective(f32(90*mm.RAD_PER_DEG),1,0.1,100)*mm.look_at({},{0,0,-1},{0,1,0})
    items:[dynamic]Item
    defer delete(items)
    // Farther first: the view sorts them. One more than it has room for.
    for i:=NESTED_VIEW_CAPACITY;i>=0;i-=1 {append(&items,Item{origin+{0,0,-3-f32(i)},{0,0,1}})}
    append(&items,Item{origin+{0,0,-2},{0,0,-1}}) // turned away
    append(&items,Item{origin+{0,0,5},{0,0,1}})   // behind the eye
    append(&items,Item{origin+{50,0,-5},{0,0,1}}) // out of the view
    faces:[NESTED_VIEW_CAPACITY]Nested_Face
    count:=nested_faces_nearest(&pass,items[:],of,&faces)
    if !testing.expect_value(t,count,NESTED_VIEW_CAPACITY) {return}
    for face,i in faces {
        testing.expectf(t,face.item==NESTED_VIEW_CAPACITY-i,"face %d is item %d",i,face.item)
        testing.expect(t,face.rect.z>0 && face.rect.w>0)
    }
}
