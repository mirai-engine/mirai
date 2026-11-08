package asset

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "mirai:std/base"
import mm "mirai:std/math"

// What a content tool (a program that writes the assets of a project) shares
// between its assets.
Content :: struct {
    types:Types,
    project:string, // a view
    failed:bool,    // something was not written; the tool exits with an error
}

content_init :: proc(content:^Content,project:string,allocator:=context.allocator) {
    content^={project=project}
    types_init(&content.types,allocator)
}

content_destroy :: proc(content:^Content) {
    types_destroy(&content.types)
    content^={}
}

// The id of an asset a tool writes: the same on every run, and apart from those of other projects.
content_id :: proc(project,kind,name:string) -> base.Asset_Id {
    return base.asset_id_named(fmt.tprintf("%s\x1f%s\x1f%s",kind,project,name))
}

// Prints what was written, or why it was not and marks the tool as failed.
content_check :: proc(content:^Content,what:string,error:Error) {
    if error==.None {
        fmt.printfln("wrote %s",what)
        return
    }
    fmt.eprintfln("%s: %s: %v",content.project,what,error)
    content.failed=true
}

// A scene or prefab written from code. Its entities take the ids 1, 2, 3...
// in the order they are added, so the same code gives the same bytes. The
// first error is reported and everything after it does nothing.
Scene_Builder :: struct {
    scene:Scene,
    content:^Content,
    next:base.Entity_Id,
    failed:bool,
}

builder_init :: proc(b:^Scene_Builder,content:^Content,kind:Fourcc,id:base.Asset_Id,allocator:=context.allocator) {
    b^={content=content}
    if error:=scene_init(&b.scene,&content.types,kind,id,allocator);error!=.None {
        builder_fail(b,"the document",error)
    }
}

builder_destroy :: proc(b:^Scene_Builder) {
    scene_destroy(&b.scene)
    b^={}
}

// Adds an entity with its Transform: a rotation or a scale left zero is the
// identity. The first entity of a prefab without a parent is its root, and a
// prefab has only one.
builder_entity :: proc(b:^Scene_Builder,name:string,place:mm.Transform={},parent:base.Entity_Id=0) -> base.Entity_Id {
    if b.failed {return 0}
    is_root:=b.scene.doc.kind==KIND_PREFAB && parent==0
    if is_root && b.scene.info.root!=0 {
        builder_fail(b,fmt.tprintf("%s: a prefab has one entity without a parent",name),.Invalid)
        return 0
    }
    b.next+=1
    id:=b.next
    if _,error:=scene_entity_add(&b.scene,id,parent,name);error!=.None {
        builder_fail(b,name,error)
        return 0
    }
    if is_root {b.scene.info.root=id}
    place:=place
    if place.rotation==0 {place.rotation=1}
    if place.scale==([3]f32{}) {place.scale=1}
    // mm.Transform has the name and the layout of the Transform component.
    builder_set(b,id,place)
    return id
}

// Sets the component of an entity named as the type of the value.
builder_set :: proc(b:^Scene_Builder,id:base.Entity_Id,value:$T) where intrinsics.type_is_named(T) {
    if b.failed {return}
    named,is_named:=type_info_of(T).variant.(runtime.Type_Info_Named)
    if !is_named {
        builder_fail(b,fmt.tprintf("%v is not a type a component can have",typeid_of(T)),.Invalid)
        return
    }
    value:=value
    if error:=scene_set(&b.scene,id,named.name,&value);error!=.None {
        row,found:=scene_entity_find(&b.scene,id)
        entity:=found?scene_entity(&b.scene,row).name:"no entity"
        builder_fail(b,fmt.tprintf("%s: %s",entity,named.name),error)
    }
}

// Saves to path and reports as content_check does.
builder_save :: proc(b:^Scene_Builder,path:string) {
    if b.failed {
        fmt.eprintfln("%s: %s: not written, it has errors",b.content.project,path)
        b.content.failed=true
        return
    }
    content_check(b.content,path,scene_save(&b.scene,path))
}

@(private="file")
builder_fail :: proc(b:^Scene_Builder,what:string,error:Error) {
    content_check(b.content,what,error)
    b.failed=true
}
